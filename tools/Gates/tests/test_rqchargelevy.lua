-- RQChargeLevy fixture - EMP inventory drain follows verified item contracts.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDirge/42/media/lua/server/RQChargeLevy.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then passed = passed + 1 else failed = failed + 1; print("FAIL RQChargeLevy: " .. message) end
end

function isServer() return true end

local function javaList(values)
    return {
        size = function() return #values end,
        get = function(_, index) return values[index + 1] end,
    }
end

local function electronic(itemType, active, fullness)
    local item = { value = fullness, deactivated = false }
    item.getType = function() return itemType end
    item.isActivated = function() return active end
    item.setActivated = function(_, value) item.deactivated = value == false end
    item.getCurrentUsesFloat = function() return item.value end
    item.setUsedDelta = function(_, value) item.value = value end
    return item
end

RQChargeLevy = nil
local loaded, loadErr = pcall(dofile, SOURCE)
check(loaded, "module loads: " .. tostring(loadErr))

local torch = electronic("HandTorch", true, 0.80)
local battery = electronic("Battery", false, 0.60)
local water = electronic("WaterBottle", false, 0.90)
local inventoryItems = javaList({ torch, battery, water })
local player = { getInventory = function() return { getItems = function() return inventoryItems end } end }

local drained = RQChargeLevy.drain(player, 25)
check(drained == 2, "counts only eligible electronics that were drained")
check(torch.deactivated and math.abs(torch.value - 0.55) < 0.00001,
    "deactivates and drains active electronics")
check(math.abs(battery.value - 0.35) < 0.00001, "drains inactive loose batteries")
check(water.value == 0.90, "leaves unrelated drainable items unchanged")

torch.setUsedDelta = function() error("fixture item fault") end
check(not pcall(RQChargeLevy.drain, player, 25), "does not swallow an unexpected mutation fault")

print(string.format("RQChargeLevy: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end

