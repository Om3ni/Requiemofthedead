-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFMedicalCheck - admin bypass of the medical-check target prompt.
--
-- Vanilla: when a player triggers medical check on another player, the
-- target gets an accept/refuse dialog. Admins inspecting a downed/AFK
-- player for cheat detection or wellness checks don't want that gate.
--
-- Bypass: hijack ISWorldObjectContextMenu.onMedicalCheck. If the requester
-- has Capability.CanMedicalCheat, queue the ISMedicalCheckAction directly
-- on the requester without the target dialog. Otherwise fall through to
-- vanilla behavior. Pattern lifted from ebfadminfix_medicalcheck.lua.

if isServer() then return end

require "ISUI/ISWorldObjectContextMenu"
require "TimedActions/ISMedicalCheckAction"
require "XpSystem/ISUI/ISHealthPanel"

DFMedicalCheck = DFMedicalCheck or {}

DFMedicalCheck.vanillaOnMedicalCheck =
    DFMedicalCheck.vanillaOnMedicalCheck or ISWorldObjectContextMenu.onMedicalCheck

function DFMedicalCheck.performAdmin(requester, target)
    if not requester or not target then return false end
    if not ISHealthPanel.canPerformMedicalCheck(target, requester) then return false end
    local action = ISMedicalCheckAction:new(requester, target)
    action.maxTime = 1
    ISTimedActionQueue.add(action)
    return true
end

function ISWorldObjectContextMenu.onMedicalCheck(worldobjects, requester, target)
    if DFCore.roleHas(requester, Capability.CanMedicalCheat)
        and DFMedicalCheck.performAdmin(requester, target) then
        return
    end
    return DFMedicalCheck.vanillaOnMedicalCheck(worldobjects, requester, target)
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
