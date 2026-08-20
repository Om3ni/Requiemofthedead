-- RQLoot fixture - fixed vanilla corpse rewards use direct AddItem after script preflight.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDirge/42/media/lua/client/RQLoot.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL RQLoot: " .. message)
    end
end

local currentType = "Screamer"
RQRegistry = { getType = function() return currentType end }

local logs = {}
RQDirgeLog = { write = function(zType, line) logs[#logs + 1] = { zType = zType, line = line } end }

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

RQLoot = nil
local ok, err = pcall(dofile, SOURCE)
check(ok, "module loads: " .. tostring(err))

local added = {}
local zombie = {
    getOnlineID = function() return 42 end,
    getInventory = function()
        return {
            AddItem = function(_, itemType)
                added[#added + 1] = itemType
                return { fullType = itemType }
            end,
        }
    end,
}

RQLoot.dropForZombie(zombie)
check(#added == 1 and added[1] == "Base.Bandage", "adds a verified fixed loot item directly")
check(#logs == 1 and logs[1].zType == "Screamer", "logs successful corpse loot")

scriptExists = false
added, logs, randCalls = {}, {}, {}
RQLoot.dropForZombie(zombie)
check(#added == 0 and #logs == 0, "missing scripts skip AddItem and produce no loot log")

scriptExists = true
currentType = "OrdinaryTuesday"
added, logs, randCalls = {}, {}, {}
RQLoot.dropForZombie(zombie)
check(#added == 0 and #logs == 0 and #randCalls == 0, "unknown zombie types skip before rolling loot")

print(string.format("RQLoot: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
