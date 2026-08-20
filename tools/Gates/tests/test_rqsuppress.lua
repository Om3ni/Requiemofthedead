-- RQSuppress fixture - one foreign predicate may fail without silencing a
-- healthy source, and render-tick failures must remain bounded and visible.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDirge/42/media/lua/client/RQSuppress.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then passed = passed + 1 else failed = failed + 1; print("FAIL RQSuppress: " .. message) end
end

local callbacks = { render = nil, gameStart = nil }
Events = {
    OnRenderTick = { Add = function(fn) callbacks.render = fn end },
    OnGameStart = { Add = function(fn) callbacks.gameStart = fn end },
}
RQDirgeLog = { write = function() end }
function getTimestampMs() return 1000 end

local modData = {}
local weapon = {}
function weapon:getModData() return modData end
function weapon:getMinDamage() return 10 end
function weapon:getMaxDamage() return 20 end
function weapon:setMinDamage(value) self.minDamage = value end
function weapon:setMaxDamage(value) self.maxDamage = value end
function weapon:getName() return "Fixture weapon" end
local player = {
    getPrimaryHandItem = function() return weapon end,
    getInventory = function() return nil end,
}
function getPlayer() return player end

RQSuppress = nil
local loaded, loadErr = pcall(dofile, SOURCE)
check(loaded, "module loads: " .. tostring(loadErr))
check(type(callbacks.render) == "function", "registers its render lifecycle")

RQSuppress.register("fixture", "broken", function() error("fixture predicate fault") end)
RQSuppress.register("fixture", "healthy", function() return 0.5 end)

local realPrint = print
local warnings = {}
print = function(message) warnings[#warnings + 1] = tostring(message) end
callbacks.render()
callbacks.render()
print = realPrint

check(weapon.minDamage == 5 and weapon.maxDamage == 10,
    "a healthy source still applies while its sibling predicate fails")
check(#warnings == 1 and warnings[1]:find("fixture.broken", 1, true)
    and warnings[1]:find("fixture predicate fault", 1, true),
    "a failed predicate is identified and reported once")

RQSuppress.register("fixture", "broken", function() error("replacement predicate fault") end)
warnings = {}
print = function(message) warnings[#warnings + 1] = tostring(message) end
callbacks.render()
print = realPrint
check(#warnings == 1 and warnings[1]:find("replacement predicate fault", 1, true),
    "replacing a source permits one diagnostic for the new predicate")

print(string.format("RQSuppress: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
