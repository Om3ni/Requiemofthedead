-- SPDX-License-Identifier: GPL-3.0-or-later
-- =============================================
-- RQPoise.lua - tanks power through stagger instead of being stunlocked.
--
-- THE PROBLEM, measured 2026-08-24: a .45 kept a Boss staggered for an entire
-- encounter. Anything with a fast cycle does it - SMGs, shotguns, a fast melee
-- swing - because each hit re-triggers the stagger before the last one ends.
--
-- WHY BULWARK CANNOT FIX THIS, and why raising its soak rates would have been
-- wasted work. The flinch is not part of the damage path. CombatManager
-- resolves each hit into a reaction on the ATTACKING side, and Bulwark's soak
-- exits at IsoGameCharacter.java:5711 - before hitConsequences ever runs - so
-- server-side a soaked hit produces no reaction at all. The client reacts
-- regardless. A fully soaked hit still flinches.
--
-- WHY NOT JUST SHORTEN THE STAGGER. StaggerBackState.getMaxStaggerTime is
-- `35 * hitForce * staggerTimeMod` CLAMPED TO [20, 30] (:58-64), so a
-- staggerTimeMod of zero still yields 20. Duration was never the lever, and in
-- any case gunfire does not use that state - see isReacting() below.
--
-- HOW THE FLINCH IS ACTUALLY DEFEATED: not by refusing it, which we cannot do
-- from Lua, but by making it cost nothing. RQFlinch owns that mechanism and
-- explains it; this file owns only the policy of when to ask for it.
--
-- THE MODEL: poise. A tank absorbs a rolled number of staggers, then becomes
-- immune for a rolled window. Bounded by construction rather than statistically
-- - a flat resistance percentage can still lose to a thirty-round magazine.
-- Both numbers are randomised per cycle (owner decision 2026-08-24) so the
-- break point is not something a player can count off.
--
-- WHY THIS IS CLIENT-SIDE while the rest of the mitigation family is not.
-- The reaction is entered by the animation graph on the machine simulating the
-- zombie, and that is the owning client for anything a player is shooting -
-- the hit probe recorded owner=client on 90 of 90 hits. There is nothing for
-- the server to do. Bulwark therefore owns a server-side soak and this file
-- owns a client-side poise rule; that split is real and is stated rather than
-- hidden.
--
-- ADDING A TYPE is one row in PROFILES below. The mechanism is type-agnostic,
-- so extending poise to another zombie is a data change, not a code change.
-- Boss is the one to watch first: it is the type the stunlock was reported on.
-- =============================================

-- No isServer guard: media/lua/client is client-only, and no other file in this
-- directory carries one. The per-zombie owner gate lives in update().

require "RQCommon"
require "RQDirgeLog"
require "RQFlinch"
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
    suppressed = 0,  -- update passes spent inside an immunity window
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
        -- Mirrors what RQFlinch has been told, so the variable is written only
        -- on transitions rather than every frame.
        suppressed   = false,
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

-- Suppression is RQFlinch's job now; this file only decides WHEN.
--
-- WHAT WAS REMOVED HERE, so nobody rebuilds it. This used to clear
-- staggerBack, knockedDown and the hit reaction string, and zero the state
-- event timer. All four were verified inert against gunfire on Mosaic
-- (2026-08-24): the flags are read by the graph, but the transition fires
-- between the hit and our next OnZombieUpdate, so we were always one frame
-- late and the animation already owned the zombie. Poise logged its breaks
-- correctly while the Boss kept flinching. Clearing a flag after the state has
-- been entered achieves nothing, and leaving those calls in as decoration
-- would have been four engine calls per frame per tank doing exactly that.
--
-- RQFlinch wins instead by changing what the reaction COSTS - see its header.
local function suppress(zombie, on)
    RQFlinch.set(zombie, on)
end

-- "Has this zombie just been rocked?" - and it is TWO states, not one.
--
-- CORRECTED 2026-08-24, after the first version of this file shipped watching
-- only isStaggerBack() and did nothing at all against a .45. CombatManager
-- resolves every hit into ONE of two mutually exclusive outcomes (:2410-2417):
--
--     if (hitReaction != HitReaction.NONE) target.setHitReaction(value);
--     else                                 zombie.setStaggerBack(true);
--
-- A bullet resolves to a real directional HitReaction, so it takes the FIRST
-- branch and staggerBack is never set. Poise was polling a flag that gunfire
-- does not touch, which is exactly why it counted nothing and logged nothing.
-- `hitreaction` is bound live to getHitReaction/setHitReaction as an animation
-- variable (IsoGameCharacter.java:833), so the graph reads what we read and
-- clearing it is how the state is refused.
local function isReacting(zombie)
    if zombie:isStaggerBack() then return true end
    local reaction = zombie:getHitReaction()
    return reaction ~= nil and reaction ~= ""
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
        -- outlive a reload) must not keep a stale cycle around - NOR a stale
        -- suppression. Only touched when we actually have a row, so an ordinary
        -- zombie never costs an engine call here.
        if poise[zombie] then
            suppress(zombie, false)
            poise[zombie] = nil
        end
        return
    end

    local st = poise[zombie]
    if not st then
        st = freshCycle(profile)
        poise[zombie] = st
    end

    if now < st.immuneUntil then
        RQPoise.stats.suppressed = RQPoise.stats.suppressed + 1
        -- EDGE-WRITTEN, not written every frame. Unlike the flag-clearing this
        -- replaced, the variable LATCHES - it stays true until we clear it - so
        -- re-asserting it each pass would be pure waste, and forgetting to
        -- clear it would leave the tank permanently unflinchable.
        if not st.suppressed then
            suppress(zombie, true)
            st.suppressed = true
        end
        st.wasStaggered = false
        return
    end

    -- Out of the window: hand the flinch back. This is the half a one-shot
    -- clear never needed and a latching variable absolutely does.
    if st.suppressed then
        suppress(zombie, false)
        st.suppressed = false
    end

    -- EDGE-TRIGGERED. Both reaction states persist for their whole animation,
    -- so counting every frame would burn a full cycle on one bullet. Only the
    -- rising edge is a new hit.
    local staggered = isReacting(zombie)
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
            suppress(zombie, true)
            st.suppressed = true
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
