-- RQSvScreamer.lua
-- handles the alive behavior tick for Screamer type zombies
-- screamer wakes up when a player enters awareness range, then screams + spawns on shorter trigger range
if not isServer() then return end

-- how much wider the "awareness" range is vs the actual scream trigger range
local SCREAMER_AWARENESS_MULT = 2.5

RQSvScreamer = RQSvScreamer or {}
RQSvScreamer.state = {}  -- scID -> { lastScreamTime, castDue, isAlert }

-- returns true if the zombie currently has a live target in aggro, used to avoid double-triggering
local function svScreamerHasAggro(zombie)
    local okTarget, target = pcall(zombie.getTarget, zombie)
    if not okTarget or not target then return false end
    local okDead, dead = pcall(target.isDead, target)
    if okDead and dead then return false end
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
    local okSound = pcall(addSound, source, zx, zy, zz, cfg.screamerSoundRadius, cfg.screamerSoundRadius)
    if not okSound then
        RQDirgeLog.write("Screamer", "[WARN] addSound failed - falling back to WorldSoundManager at (" .. zx .. "," .. zy .. "," .. zz .. ")")
        pcall(function()
            getWorldSoundManager():addSound(source, zx, zy, zz, cfg.screamerSoundRadius, cfg.screamerSoundRadius, false)
        end)
    end
    local nearbyCount = RQSvShared.svCountNearbyAliveZombies(zx, zy, zz, RQSvShared.SCREAMER_SPAWN_RADIUS, source)
    if nearbyCount < cfg.screamerSpawnThreshold then
        local count = cfg.screamerSpawnMin + ZombRand(cfg.screamerSpawnMax - cfg.screamerSpawnMin + 1)
        RQDirgeLog.write("Screamer", "[INFO] scream fired at (" .. zx .. "," .. zy .. "," .. zz .. ")"
            .. " soundOk=" .. tostring(okSound)
            .. " nearby=" .. nearbyCount .. " threshold=" .. cfg.screamerSpawnThreshold
            .. " spawning=" .. count)
        RQSvShared.svDoSpawn(zx, zy, zz, count)
        return count
    end
    RQDirgeLog.write("Screamer", "[INFO] scream fired at (" .. zx .. "," .. zy .. "," .. zz .. ")"
        .. " soundOk=" .. tostring(okSound)
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
    -- wider awareness range wakes the screamer up and re-enables pathfinding
    local awarenessRange = cfg.screamerTriggerRange * SCREAMER_AWARENESS_MULT
    local playerInAwareness = RQSvShared.isAnyPlayerInRange(zombie, awarenessRange)
    if playerInAwareness and not state.isAlert then
        state.isAlert = true
        pcall(zombie.setUseless,  zombie, false)
        pcall(zombie.setVariable, zombie, "bPathfind", true)
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

-- Copyright Project_Omen
