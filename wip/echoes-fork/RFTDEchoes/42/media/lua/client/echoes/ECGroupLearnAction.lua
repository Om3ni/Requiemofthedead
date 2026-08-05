-- Echoes: learning a group song inside a live group performance.
--
-- Fixed from the fork source: perform() ran the parent perform twice (double
-- dequeue) and stop() sent LeavePerformance twice (the parent already sends
-- it). Both are single now.

require "echoes/ECGroupPlayAction"

ECGroupLearnAction = ECGroupLearnAction or ECGroupPlayAction:derive("ECGroupLearnAction")

function ECGroupLearnAction:perform()
    if SandboxVars.RFTDEchoes.SheetMusicConsumed then
        local container = self.sheetMusic:getContainer()
        if container then
            container:DoRemoveItem(self.sheetMusic)
        end
    end
    ECCore:learnSong(self.character, self.song)
    HaloTextHelper.addText(self.character, getText("IGUI_EC_LearnedSong"), 200, 200, 250)
    ECGroupPlayAction.perform(self)
end

--- @param character IsoGameCharacter
--- @param username string leader's username
--- @param instrument InventoryItem
--- @param sheetMusic InventoryItem
--- @param isLeader boolean
function ECGroupLearnAction:new(character, username, instrument, sheetMusic, isLeader)
    local song = ECCore:getSong(sheetMusic:getModData()["EC_Song"])
    local o = ECGroupPlayAction:new(character, username, instrument, song, isLeader)
    setmetatable(o, self)
    self.__index = self
    o.sheetMusic = sheetMusic
    return o
end
