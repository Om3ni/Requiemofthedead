-- RCShared halo fixture - Reclamation uses HaloTextHelper's exposed int-color
-- overload directly for every local-player notification.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDReclamation/42/media/lua/shared/RCShared.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then passed = passed + 1 else failed = failed + 1; print("FAIL RCShared halo: " .. message) end
end

Events = {
    OnGameStart = { Add = function() end },
    OnServerStarted = { Add = function() end },
}
function isServer() return false end
RDShared = { registerMod = function() end }
RDEvents = { registerNamespace = function() end }
function require(name)
    if name == "RDShared" then return RDShared end
    if name == "RDEvents" then return RDEvents end
    error("unexpected require: " .. tostring(name))
end

local calls = {}
HaloTextHelper = {
    addText = function(character, text, separator, r, g, b)
        calls[#calls + 1] = { character, text, separator, r, g, b }
    end,
}

RCShared = nil
local loaded, loadErr = pcall(dofile, SOURCE)
check(loaded, "module loads: " .. tostring(loadErr))

local player = {}
RCShared.halo(player, "confirmed", false)
RCShared.halo(player, "denied", true)
RCShared.haloThought(player, "thinking")
check(#calls == 3, "each requested notification calls HaloTextHelper once")
check(calls[1][4] == 100 and calls[1][5] == 255 and calls[1][6] == 100,
    "confirmation uses the green integer-color overload")
check(calls[2][4] == 255 and calls[2][5] == 90 and calls[2][6] == 90,
    "denial uses the red integer-color overload")
check(calls[3][4] == 190 and calls[3][5] == 205 and calls[3][6] == 255,
    "thought uses the blue-white integer-color overload")

PhunZones = { getLocation = function() error("foreign zone fault") end }
local warnings = {}
local realPrint = print
print = function(message) warnings[#warnings + 1] = tostring(message) end
check(RCShared.phunZoneBlocks(1, 2) == false, "a failed PhunZones lookup keeps the fail-open gate")
RCShared.phunZoneBlocks(1, 2)
print = realPrint
check(#warnings == 1 and warnings[1]:find("PhunZones lookup failed", 1, true)
    and warnings[1]:find("foreign zone fault", 1, true),
    "a failed PhunZones lookup reports one bounded diagnostic")

print(string.format("RCShared halo: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
