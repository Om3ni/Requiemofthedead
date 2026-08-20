-- HBFarmHand fixture - the hutch registry, and the prune rule that could
-- forget every coop on the map.
--
-- WHY THIS EXISTS: this module was written to fix a silent live bug (a coop at
-- Bedding 88% / Dirtiness 25% - bedding present, dirt climbing anyway) caused
-- by upkeep running on PLAYER proximity while vanilla dirties on LOADED. The
-- repair is a registry walked by coordinate, and its one dangerous edge is
-- deciding when to FORGET a hutch. Get that wrong in the unloaded direction and
-- the module quietly un-services every coop the moment the server is empty -
-- which is the exact failure it was written to end, reintroduced from the other
-- side and just as invisible.
--
-- STUBS MODEL THE VERIFIED SURFACE. getGridSquare returns nil for a cold
-- coordinate (IsoCell.java:2800-2818) rather than throwing; IsoGridSquare
-- getHutch is a specialObjects walk returning the first hutch or nil
-- (:9846-9854); IsoHutch getHutch returns self for a master and follows
-- linkedX/Y/Z for a slave, answering nil when the master's square is cold
-- (IsoHutch.java:127-142). Nothing here throws to force a guard.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDHusbandry/42/media/lua/server/HBFarmHand.lua"

local passed, failed = 0, 0
local realPrint = print
local function check(ok, message)
    if ok then passed = passed + 1
    else failed = failed + 1; realPrint("FAIL HBFarmHand: " .. message) end
end

-- ---- engine stubs -------------------------------------------------------
function isServer() return true end
require = function() return true end

local world = {}     -- "x,y,z" -> hutch stub (or nil for "loaded, no hutch")
local loaded = {}    -- "x,y,z" -> true when the square is loaded

local function mkHutch(x, y, z, master)
    local h = { x = x, y = y, z = z, master = master }
    function h:getSquare()
        return { getX = function() return self.x end,
                 getY = function() return self.y end,
                 getZ = function() return self.z end }
    end
    -- IsoHutch.getHutch: self when master, else the linked master IF loaded.
    function h:getHutch()
        if not self.master then return self end
        local mk = self.master
        if not loaded[mk] then return nil end   -- cold master square
        return world[mk]
    end
    return h
end

local function key(x, y, z) return x .. "," .. y .. "," .. z end

function getCell()
    return { getGridSquare = function(_, x, y, z)
        local k = key(x, y, z)
        if not loaded[k] then return nil end
        return { getHutch = function() return world[k] end }
    end }
end

local bedded = {}
HBBedding = {
    applyBedding = function(h) bedded[#bedded + 1] = key(h.x, h.y, h.z) end,
    -- The real resolver: master resolution, nil when the master is cold.
    resolveHutchAt = function(x, y, z)
        local h = world[key(x, y, z)]
        if not h then return nil end
        return h:getHutch()
    end,
}
local refilled = {}
HBKeepAlive = { refillHutch = function(h) refilled[#refilled + 1] = key(h.x, h.y, h.z) end }

HBFarmHand = nil
local ok, err = pcall(dofile, SOURCE)
check(ok, "module loads: " .. tostring(err))

-- ---- registration --------------------------------------------------------
local a = mkHutch(10, 20, 0)
world[key(10, 20, 0)] = a; loaded[key(10, 20, 0)] = true

HBFarmHand.remember(a)
check(HBFarmHand.stats.registered == 1, "a hutch was not registered")
HBFarmHand.remember(a)
check(HBFarmHand.stats.registered == 1, "registering the same hutch twice double-counted")
HBFarmHand.remember(nil)
check(HBFarmHand.stats.registered == 1, "a nil hutch was registered")

-- A SLAVE tile must register its MASTER's coordinates, or a multi-tile coop
-- takes one registry slot per tile and each resolves back to the same master.
local m = mkHutch(50, 50, 0)
world[key(50, 50, 0)] = m; loaded[key(50, 50, 0)] = true
local slave = mkHutch(51, 50, 0, key(50, 50, 0))
world[key(51, 50, 0)] = slave; loaded[key(51, 50, 0)] = true
HBFarmHand.remember(slave)
check(HBFarmHand.stats.registered == 2, "registering a slave did not resolve to one master entry")

-- ---- the pass ------------------------------------------------------------
bedded, refilled = {}, {}
local serviced, skipped = HBFarmHand.pass()
check(serviced == 2, "expected both coops serviced, got " .. serviced)
check(#bedded == 2 and #refilled == 2, "upkeep did not run both jobs per hutch")

-- A slave-registered coop must service the MASTER's coordinates, never the
-- slave's - dirt, animals and bedding all live on the master alone.
local sawMaster = false
for _, k in ipairs(bedded) do if k == key(50, 50, 0) then sawMaster = true end end
check(sawMaster, "the multi-tile coop was serviced on the slave tile, not the master")

-- ---- unloaded is a SKIP, never a prune -----------------------------------
-- This is the assertion that matters most.
loaded[key(10, 20, 0)] = nil
loaded[key(50, 50, 0)] = nil
loaded[key(51, 50, 0)] = nil
bedded = {}
serviced, skipped = HBFarmHand.pass()
check(serviced == 0 and skipped == 2, "an unloaded pass did not read as skipped")
check(HBFarmHand.stats.registered == 2,
    "UNLOADED HUTCHES WERE PRUNED - an empty server would forget every coop on "
    .. "the map, which is the original bug reintroduced from the other side")
check(#bedded == 0, "upkeep ran against a cold coordinate")

-- Reloading must resume service without re-registration.
loaded[key(10, 20, 0)] = true
loaded[key(50, 50, 0)] = true
serviced = HBFarmHand.pass()
check(serviced == 2, "service did not resume when the coops reloaded")

-- ---- a cold MASTER is a skip too -----------------------------------------
-- The square is loaded and holds a hutch, but its master is not reachable.
-- That is "come back later", not "this coop is gone".
loaded[key(50, 50, 0)] = nil          -- master cold
world[key(50, 50, 0)] = nil
HBFarmHand.remember(mkHutch(70, 70, 0, key(99, 99, 0)))  -- master never loaded
local before = HBFarmHand.stats.registered
HBFarmHand.pass()
check(HBFarmHand.stats.registered == before,
    "a hutch whose master square is cold was pruned rather than skipped")

-- ---- a LOADED square with no hutch IS a prune ----------------------------
local gone = mkHutch(80, 80, 0)
world[key(80, 80, 0)] = gone; loaded[key(80, 80, 0)] = true
HBFarmHand.remember(gone)
local n = HBFarmHand.stats.registered
world[key(80, 80, 0)] = nil            -- destroyed; square still loaded
HBFarmHand.pass()
check(HBFarmHand.stats.registered == n - 1,
    "a destroyed hutch on a loaded square was not pruned")
check(HBFarmHand.stats.pruned >= 1, "the prune was not counted")

-- ---- no cell -------------------------------------------------------------
local realGetCell = getCell
getCell = function() return nil end
local okNoCell = pcall(HBFarmHand.pass)
check(okNoCell, "the pass threw with no cell")
getCell = realGetCell

-- ---- coverage is honest --------------------------------------------------
local cov = HBFarmHand.coverage()
check(type(cov) == "table" and cov.registered == HBFarmHand.stats.registered,
    "coverage disagrees with the registry")
check(type(cov.note) == "string" and cov.note:find("restart"),
    "coverage does not state the in-memory restart limitation")

realPrint(string.format("HBFarmHand: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
