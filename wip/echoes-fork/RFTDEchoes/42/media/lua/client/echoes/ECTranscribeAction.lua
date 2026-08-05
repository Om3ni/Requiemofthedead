-- Echoes: savants can write out any song they know onto blank sheet paper,
-- producing tradable sheet music. Read-animation port from the fork source.

require "TimedActions/ISBaseTimedAction"
require "echoes/ECCore"

ECTranscribeAction = ECTranscribeAction or ISBaseTimedAction:derive("ECTranscribeAction")

function ECTranscribeAction:isValid()
    return self.item ~= nil
end

function ECTranscribeAction:start()
    self:setAnimVariable("ReadType", "newspaper")
    self:setActionAnim(CharacterActionAnims.Read)
    self:setOverrideHandModels(nil, self.item)
    self.character:setReading(true)
    self.character:reportEvent("EventRead")
end

function ECTranscribeAction:stop()
    ISBaseTimedAction.stop(self)
    self.character:setReading(false)
end

function ECTranscribeAction:perform()
    self.character:setReading(false)
    self.item:getContainer():DoRemoveItem(self.item)
    local item = self.character:getInventory():AddItem("RFTDEchoes.SheetMusic")
    item:getModData()["EC_Song"] = self.song.name
    ISBaseTimedAction.perform(self)
end

function ECTranscribeAction:new(character, item, song)
    local o = ISBaseTimedAction:new(character)
    setmetatable(o, self)
    self.__index = self
    o.character = character
    o.item = item
    o.song = song
    o.maxTime = 500
    return o
end
