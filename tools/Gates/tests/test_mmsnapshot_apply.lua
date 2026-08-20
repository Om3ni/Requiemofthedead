-- test_mmsnapshot_apply.lua - truthful character-application failure boundary.
--
-- The engine cannot roll back character setters. These tests prove the codec
-- distinguishes a refusal before mutation from a fault after XP has changed.

local ROOT = arg[1] or "."
local TARGET = ROOT
    .. "/RequiemOfTheDead/Contents/mods/RFTDMemoir/42/media/lua/shared/MMSnapshotCodec.lua"

local pass, fail = 0, 0
local function eq(name, got, want)
    if got == want then pass = pass + 1
    else
        fail = fail + 1
        print("FAIL " .. name .. ": got " .. tostring(got) .. ", want " .. tostring(want))
    end
end

require = function() end
MMlog = function() end
MMwarn = function() end
MMname = function() return "alice" end
MMShared = {
    fqid = function(value) return value and value.id or nil end,
    requireId = function(value) return value.id end,
    findProfessionDef = function() return nil end,
    findTrait = function() return nil end,
    traitDefsReady = function() return true end,
    xpRestoreFraction = function() return 1 end,
}
CharacterTrait = {
    UNDERWEIGHT = nil, VERY_UNDERWEIGHT = nil, EMACIATED = nil,
    OVERWEIGHT = nil, OBESE = nil,
}
CharacterTraitDefinition = {}

local perkType = {}
local perk = {
    getType = function() return perkType end,
    getId = function() return "Skill" end,
    getTotalXpForLevel = function(_, level) return level * 100 end,
}
PerkFactory = {
    PerkList = {
        size = function() return 1 end,
        get = function() return perk end,
    },
    Perks = { None = {}, MAX = {} },
}

local knownTraits = { size = function() return 0 end }
local knownRecipes = {
    size = function() return 0 end,
    remove = function() return false end,
}
local xpTotal, bodyFails
local xp = {
    getXP = function() return xpTotal end,
    AddXP = function(_, _, delta) xpTotal = xpTotal + delta end,
}
local nutrition = {
    setWeight = function()
        if bodyFails then error("simulated weight setter failure") end
    end,
    applyTraitFromWeight = function() end,
}
local descriptor = { getCharacterProfession = function() return nil end }
local player = {
    getDescriptor = function() return descriptor end,
    getCharacterTraits = function() return { getKnownTraits = function() return knownTraits end } end,
    getXp = function() return xp end,
    getPerkLevel = function() return 0 end,
    getKnownRecipes = function() return knownRecipes end,
    isRecipeActuallyKnown = function() return false end,
    getNutrition = function() return nutrition end,
    getModData = function() return {} end,
}

dofile(TARGET)

xpTotal, bodyFails = 0, false
local result = MMSnapshotCodec.applyToCharacter(player, { perks = "broken" }, nil, "max", true)
eq("malformed snapshot is refused", result.ok, false)
eq("malformed snapshot fails in preflight", result.phase, "preflight")
eq("malformed snapshot changed nothing", result.partial, false)
eq("malformed snapshot leaves XP untouched", xpTotal, 0)

xpTotal, bodyFails = 0, false
result = MMSnapshotCodec.applyToCharacter(player,
    { perks = {}, traits = {}, recipes = {} }, nil, "max", true)
eq("empty valid snapshot applies", result.ok, true)
eq("successful apply reports completion", result.phase, "complete")

xpTotal, bodyFails = 0, true
result = MMSnapshotCodec.applyToCharacter(player, {
    perks = { Skill = 10 }, traits = {}, recipes = {}, nutrition = { weight = 80 },
}, nil, "max", true)
eq("late body failure is refused", result.ok, false)
eq("late body failure names its phase", result.phase, "body")
eq("late body failure is classified partial", result.partial, true)
eq("XP mutation occurred before injected failure", xpTotal, 10)

print(string.format("MMSnapshot apply boundary: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
