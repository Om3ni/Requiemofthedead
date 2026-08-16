-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFRoleShared - the role-editor bypass, in one place instead of three.
--
-- WHY THIS FILE EXISTS. The unlock is a client/server pair by nature: the
-- client mutates the live Role so the admin sees the edit immediately, and the
-- server does the same mutation and persists it. Both therefore need the same
-- three primitives, and both grew their own copy of all three -
-- DFRoleEditorUnlock.lua and DFRoleEdit_Server.lua, plus a third findRole in
-- DFPlayerRoles_Server.lua.
--
-- Three copies of a CAPABILITY check is the kind of duplication that does not
-- announce the day it starts disagreeing, and it already had: the copy in
-- DFPlayerRoles_Server wrapped getRoles in a pcall while the other two called
-- it bare. Settled against the decompile - getRoles (LuaManager:3109) is
-- Roles.getRoles():89, `return roles`, and that field is
-- `private static final ArrayList<Role> roles = new ArrayList()` (Roles:25).
-- Never null, never throws. The bare call was right; the guard was cargo.
--
-- The bypass itself is documented where it is used - see DFRoleEditorUnlock's
-- header for the two vanilla read-only guards this defeats and why mutating
-- the HashSet reference works where the vanilla mutators no-op.
--
-- Loads on BOTH sides on purpose: no isServer/isClient gate here, because the
-- point is that the two sides run identical logic. Consumers require it by
-- name; the client's alphabetical cross-mod walk makes that mandatory rather
-- than polite (see CLAUDE.md 4).

DFRoleShared = DFRoleShared or {}

-- Built once. Capability.values() is a fixed enum, so the map cannot go stale
-- within a session.
local capabilityByName

function DFRoleShared.capability(name)
    if not capabilityByName then
        capabilityByName = {}
        -- getCapabilities (LuaManager:3114) builds a fresh ArrayList from
        -- Capability.values() every call - hence caching it here.
        local all = getCapabilities()
        for i = 0, all:size() - 1 do
            local c = all:get(i)
            capabilityByName[c:name()] = c
        end
    end
    return capabilityByName[name]
end

function DFRoleShared.findRole(name)
    local list = getRoles()
    for i = 0, list:size() - 1 do
        local r = list:get(i)
        if r and r:getName() == name then return r end
    end
    return nil
end

-- Mutates the live Role. setDescription and setColor are unguarded by vanilla,
-- and getCapabilities() hands back the underlying HashSet by reference, so
-- clear/add on it bypass the isReadOnly checks that make addCapability a no-op.
function DFRoleShared.applyOverride(role, args)
    if not role then return end
    role:setDescription(args.description or "")
    role:setColor(Color.new(args.r or 1, args.g or 1, args.b or 1, 1.0))
    local caps = role:getCapabilities()
    caps:clear()
    for _, capName in ipairs(args.capabilities or {}) do
        local cap = DFRoleShared.capability(capName)
        if cap then caps:add(cap) end
    end
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
