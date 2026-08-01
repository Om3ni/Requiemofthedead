-- COClient.lua - Container Order: drag the container buttons in your own
-- inventory sidebar into the order you want, and have it stick.
--
-- MOVED OUT OF CORE 2026-07-31, and the reason is the whole point of this mod.
-- It lived in RFTDCore as RDContainerOrder.lua, parked there because it was a
-- leaf feature waiting on RFTD Wardrobe to be scoped. Core is hard-required by
-- every mod in the family, so anything parked there can never be switched off -
-- and this one reorders a UI surface that popular third-party mods also reorder.
-- A workshop report: "conflict with container reorder mod (better container,
-- clean ui...). i just want Dirge, but maybe RFTDCore cause error. there no
-- error code, but only that container reorder function doesn't work when
-- RFTDCore is activated." Exactly right, and there was no error to find: apply()
-- ran after the other mod on every refreshBackpacks and restacked every button,
-- so their layout was overwritten with a result identical to vanilla.
--
-- Here it is optional twice over - don't install Odds & Ends, or leave
-- ContainerOrderEnable off - so wanting Dirge no longer means taking this.
-- It landed here rather than waiting for Wardrobe because O&E is the catch-all
-- and this is exactly what the catch-all is for. Its fellow lodger in Core,
-- RDEquippedCollapse.lua, moved out the same day and now sits beside it as
-- InventoryCollapse/ICClient.lua.
--
-- Vanilla has no ordering concept at all: refreshBackpacks wipes self.backpacks,
-- walks the worn containers in engine order, and addContainerButton lays each one
-- out at ((#backpacks) * buttonSize). Your keyring sits wherever the inventory
-- iterator happened to put it, and it moves when you change bags. This adds an
-- order the player chooses, stored per container in player modData.
--
-- NO FORK. Three wrappers on the vanilla class tables, nothing copied:
--   addContainerButton   -> attach drag handlers to the button it just made
--   refreshBackpacks     -> re-sort and re-lay-out after every rebuild
--   ISInventoryPageContainerButtonPanel.render -> draw the drop indicator
--
-- WE SORT self.backpacks ITSELF, not just the on-screen Y positions, and that is
-- the main design decision here. Vanilla indexes self.backpacks[i] positionally in
-- at least five places for container cycling (onMouseWheel plus the keyboard
-- paths at :521, :824, :837, :1325). Reordering only the Y coordinates leaves the
-- array in engine order, so the wheel walks the list in an order that no longer
-- matches what the eye sees - you scroll from your bag to your keyring and land
-- somewhere else. Sorting the array fixes every one of those consumers at once
-- instead of wrapping them one at a time. It also makes vanilla's own
-- setScrollHeight(self.backpacks[#self.backpacks]:getBottom()) correct again,
-- since after the sort the last element really is the bottom one.
--
-- DORMANT UNTIL USED, and this is a compatibility contract, not an optimisation.
-- apply() returns immediately unless the player has actually dragged something,
-- because the restack is an unconditional `setY` over EVERY button that forces
-- one vertical column at our buttonSize. With no saved order every container
-- falls back to DEFAULT + index, so we would compute vanilla order and then write
-- it over a third-party grid or sort for no gain at all. That is the shipped bug
-- above. The kill switch is the coarse answer; this is the one that matters,
-- because it means a player who never touches the feature never collides with
-- anything even with the module enabled.
--
-- The drag handlers stay installed while dormant - they pass through to the
-- captured originals unless a drag crosses the threshold, which is how a first
-- drag creates the order that wakes apply() up. So a player running both this and
-- a reorder mod can still collide by dragging deliberately; that is what
-- ContainerOrderEnable is for.
--
-- TWO VANILLA BEHAVIOURS THE HANDLERS HAVE TO RESPECT:
--
--   1. Buttons are POOLED. refreshBackpacks pushes them into self.buttonPool and
--      addContainerButton pulls them back out, so the same button object is reused
--      across refreshes and any handler we install persists. Installing blindly
--      would wrap our own wrapper a little more on every refresh until the call
--      chain is hundreds deep. Hence the coDragReady tag.
--
--   2. addContainerButton REASSIGNS button.onMouseUp every call
--      (= ISInventoryPage.onBackpackMouseUp). So that one must be re-captured and
--      re-wrapped on every refresh, while onMouseDown / onMouseMove /
--      onMouseMoveOutside are only ever set by us and are installed once.
--
-- Order lives in player modData keyed by the container's ITEM id ("i" .. getID()),
-- with "main" for the character's own inventory. A bag destroyed and recreated
-- gets a new id and therefore a default slot; that is correct - it is a different
-- bag. Priorities are stored as (index * 10) so a later insert has room between
-- two neighbours without renumbering everything.

if isServer() then return end

require "OEShared"
require "ISUI/ISInventoryPage"

ContainerOrder = ContainerOrder or {}

-- Deliberately still "RDContainerOrder": this is a live player-modData key, and
-- every player who has already dragged a button on the RotD server has an order
-- stored under it. Renaming it to match the new module prefix would silently drop
-- all of them back to engine order for nothing but cosmetic consistency.
local MD_KEY    = "RDContainerOrder"
local DEFAULT   = 1000          -- unranked containers sort after ranked ones
local STEP      = 10

-- ---------------------------------------------------------------------------
-- Kill switch
-- ---------------------------------------------------------------------------

-- Read at use time, not at load: SandboxVars is not up when this file is walked,
-- and OEShared.enabled defaults ON until it is. Same idiom as RipIt/RIClient.
function ContainerOrder.isEnabled()
    return OEShared.enabled("ContainerOrderEnable")
end

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

-- Stable key for a container. The player's own inventory has no containing item,
-- which is exactly what distinguishes it.
local function keyFor(container)
    if not container then return nil end
    local item
    pcall(function() item = container:getContainingItem() end)
    if not item then return "main" end
    local id
    pcall(function() id = item:getID() end)
    if id then return "i" .. tostring(id) end
    return nil
end

local function orderTable(playerObj, create)
    if not playerObj then return nil end
    local md
    pcall(function() md = playerObj:getModData() end)
    if not md then return nil end
    if type(md[MD_KEY]) ~= "table" then
        if not create then return nil end
        md[MD_KEY] = {}
    end
    return md[MD_KEY]
end

-- Has this player actually dragged anything? Everything in apply() is gated on
-- this, and MUST be - see DORMANT UNTIL USED in the header.
--
-- pairs(), NOT next(): B42's Kahlua registers no global `next`, so `next(t) == nil`
-- throws "Object tried to call nil" at runtime while passing tools/run-tests under
-- real Lua 5.1. Same trap InventoryCollapse/ICClient.lua documents at length.
local function hasOrder(playerObj)
    local t = orderTable(playerObj, false)
    if not t then return false end
    for _, v in pairs(t) do
        if type(v) == "number" then return true end
    end
    return false
end

function ContainerOrder.priorityOf(playerObj, container, fallbackIndex)
    local t = orderTable(playerObj, false)
    local k = keyFor(container)
    if t and k and type(t[k]) == "number" then return t[k] end
    -- Unranked: keep engine order among themselves, after everything ranked.
    return DEFAULT + (fallbackIndex or 0)
end

-- Persist the current visual order. Called once on drop, not per frame.
function ContainerOrder.commit(page)
    local playerObj = getSpecificPlayer(page.player)
    local t = orderTable(playerObj, true)
    if not t then return end

    local ordered = {}
    for _, b in ipairs(page.backpacks) do
        if b:getIsVisible() then ordered[#ordered + 1] = b end
    end
    table.sort(ordered, function(a, b) return a:getY() < b:getY() end)

    for i, b in ipairs(ordered) do
        local k = keyFor(b.inventory)
        if k then t[k] = i * STEP end
    end
    pcall(function() playerObj:transmitModData() end)
end

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------

-- Sort the ARRAY (see header) and restack the buttons to match.
function ContainerOrder.apply(page)
    if not ContainerOrder.isEnabled() then return end
    if not page.onCharacter then return end
    if type(page.backpacks) ~= "table" or #page.backpacks == 0 then return end

    local playerObj = getSpecificPlayer(page.player)
    if not playerObj then return end

    -- DORMANT UNTIL USED. Without a saved order there is nothing to impose, and
    -- the restack below would be an unconditional write over another mod's layout
    -- for a result identical to vanilla. Bail before touching anything.
    if not hasOrder(playerObj) then return end

    local rank = {}
    for i, b in ipairs(page.backpacks) do
        rank[b] = ContainerOrder.priorityOf(playerObj, b.inventory, i)
    end

    table.sort(page.backpacks, function(a, b)
        if rank[a] ~= rank[b] then return rank[a] < rank[b] end
        return tostring(a.name or "") < tostring(b.name or "")
    end)

    local size = page.buttonSize or 32
    for i, b in ipairs(page.backpacks) do
        b:setY(((i - 1) * size) - 1)
    end

    -- Vanilla set this before we moved anything; the bottom button changed.
    if page.containerButtonPanel and page.backpacks[#page.backpacks] then
        pcall(function()
            page.containerButtonPanel:setScrollHeight(page.backpacks[#page.backpacks]:getBottom())
        end)
    end
end

-- Where a drop would land: the count of visible buttons whose midpoint sits above
-- the dragged button's midpoint. 0 means "above everything".
function ContainerOrder.insertPosition(page, dragged)
    local others = {}
    for _, b in ipairs(page.backpacks) do
        if b ~= dragged and b:getIsVisible() then others[#others + 1] = b end
    end
    table.sort(others, function(a, b) return a:getY() < b:getY() end)

    local mid = dragged:getY() + dragged:getHeight() / 2
    for i, b in ipairs(others) do
        if mid < b:getY() + b:getHeight() / 2 then return i - 1, others end
    end
    return #others, others
end

-- ---------------------------------------------------------------------------
-- Drag handlers
-- ---------------------------------------------------------------------------

local function pageOf(button)
    local panel = button:getParent()
    return panel and panel.parent or nil
end

local function onMouseDown(self, x, y)
    local page = pageOf(self)
    self.coDragStartY = self:getY()
    self.coDragStartMouseY = getMouseY()
    self.coCanDrag = ContainerOrder.isEnabled() and page ~= nil and page.onCharacter == true
    self.coDragging = false
    if self.coDownOrig then return self.coDownOrig(self, x, y) end
end

local function onMouseMove(self, dx, dy, skipOriginal)
    if not skipOriginal and self.coMoveOrig then self.coMoveOrig(self, dx, dy) end
    if not (self.pressed and self.coCanDrag) then return end

    local page = pageOf(self)
    if not page then return end

    local size = page.buttonSize or 32
    -- Threshold so a normal click to SELECT a container is never read as a drag.
    if math.abs((self.coDragStartMouseY or 0) - getMouseY()) > size / 6 then
        self.coDragging = true
    end
    if not self.coDragging then return end

    local panel = self:getParent()
    local newY = getMouseY() - panel:getAbsoluteY() - self:getHeight() / 2
    self:setY(math.max(0, newY))
    self:bringToTop()

    page.coDragButton = self
    page.coDropIndex = ContainerOrder.insertPosition(page, self)
end

local function onMouseMoveOutside(self, dx, dy)
    if self.coOutOrig then self.coOutOrig(self, dx, dy) end
    if not self.coDragging then return end
    onMouseMove(self, dx, dy, true)
    -- Released off the panel: the button never gets a real onMouseUp, so finish
    -- here or it stays stuck to the cursor.
    if not isMouseButtonDown(0) then
        self.pressed = false
        ContainerOrder.finishDrag(self)
    end
end

local function onMouseUp(self, x, y)
    if self.coDragging then
        self.pressed = false
        ContainerOrder.finishDrag(self)
        return
    end
    -- Not a drag: let vanilla select the container as usual.
    if self.coUpOrig then return self.coUpOrig(self, x, y) end
end

function ContainerOrder.finishDrag(button)
    local page = pageOf(button)
    button.coDragging = false
    if not page then return end

    page.coDragButton = nil
    page.coDropIndex  = nil

    -- A nudge shorter than half a slot is a mis-click, not a reorder: snap back
    -- rather than silently resequencing everything.
    local size = page.buttonSize or 32
    if button.coDragStartY and math.abs(button:getY() - button.coDragStartY) <= size / 2 then
        button:setY(button.coDragStartY)
        return
    end

    ContainerOrder.commit(page)
    if page.refreshBackpacks then pcall(function() page:refreshBackpacks() end) end
end

-- Install on one button. See header note 2: onMouseUp is reassigned by vanilla on
-- every addContainerButton, so it is re-captured every call; the rest are ours
-- alone and are installed once per pooled button object.
local function attach(button)
    if button.onMouseUp ~= onMouseUp then
        button.coUpOrig = button.onMouseUp
        button.onMouseUp = onMouseUp
    end
    if button.coDragReady then return end
    button.coDragReady = true
    button.coDownOrig = button.onMouseDown
    button.coMoveOrig = button.onMouseMove
    button.coOutOrig  = button.onMouseMoveOutside
    button.onMouseDown        = onMouseDown
    button.onMouseMove        = onMouseMove
    button.onMouseMoveOutside = onMouseMoveOutside
end

-- ---------------------------------------------------------------------------
-- Install
-- ---------------------------------------------------------------------------

local installed = false

local function install()
    if installed then return end
    if type(ISInventoryPage) ~= "table" then return end
    if type(ISInventoryPage.addContainerButton) ~= "function" then return end
    installed = true

    local origAdd = ISInventoryPage.addContainerButton
    function ISInventoryPage:addContainerButton(container, texture, name, tooltip)
        local button = origAdd(self, container, texture, name, tooltip)
        if button and self.onCharacter and ContainerOrder.isEnabled() then
            pcall(attach, button)
        end
        return button
    end

    local origRefresh = ISInventoryPage.refreshBackpacks
    function ISInventoryPage:refreshBackpacks(...)
        local r = origRefresh(self, ...)
        pcall(ContainerOrder.apply, self)
        return r
    end

    if type(ISInventoryPageContainerButtonPanel) == "table"
        and type(ISInventoryPageContainerButtonPanel.render) == "function" then
        local origRender = ISInventoryPageContainerButtonPanel.render
        function ISInventoryPageContainerButtonPanel:render(...)
            local r = origRender(self, ...)
            local page = self.parent
            -- No enabled() check: coDragButton is only ever set by a live drag,
            -- which cannot start while the module is off.
            if page and page.coDragButton and page.coDropIndex then
                -- Flat bar rather than a texture: no art to ship, and it reads
                -- clearly against every container icon.
                local size = page.buttonSize or 32
                local y = page.coDropIndex * size - 1
                pcall(function()
                    self:drawRect(1, y, self:getWidth() - 2, 2, 0.9, 0.55, 0.75, 1.0)
                end)
            end
            return r
        end
    end
end

install()
Events.OnGameStart.Add(install)

return ContainerOrder
