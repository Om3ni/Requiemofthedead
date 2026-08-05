-- Echoes: staff-side XP grants and song teaching. Kept as the fork source's
-- dialog flow for now (redesign parked with the songbook refinement pass).
-- Skill state lives in target-player modData, so grants round-trip through
-- the server to the target's own client, which applies them locally.

require "echoes/ECCore"

local MODULE = "RFTDEchoes:AdminXp"

ECAdminClient = ECAdminClient or {}

local function createXpInputDialog(playerObj, skillType, callback)
    local modal = ISTextBox:new(0, 0, 280, 180, getText("IGUI_EC_AdminXp_EnterAmount"), "", nil, callback)
    modal:initialise()
    modal:addToUIManager()
    modal:setAlwaysOnTop(true)
    modal.backgroundColor = {r=0, g=0, b=0, a=0.8}
    modal.borderColor = {r=0.4, g=0.4, b=0.4, a=1}
    modal.entry:setOnlyNumbers(true)
    modal.entry:setMaxTextLength(6)
    modal:setX(getCore():getScreenWidth() / 2 - modal.width / 2)
    modal:setY(getCore():getScreenHeight() / 2 - modal.height / 2)
    return modal
end

local function createSongSelectionDialog(playerObj, callback)
    local modal = ISModalDialog:new(0, 0, 400, 500, getText("IGUI_EC_AdminXp_SelectSong"), false, nil, callback)
    modal:initialise()
    modal:addToUIManager()
    modal:setAlwaysOnTop(true)

    local listBox = ISScrollingListBox:new(10, 50, modal.width - 20, modal.height - 100)
    listBox:initialise()
    listBox:instantiate()
    modal:addChild(listBox)

    local allSongs = ECCore:getAllSongs()
    local songsByInstrument = {}

    for _, song in ipairs(allSongs) do
        if song.type == "single" then
            songsByInstrument[song.instrumentType] = songsByInstrument[song.instrumentType] or {}
            table.insert(songsByInstrument[song.instrumentType], song)
        else
            songsByInstrument["Group"] = songsByInstrument["Group"] or {}
            table.insert(songsByInstrument["Group"], song)
        end
    end

    for instrumentType, songs in pairs(songsByInstrument) do
        listBox:addItem(getText("IGUI_EC_InstrumentType_" .. instrumentType) or instrumentType, nil)

        table.sort(songs, function(a, b) return getText(a.name) < getText(b.name) end)

        for _, song in ipairs(songs) do
            local songItem = listBox:addItem("  " .. getText(song.name), song)
            songItem.item.textColor = {r=1, g=1, b=1, a=1}
        end
    end

    local originalCallback = callback
    modal.onclick = function(self, button)
        if button.internal == "OK" then
            local selected = listBox.selected
            if selected > 0 then
                local selectedItem = listBox.items[selected]
                if selectedItem.item then
                    originalCallback(selectedItem.item)
                end
            end
        end
    end

    modal:setX(getCore():getScreenWidth() / 2 - modal.width / 2)
    modal:setY(getCore():getScreenHeight() / 2 - modal.height / 2)
    return modal
end

function ECAdminClient.showXpDialog(targetPlayer, skillType)
    local skillName = getText(ECCore:getSkillName(skillType))
    local dialog
    dialog = createXpInputDialog(targetPlayer, skillType, function(target, button)
        if button.internal == "OK" and dialog.entry:getText() and dialog.entry:getText() ~= "" then
            local xpAmount = tonumber(dialog.entry:getText())
            if xpAmount and xpAmount > 0 then
                sendClientCommand(getPlayer(), MODULE, "GivePlayerXp", {targetPlayer:getUsername(), skillType, xpAmount})
            end
        end
    end)
    dialog.text = getText("IGUI_EC_AdminXp_EnterXpFor") .. " " .. targetPlayer:getUsername() .. " (" .. skillName .. ")"
end

function ECAdminClient.showSongDialog(targetPlayer)
    createSongSelectionDialog(targetPlayer, function(selectedSong)
        if selectedSong then
            sendClientCommand(getPlayer(), MODULE, "TeachPlayerSong", {targetPlayer:getUsername(), selectedSong.name})
        end
    end)
end

-- Server -> client handlers ------------------------------------------------

function ECAdminClient.ReceiveXp(args)
    local skillType = args[1]
    local xpAmount = tonumber(args[2])

    if skillType and xpAmount then
        local player = getPlayer()
        ECCore:givePlayerXp(player, skillType, xpAmount)
        local skillName = getText(ECCore:getSkillName(skillType))
        HaloTextHelper.addText(player, getText("IGUI_EC_AdminXp_ReceivedXp") .. " " .. xpAmount .. " " .. skillName .. " XP", 100, 255, 100)
    end
end

function ECAdminClient.LearnSong(args)
    local songName = args[1]

    if songName then
        local player = getPlayer()
        local song = ECCore:getSong(songName)
        if song then
            ECCore:learnSong(player, song)
            HaloTextHelper.addText(player, getText("IGUI_EC_AdminXp_LearnedSong") .. " " .. getText(song.name), 100, 255, 100)
        end
    end
end

function ECAdminClient.XpGiven(args)
    local targetUsername = args[1]
    local skillType = args[2]
    local xpAmount = args[3]
    local skillName = getText(ECCore:getSkillName(skillType))
    HaloTextHelper.addText(getPlayer(), getText("IGUI_EC_AdminXp_GaveXp") .. " " .. xpAmount .. " " .. skillName .. " XP to " .. targetUsername, 255, 255, 100)
end

function ECAdminClient.SongTaught(args)
    local targetUsername = args[1]
    local songName = args[2]
    HaloTextHelper.addText(getPlayer(), getText("IGUI_EC_AdminXp_TaughtSong") .. " " .. getText(songName) .. " to " .. targetUsername, 255, 255, 100)
end

function ECAdminClient.PlayerNotFound(args)
    local targetUsername = args[1]
    HaloTextHelper.addText(getPlayer(), getText("IGUI_EC_AdminXp_PlayerNotFound") .. " " .. targetUsername, 255, 100, 100)
end

function ECAdminClient.SongNotFound(args)
    local songName = args[1]
    HaloTextHelper.addText(getPlayer(), getText("IGUI_EC_AdminXp_SongNotFound") .. " " .. songName, 255, 100, 100)
end

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= MODULE then return end
    if not ECAdminClient[command] then return end
    ECAdminClient[command](args)
end)

-- Staff world context menu: manage a player's instrument skills by clicking
-- their square. Ported unchanged from the fork source.

ECAdminMenu = ECAdminMenu or {}

function ECAdminMenu.onMenu(playerIdx, context, worldobjects, test)
    local player = getSpecificPlayer(playerIdx)
    if not player then return end
    if player:getAccessLevel() ~= "Admin" and player:getAccessLevel() ~= "Moderator" then
        return
    end

    local square = worldobjects[1] and worldobjects[1]:getSquare()
    if not square then return end
    local movingObjects = square:getMovingObjects()
    if not movingObjects or movingObjects:size() == 0 then return end

    for i = 0, movingObjects:size() - 1 do
        local movingObject = movingObjects:get(i)
        if instanceof(movingObject, "IsoPlayer") then
            local playerObj = movingObject

            local playerMenu = context:addOption(getText("IGUI_EC_AdminXp_ManagePlayer") .. " " .. playerObj:getUsername())
            local playerContext = context:getNew(context)
            context:addSubMenu(playerMenu, playerContext)

            local skillTypes = ECCore:getAllSkillTypes()

            for _, skillType in ipairs(skillTypes) do
                local skillName = getText(ECCore:getSkillName(skillType))
                local skillMenu = playerContext:addOption(skillName)
                local skillContext = playerContext:getNew(playerContext)
                playerContext:addSubMenu(skillMenu, skillContext)

                local addXpOption = skillContext:addOption(getText("IGUI_EC_AdminXp_AddXp"))
                addXpOption.onSelect = function()
                    ECAdminClient.showXpDialog(playerObj, skillType)
                end

                local teachSongOption = skillContext:addOption(getText("IGUI_EC_AdminXp_TeachSong"))
                teachSongOption.onSelect = function()
                    ECAdminClient.showSongDialog(playerObj)
                end
            end
        end
    end
end

Events.OnFillWorldObjectContextMenu.Add(function(playerIdx, context, worldobjects, test)
    ECAdminMenu.onMenu(playerIdx, context, worldobjects, test)
end)
