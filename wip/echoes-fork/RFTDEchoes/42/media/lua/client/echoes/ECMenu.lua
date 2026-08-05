-- Echoes: the slim context menu. The fork source stacked four levels of
-- nested submenus here; Echoes keeps right-click to three entries and sends
-- everything else through the songbook window.
--
--   instrument      -> Songbook / Pretend to Play
--   sheet music     -> Learn (savants sight-read; group sheets broker in MP)
--   blank sheet     -> Transcribe (savants with something to write with)
--   staff + sheet   -> Admin: Change Song
--
-- Fixed from the fork source: right-clicking group-song sheet music in SP
-- crashed (it reached for the MP-only group client); it now shows a tooltip.

require "echoes/ECCore"
require "echoes/ECLaunch"
require "echoes/ECTranscribeAction"
require "echoes/ECSongbook"

ECMenu = ECMenu or {}

local function addTooltip(option, text)
    local toolTip = ISWorldObjectContextMenu.addToolTip()
    toolTip.description = getText(text)
    option.toolTip = toolTip
end

local function getAllInventories(playerObj)
    local containerList = ArrayList.new()
    if not playerObj then return containerList end
    for _, v in ipairs(getPlayerInventory(playerObj:getPlayerNum()).inventoryPane.inventoryPage.backpacks) do
        containerList:add(v.inventory)
    end
    for _, v in ipairs(getPlayerLoot(playerObj:getPlayerNum()).inventoryPane.inventoryPage.backpacks) do
        containerList:add(v.inventory)
    end
    return containerList
end

local function findInstrumentFor(playerObj, song)
    local inventories = getAllInventories(playerObj)
    for j = 0, inventories:size() - 1 do
        local invItems = inventories:get(j):getItems()
        for i = 0, invItems:size() - 1 do
            local invItem = invItems:get(i)
            local instrumentType = ECCore:getInstrumentType(invItem:getFullType())
            if instrumentType then
                if song.type == "single" then
                    if instrumentType == song.instrumentType then
                        return invItem
                    end
                else
                    for _, songInstrumentType in ipairs(song.instrumentTypes) do
                        if instrumentType == songInstrumentType then
                            return invItem
                        end
                    end
                end
            end
        end
    end
    return nil
end

local function learnImmediate(playerObj, sheetMusic, song)
    if SandboxVars.RFTDEchoes.SheetMusicConsumed then
        sheetMusic:getContainer():DoRemoveItem(sheetMusic)
    end
    ECCore:learnSong(playerObj, song)
    HaloTextHelper.addText(playerObj, getText("IGUI_EC_LearnedSong"), 200, 200, 250)
end

function ECMenu.CheckInstrument(playerObj, context, item)
    if not ECCore:getInstrumentType(item:getFullType()) then return end

    context:addOption(getText("ContextMenu_EC_Songbook"), playerObj, function(player)
        ECSongbook.open(player, item)
    end)
    context:addOption(getText("ContextMenu_EC_PretendPlay"), playerObj, function(player)
        ECLaunch.play(player, item, nil)
    end)
end

function ECMenu.CheckLearnSong(playerObj, context, item)
    if item:getFullType() ~= "RFTDEchoes.SheetMusic" then return end
    local songName = item:getModData()["EC_Song"]

    if songName == "IGUI_EC_AllSongs" then
        local learnAllSongsOption = context:addOption(getText("ContextMenu_EC_LearnSong"))
        learnAllSongsOption.onSelect = function()
            playerObj:getInventory():DoRemoveItem(item)
            for _, song in ipairs(ECCore:getAllSongs()) do
                ECCore:learnSong(playerObj, song)
            end
            HaloTextHelper.addText(playerObj, getText("IGUI_EC_LearnedAllSongs"), 200, 200, 250)
        end
        return
    end

    if not songName then return end
    local song = ECCore:getSong(songName)
    if not song then return end
    local learnSongOption = context:addOption(getText("ContextMenu_EC_LearnSong"))

    if playerObj:getModData()["EC_Learned:" .. songName] then
        learnSongOption.notAvailable = true
        addTooltip(learnSongOption, "IGUI_EC_AlreadyKnown")
        return
    end

    if not playerObj:getInventory():contains(item) then
        learnSongOption.notAvailable = true
        addTooltip(learnSongOption, "IGUI_EC_NotInInventory")
        return
    end

    if ECCore:isSavant(playerObj) then
        learnSongOption.onSelect = learnImmediate
        learnSongOption.target = playerObj
        learnSongOption.param1 = item
        learnSongOption.param2 = song
        addTooltip(learnSongOption, "IGUI_EC_SightRead")
        return
    end

    local instrument = findInstrumentFor(playerObj, song)
    if not instrument then
        learnSongOption.notAvailable = true
        addTooltip(learnSongOption, "IGUI_EC_NoInstrument")
        return
    end

    local learnIssue = ECCore:getLearnSongIssue(playerObj, songName, ECCore:getInstrumentType(instrument:getFullType()))
    if learnIssue then
        learnSongOption.notAvailable = true
        addTooltip(learnSongOption, learnIssue)
        return
    end

    if song.type == "single" then
        learnSongOption.onSelect = function()
            ECLaunch.learn(playerObj, instrument, item)
        end
        return
    end

    -- Group songs need other players; the broker only exists on MP clients.
    if not isClient() then
        learnSongOption.notAvailable = true
        addTooltip(learnSongOption, "IGUI_EC_GroupNeedsMP")
        return
    end

    if ECGroupClient.isBusy() then
        learnSongOption.notAvailable = true
        addTooltip(learnSongOption, "IGUI_EC_AlreadyInGroupSong")
        return
    end

    local onlinePlayers = getOnlinePlayers()
    for username, groupData in pairs(ECGroupClient.openPerformances) do
        if song.name == groupData.songName then
            for i = 0, onlinePlayers:size() - 1 do
                local player = onlinePlayers:get(i)
                if player:getUsername() == username and playerObj:getDistanceSq(player) < 36 then
                    learnSongOption.name = getText("ContextMenu_EC_JoinGroup") .. " - " .. username .. " - " .. getText(song.name)
                    learnSongOption.onSelect = function()
                        ECGroupClient.SendJoinPerformanceLearn(playerObj, username, item, instrument)
                    end
                    return
                end
            end
        end
    end

    learnSongOption.name = getText("ContextMenu_EC_StartGroupSong") .. " - " .. getText(song.name)
    learnSongOption.onSelect = function()
        ECGroupClient.SendStartPerformanceLearn(playerObj, item, instrument)
    end
end

function ECMenu.CheckTranscribe(playerObj, context, item)
    if item:getFullType() ~= "Base.SheetPaper2" then return end
    if not ECCore:isSavant(playerObj) then return end
    local inv = playerObj:getInventory()
    if not inv:containsTagRecurse(ItemTag.WRITE) then return end

    local transcribeOption = context:addOption(getText("ContextMenu_EC_TranscribeMusic"))
    local transcribeContext = context:getNew(context)
    context:addSubMenu(transcribeOption, transcribeContext)

    local knownSongs = ECCore:getAllKnownSongs(playerObj)
    for instrument, songsByLevel in pairs(knownSongs) do
        local instrumentOption = transcribeContext:addOption(getText("IGUI_EC_InstrumentType_" .. instrument))
        local instrumentContext = transcribeContext:getNew(transcribeContext)
        transcribeContext:addSubMenu(instrumentOption, instrumentContext)

        for _, songs in pairs(songsByLevel) do
            for _, song in ipairs(songs) do
                local transcribeSongOption = instrumentContext:addOption(getText(song.name))
                transcribeSongOption.onSelect = function()
                    ISTimedActionQueue.add(ECTranscribeAction:new(playerObj, item, song))
                end
            end
        end
    end
end

function ECMenu.CheckAdminConvertMusic(playerObj, context, item)
    if playerObj:getAccessLevel() == "None" then return end
    if item:getFullType() ~= "RFTDEchoes.SheetMusic" then return end

    local convertOption = context:addOption("Admin: Change Song")
    local convertContext = context:getNew(context)
    context:addSubMenu(convertOption, convertContext)

    local allSongsOption = convertContext:addOption(getText("IGUI_EC_AllSongs"))
    allSongsOption.onSelect = function()
        item:getModData()["EC_Song"] = "IGUI_EC_AllSongs"
    end

    local allSongs = ECCore:getAllSongs()
    table.sort(allSongs, function(a, b) return getText(a.name) < getText(b.name) end)
    for _, song in ipairs(allSongs) do
        local label
        if song.type == "group" then
            label = getText("IGUI_EC_MultiInstrument") .. " - " .. getText(song.name)
        else
            label = getText("IGUI_EC_InstrumentType_" .. song.instrumentType) .. " - " .. getText(song.name)
        end
        local convertSongOption = convertContext:addOption(label)
        convertSongOption.onSelect = function()
            item:getModData()["EC_Song"] = song.name
        end
    end
end

function ECMenu.ShowMenu(playerIdx, context, items)
    local actualItems = ISInventoryPane.getActualItems(items)
    local playerObj = getSpecificPlayer(playerIdx)

    local item = actualItems[1]
    if not item then return end

    ECMenu.CheckInstrument(playerObj, context, item)
    ECMenu.CheckLearnSong(playerObj, context, item)
    ECMenu.CheckTranscribe(playerObj, context, item)
    ECMenu.CheckAdminConvertMusic(playerObj, context, item)
end

if not ECMenu.initialized then
    ECMenu.initialized = true
    Events.OnPreFillInventoryObjectContextMenu.Add(function(p, c, i) ECMenu.ShowMenu(p, c, i) end)
end
