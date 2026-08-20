-- test_dfentry.lua - geometry contract for the shared text-entry popout.

local ROOT = arg[1] or "."
local SRC = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/client/DFEntry.lua"

local pass, fail = 0, 0
local function eq(name, got, want)
    if got == want then pass = pass + 1
    else
        fail = fail + 1
        print("FAIL " .. name .. " (got " .. tostring(got) .. ", want " .. tostring(want) .. ")")
    end
end

isServer = function() return false end
require = function() end
UIFont = { Small = "small" }
DFKit = {
    font = { small = "small", label = "small" },
    metrics = { btnH = 24, gap = 6 },
    wrapText = function(text) return { text } end,
}
getTextManager = function()
    return {
        getFontHeight = function() return 20 end,
        MeasureStringX = function(_, _, text) return #text * 10 end,
    }
end
getCore = function()
    return { getScreenWidth = function() return 1280 end, getScreenHeight = function() return 720 end }
end

ISPanel = {}
function ISPanel:derive()
    local derived = {}
    setmetatable(derived, { __index = self })
    return derived
end
function ISPanel:new(x, y, w, h)
    return {
        x = x, y = y, width = w, height = h,
        initialise = function() end,
        instantiate = function() end,
        addToUIManager = function() end,
    }
end

DFEntryState = nil
dofile(SRC)

local rule = string.rep("w", 50)
local win = DFEntry.show({ title = "Rule", rule = rule })
eq("rule width uses the direct string measurement", win.width, 532)
eq("height uses direct title, line, and entry measurements", win.height, 172)
eq("window is centered after measured geometry", win.x, 374)
eq("window state retains the opened instance", DFEntryState.instance, win)

win.entry = { getInternalText = function() return "edited value" end }
eq("text reads the current direct internal value", win:text(), "edited value")

print(string.format("DFEntry: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
