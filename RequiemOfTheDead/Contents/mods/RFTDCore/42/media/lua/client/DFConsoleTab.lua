-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFConsoleTab - the Console tab, registered through DFRegistry (client only).
--
-- MOVED TO CORE 2026-08-08, from Dragonfly. Every part of this surface's data
-- layer already lived here - DFLog, DFErrorPoller, DFTripwire, RDCmdConsole,
-- DFKit, DFRegistry - and only the view was a mod away from all of it. Error
-- capture is infrastructure: anything that can throw wants it, and no mod should
-- need the admin panel installed for its errors to be caught. Dragonfly remains
-- what it was, the glass this renders through.
--
-- ===========================================================================
-- A LIST OF LINES BECAME A LIST OF EVENTS WITH A DETAIL PANE, and that is the
-- whole point of the rework.
--
-- The old tab drew one 18px row per DFLog entry and nothing else. Since a stack
-- trace arrived pre-flattened to a single truncated string (see DFErrorPoller's
-- header for why it was flattened and why it no longer is), a trace was
-- unreadable by construction - there was nowhere for it to be readable.
--
-- errorMagnifier solves this with fat 100px rows that draw the first five or six
-- lines of the trace and clip the rest. We deliberately did NOT copy that:
--
--   * It still clips. A real trace is far longer than six lines, so the fat row
--     trades "unreadable because truncated to one line" for "unreadable because
--     truncated to six" - and the second is worse, because it LOOKS complete.
--   * Variable-height rows fight ISScrollingListBox, which computes its scroll
--     height as itemheight x count and resolves clicks by dividing by itemheight.
--     A uniform tall row wastes most of the list on one-line entries.
--
-- A detail pane has neither problem: rows stay one line and scannable, the
-- selected event renders in full with its own scrollbar, and the trace reads the
-- way it reads in the log file - which is what was asked for.
-- ===========================================================================
--
-- REBUILDS ARE COALESCED INTO prerender, which fixes a real cost the old tab
-- carried. It subscribed a listener that called a full DFLog.snapshot plus a
-- full list refill on EVERY push - so an error storm rebuilt a 500-entry list
-- once per error, whether or not anyone had the panel open. The listener now
-- only sets a dirty flag; the rebuild happens in the list's own prerender, which
-- the UI manager calls only for a visible element and only once per frame. Forty
-- pushes in a tick cost one rebuild, and pushes while the deck is shut cost
-- nothing at all.

if isServer() then return end

require "ISUI/ISScrollingListBox"
require "ISUI/ISButton"
require "ISUI/ISComboBox"

local LEVEL_COLOR = {
    info     = { 0.85, 0.85, 0.85 },
    warn     = { 0.95, 0.75, 0.30 },
    error    = { 0.95, 0.40, 0.40 },
    audit    = { 0.55, 0.75, 0.95 },
    -- Distinct from `error` on purpose: an error is the game misbehaving, a
    -- tripwire is a person doing something. They should never be scanned as the
    -- same class of event.
    tripwire = { 1.00, 0.45, 0.85 },
}

local ui = nil            -- live widget handles for the reflow
local dirty = true        -- a rebuild is owed; consumed by prerender
local activeListener = nil

-- ---------------------------------------------------------------------------
-- Event list
-- ---------------------------------------------------------------------------

local ConsoleList = ISScrollingListBox:derive("DFConsoleList")

function ConsoleList:doDrawItem(y, item, alt)
    local e = item.item
    if not e then return y + self.itemheight end

    if self.selected == item.index then
        self:drawRect(0, y, self.width, self.itemheight - 1, 0.35, 0.25, 0.55, 0.85)
    elseif alt then
        self:drawRect(0, y, self.width, self.itemheight - 1, 0.18, 0.08, 0.08, 0.08)
    end

    local c = LEVEL_COLOR[e.level] or LEVEL_COLOR.info
    local txt = DFKit.fitText(DFLog.headline(e), DFKit.font.small, self.width - 8)
    self:drawText(txt, 4, y + 2, c[1], c[2], c[3], 1, DFKit.font.small)
    return y + self.itemheight
end

-- ---------------------------------------------------------------------------
-- Detail pane
-- ---------------------------------------------------------------------------
--
-- A scrolling list of pre-wrapped lines rather than a hand-rolled text widget:
-- it inherits the scrollbar, the stencil and the mouse wheel from vanilla, and
-- DFKit.sizeList already knows how to keep those correct through a resize.
--
-- Wrapping is recomputed on selection change AND on layout, because a wrap
-- measured at one width is wrong at another - and this pane is inside a panel
-- the admin can drag.

local DetailList = ISScrollingListBox:derive("DFConsoleDetail")

function DetailList:doDrawItem(y, item, alt)
    local line = item.item
    if line == nil then return y + self.itemheight end
    local c = self.lineColor or LEVEL_COLOR.info
    self:drawText(tostring(line), 6, y, c[1], c[2], c[3], 1, self.lineFont)
    return y + self.itemheight
end

-- Selection is never drawn here; these rows are text, not choices.
function DetailList:onMouseDown() return false end

local function detailFont()
    return DFKit.font.code or DFKit.font.small
end

local function rebuildDetail()
    if not ui or not ui.detail then return end
    local e = ui.selectedEntry
    local font = detailFont()

    ui.detail.lineFont  = font
    ui.detail.lineColor = e and (LEVEL_COLOR[e.level] or LEVEL_COLOR.info) or LEVEL_COLOR.info

    local fh = 12
    -- getFontHeight (TextManager:127) NPEs on a font this build lacks;
    -- fallback height stands in
    pcall(function() fh = getTextManager():getFontHeight(font) end)
    ui.detail.itemheight = math.max(12, fh + 1)

    DFKit.refillList(ui.detail, function(box)
        if not e then return end
        local w = math.max(40, box.width - 24)
        for _, line in ipairs(DFKit.wrapText(DFLog.detailText(e), font, w)) do
            box:addItem("", line)
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Rebuild
-- ---------------------------------------------------------------------------

local function currentFilter()
    if not ui or not ui.filterCombo then return "all" end
    if not ui.filterCombo.getOptionData then return "all" end
    return ui.filterCombo:getOptionData(ui.filterCombo.selected) or "all"
end

-- SELECTION SURVIVES A REBUILD, tracked by entry identity rather than by row
-- index. The buffer is a ring: a push at the tail can evict at the head and slide
-- every index down by one, so an index-based selection silently walks up the list
-- while an operator is reading the row it used to point at.
local function rebuildList()
    if not ui or not ui.list then return end

    local keep = ui.selectedEntry
    local snap = DFLog.snapshot(currentFilter())

    DFKit.refillList(ui.list, function(box)
        for _, e in ipairs(snap) do box:addItem("", e) end
    end)

    local foundAt = nil
    if keep then
        for i, e in ipairs(snap) do
            if e == keep then foundAt = i; break end
        end
    end

    if foundAt then
        ui.list.selected = foundAt
    elseif #snap > 0 then
        -- No prior selection, or the selected entry aged out of the ring. Follow
        -- the tail, which is what a live console should do when nobody has
        -- pinned anything.
        ui.list.selected     = #snap
        ui.selectedEntry     = snap[#snap]
        -- Vanilla validates the list index before adjusting local scroll state
        -- (ISScrollingListBox.lua:623-638); #snap is the just-built tail row.
        ui.list:ensureVisible(#snap)
        rebuildDetail()
        return
    else
        ui.list.selected = 0
        ui.selectedEntry = nil
    end

    rebuildDetail()
end

-- The coalescing point. prerender runs only for a visible element and at most
-- once per frame, so this is both the "is anyone looking" gate and the "many
-- pushes, one rebuild" throttle.
function ConsoleList:prerender()
    if dirty then
        dirty = false
        rebuildList()
    end
    ISScrollingListBox.prerender(self)
end

-- Guarded on `ui`, not because it should ever be nil, but because a list can
-- outlive the build that owns it: the tab is rebuilt each time the panel opens,
-- and a click landing on a previous build's widget would otherwise index nil.
function ConsoleList:onMouseDown(x, y)
    local r = ISScrollingListBox.onMouseDown(self, x, y)
    if not ui or ui.list ~= self then return r end
    local item = self.items[self.selected]
    if item then
        ui.selectedEntry = item.item
        rebuildDetail()
    end
    return r
end

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------
--
-- Split 55/45 between roster and detail. The detail pane gets a floor because a
-- trace shown three lines at a time is no better than the single line this
-- rework exists to replace.
local DETAIL_MIN = 120

local function layout(panel, x, y, w, h)
    if not ui then return end
    local m = DFKit.metrics
    local R = DFKit.layout(panel, x, y, w, h)

    local bar = R:header(m.btnH + m.pad)
    ui.filterCombo:setX(bar.x);       ui.filterCombo:setY(bar.y)
    ui.copyBtn:setX(bar.x + 170);     ui.copyBtn:setY(bar.y)
    ui.copyOneBtn:setX(bar.x + 280);  ui.copyOneBtn:setY(bar.y)
    ui.clearBtn:setX(bar.x + 400);    ui.clearBtn:setY(bar.y)
    ui.testBtn:setX(bar.x + 490);     ui.testBtn:setY(bar.y)

    local detailH = math.floor(R.h * 0.45)
    if detailH < DETAIL_MIN then detailH = math.min(DETAIL_MIN, math.floor(R.h / 2)) end
    local listH = R.h - detailH - m.gap

    DFKit.sizeList(ui.list,   R.x, R.y, R.w, listH)
    DFKit.sizeList(ui.detail, R.x, R.y + listH + m.gap, R.w, detailH)

    ui.list.itemheight = DFKit.rowHeight()

    -- The wrap was measured against the old width and is wrong at the new one.
    rebuildDetail()
end

-- ---------------------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------------------

local function build(spec, panel, x, y, w, h)
    local m = DFKit.metrics

    local filterCombo = ISComboBox:new(0, 0, 160, m.btnH, panel)
    filterCombo:initialise()
    filterCombo:instantiate()
    filterCombo:addOptionWithData("All sources",    "all")
    filterCombo:addOptionWithData("Tripwires only", "Tripwire")
    filterCombo:addOptionWithData("Errors only",    "Error")
    filterCombo:addOptionWithData("Admin only",     "Admin")
    filterCombo:addOptionWithData("Client commands","ClientCmd")
    filterCombo:addOptionWithData("Mod traffic",    "Mod")
    panel:addChild(filterCombo)

    local list = ConsoleList:new(0, 0, 10, 10)
    list.itemheight = DFKit.rowHeight()
    list.drawBorder = true
    DFKit.well(list)
    list:initialise()
    list:instantiate()
    panel:addChild(list)

    local detail = DetailList:new(0, 0, 10, 10)
    detail.itemheight = 14
    detail.drawBorder = true
    DFKit.well(detail)
    detail:initialise()
    detail:instantiate()
    panel:addChild(detail)

    local origSelect = filterCombo.select
    filterCombo.select = function(self_, ...)
        origSelect(self_, ...)
        -- A filter change may hide the pinned row; drop the pin rather than
        -- leave the detail pane showing something the list no longer contains.
        ui.selectedEntry = nil
        dirty = true
    end

    local copyBtn = DFKit.button(panel, 0, 0, 100, "Copy all", panel, function()
        DFLog.copyAllToClipboard(currentFilter())
    end, nil, { tooltip = "Copy every visible entry, with build context, fenced for pasting." })

    local copyOneBtn = DFKit.button(panel, 0, 0, 110, "Copy selected", panel, function()
        if ui.selectedEntry then
            DFLog.copyEntryToClipboard(ui.selectedEntry)
        elseif DFFeedback then
            DFFeedback.bad("Nothing selected.")
        end
    end, nil, { tooltip = "Copy the selected event in full, with build context." })

    local clearBtn = DFKit.button(panel, 0, 0, 80, "Clear", panel, function()
        DFLog.clear()
        ui.selectedEntry = nil
        dirty = true
    end)

    -- Deliberately throw one non-fatal Lua error, to prove the whole error path is
    -- alive: engine catches -> KahluaThread.m_errors_list -> DFErrorPoller ->
    -- DFLog -> this list. Worth having as a button because every link in that
    -- chain has failed silently at least once, and there is no other way to tell
    -- "no errors happening" from "error capture is broken".
    --
    -- IT INDEXES A NIL rather than calling error(), because that is the case
    -- worth testing. A nil index is the four-fragment sequence DFErrorPoller's
    -- reassembly exists for (message, Lua trace, RuntimeException, Lua trace -
    -- KahluaThread.java:1097-1102 then :677). If reassembly is working this
    -- produces ONE console row with a full trace behind it; if it regresses, it
    -- produces four. The button tests the fix, not just the plumbing.
    --
    -- NON-FATAL BY CONSTRUCTION: the throw happens inside an event callback, and
    -- the engine catches Lua errors there, logs the trace and carries on - which is
    -- exactly why modded PZ spams traces without dying. The handler removes itself
    -- before throwing, so it fires once and cannot loop.
    local testBtn = DFKit.button(panel, 0, 0, 90, "Test error", panel, function()
        local function boom()
            Events.OnTick.Remove(boom)
            local absent = nil
            local _ = absent.dragonflyConsoleSelfTest
        end
        Events.OnTick.Add(boom)
        if DFFeedback then
            DFFeedback.good("Simulated error thrown; expect ONE row with a full trace.")
        end
    end, "warn", { tooltip = "Throw a harmless nil-index error to prove capture and reassembly work." })

    -- The tab is rebuilt every time the panel opens, and each build subscribed a
    -- fresh listener closing over that build's widgets. They accumulated for the
    -- session, every one of them firing against a dead list on every log push
    -- (swallowed by the pcall in DFLog.notify, so it looked harmless). Track the
    -- live one and drop it on rebuild.
    if activeListener then DFLog.unsubscribe(activeListener) end
    activeListener = function() dirty = true end
    DFLog.subscribe(activeListener)

    -- Z-order: the combo's dropdown popup must render above the lists. ISUI draws
    -- siblings in addChild order (later = on top), and both lists were added after
    -- the combo, so they overdraw the popup. bringToTop promotes it back.
    filterCombo:bringToTop()

    ui = {
        filterCombo = filterCombo,
        list = list, detail = detail,
        copyBtn = copyBtn, copyOneBtn = copyOneBtn,
        clearBtn = clearBtn, testBtn = testBtn,
        selectedEntry = nil,
    }
    layout(panel, x, y, w, h)
    dirty = true
end

Events.OnGameStart.Add(function()
    if not DFRegistry then return end
    if not DFLog then
        print("[RFTDCore] DFConsoleTab: DFLog not loaded, skipping tab registration")
        return
    end
    -- a tab-registration fault is reported below, not allowed to kill
    -- the OnGameStart chain
    local ok, err = pcall(function()
        DFRegistry.registerTab{
            id     = "console",
            label  = "Console",
            order  = 1000,
            build  = build,
            resize = function(_, panel, w, h) layout(panel, 0, 0, w, h) end,
        }
    end)
    if not ok then
        print("[RFTDCore] DFConsoleTab registerTab error: " .. tostring(err))
    end
end)

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
