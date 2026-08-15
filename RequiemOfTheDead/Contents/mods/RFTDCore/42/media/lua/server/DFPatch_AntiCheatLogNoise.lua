-- SPDX-License-Identifier: GPL-3.0-or-later
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
-- ONE MUTED LINE THIS HEADER DID NOT LIST, found 2026-08-08 while auditing the
-- engine's own Lua checksum: ChecksumPacket.parseServer emits
--
--   DebugType.Multiplayer.warn("user <name> will be kicked in <N>ms because
--                               Lua/script checksums do not match")
--
-- when a connecting client's Lua, script or animation checksum differs from the
-- server's. This patch silences that warning from the debug log and console.
--
-- IT IS STILL RECORDED TWICE, which is why the patch stands rather than growing
-- a carve-out: the same code path calls AntiCheat.log, which writes to
-- LoggerManager "user" (AntiCheat.java:123-126) - the file this header already
-- names as the forensic record - and ServerWorldDatabase.addUserlog stores a
-- persistent Userlog.LuaChecksum row against the account. So the evidence
-- survives in both durable places; only the redundant console copy is lost,
-- which is exactly the bargain the rest of this file makes.
--
-- Recorded here because a reader deciding whether to keep this patch should know
-- a checksum kick is among the things it quietens.
--
-- REMOVABLE: delete this file to restore stock logging. Nothing depends
-- on it.

if not isServer() then return end

-- setLogSeverity/getLogSeverity are field accessors (DebugType:132/136);
-- isLogEnabled is an ordinal compare (LogSeverity:28) that NPEs only on a nil
-- argument, so Warning is nil-checked alongside Error below.
local function applyMute()
    if not DebugType or not LogSeverity or not LogSeverity.Error
        or not LogSeverity.Warning then return end
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
applyMute()
if Events then
    if Events.OnGameBoot      then Events.OnGameBoot.Add(applyMute) end
    if Events.OnServerStarted then Events.OnServerStarted.Add(applyMute) end
end

print("[Dragonfly] DFPatch_AntiCheatLogNoise: Multiplayer channel raised to Error (anti-cheat verdicts still in user.txt; delete file to restore)")

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
