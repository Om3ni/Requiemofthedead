-- SPDX-License-Identifier: GPL-3.0-or-later
-- RCDismantleAction - the dismantle timed action (DESIGN §1). Shared, like
-- its vanilla base class.
--
-- Derives ISRemoveBurntVehicle and inherits the BlowTorch requirement,
-- animation/sound, and skill-scaled duration. RCDismantleYield mirrors the
-- vanilla scrap table and downgrade rates on the authoritative side.
-- complete() is OUR OWN, not vanilla's (the Nep lesson, DESIGN §References):
-- modded (KI5) part
-- layouts throw inside unguarded vanilla teardown steps and abort before
-- removal. In multiplayer the engine reconstructs this action, calculates its
-- duration, and calls complete() on the server; that completion consumes the
-- one-use permit and owns every mutation. Single-player commits the same shared
-- yield locally.

require "Vehicles/TimedActions/ISRemoveBurntVehicle"
require "RCDismantleRules"
require "RCDismantleYield"

RCDismantleAction = ISRemoveBurntVehicle:derive("RCDismantleAction")

-- Backstop only - the menus gate at click time (claim -> zone -> engine ->
-- tools). This re-checks just the claim (cheap modData reads, no allocation)
-- so a car claimed mid-action stops the teardown.
function RCDismantleAction:isValid()
    if not ISRemoveBurntVehicle.isValid(self) then return false end
    if RCShared.claimDismantleBlock(self.vehicle, self.character) then return false end
    return true
end

-- Admin-tunable teardown time. The base stays skill-scaled; 100 = vanilla.
function RCDismantleAction:getDuration()
    local base = ISRemoveBurntVehicle.getDuration(self)
    local pct = RCShared.cfg().dismantleTimePct
    if pct == 100 or base <= 10 then return base end
    return math.max(10, math.floor(base * pct / 100))
end

function RCDismantleAction:complete()
    local v = self.vehicle
    if not v then return false end

    if isServer() then
        -- LuaTimedActionNew.complete skips Lua completion on GameClient and
        -- NetTimedAction.perform invokes it here after the server-owned duration
        -- (LuaTimedActionNew.java:150-160; NetTimedAction.java:127-135).
        return RCDismantleAuthority.finish(self.character, self.rcPermit, v)
    end

    -- The MP client never enters Lua complete(); its ActionManager waits for
    -- Done/Reject from the server. Keep this branch mutation-free if invoked by
    -- a test or a future engine path.
    if isClient() then return true end

    -- Single-player has no RCServer command loop. Commit through the same yield
    -- implementation used by the dedicated server, but against the local world.
    local torch = RCDismantleRules.primaryTorch(self.character)
    if not torch then return false end
    local eternal = RCEternalTorch and RCEternalTorch.active(self.character)
    local removed, result = RCDismantleYield.commit(v, self.character, torch, eternal)
    if not removed then
        RCShared.dbg("dismantle: vehicle removal failed at %s (%s)",
            tostring(result and result.phase), tostring(result and result.error))
        return false
    end
    return true
end

-- via: "field" (player, gated) or "panel" (admin tab, gates bypassed).
function RCDismantleAction:new(character, vehicle, via, permit)
    local o = ISRemoveBurntVehicle.new(self, character, vehicle)
    -- NetTimedAction.set serializes constructor arguments by their debug local
    -- names and reads matching fields from the action table
    -- (NetTimedAction.java:58-101). Keep those exact fields even though the
    -- prefixed aliases make their ownership clearer elsewhere in this module.
    o.via = via or "field"
    o.permit = permit
    o.rcVia = o.via
    o.rcPermit = o.permit
    return o
end

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
