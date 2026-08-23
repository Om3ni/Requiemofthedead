-- DFSandboxView fixture - the row builder behind the Admin tab's Sandbox pane.
--
-- WHY ONLY THIS PART. The view is ISUI and most of it cannot be tested without
-- a running client. But `rowsFor` is pure arithmetic over the model, and it
-- decides ROW HEIGHTS - which ISScrollingListBox trusts absolutely. Get a
-- height wrong and the list draws correctly while hit-testing the wrong row:
-- clicking one option expands another, and nothing about the picture says why.
--
-- This is the shape TODO.md asks for after RPNecroTab shipped a locality bug
-- that no fixture could reach, because the predicate was a file-local inside a
-- 950-line UI module. Here the arithmetic is a named function taking a model, a
-- width and a selection, and the one engine call it needs (text measurement) is
-- injected - so the fixture supplies a deterministic measurer instead of a
-- stubbed TextManager whose numbers would be fiction anyway.

local ROOT = arg[1] or "."
local SOURCE = ROOT
    .. "/RequiemOfTheDead/Contents/mods/Dragonfly/42/media/lua/client/Admin/DFSandboxView.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then passed = passed + 1
    else failed = failed + 1; print("FAIL DFSandboxView: " .. message) end
end

-- ---- stubs ---------------------------------------------------------------

function isServer() return false end
require = function() return true end

DFKit = {
    font    = { small = "small" },
    metrics = { pad = 8, gap = 6, btnH = 24, rowH = 22, headerH = 20 },
    col     = { text = {}, textDim = {}, line = {}, accent = {}, accentDim = {} },
    rowHeight = function() return 22 end,
    wrapText  = function() return {} end,
}
DFSandboxModel = { build = function() return {} end }
ISScrollingListBox = { derive = function() return { new = function() end } end }

DFSandboxView = nil
local ok, err = pcall(dofile, SOURCE)
check(ok, "module loads: " .. tostring(err))

local ROWH = 22
local LINEH = ROWH - 6

-- A measurer with no engine in it: one "line" per eight characters, so the
-- clamp can be driven precisely instead of hoped at.
local function wrap(text, _, _)
    local out = {}
    text = tostring(text or "")
    if text == "" then return out end
    local i = 1
    while i <= #text do
        out[#out + 1] = text:sub(i, i + 7)
        i = i + 8
    end
    return out
end

-- Modelled on what DFSandboxModel.readOption actually produces: `name` is the
-- namespaced id ("RFTDDirge.DebugMode") and `short` is the tail. They are kept
-- DISTINCT here even for unqualified inputs, because making them equal is what
-- silently turned the namespacing assertion below into a tautology - caught by
-- a mutation run, not by the test passing.
local function opt(name, tooltip)
    local short = name:match("%.(.+)$") or name
    return { name = name, short = short, label = short,
             type = "boolean", tooltip = tooltip }
end

local function rowsFor(mod, selected)
    return DFSandboxView.rowsFor(mod, 100, selected, ROWH, wrap)
end

-- ---- shape ---------------------------------------------------------------

check(#DFSandboxView.rowsFor(nil, 100, nil, ROWH, wrap) == 0, "a nil mod produced rows")
check(#rowsFor({ sections = {} }) == 0, "a mod with no sections produced rows")

-- The model emits a LEADING section with no title for options declared before a
-- mod's first header - and for a mod that uses no headers at all, that untitled
-- section holds everything. It must contribute its options and no divider.
local flat = rowsFor({ sections = { { title = nil, options = { opt("A"), opt("B") } } } })
check(#flat == 2, "an untitled section did not emit exactly its options, got " .. #flat)
check(flat[1].kind == "option" and flat[2].kind == "option",
    "an untitled section emitted a divider row - a mod that declines the header "
    .. "convention must render flat, not with a blank rule above it")

-- ---- sections ------------------------------------------------------------

local mod = {
    sections = {
        { title = nil,       options = { opt("Debug") } },
        { title = "Visuals", options = { opt("Bar"), opt("Width") } },
    },
}
local rows = rowsFor(mod)
check(#rows == 4, "expected 4 rows (1 option, 1 section, 2 options), got " .. #rows)
check(rows[1].kind == "option", "the pre-header option was not emitted first")
check(rows[2].kind == "section" and rows[2].title == "Visuals", "the section row is wrong")
check(rows[3].opt.name == "Bar" and rows[4].opt.name == "Width",
    "declaration order was not preserved - it is the only ordering the engine "
    .. "keeps, and section membership depends on it")
check(rows[2].height == ROWH, "a section row is not one row tall")

-- ---- heights -------------------------------------------------------------
-- ISScrollingListBox hit-tests on item.height (:66-69). A row whose stated
-- height disagrees with what it draws sends the click to a neighbour.

local none = rowsFor({ sections = { { options = { opt("Bare", nil) } } } })[1]
check(none.height == ROWH,
    "an option with NO description got extra height - a phantom gap under every "
    .. "undocumented option, and every row below it hit-tests short")
check(#none.lines == 0, "an absent tooltip produced description lines")

local one = rowsFor({ sections = { { options = { opt("One", "12345678") } } } })[1]
check(#one.lines == 1, "expected 1 wrapped line, got " .. #one.lines)
check(one.height == ROWH + LINEH, "a one-line description has the wrong height")

local two = rowsFor({ sections = { { options = { opt("Two", string.rep("x", 16)) } } } })[1]
check(#two.lines == 2 and two.height == ROWH + 2 * LINEH, "a two-line description is mis-sized")

-- ---- the clamp -----------------------------------------------------------
-- Measured across the suite: median 207 characters, p90 461. Three lines shows
-- most of them in full; unclamped, Dirge's 64 options are a wall of prose.

local long = string.rep("y", 8 * 6)          -- six lines
local clamped = rowsFor({ sections = { { options = { opt("Long", long) } } } })[1]
check(#clamped.lines == 3, "the description was not clamped to 3 lines, got " .. #clamped.lines)
check(clamped.clamped == true, "a clamped row did not say so, so nothing marks it as cut")
check(clamped.height == ROWH + 3 * LINEH, "a clamped row is sized for its full text")

-- Exactly at the clamp is NOT clamped - an off-by-one here puts an ellipsis on
-- a description that is complete, which is a lie about the content.
local exact = rowsFor({ sections = { { options = { opt("Exact", string.rep("z", 24)) } } } })[1]
check(#exact.lines == 3 and exact.clamped == false,
    "a description of exactly 3 lines was marked as truncated")

-- ---- selection expands ---------------------------------------------------

local sel = rowsFor({ sections = { { options = { opt("Long", long) } } } }, "Long")[1]
check(#sel.lines == 6, "the selected row did not expand, got " .. #sel.lines .. " lines")
check(sel.clamped == false, "the expanded row is still marked truncated")
check(sel.height == ROWH + 6 * LINEH,
    "the expanded row kept its collapsed height - the list would draw six lines "
    .. "into three lines of space and every row below would hit-test wrong")

-- Selection is by the namespaced NAME, never the short one. Both of these are
-- `Debug` after the namespace is stripped, which is the collision the whole
-- registry-id rule exists for (CLAUDE.md sect. 6), and it reaches this far:
-- keying on `short` expands BOTH rows and only one of them was clicked.
local twoMods = { sections = { { options = { opt("RFTDDirge.Debug", long),
                                             opt("RFTDCore.Debug", long) } } } }
check(twoMods.sections[1].options[1].short == twoMods.sections[1].options[2].short,
    "precondition: both options must share a short name or the next assertion "
    .. "proves nothing")
local sels = rowsFor(twoMods, "RFTDCore.Debug")
check(sels[1].clamped == true and sels[2].clamped == false,
    "selection matched the wrong option - it must key on the full namespaced "
    .. "name, since two mods can ship the same short name")

print(string.format("DFSandboxView: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
