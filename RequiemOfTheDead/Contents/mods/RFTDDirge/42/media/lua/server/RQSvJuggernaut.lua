-- SPDX-License-Identifier: GPL-3.0-or-later
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

-- main tick - only called every ~2 seconds from the orchestrator, not every tick
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
                                -- ownerOnly: this fires once per zombie in radius,
                                -- so a broadcast here is the mod's peak burst.
                                -- Only latch buffed[] when the write actually
                                -- placed -- ownership can flip between passes, and
                                -- an unconditional latch would leave that zombie
                                -- permanently unbuffed. Failing means "retry next
                                -- aura pass", which costs nothing.
                                if RQSvShared.svSetZombieHP(obj, obj:getHealth() * (1.0 + buffPct), true) then
                                    RQSvJuggernaut.buffed[obj] = true
                                    buffCount = buffCount + 1
                                end
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
                -- ownerOnly: repeats every 2s and recomputes its target, so it
                -- self-corrects through an ownership handoff.
                RQSvShared.svSetZombieHP(zombie, newHP, true)
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

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
