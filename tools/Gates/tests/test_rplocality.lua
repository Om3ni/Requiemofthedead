-- RPLocality fixture - the Necro tab's "is it in my area" predicate.
--
-- WHY THIS FILE EXISTS. The predicate shipped wrong once: a grid-bucket
-- compare excluded a zombie two tiles away from "My chunk" roughly four times
-- in ten, and it was found IN PLAY (2026-08-20) because the helper was a
-- file-local in a ~950-line UI module no fixture could load. The centred-box
-- replacement was likewise unproven by anything but reading until RPLocality
-- split out (2026-08-25). These pins are the difference between "the fix was
-- read" and "the fix is held".

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDReaper/42/media/lua/client/RPLocality.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL RPLocality: " .. message)
    end
end

-- The engine surfaces the module reads: player position and the two sizes.
local px, py = 100, 200
function getPlayer()
    return {
        getX = function() return px end,
        getY = function() return py end,
    }
end
function getChunkSizeInSquares() return 8 end
function getCellSizeInSquares() return 256 end

RPLocality = nil
local ok, err = pcall(dofile, SOURCE)
check(ok, "module loads: " .. tostring(err))

local near = RPLocality.nearPlayer

-- ---------------------------------------------------------------------------
-- THE BUG THIS FILE GUARDS AGAINST. Player at x=100: under the old
-- floor(x/8) == floor(px/8) compare, x=102 bucketed with 100 only when
-- 100 mod 8 <= 5 - and at 100 mod 8 == 4 it passes, but a player at 103
-- (mod 8 == 7) with a zombie at 105 did not. The centred box has no such
-- boundary: two tiles away is ALWAYS inside a chunk-sized window.
-- ---------------------------------------------------------------------------
for _, playerX in ipairs({ 96, 100, 103, 104, 107 }) do
    px = playerX
    check(near({ x = playerX + 2, y = 200 }, 8),
        "two tiles east is ALWAYS 'my chunk', player at x=" .. playerX
        .. " - the grid-bucket bug excluded this four times in ten")
end
px = 100

-- The box is a half-extent each side, inclusive.
check(near({ x = 104, y = 200 }, 8), "the half-extent edge is inside")
check(not near({ x = 105, y = 200 }, 8), "one past the half-extent is outside")
check(near({ x = 96, y = 196 }, 8), "both axes at the edge together")
check(not near({ x = 100, y = 205 }, 8), "the other axis excludes on its own")

-- Z is deliberately not compared - a zombie one floor up is still in the area.
check(near({ x = 100, y = 200, z = 4 }, 8), "z never excludes")

-- Absent data refuses rather than guessing.
check(not near(nil, 8), "a nil row is not near")
check(not near({ y = 200 }, 8), "a row with no x is not near")
local realGetPlayer = getPlayer
getPlayer = function() return nil end
check(not near({ x = 100, y = 200 }, 8), "no player, nothing is near")
getPlayer = realGetPlayer

-- ---------------------------------------------------------------------------
-- apply: the view over held rows
-- ---------------------------------------------------------------------------
local rows = {
    { id = 1, x = 101, y = 201 },   -- beside the player
    { id = 2, x = 150, y = 200 },   -- out of the chunk, inside the cell
    { id = 3, x = 900, y = 900 },   -- out of everything
}
local function ids(list)
    local out = {}
    for _, r in ipairs(list) do out[#out + 1] = r.id end
    return table.concat(out, ",")
end

check(ids(RPLocality.apply(rows, "any")) == "1,2,3", "'any' passes everything")
check(ids(RPLocality.apply(rows, nil)) == "1,2,3", "nil locality passes everything")
check(ids(RPLocality.apply(rows, "chunk")) == "1", "'chunk' narrows to the 8-square box")
check(ids(RPLocality.apply(rows, "cell")) == "1,2", "'cell' narrows to the 256-square box")
check(RPLocality.apply(rows, "any") == rows,
    "'any' returns the held rows themselves - no copy, no wire, no cost")

print(string.format("RPLocality: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
