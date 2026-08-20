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

print(string.format("RQSvScreamer: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
