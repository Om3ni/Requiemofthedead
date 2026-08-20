-- SPDX-License-Identifier: GPL-3.0-or-later
-- RQAdmin - admin tools for Dirge
-- Right-click a zombie to identify it or convert it to any special
-- type. Boss is only available through this menu, never spawns naturally.
-- SP: always available. MP: admin only.

RQAdmin = RQAdmin or {}

local ADMIN_TYPES = { "Screamer", "Juggernaut", "EMP", "Glutton", "Scavenger", "Boss" }

-- figures out if the current player should see the admin menu.
-- SP, co-op host, dedicated server, and MP client all handled separately -
-- the old code conflated SP and co-op host via `not isClient()` and worked
-- by accident. MP clients go through the RDAccess tier gate driven by the
-- RFTDDirge.ConvertAccess sandbox option (1 = Admin only, the default;
-- 2 = all staff). This is the UI gate only - the server re-validates every
-- command with the same policy (RQSvShared.svIsAdminPlayer).
local function isAdmin()
    local player = getPlayer()
    if not player then return false end

    -- SP: both flags false
    if not isClient() and not isServer() then return true end

    -- co-op host: owns the session
    if isServer() and isClient() then return true end

    -- dedicated server with no client (shouldn't hit a UI hook, but be safe)
    if isServer() and not isClient() then return false end

    -- MP client: sandbox-chosen tier
    local tier = SandboxVars and SandboxVars.RFTDDirge and SandboxVars.RFTDDirge.ConvertAccess
    return RDAccess.meetsTier(player, tier)
end

-- scans a small area around the click point looking for something
-- to convert. keeps the nearest one so you don't accidentally grab
-- a zombie three tiles away when there's one right next to you.
local function findNearestZombie(x, y, z, range)
    local cell = getCell()
    if not cell then return nil end
    local bestZombie = nil
    local bestDistSq = range * range + 1
    local ix = math.floor(x)
    local iy = math.floor(y)
    local iz = math.floor(z)

    for dx = -range, range do
        for dy = -range, range do
            local sq = cell:getGridSquare(ix + dx, iy + dy, iz)
            if sq then
                local movObjs = sq:getMovingObjects()
                if movObjs then
                    for i = 0, movObjs:size() - 1 do
                        local obj = movObjs:get(i)
                        if obj and instanceof(obj, "IsoZombie") and not obj:isDead() then
                            local ddx = obj:getX() - x
                            local ddy = obj:getY() - y
                            local distSq = ddx * ddx + ddy * ddy
                            if distSq < bestDistSq then
                                bestDistSq = distSq
                                bestZombie = obj
                            end
                        end
                    end
                end
            end
        end
    end
    return bestZombie
end

-- Separate halo text colors from RQConfig.COLORS - the world highlight colors
-- use a=0.3 for translucent overlays which reads dark as halo text.
-- These are lightened versions tuned for readability at full opacity.
local HALO_COLORS = {
    Screamer   = { 200, 120, 255 },  -- light violet
    Juggernaut = { 110, 170, 255 },  -- light blue
    EMP        = { 100, 235, 200 },  -- light teal
    Glutton    = { 110, 245, 130 },  -- light green
    Scavenger  = { 255, 185, 90  },  -- light orange
    Boss       = { 255, 235, 90  },  -- light gold
}

local function showIdentifyResult(message, zType)
    print("[RQAdmin] " .. tostring(message))

    local player = getPlayer()
    if not player or not player.setHaloNote then return end

    local r, g, b = 255, 255, 0
    if zType and HALO_COLORS[zType] then
        r, g, b = HALO_COLORS[zType][1], HALO_COLORS[zType][2], HALO_COLORS[zType][3]
    elseif message == "Dirge: Normal zombie" then
        r, g, b = 220, 220, 220
    else
        r, g, b = 255, 200, 80
    end

    player:setHaloNote(message, r, g, b, 300)
end

-- Conversions the admin has asked for but not yet seen confirmed.
-- onlineID -> { zType, at }. On a congested server BOTH feedback packets (the
-- adminConvertResult unicast and the zombieConverted broadcast) ride the same
-- saturated connection and drop together, which is the "I clicked Convert and
-- nothing happened at all" report. Rather than add retries, resolve locally:
-- RQRegistry is fed by three independent channels (the zombieConverted
-- broadcast, the snapshot delta, and the baseline pull), so whichever one
-- survives confirms the conversion at zero extra wire cost.
local pendingConvert  = {}
local CONVERT_TIMEOUT = 10000   -- ~5 delta passes at the 2s snapshot cadence
local convertTick     = 0

-- does the actual conversion - marks the zombie, boosts HP,
-- sets up type-specific stuff like sprinter for Boss or
-- base health tracking for Glutton/Scavenger
local function convertZombie(zombie, zType)
    if not zombie or zombie:isDead() then return end

    local oid = zombie:getOnlineID()
    if oid == 0 then oid = nil end

    if oid and RQRegistry.isSpecial(oid) then
        showIdentifyResult("Dirge: Already " .. tostring(RQRegistry.getType(oid)))
        return
    end

    -- Always route through the server so svMarkZombie runs and svActiveZombies
    -- gets the entry. The host-direct path bypassed svActiveZombies, breaking
    -- all alive behaviors (buff aura, scream, regen, etc.) for admin-converted
    -- zombies. sendClientCommand works on host too - routes to OnClientCommand.
    sendClientCommand(RQCommon.MODULE, "adminConvert", {
        onlineID = oid or 0,   -- 0 = no valid ID; server falls back to nearest-at-position
        x        = math.floor(zombie:getX()),
        y        = math.floor(zombie:getY()),
        z        = math.floor(zombie:getZ()),
        zType    = zType,
    })

    -- Immediate local ack: the admin must never see literally nothing while the
    -- round trip is in flight. The definitive answer follows from whichever
    -- channel lands first (see pendingConvert above).
    showIdentifyResult("Dirge: Converting to " .. zType .. "...", zType)
    if oid then
        pendingConvert[oid] = { zType = zType, at = getTimestampMs() }
    end
end

-- Resolve outstanding conversions from local registry state. Costs nothing on
-- the wire; it only reads what reconcile already delivered.
local function pollPendingConverts()
    convertTick = convertTick + 1
    if convertTick < 60 then return end   -- ~1s
    convertTick = 0

    local now = getTimestampMs()
    local done, n = {}, 0
    for oid, p in pairs(pendingConvert) do
        local zType = RQRegistry.getType(oid)
        if zType then
            if zType == p.zType then
                showIdentifyResult("Dirge: Converted to " .. zType, zType)
            else
                showIdentifyResult("Dirge: Already " .. zType, zType)
            end
            n = n + 1; done[n] = oid
        elseif now - p.at >= CONVERT_TIMEOUT then
            -- Honest timeout rather than silence. The conversion may well have
            -- applied server-side; what failed is our knowledge of it.
            showIdentifyResult("Dirge: No confirmation in "
                .. math.floor(CONVERT_TIMEOUT / 1000)
                .. "s - zombie may have moved, or sync is lagging")
            n = n + 1; done[n] = oid
        end
    end
    -- collect-then-delete: mutating during pairs() is the pattern RQReconcile
    -- avoids for the same reason.
    for i = 1, n do pendingConvert[done[i]] = nil end
end

Events.OnTick.Add(pollPendingConverts)

local function getZombieSpecialType(zombie)
    if not zombie or zombie:isDead() then return nil end

    local md = zombie:getModData()
    if md and md[RQRegistry.KEY_CONVERTED] and md[RQRegistry.KEY_TYPE] then
        return md[RQRegistry.KEY_TYPE]
    end

    local oid = zombie:getOnlineID()
    if oid and oid ~= 0 then
        return RQRegistry.getType(oid)
    end

    return nil
end

local function identifyZombie(zombie)
    if not zombie or zombie:isDead() then
        showIdentifyResult("Dirge: Zombie not found")
        return
    end

    local oid = zombie:getOnlineID()
    if not oid or oid == 0 then
        local zType = getZombieSpecialType(zombie)
        if zType then
            showIdentifyResult("Dirge: " .. zType, zType)
        else
            showIdentifyResult("Dirge: Normal zombie")
        end
        return
    end

    if isServer() or not isClient() then
        local zType = getZombieSpecialType(zombie)
        if zType then
            showIdentifyResult("Dirge: " .. zType, zType)
        else
            showIdentifyResult("Dirge: Normal zombie")
        end
        return
    end

    sendClientCommand(RQCommon.MODULE, "adminInspect", {
        onlineID = oid,
        x        = math.floor(zombie:getX()),
        y        = math.floor(zombie:getY()),
        z        = math.floor(zombie:getZ()),
    })
end

local function onAdminServerCommand(module, command, args)
    if not RQCommon.acceptsModule(module) then return end

    if command == "adminInspectResult" then
        local status = args and args.status or "missing"
        local zType = args and args.zType or nil
        if status == "special" and zType then
            showIdentifyResult("Dirge: " .. zType, zType)
        elseif status == "normal" then
            showIdentifyResult("Dirge: Normal zombie")
        else
            showIdentifyResult("Dirge: Zombie not found")
        end

    elseif command == "adminConvertResult" then
        local status = args and args.status or "missing"
        local zType  = args and args.zType or "?"
        -- The reply is an accelerator, not a dependency: retire the pending
        -- entry so the 1Hz poller doesn't report the same conversion again.
        local rid = args and tonumber(args.onlineID)
        if rid then pendingConvert[rid] = nil end
        if status == "ok" then
            showIdentifyResult("Dirge: Converted to " .. zType, zType)
        elseif status == "already" then
            showIdentifyResult("Dirge: Already " .. zType, zType)
        elseif status == "outOfRange" then
            -- The server refused an id-less convert aimed away from us. Said
            -- plainly rather than folded into "not found": those are different
            -- facts, and only one of them is worth retrying by walking closer.
            showIdentifyResult("Dirge: Too far to convert - the target must be near you")
        else
            showIdentifyResult("Dirge: Zombie not found - may have moved")
        end

    elseif command == "adminSpawnResult" then
        -- Spawn confirms off the reply count rather than the registry: the
        -- spawned zombie's onlineID isn't known client-side until it arrives, so
        -- there's nothing to pre-register a pending entry against.
        local zType     = args and args.zType or "?"
        local converted = args and args.converted or 0
        local requested = args and args.requested or 0
        if converted > 0 then
            local msg = "Dirge: Spawned " .. converted .. " " .. zType
            if converted < requested then
                msg = msg .. " (of " .. requested .. " - no room for the rest)"
            end
            showIdentifyResult(msg, zType)
        else
            showIdentifyResult("Dirge: Spawn failed - no valid ground near that spot")
        end

    elseif command == "adminScreamResult" then
        showIdentifyResult(string.format("Dirge: Scream called in %d zombies",
            args and args.spawned or 0))

    elseif command == "adminEMPResult" then
        showIdentifyResult("Dirge: EMP detonating")

    elseif command == "adminRerollResult" then
        -- Reply to the Necro-tab "Reroll Dirge" button (server adminReroll):
        -- every loaded zombie's spawn roll was refunded and a conversion
        -- sweep ran synchronously; these are that sweep's results.
        local msg = string.format(
            "Dirge: Reroll done - %d new specials, %d active (%d rolls refunded)",
            args and args.converted or 0,
            args and args.active or 0,
            args and args.refunded or 0)
        showIdentifyResult(msg)
        if DFFeedback then DFFeedback.good(msg) end
    end
end

Events.OnServerCommand.Add(onAdminServerCommand)

-- MP-disruptive actions go through Dragonfly's confirmation popup, which fires
-- straight through when nobody else is online and otherwise names the players
-- who are about to be affected. Dirge only soft-depends on Dragonfly, so fall
-- through to firing directly when it isn't installed.
local function confirmed(label, fn)
    if DFConfirm and DFConfirm.askIfOthersOnline then
        DFConfirm.askIfOthersOnline(label, fn)
    else
        fn()
    end
end

local function spawnSpecial(coords, zType)
    confirmed("Spawn a " .. zType .. " at your location.", function()
        sendClientCommand(RQCommon.MODULE, "adminSpawnSpecial", {
            x = coords.x, y = coords.y, z = coords.z,
            zType = zType, count = 1,
        })
        showIdentifyResult("Dirge: Spawning " .. zType .. "...", zType)
    end)
end

local function fireScream(coords)
    confirmed("Fire a Screamer scream at your location. This calls in zombies.", function()
        sendClientCommand(RQCommon.MODULE, "adminScream", {
            x = coords.x, y = coords.y, z = coords.z,
        })
        -- Fire-and-forget by nature: no ack packet, just say it went. The server
        -- logs the real outcome, and the scream is its own confirmation.
        showIdentifyResult(string.format("Dirge: Scream fired at (%d,%d)", coords.x, coords.y))
    end)
end

local function fireEMP(coords)
    confirmed("Detonate an EMP at your location. This drains nearby electronics.", function()
        sendClientCommand(RQCommon.MODULE, "adminEMP", {
            x = coords.x, y = coords.y, z = coords.z,
        })
        showIdentifyResult(string.format("Dirge: EMP armed at (%d,%d)", coords.x, coords.y))
    end)
end

-- context menu hook - one "Dirge" parent holding the whole admin toolkit.
-- Identify/Convert need a zombie within 3 tiles; Spawn/Scream/EMP act on the
-- clicked square and so are offered even in an empty field. Admin only.
local function onFillWorldObjectContextMenu(playerNum, context, worldObjects)
    if not isAdmin() then return end

    local player = getSpecificPlayer(playerNum)
    if not player then return end

    local wx = player:getX()
    local wy = player:getY()
    local wz = player:getZ()

    if worldObjects and worldObjects[1] then
        local obj = worldObjects[1]
        if obj.getX then
            wx = obj:getX()
            wy = obj:getY()
            wz = obj:getZ()
        end
    end

    local coords = { x = math.floor(wx), y = math.floor(wy), z = math.floor(wz) }
    local zombie = findNearestZombie(wx, wy, wz, 3)

    -- The parent is built unconditionally. It used to live inside `if zombie`,
    -- which meant no menu at all with nothing in range -- that would now hide
    -- Spawn/Scream/EMP, none of which need a zombie.
    local dirgeMenu   = context:getNew(context)
    local dirgeOption = context:addOption("Dirge")
    context:addSubMenu(dirgeOption, dirgeMenu)

    if zombie then
        dirgeMenu:addOption("Identify Zombie", zombie, identifyZombie)

        local zType = getZombieSpecialType(zombie)
        if not zType then
            local convertMenu   = context:getNew(context)
            local convertOption = dirgeMenu:addOption("Convert Zombie")
            context:addSubMenu(convertOption, convertMenu)

            for _, adminType in ipairs(ADMIN_TYPES) do
                convertMenu:addOption(adminType, zombie, convertZombie, adminType)
            end
        end
    end

    local spawnMenu   = context:getNew(context)
    local spawnOption = dirgeMenu:addOption("Spawn Special Zombie")
    context:addSubMenu(spawnOption, spawnMenu)
    for _, adminType in ipairs(ADMIN_TYPES) do
        spawnMenu:addOption(adminType, coords, spawnSpecial, adminType)
    end

    dirgeMenu:addOption("Scream", coords, fireScream)
    dirgeMenu:addOption("EMP", coords, fireEMP)
end

Events.OnFillWorldObjectContextMenu.Add(onFillWorldObjectContextMenu)

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
