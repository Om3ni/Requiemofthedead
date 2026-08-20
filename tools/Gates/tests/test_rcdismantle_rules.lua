-- test_rcdismantle_rules.lua - shared client/server dismantle prerequisites.

local ROOT = arg[1] or "."
local TARGET = ROOT
    .. "/RequiemOfTheDead/Contents/mods/RFTDReclamation/42/media/lua/shared/RCDismantleRules.lua"

local pass, fail = 0, 0
local function eq(name, got, want)
    if got == want then pass = pass + 1
    else
        fail = fail + 1
        print("FAIL  " .. name)
        print("  got:  " .. tostring(got))
        print("  want: " .. tostring(want))
    end
end

ItemTag = { WELDING_MASK = "mask", BLOW_TORCH = "torch" }
local function item(tag, itemType, uses)
    local value = { tag = tag, itemType = itemType, uses = uses or 0 }
    function value:hasTag(want) return self.tag == want end
    function value:getType() return self.itemType end
    function value:getCurrentUses() return self.uses end
    return value
end

local mask = item("mask", "WeldingMask", 0)
local torch = item("torch", "BlowTorch", 10)
local inventory = { items = { mask, torch } }
function inventory:getFirstEvalRecurse(predicate)
    for _, value in ipairs(self.items) do
        if predicate(value) then return value end
    end
    return nil
end

local player = { admin = false, inventory = inventory, primary = torch }
function player:getInventory() return self.inventory end
function player:getPrimaryHandItem() return self.primary end

local vehicle = { removed = false, occupied = false, wreck = false }
function vehicle:isRemovedFromWorld() return self.removed end
function vehicle:getX() return 1 end
function vehicle:getY() return 2 end
function vehicle:hasPassenger() return self.occupied end

local cfg = { enabled = true, adminOnlyDismantle = false }
local claimReason, zoneBlocked, engineBlocked = nil, false, false
RCShared = {
    cfg = function() return cfg end,
    isAdmin = function(character) return character.admin end,
    claimDismantleBlock = function() return claimReason end,
    isWreck = function(v) return v.wreck end,
    phunZoneBlocks = function() return zoneBlocked end,
    engineBlocksDismantle = function()
        return engineBlocked, engineBlocked and 80 or 20
    end,
}

local okLoad, loadErr = pcall(dofile, TARGET)
if not okLoad then
    print("FATAL: could not load " .. TARGET)
    print("  " .. tostring(loadErr))
    os.exit(2)
end

local function reset()
    cfg.enabled, cfg.adminOnlyDismantle = true, false
    player.admin, player.primary = false, torch
    inventory.items = { mask, torch }
    vehicle.removed, vehicle.occupied, vehicle.wreck = false, false, false
    claimReason, zoneBlocked, engineBlocked = nil, false, false
end

reset(); cfg.enabled = false
eq("disabled feature refuses", RCDismantleRules.check(vehicle, player), "disabled")
reset(); cfg.adminOnlyDismantle = true
eq("staff-only policy refuses player", RCDismantleRules.check(vehicle, player), "staff-only")
reset(); cfg.adminOnlyDismantle = true; player.admin = true
eq("staff-only policy admits staff", RCDismantleRules.check(vehicle, player), nil)
reset(); vehicle.removed = true
eq("removed vehicle refuses", RCDismantleRules.check(vehicle, player), "gone")
reset(); claimReason = "self"
eq("own claim still requires release", RCDismantleRules.check(vehicle, player), "claim-self")
reset(); claimReason = "other"
eq("other claim refuses", RCDismantleRules.check(vehicle, player), "claim-other")
reset(); zoneBlocked = true
eq("zone policy refuses live car", RCDismantleRules.check(vehicle, player), "zone")
reset(); zoneBlocked = true; vehicle.wreck = true
eq("wreck bypasses zone policy", RCDismantleRules.check(vehicle, player), nil)
reset(); engineBlocked = true
eq("good engine refuses", RCDismantleRules.check(vehicle, player), "engine")
reset(); vehicle.occupied = true
eq("occupied vehicle refuses", RCDismantleRules.check(vehicle, player), "occupied")
reset(); inventory.items = { torch }
eq("missing mask refuses", RCDismantleRules.check(vehicle, player), "mask")
reset(); inventory.items = { mask }
eq("missing torch refuses", RCDismantleRules.check(vehicle, player), "torch")
reset(); torch.uses = 9
eq("underfilled torch refuses", RCDismantleRules.check(vehicle, player), "torch")
torch.uses = 10
reset()
local reason, state = RCDismantleRules.check(vehicle, player)
eq("valid state is admitted", reason, nil)
eq("valid state carries server torch", state.torch, torch)
eq("primary torch resolves", RCDismantleRules.primaryTorch(player), torch)
player.primary = mask
eq("non-torch primary is refused", RCDismantleRules.primaryTorch(player), nil)

print(string.format("RCDismantleRules: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
