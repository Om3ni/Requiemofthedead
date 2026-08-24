-- SPDX-License-Identifier: GPL-3.0-or-later
-- RQSvScavenger - server tick for the sleeper threat
-- Looks like a Glutton at first - green, eats corpses, gets fatter. Hit it
-- once and it hulks out with peakHP*5 and a juggernaut-style aura that buffs
-- specials only (not regular zombies, story reason). HP decays linearly back
-- to base over 10 minutes but it stays hostile forever. Eats while raging,
-- and rage-eating actively heals toward the frozen peakHP (never above).
--
-- Rage trigger is event-driven from RQSvHit's server-side intake via the
-- scavPlayerHit command; the HP-threshold heuristic that used to live here
-- was unreliable (depended on the order of damage vs tick) and is gone.
--
-- Depends on RQSvShared and RQSvEating (corpse reservation lives there).
if not isServer() then return end

-- RQSvEating is dereferenced at FILE SCOPE (the state injection at the bottom),
-- so the dependency is declared, not assumed from load order. RQBloodhound
-- sorts ahead of RQSvEating in the alphabetical walk and pulled this file in
-- first on 2026-08-24 - the injection threw against nil and eating was dead all
-- session. Full mechanics of that failure: RQSvGlutton.lua's matching note.
require "RQSvEating"

RQSvScavenger = RQSvScavenger or {}

-- Matches the Glutton's corpse-scan cadence; both feed the same eating
-- engine and there is no reason for them to disagree about how often a
-- stationary body is worth looking for.
local CORPSE_SCAN_INTERVAL = 500

-- scavID -> state
-- phase:         "idle" | "seeking" | "eating" (eating state machine, runs even when hostile)
-- baseHealth:    immutable original spawn HP. Decay target. Gradient denominator on the client.
-- peakHP:        high-water mark while passive; frozen at rageHP on the rage flip.
-- hostile:       has it raged yet? Once true, stays true.
-- rageStartTime: when the decay clock started. Resets on server restart mid-fight (acceptable).
RQSvScavenger.state = {}

-- The `buffed` weak table is GONE (2026-08-24) with the sweep that needed it.

-- Injected by RQServer after svActiveZombies exists. Still read by the rage
-- aura's successor question - "is this zombie one of ours" - which RQBulwark
-- now asks through RQSvShared instead.
local _activeZombies = {}
function RQSvScavenger.setActiveZombies(tbl)
    _activeZombies = tbl
end

local SEEK_TIMEOUT        = 45000   -- (ms) corpse-seek timeout before we give up and pick another
local RAGE_HP_MULTIPLIER  = 5       -- rage HP = peakHP * 5. No cap, intentionally terrifying when well-fed.
local RAGE_DECAY_DURATION = 600000  -- (ms) 10 minutes from peakHP back down to baseHealth

-- Tick down the rage HP. Linear from peakHP to baseHealth over the full
-- duration. Only ever pushes HP down, never up - if the player is hitting
-- it (or rage-eating is topping it up), don't fight them by undoing their work.
local function tickRageDecay(zombie, state, now)
    if not state.hostile or not state.rageStartTime then return end
    local elapsed = now - state.rageStartTime
    if elapsed >= RAGE_DECAY_DURATION then
        -- One-time clamp to baseHealth, then disarm so subsequent ticks
        -- don't keep slamming HP down. Without this, post-decay re-feeding
        -- silently fails: rage-eating sets HP to baseHP*share, decay tick
        -- 2s later sees current > baseHealth and pushes it back. The scav
        -- ends up "stuck at baseHealth despite feeding" - exact symptom
        -- observed in the wild. State.hostile stays true (scav is angry
        -- forever, that's the design), only the decay clock is retired.
        if zombie:getHealth() > state.baseHealth then
            RQSvShared.svSetZombieHP(zombie, state.baseHealth, true)
        end
        state.rageStartTime = nil
        return
    end
    local progress = elapsed / RAGE_DECAY_DURATION
    local target   = state.peakHP - (state.peakHP - state.baseHealth) * progress
    local current  = zombie:getHealth()
    if target < current then
        -- ownerOnly: recomputed from peakHP every decay tick, so a write lost to
        -- an ownership handoff is corrected 2s later.
        RQSvShared.svSetZombieHP(zombie, target, true)
    end
end

-- Juggernaut-style aura buff, but only paints specials. Regular zombies are
-- intentionally left alone (lore: scavs don't share with shamblers). Dedup
-- via the weak-keyed `buffed` table so each target gets the +N% exactly once
-- per scav. Boss and Jugg buffs take precedence - if either has already
-- claimed a target, scav skips it.
-- tickRageAura is GONE (2026-08-24). An enraged Scavenger still protects the
-- specials around it; RQBulwark decides that when a hit lands rather than
-- pre-granting health that outlived the rage that earned it.
--
-- The two functions below were COLLATERAL of that deletion for part of
-- 2026-08-24: the removal script's pattern swallowed its neighbours, the file
-- stayed syntax-clean, and every fixture stubbed this module - so the loss was
-- invisible until a fixture loaded the real file and asked for the surface
-- RQSvHit, RQBulwark and RQBloodhound dispatch to. Restored verbatim from the
-- pre-deletion tree.

-- Is this Scavenger currently raging? Asked by RQBulwark, which protects an
-- enraged Scavenger and deliberately does not protect a passive one.
--
-- Live state first, the persisted flag second - the same shape as
-- RQSvShared.typeOf and for the same reason. A Scavenger that has not been
-- ticked since a reload has no state row yet but still carries RQScavHostile,
-- and it is unambiguously still raging; answering "no" for the gap between
-- reload and first tick would hand players a window where the hardest target in
-- the game briefly stops defending itself.
function RQSvScavenger.isEnraged(zombie)
    if not zombie then return false end
    local oid = zombie:getOnlineID()
    local state = oid and RQSvScavenger.state[oid]
    if state then return state.hostile == true end
    return zombie:getModData()["RQScavHostile"] == true
end

-- Called by RQSvHit, which has already established that this is a player
-- attack on a registered special. Takes only the zombie: the attacker's name
-- was a parameter for years and never read by a single line of this body.
function RQSvScavenger.onPlayerHit(zombie)
    if not zombie then return end
    local scavID = zombie:getOnlineID()
    if not scavID or scavID < 0 then return end
    local state = RQSvScavenger.state[scavID]
    if not state then return end          -- not yet ticked; client will retry on next hit
    if state.hostile then return end      -- already raging, ignore duplicate hits

    local cfg    = RQSvShared.getSvConfig()
    local now    = getTimestampMs()
    local rageHP = state.peakHP * RAGE_HP_MULTIPLIER

    state.hostile       = true
    state.rageStartTime = now
    state.peakHP        = rageHP   -- FROZEN. No further bumps.
    zombie:getModData()["RQScavHostile"] = true
    zombie:transmitModData()

    -- Cancel any in-flight eating before flipping. Co-eating: drop ourselves
    -- from the shared cast so the survivors get the correct share count
    -- (locked N excludes the rage-quitter). If we were the only eater this
    -- also GCs the cast entry so the corpse goes back in the pool.
    RQSvEating.svClearEatingIntent(zombie)
    RQSvEating.svRemoveEaterFromCast(state.targetCorpse, scavID)
    state.phase        = "idle"
    state.targetCorpse = nil
    state.targetSq     = nil
    state.castDue      = nil
    zombie:setUseless(false)
    zombie:setVariable("bPathfind", true)
    zombie:setVariable("bMoving",   false)
    zombie:setEatBodyTarget(nil, false, 1.0)
    RQSvShared.broadcast("castDone", { ringId = "scav_" .. scavID })
    RQSvShared.broadcast("gluttonAnimate", {
        onlineID = scavID, eating = false, phase = "idle",
        x = math.floor(zombie:getX()),
        y = math.floor(zombie:getY()),
        z = math.floor(zombie:getZ()),
    })
    RQSvShared.svSetZombieHP(zombie, rageHP)
    local zx = math.floor(zombie:getX())
    local zy = math.floor(zombie:getY())
    local zz = math.floor(zombie:getZ())
    addSound(zombie, zx, zy, zz, cfg.screamerSoundRadius, cfg.screamerSoundRadius)

    -- Tell clients to play the scream sound and apply the screamer disorientation
    -- pipeline at the rage epicenter. Mirrors what boss Scream / screamer zombies
    -- do, just delivered via a dedicated command so we don't fake a castStart bar.
    RQSvShared.broadcast("scavRageScream", {
        x = zx, y = zy, z = zz, onlineID = scavID,
    })
end

-- main tick, called each alive behavior pass for scavenger zombies
function RQSvScavenger.tick(zombie)
    local cfg    = RQSvShared.getSvConfig()
    local scavID = zombie:getOnlineID()
    if not scavID or scavID < 0 then return end
    local state  = RQSvScavenger.state[scavID]
    if not state then
        -- if this zombie was already raging when we loaded it (server restart
        -- mid-fight), pick up the hostile flag from modData. Decay clock starts
        -- fresh - we don't persist rageStartTime, the player gets a new 10 min window
        local wasHostile = zombie:getModData()["RQScavHostile"] == true
        local nowInit    = getTimestampMs()
        local curHP      = zombie:getHealth()
        local baseHP     = zombie:getModData()["RQGluttonBaseHealth"] or curHP
        state = {
            phase         = "idle",
            baseHealth    = baseHP,
            peakHP        = curHP,
            eatCount      = 0,
            totalMultGain = 0.0,  -- co-eating fractional accumulator (sum of 0.5/N shares)
            hostile       = wasHostile,
            rageStartTime = wasHostile and nowInit or nil,
            targetCorpse  = nil,
            targetSq      = nil,
            seekDue       = nil,
            castDue       = nil,
            lastBuffTick  = nil,
        }
        RQSvScavenger.state[scavID] = state
    end

    local now = getTimestampMs()

    -- Peak only tracks while passive. Once hostile, peakHP is the frozen
    -- rage ceiling and must not move - decay and gradient both key off it.
    if not state.hostile and zombie:getHealth() > state.peakHP then
        state.peakHP = zombie:getHealth()
    end
    tickRageDecay(zombie, state, now)

    repeat
        if state.phase == "eating" then
            zombie:clearAggroList()
            zombie:setTarget(nil)
            local corpseGone = not RQSvEating.svCorpseStillThere(state.targetCorpse, state.targetSq)
            local timedOut   = state.castDue and now >= state.castDue
            if corpseGone or timedOut then
                state.castDue = nil
                RQSvShared.broadcast("castDone", { ringId = "scav_" .. scavID })
                RQSvEating.svClearEatingIntent(zombie)
                -- Co-eating finalize: applies this Scavenger's share (0.5/N), removes
                -- the corpse if first finalizer, drops self from cast.eaters.
                RQSvEating.svFinalizeEater(zombie, state, scavID, "Scavenger", cfg)
                state.targetCorpse = nil
                state.targetSq     = nil
                RQSvEating.svRestoreAI(zombie)
                state.phase = "idle"
                local zx = math.floor(zombie:getX())
                local zy = math.floor(zombie:getY())
                local zz = math.floor(zombie:getZ())
                RQSvShared.broadcast("gluttonAnimate", { onlineID = scavID, eating = false, phase = "idle", x = zx, y = zy, z = zz })
            end
            break
        end

        if state.phase == "idle" then
            -- scan nearby for a corpse, radius is smaller than Glutton.
            -- Throttled for the same reason the Glutton's is: a corpse does not
            -- move, so re-asking sixty times a second buys nothing. The smaller
            -- radius makes each scan cheaper, not free.
            if not RQSvShared.due(state, "nextScan", CORPSE_SCAN_INTERVAL, now) then break end
            local corpse, corpseSq = RQSvEating.svGluttonFindCorpse(zombie, RQSvShared.SCAV_CORPSE_RADIUS, scavID)
            if not corpse then
                break
            end
            state.phase        = "seeking"
            state.targetCorpse = corpse
            state.targetSq     = corpseSq
            state.seekDue      = now + SEEK_TIMEOUT
            RQSvEating.svSetEatingIntent(zombie, "Scavenger", corpseSq, "seeking")
            local dx = math.floor(zombie:getX())
            local dy = math.floor(zombie:getY())
            local dz = math.floor(zombie:getZ())
            RQSvShared.broadcast("gluttonAnimate", {
                onlineID = scavID, eating = true, phase = "seeking",
                x = dx, y = dy, z = dz,
                corpseX = corpseSq:getX(), corpseY = corpseSq:getY(), corpseZ = corpseSq:getZ(),
            })

        elseif state.phase == "seeking" then
            local corpseGone = not RQSvEating.svCorpseStillThere(state.targetCorpse, state.targetSq)
            local timedOut   = state.seekDue and now >= state.seekDue
            if corpseGone or timedOut then
                RQSvEating.svCancelEaterState(zombie, state, scavID)
            end
        end
    until true
end

-- Hit detection MOVED to RQSvHit (2026-08-24). This file used to own its own
-- OnHitZombie listener; it now exposes onPlayerHit and the single intake calls
-- it first in a fixed order. The validation that used to live in the listener
-- here - player attacker, registered special type - is done once in RQSvHit for
-- all four responsibilities instead of once per subscriber. The debounce
-- against an already-raging Scavenger stays in onPlayerHit, where it belongs:
-- it is a property of rage, not of hit intake.

-- give RQSvEating a reference to our state table so it can clean up on zombie death
RQSvEating.setScavengerState(RQSvScavenger.state)

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
