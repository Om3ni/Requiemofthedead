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
