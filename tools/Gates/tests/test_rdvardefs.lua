-- RDVarDefs fixture - definition validity, the exhaustively testable half of
-- the var system.
--
-- WHY THE ASSERTIONS LEAN NEGATIVE: every rule here exists to refuse something,
-- and a validator that has quietly stopped refusing looks exactly like one that
-- is working. The var it lets through is not discovered until a kit fails to
-- fire on a live event, weeks later, for one player.
--
-- Engine-free by construction - the module touches no global, which is the
-- point of it being its own file.

local ROOT = arg[1] or "."
local SOURCE = ROOT
    .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/shared/RDVarDefs.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then passed = passed + 1
    else failed = failed + 1; print("FAIL RDVarDefs: " .. message) end
end

RDVarDefs = nil
local ok, err = pcall(dofile, SOURCE)
check(ok, "module loads: " .. tostring(err))

local D = RDVarDefs

-- Accepts, and hands back the reason when it does not - a validator whose
-- refusals are unexplained is a validator an admin fights.
local function accepts(def, why)
    local out, reason = D.validate(def)
    check(out ~= nil, (why or "definition") .. " was refused: " .. tostring(reason))
    return out
end
local function refuses(def, why)
    local out, reason = D.validate(def)
    check(out == nil, "ACCEPTED " .. (why or "an invalid definition"))
    check(out ~= nil or (type(reason) == "string" and reason ~= ""),
        "refused " .. (why or "") .. " with no reason given")
    return reason
end

-- ---- names ---------------------------------------------------------------
-- Matched case-insensitively, displayed as authored. The two halves are a
-- single decision and both must hold, or "Anomaly" and "anomaly" become
-- different vars and the failure is invisible until a kit does not fire.

local key, display = D.normalizeName("Anomaly")
check(key == "anomaly", "the canonical key is not lower-cased: " .. tostring(key))
check(display == "Anomaly", "the authored spelling was not preserved for display")

check(select(1, D.normalizeName("  Anomaly  ")) == "anomaly", "surrounding space not trimmed")
check(select(2, D.normalizeName("  Anomaly  ")) == "Anomaly", "trim leaked into the display name")
check(D.normalizeName("ANOMALY") == D.normalizeName("anomaly"),
    "case-insensitive matching is broken - the whole reason the key exists")

for _, bad in ipairs({
    { v = "",             why = "an empty name" },
    { v = "   ",          why = "a whitespace-only name" },
    { v = "2Fast",        why = "a name starting with a digit" },
    { v = "-flag",        why = "a name starting with a hyphen (reads as a command flag)" },
    { v = "has space",    why = "a name with a space" },
    { v = 'quo"te',       why = "a name with a quote (these reach JSON keys)" },
    { v = "line\nbreak",  why = "a name with a line break" },
    { v = "tab\there",    why = "a name with a tab" },
    { v = string.rep("a", 33), why = "a 33-character name" },
}) do
    check(D.normalizeName(bad.v) == nil, "normalizeName accepted " .. bad.why)
end
check(D.normalizeName(string.rep("a", 32)) ~= nil, "a 32-character name was refused at the boundary")
check(D.normalizeName(nil) == nil and D.normalizeName(7) == nil,
    "normalizeName accepted a non-string")

-- ---- char vars -----------------------------------------------------------

local anomaly = accepts({ kind = "char", name = "Anomaly" }, "a bare char var")
check(anomaly.key == "anomaly" and anomaly.name == "Anomaly",
    "validate did not carry both key and display name")
check(D.isPermanent(anomaly),
    "a char var with NO revokers must read as permanent - it lasts until an "
    .. "admin removes it, and this is the test every consumer asks")
check(D.isChar(anomaly) and not D.isString(anomaly), "kind predicates disagree")
check(D.expiryMs(anomaly) == nil,
    "a var that does not expire returned an expiry - a caller would read 0 as "
    .. "'expires immediately'")

local timed = accepts({ kind = "char", name = "Anomaly",
                        revokers = { kit = "anomaly_crossbow", expires = 270, death = true } },
                      "a char var with all three revokers")
check(not D.isPermanent(timed), "a var with revokers read as permanent")
check(D.expiryMs(timed) == 270 * 60000, "expiry was not converted from minutes to ms")
check(timed.revokers.kit == "anomaly_crossbow",
    "the kit revoker was not carried through verbatim - Core stores it opaquely")

-- death = false is the ABSENCE of a revoker, not a revoker. Storing it would
-- make the permanence test lie.
local notOnDeath = accepts({ kind = "char", name = "Keeper", revokers = { death = false } },
                           "a char var with death = false")
check(D.isPermanent(notOnDeath),
    "revokers.death = false left a stored revoker, so the var no longer reads "
    .. "as permanent even though nothing will ever revoke it")

-- The revoker set is CLOSED. Ignoring an unknown key hands an admin who typed
-- `expiry` a permanent var and no indication of why.
check(refuses({ kind = "char", name = "X", revokers = { expiry = 10 } },
              "a misspelled revoker key"):find("expires", 1, true) ~= nil,
    "the refusal for a misspelled revoker did not name the real set")
refuses({ kind = "char", name = "X", revokers = { expires = "270" } }, "expires as a string")
refuses({ kind = "char", name = "X", revokers = { expires = 0 } }, "expires = 0")
refuses({ kind = "char", name = "X", revokers = { expires = -5 } }, "a negative expiry")
refuses({ kind = "char", name = "X", revokers = { death = "yes" } }, "death as a string")
refuses({ kind = "char", name = "X", revokers = { kit = "" } }, "an empty kit id")
refuses({ kind = "char", name = "X", revokers = "death" }, "revokers as a string")

-- NaN compares false against every bound, so an unguarded expiry check would
-- install a var that claims to expire and never does.
local nan = 0 / 0
refuses({ kind = "char", name = "X", revokers = { expires = nan } }, "expires = NaN")

-- ---- string vars ---------------------------------------------------------

local loot = accepts({ kind = "string", name = "AnomalyLoot", resetOnDeath = true },
                     "a string var")
check(loot.resetOnDeath == true, "resetOnDeath was not carried through")
check(not D.isPermanent(loot), "a string var read as permanent - it is reset, not revoked")
check(D.expiryMs(loot) == nil, "a string var reported an expiry")
accepts({ kind = "string", name = "Stages", resetOnDeath = false }, "resetOnDeath = false")

-- The rule the whole file exists for: no default. An unset default is how
-- behaviour nobody chose gets found months later.
local why = refuses({ kind = "string", name = "AnomalyLoot" }, "a string var with no resetOnDeath")
check(tostring(why):find("resetOnDeath", 1, true) ~= nil,
    "the refusal did not name the missing field: " .. tostring(why))
refuses({ kind = "string", name = "X", resetOnDeath = "true" }, "resetOnDeath as a string")
refuses({ kind = "string", name = "X", resetOnDeath = 1 }, "resetOnDeath as a number")

-- The two kinds do not borrow each other's lifecycle vocabulary. Two spellings
-- of one concept is how they drift apart.
refuses({ kind = "string", name = "X", resetOnDeath = true, revokers = { death = true } },
        "a string var with revokers")
refuses({ kind = "char", name = "X", resetOnDeath = true }, "a char var with resetOnDeath")

-- ---- shape ---------------------------------------------------------------

refuses(nil, "nil")
refuses("Anomaly", "a bare string")
refuses({ name = "X" }, "a definition with no kind")
refuses({ kind = "marker", name = "X" }, "an unknown kind")
refuses({ kind = "char" }, "a definition with no name")
refuses({ kind = "char", name = "X", colour = "red" }, "an unknown field")
refuses({ kind = "char", name = "X", note = 7 }, "a non-string note")
accepts({ kind = "char", name = "X", note = "for the Anomaly event" }, "an admin note")

-- ---- validate never hands back the caller's table -------------------------
-- A form object still being edited must not be able to mutate a stored
-- definition behind the store's back.
local form = { kind = "char", name = "Live", revokers = { death = true } }
local stored = D.validate(form)
check(stored ~= form, "validate returned the caller's own table")
form.revokers.death = false
form.name = "Changed"
check(stored.revokers.death == true and stored.name == "Live",
    "editing the submitted form mutated the validated definition")

print(string.format("RDVarDefs: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
