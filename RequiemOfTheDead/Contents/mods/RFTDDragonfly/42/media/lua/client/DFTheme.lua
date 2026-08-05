-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFTheme.lua - the Growl skin's constitution: tokens, sprites, and the
-- drawing verbs every deck surface speaks (client only).
--
-- THE FOUR RULES, which are review criteria, not vibes. A tab migration that
-- breaks one fails review:
--
--   1. GREEN IS ATTENTION.  col.sight appears on: the active page rail, the
--      hovered row's acquisition, ONE armed action per page, focus rings, and
--      the watch pulse. Never headers, never decoration, never body text.
--   2. AMBIENT IS MONOCHROME.  At rest the deck is bone-on-murk with scar
--      hairlines. Semantic color (oldblood danger / ochre warning / fen live-ok)
--      is data, and is not the accent.
--   3. HARD EDGES, LOW LIGHT.  3px radii, 1px hairlines, grain at 4%. No glow
--      anywhere except the armed hover.
--   4. STILLNESS, THEN THE STRIKE.  One sweep when the deck opens, the 4s
--      watch pulse, 120ms acquisitions. Nothing else moves.
--
-- SPRITES ARE SHAPE, LUA IS COLOR. Everything in media/ui/Growl/ is pure
-- white with geometry in the alpha channel; tinting happens per draw call via
-- drawTextureScaled's color args (vanilla wrapper ISUIElement.lua:1032 ->
-- DrawTextureScaledCol, UIElement.java:384). Reskinning the family forever
-- after means editing THIS file and never touching a PNG. Regenerate the
-- sprite set with tools\make-growl-sprites.py (seeded - same wing every run).
--
-- PER-FRAME DISCIPLINE, the actual render budget in PZ UIs: draw calls are
-- cheap-ish (a rounded panel is 7), but Lua-side churn is not. Rules for
-- consumers: no string.format in render paths - cache text until the value
-- changes; no table allocation per frame - the helpers below take scalars and
-- allocate nothing.
--
-- Design source: the Phase 0 "Growl" mockup (approved 2026-08-02); palette
-- descends from the Dragonfly mark - black disc, acid ring, wing venation.

if isServer() then return end

DFTheme = DFTheme or {}

-- ---------------------------------------------------------------------------
-- Tokens
-- ---------------------------------------------------------------------------

DFTheme.col = {
    void     = { r = 0.031, g = 0.035, b = 0.039 },  -- #08090a page ground
    murk     = { r = 0.051, g = 0.063, b = 0.051 },  -- #0d100d panel
    hide     = { r = 0.075, g = 0.094, b = 0.075 },  -- #131813 card / raised
    hideHi   = { r = 0.094, g = 0.125, b = 0.094 },  -- #182018 row hover ground
    scar     = { r = 0.133, g = 0.169, b = 0.133 },  -- #222b22 hairlines
    bone     = { r = 0.788, g = 0.808, b = 0.761 },  -- #c9cec2 text
    ash      = { r = 0.427, g = 0.463, b = 0.420 },  -- #6d766b muted
    sight    = { r = 0.561, g = 0.886, b = 0.196 },  -- #8fe232 ATTENTION ONLY
    sightDim = { r = 0.290, g = 0.455, b = 0.125 },  -- #4a7420
    fen      = { r = 0.180, g = 0.490, b = 0.329 },  -- #2e7d54 live / ok
    oldblood = { r = 0.612, g = 0.227, b = 0.180 },  -- #9c3a2e danger, dried
    ochre    = { r = 0.659, g = 0.529, b = 0.235 },  -- #a8873c warnings
    black    = { r = 0.020, g = 0.024, b = 0.020 },  -- #050605 the mark's disc
}

DFTheme.radius = 3
DFTheme.pad    = 8

DFTheme.font = {
    label = UIFont.Small,    -- roster, buttons, headers: drawn uppercase
    body  = UIFont.Small,
    title = UIFont.Medium,
}

-- ---------------------------------------------------------------------------
-- Sprites (shape-only; see header)
-- ---------------------------------------------------------------------------

local texCache = {}

function DFTheme.tex(name)
    local t = texCache[name]
    if t == nil then
        t = getTexture("media/ui/Growl/" .. name .. ".png") or false
        texCache[name] = t
    end
    if t == false then return nil end
    return t
end

-- ---------------------------------------------------------------------------
-- Time: frame delta normalized to 30 FPS, capped so a hitch cannot teleport
-- an animation (UIManager.getMillisSinceLastRender, UIManager.java:1321)
-- ---------------------------------------------------------------------------

function DFTheme.delta()
    local d = UIManager.getMillisSinceLastRender() / 33.3
    if d > 3 then d = 3 end
    return d
end

-- Framerate-independent approach toward a target; the deck's ONLY easing.
-- rate ~0.25 lands in roughly 120ms - the acquisition speed.
function DFTheme.glide(cur, target, rate)
    local t = rate * DFTheme.delta()
    if t > 1 then t = 1 end
    local v = cur + (target - cur) * t
    if math.abs(target - v) < 0.002 then return target end
    return v
end

-- ---------------------------------------------------------------------------
-- Drawing verbs. `el` is any ISUIElement; colors are token tables.
-- ---------------------------------------------------------------------------

-- Filled rounded rectangle: four tinted corner sprites + three plain rects.
-- Radius clamps to half the short side; r < 1 degrades to a plain rect.
function DFTheme.roundRect(el, x, y, w, h, r, a, c)
    local half = math.floor(math.min(w, h) / 2)
    if r > half then r = half end
    if r < 1 then
        el:drawRect(x, y, w, h, a, c.r, c.g, c.b)
        return
    end
    el:drawTextureScaled(DFTheme.tex("cnr_tl"), x,         y,         r, r, a, c.r, c.g, c.b)
    el:drawTextureScaled(DFTheme.tex("cnr_tr"), x + w - r, y,         r, r, a, c.r, c.g, c.b)
    el:drawTextureScaled(DFTheme.tex("cnr_bl"), x,         y + h - r, r, r, a, c.r, c.g, c.b)
    el:drawTextureScaled(DFTheme.tex("cnr_br"), x + w - r, y + h - r, r, r, a, c.r, c.g, c.b)
    if w > 2 * r then
        el:drawRect(x + r, y,         w - 2 * r, r, a, c.r, c.g, c.b)
        el:drawRect(x + r, y + h - r, w - 2 * r, r, a, c.r, c.g, c.b)
    end
    if h > 2 * r then
        el:drawRect(x, y + r, w, h - 2 * r, a, c.r, c.g, c.b)
    end
end

-- Border under fill, inset 1px - the deck's card outline.
function DFTheme.roundFrame(el, x, y, w, h, r, a, cBorder, cFill)
    DFTheme.roundRect(el, x, y, w, h, r, a, cBorder)
    DFTheme.roundRect(el, x + 1, y + 1, w - 2, h - 2, math.max(1, r - 1), a, cFill)
end

-- 1px scar line.
function DFTheme.hairline(el, x, y, w, a, c)
    c = c or DFTheme.col.scar
    el:drawRect(x, y, w, 1, a or 1, c.r, c.g, c.b)
end

function DFTheme.hairlineV(el, x, y, h, a, c)
    c = c or DFTheme.col.scar
    el:drawRect(x, y, 1, h, a or 1, c.r, c.g, c.b)
end

-- The ONE glow (rule 3): armed hover, and nothing else.
function DFTheme.glow(el, x, y, w, h, spread, a, c)
    local t = DFTheme.tex("glow")
    if not t then return end
    c = c or DFTheme.col.sight
    el:drawTextureScaled(t, x - spread, y - spread, w + spread * 2, h + spread * 2,
        a, c.r, c.g, c.b)
end

-- Film grain over a region; alpha defaults to the constitutional 4%.
function DFTheme.grain(el, x, y, w, h, a)
    local t = DFTheme.tex("noise")
    if not t then return end
    el:drawTextureScaled(t, x, y, w, h, a or 0.04, 1, 1, 1)
end

-- The wing, for the roster strip.
function DFTheme.vein(el, x, y, w, h, a, c)
    local t = DFTheme.tex("vein")
    if not t then return end
    c = c or DFTheme.col.sight
    el:drawTextureScaled(t, x, y, w, h, a or 0.05, c.r, c.g, c.b)
end

-- ---------------------------------------------------------------------------
-- Text. Callers cache their strings; these allocate nothing.
-- ---------------------------------------------------------------------------

function DFTheme.text(el, str, x, y, font, c, a)
    el:drawText(str, x, y, c.r, c.g, c.b, a or 1, font)
end

function DFTheme.textCentre(el, str, x, y, font, c, a)
    el:drawTextCentre(str, x, y, c.r, c.g, c.b, a or 1, font)
end

function DFTheme.textRight(el, str, x, y, font, c, a)
    el:drawTextRight(str, x, y, c.r, c.g, c.b, a or 1, font)
end

function DFTheme.fontH(font)
    return getTextManager():getFontHeight(font)
end

function DFTheme.strW(font, str)
    return getTextManager():MeasureStringX(font, str)
end

-- Trim to width with a ".." tail, never leaving a dangling UTF-8
-- continuation byte at the cut (0x80-0xBF trail bytes back off with the
-- character they belong to).
function DFTheme.fitText(str, font, maxW)
    if not str or str == "" then return "" end
    if DFTheme.strW(font, str) <= maxW then return str end
    local s = str
    while #s > 1 and DFTheme.strW(font, s .. "..") > maxW do
        s = string.sub(s, 1, #s - 1)
        while #s > 1 do
            local b = string.byte(s, #s)
            if b and b >= 128 and b < 192 then
                s = string.sub(s, 1, #s - 1)
            else
                break
            end
        end
    end
    return s .. ".."
end

-- ---------------------------------------------------------------------------
-- Skin bridge: hand Growl's palette to Core's DFKit
-- ---------------------------------------------------------------------------
--
-- Core owns tokens AND structure; a skin overrides TOKENS ONLY. DFKit ignores
-- any key it does not already define, so geometry cannot ride in through here -
-- that is what guarantees a tab lays out identically in the classic panel and
-- in the deck, and only its paint changes.
--
-- Growl's vocabulary stays inside Growl: Core must never learn what "scar" or
-- "sight" mean. This is the one place the two naming systems meet.
if DFKit and DFKit.applySkin then
    DFKit.applySkin{
        col = {
            bg        = DFTheme.col.void,
            panel     = DFTheme.col.murk,
            line      = DFTheme.col.scar,
            text      = DFTheme.col.bone,
            textDim   = DFTheme.col.ash,
            accent    = DFTheme.col.sight,      -- ATTENTION ONLY, per rule
            accentDim = DFTheme.col.sightDim,
            ok        = DFTheme.col.fen,
            warn      = DFTheme.col.ochre,
            danger    = DFTheme.col.oldblood,
        },
        font = {
            small = DFTheme.font.body,
            label = DFTheme.font.label,
        },
    }
    print("[Deck] DFTheme -> DFKit skin bridge applied")
end

print("[Deck] DFTheme loaded - the Growl constitution is in force")

return DFTheme

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
