-- SPDX-License-Identifier: GPL-3.0-or-later
-- RDStandToReason.lua - repairs vanilla's stale furniture-sitting state on a
-- dedicated server.
--
-- B42.20.3/4 can leave isSittingOnFurniture() true when a player starts a
-- timed action while seated and interrupts it by standing. IsoPlayer.java:
-- 2984-2990 makes that flag server-authoritative for endurance: it applies the
-- sitting multiplier and returns before movement drain. The upstream no-mod
-- dedicated-server reproduction is TIS forum topic 100195; MP QA confirmed it.
--
-- This guard does not infer intent from a client command. It reconciles engine
-- state already accepted by the server. A settled furniture flag is valid only
-- while the player is in PlayerSitOnFurnitureState/PlayerGetUpState, attached
-- to a live furniture object, and still within
-- PlayerSitOnFurnitureState.java:234-235's own 0.8-tile away tolerance.
-- StatePacket.java:155-170 calls processOnEnter (and sets the flag) before
-- NetworkState.java:20-30 applies the queued state, so a short mismatch is a
-- normal entry transition. Anything surviving the grace below is residue.
-- PlayerSitOnFurnitureState.abortSitting() is the engine's public cleanup path
-- (PlayerSitOnFurnitureState.java:165-180), so use it instead of maintaining a
-- second, inevitably drifting copy of the teardown here.
--
-- OnPlayerUpdate does not fire for remote players on a dedicated server (see
-- RDLife.lua). The OnTick scan is allocation-free for settled players. Repair
-- notices contain no player identity and are aggregated to at most one line per
-- minute so repeatedly attempting the exploit cannot create a log flood.

if not isServer() then return end

RDStandToReason = RDStandToReason or {}

local SIT_STATE = PlayerSitOnFurnitureState.instance()
local GETUP_STATE = PlayerGetUpState.instance()
local AWAY_TOLERANCE = 0.8
local STATE_GRACE_MS = 2 * 1000
local NOTICE_INTERVAL_MS = 60 * 1000

-- onlineID -> { player, x, y, z }; the player reference prevents an onlineID
-- reused after reconnect/respawn from inheriting the previous body's anchor.
local anchors = {}
local repairCount = 0
local pendingNotices = 0
local lastNoticeMs = nil

local function notice(reason)
    repairCount = repairCount + 1
    pendingNotices = pendingNotices + 1

    local now = RDShared.nowMs()
    if lastNoticeMs == nil or now - lastNoticeMs >= NOTICE_INTERVAL_MS then
        print(string.format(
            "[RFTDCore] RDStandToReason: repaired %d stale furniture-sitting state(s) "
            .. "since last notice (latest reason=%s; total=%d)",
            pendingNotices, reason, repairCount))
        pendingNotices = 0
        lastNoticeMs = now
    end
end

local function repair(player, id, reason)
    -- Exact vanilla cleanup; direct call by design. There is no recoverable
    -- failure on a valid IsoPlayer (PlayerSitOnFurnitureState.java:165-180).
    SIT_STATE:abortSitting(player)
    anchors[id] = nil
    notice(reason)
end

local function movedAway(player, anchor)
    local planar = math.abs(player:getX() - anchor.x) + math.abs(player:getY() - anchor.y)
    return planar > AWAY_TOLERANCE or math.abs(player:getZ() - anchor.z) > 0
end

local function inspect(player)
    if not player then return end

    local id = player:getOnlineID()
    if player:isDead() or not player:isSittingOnFurniture() then
        anchors[id] = nil
        return
    end

    local current = player:getCurrentState()
    if not current then return end

    local furniture = player:getSitOnFurnitureObject()
    if not furniture or furniture:getObjectIndex() == -1 then
        repair(player, id, "missing-furniture")
        return
    end

    local anchor = anchors[id]
    if not anchor or anchor.player ~= player then
        anchor = {
            player = player,
            x = player:getX(), y = player:getY(), z = player:getZ(),
            stateSeen = false,
        }
        anchors[id] = anchor
    end

    local inSit = player:isCurrentState(SIT_STATE)
    local inGetUp = player:isCurrentState(GETUP_STATE)
    if not inSit and not inGetUp then
        local now = RDShared.nowMs()
        if not anchor.mismatchSince then anchor.mismatchSince = now end
        if anchor.stateSeen and movedAway(player, anchor) then
            repair(player, id, "moved-away")
        elseif now - anchor.mismatchSince >= STATE_GRACE_MS then
            repair(player, id, "state-mismatch")
        end
        return
    end

    if not anchor.stateSeen then
        -- The queued sit state has now landed. Its network position, rather
        -- than the pre-entry position, is the authoritative seated anchor.
        anchor.x, anchor.y, anchor.z = player:getX(), player:getY(), player:getZ()
        anchor.stateSeen = true
    end
    anchor.mismatchSince = nil

    if movedAway(player, anchor) then
        repair(player, id, "moved-away")
    end
end

local function onTick()
    local players = getOnlinePlayers()
    if not players then return end
    for i = 0, players:size() - 1 do inspect(players:get(i)) end
end

Events.OnTick.Add(onTick)

local function prune(player)
    if player then anchors[player:getOnlineID()] = nil end
end
if Events.OnDisconnect then Events.OnDisconnect.Add(prune) end
if Events.OnPlayerDisconnect then Events.OnPlayerDisconnect.Add(prune) end

-- Small read-only surface for the dedicated-server console/debugger and the
-- engine-free regression fixture. The regular signal is the bounded log above.
function RDStandToReason.getRepairCount()
    return repairCount
end

return RDStandToReason

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
