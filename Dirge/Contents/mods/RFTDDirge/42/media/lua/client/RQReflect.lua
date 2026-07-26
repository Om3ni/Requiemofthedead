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
--   MISS    registered special near player, not resolvable in client world
--           (no outline possible -> looks like a normal zombie / nothing)
--   DRIFT   resolvable, but far from lastKnownPos (stale-pos hypothesis:
--           the outline search window is only +/-15 tiles around the cache)
--   RECOVER a MISS ended; logs how long the special was untrackable
--
-- Reading a TRUTH block (the server's answer, diffed here on arrival):
--   status=ok                    client tracks it AND has the object ->
--                                outline should be painting; if the tester
--                                still saw nothing, suspect render/overlay
--   status=TRACKED-NOT-IN-WORLD  registry knows it but the engine hasn't
--                                synced the zombie into this client's world
--                                -> vanilla zombie-sync lag, not Dirge
--   status=UNKNOWN-TO-CLIENT     server tracks a special this client never
--                                registered -> Dirge sync gap, OUR bug
--   GHOST                        client tracks a special near the player
--                                that the server no longer does

RQReflect = RQReflect or {}
require "RQReflectLog"

-- Master switch. Ships ON: the sampler only writes anomalies and dumps are
-- event-driven + cooldown-limited, so a quiet session writes ~nothing.
RQReflect.ENABLED = true

local MARKER_KEY_NAME    = "F9"    -- keep in sync with the Keyboard.KEY_ lookup below
local SAMPLE_TICKS       = 60      -- ~1s between sampler passes
local NEAR_SAMPLE        = 30      -- tiles; farther specials legitimately unresolvable (chunks)
local MISS_STREAK        = 3       -- consecutive sampler misses before MISS fires
local DRIFT_MIN          = 10      -- tiles between cached and actual before DRIFT fires
local DRIFT_RELOG_MS     = 10000   -- per-zombie DRIFT re-log floor
local DUMP_RADIUS        = 10      -- tiles; "who is around me" radius in dumps
local SEEN_CAP           = 24      -- max SEEN lines per dump (horde nights exist)
local DAMAGE_COOLDOWN_MS = 8000
local MANUAL_COOLDOWN_MS = 2000
local AUTOPING_COOLDOWN_MS = 15000

local missStreak     = {}   -- onlineID -> consecutive sampler misses
local driftLoggedAt  = {}   -- onlineID -> last DRIFT log ms
local noPosLogged    = {}   -- onlineID -> true once NOPOS logged
local tickCounter    = 0
local lastDamageDump = 0
local lastManualDump = 0
local lastAutoPing   = 0

local fmt = string.format

local function dist2(x1, y1, x2, y2)
    local dx, dy = x1 - x2, y1 - y2
    return dx * dx + dy * dy
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
        local ok, s = pcall(vehicle.getCurrentSpeedKmHour, vehicle)
        speed = (ok and s) or -1
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
    local okList, zl = pcall(function() return getCell():getZombieList() end)
    if okList and zl then
        for i = 0, zl:size() - 1 do
            local zombie = zl:get(i)
            if zombie then
                local okC, zx, zy, zz = pcall(function()
                    return zombie:getX(), zombie:getY(), zombie:getZ()
                end)
                if okC and dist2(px, py, zx, zy) <= DUMP_RADIUS * DUMP_RADIUS then
                    seen = seen + 1
                    if seen <= SEEN_CAP then
                        local okId, oid = pcall(zombie.getOnlineID, zombie)
                        local reg = (okId and oid) and RQRegistry.getType(oid) or nil
                        local okT, target = pcall(zombie.getTarget, zombie)
                        local okD, dead   = pcall(zombie.isDead, zombie)
                        lines[#lines + 1] = fmt(" SEEN id=%s type=%s dist=%.1f pos=(%.1f,%.1f,%.0f) targetingMe=%s dead=%s",
                            tostring(okId and oid or "?"), reg or "-",
                            math.sqrt(dist2(px, py, zx, zy)), zx, zy, zz,
                            tostring(okT and target == player), tostring(okD and dead))
                    end
                end
            end
        end
        if seen > SEEN_CAP then
            lines[#lines + 1] = fmt(" SEEN ... %.0f more within %.0f tiles (capped)", seen - SEEN_CAP, DUMP_RADIUS)
        end
    else
        lines[#lines + 1] = " SEEN unavailable (getZombieList failed)"
    end

    for oid, zType in pairs(RQRegistry.activeZombies) do
        local lk = RQReconcile and RQReconcile.lastKnownPos[oid]
        if lk and dist2(px, py, lk.x, lk.y) <= NEAR_SAMPLE * NEAR_SAMPLE then
            local zombie = RQCore.findZombieByID(oid, lk.x, lk.y, lk.z)
            local resolved = "no"
            if zombie then
                resolved = fmt("(%.1f,%.1f)", zombie:getX(), zombie:getY())
            end
            lines[#lines + 1] = fmt(" REG id=%s type=%s lastKnown=(%.0f,%.0f,%.0f) dist=%.1f resolved=%s",
                tostring(oid), zType, lk.x, lk.y, lk.z,
                math.sqrt(dist2(px, py, lk.x, lk.y)), resolved)
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
    pcall(function()
        getPlayer():setHaloNote("Dirge marker logged (" .. MARKER_KEY_NAME .. ")", 180, 255, 180, 300)
    end)
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

    for oid, zType in pairs(RQRegistry.activeZombies) do
        local lk = RQReconcile and RQReconcile.lastKnownPos[oid]
        if not lk then
            -- Registered but no cached position: zombieConverted and every
            -- delta row carry coords, so this state should be impossible.
            if not noPosLogged[oid] then
                noPosLogged[oid] = true
                RQReflectLog.write(fmt("NOPOS id=%s type=%s registered with no cached position", tostring(oid), zType))
            end
        elseif dist2(px, py, lk.x, lk.y) <= NEAR_SAMPLE * NEAR_SAMPLE then
            local zombie = RQCore.findZombieByID(oid, lk.x, lk.y, lk.z)
            if not zombie then
                local streak = (missStreak[oid] or 0) + 1
                missStreak[oid] = streak
                if streak == MISS_STREAK then
                    RQReflectLog.write(fmt("MISS id=%s type=%s lastKnown=(%.0f,%.0f,%.0f) player=(%.0f,%.0f) dist=%.1f unresolvable for %.0fs",
                        tostring(oid), zType, lk.x, lk.y, lk.z, px, py,
                        math.sqrt(dist2(px, py, lk.x, lk.y)), MISS_STREAK))
                    if t - lastAutoPing >= AUTOPING_COOLDOWN_MS then
                        lastAutoPing = t
                        dumpLocalView("auto-miss", fmt("missId=%s", tostring(oid)))
                        sendPing("auto-miss")
                    end
                end
            else
                if (missStreak[oid] or 0) >= MISS_STREAK then
                    RQReflectLog.write(fmt("RECOVER id=%s type=%s gap=%.0fs resolved=(%.1f,%.1f)",
                        tostring(oid), zType, missStreak[oid], zombie:getX(), zombie:getY()))
                end
                missStreak[oid] = 0
                local drift = math.sqrt(dist2(zombie:getX(), zombie:getY(), lk.x, lk.y))
                if drift >= DRIFT_MIN and t - (driftLoggedAt[oid] or 0) >= DRIFT_RELOG_MS then
                    driftLoggedAt[oid] = t
                    RQReflectLog.write(fmt("DRIFT id=%s type=%s drift=%.1f cached=(%.0f,%.0f) actual=(%.1f,%.1f) search window is +/-15",
                        tostring(oid), zType, drift, lk.x, lk.y, zombie:getX(), zombie:getY()))
                end
            end
        else
            -- out of sample range; a miss out here is legitimate (unloaded chunks)
            missStreak[oid] = nil
        end
    end

    -- prune bookkeeping for ids no longer registered (collect first, then
    -- delete -- same safe pairs pattern as RQReconcile)
    local stale, n = {}, 0
    for oid in pairs(missStreak) do
        if not RQRegistry.activeZombies[oid] then n = n + 1; stale[n] = oid end
    end
    for oid in pairs(driftLoggedAt) do
        if not RQRegistry.activeZombies[oid] then n = n + 1; stale[n] = oid end
    end
    for oid in pairs(noPosLogged) do
        if not RQRegistry.activeZombies[oid] then n = n + 1; stale[n] = oid end
    end
    for i = 1, n do
        missStreak[stale[i]]    = nil
        driftLoggedAt[stale[i]] = nil
        noPosLogged[stale[i]]   = nil
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
                local resolved = RQCore.findZombieByID(oid, row.x, row.y, row.z) ~= nil
                local status
                if not known then
                    status = "UNKNOWN-TO-CLIENT"; nUnknown = nUnknown + 1
                elseif not resolved then
                    status = "TRACKED-NOT-IN-WORLD"; nNotInWorld = nNotInWorld + 1
                else
                    status = "ok"; nOk = nOk + 1
                end
                lines[#lines + 1] = fmt(" TRUTH id=%s type=%s serverPos=(%.0f,%.0f,%.0f) dist=%.1f rev=%s ageMs=%s known=%s resolved=%s cacheDrift=%.1f status=%s",
                    tostring(oid), tostring(row.zType), row.x or 0, row.y or 0, row.z or 0,
                    tonumber(row.dist) or -1, tostring(row.rev), tostring(row.ageMs),
                    tostring(known), tostring(resolved), drift, status)
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
                lines[#lines + 1] = fmt(" GHOST id=%s type=%s lastKnown=(%.0f,%.0f,%.0f) client tracks it near player, server does not",
                    tostring(oid), zType, lk.x, lk.y, lk.z)
            end
        end
    end

    lines[#lines + 1] = fmt("VERDICT ok=%.0f trackedNotInWorld=%.0f unknownToClient=%.0f ghost=%.0f",
        nOk, nNotInWorld, nUnknown, nGhost)
    RQReflectLog.writeAll(lines)
end)

Events.OnGameStart.Add(function()
    missStreak     = {}
    driftLoggedAt  = {}
    noPosLogged    = {}
    tickCounter    = 0
    lastDamageDump = 0
    lastManualDump = 0
    lastAutoPing   = 0
end)

-- Copyright Project_Omen
