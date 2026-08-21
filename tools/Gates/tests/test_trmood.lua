-- test_trmood.lua - behavioural tests for Triage/TRMood under Lua 5.1.
--
-- WHAT THIS PINS. Three properties, each silent in play if it regresses:
--  1. The step gate: UNHAPPINESS moves of 2+ log with their co-deltas, and
--     the "em-proc" fingerprint fires only for the co-movement shape that
--     Expanded Moodles' proc block produces (unhappiness AND stress up, with
--     wetness or anger moving too - EM_Core.lua:711-717). A false fingerprint
--     sends the hunt at the wrong mod.
--  2. The ExpandedMoodles.addStat wrap: binds once, logs watched stats for
--     players only, and passes every call through UNCHANGED - arguments and
--     return value. The wrap observing must never become the wrap behaving.
--  3. The dial: off means no rows anywhere, and the wrap does not bind while
--     off (nothing invasive installs while the instrument is disabled).
--
-- Usage (normally via tools\Gates\run-tests.bat):
--   lua5.1.exe tools/Gates/tests/test_trmood.lua <repo-root>

local ROOT = arg[1] or "."
local SRC  = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDOddsAndEnds"
             .. "/42/media/lua/server/Triage/TRMood.lua"

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

require  = function() end
isServer = function() return true end

instanceof = function(obj, cls)
    return type(obj) == "table" and obj.__cls == cls
end

local enabled = true
OEShared = {
    enabled = function(flag) return enabled end,
}

local rows = {}
RDLog = {
    forensic = function(stream, evt, subj, payload, modId)
        rows[#rows + 1] = { stream = stream, evt = evt, subj = subj,
                            payload = payload, modId = modId }
    end,
}

local minuteHandler
Events = {
    EveryOneMinute = { Add = function(fn) minuteHandler = fn end },
}

CharacterStat = {
    UNHAPPINESS = "UNHAPPINESS", STRESS = "STRESS", ANGER = "ANGER",
    INTOXICATION = "INTOXICATION", BOREDOM = "BOREDOM", WETNESS = "WETNESS",
}

local function mkPlayer(name)
    local p = { __cls = "IsoPlayer", user = name, dead = false,
                stat = { UNHAPPINESS = 0, STRESS = 0, ANGER = 0,
                         INTOXICATION = 0, BOREDOM = 0, WETNESS = 0 } }
    p.getUsername = function(self) return self.user end
    p.isDead      = function(self) return self.dead end
    p.getStats    = function(self)
        return { get = function(_, key) return p.stat[key] end }
    end
    return p
end

local online = {}
getOnlinePlayers = function()
    return {
        size = function() return #online end,
        get  = function(_, i) return online[i + 1] end,
    }
end

dofile(SRC)

ok("minute handler registered", minuteHandler ~= nil)

-- ---------------------------------------------------------------------------
-- Step gate and fingerprint
-- ---------------------------------------------------------------------------

local mox = mkPlayer("Mox")
online = { mox }

minuteHandler()                          -- baseline
eq("baseline emits nothing", #rows, 0)

-- EM proc shape: unhappiness + stress + wetness all step together
mox.stat.UNHAPPINESS = 8
mox.stat.STRESS = 0.4
mox.stat.WETNESS = 4
minuteHandler()
eq("co-movement logs", rows[1] and rows[1].evt, "TR.MOOD_STEP")
eq("fingerprint tagged", rows[1].payload.shape, "em-proc")
eq("delta recorded", rows[1].payload.du, "8.00")

-- lone unhappiness step: no co-movement, no fingerprint
rows = {}
mox.stat.UNHAPPINESS = 13
minuteHandler()
eq("lone step logs", rows[1] and rows[1].evt, "TR.MOOD_STEP")
eq("lone step not fingerprinted", rows[1].payload.shape, "-")

-- relief steps log too (what HELPED is also attribution)
rows = {}
mox.stat.UNHAPPINESS = 10
minuteHandler()
eq("negative step logs", rows[1] and rows[1].evt, "TR.MOOD_STEP")
eq("negative delta", rows[1].payload.du, "-3.00")

-- sub-threshold movement stays quiet
rows = {}
mox.stat.UNHAPPINESS = 11
minuteHandler()
eq("small step stays quiet", #rows, 0)

-- ---------------------------------------------------------------------------
-- ExpandedMoodles.addStat wrap
-- ---------------------------------------------------------------------------

local emCalls = {}
ExpandedMoodles = {
    addStat = function(player, stats, bodyDamage, key, amount)
        emCalls[#emCalls + 1] = { key = key, amount = amount }
        return "em-return"
    end,
}

rows = {}
minuteHandler()                          -- first enabled tick binds the wrap
ok("wrap installed", ExpandedMoodles.addStat ~= nil)

local ret = ExpandedMoodles.addStat(mox, nil, nil, "UNHAPPINESS", 7.25)
eq("watched stat logs", rows[#rows] and rows[#rows].evt, "TR.EM_WRITE")
eq("stat named", rows[#rows].payload.stat, "UNHAPPINESS")
eq("amount recorded", rows[#rows].payload.amount, "7.2500")
eq("call passed through", emCalls[1] and emCalls[1].key, "UNHAPPINESS")
eq("amount passed through", emCalls[1] and emCalls[1].amount, 7.25)
eq("return passed through", ret, "em-return")

rows = {}
ExpandedMoodles.addStat(mox, nil, nil, "FATIGUE", 0.5)
eq("unwatched stat silent", #rows, 0)
eq("unwatched call still passes through", emCalls[2] and emCalls[2].key, "FATIGUE")

rows = {}
local zed = { __cls = "IsoZombie" }
ExpandedMoodles.addStat(zed, nil, nil, "UNHAPPINESS", 3)
eq("non-player silent", #rows, 0)
eq("non-player call still passes through", emCalls[3] and emCalls[3].key, "UNHAPPINESS")

-- rebinding must not stack wrappers: a stacked wrap would log one row per
-- layer for a watched stat, so a second tick then one call must yield
-- exactly one row and one pass-through
local before = #emCalls
minuteHandler()
rows = {}
ExpandedMoodles.addStat(mox, nil, nil, "STRESS", 1)
eq("wrap binds once (pass-through)", #emCalls, before + 1)
eq("wrap binds once (single row)", #rows, 1)

-- ---------------------------------------------------------------------------
-- The dial
-- ---------------------------------------------------------------------------

enabled = false
rows = {}
mox.stat.UNHAPPINESS = 40
minuteHandler()
eq("dial off: no mood rows", #rows, 0)
ExpandedMoodles.addStat(mox, nil, nil, "UNHAPPINESS", 5)
eq("dial off: wrap logs nothing", #rows, 0)
ok("dial off: wrap still passes through",
   emCalls[#emCalls] and emCalls[#emCalls].amount == 5)
enabled = true

-- a fresh module load with the dial off must not bind the wrap at all
local freshEmCalls = {}
ExpandedMoodles = {
    addStat = function(player, stats, bodyDamage, key, amount)
        freshEmCalls[#freshEmCalls + 1] = key
    end,
}
local unwrapped = ExpandedMoodles.addStat
enabled = false
dofile(SRC)                              -- re-register; new module state
minuteHandler()                          -- disabled tick: returns before wrap
eq("disabled tick leaves EM unwrapped", ExpandedMoodles.addStat, unwrapped)
enabled = true

print(string.format("test_trmood: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
