-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFPatch_Turn180Noise.lua - Dragonfly removable log-noise patch
--
-- Silences the vanilla B42 "turning180" log flood. On 42.x the player action
-- graph (media/actiongroups/player/) ships a `turning180` state whose tag
-- ("turning") is NOT in the childTags of its turning-family parents, and there
-- is no matching animation state (media/AnimSets/player/turning180/ is absent).
-- So every player 180-turn the server authoritatively steps produces TWO warns:
--
--   WARN : ActionSystem ... Transition's target state "turning180" not
--          supported by parent: "turning"           (ActionStateContainer
--          .tryInsertChildState - tagsOverlap(parent.childTags, child.tags)
--          fails; see ActionState.canHaveSubState)
--   WARN : Animation    ... AnimState not found: turning180
--          (AnimationSet.GetState - no such state folder, returns an empty one)
--
-- Both are cosmetic: the engine recovers (substate insert is skipped, GetState
-- returns a fresh empty AnimState). It is a vanilla DATA gap, not a mod bug -
-- not cleanly fixable from a mod because actiongroup state folders are resolved
-- as a single dir (ZomboidFileSystem.getMediaFile), so we can't merge a tag fix
-- without shipping/overriding the entire vanilla player actiongroup.
--
-- Fix: raise the log threshold on the two offending channels from Warning to
-- Error. Real errors and exceptions on these channels STILL print (Error >=
-- Error); only Warning/Debug/Trace are dropped. DebugLogStream.getLogSeverity()
-- reads back from the DebugType, so this gates the actual warn() stream.
--
-- TRADE-OFF: this is channel-wide, not message-specific (the engine warn() API
-- has no per-message filter). You lose OTHER Animation/ActionSystem *warnings*
-- too - e.g. a broken animation mod's "AnimState not found" would no longer
-- warn. Acceptable on a production server where these channels are dominated by
-- this vanilla spam; revisit if you start debugging animation/action issues.
--
-- REMOVABLE: delete this file to restore stock logging. Nothing depends on it.
-- Shared file: applies on whichever process loads it (server + client logs).

local MUTED = { "ActionSystem", "Animation" }

-- setLogSeverity/getLogSeverity are field accessors (DebugType:132/136);
-- isLogEnabled is an ordinal compare (LogSeverity:28) that NPEs only on a nil
-- argument, so Warning is nil-checked alongside Error below.
local function applyMute()
    if not DebugType or not LogSeverity or not LogSeverity.Error
        or not LogSeverity.Warning then return end
    for _, name in ipairs(MUTED) do
        local chan = DebugType[name]
        if chan and chan.setLogSeverity then
            -- Only raise the floor; never lower a channel already set stricter.
            local cur = chan.getLogSeverity and chan:getLogSeverity() or nil
            if not cur or cur:isLogEnabled(LogSeverity.Warning) then
                chan:setLogSeverity(LogSeverity.Error)
            end
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

print("[Dragonfly] DFPatch_Turn180Noise: muted vanilla turning180 ActionSystem/Animation warnings (delete file to restore)")

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
