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

eq("lewtkey is free text", Limes.fields.spec("lewtkey").ui, "text")

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

local warnings = Limes.apply({
    _default  = { rects = {}, fields = { tier = 1, title = "Somewhere" } },
    Hard      = { rects = {}, fields = { tier = "4", hp = "8" } },            -- stringly, template
    City      = { inherits = "Hard",
                  rects = { { 0, 0, 99, 99 } },
                  fields = { title = "The City" } },
    GunStore  = { inherits = "City",
                  rects = { { 10, 10, 19, 19 } },
                  fields = { tier = "99", mystery = "keep-me" } },            -- 99 clamps to 10
    Annex     = { rects = { { 200, 0, 249, 24 }, { 250, 0, 299, 24 } },       -- multi-rect
                  fields = { hp = "" } },                                     -- "" = inherit (unset)
    Loop1     = { inherits = "Loop2", rects = {}, fields = {} },
    Loop2     = { inherits = "Loop1", rects = {}, fields = {} },
    Orphan    = { inherits = "NoSuchZone", rects = { { 400, 400, 409, 409 } }, fields = {} },
    Ghost     = { rects = { { 500, 500, 509, 509 } }, fields = { disabled = true } },
}, 1)

eq("revision stamped", Limes.revision, 1)

local city = Limes.getZone("City")
eq("child sees template field",        city.fields.tier, 4)
eq("stringly number coerced",          city.fields.hp, 8)
eq("own field wins over chain",        city.fields.title, "The City")
eq("_default reaches everyone",        Limes.getZone("Annex").fields.title, "Somewhere")
eq("'' inherits instead of zeroing",   Limes.getZone("Annex").fields.hp, nil)
eq("clamp applies on resolve",         Limes.getZone("GunStore").fields.tier, 10)
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
    _default = { profiles = { "Ambient" }, fields = { tier = 1, loot = "root" } },
    Ambient  = { fields = { loot = "ambient", speed = 10 } },
    Spooky   = { fields = { loot = "rare", speed = 20 } },
    Sprinty  = { fields = { speed = 30 } },
    -- A profile whose own structure must NOT be followed:
    Trap     = { inherits = "Spooky", profiles = { "Sprinty" },
                 rects = { { 900, 900, 909, 909 } }, fields = { hp = 9 } },
    Parent   = { inherits = "_default", rects = { { 0, 0, 199, 199 } },
                 profiles = { "Spooky" }, fields = { tier = 2 } },
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
    Muffle = { fields = { tier = "" } },
    Z      = { rects = { { 0, 0, 9, 9 } }, profiles = { "Muffle" },
               fields = {} },
    _default = { fields = { tier = 7 } },
}, 33)
eq("'' in a profile inherits through", Limes.getZone("Z").fields.tier, 7)

-- disabled via a profile takes the zone out of the lookup (RESOLVER_CRITICAL
-- path through a bag).
Limes.apply({
    Off = { fields = { disabled = true } },
    Z   = { rects = { { 0, 0, 9, 9 } }, profiles = { "Off" }, fields = {} },
}, 34)
eq("disabled-via-profile leaves the lookup", Limes.getLocation(5, 5), nil)
eq("...but the zone still resolves by name", Limes.getZone("Z").disabled, true)

-- THE WIRE PIN (silent-erasure site #1): stripServerOnly carries the list.
Limes.fields.register("T", "secret", { type = "string", default = "", side = "server" })
local stripped = Limes.fields.stripServerOnly({
    Z = { inherits = "P", profiles = { "A", "B" },
          rects = { { 0, 0, 9, 9 } }, fields = { secret = "x", hp = 1 } },
})
eq("stripServerOnly carries profiles", stripped.Z.profiles[2], "B")
eq("...still strips server-only fields", stripped.Z.fields.secret, nil)
eq("...and keeps the rest", stripped.Z.fields.hp, 1)

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
eq("a throwing provider is unknowable", Limes.moonPhase(), nil)
LMMoon.setProvider(function() return SKY end)

Limes.apply({
    _default  = { fields = { tier = 1 } },
    FullOnly  = { fields = { tier = 9, phases = "full" } },
    Z         = { rects = { { 0, 0, 9, 9 } }, profiles = { "FullOnly" }, fields = {} },
}, 60)
eq("on-phase, the profile merges",  Limes.getZone("Z").fields.tier, 9)
eq("...but never its phases key",   Limes.getZone("Z").fields.phases, nil)
eq("...while the profile's own record keeps it",
   Limes.getZone("FullOnly").fields.phases, "full")

SKY = 0
Limes.refresh()
eq("off-phase, the profile is dormant", Limes.getZone("Z").fields.tier, 1)

SKY = nil
Limes.refresh()
eq("an unknowable sky is dormant too", Limes.getZone("Z").fields.tier, 1)

-- refresh() keeps the revision - the editor's save gate depends on it.
SKY = 4
local revWas = Limes.revision
Limes.refresh()
eq("refresh does not move the revision", Limes.revision, revWas)
eq("...while re-resolving correctly", Limes.getZone("Z").fields.tier, 9)

print(string.format("LMCore: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
