-- RQPhunZones fixture - foreign PhunZones lookups fail open, visibly and once.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDirge/42/media/lua/shared/RQPhunZones.lua"

local passed, failed = 0, 0
local realPrint = print
local function check(ok, message)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        realPrint("FAIL RQPhunZones: " .. message)
    end
end

local prints = {}
function print(line) prints[#prints + 1] = line end

function getActivatedMods()
    return { contains = function(_, modId) return modId == "phunzones2" end }
end

local realRequire = require
function require(name)
    if name == "PhunZones/core" then return true end
    return realRequire(name)
end

local mode = "zone"
PhunZones = {
    fields = {},
    getLocation = function()
        if mode == "throw" then error("foreign zone index broke") end
        if mode == "none" then return nil end
        return {
            dirgeSpawnChance = "125",
            dirgeGluttonSpacing = "400",
        }
    end,
}

RQPhunZones = nil
local ok, err = pcall(dofile, SOURCE)
require = realRequire
check(ok, "module loads: " .. tostring(err))
check(PhunZones.fields.dirgeSpawnChance.order == 100, "registers legacy spawn field order")
check(PhunZones.fields.dirgeGluttonSpacing.order == 303, "registers spacing field order")

local cfg = { spawnChance = 15, gluttonSpacing = 25, empWeight = 4 }
local overlay = RQPhunZones.getEffectiveRules(10, 20, cfg)
check(overlay ~= cfg, "zone overrides allocate an overlay")
check(overlay.spawnChance == 100 and overlay.gluttonSpacing == 300, "zone values coerce and clamp")
check(overlay.empWeight == 4, "unset values read through the caller config")

mode = "none"
local same = RQPhunZones.getEffectiveRules(10, 20, cfg)
check(same == cfg, "no matching PhunZones zone returns the caller config")

mode = "throw"
local first = RQPhunZones.getEffectiveRules(10, 20, cfg)
local second = RQPhunZones.getEffectiveRules(10, 20, cfg)
check(first == cfg and second == cfg, "foreign PhunZones errors degrade to default config")

local failureLogs = 0
for i = 1, #prints do
    if string.find(prints[i], "PhunZones getLocation failed", 1, true) then
        failureLogs = failureLogs + 1
    end
end
check(failureLogs == 1, "foreign PhunZones failures log once")

realPrint(string.format("RQPhunZones: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
