-- DFConsoleTab - registers the built-in Console tab on Dragonfly's panel.
--
-- Full scrollback over the DFLog buffer with source filter, clipboard
-- copy, and clear. Same data the bottom strip shows, presented bigger
-- and filterable. No special-casing in DFPanel - this tab registers
-- through DFRegistry just like consumer-mod tabs do.

if isServer() then return end

require "ISUI/ISScrollingListBox"
require "ISUI/ISButton"
require "ISUI/ISComboBox"

local LEVEL_COLOR = {
    info  = { 0.85, 0.85, 0.85 },
    warn  = { 0.95, 0.75, 0.30 },
    error = { 0.95, 0.40, 0.40 },
    audit = { 0.55, 0.75, 0.95 },
}

local ConsoleList = ISScrollingListBox:derive("DFConsoleList")

function ConsoleList:doDrawItem(y, item, alt)
    local e = item.item
    if not e then return y + self.itemheight end

    if self.selected == item.index then
        self:drawRect(0, y, self.width, self.itemheight - 1, 0.35, 0.25, 0.55, 0.85)
    elseif alt then
        self:drawRect(0, y, self.width, self.itemheight - 1, 0.18, 0.08, 0.08, 0.08)
    end

    local c = LEVEL_COLOR[e.level] or LEVEL_COLOR.info
    self:drawText(DFLog.formatLine(e), 4, y + 2, c[1], c[2], c[3], 1, UIFont.Small)
    return y + self.itemheight
end

local function rebuildList(list, filter)
    list:clear()
    for _, e in ipairs(DFLog.snapshot(filter)) do
        list:addItem("", e)
    end
    if #list.items > 0 then
        list.selected = #list.items
    end
end

local function build(spec, panel, x, y, w, h)
    local PADDING = 6
    local BTN_H   = 22

    local filterCombo = ISComboBox:new(x + PADDING, y + PADDING, 160, BTN_H, panel)
    filterCombo:initialise()
    filterCombo:instantiate()
    filterCombo:addOptionWithData("All sources",    "all")
    filterCombo:addOptionWithData("Admin only",     "Admin")
    filterCombo:addOptionWithData("Errors only",    "Error")
    filterCombo:addOptionWithData("Mod traffic",    "Mod")
    panel:addChild(filterCombo)

    local list = ConsoleList:new(
        x + PADDING,
        y + PADDING + BTN_H + PADDING,
        w - PADDING * 2,
        h - (PADDING * 3 + BTN_H))
    list.itemheight  = 18
    list.drawBorder  = true
    list:initialise()
    list:instantiate()
    panel:addChild(list)

    local function refresh()
        local filter = "all"
        if filterCombo.getOptionData then
            filter = filterCombo:getOptionData(filterCombo.selected) or "all"
        end
        rebuildList(list, filter)
    end

    -- Wire combo change.
    local origDoSelected = filterCombo.select
    filterCombo.select = function(self_, ...)
        origDoSelected(self_, ...)
        refresh()
    end

    local copyBtn = ISButton:new(x + PADDING + 170, y + PADDING, 100, BTN_H,
        "Copy all", panel, function()
            local filter = "all"
            if filterCombo.getOptionData then
                filter = filterCombo:getOptionData(filterCombo.selected) or "all"
            end
            DFLog.copyAllToClipboard(filter)
        end)
    copyBtn.borderColor.a = 0.3
    copyBtn:initialise()
    copyBtn:instantiate()
    panel:addChild(copyBtn)

    local clearBtn = ISButton:new(x + PADDING + 280, y + PADDING, 80, BTN_H,
        "Clear", panel, function() DFLog.clear(); refresh() end)
    clearBtn.borderColor.a = 0.3
    clearBtn:initialise()
    clearBtn:instantiate()
    panel:addChild(clearBtn)

    local listener = function() refresh() end
    DFLog.subscribe(listener)
    -- (Listener leaks when the tab is rebuilt; acceptable for v0.1.
    --  Cleanup hook lives in v0.2 polish.)

    -- Z-order: combo's dropdown popup must render above the scrolling list.
    -- ISUI draws siblings in addChild order (later = on top); the list was
    -- added after the combo so it overdraws the popup. bringToTop promotes
    -- the combo back above so its expanded options aren't hidden behind rows.
    filterCombo:bringToTop()

    refresh()
end

print("[Dragonfly] DFConsoleTab body loaded; deferring registration to OnGameStart")

-- Defer registration to OnGameStart so DFRegistry is guaranteed loaded
-- regardless of alphabetical file-load order.
Events.OnGameStart.Add(function()
    print("[Dragonfly] DFConsoleTab OnGameStart fired; DFRegistry=" .. tostring(DFRegistry ~= nil))
    if not DFRegistry then return end
    if not DFLog then
        print("[Dragonfly] DFConsoleTab: DFLog not loaded, skipping tab registration")
        return
    end
    local ok, err = pcall(function()
        DFRegistry.registerTab{
            id    = "console",
            label = "Console",
            order = 1000,
            build = build,
        }
    end)
    if not ok then
        print("[Dragonfly] DFConsoleTab registerTab error: " .. tostring(err))
    end
end)

-- Dragonfly v0.2.0
