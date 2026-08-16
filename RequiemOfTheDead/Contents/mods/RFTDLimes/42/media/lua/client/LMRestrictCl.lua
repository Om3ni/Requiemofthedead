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

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= "RFTDLimes" or command ~= "restricted" then return end
    if type(args) ~= "table" then return end
    -- No guard: OnServerCommand is shared with every other mod's handler, but
    -- Event.trigger already gives each listener its own protectedCallVoid and
    -- try/catch (Event.java:53-63), so a throw here cannot cost them their turn.
    LMRestrictCl.explain(args.flag, args.zone)
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

    local no, zone = denied(x, y, "noplayers")
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
