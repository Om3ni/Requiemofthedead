-- RQAura fixture - the circle, the floor, and who the walk never yields.
--
-- The three consumers (RQJuggernaut, RQBoss, RQMuster) each pin their own
-- policy; this pins the one walk they share.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDirge/42/media/lua/shared/RQAura.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then passed = passed + 1
    else failed = failed + 1; print("FAIL RQAura: " .. message) end
end

function instanceof(obj, className) return obj ~= nil and obj.className == className end

local squares, lookups = {}, 0
local cell = {
    getGridSquare = function(_, x, y, z)
        lookups = lookups + 1
        return squares[x .. "," .. y .. "," .. z]
    end,
}
local function place(obj, x, y, z)
    local key = x .. "," .. y .. "," .. (z or 0)
    local sq = squares[key]
    if not sq then
        local list = {}
        sq = {
            list = list,
            getMovingObjects = function()
                return { size = function() return #list end, get = function(_, i) return list[i + 1] end }
            end,
        }
        squares[key] = sq
    end
    sq.list[#sq.list + 1] = obj
    return obj
end
local function zombie(id, dead)
    return { className = "IsoZombie", id = id, isDead = function() return dead == true end }
end
local function special(x, y, z)
    local s = zombie("special")
    s.getX = function() return x + 0.7 end
    s.getY = function() return y + 0.2 end
    s.getZ = function() return z or 0 end
    return s
end

RQAura = nil
local ok, err = pcall(dofile, SOURCE)
check(ok, "module loads: " .. tostring(err))

local seen = {}
local function collect(z) seen[#seen + 1] = z.id end

-- The circle on the special's floor.
local jugg = place(special(10, 10), 10, 10)
place(zombie("two"), 12, 10)
place(zombie("edge"), 13, 10)        -- exactly the radius, inclusive
place(zombie("past"), 14, 10)        -- one past it
place(zombie("diag"), 12, 12)        -- sqrt(8): inside
place(zombie("corner"), 13, 13)      -- sqrt(18): the square's corner, outside the circle
place(zombie("upstairs"), 11, 10, 1)
place(zombie("corpse", true), 11, 10)
place({ className = "IsoPlayer", id = "player" }, 11, 11)
check(RQAura.eachEscort(cell, jugg, 3, collect) == 3, "three live zombies inside the circle are yielded")
local got = {}
for i = 1, #seen do got[seen[i]] = true end
check(got.two and got.edge and got.diag, "the ones at 2, 3 and sqrt(8) tiles, the radius inclusive")
check(not got.past and not got.corner, "not past the radius, not in the square's corner")
check(not got.upstairs, "not on the floor above")
check(not got.corpse and not got.player and not got.special,
    "never a corpse, never a non-zombie, never the special itself")

-- The count matches the calls, and the walk is the circle's squares only.
lookups, seen = 0, {}
check(RQAura.eachEscort(cell, jugg, 2, collect) == #seen, "the return value is the number of calls")
check(lookups == 13, "a radius of 2 looks up the 13 squares in its circle, not the 25 in its square")

-- Fractional position floors to the tile the special stands on.
squares, seen = {}, {}
local boss = place(special(20, 20), 20, 20)
place(zombie("here"), 20, 20)
check(RQAura.eachEscort(cell, boss, 0, collect) == 1 and seen[1] == "here",
    "radius 0 is the special's own square, and a zombie sharing it is yielded")

print(string.format("RQAura: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
