-- SPDX-License-Identifier: GPL-3.0-or-later
-- HBContextMenu - animal right-click integration.
-- Notifies the server of encountered animals (seen list) and will host
-- Register/Unregister actions once the Ledger UI exists.

-- When the Ledger UI lands and its Register/Unregister entries need a staff
-- test, the answer is `RDAccess.isStaff` (RFTDCore/shared/RDAccess.lua) - the
-- OR of access level "admin" and capability-granted roles, promoted to Core in
-- 2026-08-20 precisely so surfaces stop writing their own. A local copy that
-- read getAccessLevel() directly sat here unused until 2026-08-27; it also
-- missed capability roles, so reviving it would have been the wrong answer as
-- well as a fourth copy. Reaching it needs `require "RDShared"` at file scope
-- (client load order is alphabetical across mods).

local function onAnimalContext(playerNum, context, animals, test)
    if test then return end
    local player = getSpecificPlayer(playerNum)
    if not player then return end

    for _, animal in ipairs(animals) do
        -- getOnlineID is a field read; the guard was standing in for a nil entry
        -- in the list vanilla hands us.
        local oid = animal and animal:getOnlineID()
        if oid and oid ~= 0 then
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
