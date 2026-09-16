-- SPDX-License-Identifier: GPL-3.0-or-later
-- LMRestrictCl.lua - the client half of the restriction flags.
--
-- TWO JOBS, AND THEY ARE NOT THE SAME JOB.
--
--   1. Say why something was refused. LMRestrictSv vetoes server-side, and a
--      veto nobody explains is indistinguishable from a broken server: the
--      player repeats the action, it fails again, and they file a bug. This end
--      turns the refusal into a sentence naming the zone and the rule.
--
--   2. BE the enforcement, for the two flags where nothing else can be.
--      `nodestruction` and `noplayers` have no server veto in 42.20.2 - that is
--      verified, not assumed (see LMRestrictSv's header and §7.2). For those,
--      an honest client complying is the whole mechanism. A hacked client is
--      not stopped; the server logs what got through.
--
-- WHY THERE IS NO CLIENT GATE FOR THE VETOED FLAGS. Hiding the build option
-- inside a nobuilding zone would be nicer UX, and it is deliberately not here
-- yet: the server already refuses, so a missing gate costs a wasted click and a
-- message, while a gate that disagrees with the server - because this client's
-- store is a revision behind - costs a player who cannot build somewhere they
-- are allowed to. The safe half first. The gates are additive later.
--
-- DELETE THIS FILE and the S and R flags are unaffected; only the explanation
-- and the two cooperative flags go away.

if isServer() then return end

require "LMCore"
require "LMRestrictShared"

LMRestrictCl = LMRestrictCl or {}

-- Shared with LMRestrictSv - a restriction whose two halves can disagree is
-- worse than none. See shared/LMRestrictShared.lua.
local denied = LMRestrictShared.denied
-- The area form, for the one flag whose subject is a rectangle. The server
-- reverts a claim using this exact test; refusing one with a different test
-- would be the disagreement the shared file exists to prevent.
local rectDenied = LMRestrictShared.rectDenied

-- No guard: getSpecificPlayer (LuaManager:3617) is `IsoPlayer.players[player]`,
-- and index 0 is always in bounds of that four-slot static array.
local function me()
    return getSpecificPlayer(0)
end

-- ---------------------------------------------------------------------------
-- 1. The explanation
-- ---------------------------------------------------------------------------

-- Named for the player, not for the code. "nobuilding" is a field name; what
-- the player needs is a sentence about this place.
local SAYS = {
    nobuilding    = "You cannot build in %s.",
    nopickup      = "Nothing can be picked up in %s.",
    noplacing     = "Nothing can be put down in %s.",
    noscrap       = "Nothing can be dismantled in %s.",
    nofire        = "Fires cannot be lit in %s.",
    nosafehouse   = "%s cannot be claimed as a safehouse.",
    nodestruction = "Nothing can be destroyed in %s.",
    noplayers     = "%s is closed.",
}

function LMRestrictCl.explain(flag, zone)
    local shape = SAYS[flag] or "That is not allowed in %s."
    local msg = string.format(shape, tostring(zone or "this area"))
    -- pcall: DFFeedback belongs to Dragonfly - a foreign callback whose body is
    -- not ours to verify, and a toast must never break the refusal it explains.
    if DFFeedback and DFFeedback.bad then pcall(DFFeedback.bad, msg) end
    return msg
end

-- ---------------------------------------------------------------------------
-- The reverted claim, dropped from THIS client's list.
--
-- The server has already removed it from its own; SafeHouse.removeSafeHouse
-- notifies nobody (SafeHouse.java:297-303) and server Lua cannot reach the
-- packet that would - see LMRestrictSv's note beside dropOnClients. So the
-- server names the row and every client drops its own copy here, where
-- GameClient.client IS true and the very same call also fires
-- OnSafehousesChanged, refreshing the vanilla safehouse UI for free.
--
-- CACHE INVALIDATION, NOT AUTHORITY. The claim is already gone server-side;
-- refusing to act on this message gains a cheating client nothing but a stale
-- list of its own. A client that never had the row resolves nil and stops.
-- ---------------------------------------------------------------------------

local function safehouseGone(id)
    id = tonumber(id)
    if not id then return end
    -- One number binds the (int onlineID) overload and nothing else: the
    -- IsoGridSquare and String overloads reject a Double outright, the 4-arg
    -- one fails on arity (LuaJavaInvoker.java:247, :272-290). The id is
    -- derived from the rectangle's coordinates (SafeHouse.java:519), so the
    -- server's id resolves against our own list.
    local sh = SafeHouse.getSafeHouse(id)
    if not sh then return end
    SafeHouse.removeSafeHouse(sh)
end

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= "RFTDLimes" then return end
    if type(args) ~= "table" then return end
    -- No guard: OnServerCommand is shared with every other mod's handler, but
    -- Event.trigger already gives each listener its own protectedCallVoid and
    -- try/catch (Event.java:53-63), so a throw here cannot cost them their turn.
    if command == "restricted" then
        LMRestrictCl.explain(args.flag, args.zone)
    elseif command == "safehouseGone" then
        safehouseGone(args.id)
    end
end)

-- ---------------------------------------------------------------------------
-- 2a. nodestruction - C
--
-- ISDestroyStuffAction:isValid() is shared Lua and carries the target object,
-- so the gate goes there rather than on the context menu. Menu gating means
-- matching translated option strings, which breaks in every language but ours;
-- this refuses the action itself however it was started, including from a
-- keybind or another mod's menu.
--
-- The action's own square, never the player's: a player standing outside the
-- boundary sledging through it is exactly what the boundary is for.
-- ---------------------------------------------------------------------------

local wrapped = {}

local function wrapDestroy()
    if wrapped.destroy or type(ISDestroyStuffAction) ~= "table"
        or type(ISDestroyStuffAction.isValid) ~= "function" then
        return false
    end
    local original = ISDestroyStuffAction.isValid
    ISDestroyStuffAction.isValid = function(self)
        -- self.item is the action's target object, and getSquare is a field
        -- return on every class that carries it (IsoObject:1126,
        -- IsoMovingObject:534); IsoGridSquare.getX/getY are too (:6331/:6335).
        -- Tested rather than assumed, because the target is the action's to
        -- choose - indexing an absent method is safe, calling one is not.
        local x, y
        local sq = self.item and self.item.getSquare and self.item:getSquare()
        if sq then x, y = sq:getX(), sq:getY() end
        if x then
            local no, zone = denied(x, y, "nodestruction")
            if no then
                -- Explained here rather than left silent: isValid returning
                -- false just makes the action never start, which reads as the
                -- sledgehammer not working.
                LMRestrictCl.explain("nodestruction", zone)
                return false
            end
        end
        return original(self)
    end
    wrapped.destroy = true
    return true
end

-- ---------------------------------------------------------------------------
-- 2c. nosafehouse - C in front of the server's R
--
-- The claim has no pre-claim hook anywhere: SafehouseClaimPacket.processServer
-- goes straight to SafeHouse.canBeSafehouse and adds the row, with no event and
-- no veto point in between. The server's revert stays the authority and a
-- modified client changes nothing about it. This is the honest half - refuse
-- before the packet is sent, so a player who cannot claim here is told so
-- instead of watching a claim appear and then vanish a game minute later.
--
-- WRAPPED ON THE GLOBAL, not on the context menu, for the reason nodestruction
-- gives above: it refuses the claim however it was started, including from a
-- keybind or another mod's menu. Vanilla's only caller is
-- ISWorldObjectContextMenu.onTakeSafeHouse:517.
--
-- THE RECT IS THE BUILDING'S, NOT THE CLICKED SQUARE'S. addSafeHouse derives
-- the claim from the building def and pads it by two on every side
-- (SafeHouse.java:89-91), so testing the square under the cursor would refuse
-- a different rectangle than the server later reverts - a player could be
-- refused standing on protected ground for a building entirely outside the
-- zone, or claim a building whose protected half they never clicked.
-- ---------------------------------------------------------------------------

local function claimRect(square)
    -- Tested rather than assumed: the square is the caller's to choose, and
    -- indexing an absent method is safe where calling one is not.
    local building = square and square.getBuilding and square:getBuilding()
    if not building then return nil end
    -- getDef is a METHOD (IsoBuilding.java:119). The `def` field beside it
    -- (:55) is a Java field and reading it from Lua answers nil - Kahlua
    -- exposes methods only.
    local def = building.getDef and building:getDef()
    if not def then return nil end
    return def:getX() - 2, def:getY() - 2, def:getW() + 4, def:getH() + 4
end

local function wrapClaim()
    if wrapped.claim or type(sendSafehouseClaim) ~= "function" then return false end
    local original = sendSafehouseClaim
    sendSafehouseClaim = function(square, player, title)
        local x, y, w, h = claimRect(square)
        -- No building means no claim the engine would accept either
        -- (SafehouseClaimPacket.isConsistent:65-68), and no rectangle for us
        -- to test. Let it through to the refusal that already exists.
        if x then
            local no, zone = rectDenied(x, y, w, h, "nosafehouse")
            if no then
                LMRestrictCl.explain("nosafehouse", zone)
                return
            end
        end
        return original(square, player, title)
    end
    wrapped.claim = true
    return true
end

-- ---------------------------------------------------------------------------
-- 2b. noplayers - C
--
-- Movement is client-authoritative and there is no engine concept of forbidden
-- presence except safehouse trespass, whose bounce is not reachable from Lua
-- (GameServer is not exposed). So the client turns itself back.
--
-- IT PUTS YOU WHERE YOU CAME FROM, not at the boundary. Snapping to the nearest
-- edge of a rectangle is how a player ends up inside a wall, or on the far side
-- of the zone when they clipped a corner. The last position known to be outside
-- is a place they were legitimately standing one moment ago.
-- ---------------------------------------------------------------------------

local lastGood = nil    -- {x, y} last confirmed outside every noplayers zone
local lastSaid = 0

local function bounce()
    local p = me()
    if not p then return end
    -- No guard: getX/getY are field returns on IsoMovingObject and p is the
    -- local player, checked non-nil above.
    local x, y = p:getX(), p:getY()

    -- deniedFor, not denied: the zone's noplayersPass list can clear THIS
    -- player (their role name or a role capability), and a cleared player's
    -- position inside the zone is a legitimate place to stand - it feeds
    -- lastGood like anywhere else.
    local no, zone = LMRestrictShared.deniedFor(p, x, y, "noplayers")
    if not no then
        lastGood = { x, y }
        return
    end

    -- Nowhere known to send them - they logged in inside the zone, or it was
    -- drawn around them. Say so and let them walk out rather than teleporting
    -- them somewhere arbitrary, which could be worse than where they are.
    if not lastGood then
        local now = getTimestampMs and getTimestampMs() or 0
        if now - lastSaid > 5000 then
            lastSaid = now
            LMRestrictCl.explain("noplayers", zone)
        end
        return
    end

    -- setX/setY update both the current and next coordinates
    -- (IsoMovingObject.java:478-498). setLx/setLy are not engine methods and
    -- previously made this throw after updating X but before updating Y.
    p:setX(lastGood[1])
    p:setY(lastGood[2])
    local now = getTimestampMs and getTimestampMs() or 0
    if now - lastSaid > 3000 then
        lastSaid = now
        LMRestrictCl.explain("noplayers", zone)
    end
end

-- ---------------------------------------------------------------------------
-- Install
-- ---------------------------------------------------------------------------

wrapDestroy()
Events.OnGameStart.Add(function() wrapDestroy() end)

-- wrapClaim is OnGameStart ONLY, and never at file scope, because it has to be
-- the OUTER wrapper on sendSafehouseClaim. Core's DFSendWatch wraps the same
-- global to ledger it, and defers that to OnGameStart (DFSendWatch.lua:258).
-- Wrapping here at file scope would put us underneath it, and Core would then
-- report every refused claim as one that was made - a forensic record of an
-- event that never happened. Registered on the same event instead, we land
-- outside: listeners run in registration order, registration follows the
-- client's alphabetical walk, and DFSendWatch.lua sorts before LMRestrictCl.lua.
--
-- Nothing needs the gate before the game is up; there is no claim to refuse.
Events.OnGameStart.Add(function() wrapClaim() end)

-- OnPlayerUpdate is per player per tick, which is the cadence a bounce needs:
-- checked once a second, a sprinting player is most of the way across a small
-- zone before anything notices.
Events.OnPlayerUpdate.Add(function(player)
    if player and player == me() then bounce() end
end)

return LMRestrictCl

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
