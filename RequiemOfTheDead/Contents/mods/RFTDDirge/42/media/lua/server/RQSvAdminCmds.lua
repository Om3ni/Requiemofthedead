-- SPDX-License-Identifier: GPL-3.0-or-later
-- RQSvAdminCmds - Dirge's operator-driven interventions, and nothing else.
--
-- SPLIT OUT OF RQServer 2026-08-19. These six commands used to live as inline
-- branches inside one 433-line OnClientCommand listener alongside the player
-- and telemetry traffic, which meant the file that owned zombie conversion
-- state also owned every admin verb, and the trust boundary for the whole token
-- was spread across a single anonymous function. They are separable because
-- they share one property nothing else here has: an operator asked for them.
--
-- What did NOT come with them, on purpose: reflectPing, eaterArrived and
-- zombieKilled stay in RQServer because they read and write its own death
-- cache, dedup table and conversion state (svProcessedDeaths, svDeathCache,
-- svPids). Moving those would mean exporting three mutable tables to make a
-- file boundary look tidy, which trades a real invariant for a cosmetic one.
-- The seam is where the coupling actually is.
--
-- THE GATE IS A RUNTIME TIER, NOT A CAPABILITY. Every command here checks
-- RQSvShared.svIsAdminPlayer, which resolves
-- RDAccess.meetsTier(player, SandboxVars.RFTDDirge.ConvertAccess) - a tier the
-- server operator sets. That is why these register with `gate = "handler"`
-- rather than a capability: no fixed capability names the same set of people,
-- and the shipped default (tier 1 = access level "admin") is not the same set
-- as RDNet's `capability = "any"` (any capability-holding role) in either
-- direction. Registering them as "any" would have silently overridden the
-- operator's sandbox choice on a live server.

if not isServer() then return end

require "RDShared"
require "RDNet"
require "RQCommon"      -- RQCommon.MODULE is read at file scope below
require "RQSvShared"    -- the tier gate and the spawn/convert helpers

RQSvAdminCmds = RQSvAdminCmds or {}

-- Hard ceiling on a single admin spawn request. The client is never trusted for
-- a count -- this is clamped server-side. Deliberately far below vanilla
-- ISSpawnHordeUI's 500: these land on a populated cell that is already shedding
-- packets, and a horde drop is the exact burst shape this release exists to fix.
local ADMIN_SPAWN_CAP = 50

-- Admission barrier for deliberate special spawns. The engine creates the
-- zombie synchronously, but does not authorize and ship it to a client until a
-- later NetworkZombiePacker.postupdate. NetworkZombieManager.moveZombie sets
-- ownerPlayer and resets that connection's zombie-send timer
-- (NetworkZombieManager.java:166-173), then postupdate emits the auth list and
-- queues initial zombie data (NetworkZombiePacker.java:118-156).
--
-- Converting in the addZombiesInOutfit callback used to call transmitModData
-- before that pass. ObjectModDataPacket.parse drops the payload when its moving
-- object cannot yet be resolved (ObjectModDataPacket.java:50-56), which is
-- exactly the race observed as "appears after relog". A stable owner is our
-- server-side evidence that the native send path has admitted the zombie; the
-- grace gives that path time to land before Dirge transmits the special state.
-- This is intentionally not described as client receipt -- only a client
-- acknowledgement could prove that, and this first experiment adds no wire
-- traffic.
local SPAWN_ADMISSION_GRACE_MS   = 1000
local SPAWN_ADMISSION_TIMEOUT_MS = 10000
local pendingSpawnAdmissions     = {}

-- Every type an admin may name. Shared by adminConvert and adminSpawnSpecial so
-- the two can't drift; Boss is admin-only and never spawns organically.
local ADMIN_VALID_TYPES = {
    Screamer = true, Juggernaut = true, EMP = true,
    Glutton  = true, Scavenger  = true, Boss = true,
}

-- Coordinates arrive as untrusted wire values and are used as the ORIGIN of a
-- gridsquare sweep - 961 squares for a convert (radius 15), 121 for an inspect.
-- A non-integer origin makes every getGridSquare lookup fractional; a nil makes
-- it 0,0. adminSpawnSpecial and adminScream already did exactly this two
-- functions away, so this is the sibling treatment those two never got rather
-- than a new rule.
local function coord(v)
    return math.floor(tonumber(v) or 0)
end

-- How far from the operator an ID-LESS convert may point, in tiles.
--
-- This bounds one specific shape and nothing else: a COORDINATE-SELECTED
-- convert, where the coordinates alone choose the victim (see hAdminConvert
-- below, which asks RQSvShared.usesCoordinateLane rather than testing the id
-- here). A convert that names a real id has no ambiguity to bound, so the
-- check is deliberately not applied to those.
--
-- Derived, not picked. The id-less path exists for one thing: a zombie the
-- operator right-clicked in their own world, which is on their screen and
-- therefore inside their own chunk map. IsoChunkMap sizes that box between 5
-- and 19 chunks square depending on the client's setting (IsoChunkMap.java:
-- 107-140), so the smallest client anyone can run loads only +/-20 tiles and the
-- largest +/-76. 48 sits above every plausible on-screen right-click and far
-- below "anywhere on the map", which was the actual affordance being handed out:
-- staff tier plus a coordinate pair could convert a zombie in a cell the
-- operator had never visited, with nothing on the wire to distinguish that from
-- a legitimate click.
--
-- Squared, because the comparison is.
local IDLESS_CONVERT_RANGE_SQ = 48 * 48

-- Convert one existing zombie into a named special.
--
-- AN ID THE RESOLVER CANNOT USE is MEANINGFUL and deliberate: nil, 0 and -1
-- all send svFindZombieByOnlineID down its coordinate lane, where it takes the
-- nearest zombie to the given point. That is how the context menu converts
-- something the operator is pointing at but that the client could not resolve
-- an id for (RQAdmin.lua:136 sends `oid or 0`). It also means the coordinates
-- alone can select the victim, which is why they are coerced below rather than
-- trusted AND why the anchor covers every id in that lane, not just zero.
local function hAdminConvert(player, args)
    if not RQSvShared.svIsAdminPlayer(player) then return end

    local onlineID = tonumber(args.onlineID)
    local zType    = args.zType
    if not onlineID or not zType then return end

    if not ADMIN_VALID_TYPES[zType] then return end

    local cfg = RQSvShared.getSvConfig()
    local x = coord(args.x)
    local y = coord(args.y)
    local z = coord(args.z)

    -- ANCHOR EVERY COORDINATE-SELECTED CONVERT TO THE CALLER. When the
    -- resolver takes its coordinate lane the sweep takes the nearest zombie to
    -- (x,y,z) whatever that point is, so the POINT is the selector - and a
    -- point is trivially forged where an online id is not. The rule the
    -- maintainer set for the panel is "it has to be loaded and we can see it";
    -- this is that same rule for the one path with no panel, enforced where
    -- the client cannot lie about it.
    --
    -- ASKS THE RESOLVER rather than testing the id itself, and that is the
    -- correction: this read `onlineID == 0` until 2026-08-25, when the lane
    -- split widened the coordinate lane to nil/0/-1 and left the gate behind.
    -- An id of -1 then reached the sweep with no anchor at all - a staff
    -- caller could convert the nearest zombie to any loaded point on the map.
    -- Found in review the same day. One test, one owner, no drift.
    --
    -- Planar on purpose. A zombie one floor up is still something the operator
    -- is looking at, and z is already pinned exactly by the sweep.
    if RQSvShared.usesCoordinateLane(onlineID) then
        local dx = player:getX() - x
        local dy = player:getY() - y
        if dx * dx + dy * dy > IDLESS_CONVERT_RANGE_SQ then
            RQSvShared.sendToPlayer(player, "adminConvertResult",
                { status = "outOfRange", zType = zType, onlineID = 0 })
            return
        end
    end
    -- With a real id this resolves through RQZombieCache and the coordinates
    -- and radius are ignored - a Boss that wandered past any box still
    -- converts (the old 15-tile sweep missed it). They still matter for the
    -- coordinate lane, where coordinates ARE the selector: 15 tiles of slack
    -- around the point the operator named, inside the 48-tile anchor enforced
    -- above. onlineID rides back on every reply so the client can
    -- retire the right pending-confirm entry (RQAdmin) instead of guessing.
    local obj = RQSvShared.svFindZombieByOnlineID(onlineID, x, y, z, 15)
    if not obj then
        RQSvShared.sendToPlayer(player, "adminConvertResult", { status = "missing", zType = zType, onlineID = onlineID })
        return
    end
    -- typeOf, not a registry read. `svActiveZombies` was RQServer's LOCAL when
    -- these handlers lived there; after the 2026-08-19 split this line read a
    -- global that has never existed and threw on every convert (proven in the
    -- 2026-08-24 Mosaic session - the split shipped without a runtime pass).
    -- typeOf is registry-then-modData, which also refuses a reloaded special
    -- that has not re-registered yet - re-converting one would re-multiply its
    -- health, so the wider refusal is the correct one.
    local existing = RQSvShared.typeOf(obj)
    if existing then
        RQSvShared.sendToPlayer(player, "adminConvertResult", { status = "already", zType = existing, onlineID = onlineID })
        return
    end
    RQServer.svTryConvert(obj, cfg, zType, true)   -- admin placement: spacing bypassed
    if zType == "Boss" then
        RQSvShared.applyBossSprinter(obj)
    end
    RQSvShared.sendToPlayer(player, "adminConvertResult", { status = "ok", zType = zType, onlineID = onlineID })
    return
end

local function finishSpawnAdmission(batch)
    if batch.finished or batch.remaining > 0 then return end
    batch.finished = true

    local notConverted = batch.spawned - batch.converted
    print(string.format(
        "[RQSpawnAdmission] complete by=%s type=%s requested=%d spawned=%d converted=%d notConverted=%d at=(%d,%d,%d)",
        batch.username, batch.zType, batch.requested, batch.spawned,
        batch.converted, notConverted, batch.x, batch.y, batch.z))
    RQDirgeLog.write(batch.zType, "[INFO] adminSpawnSpecial by "
        .. batch.username
        .. " requested=" .. batch.requested
        .. " spawned=" .. batch.spawned
        .. " converted=" .. batch.converted
        .. " notConverted=" .. notConverted
        .. " at (" .. batch.x .. "," .. batch.y .. "," .. batch.z .. ")")

    -- Same reply token and fields as the synchronous path. It is delayed until
    -- the batch has a truthful conversion count; no extra packet is introduced.
    RQSvShared.sendToPlayer(batch.player, "adminSpawnResult", {
        status    = batch.converted > 0 and "ok" or "failed",
        zType     = batch.zType,
        requested = batch.requested,
        spawned   = batch.spawned,
        converted = batch.converted,
    })
end

local function settleSpawnAdmission(entry, converted, reason, now)
    local batch = entry.batch
    batch.remaining = batch.remaining - 1
    if converted then batch.converted = batch.converted + 1 end

    print(string.format(
        "[RQSpawnAdmission] %s id=%s type=%s waitMs=%d ownerSeen=%s",
        reason, tostring(entry.onlineID), batch.zType,
        now - entry.createdAt, tostring(entry.ownerAt ~= nil)))
    finishSpawnAdmission(batch)
end

local function trySpawnAdmission(entry, now)
    local zombie = entry.zombie
    if zombie:isDead() then
        settleSpawnAdmission(entry, false, "refuse-dead", now)
        return true
    end
    if zombie:getOnlineID() ~= entry.onlineID then
        settleSpawnAdmission(entry, false, "refuse-id-changed", now)
        return true
    end
    if now >= entry.deadline then
        settleSpawnAdmission(entry, false, "refuse-timeout", now)
        return true
    end

    local owner = zombie:getOwnerPlayer()
    if not owner then
        -- Ownership can move as relevance changes. Require one owner to remain
        -- present for the whole grace instead of treating a stale observation
        -- as permission to transmit to a different client generation.
        entry.owner   = nil
        entry.ownerAt = nil
        return false
    end
    if entry.owner ~= owner then
        entry.owner   = owner
        entry.ownerAt = now
        return false
    end
    if now - entry.ownerAt < SPAWN_ADMISSION_GRACE_MS then return false end

    -- skipSpacing: this is still the deliberate admin placement requested by
    -- the caller. Only its network admission moved; conversion policy did not.
    local converted = RQServer.svTryConvert(zombie, entry.batch.cfg,
                                             entry.batch.zType, true)
    if converted and entry.batch.zType == "Boss" then
        RQSvShared.applyBossSprinter(zombie)
    end
    settleSpawnAdmission(entry, converted,
        converted and "converted" or "refuse-conversion", now)
    return true
end

local function processSpawnAdmissions()
    if #pendingSpawnAdmissions == 0 then return end
    local now = getTimestampMs()
    for i = #pendingSpawnAdmissions, 1, -1 do
        if trySpawnAdmission(pendingSpawnAdmissions[i], now) then
            pendingSpawnAdmissions[i] = pendingSpawnAdmissions[#pendingSpawnAdmissions]
            pendingSpawnAdmissions[#pendingSpawnAdmissions] = nil
        end
    end
end

-- Spawn N new specials at a point. Count is clamped server-side, always.
local function hAdminSpawnSpecial(player, args)
    if not RQSvShared.svIsAdminPlayer(player) then return end

    local zType = args and args.zType
    if not zType or not ADMIN_VALID_TYPES[zType] then return end

    local x = math.floor(tonumber(args.x) or 0)
    local y = math.floor(tonumber(args.y) or 0)
    local z = math.floor(tonumber(args.z) or 0)

    local count = math.floor(tonumber(args.count) or 1)
    if count < 1 then count = 1 end
    if count > ADMIN_SPAWN_CAP then count = ADMIN_SPAWN_CAP end

    local now = getTimestampMs()
    local batch = {
        player    = player,
        username  = tostring(player and player:getUsername() or "?"),
        zType     = zType,
        requested = count,
        spawned   = 0,
        queued    = 0,
        remaining = 0,
        converted = 0,
        cfg        = RQSvShared.getSvConfig(),
        x = x, y = y, z = z,
    }

    -- The callback now consumes only the ordinary-roll ticket and records the
    -- newborn. It MUST NOT call svTryConvert or transmit modData: the native
    -- zombie packer has not admitted the object to a client yet.
    local spawned = RQSvShared.svDoSpawn(x, y, z, count, function(zed)
        zed:getModData()["RQRolled"] = true
        batch.queued    = batch.queued + 1
        batch.remaining = batch.remaining + 1
        pendingSpawnAdmissions[#pendingSpawnAdmissions + 1] = {
            zombie    = zed,
            onlineID  = zed:getOnlineID(),
            createdAt = now,
            deadline  = now + SPAWN_ADMISSION_TIMEOUT_MS,
            owner     = nil,
            ownerAt   = nil,
            batch     = batch,
        }
    end)

    batch.spawned = spawned or 0
    print(string.format(
        "[RQSpawnAdmission] queued by=%s type=%s requested=%d spawned=%d queued=%d at=(%d,%d,%d)",
        batch.username, zType, count, batch.spawned, batch.queued, x, y, z))
    if batch.remaining == 0 then finishSpawnAdmission(batch) end
    return
end

-- Fire a screamer pulse at a point.
local function hAdminScream(player, args)
    if not RQSvShared.svIsAdminPlayer(player) then return end

    local x = math.floor(tonumber(args and args.x) or 0)
    local y = math.floor(tonumber(args and args.y) or 0)
    local z = math.floor(tonumber(args and args.z) or 0)
    local cfg = RQSvShared.getSvConfig()

    -- Emitter is the admin: the sound should originate from where they are
    -- standing, and it keeps them out of their own nearby-zombie count.
    local spawnedCount = RQSvScreamer.screamAt(player, x, y, z, cfg)

    -- Ring id must not collide with a live screamer's. Every organic id is
    -- "screamer_<onlineID>", so an "admin_" infix can never alias one.
    local displayRadius = math.min(cfg.screamerSoundRadius, 15)
    local ringId = "screamer_admin_" .. tostring(getTimestampMs())
    RQSvShared.broadcast("castStart", RQSvShared.makeCastArgs(
        ringId, x, y, z,
        cfg.screamerCastTime, RQSvShared.COLORS.Screamer, "Screaming...", displayRadius))
    -- An organic screamer retires its own ring from its behaviour tick once
    -- castDue passes (RQSvScreamer.tick). Nothing ticks an admin scream, so
    -- schedule the teardown here or the ring lingers on every client forever.
    RQSvShared.scheduleAction(cfg.screamerCastTime, function()
        RQSvShared.broadcast("castDone", { ringId = ringId })
    end)

    print(string.format("[Dirge] adminScream by %s at (%d,%d,%d) spawned=%d",
        tostring(player and player:getUsername() or "?"), x, y, z, spawnedCount or 0))
    RQSvShared.sendToPlayer(player, "adminScreamResult", {
        status = "ok", x = x, y = y, spawned = spawnedCount or 0,
    })
    return
end

-- Detonate an EMP at a point.
local function hAdminEMP(player, args)
    if not RQSvShared.svIsAdminPlayer(player) then return end

    local x = math.floor(tonumber(args and args.x) or 0)
    local y = math.floor(tonumber(args and args.y) or 0)
    local z = math.floor(tonumber(args and args.z) or 0)
    local cfg = RQSvShared.getSvConfig()

    -- "emp_<x>_<y>" is the form the client's detonation regex matches, so
    -- reusing it here is what makes the blast VFX fire. Cast then detonate,
    -- mirroring the EMP zombie's own death sequence.
    local ringId = "emp_" .. x .. "_" .. y
    RQSvShared.broadcast("castStart", RQSvShared.makeCastArgs(ringId, x, y, z,
        cfg.empCastTime, RQSvShared.COLORS.EMP, "EMP Detonating...", cfg.empRadius))
    RQSvShared.scheduleAction(cfg.empCastTime, function()
        RQSvShared.broadcast("castDone", {
            ringId = ringId, fixedX = x, fixedY = y, fixedZ = z, radius = cfg.empRadius,
        })
        RQSvShared.svApplyEMPBlast(x, y, z, cfg.empRadius, cfg.empBatteryDrain)
    end)

    print(string.format("[Dirge] adminEMP by %s at (%d,%d,%d) radius=%s",
        tostring(player and player:getUsername() or "?"), x, y, z, tostring(cfg.empRadius)))
    RQDirgeLog.write("EMP", "[INFO] adminEMP by "
        .. tostring(player and player:getUsername() or "?")
        .. " at (" .. x .. "," .. y .. "," .. z .. ") radius=" .. tostring(cfg.empRadius))
    RQSvShared.sendToPlayer(player, "adminEMPResult", { status = "ok", x = x, y = y })
    return
end

-- Re-roll the whole special population. The most expensive command in the mod:
-- a full synchronous scan of every loaded zombie. No Dirge client sends it -
-- Reaper's Necro tab does (RPNecroTab.lua:776), behind its own mod check.
local function hAdminReroll(player, args)
    if not RQSvShared.svIsAdminPlayer(player) then return end

    -- Refund every loaded zombie's consumed spawn roll (and any parked
    -- spacing retries), then sweep immediately so the admin sees the
    -- result now rather than on the next interval pass. Verdicts live in
    -- zombie modData now, so the refund happens inline during the sweep
    -- (svRefundSeen) and by construction reaches exactly the zombies the
    -- sweep can re-roll (loaded, near a player). Existing specials are
    -- untouched: the scan skips svActiveZombies, and reloaded RQConverted
    -- zombies just re-adopt. Recent screamer summons stay protected --
    -- svCheckAndMarkSummoned re-marks any zombie still inside a live
    -- summon window. NOTE: the GUARD_RANGE engagement gate still applies,
    -- so zombies currently fighting someone (or near a visible admin)
    -- refund now but re-roll only after they disengage -- expect
    -- "converted" to trail "refunded" when players are in the thick of it.
    -- eachActiveZombie's return value IS the visit count; the no-op callback
    -- just declines the early stop. The registry itself is RQServer's local,
    -- reachable only through RQSvShared's injected reference - the bare
    -- `svActiveZombies` reads that stood here since the 08-19 split were
    -- globals that never existed.
    local before = RQSvShared.eachActiveZombie(function() end)

    -- One call, not an arm/scan/disarm dance against RQServer's internals.
    -- The old inline sequence here assigned GLOBALS named like RQServer's
    -- refund locals, so the latch never armed and every reroll reported
    -- "0 rolls refunded" while refunding nothing. The latch stays private to
    -- RQServer; the seam is a function.
    local refunded, visited = RQServer.svRefundSweep()

    local after = RQSvShared.eachActiveZombie(function() end)

    print(string.format(
        "[Dirge] adminReroll by %s: %d rolls refunded, %d zombies visited, %d new specials (%d active)",
        tostring(player and player:getUsername() or "?"),
        refunded, visited, after - before, after))
    RQSvShared.sendToPlayer(player, "adminRerollResult", {
        refunded  = refunded,
        visited   = visited,
        converted = after - before,
        active    = after,
    })
    return
end

-- Report what the server believes one zombie is. Read-only.
local function hAdminInspect(player, args)
    if not RQSvShared.svIsAdminPlayer(player) then return end

    local onlineID = tonumber(args.onlineID)
    if not onlineID then return end

    local x = coord(args.x)
    local y = coord(args.y)
    local z = coord(args.z)
    -- Id-keyed through RQZombieCache when the id is real; the coordinates and
    -- 5-tile radius only serve the id-0 nearest-at-point lane.
    local obj = RQSvShared.svFindZombieByOnlineID(onlineID, x, y, z, 5)
    if not obj then
        RQSvShared.sendToPlayer(player, "adminInspectResult", {
            onlineID = onlineID,
            status   = "missing",
        })
        return
    end

    -- Registry-then-modData is exactly RQSvShared.typeOf; the hand-rolled pair
    -- this replaces read `svActiveZombies` as a global that never existed here
    -- (RQServer's local, orphaned by the 08-19 split) and threw on every
    -- inspect.
    local zType = RQSvShared.typeOf(obj)
    RQSvShared.sendToPlayer(player, "adminInspectResult", {
        onlineID = onlineID,
        status   = zType and "special" or "normal",
        zType    = zType,
    })
    return
end

-- ---------------------------------------------------------------------------
-- Registration.
--
-- gate = "handler": see the header. The tier check stays inside each handler,
-- where it can read the operator's current sandbox setting; RDNet supplies
-- default-deny on the token and a per-command rate bucket, which is what these
-- commands were missing entirely.
--
-- Rates are per player per second and are set to the shape of the affordance,
-- not to measured volume - the live capture recorded these at under 2/h each
-- across all senders, so any of these numbers is orders of magnitude above
-- honest use. What they bound is a scripted or stuck client.
--
-- adminReroll is the outlier at 1/s and deserves its number said out loud: it
-- runs a full synchronous conversion scan over every loaded zombie with no cap
-- and no cooldown, so it is the most expensive single command in the mod. It is
-- also the only one here with no Dirge sender at all - Reaper's Necro tab sends
-- it (RPNecroTab.lua:776), which is why it cannot simply be deleted.
-- ---------------------------------------------------------------------------

RDNet.register(RQCommon.MODULE, "adminConvert",      { gate = "handler", rate = 10 }, hAdminConvert)
RDNet.register(RQCommon.MODULE, "adminSpawnSpecial", { gate = "handler", rate = 4  }, hAdminSpawnSpecial)
RDNet.register(RQCommon.MODULE, "adminScream",       { gate = "handler", rate = 4  }, hAdminScream)
RDNet.register(RQCommon.MODULE, "adminEMP",          { gate = "handler", rate = 4  }, hAdminEMP)
RDNet.register(RQCommon.MODULE, "adminReroll",       { gate = "handler", rate = 1  }, hAdminReroll)
RDNet.register(RQCommon.MODULE, "adminInspect",      { gate = "handler", rate = 10 }, hAdminInspect)

Events.OnTick.Add(processSpawnAdmissions)

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
