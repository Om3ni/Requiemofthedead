-- SPDX-License-Identifier: GPL-3.0-or-later
-- RQReflect - "invisible skittle" reflection trace (client half)
--
-- Captures what THIS client believes about special zombies at the moment
-- something suspicious happens, then asks the server for its authoritative
-- view of the same instant and logs both, diffed by onlineID. Lines land in
-- Zomboid/Lua/Dirge_Reflect_CL.txt (server half: Dirge_Reflect_SV.txt).
--
-- Three triggers write a paired dump:
--   damage    - local player takes any damage (8s cooldown). If an unseen
--               special is the attacker, this is the moment that proves it.
--   manual    - F9. The "it just happened!" button for testers.
--   auto-miss - the 1Hz sampler below caught a registered special near the
--               player that findZombieByID can't resolve for 3s straight.
--
-- The sampler also writes standalone anomaly lines:
--   CACHE-MISS-IN-CELL
--           the object exists in the engine cell but the id cache missed it;
--           reflection repairs the cache immediately from that independent view
--   MISS class=ABSENT-FROM-CELL
--           registered special near player, absent from the engine cell itself
--   RECOVER a MISS ended; logs how long the special was untrackable
--
-- DRIFT IS GONE, retired 2026-08-25, and it is worth saying why rather than
-- leaving a reader to wonder where it went. It reported "resolvable, but far
-- from lastKnownPos", and it was an anomaly only because resolution used to
-- SEARCH from that cached position within +/-15 tiles - so a special that had
-- outrun its own cache silently lost its outline. RQZombieCache resolves by id,
-- so there is no search window and drift costs nothing. Left in place the check
-- would have reported a healthy system as broken, loudly: 974 of the anomaly
-- lines in one archive were DRIFT.
--
-- The sampler was rewritten in the same pass so that a stale cached position
-- can no longer HIDE a real anomaly either - see the resolve-first note there.
--
-- Reading a TRUTH block (the server's answer, diffed here on arrival):
--   status=ok                    client tracks it AND has the object ->
--                                outline should be painting; if the tester
--                                still saw nothing, suspect render/overlay
--   status=CACHE-MISS-IN-CELL     engine cell has the object but Dirge's cache
--                                missed it; repaired locally on this pass
--   status=ABSENT-FROM-CELL       registry knows it but the engine cell does
--                                not contain the zombie -> real sync gap
--   status=CELL-UNAVAILABLE       no client world cell exists yet; no verdict
--   status=UNKNOWN-TO-CLIENT     server tracks a special this client never
--                                registered -> Dirge sync gap, OUR bug
--   STALE-REGISTRY               client tracks a special near the player
--                                that the server no longer does (often removal lag)

RQReflect = RQReflect or {}
require "RQReflectLog"

-- Master switch. Ships ON: the sampler only writes anomalies and dumps are
-- event-driven + cooldown-limited, so a quiet session writes ~nothing.
RQReflect.ENABLED = true

local MARKER_KEY_NAME    = "F9"    -- keep in sync with the Keyboard.KEY_ lookup below
local SAMPLE_TICKS       = 60      -- ~1s between sampler passes
local NEAR_SAMPLE        = 30      -- tiles; farther specials legitimately unresolvable (chunks)
local MISS_STREAK        = 3       -- consecutive sampler misses before MISS fires
local DUMP_RADIUS        = 10      -- tiles; "who is around me" radius in dumps
local SEEN_CAP           = 24      -- max SEEN lines per dump (horde nights exist)
local DAMAGE_COOLDOWN_MS = 8000
local MANUAL_COOLDOWN_MS = 2000
local AUTOPING_COOLDOWN_MS = 15000

local missStreak     = {}   -- onlineID -> consecutive sampler misses
local noPosLogged    = {}   -- onlineID -> true once NOPOS logged
local cacheMissLogged = {}  -- onlineID -> true while cell evidence contradicts resolver
local tickCounter    = 0
local lastDamageDump = 0
local lastManualDump = 0
local lastAutoPing   = 0

local fmt = string.format

local function dist2(x1, y1, x2, y2)
    local dx, dy = x1 - x2, y1 - y2
    return dx * dx + dy * dy
end

-- Independent engine view. RQCore.findZombieByID ultimately reads
-- RQZombieCache, so asking it twice cannot audit the cache. A complete cell-list
-- index can: IsoCell.getZombieList returns every currently realized zombie
-- (IsoCell.java:2339-2340). Built once per sampler/truth pass, never per id.
local function indexClientCell()
    local cell = getCell()
    local list = cell and cell:getZombieList()
    if not list then return nil, nil end
    local byID = {}
    for i = 0, list:size() - 1 do
        local zombie = list:get(i)
        if zombie and not zombie:isDead() then
            local oid = zombie:getOnlineID()
            if oid ~= nil and oid ~= -1 then byID[oid] = zombie end
        end
    end
    return byID, list
end

-- Heal a cache contradiction from the independent cell index. Returning the
-- cell object keeps outlines and diagnostics working on this pass even if a
-- future cache implementation refuses the row. One bounded line per episode.
local function repairCellContradiction(oid, zType, resolved, inCell, context)
    if resolved or not inCell then
        if resolved then cacheMissLogged[oid] = nil end
        return resolved
    end

    local repaired = false
    if RQZombieCache and RQZombieCache.remember then
        repaired = RQZombieCache.remember(inCell) == true
    end
    if not cacheMissLogged[oid] then
        cacheMissLogged[oid] = true
        local stats = RQZombieCache and RQZombieCache.stats or {}
        RQReflectLog.write(fmt(
            "CACHE-MISS-IN-CELL id=%s type=%s context=%s repaired=%s cacheResolves=%s warmed=%s deferred=%s dropped=%s",
            tostring(oid), tostring(zType), tostring(context), tostring(repaired),
            tostring(stats.resolves), tostring(stats.warmed),
            tostring(stats.deferred), tostring(stats.dropped)))
    end
    return inCell
end

-- Ask the server for its authoritative nearby-special rows. The response
-- (reflectTruth) is logged and diffed by the OnServerCommand handler below.
local function sendPing(reason)
    local player = getPlayer()
    if not player then return end
    sendClientCommand(RQCommon.MODULE, "reflectPing", {
        reason   = reason,
        clientTs = getTimestampMs(),
        x        = math.floor(player:getX()),
        y        = math.floor(player:getY()),
        z        = math.floor(player:getZ()),
    })
end

-- Snapshot of everything this client can currently see/knows near the player:
-- header (context: vehicle, our own screen overlays), SEEN lines (every
-- IsoZombie within DUMP_RADIUS, special or not), REG lines (registry entries
-- near the player and whether they resolve to a live object right now).
local function dumpLocalView(reason, detail)
    local player = getPlayer()
    if not player then return end
    local px, py, pz = player:getX(), player:getY(), player:getZ()

    local vehicle = player:getVehicle()
    local speed = 0
    if vehicle then
        speed = vehicle:getCurrentSpeedKmHour() or -1
    end
    -- Our own overlays can hide the world: an active EMP blackout or screamer
    -- darkness at hit time is an answer, not background noise.
    local blind = (RQEMP and RQEMP.isBlindActive and RQEMP.isBlindActive()) or false
    local dazed = (RQScreamer and RQScreamer.isDisoriented and RQScreamer.isDisoriented()) or false

    local lines = {}
    lines[1] = fmt("DUMP reason=%s%s player=(%.1f,%.1f,%.0f) vehicle=%s speed=%.0f empBlind=%s screamerDazed=%s",
        reason, (detail and detail ~= "" and (" " .. detail)) or "",
        px, py, pz, tostring(vehicle ~= nil), speed, tostring(blind), tostring(dazed))

    local seen = 0
    -- LuaManager.getCell returns IsoWorld.currentCell (LuaManager.java:4771-4773),
    -- which is nil before a world exists. Treat that known lifecycle state as a
    -- precondition instead of converting its nil dereference into an exception.
    local cellByID, zl = indexClientCell()
    if zl then
        for i = 0, zl:size() - 1 do
            local zombie = zl:get(i)
            if zombie then
                local zx, zy, zz = zombie:getX(), zombie:getY(), zombie:getZ()
                if dist2(px, py, zx, zy) <= DUMP_RADIUS * DUMP_RADIUS then
                    seen = seen + 1
                    if seen <= SEEN_CAP then
                        local oid = zombie:getOnlineID()
                        local reg = oid and RQRegistry.getType(oid) or nil
                        lines[#lines + 1] = fmt(" SEEN id=%s type=%s dist=%.1f pos=(%.1f,%.1f,%.0f) targetingMe=%s dead=%s",
                            tostring(oid or "?"), reg or "-",
                            math.sqrt(dist2(px, py, zx, zy)), zx, zy, zz,
                            tostring(zombie:getTarget() == player), tostring(zombie:isDead()))
                    end
                end
            end
        end
        if seen > SEEN_CAP then
            lines[#lines + 1] = fmt(" SEEN ... %.0f more within %.0f tiles (capped)", seen - SEEN_CAP, DUMP_RADIUS)
        end
    else
        lines[#lines + 1] = " SEEN unavailable (world cell unavailable)"
    end

    -- Same resolve-first order as the sampler, for the same reason: a stale
    -- cached position must not be able to keep a nearby special OUT of the
    -- dump. Distance is measured from the object when we have one, and only
    -- falls back to the cache when we do not. Both numbers are printed so a
    -- reader can still see the two disagreeing - which is what DRIFT used to
    -- say, said once per dump instead of continuously.
    for oid, zType in pairs(RQRegistry.activeZombies) do
        local resolved = RQCore.findZombieByID(oid)
        local inCell = cellByID and cellByID[oid]
        local zombie = repairCellContradiction(oid, zType, resolved, inCell, "dump")
        local lk = RQReconcile and RQReconcile.lastKnownPos[oid]
        local zx, zy
        if zombie then zx, zy = zombie:getX(), zombie:getY()
        elseif lk then zx, zy = lk.x, lk.y end
        if zx and dist2(px, py, zx, zy) <= NEAR_SAMPLE * NEAR_SAMPLE then
            lines[#lines + 1] = fmt(" REG id=%s type=%s lastKnown=%s dist=%.1f resolved=%s inCell=%s",
                tostring(oid), zType,
                lk and fmt("(%.0f,%.0f,%.0f)", lk.x, lk.y, lk.z) or "none",
                math.sqrt(dist2(px, py, zx, zy)),
                resolved and fmt("(%.1f,%.1f)", zx, zy) or "no",
                tostring(inCell ~= nil))
        end
    end

    RQReflectLog.writeAll(lines)
end

-- expose for RQAdmin / console use ("RQReflect.mark()" from the Lua debugger)
function RQReflect.mark(reason)
    dumpLocalView(reason or "manual", "")
    sendPing(reason or "manual")
end

-- ========================
-- Trigger: local player takes damage
-- ========================

if Events.OnPlayerGetDamage then
    Events.OnPlayerGetDamage.Add(function(character, damageType, damage)
        if not RQReflect.ENABLED or not isClient() then return end
        if character ~= getPlayer() then return end
        local t = getTimestampMs()
        if t - lastDamageDump < DAMAGE_COOLDOWN_MS then return end
        lastDamageDump = t
        dumpLocalView("damage", fmt("dmgType=%s dmg=%.2f", tostring(damageType), tonumber(damage) or 0))
        sendPing("damage")
    end)
else
    print("[RQReflect] Events.OnPlayerGetDamage unavailable; damage trigger disabled (manual key still works)")
end

-- ========================
-- Trigger: manual marker key
-- ========================

Events.OnKeyPressed.Add(function(key)
    if not RQReflect.ENABLED or not isClient() then return end
    if not (Keyboard and Keyboard.KEY_F9) or key ~= Keyboard.KEY_F9 then return end
    local t = getTimestampMs()
    if t - lastManualDump < MANUAL_COOLDOWN_MS then return end
    lastManualDump = t
    RQReflect.mark("manual")
    -- on-screen ack so the tester knows the marker registered
    local marker = getPlayer()
    if marker then
        marker:setHaloNote("Dirge marker logged (" .. MARKER_KEY_NAME .. ")", 180, 255, 180, 300)
    end
end)

-- ========================
-- 1Hz sampler: outline-resolution anomalies
-- ========================
-- Same resolution path RQHighlight uses every render frame; a sampler miss
-- means the outline could not have been painted that second.

Events.OnTick.Add(function()
    if not RQReflect.ENABLED or not isClient() then return end
    tickCounter = tickCounter + 1
    if tickCounter < SAMPLE_TICKS then return end
    tickCounter = 0

    local player = getPlayer()
    if not player then return end
    local px, py = player:getX(), player:getY()
    local t = getTimestampMs()
    local cellByID = indexClientCell()
    -- Without a cell there is no independent engine view and therefore no
    -- evidence of absence. Wait for the lifecycle precondition instead of
    -- turning "cannot inspect" into ABSENT-FROM-CELL.
    if not cellByID then return end

    -- RESOLVE FIRST, THEN DECIDE IF IT IS NEAR. The order is the point.
    --
    -- This used to gate on lastKnownPos and only then resolve, which made the
    -- instrumentation depend on the very cache it was supposed to be auditing:
    -- a special standing next to the player but cached forty tiles away read as
    -- "out of sample range", and the MISS that should have fired never did.
    -- Resolution is a table index now, so asking every registered special is
    -- cheaper than the distance test that used to guard it, and the answer is
    -- authoritative - the object's own coordinates, not a remembered pair.
    --
    -- The cached position is still the fallback for the miss path, and there it
    -- is unavoidable rather than sloppy: when nothing resolves there is no
    -- object left to ask where it is.
    for oid, zType in pairs(RQRegistry.activeZombies) do
        local resolved = RQCore.findZombieByID(oid)
        local inCell = cellByID and cellByID[oid]
        local zombie = repairCellContradiction(oid, zType, resolved, inCell, "sampler")
        if zombie then
            if (missStreak[oid] or 0) >= MISS_STREAK then
                RQReflectLog.write(fmt("RECOVER id=%s type=%s gap=%.0fs resolved=(%.1f,%.1f)",
                    tostring(oid), zType, missStreak[oid], zombie:getX(), zombie:getY()))
            end
            missStreak[oid] = 0
        else
            local lk = RQReconcile and RQReconcile.lastKnownPos[oid]
            if not lk then
                -- Registered but no cached position: zombieConverted and every
                -- delta row carry coords, so this state should be impossible.
                if not noPosLogged[oid] then
                    noPosLogged[oid] = true
                    RQReflectLog.write(fmt("NOPOS id=%s type=%s registered with no cached position", tostring(oid), zType))
                end
            elseif dist2(px, py, lk.x, lk.y) <= NEAR_SAMPLE * NEAR_SAMPLE then
                local streak = (missStreak[oid] or 0) + 1
                missStreak[oid] = streak
                if streak == MISS_STREAK then
                    RQReflectLog.write(fmt("MISS id=%s type=%s class=ABSENT-FROM-CELL lastKnown=(%.0f,%.0f,%.0f) player=(%.0f,%.0f) dist=%.1f absent for %.0fs",
                        tostring(oid), zType, lk.x, lk.y, lk.z, px, py,
                        math.sqrt(dist2(px, py, lk.x, lk.y)), MISS_STREAK))
                    if t - lastAutoPing >= AUTOPING_COOLDOWN_MS then
                        lastAutoPing = t
                        dumpLocalView("auto-miss", fmt("missId=%s", tostring(oid)))
                        sendPing("auto-miss")
                    end
                end
            else
                -- out of sample range; a miss out here is legitimate (unloaded chunks)
                missStreak[oid] = nil
            end
        end
    end

    -- prune bookkeeping for ids no longer registered (collect first, then
    -- delete -- same safe pairs pattern as RQReconcile)
    local stale, n = {}, 0
    for oid in pairs(missStreak) do
        if not RQRegistry.activeZombies[oid] then n = n + 1; stale[n] = oid end
    end
    for oid in pairs(noPosLogged) do
        if not RQRegistry.activeZombies[oid] then n = n + 1; stale[n] = oid end
    end
    for oid in pairs(cacheMissLogged) do
        if not RQRegistry.activeZombies[oid] then n = n + 1; stale[n] = oid end
    end
    for i = 1, n do
        missStreak[stale[i]]  = nil
        noPosLogged[stale[i]] = nil
        cacheMissLogged[stale[i]] = nil
    end
end)

-- ========================
-- Server truth arrives: log it diffed against local state
-- ========================

Events.OnServerCommand.Add(function(module, command, args)
    if not RQCommon.acceptsModule(module) or command ~= "reflectTruth" then return end
    if not RQReflect.ENABLED or not args then return end
    local player = getPlayer()
    if not player then return end
    local t = getTimestampMs()
    local rtt = (args.clientTs and (t - args.clientTs)) or -1

    local lines = {}
    lines[1] = fmt("TRUTH reason=%s serverTime=%s rtt=%.0fms totalActive=%s serverSawMeAt=(%s,%s) posDrift=%s",
        tostring(args.reason), tostring(args.serverTime), rtt,
        tostring(args.totalActive), tostring(args.px), tostring(args.py), tostring(args.posDrift))

    local reported = {}
    local nOk, nNotInWorld, nUnknown, nGhost = 0, 0, 0, 0
    local nCacheMiss, nCellUnavailable = 0, 0
    local cellByID = indexClientCell()

    if args.rows then
        for i = 1, #args.rows do
            local row = args.rows[i]
            local oid = tonumber(row.id)
            if oid then
                reported[oid] = true
                local known = RQRegistry.activeZombies[oid] ~= nil
                local lk    = RQReconcile and RQReconcile.lastKnownPos[oid]
                local drift = -1
                if lk then drift = math.sqrt(dist2(lk.x, lk.y, row.x, row.y)) end
                -- cacheDrift below is client-cache vs SERVER truth, which is a
                -- different question from the retired DRIFT check and still a
                -- real one - it is bounded to one line per row per dump.
                local resolvedZombie = RQCore.findZombieByID(oid)
                local inCell = cellByID and cellByID[oid]
                local zombie = repairCellContradiction(
                    oid, row.zType, resolvedZombie, inCell, "truth")
                local status
                if not known then
                    status = "UNKNOWN-TO-CLIENT"; nUnknown = nUnknown + 1
                elseif not cellByID then
                    status = "CELL-UNAVAILABLE"; nCellUnavailable = nCellUnavailable + 1
                elseif inCell and not resolvedZombie then
                    status = "CACHE-MISS-IN-CELL"; nCacheMiss = nCacheMiss + 1
                elseif not zombie then
                    status = "ABSENT-FROM-CELL"; nNotInWorld = nNotInWorld + 1
                else
                    status = "ok"; nOk = nOk + 1
                end
                lines[#lines + 1] = fmt(" TRUTH id=%s type=%s serverPos=(%.0f,%.0f,%.0f) dist=%.1f rev=%s ageMs=%s known=%s resolved=%s inCell=%s cacheDrift=%.1f status=%s",
                    tostring(oid), tostring(row.zType), row.x or 0, row.y or 0, row.z or 0,
                    tonumber(row.dist) or -1, tostring(row.rev), tostring(row.ageMs),
                    tostring(known), tostring(resolvedZombie ~= nil),
                    tostring(inCell ~= nil), drift, status)
            end
        end
    end

    -- inverse diff: specials this client tracks near the player that the
    -- server did not report (dead/reclaimed server-side, ghost here)
    local px, py = player:getX(), player:getY()
    for oid, zType in pairs(RQRegistry.activeZombies) do
        if not reported[oid] then
            local lk = RQReconcile and RQReconcile.lastKnownPos[oid]
            if lk and dist2(px, py, lk.x, lk.y) <= NEAR_SAMPLE * NEAR_SAMPLE then
                nGhost = nGhost + 1
                lines[#lines + 1] = fmt(" STALE-REGISTRY id=%s type=%s lastKnown=(%.0f,%.0f,%.0f) client tracks it near player, server does not",
                    tostring(oid), zType, lk.x, lk.y, lk.z)
            end
        end
    end

    lines[#lines + 1] = fmt("VERDICT ok=%.0f cacheMissInCell=%.0f absentFromCell=%.0f cellUnavailable=%.0f unknownToClient=%.0f staleRegistry=%.0f",
        nOk, nCacheMiss, nNotInWorld, nCellUnavailable, nUnknown, nGhost)
    RQReflectLog.writeAll(lines)
end)

Events.OnGameStart.Add(function()
    missStreak     = {}
    noPosLogged    = {}
    cacheMissLogged = {}
    tickCounter    = 0
    lastDamageDump = 0
    lastManualDump = 0
    lastAutoPing   = 0
end)

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
