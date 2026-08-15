-- SPDX-License-Identifier: GPL-3.0-or-later
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
-- BUT THE ARRAY MUST BE BACK IN ENGINE ORDER WHEN refreshBackpacks RUNS, and that
-- is the price of sorting it. Fixed 2026-08-07 after a report that reordering was
-- "only visual - clicking on the fanny pack brings up the hiking bag's inventory,
-- and it depends solely on which was equipped first".
--
-- Vanilla dispatches a container-button click TWICE. onBackpackMouseUp calls
-- ISButton.onMouseUp, whose onclick reaches selectContainer, and selectContainer
-- ends by calling refreshBackpacks (:1119). Control comes back and
-- onBackpackMouseUp calls onBackpackClick AGAIN (:1365) on the button object it
-- captured before that refresh. Vanilla survives its own double dispatch because
-- refreshBackpacks rebinds each pooled button to the container it already held:
-- the pool is FILLED by walking self.backpacks (:1542) and DRAINED front-first
-- (:1468) while containers are walked in engine order (:1562), so as long as
-- self.backpacks is itself in engine order the rebinding is the identity map.
--
-- Leave the array sorted and that map becomes "visual slot k -> engine container
-- k". The first dispatch opens the right bag, the refresh rebinds the button
-- under the cursor to whatever equip order puts at that slot, and the second
-- dispatch opens THAT. Dropping an item was unaffected and the asymmetry is the
-- tell: a drop happens with pressed=false and allowMouseUpProcessing=false
-- (:1473), so onclick never fires, no refresh happens, and dropItemsInContainer
-- reads the binding while it is still good.
--
-- So restoreEngineOrder() runs BEFORE origRefresh and apply() runs after. Vanilla
-- gets the invariant it silently depends on for the length of the rebuild; every
-- consumer outside the rebuild still sees the player's order. Nothing else can
-- observe the difference - origRefresh wipes the array (:1554) immediately after
-- filling the pool from it.
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
-- A GESTURE IS EITHER A REORDER OR A CLICK, NEVER NEITHER. Fixed 2026-08-01 after
-- a report that moving a bag "changes the position of the icon, but not the
-- inventory - when you open the duffel you are actually looking at the fanny
-- pack". Two thresholds were doing one job and disagreeing about it: onMouseMove
-- ARMED a drag once the mouse had travelled size/6 (five pixels on a 32px
-- button), while finishDrag only COMMITTED one past size/2, and onMouseUp
-- returned unconditionally the moment coDragging was set. Everything in between
-- - which is to say most real clicks, since five pixels of drift is nothing -
-- reordered nothing and swallowed the selection on its way out, so the pane went
-- on showing whichever container was already open while the icon under the
-- cursor visibly hopped and snapped back. Clicking a bag left you in a different
-- bag, exactly as reported.
--
-- The rule now: finishDrag REPORTS whether it resequenced anything, and
-- onMouseUp falls through to vanilla's handler when it did not. A drag that ends
-- where it began is a click, and is treated as one.
--
-- The test for "did it move" is slots, not pixels: dropIndexAt() is asked where
-- the button would land and where it started, and they are compared. That is the
-- same question the on-screen drop indicator answers during the drag, so what
-- the player was shown is what they get. Arming now waits for size/2 as well -
-- buttons sit a full size apart, so no drop can change anything until the mouse
-- has moved a whole button, and arming six times sooner only bought the flicker.
--
-- ARMING MUST NOT DEPEND ON THE CURSOR STAYING INSIDE THE BUTTON. Fixed
-- 2026-08-08 after the owner reported it took "a good 10 tries" to make a bag
-- move. The threshold above is the right SIZE; it was being measured in the wrong
-- PLACE, and the two faults compounded into a gesture almost nobody could perform.
--
-- UIElement hands a child onMouseMove only while the cursor is within that child's
-- rect, and onMouseMoveOutside to every child it is not over (decompile
-- zombie/ui/UIElement.java:998-1003). A container button is a SQUARE of exactly
-- buttonSize on a side (ISButton:new(x, y, self.buttonSize, self.buttonSize),
-- ISInventoryPage.lua:1473). Arming lived only in onMouseMove while
-- onMouseMoveOutside returned early on `not coDragging`, so the mouse had to
-- travel more than half a button WITHOUT LEAVING a box one button high and one
-- button wide. In practice that meant all three of:
--
--   * press in the top half and drag DOWN, or the bottom half and drag UP - the
--     usable travel is size - py one way and py the other, so a press near the
--     middle had at most size/2 available and could never clear a size/2 test;
--   * hold the cursor inside the button's width, since leaving sideways cuts off
--     the events just as effectively as leaving vertically;
--   * and move SLOWLY, because the cursor is sampled once a frame and a flick
--     jumps from inside the rect to well outside in a single event - which was
--     delivered here, and dropped.
--
-- Forwarding unconditionally takes the rect out of the question: once the button
-- is pressed, travel is measured wherever the cursor goes. The gate that matters
-- is still `self.pressed and self.coCanDrag`, both set only by our own
-- onMouseDown on this button, so a button nobody pressed does nothing.
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

-- Vanilla addContainerButton lays the first button at ((1 - 1) * buttonSize) - 1,
-- so the top of the column is -1, NOT 0. apply() reproduces that origin and the
-- drag clamp is measured from it - see the clamp in onMouseMove for why the
-- difference of one pixel mattered.
local ORIGIN_Y  = -1

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
-- which is exactly what distinguishes it - a nil from getContainingItem IS the
-- character's inventory. Both calls are field returns in the 42.20.2 decompile
-- (ItemContainer.getContainingItem:356, InventoryItem.getID:3333), so neither
-- can throw on the nil-checked receivers here.
local function keyFor(container)
    if not container then return nil end
    local item = container:getContainingItem()
    if not item then return "main" end
    return "i" .. tostring(item:getID())
end

local function orderTable(playerObj, create)
    if not playerObj then return nil end
    -- lazy-alloc table return (IsoObject.getModData:1110), cannot throw
    local md = playerObj:getModData()
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
    -- IsoObject.transmitModData:4470 null-checks the square and the packet send
    -- is try/catch'd throughout (INetworkPacket.send:127) - cannot throw
    playerObj:transmitModData()
end

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------

-- Put the array back the way vanilla left it, so refreshBackpacks fills its button
-- pool in the same order it drains it. See the header: this is what keeps a pooled
-- button bound to the container it already held, and therefore what keeps vanilla's
-- double click dispatch honest.
--
-- Unconditional on purpose. When apply() has not sorted anything the array is
-- already in engine order and this is a no-op, and running it anyway is what
-- unwinds a stale sort left behind if the kill switch is turned off mid-session.
--
-- coEngineIndex is stamped by the addContainerButton wrapper. The `or i` fallback
-- only matters for buttons that predate install() - it keeps the comparator a
-- consistent ordering (every button has one fixed number) rather than being
-- correct, and the next refresh stamps everything and heals it.
function ContainerOrder.restoreEngineOrder(page)
    if type(page.backpacks) ~= "table" or #page.backpacks < 2 then return end
    local pos = {}
    for i, b in ipairs(page.backpacks) do pos[b] = b.coEngineIndex or i end
    table.sort(page.backpacks, function(a, b) return pos[a] < pos[b] end)
end

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
        b:setY(((i - 1) * size) + ORIGIN_Y)
    end

    -- Vanilla set this before we moved anything; the bottom button changed.
    -- guarded: setScrollHeight/getBottom are vanilla ISUI Lua, unverifiable
    -- against the Java decompile; a miss just leaves vanilla's scroll height.
    if page.containerButtonPanel and page.backpacks[#page.backpacks] then
        pcall(function()
            page.containerButtonPanel:setScrollHeight(page.backpacks[#page.backpacks]:getBottom())
        end)
    end
end

-- Where a drop would land if the dragged button sat at pixel `y`: the count of
-- visible buttons whose midpoint is at or above that midpoint. 0 means "above
-- everything". Parameterised on y rather than reading dragged:getY() so
-- finishDrag can ask the same question of the position the drag STARTED from
-- and compare the two - see there.
local function dropIndexAt(page, dragged, y)
    local mid = y + dragged:getHeight() / 2
    local n = 0
    for _, b in ipairs(page.backpacks) do
        if b ~= dragged and b:getIsVisible()
            and (b:getY() + b:getHeight() / 2) <= mid then
            n = n + 1
        end
    end
    return n
end

function ContainerOrder.insertPosition(page, dragged)
    return dropIndexAt(page, dragged, dragged:getY())
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
    --
    -- Half a button, not size/6. Buttons are a full `size` apart, so the dragged
    -- midpoint cannot cross a neighbour's midpoint - the only thing that changes
    -- the order - until the mouse has travelled a whole `size`. A threshold of
    -- size/6 armed the drag six times sooner than any reorder was reachable, so
    -- every click with a few pixels of drift lifted the icon off its slot and
    -- then put it straight back.
    --
    -- The size is only half the story: this test also has to be REACHED, which is
    -- why onMouseMoveOutside forwards here unconditionally. A button is size x size,
    -- so a threshold of size/2 is not clearable inside the button's own rect from an
    -- arbitrary press point - see the header.
    if math.abs((self.coDragStartMouseY or 0) - getMouseY()) > size / 2 then
        self.coDragging = true
    end
    if not self.coDragging then return end

    local panel = self:getParent()
    local newY = getMouseY() - panel:getAbsoluteY() - self:getHeight() / 2
    -- Clamp from the layout origin, not from 0. The top button sits at ORIGIN_Y
    -- (-1), so a floor of 0 left the dragged button permanently one pixel BELOW
    -- it and its midpoint could never win the comparison in dropIndexAt: no
    -- container could be placed above the character's own inventory, however far
    -- up you dragged. Half a button above the origin is enough to take slot 0
    -- and never puts more than half the icon past the top edge.
    self:setY(math.max(ORIGIN_Y - size / 2, newY))
    self:bringToTop()

    page.coDragButton = self
    page.coDropIndex = ContainerOrder.insertPosition(page, self)
end

-- Forwarded UNCONDITIONALLY, not just once a drag is already armed: this is where
-- most real gestures cross the threshold, because the cursor leaves a 32px square
-- long before it has travelled half a button. See ARMING MUST NOT DEPEND ON THE
-- CURSOR STAYING INSIDE THE BUTTON in the header - that early return was the whole
-- reason a reorder took ten attempts. onMouseMove's own `self.pressed and
-- self.coCanDrag` gate is what keeps this cheap and safe for every other button,
-- and UIElement really does call this on all of them (UIElement.java:1024-1028).
local function onMouseMoveOutside(self, dx, dy)
    if self.coOutOrig then self.coOutOrig(self, dx, dy) end
    onMouseMove(self, dx, dy, true)
    if not self.coDragging then return end
    -- Released off the panel: the button never gets a real onMouseUp, so finish
    -- here or it stays stuck to the cursor.
    if not isMouseButtonDown(0) then
        self.pressed = false
        ContainerOrder.finishDrag(self)
    end
end

-- The release itself, when it lands outside the button's own rectangle.
-- UIElement.onMouseUp hands a child onMouseUpOutside whenever the release point
-- misses its rect (decompile zombie/ui/UIElement.java:1048), and for a drag that
-- ends without any further cursor movement that is the ONLY event it will get:
-- the isMouseButtonDown poll in onMouseMoveOutside needs a move event to run, and
-- the engine only sends those when the cursor actually moved. Drag a button up
-- past the top clamp or sideways off the 32px panel and let go without twitching,
-- and before this the reorder was silently discarded while page.coDragButton
-- stayed set and the drop indicator drew forever.
--
-- finishDrag clears coDragging as its first act, so this and the poll above can
-- never both commit the same drag.
local function onMouseUpOutside(self, x, y)
    if self.coUpOutOrig then self.coUpOutOrig(self, x, y) end
    if not self.coDragging then return end
    ContainerOrder.finishDrag(self)
end

local function onMouseUp(self, x, y)
    if self.coDragging and ContainerOrder.finishDrag(self) then
        -- A real reorder consumes the click: refreshBackpacks has already rebuilt
        -- the column and the player did not ask to change container.
        self.pressed = false
        return
    end
    -- Either never a drag, or a drag that resolved to the slot it started in.
    -- Either way it was a click, so let vanilla select the container.
    --
    -- Falling through here is the fix for the reported bug. Arming a drag and
    -- committing one used to be two different tests - `> size/6` to arm,
    -- `> size/2` to commit - and this branch returned unconditionally as soon as
    -- coDragging was set. Every gesture between the two thresholds therefore
    -- reordered nothing AND swallowed the selection: the icon lifted and dropped
    -- back while the pane went on showing whichever container was already open,
    -- so clicking a bag left you looking at a different bag. self.pressed is
    -- deliberately left alone on this path - vanilla's onBackpackMouseUp bails
    -- out early on `not self.pressed` and would eat the click all over again.
    if self.coUpOrig then return self.coUpOrig(self, x, y) end
end

-- Returns true if the drop actually resequenced the column, false if it was a
-- click in disguise and the button has been put back. Callers use that to decide
-- whether the click still needs handling.
function ContainerOrder.finishDrag(button)
    local page = pageOf(button)
    button.coDragging = false
    if not page then return false end

    page.coDragButton = nil
    page.coDropIndex  = nil

    -- Does this drop land anywhere other than where it started? That is the only
    -- honest test of "was this a reorder", and it is the same question the drop
    -- indicator answered on screen, so what the player was shown is what they
    -- get. The old test - "did the button move more than half a slot" - measured
    -- pixels instead of slots and disagreed with both.
    local startY = button.coDragStartY
    if startY and dropIndexAt(page, button, button:getY())
               == dropIndexAt(page, button, startY) then
        button:setY(startY)
        return false
    end

    ContainerOrder.commit(page)
    -- guarded: refreshBackpacks is vanilla (or a third-party override) Lua;
    -- a throw here would leave the drag half-committed with no rebuild.
    if page.refreshBackpacks then pcall(function() page:refreshBackpacks() end) end
    return true
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
    button.coDownOrig  = button.onMouseDown
    button.coMoveOrig  = button.onMouseMove
    button.coOutOrig   = button.onMouseMoveOutside
    button.coUpOutOrig = button.onMouseUpOutside
    button.onMouseDown        = onMouseDown
    button.onMouseMove        = onMouseMove
    button.onMouseMoveOutside = onMouseMoveOutside
    button.onMouseUpOutside   = onMouseUpOutside
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
        -- origAdd has just appended this button (:1507), so the count IS its engine
        -- enumeration index. Stamped on every page, not just ours: it costs one
        -- field and it is the only record of the order vanilla handed us.
        if button then button.coEngineIndex = #self.backpacks end
        if button and self.onCharacter and ContainerOrder.isEnabled() then
            -- attach is pure Lua field reads/writes on the button table; it
            -- cannot throw, so it runs unguarded.
            attach(button)
        end
        return button
    end

    local origRefresh = ISInventoryPage.refreshBackpacks
    function ISInventoryPage:refreshBackpacks(...)
        -- Engine order going in, player order coming out. Both halves matter - see
        -- the header on vanilla's double dispatch. restoreEngineOrder is pure Lua
        -- table work and cannot throw; apply stays guarded because it reaches
        -- vanilla ISUI Lua (setY, scroll height) and a throw inside this wrapper
        -- would take refreshBackpacks down for every mod.
        ContainerOrder.restoreEngineOrder(self)
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
                -- drawRect is (x, y, w, h, A, R, G, B) - ISUIElement.lua:1191, and
                -- the alpha leads. Passed as (r, g, b, a) this drew pale blue at
                -- 0.9 alpha instead of solid pink.
                -- guarded: vanilla ISUI Lua on the per-frame render path - a
                -- throw here would error the panel render every frame.
                pcall(function()
                    self:drawRect(1, y, self:getWidth() - 2, 2, 1.0, 0.9, 0.55, 0.75)
                end)
            end
            return r
        end
    end
end

install()
Events.OnGameStart.Add(install)

return ContainerOrder

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
