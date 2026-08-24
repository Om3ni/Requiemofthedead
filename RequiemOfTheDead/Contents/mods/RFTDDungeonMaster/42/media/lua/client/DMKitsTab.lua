-- SPDX-License-Identifier: GPL-3.0-or-later
-- DMKitsTab - the kit catalogue, on Dragonfly's deck (client only).
--
-- This file owns NAVIGATION: what kits exist, what the selected one contains,
-- and the four verbs that act on a whole kit. One kit's SHAPE lives in
-- DMKitForm, opened by clicking a row. They change for different reasons - a
-- list gains a sort, a kit gains a grant kind.
--
-- ---------------------------------------------------------------------------
-- SOFT DRAGONFLY INTEGRATION, exactly as RFTDStaffTools does it. This mod
-- requires RFTDCore and nothing else; DFRegistry lives in Core, so registering
-- a tab costs no dependency, and with Dragonfly disabled the registration is
-- simply never rendered by anything. There is no hard edge from gameplay to
-- the presentation layer (CLAUDE.md sect. 12).
--
-- ---------------------------------------------------------------------------
-- SELECTION IS AN ID, never a row index. Every verb here triggers a server
-- push, the push rebuilds the list, and DFKit.refillList calls clear() - which
-- sets `selected = 1` (ISScrollingListBox.lua:340-345). A tab that read its
-- target off the widget would delete a kit, refresh, silently point at whatever
-- is now first, and delete THAT on the next click. Same rule, same reason, as
-- DFVarsView.
--
-- ---------------------------------------------------------------------------
-- THE REPLY ENVELOPE IS SHARED WITH THE PLAYER'S CLAIM WINDOW. One client can
-- be both this tab and somebody with a Kits window open, and both are answered
-- with KitResult on one token. Every reply names the command it answers
-- (DMKits_Server), so this file renders only its own four verbs' answers and
-- leaves kitClaim's to DMClaim. Without that test an admin claiming a kit would
-- see the delivery report land in the authoring footer.

if isServer() then return end

require "DFKit"
require "DMIcons"
require "DFConfirm"
require "DMKitDefs"
require "DMKitForm"
require "DMClaimants"
require "ISUI/ISScrollingListBox"
require "ISUI/ISTextBox"

DMKitsTab = DMKitsTab or {}
local V = DMKitsTab

local TOKEN = "RFTDDungeonMaster"
local FONT  = DFKit.font.small
local LIST_MIN = 220

-- The verbs this tab is responsible for rendering answers to. kitClaim and
-- kitMine belong to the player's window; a set rather than a list because the
-- test runs on every reply.
local MINE = {
    kitDefine = true, kitDelete = true, kitForget = true, kitGrantTo = true,
    -- kitForgetOne is deliberately ABSENT: its answer belongs to the claimants
    -- window that asked, and showing it in the tab footer as well would report
    -- one act twice.
}

V.kits     = {}     -- the catalogue as the server sent it
V.selected = nil    -- kit ID
V.status   = nil
V.claimants = nil   -- { id, rows } for the selected kit, or nil
V.totals    = {}    -- id -> how many times it has been claimed, over everyone

-- ---------------------------------------------------------------------------
-- Pure
-- ---------------------------------------------------------------------------

-- Sorted by LABEL, which is what the row draws. The wire delivers whatever
-- order the store's pairs() produced, and a catalogue that reshuffles between
-- two reads of an unchanged server is a list an admin cannot scan.
--
-- Ties break on id so the order is total: two kits may legitimately share a
-- label ("Anomaly Loot" for two seasons), and without the tiebreak those two
-- swap places on every refresh.
function DMKitsTab.sorted(kits)
    local out = {}
    for _, k in ipairs(kits or {}) do out[#out + 1] = k end
    table.sort(out, function(a, b)
        local la, lb = tostring(a.label or a.id), tostring(b.label or b.id)
        if la ~= lb then return la < lb end
        return tostring(a.id) < tostring(b.id)
    end)
    return out
end

-- The row's right-hand column: the kind, and whether it can be taken twice.
-- Both are properties an admin scans for rather than opens a kit to learn -
-- "how often can this be taken" is the question behind every farm, and it is
-- now a duration rather than a yes/no - so the row says the duration.
function DMKitsTab.tagFor(k)
    if not k then return "" end
    return tostring(k.kind or "?") .. "  " .. DMKitDefs.claimText(k)
end

-- What the detail pane says about a kit, as lines. PURE, because it is the
-- summary an admin reads INSTEAD of opening the editor, and a summary that
-- omits a grant is worse than no summary at all - it is a kit that does more
-- than the panel says it does.
--
-- Roulette branches are counted, not expanded: a ten-branch table would push
-- everything else off the pane, and the odds belong in the editor next to the
-- weights that produce them.
function DMKitsTab.summaryOf(k)
    local out = {}
    if not k then return out end

    out[#out + 1] = "id: " .. tostring(k.id)
    if k.note and k.note ~= "" then out[#out + 1] = k.note end

    local req = k.requires or {}
    local flags, counters = req.flags or {}, req.counters or {}
    if #flags == 0 and #counters == 0 then
        out[#out + 1] = "Requires: nothing - anyone may claim it"
    else
        for _, name in ipairs(flags) do
            out[#out + 1] = "Requires flag: " .. tostring(name)
        end
        for _, c in ipairs(counters) do
            out[#out + 1] = "Requires counter: " .. tostring(c.name)
                .. " at least " .. tostring(c.atLeast)
        end
    end

    for i, g in ipairs(k.grants or {}) do
        out[#out + 1] = i .. ". " .. DMKitForm.grantLine(g)
    end

    -- THE ODDS, admin-side only (owner, 2026-08-23). The player's payload is
    -- built without them server-side, so this is the only surface that has the
    -- numbers at all - and tuning a drop table you cannot see the shape of is
    -- guesswork. Projected from the raw definition, which kitList ships whole
    -- to this tab, so no second round trip.
    for _, row in ipairs(DMKitDefs.contents(k, true)) do
        if row.kind == DMKitDefs.ROULETTE then
            out[#out + 1] = ""
            out[#out + 1] = DMIcons.rouletteHeading(row)
            for _, b in ipairs(row.branches or {}) do
                local odds = DMIcons.oddsText(b)
                local what = {}
                for _, r in ipairs(b.rows or {}) do
                    what[#what + 1] = DMIcons.label(r)
                end
                out[#out + 1] = "   " .. (odds ~= "" and (odds .. "  ") or "")
                    .. (#what > 0 and table.concat(what, ", ")
                                  or "(bookkeeping only)")
            end
        end
    end
    return out
end

-- How many times this kit has been claimed, over everyone. Absent means none -
-- the server omits a kit nobody has taken rather than sending a zero for every
-- row in the catalogue.
function DMKitsTab.claimTotal(id)
    return tonumber(V.totals and V.totals[id]) or 0
end

local function selectedKit()
    for _, k in ipairs(V.kits) do if k.id == V.selected then return k end end
end

-- ---------------------------------------------------------------------------
-- Wire
-- ---------------------------------------------------------------------------

function DMKitsTab.refresh()
    RDNet.send(TOKEN, "kitList", {})
end

function DMKitsTab.receive(command, args)
    if command == "KitList" then
        V.kits   = (args and args.kits) or {}
        V.totals = (args and args.totals) or {}
        -- A selection whose kit is gone becomes NO selection rather than
        -- sliding onto a neighbour. Delete and Re-open are both in the footer.
        if V.selected and not selectedKit() then
            V.selected, V.claimants = nil, nil
        end
        DMKitsTab.rebuild()
        return true

    elseif command == "KitsStale" then
        DMKitsTab.refresh()
        return true

    elseif command == "KitLog" then
        -- Belongs entirely to the read-out window; this tab has no use for it
        -- and says so by consuming nothing.
        DMClaimants.observe(command, args)
        return true

    elseif command == "KitClaimants" then
        -- Answers arrive unordered against clicks. One for a kit that is no
        -- longer selected is dropped rather than drawn under the current one,
        -- which would attribute one kit's claimants to another.
        if args and args.id == V.selected then V.claimants = args end
        -- The window OBSERVES the same push rather than claiming it: both it
        -- and this tab's summary pane legitimately want it, and whichever
        -- rendered second would otherwise never see one.
        DMClaimants.observe(command, args)
        return true

    elseif command == "KitResult" then
        -- Only this tab's own verbs. kitClaim's answer belongs to the player's
        -- window, and an admin claiming a kit would otherwise watch the
        -- delivery report appear in the authoring footer.
        if not (args and MINE[args.command]) then
            -- Not ours. Offered to the windows that might own it - kitForgetOne
            -- is answered on this same envelope and belongs to the claimants
            -- window that asked for it. Handing it over here rather than in a
            -- second KitResult branch, which would never be reached.
            DMClaimants.observe(command, args)
            return false
        end
        V.status = args.ok and tostring(args.message) or tostring(args.reason)
        if DFFeedback then
            if args.ok then DFFeedback.good(V.status) else DFFeedback.bad(V.status) end
        end
        if args.ok then DMKitForm.acknowledge(args) end
        return true

    end
    return false
end

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= TOKEN then return end
    DMKitsTab.receive(command, args)
end)

-- ---------------------------------------------------------------------------
-- The list
-- ---------------------------------------------------------------------------

local KitList = ISScrollingListBox:derive("DMKitList")

function KitList:doDrawItem(y, item, alt)
    local k = item.item
    if not k then return y + item.height end
    local on = (V.selected == k.id)
    if on then
        local a = DFKit.col.accentDim
        self:drawRect(0, y, self.width, item.height - 1, 0.55, a.r, a.g, a.b)
    elseif alt then
        self:drawRect(0, y, self.width, item.height - 1, 0.10, 1, 1, 1)
    end
    self:drawRectBorder(0, y, self.width, item.height, 0.12, 1, 1, 1)

    local c = on and DFKit.col.text or DFKit.col.textDim
    local d = DFKit.col.textDim
    local tag = DMKitsTab.tagFor(k)
    local tw  = getTextManager():MeasureStringX(FONT, tag)

    -- TWO BOXES ON THE RIGHT, and the pair is deliberate. The COUNT opens who
    -- took it; CLEAR wipes every one of those claims so an event kit can run
    -- again without being duplicated or unpicked player by player (owner,
    -- 2026-08-24). They sit together because they are two halves of one
    -- question - how many, and start over - and a box that DOES something has
    -- to look unlike a number that does not.
    --
    -- Clear is destructive and confirmed. It is also drawn dim and only lit
    -- when there is something to clear: an unlit box on a kit nobody has taken
    -- is a click that would ask a frightening question about nothing.
    local n  = DMKitsTab.claimTotal(k.id)
    local ns = tostring(n)
    local nw = math.max(24, getTextManager():MeasureStringX(FONT, ns) + 12)
    local bx = self.width - nw - 4
    local by = y + 2
    local bh = item.height - 5
    local lit = n > 0
    self:drawRect(bx, by, nw, bh, lit and 0.5 or 0.22,
        DFKit.col.bg.r, DFKit.col.bg.g, DFKit.col.bg.b)
    self:drawRectBorder(bx, by, nw, bh, lit and 0.55 or 0.25,
        DFKit.col.line.r, DFKit.col.line.g, DFKit.col.line.b)
    local nc = lit and DFKit.col.text or DFKit.col.textDim
    self:drawText(ns, bx + math.floor((nw - getTextManager():MeasureStringX(FONT, ns)) / 2),
                  y + 3, nc.r, nc.g, nc.b, 1, FONT)
    -- Recorded so the click can find it. Widths are font-dependent, so the hit
    -- rect is whatever was actually drawn rather than a constant guessed here.
    self.countX, self.countW = bx, nw

    local CLEAR = "Clear"
    local cw = getTextManager():MeasureStringX(FONT, CLEAR) + 12
    local cx = bx - DFKit.metrics.gap - cw
    self:drawRect(cx, by, cw, bh, lit and 0.5 or 0.22,
        DFKit.col.bg.r, DFKit.col.bg.g, DFKit.col.bg.b)
    self:drawRectBorder(cx, by, cw, bh, lit and 0.55 or 0.25,
        DFKit.col.line.r, DFKit.col.line.g, DFKit.col.line.b)
    local cc = lit and DFKit.col.warn or DFKit.col.textDim
    self:drawText(CLEAR, cx + 6, y + 3, cc.r, cc.g, cc.b, 1, FONT)
    self.clearX, self.clearW = cx, cw

    self:drawText(tag, cx - tw - 8, y + 3, d.r, d.g, d.b, 1, FONT)
    self:drawText(DFKit.fitText(k.label or k.id, FONT,
                                self.width - tw - nw - cw - 34),
                  6, y + 3, c.r, c.g, c.b, 1, FONT)
    return y + item.height
end

function KitList:onMouseDown(x, y)
    local idx = self:rowAt(x, y)
    if idx < 1 or idx > #self.items then return end
    local k = self.items[idx].item
    if not k then return end
    self.selected = idx
    V.selected, V.status = k.id, nil
    -- THREE TARGETS ON ONE ROW, decided here so the drawing and the routing
    -- read off the same rects. The row still selects underneath either box, so
    -- the summary pane is always describing the kit being acted on.
    self.wantClaimants = (self.countX ~= nil and x >= self.countX
                          and x < self.countX + (self.countW or 0))
    self.wantClear = (self.clearX ~= nil and x >= self.clearX
                      and x < self.clearX + (self.clearW or 0))
    -- Claimants are read on SELECTION rather than with the catalogue: the
    -- catalogue is one packet for every kit, and a claimant list per kit inside
    -- it would grow with the roster times the number of kits for a pane only
    -- one of them is ever showing.
    V.claimants = nil
    RDNet.send(TOKEN, "kitClaimants", { id = k.id })
end

-- Single click opens it, matching the Variables tab. Opening a kit is not a
-- destructive act; the destructive verbs are in the footer behind confirmations.
function KitList:onMouseUp(x, y)
    ISScrollingListBox.onMouseUp(self, x, y)
    local idx = self:rowAt(x, y)
    if idx < 1 or idx > #self.items then return end
    local k = self.items[idx].item
    if not k then return end
    -- Neither box opens the editor. Opening the kit is the common act and gets
    -- the whole rest of the row; the two boxes are small targets on purpose.
    if self.wantClear then
        self.wantClear = false
        DMKitsTab.clearAll(k)
        return
    end
    if self.wantClaimants then
        self.wantClaimants = false
        DMClaimants.open(k)
        return
    end
    DMKitForm.open(k)
end

-- Clear every claim on this kit. The event-rerun verb: one act instead of
-- duplicating the kit or unpicking two hundred players by hand.
--
-- CONFIRMED, and the confirmation says the number, because "clear" reads the
-- same whether it is undoing one mis-delivery or re-opening a season's reward
-- to everybody who already took it. The per-player version lives in the
-- claimants window and is a different verb on the wire.
function DMKitsTab.clearAll(k)
    if not k then return end
    local n = DMKitsTab.claimTotal(k.id)
    if n <= 0 then
        V.status = "Nobody has claimed '" .. (k.label or k.id) .. "' yet."
        return
    end
    DFConfirm.ask("Clear ALL " .. n .. " claim(s) on '" .. (k.label or k.id)
        .. "'?\n\nEveryone who has taken it will be able to take it again, "
        .. "and their claim counts start from zero. To reset one player "
        .. "instead, open the count beside this button.",
        function() RDNet.send(TOKEN, "kitForget", { id = k.id }) end)
end

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------

function DMKitsTab.rebuild()
    if not V.listBox then return end
    DFKit.refillList(V.listBox, function(box)
        for _, k in ipairs(DMKitsTab.sorted(V.kits)) do
            local i = box:addItem(k.label or k.id, k)
            i.height = DFKit.rowHeight()
        end
    end)
    -- Put the widget back where the ID says it is; see the header.
    V.listBox.selected = -1
    if V.selected then
        for i, item in ipairs(V.listBox.items) do
            if item.item and item.item.id == V.selected then
                V.listBox.selected = i
                break
            end
        end
        if V.listBox.selected == -1 then V.selected, V.claimants = nil, nil end
    end
end

local function needSelection()
    if V.selected then return selectedKit() end
    V.status = "Select a kit first."
    return nil
end

local function askUser(prompt, then_)
    local modal
    modal = ISTextBox:new(getCore():getScreenWidth() / 2 - 150,
        getCore():getScreenHeight() / 2 - 60, 300, 120, prompt, "", nil,
        function(_, btn)
            if btn.internal ~= "OK" or not (modal and modal.entry) then return end
            local text = modal.entry:getText()
            if text and text ~= "" then then_(text) end
        end, getPlayer() and getPlayer():getPlayerNum() or 0)
    modal:initialise(); modal:addToUIManager()
end

-- Declared before build uses it. Lua resolves a LOCAL at compile time, so a
-- `local function layout` further down is a different, nil upvalue here -
-- which parses clean and throws the first time the tab is opened.
local layout

local function build(spec, panel, x, y, w, h)
    V.kits, V.selected, V.claimants, V.status = {}, nil, nil, nil

    local list = KitList:new(0, 0, 10, 10)
    list.itemheight = DFKit.rowHeight()
    list.drawBorder = true
    DFKit.well(list)
    list:initialise(); list:instantiate()
    panel:addChild(list)
    V.listBox = list

    V.createBtn = DFKit.button(panel, 0, 0, 96, "Create New", panel,
        function() DMKitForm.openNew() end, "action",
        { tooltip = "Author a new kit. Definitions are server-wide." })

    V.giveBtn = DFKit.button(panel, 0, 0, 90, "Give to...", panel, function()
        local k = needSelection(); if not k then return end
        askUser("Give '" .. (k.label or k.id) .. "' to which player?",
            function(user)
                RDNet.send(TOKEN, "kitGrantTo", { id = k.id, username = user })
            end)
    end, nil, { tooltip = "Hand this kit to a player who is online now. "
             .. "Requirements are NOT checked - a staff grant is the authority "
             .. "the requirements stood in for - but a one-time kit already "
             .. "taken is still refused." })

    -- No footer Re-open: it moved onto the row as Clear (owner, 2026-08-24),
    -- where the count it undoes is already on screen. Two affordances for one
    -- destructive verb is one of them going stale.

    V.logBtn = DFKit.button(panel, 0, 0, 92, "Claim log", panel, function()
        DMClaimants.openLog()
    end, nil, { tooltip = "When each kit was claimed, by whom, and what was "
        .. "handed over. A bounded window, not the archive." })

    V.deleteBtn = DFKit.button(panel, 0, 0, 76, "Delete", panel, function()
        local k = needSelection(); if not k then return end
        DFConfirm.ask("Delete '" .. (k.label or k.id) .. "'?\n\n"
            .. "Its CLAIMS are kept, so recreating the same id will not "
            .. "re-open it for anybody who already took it.",
            function() RDNet.send(TOKEN, "kitDelete", { id = k.id }) end)
    end, nil, { tooltip = "Delete this kit. Claims survive on purpose - use "
             .. "Re-open to clear them." })

    -- The detail pane is DRAWN, not built out of widgets: it is a read-only
    -- summary whose line count changes with the selected kit, and a widget per
    -- line would mean creating and destroying a dozen labels per click. Same
    -- attachment RCVehicleTab uses (RCVehicleTab.lua:979-982) - wrap the host
    -- panel's prerender rather than replace it, so a second tenant on the same
    -- panel keeps whatever it drew.
    local orig = panel.prerender
    panel.prerender = function(self_)
        if orig then orig(self_) end
        DMKitsTab.draw(self_)
    end

    layout(panel, x, y, w, h)
    DMKitsTab.refresh()
end

layout = function(panel, x, y, w, h)
    if not V.listBox then return end
    local m = DFKit.metrics
    local R = DFKit.layout(panel, x, y, w, h)

    local foot = R:footer(m.btnH + m.pad)
    V.footRect = { x = foot.x, y = foot.y, w = foot.w, h = foot.h }
    -- NOT ipairs. It stops at the first nil, so a button that failed to be
    -- created leaves every button after it sitting at its creation spot -
    -- which is (0, 0), on top of the caption. That is exactly what happened to
    -- Create New when the Claim log button went missing (owner, 2026-08-24).
    local row = { V.deleteBtn, V.giveBtn, V.logBtn, V.createBtn }
    local bx = foot.x + foot.w
    for i = 1, 4 do
        local b = row[i]
        if b then
            bx = bx - b:getWidth()
            b:setX(bx); b:setY(foot.y)
            bx = bx - m.gap
        end
    end
    V.footTextW = bx - foot.x - m.gap

    -- The caption band is SLICED, never drawn at the list's top edge minus a
    -- padding. That mistake cost two screens in this suite on 2026-08-23 and
    -- the fix is the same one: Region:header (DFKit.lua:466-472), sized by
    -- rowHeight() so it survives a larger text tier.
    -- A gap above the caption so it does not butt against the deck chrome
    -- (owner, 2026-08-24).
    R:header(12)
    local head = R:header(DFKit.rowHeight())
    V.headY = head.y + 2

    local left, right = R:splitH(0.42, LIST_MIN, 260)
    DFKit.sizeList(V.listBox, left.x, left.y, left.w, left.h)
    V.leftRect, V.rightRect = left, right
end

function DMKitsTab.draw(el)
    local t = DFKit.col.textDim

    if V.leftRect and V.headY then
        el:drawText("KITS  (" .. #V.kits .. ")", V.leftRect.x, V.headY,
                    t.r, t.g, t.b, 1, FONT)
        local k = selectedKit()
        el:drawText(k and (k.label or k.id) or "No kit selected",
                    V.rightRect.x, V.headY, t.r, t.g, t.b, 1, FONT)
    end

    if V.rightRect then
        local r = V.rightRect
        local k = selectedKit()
        local lineH = DFKit.rowHeight()
        local yy = r.y + 4
        for _, line in ipairs(DMKitsTab.summaryOf(k)) do
            if yy + lineH > r.y + r.h then break end
            el:drawText(DFKit.fitText(line, FONT, r.w - 8), r.x + 4, yy,
                        t.r, t.g, t.b, 1, FONT)
            yy = yy + lineH
        end
        if k then
            -- The claimant count is a READ that had to be asked for, so its
            -- three states are three different sentences: not asked, asked and
            -- none, asked and some. Drawing "0 claims" while the answer is
            -- still in flight is the one that gets acted on.
            local line
            if not V.claimants then line = "reading claims..."
            else line = #(V.claimants.rows or {}) .. " player(s) have claimed this" end
            if yy + lineH <= r.y + r.h then
                el:drawText(line, r.x + 4, yy + 4, t.r, t.g, t.b, 1, FONT)
            end
        end
    end

    if V.status and V.footRect then
        local a = DFKit.col.accent
        el:drawText(DFKit.fitText(V.status, FONT, V.footTextW or 200),
                    V.footRect.x, V.footRect.y + 4, a.r, a.g, a.b, 1, FONT)
    end
end

-- ---------------------------------------------------------------------------
-- Registration
--
-- Deferred to OnGameStart, matching every other tab in the family: DFRegistry
-- is Core's and loads in the same client tier, so a file-scope registration
-- would depend on the alphabetical walk reaching DFRegistry.lua first.
-- ---------------------------------------------------------------------------

Events.OnGameStart.Add(function()
    if not DFRegistry then return end
    DFRegistry.registerTab{
        id         = "dmKits",
        label      = "Kits",
        -- The deck's order, spaced by ten so a new tab lands between two
        -- without renumbering five files: Admin 10, Players 20, Necro 30,
        -- Vehicles 40, Husbandry 50, Longstrider 60, Zones 70, Console 1000.
        order      = 80,
        -- The same gate the authoring commands declare. It greys the tab for
        -- somebody the server would refuse anyway, which is the only thing a
        -- client-side capability check is for.
        capability = Capability.SandboxOptions,
        build      = build,
        resize     = function(_, panel, w, h) layout(panel, 0, 0, w, h) end,
        -- No onShow hook exists on a deck tab and none is needed: DFDeck throws
        -- the content panel away and re-runs build on every selection
        -- (DFDeck.lua:283-297), so build IS the show, and the catalogue read at
        -- the end of it is what keeps a re-opened tab current.
    }
end)

return DMKitsTab

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
