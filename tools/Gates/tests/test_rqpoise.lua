-- RQPoise fixture - a tank absorbs a rolled number of staggers, then powers
-- through for a rolled window.
--
-- WHY THIS FILE EXISTS. A .45 kept a Boss staggered for an entire encounter
-- (owner, 2026-08-24). This file covers the POLICY - when a tank should stop
-- caring about being shot. The mechanism that makes it true lives in RQFlinch
-- and is covered by test_rqflinch.
--
-- Three things are most likely to go wrong here, and all three are pinned:
--   1. EDGE-TRIGGERING. A reaction persists for its whole animation, so a
--      naive counter burns a cycle per FRAME instead of per bullet.
--   2. THE GUNFIRE PATH. A bullet sets a hit reaction and never touches
--      staggerBack; the first shipped version watched only the stagger flag
--      and did nothing at all.
--   3. HANDING THE FLINCH BACK. Suppression latches now, so forgetting to
--      clear it leaves a tank permanently unflinchable - a failure the old
--      one-shot flag clear could not have.

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

-- The mechanism, recorded rather than simulated. RQPoise's job is to decide
-- WHEN a zombie should stop caring about being shot; RQFlinch's job is to make
-- that true. This fixture asserts the decision, and test_rqflinch covers the
-- mechanism separately.
local flinchCalls = {}
RQFlinch = {
    set = function(zombie, on)
        flinchCalls[#flinchCalls + 1] = { zombie = zombie, on = on }
        zombie.flinchSuppressed = on
        return true
    end,
}
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
    local known = { RQCommon = true, RQDirgeLog = true, RQRegistry = true,
                    RQReconcile = true, RQFlinch = true }
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
        staggered = false, reaction = "",
        flinchSuppressed = nil,
        getOnlineID  = function(self) return self.id end,
        isDead       = function() return false end,
        isRemoteZombie = function() return false end,
        isStaggerBack  = function(self) return self.staggered end,
        -- No setStaggerBack/setKnockedDown/setStateEventDelayTimer: poise no
        -- longer writes engine flags at all. If a future change reintroduces
        -- one, this fixture throws rather than silently passing.
        -- The gunfire path. CombatManager sets EITHER a named hit reaction OR
        -- staggerBack, never both (:2410-2417); a bullet always takes the
        -- reaction branch, which is why the first version of this feature -
        -- watching staggerBack alone - did nothing against a .45.
        getHitReaction = function(self) return self.reaction end,
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
-- should be immune now and RQFlinch asked to suppress.
check(RQPoise.stats.broken == 1, "reaching the threshold breaks poise exactly once")
check(z1.flinchSuppressed == true, "breaking poise asks RQFlinch to suppress")

-- LATCHING, not per-frame. The old mechanism cleared a flag every pass; the
-- variable RQFlinch sets stays true until cleared, so re-asserting it each
-- frame would be pure waste. One write in, one write out.
local callsAfterBreak = #flinchCalls
local absorbedBefore = RQPoise.stats.absorbed
z1.staggered = true
RQPoise.update(z1, nowMs + 1000)
RQPoise.update(z1, nowMs + 1100)
check(#flinchCalls == callsAfterBreak,
    "suppression is not re-written on every frame of the window")
check(z1.flinchSuppressed == true, "and it stays suppressed throughout")
check(RQPoise.stats.absorbed == absorbedBefore,
    "a stagger during immunity is not counted against the next cycle")

-- Immunity is 5000ms at the low roll; at 5001 it is over. The distinction that
-- matters is COUNTED vs SCRUBBED: a stagger inside the window is discarded
-- without touching the counter, one outside it is processed. The flag ends up
-- false either way here, because a Boss at the low roll of 1 breaks poise again
-- on that very stagger - which is the profile working, not a failure.
-- Immunity is 5000ms at the low roll. Expiry must HAND THE FLINCH BACK - the
-- half a one-shot flag clear never needed, and the way a latching variable
-- leaves a tank permanently unflinchable if it is forgotten.
local brokenAtExpiry = RQPoise.stats.broken
z1.staggered = false
RQPoise.update(z1, nowMs + 5001)
check(z1.flinchSuppressed == false,
    "the window expiring returns the zombie to normal flinching")

z1.staggered = true
RQPoise.update(z1, nowMs + 5002)
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
check(z3.flinchSuppressed == nil, "a passive Scavenger is never suppressed")
check(RQPoise.poise[z3] == nil, "and it carries no poise state at all")

RQReconcile.scavClientState[3] = { enraged = true }
local absorbed2 = RQPoise.stats.absorbed
z3.staggered = false
RQPoise.update(z3, nowMs)
z3.staggered = true
RQPoise.update(z3, nowMs)
check(RQPoise.stats.absorbed == absorbed2 + 1, "an ENRAGED Scavenger absorbs staggers")

-- ---------------------------------------------------------------------------
-- THE GUNFIRE PATH - the regression that shipped once already
-- ---------------------------------------------------------------------------
-- A bullet never sets staggerBack. CombatManager resolves it to a named
-- HitReaction and takes the other branch entirely, so a poise implementation
-- watching only staggerBack counts nothing, breaks never, and logs nothing -
-- which is exactly what a .45 demonstrated on Mosaic. These assertions fail if
-- anyone narrows the check back to the stagger flag.
types[7] = "Boss"
local z7 = makeZombie(7)
local absorbedGun = RQPoise.stats.absorbed
local brokenGun   = RQPoise.stats.broken

z7.staggered = false            -- exactly as a gunshot leaves it
z7.reaction  = "HitReactionF"   -- a named directional reaction
RQPoise.update(z7, nowMs)
check(RQPoise.stats.absorbed == absorbedGun + 1,
    "a hit reaction with NO staggerBack still counts as a hit")
check(RQPoise.stats.broken == brokenGun + 1,
    "and a Boss at threshold one breaks poise on it")
check(z7.flinchSuppressed == true,
    "a gunshot with no staggerBack still drives poise to suppress")

-- A nil reaction must read as "not reacting" rather than throwing.
local z8 = makeZombie(8)
types[8] = "Boss"
z8.reaction = nil
local absorbedNil = RQPoise.stats.absorbed
RQPoise.update(z8, nowMs)
check(RQPoise.stats.absorbed == absorbedNil,
    "a nil hit reaction is not a hit")

-- ---------------------------------------------------------------------------
-- Types that are not tanks are untouched
-- ---------------------------------------------------------------------------
types[4] = "Glutton"
local z4 = makeZombie(4)
z4.staggered = true
RQPoise.update(z4, nowMs)
check(z4.flinchSuppressed == nil, "a Glutton is never suppressed - it is not a tank")

types[5] = nil
local z5 = makeZombie(5)
z5.staggered = true
RQPoise.update(z5, nowMs)
check(z5.flinchSuppressed == nil, "an ordinary zombie is untouched")

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
check(z6.flinchSuppressed == nil, "a zombie this client does not own is left to its owner")

print(string.format("RQPoise: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
