-- SPDX-License-Identifier: GPL-3.0-or-later
-- RPContextMenu - adds a debug right-click ground option that asks the server
-- to run an immediate full scan (all bloom detection layers on demand).
-- Sandbox option RFTDReaper.DebugContextMenu gates whether the option appears.

if isServer() then return end

local MODULE = "RFTDReaper"

local function onFillWorldObjectContextMenu(playerNum, context, worldobjects, test)
    local s = SandboxVars.RFTDReaper or {}
    if s.Enabled == false then return end
    if s.DebugContextMenu ~= true then return end
    if test then return end

    context:addOption(
        "Reaper: Force full scan",
        nil,
        function()
            local player = getPlayer()
            sendClientCommand(player, MODULE, "forceScan", {})
            if player then
                player:Say("Reaper full scan dispatched")
            end
        end
    )
end

Events.OnFillWorldObjectContextMenu.Add(onFillWorldObjectContextMenu)

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
