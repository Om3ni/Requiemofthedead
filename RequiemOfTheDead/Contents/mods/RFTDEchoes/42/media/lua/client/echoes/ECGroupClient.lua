-- Echoes: client half of group performances (MP only). The server brokers
-- slots keyed by leader username; this side tracks what we're pending on,
-- swaps the wait action for the play action when the group fills, and keeps
-- openPerformances current so UI can list joinable sessions.
--
-- UI hook: ECGroupClient.onChanged is called (if set) whenever the open
-- session list or our own state moves - the songbook subscribes to repaint.

if not isClient() then return end

require "echoes/ECCore"
require "echoes/ECLaunch"
require "echoes/ECGroupPlayAction"
require "echoes/ECGroupLearnAction"
require "echoes/ECWaitGroupAction"
require "echoes/ECWaitLearnGroupAction"

local MODULE = "RFTDEchoes:GroupPlay"

ECGroupClient = ECGroupClient or {}
ECGroupClient.pendingJoinParams = nil
ECGroupClient.pendingWaitAction = nil
ECGroupClient.currentPlayAction = nil
ECGroupClient.openPerformances = {}
ECGroupClient.onChanged = nil

local function notifyChanged()
    if ECGroupClient.onChanged then
        ECGroupClient.onChanged()
    end
end

--- True while we're in any stage of a group performance; UI uses this to
--- grey out "start another one".
function ECGroupClient.isBusy()
    return ECGroupClient.pendingJoinParams ~= nil
        or ECGroupClient.pendingWaitAction ~= nil
        or ECGroupClient.currentPlayAction ~= nil
end

function ECGroupClient.SendStartPerformance(player, song, instrument)
    local instrumentType = ECCore:getInstrumentType(instrument:getFullType())
    ECGroupClient.pendingJoinParams = {
        type = "perform",
        player = player,
        groupUsername = player:getUsername(),
        song = song,
        instrument = instrument,
        isLeader = true,
    }
    sendClientCommand(player, MODULE, "StartPerformance", {song.name, instrumentType})
end

function ECGroupClient.SendJoinPerformance(player, username, song, instrument)
    local instrumentType = ECCore:getInstrumentType(instrument:getFullType())
    ECGroupClient.pendingJoinParams = {
        type = "perform",
        player = player,
        groupUsername = username,
        song = song,
        instrument = instrument,
        isLeader = false,
    }
    sendClientCommand(player, MODULE, "JoinPerformance", {username, instrumentType})
end

function ECGroupClient.SendStartPerformanceLearn(player, sheetMusic, instrument)
    local song = ECCore:getSong(sheetMusic:getModData()["EC_Song"])
    local instrumentType = ECCore:getInstrumentType(instrument:getFullType())
    ECGroupClient.pendingJoinParams = {
        type = "learn",
        player = player,
        groupUsername = player:getUsername(),
        song = song,
        sheetMusic = sheetMusic,
        instrument = instrument,
        isLeader = true,
    }
    sendClientCommand(player, MODULE, "StartPerformance", {song.name, instrumentType})
end

function ECGroupClient.SendJoinPerformanceLearn(player, username, sheetMusic, instrument)
    local song = ECCore:getSong(sheetMusic:getModData()["EC_Song"])
    local instrumentType = ECCore:getInstrumentType(instrument:getFullType())
    ECGroupClient.pendingJoinParams = {
        type = "learn",
        player = player,
        groupUsername = username,
        song = song,
        sheetMusic = sheetMusic,
        instrument = instrument,
        isLeader = false,
    }
    sendClientCommand(player, MODULE, "JoinPerformance", {username, instrumentType})
end

function ECGroupClient.SendLeavePerformance(player)
    sendClientCommand(player, MODULE, "LeavePerformance", {})
    ECGroupClient.pendingJoinParams = nil
    ECGroupClient.pendingWaitAction = nil
    ECGroupClient.currentPlayAction = nil
    notifyChanged()
end

function ECGroupClient.SendEndPerformance(player)
    sendClientCommand(player, MODULE, "EndPerformance", {})
    ECGroupClient.pendingJoinParams = nil
    ECGroupClient.pendingWaitAction = nil
    ECGroupClient.currentPlayAction = nil
    notifyChanged()
end

-- Server -> client handlers ------------------------------------------------

function ECGroupClient.OpenPerformance(args)
    local username = args[1]
    local groupData = args[2]
    ECGroupClient.openPerformances[username] = groupData
    notifyChanged()
end

function ECGroupClient.ClosePerformance(args)
    local username = args[1]
    local started = args[2]
    if not started and ECGroupClient.pendingWaitAction and ECGroupClient.pendingWaitAction.groupUsername == username then
        ECGroupClient.pendingWaitAction:forceComplete()
        ECGroupClient.pendingWaitAction = nil
    end
    ECGroupClient.openPerformances[username] = nil
    notifyChanged()
end

function ECGroupClient.WaitPerformance(args)
    if not ECGroupClient.pendingJoinParams then return end
    local username = args[1]

    local params = ECGroupClient.pendingJoinParams
    local waitAction
    if params.type == "perform" then
        waitAction = ECLaunch.group(ECWaitGroupAction, params.player, username, params.instrument, params.song, params.isLeader)
    elseif params.type == "learn" then
        waitAction = ECLaunch.group(ECWaitLearnGroupAction, params.player, username, params.instrument, params.sheetMusic, params.isLeader)
    end
    ECGroupClient.pendingWaitAction = waitAction
    ECGroupClient.pendingJoinParams = nil
    notifyChanged()
end

function ECGroupClient.StartPerformance(args)
    local username = args[1]

    -- Last slot filled the group before our wait action even started.
    if ECGroupClient.pendingJoinParams and username == ECGroupClient.pendingJoinParams.groupUsername then
        local params = ECGroupClient.pendingJoinParams
        local playAction
        if params.type == "perform" then
            playAction = ECLaunch.group(ECGroupPlayAction, getPlayer(), username, params.instrument, params.song, params.isLeader)
        elseif params.type == "learn" then
            playAction = ECLaunch.group(ECGroupLearnAction, getPlayer(), username, params.instrument, params.sheetMusic, params.isLeader)
        end
        ECGroupClient.pendingJoinParams = nil
        ECGroupClient.pendingWaitAction = nil
        ECGroupClient.currentPlayAction = playAction
        notifyChanged()
        return
    end

    if ECGroupClient.pendingWaitAction and username == ECGroupClient.pendingWaitAction.groupUsername then
        local waitAction = ECGroupClient.pendingWaitAction
        ECGroupClient.pendingJoinParams = nil
        waitAction.isGroupReady = true
        waitAction:forceComplete()
        local playAction
        if waitAction.Type == "ECWaitGroupAction" then
            playAction = ECLaunch.group(ECGroupPlayAction, getPlayer(), username, waitAction.instrument, waitAction.song, waitAction.isLeader)
        elseif waitAction.Type == "ECWaitLearnGroupAction" then
            playAction = ECLaunch.group(ECGroupLearnAction, getPlayer(), username, waitAction.instrument, waitAction.sheetMusic, waitAction.isLeader)
        end
        ECGroupClient.pendingWaitAction = nil
        ECGroupClient.currentPlayAction = playAction
        notifyChanged()
        return
    end
end

function ECGroupClient.StopPerformance(args)
    if not ECGroupClient.currentPlayAction then
        return
    end

    local username = args[1]
    local reason = args[2]
    if username ~= ECGroupClient.currentPlayAction.groupUsername then return end
    if reason == "PlayerLeft" then
        ECGroupClient.currentPlayAction:forceStop()
        ECGroupClient.currentPlayAction = nil
        getPlayer():Say(getText("IGUI_EC_PlayerLeft"))
    else
        ECGroupClient.currentPlayAction:forceComplete()
        ECGroupClient.currentPlayAction = nil
    end
    notifyChanged()
end

function ECGroupClient.StartPerformanceFail(args)
    local reason = args[1]
    if reason == "InternalError" then
        getPlayer():Say(getText("IGUI_EC_InternalError"))
    elseif reason == "InvalidSong" then
        getPlayer():Say(getText("IGUI_EC_InvalidSong"))
    end
    ECGroupClient.pendingJoinParams = nil
    notifyChanged()
end

function ECGroupClient.FailJoinPerformance(args)
    local reason = args[1]
    if reason == "NoGroup" then
        getPlayer():Say(getText("IGUI_EC_NoGroup"))
    elseif reason == "NoSlot" then
        getPlayer():Say(getText("IGUI_EC_NoSlot"))
    end
    ECGroupClient.pendingJoinParams = nil
    notifyChanged()
end

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= MODULE then return end
    if not ECGroupClient[command] then return end
    ECGroupClient[command](args)
end)
