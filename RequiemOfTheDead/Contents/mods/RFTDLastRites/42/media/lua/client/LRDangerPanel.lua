-- LRDangerPanel.lua  (client)
--
-- Registers the "Danger" tab in the LRHub settings window: per-signal on/off,
-- the over-head thought-quip toggle, and a calibration nudge for the over-head
-- badge vertical anchor (projection alignment varies with zoom/resolution, so
-- it's exposed rather than hard-coded). All purely cosmetic client prefs,
-- persisted via LRPrefs.

require "ISUI/ISTickBox"
require "ISUI/ISButton"

LRDangerPanel = LRDangerPanel or {}

-- Toggle rows, in display order. Each maps a checkbox to a pref key.
local TOGGLES = {
    { pref = "lr_danger_enabled", default = true, label = "IGUI_LR_Danger_Enabled" },
    { pref = "lr_danger_cold",    default = true, label = "IGUI_LR_Danger_Cold" },
    { pref = "lr_danger_hot",     default = true, label = "IGUI_LR_Danger_Hot" },
    { pref = "lr_danger_blood",   default = true, label = "IGUI_LR_Danger_Blood" },
    { pref = "lr_danger_quips",   default = true, label = "IGUI_LR_Danger_Quips" },
    { pref = "lr_danger_shake",   default = true, label = "IGUI_LR_Danger_Shake" },
}

local Y_ADJUST_STEP = 8
local Y_ADJUST_MIN  = -300
local Y_ADJUST_MAX  = 300

-- Checkbox change handler. ISTickBox calls this as (target, index, selected);
-- option index lines up with TOGGLES since we add options in that order.
local function onToggle(_, index, selected)
    local row = TOGGLES[index]
    if row then
        LRPrefs.set(row.pref, selected and true or false)
        if LRDanger and LRDanger.update then pcall(LRDanger.update) end
    end
end

local function nudgeY(delta)
    local v = LRPrefs.get("lr_overhead_yadjust", 0) + delta
    if v < Y_ADJUST_MIN then v = Y_ADJUST_MIN end
    if v > Y_ADJUST_MAX then v = Y_ADJUST_MAX end
    LRPrefs.set("lr_overhead_yadjust", v)
    LRDangerHUD.overheadYAdjust = v
end

local function fill(view)
    local x = 12
    local y = 12

    -- Toggles.
    local tick = ISTickBox:new(x, y, view.width - x * 2, 20, "", nil, onToggle)
    tick:initialise()
    for i = 1, #TOGGLES do
        local row = TOGGLES[i]
        tick:addOption(getText(row.label))
        tick.selected[i] = LRPrefs.get(row.pref, row.default) and true or false
    end
    view:addChild(tick)
    y = y + tick:getHeight() + 16   -- addOption sized the box; use its real height

    -- Over-head vertical calibration: [-] [+] (value drawn live in render).
    local labelW = view.width - x * 2 - 72
    view.calibY = y
    local minus = ISButton:new(x + labelW, y, 32, 24, "-", nil, function() nudgeY(-Y_ADJUST_STEP) end)
    minus:initialise()
    view:addChild(minus)
    local plus = ISButton:new(x + labelW + 36, y, 32, 24, "+", nil, function() nudgeY(Y_ADJUST_STEP) end)
    plus:initialise()
    view:addChild(plus)

    -- Live labels (calibration value + hint).
    view.render = function(v)
        v:drawText(getText("IGUI_LR_Danger_OverheadY") .. ": " .. LRPrefs.get("lr_overhead_yadjust", 0),
            x, v.calibY + 4, 0.85, 0.85, 0.85, 1, UIFont.Small)
        v:drawText(getText("IGUI_LR_Danger_Hint"), x, v.height - 24, 0.6, 0.6, 0.6, 1, UIFont.Small)
    end
end

-- Register with the hub on boot - by OnGameBoot every client Lua file has
-- loaded, so LRHub is defined regardless of alphabetical load order (LRHub.lua
-- sorts after LRDangerPanel.lua).
Events.OnGameBoot.Add(function()
    if LRHub and LRHub.registerSection then
        LRHub.registerSection{ id = "danger", title = getText("IGUI_LR_Danger_Tab"), fill = fill }
    end
end)
