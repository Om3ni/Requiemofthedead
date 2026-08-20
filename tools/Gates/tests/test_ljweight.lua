-- test_ljweight.lua - script-weight scaling contracts for Lumberjack.
--
-- Uses the valid engine contracts LJWeight relies on: ItemTag lookup returns
-- nil for an absent tag, Item scripts expose direct weight reads/writes, and a
-- valid Weight parameter is accepted. Invalid script weights and invalid
-- sandbox values are preconditions to skip/fall back from, not exceptions to
-- swallow around a partially completed mutation.

local ROOT = arg[1] or "."
local SRC = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDOddsAndEnds"
    .. "/42/media/lua/shared/Lumberjack/LJWeight.lua"

local pass, fail = 0, 0
local function eq(name, got, want)
    if got == want then pass = pass + 1
    else
        fail = fail + 1
        print("FAIL " .. name .. " (got " .. tostring(got) .. ", want " .. tostring(want) .. ")")
    end
end

local function jlist(values)
    return {
        size = function() return #values end,
        get = function(_, index) return values[index + 1] end,
    }
end

local tags, tagLookups = {}, 0
ItemTag = {
    get = function(id)
        tagLookups = tagLookups + 1
        return tags[id]
    end,
}
ResourceLocation = { of = function(id) return id end }

local function script(full, weight, tagNames)
    local value = { full = full, weight = weight, tags = {}, params = {}, writes = 0 }
    for _, name in ipairs(tagNames or {}) do value.tags["base:" .. name] = true end
    function value:getFullName() return self.full end
    function value:getActualWeight() return self.weight end
    function value:setActualWeight(newWeight)
        self.weight = newWeight
        self.writes = self.writes + 1
    end
    function value:DoParam(parameter) self.params[#self.params + 1] = parameter end
    function value:hasTag(tag) return self.tags[tag] == true end
    return value
end

for _, name in ipairs({ "makewoodcharcoalsmall", "makewoodcharcoalmedium", "makewoodcharcoallarge", "log" }) do
    tags["base:" .. name] = "base:" .. name
end

local log = script("Base.Log", 9)
local plank = script("Base.Plank", 3)
local tagged = script("Other.BurnableWood", 2, { "log" })
local ordinary = script("Other.MetalThing", 7)
local malformed = script("Other.BrokenWood", math.huge, { "log" })
local all = { log, plank, tagged, ordinary, malformed }
local byName = { [log.full] = log, [plank.full] = plank }

getScriptManager = function()
    return {
        getItem = function(_, full) return byName[full] end,
        getAllItems = function() return jlist(all) end,
    }
end

local enabled = true
OEShared = { enabled = function(flag) eq("uses the established sandbox key", flag, "LumberjackEnable"); return enabled end }
SandboxVars = { RFTDOddsAndEnds = { LumberjackBulkWeight = 0.5, LumberjackWoodWeight = 0.25 } }
Events = {
    OnGameStart = { Add = function(fn) _G.onGameStart = fn end },
    OnServerStarted = { Add = function(fn) _G.onServerStarted = fn end },
}
isServer = function() return false end
require = function() end

Lumberjack = nil
dofile(SRC)
local LJ = Lumberjack

eq("registers client and single-player startup", type(onGameStart), "function")
eq("does not register the server event in a client process", onServerStarted, nil)
onGameStart()
eq("scales logs from their original weight", log.weight, 4.5)
eq("scales planks from their original weight", plank.weight, 1.5)
eq("scales tagged wood with its own dial", tagged.weight, 0.5)
eq("leaves untagged items untouched", ordinary.weight, 7)
eq("does not mutate malformed third-party script weights", malformed.writes, 0)
eq("updates the log parameter", log.params[1], "Weight = 4.5")
eq("updates the tagged parameter", tagged.params[1], "Weight = 0.5")
eq("resolves each declared tag once", tagLookups, 4)

SandboxVars.RFTDOddsAndEnds.LumberjackBulkWeight = 0.25
SandboxVars.RFTDOddsAndEnds.LumberjackWoodWeight = 0.5
LJ.apply()
eq("repeat application uses the original log weight", log.weight, 2.25)
eq("repeat application uses the original tagged weight", tagged.weight, 1)
eq("cached tags avoid repeat registry lookups", tagLookups, 4)

SandboxVars.RFTDOddsAndEnds.LumberjackBulkWeight = 0 / 0
SandboxVars.RFTDOddsAndEnds.LumberjackWoodWeight = math.huge
LJ.apply()
eq("NaN bulk dial falls back to vanilla", log.weight, 9)
eq("infinite wood dial falls back to vanilla", tagged.weight, 2)

enabled = false
LJ.apply()
eq("disable restores the original log weight", log.weight, 9)
eq("disable restores the original tagged weight", tagged.weight, 2)

print(string.format("LJWeight: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
