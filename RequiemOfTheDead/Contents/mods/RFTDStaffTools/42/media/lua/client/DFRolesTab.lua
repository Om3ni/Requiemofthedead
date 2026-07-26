-- DFRolesTab - in-panel role editor.
--
-- Surfaces what Dragonfly's role-editor-unlock made possible (editing built-in
-- role capabilities) inside the Shift+U panel instead of via vanilla's
-- ISModalEditRole. Two-pane layout: roles list on the left, capability grid
-- and meta fields on the right. Save routes through DFRoleEdit_Server's
-- existing "save" handler which persists to Dragonfly_RoleOverrides.txt.
--
-- All edits are local-only until Save is clicked. The capability list shows
-- every Capability the engine knows about, ticked according to the role's
-- current state. Toggling a checkbox just updates the local model.

if isServer() then return end

require "ISUI/ISScrollingListBox"
require "ISUI/ISButton"
require "ISUI/ISTextEntryBox"
require "ISUI/ISLabel"

local FONT = UIFont.Small

local RolesTab = {
    roles          = {},     -- role name list
    selectedRole   = nil,    -- role name string
    capabilities   = {},     -- list of cap names (sorted)
    pendingCaps    = {},     -- [capName] = bool (current local state for selected role)
    pendingDesc    = "",
    pendingColor   = { r = 1, g = 1, b = 1 },
    rolesList      = nil,
    capsList       = nil,
    descEntry      = nil,
    rEntry         = nil,
    gEntry         = nil,
    bEntry         = nil,
    headerLabel    = nil,
}

-- ─────────────────────────────────────────────────────────────────────────
-- Data helpers
-- ─────────────────────────────────────────────────────────────────────────

-- Same pattern as the Players tab: getRoles() returns nil / empty on some
-- servers at tab-build time. Seed with vanilla defaults and add any extras
-- getRoles() reports on top, deduped.
local DEFAULT_ROLES = { "Admin", "Moderator", "GM", "Observer", "User" }

local function loadRoleList()
    local seen, out = {}, {}
    local function push(name)
        if name and name ~= "" and not seen[name] then
            seen[name] = true
            out[#out + 1] = name
        end
    end
    for _, n in ipairs(DEFAULT_ROLES) do push(n) end
    local ok, roles = pcall(getRoles)
    if ok and roles then
        for i = 0, roles:size() - 1 do
            local r = roles:get(i)
            if r then
                local n; pcall(function() n = r:getName() end)
                push(n)
            end
        end
    end
    table.sort(out)
    print("[Dragonfly] DFRolesTab roles available: " .. table.concat(out, ", "))
    return out
end

local function loadAllCapabilityNames()
    local out = {}
    local ok, caps = pcall(getCapabilities)
    if not ok or not caps then return out end
    for i = 0, caps:size() - 1 do
        local c = caps:get(i)
        if c then
            local n; pcall(function() n = c:name() end)
            if n then out[#out + 1] = n end
        end
    end
    table.sort(out)
    return out
end

local function findRoleByName(name)
    if DFRoleEdit and DFRoleEdit.findRole then return DFRoleEdit.findRole(name) end
    local list = getRoles()
    for i = 0, list:size() - 1 do
        local r = list:get(i)
        if r and r:getName() == name then return r end
    end
    return nil
end

local function readRoleState(roleName)
    -- Reset first so a failed lookup never leaves stale data from a previous
    -- selection. If we bail without doing this, the right pane keeps showing
    -- the last-good role's caps/color/description against a different name.
    RolesTab.pendingDesc  = ""
    RolesTab.pendingColor = { r = 1, g = 1, b = 1 }
    RolesTab.pendingCaps  = {}

    local role = findRoleByName(roleName)
    if not role then
        print("[Dragonfly] DFRolesTab readRoleState: no role for name=" .. tostring(roleName)
            .. " (getRoles() likely empty client-side; reopen panel after server settles)")
        return
    end
    -- Description
    local d; pcall(function() d = role:getDescription() end)
    RolesTab.pendingDesc = d or ""
    -- Color
    local col; pcall(function() col = role:getColor() end)
    if col then
        RolesTab.pendingColor = {
            r = col:getR() or 1, g = col:getG() or 1, b = col:getB() or 1 }
    end
    -- Capabilities: build a set of cap names currently on the role
    local caps; pcall(function() caps = role:getCapabilities() end)
    if caps then
        local it; pcall(function() it = caps:iterator() end)
        if it then
            while it:hasNext() do
                local c = it:next()
                if c then
                    local n; pcall(function() n = c:name() end)
                    if n then RolesTab.pendingCaps[n] = true end
                end
            end
        end
    end
    print(string.format(
        "[Dragonfly] DFRolesTab readRoleState: role=%s desc=%q color=%.2f,%.2f,%.2f caps=%d",
        roleName, RolesTab.pendingDesc,
        RolesTab.pendingColor.r, RolesTab.pendingColor.g, RolesTab.pendingColor.b,
        (function() local n=0; for _ in pairs(RolesTab.pendingCaps) do n=n+1 end return n end)()))
end

-- ─────────────────────────────────────────────────────────────────────────
-- Roles list (left pane)
-- ─────────────────────────────────────────────────────────────────────────

local RolesList = ISScrollingListBox:derive("DFRolesList")

function RolesList:doDrawItem(y, item, alt)
    local name = item.item
    if self.selected == item.index then
        self:drawRect(0, y, self.width, self.itemheight - 1, 0.35, 0.25, 0.55, 0.85)
    elseif alt then
        self:drawRect(0, y, self.width, self.itemheight - 1, 0.18, 0.08, 0.08, 0.08)
    end
    self:drawText(tostring(name or "?"), 8, y + 4,
        0.92, 0.92, 0.92, 1, FONT)
    return y + self.itemheight
end

function RolesList:onMouseDown(x, y)
    local idx = self:rowAt(x, y)
    if idx <= 0 then return end
    self.selected = idx
    local item = self.items[idx]
    if item and item.item then
        RolesTab.selectedRole = item.item
        readRoleState(item.item)
        RolesTab.refreshDetail()
    end
end

function RolesList:render()
    self:setStencilRect(0, 0, self.width, self.height)
    ISScrollingListBox.render(self)
    self:clearStencilRect()
end

-- ─────────────────────────────────────────────────────────────────────────
-- Capabilities list (right pane)
-- ─────────────────────────────────────────────────────────────────────────

local CapsList = ISScrollingListBox:derive("DFRolesCapsList")

function CapsList:doDrawItem(y, item, alt)
    local capName = item.item
    if alt then
        self:drawRect(0, y, self.width, self.itemheight - 1, 0.18, 0.08, 0.08, 0.08)
    end
    local on = RolesTab.pendingCaps[capName] == true
    -- Checkbox
    local boxX, boxY, boxW = 8, y + 4, 14
    self:drawRectBorder(boxX, boxY, boxW, boxW, 0.9, 0.6, 0.8, 0.8)
    if on then
        self:drawRect(boxX + 3, boxY + 3, boxW - 6, boxW - 6, 1, 0.5, 0.85, 0.5)
    end
    local textColor = on and { 0.95, 0.95, 0.95 } or { 0.6, 0.6, 0.6 }
    self:drawText(tostring(capName or "?"), boxX + boxW + 8, y + 4,
        textColor[1], textColor[2], textColor[3], 1, FONT)
    return y + self.itemheight
end

function CapsList:onMouseDown(x, y)
    local idx = self:rowAt(x, y)
    if idx <= 0 then return end
    local item = self.items[idx]
    if not item or not item.item then return end
    local capName = item.item
    RolesTab.pendingCaps[capName] = not (RolesTab.pendingCaps[capName] == true) or nil
end

function CapsList:render()
    self:setStencilRect(0, 0, self.width, self.height)
    ISScrollingListBox.render(self)
    self:clearStencilRect()
end

-- ─────────────────────────────────────────────────────────────────────────
-- Detail refresh + save
-- ─────────────────────────────────────────────────────────────────────────

function RolesTab.refreshDetail()
    if RolesTab.headerLabel then
        RolesTab.headerLabel:setName("Role: " .. tostring(RolesTab.selectedRole or "-"))
    end
    if RolesTab.descEntry then
        RolesTab.descEntry:setText(RolesTab.pendingDesc or "")
    end
    if RolesTab.rEntry then RolesTab.rEntry:setText(string.format("%.2f", RolesTab.pendingColor.r or 1)) end
    if RolesTab.gEntry then RolesTab.gEntry:setText(string.format("%.2f", RolesTab.pendingColor.g or 1)) end
    if RolesTab.bEntry then RolesTab.bEntry:setText(string.format("%.2f", RolesTab.pendingColor.b or 1)) end
    -- Caps list re-uses pendingCaps directly via doDrawItem; no rebuild needed.
end

local function onSave()
    if not RolesTab.selectedRole then
        if DFFeedback then DFFeedback.bad("Select a role first.") end
        return
    end
    if not RDAccess.roleHas(getPlayer(), Capability.RolesWrite) then
        if DFFeedback then DFFeedback.bad("Missing capability: RolesWrite.") end
        return
    end
    local capList = {}
    for name, on in pairs(RolesTab.pendingCaps) do
        if on then capList[#capList + 1] = name end
    end
    table.sort(capList)
    local args = {
        roleName    = RolesTab.selectedRole,
        description = RolesTab.descEntry and RolesTab.descEntry:getText() or "",
        r = tonumber(RolesTab.rEntry and RolesTab.rEntry:getText()) or 1,
        g = tonumber(RolesTab.gEntry and RolesTab.gEntry:getText()) or 1,
        b = tonumber(RolesTab.bEntry and RolesTab.bEntry:getText()) or 1,
        capabilities = capList,
    }
    -- Apply locally first so the UI sees the change immediately. Server
    -- broadcasts an "applied" event that other admins consume the same way.
    if DFRoleEdit and DFRoleEdit.applyOverrideLocal then
        DFRoleEdit.applyOverrideLocal(findRoleByName(args.roleName), args)
    end
    sendClientCommand(getPlayer(),
        DFRoleEdit and DFRoleEdit.MODULE or "Dragonfly_RoleEdit",
        "save", args)
    if DFFeedback then
        DFFeedback.good(string.format("Saved role: %s (%d caps).",
            args.roleName, #capList))
    end
end

-- ─────────────────────────────────────────────────────────────────────────
-- Build
-- ─────────────────────────────────────────────────────────────────────────

local function build(spec, panel, x, y, w, h)
    RolesTab.roles        = loadRoleList()
    RolesTab.capabilities = loadAllCapabilityNames()
    RolesTab.selectedRole = nil
    RolesTab.pendingCaps  = {}
    RolesTab.pendingDesc  = ""
    RolesTab.pendingColor = { r = 1, g = 1, b = 1 }

    local PAD       = 8
    local BTN_H     = 24
    local LEFT_W    = 180
    local FOOTER_H  = BTN_H + PAD * 2

    -- LEFT: roles list
    local rolesList = RolesList:new(PAD, PAD, LEFT_W, h - PAD * 2)
    rolesList.itemheight = 22
    rolesList.drawBorder = true
    rolesList:initialise(); rolesList:instantiate()
    panel:addChild(rolesList)
    RolesTab.rolesList = rolesList
    for _, name in ipairs(RolesTab.roles) do rolesList:addItem("", name) end

    -- RIGHT: detail pane
    local rx = PAD * 2 + LEFT_W
    local rw = w - rx - PAD
    local cursorY = PAD

    -- Header
    local hdr = ISLabel:new(rx, cursorY, 16, "Role: -",
        0.85, 0.85, 0.95, 1, UIFont.Medium, true)
    hdr:initialise(); hdr:instantiate()
    panel:addChild(hdr)
    RolesTab.headerLabel = hdr
    cursorY = cursorY + 22

    -- Description. Entry x sits a bit right of the label so the "Description:"
    -- text doesn't crowd the box - 10px of breathing room.
    local LABEL_GAP = 10
    local dlbl = ISLabel:new(rx, cursorY + 4, 16, "Description:",
        0.85, 0.85, 0.85, 1, UIFont.Small, true)
    dlbl:initialise(); dlbl:instantiate()
    panel:addChild(dlbl)
    local descEntryX = rx + 92 + LABEL_GAP
    local descEntry = ISTextEntryBox:new("", descEntryX, cursorY, rw - (descEntryX - rx), BTN_H)
    descEntry.align = "left"
    descEntry:initialise(); descEntry:instantiate()
    panel:addChild(descEntry)
    RolesTab.descEntry = descEntry
    cursorY = cursorY + BTN_H + PAD

    -- Color R/G/B. Same 10px gap between each letter label and its entry.
    local clbl = ISLabel:new(rx, cursorY + 4, 16, "Color:",
        0.85, 0.85, 0.85, 1, UIFont.Small, true)
    clbl:initialise(); clbl:instantiate()
    panel:addChild(clbl)
    local function mkColorEntry(label, ex)
        local l = ISLabel:new(ex, cursorY + 4, 16, label,
            0.85, 0.85, 0.85, 1, UIFont.Small, true)
        l:initialise(); l:instantiate()
        panel:addChild(l)
        local e = ISTextEntryBox:new("1.00", ex + 14 + LABEL_GAP, cursorY, 50, BTN_H)
        e.align = "center"
        e:initialise(); e:instantiate()
        panel:addChild(e)
        return e
    end
    RolesTab.rEntry = mkColorEntry("R", rx + 60)
    RolesTab.gEntry = mkColorEntry("G", rx + 130)
    RolesTab.bEntry = mkColorEntry("B", rx + 200)
    cursorY = cursorY + BTN_H + PAD

    -- Capabilities header
    local caplbl = ISLabel:new(rx, cursorY, 16, "Capabilities:",
        0.55, 0.75, 0.95, 1, UIFont.Small, true)
    caplbl:initialise(); caplbl:instantiate()
    panel:addChild(caplbl)
    cursorY = cursorY + 18

    -- Capabilities list
    local capsH = h - cursorY - FOOTER_H - PAD
    local capsList = CapsList:new(rx, cursorY, rw, capsH)
    capsList.itemheight = 22
    capsList.drawBorder = true
    capsList:initialise(); capsList:instantiate()
    panel:addChild(capsList)
    RolesTab.capsList = capsList
    for _, capName in ipairs(RolesTab.capabilities) do capsList:addItem("", capName) end

    -- Footer: Save button
    local fy = h - FOOTER_H + PAD / 2
    local saveBtn = ISButton:new(rx, fy, 140, BTN_H, "Save Role",
        panel, onSave)
    saveBtn.borderColor = { r = 0.4, g = 0.7, b = 0.4, a = 1 }
    saveBtn:initialise(); saveBtn:instantiate()
    panel:addChild(saveBtn)

    -- Auto-select the first role so the right pane shows real data on tab
    -- open. Without this the admin sees a blank "Role: -" and has to click
    -- before anything populates, which reads as "the panel doesn't work".
    if #RolesTab.roles > 0 then
        local first = RolesTab.roles[1]
        rolesList.selected      = 1
        RolesTab.selectedRole   = first
        readRoleState(first)
    end

    RolesTab.refreshDetail()
end

print("[Dragonfly] DFRolesTab body loaded; deferring registration to OnGameStart")

Events.OnGameStart.Add(function()
    if not DFRegistry then return end
    local ok, err = pcall(function()
        DFRegistry.registerTab{
            id         = "roles",
            label      = "Roles",
            order      = 25,
            capability = Capability.RolesWrite,
            build      = build,
        }
    end)
    if not ok then
        print("[Dragonfly] DFRolesTab registerTab error: " .. tostring(err))
    end
end)

-- Dragonfly v0.2.0
