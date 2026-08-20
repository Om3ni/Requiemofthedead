-- test_rcregistry.lua - loaded claim-map self-heal isolation.

local ROOT = arg[1] or "."
local HELPER = ROOT
    .. "/RequiemOfTheDead/Contents/mods/RFTDReclamation/42/media/lua/server/RCLoadedVehicles.lua"
local TARGET = ROOT
    .. "/RequiemOfTheDead/Contents/mods/RFTDReclamation/42/media/lua/server/RCRegistry.lua"

local pass, fail = 0, 0
local realPrint = print
local function eq(name, got, want)
    if got == want then pass = pass + 1
    else
        fail = fail + 1
        realPrint("FAIL  " .. name)
        realPrint("  got:  " .. tostring(got))
        realPrint("  want: " .. tostring(want))
    end
end

function isServer() return true end
require = function() end
Events = { OnInitGlobalModData = { Add = function() end } }
local globalData = {}
ModData = { getOrCreate = function() return globalData end }
RCClaim = { KEY_ID = "id", KEY_OWNER = "owner", KEY_ALLOWED = "allowed" }
RCShared = { cfg = function() return {} end, dbg = function() end, isTrailer = function() return false end }
function getOnlinePlayers() return { size = function() return 0 end } end
function ZombRand() return 0 end

local diagnostics = {}
function print(message) diagnostics[#diagnostics + 1] = tostring(message) end

local bad = { md = { id = "stale" }, name = "bad" }
local good = { md = { id = "current" }, name = "good" }
function bad:getModData() return self.md end
function good:getModData() return self.md end
local vehicles = { bad, good }
function getCell()
    local index = 0
    return { getVehicles = function()
        return { iterator = function()
            return {
                hasNext = function() return index < #vehicles end,
                next = function()
                    index = index + 1
                    return vehicles[index]
                end,
            }
        end }
    end }
end

local okLoad, loadErr = pcall(dofile, HELPER)
if okLoad then okLoad, loadErr = pcall(dofile, TARGET) end
if not okLoad then
    realPrint("FATAL: could not load " .. TARGET)
    realPrint("  " .. tostring(loadErr))
    os.exit(2)
end

local healed = {}
RCRegistry.syncFromVehicle = function(vehicle)
    if vehicle == bad then error("simulated self-heal fault") end
    healed[#healed + 1] = vehicle.name
end

local map = RCRegistry.loadedClaimMap()
eq("good vehicle is still self-healed", healed[1], "good")
eq("failed vehicle is absent from editable map", map.stale, nil)
eq("good vehicle is available by current claim id", map.current, good)
eq("one bounded diagnostic is emitted", #diagnostics, 1)
eq("diagnostic names skipped vehicle count",
    diagnostics[1]:find("skipped 1 of 2 vehicle%(s%)", 1) ~= nil, true)
eq("diagnostic retains the first fault", diagnostics[1]:find("simulated self-heal fault", 1, true) ~= nil, true)

local minted, mintError = RCRegistry.addToken("vehicle")
eq("valid token mint returns the new balance", minted, 1)
eq("valid token mint has no validation error", mintError, nil)
local invalidMint, invalidError = RCRegistry.addToken("aircraft")
eq("unknown token kind is refused", invalidMint, nil)
eq("unknown token kind explains refusal", invalidError, "invalid-kind")
globalData.meta.tokens = "corrupt"
local corruptMint, corruptError = RCRegistry.addToken("trailer")
eq("malformed token pool is fail-open to its caller", corruptMint, nil)
eq("malformed token pool explains refusal", corruptError, "token-pool-invalid")

realPrint(string.format("RCRegistry: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
