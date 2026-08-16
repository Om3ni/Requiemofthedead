-- test_rdlife.lua - RDLife's player-ready poll, and the respawn re-arm.
--
-- WHY THIS EXISTS. The poll is a state machine over three tables (readyID,
-- gaveUpID, watchStart) crossed with alive/dead and present/absent life id. It
-- cannot be exercised without a running dedicated server and a player willing to
-- die on cue, and it is Core - every mod's chronicle records depend on it. The
-- respawn bug it now guards against went unnoticed precisely because it only
-- appears when a player dies and does NOT reconnect.
--
-- ENGINE FACTS THIS ENCODES (verified against the B42 decompile, not guessed):
--   * respawning is NOT a reconnect - GameServer.receivePlayerConnect returns
--     early when the connection's player slot is occupied, and onlineID comes
--     from connection.getPlayerId(playerIndex), so it is stable for the session
--   * CreatePlayerPacket.processServer builds a BRAND NEW IsoPlayer, so modData
--     (and RFTD_LifeId with it) does not survive death
-- The mock below reproduces exactly that: same onlineID, fresh modData table.
--
-- The fixture mirrors every engine surface RDLife calls directly. Those calls
-- were verified and deliberately unwrapped in the pcall sweep, so a missing mock
-- method should fail loudly here instead of being mistaken for engine resilience.
--
-- Usage (normally via tools\run-tests.bat):
--   lua5.1.exe tools/tests/test_rdlife.lua <repo-root>

local ROOT = arg[1] or "."
local SRC  = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/server/RDLife.lua"

local pass, fail = 0, 0
local function eq(name, got, want)
    if got == want then pass = pass + 1
    else
        fail = fail + 1
        print("FAIL " .. name)
        print("  got:  " .. tostring(got))
        print("  want: " .. tostring(want))
    end
end

-- ---------------------------------------------------------------------------
-- Engine stubs
-- ---------------------------------------------------------------------------

function isServer() return true end
function isClient() return false end
require = function() end

local clockMs, clockSec = 1000, 1000
local randSeq = 0
function ZombRand() randSeq = randSeq + 1; return randSeq end

local gameDay = 1.0
RDShared = { mods = {}, nowMs = function() return clockMs end,
             nowSec = function() return clockSec end,
             gameDay = function() return gameDay end,
             debugOn = function() return false end }

-- LuaManager.java:1757-1759 exposes PerkFactory, Perk and Perks. The production
-- loop consumes the Java ArrayList through size/get, so preserve that shape.
local perkNone   = { id = "None" }
local perkAiming = { id = "Aiming" }
local perkMax    = { id = "MAX" }
for _, perk in ipairs({ perkNone, perkAiming, perkMax }) do
    function perk:getType() return self end
    function perk:getId() return self.id end
end
local perkList = { perkNone, perkAiming, perkMax }
PerkFactory = {
    Perks = { None = perkNone, MAX = perkMax },
    PerkList = {
        size = function() return #perkList end,
        get  = function(_, i) return perkList[i + 1] end,
    },
}

-- homePass owns the genuine SafeHouse failure boundary. No safehouse is the
-- ordinary result for these players; the global itself always exists in-game.
SafeHouse = { hasSafehouse = function() return nil end }

local chronicled = {}   -- list of event names, in order
local lastPayload = {}  -- event name -> the payload table it last carried
RDLog = {
    chronicle = function(evt, _p, payload)
        chronicled[#chronicled + 1] = evt
        lastPayload[evt] = payload
    end,
    forensic  = function() end,
}

-- Events stub that hands back whatever handler each Add() was given.
local handlers = {}
Events = setmetatable({}, { __index = function(t, k)
    local e = { Add = function(fn) handlers[k] = fn end }
    rawset(t, k, e)
    return e
end })

-- ---------------------------------------------------------------------------
-- Mock player + online list
-- ---------------------------------------------------------------------------

local function newPlayer(onlineId, username)
    local self = {
        _id = onlineId, _user = username,
        _md = {},                -- modData; replaced wholesale on "respawn"
        _dead = false,
        _loaded = true,          -- has square + inventory
        _hours = 0.25,
        _x = 100.75, _y = 200.25, _z = 0,
        _zombieKills = 3, _survivorKills = 1,
        _perkLevels = { [perkAiming] = 2 },
    }
    self._square = { getBuilding = function() return nil end }
    function self:getOnlineID()   return self._id end
    function self:getUsername()   return self._user end
    function self:getModData()    return self._md end
    function self:isDead()        return self._dead end
    function self:getSquare()     return self._loaded and self._square or nil end
    function self:getInventory()  return self._loaded and {} or nil end
    function self:getHoursSurvived() return self._hours end
    function self:getX() return self._x end
    function self:getY() return self._y end
    function self:getZ() return self._z end
    function self:getZombieKills() return self._zombieKills end
    function self:getSurvivorKills() return self._survivorKills end
    function self:getPerkLevel(perk) return self._perkLevels[perk] or 0 end
    function self:transmitModData() end
    -- Traits/profession as the engine hands them over: getName() is the PATH with
    -- the namespace stripped, tostring() is the full "namespace:path" id. The
    -- chronicle must record the id - see the traitsOf comment in RDLife for why a
    -- name-only record cannot tell base:organized from a mod trait shadowing it.
    local function regObj(id)
        local o = { getName = function(s) return (s.__id:match("^[^:]+:(.+)$")) end, __id = id }
        return setmetatable(o, { __tostring = function(s) return s.__id end })
    end
    self._traits = { regObj("base:organized"), regObj("seinarextendedprofessions:slicer") }
    self._prof   = regObj("base:unemployed")
    function self:getCharacterTraits()
        local t = self._traits
        return { getKnownTraits = function()
            return { size = function() return #t end, get = function(_, i) return t[i + 1] end }
        end }
    end
    function self:getDescriptor()
        local pr = self._prof
        return { getCharacterProfession = function() return pr end }
    end
    -- CreatePlayerPacket.processServer constructs a new IsoPlayer: same
    -- connection, same onlineID, empty modData.
    function self:respawnAsNewCharacter()
        self._md = {}
        self._dead = false
    end
    return self
end

local online = {}
function getOnlinePlayers()
    return {
        size = function() return #online end,
        get  = function(_, i) return online[i + 1] end,
    }
end

-- ---------------------------------------------------------------------------
-- Load and drive
-- ---------------------------------------------------------------------------

local okLoad, err = pcall(dofile, SRC)
if not okLoad then
    print("FATAL: could not load " .. SRC)
    print("  " .. tostring(err))
    os.exit(2)
end

local poll = handlers.OnTick
if type(poll) ~= "function" then
    print("FAIL RDLife did not register an OnTick poll")
    print("RDLife: 0 passed, 1 failed")
    os.exit(1)
end

-- One poll pass. The poll self-throttles to 1s, so the clock always advances.
local function tick()
    clockMs  = clockMs + 1500
    clockSec = clockSec + 2
    chronicled = {}
    local ok, e = pcall(poll)
    if not ok then
        fail = fail + 1
        print("FAIL poll() threw: " .. tostring(e))
    end
    return chronicled
end

local function counts(list)
    local spawn, login = 0, 0
    for _, e in ipairs(list) do
        if e == "RD.SPAWN" then spawn = spawn + 1
        elseif e == "RD.LOGIN" then login = login + 1 end
    end
    return spawn, login
end

-- ---------------------------------------------------------------------------
-- First ready
-- ---------------------------------------------------------------------------

local p = newPlayer(101, "Omen")
online = { p }

local spawn, login = counts(tick())
eq("first ready chronicles RD.SPAWN", spawn, 1)
eq("first ready does not chronicle RD.LOGIN", login, 0)
eq("a life id was minted", type(p._md.RFTD_LifeId), "string")

-- The build record must carry FULL REGISTRY IDS. Recording getName() was how a
-- memoir read that swapped base:organized for a mod trait shadowing the same path
-- produced a chronicle showing nothing had changed (Mox, 2026-08-09): both objects
-- answer "organized", so the record could not distinguish the character it
-- described from the one it had lost. traitsOf sorts, so the order is stable.
local build = lastPayload["RD.SPAWN"] and lastPayload["RD.SPAWN"].build or {}
local firstSpawn = lastPayload["RD.SPAWN"] or {}
eq("chronicled survival hours come from the player", firstSpawn.hours, 0.25)
eq("chronicled x is floored", firstSpawn.x, 100)
eq("chronicled y is floored", firstSpawn.y, 200)
eq("chronicled z is floored", firstSpawn.z, 0)
eq("chronicled zombie kills come from the player", firstSpawn.kills and firstSpawn.kills.zombies, 3)
eq("chronicled survivor kills come from the player", firstSpawn.kills and firstSpawn.kills.survivors, 1)
eq("chronicled perk levels come from PerkFactory", build.perks and build.perks.Aiming, 2)
eq("chronicled traits are namespaced ids, not getName()",
    table.concat(build.traits or {}, ","), "base:organized,seinarextendedprofessions:slicer")
eq("chronicled profession is a namespaced id", build.profession, "base:unemployed")
local firstLife = p._md.RFTD_LifeId

spawn, login = counts(tick())
eq("a settled player produces nothing further", spawn + login, 0)
eq("the life id is unchanged", p._md.RFTD_LifeId, firstLife)

-- ---------------------------------------------------------------------------
-- THE FIX: die, respawn on the SAME connection
-- ---------------------------------------------------------------------------

p._dead = true
spawn, login = counts(tick())
eq("a corpse chronicles nothing", spawn + login, 0)

-- Still dead, and modData is already gone the moment the new IsoPlayer exists.
-- This is the window that must not produce a spawn on the body.
p._md = {}
spawn, login = counts(tick())
eq("a dead player with wiped modData still chronicles nothing", spawn + login, 0)

p:respawnAsNewCharacter()
spawn, login = counts(tick())
eq("the respawned life chronicles RD.SPAWN", spawn, 1)
eq("the respawned life is NOT recorded as a login", login, 0)
eq("the respawned life got a life id", type(p._md.RFTD_LifeId), "string")
eq("the respawned life id is NEW", p._md.RFTD_LifeId ~= firstLife, true)

-- Re-arm must be one-shot: handleReady sets the life id, so the condition stops
-- matching. If this regresses, RD.SPAWN floods once per second forever.
local total = 0
for _ = 1, 5 do
    local s, l = counts(tick())
    total = total + s + l
end
eq("the re-arm does not repeat once the life id is set", total, 0)

-- ---------------------------------------------------------------------------
-- Reconnect with modData intact is a LOGIN, not a spawn
-- ---------------------------------------------------------------------------

local prune = handlers.OnPlayerDisconnect or handlers.OnDisconnect
eq("a disconnect hook is registered", type(prune), "function")
prune(p)
spawn, login = counts(tick())
eq("reconnect with a surviving life id chronicles RD.LOGIN", login, 1)
eq("reconnect does not chronicle RD.SPAWN", spawn, 0)

-- ---------------------------------------------------------------------------
-- Give-up path, and its interaction with the re-arm
--
-- The give-up deliberately never sets a life id. A naive re-arm ("no life id =
-- swapped character") would therefore clear readyID every pass and turn the
-- 5-minute give-up into an endless retry - which is why gaveUpID exists.
-- ---------------------------------------------------------------------------

local stuck = newPlayer(202, "Stuck")
stuck._loaded = false          -- never gets a square or inventory
online = { stuck }

tick()
eq("a still-loading player chronicles nothing", #chronicled, 0)
eq("a still-loading player has no life id", stuck._md.RFTD_LifeId, nil)

-- Push past WATCH_MAX_MS (5 minutes) so the give-up fires.
clockMs = clockMs + 6 * 60 * 1000
tick()
eq("give-up chronicles nothing", #chronicled, 0)

-- The player is STILL loadable-looking and still has no life id. Without the
-- gaveUpID guard this would re-arm and retry on every single pass.
stuck._loaded = true
total = 0
for _ = 1, 5 do
    local s, l = counts(tick())
    total = total + s + l
end
eq("a given-up player is not retried by the re-arm", total, 0)

-- A genuine reconnect still clears the give-up.
prune(stuck)
spawn, login = counts(tick())
eq("reconnect clears the give-up and instruments the player", spawn, 1)

-- ---------------------------------------------------------------------------
-- Two players do not interfere
-- ---------------------------------------------------------------------------

local a, b = newPlayer(301, "A"), newPlayer(302, "B")
online = { a, b }
spawn, login = counts(tick())
eq("both new players spawn", spawn, 2)

a:respawnAsNewCharacter()
spawn, login = counts(tick())
eq("only the respawned player re-spawns", spawn, 1)
eq("distinct life ids per player", a._md.RFTD_LifeId ~= b._md.RFTD_LifeId, true)

-- ---------------------------------------------------------------------------
-- The hourly sampler must not sample a corpse
--
-- A player who dies and does NOT log out stays in getOnlinePlayers(), and
-- getHoursSurvived() keeps climbing on the dead character. Observed live
-- 2026-07-28: a life died at day 7.08 with hours=49.26, the client was left
-- connected overnight, and the sampler wrote RD.SAMPLE for ten more game days
-- under that dead life's id, ending at hours=300.37. Chronicle records are
-- permanent, so those would tell a future reader the life lasted 300 hours.
-- RD.DEATH is the last thing a life may record.
-- ---------------------------------------------------------------------------

local sample = handlers.EveryHours
eq("an hourly sampler is registered", type(sample), "function")

-- Advance a game day and run one sampler pass.
local function hour()
    gameDay = gameDay + 2      -- past the 1.0-day resample threshold
    chronicled = {}
    local ok, e = pcall(sample)
    if not ok then
        fail = fail + 1
        print("FAIL EveryHours threw: " .. tostring(e))
    end
    local n = 0
    for _, ev in ipairs(chronicled) do if ev == "RD.SAMPLE" then n = n + 1 end end
    return n
end

local s1 = newPlayer(401, "Sampled")
online = { s1 }
tick()                                   -- become ready (mints a life id)
eq("sampler subject is ready", type(s1._md.RFTD_LifeId), "string")

eq("a live ready player is sampled", hour(), 1)

s1._dead = true
eq("a corpse is NOT sampled", hour(), 0)
eq("a corpse is still not sampled an hour later", hour(), 0)

-- Respawn: the poll re-arms and the new life becomes sampleable again, under a
-- NEW id - which is the whole point of keeping the two guards consistent.
local deadLife = s1._md.RFTD_LifeId
s1:respawnAsNewCharacter()
tick()
eq("the respawned life has a new id", s1._md.RFTD_LifeId ~= deadLife, true)
eq("the respawned life is sampled again", hour(), 1)

print(string.format("RDLife: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
