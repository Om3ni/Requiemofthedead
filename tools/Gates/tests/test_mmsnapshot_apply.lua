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
local xpTotal, bodyFails, zombieKills, survivorKills
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
    getZombieKills = function() return zombieKills end,
    setZombieKills = function(_, n) zombieKills = n end,
    getSurvivorKills = function() return survivorKills end,
    setSurvivorKills = function(_, n) survivorKills = n end,
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

-- ─────────────────────────────────────────────────────────────────────────
-- The two XP shapes, pinned. The fixture's one perk has no build grant, so the
-- arithmetic reduces to the header's rule with floorXP = 0:
--   overwrite: target = saved + cur   (two DISJOINT lives: the book's earnings
--                                      plus what this body earned since spawn)
--   max:       target = max(cur, saved)
-- Feed the overwrite the SAME life's own snapshot and "cur" already contains
-- "saved": the result is 2x. That is exactly the 2026-09-05 admin-restore
-- doubling, and why MMRestore dispatches a same-life archive to "max".
-- ─────────────────────────────────────────────────────────────────────────
local SNAP = { perks = { Skill = 1000 }, traits = {}, recipes = {},
               kills = { Zombie = 100, Survivor = 2 } }

-- Disjoint lives: 1000 in the book, 300 earned on the new body -> 1300.
xpTotal, bodyFails, zombieKills, survivorKills = 300, false, 7, 1
result = MMSnapshotCodec.applyToCharacter(player, SNAP, { traits = {} }, "overwrite", true)
eq("overwrite applies", result.ok, true)
eq("overwrite adds the book to this life's earnings", xpTotal, 1300)
eq("overwrite adds the book's kills to this life's", zombieKills, 107)
eq("overwrite adds survivor kills the same way", survivorKills, 3)

-- The same numbers fed back to the life that wrote them: cur == saved -> 2x.
xpTotal, bodyFails, zombieKills, survivorKills = 1000, false, 100, 2
result = MMSnapshotCodec.applyToCharacter(player, SNAP, { traits = {} }, "overwrite", true)
eq("overwrite against its own life doubles XP", xpTotal, 2000)
eq("overwrite against its own life doubles kills", zombieKills, 200)

-- "max" on the same numbers: nothing to add, nothing added.
xpTotal, bodyFails, zombieKills, survivorKills = 1000, false, 100, 2
result = MMSnapshotCodec.applyToCharacter(player, SNAP, nil, "max", true)
eq("top-up on its own life is a no-op", xpTotal, 1000)
eq("top-up never adds kills", zombieKills, 100)

-- "max" after a rollback: 700 on the body, 1000 in the archive -> 1000, once.
xpTotal, bodyFails, zombieKills, survivorKills = 700, false, 60, 2
result = MMSnapshotCodec.applyToCharacter(player, SNAP, nil, "max", true)
eq("top-up restores a rolled-back skill to the archive", xpTotal, 1000)
eq("top-up restores rolled-back kills to the archive", zombieKills, 100)

-- "max" never goes below current.
xpTotal, bodyFails, zombieKills, survivorKills = 1500, false, 120, 2
result = MMSnapshotCodec.applyToCharacter(player, SNAP, nil, "max", true)
eq("top-up never lowers XP", xpTotal, 1500)
eq("top-up never lowers kills", zombieKills, 120)

print(string.format("MMSnapshot apply boundary: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
