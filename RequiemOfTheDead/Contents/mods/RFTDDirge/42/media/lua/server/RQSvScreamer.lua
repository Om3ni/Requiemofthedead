-- SPDX-License-Identifier: GPL-3.0-or-later
-- RQSvScreamer.lua
-- handles the alive behavior tick for Screamer type zombies
-- screamer wakes up when a player enters awareness range, then screams + spawns on shorter trigger range
if not isServer() then return end

-- how much wider the "awareness" range is vs the actual scream trigger range
local SCREAMER_AWARENESS_MULT = 2.5

RQSvScreamer = RQSvScreamer or {}

-- How often a screamer re-checks whether anyone is inside its awareness
-- band. Kept short: this is perceived as reaction time.
local AWARENESS_INTERVAL = 250

RQSvScreamer.state = {}  -- scID -> { lastScreamTime, castDue, isAlert }

-- returns true if the zombie currently has a live target in aggro, used to avoid double-triggering
local function svScreamerHasAggro(zombie)
    local target = zombie:getTarget()
    if not target then return false end
    -- isDead lives on IsoGameCharacter; a non-character target indexes nil
    if target.isDead and target:isDead() then return false end
    return true
end

-- Fires a scream at an arbitrary point: plays the sound and optionally spawns
-- extra zombies nearby, only when the local zombie count is under the threshold
-- so we don't flood an already-packed area. Returns how many it spawned.
--
-- `source` is the sound emitter (a screamer zombie normally, the admin's player
-- for a hand-fired scream, nil if neither) and is also the exclusion for the
-- nearby count. Coords are explicit rather than read off the source, so the
-- admin path and the zombie path run the exact same code instead of drifting.
function RQSvScreamer.screamAt(source, zx, zy, zz, cfg)
    -- addSound is a Java-exported global whose body delegates to the final
    -- WorldSoundManager singleton. Retrying through that same singleton after a
    -- partial failure could duplicate the world sound, so this authoritative
    -- emission is direct. LuaManager.java:9227-9229, 3475-3477;
    -- WorldSoundManager.java:43, 73-82, 107-156.
    addSound(source, zx, zy, zz, cfg.screamerSoundRadius, cfg.screamerSoundRadius)
    local nearbyCount = RQSvShared.svCountNearbyAliveZombies(zx, zy, zz, RQSvShared.SCREAMER_SPAWN_RADIUS, source)
    if nearbyCount < cfg.screamerSpawnThreshold then
        local count = cfg.screamerSpawnMin + ZombRand(cfg.screamerSpawnMax - cfg.screamerSpawnMin + 1)
        RQDirgeLog.write("Screamer", "[INFO] scream fired at (" .. zx .. "," .. zy .. "," .. zz .. ")"
            .. " nearby=" .. nearbyCount .. " threshold=" .. cfg.screamerSpawnThreshold
            .. " spawning=" .. count)
        RQSvShared.svDoSpawn(zx, zy, zz, count)
        return count
    end
    RQDirgeLog.write("Screamer", "[INFO] scream fired at (" .. zx .. "," .. zy .. "," .. zz .. ")"
        .. " nearby=" .. nearbyCount .. " >= threshold=" .. cfg.screamerSpawnThreshold .. " NO spawn")
    return 0
end

-- Zombie-driven scream: same effect, coords taken from the screamer itself.
local function svDoScreamerScream(zombie, cfg)
    RQSvScreamer.screamAt(zombie,
        math.floor(zombie:getX()), math.floor(zombie:getY()), math.floor(zombie:getZ()), cfg)
end

-- main tick, called each alive behavior pass for screamer zombies
function RQSvScreamer.tick(zombie)
    local cfg   = RQSvShared.getSvConfig()
    local scID  = zombie:getOnlineID()
    local state = RQSvScreamer.state[scID]
    if not state then
        state = { lastScreamTime = 0, castDue = nil, isAlert = false }
        RQSvScreamer.state[scID] = state
    end
    local now = getTimestampMs()
    -- if a cast is in progress just wait for it to finish, dont queue another
    if state.castDue then
        if now >= state.castDue then
            state.castDue = nil
            RQSvShared.broadcast("castDone", { ringId = "screamer_" .. scID })
        end
        return
    end
    -- wider awareness range wakes the screamer up and re-enables pathfinding.
    --
    -- Throttled, but only just: isAnyPlayerInRange walks getOnlinePlayers() with
    -- an isPlayerVisible check per player, so on a full server this was forty
    -- visibility tests per screamer per tick. AWARENESS_INTERVAL is the tightest
    -- cadence in this file on purpose - this is the one gate where being late
    -- reads as a screamer that did not notice you, rather than as nothing.
    -- state.isAlert simply holds its previous value on a skipped pass.
    local awarenessRange = cfg.screamerTriggerRange * SCREAMER_AWARENESS_MULT
    local playerInAwareness = state.isAlert
    if RQSvShared.due(state, "nextAwareness", AWARENESS_INTERVAL, now) then
        playerInAwareness = RQSvShared.isAnyPlayerInRange(zombie, awarenessRange)
    end
    if playerInAwareness and not state.isAlert then
        state.isAlert = true
        zombie:setUseless(false)
        zombie:setVariable("bPathfind", true)
        RQDirgeLog.write("Screamer", "[INFO] id=" .. tostring(scID) .. " idle->ALERT awarenessRange=" .. awarenessRange)
    elseif not playerInAwareness and state.isAlert then
        state.isAlert = false
        RQDirgeLog.write("Screamer", "[INFO] id=" .. tostring(scID) .. " ALERT->idle (player left awareness)")
    end
    if not state.isAlert then return end
    -- respect the repeat interval so screamer doesnt spam every tick
    if now - state.lastScreamTime < cfg.screamerRepeatInterval then return end
    -- final check: must be within the tighter trigger range to actually fire
    if not RQSvShared.isAnyPlayerInRange(zombie, cfg.screamerTriggerRange) then return end
    local x = math.floor(zombie:getX())
    local y = math.floor(zombie:getY())
    local z = math.floor(zombie:getZ())
    local displayRadius = math.min(cfg.screamerSoundRadius, 15)
    state.lastScreamTime = now
    svDoScreamerScream(zombie, cfg)
    RQDirgeLog.write("Screamer", "[INFO] id=" .. tostring(scID) .. " SCREAM triggered at (" .. x .. "," .. y .. "," .. z .. ")"
        .. " castTime=" .. cfg.screamerCastTime .. " displayRadius=" .. displayRadius)
    RQSvShared.broadcast("castStart", RQSvShared.makeCastArgs("screamer_" .. scID, x, y, z, cfg.screamerCastTime, RQSvShared.COLORS.Screamer, "Screaming...", displayRadius, zombie:getOnlineID()))
    state.castDue = now + cfg.screamerCastTime
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
