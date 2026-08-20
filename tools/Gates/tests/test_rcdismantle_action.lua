-- test_rcdismantle_action.lua - engine-native authoritative completion.

local ROOT = arg[1] or "."
local TARGET = ROOT
    .. "/RequiemOfTheDead/Contents/mods/RFTDReclamation/42/media/lua/shared/RCDismantleAction.lua"

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

require = function() end
ISRemoveBurntVehicle = {}
function ISRemoveBurntVehicle:derive()
    local child = {}
    child.__index = child
    setmetatable(child, { __index = self })
    return child
end
function ISRemoveBurntVehicle:isValid() return true end
function ISRemoveBurntVehicle:getDuration() return 800 end
function ISRemoveBurntVehicle:new(character, vehicle)
    local action = { character = character, vehicle = vehicle }
    setmetatable(action, self)
    self.__index = self
    return action
end

local client = true
local server = false
function isClient() return client end
function isServer() return server end
local yieldCalls, finishCalls = 0, 0
local character, vehicle = {}, {}
RCShared = {
    MODULE = "RFTDReclamation",
    cfg = function() return { dismantleTimePct = 100 } end,
    claimDismantleBlock = function() return nil end,
    dbg = function() end,
}
local torch = {}
RCDismantleRules = { primaryTorch = function() return torch end }
RCDismantleYield = {
    commit = function()
        yieldCalls = yieldCalls + 1
        return true, { phase = "committed" }
    end,
}
RCDismantleAuthority = {
    finish = function(gotCharacter, gotPermit, gotVehicle)
        finishCalls = finishCalls + 1
        eq("server completion receives character", gotCharacter, character)
        eq("server completion receives opaque permit", gotPermit, "permit-7")
        eq("server completion receives action vehicle", gotVehicle, vehicle)
        return true
    end,
}

local okLoad, loadErr = pcall(dofile, TARGET)
if not okLoad then
    print("FATAL: could not load " .. TARGET)
    print("  " .. tostring(loadErr))
    os.exit(2)
end

local action = RCDismantleAction:new(character, vehicle, "field", "permit-7")
eq("constructor exposes transport via field", action.via, "field")
eq("constructor exposes transport permit field", action.permit, "permit-7")
eq("MP client completion remains mutation-free", action:complete(), true)
eq("MP action performs no local yield", yieldCalls, 0)

client, server = false, true
eq("server action completes authoritatively", action:complete(), true)
eq("server action calls authority once", finishCalls, 1)
eq("server action performs no local yield", yieldCalls, 0)

server = false
local single = RCDismantleAction:new(character, vehicle, "field", nil)
eq("single-player action commits locally", single:complete(), true)
eq("single-player action uses shared yield", yieldCalls, 1)

print(string.format("RCDismantleAction: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
