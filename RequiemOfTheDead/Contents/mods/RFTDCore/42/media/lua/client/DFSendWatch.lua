-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFSendWatch - faction and safehouse lifecycle ledger (client only).
--
-- ===========================================================================
-- WHY THIS EXISTS: it closes the blind spot RDGuardian's header documents.
--
-- Guardian watches OnClientCommand and records everything on that channel. In
-- 42.20 the faction lifecycle moved to INetworkPacket, which fires no
-- OnClientCommand, writes no cmd.txt entry, and - as Guardian's header sets out
-- with line numbers - has NO server-side Lua hook of any kind. Disbanding a
-- faction or seizing its ownership, which is exactly Guardian's subject matter,
-- leaves no trace we can see. Guardian concluded that closing it needed
-- interception below Lua: the shelved Java agent.
--
-- It does not. The client-side CALL SITE is a plain Lua global, so wrapping it
-- puts the act back on a channel the server does watch. Every function below is
-- confirmed @LuaMethod(global=true) in the 42.20.2 decompile
-- (LuaManager.java:4246-4372), so these are engine globals living in the Lua
-- global table - assigning over one replaces what subsequent Lua calls resolve.
--
-- WHAT IT IS WORTH, stated plainly because the difference is the whole point:
-- this is a LEDGER, not evidence. A client that does not want to be recorded
-- deletes this file. It covers accidents, disputes and griefing between honest
-- players - which is most of what actually happens - and covers nothing at all
-- against someone determined. RDTripwire files it under "lifecycle", never
-- broadcasts it, and never flashes the badge for it. See that file's header.
-- ===========================================================================
--
-- THREE THINGS KWRR SECURITY'S EQUIVALENT GETS WRONG, all avoided here:
--
--   1. It guards each hook with a bare `return` at FILE SCOPE
--      (`if type(fn) ~= "function" then return end`). That aborts the entire
--      file, so one unexpected global silently kills every hook below it. Here
--      each wrap is a function call and a failed one costs only itself.
--   2. Its sendSafezoneClaim wrapper drops the original's return value while
--      every sibling returns it. `wrap` below returns unconditionally.
--   3. Its parameter names are guesses that disagree with the engine in two
--      places - sendSafehouseClaim's third argument is the TITLE, not a player
--      name, and sendSafezoneClaim's extent pair is passed w,h by both vanilla
--      call sites while the decompiled signature names them h,w. We log the two
--      numbers as given and label them by position rather than inherit either
--      reading.
--
-- A REPORT MUST NEVER COST THE CALL. The description is built and sent inside a
-- pcall, and the original runs whether or not that succeeded. An observer that
-- can break the thing it observes is worse than no observer.

if isServer() then return end

require "RDShared"

DFSendWatch = DFSendWatch or { originals = {}, installed = false }

-- ---------------------------------------------------------------------------
-- Reporting
-- ---------------------------------------------------------------------------

local function report(act, text)
    local player = getPlayer()
    if not player then return end
    sendClientCommand(player, RDShared.MODULE, "lifecycleReport", {
        act  = tostring(act),
        text = tostring(text),
    })
end

-- Safe accessors. Every one of these touches a Java object that may be nil or
-- may throw; a description that fails degrades to a placeholder rather than
-- taking the wrapper down with it.
local function nameOf(obj)
    local v
    if pcall(function() v = obj:getName() end) and v then return tostring(v) end
    return "?"
end

local function titleOf(obj)
    local v
    if pcall(function() v = obj:getTitle() end) and v then return tostring(v) end
    return "?"
end

local function ownerOf(obj)
    local v
    if pcall(function() v = obj:getOwner() end) and v then return tostring(v) end
    return "?"
end

local function boundsOf(safehouse)
    local x, y, x2, y2
    local ok = pcall(function()
        x, y   = safehouse:getX(),  safehouse:getY()
        x2, y2 = safehouse:getX2(), safehouse:getY2()
    end)
    if not ok or not x then return "?" end
    return string.format("%d,%d..%d,%d", x, y, x2, y2)
end

-- ---------------------------------------------------------------------------
-- The wrap primitive
-- ---------------------------------------------------------------------------
--
-- Idempotent: re-running this file must never stack a second wrap onto a global,
-- because every stacked wrap is another description built and another packet
-- sent per call, forever. The original is stashed under its name and its
-- presence is the sentinel.
--
-- `describe` receives the call's arguments and returns a string, or nil to skip
-- reporting for that call. It runs inside a pcall.
--
-- ARGUMENTS ARE UNPACKED BY FIXED ARITY, not through `{...}` + unpack. Kahlua
-- does expose unpack (BaseLib.java:447) so that form would run, but `#` on a
-- table built from `...` is undefined when any argument is nil - a nil `host`
-- would silently truncate the list and hand `describe` the wrong parameters.
-- Six named locals cannot do that, and cost no per-call table either. Six is the
-- widest signature in the set (sendSafezoneClaim); nothing here takes more.
local function wrap(name, describe)
    local orig = _G[name]
    if type(orig) ~= "function" then return false end
    if DFSendWatch.originals[name] then return false end
    DFSendWatch.originals[name] = orig

    _G[name] = function(...)
        local a1, a2, a3, a4, a5, a6 = ...
        -- guarded: this wraps sixteen rewritten engine globals. The sensor must
        -- never cost the real call - `return orig(...)` below is the continuation
        -- it protects, which the engine's own boundary would skip.
        pcall(function()
            local text = describe(a1, a2, a3, a4, a5, a6)
            if text then report(name, text) end
        end)
        return orig(...)
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Installation
-- ---------------------------------------------------------------------------
--
-- MULTIPLAYER ONLY. In single player there is no server to report to and
-- sendClientCommand has nothing to do; wrapping every faction global to build
-- descriptions nobody receives is pure cost.
--
-- Deferred to OnGameStart rather than done at file scope. The globals are Java
-- and exist from Lua init, so file scope would work today - but a wrap installed
-- before the game is up has no getPlayer() to report as, and OnGameStart is the
-- point where that is guaranteed.

-- ON BY DEFAULT, with an off switch, because this file WRAPS SIXTEEN ENGINE
-- GLOBALS that vanilla UI calls. If a wrap ever misbehaves, the symptom is a
-- faction or safehouse action failing for every player - and the fix has to be
-- available to a server admin at 3am without a redeploy. The sandbox option is
-- that fix. It is read server-side and synced, so the SERVER decides whether its
-- clients instrument themselves.
local function armed()
    -- SandboxVars is nil until options load; the chain replaces the guard
    local v = SandboxVars and SandboxVars.RFTDCore and SandboxVars.RFTDCore.SendWatchEnabled
    if v == nil then return true end   -- absent option = on
    return v == true
end

local function install()
    if DFSendWatch.installed then return end
    if not isClient() then return end
    if not armed() then
        print("[RFTDCore] DFSendWatch: disarmed by sandbox (SendWatchEnabled=false)")
        return
    end
    DFSendWatch.installed = true

    local n = 0
    local function w(name, fn) if wrap(name, fn) then n = n + 1 end end

    -- Faction. Signatures verified at LuaManager.java:4248-4304.
    w("sendFactionCreate", function(title, host)
        return "created faction [" .. tostring(title) .. "]"
    end)
    w("sendFactionDisband", function(faction)
        return "disbanded faction [" .. nameOf(faction) .. "]"
    end)
    w("sendFactionChangeOwner", function(faction, username)
        return "transferred faction [" .. nameOf(faction) .. "] from ["
            .. ownerOf(faction) .. "] to [" .. tostring(username) .. "]"
    end)
    w("sendFactionChangeTitle", function(faction, title)
        return "renamed faction [" .. nameOf(faction) .. "] to [" .. tostring(title) .. "]"
    end)
    w("sendFactionChangeTag", function(faction)
        local tag
        pcall(function() tag = faction:getTag() end)
        return "changed tag of faction [" .. nameOf(faction) .. "] to [" .. tostring(tag or "") .. "]"
    end)
    w("sendFactionInvite", function(faction, host, invited)
        return "invited [" .. tostring(invited) .. "] to faction [" .. nameOf(faction) .. "]"
    end)
    w("sendFactionRemoveMember", function(faction, username)
        -- wrap() pcalls every describer already (:124) - no inner guard, just
        -- the nil-check that keeps the generic label when there is no player.
        local p = getPlayer()
        local me = p and p:getUsername()
        if me and tostring(username) == tostring(me) then
            return "left faction [" .. nameOf(faction) .. "]"
        end
        return "removed [" .. tostring(username) .. "] from faction [" .. nameOf(faction) .. "]"
    end)
    w("acceptFactionInvite", function(faction, host, invited, isAccepted)
        return (isAccepted and "joined faction [" or "declined faction [")
            .. nameOf(faction) .. "]"
    end)

    -- Safehouse. Signatures verified at LuaManager.java:4311-4372.
    w("sendSafehouseClaim", function(square, player, title)
        local x, y
        if square then x, y = square:getX(), square:getY() end
        return "claimed safehouse [" .. tostring(title) .. "] at ["
            .. tostring(x or "?") .. "," .. tostring(y or "?") .. "]"
    end)
    w("sendSafehouseRelease", function(safehouse)
        return "released safehouse [" .. titleOf(safehouse) .. "] at [" .. boundsOf(safehouse) .. "]"
    end)
    w("sendSafehouseChangeOwner", function(safehouse, username)
        return "transferred safehouse [" .. titleOf(safehouse) .. "] from ["
            .. ownerOf(safehouse) .. "] to [" .. tostring(username) .. "]"
    end)
    w("sendSafehouseChangeTitle", function(safehouse, title)
        return "renamed safehouse [" .. titleOf(safehouse) .. "] to [" .. tostring(title) .. "]"
    end)
    w("sendSafehouseInvite", function(safehouse, host, invited)
        return "invited [" .. tostring(invited) .. "] to safehouse [" .. titleOf(safehouse) .. "]"
    end)
    w("acceptSafehouseInvite", function(safehouse, host, invited, isAccepted)
        return (isAccepted and "joined safehouse [" or "declined safehouse [")
            .. titleOf(safehouse) .. "]"
    end)
    -- KWRR walks the member list to decide whether this is an add or a remove.
    -- We do not: the walk races the change it is describing, and "changed
    -- membership" plus the name is the fact we can actually stand behind.
    w("sendSafehouseChangeMember", function(safehouse, player)
        return "changed safehouse [" .. titleOf(safehouse) .. "] membership for ["
            .. tostring(player) .. "]"
    end)
    w("sendSafehouseChangeRespawn", function(safehouse, player, doRemove)
        return (doRemove and "cleared respawn at safehouse [" or "set respawn at safehouse [")
            .. titleOf(safehouse) .. "] for [" .. tostring(player) .. "]"
    end)
    -- Positional labels, not w/h: both vanilla call sites pass width then height
    -- (ISAddSafeZoneUI.lua:22, MultiplayerZoneEditorMode_Safehouse.lua:865) while
    -- the decompiled signature names the pair h,w. Rather than pick a side and
    -- log a wrong extent, the two numbers are reported as given.
    w("sendSafezoneClaim", function(username, x, y, a, b, title)
        return "created safezone [" .. tostring(title) .. "] for [" .. tostring(username)
            .. "] at [" .. tostring(x) .. "," .. tostring(y) .. "] extent ["
            .. tostring(a) .. "," .. tostring(b) .. "]"
    end)

    print("[RFTDCore] DFSendWatch: " .. tostring(n)
        .. " faction/safehouse call sites instrumented (lifecycle ledger; see header for what it is worth)")
end

-- install rewrites sixteen engine globals. No guard: Event.trigger isolates
-- listeners (Event.java:53-63), so a failed install already costs the ledger,
-- not the boot.
Events.OnGameStart.Add(function() install() end)

return DFSendWatch

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
