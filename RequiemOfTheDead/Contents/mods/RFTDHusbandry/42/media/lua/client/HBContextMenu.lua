-- SPDX-License-Identifier: GPL-3.0-or-later
-- HBContextMenu - animal right-click integration.
-- Notifies the server of encountered animals (seen list) and will host
-- Register/Unregister actions once the Ledger UI exists.

-- Mirrors Dirge's access-level check: getAccessLevel() is reliable in both
-- SP and MP. The global isAdmin() can return false for the host in some contexts.
local function isHBAdmin()
    local player = getPlayer()
    if not player then return false end
    local access = player:getAccessLevel()
    if access and access ~= "" and access ~= "None" then return true end
    if not isClient() then return true end
    if isServer() then return true end
    return false
end

local function onAnimalContext(playerNum, context, animals, test)
    if test then return end
    local player = getSpecificPlayer(playerNum)
    if not player then return end

    for _, animal in ipairs(animals) do
        local ok, oid = pcall(function() return animal:getOnlineID() end)
        if ok and oid and oid ~= 0 then
            sendClientCommand(player, "RFTDHusbandry", HBCmd.ADD_SEEN, { id = tostring(oid) })
        end
    end
end

Events.OnClickedAnimalForContext.Add(onAnimalContext)

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
