-- SPDX-License-Identifier: GPL-3.0-or-later
-- DMClaimants - two staff read-outs over the claim record (client only).
--
-- WHO TOOK THIS KIT, opened from the count box on a catalogue row, and WHAT HAS
-- BEEN TAKEN LATELY, opened from the tab's footer. One file because they are
-- the same window with a different query behind it, and splitting them would be
-- two copies of a sortable list of rows nobody would keep in step.
--
-- ---------------------------------------------------------------------------
-- THE TWO ANSWER DIFFERENT QUESTIONS, and the difference is worth stating
-- because it looks like duplication.
--
--   CLAIMANTS  is derived from the LEDGER: who holds a claim on this kit, and
--              how many times. It is a current-state answer, and it survives
--              for as long as the claim does - including for players who have
--              not logged in this season.
--
--   THE LOG    is a bounded ring of EVENTS: this was taken, then this, then
--              this. It answers "what happened", in order, and it starts where
--              the log was added rather than where the server did. A claim
--              made before the log existed has a ledger row and no line, which
--              is honest - it cannot invent a past it did not watch.
--
-- Neither is the archive. The forensic stream (DM.KIT_CLAIMED, written on every
-- claim since the wire shipped) is, and it rotates on its own terms.
--
-- ---------------------------------------------------------------------------
-- TIMES ARE FORMATTED ON THE CLIENT, from a millisecond stamp on the wire.
-- os.date is registered in Kahlua (OsLib.java:44-50, 87-103) and RDLog already
-- relies on it. The stamp is the SERVER's clock; rendered without a timezone
-- marker it would read as local time and quietly mislead an admin comparing it
-- against a chat log, so the format says UTC.

if isServer() then return end

require "DFKit"
require "DFConfirm"
require "ISUI/ISScrollingListBox"
require "ISUI/ISCollapsableWindow"

DMClaimants = DMClaimants or {}
local M = DMClaimants

local TOKEN = "RFTDDungeonMaster"
local FONT  = DFKit.font.small

M.win = nil

-- The claimant the admin has picked, by NAME rather than row index: the list is
-- refilled from the server after every clear, and refillList resets the
-- selection, so an index would point at whoever moved into that slot.
M.picked = nil

-- ---------------------------------------------------------------------------
-- Pure
-- ---------------------------------------------------------------------------

-- A server millisecond stamp -> a readable, unambiguous time. Empty for a row
-- that carries none, which is a real case: the ledger recorded `at` only from
-- the build that added it.
function DMClaimants.stamp(ms)
    local n = tonumber(ms)
    if not n or n <= 0 then return "" end
    return os.date("!%Y-%m-%d %H:%M", n / 1000) .. "Z"
end

-- One claimant row. Sorted most-claims-first, then by name: the admin question
-- behind this window is nearly always "who has taken it the most".
function DMClaimants.sortClaimants(rows)
    local out = {}
    for _, r in ipairs(rows or {}) do out[#out + 1] = r end
    table.sort(out, function(a, b)
        local na, nb = tonumber(a.n) or 0, tonumber(b.n) or 0
        if na ~= nb then return na > nb end
        return tostring(a.user) < tostring(b.user)
    end)
    return out
end

function DMClaimants.claimantLine(r)
    if type(r) ~= "table" then return "(malformed row)" end
    local n = tonumber(r.n) or 0
    local line = tostring(r.user) .. "   x" .. n
    local at = DMClaimants.stamp(r.at)
    if at ~= "" then line = line .. "   last: " .. at end
    -- `by` is the admin who handed it over; absent means the player claimed it
    -- themselves, and saying "self" is clearer than a blank column.
    if r.by and r.by ~= "" then line = line .. "   by " .. tostring(r.by) end
    return line
end

-- One log line. Everything the owner asked for, in the order they asked for it:
-- when, which kit, who, and what they got.
function DMClaimants.logLine(e)
    if type(e) ~= "table" then return "(malformed line)" end
    local parts = { DMClaimants.stamp(e.at) }
    parts[#parts + 1] = tostring(e.label or e.id or "?")
    parts[#parts + 1] = tostring(e.user or "?")
    if e.by and e.by ~= "" then
        parts[#parts + 1] = "(granted by " .. tostring(e.by) .. ")"
    end
    -- The delivery summary is attached AFTER the grants run, so a line without
    -- one is a claim whose delivery did not finish - worth seeing as such
    -- rather than rendered as an empty column.
    parts[#parts + 1] = (e.items and e.items ~= "")
        and tostring(e.items) or "(delivery not recorded)"
    return table.concat(parts, "   -   ")
end

function DMClaimants.emptyLine(rows, mode)
    if rows == nil then return "Reading..." end
    if mode == "log" then
        return "Nothing claimed yet, or nothing since the log was added."
    end
    return "Nobody has claimed this kit."
end

-- ---------------------------------------------------------------------------
-- Replies
-- ---------------------------------------------------------------------------

-- OBSERVES rather than claims: DMKitsTab owns the KitClaimants reply for its
-- own summary pane, and both it and this window can legitimately want the same
-- push. Never gates the chain - the same shape DFPlayerVarsModal uses.
function DMClaimants.observe(command, args)
    if not M.win then return false end
    if command == "KitClaimants" and M.win.mode == "kit" then
        if not (args and args.id == M.win.kitId) then return false end
        M.win.rows = DMClaimants.sortClaimants(args.rows)
        M.win:rebuild()
        return true
    elseif command == "KitLog" and M.win.mode == "log" then
        M.win.rows = (args and args.rows) or {}
        M.win:rebuild()
        return true

    elseif command == "KitResult" and args and args.command == "kitForgetOne" then
        M.win.status = args.ok and tostring(args.message) or tostring(args.reason)
        if args.ok then
            -- Re-read rather than editing the row out locally: the server has
            -- just changed the claim record and its answer is the only one
            -- worth drawing. A cleared player leaves the list entirely.
            M.picked = nil
            if M.win.mode == "kit" and M.win.kitId then
                RDNet.send(TOKEN, "kitClaimants", { id = M.win.kitId })
            end
        end
        return true
    end
    return false
end

-- ---------------------------------------------------------------------------
-- The window
-- ---------------------------------------------------------------------------

local RowList = ISScrollingListBox:derive("DMClaimantsList")

function RowList:doDrawItem(y, item, alt)
    if item.item == nil then return y + item.height end
    local row = item.item
    if M.picked and type(row) == "table" and row.user == M.picked then
        local a = DFKit.col.accentDim
        self:drawRect(0, y, self.width, item.height - 1, 0.55, a.r, a.g, a.b)
    elseif alt then
        self:drawRect(0, y, self.width, item.height - 1, 0.10, 1, 1, 1)
    end
    self:drawRectBorder(0, y, self.width, item.height, 0.12, 1, 1, 1)
    local c = DFKit.col.text
    self:drawText(DFKit.fitText(item.text, FONT, self.width - 12), 6, y + 3,
                  c.r, c.g, c.b, 1, FONT)
    return y + item.height
end

-- Only the claimants list is selectable. The log is a record of things that
-- have already happened and has no verb attached, so a highlight there would
-- promise one.
function RowList:onMouseDown(x, y)
    if M.win and M.win.mode ~= "kit" then return end
    local idx = self:rowAt(x, y)
    if idx < 1 or idx > #self.items then return end
    local row = self.items[idx].item
    M.picked = (type(row) == "table") and row.user or nil
end

local Window = ISCollapsableWindow:derive("DMClaimantsWindow")

function Window:createChildren()
    ISCollapsableWindow.createChildren(self)
    local m, pad = DFKit.metrics, DFKit.metrics.pad
    local top   = self:titleBarHeight() + pad
    local footH = m.btnH + pad * 2
    local win   = self

    local list = RowList:new(pad, top, self.width - pad * 2,
                             self.height - top - footH - pad)
    list.itemheight = DFKit.rowHeight()
    list.drawBorder = true
    DFKit.well(list)
    list:initialise(); list:instantiate()
    self:addChild(list)
    self.listBox = list

    local bx = self.width - pad - 80
    DFKit.button(self, bx, self.height - footH, 80, "Close",
                 self, function() win:close() end)

    -- CLEAR ONE CLAIM, and only on the claimants list. This is the lost-packet
    -- fix: a delivery that died leaves a player charged for nothing and, on a
    -- once-ever kit, locked out with no way back. Confirmed, because it hands
    -- somebody a second go at a one-time reward.
    if self.mode == "kit" then
        bx = bx - DFKit.metrics.gap - 120
        DFKit.button(self, bx, self.height - footH, 120, "Clear claim", self,
            function() win:clearPicked() end, nil,
            { tooltip = "Let this player claim the kit again. Use it when a "
                .. "delivery was lost - the claim is recorded before the items "
                .. "are handed over, so a dropped packet can charge somebody "
                .. "for nothing." })
    end
    self.footY = self.height - footH + 4
    self:rebuild()
end

function Window:clearPicked()
    if self.mode ~= "kit" then return end
    if not M.picked then self.status = "Pick a player first."; return end
    local who, kit = M.picked, self.kitId
    DFConfirm.ask("Clear " .. who .. "'s claim on this kit?\n\n"
        .. "They will be able to claim it again. Their claim COUNT is cleared "
        .. "with it, so a repeatable kit starts over.",
        function()
            RDNet.send(TOKEN, "kitForgetOne", { id = kit, user = who })
        end)
end

function Window:rebuild()
    if not self.listBox then return end
    local rows, mode = self.rows, self.mode
    DFKit.refillList(self.listBox, function(box)
        for _, r in ipairs(rows or {}) do
            local text = (mode == "log") and DMClaimants.logLine(r)
                                          or DMClaimants.claimantLine(r)
            box:addItem(text, r).height = DFKit.rowHeight()
        end
    end)
    -- Read-only: nothing here is actionable, so nothing is selectable. A
    -- highlight would imply a verb this window does not have.
    self.listBox.selected = -1
end

function Window:prerender()
    ISCollapsableWindow.prerender(self)
    local d = DFKit.col.textDim
    if self.status then
        local a = DFKit.col.accent
        self:drawText(DFKit.fitText(self.status, FONT, self.width - 230),
                      DFKit.metrics.pad, self.footY, a.r, a.g, a.b, 1, FONT)
    end
    if not self.rows or #self.rows == 0 then
        self:drawText(DMClaimants.emptyLine(self.rows, self.mode),
                      DFKit.metrics.pad + 8, self.listBox:getY() + 6,
                      d.r, d.g, d.b, 1, FONT)
    end
end

function Window:close()
    M.win = nil
    self:removeFromUIManager()
end

local function openWindow(mode, title, kitId)
    if M.win then M.win:close() end
    local w, h = 560, 420
    local win = Window:new(getCore():getScreenWidth() / 2 - w / 2,
                           getCore():getScreenHeight() / 2 - h / 2, w, h)
    win.mode  = mode
    win.kitId = kitId
    win.status = nil
    M.picked   = nil
    win.rows  = nil          -- nil is "reading", {} is "none" - see emptyLine
    win:setTitle(title)
    win:setResizable(true)
    win:initialise(); win:instantiate(); win:addToUIManager()
    M.win = win
    return win
end

-- Who has claimed this kit. The tab has already asked for the claimants on
-- selection, so this usually fills from a reply already in flight; asking again
-- covers the case where the answer landed before the window existed.
function DMClaimants.open(kit)
    if type(kit) ~= "table" then return nil end
    local win = openWindow("kit", "Claimed: " .. tostring(kit.label or kit.id),
                           kit.id)
    RDNet.send(TOKEN, "kitClaimants", { id = kit.id })
    return win
end

-- What has been claimed lately, across every kit.
function DMClaimants.openLog()
    local win = openWindow("log", "Kit claim log", nil)
    RDNet.send(TOKEN, "kitLog", {})
    return win
end

return DMClaimants

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
