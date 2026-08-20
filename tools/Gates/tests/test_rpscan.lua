-- test_rpscan.lua - Reaper's scan scheduler: cadence, stagger, and bounded walk.
--
-- WHY THIS EXISTS: the scans used to hang off EveryOneMinute and run all three
-- back to back in one handler. EveryOneMinute is IN-GAME time (GameTime fires
-- it off minutesStamp = worldAgeHours*60 + getMinutes()), so Day Length scaled
-- it: at Day Length 5 a "5 minute" bloom interval fired a triple O(N) walk of
-- the entire loaded population every 25 REAL seconds - and N is unbounded
-- precisely because this mod exists to let you turn the vanilla cull off. The
-- two settings fed each other, and the result read as engine stutter.
--
-- WHAT IT PINS:
--   * the scheduler is driven by the WALL CLOCK, not ticks and not game time.
--     Ticking twenty thousand times with the clock frozen must do no work.
--   * EveryOneMinute is never subscribed. This is the regression that matters:
--     re-adding that hook silently restores Day Length compression.
--   * the three bloom scans are STAGGERED - one per interval/3 slot, never a
--     burst of three, and never two in flight at once.
--   * a scan's per-tick cost is BOUNDED by ScanBudget. A scan is a resumable
--     job with a cursor, not a function call that runs to completion.
--   * detection still works after all that - a real bloom is still culled.
--   * spreading a walk across ticks means the live zombie list can shift a
--     zombie back past the cursor. Two copies of one zombie in a bucket look
--     exactly like a twin pair, so the pass dedupes by OnlineID. Without that
--     guard the fix would invent blooms out of its own re-reads.
--
-- Usage (normally via tools\run-tests.bat):
--   lua5.1.exe tools/tests/test_rpscan.lua <repo-root>

local ROOT = arg[1] or "."
local SRC  = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDReaper/42/media/lua/server/RPCore.lua"

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
local function ok(name, cond, detail)
    if cond then pass = pass + 1
    else
        fail = fail + 1
        print("FAIL " .. name)
        if detail then print("  " .. tostring(detail)) end
    end
end

-- ---------------------------------------------------------------------------
-- Engine stubs
-- ---------------------------------------------------------------------------

local nowMs      = 1000000       -- the wall clock, under test control
local idCalls    = 0             -- zombie inspections; the cost we are bounding
local countCalls = true          -- muted while the test itself walks the list

local EMPTY_ITEMS = { size = function() return 0 end, get = function() return nil end }
local EMPTY_INV   = { getItems = function() return EMPTY_ITEMS end }

-- Declared before makeZombie on purpose: removeFromWorld below closes over
-- this upvalue, and a `local` introduced afterwards would leave it binding the
-- (nil) global instead - an error that cullZombie's pcall would swallow whole.
local zombies    = {}
local onTickFn   = nil
local subscribed = {}

local function makeZombie(id, x, y, z, outfit)
    return {
        getOnlineID = function(self)
            if countCalls then idCalls = idCalls + 1 end
            return id
        end,
        getSquare = function(self)
            return {
                getX = function() return x end,
                getY = function() return y end,
                getZ = function() return z end,
            }
        end,
        getPersistentOutfitID = function(self) return outfit end,
        getInventory          = function(self) return EMPTY_INV end,
        getModData            = function(self) return {} end,
        removeFromSquare      = function(self) end,
        -- Real removal, so the list genuinely shifts under an in-flight scan.
        -- That is the condition the OnlineID dedupe guard exists for; a stub
        -- that only pretended to remove would never exercise it.
        removeFromWorld       = function(self)
            for i = 1, #zombies do
                if zombies[i] == self then table.remove(zombies, i); break end
            end
        end,
        getCell               = function(self) return nil end,
    }
end

local function installEngine(sandbox)
    zombies = {}
    onTickFn = nil
    subscribed = {}

    isServer       = function() return true end
    getTimestampMs = function() return nowMs end
    SandboxVars    = { RFTDReaper = sandbox }

    local zlist = {
        size = function(self) return #zombies end,
        -- Java list semantics: 0-based.
        get  = function(self, i) return zombies[i + 1] end,
    }
    getCell = function() return { getZombieList = function(self) return zlist end } end

    local function fakeEvent(name)
        return { Add = function(fn) subscribed[name] = fn end }
    end
    Events = {
        OnTick          = fakeEvent("OnTick"),
        EveryOneMinute  = fakeEvent("EveryOneMinute"),
        OnZombieCreate  = fakeEvent("OnZombieCreate"),
    }
end

-- Fresh module state per scenario: RPCore keeps everything in file-local
-- upvalues, so a reload is the only honest reset.
local function loadCore(sandbox)
    installEngine(sandbox)
    RPCore = nil
    local okLoad, err = pcall(dofile, SRC)
    if not okLoad then
        print("FATAL: could not load " .. SRC)
        print("  " .. tostring(err))
        os.exit(2)
    end
    onTickFn = subscribed.OnTick
    if type(onTickFn) ~= "function" then
        print("FAIL RPCore did not subscribe OnTick - the scheduler is unreachable")
        os.exit(1)
    end
end

-- Drive n ticks, advancing the wall clock by dtMs each. Returns the largest
-- number of zombie inspections any single tick spent.
local function run(n, dtMs)
    local peak = 0
    for _ = 1, n do
        nowMs = nowMs + (dtMs or 0)
        idCalls = 0
        onTickFn(0)
        if idCalls > peak then peak = idCalls end
    end
    return peak
end

local function snap()
    countCalls = false
    local s = RPCore.snapshot({ includeClean = false })
    countCalls = true
    return s
end

local BASE = {
    Enabled = true, CullEnabled = true, LogCulls = false,
    SequentialThreshold = 2, StackThreshold = 5,
    BloomInterval = 5,      -- real minutes per full rotation -> 100s slots
    SweepInterval = 2,
    ScanBudget = 200,
    MaxRemovalsPerScan = 500, CullsPerTick = 15,
    OutfitIdGap = 15, OutfitMinCluster = 3, OutfitProximity = 75,
}
local function sandbox(over)
    local t = {}
    for k, v in pairs(BASE) do t[k] = v end
    for k, v in pairs(over or {}) do t[k] = v end
    return t
end

local SLOT_MS = 100000   -- BloomInterval 5 -> 5*60000/3

-- ---------------------------------------------------------------------------
-- 1. The clock is the wall clock. Not ticks, not game time.
-- ---------------------------------------------------------------------------

loadCore(sandbox())
for i = 1, 1000 do
    zombies[i] = makeZombie(10000 + i, i * 40, i * 40, 0, 7000 + i)
end

eq("EveryOneMinute is not subscribed", subscribed.EveryOneMinute, nil)
eq("OnZombieCreate is still subscribed", type(subscribed.OnZombieCreate), "function")

-- 20,000 ticks with the clock frozen. Under the old tick/game-time cadence
-- this was minutes of scanning; under a wall clock it is nothing at all.
local peakFrozen = run(20000, 0)
eq("frozen clock does no scan work", peakFrozen, 0)
eq("frozen clock leaves the scanner idle", snap().stats.scan, "idle")

-- ---------------------------------------------------------------------------
-- 2. The per-tick walk is bounded by ScanBudget.
-- ---------------------------------------------------------------------------

-- Cross the bootstrap deadline, then let the sweep run to completion one
-- budgeted step at a time. 1000 zombies at 200/tick cannot be one tick's work.
local peakSweep = run(1, 8000)
local p = run(40, 0)
if p > peakSweep then peakSweep = p end

ok("sweep walk is bounded by ScanBudget",
   peakSweep > 0 and peakSweep <= 260,
   "peak inspections in one tick = " .. tostring(peakSweep) .. " (budget 200, population 1000)")

-- The population really was walked, not skipped: every id is now known, so a
-- snapshot reports the full loaded count.
eq("sweep saw the whole population", snap().loaded, 1000)

-- ---------------------------------------------------------------------------
-- 3. The three bloom scans are staggered, one per slot, never overlapping.
-- ---------------------------------------------------------------------------

local seen, order = {}, {}
local peakBloom = 0
for slot = 1, 3 do
    -- Cross one slot boundary, then let that scan finish.
    local first = run(1, SLOT_MS + 1)
    if first > peakBloom then peakBloom = first end
    local active = snap().stats.scan
    if active ~= "idle" and not seen[active] then
        seen[active] = true
        order[#order + 1] = active
    end
    local rest = run(40, 0)
    if rest > peakBloom then peakBloom = rest end
    eq("slot " .. slot .. " scan retired", snap().stats.scan, "idle")
end

eq("one distinct scan per slot", #order, 3)
ok("rotation covered all three bloom scans",
   seen.bloom and seen.wander and seen.cluster,
   "observed: " .. table.concat(order, ", "))
ok("bloom walk is bounded by ScanBudget",
   peakBloom <= 260,
   "peak inspections in one tick = " .. tostring(peakBloom))

-- ---------------------------------------------------------------------------
-- 4. Detection survives the rewrite - a real bloom is still culled.
-- ---------------------------------------------------------------------------

loadCore(sandbox())
-- Six template-clones: one tile, one outfit, consecutive OnlineIDs.
for i = 1, 6 do
    zombies[i] = makeZombie(500 + i, 120, 340, 0, 4242)
end
-- Plus honest neighbours elsewhere, so "cull everything" would also fail.
for i = 7, 20 do
    zombies[i] = makeZombie(9000 + i, i * 60, i * 77, 0, 5000 + i)
end

run(1, 8000)      -- bootstrap sweep
run(60, 0)
run(1, SLOT_MS + 1)   -- first bloom slot: tile+outfit scan
run(60, 0)

local s = snap()
eq("bloom of 6 culled down to 1", s.stats.culled, 5)
eq("cull queue drained", s.stats.queued, 0)
eq("honest neighbours survive", s.loaded, 15)

-- ---------------------------------------------------------------------------
-- 5. A revisited zombie is not a twin.
--
-- An incremental walk reads a live list. A removal shifts the tail down, so
-- one zombie can land under the cursor twice. Five reads of ONE zombie make a
-- bucket of five identical ids - gap 0, well inside SequentialThreshold, and
-- over StackThreshold - which both cull rules would happily convict.
-- ---------------------------------------------------------------------------

loadCore(sandbox())
local ghost = makeZombie(777, 200, 200, 0, 8888)
for i = 1, 5 do zombies[i] = ghost end
zombies[6] = makeZombie(4321, 900, 900, 0, 1234)

run(1, 8000)
run(60, 0)
run(1, SLOT_MS + 1)
run(60, 0)
run(1, SLOT_MS + 1)
run(60, 0)
run(1, SLOT_MS + 1)
run(60, 0)

eq("re-read of one zombie is not convicted as a bloom", snap().stats.culled, 0)

-- ---------------------------------------------------------------------------
-- 6. forceScan requests the rotation; it does not buy a synchronous triple walk.
-- ---------------------------------------------------------------------------

loadCore(sandbox())
for i = 1, 600 do
    zombies[i] = makeZombie(20000 + i, i * 31, i * 53, 0, 6000 + i)
end
run(1, 8000)
run(40, 0)

eq("forceScan queues all three", RPCore.forceScan(), 3)
eq("forceScan queues each kind once", RPCore.forceScan(), 0)

local peakForced = run(60, 0)
ok("forced scans stay budgeted",
   peakForced <= 260,
   "peak inspections in one tick = " .. tostring(peakForced))
eq("forced rotation completed", snap().stats.scan, "idle")

-- ---------------------------------------------------------------------------

print(string.format("RPCore scan scheduler: %d passed, %d failed", pass, fail))
os.exit(fail > 0 and 1 or 0)
