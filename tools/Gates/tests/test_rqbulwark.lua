-- RQBulwark fixture - who is protected, by how much, and what a roll means.
--
-- The policy half of this module is pure on purpose: rateFor and decide take
-- everything they need as arguments, including the roll, so the boundaries can
-- be pinned exactly rather than sampled. That seam is a PARAMETER and not a
-- swappable global - production randomness stays un-replaceable, so nothing can
-- reach in at runtime and make every Boss invulnerable.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDirge/42/media/lua/server/RQBulwark.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL RQBulwark: " .. message)
    end
end

function isServer() return true end

local nextRoll = 0
function ZombRand(n) return nextRoll % n end

local debugMode = false
RQSvShared = { getSvConfig = function() return { debugMode = debugMode } end }
RQDirgeLog = { write = function() end }
RQCommon = { MODULE = "RFTDDirge" }
local enragedAnswer = false
RQSvScavenger = { isEnraged = function() return enragedAnswer end }

function require(name)
    local known = { RQCommon = true, RQDirgeLog = true, RQSvShared = true, RQSvScavenger = true }
    if known[name] then return end
    error("unexpected fixture require: " .. tostring(name))
end

RQBulwark = nil
local ok, err = pcall(dofile, SOURCE)
check(ok, "module loads: " .. tostring(err))

-- ---------------------------------------------------------------------------
-- rateFor - who is protected at all
-- ---------------------------------------------------------------------------
local function rate(t, ranged, enraged) return (RQBulwark.rateFor(t, ranged, enraged)) end
local function why(t, ranged, enraged) local _, w = RQBulwark.rateFor(t, ranged, enraged); return w end

check(rate("Boss", true) == 70 and rate("Boss", false) == 35, "Boss soaks 70/35")
check(rate("Juggernaut", true) == 60 and rate("Juggernaut", false) == 30, "Juggernaut soaks 60/30")
check(rate("Scavenger", true, true) == 50 and rate("Scavenger", false, true) == 25,
    "an enraged Scavenger soaks 50/25")

-- Ranged is worth more than melee everywhere. This is the whole point of the
-- table: a player outside melee reach is taking no risk in return.
for _, t in ipairs({ "Boss", "Juggernaut" }) do
    check(rate(t, true) > rate(t, false), t .. " protects harder against ranged than melee")
end
check(rate("Scavenger", true, true) > rate("Scavenger", false, true),
    "Scavenger protects harder against ranged than melee")

-- The three types NOT in the table get nothing, by name.
for _, t in ipairs({ "Screamer", "EMP", "Glutton" }) do
    check(rate(t, true) == nil, t .. " is not self-protected")
    check(why(t, true) == "not-protected-type", t .. "'s refusal is named")
end
check(rate("Juggernaut", true, false) == 60,
    "the enraged flag is ignored for types where it means nothing")
check(rate(nil, true) == nil and why(nil, true) == "not-protected-type",
    "an unknown type is refused rather than defaulting to protected")

-- A PASSIVE Scavenger is not armoured. It is eating; rage is what makes it a
-- threat, and rage is something the player caused.
check(rate("Scavenger", true, false) == nil, "a passive Scavenger is not protected")
check(why("Scavenger", true, false) == "scavenger-passive",
    "a passive Scavenger's refusal is distinct from an unprotected type")

-- ---------------------------------------------------------------------------
-- decide - the roll boundary
-- ---------------------------------------------------------------------------
-- Soak when roll < rate. Pinned at the edges because an off-by-one here is a
-- balance change nobody would notice for a season.
check(RQBulwark.decide("Boss", true, false, 0) == true, "roll 0 soaks against a rate of 70")
check(RQBulwark.decide("Boss", true, false, 69) == true, "roll 69 is the last soak at rate 70")
check(RQBulwark.decide("Boss", true, false, 70) == false, "roll 70 penetrates at rate 70")
check(RQBulwark.decide("Boss", true, false, 99) == false, "the top roll penetrates")
check(RQBulwark.decide("Boss", false, false, 34) == true, "melee rate 35 soaks at 34")
check(RQBulwark.decide("Boss", false, false, 35) == false, "melee rate 35 penetrates at 35")

-- An unprotected target never soaks whatever the roll says.
check(RQBulwark.decide("Screamer", true, false, 0) == false, "an unprotected type never soaks")
local _, w = RQBulwark.decide("Screamer", true, false, 0)
check(w == "not-protected-type", "and says why")

-- Rate 0 and rate 100 are the boundaries the config surface will eventually be
-- able to reach, so they are pinned against the real table rather than assumed.
local saved = RQBulwark.SELF_SOAK.Boss.ranged
RQBulwark.SELF_SOAK.Boss.ranged = 0
check(RQBulwark.decide("Boss", true, false, 0) == false, "rate 0 never soaks, not even on roll 0")
RQBulwark.SELF_SOAK.Boss.ranged = 100
check(RQBulwark.decide("Boss", true, false, 99) == true, "rate 100 always soaks, even on roll 99")
RQBulwark.SELF_SOAK.Boss.ranged = saved

-- ---------------------------------------------------------------------------
-- resolve - the one mutation
-- ---------------------------------------------------------------------------
local avoidCalls = 0
local function makeZombie()
    return {
        getOnlineID    = function() return 1 end,
        getModData     = function() return {} end,
        getHealth      = function() return 8.0 end,
        setAvoidDamage = function(_, v)
            avoidCalls = avoidCalls + 1
            check(v == true, "setAvoidDamage is only ever called with true")
        end,
    }
end

local function fire(zType, isRanged, roll)
    nextRoll = roll
    return RQBulwark.resolve{ zombie = makeZombie(), zType = zType, isRanged = isRanged }
end

avoidCalls = 0
check(fire("Juggernaut", true, 10) == true, "a winning roll reports a soak")
check(avoidCalls == 1, "a soak sets avoidance exactly once")

avoidCalls = 0
check(fire("Juggernaut", true, 90) == false, "a losing roll reports a penetration")
check(avoidCalls == 0, "a penetrating hit leaves the vanilla pipeline untouched")

-- An unprotected target must not be touched at all - no roll, no mutation.
avoidCalls = 0
check(fire("Glutton", true, 0) == nil, "an unprotected type returns nil rather than a verdict")
check(avoidCalls == 0, "an unprotected type is never made to avoid damage")

-- Scavenger rage is read from the rage module, not from a copy of its state.
avoidCalls, enragedAnswer = 0, false
check(fire("Scavenger", true, 0) == nil, "a passive Scavenger is refused at resolve too")
check(avoidCalls == 0, "a passive Scavenger is never made to avoid damage")
enragedAnswer = true
avoidCalls = 0
check(fire("Scavenger", true, 0) == true, "an enraged Scavenger soaks")
check(avoidCalls == 1, "and the mutation lands")

-- ---------------------------------------------------------------------------
-- Counters
-- ---------------------------------------------------------------------------
-- These are what an operator reads to answer "is this doing anything", so they
-- have to survive the refusal paths without being inflated by them.
local st = RQBulwark.stats
local evaluatedBefore = st.evaluated
fire("Glutton", true, 0)
check(st.evaluated == evaluatedBefore, "a refused hit is not counted as evaluated")
check(st.refused["not-protected-type"] > 0, "refusals are counted by reason")
check(st.refused["scavenger-passive"] > 0, "the passive-Scavenger refusal is counted separately")

enragedAnswer = false
local soakedBefore, penBefore = st.soaked, st.penetrated
fire("Boss", true, 5)
fire("Boss", true, 95)
check(st.soaked == soakedBefore + 1, "soaks are counted")
check(st.penetrated == penBefore + 1, "penetrations are counted")
check(st.byType.Boss.soaked > 0 and st.byType.Boss.penetrated > 0,
    "outcomes are broken down by type")

local rangedBefore, meleeBefore = st.ranged, st.melee
fire("Boss", true, 5)
fire("Boss", false, 5)
check(st.ranged == rangedBefore + 1 and st.melee == meleeBefore + 1,
    "weapon class is counted for both branches")

print(string.format("RQBulwark: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
