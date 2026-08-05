-- test_dfviews.lua - one tab, many views.
--
-- WHAT IT PINS, and why each one earns its place:
--   * VISIBILITY IS THE SWITCH. setVisible(false) is also what stops an element
--     receiving mouse events, so "hidden" has to mean hidden to the widget and
--     not merely undrawn. The inactive view's widgets must ALL come back false,
--     every time, or its buttons stay clickable underneath the active view.
--   * widgets are built ONCE. A switch that rebuilt them would drop selection,
--     scroll position and in-flight requests every time somebody glanced at the
--     other view.
--   * relayout runs BEFORE onShow, because onShow fires server requests whose
--     replies paint into rects the switch just changed.
--   * one bad widget cannot leave the panel half-switched.
--
-- Usage (normally via tools\run-tests.bat):
--   lua5.1.exe tools/tests/test_dfviews.lua <repo-root>

local ROOT = arg[1] or "."
local SRC  = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/client/DFViews.lua"

isServer = function() return false end
require  = function() end

-- Buttons the strip builds. Records what DFKit.button was asked for so the
-- strip's own construction can be asserted, not just its behaviour.
local built = {}
DFKit = {
    col = { accent = { r = 1, g = 1, b = 1 }, line = { r = 0, g = 0, b = 0 } },
    button = function(_, x, y, w, label, _target, onclick, kind, opts)
        local b = {
            label = label, w = w, kind = kind, tip = opts and opts.tooltip,
            x = x, y = y, click = onclick,
            setX = function(s, v) s.x = v end,
            setY = function(s, v) s.y = v end,
            getWidth = function(s) return s.w end,
        }
        built[#built + 1] = b
        return b
    end,
}

local okLoad, err = pcall(dofile, SRC)
if not okLoad then
    print("FATAL: could not load " .. SRC)
    print("  " .. tostring(err))
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

local function widget()
    local w = { visible = nil, shown = 0 }
    w.setVisible = function(s, v) s.visible = v; s.shown = s.shown + 1 end
    return w
end

-- ---------------------------------------------------------------------------
-- A host with one inline view (built by the host) and one implemented view,
-- which is exactly the Fleet|Janitor shape.
-- ---------------------------------------------------------------------------
local log = {}
local attachCount = 0

local janitor = {
    attach = function(_) attachCount = attachCount + 1; return { widget(), widget() } end,
    layout = function() log[#log + 1] = "layout" end,
    draw   = function() log[#log + 1] = "draw" end,
    onShow = function() log[#log + 1] = "onShow" end,
}

local relayouts = 0
local v = DFViews.new{
    views = {
        { id = "fleet",   label = "Fleet",   w = 72, tip = "the fleet" },
        { id = "janitor", label = "Janitor", w = 82, tip = "the dials", view = janitor },
    },
    relayout = function() relayouts = relayouts + 1; log[#log + 1] = "relayout" end,
}

eq("the FIRST view is the landing view", v:active(), "fleet")

local strip = v:attachStrip({})
eq("one button per view", #strip, 2)
eq("in declaration order", strip[1].label .. "|" .. strip[2].label, "Fleet|Janitor")
eq("widths honoured", strip[1].w, 72)
eq("tooltips carried through", strip[2].tip, "the dials")

v:attachViews({})
eq("an implemented view is attached once", attachCount, 1)

-- The host's own inline view registers its widgets rather than being attached.
local fleetWidgets = { widget(), widget(), widget() }
v:setWidgets("fleet", fleetWidgets)

-- ---------------------------------------------------------------------------
-- The switch itself.
-- ---------------------------------------------------------------------------
log = {}
v:set("janitor")
eq("active view moved", v:active(), "janitor")
for i, w in ipairs(fleetWidgets) do
    eq("outgoing widget " .. i .. " is hidden", w.visible, false)
end
eq("relayout ran before onShow",
    table.concat(log, ","), "relayout,onShow")

-- Border state is how the strip shows which view you are on.
eq("active button takes the accent border", strip[2].borderColor.a, 0.9)
eq("inactive button falls back to the line colour", strip[1].borderColor.a, 0.4)

log = {}
v:set("fleet")
for i, w in ipairs(fleetWidgets) do
    eq("returning widget " .. i .. " is shown again", w.visible, true)
end
eq("...and the view was NOT rebuilt", attachCount, 1)
eq("a view with no onShow just relayouts", table.concat(log, ","), "relayout")

-- ---------------------------------------------------------------------------
-- Robustness.
-- ---------------------------------------------------------------------------
v:set("nonsense")
eq("an unknown id falls back to the landing view rather than showing nothing",
    v:active(), "fleet")

-- A junk entry in a widget list must not strand the rest half-switched.
local good1, good2 = widget(), widget()
v:setWidgets("fleet", { good1, { setVisible = function() error("bad widget") end }, good2 })
ok("a throwing widget does not abort the switch", pcall(function() v:set("janitor") end))
eq("...widgets before it still hid", good1.visible, false)
eq("...and widgets AFTER it hid too", good2.visible, false)

-- ---------------------------------------------------------------------------
-- Dispatch to the active view only.
-- ---------------------------------------------------------------------------
log = {}
v:set("janitor")
log = {}
v:draw({})
eq("draw reaches the active view", table.concat(log, ","), "draw")
v:layoutActive({}, 0, 0, 100, 100)
eq("layout reaches the active view", table.concat(log, ","), "draw,layout")

log = {}
v:set("fleet")
log = {}
v:draw({})
eq("the inactive view is never drawn", table.concat(log, ","), "")

-- ---------------------------------------------------------------------------
-- Strip positioning walks left to right and reports where it ended.
-- ---------------------------------------------------------------------------
local endX = v:layoutStrip(10, 5)
eq("first button at the origin", strip[1].x, 10)
eq("second follows it", strip[2].x, 10 + 72 + 2)
eq("both share the row", strip[2].y, 5)
eq("the end x is returned for whatever comes next", endX, 10 + 72 + 2 + 82 + 2)

-- ---------------------------------------------------------------------------
print(string.format("DFViews: %d passed, %d failed", pass, fail))
os.exit(fail > 0 and 1 or 0)
