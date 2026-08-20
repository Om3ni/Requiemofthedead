-- SPDX-License-Identifier: GPL-3.0-or-later
-- RCDismantleAuthority - one-use server permits and authoritative commit.
--
-- A permit proves only that this authenticated player asked to dismantle this
-- live vehicle while its persistent gates passed. Build 42's NetTimedAction
-- reconstructs RCDismantleAction on the server, calculates its adjusted
-- duration there, waits on the server clock, then invokes complete() server-side
-- (NetTimedAction.java:58-101, 127-135; ActionManager.java:70-108).
-- Completion consumes the permit, repeats every rule plus distance and equipped
-- tool state, and only then removes. At most four queued permits per username
-- bound retained state without invalidating legitimate sequential actions.

if not isServer() then return end

require "RDShared"
require "RCAudit"
require "RCRegistry"
require "RCDismantleRules"
require "RCDismantleYield"

RCDismantleAuthority = RCDismantleAuthority or {}

-- Final validation makes a permit harmless while the player is away. Thirty
-- minutes accommodates the sandbox's 1000% duration plus vanilla moodle,
-- injury, and temperature multipliers. The per-player cap still bounds state.
local TTL_MS = 1800000
local MAX_DISTANCE_SQ = 16 -- closest point on vehicle polygon, same Z level
local MAX_PERMITS = 4
local active = {}
local sequence = 0

local REASON_KEY = {
    disabled           = "IGUI_RC_DismUnavailable",
    ["staff-only"]     = "IGUI_RC_DismUnavailable",
    gone               = "IGUI_RC_DismGone",
    ["claim-self"]     = "IGUI_RC_DismReleaseFirst",
    ["claim-other"]    = "IGUI_RC_DismClaimed",
    zone               = "IGUI_RC_DismZoneBlocked",
    engine             = "IGUI_RC_EngineTooGood",
    occupied           = "IGUI_RC_DismOccupied",
    mask               = "IGUI_RC_DismNoMask",
    torch              = "IGUI_RC_DismNoTorch",
    ["torch-equipped"] = "IGUI_RC_DismNoTorch",
    distance           = "IGUI_RC_DismTooFar",
    expired            = "IGUI_RC_DismExpired",
    ticket             = "IGUI_RC_DismExpired",
    ["vehicle-id"]    = "IGUI_RC_DismGone",
    ["remove-failed"] = "IGUI_RC_DismRemoveFailed",
    rate               = "IGUI_RC_DismBusy",
}

local function username(player)
    return player and player.getUsername and player:getUsername() or nil
end

local function vehicleId(value)
    if type(value) ~= "number" or value ~= math.floor(value) then return nil end
    -- LuaManager.getVehicleById accepts int then casts to the engine's short id
    -- (LuaManager.java:8209-8210). Refuse values that could alias in that cast.
    if value < -32768 or value > 32767 then return nil end
    return value
end

local function reply(ok, stage, reason, fields)
    fields = fields or {}
    fields.ok = ok == true
    fields.stage = stage
    fields.reason = reason
    return fields
end

local function pruneExpired(bucket, now)
    for i = #bucket, 1, -1 do
        if now > bucket[i].expiresAt then table.remove(bucket, i) end
    end
end

function RCDismantleAuthority.reasonKey(reason)
    return REASON_KEY[reason] or "IGUI_RC_DismUnavailable"
end

function RCDismantleAuthority.auditRefusal(player, result)
    -- RCAudit contains its own independent Core/legacy I/O boundaries; this
    -- owned record cannot throw on the structured fields supplied here.
    RCAudit.log("DISMANTLE-DENY", player, {
        stage = result and result.stage,
        reason = result and result.reason,
        vehicleId = result and result.vehicleId,
        failurePhase = result and result.failurePhase,
        failure = result and result.failure,
        authority = "server-timed-action",
    })
end

function RCDismantleAuthority.begin(player, args)
    local name = username(player)
    if not name then return reply(false, "begin", "identity") end

    local id = vehicleId(args and args.vehicleId)
    if not id then return reply(false, "begin", "vehicle-id") end
    local vehicle = getVehicleById(id)
    if not vehicle then return reply(false, "begin", "gone", { vehicleId = id }) end

    local reason = RCDismantleRules.check(vehicle, player)
    if reason then return reply(false, "begin", reason, { vehicleId = id }) end

    local now = RDShared.nowMs()
    sequence = sequence + 1
    local ticket = tostring(now) .. "-" .. tostring(sequence)
    local eternal = args.eternal == true and RCShared.isAdmin(player)
    local bucket = active[name] or {}
    pruneExpired(bucket, now)
    if #bucket >= MAX_PERMITS then table.remove(bucket, 1) end
    bucket[#bucket + 1] = {
        ticket = ticket,
        vehicle = vehicle,
        vehicleId = id,
        expiresAt = now + TTL_MS,
        eternal = eternal,
    }
    active[name] = bucket
    return reply(true, "begin", nil, {
        ticket = ticket, vehicleId = id, expiresAt = now + TTL_MS,
    })
end

function RCDismantleAuthority.complete(player, args)
    local name = username(player)
    if not name then return reply(false, "complete", "identity") end
    local ticket = args and args.ticket
    if type(ticket) ~= "string" or ticket == "" then
        return reply(false, "complete", "ticket")
    end

    local bucket = active[name]
    local permit, permitIndex
    if bucket then
        for i, candidate in ipairs(bucket) do
            if candidate.ticket == ticket then
                permit, permitIndex = candidate, i
                break
            end
        end
    end
    if not permit then
        return reply(false, "complete", "ticket")
    end
    -- Exact tickets are one-shot even when final validation refuses them.
    table.remove(bucket, permitIndex)
    if #bucket == 0 then active[name] = nil end

    if RDShared.nowMs() > permit.expiresAt then
        return reply(false, "complete", "expired", { vehicleId = permit.vehicleId })
    end

    local actionVehicle = args and args.vehicle
    local vehicle = getVehicleById(permit.vehicleId)
    if not actionVehicle or actionVehicle ~= permit.vehicle
        or not vehicle or vehicle ~= permit.vehicle or vehicle:isRemovedFromWorld() then
        return reply(false, "complete", "gone", { vehicleId = permit.vehicleId })
    end

    local reason, state = RCDismantleRules.check(vehicle, player)
    if reason then
        return reply(false, "complete", reason, { vehicleId = permit.vehicleId })
    end

    -- IsoMovingObject.DistToSquared uses the closest point on a vehicle's
    -- polygon, not its center (IsoMovingObject.java:602-626). Four tiles plus
    -- same-Z tolerates network interpolation while requiring field presence.
    if player:getVehicle() ~= nil or player:getZi() ~= vehicle:getZi()
        or player:DistToSquared(vehicle) > MAX_DISTANCE_SQ then
        return reply(false, "complete", "distance", { vehicleId = permit.vehicleId })
    end

    -- The timed action requires the torch in primary hand throughout. Server
    -- inventory state is authoritative at commit, not the permit's old item.
    local torch = RCDismantleRules.primaryTorch(player)
    if not torch then
        return reply(false, "complete", "torch-equipped", { vehicleId = permit.vehicleId })
    end

    -- Snapshot server-owned evidence before removal destroys world placement.
    local owner = RCClaim.isClaimed(vehicle) and RCClaim.getOwner(vehicle) or nil
    local claimId = owner and RCClaim.getClaimId(vehicle) or nil
    local scriptName = vehicle:getScriptName()
    local wreck = state.wreck == true
    local x, y, z = math.floor(vehicle:getX()), math.floor(vehicle:getY()), math.floor(vehicle:getZ())

    local committed, yield = RCDismantleYield.commit(
        vehicle, player, torch, permit.eternal)
    if not committed then
        return reply(false, "complete", "remove-failed", {
            vehicleId = permit.vehicleId,
            failurePhase = yield and yield.phase,
            failure = yield and yield.error,
        })
    end

    local claimMutation = "none"
    if owner and claimId then
        RCRegistry.remove(owner, claimId)
        claimMutation = "pruned"
    end

    local tokenMutation = "none"
    local tokenFailure
    if not wreck then
        if type(scriptName) ~= "string" or scriptName == "" then
            tokenMutation = "withheld-unverified"
            tokenFailure = "vehicle-script-unavailable"
        else
            -- RCShared mirrors vanilla TowMenu's script-name classification.
            -- A known non-trailer BaseVehicle is eligible for the vehicle pool.
            local kind = RCShared.isTrailer(vehicle) and "trailer" or "vehicle"
            local tokenCount, reason = RCRegistry.addToken(kind)
            if tokenCount then
                tokenMutation = "minted-" .. kind
            else
                tokenMutation = "withheld-unverified"
                tokenFailure = reason or "token-registry-unavailable"
            end
        end
    end

    return reply(true, "complete", nil, {
        vehicleId = permit.vehicleId,
        vehicle = scriptName,
        wreck = wreck,
        x = x, y = y, z = z,
        engine = state.engine,
        owner = owner, claimId = claimId,
        authority = "server-transaction",
        claimMutation = claimMutation,
        tokenMutation = tokenMutation,
        tokenFailure = tokenFailure,
        cheat = permit.eternal and "eternal-torch" or nil,
        dumped = yield.dumped,
        xp = yield.xp,
        rewardFailure = yield.scrapError,
    })
end

-- Called only by RCDismantleAction.complete on the server after ActionManager's
-- server-clock duration has elapsed. Returning false rejects the engine action;
-- returning true lets it send Done to the client.
function RCDismantleAuthority.finish(player, ticket, actionVehicle)
    local result = RCDismantleAuthority.complete(player, {
        ticket = ticket, vehicle = actionVehicle,
    })
    if not result.ok then
        if player and sendServerCommand then
            sendServerCommand(player, RCShared.MODULE, "Notify", {
                key = RCDismantleAuthority.reasonKey(result.reason), error = true,
            })
        end
        RCDismantleAuthority.auditRefusal(player, result)
        return false
    end
    RCAudit.log("DISMANTLE", player, result)
    return true
end

function RCDismantleAuthority.forget(playerOrName)
    local name
    if type(playerOrName) == "string" then name = playerOrName
    else name = username(playerOrName) end
    if name then active[name] = nil end
end

if Events.OnDisconnect then Events.OnDisconnect.Add(RCDismantleAuthority.forget) end
if Events.OnPlayerDisconnect then Events.OnPlayerDisconnect.Add(RCDismantleAuthority.forget) end

return RCDismantleAuthority

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
