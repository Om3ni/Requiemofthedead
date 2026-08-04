-- test_rcparking.lua - placement legality and the minimum-spacing rule.
--
-- WHY THIS IS TESTABLE AT ALL: RCParking touches the engine only through four
-- calls, all of them inside functions rather than at file scope -
-- getVehicleZoneAt, getGridSquare, getVehicles and SafeHouse.getSafeHouse - so
-- a stub world can answer all four and the search logic runs unmodified.
--
-- WHAT IT PINS:
--   * the SPACING rule (owner's, 2026-08-03): a replacement may not land
--     within 8 tiles of another vehicle. Two placements in one sweep landed
--     almost on top of each other on a live server.
--   * that the rule works through the `avoid` list specifically, which is the
--     half no engine query can do for us. A brand-new vehicle sits in
--     cell.addVehicles (BaseVehicle.java:882) and does not reach
--     cell.getVehicles() (IsoCell.java:2368) until the cell's update pass
--     (:1875-1879), so within ONE sweep every placement is invisible to the
--     next. A test that only stocked getVehicles() would pass while the real
--     bug survived untouched - so the sequential case below is the point of
--     this file, not a bonus.
--   * that spacing did not eat the gates it sits beside: never-in-grass, the
--     safehouse veto, and nil-as-a-normal-outcome all still hold.
--
-- Usage (normally via tools\run-tests.bat):
--   lua5.1.exe tools/tests/test_rcparking.lua <repo-root>

local ROOT = arg[1] or "."
local SRC  = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDReclamation/42/media/lua/server/RCParking.lua"

-- ---------------------------------------------------------------------------
-- The stub world. Every knob defaults to "wide open, empty" so each test can
-- change exactly one thing and the failure names the thing it changed.
-- ---------------------------------------------------------------------------
local W = { parkable = true, safehouse = false, vehicles = {}, occupied = {},
            zoneW = 10, zoneH = 10, roll = 0, outside = true }

local function key(x, y) return math.floor(x) .. "," .. math.floor(y) end

require   = function() end
isServer  = function() return true end

-- Deterministic ring start. The real one randomises the bearing so
-- replacements do not all cluster east of the player; here it would only make
-- failures irreproducible.
ZombRandFloat = function() return 0 end
-- Which end of the axis zoneDirection picks. Fixed per test so the assertion
-- names a heading instead of accepting either.
ZombRand = function() return W.roll end

-- A zone answers the geometry getters the orientation rule reads. They are
-- METHODS on Zone, which is why they are reachable at all - `dir` is a field
-- and is deliberately absent here, mirroring what Lua really sees.
local function fakeZone()
    return {
        getWidth        = function() return W.zoneW end,
        getHeight       = function() return W.zoneH end,
        isFaceDirection = function() return false end,
    }
end

getWorld = function()
    return { getMetaGrid = function()
        return { getVehicleZoneAt = function(_, x, y, _z)
            if type(W.parkable) == "function" then return W.parkable(x, y) and fakeZone() or nil end
            return W.parkable and fakeZone() or nil
        end }
    end }
end

local function fakeSet(list)
    return { iterator = function()
        local i = 0
        return {
            hasNext = function() return i < #list end,
            next    = function() i = i + 1; return list[i] end,
        }
    end }
end

getCell = function()
    return {
        getGridSquare = function(_, x, y, _z)
            return {
                isVehicleIntersecting = function() return W.occupied[key(x, y)] == true end,
                isOutside = function()
                    if type(W.outside) == "function" then return W.outside(x, y) end
                    return W.outside
                end,
            }
        end,
        getVehicles = function() return fakeSet(W.vehicles) end,
    }
end

SafeHouse = { getSafeHouse = function() return W.safehouse and {} or nil end }

local function vehicleAt(x, y)
    return { getX = function() return x end, getY = function() return y end }
end

local okLoad, err = pcall(dofile, SRC)
if not okLoad then
    print("FATAL: could not load " .. SRC)
    print("  " .. tostring(err))
    os.exit(2)
end
if type(RCParking) ~= "table" then
    print("FATAL: RCParking did not load as a table")
    os.exit(2)
end

-- ---------------------------------------------------------------------------
local pass, fail = 0, 0
local function ok(label, cond, detail)
    if cond then
        pass = pass + 1
    else
        fail = fail + 1
        print("FAIL  " .. label .. (detail and ("  -- " .. tostring(detail)) or ""))
    end
end
local function eq(label, got, want)
    ok(label, got == want, string.format("got %s, want %s", tostring(got), tostring(want)))
end

local function dist(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return math.sqrt(dx * dx + dy * dy)
end

local function reset()
    W.parkable, W.safehouse, W.vehicles, W.occupied = true, false, {}, {}
    W.zoneW, W.zoneH, W.roll, W.outside = 10, 10, 0, true
end

local SPACING = 8   -- mirrors the constant under test; if that moves, this must

-- ---------------------------------------------------------------------------
-- The gates that existed before spacing, re-pinned so a spacing bug and a
-- legality bug cannot be confused for one another.
-- ---------------------------------------------------------------------------
reset()
local x, y = RCParking.findSpot(0, 0, 0, 0, 30)
ok("open ground: a spot is found", x ~= nil, tostring(x))
ok("open ground: it reports found", RCParking.status().found == true)

reset()
W.parkable = false
eq("never-in-grass: no vehicle zone means no spot", (RCParking.findSpot(0, 0, 0, 0, 30)), nil)
eq("...and the search says so rather than erroring", RCParking.status().found, false)

reset()
W.safehouse = true
eq("safehouse veto still holds", (RCParking.findSpot(0, 0, 0, 0, 30)), nil)

-- INDOOR STALLS ARE LEGAL (2026-08-04). A painted zone inside a fire bay or a
-- showroom is real parking and vanilla uses it; a blanket outdoors-only gate
-- was tried and removed because it also refused carports and overhangs. The
-- bad rooms are recorded in RCNoPark instead, one report at a time.
reset()
W.outside = false
ok("an indoor stall is accepted", RCParking.findSpot(0, 0, 0, 0, 30) ~= nil)

-- ...and the exclusion list is what refuses one. RCNoPark is a separate server
-- file; the stub here is the whole contract RCParking depends on.
reset()
RCNoPark = { blocks = function() return true end }
eq("an excluded tile is refused", (RCParking.findSpot(0, 0, 0, 0, 30)), nil)
RCNoPark = { blocks = function(x, y) return x == 3 and y == 0 end }
local nx = RCParking.findSpot(0, 0, 0, 0, 30)
ok("...and only that tile - the search moves on", nx ~= nil and nx ~= 3, tostring(nx))
RCNoPark = nil

reset()
W.occupied[key(3, 0)] = true
local ox = RCParking.findSpot(0, 0, 0, 0, 30)
ok("occupied footprint still rejected", ox ~= nil and ox ~= 3, tostring(ox))

-- ---------------------------------------------------------------------------
-- SPACING against vehicles the world already knows about.
-- ---------------------------------------------------------------------------
reset()
W.vehicles = { vehicleAt(0, 0) }
local sx, sy = RCParking.findSpot(0, 0, 0, 0, 60)
ok("existing vehicle: a spot is still found", sx ~= nil)
ok("existing vehicle: result is at least SPACING away",
    sx and dist(sx, sy, 0, 0) >= SPACING,
    sx and string.format("(%d,%d) is %.2f from (0,0)", sx, sy, dist(sx, sy, 0, 0)))

-- THE FALLBACK. maxDist 6 puts every candidate ring inside the exclusion
-- radius of that one car, so the strict pass cannot succeed. It must not end
-- there: a car park is both the only legal ground AND where cars already are,
-- so a strictly-spaced search returns nothing in exactly the dense areas that
-- have the most parking. That is not hypothetical - it placed 0 three times in
-- Louisville with 21 tokens banked.
reset()
W.vehicles = { vehicleAt(0, 0) }
local cx, cy = RCParking.findSpot(0, 0, 0, 0, 6)
ok("a crowded area still places, via the fallback", cx ~= nil, tostring(cx))
eq("...and the relaxation is reported rather than hidden", RCParking.status().relaxed, true)

reset()
-- A strict success must NOT be flagged relaxed, or the panel cries wolf.
local ux, _ = RCParking.findSpot(0, 0, 0, 0, 30)
ok("an uncrowded placement is not flagged relaxed",
    ux ~= nil and RCParking.status().relaxed == false)

reset()
W.parkable = false
eq("no legal ground anywhere is still nil after BOTH passes",
    (RCParking.findSpot(0, 0, 0, 0, 30)), nil)
eq("...and reported as not found", RCParking.status().found, false)

-- The avoid list is never relaxed. It is the one rule that exists because no
-- engine query can see those cars at all, so the fallback honours it too.
reset()
W.vehicles = { vehicleAt(0, 0) }              -- forces the fallback
local rx, ry = RCParking.findSpot(0, 0, 0, 0, 6, { { x = 3, y = 0 } })
ok("the fallback still clears this sweep's own placements",
    rx == nil or dist(rx, ry, 3, 0) >= SPACING,
    rx and string.format("(%d,%d) is %.2f from (3,0)", rx, ry, dist(rx, ry, 3, 0)))

reset()
-- The box filter in vehiclePoints must not let a distant car veto anything.
W.vehicles = { vehicleAt(10000, 10000) }
local fx = RCParking.findSpot(0, 0, 0, 0, 30)
ok("a car outside the search band blocks nothing", fx ~= nil, tostring(fx))

-- ---------------------------------------------------------------------------
-- SPACING against the avoid list. THE REGRESSION: these are the cars the
-- engine cannot see yet.
-- ---------------------------------------------------------------------------
reset()
local ax, ay = RCParking.findSpot(0, 0, 0, 0, 60, { { x = 0, y = 0 } })
ok("avoid list: a spot is still found", ax ~= nil)
ok("avoid list: result clears an invisible vehicle by SPACING",
    ax and dist(ax, ay, 0, 0) >= SPACING,
    ax and string.format("(%d,%d) is %.2f from (0,0)", ax, ay, dist(ax, ay, 0, 0)))

reset()
-- One sweep placing three cars, exactly as RCRespawn drives it: the accumulated
-- spots ARE the avoid list. Before the fix every call returned the same tile,
-- because nothing placed this tick is visible to anything.
local placed = {}
for _ = 1, 3 do
    local px, py = RCParking.findSpot(0, 0, 0, 0, 120, placed)
    if px then placed[#placed + 1] = { x = px, y = py } end
end
eq("a 3-car sweep places 3", #placed, 3)
local minGap, worst = math.huge, nil
for i = 1, #placed do
    for j = i + 1, #placed do
        local d = dist(placed[i].x, placed[i].y, placed[j].x, placed[j].y)
        if d < minGap then minGap, worst = d, string.format("(%d,%d) vs (%d,%d)",
            placed[i].x, placed[i].y, placed[j].x, placed[j].y) end
    end
end
ok("no two cars in one sweep are within SPACING",
    minGap >= SPACING, string.format("closest pair %.2f apart: %s", minGap, tostring(worst)))

reset()
-- Both sources at once, since a real sweep always has both.
W.vehicles = { vehicleAt(0, 0) }
local bx, by = RCParking.findSpot(0, 0, 0, 0, 120, { { x = 12, y = 0 } })
ok("both sources honoured: clear of the loaded car",
    bx and dist(bx, by, 0, 0) >= SPACING,
    bx and string.format("%.2f from (0,0)", dist(bx, by, 0, 0)))
ok("both sources honoured: clear of the pending car",
    bx and dist(bx, by, 12, 0) >= SPACING,
    bx and string.format("%.2f from (12,0)", dist(bx, by, 12, 0)))

-- The boundary, on real lattice points rather than invented ones. The search
-- samples rings at STEP=3, so most tiles are never offered to the rule at all
-- and "allow only tile (8,0)" would test the lattice, not the spacing. Ring 9
-- visits (6,5) at 7.81 tiles and (4,7) at 8.06 - in that order - which straddles
-- the rule with two points the search genuinely reaches.
reset()
W.parkable = function(px, py) return (px == 6 and py == 5) or (px == 4 and py == 7) end
local ex, ey = RCParking.findSpot(0, 0, 0, 0, 30, { { x = 0, y = 0 } })
ok("the nearer point is skipped and the one clear of SPACING is taken",
    ex == 4 and ey == 7, string.format("got %s,%s", tostring(ex), tostring(ey)))
ok("...and that point really is outside the rule",
    ex and dist(ex, ey, 0, 0) >= SPACING)

reset()
W.parkable = function(px, py) return px == 6 and py == 5 end
eq("with only the nearer point available, nothing is placed",
    (RCParking.findSpot(0, 0, 0, 0, 30, { { x = 0, y = 0 } })), nil)

-- ---------------------------------------------------------------------------
-- ORIENTATION. Ported from IsoChunk.java:980, whose test is a double negative:
--     if (!(w != 4 && w != 5 && w != 6 || h > 3 && h < 6)) dir = W;
-- meaning WEST when w is one of 4/5/6 AND h is not 4 or 5. These cases pin that
-- resolution, because getting it inverted points every car across its stall -
-- which is the exact symptom the rule exists to fix.
-- Codes are RCSpawn's: 1=W 2=E 3=N 4=S.
-- ---------------------------------------------------------------------------
reset()
W.zoneW, W.zoneH, W.roll = 5, 2, 0
eq("a stall-length-wide, shallow zone runs east-west", RCParking.zoneDirection(0, 0, 0), 1)
W.roll = 1
eq("...and takes the other end of that axis on the other roll",
    RCParking.zoneDirection(0, 0, 0), 2)

reset()
W.zoneW, W.zoneH, W.roll = 5, 8, 0
eq("w in range but h >= 6 is still east-west", RCParking.zoneDirection(0, 0, 0), 1)

reset()
W.zoneW, W.zoneH, W.roll = 5, 4, 0
eq("h of 4 makes the shape ambiguous, so vanilla defaults it north",
    RCParking.zoneDirection(0, 0, 0), 3)

reset()
W.zoneW, W.zoneH, W.roll = 3, 10, 0
eq("a narrow, deep zone runs north-south", RCParking.zoneDirection(0, 0, 0), 3)
W.roll = 1
eq("...and takes the other end on the other roll", RCParking.zoneDirection(0, 0, 0), 4)

reset()
W.zoneW, W.zoneH, W.roll = 20, 20, 0
eq("a big open lot defaults north-south", RCParking.zoneDirection(0, 0, 0), 3)

reset()
W.parkable = false
eq("no zone means no opinion - the caller keeps rolling",
    RCParking.zoneDirection(0, 0, 0), nil)

-- ---------------------------------------------------------------------------
-- Diagnostics contract - the Janitor view reads these keys by name.
-- ---------------------------------------------------------------------------
reset()
RCParking.findSpot(0, 0, 0, 0, 30)
local st = RCParking.status()
eq("status reports the spacing rule", st.spacing, SPACING)
eq("status reports the lattice step", st.step, 3)
ok("status reports a probe cap", (st.cap or 0) > 0, tostring(st.cap))
ok("status counts probes", (st.probes or 0) > 0, tostring(st.probes))

-- ---------------------------------------------------------------------------
print(string.format("RCParking: %d passed, %d failed", pass, fail))
os.exit(fail > 0 and 1 or 0)
