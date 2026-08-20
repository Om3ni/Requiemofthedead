-- test_rditemkind.lua - item taxonomy, and the hole-mending arithmetic.
--
-- TWO MODULES, ONE SUITE, because they were written together for the same two
-- callers and neither is big enough to justify its own runner.
--
-- RDItemKind needs ZERO STUBS: classify() only calls methods on the item handed
-- to it, so a plain Lua table IS a valid item. Same property as RDSelect.
--
-- RDClothing needs a stubbed BloodBodyPartType, because per-part hole state is
-- indexed by that enum. The stub returns the raw index as the "part" token, which
-- is all RDClothing does with it (hand it back to getHole / removeHole), so the
-- fake visual can key its hole set on plain integers. Precedent for stubbing here
-- is test_mmaudit, which stubs getFileWriter for the same reason: the behaviour
-- under test is arithmetic and ordering, and none of it is verifiable by reading.
--
-- THE COVERAGE ASSERTION is the point of the boring forty General entries in
-- RDItemKind.CATEGORY_MAP. Every DisplayCategory vanilla ships is checked to be
-- either explicitly mapped or caught by the <Base>Weapon suffix rule. Falling
-- through to the General FALLBACK is correct for a mod-invented category and
-- WRONG for a vanilla one - it means TIS added something nobody triaged. That
-- distinction is invisible at runtime (both produce "General"), so it can only be
-- caught here. When this goes red after a build, decide where the new category
-- belongs and add it; do not just extend the list below.
--
-- Usage (normally via tools\run-tests.bat):
--   lua5.1.exe tools/tests/test_rditemkind.lua <repo-root>

local ROOT = arg[1] or "."
local CORE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/shared/"

local pass, fail = 0, 0
local suite = "?"

local function eq(name, got, want)
    if got == want then pass = pass + 1
    else
        fail = fail + 1
        print("FAIL [" .. suite .. "] " .. name)
        print("  got:  " .. tostring(got))
        print("  want: " .. tostring(want))
    end
end

local function load(file, global)
    _G[global] = nil
    local ok, err = pcall(dofile, CORE .. file)
    if not ok then
        print("FATAL: could not load " .. CORE .. file)
        print("  " .. tostring(err))
        os.exit(2)
    end
    if type(_G[global]) ~= "table" then
        print("FATAL: " .. file .. " did not expose " .. global)
        os.exit(2)
    end
    return _G[global]
end

-- Every DisplayCategory value in vanilla's scripts, as of B42.20. Regenerate with:
--   grep -rhoP 'DisplayCategory\s*=\s*\K[A-Za-z]+' <game>/media/scripts | sort -u
local VANILLA_CATEGORIES = {
    "Accessory", "Ammo", "Animal", "AnimalPart", "AnimalPartWeapon", "Appearance",
    "Badger", "Bag", "Bandage", "Bear", "Beaver", "BrokenWeapon", "Bug", "Bunny",
    "Camping", "Cartography", "Clothing", "Communications", "Container", "Cooking",
    "CookingWeapon", "Corpse", "Dog", "Duck", "Ears", "Electronics", "Entertainment",
    "Explosives", "Eye", "FireSource", "FirstAid", "FirstAidWeapon", "Fishing",
    "FishingWeapon", "Food", "Fox", "Frog", "Furniture", "Gardening",
    "GardeningWeapon", "Generic", "Goblin", "Hedgehog", "Hidden", "Household",
    "HouseholdWeapon", "Instrument", "InstrumentWeapon", "Junk", "JunkWeapon",
    "LightSource", "Literature", "MaleBody", "Material", "MaterialWeapon", "Memento",
    "Mole", "Paint", "ProtectiveGear", "Raccoon", "RecipeResource", "Security",
    "SkillBook", "Spider", "Sports", "SportsWeapon", "Squirrel", "Tail", "Teddy",
    "Tool", "ToolWeapon", "Trapping", "VehicleMaintenance",
    "VehicleMaintenanceWeapon", "Water", "WaterContainer", "Weapon", "WeaponCrafted",
    "WeaponImprovised", "WeaponPart", "Wound", "ZedDmg",
}

-- ---------------------------------------------------------------------------
-- RDItemKind
-- ---------------------------------------------------------------------------

local K = load("RDItemKind.lua", "RDItemKind")
suite = "RDItemKind"

local function item(displayCat, mainCat)
    local o = {}
    if displayCat then o.getDisplayCategory = function() return displayCat end end
    if mainCat    then o.getCategory        = function() return mainCat    end end
    return o
end

local function bucketOf(displayCat)
    local b = K.classify(item(displayCat))
    return b
end

eq("vanilla list length matches the 82 found in scripts", #VANILLA_CATEGORIES, 82)

-- Bucket assignment, one representative each.
eq("Weapon is a weapon",           bucketOf("Weapon"),         "Weapons")
eq("Ammo is a weapon",             bucketOf("Ammo"),           "Weapons")
eq("Tool is tooling",              bucketOf("Tool"),           "Tooling")
eq("Clothing is clothing",         bucketOf("Clothing"),       "Clothing/Armor")
eq("ProtectiveGear is clothing",   bucketOf("ProtectiveGear"), "Clothing/Armor")
eq("Bag is clothing (worn)",       bucketOf("Bag"),            "Clothing/Armor")
eq("Material is materials",        bucketOf("Material"),       "Materials")
eq("Accessory is jewelry",         bucketOf("Accessory"),      "Jewelry")
eq("Literature is general",        bucketOf("Literature"),     "General")
eq("SkillBook is general",         bucketOf("SkillBook"),      "General")
eq("Container is general, not a bag", bucketOf("Container"),   "General")

-- The suffix rule, and that it beats the explicit map.
local b, base, dual = K.classify(item("ToolWeapon"))
eq("ToolWeapon buckets as a weapon", b,    "Weapons")
eq("ToolWeapon keeps its base",      base, "Tool")
eq("ToolWeapon is dual-use",         dual, true)

b, base, dual = K.classify(item("CookingWeapon"))
eq("CookingWeapon buckets as a weapon", b,    "Weapons")
eq("CookingWeapon keeps its base",      base, "Cooking")

-- A mod inventing FooWeapon still lands in Weapons - that is why the suffix rule
-- runs before the map - but Foo is not a category we know, so it is not dual-use.
b, base, dual = K.classify(item("QuantumWeapon"))
eq("unknown <Base>Weapon still buckets as a weapon", b,    "Weapons")
eq("unknown base yields no base label",              base, nil)
eq("unknown base is not dual-use",                   dual, false)

-- The two values the "known base" test exists to filter out.
b, base, dual = K.classify(item("BrokenWeapon"))
eq("BrokenWeapon is a plain weapon", b,    "Weapons")
eq("BrokenWeapon has no base label", base, nil)
eq("BrokenWeapon is not dual-use",   dual, false)

b, base, dual = K.classify(item("Weapon"))
eq("bare Weapon has no base label", base, nil)
eq("bare Weapon is not dual-use",   dual, false)

-- Prefix-form values must NOT be mistaken for the suffix convention.
b, base, dual = K.classify(item("WeaponCrafted"))
eq("WeaponCrafted buckets as a weapon", b,    "Weapons")
eq("WeaponCrafted is not dual-use",     dual, false)
eq("WeaponPart buckets as a weapon",    bucketOf("WeaponPart"), "Weapons")

-- Fallback chain: DisplayCategory, then getCategory, then General.
eq("falls back to getCategory",      K.classify(item(nil, "Clothing")), "Clothing/Armor")
eq("prefers DisplayCategory",        K.classify(item("Tool", "Weapon")), "Tooling")
eq("no category at all is General",  K.classify(item(nil, nil)),        "General")
eq("nil item is General",            K.classify(nil),                   "General")
eq("empty string is General",        K.classify(item("")),              "General")
eq("unknown category is General",    K.classify(item("Nonsense")),      "General")

-- Never nil, for any input - a nil bucket would drop the row out of every group.
for _, cat in ipairs(VANILLA_CATEGORIES) do
    if bucketOf(cat) == nil then
        eq("bucket is never nil for " .. cat, "nil", "a bucket")
    end
end
pass = pass + 1  -- the loop above asserts by exception; count it once

-- Every bucket returned must be one BUCKETS declares, or the UI has no group to
-- put it in and the row disappears.
local declared = {}
for _, name in ipairs(K.BUCKETS) do declared[name] = true end
eq("BUCKETS has six entries", #K.BUCKETS, 6)
for _, cat in ipairs(VANILLA_CATEGORIES) do
    if not declared[bucketOf(cat)] then
        eq(cat .. " maps to a declared bucket", bucketOf(cat), "one of BUCKETS")
    end
end
pass = pass + 1

-- THE COVERAGE ASSERTION. See the header: a vanilla category reaching the
-- fallback means TIS added something nobody triaged.
local untriaged = {}
for _, cat in ipairs(VANILLA_CATEGORIES) do
    local handled = K.CATEGORY_MAP[cat] ~= nil or string.match(cat, "Weapon$") ~= nil
    if not handled then untriaged[#untriaged + 1] = cat end
end
eq("no vanilla category reaches the fallback untriaged",
    #untriaged == 0 and "none" or table.concat(untriaged, ","), "none")

-- typeLabel: the dual-use form for dual-use, raw category otherwise. Must stay
-- single-byte-per-character - these land in fixed-width cells that DFColumns
-- truncates with string.sub, which would cut a multi-byte glyph in half.
eq("typeLabel shows the dual-use form", K.typeLabel(item("ToolWeapon")), "Tool>Weapon")
eq("typeLabel shows raw for plain",     K.typeLabel(item("Tool")),       "Tool")
eq("typeLabel falls back to Item",      K.typeLabel(item(nil, nil)),     "Item")
eq("typeLabel is ASCII-only", K.typeLabel(item("VehicleMaintenanceWeapon")):find("[\128-\255]"), nil)

-- ---------------------------------------------------------------------------
-- RDClothing.setHoleCount
-- ---------------------------------------------------------------------------

-- Stub the enum. FromIndex hands back the raw index, so a "part" IS an integer
-- everywhere below and the fake visual can key on it directly.
local PART_COUNT = 20
BloodBodyPartType = {
    MAX = { index = function() return PART_COUNT end },
    FromIndex = function(i) return i end,
}

local C = load("RDClothing.lua", "RDClothing")
suite = "RDClothing"

-- A clothing item with holes at the given part indices.
--
-- covered defaults to a superset of the holed parts, because the ENGINE cannot
-- produce a hole in a part the garment does not cover (BloodClothingType.addHole
-- only visits covered parts) - a stub that allowed it would be more permissive
-- than the thing it stands in for. setHole/removeHole mirror ItemVisual: setHole
-- takes a part token, removeHole an index, and here those are the same integer.
local function clothing(holeIdx, cond, maxCond, perHole, covered)
    local holes = {}
    for _, i in ipairs(holeIdx) do holes[i] = 1.0 end
    covered = covered or { 2, 5, 11, 14 }

    local visual = {
        getHole    = function(_, part) return holes[part] or 0 end,
        removeHole = function(_, idx)  holes[idx] = nil end,
        setHole    = function(_, part) holes[part] = 1.0 end,
    }
    local parts = {
        size = function() return #covered end,
        get  = function(_, i) return covered[i + 1] end,
    }

    local it
    it = {
        holes   = holes,
        visual  = visual,
        cond    = cond or 50,
        getVisual           = function() return visual end,
        getCoveredParts     = function() return parts end,
        getCanHaveHoles     = function() return true end,
        getCondLossPerHole  = function() return perHole or 10 end,
        getCondition        = function() return it.cond end,
        getConditionMax     = function() return maxCond or 100 end,
        setConditionNoSound = function(_, v) it.cond = v end,
    }
    return it
end

local function holeCount(it)
    local n = 0
    for _ in pairs(it.holes) do n = n + 1 end
    return n
end

eq("partCount reads the enum", C.partCount(), PART_COUNT)

-- Finding holes.
local it = clothing({ 2, 5, 11 })
eq("holeParts finds them all", table.concat(C.holeParts(it), ","), "2,5,11")
eq("holeParts on a clean item is empty", #C.holeParts(clothing({})), 0)

-- ---- Removing -------------------------------------------------------------

it = clothing({ 2, 5, 11 })
local ok, err, delta = C.setHoleCount(it, 0)
eq("mend to zero succeeds",   ok,            true)
eq("mend to zero has no err", err,           nil)
eq("mend to zero reports -3", delta,         -3)
eq("no holes remain",         holeCount(it), 0)

it = clothing({ 2, 5, 11 })
ok, err, delta = C.setHoleCount(it, 1)
eq("partial mend succeeds",   ok,            true)
eq("partial mend reports -2", delta,         -2)
eq("partial mend left one",   holeCount(it), 1)

-- Condition credit mirrors vanilla: getCondLossPerHole() back per hole mended.
it = clothing({ 2, 5, 11 }, 40, 100, 10)
C.setHoleCount(it, 0)
eq("condition credited per hole", it.cond, 70)

it = clothing({ 2, 5 }, 40, 100, 10)
C.setHoleCount(it, 1)
eq("credit matches holes actually removed", it.cond, 50)

-- Clamped to max. Without this, mending a nearly-pristine coat overshoots and
-- hands out condition the item never had.
it = clothing({ 2, 5, 11 }, 95, 100, 10)
C.setHoleCount(it, 0)
eq("credit clamps to conditionMax", it.cond, 100)

-- ---- Adding, the 2026-08-18 direction -------------------------------------

it = clothing({}, 100, 100, 10)
ok, err, delta = C.setHoleCount(it, 2)
eq("adding succeeds",             ok,            true)
eq("adding has no err",           err,           nil)
eq("adding reports +2",           delta,         2)
eq("two holes exist",             holeCount(it), 2)
eq("holes land on covered parts", table.concat(C.holeParts(it), ","), "2,5")
eq("condition debited per hole",  it.cond,       80)

-- Raising an existing count adds only the difference.
it = clothing({ 2 }, 100, 100, 10)
ok, err, delta = C.setHoleCount(it, 3)
eq("raising adds the difference",   delta,         2)
eq("resulting count is the target", holeCount(it), 3)
eq("existing hole is untouched",    it.holes[2],   1.0)
eq("debit counts only new holes",   it.cond,       80)

-- Condition floors at zero rather than going negative.
it = clothing({}, 5, 100, 10)
C.setHoleCount(it, 3)
eq("debit floors at zero", it.cond, 0)

-- The cap is the garment's covered parts, and exceeding it is reported, not
-- silently rounded down.
it = clothing({}, 100, 100, 10, { 2, 5 })
ok, err, delta = C.setHoleCount(it, 9)
eq("over-cap still succeeds",   ok,            true)
eq("over-cap adds what it can", delta,         2)
eq("over-cap fills every part", holeCount(it), 2)
eq("over-cap explains itself",  err ~= nil and err:find("at most 2") ~= nil, true)

ok, err, delta = C.setHoleCount(it, 9)
eq("a full garment refuses",      ok,    false)
eq("a full garment says so",      err ~= nil and err:find("every covered part") ~= nil, true)
eq("a full garment adds nothing", delta, 0)

-- DUPLICATE covered parts must not produce a double count: getCoveredParts
-- concatenates every declared BloodClothingType, so overlap is normal.
it = clothing({}, 100, 100, 10, { 2, 5, 2, 5, 11 })
ok, err, delta = C.setHoleCount(it, 5)
eq("duplicates do not inflate the add", delta,         3)
eq("duplicates yield distinct holes",   holeCount(it), 3)

-- canHaveHoles=false is the engine's own refusal (Clothing.java:1103).
it = clothing({}, 100, 100, 10)
it.getCanHaveHoles = function() return false end
ok, err, delta = C.setHoleCount(it, 2)
eq("canHaveHoles=false refuses",      ok,            false)
eq("canHaveHoles=false adds nothing", holeCount(it), 0)
eq("canHaveHoles=false explains",     err, "this garment cannot have holes")

-- Mending is NOT gated on canHaveHoles - a garment that somehow has holes must
-- always be repairable, whatever its script says now.
it = clothing({ 2, 5 }, 50, 100, 10)
it.getCanHaveHoles = function() return false end
ok, err, delta = C.setHoleCount(it, 0)
eq("mending ignores canHaveHoles",         ok,            true)
eq("mending ignores canHaveHoles (count)", holeCount(it), 0)

-- ---- Refusals -------------------------------------------------------------

-- No-op targets are refused loudly rather than reporting a phantom success.
it = clothing({ 2, 5 })
ok, err, delta = C.setHoleCount(it, 2)
eq("same count is refused",      ok,    false)
eq("same count changes nothing", delta, 0)
eq("same count explains",        err,   "already has 2 hole(s)")

ok, err = C.setHoleCount(clothing({}), 0)
eq("clean item asked for zero is refused", ok, false)

-- Degenerate input must not throw - these run inside an admin panel edit.
ok, err = C.setHoleCount(nil, 0)
eq("nil item is refused", ok, false)

ok, err = C.setHoleCount(clothing({ 1 }), "banana")
eq("non-numeric target is refused", ok, false)
eq("non-numeric target explains", err, "hole count must be a number")

ok, err = C.setHoleCount({}, 0)
eq("item with no visual is refused", ok, false)

local brokenVisual = { getVisual = function() error("foreign visual fault") end }
ok, err = C.setHoleCount(brokenVisual, 0)
eq("throwing foreign visual is refused", ok, false)
eq("throwing foreign visual identifies the lookup", err:find("foreign visual fault", 1, true) ~= nil, true)
eq("holeParts contains a throwing foreign visual", #C.holeParts(brokenVisual), 0)

-- Negative target clamps to zero rather than looping backwards forever.
it = clothing({ 2, 5 })
ok, err, delta = C.setHoleCount(it, -4)
eq("negative target mends all",   delta,         -2)
eq("negative target leaves none", holeCount(it), 0)

-- A fractional count from a text field floors rather than corrupting the loop.
it = clothing({}, 100, 100, 10)
ok, err, delta = C.setHoleCount(it, 2.7)
eq("fractional target floors", delta, 2)

-- ---------------------------------------------------------------------------
-- RDClothing.setVisualPercent
-- ---------------------------------------------------------------------------

-- A garment whose visual implements the VERIFIED ItemVisual surface: setBlood /
-- setDirt clamp 0..1 then truncate amount*255 into a byte, and the getters read
-- byte/255 back (ItemVisual.java:527-555). The quantization is load-bearing:
-- the module derives the scalar from re-read part values, so a stub that stored
-- floats verbatim would hide a drift the engine produces.
local function garment(coveredIdx, scriptItem)
    local blood, dirt = {}, {}
    local function store(t, part, amount)
        if amount < 0 then amount = 0 elseif amount > 1 then amount = 1 end
        t[part] = math.floor(amount * 255)
    end
    local visual = {
        setBlood = function(_, part, amount) store(blood, part, amount) end,
        setDirt  = function(_, part, amount) store(dirt,  part, amount) end,
        getBlood = function(_, part) return (blood[part] or 0) / 255 end,
        getDirt  = function(_, part) return (dirt[part]  or 0) / 255 end,
    }
    local parts = {
        size = function() return #coveredIdx end,
        get  = function(_, i) return coveredIdx[i + 1] end,  -- 0-based, like ArrayList
    }
    local g
    g = {
        blood = blood, dirt = dirt, bloodScalar = -1, dirtScalar = -1,
        getVisual       = function() return visual end,
        getCoveredParts = function() return parts end,
        getScriptItem   = function() if scriptItem == nil then return {} end return scriptItem or nil end,
        setBloodLevel   = function(_, v) g.bloodScalar = v end,
        setDirtiness    = function(_, v) g.dirtScalar  = v end,
    }
    return g
end

-- The quantized value 50% actually lands as: floor(0.5*255)=127 -> 127/255.
local Q50 = (127 / 255) * 100

it = garment({ 3, 7 })
ok, err = C.setVisualPercent(it, "blood", 50)
eq("blood 50 succeeds",                ok, true)
eq("blood 50 writes each covered part", it.blood[3], 127)
eq("blood 50 writes the second part",   it.blood[7], 127)
eq("blood 50 leaves other parts alone", it.blood[5], nil)
eq("blood 50 leaves dirt alone",        next(it.dirt), nil)
eq("blood scalar matches the quantized average", it.bloodScalar, Q50)

it = garment({ 4 })
ok = C.setVisualPercent(it, "dirt", 50)
eq("dirt 50 succeeds",             ok, true)
eq("dirt 50 writes the dirt array", it.dirt[4], 127)
eq("dirt 50 leaves blood alone",    next(it.blood), nil)
eq("dirt scalar matches",           it.dirtScalar, Q50)

-- Clamping, both ends, matching the engine's own 0..1 clamp.
it = garment({ 2 })
C.setVisualPercent(it, "blood", 150)
eq("over 100 clamps the part",   it.blood[2], 255)
eq("over 100 clamps the scalar", it.bloodScalar, 100)
C.setVisualPercent(it, "blood", -12)
eq("below 0 clamps the part to clean", it.blood[2], 0)
eq("below 0 clamps the scalar",        it.bloodScalar, 0)

-- Zero is a real write (the actual dirt-clean path: the engine's own
-- fullyRestore zeroes per-part blood but NOT per-part dirt, Clothing.java:1009).
it = garment({ 1, 2 })
C.setVisualPercent(it, "dirt", 80)
C.setVisualPercent(it, "dirt", 0)
eq("dirt 0 cleans the parts",  it.dirt[1] + it.dirt[2], 0)
eq("dirt 0 cleans the scalar", it.dirtScalar, 0)

-- Refusals are loud and specific.
ok, err = C.setVisualPercent(garment({ 1 }), "mud", 50)
eq("unknown channel is refused", ok, false)
eq("unknown channel names itself", err, "unknown channel: mud")

ok, err = C.setVisualPercent(nil, "blood", 50)
eq("nil item is refused", ok, false)

ok, err = C.setVisualPercent(garment({ 1 }), "blood", "soaked")
eq("non-numeric level is refused", ok, false)
eq("non-numeric level explains", err, "level must be a number")

ok, err = C.setVisualPercent(garment({}), "blood", 50)
eq("no covered parts is refused", ok, false)
eq("no covered parts explains", err, "garment has no blood/dirt-mappable parts")

ok, err = C.setVisualPercent({ getVisual = function() return {} end }, "blood", 50)
eq("non-garment is refused", ok, false)
eq("non-garment explains", err, "not a garment")

ok, err = C.setVisualPercent(garment({ 1 }, false), "blood", 50)
eq("missing script item is refused", ok, false)
eq("missing script item explains", err, "item has no script definition")

ok, err = C.setVisualPercent({}, "blood", 50)
eq("item with no visual is refused", ok, false)

-- sync() is a no-op without the engine global, and must not throw.
eq("sync without the global is false", C.sync({}), false)
eq("sync with no player is false",     C.sync(nil), false)

print(string.format("RDItemKind/RDClothing: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
