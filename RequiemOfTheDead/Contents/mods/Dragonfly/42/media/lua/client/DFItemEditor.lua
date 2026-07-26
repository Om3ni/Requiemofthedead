-- DFItemEditor - replacement for vanilla's small fixed-size Item Editor.
--
-- Larger panel (no scroll for typical items), reflection-driven via the
-- DFItemProbes shared whitelist. The server snapshots a target's item via
-- playerInventoryItemSnapshot and replies PlayerInventoryItem; we render
-- one input row per readable field plus an action-button strip at top whose
-- buttons feature-detect against the item (Repair / Refill / Refresh / etc.).
--
-- On Save: collect all modified field values, ship via playerInventoryEdit.
-- Each action button ships via playerInventoryAction. Both re-request the
-- snapshot afterward so the editor reflects the new state.

if isServer() then return end

require "ISUI/ISCollapsableWindow"
require "ISUI/ISButton"
require "ISUI/ISTextEntryBox"
require "ISUI/ISTickBox"
require "ISUI/ISLabel"

local MODULE = "RFTDDragonfly"

DFItemEditor = DFItemEditor or {}

local OPEN = nil  -- single-instance: opening a new one closes the old

-- ─────────────────────────────────────────────────────────────────────────
-- Window class
-- ─────────────────────────────────────────────────────────────────────────

local Editor = ISCollapsableWindow:derive("DFItemEditor")

local PAD       = 8
local ROW_H     = 22
local LABEL_W   = 130
local INPUT_W   = 110
local COL_W     = LABEL_W + INPUT_W + PAD * 2
local GROUP_H   = 16
local TITLE_H   = 28
local ACTION_H  = 30
local FOOTER_H  = 36
local WIN_W     = COL_W * 2 + PAD * 3
local DIRTY_TINT = { 0.55, 0.80, 0.55 }
local CLEAN_TINT = { 0.85, 0.85, 0.85 }

function Editor:initialise()
    ISCollapsableWindow.initialise(self)
end

function Editor:createChildren()
    ISCollapsableWindow.createChildren(self)
end

function Editor:setItemSnapshot(snap)
    self.snapshot = snap   -- { fields, actions, username, slot, fullType }
    self.dirty   = {}      -- [label] = newValue (only changed entries)
    self.inputs  = {}      -- [label] = widget
    self.actionBtns = {}
    self:rebuildBody()
end

local function groupOf(field) return field.group or "Misc" end

local function fieldGroups(fields)
    -- Preserve probe order while bucketing by group.
    local groups, order = {}, {}
    for _, f in ipairs(fields or {}) do
        local g = groupOf(f)
        if not groups[g] then groups[g] = {}; order[#order + 1] = g end
        table.insert(groups[g], f)
    end
    return groups, order
end

local function mkLabel(parent, x, y, w, text, color)
    color = color or CLEAN_TINT
    local lbl = ISLabel:new(x, y + 4, 16, text,
        color[1], color[2], color[3], 1, UIFont.Small, true)
    lbl:initialise(); lbl:instantiate()
    parent:addChild(lbl)
    return lbl
end

function Editor:rebuildBody()
    -- Clear prior children except title-bar.
    if self.bodyChildren then
        for _, c in ipairs(self.bodyChildren) do
            self:removeChild(c)
        end
    end
    self.bodyChildren = {}
    self.inputs      = {}
    self.actionBtns  = {}

    if not self.snapshot then return end

    local snap = self.snapshot
    local cursorY = TITLE_H + PAD

    -- Header line: target + item type
    local hdr = ISLabel:new(PAD, cursorY, 16,
        string.format("Editing %s's %s (slot %d)",
            snap.username or "?", snap.fullType or "?", snap.slot or -1),
        0.85, 0.85, 0.95, 1, UIFont.Medium, true)
    hdr:initialise(); hdr:instantiate()
    self:addChild(hdr); self.bodyChildren[#self.bodyChildren + 1] = hdr
    cursorY = cursorY + 20 + PAD

    -- Action button strip
    if snap.actions and #snap.actions > 0 then
        local btnX = PAD
        for _, a in ipairs(snap.actions) do
            local b = ISButton:new(btnX, cursorY, 120, ACTION_H - 4,
                a.label, self, function() self:onAction(a.id) end)
            b.borderColor.a = 0.4
            b:initialise(); b:instantiate()
            self:addChild(b)
            self.bodyChildren[#self.bodyChildren + 1] = b
            self.actionBtns[#self.actionBtns + 1] = b
            btnX = btnX + 124
        end
        cursorY = cursorY + ACTION_H + PAD
    end

    -- Field grid: 2 columns, grouped headers
    local groups, order = fieldGroups(snap.fields)
    local colX = { PAD, PAD + COL_W + PAD }
    local colY = { cursorY, cursorY }
    local col  = 1

    for _, g in ipairs(order) do
        -- Group header in current column
        local hl = ISLabel:new(colX[col], colY[col], 16, "── " .. g .. " ──",
            0.55, 0.75, 0.95, 1, UIFont.Small, true)
        hl:initialise(); hl:instantiate()
        self:addChild(hl); self.bodyChildren[#self.bodyChildren + 1] = hl
        colY[col] = colY[col] + GROUP_H + 2

        for _, f in ipairs(groups[g]) do
            self:addFieldRow(colX[col], colY[col], f)
            colY[col] = colY[col] + ROW_H + 2
        end
        colY[col] = colY[col] + PAD
        -- Switch column when current one gets tallest
        if colY[1] > colY[2] then col = 2 elseif colY[2] > colY[1] then col = 1 end
    end

    local bodyBottom = math.max(colY[1], colY[2])
    self:setHeight(bodyBottom + FOOTER_H + PAD)

    -- Footer: Save / Refresh / Close
    local fy = self.height - FOOTER_H - PAD
    local saveBtn = ISButton:new(PAD, fy, 100, FOOTER_H - 8,
        "Save", self, function() self:onSave() end)
    saveBtn.borderColor = { r = 0.4, g = 0.7, b = 0.4, a = 1 }
    saveBtn:initialise(); saveBtn:instantiate()
    self:addChild(saveBtn); self.bodyChildren[#self.bodyChildren + 1] = saveBtn

    local refBtn = ISButton:new(PAD + 110, fy, 100, FOOTER_H - 8,
        "Refresh", self, function() self:requestSnapshot() end)
    refBtn.borderColor.a = 0.4
    refBtn:initialise(); refBtn:instantiate()
    self:addChild(refBtn); self.bodyChildren[#self.bodyChildren + 1] = refBtn

    local closeBtn = ISButton:new(self.width - PAD - 100, fy, 100, FOOTER_H - 8,
        "Close", self, function() self:close() end)
    closeBtn.borderColor = { r = 0.7, g = 0.4, b = 0.4, a = 1 }
    closeBtn:initialise(); closeBtn:instantiate()
    self:addChild(closeBtn); self.bodyChildren[#self.bodyChildren + 1] = closeBtn
end

function Editor:addFieldRow(x, y, field)
    local label = field.label
    mkLabel(self, x, y, LABEL_W, label .. ":",
        field.writable and CLEAN_TINT or { 0.6, 0.6, 0.6 })

    local inputX = x + LABEL_W + 4

    if field.kind == "bool" then
        local tick = ISTickBox:new(inputX, y + 2, 16, 16, "", self,
            function() self.dirty[label] = tick:isSelected(1) end)
        tick:initialise(); tick:instantiate()
        tick:addOption("")
        if field.value then tick:setSelected(1, true) end
        tick.enable = field.writable == true
        self:addChild(tick); self.bodyChildren[#self.bodyChildren + 1] = tick
        self.inputs[label] = tick
        return
    end

    local initial
    if field.kind == "number" then
        initial = string.format("%.3f", tonumber(field.value) or 0)
        initial = initial:gsub("0+$", ""):gsub("%.$", "")
    elseif field.kind == "int" then
        initial = tostring(math.floor(tonumber(field.value) or 0))
    else
        initial = tostring(field.value or "")
    end

    local entry = ISTextEntryBox:new(initial, inputX, y, INPUT_W, ROW_H - 4)
    entry.align  = "left"
    entry.valign = "middle"
    entry:initialise(); entry:instantiate()
    entry:setEditable(field.writable == true)
    -- Track edits: re-read on every prerender (cheap; the values are tiny).
    local original = initial
    entry.prerender = (function(orig)
        return function(self_)
            ISTextEntryBox.prerender(self_)
            local cur = self_:getText()
            if cur ~= original then
                self.dirty[label] = cur
                self_.backgroundColor = { r = 0.20, g = 0.30, b = 0.20, a = 1 }
            else
                self.dirty[label] = nil
                self_.backgroundColor = { r = 0.10, g = 0.10, b = 0.10, a = 1 }
            end
            orig(self_)
        end
    end)(function(_) end)  -- the wrapped original; we don't actually need to chain
    self:addChild(entry); self.bodyChildren[#self.bodyChildren + 1] = entry
    self.inputs[label] = entry
end

-- ─────────────────────────────────────────────────────────────────────────
-- Wire actions
-- ─────────────────────────────────────────────────────────────────────────

function Editor:requestSnapshot()
    if not self.target then return end
    sendClientCommand(getPlayer(), MODULE, "playerInventoryItemSnapshot",
        { username = self.target.username, slot = self.target.slot,
          fullType = self.target.fullType })
end

function Editor:onSave()
    if not self.target then return end
    local fields = {}
    local count = 0
    for label, val in pairs(self.dirty) do
        fields[label] = val
        count = count + 1
    end
    if count == 0 then
        if DFFeedback then DFFeedback.bad("No changes to save.") end
        return
    end
    sendClientCommand(getPlayer(), MODULE, "playerInventoryEdit",
        { username = self.target.username, slot = self.target.slot,
          fullType = self.target.fullType, fields = fields })
end

function Editor:onAction(actionId)
    if not self.target then return end
    sendClientCommand(getPlayer(), MODULE, "playerInventoryAction",
        { username = self.target.username, slot = self.target.slot,
          fullType = self.target.fullType, actionId = actionId })
end

function Editor:close()
    if OPEN == self then OPEN = nil end
    self:setVisible(false)
    self:removeFromUIManager()
end

-- ─────────────────────────────────────────────────────────────────────────
-- Public entry point
-- ─────────────────────────────────────────────────────────────────────────

function DFItemEditor.open(username, slot, fullType)
    if OPEN then OPEN:close() end
    local w = WIN_W
    local h = 300  -- resized in rebuildBody once snapshot arrives
    local x = (getCore():getScreenWidth() - w) / 2
    local y = (getCore():getScreenHeight() - h) / 2
    local ed = Editor:new(x, y, w, h)
    ed.title = "Item Editor"
    ed.resizable = false
    ed.target = { username = username, slot = slot, fullType = fullType }
    ed:initialise()
    ed:createChildren()
    ed:addToUIManager()
    OPEN = ed
    ed:requestSnapshot()
    return ed
end

-- Server reply handler
local function onServerCommand(module, command, args)
    if module ~= MODULE then return end
    if command == "PlayerInventoryItem" and args then
        if OPEN and OPEN.target
           and OPEN.target.username == args.username
           and OPEN.target.slot     == args.slot then
            OPEN:setItemSnapshot(args)
        end
    end
end
Events.OnServerCommand.Add(onServerCommand)

-- Dragonfly v0.2.0
