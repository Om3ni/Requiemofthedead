-- SPDX-License-Identifier: GPL-3.0-or-later
-- HBAnimalMenu - opens the vanilla animal menu with Husbandry's caretaker
-- controls visible, then restores the caller's cheat state.

require "ISUI/Animal/ISAnimalContextMenu"

HBAnimalMenu = HBAnimalMenu or {}

function HBAnimalMenu.openCaretakerMenu(player, screenX, screenY, animal)
    local playerNum = player:getPlayerNum()
    local context = ISContextMenu.get(playerNum, screenX, screenY)
    if not context then return true end

    local previousCheat = AnimalContextMenu.cheat
    AnimalContextMenu.cheat = true

    -- KEEP: vanilla's large menu builder crosses many animal-state and UI
    -- surfaces. A malformed animal must not strand either cheat flag or break
    -- the owning Husbandry panel; the caller reports the bounded failure.
    local ok, err = pcall(AnimalContextMenu.doMenu,
                          playerNum, context, animal, false)

    AnimalContextMenu.cheat = previousCheat
    -- doMenu copies the Lua flag into Core before building any options
    -- (ISAnimalContextMenu.lua:132-140; Core.java:4772-4774).
    getCore():setAnimalCheat(previousCheat)
    return ok, err
end

return HBAnimalMenu

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
