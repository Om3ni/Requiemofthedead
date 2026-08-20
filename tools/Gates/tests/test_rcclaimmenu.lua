-- RCClaimMenu fixture - owned radial slices are direct, while one failing
-- extension provider is reported once and cannot suppress later providers.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDReclamation/42/media/lua/client/RCClaimMenu.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL RCClaimMenu: " .. message)
    end
end

function isServer() return false end
function isClient() return true end
function getText(key) return key end
function getTexture(path) return path end
function sendClientCommand() end

RCShared = {
    MODULE = "Reclamation",
    cfg = function() return { claimsEnabled = true, debug = false } end,
    halo = function() end,
    isAdmin = function() return false end,
}
RCClaim = {
    PERMS = {},
    getOwner = function() return nil end,
    canClaim = function() return true end,
    canInteract = function() return true end,
}

local gameStart
Events = {
    OnGameStart = { Add = function(fn) gameStart = fn end },
    OnServerCommand = { Add = function() end },
}

local originalCalls = 0
local vehicle = { getId = function() return 12 end }
ISVehicleMenu = {
    getVehicleToInteractWith = function() return vehicle end,
    showRadialMenuOutside = function() originalCalls = originalCalls + 1 end,
}

local slices = {}
local menu = {
    isReallyVisible = function() return false end,
    isEmpty = function() return false end,
    addSlice = function(_, label) slices[#slices + 1] = label end,
    setX = function() end,
    setY = function() end,
    getWidth = function() return 100 end,
    getHeight = function() return 100 end,
}
function getPlayerRadialMenu() return menu end
function getPlayerScreenLeft() return 0 end
function getPlayerScreenTop() return 0 end
function getPlayerScreenWidth() return 800 end
function getPlayerScreenHeight() return 600 end

local player = {
    getPlayerNum = function() return 0 end,
    getUsername = function() return "Caretaker" end,
}

local laterProviderCalls = 0
local badProvider = function() error("simulated provider failure") end
RCClaimMenu = { sliceProviders = {
    function(radial) radial:addSlice("first-provider") end,
    badProvider,
    function(radial)
        laterProviderCalls = laterProviderCalls + 1
        radial:addSlice("later-provider")
    end,
} }

local realPrint = print
local diagnostics = {}
print = function(message) diagnostics[#diagnostics + 1] = tostring(message) end
local ok, err = pcall(dofile, SOURCE)
check(ok, "module loads: " .. tostring(err))
check(type(gameStart) == "function", "registers the delayed wrapper installer")

gameStart()
ISVehicleMenu.showRadialMenuOutside(player)
check(originalCalls == 1, "preserves the wrapped vanilla radial builder")
check(slices[1] == "IGUI_RC_Claim", "adds the owned claim slice directly")
check(slices[2] == "first-provider" and slices[3] == "later-provider",
      "continues through healthy providers after a failed provider")
check(laterProviderCalls == 1, "invokes the later provider exactly once")
check(#diagnostics == 1 and diagnostics[1]:find("simulated provider failure", 1, true),
      "reports the provider failure")

ISVehicleMenu.showRadialMenuOutside(player)
check(laterProviderCalls == 2, "a later provider remains usable on the next menu")
check(#diagnostics == 1, "reports each failing provider only once")
print = realPrint

realPrint(string.format("RCClaimMenu: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
