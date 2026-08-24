-- RQSvScreamer fixture - a Screamer emits one authoritative world sound, then
-- independently decides whether the local population allows a reinforcement wave.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDirge/42/media/lua/server/RQSvScreamer.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL RQSvScreamer: " .. message)
    end
end

function isServer() return true end

local sounds, spawns, logs = {}, {}, {}
function addSound(source, x, y, z, radius, volume)
    sounds[#sounds + 1] = { source = source, x = x, y = y, z = z, radius = radius, volume = volume }
end
function ZombRand() return 1 end

RQDirgeLog = { write = function(_, line) logs[#logs + 1] = line end }
local nearby = 0
RQSvShared = {
    SCREAMER_SPAWN_RADIUS = 40,
    svCountNearbyAliveZombies = function(x, y, z, radius, source)
        return nearby
    end,
    svDoSpawn = function(x, y, z, count)
        spawns[#spawns + 1] = { x = x, y = y, z = z, count = count }
    end,
}

RQSvScreamer = nil
local ok, err = pcall(dofile, SOURCE)
check(ok, "module loads: " .. tostring(err))

local source = {}
local cfg = {
    screamerSoundRadius = 100,
    screamerSpawnThreshold = 5,
    screamerSpawnMin = 2,
    screamerSpawnMax = 4,
}

local spawned = RQSvScreamer.screamAt(source, 10, 20, 0, cfg)
check(#sounds == 1 and sounds[1].source == source, "emits one world sound from the supplied source")
check(sounds[1] and sounds[1].x == 10 and sounds[1].y == 20 and sounds[1].z == 0,
    "world sound preserves authoritative coordinates")
check(sounds[1] and sounds[1].radius == 100 and sounds[1].volume == 100,
    "world sound uses the configured radius and volume")
check(spawned == 3 and #spawns == 1 and spawns[1].count == 3,
    "below threshold emits the configured reinforcement count")

nearby = 5
spawned = RQSvScreamer.screamAt(source, 30, 40, 1, cfg)
check(#sounds == 2, "thresholded scream still emits exactly one additional world sound")
check(spawned == 0 and #spawns == 1, "at threshold suppresses only the reinforcement wave")
check(logs[#logs] and logs[#logs]:find("NO spawn", 1, true) ~= nil,
    "threshold decision remains observable")

-- ---------------------------------------------------------------------------
-- Awareness throttle
-- ---------------------------------------------------------------------------
-- isAnyPlayerInRange walks getOnlinePlayers() with a visibility test per player,
-- so on a full server this was ~40 checks per screamer per tick. It is now gated.
-- The gate is the one place in the cadence slice where being late is felt as AI
-- that did not notice you, so it runs at the tightest interval in the mod - and
-- the skipped-pass path has to HOLD the previous verdict rather than reading as
-- "nobody there", or a screamer would flicker out of alert between checks.

local clock = 0
function getTimestampMs() return clock end

local rangeCalls, playerNear = 0, false
local function due(state, key, intervalMs, when)
    if not state then return true end
    local last = state[key]
    if last and (when - last) < intervalMs then return false end
    state[key] = when
    return true
end

RQSvShared.due = due
RQSvShared.broadcast = function() end
RQSvShared.makeCastArgs = function() return {} end
RQSvShared.COLORS = { Screamer = {} }
RQSvShared.getSvConfig = function()
    return {
        screamerTriggerRange   = 10,
        screamerRepeatInterval = 60000,
        screamerCastTime       = 3000,
        screamerSoundRadius    = 100,
        screamerSpawnThreshold = 5,
        screamerSpawnMin       = 2,
        screamerSpawnMax       = 4,
    }
end
RQSvShared.isAnyPlayerInRange = function()
    rangeCalls = rangeCalls + 1
    return playerNear
end

local useless, pathfind = true, false
local zed = {
    getOnlineID = function() return 77 end,
    getX = function() return 5 end,
    getY = function() return 5 end,
    getZ = function() return 0 end,
    setUseless  = function(_, v) useless = v end,
    setVariable = function(_, k, v) if k == "bPathfind" then pathfind = v end end,
}

-- Idle, nobody about: sixty ticks must not buy sixty player walks.
clock, rangeCalls, playerNear = 1000, 0, false
RQSvScreamer.state[77] = nil
for _ = 1, 60 do
    RQSvScreamer.tick(zed)
    clock = clock + 16
end
check(rangeCalls > 0, "a screamer checks awareness at least once per second")
check(rangeCalls <= 6,
    "awareness is no longer tested every tick: " .. rangeCalls .. " walks in ~1s")

-- A player arriving is noticed on the next due pass, and the wake-up side
-- effects fire exactly once rather than on every tick that follows.
playerNear = true
clock = clock + 300
RQSvScreamer.tick(zed)
check(RQSvScreamer.state[77].isAlert == true, "an arriving player raises alert")
check(useless == false and pathfind == true, "raising alert wakes the zombie for pathfinding")

-- THE LATCH. Between due passes the check is skipped; alert must hold. If the
-- skipped path read as "no player", the screamer would drop back to idle on the
-- very next tick and re-wake on the one after.
useless, pathfind = true, false
rangeCalls = 0
for _ = 1, 10 do
    clock = clock + 16
    RQSvScreamer.tick(zed)
end
check(rangeCalls == 0, "the latch test is genuinely running on skipped passes")
check(RQSvScreamer.state[77].isAlert == true, "alert holds through skipped passes")
check(useless == true and pathfind == false,
    "an already-alert screamer does not re-fire its wake-up side effects")

-- And it does stand down once a due pass sees the player gone.
playerNear = false
clock = clock + 300
RQSvScreamer.tick(zed)
check(RQSvScreamer.state[77].isAlert == false, "a due pass with nobody in range stands the screamer down")

print(string.format("RQSvScreamer: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
