-- Echoes: show which song a sheet holds in its inventory name. Overrides
-- ComboItem.getName (Type=Normal items still instantiate ComboItem in 42.20).
-- The fork source parked this in lua/server, so MP clients only ever saw
-- "Sheet Music" - living client-side it works in SP and MP both, and stays
-- language-correct because the text renders on the viewer's side.

require "echoes/ECCore"

local metatable = __classmetatables[ComboItem.class].__index
local old_getName = metatable.getName
function metatable.getName(self)
    if self:getFullType() == "RFTDEchoes.SheetMusic" and self:getModData()["EC_Song"] then
        local songName = self:getModData()["EC_Song"]
        if songName == "IGUI_EC_AllSongs" then
            return getText("IGUI_EC_AllSongs")
        end
        local song = ECCore:getSong(songName)
        if song then
            if song.type == "single" then
                return getText("IGUI_EC_InstrumentType_" .. song.instrumentType) .. " - " .. getText(song.name)
            else
                return getText("IGUI_EC_MultiInstrument") .. " - " .. getText(song.name)
            end
        end
    end
    return old_getName(self)
end
