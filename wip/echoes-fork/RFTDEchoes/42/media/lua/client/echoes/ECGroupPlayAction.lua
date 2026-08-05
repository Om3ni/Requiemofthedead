-- Echoes: one member's side of a group performance. The leader runs the full
-- solo action (their emitter carries the song); everyone else animates along
-- and bails out if the leader vanishes or drifts out of range.

require "echoes/ECPlayAction"

ECGroupPlayAction = ECGroupPlayAction or ECPlayAction:derive("ECGroupPlayAction")

function ECGroupPlayAction:isValid()
    return ECPlayAction.isValid(self)
end

function ECGroupPlayAction:update()
    self.character:setMetabolicTarget(Metabolics.LightWork)

    if self.isLeader then
        ECPlayAction.update(self)
        return
    end

    if not self.startTime then
        self.startTime = getTimestamp()
    end
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

function ECGroupPlayAction:stop()
    ECPlayAction.stop(self)
    ECGroupClient.SendLeavePerformance(self.character)
end

function ECGroupPlayAction:perform()
    if self.isLeader then
        ECGroupClient.SendEndPerformance(self.character)
    end
    ECPlayAction.perform(self)
end

--- @param character IsoGameCharacter
--- @param username string leader's username, the group key
--- @param instrument InventoryItem
--- @param song table
--- @param isLeader boolean
function ECGroupPlayAction:new(character, username, instrument, song, isLeader)
    local o = ECPlayAction:new(character, instrument, song)
    setmetatable(o, self)
    self.__index = self
    o.groupUsername = username
    o.isLeader = isLeader
    return o
end
