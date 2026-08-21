-- test_trdamage.lua - behavioural tests for Triage/TRDamage under Lua 5.1.
--
-- WHAT THIS PINS. TRDamage's whole value is correct attribution: a minute
-- with lane events must produce exactly one aggregated row, a health drop
-- with NO lane events must flag as unattributed with the wound-clock census,
-- and a fracture on a BoneFracture=false world must log once per fracture -
-- not once per tick, and not at all when the option is on. Every one of those
-- properties failing is silent in play (the module only writes logs), which
-- is exactly the kind of regression a test has to hold.
--
-- The stubs model the verified engine surface: OnPlayerGetDamage passes
-- (character, laneString, amount) (BodyDamage.java:1977-1992 among the
-- trigger sites); BodyPart exposes get*Time clocks (BodyPart.java:138-179);
-- getOnlinePlayers returns a size()/get() list. No stub models a throw the
-- lanes cannot deliver.
--
-- Usage (normally via tools\Gates\run-tests.bat):
--   lua5.1.exe tools/Gates/tests/test_trdamage.lua <repo-root>

local ROOT = arg[1] or "."
local SRC  = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDOddsAndEnds"
             .. "/42/media/lua/server/Triage/TRDamage.lua"

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

local damageHandler, minuteHandler
Events = {
    OnPlayerGetDamage = { Add = function(fn) damageHandler = fn end },
    EveryOneMinute    = { Add = function(fn) minuteHandler = fn end },
}

MoodleType = {
    HEAVY_LOAD = "HEAVY_LOAD", SICK = "SICK", HUNGRY = "HUNGRY",
    THIRST = "THIRST", BLEEDING = "BLEEDING",
}

BodyPartType = {
    FromIndex = function(i) return i end,
    getDisplayName = function(i) return "Part" .. tostring(i) end,
}

SandboxVars = { BoneFracture = true }

local function mkPart()
    local part = { scratchT = 0, cutT = 0, deepT = 0, biteT = 0,
                   burnT = 0, bleedT = 0, fracT = 0, splint = false }
    part.getScratchTime   = function(self) return self.scratchT end
    part.getCutTime       = function(self) return self.cutT end
    part.getDeepWoundTime = function(self) return self.deepT end
    part.getBiteTime      = function(self) return self.biteT end
    part.getBurnTime      = function(self) return self.burnT end
    part.getBleedingTime  = function(self) return self.bleedT end
    part.getFractureTime  = function(self) return self.fracT end
    part.isSplint         = function(self) return self.splint end
    return part
end

local function mkList(arr)
    return {
        size = function() return #arr end,
        get  = function(_, i) return arr[i + 1] end,
    }
end

local function mkPlayer(name, hp)
    local p = { __cls = "IsoPlayer", user = name, hp = hp, dead = false,
                moodle = {} }
    local parts = {}
    for i = 1, 21 do parts[i] = mkPart() end
    p.parts = parts
    p.bd = {
        getOverallBodyHealth = function() return p.hp end,
        getBodyParts = function() return mkList(parts) end,
    }
    p.getUsername    = function(self) return self.user end
    p.isDead         = function(self) return self.dead end
    p.getBodyDamage  = function(self) return self.bd end
    p.getMoodles     = function(self)
        return { getMoodleLevel = function(_, mt) return p.moodle[mt] or 0 end }
    end
    return p
end

local online = {}
getOnlinePlayers = function() return mkList(online) end

dofile(SRC)

ok("handlers registered", damageHandler ~= nil and minuteHandler ~= nil)

-- ---------------------------------------------------------------------------
-- Lane aggregation: three events, one row, sorted lane totals
-- ---------------------------------------------------------------------------

local mox = mkPlayer("Mox", 100)
online = { mox }

minuteHandler()                      -- baseline sample, no prev -> no row
eq("baseline minute emits nothing", #rows, 0)

damageHandler(mox, "HUNGRY", 0.1)
damageHandler(mox, "HUNGRY", 0.1)
damageHandler(mox, "SICK", 0.5)
mox.hp = 99.3
minuteHandler()
eq("one aggregated row", #rows, 1)
eq("row evt", rows[1].evt, "TR.DAMAGE_MINUTE")
eq("events counted", rows[1].payload.events, 3)
eq("lanes sorted+summed", rows[1].payload.lanes, "HUNGRY=0.200 SICK=0.500")
eq("drop recorded", rows[1].payload.drop, "0.700")

-- ---------------------------------------------------------------------------
-- Quiet minute: no events, no drop -> no row
-- ---------------------------------------------------------------------------

rows = {}
minuteHandler()
eq("quiet minute emits nothing", #rows, 0)

-- ---------------------------------------------------------------------------
-- Unattributed drop: health fell, no lane fired -> flagged with context
-- ---------------------------------------------------------------------------

rows = {}
mox.hp = 94.3
mox.moodle.HEAVY_LOAD = 4
mox.parts[3].bleedT = 6      -- a clock with no flag: the census must see it
minuteHandler()
eq("unattributed row", rows[1] and rows[1].evt, "TR.UNATTRIBUTED_DROP")
eq("heavy load context", rows[1].payload.heavyLoad, 4)
eq("clock census", rows[1].payload.clocks,
   "scr=0 cut=0 deep=0 bite=0 burn=0 bleed=1 frac=0")

-- ---------------------------------------------------------------------------
-- Healing minute with events still logs the lanes
-- ---------------------------------------------------------------------------

rows = {}
damageHandler(mox, "BLEEDING", 0.3)
mox.hp = 95.0
minuteHandler()
eq("heal minute keeps lane row", rows[1] and rows[1].evt, "TR.DAMAGE_MINUTE")
eq("negative drop reported", rows[1].payload.drop, "-0.700")

-- ---------------------------------------------------------------------------
-- Non-player characters never accumulate
-- ---------------------------------------------------------------------------

rows = {}
local zed = { __cls = "IsoZombie", getUsername = function() return "z" end }
damageHandler(zed, "FIRE", 5)
minuteHandler()
eq("zombie FIRE ignored", #rows, 0)

-- ---------------------------------------------------------------------------
-- Fracture audit: only on BoneFracture=false, once per fracture, re-arming
-- ---------------------------------------------------------------------------

rows = {}
mox.parts[5].fracT = 42
minuteHandler()
eq("fractures-on world stays silent", #rows, 0)

SandboxVars.BoneFracture = false
minuteHandler()
eq("impossible fracture flagged", rows[1] and rows[1].evt, "TR.IMPOSSIBLE_FRACTURE")
eq("part named", rows[1].payload.part, "Part4")   -- index 4, 0-based walk
eq("clock recorded", rows[1].payload.clock, "42.0")

rows = {}
minuteHandler()
eq("no duplicate row while fracture persists", #rows, 0)

mox.parts[5].fracT = 0
minuteHandler()
mox.parts[5].fracT = 30
rows = {}
minuteHandler()
eq("audit re-arms after the clock clears", rows[1] and rows[1].evt,
   "TR.IMPOSSIBLE_FRACTURE")

-- ---------------------------------------------------------------------------
-- The dial: off means silent, both handlers
-- ---------------------------------------------------------------------------

rows = {}
enabled = false
damageHandler(mox, "SICK", 1.0)
mox.hp = 80
minuteHandler()
eq("dial off emits nothing", #rows, 0)
enabled = true

print(string.format("test_trdamage: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
