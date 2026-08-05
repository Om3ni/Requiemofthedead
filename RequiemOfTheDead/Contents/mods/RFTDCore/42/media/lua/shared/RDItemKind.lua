-- SPDX-License-Identifier: GPL-3.0-or-later
-- RDItemKind.lua - one item taxonomy for every RFTD surface that lists items.
--
-- WHY THIS IS IN CORE: two consumers on day one, looking at the same items from
-- opposite sides. Dragonfly's player-inventory modal groups an admin's view of
-- someone else's kit; Wardrobe's equipped tab will group the player's own. Those
-- two MUST agree - an admin and a player reading different categories off the
-- same jacket is a support ticket, not a cosmetic difference. One table, one rule
-- set, both sides read it. Contrast DFColumns, which stays in Dragonfly because
-- it DRAWS; this only decides which bin a thing belongs in.
--
-- WHAT THE ENGINE GIVES US, and why the rule is a suffix match and not a list:
-- B42 items carry a script-defined DisplayCategory - 82 distinct values across
-- vanilla's scripts. Fourteen end in "Weapon", and thirteen of those are dual-use
-- variants named <Base>Weapon: ToolWeapon, HouseholdWeapon, JunkWeapon,
-- CookingWeapon, SportsWeapon and so on. That is the game telling us "this is a
-- hammer you can also swing". Matching the suffix catches all of them plus
-- anything a mod invents on the same convention, and keeps the base visible so a
-- UI can render "Tool -> Weapon" instead of flattening a hammer into an axe.
--
-- The dual-use test is "does the stripped base name itself a category we know".
-- Tool does (Tooling), so ToolWeapon is dual-use. Broken does not, so
-- BrokenWeapon is a plain weapon rather than the nonsense "Broken -> Weapon".
-- Bare "Weapon" strips to an empty string, which is likewise unknown, so it also
-- reads as a plain weapon. One rule, all three cases.
--
-- Prefix-form values - WeaponCrafted, WeaponImprovised, WeaponPart - do NOT end
-- in "Weapon" and need explicit entries. That asymmetry is TIS's, not ours.
--
-- Every vanilla value is listed explicitly, including the ones that land in
-- General, so this file is a complete record of what we have actually triaged and
-- test_rditemkind can assert that nothing vanilla reaches the fallback. When TIS
-- adds a category the test goes red and someone decides where it belongs, which
-- is the entire point of spelling out the boring forty.
--
-- The fallback still exists, for mods. The pack runs a large workshop set and any
-- of them can invent a DisplayCategory; a row that silently vanishes from an
-- admin's inventory audit is far worse than a row in a slightly wrong bin.
--
-- ENGINE-FREE. classify() only calls methods on the item handed to it, so a test
-- passes a plain table and needs ZERO stubs - same arrangement as RDSelect. Keep
-- it that way: no getters off globals, no instanceof, no drawing.

RDItemKind = RDItemKind or {}

-- Display order. Dragonfly's modal and Wardrobe's tabs both walk this, so the
-- order here IS the order on screen.
RDItemKind.BUCKETS = {
    "Weapons",
    "Tooling",
    "Clothing/Armor",
    "Materials",
    "Jewelry",
    "General",
}

RDItemKind.WEAPONS  = "Weapons"
RDItemKind.FALLBACK = "General"

-- DisplayCategory -> bucket. The 68 vanilla values that do NOT end in "Weapon";
-- the other 14 are handled by the suffix rule in classify().
RDItemKind.CATEGORY_MAP = {
    -- Weapons: ammunition, ordnance, and the prefix-form weapon values.
    Ammo                 = "Weapons",
    Explosives           = "Weapons",
    WeaponCrafted        = "Weapons",
    WeaponImprovised     = "Weapons",
    WeaponPart           = "Weapons",

    -- Tooling: things you work with rather than fight with.
    Tool                 = "Tooling",
    Electronics          = "Tooling",
    VehicleMaintenance   = "Tooling",
    Fishing              = "Tooling",
    Trapping             = "Tooling",
    Gardening            = "Tooling",
    Cooking              = "Tooling",
    Camping              = "Tooling",
    FireSource           = "Tooling",
    LightSource          = "Tooling",
    Communications       = "Tooling",
    Cartography          = "Tooling",
    Security             = "Tooling",
    Paint                = "Tooling",

    -- Clothing/Armor: worn. Bag belongs here because bags are worn containers;
    -- Container and WaterContainer are carried objects and sit in General.
    Clothing             = "Clothing/Armor",
    ProtectiveGear       = "Clothing/Armor",
    Bag                  = "Clothing/Armor",
    Appearance           = "Clothing/Armor",

    -- Materials: crafting inputs and salvage.
    Material             = "Materials",
    RecipeResource       = "Materials",
    Junk                 = "Materials",
    AnimalPart           = "Materials",

    -- Jewelry: vanilla's name for it is Accessory.
    Accessory            = "Jewelry",

    -- General: everything else, spelled out so the coverage test has teeth.
    Food                 = "General",
    Water                = "General",
    WaterContainer       = "General",
    Container            = "General",
    Literature           = "General",
    SkillBook            = "General",
    Entertainment        = "General",
    Memento              = "General",
    Teddy                = "General",
    Furniture            = "General",
    Household            = "General",
    FirstAid             = "General",
    Bandage              = "General",
    Wound                = "General",
    Instrument           = "General",
    Sports               = "General",
    Generic              = "General",
    Hidden               = "General",
    ZedDmg               = "General",
    -- Bodies and body parts.
    Corpse               = "General",
    MaleBody             = "General",
    Ears                 = "General",
    Eye                  = "General",
    Tail                 = "General",
    -- Animals. Vanilla gives most species its own category.
    Animal               = "General",
    Badger               = "General",
    Bear                 = "General",
    Beaver               = "General",
    Bug                  = "General",
    Bunny                = "General",
    Dog                  = "General",
    Duck                 = "General",
    Fox                  = "General",
    Frog                 = "General",
    Goblin               = "General",
    Hedgehog             = "General",
    Mole                 = "General",
    Raccoon              = "General",
    Spider               = "General",
    Squirrel             = "General",
}

-- Read a string off the item without assuming the method exists. Older objects
-- and non-InventoryItem things get passed in by mistake eventually; returning nil
-- is better than throwing inside a render loop.
local function readString(item, method)
    if not item then return nil end
    local fn = item[method]
    if type(fn) ~= "function" then return nil end
    local ok, val = pcall(fn, item)
    if not ok or type(val) ~= "string" or val == "" then return nil end
    return val
end

-- The raw DisplayCategory for an item, or nil. Exposed because callers sometimes
-- want to show the raw value alongside the bucket.
function RDItemKind.rawCategory(item)
    return readString(item, "getDisplayCategory")
        or readString(item, "getCategory")
end

-- bucket, baseCat, weaponCapable
--   bucket        one of BUCKETS, never nil
--   baseCat       for dual-use weapons, the non-weapon half ("Tool"); else nil
--   weaponCapable true only for dual-use weapons
function RDItemKind.classify(item)
    local cat = RDItemKind.rawCategory(item)
    if not cat then
        return RDItemKind.FALLBACK, nil, false
    end

    -- Suffix rule first: <Base>Weapon. Deliberately ahead of the map so a mod
    -- adding FooWeapon lands in Weapons without needing an entry here.
    local base = string.match(cat, "^(.*)Weapon$")
    if base then
        -- Dual-use only when the stripped base is itself a category we know.
        -- Filters out BrokenWeapon ("Broken") and bare Weapon ("").
        if RDItemKind.CATEGORY_MAP[base] then
            return RDItemKind.WEAPONS, base, true
        end
        return RDItemKind.WEAPONS, nil, false
    end

    return RDItemKind.CATEGORY_MAP[cat] or RDItemKind.FALLBACK, nil, false
end

-- Label for a row's type cell: "Tool>Weapon" for dual-use, else the raw category.
-- Keeps the convention in one place instead of in every caller.
--
-- ASCII ">" and not a UTF-8 arrow ON PURPOSE. These labels land in fixed-width
-- table cells, and DFColumns.truncate trims byte-wise (string.sub) - a long value
-- like VehicleMaintenance>Weapon does get truncated, and a multi-byte arrow could
-- be cut mid-sequence and render as garbage. One byte per character cannot.
function RDItemKind.typeLabel(item)
    local _, baseCat, weaponCapable = RDItemKind.classify(item)
    if weaponCapable and baseCat then
        return baseCat .. ">Weapon"
    end
    return RDItemKind.rawCategory(item) or "Item"
end

return RDItemKind

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
