-- SPDX-License-Identifier: GPL-3.0-or-later
-- RPLocality - is this row inside the area the operator is standing in?
--
-- Split out of RPNecroTab 2026-08-25 so a fixture can load the rule without
-- stubbing a ~950-line UI module. This predicate SHIPPED WRONG ONCE (the
-- grid-bucket bug below, found in play), which is exactly the argument for it
-- being requireable: pure arithmetic that nothing could test is arithmetic
-- that gets tested by players. One consumer, so it stays in Reaper
-- (CLAUDE.md sect. 5) - this is a file move, not a Core promotion.
--
-- THE PANEL SHOWS MORE THAN THE OPERATOR CAN SEE, and that is the hazard the
-- filter closes. RPCore.snapshot walks every LOADED zombie server-side, which
-- on a dedicated server is the union of every player's chunk map - not this
-- admin's. So a row can be perfectly real and forty tiles inside someone
-- else's cell, where nothing this client does can confirm it is the right
-- body. Narrowing to "my chunk" or "my cell" makes the list honest: what is
-- left is what the operator can walk to, point at, and watch light up.
--
-- CENTRED ON THE PLAYER, NOT SNAPPED TO THE WORLD GRID. This started as a
-- bucket comparison - floor(x/size) == floor(px/size) - which asks whether
-- two points fall in the same cell of the grid the WORLD draws, and that is
-- not the question the filter is for.
--
-- The failure was not marginal. At chunk size 8, a zombie two tiles east
-- shares your bucket only when your x mod 8 is 0-5, six cases in eight;
-- across both axes that is 0.75 * 0.75, so roughly FOUR TIMES IN TEN a
-- zombie two tiles away was correctly excluded from "My chunk" while
-- standing in plain sight. Reported from play 2026-08-20. A boundary the
-- operator cannot see, cutting through the area they are standing in, is
-- indistinguishable from a bug.
--
-- A half-extent box centred on the player covers the same AREA - (size+1)^2
-- against size^2 - and has no interior boundary at all, so the answer
-- changes smoothly as they walk instead of jumping when they cross an
-- invisible line.
--
-- Sizes come from the engine rather than from the constants they currently
-- return - 8 and 256 (LuaManager.java:4786-4789, :4781-4784). B41 chunks
-- were 10 squares and B41 cells were 300, so hardcoding is exactly how this
-- file would quietly start lying after a build bump.

RPLocality = RPLocality or {}

function RPLocality.nearPlayer(row, size)
    local p = getPlayer()
    if not p or not row or not row.x or not row.y then return false end
    local half = size / 2
    -- Z is deliberately NOT compared. A zombie one floor up is still inside
    -- the area the operator is standing in and still on their screen; the
    -- question this filter answers is "can I get to it", not "am I level
    -- with it".
    return math.abs(math.floor(p:getX()) - row.x) <= half
       and math.abs(math.floor(p:getY()) - row.y) <= half
end

-- The view over rows the tab already holds - no second request, no wire cost.
-- locality: "any" (or nil) passes everything; "chunk" and "cell" narrow to
-- the engine's own current sizes.
function RPLocality.apply(rows, locality)
    if not locality or locality == "any" then return rows end
    local size = (locality == "chunk") and getChunkSizeInSquares() or getCellSizeInSquares()
    local out = {}
    for _, e in ipairs(rows) do
        if RPLocality.nearPlayer(e, size) then out[#out + 1] = e end
    end
    return out
end

return RPLocality

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
