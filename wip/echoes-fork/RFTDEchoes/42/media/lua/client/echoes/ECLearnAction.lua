-- Echoes: learn a song by playing it from sheet music. The whole song plays
-- (parent action), then the knowledge sticks; consuming the sheet is a
-- sandbox dial.

require "echoes/ECPlayAction"

ECLearnAction = ECLearnAction or ECPlayAction:derive("ECLearnAction")

function ECLearnAction:perform()
    if SandboxVars.RFTDEchoes.SheetMusicConsumed then
        local container = self.sheetMusic:getContainer()
        if container then
            container:DoRemoveItem(self.sheetMusic)
        end
    end
    ECCore:learnSong(self.character, self.song)
    HaloTextHelper.addText(self.character, getText("IGUI_EC_LearnedSong"), 200, 200, 250)
    ECPlayAction.perform(self)
end

--- @param character IsoGameCharacter
--- @param instrument InventoryItem
--- @param sheetMusic InventoryItem
function ECLearnAction:new(character, instrument, sheetMusic)
    local song = ECCore:getSong(sheetMusic:getModData()["EC_Song"])
    local o = ECPlayAction:new(character, instrument, song)
    setmetatable(o, self)
    self.__index = self
    o.sheetMusic = sheetMusic
    return o
end
