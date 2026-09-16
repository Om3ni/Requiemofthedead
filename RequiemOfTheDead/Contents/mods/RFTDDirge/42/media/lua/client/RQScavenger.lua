-- SPDX-License-Identifier: GPL-3.0-or-later
-- RQScavenger - client visuals for the sleeper threat
-- Server (RQSvScavenger) owns all behavior - eating, rage flip, HP growth,
-- decay. Client just paints. Two visuals, both gated on rage: the ground ring,
-- and the outline it puts on nearby specials.
--
-- THE COLOUR IS CONSTANT, and that is a decision, not a simplification. A rage
-- gradient used to run the outline from red at peak down to pure blue as the
-- rage decayed, so a player watching one scavenger rage out saw it change hue
-- four times - green, red, purple, blue - which reads as the zombie changing
-- TYPE rather than state. Worse, it landed on blue: RQConfig.lua:16 already
-- records moving EMP off blue because players confused it with Juggernauts,
-- and the gradient walked into that same collision from the other side.
--
-- Emerald now means one thing wherever it appears - empowered by a Devourer.
-- The scav wears it passive and enraged alike, and so does everything it has
-- buffed, so the SPREAD is the tell rather than the source. Passive scavs
-- already shared the Glutton colour deliberately (no point advertising the
-- threat before they pop); this extends that intent through the rage instead
-- of abandoning it at the moment it matters. Owner decision 2026-09-03.
--
-- WHAT WENT WITH IT is the at-a-glance read on remaining rage. Accepted: the
-- count of things wearing the colour replaces it. Note this removed a VISUAL,
-- not a wire field - currentHP/peakHP still travel in scavClientState and are
-- still consumed by RQHealthBar (RQHealthBar.lua:94-95).
--
-- WHO GETS BUFFED DID NOT CHANGE. The radius paint below is still specials
-- only; scavs share with their own kind, not shamblers.
--
-- State arrives via RQReconcile.scavClientState[onlineID], populated each
-- snapshot.

RQScavenger = RQScavenger or {}

-- Rage ring + special-only outline paint.
-- Near-clone of RQJuggernaut's render tick, with three inversions:
--   1. Gated on `state.enraged` (passive scavs render nothing extra)
--   2. Ring and outline share one constant colour (see header)
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

    for onlineID, zType in pairs(RQRegistry.activeZombies) do
        if zType == "Scavenger" then
            local state = RQReconcile.scavClientState[onlineID]
            if state and state.enraged then
                local scav = RQCore.findZombieByID(onlineID)
                if scav then
                    if not scav:isDead() then
                        local zx = math.floor(scav:getX())
                        local zy = math.floor(scav:getY())
                        local zz = math.floor(scav:getZ())
                        local color = RQConfig.COLORS.Scavenger
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
