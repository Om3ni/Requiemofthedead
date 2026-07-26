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

local MODULE = "Dragonfly_RoleEdit"
local OVERRIDES_FILE = "Dragonfly_RoleOverrides.txt"
local FIELD_DELIM = "\t"

local capabilityByName
local function getCapabilityByName(name)
    if not capabilityByName then
        capabilityByName = {}
        local all = getCapabilities()
        for i=0,all:size()-1 do
            local c = all:get(i)
            capabilityByName[c:name()] = c
        end
    end
    return capabilityByName[name]
end

local function findRole(name)
    local list = getRoles()
    for i=0,list:size()-1 do
        local r = list:get(i)
        if r:getName() == name then return r end
    end
    return nil
end

local function applyOverride(role, args)
    if not role then return end
    role:setDescription(args.description or "")
    role:setColor(Color.new(args.r or 1, args.g or 1, args.b or 1, 1.0))
    local caps = role:getCapabilities()
    caps:clear()
    for _, capName in ipairs(args.capabilities or {}) do
        local cap = getCapabilityByName(capName)
        if cap then caps:add(cap) end
    end
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
        applyOverride(findRole(name), args)
    end
end

local function onClientCommand(module, command, player, args)
    if module ~= MODULE or command ~= "save" then return end
    if not player or not args or not args.roleName then return end
    if not player:getRole():hasCapability(Capability.RolesWrite) then return end

    local role = findRole(args.roleName)
    if not role then return end
    applyOverride(role, args)

    local overrides = loadOverrides()
    overrides[args.roleName] = args
    saveOverrides(overrides)

    sendServerCommand(MODULE, "applied", args)
end

Events.OnClientCommand.Add(onClientCommand)
Events.OnServerStarted.Add(applyAllOverrides)

-- Dragonfly v0.2.0
