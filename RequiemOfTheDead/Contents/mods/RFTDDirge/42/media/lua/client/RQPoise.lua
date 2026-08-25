-- SPDX-License-Identifier: GPL-3.0-or-later
-- =============================================
-- RQPoise.lua - tanks power through stagger instead of being stunlocked.
--
-- THE PROBLEM, measured 2026-08-24: a .45 kept a Boss staggered for an entire
-- encounter. Anything with a fast cycle does it - SMGs, shotguns, a fast melee
-- swing - because each hit re-triggers the stagger before the last one ends.
--
-- WHY BULWARK CANNOT FIX THIS, and why raising its soak rates would have been
-- wasted work. Stagger is not part of the damage path. The ATTACKING client
-- decides it and ships it in the hit packet's zombieFlags (bit 1), and
-- `zombie/network/fields/hit/Zombie.java:63-73` applies those flags in BOTH
-- preProcess() and postProcess() - on either side of the server's own damage
-- processing. Bulwark's soak exits at IsoGameCharacter.java:5711, before
-- hitConsequences ever runs, so server-side a soaked hit really does produce no
-- stagger; the flag simply arrives from the packet anyway. A fully soaked hit
-- still staggers.
--
-- WHY NOT JUST SHORTEN IT. StaggerBackState.getMaxStaggerTime is
-- `35 * hitForce * staggerTimeMod` CLAMPED TO [20, 30] (:58-64). A
-- staggerTimeMod of zero still yields 20. Duration was never the lever -
-- FREQUENCY is, so the fix has to stop the state being entered at all.
--
-- THE MODEL: poise. A tank absorbs a rolled number of staggers, then becomes
-- immune for a rolled window. Bounded by construction rather than statistically
-- - a flat resistance percentage can still lose to a thirty-round magazine.
-- Both numbers are randomised per cycle (owner decision 2026-08-24) so the
-- break point is not something a player can count off.
--
-- WHY THIS IS CLIENT-SIDE while the rest of the mitigation family is not.
-- Stagger is entered by the animation graph on the machine simulating the
-- zombie, and that is the owning client for anything a player is shooting -
-- the hit probe recorded owner=client on 90 of 90 hits. There is nothing for
-- the server to clear. Bulwark therefore owns a server-side soak and this file
-- owns a client-side poise rule; that split is real and is stated rather than
-- hidden.
-- =============================================

-- No isServer guard: media/lua/client is client-only, and no other file in this
-- directory carries one. The per-zombie owner gate lives in update().

require "RQCommon"
require "RQDirgeLog"
require "RQRegistry"
require "RQReconcile"

RQPoise = RQPoise or {}

-- hits: how many staggers land before the tank powers through, rolled per
-- cycle. ms: how long the immunity then lasts, also rolled per cycle.
-- Screamers, EMPs, Gluttons and passive Scavengers are absent on purpose -
-- they are not tanks and being staggerable is most of what makes them fragile.
local PROFILES = {
    Boss       = { hitsMin = 1, hitsMax = 3, msMin = 5000, msMax = 7000 },
    Juggernaut = { hitsMin = 2, hitsMax = 5, msMin = 3000, msMax = 5000 },
    Scavenger  = { hitsMin = 2, hitsMax = 5, msMin = 3000, msMax = 5000 },
}
RQPoise.PROFILES = PROFILES

-- Weak-keyed: poise state must never be the reason a dead zombie stays
-- reachable. Same rule as RQBloodhound's pursuit table.
local poise = setmetatable({}, { __mode = "k" })
RQPoise.poise = poise

RQPoise.stats = {
    absorbed  = 0,   -- staggers counted against a threshold
    broken    = 0,   -- times a tank reached its threshold and went immune
    suppressed = 0,  -- update passes where a stagger flag was cleared
    byType    = {},
}

-- ZombRand(a, b) is [a, b) - matching every other call site in this suite.
local function roll(minV, maxV)
    return ZombRand(minV, maxV + 1)
end

local function freshCycle(profile)
    return {
        staggersLeft = roll(profile.hitsMin, profile.hitsMax),
        immuneUntil  = 0,
        wasStaggered = false,
    }
end

-- Which profile applies to this zombie RIGHT NOW, or nil.
--
-- A Scavenger only qualifies while ENRAGED, matching Bulwark: a passive
-- Scavenger is not a tank and takes full damage and full stagger. That is the
-- sleeper-threat design, not an oversight.
local function profileFor(onlineID)
    local zType = RQRegistry.getType(onlineID)
    if not zType then return nil end
    local profile = PROFILES[zType]
    if not profile then return nil end
    if zType == "Scavenger" then
        local state = RQReconcile.scavClientState[onlineID]
        if not (state and state.enraged) then return nil end
    end
    return profile, zType
end

-- Clear the stagger and knockdown flags for one update.
--
-- setStateEventDelayTimer is used WHEN PRESENT to end a stagger already in
-- progress - StaggerBackState.enter parks the state on that timer (:33), so
-- zeroing it retires the state on the next evaluation instead of waiting out
-- the full 20-30. It is reached by inheritance from IsoMovingObject:1960 rather
-- than declared on IsoZombie, and no vanilla Lua call site proves that
-- inherited surface, so its ABSENCE is handled rather than assumed. Clearing
-- the flags is the load-bearing part; the timer is a bonus that makes the
-- transition instant instead of merely preventing the next one.
local function suppress(zombie)
    zombie:setStaggerBack(false)
    zombie:setKnockedDown(false)
    if zombie.setStateEventDelayTimer then
        zombie:setStateEventDelayTimer(0.0)
    end
end

-- One zombie, one frame. Called from OnZombieUpdate.
function RQPoise.update(zombie, now)
    if not zombie or zombie:isDead() then return end
    -- Owner-only, the same gate RQGlutton's navigation uses. Poise has to be a
    -- single-authority decision: every client rolling its own threshold would
    -- have them break at different moments on the same zombie. Non-owning
    -- clients may briefly render a stagger the owner ignored - the flag is not
    -- carried in NetworkZombieVariables, so it does not propagate - and the
    -- owner's position updates settle it.
    if isClient() and zombie:isRemoteZombie() then return end

    local onlineID = zombie:getOnlineID()
    if not onlineID or onlineID <= 0 then return end

    local profile, zType = profileFor(onlineID)
    if not profile then
        -- A Scavenger that stops qualifying (it cannot un-enrage, but a row can
        -- outlive a reload) must not keep a stale cycle around.
        poise[zombie] = nil
        return
    end

    local st = poise[zombie]
    if not st then
        st = freshCycle(profile)
        poise[zombie] = st
    end

    if now < st.immuneUntil then
        RQPoise.stats.suppressed = RQPoise.stats.suppressed + 1
        suppress(zombie)
        st.wasStaggered = false
        return
    end

    -- EDGE-TRIGGERED. isStaggerBack() stays true for the whole 20-30 the state
    -- runs, so counting it every frame would burn a full cycle on one bullet.
    -- Only the rising edge is a new stagger.
    local staggered = zombie:isStaggerBack()
    if staggered and not st.wasStaggered then
        st.staggersLeft = st.staggersLeft - 1
        RQPoise.stats.absorbed = RQPoise.stats.absorbed + 1

        if st.staggersLeft <= 0 then
            st.immuneUntil = now + roll(profile.msMin, profile.msMax)
            st.staggersLeft = roll(profile.hitsMin, profile.hitsMax)
            RQPoise.stats.broken = RQPoise.stats.broken + 1
            RQPoise.stats.byType[zType] = (RQPoise.stats.byType[zType] or 0) + 1
            RQDirgeLog.write("Poise", "[INFO] " .. zType .. " id=" .. tostring(onlineID)
                .. " powers through for " .. tostring(st.immuneUntil - now) .. "ms"
                .. " (next break in " .. tostring(st.staggersLeft) .. " staggers)")
            suppress(zombie)
            st.wasStaggered = false
            return
        end
    end
    st.wasStaggered = staggered
end

Events.OnZombieUpdate.Add(function(zombie)
    RQPoise.update(zombie, getTimestampMs())
end)

function RQPoise.reset()
    poise = setmetatable({}, { __mode = "k" })
    RQPoise.poise = poise
    RQPoise.stats.absorbed   = 0
    RQPoise.stats.broken     = 0
    RQPoise.stats.suppressed = 0
    RQPoise.stats.byType     = {}
end

Events.OnGameStart.Add(RQPoise.reset)

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
