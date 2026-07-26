-- DFPatch_AntiCheatLogNoise.lua - Dragonfly removable log-noise patch
--
-- Silences the anti-cheat WARN flood on the Multiplayer debug channel.
-- Every verdict is written THREE independent ways by the engine
-- (AntiCheat.java log()/isValid()): DebugType.Multiplayer.warn (debug
-- log + console), LoggerManager "user" (Logs/<server>_user.txt), and
-- admin chat. One live-morning sample: 1,945 of ~2,374 Multiplayer-
-- channel lines (82%) were anti-cheat warnings.
--
-- This raises the Multiplayer channel floor from Warning to Error, the
-- same technique as DFPatch_Turn180Noise. user.txt and admin chat are
-- untouched - that file remains the forensic record (and Guardian's
-- harvest channel), which is exactly why the debug copy is redundant.
--
-- TRADE-OFF: channel-wide, not message-specific. Also muted from the
-- debug log/console: PacketTypes "not consistent/not valid" warns,
-- ObjectModDataPacket stale-hutch warns, and LOG-severity lines ("coop
-- player ... is joining", SendAlarm). Joins stay recorded in Logs/
-- *_connections.txt (with SteamIDs) and cmd/user logs. Channel ERRORs
-- (e.g. receiveEatBody) still print. For live debugging, an admin can
-- temporarily restore with the server command: /log multiplayer general
-- (this patch only re-asserts at boot/server-start, not periodically).
--
-- REMOVABLE: delete this file to restore stock logging. Nothing depends
-- on it.

if not isServer() then return end

local function applyMute()
    if not DebugType or not LogSeverity or not LogSeverity.Error then return end
    local chan = DebugType.Multiplayer
    if chan and chan.setLogSeverity then
        -- Only raise the floor; never lower a channel already set stricter.
        local cur = chan.getLogSeverity and chan:getLogSeverity() or nil
        if not cur or cur:isLogEnabled(LogSeverity.Warning) then
            chan:setLogSeverity(LogSeverity.Error)
        end
    end
end

-- Apply at load (catches boot-time spam) and re-assert after boot in case the
-- server's log config re-applies severities later in startup.
pcall(applyMute)
if Events then
    if Events.OnGameBoot      then Events.OnGameBoot.Add(function()      pcall(applyMute) end) end
    if Events.OnServerStarted then Events.OnServerStarted.Add(function() pcall(applyMute) end) end
end

print("[Dragonfly] DFPatch_AntiCheatLogNoise: Multiplayer channel raised to Error (anti-cheat verdicts still in user.txt; delete file to restore)")
