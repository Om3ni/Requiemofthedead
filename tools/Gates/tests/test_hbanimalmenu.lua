-- HBAnimalMenu fixture - the caretaker menu exposes vanilla debug controls
-- only while it builds and restores both cheat flags even when that build fails.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDHusbandry/42/media/lua/client/HBAnimalMenu.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL HBAnimalMenu: " .. message)
    end
end

local core = { animalCheat = false }
function core:setAnimalCheat(value) self.animalCheat = value end
function getCore() return core end

local context = { id = "menu" }
ISContextMenu = { get = function(_, x, y)
    if x == -1 then return nil end
    return context
end }

local player = { getPlayerNum = function() return 2 end }
local animal = { id = "animal" }
local call
AnimalContextMenu = {
    cheat = false,
    doMenu = function(playerNum, receivedContext, receivedAnimal, test)
        getCore():setAnimalCheat(AnimalContextMenu.cheat)
        call = { playerNum, receivedContext, receivedAnimal, test,
                 AnimalContextMenu.cheat }
    end,
}

local realRequire = require
require = function(name)
    if name == "ISUI/Animal/ISAnimalContextMenu" then return true end
    return realRequire(name)
end
local ok, err = pcall(dofile, SOURCE)
require = realRequire
check(ok, "module loads: " .. tostring(err))

local opened, openErr = HBAnimalMenu.openCaretakerMenu(player, 10, 20, animal)
check(opened and openErr == nil, "successful menu build reports success")
check(call and call[1] == 2 and call[2] == context and call[3] == animal
      and call[4] == false and call[5] == true,
      "menu builder receives the selected animal under temporary cheat mode")
check(AnimalContextMenu.cheat == false, "successful build restores Lua cheat state")
check(core.animalCheat == false, "successful build restores Core cheat state")

AnimalContextMenu.doMenu = function()
    getCore():setAnimalCheat(AnimalContextMenu.cheat)
    error("simulated vanilla menu failure")
end
opened, openErr = HBAnimalMenu.openCaretakerMenu(player, 10, 20, animal)
check(not opened and tostring(openErr):find("simulated vanilla menu failure", 1, true),
      "menu-builder failure is returned to the owning panel")
check(AnimalContextMenu.cheat == false, "failed build restores Lua cheat state")
check(core.animalCheat == false, "failed build restores Core cheat state")

AnimalContextMenu.cheat = true
core.animalCheat = true
opened, openErr = HBAnimalMenu.openCaretakerMenu(player, -1, 20, animal)
check(opened and openErr == nil, "an unavailable context is a normal no-op")
check(AnimalContextMenu.cheat == true and core.animalCheat == true,
      "no-op preserves the caller's existing cheat state")

print(string.format("HBAnimalMenu: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
