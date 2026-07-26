-- RQHighlight - outline glow on special zombies
-- PZ doesn't persist outline highlights between frames so we
-- reapply them every render tick. Registry is now keyed by
-- onlineID; the zombie object is resolved at render time from
-- lastKnownPos coordinates so a dead/missing ref is just a miss,
-- not a stale table entry that poisons the loop.

RQHighlight = RQHighlight or {}

local function onRenderTick()
    local player = getPlayer()
    if not player then return end
    local playerNum = player:getPlayerNum()

    for onlineID, zType in pairs(RQRegistry.activeZombies) do
        -- resolve object at render time; nil = not in loaded chunks, skip
        local pos = RQReconcile.lastKnownPos[onlineID]
        local px = pos and pos.x or 0
        local py = pos and pos.y or 0
        local pz = pos and pos.z or 0
        local zombie = RQCore.findZombieByID(onlineID, px, py, pz)
        if zombie then
            local ok, dead = pcall(zombie.isDead, zombie)
            if not ok or dead then
                pcall(zombie.setOutlineHighlight, zombie, playerNum, false)
            else
                local col
                -- Boss aura override: if this zombie is currently being painted by
                -- a Boss buff aura, force boss color regardless of its own type.
                -- Boss render tick rebuilds bossBuffPainted before this loop runs.
                if RQBoss and RQBoss.bossBuffPainted and RQBoss.bossBuffPainted[zombie] then
                    col = RQConfig.COLORS.Boss
                elseif zType == "Scavenger" and RQScavenger and RQScavenger.getHighlightColor then
                    col = RQScavenger.getHighlightColor(onlineID)
                elseif zType == "EMP" then
                    -- Match the EMP inner knockdown ring (orange) so the body
                    -- glow and that ring read as one colour - and so EMPs are
                    -- no longer confused with Juggernauts (blue).
                    col = RQConfig.COLORS.EMPInner
                end
                col = col or RQConfig.COLORS[zType]
                if col then
                    pcall(zombie.setOutlineHighlight, zombie, playerNum, true)
                    pcall(zombie.setOutlineHighlightCol, zombie, playerNum, col.r, col.g, col.b, col.a)
                end
            end
        end
    end
end

Events.OnRenderTick.Add(onRenderTick)

-- called by RQCore when a zombie dies, after loot is handled
function RQHighlight.remove(onlineID)
    if not onlineID then return end
    local pos = RQReconcile and RQReconcile.lastKnownPos[onlineID]
    if not pos then return end
    local zombie = RQCore.findZombieByID(onlineID, pos.x, pos.y, pos.z)
    if not zombie then return end
    local player = getPlayer()
    if not player then return end
    pcall(zombie.setOutlineHighlight, zombie, player:getPlayerNum(), false)
end

-- Copyright Project_Omen
