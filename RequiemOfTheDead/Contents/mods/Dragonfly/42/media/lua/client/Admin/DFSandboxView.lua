-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFSandboxView - the suite's sandbox options, rendered. Read-only for now.
--
-- Pairs with DFSandboxModel, which does the reflection and the grouping. This
-- file owns nothing but presentation: what a row looks like, how tall it is,
-- and which mod is selected. Keeping the split means the part with all the
-- engine assumptions in it stays testable, and the part that cannot be tested
-- stays small.
--
-- ---------------------------------------------------------------------------
-- WHAT THIS IMPROVES ON, because "a prettier vanilla screen" is not a reason to
-- build one. Three things the settings screen does not do:
--
--   1. ONE PAGE PER MOD, side by side. Vanilla nests every mod page in a combo
--      and shows one at a time, so comparing Dirge's rate against Reaper's is
--      two navigations and a memory test.
--   2. THE DESCRIPTION IS VISIBLE. Vanilla hides it in a hover tooltip, which
--      means an admin scanning forty options either knows what they all do
--      already or hovers forty times. Measured across the suite: median 207
--      characters, 72% under 300. A three-line clamp shows ~87% in full, and
--      the selected row expands to the rest.
--   3. CHANGED-FROM-DEFAULT IS MARKED. "What has this server actually changed"
--      is the first question when debugging one, and neither vanilla screen
--      can answer it.
--
-- ---------------------------------------------------------------------------
-- READ-ONLY, DELIBERATELY, FOR NOW. Editing is the next slice and it is a
-- bigger one than it looks: SandboxOptions.sendToServer() serialises the ENTIRE
-- option set, so instant-apply would let two admins editing different options
-- clobber each other across every option on the server. That needs batching and
-- a re-read before push, which is its own change with its own failure modes.
-- Shipping the read half first means the reflection is proven against a live
-- server before anything can write through it.
--
-- ---------------------------------------------------------------------------
-- ROW HEIGHTS VARY, which ISScrollingListBox supports but does not advertise:
-- addItem stamps i.height from self.itemheight (ISScrollingListBox.lua:141-150)
-- and everything downstream reads v.height, not the box default - rowAt (:66-69),
-- the scroll accumulation (:519, :540) and doDrawItem's own skip test (:305-310).
-- So a row is free to be taller as long as its height is stamped after the add.
-- Get that wrong and the list draws correctly while hit-testing the wrong row,
-- which is the worst of both.

if isServer() then return end

require "DFKit"
-- Path-relative to the lua TIER root, not a bare name: this module sits in
-- client/Admin/, so a bare "DFSandboxModel" does not resolve and the require
-- throws at load. Same form as Longstrider's `require "Longstrider/LSTour"`.
-- check-lua is syntax only, so a wrong path here parses clean and fails in game
-- (CLAUDE.md sect. 1).
require "Admin/DFSandboxModel"
require "ISUI/ISScrollingListBox"

DFSandboxView = DFSandboxView or {}
local V = DFSandboxView

local FONT      = DFKit.font.small
local DESC_FONT = DFKit.font.small
local NAV_MIN   = 160
local DESC_CLAMP = 3          -- lines shown on an unselected row
local MARK_W    = 14          -- gutter for the changed-from-default mark
local VALUE_W   = 110

V.mods       = {}
V.selected   = nil            -- page name of the chosen mod
V.selectedRow= nil            -- option name of the chosen row, or nil

-- ---------------------------------------------------------------------------
-- Row building - PURE, and separated from drawing on purpose.
--
-- This is the half with the arithmetic in it, and the RPNecroTab lesson says a
-- file-local predicate inside a UI module is a predicate no fixture will ever
-- load (see TODO.md). So it takes a model, a width and a selection, returns
-- plain tables, and touches no widget. DFKit.wrapText is the one engine-facing
-- call and it is injected, so a fixture supplies its own measurer.
-- ---------------------------------------------------------------------------

-- Returns a flat list of rows:
--   { kind = "section", title = str, height = n }
--   { kind = "option", opt = <model row>, lines = {str,...}, clamped = bool, height = n }
--
-- `wrap` is DFKit.wrapText's signature (text, font, maxW) -> lines.
function DFSandboxView.rowsFor(mod, descW, selectedName, rowH, wrap)
    local out = {}
    if not mod then return out end
    rowH = rowH or 22
    wrap = wrap or DFKit.wrapText

    for _, sec in ipairs(mod.sections or {}) do
        if sec.title then
            out[#out + 1] = { kind = "section", title = sec.title, height = rowH }
        end
        for _, opt in ipairs(sec.options or {}) do
            local selected = (selectedName ~= nil and opt.name == selectedName)
            local lines = wrap(opt.tooltip or "", DESC_FONT, descW) or {}
            local clamped = false
            -- The selected row shows everything; every other row stops at the
            -- clamp. Unclamped, Dirge's 64 options are a wall of prose and the
            -- list stops being scannable, which is the thing it is for.
            if not selected and #lines > DESC_CLAMP then
                local cut = {}
                for i = 1, DESC_CLAMP do cut[i] = lines[i] end
                lines, clamped = cut, true
            end
            out[#out + 1] = {
                kind = "option", opt = opt, lines = lines, clamped = clamped,
                -- One row for the label/value line, then the description.
                height = rowH + (#lines * (rowH - 6)),
            }
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- The two lists
-- ---------------------------------------------------------------------------

local NavList = ISScrollingListBox:derive("DFSandboxNav")

function NavList:doDrawItem(y, item, alt)
    local mod = item.item
    if not mod then return y + item.height end
    local on = (V.selected == mod.page)
    if on then
        local a = DFKit.col.accentDim
        self:drawRect(0, y, self.width, item.height - 1, 0.55, a.r, a.g, a.b)
    elseif alt then
        self:drawRect(0, y, self.width, item.height - 1, 0.10, 1, 1, 1)
    end
    local c = on and DFKit.col.text or DFKit.col.textDim
    local label = DFKit.fitText(mod.label or mod.page, FONT, self.width - 40)
    self:drawText(label, 6, y + 3, c.r, c.g, c.b, 1, FONT)
    local n = tostring(mod.count or 0)
    local nw = getTextManager():MeasureStringX(FONT, n)
    local d = DFKit.col.textDim
    self:drawText(n, self.width - nw - 6, y + 3, d.r, d.g, d.b, 1, FONT)
    return y + item.height
end

function NavList:onMouseDown(x, y)
    local idx = self:rowAt(x, y)
    if idx <= 0 then return end
    local item = self.items[idx]
    if item and item.item then
        V.selected    = item.item.page
        V.selectedRow = nil
        self.selected = idx
        V.refillOptions()
    end
end

local OptList = ISScrollingListBox:derive("DFSandboxOpts")

function OptList:doDrawItem(y, item, alt)
    local row = item.item
    if not row then return y + item.height end
    local m = DFKit.metrics

    if row.kind == "section" then
        -- A real divider, which is the whole reason the model strips the
        -- underscore scenery off the header decoy's translation: the vanilla
        -- screen can only draw a checkbox, so a section there has to be faked
        -- with punctuation. Here it can just be a rule.
        local l = DFKit.col.line
        local t = DFKit.col.textDim
        local tw = getTextManager():MeasureStringX(FONT, row.title)
        local ty = y + math.floor((item.height - 14) / 2)
        self:drawText(row.title, 4, ty, t.r, t.g, t.b, 1, FONT)
        self:drawRect(tw + 10, ty + 7, self.width - tw - 16, 1, 0.5, l.r, l.g, l.b)
        return y + item.height
    end

    local opt = row.opt
    if V.selectedRow == opt.name then
        local a = DFKit.col.accentDim
        self:drawRect(0, y, self.width, item.height - 1, 0.40, a.r, a.g, a.b)
    elseif alt then
        self:drawRect(0, y, self.width, item.height - 1, 0.08, 1, 1, 1)
    end

    -- The changed-from-default mark, read LIVE rather than cached with the row:
    -- another admin can turn a knob in the vanilla screen while this panel is
    -- open, and the mark going stale would be a lie about server state.
    if not DFSandboxModel.isDefault(opt.name) then
        local a = DFKit.col.accent
        self:drawRect(4, y + 8, 5, 5, 1, a.r, a.g, a.b)
    end

    local c = DFKit.col.text
    local label = DFKit.fitText(opt.label or opt.short, FONT,
                                self.width - MARK_W - VALUE_W - 12)
    self:drawText(label, MARK_W, y + 3, c.r, c.g, c.b, 1, FONT)

    local value = DFSandboxModel.valueOf(opt.name)
    if value ~= nil then
        local vs = DFKit.fitText(tostring(value), FONT, VALUE_W)
        local vw = getTextManager():MeasureStringX(FONT, vs)
        local vc = DFKit.col.textDim
        self:drawText(vs, self.width - vw - 8, y + 3, vc.r, vc.g, vc.b, 1, FONT)
    end

    local d  = DFKit.col.textDim
    local ly = y + DFKit.rowHeight() - 4
    local lh = DFKit.rowHeight() - 6
    for i, line in ipairs(row.lines) do
        local text = line
        if row.clamped and i == #row.lines then text = text .. " ..." end
        self:drawText(text, MARK_W + 4, ly, d.r * 0.9, d.g * 0.9, d.b * 0.9, 1, DESC_FONT)
        ly = ly + lh
    end
    return y + item.height
end

function OptList:onMouseDown(x, y)
    local idx = self:rowAt(x, y)
    if idx <= 0 then return end
    local item = self.items[idx]
    local row = item and item.item
    if not row or row.kind ~= "option" then return end
    -- Clicking the selected row again collapses it. Without that, the only way
    -- to shrink an expanded description is to expand a different one.
    V.selectedRow = (V.selectedRow == row.opt.name) and nil or row.opt.name
    self.selected = idx
    V.refillOptions()
end

-- NO render() OVERRIDE HERE, and that is deliberate rather than forgotten -
-- seven other lists in the family carry one and every copy is inert.
--
-- The override is the four-line "set a full-size stencil, call up, clear it"
-- shape, written to stop rows drawing outside the list. Rows never could:
-- ISScrollingListBox:prerender draws EVERY row itself, inside a stencil it sets
-- at :505 and clears at :541, clamped to the scrollbar edge when one is visible
-- (:494-496). ISScrollingListBox:render (:642-647) draws no rows at all - it
-- clears a stencil if useStencilForChildren is set, then draws a joypad focus
-- border. So the override clips a focus rectangle and nothing else.
--
-- check-helpers is what surfaced this: adding an eighth copy tripped Dragonfly's
-- ratchet, and the copy turned out to be unnecessary rather than promotable.
-- The seven existing ones are noted in TODO.md; sweeping them is not this slice.

-- ---------------------------------------------------------------------------
-- Refills
-- ---------------------------------------------------------------------------

local function refillNav()
    DFKit.refillList(V.navBox, function(box)
        for _, mod in ipairs(V.mods) do
            local i = box:addItem(mod.label or mod.page, mod)
            i.height = DFKit.rowHeight()
        end
    end)
end

-- Public because both mouse handlers call it, and because layout calls it after
-- a width change - the description wrap depends on the pane width, so a resize
-- genuinely changes how tall every row is.
function DFSandboxView.refillOptions()
    if not V.optBox then return end
    local mod
    for _, m in ipairs(V.mods) do if m.page == V.selected then mod = m end end

    local descW = math.max(80, (V.optW or 400) - MARK_W - 20)
    local rows = DFSandboxView.rowsFor(mod, descW, V.selectedRow,
                                       DFKit.rowHeight(), DFKit.wrapText)
    DFKit.refillList(V.optBox, function(box)
        for _, row in ipairs(rows) do
            local i = box:addItem("", row)
            -- Stamped AFTER the add: addItem writes itemheight, and every
            -- consumer downstream reads the item's own value.
            i.height = row.height
        end
    end)
end

local function reload()
    V.mods = DFSandboxModel.build() or {}
    if not V.selected and V.mods[1] then V.selected = V.mods[1].page end
    refillNav()
    DFSandboxView.refillOptions()
end

-- ---------------------------------------------------------------------------
-- The DFViews contract - attach / layout / draw / onShow.
--
-- Implemented in full even though nothing hosts a strip yet: the Server sub-tab
-- lands next and the host swaps a direct call for a DFViews registration, with
-- nothing here changing.
-- ---------------------------------------------------------------------------

function DFSandboxView.attach(panel)
    local nav = NavList:new(0, 0, 10, 10)
    nav.itemheight = DFKit.rowHeight()
    nav.drawBorder = true
    DFKit.well(nav)
    nav:initialise(); nav:instantiate()
    panel:addChild(nav)
    V.navBox = nav

    local opts = OptList:new(0, 0, 10, 10)
    opts.itemheight = DFKit.rowHeight()
    opts.drawBorder = true
    DFKit.well(opts)
    opts:initialise(); opts:instantiate()
    panel:addChild(opts)
    V.optBox = opts

    reload()
    return { nav, opts }
end

function DFSandboxView.layout(panel, x, y, w, h)
    if not V.navBox then return end
    local R = DFKit.layout(panel, x, y, w, h)
    local legend = R:footer(DFKit.rowHeight())
    V.legendRect = { x = legend.x, y = legend.y, w = legend.w, h = legend.h }

    local navR, optR = R:splitH(0.22, NAV_MIN, 300)
    DFKit.sizeList(V.navBox, navR.x, navR.y, navR.w, navR.h)

    -- A width change alters the description wrap, which alters every row's
    -- height, so the list is genuinely stale after a resize rather than merely
    -- differently shaped.
    local changed = (V.optW ~= optR.w)
    V.optW = optR.w
    DFKit.sizeList(V.optBox, optR.x, optR.y, optR.w, optR.h)
    if changed then DFSandboxView.refillOptions() end
end

function DFSandboxView.draw(el)
    local r = V.legendRect
    if not r then return end
    local a, d = DFKit.col.accent, DFKit.col.textDim
    el:drawRect(r.x, r.y + 7, 5, 5, 1, a.r, a.g, a.b)
    el:drawText("changed from default", r.x + 12, r.y + 2, d.r, d.g, d.b, 1, FONT)

    if #V.mods == 0 then
        DFKit.drawEmpty(el, r.x, r.y - 40, r.w, 30,
            "No RFTD sandbox options found.")
    end
end

-- Rebuilt on show rather than cached: the SHAPE cannot change while a world is
-- running, but a mod list read once at boot would miss nothing and cost the
-- same, so this is really about values - and those are read live per draw
-- anyway. What onShow buys is the mod list after a font-tier rebuild.
function DFSandboxView.onShow() reload() end

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
