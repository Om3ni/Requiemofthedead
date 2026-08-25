-- SPDX-License-Identifier: GPL-3.0-or-later
-- =============================================
-- RQMcCoy.lua - bounded reactive healing for every special.
--
-- REACTIVE, NOT REGENERATIVE. An attack arms a short window; while the window
-- is open the target claws back a little health on a fixed cadence; when the
-- window lapses it stops. A special that walks away from a fight does not
-- quietly refill on the way home - it only heals while somebody is still
-- hitting it. That is deliberately the opposite of out-of-combat regeneration:
-- the pressure is meant to be on the player who commits to a kill and then
-- hesitates, not on the player who disengages.
--
-- WHY IT IS SMALL. One percent of effective maximum every two seconds, for
-- eight seconds after the last hit - about four percent per window at the
-- shipped numbers. Against Bulwark's soak rates that is a meaningful tax on a
-- slow damage race and nearly irrelevant to a committed one, which is the
-- intent. Starting larger risks a target that is mathematically unkillable by
-- some weapon classes, and that is a bug you discover from a bug report rather
-- than from a number.
--
-- THIS REPLACES the Juggernaut-only mitigation loop that used to live in
-- RQSvJuggernaut. Worth being clear that JuggernautMitigation defaults to 0, so
-- for most operators this is not a swap - it is healing where there was none.
--
-- A SOAKED HIT STILL ARMS THE WINDOW. Bulwark cancelling the damage does not
-- make the attack not have happened; the next tick simply finds nothing to
-- heal. Keeping that simple is what stops Bulwark's success from hiding an
-- attack from McCoy.
-- =============================================

if not isServer() then return end

require "RQCommon"
require "RQCeiling"
require "RQDirgeLog"
require "RQSvShared"
require "RQSvGlutton"
require "RQSvScavenger"

RQMcCoy = RQMcCoy or {}

-- ---------------------------------------------------------------------------
-- Tuning
-- ---------------------------------------------------------------------------
local WINDOW_MS   = 8000    -- how long after the last hit healing stays armed
local CADENCE_MS  = 2000    -- how often it ticks while armed
local HEAL_PCT    = 1.0     -- percent of effective maximum per tick

RQMcCoy.WINDOW_MS  = WINDOW_MS
RQMcCoy.CADENCE_MS = CADENCE_MS
RQMcCoy.HEAL_PCT   = HEAL_PCT

-- Weak-keyed for the same reason Bloodhound's table is: a healing window must
-- never be why a pooled zombie object stays reachable.
-- NOT weak-keyed, and it never was: Kahlua ignores `__mode` entirely
-- (see RDLedger's header). This table is safe for a different, real reason:
-- the expiry pass clears finished windows and the reset path clears the rest,
-- so rows leave on their own schedule rather than on the collector's.
local windows = {}
RQMcCoy.windows = windows

RQMcCoy.stats = {
    armed      = 0,
    refreshed  = 0,
    considered = 0,   -- cadence ticks that ran the ceiling maths
    writes     = 0,   -- HP commands actually sent
    healed     = 0.0, -- total HP handed back
    expired    = 0,
    skipped    = {},  -- reason -> count
    byCeiling  = {},  -- how the ceiling was established -> count
}

local function skip(reason)
    local s = RQMcCoy.stats.skipped
    s[reason] = (s[reason] or 0) + 1
    return false
end

-- ---------------------------------------------------------------------------
-- Ceiling
-- ---------------------------------------------------------------------------
-- Assembles the per-type inputs RQCeiling cannot know about, then asks it.
-- Every branch here is a type whose maximum is dynamic; the four static types
-- fall straight through to base * multiplier.
function RQMcCoy.ceilingFor(zombie, zType, cfg)
    local mult = (zType == "Juggernaut" and cfg.juggernautHealthMultiplier)
                 or RQCommon.HEALTH_MULTIPLIER[zType]
    local opts = { currentHP = zombie:getHealth() }

    if zType == "Scavenger" then
        local st = RQSvScavenger.state[zombie:getOnlineID()]
        if st and st.hostile and st.peakHP and st.peakHP > 0 then
            -- The frozen rage ceiling, which decay is already walking down.
            -- Handing this straight to RQCeiling is what keeps McCoy from
            -- healing above the current decay target and defeating the timer.
            opts.ragePeak = st.peakHP
        elseif st then
            opts.eatMult = 1.0 + (st.totalMultGain or 0)
        end
    elseif zType == "Glutton" then
        local st = RQSvGlutton.state[zombie:getOnlineID()]
        -- What it has ACTUALLY eaten, never the theoretical cap. A Glutton that
        -- has never fed must not heal up to five times its base.
        if st then opts.eatMult = 1.0 + (st.totalMultGain or 0) end
    end

    return RQCeiling.resolve(zombie:getModData(), zType, mult, opts)
end

-- ---------------------------------------------------------------------------
-- Arming
-- ---------------------------------------------------------------------------
-- Called by RQSvHit for every qualifying hit, including one Bulwark goes on to
-- soak. `firstDueAt` is one cadence out rather than immediate: healing that
-- began on the same tick as the blow would read as the hit doing nothing.
function RQMcCoy.onAttacked(ctx)
    local w = windows[ctx.zombie]
    if w then
        w.expiresAt = ctx.now + WINDOW_MS
        RQMcCoy.stats.refreshed = RQMcCoy.stats.refreshed + 1
        return true
    end
    windows[ctx.zombie] = {
        zType     = ctx.zType,
        expiresAt = ctx.now + WINDOW_MS,
        nextDueAt = ctx.now + CADENCE_MS,
    }
    RQMcCoy.stats.armed = RQMcCoy.stats.armed + 1
    return true
end

-- ---------------------------------------------------------------------------
-- One target's tick
-- ---------------------------------------------------------------------------
-- Returns true when it actually wrote health. Every refusal is named, because
-- "McCoy did nothing" has half a dozen legitimate causes and telling them apart
-- afterwards is the difference between a tuning conversation and a bug hunt.
function RQMcCoy.tickOne(zombie, w, now, cfg)
    -- A LETHAL HIT STAYS LETHAL. Nothing in this module may resurrect, and a
    -- window outliving its owner by one cadence is exactly how a late write
    -- would happen.
    if zombie:isDead() then
        windows[zombie] = nil
        return skip("dead")
    end
    local hp = zombie:getHealth()
    if hp <= 0 then
        windows[zombie] = nil
        return skip("zero-health")
    end

    RQMcCoy.stats.considered = RQMcCoy.stats.considered + 1

    local ceiling, how = RQMcCoy.ceilingFor(zombie, w.zType, cfg)
    if not ceiling then return skip(how or "no-ceiling") end

    local st = RQMcCoy.stats
    st.byCeiling[how] = (st.byCeiling[how] or 0) + 1

    local target = hp + (ceiling * (HEAL_PCT / 100.0))
    if target > ceiling then target = ceiling end
    -- The network cap is not negotiable: ZombiePacket.health is a signed short
    -- applied as health/1000, and RQSvShared clamps every write to it anyway.
    -- Clamping here too means the no-op test below is made against the value
    -- that will actually land, not one the write path is about to reduce.
    if target > RQSvShared.MAX_NETWORK_HP then target = RQSvShared.MAX_NETWORK_HP end

    if target <= hp then return skip("at-ceiling") end

    -- ownerOnly: this repeats on a cadence and recomputes its target every
    -- time, so it self-corrects through an ownership handoff rather than
    -- needing the belt-and-braces broadcast conversion uses.
    if not RQSvShared.svSetZombieHP(zombie, target, true) then
        return skip("no-authority")
    end

    st.writes = st.writes + 1
    st.healed = st.healed + (target - hp)

    if cfg.debugMode then
        RQDirgeLog.write("McCoy", "[INFO] " .. tostring(w.zType)
            .. " hp=" .. string.format("%.2f", hp)
            .. " -> " .. string.format("%.2f", target)
            .. " ceiling=" .. string.format("%.2f", ceiling)
            .. " via=" .. tostring(how))
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Update
-- ---------------------------------------------------------------------------
-- Walks only armed windows, never the special registry. Returns the number
-- still armed so the caller can see the set stays bounded.
function RQMcCoy.update(now)
    local cfg = RQSvShared.getSvConfig()
    local live, expiring = 0, nil

    for zombie, w in pairs(windows) do
        if now >= w.expiresAt then
            expiring = expiring or {}
            expiring[#expiring + 1] = zombie
        else
            live = live + 1
            if now >= w.nextDueAt then
                -- Advance from the deadline, not from `now`, so a late pass
                -- does not slowly walk the cadence forward and turn a
                -- two-second heal into a two-and-a-bit-second one.
                w.nextDueAt = w.nextDueAt + CADENCE_MS
                if w.nextDueAt <= now then w.nextDueAt = now + CADENCE_MS end
                RQMcCoy.tickOne(zombie, w, now, cfg)
            end
        end
    end

    -- Same reason as Bloodhound: never mutate the table mid-walk.
    if expiring then
        for i = 1, #expiring do
            windows[expiring[i]] = nil
            RQMcCoy.stats.expired = RQMcCoy.stats.expired + 1
        end
    end
    return live
end

function RQMcCoy.reset()
    for zombie in pairs(windows) do windows[zombie] = nil end
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
