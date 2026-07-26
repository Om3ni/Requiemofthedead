-- RQJuggernaut - client render only
-- All buff behavior runs server-side (svJuggernautTick).
-- Client keeps: ring follow, proximity-based buff highlight,
-- and aura weapon damage multiplier.

RQJuggernaut = RQJuggernaut or {}

-- Ring color for the jugg's ground marker. Full alpha so it reads
-- clearly against the outline highlight (which uses a=0.3).
-- Ring and buffed normals both pull from COLORS so they stay in lockstep with the outline highlight.
local JUGG_RING_COLOR = RQConfig.COLORS.Juggernaut
local BUFF_COLOR      = JUGG_RING_COLOR

-- ========================
-- Aura weapon multiplier
-- ========================
-- While inside any Juggernaut's aura the player's weapon damage is
-- scaled by juggernautAuraMultiplier (0.01-1.0). The boolean flips
-- automatically each render tick so cleanup is self-contained:
-- Jugg dies → no longer found in range → boolean flips → weapon restored.
--
-- Original values are stored in the weapon item's own modData (RQOrigMin/Max).
-- This prevents stacking (applyAura is a no-op if tag already present) and
-- allows releaseAura to find the weapon anywhere in inventory, not just equipped.

local jugPresent = false

local function applyAura(player, mult)
    local weapon = player:getPrimaryHandItem()
    if not weapon or not weapon.setMinDamage then return end
    local wmd = weapon:getModData()
    if wmd["RQOrigMin"] then return end  -- already tagged; don't stack
    local baseMin = weapon:getMinDamage()
    local baseMax = weapon:getMaxDamage()
    wmd["RQOrigMin"] = baseMin
    wmd["RQOrigMax"] = baseMax
    weapon:setMinDamage(baseMin * mult)
    weapon:setMaxDamage(baseMax * mult)
    RQDirgeLog.write("Juggernaut", "[INFO] applyAura mult=" .. string.format("%.2f", mult)
        .. " dmg " .. string.format("%.2f", baseMin) .. "-" .. string.format("%.2f", baseMax)
        .. " -> " .. string.format("%.2f", baseMin * mult) .. "-" .. string.format("%.2f", baseMax * mult))
end

-- Scans the full inventory for any weapon tagged by applyAura and restores it.
-- Covers the case where the player holsters or bags the weapon during the aura.
local function releaseAura(player)
    local inv = player:getInventory()
    if not inv then return end
    local items = inv:getItems()
    if not items then return end
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if item and item.setMinDamage and item.getModData then
            local imd = item:getModData()
            if imd["RQOrigMin"] then
                item:setMinDamage(imd["RQOrigMin"])
                item:setMaxDamage(imd["RQOrigMax"])
                RQDirgeLog.write("Juggernaut", "[INFO] releaseAura restored weapon"
                    .. " dmg " .. string.format("%.2f", imd["RQOrigMin"])
                    .. "-" .. string.format("%.2f", imd["RQOrigMax"]))
                imd["RQOrigMin"] = nil
                imd["RQOrigMax"] = nil
            end
        end
    end
end

-- When the player swaps weapons mid-aura, nerf the new one.
-- applyAura's tag-check makes this safe to call even if weapon didn't change.
Events.OnClothingUpdated.Add(function(character)
    local player = getPlayer()
    if character ~= player then return end
    if not jugPresent then return end
    local cfg = RQConfig.get()
    if cfg.juggernautAuraMultiplier >= 1.0 then return end
    applyAura(player, cfg.juggernautAuraMultiplier)
end)

Events.OnRenderTick.Add(function()
    local player = getPlayer()
    if not player then return end
    local playerNum = player:getPlayerNum()
    local cfg = RQConfig.get()
    local cell = getCell()
    local radius = cfg.juggernautBuffRadius
    local rSq    = radius * radius
    local px     = player:getX()
    local py     = player:getY()

    local inRange = false

    for onlineID, zType in pairs(RQRegistry.activeZombies) do
        if zType == "Juggernaut" then
            local pos = RQReconcile.lastKnownPos[onlineID]
            local lx = pos and pos.x or 0
            local ly = pos and pos.y or 0
            local lz = pos and pos.z or 0
            local jugg = RQCore.findZombieByID(onlineID, lx, ly, lz)
            if jugg then
                local ok, dead = pcall(jugg.isDead, jugg)
                if ok and not dead then
                    local jx = math.floor(jugg:getX())
                    local jy = math.floor(jugg:getY())
                    local jz = math.floor(jugg:getZ())
                    RQRing.update("jugg_" .. onlineID, jx, jy, jz, radius, JUGG_RING_COLOR)

                    -- Check if this player is inside this Jugg's aura
                    local ddx = px - jx
                    local ddy = py - jy
                    if ddx*ddx + ddy*ddy <= rSq then
                        inRange = true
                    end

                    -- Proximity-based buff highlight: any normal zombie within
                    -- buffRadius of this jugg is considered buffed (cosmetic only).
                    -- Yields to RQBoss.bossBuffPainted - if a boss is also nearby,
                    -- the boss color wins on the overlap.
                    if cell then
                        local bossPainted = RQBoss and RQBoss.bossBuffPainted or {}
                        for dx = -radius, radius do
                            for dy = -radius, radius do
                                if dx*dx + dy*dy <= rSq then
                                    local sq = cell:getGridSquare(jx + dx, jy + dy, jz)
                                    if sq then
                                        local movs = sq:getMovingObjects()
                                        if movs then
                                            for i = 0, movs:size() - 1 do
                                                local obj = movs:get(i)
                                                if obj and instanceof(obj, "IsoZombie")
                                                   and not obj:isDead()
                                                   and obj ~= jugg
                                                   and not bossPainted[obj]
                                                then
                                                    local ooid = obj:getOnlineID()
                                                    if not RQRegistry.isSpecial(ooid) then
                                                        pcall(obj.setOutlineHighlight, obj, playerNum, true)
                                                        pcall(obj.setOutlineHighlightCol, obj, playerNum,
                                                            BUFF_COLOR.r, BUFF_COLOR.g, BUFF_COLOR.b, BUFF_COLOR.a)
                                                    end
                                                end
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- Flip the boolean and modify/restore weapon only on state change.
    -- No-op when multiplier is 1.0 (feature disabled).
    -- Boss buff aura also debuffs weapons at the same multiplier - we OR Boss's
    -- range flag into our own so the weapon stays nerfed as long as the player
    -- is in EITHER aura, and only restores when they leave both. Boss publishes
    -- its flag earlier in the same frame (its render tick runs before ours).
    local mult = cfg.juggernautAuraMultiplier
    local bossInRange = (RQBoss      and RQBoss.playerInAura)      or false
    local scavInRange = (RQScavenger and RQScavenger.playerInAura) or false
    local anyInRange  = inRange or bossInRange or scavInRange
    if mult < 1.0 then
        if anyInRange and not jugPresent then
            jugPresent = true
            RQDirgeLog.write("Juggernaut", "[INFO] player ENTERED debuff aura mult=" .. string.format("%.2f", mult)
                .. " sources=" .. (inRange and "jugg" or "")
                .. (bossInRange and ((inRange and "+" or "") .. "boss") or "")
                .. (scavInRange and (((inRange or bossInRange) and "+" or "") .. "scav") or ""))
            applyAura(player, mult)
        elseif not anyInRange and jugPresent then
            jugPresent = false
            RQDirgeLog.write("Juggernaut", "[INFO] player EXITED debuff aura")
            releaseAura(player)
        elseif anyInRange and jugPresent then
            -- Already in aura - catch the case where player draws a weapon
            -- AFTER entering. OnClothingUpdated doesn't fire for hand-item
            -- draws, so without this the freshly-drawn weapon stays at full
            -- damage. applyAura is cheap when the weapon is already tagged
            -- (early-return on RQOrigMin check), so running it per frame here
            -- is harmless when nothing changed.
            local weapon = player:getPrimaryHandItem()
            if weapon and weapon.getModData and not weapon:getModData()["RQOrigMin"] then
                applyAura(player, mult)
            end
        end
    end
end)

function RQJuggernaut.onDead(zombie)
    local ok, oid = pcall(zombie.getOnlineID, zombie)
    if ok and oid and oid ~= 0 then
        RQRing.clear("jugg_" .. oid)
    end
end

Events.OnGameStart.Add(function()
    jugPresent = false
    -- Weapon modData persists across sessions. If the player reconnects with a
    -- weapon still tagged from a prior aura, restore it now.
    local player = getPlayer()
    if player then releaseAura(player) end
end)

-- Copyright Project_Omen
