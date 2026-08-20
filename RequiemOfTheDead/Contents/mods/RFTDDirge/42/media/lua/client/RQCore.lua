-- SPDX-License-Identifier: GPL-3.0-or-later
-- RQCore - entry point, loads everything and handles death dispatch
-- All the require() calls are here so load order is explicit.
-- Death event goes through here first (loot drop, type-specific
-- cleanup) before the zombie gets removed from tracking.

RQCore = RQCore or {}

-- Load in dependency order
require "RQDirgeLog"
require "RQConfig"
require "RQRegistry"
require "RQCastBar"
require "RQRing"
require "RQHighlight"
require "RQMoodle"
require "RQScreamer"
require "RQJuggernaut"
require "RQEMP"
require "RQGlutton"
require "RQBoss"
require "RQScavenger"
require "RQReconcile"
require "RQAdmin"
require "RQHealthBar"
require "RQReflect"


local function onZombieDead(zombie)
    if not zombie then return end

    local oid = zombie:getOnlineID()
    local validID = oid and oid ~= 0

    -- Look up type by onlineID first; fall back to modData so local
    -- death handlers (RQEMP.onDead, RQScreamer.onDead, etc.) still
    -- fire even when this client missed the zombieConverted broadcast
    -- (late join, chunk boundary timing, conversion/death race window).
    local zType = validID and RQRegistry.getType(oid) or nil
    if not zType then
        local md = zombie:getModData()
        zType = md and md[RQRegistry.KEY_TYPE]
    end
    if not zType then return end

    RQDirgeLog.write(zType, "[INFO] Special zombie died id=" .. tostring(validID and oid or "modData-fallback")
        .. " source=" .. (validID and "registry" or "modData"))

    -- Forward to server for loot drop + broadcast effects (EMP detonation,
    -- Screamer spawn, etc.). Requires a valid onlineID; if we only have a
    -- modData fallback, the server can't process the death anyway.
    if validID then
        sendClientCommand(RQCommon.MODULE, "zombieKilled", {
            onlineID = tostring(oid),
            x        = math.floor(zombie:getX()),
            y        = math.floor(zombie:getY()),
            z        = math.floor(zombie:getZ()),
            zType    = zType,
        })
    end

    -- Type-specific death cleanup
    if zType == "Screamer" then
        RQScreamer.onDead(zombie)
    elseif zType == "Juggernaut" then
        RQJuggernaut.onDead(zombie)
    elseif zType == "EMP" then
        RQEMP.onDead(zombie)
    elseif zType == "Glutton" then
        RQGlutton.onDead(zombie)
    elseif zType == "Boss" then
        RQBoss.onDead(zombie)
    elseif zType == "Scavenger" then
        RQScavenger.onDead(zombie)
    end

    -- NOW safe to remove from tracking (loot already processed)
    RQHighlight.remove(oid)
    RQRegistry.unregister(oid)
end

Events.OnZombieDead.Add(onZombieDead)


local mpCastBars = {}
local mpCastTrackers = {}

-- Every ring id prefix the server can open a cast under. Used by castClearAll
-- to wipe one zombie's rings without the server having to name each one.
local CAST_PREFIXES = {
    "screamer_", "jugg_", "emp_", "glutton_", "boss_", "boss_emp_", "scav_",
}

-- Tear down one ring id: cancel its bar, drop its tracker, clear the ring and
-- any flash, and clear the EMP inner ring (a no-op when there isn't one).
-- Shared by castDone and castClearAll so the two can't drift.
local function clearCastRing(ringId)
    local barData = mpCastBars[ringId]
    if barData then
        RQCastBar.cancel(barData.barId)
        mpCastBars[ringId] = nil
    end
    mpCastTrackers[ringId] = nil
    RQRing.clear(ringId)
    RQRing.stopFlash(ringId)
    RQRing.clear(ringId .. "_inner")
end

-- Search for living zombie by onlineID near specified coordinates.
-- Expanded to 15 tiles to account for zombie movement between
-- server conversion and client receiving the broadcast.
local function findZombieByID(onlineID, x, y, z)
    local cell = getCell()
    if not cell then return nil end
    local searchID = tonumber(onlineID)
    if not searchID then return nil end
    for dx = -15, 15 do
        for dy = -15, 15 do
            local sq = cell:getGridSquare(x + dx, y + dy, z)
            if sq then
                local movs = sq:getMovingObjects()
                if movs then
                    for i = 0, movs:size() - 1 do
                        local obj = movs:get(i)
                        if obj and instanceof(obj, "IsoZombie") and not obj:isDead()
                           and obj:getOnlineID() == searchID then
                            return obj
                        end
                    end
                end
            end
        end
    end
    return nil
end

-- Expose for RQHighlight, RQJuggernaut, etc.
RQCore.findZombieByID = findZombieByID

-- Distance-falloff world sound. B42's PlayWorldSoundImpl ignores its
-- radius/gain/pitch args entirely (engine-verified: SoundManager just fires
-- the FMOD event at the coords; audible range comes from the event/clip
-- definition), so the falloff is built by hand. Every effect sound already
-- plays client-side from a broadcast, so each client scales volume by its own
-- distance to the emit point: vol = base * (1 - dist/70) -- ~10% quieter per
-- 7 tiles, silent at 70 -- and skips playback entirely past the range. FMOD's
-- own 3D attenuation still stacks on top, so distant sounds are never louder
-- than this curve. Pooled world emitter at raw coords: no grid square lookup,
-- so playback no longer depends on the source chunk being loaded here.
RQCore.SOUND_FALLOFF_RANGE = 70
function RQCore.playFalloffSound(name, x, y, z, baseGain)
    local player = getPlayer()
    if not player then return end
    local dx = player:getX() - x
    local dy = player:getY() - y
    local dist = math.sqrt(dx * dx + dy * dy)
    -- The 0.05 skip is a DISTANCE test, not a gain test: it exists to avoid
    -- spawning an emitter for a sound nobody can hear from here (~66 tiles
    -- out). Testing the post-gain volume instead would make a low
    -- ScreamerVolume read as "too far" at point-blank range and mute the
    -- howl outright, turning the volume slider into a cliff at 5%.
    local falloff = 1.0 - dist / RQCore.SOUND_FALLOFF_RANGE
    if falloff <= 0.05 then return end
    local vol = (baseGain or 1.0) * falloff
    if vol <= 0 then return end   -- volume knob at 0: nothing to play
    -- 42.20.3: getWorld returns IsoWorld.instance (LuaManager.java:4766-4769);
    -- before world init this is a normal absent precondition. Once present,
    -- IsoWorld.java:481-491 always returns a pooled/new emitter, and
    -- FMODSoundEmitter.java:484-496 returns 0 for an unknown sound instead of
    -- throwing; setVolume only walks the emitter's own sound lists (:280-294).
    local world = getWorld()
    if not world then return end
    local emitter = world:getFreeEmitter(x + 0.5, y + 0.5, z or 0)
    local handle  = emitter:playSound(name)
    emitter:setVolume(handle, vol)
end

-- The Screamer howl. Three separate things play this exact clip -- a Screamer
-- casting, the Boss Scream skill, and a Scavenger flipping to rage -- and the
-- volume knob has to move all three together, so they share one entry point
-- rather than three copies of the gain lookup.
function RQCore.playScreamSound(x, y, z)
    RQCore.playFalloffSound("RQScreamerScream", x, y, z, RQConfig.get().screamerVolume)
end

function RQCore.ensureCastFromSnapshot(row, serverTime)
    if not row or not row.castRingId or not row.castDue then return end
    local ringId = row.castRingId
    if mpCastBars[ringId] then return end

    local remaining = row.castDuration or 0
    if serverTime then
        remaining = row.castDue - serverTime
    end
    if remaining <= 0 then return end

    local col = RQConfig.COLORS[row.zType] or { r = 1, g = 1, b = 1, a = 1 }
    local fx  = math.floor(row.x or 0)
    local fy  = math.floor(row.y or 0)
    local fz  = math.floor(row.z or 0)
    local radius = row.castRadius or 0

    if radius > 0 then
        RQRing.show(ringId, fx, fy, fz, radius, col)
        if ringId:sub(1, 4) == "emp_" or ringId:sub(1, 8) == "boss_emp" then
            local innerCol = { r = 1.0, g = 0.4, b = 0.0, a = 0.6 }
            RQRing.show(ringId .. "_inner", fx, fy, fz, radius * 0.5, innerCol)
        end
    end

    local zombieObj = nil
    if row.id then
        zombieObj = findZombieByID(row.id, fx, fy, fz)
    end

    if ringId:sub(1, 9) ~= "screamer_" then
        local castParams = {
            duration = remaining,
            color    = col,
            label    = row.castLabel or "...",
        }
        if zombieObj then
            castParams.zombie = zombieObj
        else
            castParams.fixedX = fx + 0.5
            castParams.fixedY = fy + 0.5
            castParams.fixedZ = fz
        end
        local barId = RQCastBar.create(castParams)
        mpCastBars[ringId] = { barId = barId, col = col }
    end

    if zombieObj and radius > 0 then
        mpCastTrackers[ringId] = {
            zombie = zombieObj,
            radius = radius,
            col    = col,
            lastX  = math.floor(zombieObj:getX()),
            lastY  = math.floor(zombieObj:getY()),
            lastZ  = math.floor(zombieObj:getZ()),
        }
    end
end

local function onServerCommand(module, command, args)
    if not RQCommon.acceptsModule(module) then return end

    if command == "zombieConverted" then
        local onlineID = tonumber(args.onlineID)
        local zType    = args.zType
        if not onlineID or not zType then return end
        -- Register by ID immediately - highlight will resolve the object at render time
        RQRegistry.register(onlineID, zType)
        -- Also update last known position
        if RQReconcile and args.x then
            RQReconcile.lastKnownPos[onlineID] = {
                x = args.x or 0, y = args.y or 0, z = args.z or 0
            }
        end
        RQDirgeLog.write(zType, "[INFO] zombieConverted id=" .. tostring(onlineID)
            .. " pos=(" .. tostring(args.x) .. "," .. tostring(args.y) .. "," .. tostring(args.z) .. ")")

    elseif command == "applyZombieHP" then
        -- PZ MP uses client-authoritative zombie ownership: the client that
        -- owns the zombie sends sync packets ~every 2s and the server applies
        -- their cached HP via setHealth, clobbering anything the server set.
        -- Workaround: server broadcasts the target HP, all clients try to
        -- apply it, and only the owner's write sticks (others get overwritten
        -- by the owner's next sync via the server). End state: HP propagates
        -- through PZ's vanilla zombie sync within ~2-4s.
        local onlineID = tonumber(args.onlineID)
        local targetHP = tonumber(args.targetHP)
        if not onlineID or not targetHP then return end
        local sx = tonumber(args.x) or 0
        local sy = tonumber(args.y) or 0
        local sz = tonumber(args.z) or 0
        local zombie = findZombieByID(onlineID, sx, sy, sz)
        if not zombie or zombie:isDead() then return end
        zombie:setHealth(targetHP)

    elseif command == "castStart" then
        local col    = { r = args.rR or 1, g = args.rG or 1, b = args.rB or 1, a = args.rA or 1 }
        local ringId = args.ringId
        local fx     = math.floor(args.fixedX or 0)
        local fy     = math.floor(args.fixedY or 0)
        local fz     = math.floor(args.fixedZ or 0)
        local isScreamerCast = ringId and ringId:sub(1, 9) == "screamer_"

        local zombieObj = nil
        if args.onlineID then
            local pos = RQReconcile and RQReconcile.lastKnownPos[tonumber(args.onlineID)]
            local sx = pos and pos.x or fx
            local sy = pos and pos.y or fy
            local sz = pos and pos.z or fz
            zombieObj = findZombieByID(args.onlineID, sx, sy, sz)
        end

        -- Show range ring (initial position)
        if args.ringRadius and args.ringRadius > 0 and ringId then
            RQRing.show(ringId, fx, fy, fz, args.ringRadius, col)
            -- EMP: also show inner knockdown ring (inner half radius, orange)
            if ringId:sub(1, 4) == "emp_" or ringId:sub(1, 8) == "boss_emp" then
                local innerCol = (RQConfig and RQConfig.COLORS and RQConfig.COLORS.EMPInner)
                    or { r = 1.0, g = 0.4, b = 0.0, a = 0.6 }
                RQRing.show(ringId .. "_inner", fx, fy, fz,
                    args.ringRadius * 0.5, innerCol)
            end
        end

        local barId = nil
        if not isScreamerCast then
            -- Create cast bar: follow mode if zombie found, otherwise fixed position.
            local castParams = { duration = args.duration or 3000, color = col, label = args.label or "..." }
            if zombieObj then
                castParams.zombie = zombieObj
            else
                castParams.fixedX = args.fixedX
                castParams.fixedY = args.fixedY
                castParams.fixedZ = args.fixedZ
            end
            barId = RQCastBar.create(castParams)
        end

        if ringId then
            if barId then
                mpCastBars[ringId] = { barId = barId, col = col }
            end
            if zombieObj and args.ringRadius and args.ringRadius > 0 then
                mpCastTrackers[ringId] = {
                    zombie = zombieObj,
                    radius = args.ringRadius,
                    col    = col,
                    lastX  = math.floor(zombieObj:getX()),
                    lastY  = math.floor(zombieObj:getY()),
                    lastZ  = math.floor(zombieObj:getZ()),
                }
            end
        end

        -- Screamer castStart: scream begins immediately, so play the sound and
        -- apply the client-side disorientation now instead of at cast end.
        -- Falloff playback (raw coords, works outside loaded chunks): each
        -- client hears it at a volume scaled by its own distance -- fixes the
        -- "screamers in my base with no zombies around" reports.
        if isScreamerCast then
            RQCore.playScreamSound(fx, fy, fz)
            local player = getPlayer()
            if player then
                -- Pass blast position so onCastStart can range-check
                -- even when the zombie isn't in this client's loaded chunks.
                RQScreamer.onCastStart(player, zombieObj, fx, fy)
            end
        end

        -- Boss Scream castStart: same treatment as a Screamer zombie - audible scream
        -- AND the disorientation pipeline (blur, darkness, dazed moodle, panic bump).
        -- Without the onCastStart call the boss just plays a sound and the player
        -- gets no actual screamer effect.
        if args.skill == "Scream" and ringId and ringId:sub(1, 5) == "boss_" then
            RQCore.playScreamSound(fx, fy, fz)
            local player = getPlayer()
            if player then
                RQScreamer.onCastStart(player, nil, fx, fy)
            end
        end

    elseif command == "castDone" then
        local ringId = args.ringId
        if not ringId then return end
        clearCastRing(ringId)

        -- EMP family: play detonation VFX when countdown completes.
        if ringId:sub(1, 4) == "emp_" or ringId:sub(1, 8) == "boss_emp" then
            local bx, by = ringId:match("^emp_(-?%d+)_(-?%d+)$")
            bx = tonumber(args.fixedX) or tonumber(bx)
            by = tonumber(args.fixedY) or tonumber(by)
            if bx and by then
                local cfg = RQConfig.get()
                local bz  = args.fixedZ or 0
                local radius = args.radius or cfg.empRadius
                -- castDone reaches every client, so this is where each client
                -- stumbles the blast zombies IT owns (empDebuff won't do: it
                -- only goes to players caught in the blast, and a client can
                -- own zeds near the blast while standing outside it).
                -- Run the owned-zombie gameplay before presentation; if a
                -- verified VFX/audio contract ever regresses, it should not
                -- suppress the authoritative local stumble work.
                RQEMP.stumbleZombies(bx, by, tonumber(bz) or 0, radius)
                RQEMP.playDetonationVFX(bx, by, bz, radius)
            end
        end


    elseif command == "castClearAll" then
        -- One packet replaces the seven castDone broadcasts the eviction sweep
        -- used to send per zombie. Carries no blast coords ON PURPOSE: the old
        -- sweep's ids were "emp_<oid>" / "boss_emp_<oid>", which never matched
        -- castDone's "^emp_(-?%d+)_(-?%d+)$" detonation regex (the real blast
        -- ring is "emp_<x>_<y>"), so no VFX ever fired from that path. Clearing
        -- without VFX is exactly what it already did.
        local sid = args and args.id
        if not sid then return end
        for i = 1, #CAST_PREFIXES do
            clearCastRing(CAST_PREFIXES[i] .. sid)
        end

    elseif command == "gluttonAnimate" then
        local onlineID = tonumber(args.onlineID)
        local eating   = args.eating
        if not onlineID then return end
        RQDirgeLog.write("Glutton", "[RQEat:Cl] gluttonAnimate id=" .. onlineID .. " eating=" .. tostring(eating) .. " phase=" .. tostring(args.phase))
        local pos = RQReconcile and RQReconcile.lastKnownPos[onlineID]
        local sx = pos and pos.x or (args.x or 0)
        local sy = pos and pos.y or (args.y or 0)
        local sz = pos and pos.z or (args.z or 0)
        local zombie = findZombieByID(onlineID, sx, sy, sz)
        if zombie then
            -- Pathing/AI control is only applied by the owning client. The
            -- durable source of truth is zombie modData; this command is just
            -- a fast hint for clients that already have the zombie loaded.
            if not (isClient() and zombie:isRemoteZombie()) then
                if eating then
                    if args.phase == "eating" then
                        -- server confirmed devour: lock zombie and set the body target NOW.
                        -- do NOT call startEating here - it would reset arrivedSent=false and
                        -- cause a second eaterArrived, letting the server find corpseGone=true.
                        zombie:clearAggroList()
                        zombie:setTarget(nil)
                        zombie:setUseless(true)
                        RQGlutton.confirmEating(onlineID, zombie, args.corpseX, args.corpseY, args.corpseZ)
                    elseif args.corpseX then
                        -- seeking phase: set up pathfinding entry on owning client
                        RQGlutton.startEating(zombie, onlineID, args.corpseX, args.corpseY, args.corpseZ)
                    end
                else
                    RQGlutton.stopEating(onlineID, zombie)
                end
            elseif not eating and zombie.setForceEatingAnimation then
                zombie:setForceEatingAnimation(false)
            end
        end

    elseif command == "empDebuff" then
        -- Health, endurance, and electronics are server-owned. The client only
        -- drives local movement/sensory presentation; mutating inventory here
        -- would race the authoritative drain already committed by RQSvShared.
        local player = getPlayer()
        if player then
            if args.x and args.y then
                local dx = player:getX() - (args.x or 0)
                local dy = player:getY() - (args.y or 0)
                local distSq   = dx * dx + dy * dy
                local radius   = args.radius or RQConfig.get().empRadius
                local radiusSq = radius * radius
                RQEMP.applyKnockback(player, distSq, radiusSq)
                RQEMP.applySensoryEffects(player, distSq, radiusSq)
            end
        end

    elseif command == "scavRageScream" then
        -- Scav rage flip triggers the screamer disorientation pipeline at the
        -- rage epicenter. Reuses RQScreamer.onCastStart so blur/darkness/dazed
        -- moodle/panic all stay in lockstep with the regular screamer behavior;
        -- range check, trait resistance, and lingering timer are all reused for
        -- free. Falloff playback matches the screamer pattern in castStart:
        -- audible outside loaded chunks, but fading with distance.
        local fx = tonumber(args.x) or 0
        local fy = tonumber(args.y) or 0
        local fz = tonumber(args.z) or 0
        RQCore.playScreamSound(fx, fy, fz)
        local player = getPlayer()
        if player then
            RQScreamer.onCastStart(player, nil, fx, fy)
        end

    end
end

Events.OnServerCommand.Add(onServerCommand)

Events.OnRenderTick.Add(function()
    local player = getPlayer()
    if not player then return end

    -- Function-local scratch table: a fresh empty list each tick, no
    -- stale ringId strings carrying over from previous frames.
    local removals = {}
    for ringId, tracker in pairs(mpCastTrackers) do
        local zombie = tracker.zombie
        if zombie then
            if not zombie:isDead() then
                local x = math.floor(zombie:getX())
                local y = math.floor(zombie:getY())
                local z = math.floor(zombie:getZ())
                if x ~= tracker.lastX or y ~= tracker.lastY or z ~= tracker.lastZ then
                    tracker.lastX = x
                    tracker.lastY = y
                    tracker.lastZ = z
                    RQRing.show(ringId, x, y, z, tracker.radius, tracker.col)
                end
            else
                removals[#removals + 1] = ringId
            end
        end
    end
    for i = 1, #removals do
        mpCastTrackers[removals[i]] = nil
    end
end)

-- Clean up MP state on game start
local function onGameStart()
    mpCastBars = {}
    mpCastTrackers = {}
end
Events.OnGameStart.Add(onGameStart)

if getDebug() then
    print("[Dirge] v1.0.0 loaded")
end

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
