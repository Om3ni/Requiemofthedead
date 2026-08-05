-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFColumns - column-layout primitives for dense data tabs.
--
-- Pattern lifted from Husbandry's HBDebugPanel: a tab declares a `cols`
-- array of { key, label, w, align, color, format } specs, then draws each
-- row with drawRow(). Right-aligned numeric cells, truncation with
-- ellipsis, optional per-cell color function. No icon column, no two-line
-- stacked text - this is for dense scannable data, not visual browsing.
--
-- Use this for: zombie inspector, animal stat readout, vehicle catalog,
-- per-player admin lists, anything where columns + rows is more readable
-- than icon + two-line cards.

if isServer() then return end

DFColumns = DFColumns or {}

local function measure(font, s)
    return getTextManager():MeasureStringX(font, tostring(s or ""))
end

-- Truncate text with ellipsis to fit a pixel width.
function DFColumns.truncate(text, font, maxW)
    text = tostring(text or "")
    if maxW <= 0 then return "" end
    if measure(font, text) <= maxW then return text end
    while #text > 1 do
        text = string.sub(text, 1, #text - 1)
        if measure(font, text .. "...") <= maxW then return text .. "..." end
    end
    return text
end

-- Sum of column widths plus inter-column gaps.
function DFColumns.totalWidth(cols, gap)
    gap = gap or 4
    local t = 0
    for i, c in ipairs(cols) do
        t = t + c.w
        if i < #cols then t = t + gap end
    end
    return t
end

-- Draw the header row at (x, y). Returns the y-coord after the row.
-- Draws subtle column separators between cells so the column structure
-- is visible at a glance even on dense rows.
function DFColumns.drawHeader(panel, cols, x, y, font, gap)
    gap = gap or 4
    font = font or UIFont.Small
    local cx = x
    for i, col in ipairs(cols) do
        local label = tostring(col.label or col.key or "")
        local drawX = cx
        if col.align == "right" then
            drawX = cx + col.w - measure(font, label) - 2
        elseif col.align == "center" then
            drawX = cx + (col.w - measure(font, label)) / 2
        end
        panel:drawText(label, drawX, y, 0.65, 0.70, 0.80, 1, font)
        cx = cx + col.w
        if i < #cols then
            -- Tall separator from header through visible rows. The header
            -- itself only needs ~16px but extending the bar gives the row
            -- area a column-frame feel.
            panel:drawRect(cx + gap / 2, y - 2, 1, 18, 0.5, 0.5, 0.55, 0.6)
            cx = cx + gap
        end
    end
    -- Underline.
    panel:drawRect(x, y + 14, DFColumns.totalWidth(cols, gap), 1, 0.4, 0.7, 0.7, 0.8)
    return y + 18
end

-- Draw a single data row. `row` is the source object. Each col either:
--   uses row[col.key] directly, or
--   col.format(row) for derived values.
-- col.color(row, value) -> { r, g, b } overrides the row's base color.
-- `rowH` is the full pixel height of the row; defaults to 16 for backward
-- compat. Text is vertically centered in the row using actual font metrics.
-- Returns the y-coord after the row.
function DFColumns.drawRow(panel, cols, row, x, y, font, baseColor, gap, rowH)
    gap   = gap   or 4
    rowH  = rowH  or 16
    font  = font  or UIFont.Small
    baseColor = baseColor or { 1, 1, 1 }

    local fh    = getTextManager():getFontHeight(font)
    local textY = y + math.floor((rowH - fh) / 2)
    local cx    = x

    for i, col in ipairs(cols) do
        local raw
        if col.format then raw = col.format(row) else raw = row[col.key] end
        local text = DFColumns.truncate(raw, font, col.w - 6)
        local c = col.color and col.color(row, raw) or baseColor
        local drawX = cx + 2
        if col.align == "right" then
            drawX = cx + col.w - measure(font, text) - 2
        elseif col.align == "center" then
            drawX = cx + (col.w - measure(font, text)) / 2
        end
        panel:drawText(text, drawX, textY, c[1], c[2], c[3], 1, font)
        cx = cx + col.w
        if i < #cols then
            -- Column separator running full row height. Subtle so dense
            -- rows still read as a unit but column lines stay visible.
            panel:drawRect(cx + gap / 2, y, 1, rowH, 0.18, 0.6, 0.6, 0.7)
            cx = cx + gap
        end
    end
    return y + rowH
end

-- Draw text aligned within an arbitrary box.
--   align:  "left" | "center" | "right"   (horizontal)
--   valign: "top"  | "middle" | "bottom"  (vertical)
-- color: {r, g, b, a?}. Computes pixel position from actual font metrics so
-- the result is centered correctly across fonts (Small/Medium/Large/Code).
-- Use this anywhere you'd otherwise hand-roll `y + (h - fontH) / 2` math.
function DFColumns.drawInBox(panel, text, x, y, w, h, font, color, align, valign)
    font  = font  or UIFont.Small
    color = color or { 1, 1, 1, 1 }
    align = align  or "left"
    valign = valign or "top"

    local s  = tostring(text or "")
    local tm = getTextManager()
    local tw = tm:MeasureStringX(font, s)
    local th = tm:getFontHeight(font)

    local tx, ty
    if align == "center" then
        tx = x + (w - tw) / 2
    elseif align == "right" then
        tx = x + w - tw - 2
    else
        tx = x + 2
    end

    if valign == "middle" then
        ty = y + (h - th) / 2
    elseif valign == "bottom" then
        ty = y + h - th - 2
    else
        ty = y + 2
    end

    panel:drawText(s, tx, ty, color[1], color[2], color[3], color[4] or 1, font)
end

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
