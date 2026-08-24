-- SPDX-License-Identifier: GPL-3.0-or-later
-- RQScavenger - client visuals for the sleeper threat
-- Server (RQSvScavenger) owns all behavior - eating, rage flip, HP growth,
-- decay. Client just paints. Two visuals: outline highlight color and the
-- ground ring that appears once it rages. Both shift on a gradient as the
-- rage HP burns down, so you can read its remaining juice at a glance.
--
-- State arrives via RQReconcile.scavClientState[onlineID], populated each
-- snapshot. peakHP is frozen at the rage trigger (peakHP*5) - we use it as
-- the gradient denominator so red = full rage HP, blue = decayed back to
-- base. Personal scaling: a well-fed scav that pops still reads "full red"
-- at its own peak, not against some global ceiling.

RQScavenger = RQScavenger or {}

-- Color math for the rage gradient. Red at peak terror -> blue as rage
-- decays. Denominator is the frozen peakHP, not baseHealth, so the color
-- reads as "how much of this specific scav's rage is left."
local function getRageGradient(currentHP, peakHP)
    local ratio = math.min(1.0, currentHP / math.max(peakHP, 0.0001))
    return {
        r = ratio,
        g = 0.0,
        b = math.max(0, 1.0 - ratio * 1.5),
        a = 0.4,
    }
end

-- Passive scavs use the Glutton color so they blend in - no point
-- advertising the threat before they pop. Once raging, the gradient takes over.
local function getScavColor(state)
    if not state.enraged then
        return RQConfig.COLORS.Glutton
    end
    return getRageGradient(state.currentHP or 1,
                           state.peakHP or state.baseHealth or 1)
end

-- Called by RQHighlight with onlineID. Returns nil if we haven't received
-- a snapshot yet (the highlight pass falls back to the static config color).
function RQScavenger.getHighlightColor(onlineID)
    local state = RQReconcile.scavClientState[onlineID]
    if not state then return nil end
    return getScavColor(state)
end

-- Rage ring + special-only outline paint + player-in-aura flag.
-- Near-clone of RQJuggernaut's render tick, with three inversions:
--   1. Gated on `state.enraged` (passive scavs render nothing extra)
--   2. Ring color is the live rage gradient, not a constant
--   3. Special filter inverted: paint SPECIALS only (lore: scavs share with
--      their own kind, not shamblers). Yields to boss-painted entries.
Events.OnRenderTick.Add(function()
    local player = getPlayer()
    if not player then return end
    local playerNum = player:getPlayerNum()
    local cfg    = RQConfig.get()
    local cell   = getCell()
    local radius = cfg.juggernautBuffRadius
    local rSq    = radius * radius
    local px     = player:getX()
    local py     = player:getY()

    for onlineID, zType in pairs(RQRegistry.activeZombies) do
        if zType == "Scavenger" then
            local state = RQReconcile.scavClientState[onlineID]
            if state and state.enraged then
                local pos = RQReconcile.lastKnownPos[onlineID]
                local lx  = pos and pos.x or 0
                local ly  = pos and pos.y or 0
                local lz  = pos and pos.z or 0
                local scav = RQCore.findZombieByID(onlineID, lx, ly, lz)
                if scav then
                    if not scav:isDead() then
                        local zx = math.floor(scav:getX())
                        local zy = math.floor(scav:getY())
                        local zz = math.floor(scav:getZ())
                        local color = getScavColor(state)
                        RQRing.update("scav_" .. onlineID, zx, zy, zz, radius, color)

                        if cell then
                            local bossPainted = RQBoss and RQBoss.bossBuffPainted or {}
                            for dx = -radius, radius do
                                for dy = -radius, radius do
                                    if dx*dx + dy*dy <= rSq then
                                        local sq = cell:getGridSquare(zx + dx, zy + dy, zz)
                                        if sq then
                                            local movs = sq:getMovingObjects()
                                            if movs then
                                                for i = 0, movs:size() - 1 do
                                                    local obj = movs:get(i)
                                                    if obj and instanceof(obj, "IsoZombie")
                                                       and not obj:isDead()
                                                       and obj ~= scav
                                                       and not bossPainted[obj]
                                                    then
                                                        local ooid = obj:getOnlineID()
                                                        if RQRegistry.isSpecial(ooid) then
                                                            obj:setOutlineHighlight(playerNum, true)
                                                            obj:setOutlineHighlightCol(playerNum,
                                                                color.r, color.g, color.b, color.a)
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
    end
end)

-- Damage detection lives entirely server-side (RQSvScavenger's OnHitZombie
-- listener). In dedicated MP the event fires on the zombie-authoritative
-- server, not on the attacker's client, so a client-side hook here is dead
-- weight. SP and co-op host still cover it through the same server listener
-- since isServer() is true on the host loop.

function RQScavenger.onDead(zombie)
    local oid = zombie and zombie:getOnlineID()
    if oid and oid ~= 0 then
        RQRing.clear("scav_" .. oid)
        RQRing.clear("scav_eat_" .. oid)
        if RQGlutton and RQGlutton.stopEating then
            RQGlutton.stopEating(oid, zombie)
        end
        RQReconcile.scavClientState[oid] = nil
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
