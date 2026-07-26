-- RCUserPanelHook.lua (client)
--
-- Adds a "My Vehicles" button to the TOP of the vanilla Client panel
-- (ISUserPanelUI) - the owner-specced entry point for the fleet panel
-- (management lives here, NOT on the vehicle right-click menu).
--
-- WHY the top (not above Close): the bottom of the panel is its most contested
-- region - vanilla's two ISTickBox controls resize TALLER than a standard button
-- (ISTickBox:addOption sets height = itemHgt, which includes an extra gap) while
-- create() only advances y by the standard button height, so its accounting
-- under-counts there, AND other mods append their own controls in the same spot.
-- A button inserted into that zone overlapped the tick-boxes. The top row is
-- uncontested, so we insert there and push every existing control down one row.
--
-- MP-only by design: the Client button that opens ISUserPanelUI only exists for
-- network clients (matches Reclamation's dedicated-MP scope).
--
-- Post-hooks create() (no vanilla edits) with our own onclick closure. Mirrors
-- Last Rites' LRUserPanelHook, which does the identical top-insert - when both
-- mods are present they simply stack at the top, in load order.

if isServer() and not isClient() then return end

require "ISUI/UserPanel/ISUserPanelUI"

local UI_BORDER_SPACING = 10

local _create = ISUserPanelUI.create
function ISUserPanelUI:create()
    _create(self)

    if not RCShared.cfg().claimsEnabled then return end

    -- cancel (Close) is a reliable, width-normalized standard button we borrow
    -- dimensions from.
    local cancel = self.cancel
    if not cancel then return end

    if not self.rcBtn then
        local w, h = cancel:getWidth(), cancel.height
        local ROW = h + UI_BORDER_SPACING

        -- current topmost control (all controls sit below the title text, which
        -- is drawn in render(), not a child, so it never moves)
        local topY
        for _, c in pairs(self:getChildren()) do
            local cy = c:getY()
            if topY == nil or cy < topY then topY = cy end
        end
        if not topY then return end

        -- free the top row: push every existing control (incl. any other mod's
        -- button already inserted here) down by one row
        for _, c in pairs(self:getChildren()) do
            c:setY(c:getY() + ROW)
        end

        local btn = ISButton:new(cancel.x, topY, w, h, getText("IGUI_RC_MyVehicles"), self,
            function(target) RCMyVehicles.open(target.player or getPlayer()) end)
        btn.internal    = "RCMYVEHICLES"
        btn.borderColor = self.buttonBorderColor
        btn:initialise()
        btn:instantiate()
        self:addChild(btn)   -- added AFTER the push, so it stays at topY
        self.rcBtn = btn
    end

    -- Grow the panel to fit its lowest control (robust vs. the other hook + the
    -- taller-than-accounted tick-boxes), so nothing spills past the background.
    local maxBottom = 0
    for _, c in pairs(self:getChildren()) do
        local b = c.getBottom and c:getBottom()
        if b and b > maxBottom then maxBottom = b end
    end
    if maxBottom > 0 then self:setHeight(maxBottom + UI_BORDER_SPACING + 1) end
end
