-- RDZombieFocus fixture - the white "this is the one you picked" outline, and
-- the lease that makes it let go.
--
-- WHY THIS EXISTS: the module's whole job is invisible except as a colour on a
-- body, and every property worth having is one a future edit could drop without
-- anything failing loudly. It has to yield-check cheaply (Dirge asks per special
-- per frame), it has to paint the INDEX-SCOPED overload (the untyped one writes
-- all four splitscreen player bits), it has to set the colour EXPLICITLY rather
-- than lean on IsoObject's -1 initialiser, and it has to release when the panel
-- stops renewing - which is the only reason closing the deck turns the outline
-- off at all.
--
-- STUBS MODEL THE VERIFIED SURFACE. setOutlineHighlight and
-- setOutlineHighlightCol are exposed instance methods, so their bodies cannot
-- raise into Lua (MethodCaller.java:33-56) - the fakes here are plain recorders
-- and never throw. Both real overloads exist (IsoObject.java:5140 untyped,
-- :5161 index-scoped), so the recorder captures the ARITY: that is how the
-- splitscreen property gets asserted instead of assumed.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/client/RDZombieFocus.lua"

local passed, failed = 0, 0
local realPrint = print
local function check(ok, message)
    if ok then passed = passed + 1
    else failed = failed + 1; realPrint("FAIL RDZombieFocus: " .. message) end
end

-- ---- engine stubs -------------------------------------------------------
function isServer() return false end

local renderTick, gameStart
Events = {
    OnRenderTick = { Add = function(fn) renderTick = fn end },
    OnGameStart  = { Add = function(fn) gameStart  = fn end },
}

local PLAYER_INDEX = 1   -- deliberately not 0: a bug that passes the raw
                         -- boolean through would still "work" at index 0.

local function newZombie(id)
    local z = { id = id, dead = false, calls = {}, cols = {} }
    function z:getOnlineID() return self.id end
    function z:isDead() return self.dead end
    -- Records arity, so "was the index-scoped overload used" is checkable.
    function z:setOutlineHighlight(a, b)
        self.calls[#self.calls + 1] = { a = a, b = b, argc = (b == nil) and 1 or 2 }
    end
    function z:setOutlineHighlightCol(idx, r, g, b, a)
        self.cols[#self.cols + 1] = { idx = idx, r = r, g = g, b = b, a = a }
    end
    return z
end

local loaded = {}   -- what the local cell currently holds

local cell = {}
function cell:getZombieList()
    local list = {}
    function list:size() return #loaded end
    function list:get(i) return loaded[i + 1] end   -- Java lists are 0-based
    return list
end

local player = {}
function player:getPlayerNum() return PLAYER_INDEX end
function player:getCell() return cell end

local havePlayer = true
function getPlayer() return havePlayer and player or nil end

-- ---- load ---------------------------------------------------------------
dofile(SOURCE)

check(type(RDZombieFocus) == "table", "module did not define RDZombieFocus")
check(type(renderTick) == "function", "no OnRenderTick listener registered")
check(type(gameStart) == "function",  "no OnGameStart listener registered")

local function lastCall(z) return z.calls[#z.calls] end
local function lastCol(z)  return z.cols[#z.cols] end

-- ---- claim semantics ----------------------------------------------------
RDZombieFocus.set(4242)
check(RDZombieFocus.id() == 4242, "set() did not record the id")
check(RDZombieFocus.isFocused(4242) == true, "isFocused false for the claimed id")
check(RDZombieFocus.isFocused(4243) == false, "isFocused true for an unclaimed id")

-- 0 is how the engine reports "no network id assigned" (it is the value
-- RQAdmin sends as `oid or 0`), so it must never name a zombie.
RDZombieFocus.set(0)
check(RDZombieFocus.id() == nil, "set(0) claimed a focus instead of releasing")
RDZombieFocus.set(7)
RDZombieFocus.set(nil)
check(RDZombieFocus.id() == nil, "set(nil) did not release")
RDZombieFocus.set(7)
RDZombieFocus.set("not a number")
check(RDZombieFocus.id() == nil, "a non-numeric id was accepted as a claim")

check(RDZombieFocus.isFocused(nil) == false, "isFocused(nil) matched an empty claim")

-- ---- painting -----------------------------------------------------------
local zA = newZombie(100)
local zB = newZombie(200)
loaded = { zA, zB }

RDZombieFocus.set(100)
renderTick()

local c = lastCall(zA)
check(c ~= nil and c.b == true, "focused zombie was not highlighted")
check(c ~= nil and c.argc == 2, "used the untyped setOutlineHighlight overload; "
    .. "IsoObject.java:5140 writes ALL four splitscreen player bits")
check(c ~= nil and c.a == PLAYER_INDEX, "highlighted for the wrong player index")

local col = lastCol(zA)
check(col ~= nil, "colour was never set - the white would be IsoObject's -1 "
    .. "initialiser by accident, which vanilla combat targeting overwrites")
check(col ~= nil and col.r == 1 and col.g == 1 and col.b == 1 and col.a == 1,
    "focus colour is not opaque white")
check(col ~= nil and col.idx == PLAYER_INDEX, "colour set for the wrong player index")
check(#zB.calls == 0, "an unfocused zombie was painted")

-- ---- moving the claim ---------------------------------------------------
RDZombieFocus.set(200)
local afterSwitch = lastCall(zA)
check(afterSwitch ~= nil and afterSwitch.b == false,
    "switching focus left the previous zombie lit")
renderTick()
check(lastCall(zB) ~= nil and lastCall(zB).b == true, "new focus was not painted")

-- ---- the lease ----------------------------------------------------------
-- Renewed every frame the way a visible panel renews it: the claim survives
-- indefinitely.
for _ = 1, 20 do
    RDZombieFocus.set(200)
    renderTick()
end
check(RDZombieFocus.id() == 200, "a continuously renewed claim expired")

-- Stop renewing - the panel closed, the deck was torn down, the tab switched.
-- Nothing is left to call clear(), so the lease is the only thing that can.
local drained = false
for _ = 1, 10 do
    renderTick()
    if RDZombieFocus.id() == nil then drained = true; break end
end
check(drained, "an unrenewed claim never expired - the outline would stay lit "
    .. "on that zombie for as long as it stayed loaded")
check(lastCall(zB) ~= nil and lastCall(zB).b == false,
    "the expired claim was released without turning the outline off")

-- ---- target leaves, target dies -----------------------------------------
-- Out of the loaded set is NOT gone: keep the claim, drop the paint.
loaded = {}
RDZombieFocus.set(100)
RDZombieFocus.set(100)
renderTick()
check(RDZombieFocus.id() == 100,
    "a zombie merely out of the loaded cell dropped the claim; walking back "
    .. "into range would not re-light it")

loaded = { zA }
RDZombieFocus.set(100)
renderTick()
check(lastCall(zA).b == true, "claim did not repaint once the target reloaded")

-- Dead IS gone. Release outright, so Dirge stops yielding its own outline to a
-- body nothing is painting.
zA.dead = true
RDZombieFocus.set(100)
renderTick()
check(RDZombieFocus.id() == nil, "a dead target kept the claim")
check(lastCall(zA).b == false, "a dead target was left lit")

-- ---- no player ----------------------------------------------------------
-- Loading screens and the moment after a disconnect. Must not throw.
zA.dead = false
loaded = { zA }
RDZombieFocus.set(100)
havePlayer = false
local ok = pcall(renderTick)
check(ok, "render tick threw with no local player")
havePlayer = true

-- ---- session boundary ---------------------------------------------------
RDZombieFocus.set(100)
gameStart()
check(RDZombieFocus.id() == nil,
    "a claim survived OnGameStart; next session it would paint whatever zombie "
    .. "the server hands that id to")

realPrint(string.format("RDZombieFocus: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
