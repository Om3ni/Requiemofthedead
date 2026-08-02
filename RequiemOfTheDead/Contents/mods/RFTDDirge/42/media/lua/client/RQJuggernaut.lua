-- RQJuggernaut - client render only
-- All buff behavior runs server-side (svJuggernautTick).
-- Client keeps: ring follow and the proximity-based buff highlight.
--
-- The weapon debuff that used to live here moved to RQSuppress -- this file
-- now just publishes RQJuggernaut.playerInAura each frame, the same contract
-- RQBoss and RQScavenger already used. RQSuppress loads after all three
-- (alphabetical load order registers its render tick last), reads the flags
-- same-frame, and owns every weapon write: snapshot, stacking, the ranged
-- kiting counter, linger, and restore. Nothing in this file touches items.

RQJuggernaut = RQJuggernaut or {}

-- Local player in range of any Juggernaut's aura this frame. Read by
-- RQSuppress's "aura" group alongside RQBoss.playerInAura and
-- RQScavenger.playerInAura.
RQJuggernaut.playerInAura = false

-- Ring color for the jugg's ground marker. Full alpha so it reads
-- clearly against the outline highlight (which uses a=0.3).
-- Ring and buffed normals both pull from COLORS so they stay in lockstep with the outline highlight.
local JUGG_RING_COLOR = RQConfig.COLORS.Juggernaut
local BUFF_COLOR      = JUGG_RING_COLOR

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

    RQJuggernaut.playerInAura = inRange
end)

function RQJuggernaut.onDead(zombie)
    local ok, oid = pcall(zombie.getOnlineID, zombie)
    if ok and oid and oid ~= 0 then
        RQRing.clear("jugg_" .. oid)
    end
end

Events.OnGameStart.Add(function()
    RQJuggernaut.playerInAura = false
end)

-- Copyright Project_Omen
