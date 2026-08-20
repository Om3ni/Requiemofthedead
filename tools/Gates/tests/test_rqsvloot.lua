-- RQSvLoot fixture - server corpse rewards use direct AddItem after script preflight.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDirge/42/media/lua/server/RQSvLoot.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL RQSvLoot: " .. message)
    end
end

local scriptExists = true
function getScriptManager()
    return {
        getItem = function(_, itemType)
            if scriptExists then return { fullType = itemType } end
            return nil
        end,
    }
end

local randCalls = {}
function ZombRand(max)
    randCalls[#randCalls + 1] = max
    return 0
end

RQSvLoot = nil
local ok, err = pcall(dofile, SOURCE)
check(ok, "module loads: " .. tostring(err))

local added = {}
local zombie = {
    getInventory = function()
        return {
            AddItem = function(_, itemType)
                added[#added + 1] = itemType
                return { fullType = itemType }
            end,
        }
    end,
}

RQSvLoot.drop(zombie, "Boss")
check(#added == 3, "boss corpse rolls its minimum reward count")
check(added[1] == "Base.Katana" and added[2] == "Base.Katana" and added[3] == "Base.Katana",
    "adds verified fixed loot items directly")

scriptExists = false
added, randCalls = {}, {}
RQSvLoot.drop(zombie, "Boss")
check(#added == 0, "missing scripts skip AddItem")

scriptExists = true
added, randCalls = {}, {}
RQSvLoot.drop(zombie, "OrdinaryTuesday")
check(#added == 0 and #randCalls == 0, "unknown zombie types skip before rolling loot")

added, randCalls = {}, {}
RQSvLoot.drop({ getInventory = function() return nil end }, "Boss")
check(#added == 0 and #randCalls == 0, "missing corpse inventory skips before rolling loot")

print(string.format("RQSvLoot: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
