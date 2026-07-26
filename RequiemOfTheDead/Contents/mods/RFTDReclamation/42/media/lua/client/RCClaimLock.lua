-- RCClaimLock - the enforcement safety net (client).
--
-- Wraps isValid() on the vehicle timed-actions so a player is denied the
-- specific thing they lack permission for, even on NON-menu paths the menu
-- suppression can't catch (press-E world prompt, keybinds, other mods' queued
-- actions). Menu suppression (RCClaimMenu) hides everything from a no-access
-- player; this backstop enforces the per-PERMISSION grant for partial-access
-- players too. Both route through RCClaim.
--
-- Action -> permission map (see RCClaim):
--   enter / seat-swap  -> driver if the seat is the driver seat (index 0), else passenger
--   mechanics UI       -> mechanic
--   siphon fuel        -> inventory
--   attach trailer/tow -> driver (it moves the vehicle); checks BOTH vehicles
--   open/unlock door   -> any access (benign; the real action is gated downstream)
--   smash window       -> owner/admin only (no whitelist tier grants a break-in)
--
-- Field names verified against vanilla (DESIGN Engine facts). Wrapping isValid
-- (vs start) means the action never even begins.

if isServer() and not isClient() then return end

local function deny(character)
    RCShared.halo(character, getText("IGUI_RC_NoPermission"), true)
end

local function uname(character)
    return tostring(character and character.getUsername and character:getUsername())
end

-- Wrap one action class. getVehicle(self) reads the target vehicle;
-- gate(self, vehicle) returns whether the actor is allowed. `name` tags the
-- debug trace so we can see WHICH gate fired and on what claim state.
local function wrap(klass, name, getVehicle, gate)
    if not klass then return end
    local orig = klass.isValid
    klass.isValid = function(self)
        local v = getVehicle(self)
        if v and not gate(self, v) then
            RCShared.trace("gate:" .. name, "DENY %s me=%s | %s", name, uname(self.character), RCClaim.describe(v))
            deny(self.character)
            return false
        end
        if orig then return orig(self) end
        return true
    end
end

local function permGate(perm)
    return function(self, v) return RCClaim.canDo(v, self.character, perm) end
end
local function anyGate(self, v)   return RCClaim.canInteract(v, self.character) end
local function smashGate(self, v) return RCClaim.isOwnerOrAdmin(v, self.character) end

-- enter / seat-swap: driver seat (index 0) needs "driver", else "passenger".
-- Trace the seat + resolved perm so a mis-read seat is visible in the log.
local function enterGate(self, v)
    local perm = RCClaim.isDriverSeat(self.seat) and "driver" or "passenger"
    local ok = RCClaim.canDo(v, self.character, perm)
    RCShared.trace("enterGate", "enter seat=%s -> perm=%s canDo=%s me=%s",
        tostring(self.seat), perm, tostring(ok), uname(self.character))
    return ok
end
local function swapGate(self, v)
    local perm = RCClaim.isDriverSeat(self.seatTo) and "driver" or "passenger"
    local ok = RCClaim.canDo(v, self.character, perm)
    RCShared.trace("swapGate", "seatswap seatTo=%s -> perm=%s canDo=%s me=%s",
        tostring(self.seatTo), perm, tostring(ok), uname(self.character))
    return ok
end

wrap(ISEnterVehicle,            "enter",     function(s) return s.vehicle end, enterGate)
wrap(ISOpenVehicleDoor,         "door",      function(s) return s.vehicle end, anyGate)
-- onOpenDoor queues unlock THEN open; gate the unlock too or a non-owner could
-- unlock a claimed door via the press-E path.
wrap(ISUnlockVehicleDoor,       "unlock",    function(s) return s.vehicle end, anyGate)
wrap(ISOpenMechanicsUIAction,   "mechanic",  function(s) return s.vehicle end, permGate("mechanic"))
wrap(ISTakeGasolineFromVehicle, "siphon",    function(s) return s.vehicle end, permGate("inventory"))
-- seat-swap stores no vehicle field - read it fresh from the character
wrap(ISSwitchVehicleSeat,       "seatswap",  function(s) return s.character and s.character:getVehicle() end, swapGate)
-- smash stores the PART (nil for building windows -> getVehicle nil -> not gated)
wrap(ISSmashWindow,             "smash",     function(s) return s.vehiclePart and s.vehiclePart:getVehicle() end, smashGate)

-- Trailer attach touches TWO vehicles; both need "driver".
if ISAttachTrailerToVehicle then
    local orig = ISAttachTrailerToVehicle.isValid
    ISAttachTrailerToVehicle.isValid = function(self)
        local a, b = self.vehicleA, self.vehicleB
        if (a and not RCClaim.canDo(a, self.character, "driver"))
        or (b and not RCClaim.canDo(b, self.character, "driver")) then
            deny(self.character)
            return false
        end
        if orig then return orig(self) end
        return true
    end
end
