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
