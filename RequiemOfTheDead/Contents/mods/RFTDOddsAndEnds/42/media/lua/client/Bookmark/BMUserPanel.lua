-- BMUserPanel.lua  (client)
--
-- Puts Bookmark's one switch - "Welcome Message", default OFF - on the vanilla Client
-- panel (ISUserPanelUI), beside vanilla's own Show Connection Info / Show
-- Server Info tick-boxes. One checkbox does not earn a window of its own, so
-- this deliberately does NOT open a settings screen the way Reclamation's "My
-- Vehicles" button or Last Rites' hub button do - it is just another tick-box
-- in the list that is already there.
--
-- Placement: we take the row Close currently occupies and push Close down one
-- row, which lands us directly under showServerInfo - the tick-box group is
-- exactly where a "show X" preference belongs. Vanilla normalizes every child
-- to a common width in create() (ISUserPanelUI.lua:91-97) before adding Close,
-- so we borrow Close's dimensions rather than computing our own.
--
-- MP-only by design: the Client button that opens ISUserPanelUI only exists
-- for network clients. Matches Reclamation's and Last Rites' identical scope.
--
-- Post-hooks create() (no vanilla edits). Last Rites and Reclamation hook the
-- same function to insert their buttons at the TOP; ours appends at the bottom
-- instead, so the two never contend for a row - and each hook re-grows the
-- panel to fit its lowest control, so any order of loading still fits.

if isServer() and not isClient() then return end

require "Bookmark/BMClient"   -- explicit: isEnabled/setEnabled must not ride on load order
require "ISUI/UserPanel/ISUserPanelUI"
require "ISUI/ISTickBox"

local UI_BORDER_SPACING = 10

local _create = ISUserPanelUI.create
function ISUserPanelUI:create()
    _create(self)

    -- cancel (Close) is a reliable, width-normalized standard button we borrow
    -- dimensions and the x-column from.
    local cancel = self.cancel
    if not cancel then return end

    if not self.bmTick then
        local w, h = cancel:getWidth(), cancel.height
        local ROW = h + UI_BORDER_SPACING

        local tick = ISTickBox:new(cancel.x, cancel.y, w, h,
            getText("IGUI_OE_BookmarkEnable"), self,
            function(_, index, selected)
                if index == 1 then Bookmark.setEnabled(selected and true or false) end
            end)
        tick:initialise()
        tick:instantiate()
        tick.selected[1] = Bookmark.isEnabled()
        tick:addOption(getText("IGUI_OE_BookmarkEnable"))
        self:addChild(tick)
        self.bmTick = tick

        -- Close moves down to make room; it stays the last control.
        cancel:setY(cancel:getY() + ROW)
    end

    -- Grow the panel to fit its lowest control (robust vs. the other mods'
    -- hooks and vanilla's taller-than-accounted tick-boxes), so nothing spills
    -- past the background.
    local maxBottom = 0
    for _, c in pairs(self:getChildren()) do
        local b = c.getBottom and c:getBottom()
        if b and b > maxBottom then maxBottom = b end
    end
    if maxBottom > 0 then self:setHeight(maxBottom + UI_BORDER_SPACING + 1) end
end
