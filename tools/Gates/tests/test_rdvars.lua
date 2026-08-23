-- RDVars fixture - the lifecycle half of the player-variable system.
--
-- WHAT IS ACTUALLY AT RISK HERE. A var is a permission in disguise: holding one
-- is what lets a player claim a kit. So the failures worth catching are the two
-- directions of getting that wrong - a marker that outlives what it was meant
-- to cover (a spent event grant that never expires, an admin-only flag that
-- survives death when it declared it would not), and a marker that vanishes
-- from under a player who legitimately holds it. Both are silent. Neither is
-- visible until someone types /kit at an event.
--
-- REAL RDVarDefs, RDConfigStore AND RDJson - all three loaded, none stubbed.
-- The interesting behaviour lives in the seams between them: a definition's
-- revokers decide what death does, and the store decides whether any of it
-- survives a restart. Stubbing either would test the stub.
--
-- The clock is ours because two of the rules here are ABOUT the clock, and one
-- of them is that it can run backwards.

local ROOT = arg[1] or "."
local CORE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua"

local passed, failed = 0, 0
local realPrint = print
local function check(ok, message)
    if ok then passed = passed + 1
    else failed = failed + 1; realPrint("FAIL RDVars: " .. message) end
end

-- ---- engine stubs -------------------------------------------------------

function isServer() return true end
print = function() end

-- Only IsoPlayer matters: OnCharacterDeath fires for zombies and animals too,
-- and the type test is the first statement in the handler for that reason.
function instanceof(o, cls) return type(o) == "table" and o.__class == cls end
local function player(name) return { __class = "IsoPlayer", getUsername = function() return name end } end
local function zombie() return { __class = "IsoZombie" } end

local fs = {}
function getFileReader(path, _)
    local content = fs[path]
    if content == nil then return nil end
    local lines, i = {}, 1
    for line in (content .. "\n"):gmatch("(.-)\n") do lines[i] = line; i = i + 1 end
    if lines[#lines] == "" then lines[#lines] = nil end
    local pos = 0
    return { readLine = function() pos = pos + 1; return lines[pos] end, close = function() end }
end
function getFileWriter(path, _, append)
    if not append then fs[path] = "" end
    return {
        write = function(_, s) fs[path] = (fs[path] or "") .. s end,
        close = function() end,
    }
end

local modDataMap = {}
ModData = { getOrCreate = function(tag)
    modDataMap[tag] = modDataMap[tag] or {}
    return modDataMap[tag]
end }

local onDeath, onSweep
Events = {
    EveryTenMinutes  = { Add = function(fn) onSweep = fn end },
    OnCharacterDeath = { Add = function(fn) onDeath = fn end },
    OnServerStarted  = { Add = function() end },
}

local clock = 1000000
RDShared = {
    nowMs   = function() return clock end,
    DIR     = "RFTD/",
    EXT_DOC = ".json.txt",
}

require = function() return true end
dofile(CORE .. "/shared/RDJson.lua")
dofile(CORE .. "/shared/RDVarDefs.lua")
dofile(CORE .. "/server/RDConfigStore.lua")

RDVars = nil
local ok, err = pcall(dofile, CORE .. "/server/RDVars.lua")
check(ok, "module loads: " .. tostring(err))
check(onDeath ~= nil, "no OnCharacterDeath listener was registered")
check(onSweep ~= nil, "no expiry sweep was registered")

local STATE_FILE = "RFTD/vars-state.json.txt"
local DEFS_FILE  = "RFTD/vars-defs.json.txt"

local function reset()
    fs, modDataMap = {}, {}
    clock = 1000000
    -- Fresh store list and fresh listeners; RDVars caches its store in an
    -- upvalue, so both modules are reloaded together or the new RDVars would
    -- keep writing through the old store.
    dofile(CORE .. "/server/RDConfigStore.lua")
    dofile(CORE .. "/server/RDVars.lua")
end

-- Shorthands: every block wants the same two vars.
local function defineAnomaly(revokers)
    return RDVars.define{ kind = "char", name = "Anomaly", revokers = revokers }
end
local function defineLoot(resetOnDeath)
    return RDVars.define{ kind = "counter", name = "AnomalyLoot", resetOnDeath = resetOnDeath }
end

-- ---- definitions ---------------------------------------------------------

reset()
check(defineAnomaly({ death = true }) ~= nil, "a valid char var was refused")
check(defineLoot(true) ~= nil, "a valid string var was refused")
check(RDVars.define{ kind = "counter", name = "Bad" } == nil,
    "a string var with no resetOnDeath reached the store - RDVarDefs' rule "
    .. "must not be bypassable through define()")
check(RDVars.definition("ANOMALY") ~= nil,
    "definition lookup is case-sensitive - 'ANOMALY' and 'Anomaly' must be one var")
check(#RDVars.definitions() == 2, "definitions() did not list both")
check(RDVars.definitions()[1].key == "anomaly",
    "definitions() is not sorted - an admin list would reshuffle between calls")
check(fs[DEFS_FILE] ~= nil, "defining a var did not write the defs file immediately")

-- Changing kind under a live name would strand every holder's state in the
-- wrong half of their record, silently.
check(RDVars.define{ kind = "counter", name = "Anomaly", resetOnDeath = true } == nil,
    "a char var was silently converted to a string var")

-- ---- markers -------------------------------------------------------------

reset()
defineAnomaly({ death = true })
check(RDVars.has("Kriegan", "Anomaly") == false, "has() was true before any grant")
check(RDVars.grant("Kriegan", "Anomaly", "Omen") == true, "grant failed")
check(RDVars.has("Kriegan", "Anomaly") == true, "has() false after a grant")
check(RDVars.has("Omen", "Anomaly") == false, "a grant leaked to another player")
check(RDVars.has(player("Kriegan"), "Anomaly") == true,
    "an IsoPlayer object did not resolve to the same record as its username")

local holders = RDVars.holders("Anomaly")
check(#holders == 1 and holders[1] == "Kriegan", "holders() did not report the grant")

check(RDVars.revoke("Kriegan", "Anomaly", "claimed anomaly_crossbow") == true, "revoke failed")
check(RDVars.has("Kriegan", "Anomaly") == false, "has() true after a revoke")
check(RDVars.revoke("Kriegan", "Anomaly") == nil, "revoking a marker nobody holds reported success")

-- Undefined vars are refused once, in one place, with a reason an admin can read.
local okGrant, why = RDVars.grant("Kriegan", "Nonexistent")
check(okGrant == nil and tostring(why):find("no var named", 1, true) ~= nil,
    "granting an undefined var was not refused clearly: " .. tostring(why))

-- The kinds do not borrow each other's verbs.
defineLoot(true)
check(RDVars.grant("Kriegan", "AnomalyLoot") == nil, "grant() worked on a counter")
check(select(1, RDVars.has("Kriegan", "AnomalyLoot")) == false, "has() claimed a counter was held")
check(RDVars.get("Kriegan", "Anomaly") == nil, "get() worked on a marker")

-- Re-granting refreshes the clock. An admin re-granting a timed marker means
-- "another four hours", not "nothing happened".
reset()
defineAnomaly({ expires = 60 })
RDVars.grant("Kriegan", "Anomaly")
clock = clock + 59 * 60000
RDVars.grant("Kriegan", "Anomaly")
clock = clock + 59 * 60000
RDVars.sweep()
check(RDVars.has("Kriegan", "Anomaly") == true,
    "a re-granted marker expired on the ORIGINAL grant time - the refresh was lost")

-- ---- counters: absent is not zero ---------------------------------------

reset()
defineLoot(false)
check(RDVars.get("Kriegan", "AnomalyLoot") == nil,
    "an untouched counter read as a value - 'never started' and 'started, back "
    .. "to nothing' are different answers and this collapses them")
check(RDVars.add("Kriegan", "AnomalyLoot", 1) == 1, "add() did not return the new value")
check(RDVars.add("Kriegan", "AnomalyLoot", 4) == 5, "add() did not accumulate")
check(RDVars.get("Kriegan", "AnomalyLoot") == 5, "get() disagreed with add()")
check(RDVars.add("Kriegan", "AnomalyLoot", -2) == 3, "add() refused a negative delta")
check(RDVars.set("Kriegan", "AnomalyLoot", 0) == 0, "set() to zero failed")
check(RDVars.get("Kriegan", "AnomalyLoot") == 0,
    "a counter SET to zero reads as absent - the distinction absent/zero is the "
    .. "single thing the two-kind split exists to preserve")
check(RDVars.reset("Kriegan", "AnomalyLoot") == true, "reset failed")
check(RDVars.get("Kriegan", "AnomalyLoot") == nil, "reset left a value instead of clearing to absent")
check(RDVars.set("Kriegan", "AnomalyLoot", "5") == nil, "set() accepted a string")
check(RDVars.add("Kriegan", "AnomalyLoot", 0 / 0) == nil, "add() accepted NaN")

-- The REASON, not just the refusal. These reach an admin panel verbatim, and
-- both of them used to be one sentence built with tostring - which prints the
-- string "5" and the number 5 identically, so "a counter takes a number, got 5"
-- read like a bug in the panel rather than like an answer. NaN is separated
-- because its type IS number, so the generic sentence contradicted itself.
check(tostring(select(2, RDVars.set("Kriegan", "AnomalyLoot", "5"))):find("string", 1, true),
    "the refusal did not name the type: "
    .. tostring(select(2, RDVars.set("Kriegan", "AnomalyLoot", "5"))))
check(tostring(select(2, RDVars.add("Kriegan", "AnomalyLoot", 0 / 0))):find("NaN", 1, true),
    "NaN was refused with the generic type message: "
    .. tostring(select(2, RDVars.add("Kriegan", "AnomalyLoot", 0 / 0))))
check(tostring(select(2, RDVars.set("Kriegan", "AnomalyLoot", nil))):find("nil", 1, true),
    "a nil value gave no usable reason")

-- INFINITY, which is the one that DISAPPEARS rather than misbehaving. Its type
-- is number and it compares equal to itself, so both earlier guards let it
-- through - and RDJson has no representation for it, encoding it as null which
-- decodes back to nil (verified against the real encoder). The counter then
-- reads normally until the mirror is replayed after a crash, and is gone.
check(RDVars.set("Kriegan", "AnomalyLoot", math.huge) == nil,
    "POSITIVE INFINITY was accepted into a counter. It survives in ModData and "
    .. "vanishes through the JSON mirror, so the value is present until the "
    .. "next restart and absent afterwards.")
check(RDVars.set("Kriegan", "AnomalyLoot", -math.huge) == nil,
    "negative infinity was accepted into a counter")
check(RDVars.add("Kriegan", "AnomalyLoot", math.huge) == nil,
    "add() accepted infinity where set() refused it")
check(tostring(select(2, RDVars.set("Kriegan", "AnomalyLoot", math.huge))):find("finite", 1, true),
    "infinity was refused with the wrong reason")
check(RDVars.set("Kriegan", "AnomalyLoot", 2^40) == 2^40,
    "a merely LARGE finite number was refused - the bound is finiteness, not size")
RDVars.set("Kriegan", "AnomalyLoot", 5)

-- valuesOf: holders() for counters. Same admin question of the other kind.
RDVars.set("Kriegan", "AnomalyLoot", 3)
RDVars.set("Astrid",  "AnomalyLoot", 0)
local vals = RDVars.valuesOf("AnomalyLoot")
check(#vals == 2, "valuesOf returned " .. #vals .. " rows, expected 2")
check(vals[1].user == "Astrid" and vals[1].value == 0,
    "valuesOf is not sorted by username, or it dropped a ZERO - zero is a value "
    .. "somebody was set to, and only absent means untouched")
check(vals[2].user == "Kriegan" and vals[2].value == 3, "valuesOf lost a value")
RDVars.reset("Astrid", "AnomalyLoot")
check(#RDVars.valuesOf("AnomalyLoot") == 1,
    "a reset counter still appeared in valuesOf - reset means ABSENT")
check(RDVars.valuesOf("Anomaly") == nil,
    "valuesOf answered for a MARKER - asking a counter question of a marker is "
    .. "a programming error, and holders() is the other half of the pair")
check(RDVars.valuesOf("NoSuchVar") == nil, "valuesOf answered for an undefined var")

-- ---- expiry --------------------------------------------------------------

reset()
defineAnomaly({ expires = 60 })
RDVars.grant("Kriegan", "Anomaly")

clock = clock + 59 * 60000
check(RDVars.sweep() == 0, "a marker expired one minute early")
check(RDVars.has("Kriegan", "Anomaly") == true, "a marker was taken before its expiry")

clock = clock + 1 * 60000                        -- exactly 60 minutes
check(RDVars.sweep() == 1, "the expiry did not fire AT the boundary")
check(RDVars.has("Kriegan", "Anomaly") == false, "an expired marker was still held")
check(RDVars.sweep() == 0, "sweeping again re-counted an already-expired marker")

-- The clock is wall time and NOT monotonic. Erring the other way here would
-- TAKE SOMETHING FROM A PLAYER, which is why this rule is the opposite of the
-- one RDConfigStore applies to its flush budget.
--
-- The property is structural rather than guarded - a negative elapsed cannot
-- reach a positive ms - so the mutation this pins is not "the guard was
-- deleted" but the shape that actually breaks it: comparing a MAGNITUDE.
-- Written after a mutation run showed an `elapsed >= 0` clause could be removed
-- with no test noticing, because it could never change an outcome.
reset()
defineAnomaly({ expires = 60 })
RDVars.grant("Kriegan", "Anomaly")
clock = clock - 24 * 60 * 60000                  -- NTP steps the clock back a day
check(RDVars.sweep() == 0,
    "a BACKWARDS clock step expired a live marker - an NTP correction would "
    .. "silently strip every timed grant on the server")
check(RDVars.has("Kriegan", "Anomaly") == true, "the marker was taken by a backwards clock")

-- ...and forward again. The grant must still be live: a clock that wandered and
-- came back has not consumed any of the marker's hour.
clock = clock + 24 * 60 * 60000
check(RDVars.sweep() == 0, "a marker expired after the clock returned to normal")
check(RDVars.has("Kriegan", "Anomaly") == true, "a round-trip clock excursion took the marker")

-- A marker with no expiry is never touched by the sweep, however long it runs.
reset()
defineAnomaly(nil)
RDVars.grant("Kriegan", "Anomaly")
clock = clock + 365 * 24 * 60 * 60000
check(RDVars.sweep() == 0, "a permanent marker expired")
check(RDVars.has("Kriegan", "Anomaly") == true, "a permanent marker was swept away after a year")

-- ---- death ---------------------------------------------------------------

reset()
RDVars.define{ kind = "char", name = "Temporary", revokers = { death = true } }
RDVars.define{ kind = "char", name = "Keeper" }
RDVars.define{ kind = "counter", name = "Fragile", resetOnDeath = true }
RDVars.define{ kind = "counter", name = "Durable", resetOnDeath = false }

RDVars.grant("Kriegan", "Temporary")
RDVars.grant("Kriegan", "Keeper")
RDVars.set("Kriegan", "Fragile", 7)
RDVars.set("Kriegan", "Durable", 9)
RDVars.grant("Omen", "Temporary")

onDeath(player("Kriegan"))

check(RDVars.has("Kriegan", "Temporary") == false, "a death-revoked marker survived death")
check(RDVars.has("Kriegan", "Keeper") == true,
    "a marker that did NOT declare death as a revoker was taken anyway - a var "
    .. "goes nowhere on death unless it said it would")
check(RDVars.get("Kriegan", "Fragile") == nil, "resetOnDeath = true did not reset")
check(RDVars.get("Kriegan", "Durable") == 9, "resetOnDeath = false was reset anyway")
check(RDVars.has("Omen", "Temporary") == true, "another player's markers were cleared by this death")

-- The handler fires for every character in the world.
onDeath(zombie())
onDeath({ __class = "IsoAnimal" })
check(RDVars.has("Omen", "Temporary") == true, "a zombie's death touched player state")

-- ---- ofPlayer ------------------------------------------------------------

reset()
defineAnomaly({ expires = 60 })
defineLoot(true)
RDVars.grant("Kriegan", "Anomaly", "Omen")
RDVars.set("Kriegan", "AnomalyLoot", 3)

local view = RDVars.ofPlayer("Kriegan")
check(view.username == "Kriegan", "ofPlayer lost the username")
check(#view.chars == 1 and view.chars[1].name == "Anomaly",
    "ofPlayer did not report the marker under its authored spelling")
check(view.chars[1].by == "Omen", "ofPlayer lost the granting admin")
check(view.chars[1].expiresMs == 60 * 60000, "ofPlayer did not join the definition's expiry")
check(#view.numbers == 1 and view.numbers[1].value == 3, "ofPlayer lost the counter")

-- A panel that holds a reference to the live record can corrupt the store by
-- rendering.
view.chars[1].name = "Tampered"
view.numbers[1].value = 999
check(RDVars.ofPlayer("Kriegan").chars[1].name == "Anomaly"
    and RDVars.get("Kriegan", "AnomalyLoot") == 3,
    "ofPlayer handed back the live record - editing the view mutated the store")

-- ---- undefine purges, and that is the point -----------------------------
-- Orphaned state means redefining the same name next season silently
-- resurrects last season's holders.

reset()
defineAnomaly({ death = true })
RDVars.grant("Kriegan", "Anomaly")
RDVars.grant("Omen", "Anomaly")
local okUndef, touched = RDVars.undefine("Anomaly")
check(okUndef == true and touched == 2, "undefine did not report the players it affected")
check(RDVars.definition("Anomaly") == nil, "the definition survived undefine")

defineAnomaly({ death = true })                  -- a year later, same name
check(RDVars.has("Kriegan", "Anomaly") == false,
    "REDEFINING A PURGED VAR RESURRECTED LAST SEASON'S HOLDERS - orphaned state "
    .. "was left behind by undefine")

-- ---- persistence ---------------------------------------------------------
-- The store is what makes any of this survive a restart, so the seam is worth
-- one end-to-end assertion rather than trusting two green fixtures separately.

reset()
defineAnomaly({ death = true })
defineLoot(false)
RDVars.grant("Kriegan", "Anomaly", "Omen")
RDVars.set("Kriegan", "AnomalyLoot", 5)
RDVars.store():flush()
check(fs[STATE_FILE] ~= nil and fs[STATE_FILE]:find("Kriegan", 1, true) ~= nil,
    "the state file does not carry the grant")

-- A restart where the world save kept ModData but the mirror is newer: the
-- crash-recovery path.
local defsOnDisk, stateOnDisk = fs[DEFS_FILE], fs[STATE_FILE]
reset()
fs[DEFS_FILE], fs[STATE_FILE] = defsOnDisk, stateOnDisk
modDataMap["RFTDVars"] = { defs = {}, state = {}, meta = { defsMs = 1, stateMs = 1 } }
check(RDVars.definition("Anomaly") ~= nil, "definitions did not come back after a restart")
check(RDVars.has("Kriegan", "Anomaly") == true, "a grant did not survive a restart")
check(RDVars.get("Kriegan", "AnomalyLoot") == 5, "a counter did not survive a restart")
check(RDVars.ofPlayer("Kriegan").chars[1].by == "Omen",
    "the granting admin was lost in the round trip")

-- A wipe: the files outlive the save, ModData does not. Nothing may come back
-- on its own, or players keep every marker they spent last season.
reset()
fs[DEFS_FILE], fs[STATE_FILE] = defsOnDisk, stateOnDisk
check(RDVars.has("Kriegan", "Anomaly") == false,
    "A WIPE CARRIED PLAYER STATE FORWARD - the marker survived a world with no "
    .. "ModData, which is the exploit save-scoping exists to prevent")
check(RDVars.definition("Anomaly") == nil,
    "definitions were auto-loaded into a wiped world - the admin imports them "
    .. "deliberately, and the store holds the file until they do")

print = realPrint
realPrint(string.format("RDVars: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
