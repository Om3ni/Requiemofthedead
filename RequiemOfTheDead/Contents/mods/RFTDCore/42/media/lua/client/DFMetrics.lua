-- DFMetrics - the one spacing scale every family panel lays out with.
--
-- WHY THIS EXISTS. DFKit.metrics was a static literal, and every tab that
-- needed a number the literal did not have invented one locally. Measured
-- across the family before this landed: RCJanitorView advanced text lines by a
-- hard 16, DFForm used `fh + 12` for a row, DFColumns.drawHeader wrote 18 and
-- y+14 and y+18, RCVehicleTab derived its own scale from UIFont.Code, and the
-- rest used bare 8s and 6s. Nine tabs, no two agreeing, and nothing that
-- responded when the text-size preference changed - which is exactly why
-- raising text size used to break the vehicle list.
--
-- THE RULE, and it is the whole point: no file writes a raw pixel number for
-- spacing. If something needs a value that is not a token here, this table is
-- incomplete and gets extended - it does not get worked around locally. That is
-- the only way "uniform" survives the tenth tab.
--
-- EVERYTHING IS MEASURED, NOTHING IS ASSUMED. Values derive from the CURRENT
-- font's height, so the whole panel scales together when the size preference
-- moves. The reference is UIFont.Small measured at load; every token is
-- expressed as its tuned value at that reference, scaled by the ratio between
-- the reference and the live font. At default text size the arithmetic is
-- exactly x1, so this file changes nothing visually until the SPEC below is
-- retuned - which is a separate, revertable step on purpose.
--
-- ONE TABLE, NOT TWO. recompute() writes back into DFKit.metrics rather than
-- replacing it, so the table IDENTITY never changes. Tabs that captured
-- `local m = DFKit.metrics` at build time keep working and silently pick up new
-- values, and every existing key keeps its meaning.

if isServer() then return end

require "DFKit"

DFMetrics = DFMetrics or {}

-- The font the numbers below were tuned against. Not the live font: the live
-- one moves with the player's preference, and a scale needs a fixed origin.
local REFERENCE_FONT = UIFont and UIFont.Small or nil

-- Tuned values AT THE REFERENCE FONT. Step one of this migration keeps them
-- byte-identical to what the family shipped, so the extraction can be proven
-- to change nothing before any of them are argued about.
--
--   pad / gap / btnH / rowH / headerH / radius  - DFKit.metrics, as shipped
--   line                                        - RCJanitorView's hard 16
--   row                                         - DFForm's fh + 12 at reference
--   group / rule                                - new; see the note on each
local SPEC = {
    pad     = 8,    -- panel inset
    gap     = 6,    -- between sibling controls
    btnH    = 24,   -- button height
    rowH    = 22,   -- LIST row height (a drawn row of data)
    headerH = 20,   -- column header strip
    radius  = 3,    -- corner rounding (not spacing, carried for completeness)

    line    = 16,   -- one advance in a run of read-only text
    row     = 27,   -- one INTERACTIVE row: form field, stepper, toggle
    group   = 18,   -- above a category header. Deliberately the largest gap in
                    -- the set: a group boundary is the only place the eye needs
                    -- a real pause, and it was the thing most obviously missing.
    rule    = 7,    -- from a header's underline to the first row beneath it
}

-- Measured once. UIFont.Small cannot change mid-session; the LIVE font can.
local referenceFH

local function measure(font)
    local h
    if font then pcall(function() h = getTextManager():getFontHeight(font) end) end
    if type(h) ~= "number" or h < 1 then return nil end
    return h
end

-- The live font is whatever DFKit currently points `small` at, which is what
-- DFPrefs rewrites when the player changes text size.
local function liveFont()
    return (DFKit and DFKit.font and DFKit.font.small) or REFERENCE_FONT
end

-- Current font height, for callers that genuinely need the glyph box itself
-- (measuring a column against real content, centring text in a row) rather
-- than a spacing token.
function DFMetrics.fontHeight()
    return measure(liveFont()) or referenceFH or 15
end

-- Recompute every token against the live font and publish into DFKit.metrics.
-- Idempotent and cheap; safe to call on any preference change.
function DFMetrics.recompute()
    -- NEVER CACHE A FAILED MEASUREMENT. This runs at file load, which in PZ can
    -- be before the text manager is ready, and an unmeasurable reference that
    -- got cached as the fallback would poison every later recompute: a real
    -- font of 18 against a remembered reference of 15 is a permanent x1.2 on
    -- every panel, at DEFAULT text size, for the rest of the session. Leaving
    -- it nil means the next call measures properly.
    if not referenceFH then referenceFH = measure(REFERENCE_FONT) end

    local fh = measure(liveFont())
    -- Nothing measurable yet: publish the tuned values untouched. That is the
    -- shipped behaviour, and the DFPrefs hook (or the next open) will correct
    -- it once the text manager exists.
    if not (referenceFH and fh) then
        local m = DFKit.metrics
        for key, tuned in pairs(SPEC) do m[key] = tuned end
        m.fh, m.scale = fh or referenceFH or SPEC.line, 1
        return m
    end

    local scale = fh / referenceFH
    if scale < 1 then scale = 1 end   -- never tighter than tuned

    local m = DFKit.metrics
    for key, tuned in pairs(SPEC) do
        -- radius is a corner, not a rhythm - scaling it turns buttons into
        -- lozenges at large text.
        if key == "radius" then
            m[key] = tuned
        else
            m[key] = math.max(1, math.floor(tuned * scale + 0.5))
        end
    end
    m.fh    = fh
    m.scale = scale
    return m
end

-- Published at load so a panel opened before any preference change is already
-- correct, and re-published whenever the preference moves.
DFMetrics.recompute()

if DFPrefs and DFPrefs.onChange then
    DFPrefs.onChange(function() DFMetrics.recompute() end)
end

print("[Core] DFMetrics loaded (one spacing scale, measured)")
