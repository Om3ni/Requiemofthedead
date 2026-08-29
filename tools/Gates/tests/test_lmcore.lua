-- test_lmcore.lua - behavioural tests for the Limes zone store under real Lua 5.1.
--
-- LMCore is deliberately engine-free (see its header), so it runs here with no
-- stubs. What this pins, and why it matters live:
--
--   RESOLVER   inheritance flattening, the implicit _default root, cycle guard,
--              unknown-parent tolerance. A resolver defect is invisible in-game
--              until an admin wonders why one district ignores its template.
--   REGISTRY   type coercion and clamping - PhunZones data arrives stringly
--              ("25"), consumers must read numbers; "" must INHERIT, not zero.
--   LOOKUP     smallest-area-wins nesting, priority tiebreak, edge inclusivity.
--              The gun-store-inside-Louisville case is the entire reason zones
--              can nest; an off-by-one on a border tile moves a player's rules.
--   DELTA      applyDelta re-resolves everything - one changed template must
--              reshape its children, and removal must actually remove.
--
-- Usage (normally via tools\run-tests.bat):
--   lua5.1.exe tools/tests/test_lmcore.lua <repo-root>

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
-- Field registry
-- ---------------------------------------------------------------------------

eq("register a number field", Limes.fields.register("T", "hp", { type = "number", default = 5, min = 0, max = 10 }), true)
eq("reserved name refused",   Limes.fields.register("T", "rects", { type = "string" }), false)
eq("bad type refused",        Limes.fields.register("T", "x1", { type = "table" }), false)
eq("cross-owner claim refused", Limes.fields.register("T2", "hp", { type = "string" }), false)
eq("claim survives the refusal", Limes.fields.spec("hp").type, "number")
eq("same-owner re-register ok",  Limes.fields.register("T", "hp", { type = "number", default = 7 }), true)
eq("re-register updated default", Limes.fields.spec("hp").default, 7)

-- ---------------------------------------------------------------------------
-- Presentation vocabulary (the `ui` contract, §11.3)
--
-- The registry carries presentation but never interprets it, so what these pin
-- is that it carries the WHOLE of it. A key the panel needs and register()
-- forgets to copy is invisible here and shows up in game as a dial that silently
-- loses its options - the failure mode `values`/`labels` is most exposed to,
-- because a choice with no values is a pill that cannot be clicked out of its
-- current setting.
-- ---------------------------------------------------------------------------

local function listed(owner, name)
    for _, s in ipairs(Limes.fields.list(owner)) do
        if s.name == name then return s end
    end
    return nil
end

local zeds = Limes.fields.spec("zeds")
eq("zeds is a choice",            zeds.ui, "choice")
eq("zeds stores strings",         zeds.type, "string")
eq("zeds offers three positions", #zeds.values, 3)
eq("blank is the first position", zeds.values[1], "")
eq("zeds honours 'none'",         zeds.values[2], "none")
eq("zeds honours 'remove'",       zeds.values[3], "remove")
-- Parallel arrays or the pill shows the wrong word for the value it holds.
eq("every zeds value has a label", #zeds.labels, #zeds.values)
-- The two words LMZeds actually branches on. If either is renamed here without
-- LMZeds agreeing, the field goes inert with nothing to show for it.
isTrue("no zeds label is blank",
    zeds.labels[1] ~= "" and zeds.labels[2] ~= "" and zeds.labels[3] ~= "",
    "a blank label renders as an empty pill")

local zedsRow = listed("LMCore", "zeds")
eq("list carries ui",     zedsRow.ui, "choice")
eq("list carries values", zedsRow.values[3], "remove")
eq("list carries labels", zedsRow.labels[1], zeds.labels[1])

local title = Limes.fields.spec("title")
eq("title is free text",     title.ui, "text")
eq("title says what empty means", title.empty, "(the zone's name)")
isTrue("title states a rule", type(title.rule) == "string" and title.rule ~= "",
    "a text field with no rule gives the popout nothing to say")
eq("title caps its length",  title.maxLen, 64)
eq("list carries empty",     listed("LMCore", "title").empty, title.empty)
eq("list carries maxLen",    listed("LMCore", "title").maxLen, 64)
eq("list carries rule",      listed("LMCore", "title").rule, title.rule)

-- lewtkey and the sprinter band retired with S2 (2026-08-27): unregistered,
-- stripped by migration. Pinned ABSENT so a nostalgic re-registration shows up.
eq("lewtkey is retired",         Limes.fields.spec("lewtkey"), nil)
eq("the sprinter band is retired", Limes.fields.spec("minSprinterRisk"), nil)

-- maxLen is coerced to a number, so a registrant passing "64" cannot hand the
-- entry box a string where it will compare against one.
eq("maxLen is numeric", type(title.maxLen), "number")
Limes.fields.register("T", "strLen", { type = "string", maxLen = "12" })
eq("stringly maxLen coerced", Limes.fields.spec("strLen").maxLen, 12)

-- A `ui` this build has never heard of is CARRIED, not dropped: the registry is
-- forward-compatible by design and the panel is what decides it cannot draw one.
Limes.fields.register("T", "tint", { type = "string", ui = "colour" })
eq("unknown ui preserved", Limes.fields.spec("tint").ui, "colour")
eq("unknown ui reaches the list", listed("T", "tint").ui, "colour")

-- Coercion is by declared TYPE and ignores ui, so a choice stays a string even
-- when its value looks like something else.
Limes.apply({ Cast = { rects = { { 500, 500, 509, 509 } }, fields = { zeds = "remove" } } }, 2)
eq("choice value survives as a string",
   Limes.getZone("Cast").fields.zeds, "remove")

-- ---------------------------------------------------------------------------
-- Apply + resolution
-- ---------------------------------------------------------------------------

-- `risk` stands where `tier` used to in these fixtures: tier stopped being a
-- number field with the record-kind model (it is the SLOT now, pinned in its
-- own section below), and these lines test coercion/clamping, not tiers.
Limes.fields.register("T", "risk", { type = "number", default = 0, min = 0, max = 10 })

local warnings = Limes.apply({
    _default  = { rects = {}, fields = { risk = 1, title = "Somewhere" } },
    Hard      = { rects = {}, fields = { risk = "4", hp = "8" } },            -- stringly, template
    City      = { inherits = "Hard",
                  rects = { { 0, 0, 99, 99 } },
                  fields = { title = "The City" } },
    GunStore  = { inherits = "City",
                  rects = { { 10, 10, 19, 19 } },
                  fields = { risk = "99", mystery = "keep-me" } },            -- 99 clamps to 10
    Annex     = { rects = { { 200, 0, 249, 24 }, { 250, 0, 299, 24 } },       -- multi-rect
                  fields = { hp = "" } },                                     -- "" = inherit (unset)
    Loop1     = { inherits = "Loop2", rects = {}, fields = {} },
    Loop2     = { inherits = "Loop1", rects = {}, fields = {} },
    Orphan    = { inherits = "NoSuchZone", rects = { { 400, 400, 409, 409 } }, fields = {} },
    Ghost     = { rects = { { 500, 500, 509, 509 } }, fields = { disabled = true } },
}, 1)

eq("revision stamped", Limes.revision, 1)

local city = Limes.getZone("City")
eq("child sees template field",        city.fields.risk, 4)
eq("stringly number coerced",          city.fields.hp, 8)
eq("own field wins over chain",        city.fields.title, "The City")
eq("_default reaches everyone",        Limes.getZone("Annex").fields.title, "Somewhere")
eq("'' inherits instead of zeroing",   Limes.getZone("Annex").fields.hp, nil)
eq("clamp applies on resolve",         Limes.getZone("GunStore").fields.risk, 10)
eq("unknown key preserved verbatim",   Limes.getZone("GunStore").fields.mystery, "keep-me")
eq("template flagged",                 Limes.getZone("Hard").template, true)
eq("geometry zone not a template",     city.template, false)
eq("multi-rect area sums",             Limes.getZone("Annex").area, 2500)

local sawCycle, sawOrphan = false, false
for i = 1, #warnings do
    if warnings[i]:find("cycle") then sawCycle = true end
    if warnings[i]:find("NoSuchZone") then sawOrphan = true end
end
isTrue("cycle warned",          sawCycle, "no cycle warning in apply()")
isTrue("unknown parent warned", sawOrphan, "no unknown-parent warning")

-- ---------------------------------------------------------------------------
-- Lookup
-- ---------------------------------------------------------------------------

eq("plain hit",                 Limes.getLocation(50, 50).name, "City")
eq("nested: smaller zone wins", Limes.getLocation(15, 15).name, "GunStore")
eq("outside everything",        Limes.getLocation(1000, 1000), nil)
eq("template never matches",    Limes.getLocation(-5000, -5000), nil)
eq("disabled zone never matches", Limes.getLocation(505, 505), nil)
eq("second rect of a zone hits", Limes.getLocation(260, 10).name, "Annex")
eq("orphan still resolves and matches", Limes.getLocation(405, 405).name, "Orphan")

-- Edge inclusivity: all four borders belong to the zone.
eq("left/top corner inclusive",     Limes.getLocation(0, 0).name, "City")
eq("right/bottom corner inclusive", Limes.getLocation(99, 99).name, "City")
eq("one past the border misses",    Limes.getLocation(100, 100), nil)
eq("nested zone border inclusive",  Limes.getLocation(19, 19).name, "GunStore")
eq("one past nested border falls to parent", Limes.getLocation(20, 20).name, "City")

-- fields.get: default when unset or outside any zone
eq("fields.get set value",       Limes.fields.get(Limes.getZone("City"), "hp"), 8)
eq("fields.get registry default", Limes.fields.get(Limes.getZone("Annex"), "hp"), 7)
eq("fields.get nil zone",        Limes.fields.get(nil, "hp"), 7)

-- ---------------------------------------------------------------------------
-- Overlap arbitration: equal area -> priority -> name
-- ---------------------------------------------------------------------------

Limes.apply({
    Alpha = { rects = { { 0, 0, 9, 9 } }, fields = {} },
    Beta  = { rects = { { 0, 0, 9, 9 } }, fields = { priority = 5 } },
}, 2)
eq("priority breaks equal area", Limes.getLocation(5, 5).name, "Beta")

Limes.apply({
    Zed   = { rects = { { 0, 0, 9, 9 } }, fields = {} },
    Aleph = { rects = { { 0, 0, 9, 9 } }, fields = {} },
}, 3)
eq("name breaks the full tie deterministically", Limes.getLocation(5, 5).name, "Aleph")

-- ---------------------------------------------------------------------------
-- Scattered multi-rect: one name in several places is several INDEPENDENT
-- claims, arbitrated by the rect covering the tile and never by the zone's
-- summed footprint.
--
-- This is the case the old total-area rule got wrong. Guns holds five 400-tile
-- patches (2000 summed) and Warehouse is a single 1521-tile rect containing the
-- first patch. By total area Warehouse (1521) beat Guns (2000) on Guns' own
-- ground; by covering rect Guns (400) wins its patch and Warehouse keeps
-- everything around it - and, critically, patches two through five cannot
-- change the answer at patch one.
-- ---------------------------------------------------------------------------

Limes.apply({
    Warehouse = { rects = { { 0, 0, 38, 38 } }, fields = {} },          -- 39x39 = 1521
    Guns      = { rects = { { 10, 10, 29, 29 },                          -- 20x20 = 400, inside Warehouse
                            { 200, 200, 219, 219 },                      -- 400, elsewhere
                            { 400, 400, 419, 419 },                      -- 400
                            { 600, 600, 619, 619 },                      -- 400
                            { 800, 800, 819, 819 } },                    -- 400  (2000 summed)
                  fields = {} },
}, 4)

eq("multi-rect total is still the summed footprint", Limes.getZone("Guns").area, 2000)
eq("smaller covering rect wins inside the larger zone", Limes.getLocation(15, 15).name, "Guns")
eq("larger zone keeps the ground around the hole",     Limes.getLocation(5, 5).name,   "Warehouse")
eq("a distant patch of the same name still matches",   Limes.getLocation(610, 610).name, "Guns")
eq("border of the inner patch is inclusive",           Limes.getLocation(29, 29).name, "Guns")
eq("one tile past the patch falls back to the larger", Limes.getLocation(30, 30).name, "Warehouse")

-- Placement is independent: dropping the four remote patches must not change
-- the verdict at the first one. Under the old rule it did - Guns' total fell
-- from 2000 to 400 and flipped tile (15,15) from Warehouse to Guns.
Limes.apply({
    Warehouse = { rects = { { 0, 0, 38, 38 } }, fields = {} },
    Guns      = { rects = { { 10, 10, 29, 29 } }, fields = {} },
}, 5)
eq("verdict unchanged when the other placements go away",
   Limes.getLocation(15, 15).name, "Guns")

-- ---------------------------------------------------------------------------
-- Deltas
-- ---------------------------------------------------------------------------

Limes.apply({
    Tmpl = { rects = {}, fields = { hp = 3 } },
    Kid  = { inherits = "Tmpl", rects = { { 0, 0, 9, 9 } }, fields = {} },
    Doom = { rects = { { 100, 100, 109, 109 } }, fields = {} },
}, 10)

local changed = Limes.onChanged and 0 or nil
Limes.onChanged(function() changed = (changed or 0) + 1 end)

Limes.applyDelta({ Tmpl = { rects = {}, fields = { hp = 9 } } }, { "Doom" }, 11)
eq("delta revision",                    Limes.revision, 11)
eq("template edit reshapes children",   Limes.getZone("Kid").fields.hp, 9)
eq("removed zone gone from lookup",     Limes.getLocation(105, 105), nil)
eq("removed zone gone from store",      Limes.getZone("Doom"), nil)
eq("onChanged fired once for the delta", changed, 1)

-- Reversed-corner rects normalize rather than vanish.
Limes.apply({ Rev = { rects = { { 9, 9, 0, 0 } }, fields = {} } }, 20)
eq("reversed rect corners normalize", Limes.getLocation(5, 5).name, "Rev")

-- ---------------------------------------------------------------------------
-- Profiles (M-A, 2026-08-07): flat bags in the resolver.
--
-- The one-sentence contract under test: every record in the spatial chain
-- contributes its active profiles' OWN raw fields (array order, later wins),
-- then its own fields - and nothing of a profile's is followed beyond that.
-- The precedence ladder below is the normative order from the plan; if it
-- moves, client and server resolve differently, which is the worst class of
-- bug this store can have.
-- ---------------------------------------------------------------------------

Limes.fields.register("T", "loot",  { type = "string", default = "" })
Limes.fields.register("T", "speed", { type = "number", default = 0, min = 0, max = 100 })

Limes.apply({
    _default = { profiles = { "Ambient" }, fields = { risk = 1, loot = "root" } },
    Ambient  = { fields = { loot = "ambient", speed = 10 } },
    Spooky   = { fields = { loot = "rare", speed = 20 } },
    Sprinty  = { fields = { speed = 30 } },
    -- A profile whose own structure must NOT be followed:
    Trap     = { inherits = "Spooky", profiles = { "Sprinty" },
                 rects = { { 900, 900, 909, 909 } }, fields = { hp = 9 } },
    Parent   = { inherits = "_default", rects = { { 0, 0, 199, 199 } },
                 profiles = { "Spooky" }, fields = { risk = 2 } },
    Child    = { inherits = "Parent", rects = { { 10, 10, 19, 19 } },
                 profiles = { "Sprinty" }, fields = {} },
    OwnWins  = { inherits = "Parent", rects = { { 50, 50, 59, 59 } },
                 profiles = { "Sprinty" }, fields = { speed = 99 } },
}, 30)

-- The ladder, bottom up.
eq("_default's profile reaches everything",  Limes.getZone("Child").fields.loot ~= nil, true)
eq("_default's own beats _default's profile", Limes.getZone("_default").fields.loot, "root")
eq("a parent's profile reaches the child",    Limes.getZone("Parent").fields.loot, "rare")
eq("...and the child inherits it",            Limes.getZone("Child").fields.loot, "rare")
eq("the zone's own profile beats the chain",  Limes.getZone("Child").fields.speed, 30)
eq("own field beats own profile",             Limes.getZone("OwnWins").fields.speed, 99)

-- Not-followed pins: Trap is applied as a profile somewhere and its own
-- inherits/profiles/rects must contribute nothing.
Limes.apply({
    Spooky = { fields = { loot = "rare" } },
    Sprinty = { fields = { speed = 30 } },
    Trap   = { inherits = "Spooky", profiles = { "Sprinty" }, fields = { hp = 9 } },
    Z      = { rects = { { 0, 0, 9, 9 } }, profiles = { "Trap" }, fields = {} },
}, 31)
eq("a profile's own fields contribute", Limes.getZone("Z").fields.hp, 9)
eq("a profile's inherits is not followed", Limes.getZone("Z").fields.loot, nil)
eq("a profile's profiles are not followed", Limes.getZone("Z").fields.speed, nil)

-- Unknown profile: warns, contributes nothing, zone otherwise fine.
local warnedUnknown = Limes.apply({
    Z = { rects = { { 0, 0, 9, 9 } }, profiles = { "Ghost" }, fields = { hp = 2 } },
}, 32)
eq("unknown profile still resolves the zone", Limes.getZone("Z").fields.hp, 2)
local sawWarn = false
for _, w in ipairs(warnedUnknown) do
    if w:find("unknown profile", 1, true) then sawWarn = true end
end
eq("...and warns", sawWarn, true)

-- "" in a profile bag is explicit-unset for a NUMBER field: it fails coercion
-- silently and the earlier value survives - the same rule zones already live
-- by. (A registered STRING field's "" coerces to "" and lands; that too is
-- the pre-existing zone contract, and prune strips "" before it ever
-- persists, so it only matters for imported data.)
Limes.apply({
    Muffle = { fields = { risk = "" } },
    Z      = { rects = { { 0, 0, 9, 9 } }, profiles = { "Muffle" },
               fields = {} },
    _default = { fields = { risk = 7 } },
}, 33)
eq("'' in a profile inherits through", Limes.getZone("Z").fields.risk, 7)

-- disabled via a profile takes the zone out of the lookup (RESOLVER_CRITICAL
-- path through a bag).
Limes.apply({
    Off = { fields = { disabled = true } },
    Z   = { rects = { { 0, 0, 9, 9 } }, profiles = { "Off" }, fields = {} },
}, 34)
eq("disabled-via-profile leaves the lookup", Limes.getLocation(5, 5), nil)
eq("...but the zone still resolves by name", Limes.getZone("Z").disabled, true)

-- THE WIRE PIN (silent-erasure site #1): stripServerOnly carries every
-- structural key - profiles since M-A, kind/tier/moon since the record-kind
-- model. A key missing from that whitelist is deleted by editing a number.
Limes.fields.register("T", "secret", { type = "string", default = "", side = "server" })
local stripped = Limes.fields.stripServerOnly({
    Z = { inherits = "P", tier = "Spicy", profiles = { "A", "B" },
          rects = { { 0, 0, 9, 9 } }, fields = { secret = "x", hp = 1 } },
    T1 = { kind = "tier", moon = { phases = "full", fields = { hp = 5 } },
           fields = { rank = 4, secret = "y" } },
})
eq("stripServerOnly carries profiles", stripped.Z.profiles[2], "B")
eq("...still strips server-only fields", stripped.Z.fields.secret, nil)
eq("...and keeps the rest", stripped.Z.fields.hp, 1)
eq("...carries the tier slot", stripped.Z.tier, "Spicy")
eq("...carries kind", stripped.T1.kind, "tier")
eq("...carries the moon overlay whole", stripped.T1.moon.fields.hp, 5)
eq("...still strips server-only tier fields", stripped.T1.fields.secret, nil)

-- Membership edits fire "edited" even when resolved fields happen to match.
Limes.apply({
    A = { fields = {} },                       -- an empty profile
    Z = { rects = { { 0, 0, 9, 9 } }, fields = { hp = 1 } },
}, 35)
local fired = {}
Limes.onZoneEvent(function(event, name) fired[#fired + 1] = event .. ":" .. name end)
Limes.applyDelta({ Z = { rects = { { 0, 0, 9, 9 } }, profiles = { "A" },
                         fields = { hp = 1 } } }, {}, 36)
local sawEdit = false
for _, e in ipairs(fired) do if e == "edited:Z" then sawEdit = true end end
eq("a membership-only change fires edited", sawEdit, true)

-- The resolved record exposes the list (consumers like LMZeds walk it).
eq("resolved records carry profiles", Limes.getZone("Z").profiles[1], "A")

-- ---------------------------------------------------------------------------
-- Moon phases (M-B, 2026-08-07): the vocabulary and the gate.
-- ---------------------------------------------------------------------------

local realRequire = require
require = function() end
dofile((arg[1] or ".") .. "/RequiemOfTheDead/Contents/mods/RFTDLimes/42/media/lua/shared/LMMoon.lua")
require = realRequire

-- parsePhases: names, aliases, ints, case, junk.
local function setStr(set)
    if set == nil then return "nil" end
    local out = {}
    for i = 0, 7 do if set[i] then out[#out + 1] = i end end
    return table.concat(out, ",")
end
eq("nil parses to no-condition",       LMMoon.parsePhases(nil), nil)
eq("'' parses to no-condition",        LMMoon.parsePhases(""), nil)
eq("a single name",                    setStr(LMMoon.parsePhases("full")), "4")
eq("names are case-insensitive",       setStr(LMMoon.parsePhases("FULL")), "4")
eq("a comma list unions",              setStr(LMMoon.parsePhases("new, full")), "0,4")
eq("the waxing alias",                 setStr(LMMoon.parsePhases("waxing")), "1,2,3")
eq("the waning alias",                 setStr(LMMoon.parsePhases("waning")), "5,6,7")
eq("aliases union with names",         setStr(LMMoon.parsePhases("waxing,full")), "1,2,3,4")
eq("bare ints are accepted",           setStr(LMMoon.parsePhases("0,7")), "0,7")
eq("junk tokens are skipped",          setStr(LMMoon.parsePhases("full, bloodmoon")), "4")
eq("all-junk is the EMPTY set, never nil", setStr(LMMoon.parsePhases("bloodmoon")), "")
eq("whitespace is trimmed",            setStr(LMMoon.parsePhases("  full  ")), "4")
eq("unknownTokens names the junk",     LMMoon.unknownTokens("full, bloodmoon")[1], "bloodmoon")
eq("unknownTokens is empty for clean input", #LMMoon.unknownTokens("waxing,4"), 0)
eq("phaseName round-trips",            LMMoon.phaseName(4), "full")
eq("phaseName of nil is nil",          LMMoon.phaseName(nil), nil)

-- The gate, driven by an injected sky.
local SKY = 4
LMMoon.setProvider(function() return SKY end)
eq("moonPhase serves the provider", Limes.moonPhase(), 4)
LMMoon.setProvider(function() return 99 end)
eq("an out-of-range provider is unknowable", Limes.moonPhase(), nil)
LMMoon.setProvider(function() error("no sky") end)
local realPrint, moonWarnings = print, {}
print = function(message) moonWarnings[#moonWarnings + 1] = tostring(message) end
eq("a throwing provider is unknowable", Limes.moonPhase(), nil)
eq("a repeated throwing provider stays unknowable", Limes.moonPhase(), nil)
print = realPrint
eq("a throwing provider reports one bounded diagnostic", #moonWarnings == 1
    and moonWarnings[1]:find("moon provider failed", 1, true)
    and moonWarnings[1]:find("no sky", 1, true) ~= nil, true)

-- The engine path, now that the fixture implements the verified surface:
-- getClimateMoon() is a static-final singleton that can never be nil
-- (ClimateMoon.java:18-22) and getCurrentMoonPhase() is a bare primitive read
-- (:48-50) - 0 ("New") before the first climate tick.
local ENGINE_PHASE = 2
function getClimateMoon()
    return { getCurrentMoonPhase = function() return ENGINE_PHASE end }
end
LMMoon.setProvider(nil)
eq("without a provider the engine clock answers", Limes.moonPhase(), 2)
ENGINE_PHASE = 0
eq("pre-tick zero is a VALID phase (New), not unknowable", Limes.moonPhase(), 0)
ENGINE_PHASE = 2

LMMoon.setProvider(function() return SKY end)

Limes.apply({
    _default  = { fields = { risk = 1 } },
    FullOnly  = { fields = { risk = 9, phases = "full" } },
    Z         = { rects = { { 0, 0, 9, 9 } }, profiles = { "FullOnly" }, fields = {} },
}, 60)
eq("on-phase, the profile merges",  Limes.getZone("Z").fields.risk, 9)
eq("...but never its phases key",   Limes.getZone("Z").fields.phases, nil)
eq("...while the profile's own record keeps it",
   Limes.getZone("FullOnly").fields.phases, "full")

SKY = 0
Limes.refresh()
eq("off-phase, the profile is dormant", Limes.getZone("Z").fields.risk, 1)

SKY = nil
Limes.refresh()
eq("an unknowable sky is dormant too", Limes.getZone("Z").fields.risk, 1)

-- refresh() keeps the revision - the editor's save gate depends on it.
SKY = 4
local revWas = Limes.revision
Limes.refresh()
eq("refresh does not move the revision", Limes.revision, revWas)
eq("...while re-resolving correctly", Limes.getZone("Z").fields.risk, 9)

-- ---------------------------------------------------------------------------
-- The record-kind model (S1, 2026-08-26): kinds, the tier slot, the tier bag,
-- the moon overlay, terminal resolution, and the seed.
-- ---------------------------------------------------------------------------

-- The slot: nearest-ancestor-wins, _default as the fallback root.
Limes.apply({
    _default = { tier = "Newcomer" },
    Newcomer = { kind = "tier", fields = { rank = 1, hp = 1 } },
    Spicy    = { kind = "tier", fields = { rank = 4, hp = 4 } },
    IDDQL    = { kind = "tier", fields = { rank = 5, hp = 5 } },
    Town     = { tier = "Spicy", rects = { { 0, 0, 99, 99 } }, fields = {} },
    Block    = { inherits = "Town", rects = { { 10, 10, 19, 19 } }, fields = {} },
    Cellar   = { inherits = "Block", tier = "IDDQL",
                 rects = { { 12, 12, 13, 13 } }, fields = {} },
    Nowhere  = { rects = { { 500, 500, 509, 509 } }, fields = {} },
}, 70)

eq("own slot wins",                    Limes.getZone("Cellar").tier, "IDDQL")
eq("a child takes the nearest ancestor's slot", Limes.getZone("Block").tier, "Spicy")
eq("no slot anywhere falls to _default", Limes.getZone("Nowhere").tier, "Newcomer")
eq("resolveTier names the source",
   select(2, Limes.resolveTier("Block", Limes.raw())), "Town")
eq("the tier bag merges its dials",    Limes.getZone("Town").fields.hp, 4)
eq("rank flows through the bag",       Limes.getZone("Town").fields.rank, 4)
eq("the bag follows the resolved slot", Limes.getZone("Cellar").fields.hp, 5)
eq("resolved records carry kind",      Limes.getZone("IDDQL").kind, "tier")
eq("zones carry no kind",              Limes.getZone("Town").kind, nil)

-- Bag order: tier < _default < chain < profiles < own.
Limes.apply({
    _default = { fields = { hp = 2 } },
    T1       = { kind = "tier", fields = { hp = 1, loot = "t" } },
    Boost    = { kind = "profile", fields = { speed = 9 } },
    A        = { tier = "T1", rects = { { 0, 0, 99, 99 } }, fields = {} },
    B        = { inherits = "A", rects = { { 0, 0, 9, 9 } },
                 profiles = { "Boost" }, fields = { loot = "own" } },
}, 71)
eq("_default beats the tier bag",      Limes.getZone("A").fields.hp, 2)
eq("the tier bag fills what nothing else sets", Limes.getZone("A").fields.loot, "t")
eq("own beats the tier bag",           Limes.getZone("B").fields.loot, "own")
eq("a profile still merges above it all", Limes.getZone("B").fields.speed, 9)
eq("kind=profile records resolve as profiles", Limes.getZone("Boost").kind, "profile")

-- The moon overlay: one gate (Limes.phasesActive), overlay beats base, only
-- while in phase - and the overlay never leaks a phases key.
SKY = 4
Limes.apply({
    T1 = { kind = "tier", fields = { hp = 1 },
           moon = { phases = "full", fields = { hp = 8 } } },
    Z  = { tier = "T1", rects = { { 0, 0, 9, 9 } }, fields = {} },
}, 72)
eq("in phase, the overlay beats the base dial", Limes.getZone("Z").fields.hp, 8)
SKY = 0
Limes.refresh()
eq("off phase, the base dial stands", Limes.getZone("Z").fields.hp, 1)
SKY = 4

-- Terminal resolution: a tier or profile resolves to its OWN fields only,
-- even when illegal structure is present - validate() complains, the
-- resolver ignores.
Limes.apply({
    _default = { fields = { hp = 2, loot = "root" } },
    Rogue    = { kind = "profile", inherits = "_default", fields = { speed = 3 } },
}, 73)
eq("a terminal record ignores _default",  Limes.getZone("Rogue").fields.hp, nil)
eq("...and its own illegal inherits",     Limes.getZone("Rogue").fields.loot, nil)
eq("...keeping only its own fields",      Limes.getZone("Rogue").fields.speed, 3)

-- A dangling or mis-kinded slot warns and resolves without the bag.
local wDangle = Limes.apply({
    Z = { tier = "Ghost", rects = { { 0, 0, 9, 9 } }, fields = { hp = 3 } },
    NotATier = { fields = { hp = 9 } },
    Y = { tier = "NotATier", rects = { { 50, 50, 59, 59 } }, fields = {} },
}, 74)
eq("dangling slot still resolves the zone", Limes.getZone("Z").fields.hp, 3)
eq("a mis-kinded slot contributes nothing", Limes.getZone("Y").fields.hp, nil)
local sawDangle, sawMisKind = false, false
for _, w in ipairs(wDangle) do
    if w:find("not in the store", 1, true) then sawDangle = true end
    if w:find("not a tier record", 1, true) then sawMisKind = true end
end
eq("...and both warn", sawDangle and sawMisKind, true)

-- A slot change fires "edited" - consumers must see the rules move.
Limes.apply({
    T1 = { kind = "tier", fields = { rank = 1 } },
    T2 = { kind = "tier", fields = { rank = 2 } },
    Z  = { tier = "T1", rects = { { 0, 0, 9, 9 } }, fields = {} },
}, 75)
local slotFired = {}
Limes.onZoneEvent(function(event, name) slotFired[#slotFired + 1] = event .. ":" .. name end)
Limes.applyDelta({ Z = { tier = "T2", rects = { { 0, 0, 9, 9 } }, fields = {} } }, {}, 76)
local sawSlotEdit = false
for _, e in ipairs(slotFired) do if e == "edited:Z" then sawSlotEdit = true end end
eq("a tier-slot change fires edited", sawSlotEdit, true)

-- The lootReduce grammar.
local entries, bad = Limes.parseLootReduce("Base.Axe=25; cat:Ammo=50")
eq("two rules parse",            #entries, 2)
eq("item rule kind",             entries[1].kind, "item")
eq("item rule name",             entries[1].name, "Base.Axe")
eq("item rule pct",              entries[1].pct, 25)
eq("category rule kind",         entries[2].kind, "category")
eq("category rule name",         entries[2].name, "Ammo")
eq("nothing bad in clean input", #bad, 0)
entries, bad = Limes.parseLootReduce(" Base.Shotgun = 100 ;; cat: Guns =0 ")
eq("whitespace and empty runs tolerated", #entries, 2)
eq("0 and 100 are legal percents", entries[1].pct == 100 and entries[2].pct == 0, true)
entries, bad = Limes.parseLootReduce("Base.Axe=101; nonsense; cat:=5; Base.Axe=25%")
eq("junk parses nothing",        #entries, 0)
eq("...and every bad rule is named", #bad, 4)
eq("nil parses to empty",        #Limes.parseLootReduce(nil), 0)
-- format is parse's inverse - the loot widget edits rows and writes the
-- string back through it, so the round trip must be the identity.
local rt = "Base.Shotgun=75; cat:Ammo=50; Base.Axe=0"
eq("format(parse(s)) is the identity", Limes.formatLootReduce(Limes.parseLootReduce(rt)), rt)
eq("format of empty is empty", Limes.formatLootReduce({}), "")

-- The seed: the five-rung ladder, _default standing on Medium.
Limes.apply({}, 90)
eq("seed lands in an empty store", Limes.seedIfEmpty(), true)
eq("the ladder has five rungs plus _default", #Limes.zoneNames(), 6)
eq("IDDQL is a tier record",  Limes.getZone("IDDQL").kind, "tier")
eq("IDDQL is the top rung",   Limes.getZone("IDDQL").fields.rank, 5)
eq("Newcomer is the bottom",  Limes.getZone("Newcomer").fields.rank, 1)
eq("_default stands on Medium", Limes.getZone("_default").tier, "Medium")
eq("...so it resolves the ladder's middle rank", Limes.getZone("_default").fields.rank, 3)
eq("a second seed refuses",   Limes.seedIfEmpty(), false)

print(string.format("LMCore: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
