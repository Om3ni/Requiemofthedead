-- LRUserPanelHook.lua  (client)
--
-- Adds a "Last Rites" button to the TOP of the vanilla Client panel
-- (ISUserPanelUI). The button opens the LRHub window.
--
-- WHY the top (not above Close): the bottom of the panel is contested - vanilla's
-- ISTickBox controls resize taller than a standard button while create() only
-- advances y by the standard height (so its accounting under-counts there), and
-- other mods append their own controls in the same spot. A button inserted there
-- overlapped the tick-boxes. The top row is uncontested: we insert there and push
-- every existing control down one row. Reclamation's RCUserPanelHook does the
-- identical top-insert, so when both mods are present they simply stack.
--
-- MP-only by design: the on-screen Client button that opens ISUserPanelUI only
-- exists for network clients (see vanilla ISEquippedItem.lua, the whole button
-- stack is gated by `if isClient()`). Matches the intended scope.
--
-- We post-hook create() (no vanilla file edits) with our own onclick closure.

require "ISUI/UserPanel/ISUserPanelUI"

local UI_BORDER_SPACING = 10

local _create = ISUserPanelUI.create
function ISUserPanelUI:create()
    _create(self)

    -- cancel (Close) is a reliable, width-normalized standard button we borrow
    -- dimensions from.
    local cancel = self.cancel
    if not cancel then return end

    if not self.lrBtn then
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

        local btn = ISButton:new(cancel.x, topY, w, h, getText("IGUI_LR_Panel"), self,
            function(target) LRHub.toggle(target.player or getPlayer()) end)
        btn.internal    = "LASTRITES"
        btn.borderColor = self.buttonBorderColor
        btn:initialise()
        btn:instantiate()
        self:addChild(btn)   -- added AFTER the push, so it stays at topY
        self.lrBtn = btn
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
