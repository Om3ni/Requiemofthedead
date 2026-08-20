-- test_dfconsoletab.lua - detail-pane geometry for the Core Console tab.

local ROOT = arg[1] or "."
local SRC = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/client/DFConsoleTab.lua"

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
local onGameStart
Events = {
    OnGameStart = { Add = function(fn) onGameStart = fn end },
    OnTick = { Add = function() end, Remove = function() end },
}
getTextManager = function()
    return { getFontHeight = function() return 15 end }
end

local registered
DFRegistry = { registerTab = function(spec) registered = spec end }
DFLog = {
    snapshot = function() return {} end,
    formatRow = function() return "" end,
    detailText = function() return "" end,
    subscribe = function() end,
    unsubscribe = function() end,
    copyAllToClipboard = function() end,
    copyEntryToClipboard = function() end,
    clear = function() end,
}
DFKit = {
    metrics = { btnH = 24, pad = 8, gap = 6 },
    font = { code = "code", small = "small" },
    rowHeight = function() return 22 end,
    well = function() end,
    sizeList = function(box, x, y, w, h) box.x, box.y, box.width, box.height = x, y, w, h end,
    layout = function(_, x, y, w, h)
        return {
            x = x, y = y, w = w, h = h,
            header = function(self) return { x = self.x, y = self.y } end,
        }
    end,
    refillList = function(box, fill)
        box.items = {}
        fill(box)
    end,
    wrapText = function() return {} end,
    button = function()
        return { setX = function() end, setY = function() end }
    end,
}

ISScrollingListBox = {}
function ISScrollingListBox:derive(name)
    local class = { className = name }
    setmetatable(class, { __index = self })
    return class
end
function ISScrollingListBox:new(x, y, w, h)
    return setmetatable({ x = x, y = y, width = w, height = h, items = {},
        initialise = function() end, instantiate = function() end,
        addItem = function(self, _, item) self.items[#self.items + 1] = { item = item } end,
    }, { __index = self })
end
ISComboBox = {
    new = function()
        return {
            initialise = function() end, instantiate = function() end,
            addOptionWithData = function() end, bringToTop = function() end,
            select = function() end, setX = function() end, setY = function() end,
        }
    end,
}

local panel = { children = {}, addChild = function(self, child) self.children[#self.children + 1] = child end }
dofile(SRC)
onGameStart()
eq("registers the console tab", type(registered), "table")
registered.build(registered, panel, 0, 0, 600, 400)

local detail
for _, child in ipairs(panel.children) do
    if child.className == "DFConsoleDetail" then detail = child end
end
eq("builds the detail list", type(detail), "table")
eq("detail rows use the direct measured font height", detail and detail.itemheight, 16)

print(string.format("DFConsoleTab: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
