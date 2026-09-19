-- test_randmcnally.lua - Map All Known re-apply contracts for RandMcNally.
--
-- The fake WorldMapVisited implements the surface the module relies on, as
-- read in 42.20.4: isKnown(x, y) answers per point, setKnownInCells marks the
-- whole cell range, and neither throws (WorldMapVisited.java:186-188,
-- :773-776). A "download" is modelled as the engine's raw overwrite: the
-- known bits simply vanish.

local ROOT = arg[1] or "."
local SRC = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDOddsAndEnds"
    .. "/42/media/lua/client/RandMcNally/RandMcNally.lua"

local pass, fail = 0, 0
local function eq(name, got, want)
    if got == want then pass = pass + 1
    else
        fail = fail + 1
        print("FAIL " .. name .. " (got " .. tostring(got) .. ", want " .. tostring(want) .. ")")
    end
end

-- metagrid cells 2..9 x 3..7
local GRID = { minX = 2, minY = 3, maxX = 9, maxY = 7 }
local grid = {}
function grid:getMinX() return GRID.minX end
function grid:getMinY() return GRID.minY end
function grid:getMaxX() return GRID.maxX end
function grid:getMaxY() return GRID.maxY end
getWorld = function() return { getMetaGrid = function() return grid end } end

local allKnown = false
local marks, probes = {}, {}
local visited = {}
function visited:isKnown(x, y)
    probes[#probes + 1] = x .. "," .. y
    return allKnown
end
function visited:setKnownInCells(x1, y1, x2, y2)
    marks[#marks + 1] = table.concat({ x1, y1, x2, y2 }, ",")
    allKnown = true
end
WorldMapVisited = { getInstance = function() return visited end }

local ticks, lines = {}, {}
Events = {
    OnGameStart = { Add = function(fn) _G.onGameStart = fn end },
    OnTick = { Add = function(fn) ticks[#ticks + 1] = fn end },
}
local now = 100000
getTimestampMs = function() return now end
local client = true
isClient = function() return client end
isServer = function() return false end
require = function() end
local realPrint = print
print = function(s) lines[#lines + 1] = s end
SandboxVars = { Map = { MapAllKnown = false } }

dofile(SRC)
local RM = RandMcNally

local function tick() for _, fn in ipairs(ticks) do fn() end end

-- singleplayer: the engine's own load path applies the option
client = false
SandboxVars.Map.MapAllKnown = true
onGameStart()
eq("singleplayer registers no watcher", #ticks, 0)
eq("singleplayer logs nothing", #lines, 0)

-- multiplayer, option off: says so once, does not watch
client = true
SandboxVars.Map.MapAllKnown = false
onGameStart()
eq("option off registers no watcher", #ticks, 0)
eq("option off is logged", lines[1] ~= nil and lines[1]:find("off", 1, true) ~= nil, true)

-- multiplayer, option on
SandboxVars.Map.MapAllKnown = true
onGameStart()
eq("option on registers one watcher", #ticks, 1)
onGameStart()
eq("a second OnGameStart does not double-register", #ticks, 1)

tick()
eq("first poll re-marks the whole metagrid", marks[1], "2,3,9,7")
eq("probe sits in the min corner cell's middle", probes[1], (2 * 256 + 128) .. "," .. (3 * 256 + 128))
eq("count after first re-apply", RM.reapplied, 1)

now = now + 500
allKnown = false            -- download lands inside the poll interval
tick()
eq("no poll before the cadence elapses", #marks, 1)

now = now + 500
tick()
eq("download erasure is repaired on the next poll", #marks, 2)

now = now + 1000
local probesBefore = #probes
tick()
eq("known map is left alone", #marks, 2)
eq("a known map checks both corners", #probes - probesBefore, 2)
eq("second probe is the max corner cell's middle", probes[#probes], (9 * 256 + 128) .. "," .. (7 * 256 + 128))

-- option turned off mid-session: nothing re-applies
SandboxVars.Map.MapAllKnown = false
allKnown = false
now = now + 1000
tick()
eq("option off mid-session stops re-applying", #marks, 2)
SandboxVars.Map.MapAllKnown = true

-- log is bounded: repeated Forget-map presses count but stop printing
local printedBefore = 0
for _, s in ipairs(lines) do if s:find("re-marked", 1, true) then printedBefore = printedBefore + 1 end end
eq("each re-apply so far printed", printedBefore, 2)
for _ = 1, 15 do
    allKnown = false
    now = now + 1000
    tick()
end
local printed = 0
for _, s in ipairs(lines) do if s:find("re-marked", 1, true) then printed = printed + 1 end end
eq("re-apply lines stop at the cap", printed, RM.LOG_CAP)
eq("re-applies past the cap are still counted", RM.reapplied, 17)

print = realPrint
print(string.format("RandMcNally: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
