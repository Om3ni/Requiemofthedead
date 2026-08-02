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

print(string.format("LMCore: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
