-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFRoleEdit_Server - server-side counterpart to the role-editor unlock.
--
-- Two layers of vanilla persistence ignore mutations to read-only roles:
-- a) Role.addCapability / cleanCapability silently no-op when isReadOnly is
--    true, so the in-memory HashSet never changes through normal mutators.
-- b) ServerWorldDatabase.saveRole UPDATEs with `WHERE id = ? AND readonly = false`
--    and loadRoles skips description/color/capabilities for readonly rows.
--    Every boot, Roles.addStatic rebuilds them from hardcoded defaults.
--
-- (a) is bypassed by mutating role:getCapabilities() (the HashSet) directly --
-- the reference is unguarded. (b) is bypassed by maintaining our own override
-- file and re-applying after Roles.init has run.

if not isServer() then return end

require "DFRoleShared"   -- explicit: the client walks lua tiers alphabetically
                         -- across mods, so load order cannot be assumed (CLAUDE.md 4)

local MODULE = "Dragonfly_RoleEdit"
local OVERRIDES_FILE = "Dragonfly_RoleOverrides.txt"
local FIELD_DELIM = "\t"

-- capability / findRole / applyOverride live in shared/DFRoleShared.lua - the
-- client half of this bypass ran identical copies of all three.

local function split(s, sep)
    local out, i = {}, 1
    while true do
        local j = string.find(s, sep, i, true)
        if not j then out[#out+1] = s:sub(i); return out end
        out[#out+1] = s:sub(i, j-1)
        i = j + #sep
    end
end

local function loadOverrides()
    local result = {}
    -- Don't gate on fileExists(): during OnServerStarted on dedicated servers it
    -- can return false even when the file is on disk and getFileReader can open
    -- it (host cache-dir varies between sessions). Trust the reader instead.
    local reader = getFileReader(OVERRIDES_FILE, false)
    if not reader then return result end
    while true do
        local line = reader:readLine()
        if not line then break end
        if line ~= "" then
            local f = split(line, FIELD_DELIM)
            if f[1] and f[1] ~= "" then
                local r, g, b = string.match(f[2] or "", "([^,]+),([^,]+),([^,]+)")
                local caps = {}
                if f[3] then
                    for cap in string.gmatch(f[3], "[^,]+") do caps[#caps+1] = cap end
                end
                result[f[1]] = {
                    roleName = f[1],
                    r = tonumber(r) or 1, g = tonumber(g) or 1, b = tonumber(b) or 1,
                    description = f[4] or "",
                    capabilities = caps,
                }
            end
        end
    end
    reader:close()
    return result
end

local function saveOverrides(overrides)
    local writer = getFileWriter(OVERRIDES_FILE, true, false)
    if not writer then return end
    for name, o in pairs(overrides) do
        writer:write(name .. FIELD_DELIM
            .. string.format("%.4f,%.4f,%.4f", o.r or 1, o.g or 1, o.b or 1) .. FIELD_DELIM
            .. table.concat(o.capabilities or {}, ",") .. FIELD_DELIM
            .. (o.description or "") .. "\n")
    end
    writer:close()
end

local function applyAllOverrides()
    local overrides = loadOverrides()
    -- PZ B42 Kahlua VM doesn't expose `next` server-side; do the emptiness
    -- check by hand via pairs().
    local hasAny = false
    for _ in pairs(overrides) do hasAny = true; break end
    if not hasAny then return end
    for name, args in pairs(overrides) do
        DFRoleShared.applyOverride(DFRoleShared.findRole(name), args)
    end
end

local function onClientCommand(module, command, player, args)
    if module ~= MODULE or command ~= "save" then return end
    if not player or not args or not args.roleName then return end
    if not player:getRole():hasCapability(Capability.RolesWrite) then return end

    local role = DFRoleShared.findRole(args.roleName)
    if not role then return end
    DFRoleShared.applyOverride(role, args)

    local overrides = loadOverrides()
    overrides[args.roleName] = args
    saveOverrides(overrides)

    sendServerCommand(MODULE, "applied", args)
end

Events.OnClientCommand.Add(onClientCommand)
Events.OnServerStarted.Add(applyAllOverrides)

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
