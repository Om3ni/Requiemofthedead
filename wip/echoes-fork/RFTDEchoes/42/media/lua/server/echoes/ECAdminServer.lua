-- Echoes: server side of staff XP grants and song teaching. The server only
-- validates access and relays to the target's client, because skills live in
-- the target's modData and are applied there.

if not isServer() then return end

require "echoes/ECCore"

local MODULE = "RFTDEchoes:AdminXp"

ECAdminServer = ECAdminServer or {}

local function findOnlinePlayer(username)
    local onlinePlayers = getOnlinePlayers()
    for i = 0, onlinePlayers:size() - 1 do
        local player = onlinePlayers:get(i)
        if player:getUsername() == username then
            return player
        end
    end
    return nil
end

function ECAdminServer:GivePlayerXp(adminPlayer, args)
    if adminPlayer:getAccessLevel() ~= "Admin" and adminPlayer:getAccessLevel() ~= "Moderator" then
        print("RFTDEchoes: GivePlayerXp called by non-staff player: " .. adminPlayer:getUsername())
        return
    end

    local targetUsername = args[1]
    local skillType = args[2]
    local xpAmount = tonumber(args[3])

    if not targetUsername or not skillType or not xpAmount then
        print("RFTDEchoes: Invalid arguments for GivePlayerXp")
        return
    end

    local targetPlayer = findOnlinePlayer(targetUsername)
    if not targetPlayer then
        sendServerCommand(adminPlayer, MODULE, "PlayerNotFound", {targetUsername})
        return
    end

    sendServerCommand(targetPlayer, MODULE, "ReceiveXp", {skillType, xpAmount})
    sendServerCommand(adminPlayer, MODULE, "XpGiven", {targetUsername, skillType, xpAmount})
end

function ECAdminServer:TeachPlayerSong(adminPlayer, args)
    if adminPlayer:getAccessLevel() ~= "Admin" and adminPlayer:getAccessLevel() ~= "Moderator" then
        print("RFTDEchoes: TeachPlayerSong called by non-staff player: " .. adminPlayer:getUsername())
        return
    end

    local targetUsername = args[1]
    local songName = args[2]

    if not targetUsername or not songName then
        print("RFTDEchoes: Invalid arguments for TeachPlayerSong")
        return
    end

    local targetPlayer = findOnlinePlayer(targetUsername)
    if not targetPlayer then
        sendServerCommand(adminPlayer, MODULE, "PlayerNotFound", {targetUsername})
        return
    end

    if not ECCore:getSong(songName) then
        sendServerCommand(adminPlayer, MODULE, "SongNotFound", {songName})
        return
    end

    sendServerCommand(targetPlayer, MODULE, "LearnSong", {songName})
    sendServerCommand(adminPlayer, MODULE, "SongTaught", {targetUsername, songName})
end

Events.OnClientCommand.Add(function(module, command, player, args)
    if module ~= MODULE then return end
    if not ECAdminServer[command] then return end
    ECAdminServer[command](ECAdminServer, player, args)
end)
