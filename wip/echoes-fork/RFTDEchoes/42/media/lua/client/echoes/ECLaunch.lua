-- Echoes: the one place that turns "play this" into a queued action. Handles
-- the instant equip shuffle, and for world instruments records where the item
-- sat so the play action can lock the player there and re-drop it after.
-- Everything UI-side (songbook, context menu, group client) launches through
-- here so the queue choreography lives in exactly one file.

require "echoes/ECCore"
require "echoes/ECPlayAction"
require "echoes/ECLearnAction"

ECLaunch = ECLaunch or {}

-- The fork source dug this out with a reflection scan; 42.20 has a getter.
local function setPostPlayPosition(playerObj, instrument, action)
    local worldItem = instrument:getWorldItem()
    if worldItem then
        action.postPlayWorldPosition = {
            sq = worldItem:getSquare(),
            x = worldItem:getWorldPosX() - math.floor(worldItem:getWorldPosX()),
            y = worldItem:getWorldPosY() - math.floor(worldItem:getWorldPosY()),
            z = worldItem:getWorldPosZ() - math.floor(worldItem:getWorldPosZ()),
            r = instrument:getWorldZRotation(),
        }
    else
        action.postPlayWorldPosition = {
            sq = playerObj:getSquare(),
            x = playerObj:getX() - math.floor(playerObj:getX()),
            y = playerObj:getY() - math.floor(playerObj:getY()),
            z = playerObj:getZ() - math.floor(playerObj:getZ()),
            r = playerObj:getDirectionAngle(),
        }
    end
end

local function equipIfNeededInstant(playerObj, instrument)
    if playerObj:getSecondaryHandItem() == instrument then return end

    if luautils.haveToBeTransfered(playerObj, instrument) then
        local transferAction = ISInventoryTransferAction:new(playerObj, instrument, instrument:getContainer(), playerObj:getInventory())
        transferAction.maxTime = 1
        ISTimedActionQueue.add(transferAction)
    end

    local equipAction = ISEquipWeaponAction:new(playerObj, instrument, 50, false, false)
    equipAction.maxTime = 1
    ISTimedActionQueue.add(equipAction)
end

local function finishLaunch(playerObj, instrument, action)
    ISTimedActionQueue.add(action)
    if ECCore:isWorldInstrument(instrument:getFullType()) then
        setPostPlayPosition(playerObj, instrument, action)
    end
    return action
end

--- Solo play; pass song = nil to pretend-play (animation only, no sound/XP).
function ECLaunch.play(playerObj, instrument, song)
    equipIfNeededInstant(playerObj, instrument)
    return finishLaunch(playerObj, instrument, ECPlayAction:new(playerObj, instrument, song))
end

--- Learn a song by performing it from sheet music.
function ECLaunch.learn(playerObj, instrument, sheetMusic)
    equipIfNeededInstant(playerObj, instrument)
    return finishLaunch(playerObj, instrument, ECLearnAction:new(playerObj, instrument, sheetMusic))
end

--- Group actions share a constructor shape: (character, username, instrument,
--- songOrSheet, isLeader). actionClass is ECGroupPlayAction, ECGroupLearnAction
--- or one of the wait actions.
function ECLaunch.group(actionClass, playerObj, username, instrument, songOrSheet, isLeader)
    equipIfNeededInstant(playerObj, instrument)
    return finishLaunch(playerObj, instrument, actionClass:new(playerObj, username, instrument, songOrSheet, isLeader))
end
