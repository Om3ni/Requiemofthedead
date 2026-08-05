-- Echoes: holding pattern while a group performance fills its slots. The
-- server flips everyone to the play action once the last slot is claimed.
-- Members (not the leader) drop out if they stray from the leader; range is
-- the same GroupDistanceLeader dial the play action uses (the fork source
-- hardcoded 6 tiles here and used the dial there - unified on the dial).

require "TimedActions/ISBaseTimedAction"
require "echoes/ECCore"

ECWaitGroupAction = ECWaitGroupAction or ISBaseTimedAction:derive("ECWaitGroupAction")

function ECWaitGroupAction:isValid()
    if self.character:getVehicle() ~= nil then return false end
    return true
end

function ECWaitGroupAction:update()
    if self.isGroupReady then
        self:forceComplete()
        return
    end

    if self.isLeader then return end

    if not self.leaderObj then
        local onlinePlayers = getOnlinePlayers()
        for i = 0, onlinePlayers:size() - 1 do
            local player = onlinePlayers:get(i)
            if player:getUsername() == self.groupUsername then
                self.leaderObj = player
                break
            end
        end
    end
    if not self.leaderObj then
        ECGroupClient.SendLeavePerformance(self.character)
        self:forceComplete()
        return
    end
    local dist = self.character:getDistanceSq(self.leaderObj)
    local cDist = SandboxVars.RFTDEchoes.GroupDistanceLeader
    if dist > cDist * cDist then
        ECGroupClient.SendLeavePerformance(self.character)
        self:forceComplete()
        return
    end
end

function ECWaitGroupAction:stop()
    ISBaseTimedAction.stop(self)
    ECGroupClient.SendLeavePerformance(self.character)
end

function ECWaitGroupAction:perform()
    ISBaseTimedAction.perform(self)
end

--- @param character IsoGameCharacter
--- @param groupUsername string leader's username
--- @param instrument InventoryItem
--- @param song table
--- @param isLeader boolean
function ECWaitGroupAction:new(character, groupUsername, instrument, song, isLeader)
    local o = ISBaseTimedAction:new(character)
    setmetatable(o, self)
    self.__index = self
    o.stopOnWalk = false
    o.stopOnRun = false
    o.stopOnAim = false
    o.maxTime = -1
    o.forceProgressBar = true
    o.isGroupReady = false
    o.groupUsername = groupUsername
    o.instrument = instrument
    o.song = song
    o.isLeader = isLeader
    o.playingSong = 0
    return o
end
