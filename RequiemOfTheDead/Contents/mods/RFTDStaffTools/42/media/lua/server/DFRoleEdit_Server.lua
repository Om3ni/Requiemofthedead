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

require "RDShared"       -- RDShared.textSafe sanitises the persisted record
require "DFRoleShared"   -- explicit: the client walks lua tiers alphabetically
                         -- across mods, so load order cannot be assumed (CLAUDE.md 4)

local MODULE = "Dragonfly_RoleEdit"
local OVERRIDES_FILE = "Dragonfly_RoleOverrides.txt"
local FIELD_DELIM = "\t"

-- capability / findRole / applyOverride live in shared/DFRoleShared.lua - the
-- client half of this bypass ran identical copies of all three.

-- Colour channels ride the wire as numbers and are written with %.4f. NaN fails
-- every comparison including against itself, which is the check below.
local function clamp01(v)
    local n = tonumber(v)
    if not n or n ~= n then return 1 end
    if n < 0 then return 0 end
    if n > 1 then return 1 end
    return n
end

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

    -- NEVER SELF (2026-08-19, maintainer's rule): only another admin may grant
    -- or remove a role's power. A holder of RolesWrite could previously strip
    -- RolesWrite from their own role, with no confirmation and no way back
    -- except hand-editing Dragonfly_RoleOverrides.txt on a live server.
    --
    -- Refused outright rather than warned. The cosmetic half of the same
    -- command - description and colour - goes with it, because the payload
    -- rebuilds the whole role in one shot and splitting it would mean applying
    -- half a request; the panel can say so plainly instead.
    --
    -- Comparison is by NAME against the caller's own role. getRole may be nil
    -- for an account with no role assigned, and a nil role cannot be the target
    -- of a self-edit, so that case simply falls through to the normal path.
    local own = player.getRole and player:getRole()
    if own and own:getName() == args.roleName then
        print(string.format("[Dragonfly] role self-edit refused: %s tried to edit their own role %s",
            tostring(player:getUsername()), tostring(args.roleName)))
        -- "saveRefused", NOT "applied". The client's "applied" handler feeds
        -- straight into applyOverride, which clears and rebuilds the capability
        -- set from the payload - so a refusal sent on that command would strip
        -- the very role it is protecting, on the requester's own client.
        sendServerCommand(player, MODULE, "saveRefused", {
            roleName = args.roleName,
            reason = "You cannot edit your own role. Another admin must make this change.",
        })
        return
    end

    -- NORMALISE ONCE, then use the normalised record everywhere: to mutate the
    -- live role, to persist, and to tell the clients. The handler used to pass
    -- `args` - raw wire data - to all three.
    --
    -- The persist is the sharp one. The override file is tab-delimited with one
    -- record per line (FIELD_DELIM above), and `description` was written
    -- verbatim: a tab in it shifts every later field, and a newline forges a
    -- complete extra role record that loadOverrides will happily apply at the
    -- next boot. So the description is escaped for control bytes AND for the
    -- field delimiter. Capability names need no such treatment - they are
    -- resolved against the real capability table, never echoed from the wire.
    --
    -- Colours are clamped because they are written with %.4f and read back with
    -- tonumber; a NaN or an out-of-range float round-trips into a Color the
    -- renderer has no sane answer for.
    local safe = {
        roleName     = args.roleName,
        description  = RDShared.textSafe(args.description or "", "\t"),
        r            = clamp01(args.r), g = clamp01(args.g), b = clamp01(args.b),
        capabilities = {},
    }
    if safe.description == "-" then safe.description = "" end
    for _, capName in ipairs(args.capabilities or {}) do
        if #safe.capabilities >= DFRoleShared.MAX_CAPABILITIES then break end
        if DFRoleShared.capability(capName) then
            safe.capabilities[#safe.capabilities + 1] = capName
        end
    end

    DFRoleShared.applyOverride(role, safe)

    local overrides = loadOverrides()
    overrides[args.roleName] = safe
    saveOverrides(overrides)

    -- Still a broadcast, deliberately. Every client applies this to its own role
    -- table (DFRoleEditorUnlock.lua:83-85) so names and colours render the same
    -- everywhere - role definitions are display data, not staff secrets. What
    -- changed is that the normalised record goes out instead of the raw one.
    sendServerCommand(MODULE, "applied", safe)
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
