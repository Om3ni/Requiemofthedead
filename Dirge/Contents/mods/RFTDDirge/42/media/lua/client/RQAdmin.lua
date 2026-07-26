-- RQAdmin - admin tools for Dirge
-- Right-click a zombie to identify it or convert it to any special
-- type. Boss is only available through this menu, never spawns naturally.
-- SP: always available. MP: admin only.

RQAdmin = RQAdmin or {}

local ADMIN_TYPES = { "Screamer", "Juggernaut", "EMP", "Glutton", "Scavenger", "Boss" }

-- figures out if the current player should see the admin menu.
-- SP, co-op host, dedicated server, and MP client all handled separately -
-- the old code conflated SP and co-op host via `not isClient()` and worked
-- by accident. MP clients now go through the RDAccess capability model
-- (RFTDCore adoption) instead of the old duplicated access-level allowlist;
-- this is the UI gate only - the server re-validates every command.
local function isAdmin()
    local player = getPlayer()
    if not player then return false end

    -- SP: both flags false
    if not isClient() and not isServer() then return true end

    -- co-op host: owns the session
    if isServer() and isClient() then return true end

    -- dedicated server with no client (shouldn't hit a UI hook, but be safe)
    if isServer() and not isClient() then return false end

    -- MP client: any capability at all = staff
    return RDAccess.hasAnyCapability(player)
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

-- Separate halo text colors from RQConfig.COLORS — the world highlight colors
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

-- does the actual conversion - marks the zombie, boosts HP,
-- sets up type-specific stuff like sprinter for Boss or
-- base health tracking for Glutton/Scavenger
local function convertZombie(zombie, zType)
    if not zombie or zombie:isDead() then return end

    local ok2, oid = pcall(zombie.getOnlineID, zombie)
    if not ok2 or not oid or oid == 0 then oid = nil end

    if oid and RQRegistry.isSpecial(oid) then
        showIdentifyResult("Dirge: Already " .. tostring(RQRegistry.getType(oid)))
        return
    end

    -- Always route through the server so svMarkZombie runs and svActiveZombies
    -- gets the entry. The host-direct path bypassed svActiveZombies, breaking
    -- all alive behaviors (buff aura, scream, regen, etc.) for admin-converted
    -- zombies. sendClientCommand works on host too — routes to OnClientCommand.
    sendClientCommand(RQCommon.MODULE, "adminConvert", {
        onlineID = oid or 0,   -- 0 = no valid ID; server falls back to nearest-at-position
        x        = math.floor(zombie:getX()),
        y        = math.floor(zombie:getY()),
        z        = math.floor(zombie:getZ()),
        zType    = zType,
    })
end

local function getZombieSpecialType(zombie)
    if not zombie or zombie:isDead() then return nil end

    local md = zombie:getModData()
    if md and md[RQRegistry.KEY_CONVERTED] and md[RQRegistry.KEY_TYPE] then
        return md[RQRegistry.KEY_TYPE]
    end

    local ok, oid = pcall(zombie.getOnlineID, zombie)
    if ok and oid and oid ~= 0 then
        return RQRegistry.getType(oid)
    end

    return nil
end

local function identifyZombie(zombie)
    if not zombie or zombie:isDead() then
        showIdentifyResult("Dirge: Zombie not found")
        return
    end

    local ok, oid = pcall(zombie.getOnlineID, zombie)
    if not ok or not oid or oid == 0 then
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
        if status == "ok" then
            showIdentifyResult("Dirge: Converted to " .. zType, zType)
        elseif status == "already" then
            showIdentifyResult("Dirge: Already " .. zType, zType)
        else
            showIdentifyResult("Dirge: Zombie not found - may have moved")
        end

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

-- context menu hook - if a zombie is within 3 tiles of the click,
-- offer Identify and (if not already special) the Convert submenu.
-- Admin only.
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

    local zombie = findNearestZombie(wx, wy, wz, 3)

    if zombie then
        context:addOption("Dirge - Identify Zombie", zombie, identifyZombie)

        local zType = getZombieSpecialType(zombie)
        if not zType then
            local rqMenu = context:getNew(context)
            local rqOption = context:addOption("Dirge - Convert Zombie")
            context:addSubMenu(rqOption, rqMenu)

            for _, adminType in ipairs(ADMIN_TYPES) do
                local label = "Convert to " .. adminType
                rqMenu:addOption(label, zombie, convertZombie, adminType)
            end
        end
    end
end

Events.OnFillWorldObjectContextMenu.Add(onFillWorldObjectContextMenu)

-- Copyright Project_Omen
