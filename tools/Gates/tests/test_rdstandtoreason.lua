-- test_rdstandtoreason.lua - dedicated-server furniture-state repair fixture.
--
-- The mock preserves the three exact engine contracts the compatibility guard
-- relies on: the current main state, the live furniture object's world index,
-- and the position received by the server. abortSitting is modeled as vanilla's
-- complete cleanup rather than as a single boolean write.

local ROOT = arg[1] or "."
local SRC = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/server/RDStandToReason.lua"

local realPrint = print
local pass, fail = 0, 0
local function eq(name, got, want)
    if got == want then pass = pass + 1
    else
        fail = fail + 1
        realPrint("FAIL " .. name)
        realPrint("  got:  " .. tostring(got))
        realPrint("  want: " .. tostring(want))
    end
end

function isServer() return true end

local clockMs = 1000
RDShared = { nowMs = function() return clockMs end }

local sitState = {}
local getUpState = {}
local idleState = {}
local abortCalls = 0
function sitState:abortSitting(player)
    abortCalls = abortCalls + 1
    if player._furniture then player._furniture._sat = false end
    player._sitting = false
    player._furniture = nil
    player._direction = nil
end
PlayerSitOnFurnitureState = { instance = function() return sitState end }
PlayerGetUpState = { instance = function() return getUpState end }

local handlers = {}
local function event(name)
    return { Add = function(fn) handlers[name] = fn end }
end
Events = {
    OnTick = event("OnTick"),
    OnDisconnect = event("OnDisconnect"),
    OnPlayerDisconnect = event("OnPlayerDisconnect"),
}

local notices = {}
print = function(message) notices[#notices + 1] = tostring(message) end

local function furniture(index)
    return {
        _index = index == nil and 0 or index,
        _sat = true,
        getObjectIndex = function(self) return self._index end,
    }
end

local function player(id, state)
    local self = {
        _id = id, _state = state or idleState, _dead = false,
        _sitting = false, _furniture = nil, _direction = "N",
        _x = 0, _y = 0, _z = 0,
    }
    function self:getOnlineID() return self._id end
    function self:getCurrentState() return self._state end
    function self:isCurrentState(want) return self._state == want end
    function self:isDead() return self._dead end
    function self:isSittingOnFurniture() return self._sitting end
    function self:getSitOnFurnitureObject() return self._furniture end
    function self:getX() return self._x end
    function self:getY() return self._y end
    function self:getZ() return self._z end
    function self:sit(state)
        self._state = state or sitState
        self._sitting = true
        self._furniture = furniture()
    end
    return self
end

local online = {}
function getOnlinePlayers()
    return {
        size = function() return #online end,
        get = function(_, i) return online[i + 1] end,
    }
end

local ok, err = pcall(dofile, SRC)
if not ok then
    realPrint("FATAL: could not load " .. SRC)
    realPrint("  " .. tostring(err))
    os.exit(2)
end

local tick = handlers.OnTick
eq("registers the dedicated-server tick guard", type(tick), "function")

local ordinary = player(1, idleState)
online = { ordinary }
tick()
eq("ordinary standing player is untouched", abortCalls, 0)

local seated = player(2, sitState)
seated:sit()
online = { seated }
tick() -- establishes the authoritative seated anchor
eq("legitimate furniture state is untouched", abortCalls, 0)

seated._x, seated._y = 0.4, 0.39
tick()
eq("movement inside vanilla's 0.8 tolerance is untouched", abortCalls, 0)

seated._x = 0.42
tick()
eq("movement beyond vanilla's tolerance is repaired", abortCalls, 1)
eq("repair clears the endurance-driving flag", seated._sitting, false)
eq("repair clears the furniture reference", seated._furniture, nil)

local mismatch = player(3, idleState)
mismatch:sit(idleState)
online = { mismatch }
tick()
eq("pending sit entry gets its state transition grace", abortCalls, 1)
clockMs = clockMs + 1999
tick()
eq("state transition remains untouched inside the grace", abortCalls, 1)
clockMs = clockMs + 1
tick()
eq("flag outside sit/get-up state is repaired", abortCalls, 2)

-- StatePacket sets the flag before the queued sit state lands. If that state
-- arrives during the grace, its final network position becomes the anchor.
local entering = player(11, idleState)
entering:sit(idleState)
online = { entering }
tick()
entering._x, entering._y = 20, 20
entering._state = sitState
tick()
eq("legitimate queued sit entry is not repaired", abortCalls, 2)
entering._x = 20.79
tick()
eq("settled entry uses its final position as anchor", abortCalls, 2)

local removed = player(4, sitState)
removed:sit()
removed._furniture._index = -1
online = { removed }
tick()
eq("removed chair residue is repaired", abortCalls, 3)

local gettingUp = player(5, getUpState)
gettingUp:sit(getUpState)
online = { gettingUp }
tick()
eq("normal get-up transition keeps its flag", abortCalls, 3)

local dead = player(6, idleState)
dead:sit(idleState)
dead._dead = true
online = { dead }
tick()
eq("dead player is ignored", abortCalls, 3)

local loading = player(7, nil)
loading:sit(sitState)
loading._state = nil
online = { loading }
tick()
eq("player without a current state is ignored", abortCalls, 3)

-- Standing normally must clear the anchor. Sitting later at a distant chair is
-- a fresh session, not movement away from the old chair.
local resat = player(10, sitState)
resat:sit()
online = { resat }
tick() -- establish an anchor that has not gone through repair
resat._state, resat._sitting = idleState, false
tick()
resat._x, resat._y = 50, 50
resat:sit()
tick()
eq("a later legitimate sit gets a fresh anchor", abortCalls, 3)

-- Reuse of an onlineID must not inherit an old character object's anchor.
local oldBody = player(8, sitState)
oldBody:sit()
online = { oldBody }
tick()
local newBody = player(8, sitState)
newBody:sit()
newBody._x, newBody._y = 100, 100
online = { newBody }
tick()
eq("onlineID reuse gets a fresh anchor", abortCalls, 3)

eq("first repair emits one bounded notice", #notices, 1)
eq("repair counter includes suppressed notices", RDStandToReason.getRepairCount(), 3)
clockMs = clockMs + 60 * 1000
local later = player(9, idleState)
later:sit(idleState)
online = { later }
tick()
clockMs = clockMs + 2 * 1000
tick()
eq("a later repair emits the aggregate notice", #notices, 2)
eq("repair counter remains monotonic", RDStandToReason.getRepairCount(), 4)

print = realPrint
realPrint(string.format("RDStandToReason: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
