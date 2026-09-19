-- SPDX-License-Identifier: GPL-3.0-or-later
-- RQBoss - client visuals for the apex zombie
-- Server (RQSvBoss) owns the skill rotation. The passive buff aura it used to
-- own is gone: first to a hit-time soak (2026-08-24), then retired with it on
-- 2026-09-17, when durability moved onto the livery items' armour. What is
-- left of the aura is the escort PAINT below, which is presentation.
-- Client owns: persistent boss-color ring on each Boss, plus a per-frame paint
-- pass that colors every zombie inside the boss aura in Boss color (regular
-- AND special). The painted-zombie set is published as RQBoss.bossBuffPainted
-- so RQHighlight and RQJuggernaut can defer to us in overlap zones - boss
-- color always wins.
--
-- Cast bars and EMP/Scream telegraphs still come through castStart/castDone
-- broadcasts dispatched in RQCore - this file only handles the always-on visuals.

require "RQAura"

RQBoss = RQBoss or {}

-- Set of zombie objects currently inside any Boss's buff aura, rebuilt each
-- render tick. Other modules read this to know they should yield to the boss
-- color.
-- NOT weak-keyed, and it never was: Kahlua ignores `__mode` entirely
-- (see RDLedger's header). This table is safe for a different, real reason:
-- the whole table is REPLACED every render tick, so the previous one becomes
-- garbage immediately and no row can outlive one frame.
RQBoss.bossBuffPainted = {}

-- onlineID -> true for every Boss whose aura painted at least one zombie
-- this frame: a Boss WITH AN ESCORT. RQHighlight outlines an escorted Boss
-- even when ShowBossHighlight is off (owner rule, 2026-09-17: a Boss loses
-- its outline and gets it back only while it has an escort). Rebuilt every
-- render tick like the painted set, and bounded the same way.
RQBoss.escorted = {}

-- The player-in-aura flag this file used to publish is gone (2026-08-25), and
-- so is the note that described it. It existed for one consumer: RQJuggernaut
-- OR'd it with its own range check to drive a shared weapon-debuff
-- apply/release pair. Both sides of that pair went with Dirge's RQSuppress
-- terms on 2026-08-24, so the flag had been written and read by nobody since.

-- Cached on first render. Cant read at file scope because RQConfig may not
-- be loaded yet when this file runs - the server-options receive path used
-- to crash here with "attempted index: COLORS of non-table: null".
local BOSS_RING_COLOR

-- The per-zombie policy for RQAura.eachEscort, file-scope so a render tick
-- allocates no closure. Unlike the Juggernaut's, specials count too - the
-- boss colour overrides their type colour - and the sets are recorded here:
-- painted (read by RQJuggernaut and RQHighlight for the overlap) and
-- escorted (read by RQHighlight to outline an escorted Boss).
local paintPlayerNum = 0
local paintPainted   = {}
local paintEscorted  = {}
local paintBossID    = 0
local function paintEscort(obj)
    obj:setOutlineHighlight(paintPlayerNum, true)
    obj:setOutlineHighlightCol(paintPlayerNum,
        BOSS_RING_COLOR.r, BOSS_RING_COLOR.g, BOSS_RING_COLOR.b, BOSS_RING_COLOR.a)
    paintPainted[obj] = true
    paintEscorted[paintBossID] = true
end

-- Per-frame paint pass for the boss aura. For each Boss, draw a ring and
-- paint nearby zombies in Boss color. The shared bossBuffPainted table is
-- rebuilt every frame so a zombie wandering out of the aura naturally falls
-- back to its normal highlight on the next pass.
Events.OnRenderTick.Add(function()
    local player = getPlayer()
    if not player then return end
    BOSS_RING_COLOR = BOSS_RING_COLOR or (RQConfig and RQConfig.COLORS and RQConfig.COLORS.Boss)
    if not BOSS_RING_COLOR then return end
    local cfg       = RQConfig.get()
    local cell      = getCell()
    local radius    = cfg.juggernautBuffRadius
    paintPlayerNum  = player:getPlayerNum()

    -- rebuild the painted set fresh each frame - this replacement, not any
    -- weak-key behaviour, is what bounds the table (Kahlua has no weak tables)
    paintPainted  = {}
    paintEscorted = {}
    RQBoss.bossBuffPainted = paintPainted
    RQBoss.escorted        = paintEscorted

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
                    -- Removed 2026-08-25.

                    -- paint every zombie inside this boss's aura. The walk is
                    -- RQAura's; paintEscort above is the policy.
                    if cell then
                        paintBossID = onlineID
                        RQAura.eachEscort(cell, boss, radius, paintEscort)
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
    RQBoss.escorted = {}
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
