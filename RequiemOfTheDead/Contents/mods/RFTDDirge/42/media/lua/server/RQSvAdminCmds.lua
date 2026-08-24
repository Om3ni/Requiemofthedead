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
-- This bounds one specific shape and nothing else: onlineID == 0, where the
-- coordinates ALONE choose the victim (see hAdminConvert below). Every other
-- caller names an id, and an id-selected convert has no ambiguity to bound - so
-- this check is deliberately not applied to them.
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
-- onlineID == 0 is MEANINGFUL and deliberate: svFindZombieByOnlineID then
-- ignores the id and takes the nearest zombie to the given point, which is how
-- the context menu converts something the operator is pointing at but that the
-- client could not resolve an id for (RQAdmin.lua:134 sends `oid or 0`). It
-- also means the coordinates alone can select the victim, which is precisely
-- why they are coerced below rather than trusted.
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

    -- ANCHOR THE ID-LESS PATH TO THE CALLER. With onlineID == 0 the sweep below
    -- takes the nearest zombie to (x,y,z) whatever that point is, so the point
    -- is the selector - and a point is trivially forged where an online id is
    -- not. The rule the maintainer set for the panel is "it has to be loaded and
    -- we can see it"; this is that same rule for the one path with no panel,
    -- enforced where the client cannot lie about it.
    --
    -- Planar on purpose. A zombie one floor up is still something the operator
    -- is looking at, and z is already pinned exactly by the sweep.
    if onlineID == 0 then
        local dx = player:getX() - x
        local dy = player:getY() - y
        if dx * dx + dy * dy > IDLESS_CONVERT_RANGE_SQ then
            RQSvShared.sendToPlayer(player, "adminConvertResult",
                { status = "outOfRange", zType = zType, onlineID = 0 })
            return
        end
    end
    -- 15-tile radius to match client findZombieByID; zombie may have wandered a bit
    -- onlineID rides back on every reply so the client can retire the right
    -- pending-confirm entry (RQAdmin) instead of guessing.
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

    local cfg = RQSvShared.getSvConfig()
    local converted = 0

    -- Convert AT BIRTH via the spawn callback: the zombie is special before
    -- it is ever tracked or drawn as an ordinary one, so there is no
    -- spawn-then-convert step. Passing our own handler is what makes this
    -- deterministic -- the default (onSummonSpawned) would burn the roll and
    -- hand out a RANDOM type, which is not what the admin asked for.
    local spawned = RQSvShared.svDoSpawn(x, y, z, count, function(zed)
        -- Belt and braces: the conversion scan must never re-roll a
        -- deliberate placement even if svTryConvert somehow declines.
        zed:getModData()["RQRolled"] = true
        -- skipSpacing: a deliberate placement is not subject to the
        -- same-type spacing veto, exactly as adminConvert does.
        if RQServer.svTryConvert(zed, cfg, zType, true) then
            converted = converted + 1
            -- Without this a spawned Boss shambles: setWalkType/bSprinter
            -- are not part of conversion, they're applied per placement.
            if zType == "Boss" then
                RQSvShared.applyBossSprinter(zed)
            end
        end
    end)

    print(string.format(
        "[Dirge] adminSpawnSpecial by %s: %s x%d requested, %d spawned, %d converted at (%d,%d,%d)",
        tostring(player and player:getUsername() or "?"),
        tostring(zType), count, spawned or 0, converted, x, y, z))
    RQDirgeLog.write(zType, "[INFO] adminSpawnSpecial by "
        .. tostring(player and player:getUsername() or "?")
        .. " requested=" .. count .. " spawned=" .. tostring(spawned or 0)
        .. " converted=" .. converted
        .. " at (" .. x .. "," .. y .. "," .. z .. ")")

    RQSvShared.sendToPlayer(player, "adminSpawnResult", {
        status    = converted > 0 and "ok" or "failed",
        zType     = zType,
        requested = count,
        spawned   = spawned or 0,
        converted = converted,
    })
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

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
