-- RQPoise fixture - a tank absorbs a rolled number of staggers, then powers
-- through for a rolled window.
--
-- WHY THIS FILE EXISTS. A .45 kept a Boss staggered for an entire encounter
-- (owner, 2026-08-24). The engine clamps stagger DURATION to [20,30] whatever
-- staggerTimeMod says (StaggerBackState:58-64), so the only lever is refusing
-- to enter the state. The two things most likely to go wrong in that fix are
-- pinned below: edge-triggering (isStaggerBack stays true for the whole state,
-- so a naive counter burns a cycle per FRAME rather than per bullet) and the
-- type gate (a passive Scavenger is not a tank).

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDirge/42/media/lua/client/RQPoise.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL RQPoise: " .. message)
    end
end

function isServer() return false end
function isClient() return true end

-- Deterministic rolls: always the LOW end of any range, so thresholds are
-- exact and the assertions below say what they mean.
function ZombRand(a, b)
    if b == nil then return 0 end
    return a
end

local types = {}
RQRegistry = { getType = function(id) return types[id] end }
RQReconcile = { scavClientState = {} }
RQDirgeLog = { write = function() end }
RQCommon = { MODULE = "RFTDDirge" }

local callbacks = {}
local function event(name)
    callbacks[name] = {}
    return { Add = function(fn) callbacks[name][#callbacks[name] + 1] = fn end }
end
Events = { OnZombieUpdate = event("update"), OnGameStart = event("start") }

function require(name)
    local known = { RQCommon = true, RQDirgeLog = true, RQRegistry = true, RQReconcile = true }
    if known[name] then return end
    error("unexpected fixture require: " .. tostring(name))
end

local nowMs = 10000
function getTimestampMs() return nowMs end

RQPoise = nil
local ok, err = pcall(dofile, SOURCE)
check(ok, "module loads: " .. tostring(err))
check(#callbacks["update"] == 1, "the module registers exactly one OnZombieUpdate listener")

local function makeZombie(id)
    return {
        id = id,
        staggered = false, knocked = false, timer = 99,
        clears = 0,
        getOnlineID  = function(self) return self.id end,
        isDead       = function() return false end,
        isRemoteZombie = function() return false end,
        isStaggerBack  = function(self) return self.staggered end,
        setStaggerBack = function(self, v)
            self.staggered = v
            if v == false then self.clears = self.clears + 1 end
        end,
        setKnockedDown = function(self, v) self.knocked = v end,
        setStateEventDelayTimer = function(self, v) self.timer = v end,
    }
end

-- ---------------------------------------------------------------------------
-- Edge triggering
-- ---------------------------------------------------------------------------
-- isStaggerBack() stays true for the 20-30 the state runs. If poise counted
-- every frame, one bullet would consume a whole Boss cycle and the feature
-- would do nothing at all.
types[1] = "Boss"
local z1 = makeZombie(1)
z1.staggered = true
for _ = 1, 20 do RQPoise.update(z1, nowMs) end     -- one stagger, held 20 frames
check(RQPoise.stats.absorbed == 1,
    "a stagger held across many frames counts ONCE: " .. RQPoise.stats.absorbed)

-- ---------------------------------------------------------------------------
-- Boss: low roll is 1 stagger, then 5000ms immune
-- ---------------------------------------------------------------------------
-- The first stagger above already met the Boss threshold of 1, so the zombie
-- should be immune now and the flags scrubbed.
check(RQPoise.stats.broken == 1, "reaching the threshold breaks poise exactly once")
check(z1.staggered == false, "the stagger flag is cleared when poise breaks")
check(z1.knocked == false, "the knockdown flag is cleared with it")
check(z1.timer == 0.0, "an in-progress stagger is retired via the state timer")

-- While immune, further staggers are scrubbed and never counted.
local absorbedBefore = RQPoise.stats.absorbed
z1.staggered = true
RQPoise.update(z1, nowMs + 1000)
check(z1.staggered == false, "a stagger during immunity is cleared")
check(RQPoise.stats.absorbed == absorbedBefore,
    "a stagger during immunity is not counted against the next cycle")

-- Immunity is 5000ms at the low roll; at 5001 it is over. The distinction that
-- matters is COUNTED vs SCRUBBED: a stagger inside the window is discarded
-- without touching the counter, one outside it is processed. The flag ends up
-- false either way here, because a Boss at the low roll of 1 breaks poise again
-- on that very stagger - which is the profile working, not a failure.
local brokenAtExpiry = RQPoise.stats.broken
z1.staggered = true
RQPoise.update(z1, nowMs + 5001)
check(RQPoise.stats.absorbed == absorbedBefore + 1,
    "once the window expires a stagger is processed rather than scrubbed")
check(RQPoise.stats.broken == brokenAtExpiry + 1,
    "and at a threshold of one, that stagger immediately opens the next window")

-- ---------------------------------------------------------------------------
-- Juggernaut takes more hits to break
-- ---------------------------------------------------------------------------
types[2] = "Juggernaut"
local z2 = makeZombie(2)
local brokenBefore = RQPoise.stats.broken
for i = 1, 2 do                      -- low roll for Juggernaut is 2 staggers
    z2.staggered = true
    RQPoise.update(z2, nowMs + i)
    z2.staggered = false
    RQPoise.update(z2, nowMs + i)    -- falling edge, so the next one is new
end
check(RQPoise.stats.broken == brokenBefore + 1,
    "a Juggernaut breaks poise on its second stagger, not its first")
check(RQPoise.stats.byType["Juggernaut"] == 1, "the break is attributed to the type")

-- ---------------------------------------------------------------------------
-- A passive Scavenger is NOT a tank
-- ---------------------------------------------------------------------------
-- Same rule as Bulwark: rage is what armours a Scavenger. A passive one takes
-- full damage and full stagger, which is the sleeper-threat design.
types[3] = "Scavenger"
local z3 = makeZombie(3)
RQReconcile.scavClientState[3] = { enraged = false }
z3.staggered = true
RQPoise.update(z3, nowMs)
check(z3.staggered == true, "a passive Scavenger's stagger is left alone")
check(RQPoise.poise[z3] == nil, "and it carries no poise state at all")

RQReconcile.scavClientState[3] = { enraged = true }
local absorbed2 = RQPoise.stats.absorbed
z3.staggered = false
RQPoise.update(z3, nowMs)
z3.staggered = true
RQPoise.update(z3, nowMs)
check(RQPoise.stats.absorbed == absorbed2 + 1, "an ENRAGED Scavenger absorbs staggers")

-- ---------------------------------------------------------------------------
-- Types that are not tanks are untouched
-- ---------------------------------------------------------------------------
types[4] = "Glutton"
local z4 = makeZombie(4)
z4.staggered = true
RQPoise.update(z4, nowMs)
check(z4.staggered == true, "a Glutton is staggerable - it is not a tank")

types[5] = nil
local z5 = makeZombie(5)
z5.staggered = true
RQPoise.update(z5, nowMs)
check(z5.staggered == true, "an ordinary zombie is untouched")

-- ---------------------------------------------------------------------------
-- Ownership
-- ---------------------------------------------------------------------------
-- Poise must be a single-authority decision; every client rolling its own
-- threshold would break the same zombie at different moments.
types[6] = "Boss"
local z6 = makeZombie(6)
z6.isRemoteZombie = function() return true end
z6.staggered = true
RQPoise.update(z6, nowMs)
check(z6.staggered == true, "a zombie this client does not own is left to its owner")

print(string.format("RQPoise: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
