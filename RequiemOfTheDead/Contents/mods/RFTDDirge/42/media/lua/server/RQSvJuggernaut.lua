-- RQSvJuggernaut.lua
-- handles the alive behavior tick for Juggernaut type zombies
-- jugg has two jobs: apply a HP buff to nearby non-special zombies, and regen a little each tick
if not isServer() then return end

RQSvJuggernaut = RQSvJuggernaut or {}
RQSvJuggernaut.buffTick = 0

-- weak-keyed so we dont hold references to dead zombie objects, just lets them get GC'd naturally
RQSvJuggernaut.buffed = setmetatable({}, { __mode = "k" })

-- RQServer injects the active zombie table here so jugg can skip buffing special zombies
local _activeZombies = {}
function RQSvJuggernaut.setActiveZombies(tbl)
    _activeZombies = tbl
end

-- main tick — only called every ~2 seconds from the orchestrator, not every tick
function RQSvJuggernaut.tick(zombie)
    local cfg     = RQSvShared.getSvConfig()
    local radius  = cfg.juggernautBuffRadius
    local buffPct = cfg.juggernautBuffPercent / 100.0
    local cell    = getCell()
    if not cell then return end
    local x   = math.floor(zombie:getX())
    local y   = math.floor(zombie:getY())
    local z   = math.floor(zombie:getZ())
    local jid = zombie:getOnlineID()

    local rSq = radius * radius
    local buffCount = 0
    for dx = -radius, radius do
        for dy = -radius, radius do
            if dx * dx + dy * dy <= rSq then
                local sq = cell:getGridSquare(x + dx, y + dy, z)
                if sq then
                    local movs = sq:getMovingObjects()
                    if movs then
                        for i = 0, movs:size() - 1 do
                            local obj = movs:get(i)
                            -- skip dead, skip self, skip other special types, skip already buffed.
                            -- also yield to Boss buff aura - overlap zones are boss-flavored.
                            if obj and instanceof(obj, "IsoZombie") and not obj:isDead()
                               and obj ~= zombie
                               and not _activeZombies[obj]
                               and not RQSvJuggernaut.buffed[obj]
                               and not (RQSvBoss and RQSvBoss.buffed and RQSvBoss.buffed[obj]) then
                                RQSvShared.svSetZombieHP(obj, obj:getHealth() * (1.0 + buffPct))
                                RQSvJuggernaut.buffed[obj] = true
                                buffCount = buffCount + 1
                            end
                        end
                    end
                end
            end
        end
    end
    if buffCount > 0 then
        RQDirgeLog.write("Juggernaut", "[INFO] id=" .. tostring(jid)
            .. " buffed=" .. buffCount .. " zombies at (" .. x .. "," .. y .. "," .. z .. ")"
            .. " pct=" .. cfg.juggernautBuffPercent .. " radius=" .. radius)
    end

    local mitigation = cfg.juggernautMitigation or 0
    if mitigation > 0 then
        local maxHP = zombie:getModData()["RQJuggMaxHP"]
        if maxHP and maxHP > 0 then
            local hp = zombie:getHealth()
            if hp < maxHP then
                local newHP = math.min(maxHP, hp + maxHP * (mitigation / 100.0))
                RQSvShared.svSetZombieHP(zombie, newHP)
                RQDirgeLog.write("Juggernaut", "[INFO] id=" .. tostring(jid)
                    .. " mitigation regen hp=" .. string.format("%.2f", hp)
                    .. " -> " .. string.format("%.2f", newHP)
                    .. " max=" .. string.format("%.2f", maxHP))
            end
        else
            RQDirgeLog.write("Juggernaut", "[WARN] id=" .. tostring(jid)
                .. " mitigation=" .. mitigation .. " but RQJuggMaxHP missing or zero")
        end
    end
end

-- Copyright Project_Omen
