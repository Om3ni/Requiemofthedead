-- RQReflect fixture - verifies a missing world cell is a normal lifecycle
-- state and that a loaded cell still contributes nearby zombie evidence.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDirge/42/media/lua/client/RQReflect.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL RQReflect: " .. message)
    end
end

local handlers = {}
local named = {}
local function event(name)
    named[name] = {}
    return { Add = function(fn)
        handlers[#handlers + 1] = fn
        named[name][#named[name] + 1] = fn
    end }
end

Events = {
    OnPlayerGetDamage = event("damage"),
    OnKeyPressed      = event("key"),
    OnTick            = event("tick"),
    OnServerCommand   = event("server"),
    OnGameStart       = event("start"),
}

function isClient() return true end
local nowMs = 10000
function getTimestampMs() return nowMs end

local player = {
    getX = function() return 100 end,
    getY = function() return 200 end,
    getZ = function() return 0 end,
    getVehicle = function() return nil end,
}
function getPlayer() return player end

local cell = nil
function getCell() return cell end

RQCommon = { MODULE = "RFTD", acceptsModule = function() return true end }
RQRegistry = { activeZombies = {}, getType = function() return nil end }
RQReconcile = { lastKnownPos = {} }

-- Swappable so the sampler tests can decide, per id, whether the client can
-- currently SEE the zombie - which is the whole variable those tests move.
local resolvable = {}
RQCore = { findZombieByID = function(oid) return resolvable[oid] end }
local remembered = {}
RQZombieCache = {
    stats = { resolves = 4, warmed = 3, deferred = 2, dropped = 1 },
    remember = function(zombie)
        remembered[zombie:getOnlineID()] = zombie
        return true
    end,
}

local logs, commands = {}, {}
local lines = {}
RQReflectLog = {
    writeAll = function(l) logs[#logs + 1] = l end,
    write    = function(line) lines[#lines + 1] = line end,
}
function sendClientCommand(module, command, args)
    commands[#commands + 1] = { module = module, command = command, args = args }
end

local realRequire = require
require = function(name)
    if name == "RQReflectLog" then return RQReflectLog end
    return realRequire(name)
end
local ok, err = pcall(dofile, SOURCE)
require = realRequire
check(ok, "module loads: " .. tostring(err))

RQReflect.mark("cell-missing")
check(logs[1] and logs[1][2] == " SEEN unavailable (world cell unavailable)",
    "missing currentCell emits an explicit unavailable line")
check(commands[1] and commands[1].command == "reflectPing" and commands[1].args.reason == "cell-missing",
    "missing currentCell does not suppress the paired server ping")

local zombie = {
    getX = function() return 103 end,
    getY = function() return 204 end,
    getZ = function() return 0 end,
    getOnlineID = function() return 42 end,
    getTarget = function() return nil end,
    isDead = function() return false end,
}
local zombies = {
    size = function() return 1 end,
    get = function(_, index) if index == 0 then return zombie end end,
}
cell = { getZombieList = function() return zombies end }

RQReflect.mark("cell-ready")
local second = logs[2] or {}
check(second[2] and second[2]:find(" SEEN id=42", 1, true) ~= nil,
    "loaded currentCell contributes nearby zombie evidence")
check(not (second[2] and second[2]:find("unavailable", 1, true)),
    "loaded currentCell does not emit the unavailable line")

-- ---------------------------------------------------------------------------
-- THE SAMPLER: resolve first, THEN decide whether it is near
-- ---------------------------------------------------------------------------
-- Rewritten 2026-08-25 alongside the DRIFT retirement. The old order gated on
-- lastKnownPos and only resolved if the cached position looked near, which made
-- the instrumentation depend on the cache it was auditing. These assertions pin
-- the difference; without them the reorder is invisible to the suite.

local function sample()
    -- SAMPLE_TICKS is 60; one sampler pass per 60 OnTick calls.
    for _ = 1, 60 do
        for _, fn in ipairs(named["tick"]) do fn() end
    end
end
local function lastLine(needle)
    for i = #lines, 1, -1 do
        if lines[i]:find(needle, 1, true) then return lines[i] end
    end
    return nil
end

-- A lifecycle gap is not evidence that an object is absent.
cell = nil
RQRegistry.activeZombies = { [9] = "EMP" }
RQReconcile.lastKnownPos[9] = { x = 100, y = 200, z = 0 }
for _ = 1, 4 do sample() end
check(lastLine("MISS id=9") == nil, "an unavailable world cell never advances absence")
cell = { getZombieList = function() return zombies end }

-- The resolver and the complete cell list disagree. This is a cache failure,
-- not a missing zombie: reflection repairs it and never advances MISS.
RQRegistry.activeZombies = { [42] = "Glutton" }
RQReconcile.lastKnownPos[42] = { x = 103, y = 204, z = 0 }
for _ = 1, 4 do sample() end
local cacheMiss = lastLine("CACHE-MISS-IN-CELL id=42")
check(cacheMiss ~= nil, "cell evidence diagnoses a resolver contradiction")
check(cacheMiss and cacheMiss:find("repaired=true", 1, true) ~= nil,
    "the contradiction reports successful cache repair")
check(remembered[42] == zombie, "the independent cell object is warmed into the cache")
check(lastLine("MISS id=42") == nil, "a cache contradiction never becomes an engine-absence MISS")

-- A special the client CAN see is never a miss, however stale its cache.
local visible = {
    getX = function() return 101 end,
    getY = function() return 201 end,
    getZ = function() return 0 end,
    isDead = function() return false end,
}
RQRegistry.activeZombies = { [7] = "Boss" }
resolvable[7] = visible
RQReconcile.lastKnownPos[7] = { x = 100, y = 200, z = 0 }
for _ = 1, 4 do sample() end
check(lastLine("MISS id=7") == nil, "a resolvable special never fires MISS")

-- THE MISS PATH. Nothing resolves, the cache says it is next to the player:
-- three consecutive passes must fire exactly one MISS.
resolvable[7] = nil
sample(); sample()
check(lastLine("MISS id=7") == nil, "MISS holds until the streak is met")
sample()
local miss = lastLine("MISS id=7")
check(miss ~= nil, "MISS fires on the third consecutive unresolvable pass")
check(miss and miss:find("type=Boss", 1, true) ~= nil, "and names the type")
sample(); sample()
local missCount = 0
for _, l in ipairs(lines) do
    if l:find("MISS id=7", 1, true) then missCount = missCount + 1 end
end
check(missCount == 1, "and does not re-fire every pass while still missing: " .. missCount)

-- THE REGRESSION THIS REORDER EXISTS FOR. The special comes back into view
-- while its cached position is far away and stale. Under the old order the
-- distance gate ran FIRST, the pass skipped the zombie entirely, and the
-- RECOVER that closes the MISS was silently lost - so an archive showed a
-- special going missing and never coming back.
RQReconcile.lastKnownPos[7] = { x = 900, y = 900, z = 0 }
resolvable[7] = visible
sample()
local recover = lastLine("RECOVER id=7")
check(recover ~= nil,
    "RECOVER fires when the object resolves even though lastKnownPos is stale")
check(recover and recover:find("resolved=(101.0,201.0)", 1, true) ~= nil,
    "and reports the OBJECT's position, not the cached one")

-- NOPOS is still reached, and only on the unresolvable path: a registered
-- special with no cached position at all cannot be distance-tested.
RQRegistry.activeZombies = { [8] = "Screamer" }
resolvable[8] = nil
RQReconcile.lastKnownPos[8] = nil
sample()
check(lastLine("NOPOS id=8") ~= nil, "a registered special with no cached position logs NOPOS")

-- DRIFT IS RETIRED. It was 974 of the anomaly lines in one archive and can now
-- only be noise: resolution has no search window to fall out of.
local drifted = false
for _, l in ipairs(lines) do
    if l:find("DRIFT", 1, true) then drifted = true end
end
check(not drifted, "no DRIFT line can be emitted any more")

print(string.format("RQReflect: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
