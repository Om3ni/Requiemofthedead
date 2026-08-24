-- RQSvGlutton fixture - the idle corpse scan is throttled without breaking
-- acquisition.
--
-- WHY THIS FILE EXISTS. svGluttonFindCorpse sweeps (2r+1)^2 grid squares, and
-- it used to run on every server tick for every idle Glutton - about nine
-- thousand getGridSquare lookups a second, each one re-answering a question
-- about corpses, which do not move. The cadence slice throttled it. The risk
-- that throttling carries is not cost, it is behaviour: Gluttons and Scavengers
-- finding bodies has been a real problem before, so the scan has to still
-- ACQUIRE, and the phase machine downstream has to still advance. Both are
-- pinned below.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDirge/42/media/lua/server/RQSvGlutton.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL RQSvGlutton: " .. message)
    end
end

function isServer() return true end

local now = 0
function getTimestampMs() return now end

-- The real gate, not a stand-in. A fixture that reimplemented the cadence
-- would pass while production drifted; this way the fixture fails if due()'s
-- contract ever changes underneath it.
local function due(state, key, intervalMs, when)
    if not state then return true end
    local last = state[key]
    if last and (when - last) < intervalMs then return false end
    state[key] = when
    return true
end

local scanCalls = 0
local corpseAvailable = nil

RQSvShared = {
    due = due,
    broadcast = function() end,
    getSvConfig = function()
        return { gluttonRadius = 7, gluttonMaxMult = 5 }
    end,
}
RQDirgeLog = { write = function() end }

local corpsePresent = true
local injectedState = nil
RQSvEating = {
    svGluttonFindCorpse = function()
        scanCalls = scanCalls + 1
        if not corpseAvailable then return nil, nil end
        return corpseAvailable.body, corpseAvailable.sq
    end,
    svSetEatingIntent   = function() end,
    svClearEatingIntent = function() end,
    svRestoreAI         = function() end,
    svFinalizeEater     = function() end,
    svCorpseStillThere  = function() return corpsePresent end,
    setGluttonState     = function(tbl) injectedState = tbl end,
    svCancelEaterState  = function(_, state)
        state.phase        = "idle"
        state.targetCorpse = nil
        state.targetSq     = nil
        state.seekDue      = nil
    end,
}

-- Recording require: the file dereferences RQSvEating at FILE SCOPE, so it
-- must DECLARE that dependency rather than inherit it from whoever loaded it
-- first. On 2026-08-24 the alphabetical walk pulled this file in via RQMcCoy
-- before RQSvEating existed and the tail injection died for the whole session;
-- the assertion below fails if the require line is ever removed again.
local demanded = {}
function require(name)
    demanded[name] = true
    if name ~= "RQSvEating" then
        error("unexpected fixture require: " .. tostring(name))
    end
end

RQSvGlutton = nil
local ok, err = pcall(dofile, SOURCE)
check(ok, "module loads: " .. tostring(err))
check(demanded["RQSvEating"] == true,
    "the file declares its RQSvEating dependency - load order is not a contract")
check(injectedState ~= nil and injectedState == RQSvGlutton.state,
    "the eating engine received this module's state table at load")

local function makeZombie(id)
    return {
        getOnlineID  = function() return id end,
        getModData   = function() return {} end,
        getHealth    = function() return 2.0 end,
        getX = function() return 100 end,
        getY = function() return 200 end,
        getZ = function() return 0 end,
        clearAggroList = function() end,
        setTarget      = function() end,
    }
end

local square = { getX = function() return 105 end,
                 getY = function() return 200 end,
                 getZ = function() return 0 end }

-- ---------------------------------------------------------------------------
-- The throttle
-- ---------------------------------------------------------------------------
local z = makeZombie(11)

-- No corpse in range: sixty ticks of one game-second must not buy sixty scans.
now, scanCalls, corpseAvailable = 1000, 0, nil
for _ = 1, 60 do
    RQSvGlutton.tick(z)
    now = now + 16          -- ~60 Hz
end
check(scanCalls > 0, "an idle Glutton scans at least once across a second")
check(scanCalls <= 3,
    "an idle Glutton no longer scans once per tick: " .. scanCalls .. " scans in ~1s")

-- The first tick of a fresh state row scans immediately rather than waiting out
-- an interval - a Glutton that has just spawned beside a body should not stand
-- there for half a second first.
now, scanCalls = 50000, 0
RQSvGlutton.state[12] = nil
RQSvGlutton.tick(makeZombie(12))
check(scanCalls == 1, "a Glutton's very first tick scans immediately")

-- ---------------------------------------------------------------------------
-- Acquisition still works - the regression the throttle could have caused
-- ---------------------------------------------------------------------------
now = 100000
RQSvGlutton.state[13] = nil
local z13 = makeZombie(13)
corpseAvailable = { body = { id = "corpse-a" }, sq = square }
scanCalls = 0
RQSvGlutton.tick(z13)
local st = RQSvGlutton.state[13]
check(st.phase == "seeking", "a throttled scan still acquires a corpse it can see")
check(st.targetCorpse == corpseAvailable.body, "the acquired corpse is carried into state")
check(st.targetSq == square, "the acquired square is carried into state")
check(st.seekDue and st.seekDue > now, "acquisition arms the seek timeout")

-- Once seeking, the scan stops entirely - the walk is the owning client's job,
-- and re-scanning would be work for a decision already made.
scanCalls = 0
for _ = 1, 30 do
    now = now + 100
    RQSvGlutton.tick(z13)
end
check(scanCalls == 0, "a seeking Glutton does not scan again while it walks")
check(st.phase == "seeking", "a seeking Glutton stays seeking while its corpse survives")

-- A corpse taken by someone else cancels the seek, and the Glutton returns to
-- scanning. This is the path that must not stall: if cancellation left the row
-- stamped, the Glutton would idle without ever looking again.
corpsePresent = false
now = now + 100
RQSvGlutton.tick(z13)
check(st.phase == "idle", "a vanished corpse returns the Glutton to idle")
corpsePresent = true
corpseAvailable = { body = { id = "corpse-b" }, sq = square }
scanCalls = 0
now = now + 600
RQSvGlutton.tick(z13)
check(scanCalls == 1, "a cancelled Glutton scans again on the next due pass")
check(st.phase == "seeking", "and re-acquires")

-- ---------------------------------------------------------------------------
-- The cap short-circuits before the scan, not after
-- ---------------------------------------------------------------------------
-- A fully-fed Glutton must cost nothing at all. The cap test is free; the scan
-- is not, so the order of those two matters.
RQSvGlutton.state[14] = nil
local z14 = makeZombie(14)
now = 200000
RQSvGlutton.tick(z14)                      -- create the row
RQSvGlutton.state[14].totalMultGain = 10   -- well past gluttonMaxMult
scanCalls = 0
for _ = 1, 20 do
    now = now + 600                        -- every one of these would be due
    RQSvGlutton.tick(z14)
end
check(scanCalls == 0, "a capped Glutton never reaches the scan")

print(string.format("RQSvGlutton: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
