-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFVarsView - the Admin tab's Variables sub-tab (client only).
--
-- Two lists, side by side: FLAGS on the left, COUNTERS on the right. This file
-- owns navigation and nothing else - what exists, and the two verbs that change
-- which variables exist at all. One variable's details and its membership live
-- in DFVarEditor, opened by clicking a row.
--
-- ---------------------------------------------------------------------------
-- WHY TWO LISTS AND NOT ONE WITH A KIND COLUMN (owner, 2026-08-23).
--
-- A flag is present or absent and has a lifecycle - cleared on death, after an
-- interval, when a kit is claimed. A counter is a number and has none of that;
-- it resets or it does not. They take different verbs, they answer different
-- questions, and RDVarDefs keeps them in separate tables specifically so
-- "absent" and "zero" can never be confused.
--
-- One list with a kind column would put that distinction in a glyph an admin
-- has to read, on a screen where the cost of misreading it is granting the
-- wrong sort of thing to a player. Two columns make the question "which of
-- these two am I looking at" answerable by where the cursor is.
--
-- ---------------------------------------------------------------------------
-- THE VERBS THAT MOVED, and why the footer is only two buttons now.
--
-- Grant, Revoke, Set and Reset used to live here, acting on a second list's
-- highlighted row. That put four destructive verbs one click from a list that
-- refills after every action, and meant an admin could never see a variable's
-- definition and its holders together. They are in DFVarEditor now, inside a
-- window opened for one named variable - where they cannot be aimed at the
-- wrong variable at all.
--
-- What is left here is what genuinely belongs to a catalogue: CREATE NEW and
-- DELETE. Both change which variables exist; neither touches a player.
--
-- ---------------------------------------------------------------------------
-- SELECTION IS A NAME AND A SIDE, never a row index. Every action is followed
-- by a server push, the push rebuilds both lists, and DFKit.refillList calls
-- clear() - which sets `selected = 1` (ISScrollingListBox.lua:340-345). Reading
-- the target off a widget therefore means: delete Anomaly, list refreshes,
-- selection silently lands on whatever is first, click Delete again and remove
-- THAT. The name is the truth and the index is re-derived after every rebuild.

if isServer() then return end

require "DFKit"
require "DFConfirm"
require "DFVarEditor"
require "DFPlayerVarsModal"
require "RDVarDefs"
require "ISUI/ISScrollingListBox"

DFVarsView = DFVarsView or {}
local V = DFVarsView

local FONT     = DFKit.font.small
local PANE_MIN = 200

V.defs     = {}     -- every definition, both kinds, as the server sent them
V.selected = nil    -- variable NAME
V.side     = nil    -- RDVarDefs.FLAG or RDVarDefs.COUNTER - which list holds it
V.status   = nil

-- ---------------------------------------------------------------------------
-- Pure
-- ---------------------------------------------------------------------------

-- One flat definition list -> the two columns, each sorted by name. PURE, and
-- split out because "which column is this in" is the whole organising idea of
-- the screen and a fixture should be able to ask it without a UI.
--
-- Sorted here rather than trusting the server's order: the two lists are read
-- side by side and an admin scanning for a name needs both to behave the same
-- way, whatever order the wire happened to deliver.
function DFVarsView.split(defs)
    local flags, counters = {}, {}
    for _, d in ipairs(defs or {}) do
        if d.kind == RDVarDefs.COUNTER then counters[#counters + 1] = d
        elseif d.kind == RDVarDefs.FLAG then flags[#flags + 1] = d end
    end
    local byName = function(a, b) return tostring(a.name) < tostring(b.name) end
    table.sort(flags, byName)
    table.sort(counters, byName)
    return flags, counters
end

local function selectedDef()
    for _, d in ipairs(V.defs) do if d.name == V.selected then return d end end
end

-- What the row's right-hand column says. A flag reports how many players hold
-- it, because that is the number an admin is looking for; a counter cannot
-- report the same thing - "how many have a value" is not the same question as
-- "how many hold it" - so it reports its lifecycle instead.
function DFVarsView.tagFor(d)
    if not d then return "" end
    if d.kind == RDVarDefs.FLAG then
        return tostring(d.holders or 0)
    end
    -- A world counter reports its SCOPE, not its lifecycle: it has no
    -- resetOnDeath at all, so "keeps" would be a lifecycle answer invented for
    -- a question that does not apply to it - and the scope is the fact that
    -- decides whether this row appears on any player's list.
    if RDVarDefs.isWorld(d) then return "world" end
    return d.resetOnDeath and "resets" or "keeps"
end

-- ---------------------------------------------------------------------------
-- Wire
-- ---------------------------------------------------------------------------

local function send(command, args)
    sendClientCommand(getPlayer(), DFCore.MODULE, command, args or {})
end

function DFVarsView.refresh()
    send("varsList")
end

function DFVarsView.receive(command, args)
    if command == "AdminVars" then
        V.defs = (args and args.defs) or {}
        -- A selection whose variable is gone becomes NO selection rather than
        -- sliding onto a neighbour. Delete is one of two buttons here.
        if V.selected and not selectedDef() then
            V.selected, V.side = nil, nil
        end
        DFVarsView.rebuild()
        return true

    elseif command == "AdminVarsStale" then
        DFVarsView.refresh()
        return true
    end

    -- Holder traffic belongs to whichever surface asked for it. ONE listener,
    -- one intake - two would race for the same replies.
    --
    -- The player modal OBSERVES rather than claims, and the name says so. Both
    -- it and the editor can legitimately want the same per-player push: the
    -- modal is showing that player, and the editor reads any such push as "a
    -- verb landed somewhere, re-read the holders". A claim by either would be
    -- the other going stale with no way to notice.
    DFPlayerVarsModal.observe(command, args)
    return DFVarEditor.receive(command, args)
end

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= DFCore.MODULE then return end
    DFVarsView.receive(command, args)
end)

-- ---------------------------------------------------------------------------
-- The two lists
-- ---------------------------------------------------------------------------

local VarList = ISScrollingListBox:derive("DFVarsList")

function VarList:doDrawItem(y, item, alt)
    local d = item.item
    if not d then return y + item.height end
    local on = (V.selected == d.name and V.side == self.side)
    if on then
        local a = DFKit.col.accentDim
        self:drawRect(0, y, self.width, item.height - 1, 0.55, a.r, a.g, a.b)
    elseif alt then
        self:drawRect(0, y, self.width, item.height - 1, 0.10, 1, 1, 1)
    end
    -- Boxed, the way the player panel draws its rows: each variable is a thing
    -- you click into rather than a line of a report.
    self:drawRectBorder(0, y, self.width, item.height, 0.12, 1, 1, 1)

    local c = on and DFKit.col.text or DFKit.col.textDim
    local tag = DFVarsView.tagFor(d)
    local tw  = getTextManager():MeasureStringX(FONT, tag)
    self:drawText(DFKit.fitText(d.name, FONT, self.width - tw - 18), 6, y + 3,
                  c.r, c.g, c.b, 1, FONT)
    local t = DFKit.col.textDim
    self:drawText(tag, self.width - tw - 6, y + 3, t.r, t.g, t.b, 1, FONT)
    return y + item.height
end

function VarList:onMouseDown(x, y)
    local idx = self:rowAt(x, y)
    if idx < 1 or idx > #self.items then return end
    local d = self.items[idx].item
    if not d then return end
    self.selected = idx
    V.selected, V.side, V.status = d.name, self.side, nil
    -- Selecting the other list's row must not leave two highlights. The
    -- rebuild re-derives both from (name, side).
    DFVarsView.rebuild()
end

-- Clicking a row opens it. Single click rather than double: the row IS the
-- variable, and a definition screen is not a destructive act - the destructive
-- verb is Delete, which sits in the footer behind a confirmation.
function VarList:onMouseUp(x, y)
    ISScrollingListBox.onMouseUp(self, x, y)
    local idx = self:rowAt(x, y)
    if idx < 1 or idx > #self.items then return end
    local d = self.items[idx].item
    if d then DFVarEditor.open(d) end
end

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------

function DFVarsView.rebuild()
    if not V.flagBox then return end
    local flags, counters = DFVarsView.split(V.defs)

    local function fill(box, rows)
        DFKit.refillList(box, function(b)
            for _, d in ipairs(rows) do
                local i = b:addItem(d.name, d)
                i.height = DFKit.rowHeight()
            end
        end)
        -- Put the widget back where the NAME says it is. refillList calls
        -- clear(), which sets selected = 1; left alone, both lists would
        -- highlight their first row after every refresh and Delete would be
        -- aimed at whatever that happened to be.
        box.selected = -1
        if V.selected and V.side == box.side then
            for i, item in ipairs(box.items) do
                if item.item and item.item.name == V.selected then
                    box.selected = i
                    break
                end
            end
        end
    end

    fill(V.flagBox, flags)
    fill(V.counterBox, counters)

    -- Selected, but in neither list any more: forget it rather than leaving a
    -- name behind a highlight nobody can see.
    if V.selected and V.flagBox.selected == -1 and V.counterBox.selected == -1 then
        V.selected, V.side = nil, nil
    end
end

function DFVarsView.attach(panel)
    local function mkList(side)
        local box = VarList:new(0, 0, 10, 10)
        box.itemheight = DFKit.rowHeight()
        box.drawBorder = true
        box.side = side
        DFKit.well(box)
        box:initialise(); box:instantiate()
        panel:addChild(box)
        return box
    end

    V.flagBox    = mkList(RDVarDefs.FLAG)
    V.counterBox = mkList(RDVarDefs.COUNTER)

    V.createBtn = DFKit.button(panel, 0, 0, 96, "Create New", panel,
        function() DFVarEditor.openNew() end, "action",
        { tooltip = "Create a variable. Definitions are server-wide." })

    V.deleteBtn = DFKit.button(panel, 0, 0, 76, "Delete", panel, function()
        if not V.selected then V.status = "Select a variable first."; return end
        local name = V.selected
        local d = selectedDef()
        local held = (d and d.kind == RDVarDefs.FLAG) and (d.holders or 0) or nil
        DFConfirm.ask("Delete '" .. name .. "'?"
            .. (held and (" It is currently held by " .. held .. " player(s), "
                          .. "and deleting it clears it from all of them.")
                     or " Every player's value for it is cleared.")
            .. " This cannot be undone.",
            function() send("varUndefine", { name = name }) end)
    end, nil, { tooltip = "Delete the selected variable and clear it from every "
                       .. "player who holds it." })

    DFVarsView.refresh()
    return { V.flagBox, V.counterBox, V.createBtn, V.deleteBtn }
end

function DFVarsView.layout(panel, x, y, w, h)
    if not V.flagBox then return end
    local m = DFKit.metrics
    local R = DFKit.layout(panel, x, y, w, h)

    local foot = R:footer(m.btnH + m.pad)
    V.footRect = { x = foot.x, y = foot.y, w = foot.w, h = foot.h }
    local bx = foot.x + foot.w
    for _, b in ipairs({ V.deleteBtn, V.createBtn }) do
        if b then
            bx = bx - b:getWidth()
            b:setX(bx); b:setY(foot.y)
            bx = bx - m.gap
        end
    end
    V.footTextW = bx - foot.x - m.gap

    -- Even halves: neither kind is the subordinate one, and a 34/66 split would
    -- say otherwise.
    -- THE CAPTIONS GET A SLICED BAND, not a negative offset off the lists' top
    -- edge. Region:header exists for exactly this (DFKit.lua:466-472) and this
    -- tab was drawing "FLAGS (n)" at listY - pad - 2 instead: two pixels of
    -- clearance for a line of text that is twelve tall, so the caption rendered
    -- underneath its own list border. DFPlayersTab reserves the band the same
    -- way (DFPlayersTab.lua:761-763) and does not have the bug.
    --
    -- rowHeight() rather than metrics.headerH because it MEASURES the font
    -- (DFKit.lua:325-333) and the text tier is a client preference - a flat 20
    -- is only tall enough at Small, which is how the collision hid this long.
    local head = R:header(DFKit.rowHeight())
    V.headY = head.y + 2

    local left, right = R:splitH(0.5, PANE_MIN, PANE_MIN)
    DFKit.sizeList(V.flagBox, left.x, left.y, left.w, left.h)
    DFKit.sizeList(V.counterBox, right.x, right.y, right.w, right.h)
    V.leftRect, V.rightRect = left, right
end

function DFVarsView.draw(el)
    local t = DFKit.col.textDim

    -- Column headings, drawn rather than made widgets: they never change and a
    -- label per list is two more things to lay out. They sit in the band
    -- layout() reserved for them - see there for why that is not optional.
    if V.leftRect and V.headY then
        local flags, counters = DFVarsView.split(V.defs)
        el:drawText("FLAGS  (" .. #flags .. ")", V.leftRect.x, V.headY,
                    t.r, t.g, t.b, 1, FONT)
        el:drawText("COUNTERS  (" .. #counters .. ")", V.rightRect.x, V.headY,
                    t.r, t.g, t.b, 1, FONT)
    end

    if V.status and V.footRect then
        local a = DFKit.col.accent
        el:drawText(DFKit.fitText(V.status, FONT, V.footTextW or 200),
                    V.footRect.x, V.footRect.y + 4, a.r, a.g, a.b, 1, FONT)
    end
end

function DFVarsView.onShow()
    DFVarsView.refresh()
end

return DFVarsView

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
