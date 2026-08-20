-- SPDX-License-Identifier: GPL-3.0-or-later
-- LMImportWindow - the import panel, popped out, with its own console under it.
--
-- Import used to be half of the Zones tab, which gave a once-per-migration
-- operation the same standing as the editor somebody opens every session. It is
-- a button now, and the button opens this.
--
-- THE CONSOLE IS THE POINT. The old panel reported into eight fixed labels: nine
-- warnings fitted, seventeen did not, and the ones that did not became "... and
-- 9 more (console has all)" - a message telling the admin the information exists
-- somewhere else. Everything the importer says now goes through DFLog with
-- source "Limes", which means the suite's own Console tab already shows it, the
-- clipboard-copy button already covers it, and this window can show the same
-- stream filtered to us. The output arrives free because it was already being
-- printed; it was just being printed where nothing could scroll it.
--
-- Deliberately a plain ISCollapsableWindow rather than another Dragonfly tab:
-- an import is something you watch while doing something else, and a modal or a
-- tab would take the map away to show it.

if isServer() then return end

require "ISUI/ISCollapsableWindow"
require "ISUI/ISScrollingListBox"

LMImportWindow = ISCollapsableWindow:derive("LMImportWindow")

local W, H       = 640, 520
local CONSOLE_H  = 190
local SOURCE     = "Limes"

-- ---------------------------------------------------------------------------
-- The log pane
-- ---------------------------------------------------------------------------

local LogList = ISScrollingListBox:derive("LMImportLogList")

local LEVEL_COLOR = {
    info  = { 0.85, 0.85, 0.85 },
    warn  = { 0.95, 0.75, 0.30 },
    error = { 0.95, 0.40, 0.40 },
    audit = { 0.55, 0.75, 0.95 },
}

function LogList:doDrawItem(y, item, alt)
    local e = item.item
    if not e then return y + self.itemheight end
    if alt then self:drawRect(0, y, self.width, self.itemheight - 1, 0.18, 0.08, 0.08, 0.08) end
    local c = LEVEL_COLOR[e.level] or LEVEL_COLOR.info
    self:drawText(DFLog.formatLine(e), 4, y + 2, c[1], c[2], c[3], 1, UIFont.Small)
    return y + self.itemheight
end

-- ---------------------------------------------------------------------------
-- Window
-- ---------------------------------------------------------------------------

function LMImportWindow:createChildren()
    ISCollapsableWindow.createChildren(self)

    local top = self:titleBarHeight()

    -- The import controls are LMImportTab's, unchanged and unduplicated: it
    -- still owns the clipboard preview, the chunked send, Clear All and the
    -- teleport drill-down. This window only supplies a frame and a log.
    self.body = ISPanel:new(0, top, self.width, self.height - top - CONSOLE_H)
    self.body.backgroundColor = { r = 0, g = 0, b = 0, a = 0 }
    self.body.borderColor     = { r = 0, g = 0, b = 0, a = 0 }
    self.body:initialise(); self.body:instantiate()
    self:addChild(self.body)
    -- No guard, and the old justification was wrong twice over. It called DFKit
    -- "Dragonfly's" - DFKit lives in CORE (RFTDCore/client/DFKit.lua), which
    -- everything hard-requires, so there is no optional integration here. And
    -- LMImportTab is this mod's own file. pcall over our own code plus
    -- always-present Core widgets is exactly the shape the policy forbids: a
    -- build failure is a programming error, and it should be loud and
    -- attributable, not a tab that silently is not there.
    LMImportTab.attach(self.body)

    self.log = LogList:new(4, self.height - CONSOLE_H, self.width - 8, CONSOLE_H - 6)
    self.log:initialise(); self.log:instantiate()
    self.log.itemheight = 18
    self.log.drawBorder = true
    DFKit.well(self.log)
    self:addChild(self.log)

    self.copyBtn = DFKit.button(self, self.width - 116, self.height - CONSOLE_H - 26, 110,
        "Copy log", self, function()
            if DFLog and DFLog.copyAllToClipboard then DFLog.copyAllToClipboard(SOURCE) end
        end, "action", { tooltip = "Copy every Limes log line to the clipboard." })

    self:refreshLog()
    self:onResize()
end

function LMImportWindow:refreshLog()
    if not (self.log and DFLog) then return end
    DFKit.refillList(self.log, function(box)
        for _, e in ipairs(DFLog.snapshot(SOURCE)) do box:addItem("", e) end
    end)
    if #self.log.items > 0 then
        self.log.selected = #self.log.items
        -- Vanilla ensureVisible validates the index and uses only list rows,
        -- scroll state, and height; it has no render prerequisite
        -- (ISScrollingListBox.lua:623-638).
        self.log:ensureVisible(#self.log.items)
    end
end

function LMImportWindow:onResize()
    ISCollapsableWindow.onResize(self)
    local top = self:titleBarHeight()
    local bodyH = self.height - top - CONSOLE_H
    if self.body then
        self.body:setWidth(self.width)
        self.body:setHeight(bodyH)
        -- No guard. Its old premise - "widgets attach() may have failed to
        -- build" - existed only because attach was itself pcall'd; with that
        -- guard gone, a window that opened at all has a fully built tab.
        -- Guard-begets-guard is how the original 2,400 grew.
        LMImportTab.layout(self.body, 0, 0, self.width, bodyH)
    end
    if self.copyBtn then
        self.copyBtn:setX(self.width - 116)
        self.copyBtn:setY(top + bodyH - 26)
    end
    if self.log then
        DFKit.sizeList(self.log, 4, top + bodyH, self.width - 8, CONSOLE_H - 6)
    end
end

-- Poll rather than subscribe: a DFLog listener would need an unsubscribe on
-- every route that can close this window, and one left behind on a dead window
-- is a leak that survives each reopen.
--
-- THROTTLED, because the poll is not free. DFLog.snapshot builds a filtered
-- copy of the ring (up to its 500-line capacity), so asking every frame is a
-- per-frame allocation proportional to the log - for a pane whose contents
-- change at human speed. Four times a second is faster than anyone reads and
-- fifteen times cheaper.
local POLL_FRAMES = 15

function LMImportWindow:prerender()
    ISCollapsableWindow.prerender(self)
    self._tick = (self._tick or 0) + 1
    if self._tick < POLL_FRAMES then return end
    self._tick = 0
    local n = DFLog and #DFLog.snapshot(SOURCE) or 0
    if n ~= self._lastN then
        self._lastN = n
        self:refreshLog()
    end
end

function LMImportWindow:close()
    ISCollapsableWindow.close(self)
    LMImportWindow.instance = nil
    self:removeFromUIManager()
end

-- One window, brought to the front if it is already up. A second copy would be
-- a second LMImportTab.attach, and that panel keeps its parsed clipboard preview
-- in a module-level singleton - two of them would fight over it.
function LMImportWindow.toggle()
    if LMImportWindow.instance then
        LMImportWindow.instance:removeFromUIManager()
        LMImportWindow.instance = nil
        return
    end
    local w = LMImportWindow:new(
        math.floor((getCore():getScreenWidth()  - W) / 2),
        math.floor((getCore():getScreenHeight() - H) / 2), W, H)
    w:initialise()
    w:instantiate()
    w:setTitle("Limes - import and log")
    w:addToUIManager()
    LMImportWindow.instance = w
end

return LMImportWindow

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
