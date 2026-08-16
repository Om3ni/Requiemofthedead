-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFIntentWatch - records attempts to open staff-only UI without the capability
-- for it (client only).
--
-- ===========================================================================
-- WHY THIS IS WORTH HAVING even though Guardian exists: a BLOCKED attempt never
-- becomes a client command, so it leaves no trace on Guardian's channel, in
-- cmd.txt, or anywhere else server-side. Someone walking the admin panels
-- looking for an unlocked door is invisible to every sensor we own until they
-- succeed at something. This is the only signal that reports the walking.
--
-- It is INTENT, not effect. Nothing here is proof of harm; the panel may well
-- have refused them. That is precisely why it is worth a line in the ring - a
-- pattern of refusals from one account is the shape of probing, and no single
-- refusal is.
-- ===========================================================================
--
-- RECORDS, NEVER BLOCKS - and the reasoning is not squeamishness:
--
--   * A client-side block is bypassed by not loading this file. It buys no
--     protection at all, only the illusion of some.
--   * It tells the person probing, instantly, that they were detected. A
--     tripwire whose whole value is the ATTEMPT should not announce itself.
--   * Vanilla already refuses these panels server-side where it matters. Adding
--     a second, weaker gate on top risks locking out a legitimately capable
--     admin whose role we read differently than the engine does - trading a real
--     failure for an imaginary one.
--
-- KWRR Security's equivalent blocks (and shows the blocked player a paywall
-- modal). We take its detection idea and leave its enforcement behind.
--
-- The same family rule as RDCmdRelay states it: tripwire, not gate.
--
-- REPORTS ARE CLIENT-REPORTED, the weaker of RDTripwire's two tiers. They land
-- in the console and the forensic ring; they never flash the deck badge. See
-- RDTripwire's header for why the tiers are kept apart.

if isServer() then return end

require "RDShared"

DFIntentWatch = DFIntentWatch or { wrapped = {}, installed = false }

-- ---------------------------------------------------------------------------
-- Capability test
-- ---------------------------------------------------------------------------
--
-- Fails CLOSED for the report, not for the user: if we cannot read the role at
-- all we assume the player is authorised and stay silent. A tripwire that fires
-- because our own capability lookup broke is noise, and noise is how an alert
-- channel dies.
local function lacks(capabilityName)
    if not Capability or not Capability[capabilityName] then return false end
    local player = getPlayer()
    if not player then return false end

    -- getRole (IsoPlayer:6987) is a field return and may be nil early;
    -- hasCapability (Role:187) is HashSet.contains on a final set. A broken
    -- lookup still reads as "authorised" - stay silent, per the note above.
    local role = player.getRole and player:getRole()
    if not role then return false end
    return role:hasCapability(Capability[capabilityName]) ~= true
end

local function trip(code, what)
    local player = getPlayer()
    if not player then return end
    sendClientCommand(player, RDShared.MODULE, "tripwireReport", {
        code              = code,
        text              = "attempted to open [" .. what .. "] without the capability for it",
        channel           = "intent",
        -- Tells the server this claim is about the reporter's OWN access level,
        -- so it can drop the report when it sees the reporter is in fact staff.
        -- RDTripwire.receiveReport explains why that corroboration matters.
        claimsUnauthorised = true,
    })
end

-- ---------------------------------------------------------------------------
-- The wrap primitive
-- ---------------------------------------------------------------------------
--
-- Idempotent per (holder, method): re-running this file must not stack wraps.
-- The original is always called and its return value always passed back - these
-- are constructors as often as they are openers, and swallowing a return here
-- means a panel that opens as nil.
local function wrap(holder, holderName, method, code, label, capabilityName)
    if type(holder) ~= "table" then return false end
    local orig = holder[method]
    if type(orig) ~= "function" then return false end

    local sentinel = holderName .. "." .. method
    if DFIntentWatch.wrapped[sentinel] then return false end
    DFIntentWatch.wrapped[sentinel] = orig

    holder[method] = function(...)
        -- a watch fault must never break the wrapped admin tool itself
        pcall(function()
            if lacks(capabilityName) then trip(code, label) end
        end)
        return orig(...)
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Installation
-- ---------------------------------------------------------------------------
--
-- MULTIPLAYER ONLY: in single player every one of these is legitimately open and
-- there is no server to report to.
--
-- OnGameStart, because these are Lua classes from the game's own files and the
-- load order that defines them is not ours to assume. Each wrap is independently
-- guarded, so a class that is absent (or renamed in a future build) costs that
-- one hook and nothing else - the failure mode KWRR's file-scope `return` turns
-- into a silent loss of everything below it.

-- ON BY DEFAULT, with an off switch, and this one needs it more than any other
-- file in the family: it wraps VANILLA ADMIN UI CONSTRUCTORS. If a wrap breaks,
-- the thing that breaks is the admin's own toolset - the debug menu, the item
-- editor, the power panel - and the person who needs to disarm it is the person
-- whose tools just stopped working. That has to be a sandbox toggle, never a
-- code edit.
local function armed()
    -- SandboxVars is nil until options load; the chain replaces the guard
    local v = SandboxVars and SandboxVars.RFTDCore and SandboxVars.RFTDCore.IntentWatchEnabled
    if v == nil then return true end   -- absent option = on
    return v == true
end

local function install()
    if DFIntentWatch.installed then return end
    if not isClient() then return end
    if not armed() then
        print("[RFTDCore] DFIntentWatch: disarmed by sandbox (IntentWatchEnabled=false)")
        return
    end
    DFIntentWatch.installed = true

    local n = 0
    local function w(holder, holderName, method, code, label, cap)
        if wrap(holder, holderName, method, code, label, cap) then n = n + 1 end
    end

    -- Every class, method and Capability below is verified present in 42.20:
    -- the classes in the game's own Lua, the capabilities in Capability.java.
    w(ISDebugMenu,        "ISDebugMenu",        "OnOpenPanel", "openDebugMenu",
      "debug menu",          "UseDebugContextMenu")
    w(ISAdminPowerUI,     "ISAdminPowerUI",     "new",         "openAdminPower",
      "admin power menu",    "ConnectWithDebug")
    w(ISItemsListViewer,  "ISItemsListViewer",  "OnOpenPanel", "openItemList",
      "item list viewer",    "AddItem")
    w(ISItemsListTable,   "ISItemsListTable",   "addItem",     "spawnItem",
      "item spawn",          "AddItem")
    w(ISItemEditorUI,     "ISItemEditorUI",     "new",         "openItemEditor",
      "item editor",         "EditItem")
    w(ISPlayerStatsUI,    "ISPlayerStatsUI",    "OnOpenPanel", "openPlayerStats",
      "player stats panel",  "CanSeePlayersStats")
    w(BrushToolManager,   "BrushToolManager",   "openPanel",   "openBrushTool",
      "brush tool manager",  "UseBrushToolManager")
    w(ClimateControlDebug,"ClimateControlDebug","OnOpenPanel", "openClimate",
      "climate control",     "ClimateManager")

    print("[RFTDCore] DFIntentWatch: " .. tostring(n)
        .. " staff-only surfaces instrumented (records intent, never blocks)")
end

-- install touches vanilla admin-UI constructor tables that may be absent or
-- reshaped on some builds. No guard: Event.trigger isolates listeners
-- (Event.java:53-63), so a failed install already costs the watch, not the boot.
Events.OnGameStart.Add(function() install() end)

return DFIntentWatch

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
