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

-- ---- flags -----------------------------------------------------------

local anomaly = accepts({ kind = "flag", name = "Anomaly" }, "a bare flag")
check(anomaly.key == "anomaly" and anomaly.name == "Anomaly",
    "validate did not carry both key and display name")
check(D.isPermanent(anomaly),
    "a flag with NO revokers must read as permanent - it lasts until an "
    .. "admin removes it, and this is the test every consumer asks")
check(D.isFlag(anomaly) and not D.isString(anomaly), "kind predicates disagree")
check(D.expiryMs(anomaly) == nil,
    "a var that does not expire returned an expiry - a caller would read 0 as "
    .. "'expires immediately'")

local timed = accepts({ kind = "flag", name = "Anomaly",
                        revokers = { kit = "anomaly_crossbow", expires = 270, death = true } },
                      "a flag with all three revokers")
check(not D.isPermanent(timed), "a var with revokers read as permanent")
check(D.expiryMs(timed) == 270 * 60000, "expiry was not converted from minutes to ms")
check(timed.revokers.kit == "anomaly_crossbow",
    "the kit revoker was not carried through verbatim - Core stores it opaquely")

-- death = false is the ABSENCE of a revoker, not a revoker. Storing it would
-- make the permanence test lie.
local notOnDeath = accepts({ kind = "flag", name = "Keeper", revokers = { death = false } },
                           "a flag with death = false")
check(D.isPermanent(notOnDeath),
    "revokers.death = false left a stored revoker, so the var no longer reads "
    .. "as permanent even though nothing will ever revoke it")

-- The revoker set is CLOSED. Ignoring an unknown key hands an admin who typed
-- `expiry` a permanent var and no indication of why.
check(refuses({ kind = "flag", name = "X", revokers = { expiry = 10 } },
              "a misspelled revoker key"):find("expires", 1, true) ~= nil,
    "the refusal for a misspelled revoker did not name the real set")
refuses({ kind = "flag", name = "X", revokers = { expires = "270" } }, "expires as a string")
refuses({ kind = "flag", name = "X", revokers = { expires = 0 } }, "expires = 0")
refuses({ kind = "flag", name = "X", revokers = { expires = -5 } }, "a negative expiry")
refuses({ kind = "flag", name = "X", revokers = { death = "yes" } }, "death as a string")
refuses({ kind = "flag", name = "X", revokers = { kit = "" } }, "an empty kit id")
refuses({ kind = "flag", name = "X", revokers = "death" }, "revokers as a string")

-- NaN compares false against every bound, so an unguarded expiry check would
-- install a var that claims to expire and never does.
local nan = 0 / 0
refuses({ kind = "flag", name = "X", revokers = { expires = nan } }, "expires = NaN")

-- ---- string vars ---------------------------------------------------------

local loot = accepts({ kind = "counter", name = "AnomalyLoot", resetOnDeath = true },
                     "a string var")
check(loot.resetOnDeath == true, "resetOnDeath was not carried through")
check(not D.isPermanent(loot), "a string var read as permanent - it is reset, not revoked")
check(D.expiryMs(loot) == nil, "a string var reported an expiry")
accepts({ kind = "counter", name = "Stages", resetOnDeath = false }, "resetOnDeath = false")

-- The rule the whole file exists for: no default. An unset default is how
-- behaviour nobody chose gets found months later.
local why = refuses({ kind = "counter", name = "AnomalyLoot" }, "a string var with no resetOnDeath")
check(tostring(why):find("resetOnDeath", 1, true) ~= nil,
    "the refusal did not name the missing field: " .. tostring(why))
refuses({ kind = "counter", name = "X", resetOnDeath = "true" }, "resetOnDeath as a string")
refuses({ kind = "counter", name = "X", resetOnDeath = 1 }, "resetOnDeath as a number")

-- The two kinds do not borrow each other's lifecycle vocabulary. Two spellings
-- of one concept is how they drift apart.
refuses({ kind = "counter", name = "X", resetOnDeath = true, revokers = { death = true } },
        "a string var with revokers")
refuses({ kind = "flag", name = "X", resetOnDeath = true }, "a flag with resetOnDeath")

-- ---- shape ---------------------------------------------------------------

refuses(nil, "nil")
refuses("Anomaly", "a bare string")
refuses({ name = "X" }, "a definition with no kind")
-- Deliberately not a near-miss of a real kind: this case was written as
-- "marker" and a 2026-08-23 rename made that WORD valid, turning an
-- unknown-kind test into an accepted one. A bogus value it is.
refuses({ kind = "sigil", name = "X" }, "an unknown kind")
refuses({ kind = "flag" }, "a definition with no name")
refuses({ kind = "flag", name = "X", colour = "red" }, "an unknown field")
refuses({ kind = "flag", name = "X", note = 7 }, "a non-string note")
accepts({ kind = "flag", name = "X", note = "for the Anomaly event" }, "an admin note")

-- ---- validate never hands back the caller's table -------------------------
-- A form object still being edited must not be able to mutate a stored
-- definition behind the store's back.
local form = { kind = "flag", name = "Live", revokers = { death = true } }
local stored = D.validate(form)
check(stored ~= form, "validate returned the caller's own table")
form.revokers.death = false
form.name = "Changed"
check(stored.revokers.death == true and stored.name == "Live",
    "editing the submitted form mutated the validated definition")

-- ---- scope ---------------------------------------------------------------
--
-- Added 2026-08-23. A counter is either per-player or one number the whole
-- server shares, and the second exists because "how many times has this quest
-- been completed at all" had no home - summing the player half costs a walk of
-- every record AND loses everyone who was wiped or never came back.

local world = RDVarDefs.validate{ kind = "counter", name = "Runs",
                                  scope = "world" }
check(world ~= nil, "a world counter was refused")
check(world and world.scope == "world", "the scope did not survive validation")
check(RDVarDefs.isWorld(world) == true, "isWorld did not recognise one")

-- ABSENT SCOPE MEANS PER-PLAYER, and that is a status quo rather than a
-- default nobody chose. Every counter that has ever existed is per-player, so
-- unlike resetOnDeath there is no second plausible reading to be silent about.
local plain = RDVarDefs.validate{ kind = "counter", name = "Samples",
                                  resetOnDeath = false }
check(plain and plain.scope == "player",
    "an unscoped counter did not normalise to per-player: "
    .. tostring(plain and plain.scope))
check(RDVarDefs.isWorld(plain) == false, "a per-player counter reported as world")

-- A world counter has no holder, so it has no death to reset on. Refused
-- rather than accepted-and-ignored: stored, it is a lifecycle the panel would
-- draw and nothing would ever fire.
local why
_, why = RDVarDefs.validate{ kind = "counter", name = "Runs", scope = "world",
                             resetOnDeath = true }
check(_ == nil, "A WORLD COUNTER ACCEPTED resetOnDeath. Whose death?")
check(tostring(why):find("death") ~= nil, "the refusal did not name the field: " .. tostring(why))
check(RDVarDefs.validate{ kind = "counter", name = "Runs", scope = "world",
                          resetOnDeath = false } == nil,
    "resetOnDeath = false was accepted on a world counter - the field does not "
    .. "apply, and false is an answer to a question that was not asked")

-- The per-player half keeps its rule untouched.
check(RDVarDefs.validate{ kind = "counter", name = "Samples", scope = "player" } == nil,
    "a per-player counter no longer requires resetOnDeath")

-- A FLAG HAS NO SCOPE. Its whole vocabulary is about a holder, so a world flag
-- is not a flag with a different scope - it is a boolean nobody has designed.
_, why = RDVarDefs.validate{ kind = "flag", name = "Open", scope = "world" }
check(_ == nil, "A WORLD FLAG WAS ACCEPTED. Granted to whom, revoked on whose "
    .. "death, expiring from whose grant?")
check(tostring(why):find("counter") ~= nil,
    "the refusal did not point at the thing that does work: " .. tostring(why))
check(RDVarDefs.validate{ kind = "flag", name = "Open", scope = "player" } ~= nil,
    "an explicit player scope on a flag was refused - it is the only thing a "
    .. "flag can be, so saying so out loud must not be an error")
check(RDVarDefs.validate{ kind = "flag", name = "Open" } ~= nil,
    "a plain flag broke when scope arrived")

-- An unknown scope is refused rather than falling back, for the same reason an
-- unknown revoker is: a typo that silently yields the default is a var that
-- behaves nothing like the definition somebody is reading.
-- resetOnDeath is answered on both, so the ONLY rule that can refuse them is
-- the scope one. Without it these pass for the wrong reason - the missing
-- resetOnDeath - and a scope that fell through to the default would go unseen.
check(RDVarDefs.validate{ kind = "counter", name = "Runs", scope = "server",
                          resetOnDeath = false } == nil,
    "a misspelled scope fell back to a default")
check(RDVarDefs.validate{ kind = "counter", name = "Runs", scope = true,
                          resetOnDeath = false } == nil,
    "a non-string scope was accepted")
check(RDVarDefs.validate{ kind = "counter", name = "Runs", scope = "World",
                          resetOnDeath = false } == nil,
    "scope matching is case-insensitive somewhere it should not be - every "
    .. "other closed set in this file is exact, and a 'World' that quietly "
    .. "became per-player is a counter behaving as neither")

check(RDVarDefs.isWorld(nil) == false, "isWorld faulted on nothing")
check(RDVarDefs.isWorld{ kind = "flag", scope = "world" } == false,
    "isWorld answered for a FLAG carrying a stored scope. Definitions can come "
    .. "from an older document or a hand-edited file, and a flag that reads as "
    .. "world-scoped would be routed to a store half it has no values in.")

print(string.format("RDVarDefs: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
