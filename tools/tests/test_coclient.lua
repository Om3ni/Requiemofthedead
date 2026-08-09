-- test_coclient.lua - behavioural tests for Container Order under real Lua 5.1.
--
-- WHAT THIS PINS, and why it exists at all. Reported 2026-08-07 by two players on
-- the live server: reordering the container buttons was "only visual - clicking on
-- the fanny pack brings up the hiking bag's inventory, and it depends solely on
-- which was equipped first". Dropping an item onto a button went to the right
-- container, which is what made it look like a rendering fault rather than a
-- binding one.
--
-- It was neither. Vanilla dispatches a container-button click TWICE:
-- onBackpackMouseUp calls ISButton.onMouseUp, whose onclick reaches selectContainer,
-- and selectContainer ENDS BY CALLING refreshBackpacks (ISInventoryPage.lua:1119);
-- control then returns and onBackpackMouseUp calls onBackpackClick again (:1365) on
-- the button object it captured before that refresh. Vanilla survives its own
-- double dispatch only because refreshBackpacks rebinds each pooled button to the
-- container it already held - the pool is FILLED by walking self.backpacks (:1542)
-- and DRAINED front-first (:1468) while containers are walked in engine order
-- (:1562), so while self.backpacks is in engine order the rebinding is the identity
-- map. Container Order sorted that array into the player's order and left it
-- sorted, which turned the map into "visual slot k -> engine container k".
--
-- So the property under test is not "the icons are in the right order" - that part
-- always worked and is what made the bug so confusing. It is:
--
--   (1) a refresh must not change what any surviving button is bound to, and
--   (2) a click must still be on the same container after the refresh vanilla
--       performs in the middle of it.
--
-- That means this file has to model vanilla's POOL, not just call the mod. A test
-- that stubbed refreshBackpacks as "rebuild the buttons" would have passed against
-- the broken code, which is precisely how this shipped. The model below reproduces
-- the fill/drain asymmetry and nothing else.
--
-- Usage (normally via tools\run-tests.bat):
--   lua5.1.exe tools/tests/test_coclient.lua <repo-root>

local ROOT = arg[1] or "."
local SRC  = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDOddsAndEnds"
             .. "/42/media/lua/client/ContainerOrder/COClient.lua"

local pass, fail = 0, 0
local function eq(name, got, want)
    if got == want then pass = pass + 1
    else
        fail = fail + 1
        print("FAIL " .. name)
        print("  got:  " .. tostring(got))
        print("  want: " .. tostring(want))
    end
end
local function ok(name, cond, detail)
    if cond then pass = pass + 1
    else
        fail = fail + 1
        print("FAIL " .. name)
        if detail then print("  " .. tostring(detail)) end
    end
end

-- ---------------------------------------------------------------------------
-- Engine stubs
-- ---------------------------------------------------------------------------

require   = function() end
isServer  = function() return false end
OEShared  = { enabled = function() return true end }
Events    = { OnGameStart = { Add = function() end } }

local mouseY, mouseDown = 0, false
getMouseY         = function() return mouseY end
isMouseButtonDown = function() return mouseDown end

local playerModData = {}
local transmits     = 0
local playerObj = {
    getModData      = function() return playerModData end,
    transmitModData = function() transmits = transmits + 1 end,
}
getSpecificPlayer = function() return playerObj end

-- ---------------------------------------------------------------------------
-- Vanilla model
--
-- Only the parts the bug lives in. Faithful where it matters: y comes from the
-- creation index and the origin is -1 (:1466), the pool is filled from
-- self.backpacks and drained from the front, and every button property is rebound
-- from the container on every add (:1486-1505) - that last point is why the icon
-- and the inventory can never disagree ON A GIVEN BUTTON, and therefore why the
-- reported symptom had to be a binding change rather than a drawing one.
-- ---------------------------------------------------------------------------

local panel = { children = {} }
function panel:removeChild() end
function panel:addChild() end
function panel:setScrollHeight(h) self.scrollHeight = h end
function panel:getWidth() return 32 end
function panel:getAbsoluteY() return 0 end
function panel:drawRect() end

-- Square, exactly buttonSize on a side: ISButton:new(x, y, self.buttonSize,
-- self.buttonSize) at ISInventoryPage.lua:1473. The squareness is load-bearing for
-- the arming tests below, not incidental.
--
-- onMouseDown is modelled because ISButton's sets self.pressed (ISButton.lua:55-64)
-- and the drag machinery is gated on it. Leaving it out is what let the arming path
-- go untested: every drag test below this point used to begin by setting coDragging
-- by hand, which is the one thing a player cannot do.
local function newButton(size)
    local b = { y = 0, height = size, width = size, visible = true }
    function b:setY(v)      self.y = v end
    function b:getY()       return self.y end
    function b:getHeight()  return self.height end
    function b:getWidth()   return self.width end
    function b:getBottom()  return self.y + self.height end
    function b:getIsVisible() return self.visible end
    function b:bringToTop() end
    function b:getParent()  return panel end
    function b:onMouseDown(x, y) self.pressed = true end
    return b
end

ISInventoryPage = {}
ISInventoryPage.__index = ISInventoryPage

function ISInventoryPage:addContainerButton(container, texture, name, tooltip)
    local c = #self.backpacks + 1
    local y = ((c - 1) * self.buttonSize) - 1
    local button
    if #self.buttonPool > 0 then
        button = table.remove(self.buttonPool, 1)
    else
        button = newButton(self.buttonSize)
    end
    button:setY(y)
    button.inventory = container
    button.name      = name
    self.backpacks[c] = button
    return button
end

function ISInventoryPage:refreshBackpacks()
    for i, v in ipairs(self.backpacks) do
        table.insert(self.buttonPool, i, v)
    end
    for i = #self.backpacks, 1, -1 do self.backpacks[i] = nil end
    for _, cont in ipairs(self.engineOrder) do
        self:addContainerButton(cont, nil, cont.name, cont.name)
    end
end

ISInventoryPageContainerButtonPanel = {}
function ISInventoryPageContainerButtonPanel:render() end

-- ---------------------------------------------------------------------------

local ContainerOrder = dofile(SRC)
ok("COClient loads and returns its table", type(ContainerOrder) == "table")

-- Containers. The player's own inventory is the one with NO containing item,
-- which is what keyFor() keys as "main"; a bag keys as "i" .. item id.
local function mkContainer(name, id)
    local c = { name = name }
    if id then
        local item = { getID = function() return id end }
        c.getContainingItem = function() return item end
    else
        c.getContainingItem = function() return nil end
    end
    return c
end

local main   = mkContainer("main")
local fanny  = mkContainer("fanny",  2)
local hiking = mkContainer("hiking", 3)

local function newPage(engineOrder)
    local p = setmetatable({}, ISInventoryPage)
    p.backpacks   = {}
    p.buttonPool  = {}
    p.buttonSize  = 32
    p.onCharacter = true
    p.player      = 0
    p.engineOrder = engineOrder
    p.containerButtonPanel = panel
    panel.parent  = p
    return p
end

-- Vanilla's click, both dispatches. selectContainer sets the pane from
-- button.inventory and then refreshes (:1103-1119); onBackpackMouseUp then calls
-- onBackpackClick a second time with the same button (:1365). dropItemsInContainer
-- returns false on a plain click (:992) so it is not modelled.
local function selectContainer(page, button)
    page.pane = button.inventory
    page:refreshBackpacks()
end
local function clickButton(page, button)
    selectContainer(page, button)
    selectContainer(page, button)
end

-- The column as the player sees it, top to bottom.
local function visualOrder(page)
    local sorted = {}
    for _, b in ipairs(page.backpacks) do sorted[#sorted + 1] = b end
    table.sort(sorted, function(a, b) return a:getY() < b:getY() end)
    local names = {}
    for i, b in ipairs(sorted) do names[i] = b.name end
    return sorted, table.concat(names, ",")
end

-- ---------------------------------------------------------------------------
-- The dormant guard: with no saved order, nothing is touched at all
-- ---------------------------------------------------------------------------

playerModData = {}
local page = newPage({ main, fanny, hiking })
page:refreshBackpacks()
local _, order = visualOrder(page)
eq("no saved order leaves engine order alone", order, "main,fanny,hiking")

-- ---------------------------------------------------------------------------
-- The reported bug
--
-- Equip order main, fanny, hiking. The player drags the column into main, hiking,
-- fanny and clicks the fanny pack - the LAST icon, which under the bug is bound to
-- the container equip order puts third, the hiking bag.
-- ---------------------------------------------------------------------------

playerModData = { RDContainerOrder = { main = 10, i3 = 20, i2 = 30 } }
page = newPage({ main, fanny, hiking })
page:refreshBackpacks()

local buttons
buttons, order = visualOrder(page)
eq("saved order is imposed on the column", order, "main,hiking,fanny")

-- Pin the identity map directly - this is the invariant vanilla depends on and
-- the one the bug broke. Nothing about the container set has changed, so no
-- surviving button may come back bound to a different container.
local before = {}
for _, b in ipairs(page.backpacks) do before[b] = b.inventory end
page:refreshBackpacks()
local rebound = 0
for _, b in ipairs(page.backpacks) do
    if before[b] and before[b] ~= b.inventory then rebound = rebound + 1 end
end
eq("a refresh rebinds no surviving button", rebound, 0)

buttons, order = visualOrder(page)
eq("and the column is unchanged by it", order, "main,hiking,fanny")

-- Now the click itself, through vanilla's double dispatch.
local fannyButton = buttons[3]
eq("the third icon is the fanny pack", fannyButton.name, "fanny")
clickButton(page, fannyButton)
eq("clicking the fanny pack opens the fanny pack", page.pane, fanny)

buttons, order = visualOrder(page)
eq("the column survives the click", order, "main,hiking,fanny")

local hikingButton = buttons[2]
eq("the second icon is the hiking bag", hikingButton.name, "hiking")
clickButton(page, hikingButton)
eq("clicking the hiking bag opens the hiking bag", page.pane, hiking)

clickButton(page, buttons[1])
eq("clicking the top icon opens the player's own inventory", page.pane, main)

-- Every slot, repeatedly: the binding must not drift as refreshes accumulate.
local drift = 0
for _ = 1, 5 do
    local bs = visualOrder(page)
    for _, b in ipairs(bs) do
        local want = b.inventory
        clickButton(page, b)
        if page.pane ~= want then drift = drift + 1 end
    end
end
eq("no drift over 15 clicks", drift, 0)

-- ---------------------------------------------------------------------------
-- An order that is NOT a rotation
--
-- A single swap can be its own inverse, so a wrong map can still look right.
-- Reverse the column instead, where slot k and engine index k differ everywhere.
-- ---------------------------------------------------------------------------

playerModData = { RDContainerOrder = { main = 30, i2 = 20, i3 = 10 } }
page = newPage({ main, fanny, hiking })
page:refreshBackpacks()
buttons, order = visualOrder(page)
eq("a reversed column is imposed", order, "hiking,fanny,main")

local mismatches = 0
for i = 1, 3 do
    local bs = visualOrder(page)
    local want = bs[i].inventory
    clickButton(page, bs[i])
    if page.pane ~= want then mismatches = mismatches + 1 end
end
eq("every slot of a reversed column opens its own container", mismatches, 0)

-- ---------------------------------------------------------------------------
-- A drag released outside the button, without moving afterwards
--
-- UIElement.onMouseUp hands a child onMouseUpOutside when the release point misses
-- its rect (decompile zombie/ui/UIElement.java:1048). That is the only event such
-- a drag gets: the isMouseButtonDown poll in onMouseMoveOutside needs a move event,
-- and the engine only sends those when the cursor actually moved. Before this was
-- hooked, the reorder was discarded and the drop indicator drew forever.
-- ---------------------------------------------------------------------------

playerModData = { RDContainerOrder = { main = 10, i2 = 20, i3 = 30 } }
page = newPage({ main, fanny, hiking })
page:refreshBackpacks()
buttons = visualOrder(page)

ok("the drag handlers are installed on the buttons",
   type(buttons[1].onMouseUpOutside) == "function")

-- Drag the bottom button to the top and let go off the panel.
local dragged = buttons[3]
dragged.coDragging     = true
dragged.coDragStartY   = dragged:getY()
page.coDragButton      = dragged
page.coDropIndex       = 0
dragged:setY(-17)
transmits = 0
dragged:onMouseUpOutside(0, 0)

eq("the drag is finished, not left armed", page.coDragButton, nil)
eq("and the drop indicator is cleared",    page.coDropIndex,  nil)
eq("the button is no longer dragging",     dragged.coDragging, false)
ok("the reorder was committed rather than discarded", transmits > 0)

buttons, order = visualOrder(page)
eq("the dragged bag really moved to the top", order, "hiking,main,fanny")

-- A drag that ends where it began is a click, not a reorder: it must put the
-- button back and commit nothing.
buttons = visualOrder(page)
local stayer = buttons[2]
stayer.coDragging   = true
stayer.coDragStartY = stayer:getY()
page.coDragButton   = stayer
transmits = 0
stayer:onMouseUpOutside(0, 0)
eq("a drag that did not move commits nothing", transmits, 0)
eq("and is put back where it started",         stayer:getY(), stayer.coDragStartY)
eq("and still clears the indicator",           page.coDragButton, nil)

-- ---------------------------------------------------------------------------
-- ARMING - the part no test above this line touches
--
-- Reported 2026-08-08: making a bag move took "a good 10 tries". Every drag test
-- above begins by setting coDragging = true, so all of them passed against a build
-- in which a player could barely arm a drag at all.
--
-- The threshold is buttonSize/2 and it was only ever tested inside onMouseMove,
-- which UIElement delivers ONLY while the cursor is within the button's rect
-- (UIElement.java:998-1003); everything else goes to onMouseMoveOutside, which
-- returned early unless a drag was already armed. A button is 32x32 and the
-- threshold is 16, so from a press at local offset py the usable in-rect travel is
-- 32 - py downward and py upward - meaning a press at the centre had exactly 16 in
-- either direction and could never clear a strict `> 16`. These tests drive the
-- real handlers from onMouseDown and never touch coDragging.
-- ---------------------------------------------------------------------------

local function freshPage()
    playerModData = { RDContainerOrder = { main = 10, i2 = 20, i3 = 30 } }
    local p = newPage({ main, fanny, hiking })
    p:refreshBackpacks()
    return p, (visualOrder(p))
end

-- A press dead centre, dragged straight down. The cursor leaves the 32px rect
-- after 16px, so this gesture NEVER reaches onMouseMove again - the whole gesture
-- is delivered to onMouseMoveOutside. This is the case the owner kept hitting.
page = select(1, freshPage())
buttons = visualOrder(page)
local b = buttons[1]
mouseY, mouseDown = 100, true
b:onMouseDown(0, 16)
ok("the press registered as draggable", b.coCanDrag == true)
eq("and is not armed yet",              b.coDragging, false)

mouseY = 140            -- 40px of travel, all of it outside the rect
b:onMouseMoveOutside(0, 40)
eq("a centre press dragged clear of the rect arms the drag", b.coDragging, true)

-- The same gesture as a single fast event: the cursor is sampled once a frame, so
-- a flick jumps from inside the rect to far outside in one step and that step is
-- an ...Outside event. Under the old code this could not arm at any speed.
page = select(1, freshPage())
buttons = visualOrder(page)
b = buttons[3]
mouseY, mouseDown = 200, true
b:onMouseDown(0, 16)
mouseY = 60             -- one 140px jump upward
b:onMouseMoveOutside(0, -140)
eq("a fast flick arms in a single event", b.coDragging, true)

-- Anti-flicker still holds: a click with a few pixels of drift must NOT arm,
-- whichever handler the drift is delivered to.
page = select(1, freshPage())
buttons = visualOrder(page)
b = buttons[2]
mouseY, mouseDown = 100, true
b:onMouseDown(0, 16)
mouseY = 104
b:onMouseMoveOutside(0, 4)
eq("4px of drift outside the rect does not arm", b.coDragging, false)
mouseY = 112            -- 12px: still under the 16px threshold
b:onMouseMove(0, 8)
eq("12px of drift inside the rect does not arm", b.coDragging, false)

-- And the in-rect path is untouched by the fix: a press at the top edge dragged
-- down still arms through onMouseMove, as it always did.
page = select(1, freshPage())
buttons = visualOrder(page)
b = buttons[1]
mouseY, mouseDown = 100, true
b:onMouseDown(0, 1)
mouseY = 120            -- 20px, still within a rect entered near its top
b:onMouseMove(0, 20)
eq("an edge press still arms through onMouseMove", b.coDragging, true)

-- A button nobody pressed must ignore the outside events entirely - UIElement
-- broadcasts onMouseMoveOutside to every child (UIElement.java:1024-1028), so the
-- unconditional forward has to be inert for all of them.
local bystander = buttons[3]
eq("the bystander was never pressed", bystander.pressed, nil)
mouseY = 400
bystander:onMouseMoveOutside(0, 280)
eq("an unpressed button never arms",  bystander.coDragging, nil)
eq("and is not moved",                bystander:getY(), 63)

-- End to end, driven only by real events: press, drag past both neighbours,
-- release. Coordinates are the real ones - the stub panel is at absolute Y 0 and
-- vanilla lays slot k at ((k - 1) * 32) - 1 (ISInventoryPage.lua:1466), so slot 3
-- spans 63..95 and its midpoint is 79.
page = select(1, freshPage())
buttons, order = visualOrder(page)
eq("starting column", order, "main,fanny,hiking")
b = buttons[3]
eq("slot 3 is where vanilla puts it", b:getY(), 63)
mouseY, mouseDown = 79, true
b:onMouseDown(0, 16)
mouseY = 10                         -- drag the bottom bag up above slot 1
b:onMouseMoveOutside(0, -69)
ok("the dragged button followed the cursor above slot 1", b:getY() < -1)
ok("the drag armed", b.coDragging == true)
ok("and the drop indicator has a slot", page.coDropIndex ~= nil)
transmits = 0
mouseDown = false
b:onMouseUpOutside(0, 0)
ok("the release committed an order", transmits > 0)
buttons, order = visualOrder(page)
eq("the bag ends up where it was dropped", order, "hiking,main,fanny")

print(string.format("ContainerOrder: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
