-- RPServer - receives client commands and dispatches to RPCore.
-- Server is the authority on zombie removal in MP.
--
-- Commands:
--   forceScan       - run all three bloom scans on demand (legacy)
--   requestSnapshot - reply with a Necro-tab snapshot, paged as SnapshotChunk
--                     commands (one per tick) so bloom-scale snapshots never
--                     leave as a single multi-hundred-KB packet
--   cullById        - cull a single zombie by OnlineID
--   cullIds         - cull a batch of zombies by OnlineID list
--   setThreshold    - live override for sequentialThreshold / stackThreshold /
--                     outfitIdGap / outfitMinCluster / outfitProximity
--
-- Every action also pushes a LogBroadcast into the RFTDDragonfly module so
-- Dragonfly's Console tab gets a live audit line. If Dragonfly isn't
-- installed nothing listens; harmless.

if not isServer() then return end

local MODULE = "RFTDReaper"

RDShared.registerMod(MODULE, "1.2.0")   -- keep in sync with mod.info

-- Staff gate: RDAccess capability model (RFTDCore adoption) - the old
-- four-level access allowlist is retired; any role holding at least one
-- capability is staff, per family policy.
local function privileged(player)
    return RDAccess.hasAnyCapability(player)
end

local function broadcastAudit(action, player, extra)
    local username = player and player.getUsername and player:getUsername() or "?"
    local tail = extra and (" " .. tostring(extra)) or ""
    print(string.format("[Reaper] %s by %s%s", action, username, tail))
    pcall(sendServerCommand, "RFTDDragonfly", "LogBroadcast", {
        source = "Mod:RFTDReaper",
        level  = "audit",
        text   = string.format("%s by %s%s", action, username, tail),
    })
end

local function reply(player, command, args)
    pcall(sendServerCommand, player, MODULE, command, args)
end

-- -------------------------------------------------------------------------
-- Snapshot paging. At bloom scale (thousands of loaded zombies) a snapshot
-- serializes to hundreds of KB; sent as one sendServerCommand it fragments
-- on the wire and camps in the RakNet resend buffer as a single burst.
-- Page it instead: SNAP_CHUNK rows per SnapshotChunk command, one command
-- per tick, reassembled client-side keyed by gen.
-- -------------------------------------------------------------------------

local SNAP_CHUNK = 250
local snapGen    = 0
local snapSends  = {}   -- pending sends, serviced one chunk per tick

local function queueSnapshot(player)
    local snap    = RPCore.snapshot()
    local zombies = snap.zombies or {}
    snapGen = snapGen + 1
    local total  = math.max(1, math.ceil(#zombies / SNAP_CHUNK))
    local chunks = {}
    for ci = 1, total do
        local base  = (ci - 1) * SNAP_CHUNK
        local slice = {}
        for k = 1, SNAP_CHUNK do
            local e = zombies[base + k]
            if not e then break end
            slice[k] = e
        end
        chunks[ci] = { gen = snapGen, seq = ci, total = total, zombies = slice }
    end
    -- Stats ride on the last chunk; the client shows them on assembly.
    chunks[total].stats     = snap.stats
    chunks[total].timestamp = snap.timestamp
    snapSends[#snapSends + 1] = { player = player, chunks = chunks, nextIdx = 1 }
end

local function pumpSnapshotSends()
    local send = snapSends[1]
    if not send then return end
    reply(send.player, "SnapshotChunk", send.chunks[send.nextIdx])
    send.nextIdx = send.nextIdx + 1
    if send.nextIdx > #send.chunks then table.remove(snapSends, 1) end
end
Events.OnTick.Add(pumpSnapshotSends)

local function onClientCommand(module, command, player, args)
    if module ~= MODULE then return end
    local s = SandboxVars.RFTDReaper or {}
    if s.Enabled == false then
        print("[Reaper] command ignored: mod disabled (" .. tostring(command) .. ")")
        return
    end
    args = args or {}

    if command == "forceScan" then
        if s.DebugContextMenu ~= true then
            print("[Reaper] forceScan ignored: DebugContextMenu disabled")
            return
        end
        broadcastAudit("forceScan", player)
        RPCore.forceScan()

    elseif command == "requestSnapshot" then
        if not privileged(player) then
            broadcastAudit("requestSnapshot refused", player, "(no access)")
            return
        end
        queueSnapshot(player)

    elseif command == "cullById" then
        if not privileged(player) then return end
        local id = tonumber(args.id)
        if not id then return end
        -- CullResult fires once the queued cull has actually drained, so
        -- the client's auto-refresh snapshot reflects the removal.
        local queued = RPCore.cullByIds({ id }, function(_, removed)
            reply(player, "CullResult", { requested = 1, removed = removed })
        end)
        broadcastAudit("cullById", player, "id=" .. id .. " queued=" .. queued)

    elseif command == "cullIds" then
        if not privileged(player) then return end
        local ids = args.ids or {}
        local queued = RPCore.cullByIds(ids, function(_, removed)
            reply(player, "CullResult", { requested = #ids, removed = removed })
        end)
        broadcastAudit("cullIds", player, "count=" .. #ids .. " queued=" .. queued)

    elseif command == "setThreshold" then
        if not privileged(player) then return end
        local key   = args.key
        local value = tonumber(args.value)
        if not key or not value then return end
        local allowed = {
            sequentialThreshold = true, stackThreshold = true,
            outfitIdGap = true, outfitMinCluster = true, outfitProximity = true,
        }
        if not allowed[key] then return end
        RPCore.setRuntime(key, value)
        broadcastAudit("setThreshold", player, key .. "=" .. tostring(value))
        reply(player, "ThresholdAck", { key = key, value = value })
    end
end

Events.OnClientCommand.Add(onClientCommand)
