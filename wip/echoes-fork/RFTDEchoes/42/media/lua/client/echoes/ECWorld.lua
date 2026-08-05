-- Echoes: fixed instruments found in the world. Detection keys off the
-- moveable sprite property CustomName rather than sprite-name lists, so both
-- vanilla pianos ("Western Piano", "Black Grand Piano" - CustomName "Piano")
-- match and the piano stool (CustomName "Stool") does not. Pianos borrow the
-- Synthesizer song set and skill until dedicated piano recordings exist -
-- the registry shape already supports swapping that per-entry.

require "echoes/ECCore"
require "echoes/ECPlayWorldAction"

ECWorld = ECWorld or {}

-- CustomName -> world instrument def.
ECWorld.defs = {
    ["Piano"] = {
        nameKey = "IGUI_EC_WorldInstrument_Piano",
        instrumentType = "Synthesizer",
        animation = "ECPlaySynthesizer",
        loudness = 1.2,
    },
}

function ECWorld.getDef(object)
    if not object then return nil end
    local sprite = object.getSprite and object:getSprite()
    if not sprite then return nil end
    local props = sprite:getProperties()
    if props and props:has("CustomName") then
        return ECWorld.defs[props:get("CustomName")]
    end
    return nil
end

--- Find a playable world instrument on/around the clicked objects.
local function findWorldInstrument(worldobjects)
    for _, worldObj in ipairs(worldobjects) do
        local square = worldObj:getSquare()
        if square then
            local objects = square:getObjects()
            for i = 0, objects:size() - 1 do
                local object = objects:get(i)
                local def = ECWorld.getDef(object)
                if def then
                    return def, object
                end
            end
        end
    end
    return nil, nil
end

function ECWorld.play(playerObj, def, object, song)
    local targetSquare = object:getSquare()
    ISTimedActionQueue.clear(playerObj)
    if not AdjacentFreeTileFinder.isTileOrAdjacent(playerObj:getSquare(), targetSquare) then
        local adjacent = AdjacentFreeTileFinder.Find(targetSquare, playerObj)
        if not adjacent then return end
        ISTimedActionQueue.add(ISWalkToTimedAction:new(playerObj, adjacent))
    end
    ISTimedActionQueue.add(ECPlayWorldAction:new(playerObj, def, object, song))
end

local function onFillWorldObjectContextMenu(playerIdx, context, worldobjects, test)
    if test then return end
    if not SandboxVars.RFTDEchoes.WorldInstruments then return end

    local playerObj = getSpecificPlayer(playerIdx)
    if not playerObj or playerObj:getVehicle() then return end

    local def, object = findWorldInstrument(worldobjects)
    if not def then return end

    context:addOption(getText("ContextMenu_EC_PlayWorldInstrument", getText(def.nameKey)), playerObj, function(player)
        ECSongbook.openWorld(player, def, object)
    end)
end

Events.OnFillWorldObjectContextMenu.Add(onFillWorldObjectContextMenu)
