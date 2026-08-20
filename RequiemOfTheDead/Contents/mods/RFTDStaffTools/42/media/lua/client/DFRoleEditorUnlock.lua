-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFRoleEditorUnlock - removes vanilla's read-only guards on built-in roles.
--
-- Vanilla locks role editing for built-in (read-only) roles in two places:
-- 1) UI: ISModalEditRole disables the description field, color picker,
--    capability tick boxes, and SAVE button when role:isReadOnly() is true.
-- 2) Java: Role.addCapability / removeCapability / cleanCapability check
--    isReadOnly internally and silently return without mutating the HashSet.
--    So even after re-enabling the UI, the vanilla SAVE path is a no-op for
--    caps, and the server then broadcasts the unchanged role back via
--    RolesPacket, snapping the local edit back to defaults on next reopen.
--
-- Bypass: Role.getCapabilities() returns the underlying HashSet by reference.
-- HashSet.clear() and add(cap) on that reference are not guarded.
-- setDescription and setColor are also unguarded. We hijack the SAVE handler,
-- mutate locally via the HashSet, and send our own command to the server.
-- Server-side Lua (DFRoleEdit_Server.lua) performs the same bypass and
-- persists to Dragonfly_RoleOverrides.txt.

if isServer() then return end

require "DFRoleShared"   -- explicit: the client walks lua tiers alphabetically
                         -- across mods, so load order cannot be assumed (CLAUDE.md 4)

local MODULE = "Dragonfly_RoleEdit"

-- capability / findRole / applyOverride now live in shared/DFRoleShared.lua -
-- this file and DFRoleEdit_Server ran identical copies of all three.

local patched = false

local function applyPatches()
    if patched or not ISModalEditRole then return end
    patched = true

    local origInit = ISModalEditRole.initialise
    function ISModalEditRole:initialise()
        origInit(self)
        if self.valueDescription then self.valueDescription:setEditable(true) end
        if self.buttonColor then self.buttonColor:setEnable(true) end
        if self.tickBoxCapability then self.tickBoxCapability.enable = true end
    end

    local origPopulate = ISModalEditRole.populateList
    function ISModalEditRole:populateList()
        origPopulate(self)
        if self.save then self.save:setVisible(true) end
    end

    local origOnClick = ISModalEditRole.onClick
    function ISModalEditRole:onClick(button)
        if button.internal == "SAVE" and self.role and self.role:isReadOnly() then
            local capList = {}
            for cap, on in pairs(self.capabilities) do
                if on then capList[#capList+1] = cap:name() end
            end
            local args = {
                roleName = self.role:getName(),
                description = self.valueDescription:getText() or "",
                r = self.color.r, g = self.color.g, b = self.color.b,
                capabilities = capList,
            }
            DFRoleShared.applyOverride(self.role, args)
            sendClientCommand(getPlayer(), MODULE, "save", args)
            ISModalEditRole.instance:closeModal()
            return
        end
        origOnClick(self, button)
    end
end

-- Expose to DFRolesTab (and any other in-mod caller) so they can apply
-- overrides locally without monkey-patching their own copy.
DFRoleEdit = DFRoleEdit or {}
DFRoleEdit.MODULE = MODULE
-- Public surface kept pointing at the shared module so anything holding these
-- names keeps working.
DFRoleEdit.applyOverrideLocal  = DFRoleShared.applyOverride
DFRoleEdit.findRole            = DFRoleShared.findRole
DFRoleEdit.getCapabilityByName = DFRoleShared.capability

local function onServerCommand(module, command, args)
    if module ~= MODULE then return end

    -- A refusal is its own command precisely so it can never reach
    -- applyOverride, which rebuilds a role's capabilities from the payload it
    -- is given. Answering the caller matters here: the role editor is a panel
    -- with a save button, and a save that returns nothing at all leaves the
    -- admin unable to tell "refused" from "broken".
    if command == "saveRefused" then
        print("[Dragonfly] role save refused: " .. tostring(args and args.reason))
        if DFLog and DFLog.push then
            DFLog.push{ source = "Admin", level = "warn",
                text = "Role save refused: " .. tostring(args and args.reason) }
        end
        return
    end

    if command ~= "applied" then return end
    DFRoleShared.applyOverride(DFRoleShared.findRole(args.roleName), args)
end

Events.OnGameStart.Add(applyPatches)
Events.OnServerCommand.Add(onServerCommand)

-- Dragonfly v0.2.0

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
