-- SPDX-License-Identifier: GPL-3.0-or-later
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
    { key = "name",     label = "Name",      w = 220, align = "left" },
    { key = "count",    label = "Count",     w = 45,  align = "center" },
    { key = "kind",     label = "Type",      w = 105, align = "left" },
    { key = "location", label = "Location",  w = 120, align = "left" },
    { key = "fullType", label = "Full Type", w = 210, align = "left" },
    { key = "cond",     label = "Condition", w = 85, align = "right",
      format = function(r)
          if not r.cond then return "-" end
          if r.condMax then return string.format("%d / %d", r.cond, r.condMax) end
          return tostring(r.cond)
      end },
}

-- Sort order WITHIN a category group. Ranked rather than alphabetical so the gear
-- a player is actually using floats to the top of its group: hands, then hotbar,
-- then worn, then loose, then buried in a bag.
local LOCATION_RANK = { Primary = 1, Secondary = 2, Main = 5 }

local function locationRank(loc)
    loc = tostring(loc or "")
    local fixed = LOCATION_RANK[loc]
    if fixed then return fixed end
    if loc:match("^Hotbar") then return 3 end
    if loc:match("^in ")    then return 6 end
    return 4   -- a worn body location
end

-- Which category groups are folded shut. Module-level, not per-modal, so an
-- admin who always collapses Materials does not have to redo it every time they
-- open someone's inventory. Deliberately not persisted to disk - it is a view
-- preference for the current session, not configuration.
local COLLAPSED = {}

-- ─────────────────────────────────────────────────────────────────────────
-- List widget
-- ─────────────────────────────────────────────────────────────────────────

local InvList = ISScrollingListBox:derive("DFInvList")

function InvList:doDrawItem(y, item, alt)
    local row = item.item
    if not row then return y + self.itemheight end

    -- Group header. Headers sit in the SAME list as data rows so that list indices
    -- and Modal.rows indices stay aligned - the slot-addressing scheme depends on
    -- that. They are simply drawn as a band and refuse selection.
    if row.header then
        local hot = self:isMouseOver() and self.mouseoverselected == item.index
        self:drawRect(0, y, self.width, self.itemheight - 1,
            hot and 0.70 or 0.55, 0.16, 0.13, 0.24)
        self:drawRectBorder(0, y, self.width, self.itemheight, 0.30, 0.55, 0.60, 0.85)
        DFColumns.drawInBox(self,
            string.format("%s %s  (%d)",
                row.collapsed and "+" or "-", tostring(row.header), row.count or 0),
            6, y, self.width - 12, self.itemheight,
            FONT, { 0.80, 0.86, 0.99, 1 }, "left", "middle")
        return y + self.itemheight
    end

    if self.selected == item.index then
        self:drawRect(0, y, self.width, self.itemheight - 1, 0.35, 0.25, 0.55, 0.85)
    elseif alt then
        self:drawRect(0, y, self.width, self.itemheight - 1, 0.18, 0.08, 0.08, 0.08)
    end
    self:drawRectBorder(0, y, self.width, self.itemheight, 0.12, 1, 1, 1)
    DFColumns.drawRow(self, COLS, row, 4, y, FONT, { 0.92, 0.92, 0.92 }, 4, self.itemheight)
    return y + self.itemheight
end

-- Headers carry no slot, so letting the selection land on one would leave Edit and
-- Remove firing against nothing. Refuse the click outright rather than clearing,
-- so a mis-click on a header leaves the previous selection intact.
function InvList:isHeaderAt(idx)
    local entry = self.items and self.items[idx]
    local row = entry and entry.item
    return row ~= nil and row.header ~= nil
end

function InvList:onMouseDown(x, y)
    local idx = self:rowAt(x, y)
    if idx <= 0 then return end
    if self:isHeaderAt(idx) then
        -- Clicking a header folds its group rather than selecting it.
        local row = self.items[idx].item
        if self.onToggleGroup then self.onToggleGroup(row.header) end
        return
    end
    self.selected = idx
end

function InvList:onMouseDoubleClick(x, y)
    local idx = self:rowAt(x, y)
    if idx <= 0 or self:isHeaderAt(idx) then return end
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
    self.list.onToggleGroup  = function(bucket) self:toggleGroup(bucket) end
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

-- Build the display list: category group headers interleaved with their rows.
--
-- Headers go into self.rows alongside the data rows so that a list index and a
-- self.rows index are the same number, which is what selectedRow relies on. The
-- `slot` used to address an item on the wire travels on the row itself, so
-- regrouping never disturbs it.
function Modal:setRows(rows)
    self.rawRows = rows or {}
    self:rebuild()
end

-- Toggle one category group open/shut. Rebuilds from the cached snapshot rather
-- than asking the server again - folding a header is a view change, not a data one.
function Modal:toggleGroup(bucket)
    if not bucket then return end
    COLLAPSED[bucket] = (not COLLAPSED[bucket]) or nil
    self:rebuild()
end

-- Group, sort and fold the cached snapshot into the display list.
function Modal:rebuild()
    -- Capture the selection by identity before rebuilding. Every mutating action
    -- re-requests the snapshot, and grouping means indices move, so an
    -- index-preserving refresh would silently point at a different item.
    local prev = self:selectedRow()
    local keepSlot = prev and prev.slot or nil

    local byBucket, seenBuckets = {}, {}
    for _, r in ipairs(self.rawRows or {}) do
        local b = r.bucket or RDItemKind.FALLBACK
        local list = byBucket[b]
        if not list then
            list = {}
            byBucket[b] = list
            seenBuckets[#seenBuckets + 1] = b
        end
        list[#list + 1] = r
    end

    -- RDItemKind.BUCKETS is the on-screen order. Anything with a bucket not in
    -- that list still gets rendered afterwards - dropping a row silently is worse
    -- than showing it in an unexpected place.
    local order = {}
    local emitted = {}
    for _, b in ipairs(RDItemKind.BUCKETS) do
        order[#order + 1] = b
        emitted[b] = true
    end
    for _, b in ipairs(seenBuckets) do
        if not emitted[b] then order[#order + 1] = b end
    end

    self.rows = {}
    self.itemCount = 0
    for _, bucket in ipairs(order) do
        local list = byBucket[bucket]
        if list and #list > 0 then
            table.sort(list, function(a, b)
                local ra, rb = locationRank(a.location), locationRank(b.location)
                if ra ~= rb then return ra < rb end
                local la, lb = tostring(a.location or ""), tostring(b.location or "")
                if la ~= lb then return la < lb end
                return tostring(a.name or "") < tostring(b.name or "")
            end)
            -- The header always renders and always reports the full count, so a
            -- folded group still tells you how much is hidden in it.
            local folded = COLLAPSED[bucket] == true
            self.rows[#self.rows + 1] =
                { header = bucket, count = #list, collapsed = folded }
            self.itemCount = self.itemCount + #list
            if not folded then
                for _, r in ipairs(list) do
                    self.rows[#self.rows + 1] = r
                end
            end
        end
    end

    if not self.list then return end
    -- DFKit.refillList: a bare clear() leaves the scroll height behind and
    -- addItem stacks onto it, which eventually scrolls the list off its own
    -- rows. See that function's header.
    DFKit.refillList(self.list, function(box)
        for _, r in ipairs(self.rows) do
            box:addItem("", r)
        end
    end)

    -- Restore the selection, or drop it if that item is gone (removed, or moved
    -- out of the walk). Never leave it pointing at whatever now occupies the index.
    --
    -- -1, NOT nil. ISScrollingListBox:prerender guards with
    --     if self.selected ~= -1 and self.selected > #self.items
    -- so a nil here passes the first test and then throws "__lt not defined for
    -- operand" on the comparison, taking the whole list render down. -1 is the
    -- widget's own sentinel for "nothing selected", and selectedRow's existing
    -- `idx <= 0` guard already treats it as no selection.
    self.list.selected = -1
    if keepSlot ~= nil then
        for i, r in ipairs(self.rows) do
            if not r.header and r.slot == keepSlot then
                self.list.selected = i
                break
            end
        end
    end

    self.weightLabel:setName(string.format("Items: %d", self.itemCount))
end

function Modal:requestSnapshot()
    sendClientCommand(getPlayer(), MODULE, "playerInventorySnapshot",
        { username = self.target })
end

function Modal:selectedRow()
    if not self.list or not self.list.selected then return nil end
    local idx = self.list.selected
    if idx <= 0 or idx > #(self.rows or {}) then return nil end
    local row = self.rows[idx]
    -- A group header is not an item. Returning one would hand Edit / Remove a row
    -- with no slot and no fullType.
    if not row or row.header then return nil end
    return row
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
    -- Wider than the old 820: the Location column is new and the previous width
    -- already had the columns nearly touching the frame.
    local w = 900
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

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
