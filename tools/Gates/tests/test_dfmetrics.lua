-- test_dfmetrics.lua - the shared spacing scale.
--
-- WHAT IT PINS, and why each one is here rather than being obvious:
--   * AT THE REFERENCE FONT EVERY TOKEN IS ITS TUNED VALUE, exactly. This
--     migration's first step is a pure extraction across nine tabs, and the
--     only way to argue the numbers later is to prove they did not move now.
--   * DFKit.metrics keeps its TABLE IDENTITY. Tabs capture `local m =
--     DFKit.metrics` at build time; replacing the table would leave every one
--     of them holding a stale copy forever, which is a bug that presents as
--     "the text size preference does nothing" long after the cause.
--   * scale never drops below 1 - the tuned values are the floor.
--   * radius does not scale. It is a corner, not a rhythm, and scaling it turns
--     buttons into lozenges at large text.
--
-- Usage (normally via tools\run-tests.bat):
--   lua5.1.exe tools/tests/test_dfmetrics.lua <repo-root>

local ROOT = arg[1] or "."
local SRC  = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/client/DFMetrics.lua"

-- ---------------------------------------------------------------------------
-- Stub world. Font heights are per-font so the live font can be moved
-- independently of the reference, which is the whole mechanism under test.
-- ---------------------------------------------------------------------------
local H = { small = 15, large = 30 }

isServer = function() return false end
require  = function() end
UIFont   = { Small = "small", Code = "code" }

getTextManager = function()
    return { getFontHeight = function(_, font) return H[font] end }
end

-- The real DFKit, reduced to the parts DFMetrics touches. `metrics` starts as
-- the shipped literal so the identity check below is meaningful.
DFKit = {
    metrics = { pad = 8, gap = 6, btnH = 24, rowH = 22, headerH = 20, radius = 3 },
    font    = { small = "small" },
}
local METRICS_TABLE = DFKit.metrics   -- captured exactly as a tab would

local prefsHook
DFPrefs = { onChange = function(fn) prefsHook = fn end }

local okLoad, err = pcall(dofile, SRC)
if not okLoad then
    print("FATAL: could not load " .. SRC)
    print("  " .. tostring(err))
    os.exit(2)
end
if type(DFMetrics) ~= "table" then
    print("FATAL: DFMetrics did not load as a table")
    os.exit(2)
end

-- ---------------------------------------------------------------------------
local pass, fail = 0, 0
local function ok(label, cond, detail)
    if cond then pass = pass + 1
    else
        fail = fail + 1
        print("FAIL  " .. label .. (detail and ("  -- " .. tostring(detail)) or ""))
    end
end
local function eq(label, got, want)
    ok(label, got == want, string.format("got %s, want %s", tostring(got), tostring(want)))
end

-- ---------------------------------------------------------------------------
-- Step one of the migration is a PURE EXTRACTION. Every value the family
-- shipped survives untouched at the reference font.
-- ---------------------------------------------------------------------------
local m = DFKit.metrics
eq("pad unchanged",     m.pad,     8)
eq("gap unchanged",     m.gap,     6)
eq("btnH unchanged",    m.btnH,    24)
eq("rowH unchanged",    m.rowH,    22)
eq("headerH unchanged", m.headerH, 20)
eq("radius unchanged",  m.radius,  3)

-- The tokens the family did not have, at their tuned values.
eq("line is one text advance", m.line,  16)
eq("row is one interactive row", m.row, 27)
eq("group is the largest gap in the set", m.group, 18)
eq("rule sits under a header", m.rule, 7)
ok("group is larger than gap - a category break must read as a pause",
    m.group > m.gap, string.format("group %d vs gap %d", m.group, m.gap))
ok("row is taller than line - controls need more room than prose",
    m.row > m.line, string.format("row %d vs line %d", m.row, m.line))

eq("scale is exactly 1 at the reference font", m.scale, 1)
eq("fh is published for callers that need the glyph box", m.fh, 15)
eq("fontHeight() agrees", DFMetrics.fontHeight(), 15)

-- ---------------------------------------------------------------------------
-- Identity. A tab that captured the table at build time must see new values,
-- not hold a stale copy.
-- ---------------------------------------------------------------------------
ok("DFKit.metrics is still the SAME table object", DFKit.metrics == METRICS_TABLE)

-- ---------------------------------------------------------------------------
-- Scaling. The live font moves; the reference does not.
-- ---------------------------------------------------------------------------
DFKit.font.small = "large"       -- as DFPrefs rewrites it
DFMetrics.recompute()

eq("scale doubles with the font", DFKit.metrics.scale, 2)
eq("pad scales",     DFKit.metrics.pad,   16)
eq("gap scales",     DFKit.metrics.gap,   12)
eq("line scales",    DFKit.metrics.line,  32)
eq("row scales",     DFKit.metrics.row,   54)
eq("group scales",   DFKit.metrics.group, 36)
eq("radius does NOT scale - a corner is not a rhythm",
    DFKit.metrics.radius, 3)
ok("...and it is still the same table", DFKit.metrics == METRICS_TABLE)

-- The preference hook must be wired, or a size change silently does nothing.
ok("a DFPrefs change handler was registered", type(prefsHook) == "function")
DFKit.font.small = "small"
if prefsHook then prefsHook() end
eq("the hook recomputes back down", DFKit.metrics.pad, 8)

-- ---------------------------------------------------------------------------
-- Floor. Tuned values are the minimum; a smaller font must not tighten them.
-- ---------------------------------------------------------------------------
H.tiny = 8
DFKit.font.small = "tiny"
DFMetrics.recompute()
eq("scale is clamped at 1", DFKit.metrics.scale, 1)
eq("...so spacing never goes below tuned", DFKit.metrics.pad, 8)
DFKit.font.small = "small"
DFMetrics.recompute()

-- Missing font selection is the actual unavailable case. TextManager itself
-- is eagerly initialized, so a throwing test double would only preserve an
-- impossible production pcall.
DFKit.metrics = { pad = 8, gap = 6, btnH = 24, rowH = 22, headerH = 20, radius = 3 }
DFKit.font.small = nil
DFMetrics.recompute()
eq("missing live font leaves spacing at tuned values", DFKit.metrics.pad, 8)
eq("missing live font keeps a usable published height", DFKit.metrics.fh, 15)
DFKit.font.small = "small"
H.small = 18
DFMetrics.recompute()
eq("restored live font measures against the original reference", DFKit.metrics.scale, 1.2)
eq("restored live font scales spacing", DFKit.metrics.pad, 10)
H.small = 15
DFMetrics.recompute()

-- ---------------------------------------------------------------------------
print(string.format("DFMetrics: %d passed, %d failed", pass, fail))
os.exit(fail > 0 and 1 or 0)
