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
-- RDClothing.mendHoles
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
local function clothing(holeIdx, cond, maxCond, perHole)
    local holes = {}
    for _, i in ipairs(holeIdx) do holes[i] = 1.0 end

    local visual = {
        getHole    = function(_, part) return holes[part] or 0 end,
        removeHole = function(_, idx)  holes[idx] = nil end,
    }

    local it
    it = {
        holes   = holes,
        visual  = visual,
        cond    = cond or 50,
        getVisual           = function() return visual end,
        getCondLossPerHole  = function() return perHole or 10 end,
        getCondition        = function() return it.cond end,
        getConditionMax     = function() return maxCond or 100 end,
        setCondition        = function(_, v) it.cond = v end,
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

-- Mend all.
it = clothing({ 2, 5, 11 })
local ok, err, removed = C.mendHoles(it, 0)
eq("mend to zero succeeds",   ok,           true)
eq("mend to zero has no err", err,          nil)
eq("mend to zero removed 3",  removed,      3)
eq("no holes remain",         holeCount(it), 0)

-- Mend down to a count, not all the way.
it = clothing({ 2, 5, 11 })
ok, err, removed = C.mendHoles(it, 1)
eq("partial mend succeeds", ok,            true)
eq("partial mend removed 2", removed,      2)
eq("partial mend left one",  holeCount(it), 1)

-- Remove-only. Equal and higher targets are refused, and refusal is loud.
it = clothing({ 2, 5, 11 })
ok, err, removed = C.mendHoles(it, 3)
eq("equal target is refused",     ok,      false)
eq("equal target removes nothing", removed, 0)
eq("equal target left all three", holeCount(it), 3)
eq("refusal explains itself", err ~= nil and err:find("remove%-only") ~= nil, true)

ok, err, removed = C.mendHoles(it, 9)
eq("higher target is refused",      ok,      false)
eq("higher target removes nothing", removed, 0)
eq("higher target left all three",  holeCount(it), 3)

-- A clean item says so rather than reporting a nonsensical "currently 0, asked 0".
ok, err = C.mendHoles(clothing({}), 0)
eq("clean item is refused",       ok,  false)
eq("clean item says no holes", err, "no holes to mend")

-- Condition credit mirrors vanilla: getCondLossPerHole() back per hole mended.
it = clothing({ 2, 5, 11 }, 40, 100, 10)
C.mendHoles(it, 0)
eq("condition credited per hole", it.cond, 70)

it = clothing({ 2, 5 }, 40, 100, 10)
C.mendHoles(it, 1)
eq("credit matches holes actually removed", it.cond, 50)

-- Clamped to max. Without this, mending a nearly-pristine coat overshoots and
-- hands out condition the item never had.
it = clothing({ 2, 5, 11 }, 95, 100, 10)
C.mendHoles(it, 0)
eq("credit clamps to conditionMax", it.cond, 100)

-- Degenerate input must not throw - these run inside an admin panel edit.
ok, err = C.mendHoles(nil, 0)
eq("nil item is refused", ok, false)

ok, err = C.mendHoles(clothing({ 1 }), "banana")
eq("non-numeric target is refused", ok, false)
eq("non-numeric target explains", err, "hole count must be a number")

ok, err = C.mendHoles({}, 0)
eq("item with no visual is refused", ok, false)

-- Negative target clamps to zero rather than looping backwards forever.
it = clothing({ 2, 5 })
ok, err, removed = C.mendHoles(it, -4)
eq("negative target mends all", removed,       2)
eq("negative target leaves none", holeCount(it), 0)

-- sync() is a no-op without the engine global, and must not throw.
eq("sync without the global is false", C.sync({}), false)
eq("sync with no player is false",     C.sync(nil), false)

print(string.format("RDItemKind/RDClothing: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
