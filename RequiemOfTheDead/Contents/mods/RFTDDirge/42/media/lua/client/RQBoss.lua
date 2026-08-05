-- SPDX-License-Identifier: GPL-3.0-or-later
-- RQBoss - client visuals for the apex zombie
-- Server (RQSvBoss) owns the skill rotation and the passive buff aura.
-- Client owns: persistent boss-color ring on each Boss, plus a per-frame paint
-- pass that colors every zombie inside the boss aura in Boss color (regular
-- AND special). The painted-zombie set is published as RQBoss.bossBuffPainted
-- so RQHighlight and RQJuggernaut can defer to us in overlap zones - boss
-- color always wins.
--
-- Cast bars and EMP/Scream telegraphs still come through castStart/castDone
-- broadcasts dispatched in RQCore - this file only handles the always-on visuals.

RQBoss = RQBoss or {}

-- Set of zombie objects currently inside any Boss's buff aura, rebuilt each
-- render tick. Other modules read this to know they should yield to the boss
-- color. Weak-keyed so dead zombies dont linger.
RQBoss.bossBuffPainted = setmetatable({}, { __mode = "k" })

-- Local player in range of any Boss aura this frame. Published so RQJuggernaut
-- can OR this with its own range check before deciding to apply/release the
-- weapon debuff - the two auras share a single apply/release pair to avoid
-- race conditions when the player is inside both at once.
RQBoss.playerInAura = false

-- Cached on first render. Cant read at file scope because RQConfig may not
-- be loaded yet when this file runs - the server-options receive path used
-- to crash here with "attempted index: COLORS of non-table: null".
local BOSS_RING_COLOR

-- Per-frame paint pass for the boss aura. For each Boss, draw a ring and
-- paint nearby zombies in Boss color. The shared bossBuffPainted table is
-- rebuilt every frame so a zombie wandering out of the aura naturally falls
-- back to its normal highlight on the next pass.
Events.OnRenderTick.Add(function()
    local player = getPlayer()
    if not player then return end
    BOSS_RING_COLOR = BOSS_RING_COLOR or (RQConfig and RQConfig.COLORS and RQConfig.COLORS.Boss)
    if not BOSS_RING_COLOR then return end
    local playerNum = player:getPlayerNum()
    local cfg       = RQConfig.get()
    local cell      = getCell()
    local radius    = cfg.juggernautBuffRadius
    local rSq       = radius * radius
    local px        = player:getX()
    local py        = player:getY()

    -- rebuild the painted set fresh each frame
    local painted = setmetatable({}, { __mode = "k" })
    RQBoss.bossBuffPainted = painted
    local playerInAnyBossAura = false

    for onlineID, zType in pairs(RQRegistry.activeZombies) do
        if zType == "Boss" then
            local pos  = RQReconcile.lastKnownPos[onlineID]
            local lx   = pos and pos.x or 0
            local ly   = pos and pos.y or 0
            local lz   = pos and pos.z or 0
            local boss = RQCore.findZombieByID(onlineID, lx, ly, lz)
            if boss then
                local ok, dead = pcall(boss.isDead, boss)
                if ok and not dead then
                    local bx = math.floor(boss:getX())
                    local by = math.floor(boss:getY())
                    local bz = math.floor(boss:getZ())
                    RQRing.update("boss_aura_" .. onlineID, bx, by, bz, radius, BOSS_RING_COLOR)

                    -- player range check for weapon debuff coordination
                    local pdx = px - bx
                    local pdy = py - by
                    if pdx*pdx + pdy*pdy <= rSq then
                        playerInAnyBossAura = true
                    end

                    -- paint every zombie inside this boss's aura. unlike Juggernaut,
                    -- specials count too - the boss color overrides their type color.
                    if cell then
                        for dx = -radius, radius do
                            for dy = -radius, radius do
                                if dx*dx + dy*dy <= rSq then
                                    local sq = cell:getGridSquare(bx + dx, by + dy, bz)
                                    if sq then
                                        local movs = sq:getMovingObjects()
                                        if movs then
                                            for i = 0, movs:size() - 1 do
                                                local obj = movs:get(i)
                                                if obj and instanceof(obj, "IsoZombie")
                                                   and not obj:isDead()
                                                   and obj ~= boss
                                                then
                                                    pcall(obj.setOutlineHighlight, obj, playerNum, true)
                                                    pcall(obj.setOutlineHighlightCol, obj, playerNum,
                                                        BOSS_RING_COLOR.r, BOSS_RING_COLOR.g, BOSS_RING_COLOR.b, BOSS_RING_COLOR.a)
                                                    painted[obj] = true
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

    RQBoss.playerInAura = playerInAnyBossAura
end)

function RQBoss.onDead(zombie)
    local ok, oid = pcall(zombie.getOnlineID, zombie)
    if ok and oid and oid ~= 0 then
        RQRing.clear("boss_" .. oid)
        RQRing.clear("boss_emp_" .. oid)
        RQRing.clear("boss_aura_" .. oid)
    end
end

Events.OnGameStart.Add(function()
    RQBoss.bossBuffPainted = setmetatable({}, { __mode = "k" })
    RQBoss.playerInAura    = false
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
