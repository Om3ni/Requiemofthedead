-- HBHutchContextMenu fixture - hay availability alone governs whether the
-- player-facing bedding action appears on either half of a hutch.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDHusbandry/42/media/lua/client/HBHutchContextMenu.lua"
local BASE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDHusbandry/42/media/lua/client"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL HBHutchContext: " .. message)
    end
end

local fill
Events = {
    OnPreFillWorldObjectContextMenu = { Add = function(fn) fill = fn end },
}
function isServer() return false end

local realRequire = require
require = function(name)
    if name == "ISUI/ISToolTip" or name == "TimedActions/ISTimedActionQueue" then return true end
    if name == "HBHayward" then return dofile(BASE .. "/HBHayward.lua") end
    return realRequire(name)
end

function instanceof(_, class) return class == "IsoHutch" end

local hayCalls = 0
local hay = { id = "hay" }
local inventory = {
    getFirstTypeRecurse = function(_, itemType)
        hayCalls = hayCalls + 1
        if itemType == "Base.HayTuft" then return hay end
    end,
}
local player = {
    isDead = function() return false end,
    getInventory = function() return inventory end,
}
function getSpecificPlayer() return player end

local hutch = { getHutch = function(self) return self end }
local ok, err = pcall(dofile, SOURCE)
require = realRequire
check(ok, "module loads: " .. tostring(err))
check(type(fill) == "function", "registers the pre-fill context handler")

local options = {}
local context = {
    addOption = function(_, label, objects, callback)
        local option = { label = label, objects = objects, onSelect = callback }
        options[#options + 1] = option
        return option
    end,
}

fill(0, context, { hutch }, false)
check(hayCalls == 1 and #options == 1 and options[1].label == "Add Hay Bedding",
    "a valid inventory lookup adds the bedding option")

hay = nil
fill(0, context, { hutch }, false)
check(hayCalls == 2 and #options == 1,
    "an empty inventory omits the option without treating absence as an error")

fill(0, context, { hutch }, true)
check(hayCalls == 2, "test menu passes leave inventory untouched")

print(string.format("HBHutchContext: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
