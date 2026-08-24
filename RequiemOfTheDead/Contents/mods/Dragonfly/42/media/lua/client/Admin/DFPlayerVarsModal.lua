-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFPlayerVarsModal - one player's variables, read only (client only).
--
-- The inverse read of DFVarEditor. That window asks "who holds this variable";
-- this one asks "what does this player hold". Both questions are real and
-- neither answers the other: an admin looking at a stuck quest is holding a
-- PLAYER in mind, not a variable, and walking forty variables one at a time to
-- find which ones they carry is not an answer.
--
-- Opened from the Players tab's detail pane, which is where an admin already
-- has the player selected.
--
-- ---------------------------------------------------------------------------
-- READ ONLY, deliberately. Every verb that changes a player's variables lives
-- in DFVarEditor, inside a window opened for ONE named variable, because that
-- is the shape where the verb cannot be aimed at the wrong thing. A second set
-- of grant/revoke buttons here would be that guarantee undone: this window is
-- organised by player, so "Remove" would mean "remove the highlighted row",
-- and the highlighted row moves every time the list refills.
--
-- ---------------------------------------------------------------------------
-- IT OBSERVES ITS REPLY, IT DOES NOT CLAIM IT. DFVarsView owns the single
-- OnServerCommand listener and offers per-player pushes here first. Both this
-- window and an open editor can legitimately want the same push - this one is
-- showing that player, the editor reads any push as "a verb landed, re-read" -
-- so consuming it would leave the other stale with no way to notice.
--
-- ---------------------------------------------------------------------------
-- ABSENT IS NOT ZERO, again. A counter appears here only when the player has a
-- value for it, INCLUDING zero. A counter they have never touched is not in
-- the list at all, and that difference is the whole "have you started this
-- yet" test every repeatable quest will be built on.

if isServer() then return end

require "DFKit"
require "RDVarDefs"
require "ISUI/ISScrollingListBox"
require "ISUI/ISCollapsableWindow"

DFPlayerVarsModal = DFPlayerVarsModal or {}
local M = DFPlayerVarsModal

local FONT = DFKit.font.small
local W, H = 560, 380

-- The open window, or nil. One at a time: two of these would answer for two
-- different players under two titles and share one reply stream.
M.win    = nil
M.record = nil   -- the last AdminVarsPlayer for the shown user, or nil

-- ---------------------------------------------------------------------------
-- Pure
-- ---------------------------------------------------------------------------

-- One player's record -> the two columns. PURE, and split out for the same
-- reason DFVarsView.split is: which side a thing belongs on is the organising
-- idea of the screen, and a fixture should be able to ask without a UI.
--
-- The server already sorts both halves by key (RDVars.ofPlayer), and this
-- re-sorts by DISPLAY NAME because that is what is drawn - a key differs from
-- its name only in case, but that is enough to put "anomaly" and "Beacon" in
-- an order the eye reads as wrong.
function DFPlayerVarsModal.split(record)
    local flags, counters = {}, {}
    for _, f in ipairs((record and record.flags) or {}) do
        flags[#flags + 1] = f
    end
    for _, n in ipairs((record and record.numbers) or {}) do
        counters[#counters + 1] = n
    end
    local byName = function(a, b)
        return string.lower(tostring(a.name)) < string.lower(tostring(b.name))
    end
    table.sort(flags, byName)
    table.sort(counters, byName)
    return flags, counters
end

-- A row's right-hand cell. A flag shows WHO granted it, which is the follow-up
-- question every unexpected flag produces; a counter shows its value, and
-- tostring rather than a truthiness test so a real 0 renders as "0".
function DFPlayerVarsModal.cellFor(side, row)
    row = row or {}
    if side == RDVarDefs.COUNTER then
        if row.value == nil then return "-" end
        return tostring(row.value)
    end
    if type(row.by) ~= "string" or row.by == "" then return "-" end
    return row.by
end

-- What an empty column says. Three states, and they are three different facts:
-- nothing asked for yet, asked and the player has none, asked and the player
-- does not exist as far as the store is concerned. Rendering the first two
-- alike is how an admin concludes "no flags" from a request that never landed.
function DFPlayerVarsModal.emptyLine(record, side)
    if not record then return "Reading..." end
    if side == RDVarDefs.COUNTER then return "No counters set." end
    return "Holds no flags."
end

-- ---------------------------------------------------------------------------
-- Wire
-- ---------------------------------------------------------------------------

-- Offered every per-player push by DFVarsView. Returns true when the push was
-- FOR the shown player, so a caller can log it; it must never be read as "this
-- reply is spoken for" - see the header.
function DFPlayerVarsModal.observe(command, args)
    if command ~= "AdminVarsPlayer" then return false end
    if not M.win or not args or args.username ~= M.win.user then return false end
    M.record = args
    DFPlayerVarsModal.rebuild()
    return true
end

function DFPlayerVarsModal.refresh()
    if not M.win then return end
    sendClientCommand(getPlayer(), DFCore.MODULE, "varsOfPlayer",
        { user = M.win.user })
end

-- ---------------------------------------------------------------------------
-- The two lists
-- ---------------------------------------------------------------------------

local VarList = ISScrollingListBox:derive("DFPlayerVarsList")

function VarList:doDrawItem(y, item, alt)
    local row = item.item
    if not row then return y + item.height end
    if alt then
        self:drawRect(0, y, self.width, item.height - 1, 0.10, 1, 1, 1)
    end
    -- Boxed, matching the Variables tab and the player panel: a variable is a
    -- thing, not a line of a report.
    self:drawRectBorder(0, y, self.width, item.height, 0.12, 1, 1, 1)

    local cell = DFPlayerVarsModal.cellFor(self.side, row)
    local cw   = getTextManager():MeasureStringX(FONT, cell)
    local c, d = DFKit.col.text, DFKit.col.textDim
    self:drawText(DFKit.fitText(row.name, FONT, self.width - cw - 18), 6, y + 3,
                  c.r, c.g, c.b, 1, FONT)
    self:drawText(cell, self.width - cw - 6, y + 3, d.r, d.g, d.b, 1, FONT)
    return y + item.height
end

-- Nothing here is selectable. Every verb lives in DFVarEditor, so a highlight
-- would be a control that does nothing - and on a screen full of other panels
-- whose highlights DO arm a verb, that is a worse lie than no highlight.
function VarList:onMouseDown() end
function VarList:onMouseUp() end

function DFPlayerVarsModal.rebuild()
    local win = M.win
    if not win or not win.flagBox then return end
    local flags, counters = DFPlayerVarsModal.split(M.record)
    local function fill(box, rows)
        DFKit.refillList(box, function(b)
            for _, row in ipairs(rows) do
                local i = b:addItem(row.name, row)
                i.height = DFKit.rowHeight()
            end
        end)
        box.selected = -1
    end
    fill(win.flagBox, flags)
    fill(win.counterBox, counters)
end

-- ---------------------------------------------------------------------------
-- The window
-- ---------------------------------------------------------------------------

local Modal = ISCollapsableWindow:derive("DFPlayerVarsWindow")

function Modal:createChildren()
    ISCollapsableWindow.createChildren(self)
    local m     = DFKit.metrics
    local pad   = m.pad
    local top   = self:titleBarHeight() + pad
    local footH = m.btnH + pad * 2
    -- The captions get a reserved band, the same as everywhere else in this
    -- folder. Drawing them at listY - pad puts them under the list's border at
    -- any text tier above Small.
    local bandH = DFKit.rowHeight()
    local colW  = math.floor((self.width - pad * 3) / 2)
    local listY = top + bandH
    local listH = self.height - listY - footH - pad

    self.bandY = top
    local function mkList(x, side)
        local box = VarList:new(x, listY, colW, listH)
        box.itemheight = DFKit.rowHeight()
        box.drawBorder = true
        box.side = side
        DFKit.well(box)
        box:initialise(); box:instantiate()
        self:addChild(box)
        return box
    end
    self.flagBox    = mkList(pad, RDVarDefs.FLAG)
    self.counterBox = mkList(pad * 2 + colW, RDVarDefs.COUNTER)
    self.colW = colW

    local win = self
    local bx = self.width - pad
    for _, spec in ipairs({ { 80, "Close", function() win:close() end, nil },
                            { 80, "Refresh", DFPlayerVarsModal.refresh, "action" } }) do
        bx = bx - spec[1]
        DFKit.button(self, bx, self.height - footH, spec[1], spec[2], self,
                     spec[3], spec[4])
        bx = bx - m.gap
    end
end

function Modal:prerender()
    ISCollapsableWindow.prerender(self)
    local pad = DFKit.metrics.pad
    local t   = DFKit.col.textDim
    local flags, counters = DFPlayerVarsModal.split(M.record)

    self:drawText("FLAGS  (" .. #flags .. ")", pad, self.bandY,
                  t.r, t.g, t.b, 1, FONT)
    self:drawText("COUNTERS  (" .. #counters .. ")", pad * 2 + self.colW,
                  self.bandY, t.r, t.g, t.b, 1, FONT)

    -- The empty states are drawn over the wells rather than added as a row:
    -- a row would be selectable, countable and indistinguishable from a
    -- variable actually named "Holds no flags."
    if #flags == 0 then
        self:drawText(DFPlayerVarsModal.emptyLine(M.record, RDVarDefs.FLAG),
                      pad + 8, self.flagBox:getY() + 6, t.r, t.g, t.b, 1, FONT)
    end
    if #counters == 0 then
        self:drawText(DFPlayerVarsModal.emptyLine(M.record, RDVarDefs.COUNTER),
                      pad * 2 + self.colW + 8, self.counterBox:getY() + 6,
                      t.r, t.g, t.b, 1, FONT)
    end
end

function Modal:close()
    M.win, M.record = nil, nil
    self:removeFromUIManager()
end

-- ---------------------------------------------------------------------------

function DFPlayerVarsModal.open(username)
    if type(username) ~= "string" or username == "" then return nil end
    if M.win then M.win:close() end

    local win = Modal:new(getCore():getScreenWidth() / 2 - W / 2,
                          getCore():getScreenHeight() / 2 - H / 2, W, H)
    win.user = username
    win:setTitle("Variables: " .. username)
    win:setResizable(false)
    win:initialise(); win:instantiate(); win:addToUIManager()

    M.win, M.record = win, nil
    DFPlayerVarsModal.refresh()
    return win
end

return DFPlayerVarsModal

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
