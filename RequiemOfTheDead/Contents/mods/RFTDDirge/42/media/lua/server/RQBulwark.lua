-- SPDX-License-Identifier: GPL-3.0-or-later
-- =============================================
-- RQBulwark.lua - does this incoming hit penetrate this zombie?
--
-- That is the whole responsibility. Bulwark does not mutate weapons, heal
-- damage, acquire targets, change movement, or own Boss phase behaviour.
--
-- THE MECHANISM, and its honest cost. A soak calls setAvoidDamage(true) on the
-- struck zombie from inside the pre-damage lane. IsoGameCharacter.Hit checks the
-- flag at :5710-5713, clears it, and returns 0.0f - so it cancels exactly ONE
-- hit and re-arms nothing. That early return sits AHEAD of calculateHitDirection,
-- setAttackedBy, addWorldSoundUnlessInvisible and hitConsequences, which means a
-- soak is a DEFLECTION, not armour: the hit's stagger, knockback, blood and
-- death consequences all go with the damage. A player will read it as the blow
-- glancing off, and that is the intended feel, but it is worth being clear that
-- there is no "reduced damage" option available here. The engine offers cancel
-- or don't-cancel.
--
-- WHY NOT PARTIAL DAMAGE. OnWeaponHitCharacter exposes only the pre-modifier
-- damageSplit; critical, weapon-skill, one-handed and global modifiers are all
-- applied afterwards inside processHitDamage. Cancelling a hit and reapplying
-- "40% of it" from Lua would be reapplying a percentage of a number that is not
-- the damage. The all-or-nothing roll is a consequence of what the engine will
-- actually tell us, not a simplification.
--
-- WHY IT IS SERVER-SIDE AND WHAT THAT BUYS. The shipped mitigation model nerfs
-- the attacking client's own weapon fields so the client sends a smaller number
-- (RQSuppress). It works, and it is client-trusted by construction. This decides
-- the outcome on the server instead. See RQSvHit's header for the bRemote
-- reading that makes the distinction real.
--
-- SELF-PROTECTION ONLY in this slice. Aura protection - ordinary zombies
-- standing inside a living special's radius - is Slice 5 and is deliberately
-- absent rather than stubbed.
-- =============================================

if not isServer() then return end

require "RQCommon"
require "RQDirgeLog"
require "RQSvShared"
require "RQSvScavenger"

RQBulwark = RQBulwark or {}

-- ---------------------------------------------------------------------------
-- Policy
-- ---------------------------------------------------------------------------
-- Percentages, ranged and melee, per protected type. Ranged is roughly double
-- melee throughout because the problem these numbers exist to solve is the
-- kiting one: a player outside melee reach takes no risk in return, so the
-- exchange rate has to come from somewhere. Standing next to a Juggernaut and
-- hitting it is already a decision with a cost.
--
-- CODE-OWNED FOR NOW. These are the accepted starting values for runtime
-- testing, not final balance, and the sandbox surface that eventually exposes
-- them is a Slice 6 decision made together with the migration of the options
-- the old aura model left behind. Adding four dials here and four more there
-- would be two surfaces to reconcile later.
local SELF_SOAK = {
    Boss       = { ranged = 70, melee = 35 },
    Juggernaut = { ranged = 60, melee = 30 },
    Scavenger  = { ranged = 50, melee = 25 },   -- ENRAGED only; see rateFor
}

RQBulwark.SELF_SOAK = SELF_SOAK

-- ---------------------------------------------------------------------------
-- Counters
-- ---------------------------------------------------------------------------
RQBulwark.stats = {
    evaluated  = 0,
    soaked     = 0,
    penetrated = 0,
    ranged     = 0,
    melee      = 0,
    byType     = {},   -- zType -> { soaked, penetrated }
    refused    = {},   -- reason -> count
}

local function refuse(reason)
    local r = RQBulwark.stats.refused
    r[reason] = (r[reason] or 0) + 1
    return nil
end

-- ---------------------------------------------------------------------------
-- rateFor - PURE
-- ---------------------------------------------------------------------------
-- Returns the soak percentage for this target and weapon class, or nil with a
-- named reason when nothing protects it. Takes `enraged` as a parameter rather
-- than reading Scavenger state itself, so the policy can be exercised without
-- any of the engine or module state behind it.
function RQBulwark.rateFor(zType, isRanged, enraged)
    local row = SELF_SOAK[zType]
    if not row then return nil, "not-protected-type" end
    -- A passive Scavenger is a scavenger: it is eating, it is not a threat, and
    -- it is not armoured. Rage is what makes it one, and rage is something the
    -- player caused.
    if zType == "Scavenger" and not enraged then return nil, "scavenger-passive" end
    return (isRanged and row.ranged or row.melee), nil
end

-- ---------------------------------------------------------------------------
-- decide - PURE
-- ---------------------------------------------------------------------------
-- Takes the roll rather than making one. This is the seam the fixtures use to
-- pin the boundaries exactly, and it is a parameter rather than a swappable
-- global on purpose: production randomness stays un-replaceable, so nothing can
-- reach in at runtime and make every Boss invulnerable.
--
-- `roll` is 0..99. Soak when roll < rate, which puts rate=0 at never (no roll
-- is below zero) and rate=100 at always (every roll is below 100).
function RQBulwark.decide(zType, isRanged, enraged, roll)
    local rate, why = RQBulwark.rateFor(zType, isRanged, enraged)
    if not rate then return false, why end
    return roll < rate, nil
end

-- ---------------------------------------------------------------------------
-- resolve - the impure edge
-- ---------------------------------------------------------------------------
-- Called LAST by RQSvHit, after rage, McCoy and Bloodhound, so that a successful
-- soak cannot suppress any of them. A soaked hit is still an attack.
function RQBulwark.resolve(ctx)
    local zType = ctx.zType
    if not SELF_SOAK[zType] then return refuse("not-protected-type") end

    local enraged = (zType == "Scavenger") and RQSvScavenger.isEnraged(ctx.zombie) or false
    local rate, why = RQBulwark.rateFor(zType, ctx.isRanged, enraged)
    if not rate then return refuse(why) end

    local st = RQBulwark.stats
    st.evaluated = st.evaluated + 1
    if ctx.isRanged then st.ranged = st.ranged + 1 else st.melee = st.melee + 1 end

    local soaked = RQBulwark.decide(zType, ctx.isRanged, enraged, ZombRand(100))

    local row = st.byType[zType]
    if not row then row = { soaked = 0, penetrated = 0 }; st.byType[zType] = row end

    if soaked then
        -- The one mutation this file makes. Not guarded: setAvoidDamage is a
        -- plain setter on IsoGameCharacter (:10918), and IsoGameCharacter is
        -- setExposed at LuaManager.java:1770, so it is reachable for the same
        -- reason setHealth is. If that turns out to be wrong it must fail
        -- loudly on the first hit of the first test rather than soak silently
        -- into a pcall and leave us reading counters that say it worked.
        ctx.zombie:setAvoidDamage(true)
        st.soaked = st.soaked + 1
        row.soaked = row.soaked + 1
    else
        st.penetrated = st.penetrated + 1
        row.penetrated = row.penetrated + 1
    end

    if RQSvShared.getSvConfig().debugMode then
        RQDirgeLog.write("Bulwark", "[INFO] " .. zType
            .. (ctx.isRanged and " ranged" or " melee")
            .. " rate=" .. rate
            .. (soaked and " SOAKED" or " penetrated")
            .. " hp=" .. string.format("%.2f", ctx.zombie:getHealth()))
    end
    return soaked
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
