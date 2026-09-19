-- SPDX-License-Identifier: GPL-3.0-or-later

-- RQMuster - the escort turns on whoever struck its protector.
--
-- The client half of RQSvMuster. The server says which special was hit, by
-- whom, and how wide its aura is; this client walks the squares inside that
-- aura and gives a forced spot to every ordinary zombie there THAT IT
-- SIMULATES. Zombie AI runs on the owning client, so a perception call
-- sticks only there - spottedNew returns before setting any target on a
-- remote zombie (IsoZombie.java:1671-1685) - and client-side
-- isRemoteZombie() true means someone else simulates it
-- (NetworkZombieSimulator.java:124-142; CLAUDE.md sect. 4 - the name reads
-- truthfully on this side only, which is why this file is client-only).
--
-- =============================================
-- WHAT A FORCED SPOT DOES, AND DELIBERATELY DOES NOT
-- =============================================
-- spotted(other, true) makes the perception roll unlosable
-- (IsoZombie.java:1793-1795), sets the target (:1892) and paths to the
-- attacker's current position (:1938), so the escort turns and comes. It
-- does NOT reset the flesh timer (:1898-1902), so an escort that cannot see
-- the attacker drops the target on its next memory tick (:2815-2817) while
-- the path it was given keeps running. Decided in the Bulwark lab (FINDINGS
-- F32, 2026-09-16): that is enough. Every further hit re-issues it
-- (RQSvMuster's cadence), and once the escort can see the player its own
-- unforced spots hold the target exactly as vanilla does. No setTarget - it
-- holds only within flesh memory and adds nothing to the path a forced spot
-- already issued. No addAggro - inert on a client, nothing on this side
-- reads the list. No sprint - the escort walks as it always did.
--
-- Specials are never commanded: a Screamer standing in a Juggernaut's aura
-- keeps its own behaviour, and the protector itself is not its own escort.

require "RQAura"
require "RQRegistry"
require "RQDirgeLog"

RQMuster = RQMuster or {}

-- Ceiling on the scan, in tiles. The radius on the wire is the server's
-- JuggernautBuffRadius, an enum whose largest value is 20
-- (RQCommon.lua:74); anything above that is a malformed payload, and the
-- scan is (2r+1)^2 squares, so it is bounded here rather than trusted.
RQMuster.MAX_RADIUS = 20

RQMuster.stats = { musters = 0, commanded = 0, noAttacker = 0 }

-- The per-zombie policy for RQAura.eachEscort: only a zombie this client
-- simulates, and never a special. Inputs set per muster.
local musterAttacker  = nil
local musterCommanded = 0
local function commandEscort(obj)
    if not obj:isRemoteZombie() and not RQRegistry.isSpecial(obj:getOnlineID()) then
        obj:spotted(musterAttacker, true)   -- IsoZombie.java:2321 -> spottedNew :1660
        musterCommanded = musterCommanded + 1
    end
end

-- Command every owned ordinary zombie within `radius` of `special` to spot
-- the player `attackerID`. Returns how many were commanded.
function RQMuster.muster(special, attackerID, radius)
    -- The client's own id map (LuaManager.java:3453-3462). A player this
    -- client has not loaded is nobody its escorts could path to anyway.
    local attacker = getPlayerByOnlineID(attackerID)
    if not attacker then
        RQMuster.stats.noAttacker = RQMuster.stats.noAttacker + 1
        return 0
    end
    local cell = getCell()
    if not cell then return 0 end

    radius = math.floor(radius)
    if radius > RQMuster.MAX_RADIUS then radius = RQMuster.MAX_RADIUS end

    -- The same walk the escort paint makes (RQJuggernaut, RQBoss), on the
    -- special's own floor: RQAura's, with commandEscort above as the policy.
    musterAttacker, musterCommanded = attacker, 0
    RQAura.eachEscort(cell, special, radius, commandEscort)
    local commanded = musterCommanded
    musterAttacker = nil

    RQMuster.stats.musters   = RQMuster.stats.musters + 1
    RQMuster.stats.commanded = RQMuster.stats.commanded + commanded
    RQDirgeLog.write(RQRegistry.getType(special:getOnlineID()) or "Muster",
        "[INFO] muster id=" .. tostring(special:getOnlineID())
        .. " attacker=" .. tostring(attackerID)
        .. " radius=" .. tostring(radius)
        .. " commanded=" .. commanded)
    return commanded
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
