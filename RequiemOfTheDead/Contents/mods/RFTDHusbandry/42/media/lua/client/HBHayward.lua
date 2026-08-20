-- SPDX-License-Identifier: GPL-3.0-or-later
-- HBHayward - resolves the hay one player can actually offer a hutch.

HBHayward = HBHayward or {}

local HAY_TYPE = "Base.HayTuft"

-- ItemContainer.getFirstTypeRecurse(String) returns an item or nil after its
-- bounded container walk; it has no exceptional result on a valid inventory
-- (ItemContainer.java:1153-1178, 1470-1474).
function HBHayward.find(character)
    local inventory = character and character:getInventory()
    if not inventory then return nil end
    return inventory:getFirstTypeRecurse(HAY_TYPE)
end

return HBHayward

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
