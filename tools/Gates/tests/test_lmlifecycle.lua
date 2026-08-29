-- test_lmlifecycle.lua - the three LMCore surfaces added 2026-08-04, under real Lua 5.1.
--
-- Separate from test_lmcore.lua on purpose: the runner starts one interpreter
-- per suite, so this file gets a PRISTINE store and registry. seedIfEmpty is
-- only honest against a genuinely empty store, and the side tags want a
-- registry nobody else has written to.
--
-- What this pins, and why it matters live:
--
--   SEED       templates only, seeded once into an empty store, never merged on
--              a later boot. A merge would resurrect templates an admin deleted;
--              a missing copy would make the shipped constant the live store and
--              the first edit would rewrite the defaults for the next server.
--   LIFECYCLE  per-zone added/edited/enabled/disabled/deleted (§5.1). LMStats
--              modulates GLOBAL sandbox values by the local player's zone and
--              restores on exit - disable or delete that zone under a standing
--              player and the restore never fires, so the sandbox stays bent for
--              the rest of the session. These events are that undo signal, and
--              they are DERIVED from state so they never cost a packet.
--   SIDE       server-only fields must not ride to clients (join bytes, and loot
--              tables sitting in every client's memory), but resolver-critical
--              fields MUST, or the two sides resolve differently in silence.
--
-- Usage (normally via tools\run-tests.bat):
--   lua5.1.exe tools/tests/test_lmlifecycle.lua <repo-root>

local ROOT = arg[1] or "."
local SRC  = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDLimes/42/media/lua/shared/LMCore.lua"

local okLoad, err = pcall(dofile, SRC)
if not okLoad then
    print("FATAL: could not load " .. SRC)
    print("  " .. tostring(err))
    os.exit(2)
end

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
local function isTrue(name, cond, detail)
    if cond then pass = pass + 1
    else fail = fail + 1; print("FAIL " .. name .. ": " .. tostring(detail)) end
end

-- ---------------------------------------------------------------------------
-- Seed (§8.1) - first, while the store is genuinely empty
-- ---------------------------------------------------------------------------

eq("store starts empty",          #Limes.zoneNames(), 0)
eq("seedIfEmpty seeds",           Limes.seedIfEmpty(), true)
eq("seeded the shipped set",      #Limes.zoneNames(), 6)
eq("_default is a real record",   Limes.getZone("_default").name, "_default")
eq("_default stands on Medium",   Limes.getZone("_default").tier, "Medium")
eq("the rungs are tier records",  Limes.getZone("IDDQL").kind, "tier")
eq("top rung ranks 5",            Limes.getZone("IDDQL").fields.rank, 5)
eq("bottom rung ranks 1",         Limes.getZone("Newcomer").fields.rank, 1)
eq("rungs are terminal, not chained", Limes.getZone("IDDQL").inherits, nil)

-- Templates only: no geometry anywhere in the seed, so nothing it ships can
-- claim a tile out from under an admin who never referenced it.
local anyGeometry = false
for _, n in ipairs(Limes.zoneNames()) do
    if not Limes.getZone(n).template then anyGeometry = true end
end
eq("seed ships no geometry",      anyGeometry, false)
eq("seed claims no tiles",        Limes.getLocation(1000, 1000), nil)

eq("seedIfEmpty is a no-op when populated", Limes.seedIfEmpty(), false)
eq("no-op did not duplicate",     #Limes.zoneNames(), 6)

-- The copy is the whole point: without it the module constant IS the live
-- store, and the first admin edit rewrites the defaults every later server ships.
Limes.raw()["_default"].tier = "IDDQL"
eq("SEED constant untouched by store edits", Limes.SEED._default.tier, "Medium")

-- A deleted template stays deleted across a later seed attempt.
Limes.applyDelta(nil, { "Medium" }, 2)
eq("template deleted",            Limes.getZone("Medium"), nil)
eq("seed does not resurrect",     Limes.seedIfEmpty(), false)
eq("still deleted",               Limes.getZone("Medium"), nil)

-- ---------------------------------------------------------------------------
-- Zone centre - "take me there" must land INSIDE the zone
-- ---------------------------------------------------------------------------

Limes.apply({
    -- Two far-apart rects: the bounding-box centre sits in empty space between
    -- them, which is the bug this function exists to avoid. HavenOutpost in the
    -- live layer is exactly this shape.
    Split = { rects = { { 0, 0, 9, 9 }, { 1000, 1000, 1019, 1019 } }, fields = {} },
    -- An L: box centre is in the notch.
    Elbow = { rects = { { 0, 0, 99, 9 }, { 0, 0, 9, 99 } }, fields = {} },
    Solid = { rects = { { 200, 200, 209, 209 } }, fields = {} },
    Tmpl  = { rects = {}, fields = {} },
}, 100)

local function centreIsInside(name)
    local cx, cy = Limes.getZoneCenter(name)
    if not cx then return false end
    local z = Limes.getZone(name)
    for _, r in ipairs(z.rects) do
        if cx >= r[1] and cx <= r[3] and cy >= r[2] and cy <= r[4] then return true end
    end
    return false
end

eq("solid zone centre",           select(1, Limes.getZoneCenter("Solid")), 204)
isTrue("split zone centre is inside", centreIsInside("Split"),
    "bounding-box centre would land in the empty space between the two rects")
isTrue("L-shaped centre is inside",   centreIsInside("Elbow"),
    "bounding-box centre would land in the notch")
eq("largest rect wins",           select(1, Limes.getZoneCenter("Split")), 1009)
eq("template has no centre",      Limes.getZoneCenter("Tmpl"), nil)
eq("unknown zone has no centre",  Limes.getZoneCenter("Nope"), nil)

-- The lookup must agree: standing at the centre puts you in that zone.
local cx, cy = Limes.getZoneCenter("Solid")
eq("centre resolves back to the zone", Limes.getLocation(cx, cy).name, "Solid")

-- ---------------------------------------------------------------------------
-- Lifecycle events (§5.1)
-- ---------------------------------------------------------------------------

Limes.fields.register("T", "hp", { type = "number", default = 0 })

-- Start from a known-empty store: the seed above is still resident and would
-- otherwise report as deletions in the first assertion below. Done before the
-- recorder is attached so it captures nothing.
Limes.apply({}, 9)

local events = {}
Limes.onZoneEvent(function(ev, name, zone, rev)
    events[#events + 1] = { ev = ev, name = name, zone = zone, rev = rev }
end)
local function reset() events = {} end
local function names()
    local out = {}
    for i = 1, #events do out[i] = events[i].ev .. ":" .. events[i].name end
    return table.concat(out, ",")
end

reset()
Limes.apply({
    Zeta  = { rects = { { 0, 0, 9, 9 } },       fields = { hp = 1 } },
    Alpha = { rects = { { 20, 20, 29, 29 } },   fields = { hp = 2 } },
}, 10)
-- Name-sorted, so both machines fire the same sequence from the same baseline.
eq("adds fire name-sorted",       names(), "added:Alpha,added:Zeta")
eq("event carries the revision",  events[1].rev, 10)
eq("event carries the record",    events[1].zone.name, "Alpha")

-- Content-based diff: a redundant baseline (the gap re-pull that turns out to
-- match) must be silent, or every reconnect storms the consumers.
reset()
Limes.apply({
    Zeta  = { rects = { { 0, 0, 9, 9 } },       fields = { hp = 1 } },
    Alpha = { rects = { { 20, 20, 29, 29 } },   fields = { hp = 2 } },
}, 11)
eq("identical baseline is silent", #events, 0)

reset()
Limes.applyDelta({ Alpha = { rects = { { 20, 20, 29, 29 } }, fields = { hp = 5 } } }, nil, 12)
eq("field change reports edited", names(), "edited:Alpha")
eq("edited carries new value",    events[1].zone.fields.hp, 5)

reset()
Limes.applyDelta({ Alpha = { rects = { { 20, 20, 39, 39 } }, fields = { hp = 5 } } }, nil, 13)
eq("geometry change reports edited", names(), "edited:Alpha")

-- Disable is a transition, not an edit: it is the actionable half for anything
-- holding a standing side effect.
reset()
Limes.applyDelta({ Alpha = { rects = { { 20, 20, 39, 39 } }, fields = { hp = 5, disabled = true } } }, nil, 14)
eq("disable reports disabled",    names(), "disabled:Alpha")
eq("disabled zone leaves lookup", Limes.getLocation(25, 25), nil)
eq("disabled zone still readable", Limes.getZone("Alpha").disabled, true)

reset()
Limes.applyDelta({ Alpha = { rects = { { 20, 20, 39, 39 } }, fields = { hp = 5 } } }, nil, 15)
eq("re-enable reports enabled",   names(), "enabled:Alpha")
eq("re-enabled zone is findable", Limes.getLocation(25, 25).name, "Alpha")

-- Transition wins over edit when one delta does both - one event per zone.
reset()
Limes.applyDelta({ Alpha = { rects = { { 20, 20, 39, 39 } }, fields = { hp = 77, disabled = true } } }, nil, 16)
eq("transition outranks edit",    names(), "disabled:Alpha")
eq("exactly one event for the zone", #events, 1)

reset()
Limes.applyDelta(nil, { "Alpha" }, 17)
eq("removal reports deleted",     names(), "deleted:Alpha")
isTrue("deleted carries last-known record",
    events[1].zone and events[1].zone.rects and #events[1].zone.rects == 1,
    "a consumer unwinding a standing effect needs the geometry that just vanished")

-- Inheritance: a template edit changes a child's EFFECTIVE config even though
-- the child's own raw record never moved. Diffing resolved records catches it.
-- A wholesale apply also reports what the new store DROPPED - Zeta survived
-- the delta above and is not in this set, so it must arrive as a deletion.
-- Anything less and a baseline swap would silently strand standing effects.
reset()
Limes.apply({
    Tmpl = { rects = {},                    fields = { hp = 1 } },
    Kid  = { inherits = "Tmpl", rects = { { 0, 0, 9, 9 } }, fields = {} },
}, 20)
eq("apply adds new and drops absent", names(), "added:Kid,added:Tmpl,deleted:Zeta")

reset()
Limes.applyDelta({ Tmpl = { rects = {}, fields = { hp = 9 } } }, nil, 21)
eq("template edit reports both",  names(), "edited:Kid,edited:Tmpl")
eq("child inherited the new value", Limes.getZone("Kid").fields.hp, 9)

-- A listener that throws must not silence the ones behind it: one broken
-- satellite cannot be allowed to strand every other consumer's teardown.
local reached = false
Limes.onZoneEvent(function() error("listener boom") end)
Limes.onZoneEvent(function() reached = true end)
reset()
Limes.applyDelta({ Solo = { rects = { { 50, 50, 59, 59 } }, fields = {} } }, nil, 22)
eq("events survive a throwing listener", names(), "added:Solo")
isTrue("later listeners still run", reached, "a pcall per listener, not per event")

-- ---------------------------------------------------------------------------
-- Field side tags + wire strip (§5, §6)
-- ---------------------------------------------------------------------------

-- A SYNTHETIC name, not a real one. This block used `lewtkey` as its
-- server-only example because that is what a server-only field looked like -
-- right up until LMCore declared the zone policy vocabulary and claimed it (as
-- "both", so the editor can show it). First-claim-wins then made the
-- registration fail and four assertions here went red for a reason that had
-- nothing to do with sides. A name no module will ever want cannot be taken.
eq("server-only registers", Limes.fields.register("T", "secretLoot", { type = "string",  side = "server" }), true)
eq("client-only registers", Limes.fields.register("T", "banner",   { type = "string",  side = "client" }), true)
eq("both registers",        Limes.fields.register("T", "shared",   { type = "number",  side = "both"   }), true)
eq("side defaults to both", Limes.fields.register("T", "untagged", { type = "number" }), true)
eq("default side recorded", Limes.fields.spec("untagged").side, "both")

-- Correcting a bad side upward, never downward: over-sending costs bytes,
-- under-sending is a correctness bug.
eq("nonsense side accepted", Limes.fields.register("T", "weird", { type = "number", side = "sideways" }), true)
eq("nonsense side widened",  Limes.fields.spec("weird").side, "both")

-- Resolver-critical fields must reach every machine or the two sides resolve
-- differently in silence. Same owner, so it gets past the cross-owner guard.
eq("resolver-critical re-register allowed",
    Limes.fields.register("LMCore", "disabled", { type = "boolean", default = false, side = "server" }), true)
eq("resolver-critical forced to both", Limes.fields.spec("disabled").side, "both")
eq("priority is both",                 Limes.fields.spec("priority").side, "both")

eq("list exposes side", (function()
    for _, f in ipairs(Limes.fields.list()) do
        if f.name == "secretLoot" then return f.side end
    end
end)(), "server")

local store = {
    Gunstore = {
        inherits = "_default",
        rects    = { { 0, 0, 9, 9 } },
        fields   = { secretLoot = "GunStores", banner = "Gun Store", shared = 3,
                     mystery = "unregistered", disabled = false },
    },
    ServerOnlyZone = { rects = { { 10, 10, 19, 19 } }, fields = { secretLoot = "Ammos" } },
}
local wire = Limes.fields.stripServerOnly(store)

eq("server-only field stripped",  wire.Gunstore.fields.secretLoot, nil)
eq("client-only field kept",      wire.Gunstore.fields.banner, "Gun Store")
eq("both-sided field kept",       wire.Gunstore.fields.shared, 3)
eq("unregistered field kept",     wire.Gunstore.fields.mystery, "unregistered")
eq("resolver-critical kept",      wire.Gunstore.fields.disabled, false)
eq("inherits survives",           wire.Gunstore.inherits, "_default")
eq("geometry survives",           wire.Gunstore.rects[1][3], 9)

-- A zone stripped to nothing still ships: the client needs its geometry for
-- lookup and its name for anyone inheriting from it.
isTrue("emptied zone still present", wire.ServerOnlyZone ~= nil, "geometry and chain position still matter")
-- pairs(), not next(): Kahlua has no global `next`, and a test should not model
-- an idiom that would throw in the engine the code actually runs on.
eq("emptied zone has no fields left", (function()
    for k in pairs(wire.ServerOnlyZone.fields) do return k end
end)(), nil)
eq("emptied zone kept geometry",      wire.ServerOnlyZone.rects[1][1], 10)

-- The live store must be untouched: handing the serializer a table with fields
-- deleted out of it would strip the SERVER's own data.
eq("source store not mutated",      store.Gunstore.fields.secretLoot, "GunStores")
eq("source store intact elsewhere", store.ServerOnlyZone.fields.secretLoot, "Ammos")
isTrue("strip returns a new table",  wire.Gunstore ~= store.Gunstore, "same record object would alias the store")

-- ---------------------------------------------------------------------------
-- The phase flip (M-B, 2026-08-07): a moon change is a refresh, and a refresh
-- speaks entirely through the EXISTING event vocabulary. This is the
-- LMZeds-sweep pin - LMZeds keys its standing sweep off "edited"/"enabled",
-- so the exact event list here IS the contract that zombies get swept the
-- moment a full-moon zeds profile switches on.
-- ---------------------------------------------------------------------------

local realRequire = require
require = function() end
dofile(ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDLimes/42/media/lua/shared/LMMoon.lua")
require = realRequire

local PHASE = 0
LMMoon.setProvider(function() return PHASE end)

-- The base value lives on _default, NOT on Graveyard itself: a zone's own
-- field beats its profiles by design, so a profile can only ever override
-- what the zone INHERITS. Getting this wrong in the first draft of this test
-- was a free demonstration that the precedence pins hold.
Limes.apply({
    _default  = { fields = { hp = 1 } },
    BloodMoon = { fields = { hp = 66, phases = "full" } },
    Graveyard = { rects = { { 0, 0, 9, 9 } },  profiles = { "BloodMoon" }, fields = {} },
    Plain     = { rects = { { 50, 50, 59, 59 } }, fields = { hp = 2 } },
    Vanish    = { rects = { { 90, 90, 99, 99 } }, profiles = { "Curfew" }, fields = {} },
    Curfew    = { fields = { disabled = true, phases = "full" } },
}, 50)

eq("off-phase, the profile is dormant", Limes.getZone("Graveyard").fields.hp, 1)
eq("off-phase, the curfew zone answers lookups", Limes.getLocation(95, 95).name, "Vanish")

local revBefore = Limes.revision
reset()
PHASE = 4                                  -- the full moon rises
Limes.refresh()

eq("the flip edits the phased zone and disables the curfew zone",
   names(), "edited:Graveyard,disabled:Vanish")
eq("the profile's value is now in force",   Limes.getZone("Graveyard").fields.hp, 66)
eq("the curfew zone left the lookup",       Limes.getLocation(95, 95), nil)
eq("an unphased zone fired nothing",        true, true)  -- names() above pins Plain absent
eq("refresh does NOT move the revision",    Limes.revision, revBefore)
eq("events carry the unmoved revision",     events[1].rev, revBefore)

reset()
Limes.refresh()
eq("a refresh with no phase change diffs to nothing", names(), "")

reset()
PHASE = 5                                  -- the moon wanes
Limes.refresh()
eq("the flip back reverses both",
   names(), "edited:Graveyard,enabled:Vanish")
eq("the profile's value withdrew", Limes.getZone("Graveyard").fields.hp, 1)

-- The watcher drives exactly this, off its own cached diff.
reset()
PHASE = 4
LMMoon.poll()
eq("the watcher refreshes on a change", names(), "edited:Graveyard,disabled:Vanish")
reset()
LMMoon.poll()
eq("...and not without one", names(), "")

-- An unknowable sky: phased profiles go dormant, deterministically.
reset()
LMMoon.setProvider(function() return nil end)
LMMoon.poll()
eq("losing the clock deactivates phased profiles",
   names(), "edited:Graveyard,enabled:Vanish")
eq("...dormant means the base value", Limes.getZone("Graveyard").fields.hp, 1)

print(string.format("LMLifecycle: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)

-- ---------------------------------------------------------------------------
-- Copyright Project_Omen
