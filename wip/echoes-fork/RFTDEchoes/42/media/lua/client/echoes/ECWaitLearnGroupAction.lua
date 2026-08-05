-- Echoes: the wait action variant for group-learning from sheet music.

require "echoes/ECWaitGroupAction"

ECWaitLearnGroupAction = ECWaitLearnGroupAction or ECWaitGroupAction:derive("ECWaitLearnGroupAction")

--- @param character IsoGameCharacter
--- @param groupUsername string leader's username
--- @param instrument InventoryItem
--- @param sheetMusic InventoryItem
--- @param isLeader boolean
function ECWaitLearnGroupAction:new(character, groupUsername, instrument, sheetMusic, isLeader)
    local song = ECCore:getSong(sheetMusic:getModData()["EC_Song"])
    local o = ECWaitGroupAction:new(character, groupUsername, instrument, song, isLeader)
    setmetatable(o, self)
    self.__index = self
    o.sheetMusic = sheetMusic
    return o
end
