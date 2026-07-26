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

local MODULE = "Dragonfly_RoleEdit"

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

local function applyOverrideLocal(role, args)
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

local function findRole(name)
    local list = getRoles()
    for i=0,list:size()-1 do
        local r = list:get(i)
        if r:getName() == name then return r end
    end
    return nil
end

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
            applyOverrideLocal(self.role, args)
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
DFRoleEdit.applyOverrideLocal  = applyOverrideLocal
DFRoleEdit.findRole            = findRole
DFRoleEdit.getCapabilityByName = getCapabilityByName

local function onServerCommand(module, command, args)
    if module ~= MODULE or command ~= "applied" then return end
    applyOverrideLocal(findRole(args.roleName), args)
end

Events.OnGameStart.Add(applyPatches)
Events.OnServerCommand.Add(onServerCommand)

-- Dragonfly v0.2.0
