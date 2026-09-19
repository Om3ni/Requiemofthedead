-- SPDX-License-Identifier: GPL-3.0-or-later

-- RQAura - the walk over a special's aura.
--
-- One rule, three consumers: the Juggernaut escort paint (RQJuggernaut), the
-- Boss escort paint (RQBoss) and the escort muster (RQMuster) each need
-- every live zombie inside the circle of the aura radius around a special,
-- on the special's own floor, and not the special itself. Until 2026-09-17
-- each carried its own copy of that loop, inline, where check-helpers
-- cannot see it (TODO.md, paid the same day). What each does with a zombie
-- it finds - paint it, paint and record it, command it - is policy and
-- stays at the call site; only the walk lives here.
--
-- The circle, not the square: a zombie in the corner of the bounding square
-- is outside the aura the ring draws. The floor: an aura is not transparent
-- to a storey, so the squares walked are the special's z only.

RQAura = RQAura or {}

-- Call fn(zombie) for every live IsoZombie other than `special` within
-- `radius` tiles of it on its floor. `cell` is the caller's getCell(), which
-- the caller has already tested for nil - a client with no cell has nothing
-- loaded to walk, and whether that counts as an empty aura or as no aura at
-- all is the caller's question. Returns how many zombies fn was given.
--
-- No allocation per call beyond the loop itself: the callers hand in a
-- file-scope function and set its inputs through upvalues, because two of
-- them run once per special per RENDER TICK.
function RQAura.eachEscort(cell, special, radius, fn)
    local rSq = radius * radius
    local sx = math.floor(special:getX())
    local sy = math.floor(special:getY())
    local sz = math.floor(special:getZ())
    local found = 0
    for dx = -radius, radius do
        for dy = -radius, radius do
            if dx * dx + dy * dy <= rSq then
                local sq = cell:getGridSquare(sx + dx, sy + dy, sz)
                if sq then
                    local movs = sq:getMovingObjects()
                    if movs then
                        for i = 0, movs:size() - 1 do
                            local obj = movs:get(i)
                            if obj and instanceof(obj, "IsoZombie")
                               and obj ~= special
                               and not obj:isDead()
                            then
                                fn(obj)
                                found = found + 1
                            end
                        end
                    end
                end
            end
        end
    end
    return found
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
