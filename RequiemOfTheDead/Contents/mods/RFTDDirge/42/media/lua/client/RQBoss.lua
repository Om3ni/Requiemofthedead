-- SPDX-License-Identifier: GPL-3.0-or-later
-- RQBoss - client visuals for the apex zombie
-- Server (RQSvBoss) owns the skill rotation. The passive buff aura it used to
-- own is RQBulwark's now - resolved per hit against the zombie struck, rather
-- than granted once to everything standing nearby.
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
-- color.
-- NOT weak-keyed, and it never was: Kahlua ignores `__mode` entirely
-- (see RDLedger's header). This table is safe for a different, real reason:
-- the whole table is REPLACED every render tick, so the previous one becomes
-- garbage immediately and no row can outlive one frame.
RQBoss.bossBuffPainted = {}

-- The player-in-aura flag this file used to publish is gone (2026-08-25), and
-- so is the note that described it. It existed for one consumer: RQJuggernaut
-- OR'd it with its own range check to drive a shared weapon-debuff
-- apply/release pair. Both sides of that pair went with Dirge's RQSuppress
-- terms on 2026-08-24, so the flag had been written and read by nobody since.

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

    -- rebuild the painted set fresh each frame - this replacement, not any
    -- weak-key behaviour, is what bounds the table (Kahlua has no weak tables)
    local painted = {}
    RQBoss.bossBuffPainted = painted

    for onlineID, zType in pairs(RQRegistry.activeZombies) do
        if zType == "Boss" then
            local boss = RQCore.findZombieByID(onlineID)
            if boss then
                if not boss:isDead() then
                    local bx = math.floor(boss:getX())
                    local by = math.floor(boss:getY())
                    local bz = math.floor(boss:getZ())
                    RQRing.update("boss_aura_" .. onlineID, bx, by, bz, radius, BOSS_RING_COLOR)

                    -- Same removal as RQJuggernaut's: the player-distance test
                    -- here fed the aura flag RQSuppress read, and has fed
                    -- nothing since 2026-08-24. Per Boss, per render tick.
                    -- Removed 2026-08-25; rSq stays for the paint pass below.

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
                                                    obj:setOutlineHighlight(playerNum, true)
                                                    obj:setOutlineHighlightCol(playerNum,
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

end)

function RQBoss.onDead(zombie)
    local oid = zombie and zombie:getOnlineID()
    if oid and oid ~= 0 then
        RQRing.clear("boss_" .. oid)
        RQRing.clear("boss_emp_" .. oid)
        RQRing.clear("boss_aura_" .. oid)
    end
end

Events.OnGameStart.Add(function()
    RQBoss.bossBuffPainted = {}
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
