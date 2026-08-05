-- Echoes: server broker for group performances (MP only). Groups are keyed by
-- leader username; pending groups collect performers per instrument slot and
-- flip to active when full. The server holds no timers - clients drive start
-- and stop, the broker just keeps membership honest.

if not isServer() then return end

require "echoes/ECCore"

local MODULE = "RFTDEchoes:GroupPlay"

ECGroupServer = ECGroupServer or {}

ECGroupServer.Data = {
    pendingGroups = {},
    activeGroups = {},
}

local function sendOpenPerformance(username)
    sendServerCommand(MODULE, "OpenPerformance", {username, ECGroupServer.Data.pendingGroups[username]})
end

local function sendClosePerformance(username, started)
    sendServerCommand(MODULE, "ClosePerformance", {username, started})
end

local function sendWaitPerformance(player, username)
    sendServerCommand(player, MODULE, "WaitPerformance", {username})
end

local function sendToPerformers(groupData, command, args)
    local onlinePlayers = getOnlinePlayers()
    for i = 0, onlinePlayers:size() - 1 do
        local player = onlinePlayers:get(i)
        local playerUsername = player:getUsername()
        for _, performerUsername in pairs(groupData.performers) do
            if playerUsername == performerUsername then
                sendServerCommand(player, MODULE, command, args)
            end
        end
    end
end

function ECGroupServer:StartPerformance(player, args)
    local username = player:getUsername()
    local song = ECCore:getSong(args[1])
    local instrument = args[2]
    if not song then
        sendServerCommand(player, MODULE, "StartPerformanceFail", {"InvalidSong"})
        return
    end
    self.Data.pendingGroups[username] = {}
    self.Data.pendingGroups[username].songName = song.name
    self.Data.pendingGroups[username].performers = {}
    for i, instrumentType in ipairs(song.instrumentTypes) do
        if instrumentType == instrument then
            self.Data.pendingGroups[username].performers[i] = username
            sendWaitPerformance(player, username)
            sendOpenPerformance(username)
            return
        end
    end
    -- Leader's instrument doesn't fit the song; should never happen.
    self.Data.pendingGroups[username] = nil
    sendServerCommand(player, MODULE, "StartPerformanceFail", {"InternalError"})
end

function ECGroupServer:JoinPerformance(player, args)
    local username = args[1]
    local instrument = args[2]

    -- Group was cancelled, or filled, between the client seeing it and asking.
    if not self.Data.pendingGroups[username] then
        sendServerCommand(player, MODULE, "FailJoinPerformance", {"NoGroup"})
        return
    end
    local song = ECCore:getSong(self.Data.pendingGroups[username].songName)
    local performers = self.Data.pendingGroups[username].performers
    local didJoinSlot = false
    for i, instrumentType in ipairs(song.instrumentTypes) do
        if not performers[i] and instrumentType == instrument then
            performers[i] = player:getUsername()
            didJoinSlot = true
            break
        end
    end
    if not didJoinSlot then
        sendServerCommand(player, MODULE, "FailJoinPerformance", {"NoSlot"})
        return
    end

    local allPerformers = true
    for i, _ in ipairs(song.instrumentTypes) do
        if not performers[i] then
            allPerformers = false
            break
        end
    end

    if allPerformers then
        self.Data.activeGroups[username] = self.Data.pendingGroups[username]
        self.Data.pendingGroups[username] = nil
        sendToPerformers(self.Data.activeGroups[username], "StartPerformance", {username})
        sendClosePerformance(username, true)
    else
        sendWaitPerformance(player, username)
        sendOpenPerformance(username)
    end
end

function ECGroupServer:LeavePerformance(player)
    local username = player:getUsername()

    for groupUsername, group in pairs(self.Data.pendingGroups) do
        if groupUsername == username then
            self.Data.pendingGroups[username] = nil
            sendClosePerformance(groupUsername, false)
            return
        end

        for i, performerUsername in ipairs(group.performers) do
            if performerUsername == username then
                group.performers[i] = nil
                sendOpenPerformance(groupUsername)
                return
            end
        end
    end

    for groupUsername, group in pairs(self.Data.activeGroups) do
        for _, performerUsername in ipairs(group.performers) do
            if performerUsername == username then
                sendToPerformers(group, "StopPerformance", {groupUsername, "PlayerLeft"})
                self.Data.activeGroups[groupUsername] = nil
                return
            end
        end
    end
end

function ECGroupServer:EndPerformance(player)
    local username = player:getUsername()
    local group = self.Data.activeGroups[username]
    if group then
        sendToPerformers(group, "StopPerformance", {username, "SongFinished"})
        self.Data.activeGroups[username] = nil
    end
end

Events.OnClientCommand.Add(function(module, command, player, args)
    if module ~= MODULE then return end
    if not ECGroupServer[command] then return end
    ECGroupServer[command](ECGroupServer, player, args)
end)
