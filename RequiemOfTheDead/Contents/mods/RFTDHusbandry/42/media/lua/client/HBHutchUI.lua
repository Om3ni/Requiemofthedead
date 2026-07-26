-- HBHutchUI — extends the vanilla hutch window (ISHutchRoostParentPanel) with
-- a bedding "hay meter" beside the dirtiness meter, and an "Add Hay" button
-- beside the "Clean" button. Reads HBBedding state; the button walks the player
-- to the hutch and runs HBAddHayAction (consumes a HayTuft, tops up bedding).
--
-- Pattern (same as STA Better Hutches): save the vanilla method, override to
-- call through, then add our widgets/drawing. The vanilla file is core Lua so
-- ISHutchRoostParentPanel / ISHutchUI already exist when this mod file loads.

if isServer() then return end
if not ISHutchRoostParentPanel or not ISHutchUI then return end

require "TimedActions/ISTimedActionQueue"

local HAY_TYPE   = "Base.HayTuft"
local HAY_COLOR  = { r = 0.55, g = 0.82, b = 0.45, a = 1.0 }  -- green bedding bar

-- Vanilla layout constants (mirror ISHutchUI.lua's file-locals).
local FONT_HGT_SMALL   = getTextManager():getFontHeight(UIFont.Small)
local BUTTON_HGT       = FONT_HGT_SMALL + 6
local PROGRESS_WIDTH   = 200
local UI_BORDER_SPACING = 10

local function findHay(chr)
    local hay
    pcall(function() hay = chr:getInventory():getFirstTypeRecurse(HAY_TYPE) end)
    return hay
end

-- Button handler (called as ISHutchUI method: self == the hutch window).
function ISHutchUI:onAddHayBedding()
    local chr, hutch = self.chr, self.hutch
    if not chr or not hutch then return end
    local hay = findHay(chr)
    if not hay then return end
    local entry
    pcall(function() entry = hutch:getEntrySq() end)
    if entry and luautils.walkAdj(chr, entry) then
        ISTimedActionQueue.add(HBAddHayAction:new(chr, hutch, hay))
    end
end

-- createChildren: add the Add Hay button (hidden until render places it).
local _hbOldCreate = ISHutchRoostParentPanel.createChildren
function ISHutchRoostParentPanel:createChildren()
    _hbOldCreate(self)
    self.hbAddHayBtn = ISButton:new(0, 0, 60, BUTTON_HGT, "Add Hay",
        self.hutchUI, ISHutchUI.onAddHayBedding)
    self.hbAddHayBtn:initialise()
    self.hbAddHayBtn.anchorTop = false
    self.hbAddHayBtn.anchorBottom = false
    self.hbAddHayBtn.borderColor = self.hutchUI.btnBorder
    self.hbAddHayBtn:setVisible(false)
    self:addChild(self.hbAddHayBtn)
end

-- render: vanilla draws the dirt bar + positions birdPooCleanBtn; we draw the
-- bedding bar beside the dirt bar and put Add Hay beside Clean. Layout is
-- derived from birdPooCleanBtn's just-set position so we don't recompute the
-- vanilla row math.
local _hbOldRender = ISHutchRoostParentPanel.render
function ISHutchRoostParentPanel:render()
    _hbOldRender(self)

    local hutch = self.hutchUI and self.hutchUI.hutch
    local btn   = self.hbAddHayBtn
    if not hutch or not btn then return end

    -- Hidden when the coop is closed (vanilla render early-returns then).
    local open = false
    pcall(function() open = hutch:isOpen() end)
    if not open then btn:setVisible(false); return end

    local clean = self.birdPooCleanBtn
    local boxY  = clean:getY() - FONT_HGT_SMALL - 2   -- the dirt-bar row Y
    local bedX  = clean:getX() + PROGRESS_WIDTH + UI_BORDER_SPACING

    local st = (HBBedding and HBBedding.getStatus) and HBBedding.getStatus(hutch)
                or { bedding = 0, max = 100 }
    local frac = (st.max and st.max > 0) and (st.bedding / st.max) or 0

    -- Bedding meter beside the dirtiness meter.
    self:drawProgressBar(bedX, boxY, PROGRESS_WIDTH, FONT_HGT_SMALL, frac, HAY_COLOR)
    self:drawText(string.format("Bedding: %d%%", math.floor(frac * 100 + 0.5)),
        bedX + 7, boxY, 1, 1, 1, 1, UIFont.NewSmall)

    -- Add Hay button beside the Clean button.
    btn:setX(bedX)
    btn:setY(clean:getY())
    btn:setVisible(true)
    local hay  = findHay(self.hutchUI.chr)
    local full = st.bedding and st.max and st.bedding >= st.max
    if not hay then
        btn.enable = false; btn.tooltip = "Requires hay (HayTuft)."
    elseif full then
        btn.enable = false; btn.tooltip = "Bedding is already full."
    else
        btn.enable = true;  btn.tooltip = nil
    end
end
