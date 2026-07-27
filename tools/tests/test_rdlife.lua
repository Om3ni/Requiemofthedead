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
-- Stubs are light because every helper in RDLife is pcall-wrapped and degrades to
-- a default, so the mock player only needs the handful of methods the poll and
-- handleReady actually branch on.
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

RDShared = { mods = {}, nowMs = function() return clockMs end,
             nowSec = function() return clockSec end }

local chronicled = {}   -- list of event names, in order
RDLog = {
    chronicle = function(evt) chronicled[#chronicled + 1] = evt end,
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
    }
    function self:getOnlineID()   return self._id end
    function self:getUsername()   return self._user end
    function self:getModData()    return self._md end
    function self:isDead()        return self._dead end
    function self:getSquare()     return self._loaded and {} or nil end
    function self:getInventory()  return self._loaded and {} or nil end
    function self:transmitModData() end
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

print(string.format("RDLife: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
