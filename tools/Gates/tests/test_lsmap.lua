-- LSMap fixture - map bring-up, and the per-directory isolation that replaced
-- a 17-target blanket over the whole of initMap().
--
-- WHY: lot directories come from INSTALLED MAP MODS, so worldmap.xml is
-- third-party data. addData reaches WorldMapData.getOrCreateData, which calls
-- Paths.get (InvalidPathException on a malformed name) and then parses the XML
-- through the asset manager. Under the old blanket, ONE broken map mod aborted
-- the entire bring-up: no bounds, no zoom, no view flags, no style - the admin
-- got a dead map and one line of console. Each directory is independent work.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/Dragonfly/42/media/lua/client/Longstrider/LSMap.lua"

local passed, failed = 0, 0
local realPrint = print
local function check(ok, message)
    if ok then passed = passed + 1
    else failed = failed + 1; realPrint("FAIL LSMap: " .. message) end
end

-- ---- engine stubs -------------------------------------------------------
local badDirs = {}
local calls
local function newAPI()
    return {
        -- A bad lot directory raises InvalidPathException inside addData
        -- (WorldMapData.java:35, uncaught through UIWorldMapV1.addData:83-90),
        -- but addData is an exposed method: MethodCaller catches the throw, stack-traces it to the console and
-- pushes no return value (MethodCaller.java:33-56), so Lua sees nil and
-- the call simply no-ops. Corrected 2026-08-19; this used to call error().
        -- LSMap.lua:147-151 documents exactly this - the bad entry no-ops and
        -- the loop moves on to the other lots.
        addData             = function(_, f) if badDirs[f] then return nil end
                                             calls.added[#calls.added + 1] = f end,
        endDirectoryData    = function() calls.ended = calls.ended + 1 end,
        addImages           = function(_, d) calls.images[#calls.images + 1] = d end,
        setBoundsFromWorld  = function() calls.bounds = calls.bounds + 1 end,
        setZoom             = function(_, z) calls.zoom = z end,
        setBoolean          = function(_, k, v) calls.flags[k] = v end,
        centerOn            = function(_, x, y) calls.centre = { x, y } end,
    }
end

local dirList = {}
function getLotDirectories()
    return { size = function() return #dirList end,
             get  = function(_, i) return dirList[i + 1] end }
end
function fileExists() return true end
ISWorldMap_instance = true
MapUtils = { initDefaultStyleV1 = function() calls.styled = true end }

local logged = {}
local function capture() print = function(s) logged[#logged + 1] = tostring(s) end end
local function release() print = realPrint end

-- LSMap derives from ISPanel; stub just enough of the vanilla UI base for the
-- file to load. Only initMap() is under test here.
function isServer() return false end
ISPanel = { derive = function(self, name)
                local t = {}; t.__index = t; t.Type = name; return t
            end }
require = function() return true end
LSMap = nil
capture(); local ok, err = pcall(dofile, SOURCE); release()
check(ok, "module loads: " .. tostring(err))

local function bringUp(dirs, bad)
    dirList, badDirs = dirs, bad or {}
    calls = { added = {}, images = {}, ended = 0, bounds = 0, zoom = nil,
              flags = {}, centre = nil, styled = false }
    logged = {}
    local inst = { playerIndex = 0, map = { mapAPI = newAPI() },
                   player = { getX = function() return 100 end,
                              getY = function() return 200 end } }
    setmetatable(inst, { __index = LSMap })
    capture(); inst:initMap(); release()
    return inst
end

-- ---- the healthy path ---------------------------------------------------
local inst = bringUp({ "muldraugh", "riverside" })
check(#calls.added == 2 and calls.ended == 2 and #calls.images == 2,
      "every directory contributes data, a boundary mark, and images")
check(calls.bounds == 1 and calls.zoom ~= nil, "bounds and zoom are applied once")
check(calls.flags["Players"] == true and calls.flags["Symbols"] == false,
      "view flags are applied")
check(calls.flags["CellGrid"] == nil, "the cell grid is deliberately NOT set here")
check(calls.centre ~= nil and calls.centre[1] == 100, "the map centres on the player")
check(calls.styled == true, "the vanilla default style is applied")
check(inst._initialised == true, "a clean bring-up marks the map initialised")
check(#logged == 1, "a clean bring-up says one thing: that it initialised")

-- ---- THE ISOLATION ------------------------------------------------------
-- One third-party map mod with a malformed worldmap.xml.
inst = bringUp({ "muldraugh", "brokenmod", "riverside" },
               { ["media/maps/brokenmod/worldmap.xml"] = true })
check(#calls.added == 2, "the two healthy directories still load their data")
check(calls.bounds == 1 and calls.zoom ~= nil,
      "bounds and zoom STILL run - the old blanket skipped them entirely")
check(calls.flags["Players"] == true, "view flags still run after a bad directory")
check(calls.centre ~= nil, "centring still runs after a bad directory")
check(calls.styled == true, "the style pass still runs after a bad directory")
check(inst._initialised == true,
      "the map still comes up initialised - one broken mod is not a dead map")

-- NOTHING IS REPORTED, and that is correct (corrected 2026-08-19). This block
-- used to assert that the failing directory was named and that a "1 of 3
-- unusable" summary was printed. Neither can exist: addData's
-- InvalidPathException is swallowed by MethodCaller before Lua sees it
-- (MethodCaller.java:33-56), so from here a broken directory is
-- indistinguishable from one that simply had nothing to add. The skip/report
-- machinery those assertions pinned had never fired once in production, and
-- LSMap.lua:140-153 records why it was removed. The engine's own stack trace
-- is the diagnostic.
check(#logged == 1,
      "a bad directory adds no report - Lua cannot see the fault, so naming it would be invention")

-- Every directory broken is still a bring-up, just an empty one.
inst = bringUp({ "a", "b" }, { ["media/maps/a/worldmap.xml"] = true,
                               ["media/maps/b/worldmap.xml"] = true })
check(#calls.added == 0 and calls.bounds == 1,
      "even with no usable map data the bring-up completes its own work")
check(inst._initialised == true, "and still comes up initialised")

-- ---- idempotence --------------------------------------------------------
dirList = { "muldraugh" }
calls = { added = {}, images = {}, ended = 0, bounds = 0, flags = {} }
capture(); inst:initMap(); release()
check(#calls.added == 0 and calls.bounds == 0, "a second initMap is a no-op")

realPrint(string.format("LSMap: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
