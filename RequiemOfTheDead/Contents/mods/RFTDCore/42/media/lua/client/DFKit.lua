-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFKit - shared UI primitives for family tabs (client only).
--
-- WHY THIS EXISTS (2026-08-02): Core shipped DFRegistry, which tells a tab how
-- to ANNOUNCE itself and nothing about how to look. Every tab mod requires
-- RFTDCore and nothing else in common, so with no shared UI home each tab
-- hand-rolled its own. The result, measured across the eight registered tabs:
--
--   * HBAnimalsTab, HBHutchesTab and LMImportTab each define their own mkBtn,
--     identical down to `borderColor.a = 0.4`. Three copies, three mods.
--   * PAD is 8 in five tabs and 6 in RCVehicleTab. BTN_H is 24 in five and 22
--     in RCVehicleTab. Vehicles has been 2px tighter than the family forever,
--     because nobody could see the other numbers.
--   * LMImportTab writes labels at 0.85/0.85/0.85; RCVehicleTab writes column
--     headers at 0.7/0.7/0.9. DFTheme.col exists - but it lives inside
--     RFTDDragonfly, which a Husbandry tab cannot reach and may not have loaded.
--
-- So the primitives live HERE, in the one dependency all eight already share.
--
-- TOKENS vs STRUCTURE. Core owns both defaults, but only tokens are skinnable:
-- RFTDDragonfly's Growl skin calls DFKit.applySkin{...} to repaint, and never
-- changes geometry. That is what lets one tab render correctly in the classic
-- panel AND in the deck - which the deck's charter ("presentation only... the
-- glass they present through") requires and today's code cannot deliver.
--
-- Adoption is incremental and total non-adoption is fine: a tab that never
-- mentions DFKit keeps its raw rect and behaves exactly as it always has.

if isServer() then return end

DFKit = DFKit or {}

-- ---------------------------------------------------------------------------
-- Tokens - the skinnable layer
-- ---------------------------------------------------------------------------

-- Geometry is NOT skinnable. A skin that moves things breaks the promise that a
-- tab lays out identically in either shell.
DFKit.metrics = {
    pad     = 8,
    gap     = 6,
    btnH    = 24,
    rowH    = 22,
    headerH = 20,
    radius  = 3,
}

-- Semantic names, deliberately not Growl's vocabulary: Core must not know what
-- "scar" or "sight" mean. The Growl skin maps its palette onto these.
DFKit.col = {
    bg        = { r = 0.07, g = 0.07, b = 0.07 },
    panel     = { r = 0.13, g = 0.13, b = 0.13 },
    line      = { r = 0.29, g = 0.29, b = 0.29 },
    text      = { r = 0.85, g = 0.85, b = 0.85 },
    textDim   = { r = 0.60, g = 0.60, b = 0.60 },
    accent    = { r = 0.42, g = 0.72, b = 0.42 },
    accentDim = { r = 0.24, g = 0.40, b = 0.24 },
    ok        = { r = 0.42, g = 0.72, b = 0.42 },
    warn      = { r = 0.85, g = 0.65, b = 0.25 },
    danger    = { r = 0.80, g = 0.30, b = 0.30 },
}

-- Translucency. The reference point is vanilla ISCollapsableWindow, which
-- initialises backgroundColor a = 0.8 - that is what the classic Dragonfly
-- panel inherits. The deck sits a quarter lighter than that on purpose: the
-- Growl ground is much darker than vanilla's flat black, so matching 0.8
-- exactly read heavier than the old panel rather than the same.
--
-- Every value is that 0.8 reference scaled by 0.75, so the ratios between
-- ground, chrome and insets are preserved - change the scale, not one value,
-- or the panel loses its internal structure.
--
-- These stack: chrome draws OVER window, so keep chrome low or the title bar
-- and roster go effectively opaque (0.60 ground + 0.26 chrome reads ~0.70).
DFKit.alpha = {
    window = 0.60,   -- the panel's own ground
    chrome = 0.26,   -- title bar / roster strips, drawn over the ground
    card   = 0.22,   -- inset bands (verdict band)
    inset  = 0.19,   -- inset panes (detail pane, list wells)

    -- A black wash laid over the ground, under the content. Translucency let
    -- the world through and the world is brighter than Growl, so the panel
    -- read washed-out. Raising `window` would fix the brightness by REPLACING
    -- the world - that just undoes the translucency. A veil scales the whole
    -- composite instead: result = (1 - veil) x composite, so 0.12 is exactly
    -- 12% darker and the see-through ratio is untouched.
    --
    -- It goes under text and chrome detail, so type keeps its full contrast.
    veil   = 0.12,
}

DFKit.font = {
    small = UIFont and UIFont.Small or nil,
    label = UIFont and UIFont.Small or nil,
    code  = UIFont and UIFont.Code  or nil,
}

-- ---------------------------------------------------------------------------
-- FONT TIER - the "and the text size" half of a resizable panel.
--
-- PZ's fonts are discrete (UIFont.java:10-12 - Small, Medium, Large), so a panel
-- cannot scale type smoothly; it picks a rung. That is fine, because everything
-- in this kit already derives its geometry from the font: DFKit.rowHeight()
-- measures it, DFForm's metrics() derives every row, gutter and box from it, and
-- Reclamation's list computes max(18, fh + 4). Move the rung and those follow on
-- their own. Anything that hardcoded a pixel height does not, which is exactly
-- why the shared row height landed first.
--
-- THE TIER IS FAMILY-WIDE, deliberately. It lives on the kit, not on the deck,
-- so a tab laid out in the deck and the same tab laid out in the old panel agree
-- about how big text is - the whole point of the kit. The caller decides WHEN to
-- move it; DFDeck ties it to its own width.
--
-- Returns true when the tier actually changed, because a caller has to know:
-- ISLabel and ISButton bake their font at construction, so existing widgets keep
-- the old one until they are rebuilt. Changing the tier is a "rebuild the
-- surface" event, not a repaint.
-- ---------------------------------------------------------------------------

local FONT_TIERS = UIFont and { UIFont.Small, UIFont.Medium, UIFont.Large } or {}

DFKit.fontScale = 1

function DFKit.setFontScale(n)
    if #FONT_TIERS == 0 then return false end
    n = math.floor(tonumber(n) or 1)
    if n < 1 then n = 1 elseif n > #FONT_TIERS then n = #FONT_TIERS end
    if n == DFKit.fontScale then return false end
    DFKit.fontScale = n
    DFKit.font.small = FONT_TIERS[n]
    DFKit.font.label = FONT_TIERS[n]
    return true
end

-- A skin overrides colours (and fonts) only. Unknown keys are ignored rather
-- than merged blindly, so a skin cannot smuggle geometry in through this door.
function DFKit.applySkin(skin)
    if type(skin) ~= "table" then return end
    if type(skin.col) == "table" then
        for k, v in pairs(skin.col) do
            if DFKit.col[k] and type(v) == "table" then DFKit.col[k] = v end
        end
    end
    if type(skin.font) == "table" then
        for k, v in pairs(skin.font) do
            if DFKit.font[k] ~= nil or k == "code" then DFKit.font[k] = v end
        end
    end
    -- Alpha is paint, not geometry, so a skin may tune it. Clamped to [0,1]:
    -- an out-of-range alpha renders as a solid block, which is exactly the
    -- failure this token exists to prevent.
    if type(skin.alpha) == "table" then
        for k, v in pairs(skin.alpha) do
            if DFKit.alpha[k] and type(v) == "number" then
                DFKit.alpha[k] = math.max(0, math.min(1, v))
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Controls - what the three copies of mkBtn become
-- ---------------------------------------------------------------------------

-- kind: "action" (default) | "primary" | "warn" | "danger"
--
-- Weight follows INTENT, not each tab's taste. That is the fix for Necro's mass
-- cull rendering as the loudest pixel on screen while the scoped, safe, intended
-- action sat beside it in a weaker outline. Prominence should track
-- frequency x safety, never severity.
--
-- opts.hold = true makes the button require a press-and-hold to fire. Destructive
-- buttons should be recessive AND deliberate; passing kind="danger" alone still
-- leaves it one careless click away.
function DFKit.button(parent, x, y, w, label, target, onclick, kind, opts)
    local m = DFKit.metrics
    opts = opts or {}
    local btn = ISButton:new(x, y, w, opts.h or m.btnH, label, target, onclick)
    btn:initialise()
    btn:instantiate()

    local c = DFKit.col
    if kind == "primary" then
        btn.borderColor = { r = c.accent.r, g = c.accent.g, b = c.accent.b, a = 0.9 }
    elseif kind == "warn" then
        btn.borderColor = { r = c.warn.r, g = c.warn.g, b = c.warn.b, a = 0.8 }
    elseif kind == "danger" then
        btn.borderColor = { r = c.danger.r, g = c.danger.g, b = c.danger.b, a = 0.7 }
    else
        btn.borderColor = { r = c.line.r, g = c.line.g, b = c.line.b, a = 0.4 }
    end

    if opts.tooltip then btn:setTooltip(opts.tooltip) end

    -- Hold-to-fire. A destructive action should be deliberate, not one careless
    -- click. ISButton dispatches onclick from onMouseUp (ISButton.lua:47), so
    -- stamp the press in onMouseDown and gate the call on elapsed time.
    --
    -- There is no getTooltip() on ISButton - the tooltip is the plain `tooltip`
    -- field and setTooltip writes it. Calling a getter here is what threw
    -- "Object tried to call nil in button" on 2026-08-02.
    if opts.hold then
        local HOLD_MS   = opts.holdMs or 550
        local realClick = onclick

        local origDown = btn.onMouseDown
        btn.onMouseDown = function(self_, mx, my)
            self_.dfDownAt = getTimestampMs()
            if origDown then return origDown(self_, mx, my) end
        end

        btn.onclick = function(target, self_, ...)
            local t0 = self_ and self_.dfDownAt
            if self_ then self_.dfDownAt = nil end
            -- t0 nil means the press never came through the mouse path (joypad
            -- dispatches onclick directly); let those through rather than
            -- making the button dead for controller users.
            if (not t0) or (getTimestampMs() - t0) >= HOLD_MS then
                if realClick then return realClick(target, self_, ...) end
            elseif DFFeedback then
                DFFeedback.bad("Hold to confirm: " .. tostring(label))
            end
        end

        btn:setTooltip((btn.tooltip and (btn.tooltip .. "  ") or "") .. "Hold to confirm.")
    end

    if opts.enabled == false then btn:setEnable(false) end

    parent:addChild(btn)
    return btn
end

-- Knock a scrolling list back so it reads as a WELL sunk into a translucent
-- panel rather than a solid block sitting on one. ISScrollingListBox defaults
-- to backgroundColor a = 0.8; stacked on the deck's own 0.8 ground that
-- composites to ~0.96, so the list goes opaque exactly where the panel is
-- meant to be see-through.
function DFKit.well(el)
    if not el then return el end
    local c = DFKit.col.bg
    el.backgroundColor = { r = c.r, g = c.g, b = c.b, a = DFKit.alpha.inset }
    return el
end

-- REFILL A SCROLLING LIST. Every list in the family rebuilds itself the same
-- way - clear, then addItem in a loop - and that sequence is quietly broken in
-- vanilla, so it is centralised here rather than fixed twelve times.
--
-- ISScrollingListBox:clear() resets items, count and selection but NOT the
-- scroll height (ISScrollingListBox.lua:340), while addItem ADDS to it (:150).
-- So each rebuild leaves the previous content's height behind and stacks the
-- new content on top. The height only ever grows, and it takes two things with
-- it:
--
--   * isVScrollBarVisible compares the bar against that height
--     (ISUIElement.lua:1412), so a scrollbar appears on a list that fits;
--   * yScroll, which clear() also leaves alone, can then sit far below where
--     any content actually is - and the rows draw ABOVE the visible window.
--
-- The failure looks like data loss and is not: the list is fully populated and
-- rowAt() still resolves clicks correctly, so clicking blank space selects the
-- row that should have been drawn there. Nothing but rebuilding the widget
-- recovers it, so it presents as "only a relog fixes it", and refreshing makes
-- it worse. Found in the vehicles tab 2026-08-03; it was latent in every list
-- in the suite.
--
-- `fill` receives the box and adds whatever it likes, including nothing.
function DFKit.refillList(box, fill)
    if not box then return box end
    box:clear()
    box:setScrollHeight(0)
    -- A smooth scroll in flight is aimed at content that no longer exists, and
    -- updateSmoothScrolling would drive yScroll back to that target on the next
    -- frame - undoing the clamp below.
    box.smoothScrollTargetY = nil
    box.smoothScrollY       = nil
    if fill then fill(box) end
    -- Re-clamp rather than snap to the top: setYScroll bounds against the NEW
    -- scroll height (ISUIElement.lua:1690), so a list that is still long keeps
    -- the reader's position and a short one falls back to 0 on its own. Lists
    -- that refill progressively call this once per page, and yanking the view
    -- to the top mid-read would be a bug of its own.
    box:setYScroll(box:getYScroll())
    return box
end

-- SIZE A SCROLLING LIST. Use this instead of setX/setY/setWidth/setHeight -
-- the four of them alone leave the widget in a state where it cannot draw.
--
-- ISScrollingListBox:instantiate() calls addScrollBars() (:63), which builds the
-- scrollbar against WHATEVER SIZE THE LIST IS AT THAT MOMENT. Vanilla gets away
-- with this because it constructs lists at their final size. Every list in this
-- family is constructed at a placeholder 10x10 and sized later from layout(),
-- and ISUIElement:setWidth/setHeight (:230) update the element only - they never
-- touch vscroll. So the bar keeps its 10x10 geometry for the widget's whole
-- life, and two things follow from that:
--
--   1. isVScrollBarVisible() is `vscroll:getHeight() < getScrollHeight()`
--      (ISUIElement.java:1412). Against a stale tiny height that is TRUE for
--      any non-empty list.
--   2. Which makes prerender clamp the stencil to `vscroll.x + 3`
--      (ISScrollingListBox.lua:495). Against a stale tiny x that is a ~2px
--      sliver, and EVERY ROW IS CLIPPED AWAY.
--
-- The result is a list that is fully populated, correctly hit-tested and
-- completely invisible, inside a border that draws fine because the border is
-- drawn BEFORE the stencil is set. That 2px sliver at the top-left corner of an
-- empty-looking list is the whole bug, visible.
--
-- ONE ROW HEIGHT FOR EVERY LIST IN THE FAMILY, and it is derived rather than
-- declared.
--
-- Three had drifted apart: Reclamation's fleet list computed max(18, fh + 4),
-- Husbandry took metrics.rowH flat, and the Limes zone tree hardcoded 18 - the
-- tightest of the three, which is what "the text feels crowded" was measuring.
-- A constant cannot be right, because the row has to hold a glyph whose height
-- is a UI setting: at a larger font a fixed 18 clips descenders and the list
-- reads as squashed rather than as too small.
--
-- So: never smaller than the token, and always at least the glyph plus
-- breathing room. This is also the hinge the deck's resize needs - scale the
-- font and every list that asks here grows with it, instead of keeping its
-- old spacing around bigger text.
function DFKit.rowHeight()
    local fh = 12
    pcall(function() fh = getTextManager():getFontHeight(DFKit.font.small) end)
    if not fh or fh < 1 then fh = 12 end
    return math.max(DFKit.metrics.rowH, fh + 8)
end

-- Rebuilding the bars after sizing puts the widget in exactly the state vanilla
-- would have constructed it in. addScrollBars() itself detaches the old bars
-- before building fresh ones (ISUIElement.lua:1390 calls removeScrollBars as
-- its first line - verified in the b42 install 2026-08-05), so this does not
-- accumulate children even when a live resize drag runs it per mouse-move.
function DFKit.sizeList(box, x, y, w, h)
    if not box then return box end
    if x then box:setX(x) end
    if y then box:setY(y) end
    if w then box:setWidth(w) end
    if h then box:setHeight(h) end
    -- Order matters: bars first so they take the new geometry, then re-clamp
    -- yScroll against the scroll area the new size implies.
    pcall(function() box:addScrollBars() end)
    pcall(function() box:updateScrollbars() end)
    return box
end

-- NOTE the originalX guard. ISLabel:setName does `self:setX(self.originalX)`
-- (ISLabel.lua:17), and originalX is captured ONCE at construction. Every tab
-- here builds its labels at (0,0) and positions them later from layout() - so
-- without this, the first setName snaps the label back to x=0 and it renders
-- under whatever else lives at the left edge. That is what put the vehicles
-- tab's status line behind its own toolbar buttons (found 2026-08-03), and it
-- was latent in every tab with a label whose text changes.
--
-- Keeping originalX in step with setX is the narrow fix: setName still does its
-- re-measure and right-align maths, it just no longer teleports.
function DFKit.label(parent, x, y, text, colour, font)
    local c = colour or DFKit.col.text
    local l = ISLabel:new(x, y, 16, text, c.r, c.g, c.b, 1, font or DFKit.font.small, true)
    l:initialise()
    l:instantiate()
    local origSetX = l.setX
    l.setX = function(self_, nx)
        self_.originalX = nx
        return origSetX(self_, nx)
    end
    parent:addChild(l)
    return l
end

-- ---------------------------------------------------------------------------
-- Regions - what LSTab's headH/bottomH/midY/midH arithmetic becomes
-- ---------------------------------------------------------------------------

local Region = {}
Region.__index = Region

local function newRegion(panel, x, y, w, h)
    return setmetatable({ panel = panel, x = x, y = y, w = w, h = h }, Region)
end

-- Slice `hgt` off the top and keep the remainder. Returns the slice.
function Region:header(hgt)
    hgt = hgt or DFKit.metrics.headerH
    local r = newRegion(self.panel, self.x, self.y, self.w, hgt)
    self.y = self.y + hgt
    self.h = self.h - hgt
    return r
end

-- Slice `hgt` off the bottom and keep the remainder. Returns the slice.
function Region:footer(hgt)
    hgt = hgt or (DFKit.metrics.btnH + DFKit.metrics.pad * 2)
    local r = newRegion(self.panel, self.x, self.y + self.h - hgt, self.w, hgt)
    self.h = self.h - hgt
    return r
end

function Region:rest() return self end

-- Split left/right at `frac`. `minL`/`minR` clamp, because LSTab already
-- learned the hard way that an unclamped middle collapses on a short deck
-- (its `if midH < 140 then midH = 140`).
function Region:splitH(frac, minL, minR)
    local gap = DFKit.metrics.gap
    local lw  = math.floor((self.w - gap) * (frac or 0.5))
    if minL and lw < minL then lw = minL end
    local rw = self.w - gap - lw
    if minR and rw < minR then rw = minR; lw = self.w - gap - rw end
    return newRegion(self.panel, self.x, self.y, lw, self.h),
           newRegion(self.panel, self.x + lw + gap, self.y, rw, self.h)
end

function Region:inset(p)
    p = p or DFKit.metrics.pad
    return newRegion(self.panel, self.x + p, self.y + p, self.w - p * 2, self.h - p * 2)
end

-- Cursor helper - what `local cursorY = PAD` becomes in every tab.
function Region:stack(gap)
    local m = DFKit.metrics
    return {
        x = self.x, y = self.y, w = self.w,
        gap = gap or m.gap,
        row = function(s, hgt)
            local yy = s.y
            s.y = s.y + (hgt or m.btnH) + s.gap
            return s.x, yy, s.w
        end,
        remaining = function(s) return (self.y + self.h) - s.y end,
    }
end

-- A row of buttons laid left to right, evenly gapped. Returns the buttons.
-- specs: { {label, target, onclick, kind, opts, w}, ... }
function Region:buttonRow(specs, alignRight)
    local m, out = DFKit.metrics, {}
    local total = 0
    for _, s in ipairs(specs) do total = total + (s.w or 90) + m.gap end
    local cx = alignRight and (self.x + self.w - total + m.gap) or self.x
    for _, s in ipairs(specs) do
        local w = s.w or 90
        out[#out + 1] = DFKit.button(self.panel, cx, self.y, w, s[1], s[2], s[3], s[4], s[5])
        cx = cx + w + m.gap
    end
    return out
end

function DFKit.layout(panel, x, y, w, h)
    local m = DFKit.metrics
    return newRegion(panel, (x or 0) + m.pad, (y or 0) + m.pad,
                     (w or panel:getWidth()) - m.pad * 2,
                     (h or panel:getHeight()) - m.pad * 2)
end

-- ---------------------------------------------------------------------------
-- Shared states
-- ---------------------------------------------------------------------------

-- Trim to width with a ".." tail. Core-local so tabs can clip label text
-- without a DFTheme dependency (Core must not require Dragonfly). ISLabel does
-- not clip, so any label whose text is a sentence - status lines especially -
-- otherwise runs under whatever sits to its right and off the pane. UTF-8
-- safe: each step strips trailing continuation bytes (0x80-0xBF) TOGETHER
-- WITH the lead byte they belong to - one whole character - so the cut never
-- leaves a mangled glyph before the tail. (Continuation bytes first, then the
-- lead: the other order leaves the bare lead byte dangling.)
function DFKit.fitText(str, font, maxW)
    str = tostring(str or "")
    if str == "" then return "" end
    if not maxW or maxW <= 0 then return "" end
    font = font or DFKit.font.small or UIFont.Small
    local tm = getTextManager()
    if tm:MeasureStringX(font, str) <= maxW then return str end
    local s = str
    while #s > 1 and tm:MeasureStringX(font, s .. "..") > maxW do
        local n = #s
        while n > 1 do
            local b = string.byte(s, n)
            if b >= 128 and b < 192 then n = n - 1 else break end
        end
        s = string.sub(s, 1, n - 1)
    end
    return s .. ".."
end

-- Wrap prose to a column, measured against the ACTUAL font - the font is a user
-- preference (DFPrefs), so a wrap computed for Small overflows badly at Large.
-- Explicit newlines are honoured first so a caller can shape paragraphs, then
-- each paragraph wraps independently. Returns an array of lines; an empty line
-- in means an empty line out, which is what makes blank-line paragraph breaks
-- survive.
--
-- Lives here rather than in DFHelp because it is not about help: DFEntry states
-- a validation rule with it, and the next surface that has a sentence to lay
-- out will too. DFHelp keeps a one-line shim so the two cannot drift.
function DFKit.wrapText(text, font, maxW)
    local out = {}
    if type(text) ~= "string" or text == "" then return out end
    if not maxW or maxW <= 0 then return out end
    font = font or DFKit.font.small or UIFont.Small
    local tm = getTextManager()

    for paragraph in string.gmatch(text .. "\n", "([^\n]*)\n") do
        if paragraph == "" then
            out[#out + 1] = ""
        else
            local line = nil
            for word in string.gmatch(paragraph, "%S+") do
                local try = line and (line .. " " .. word) or word
                if tm:MeasureStringX(font, try) <= maxW then
                    line = try
                else
                    -- The word does not fit even alone: emit it anyway rather
                    -- than looping forever trying to make room for it.
                    if line then out[#out + 1] = line end
                    line = word
                end
            end
            if line then out[#out + 1] = line end
        end
    end
    return out
end

-- The quiet state. A triage surface should be silent when clean, not render a
-- table proving it - "no further matches" in a column list reads as data, not
-- as calm. Call from a tab's prerender when it has nothing to report.
function DFKit.drawEmpty(el, x, y, w, h, text)
    local c = DFKit.col.textDim
    local f = DFKit.font.small
    local tw = getTextManager():MeasureStringX(f, text)
    local th = getTextManager():getFontHeight(f)
    el:drawText(text, x + (w - tw) / 2, y + (h - th) / 2, c.r, c.g, c.b, 0.7, f)
end

-- Severity chip: the one place a verdict earns colour.
function DFKit.drawChip(el, x, y, text, severity)
    local c = DFKit.col[severity or "textDim"] or DFKit.col.textDim
    local f = DFKit.font.small
    local tw = getTextManager():MeasureStringX(f, text)
    el:drawRect(x, y, tw + 10, DFKit.metrics.headerH, DFKit.alpha.inset * 0.7, c.r, c.g, c.b)
    el:drawText(text, x + 5, y + 2, c.r, c.g, c.b, 1, f)
    return tw + 10
end

return DFKit

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
