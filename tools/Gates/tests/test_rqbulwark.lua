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
-- The live special registry, and the walk contract Bulwark's aura lookup uses:
-- a truthy return from the callback STOPS the walk.
local registry = {}
local visits = 0
RQSvShared = {
    getSvConfig = function()
        return { debugMode = debugMode, juggernautBuffRadius = 5 }
    end,
    eachActiveZombie = function(fn)
        local n = 0
        for z, t in pairs(registry) do
            n = n + 1
            visits = visits + 1
            if fn(z, t) then break end
        end
        return n
    end,
}
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
        -- Coordinates matter now: an unprotected type still falls through to the
        -- aura walk, because a Glutton standing beside a Boss IS protected.
        getX = function() return 500 end,
        getY = function() return 500 end,
        getZ = function() return 0 end,
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
-- resolve's refusal is "unprotected", not "not-protected-type". Since the aura
-- migration it no longer turns a type away on sight - a Glutton beside a Boss
-- IS protected - so it only refuses once BOTH self-protection and the aura walk
-- have come back empty. rateFor still names the narrower reason for callers
-- asking specifically about self-protection.
check(st.refused["unprotected"] > 0,
    "a target with neither self-protection nor an aura is refused as unprotected")

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

-- ---------------------------------------------------------------------------
-- Aura protection
-- ---------------------------------------------------------------------------
-- Evaluated at hit time against live sources, which is the whole point of the
-- migration: the model this replaced granted health once and latched it, so the
-- protection outlived its source and ignored the radius entirely.

local function auraSource(zType, x, y, z, dead)
    local o = {
        getX = function() return x end,
        getY = function() return y end,
        getZ = function() return z or 0 end,
        isDead = function() return dead == true end,
        getOnlineID = function() return 900 end,
        getModData = function() return {} end,
    }
    registry[o] = zType
    return o
end

local function targetAt(x, y, z)
    return {
        getX = function() return x end,
        getY = function() return y end,
        getZ = function() return z or 0 end,
        getOnlineID = function() return 901 end,
        getModData = function() return {} end,
        getHealth = function() return 2.0 end,
        setAvoidDamage = function() avoidCalls = avoidCalls + 1 end,
    }
end

local function clearRegistry() for k in pairs(registry) do registry[k] = nil end end

-- An ordinary zombie beside a Juggernaut is protected; the same zombie alone is
-- not. Nothing about the zombie changed - only what is standing next to it.
clearRegistry()
local ord = targetAt(10, 10)
check(RQBulwark.auraRateFor(ord, nil, true) == nil, "an ordinary zombie alone has no aura")
auraSource("Juggernaut", 12, 10)
check(RQBulwark.auraRateFor(ord, nil, true) == 30, "beside a Juggernaut it soaks 30 ranged")
check(RQBulwark.auraRateFor(ord, nil, false) == 15, "and 15 melee")

-- Range and floor are live tests, not a latch.
clearRegistry()
auraSource("Juggernaut", 40, 10)
check(RQBulwark.auraRateFor(ord, nil, true) == nil, "a Juggernaut out of radius protects nothing")
clearRegistry()
auraSource("Juggernaut", 12, 10, 1)
check(RQBulwark.auraRateFor(ord, nil, true) == nil, "a Juggernaut one floor up protects nothing")

-- A dead source protects nothing. This is the failure the old latch could not
-- express: kill the escort and its escort stayed tough forever.
clearRegistry()
auraSource("Juggernaut", 12, 10, 0, true)
check(RQBulwark.auraRateFor(ord, nil, true) == nil, "a dead Juggernaut protects nothing")

-- Who protects whom.
clearRegistry()
auraSource("Juggernaut", 12, 10)
check(RQBulwark.auraRateFor(targetAt(11, 10), "Screamer", true) == nil,
    "a Juggernaut does not protect other specials - two of them are not a fortress")
clearRegistry()
auraSource("Boss", 12, 10)
check(RQBulwark.auraRateFor(targetAt(11, 10), "Screamer", true) == 40,
    "a Boss protects specials at the special rate")
check(RQBulwark.auraRateFor(ord, nil, true) == 30, "and ordinary zombies at the ordinary rate")

clearRegistry()
local scav = auraSource("Scavenger", 12, 10)
enragedAnswer = false
check(RQBulwark.auraRateFor(targetAt(11, 10), "Screamer", true) == nil,
    "a passive Scavenger protects nothing - it is eating, not leading")
enragedAnswer = true
check(RQBulwark.auraRateFor(targetAt(11, 10), "Screamer", true) == 40,
    "an enraged Scavenger protects specials")
check(RQBulwark.auraRateFor(ord, nil, true) == nil,
    "but not the ordinary horde")

-- Nothing auras itself into extra protection.
clearRegistry()
local selfSrc = auraSource("Boss", 10, 10)
check(RQBulwark.auraRateFor(selfSrc, "Boss", true) == nil,
    "a source is not its own aura target")

-- ---------------------------------------------------------------------------
-- Strongest single result, never a stack
-- ---------------------------------------------------------------------------
clearRegistry()
auraSource("Boss", 11, 10)
auraSource("Boss", 12, 10)
local two = RQBulwark.auraRateFor(targetAt(10, 10), "Screamer", true)
check(two == 40, "two overlapping Bosses give 40, not 80: " .. tostring(two))

-- Self-protection wins when it is better, and the aura wins when IT is better.
enragedAnswer = false
clearRegistry()
auraSource("Boss", 11, 10)
avoidCalls = 0
nextRoll = 65
-- Juggernaut self is 60 ranged; a Boss aura offers a special 40. Self wins, so a
-- roll of 65 must penetrate rather than being rescued by the weaker aura.
check(RQBulwark.resolve{ zombie = targetAt(10, 10), zType = "Juggernaut", isRanged = true } == false,
    "the weaker aura does not rescue a roll the stronger self-protection lost")

-- An ordinary zombie has no self-protection at all, so the aura is all there is.
avoidCalls = 0
nextRoll = 10
check(RQBulwark.resolve{ zombie = targetAt(10, 10), zType = nil, isRanged = true } == true,
    "an ordinary zombie under a Boss aura can soak")
check(avoidCalls == 1, "and the mutation lands on it")
check(RQBulwark.stats.byType["ordinary"] ~= nil,
    "ordinary targets get their own counter row rather than a nil key")

-- Unprotected and un-auraed: refused by name, no roll, no mutation.
clearRegistry()
avoidCalls = 0
nextRoll = 0
check(RQBulwark.resolve{ zombie = targetAt(10, 10), zType = nil, isRanged = true } == nil,
    "an ordinary zombie with nothing nearby is refused")
check(avoidCalls == 0, "and is never made to avoid damage")
check(RQBulwark.stats.refused["unprotected"] > 0, "the refusal is named")

-- ---------------------------------------------------------------------------
-- The walk is bounded and stops early
-- ---------------------------------------------------------------------------
-- The strongest-single-result rule means a second matching source adds nothing,
-- so the walk breaks on the first hit rather than confirming an answer it
-- already has.
clearRegistry()
for i = 1, 20 do auraSource("Boss", 11, 10) end
visits = 0
RQBulwark.auraRateFor(targetAt(10, 10), "Screamer", true)
check(visits == 1, "the walk stops at the first eligible source: " .. visits .. " visited")

-- A Boss already at the aura ceiling never triggers a walk at all: its own
-- protection is 70, better than any aura could offer.
clearRegistry()
auraSource("Boss", 11, 10)
visits = 0
enragedAnswer = false
nextRoll = 50
RQBulwark.resolve{ zombie = targetAt(10, 10), zType = "Boss", isRanged = true }
check(visits == 0, "a Boss does not pay for an aura walk it cannot benefit from")

print(string.format("RQBulwark: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
