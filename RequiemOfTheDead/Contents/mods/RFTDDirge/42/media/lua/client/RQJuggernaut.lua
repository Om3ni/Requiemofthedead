-- SPDX-License-Identifier: GPL-3.0-or-later
-- RQJuggernaut - client render only.
-- Client keeps: ring follow and the proximity-based buff highlight. Nothing in
-- this file touches items, and nothing in it decides damage.
--
-- The weapon debuff that used to live here moved to RQSuppress, then out of
-- Dirge on 2026-08-24 in favour of a server-side soak (RQBulwark), and that
-- soak was retired 2026-09-17: durability is armour on the livery items now,
-- plus RQDread's weapon term registered back into RQSuppress.
--
-- REPAIRED 2026-08-25. Three separate removal passes each left damage in this
-- header, and the result described a file that does not exist:
--   * "All buff behavior runs server-side (svJuggernautTick)" - there is no
--     svJuggernautTick, in this build or any other. RQSvJuggernaut has no tick
--     at all; it says so itself.
--   * "the ground ring and the outline / kiting counter, linger, and restore" -
--     one sentence ending mid-phrase with the tail of a deleted one grafted on.
--   * "Local player in range of any Juggernaut's aura this frame. Read by" -
--     a dangling remnant, contradicted by the correct note two lines below it.

require "RQAura"

RQJuggernaut = RQJuggernaut or {}

-- The playerInAura flag this file used to publish is gone: RQDread computes
-- its own distance to the nearest protector. What remains here is
-- presentation - the ground ring and the escort outline.

-- Ring color for the jugg's ground marker. Full alpha so it reads
-- clearly against the outline highlight (which uses a=0.3).
-- Ring and buffed normals both pull from COLORS so they stay in lockstep with the outline highlight.
local JUGG_RING_COLOR = RQConfig.COLORS.Juggernaut
local BUFF_COLOR      = JUGG_RING_COLOR

-- The per-zombie policy for RQAura.eachEscort, file-scope so a render tick
-- allocates no closure. Its inputs are set per frame just before the walk.
local paintPlayerNum  = 0
local paintBossPainted = {}
local function paintEscort(obj)
    -- Yields to RQBoss.bossBuffPainted - if a boss is also nearby, the boss
    -- colour wins on the overlap - and never paints a special.
    if not paintBossPainted[obj] and not RQRegistry.isSpecial(obj:getOnlineID()) then
        obj:setOutlineHighlight(paintPlayerNum, true)
        obj:setOutlineHighlightCol(paintPlayerNum,
            BUFF_COLOR.r, BUFF_COLOR.g, BUFF_COLOR.b, BUFF_COLOR.a)
    end
end

Events.OnRenderTick.Add(function()
    local player = getPlayer()
    if not player then return end
    local cfg = RQConfig.get()
    local cell = getCell()
    local radius = cfg.juggernautBuffRadius
    paintPlayerNum   = player:getPlayerNum()
    paintBossPainted = RQBoss and RQBoss.bossBuffPainted or {}

    for onlineID, zType in pairs(RQRegistry.activeZombies) do
        if zType == "Juggernaut" then
            local jugg = RQCore.findZombieByID(onlineID)
            if jugg then
                if not jugg:isDead() then
                    local jx = math.floor(jugg:getX())
                    local jy = math.floor(jugg:getY())
                    local jz = math.floor(jugg:getZ())
                    RQRing.update("jugg_" .. onlineID, jx, jy, jz, radius, JUGG_RING_COLOR)

                    -- The player-distance test that used to live here computed
                    -- the aura flag RQSuppress read. Nothing has read it since
                    -- 2026-08-24, so it was two subtractions, two multiplies and
                    -- a compare per Juggernaut per RENDER TICK, feeding a local
                    -- that was written and never examined. Removed 2026-08-25.

                    -- Proximity-based buff highlight: any normal zombie within
                    -- buffRadius of this jugg is considered buffed (cosmetic only).
                    -- The walk is RQAura's; paintEscort above is the policy.
                    if cell then
                        RQAura.eachEscort(cell, jugg, radius, paintEscort)
                    end
                end
            end
        end
    end

end)

function RQJuggernaut.onDead(zombie)
    local oid = zombie and zombie:getOnlineID()
    if oid and oid ~= 0 then
        RQRing.clear("jugg_" .. oid)
    end
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
