-- SPDX-License-Identifier: GPL-3.0-or-later
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
            if zombie:isDead() then
                zombie:setOutlineHighlight(playerNum, false)
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
                    zombie:setOutlineHighlight(playerNum, true)
                    zombie:setOutlineHighlightCol(playerNum, col.r, col.g, col.b, col.a)
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
    zombie:setOutlineHighlight(player:getPlayerNum(), false)
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
