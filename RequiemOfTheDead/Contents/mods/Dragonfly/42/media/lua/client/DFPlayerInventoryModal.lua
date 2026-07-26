-- DFPlayerInventoryModal - replacement for vanilla ISPlayerStatsManageInvUI.
--
-- Same purpose (browse another player's inventory) but with the layout fixed
-- and admin verbs added. Columns no longer bleed; the Variables column is
-- replaced by an "Edit selected" button that opens DFItemEditor with the
-- selected row.
--
-- Selection-driven actions: Edit / Remove operate on the selected row.
-- Add / Refresh / Dump are independent. Dump goes through DFConfirm because
-- erasing someone else's stash is intentional disruption.

if isServer() then return end

require "ISUI/ISCollapsableWindow"
require "ISUI/ISScrollingListBox"
require "ISUI/ISButton"
require "ISUI/ISTextEntryBox"
require "ISUI/ISLabel"

local MODULE = "RFTDDragonfly"
local FONT   = UIFont.Code

DFPlayerInventoryModal = DFPlayerInventoryModal or {}

local OPEN = nil

-- ─────────────────────────────────────────────────────────────────────────
-- Column spec
-- ─────────────────────────────────────────────────────────────────────────

local COLS = {
    { key = "name",     label = "Name",     w = 240, align = "left" },
    { key = "count",    label = "Count",    w = 50,  align = "center" },
    { key = "kind",     label = "Type",     w = 110, align = "left" },
    { key = "fullType", label = "Full Type", w = 240, align = "left" },
    { key = "cond",     label = "Condition", w = 90, align = "right",
      format = function(r)
          if not r.cond then return "-" end
          if r.condMax then return string.format("%d / %d", r.cond, r.condMax) end
          return tostring(r.cond)
      end },
}

-- ─────────────────────────────────────────────────────────────────────────
-- List widget
-- ─────────────────────────────────────────────────────────────────────────

local InvList = ISScrollingListBox:derive("DFInvList")

function InvList:doDrawItem(y, item, alt)
    local row = item.item
    if not row then return y + self.itemheight end
    if self.selected == item.index then
        self:drawRect(0, y, self.width, self.itemheight - 1, 0.35, 0.25, 0.55, 0.85)
    elseif alt then
        self:drawRect(0, y, self.width, self.itemheight - 1, 0.18, 0.08, 0.08, 0.08)
    end
    self:drawRectBorder(0, y, self.width, self.itemheight, 0.12, 1, 1, 1)
    DFColumns.drawRow(self, COLS, row, 4, y, FONT, { 0.92, 0.92, 0.92 }, 4, self.itemheight)
    return y + self.itemheight
end

function InvList:onMouseDown(x, y)
    local idx = self:rowAt(x, y)
    if idx <= 0 then return end
    self.selected = idx
end

function InvList:onMouseDoubleClick(x, y)
    local idx = self:rowAt(x, y)
    if idx <= 0 then return end
    self.selected = idx
    if self.onEditSelected then self.onEditSelected() end
end

function InvList:render()
    self:setStencilRect(0, 0, self.width, self.height)
    ISScrollingListBox.render(self)
    self:clearStencilRect()
end

-- ─────────────────────────────────────────────────────────────────────────
-- Modal class
-- ─────────────────────────────────────────────────────────────────────────

local Modal = ISCollapsableWindow:derive("DFPlayerInventoryModal")

function Modal:createChildren()
    ISCollapsableWindow.createChildren(self)

    local PAD   = 8
    local BTN_H = 24
    local TITLE_H = 28
    local cursorY = TITLE_H + PAD

    -- Action row 1: Add by full type + Refresh
    self.addEntry = ISTextEntryBox:new("Base.Bandage", PAD, cursorY, 220, BTN_H)
    self.addEntry.align = "left"
    self.addEntry:initialise(); self.addEntry:instantiate()
    self:addChild(self.addEntry)

    self.addCountEntry = ISTextEntryBox:new("1", PAD + 224, cursorY, 50, BTN_H)
    self.addCountEntry.align = "center"
    self.addCountEntry:initialise(); self.addCountEntry:instantiate()
    self:addChild(self.addCountEntry)

    local addBtn = ISButton:new(PAD + 278, cursorY, 90, BTN_H, "Add Item",
        self, function() self:onAdd() end)
    addBtn.borderColor.a = 0.4
    addBtn:initialise(); addBtn:instantiate()
    self:addChild(addBtn)

    local refreshBtn = ISButton:new(PAD + 372, cursorY, 90, BTN_H, "Refresh",
        self, function() self:requestSnapshot() end)
    refreshBtn.borderColor.a = 0.4
    refreshBtn:initialise(); refreshBtn:instantiate()
    self:addChild(refreshBtn)

    -- Right-side: weight label
    self.weightLabel = ISLabel:new(self.width - PAD - 140, cursorY + 4, 16,
        "Weight: -", 0.75, 0.85, 0.95, 1, UIFont.Small, true)
    self.weightLabel:initialise(); self.weightLabel:instantiate()
    self:addChild(self.weightLabel)

    cursorY = cursorY + BTN_H + PAD

    -- Column header (drawn via prerender attach below)
    self.headerY = cursorY
    self:attachHeader()
    cursorY = cursorY + 20

    -- Inventory list
    local FOOTER_H = BTN_H + PAD * 2
    local listH = self.height - cursorY - FOOTER_H - PAD
    self.list = InvList:new(PAD, cursorY, self.width - PAD * 2, listH)
    self.list.itemheight = 22
    self.list.drawBorder = true
    self.list.onEditSelected = function() self:onEdit() end
    self.list:initialise(); self.list:instantiate()
    self:addChild(self.list)
    cursorY = cursorY + listH + PAD

    -- Footer buttons: Edit | Repair All | Remove | Dump | Close
    local editBtn = ISButton:new(PAD, cursorY, 110, BTN_H, "Edit Selected",
        self, function() self:onEdit() end)
    editBtn.borderColor = { r = 0.4, g = 0.7, b = 0.7, a = 1 }
    editBtn:initialise(); editBtn:instantiate()
    self:addChild(editBtn)

    local repairAllBtn = ISButton:new(PAD + 120, cursorY, 100, BTN_H, "Repair All",
        self, function() self:onRepairAll() end)
    repairAllBtn.borderColor = { r = 0.4, g = 0.7, b = 0.4, a = 1 }
    repairAllBtn:initialise(); repairAllBtn:instantiate()
    self:addChild(repairAllBtn)

    local removeBtn = ISButton:new(PAD + 230, cursorY, 120, BTN_H, "Remove Selected",
        self, function() self:onRemove() end)
    removeBtn.borderColor = { r = 0.7, g = 0.4, b = 0.4, a = 1 }
    removeBtn:initialise(); removeBtn:instantiate()
    self:addChild(removeBtn)

    local dumpBtn = ISButton:new(PAD + 360, cursorY, 100, BTN_H, "Dump All",
        self, function() self:onDump() end)
    dumpBtn.borderColor = { r = 0.7, g = 0.4, b = 0.4, a = 1 }
    dumpBtn:initialise(); dumpBtn:instantiate()
    self:addChild(dumpBtn)

    local closeBtn = ISButton:new(self.width - PAD - 90, cursorY, 90, BTN_H,
        "Close", self, function() self:close() end)
    closeBtn.borderColor.a = 0.4
    closeBtn:initialise(); closeBtn:instantiate()
    self:addChild(closeBtn)
end

function Modal:attachHeader()
    local hy = self.headerY
    local origPrerender = self.prerender
    self.prerender = function(self_)
        if origPrerender then origPrerender(self_) end
        DFColumns.drawHeader(self_, COLS, 8, hy, FONT)
    end
end

-- ─────────────────────────────────────────────────────────────────────────
-- Data
-- ─────────────────────────────────────────────────────────────────────────

function Modal:setRows(rows)
    self.rows = rows or {}
    if not self.list then return end
    self.list:clear()
    for _, r in ipairs(self.rows) do
        self.list:addItem("", r)
    end
    -- Weight: sum of item.weight if present, otherwise just count
    self.weightLabel:setName(string.format("Items: %d", #self.rows))
end

function Modal:requestSnapshot()
    sendClientCommand(getPlayer(), MODULE, "playerInventorySnapshot",
        { username = self.target })
end

function Modal:selectedRow()
    if not self.list or not self.list.selected then return nil end
    local idx = self.list.selected
    if idx <= 0 or idx > #(self.rows or {}) then return nil end
    return self.rows[idx]
end

-- ─────────────────────────────────────────────────────────────────────────
-- Actions
-- ─────────────────────────────────────────────────────────────────────────

function Modal:onAdd()
    local ft = self.addEntry and self.addEntry:getText() or ""
    if ft == "" then
        if DFFeedback then DFFeedback.bad("Enter a full type (Base.X).") end
        return
    end
    local count = tonumber(self.addCountEntry and self.addCountEntry:getText() or "1") or 1
    sendClientCommand(getPlayer(), MODULE, "playerInventoryAdd",
        { username = self.target, fullType = ft, count = count })
end

function Modal:onEdit()
    local row = self:selectedRow()
    if not row then
        if DFFeedback then DFFeedback.bad("Select an item first.") end
        return
    end
    if not DFItemEditor then
        if DFFeedback then DFFeedback.bad("DFItemEditor not loaded.") end
        return
    end
    DFItemEditor.open(self.target, row.slot, row.fullType)
end

function Modal:onRemove()
    local row = self:selectedRow()
    if not row then
        if DFFeedback then DFFeedback.bad("Select an item first.") end
        return
    end
    sendClientCommand(getPlayer(), MODULE, "playerInventoryRemove",
        { username = self.target, slot = row.slot, fullType = row.fullType })
end

function Modal:onDump()
    local label = string.format(
        "Dump every item in %s's inventory. This cannot be undone.", self.target)
    local function send()
        sendClientCommand(getPlayer(), MODULE, "playerInventoryDump",
            { username = self.target })
    end
    if DFConfirm then DFConfirm.askIfOthersOnline(label, send) else send() end
end

-- Repair-all: server walks main inventory + worn + bag contents and runs the
-- per-item Repair action on anything with getCondition. Non-disruptive
-- (purely beneficial to the target) so no DFConfirm wrap.
function Modal:onRepairAll()
    sendClientCommand(getPlayer(), MODULE, "playerInventoryRepairAll",
        { username = self.target })
end

function Modal:close()
    if OPEN == self then OPEN = nil end
    self:setVisible(false)
    self:removeFromUIManager()
end

-- ─────────────────────────────────────────────────────────────────────────
-- Public entry + server reply routing
-- ─────────────────────────────────────────────────────────────────────────

function DFPlayerInventoryModal.open(username)
    if OPEN then OPEN:close() end
    local w = 820
    local h = 540
    local x = (getCore():getScreenWidth() - w) / 2
    local y = (getCore():getScreenHeight() - h) / 2
    local m = Modal:new(x, y, w, h)
    m.title  = "Manage " .. tostring(username) .. "'s Inventory"
    m.target = username
    m.rows   = {}
    m.resizable = true
    m:initialise()
    m:createChildren()
    m:addToUIManager()
    OPEN = m
    m:requestSnapshot()
    return m
end

local function onServerCommand(module, command, args)
    if module ~= MODULE then return end
    if command == "PlayerInventory" and args then
        if OPEN and OPEN.target == args.username then
            OPEN:setRows(args.items or {})
        end
    elseif (command == "Result") and args and args.action and OPEN then
        -- After any inventory-mutating action, re-request the snapshot so the
        -- list stays in sync. Result feedback is handled by DFFeedback already.
        local refreshOnSuccess = {
            playerInventoryAdd = true, playerInventoryRemove = true,
            playerInventoryDump = true, playerInventoryEdit = true,
            playerInventoryAction = true, playerInventoryRepairAll = true,
        }
        if args.ok and refreshOnSuccess[args.action] then
            OPEN:requestSnapshot()
        end
    end
end
Events.OnServerCommand.Add(onServerCommand)

-- Dragonfly v0.2.0
