-- LMShadow fixture - the optional PhunZones migration probe fails quietly in
-- gameplay terms but leaves one bounded operational diagnostic.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDLimes/42/media/lua/server/LMShadow.lua"

local passed, failed = 0, 0
local realPrint = print
local function check(ok, message)
    if ok then passed = passed + 1
    else failed = failed + 1; realPrint("FAIL LMShadow: " .. message) end
end

function isServer() return true end
local sweep
Events = {
    EveryTenMinutes = { Add = function(fn) sweep = fn end },
    OnServerStarted = { Add = function() end },
}
Limes = { revision = 1, getLocation = function() return nil end }
function require(name)
    if name == "LMCore" then return Limes end
    error("unexpected require: " .. tostring(name))
end
function getActivatedMods() return { contains = function(_, id) return id == "phunzones2" end } end
local player = { getX = function() return 11 end, getY = function() return 22 end, getUsername = function() return "Omen" end }
function getOnlinePlayers() return { size = function() return 1 end, get = function() return player end } end
PhunZones = { getLocation = function() error("zone index broke") end }

local prints = {}
print = function(message) prints[#prints + 1] = tostring(message) end
LMShadow = nil
local loaded, loadErr = pcall(dofile, SOURCE)
check(loaded, "module loads: " .. tostring(loadErr))
check(type(sweep) == "function", "registers the bounded ten-minute sweep")
sweep()
sweep()

local failures = 0
for i = 1, #prints do
    if prints[i]:find("PhunZones lookup failed", 1, true) then failures = failures + 1 end
end
check(failures == 1, "foreign lookup faults produce one bounded diagnostic")
check(#prints == 1 and prints[1]:find("zone index broke", 1, true) ~= nil,
    "diagnostic identifies the skipped provider failure")

realPrint(string.format("LMShadow: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
