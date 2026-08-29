-- RQCeiling fixture - "how healthy is this special SUPPOSED to be?"
--
-- WHY A DIRECT FIXTURE, when test_rqmccoy already loads the real RQCeiling.
-- McCoy exercises it along the paths McCoy takes, which is the HAPPY path: a
-- zombie converted by this build, carrying a stamped RQBaseHP. The paths that
-- are not exercised there are the ones that matter most - the legacy
-- reconstruction arms, which exist purely so that specials converted BEFORE
-- RQBaseHP existed keep working after a chunk reload. That is save
-- compatibility (CLAUDE.md sect. 16, first category), it runs against data
-- written by an older build that cannot be re-tested, and it had no assertion
-- of its own.
--
-- WHAT IS AT RISK, in order.
--
-- 1. THE RAGE-PEAK OVERRIDE. An enraged Scavenger's ceiling is a FROZEN number
--    that rage decay walks down over ten minutes. If a multiplier is ever
--    applied on top of it, or if the base path is allowed to answer instead,
--    healing climbs back above the decay target and the ten-minute mechanic
--    silently stops meaning anything. Required test: "Scavenger healing never
--    exceeds its current decay target."
--
-- 2. RECONSTRUCTION ORDER. Three sources, and the order is a contract:
--    stamped beats legacy-jugg beats legacy-glutton. A Juggernaut carrying
--    both old keys must reconstruct from the Juggernaut one.
--
-- 3. REFUSING RATHER THAN INVENTING. When no base can be established the
--    answer is nil plus a named reason, and the caller does nothing. A
--    fabricated ceiling would either freeze healing off or hand out free
--    health, and both are invisible in play.
--
-- Pure arithmetic, zero engine surface - so everything here is provable
-- without a single stub.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDirge/42/media/lua/shared/RQCeiling.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then passed = passed + 1
    else failed = failed + 1; print("FAIL RQCeiling: " .. message) end
end

local function near(a, b)
    return a and b and math.abs(a - b) < 0.0001
end

-- The REAL RDShared, not a stub: RQCeiling's type gate keys on badNum, and a
-- stub would be the fixture testing itself.
function require(name)
    if name == "RDShared" then
        dofile(ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/shared/RDShared.lua")
        return
    end
    error("unexpected fixture require: " .. tostring(name))
end

RQCeiling = nil
local ok, err = pcall(dofile, SOURCE)
check(ok, "module loads: " .. tostring(err))

-- ---------------------------------------------------------------------------
-- reconstructBase - best evidence first
-- ---------------------------------------------------------------------------

local base, how = RQCeiling.reconstructBase({ RQBaseHP = 2.0 }, "Juggernaut", 5)
check(near(base, 2.0) and how == "stamped", "a stamped base is used verbatim: " .. tostring(base))

-- Legacy keys are POST-conversion values, so dividing by the multiplier
-- recovers the base exactly. This is the arm that keeps a live save working.
base, how = RQCeiling.reconstructBase({ RQJuggMaxHP = 10.0 }, "Juggernaut", 5)
check(near(base, 2.0) and how == "legacy-jugg",
    "a legacy Juggernaut max divides back to its base: " .. tostring(base))

base, how = RQCeiling.reconstructBase({ RQGluttonBaseHealth = 15.0 }, "Glutton", 3)
check(near(base, 5.0) and how == "legacy-glutton",
    "a legacy Glutton base divides back too: " .. tostring(base))

-- ORDER IS A CONTRACT. A Juggernaut that has also eaten carries both keys.
base, how = RQCeiling.reconstructBase(
    { RQBaseHP = 2.0, RQJuggMaxHP = 99.0, RQGluttonBaseHealth = 99.0 }, "Juggernaut", 5)
check(how == "stamped", "the stamped value outranks both legacy keys: " .. tostring(how))

base, how = RQCeiling.reconstructBase(
    { RQJuggMaxHP = 10.0, RQGluttonBaseHealth = 99.0 }, "Juggernaut", 5)
check(near(base, 2.0) and how == "legacy-jugg",
    "the Juggernaut key outranks the Glutton one on a Juggernaut: " .. tostring(how))

-- RQJuggMaxHP is Juggernaut-only ON PURPOSE - it is that type's multiplier
-- that divides it back. Reading it on another type would produce a base
-- computed from the wrong conversion.
base, how = RQCeiling.reconstructBase({ RQJuggMaxHP = 10.0 }, "Screamer", 5)
check(base == nil and how == "unreconstructable",
    "a Juggernaut key on a Screamer is ignored, not misapplied: " .. tostring(how))

-- ---------------------------------------------------------------------------
-- Refusing rather than inventing
-- ---------------------------------------------------------------------------

base, how = RQCeiling.reconstructBase({}, "Juggernaut", 5)
check(base == nil and how == "unreconstructable", "empty modData refuses with a reason")

base, how = RQCeiling.reconstructBase(nil, "Juggernaut", 5)
check(base == nil and how == "no-multiplier", "nil modData refuses")

base, how = RQCeiling.reconstructBase({ RQBaseHP = 2.0 }, "Juggernaut", 0)
check(base == nil and how == "no-multiplier",
    "a zero multiplier refuses rather than dividing by it")

base, how = RQCeiling.reconstructBase({ RQBaseHP = 2.0 }, "Juggernaut", -1)
check(base == nil and how == "no-multiplier", "a negative multiplier refuses too")

-- A zero or negative stamp is not evidence; it falls through rather than
-- pinning the ceiling at zero, which would read as "already at its ceiling"
-- and freeze healing off permanently.
base, how = RQCeiling.reconstructBase({ RQBaseHP = 0, RQJuggMaxHP = 10.0 }, "Juggernaut", 5)
check(near(base, 2.0) and how == "legacy-jugg",
    "a zero stamp is not evidence and falls through: " .. tostring(how))

-- ---------------------------------------------------------------------------
-- resolve - the rage-peak override
-- ---------------------------------------------------------------------------
-- THE ONE THAT MATTERS. Rage decay owns this number and walks it down; if the
-- multiplier were applied on top, or the base path answered instead, healing
-- would climb back above the decay target every tick and the whole ten-minute
-- mechanic would quietly stop existing.
local ceiling, why = RQCeiling.resolve({ RQBaseHP = 2.0 }, "Scavenger", 5, { ragePeak = 7.5 })
check(near(ceiling, 7.5) and why == "rage-peak",
    "the rage peak wins outright: " .. tostring(ceiling))
check(not near(ceiling, 37.5),
    "and the type multiplier is NOT applied on top of it - that would defeat rage decay")

-- Decaying: a LOWER peak than the base would produce must still win, because
-- that is what decay looks like from here.
ceiling, why = RQCeiling.resolve({ RQBaseHP = 2.0 }, "Scavenger", 5, { ragePeak = 3.0 })
check(near(ceiling, 3.0) and why == "rage-peak",
    "a decayed peak below the derived ceiling still wins: " .. tostring(ceiling))

-- currentHP must not lift a decaying rage ceiling back up. The floor rule is
-- for the derived path; a rage peak is authoritative.
ceiling = RQCeiling.resolve({ RQBaseHP = 2.0 }, "Scavenger", 5,
    { ragePeak = 3.0, currentHP = 9.0 })
check(near(ceiling, 3.0),
    "current health does not lift a rage peak - decay outranks the floor: " .. tostring(ceiling))

-- A zero/absent peak is not a peak; the ordinary path answers.
ceiling, why = RQCeiling.resolve({ RQBaseHP = 2.0 }, "Scavenger", 5, { ragePeak = 0 })
check(near(ceiling, 10.0) and why == "stamped",
    "a zero peak falls through to the derived ceiling: " .. tostring(ceiling))

-- ---------------------------------------------------------------------------
-- resolve - derivation, growth and the floor
-- ---------------------------------------------------------------------------

ceiling, why = RQCeiling.resolve({ RQBaseHP = 2.0 }, "Juggernaut", 5)
check(near(ceiling, 10.0) and why == "stamped", "base * multiplier: " .. tostring(ceiling))

-- eatMult is growth a feeding type has EARNED. The two callers legitimately
-- disagree about what to pass - McCoy passes what was actually eaten, the
-- health bar passes the theoretical cap - so the field is applied as given.
ceiling = RQCeiling.resolve({ RQBaseHP = 2.0 }, "Glutton", 5, { eatMult = 1.5 })
check(near(ceiling, 15.0), "growth multiplies the ceiling: " .. tostring(ceiling))

-- Only ABOVE 1.0. A type that has eaten nothing must not shrink its own
-- ceiling, and a nonsense sub-1 value must not either.
ceiling = RQCeiling.resolve({ RQBaseHP = 2.0 }, "Glutton", 5, { eatMult = 1.0 })
check(near(ceiling, 10.0), "an eatMult of exactly 1.0 changes nothing")
ceiling = RQCeiling.resolve({ RQBaseHP = 2.0 }, "Glutton", 5, { eatMult = 0.5 })
check(near(ceiling, 10.0), "a sub-1.0 eatMult never SHRINKS the ceiling: " .. tostring(ceiling))

-- currentHP is a floor, not a target. A zombie is never told its ceiling is
-- below where it already is - otherwise McCoy's "heal only when below the
-- ceiling" test reads as "never" for anything the old model had inflated.
ceiling = RQCeiling.resolve({ RQBaseHP = 2.0 }, "Juggernaut", 5, { currentHP = 40.0 })
check(near(ceiling, 40.0), "an over-inflated zombie keeps its current health as the ceiling")
ceiling = RQCeiling.resolve({ RQBaseHP = 2.0 }, "Juggernaut", 5, { currentHP = 3.0 })
check(near(ceiling, 10.0),
    "a damaged zombie is NOT capped at its current health - that would freeze healing")

-- Growth and the floor compose in the documented order.
ceiling = RQCeiling.resolve({ RQBaseHP = 2.0 }, "Glutton", 5,
    { eatMult = 1.5, currentHP = 12.0 })
check(near(ceiling, 15.0), "growth applies before the floor is considered: " .. tostring(ceiling))

-- ---------------------------------------------------------------------------
-- resolve - refusal carries the reason through
-- ---------------------------------------------------------------------------
-- The caller does nothing when this is nil. A reason that got lost on the way
-- out would make an unhealable special indistinguishable from a healthy one in
-- the logs.
ceiling, why = RQCeiling.resolve({}, "Screamer", 5)
check(ceiling == nil and why == "unreconstructable",
    "an unreconstructable special refuses with its reason intact: " .. tostring(why))

ceiling, why = RQCeiling.resolve(nil, "Screamer", 5)
check(ceiling == nil and why == "no-multiplier", "so does a nil modData")

ceiling, why = RQCeiling.resolve({ RQBaseHP = 2.0 }, "Screamer", nil)
check(ceiling == nil and why == "no-multiplier", "and a nil multiplier")

-- opts is optional; every caller shape must work.
ceiling = RQCeiling.resolve({ RQBaseHP = 2.0 }, "Juggernaut", 5, nil)
check(near(ceiling, 10.0), "a nil opts is the same as an empty one")

-- ---------------------------------------------------------------------------
-- THE FOUR STATES THAT COULD NOT RECONSTRUCT
-- ---------------------------------------------------------------------------
-- Slice 0 established that an enraged Scavenger, a Screamer, an EMP and a Boss
-- cannot rebuild a ceiling from anything but a stamped base - they have no
-- legacy key of their own. That finding is why RQBaseHP exists at all, so it is
-- pinned rather than left as a line in the ledger: if any of these ever starts
-- answering from a legacy key, something has been mis-wired.
for _, zType in ipairs({ "Scavenger", "Screamer", "EMP", "Boss" }) do
    local c, r = RQCeiling.resolve({ RQJuggMaxHP = 50.0 }, zType, 5)
    check(c == nil and r == "unreconstructable",
        zType .. " cannot reconstruct from a Juggernaut key: " .. tostring(r))

    local c2, r2 = RQCeiling.resolve({ RQBaseHP = 2.0 }, zType, 5)
    check(near(c2, 10.0) and r2 == "stamped",
        zType .. " resolves once RQBaseHP is stamped: " .. tostring(c2))
end

-- ---------------------------------------------------------------------------
-- DAMAGED SAVE DATA
-- ---------------------------------------------------------------------------
-- modData outlives the build that wrote it, survives hand edits, and is
-- writable by any other mod. Before 2026-08-25 a key holding the wrong type
-- reached a bare `> 0` and threw "attempt to compare number with string" -
-- from RQHealthBar's PER-FRAME render path, so once per frame per visible
-- special. Refusing with a reason is the same contract every other bad input
-- in this file already had.
for _, bad in ipairs({ "abc", true, {}, 0/0, math.huge, -math.huge }) do
    local label = tostring(bad)
    local okCall, res, reason = pcall(RQCeiling.resolve, { RQBaseHP = bad }, "Juggernaut", 5)
    check(okCall, "a corrupt RQBaseHP (" .. label .. ") must not throw: " .. tostring(res))
    if okCall then
        check(res == nil and reason == "non-numeric",
            "and refuses with the diagnosis, not a fabricated ceiling: " .. tostring(reason))
    end
end

-- A PRESENT-but-junk key reads differently from an absent one. The first means
-- the save is damaged or another mod is writing our namespace; the second is
-- just a conversion that predates RQBaseHP. Same refusal, different diagnosis.
local _, r1 = RQCeiling.resolve({}, "Juggernaut", 5)
local _, r2 = RQCeiling.resolve({ RQBaseHP = "junk" }, "Juggernaut", 5)
check(r1 == "unreconstructable" and r2 == "non-numeric",
    "absent and corrupt are distinguishable: " .. tostring(r1) .. " vs " .. tostring(r2))

-- Corruption in one key must not blind the others - a Juggernaut with a junk
-- stamp and a good legacy key still reconstructs.
local c, r = RQCeiling.resolve({ RQBaseHP = "junk", RQJuggMaxHP = 10.0 }, "Juggernaut", 5)
check(near(c, 10.0) and r == "legacy-jugg",
    "a junk stamp falls through to a good legacy key: " .. tostring(r))

-- An infinite stamp would pass a bare `> 0` and produce an infinite ceiling -
-- a special that can never be healed to full and a bar stuck at 0%.
c = RQCeiling.resolve({ RQBaseHP = math.huge }, "Juggernaut", 5)
check(c == nil, "an infinite stamp is refused, not multiplied: " .. tostring(c))

-- The opts fields take the same gate. ragePeak matters most: RQHealthBar reads
-- it out of RQReconcile.scavClientState, which is populated from the wire.
local okCall, res = pcall(RQCeiling.resolve, { RQBaseHP = 2.0 }, "Scavenger", 5,
    { ragePeak = "junk" })
check(okCall, "a junk ragePeak must not throw: " .. tostring(res))
check(okCall and near(res, 10.0),
    "and falls through to the derived ceiling: " .. tostring(res))

okCall, res = pcall(RQCeiling.resolve, { RQBaseHP = 2.0 }, "Glutton", 5, { eatMult = "junk" })
check(okCall and near(res, 10.0), "a junk eatMult is ignored: " .. tostring(res))

okCall, res = pcall(RQCeiling.resolve, { RQBaseHP = 2.0 }, "Juggernaut", 5,
    { currentHP = "junk" })
check(okCall and near(res, 10.0), "a junk currentHP is ignored: " .. tostring(res))

-- A NaN multiplier passes `mult <= 0` as false and would divide silently.
local _, rm = RQCeiling.resolve({ RQJuggMaxHP = 10.0 }, "Juggernaut", 0/0)
check(rm == "no-multiplier", "a NaN multiplier refuses: " .. tostring(rm))

print(string.format("RQCeiling: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
