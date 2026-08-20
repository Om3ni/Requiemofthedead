-- test_dfhelp.lua - geometry contract for the shared help popout.

local ROOT = arg[1] or "."
local SRC = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/client/DFHelp.lua"

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
    wrapText = function() return { "first", "second" } end,
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

DFHelpState = nil
dofile(SRC)

local win = DFHelp.show("About", "text")
eq("prose width is clamped after direct string measurement", win.width, 620)
eq("height uses direct title and body line measurements", win.height, 100)
eq("window centers from measured width", win.x, 330)
eq("window centers from measured height", win.y, 310)
eq("window state retains the opened instance", DFHelpState.instance, win)

print(string.format("DFHelp: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
