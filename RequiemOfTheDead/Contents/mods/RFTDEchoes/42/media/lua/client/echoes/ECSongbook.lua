-- Echoes: the Songbook window.
--
-- STUB LAYOUT - intentionally bare. The panel design is being redone to a
-- different layout; only the plumbing here is meant to survive that pass.
-- Everything data-shaped lives in buildRows()/refresh() and the on* handlers,
-- so a relayout should only need to touch createChildren()/render sizing.
--
-- What works now: open from an instrument (or world piano), rows for every
-- song on that instrument plus [Group] songs and joinable open sessions in
-- MP, a skill/XP readout line, Play / Start Group / Join on the selected row.

require "ISUI/ISCollapsableWindow"
require "echoes/ECCore"
require "echoes/ECLaunch"

ECSongbook = ISCollapsableWindow:derive("ECSongbook")
ECSongbook.instance = nil

local FONT_HGT = getTextManager():getFontHeight(UIFont.Small)

-- Data ----------------------------------------------------------------------

-- Rows: {kind="song", song=, issue=} | {kind="session", username=, song=, issue=}
function ECSongbook:buildRows()
    local rows = {}
    local player = self.playerObj
    local instrumentType = self.instrumentType

    local singles = ECCore:getSongsForInstrument(instrumentType)
    for level = 1, 3 do
        for _, song in ipairs(singles[level]) do
            table.insert(rows, {
                kind = "song",
                song = song,
                issue = ECCore:getPlaySongIssue(player, song, instrumentType),
            })
        end
    end

    -- Group songs and sessions only mean something with a broker around.
    if isClient() and not self.worldMode then
        local groups = ECCore:getGroupSongsForInstrument(instrumentType)
        for level = 1, 3 do
            for _, song in ipairs(groups[level]) do
                table.insert(rows, {
                    kind = "song",
                    song = song,
                    issue = ECCore:getPlaySongIssue(player, song, instrumentType),
                })
            end
        end

        local onlinePlayers = getOnlinePlayers()
        for username, groupData in pairs(ECGroupClient.openPerformances) do
            local song = ECCore:getSong(groupData.songName)
            if song and song.type == "group" then
                for i = 0, onlinePlayers:size() - 1 do
                    local leader = onlinePlayers:get(i)
                    if leader:getUsername() == username then
                        local cDist = SandboxVars.RFTDEchoes.GroupDistanceLeader
                        if player:getDistanceSq(leader) <= cDist * cDist then
                            for slot, slotInstrument in ipairs(song.instrumentTypes) do
                                if slotInstrument == instrumentType and not groupData.performers[slot] then
                                    table.insert(rows, {
                                        kind = "session",
                                        username = username,
                                        song = song,
                                        issue = ECCore:getPlaySongIssue(player, song, instrumentType),
                                    })
                                    break
                                end
                            end
                        end
                        break
                    end
                end
            end
        end
    end

    return rows
end

function ECSongbook:skillLine()
    local skillType = ECCore:getInstrumentSkill(self.instrumentType)
    local skillName = getText(ECCore:getSkillName(skillType))
    local level = ECCore:getPlayerSkill(self.playerObj, skillType)
    local levelName = getText("IGUI_EC_Difficulty_" .. level)
    if level >= ECCore.MAX_SKILL_LEVEL then
        return skillName .. ": " .. levelName
    end
    local xp = ECCore:getPlayerXp(self.playerObj, skillType)
    return skillName .. ": " .. levelName .. "  [" .. tostring(xp) .. "/" .. tostring(ECCore.XP_PER_LEVEL[level]) .. " xp]"
end

-- Window --------------------------------------------------------------------

function ECSongbook:createChildren()
    ISCollapsableWindow.createChildren(self)
    local th = self:titleBarHeight()

    self.skillLabel = ISLabel:new(10, th + 4, FONT_HGT, "", 1, 1, 1, 1, UIFont.Small, true)
    self:addChild(self.skillLabel)

    local listY = th + 4 + FONT_HGT + 6
    self.songList = ISScrollingListBox:new(10, listY, self.width - 20, self.height - listY - 40)
    self.songList:initialise()
    self.songList:instantiate()
    self.songList.itemheight = FONT_HGT + 8
    self.songList.font = UIFont.Small
    self.songList.drawBorder = true
    self.songList.doDrawItem = function(listbox, y, item, alt)
        local row = item.item
        local r, g, b = 1, 1, 1
        if row.issue then r, g, b = 0.5, 0.5, 0.5 end
        if listbox.selected == item.index then
            listbox:drawRect(0, y, listbox:getWidth(), item.height - 1, 0.3, 0.7, 0.35, 0.15)
        end
        listbox:drawText(item.text, 10, y + 4, r, g, b, 1, listbox.font)
        return y + item.height
    end
    self:addChild(self.songList)

    self.playButton = ISButton:new(10, self.height - 32, 100, 24, "", self, ECSongbook.onAction)
    self.playButton:initialise()
    self:addChild(self.playButton)

    self.closeButton = ISButton:new(120, self.height - 32, 80, 24, getText("UI_Cancel"), self, ECSongbook.close)
    self.closeButton:initialise()
    self:addChild(self.closeButton)

    self:refresh()
end

function ECSongbook:rowText(row)
    local song = row.song
    local text = getText(song.name) .. "  (" .. getText("IGUI_EC_Difficulty_" .. song.difficulty) .. ")"
    if row.kind == "session" then
        return getText("ContextMenu_EC_JoinGroup") .. " " .. row.username .. " - " .. text
    end
    if song.type == "group" then
        text = "[" .. getText("IGUI_EC_MultiInstrument") .. "] " .. text
    end
    if not ECCore:isSongKnown(self.playerObj, song) and self.playerObj:getAccessLevel() == "None" then
        text = text .. "  - " .. getText("IGUI_EC_UnknownSong")
    end
    return text
end

function ECSongbook:refresh()
    if not self.songList then return end
    local selectedIndex = self.songList.selected
    self.songList:clear()
    for _, row in ipairs(self:buildRows()) do
        self.songList:addItem(self:rowText(row), row)
    end
    if selectedIndex and selectedIndex > 0 and selectedIndex <= #self.songList.items then
        self.songList.selected = selectedIndex
    end
    self.skillLabel:setName(self:skillLine())
    self:syncButtons()
end

function ECSongbook:selectedRow()
    local item = self.songList.items[self.songList.selected]
    return item and item.item or nil
end

function ECSongbook:syncButtons()
    local row = self:selectedRow()
    if not row then
        self.playButton:setTitle(getText("IGUI_EC_Play"))
        self.playButton:setEnable(false)
        return
    end
    if row.kind == "session" then
        self.playButton:setTitle(getText("ContextMenu_EC_JoinGroup"))
    elseif row.song.type == "group" then
        self.playButton:setTitle(getText("ContextMenu_EC_StartGroupSong"))
    else
        self.playButton:setTitle(getText("IGUI_EC_Play"))
    end
    local busy = isClient() and not self.worldMode and ECGroupClient.isBusy()
    self.playButton:setEnable(row.issue == nil and not busy)
end

function ECSongbook:prerender()
    ISCollapsableWindow.prerender(self)
    self:syncButtons()
end

function ECSongbook:onAction()
    local row = self:selectedRow()
    if not row or row.issue then return end

    if self.worldMode then
        ECWorld.play(self.playerObj, self.worldDef, self.worldObject, row.song)
        self:close()
        return
    end

    if row.kind == "session" then
        ECGroupClient.SendJoinPerformance(self.playerObj, row.username, row.song, self.instrument)
    elseif row.song.type == "group" then
        ECGroupClient.SendStartPerformance(self.playerObj, row.song, self.instrument)
    else
        ECLaunch.play(self.playerObj, self.instrument, row.song)
    end
    self:close()
end

function ECSongbook:close()
    self:setVisible(false)
    self:removeFromUIManager()
    if ECSongbook.instance == self then
        ECSongbook.instance = nil
        if isClient() then
            ECGroupClient.onChanged = nil
        end
    end
end

-- Openers -------------------------------------------------------------------

local function createWindow(playerObj, titleText)
    if ECSongbook.instance then
        ECSongbook.instance:close()
    end
    local o = ECSongbook:new(getCore():getScreenWidth() / 2 - 200, getCore():getScreenHeight() / 2 - 220, 400, 440)
    o.playerObj = playerObj
    o.title = titleText
    ECSongbook.instance = o
    return o
end

local function showWindow(o)
    o:initialise()
    o:addToUIManager()
    if isClient() then
        ECGroupClient.onChanged = function()
            if ECSongbook.instance then
                ECSongbook.instance:refresh()
            end
        end
    end
end

--- Open for a held/carried instrument item.
function ECSongbook.open(playerObj, instrument)
    local instrumentType = ECCore:getInstrumentType(instrument:getFullType())
    if not instrumentType then return end
    local o = createWindow(playerObj, getText("ContextMenu_EC_Songbook") .. " - " .. instrument:getName())
    o.instrument = instrument
    o.instrumentType = instrumentType
    o.worldMode = false
    showWindow(o)
end

--- Open for a fixed world instrument (piano and friends).
function ECSongbook.openWorld(playerObj, def, object)
    local o = createWindow(playerObj, getText("ContextMenu_EC_Songbook") .. " - " .. getText(def.nameKey))
    o.instrument = nil
    o.instrumentType = def.instrumentType
    o.worldMode = true
    o.worldDef = def
    o.worldObject = object
    showWindow(o)
end

function ECSongbook:new(x, y, width, height)
    local o = ISCollapsableWindow:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    o.resizable = false
    return o
end
