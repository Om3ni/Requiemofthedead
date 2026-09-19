-- RQMuster fixture - the ownership filter, the circle, the floor, and that
-- specials are never commanded.
--
-- The cell is a table of squares keyed by "x,y,z"; a zombie stands in the
-- moving objects of exactly one. spotted() is recorded, not modelled - what
-- the engine does with a forced spot is read out of the decompile in the
-- module header, and this fixture only asks who gets one.

local ROOT = arg[1] or "."
local LUA = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDirge/42/media/lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then passed = passed + 1
    else failed = failed + 1; print("FAIL RQMuster: " .. message) end
end

-- ---------------------------------------------------------------------------
-- Engine surface
-- ---------------------------------------------------------------------------
Events = { OnGameStart = { Add = function() end } }
function instanceof(obj, className) return obj ~= nil and obj.className == className end

local squares = {}
local lookups = 0
local cellPresent = true
function getCell()
    if not cellPresent then return nil end
    return {
        getGridSquare = function(_, x, y, z)
            lookups = lookups + 1
            return squares[x .. "," .. y .. "," .. z]
        end,
    }
end
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

local spots = {}
local function zombie(oid, opts)
    opts = opts or {}
    local z = { className = "IsoZombie", oid = oid }
    z.getOnlineID    = function() return oid end
    z.isDead         = function() return opts.dead == true end
    z.isRemoteZombie = function() return opts.remote == true end
    z.spotted        = function(self, other, forced) spots[#spots + 1] = { who = self, other = other, forced = forced } end
    return z
end
local function special(oid, x, y, z)
    local s = zombie(oid)
    s.getX = function() return x + 0.4 end
    s.getY = function() return y + 0.6 end
    s.getZ = function() return z or 0 end
    return s
end

local players = {}
function getPlayerByOnlineID(id) return players[id] end

local logged = {}
RQDirgeLog = { write = function(zType, msg) logged[#logged + 1] = { zType = zType, msg = msg } end }
function require(name)
    if name == "RQRegistry" then
        dofile(LUA .. "/client/RQRegistry.lua")
        return
    end
    if name == "RQAura" then
        dofile(LUA .. "/shared/RQAura.lua")
        return
    end
    if name == "RQDirgeLog" then return end
    error("unexpected fixture require: " .. tostring(name))
end

RQMuster = nil
local ok, err = pcall(dofile, LUA .. "/client/RQMuster.lua")
check(ok, "module loads: " .. tostring(err))
check(RQMuster.MAX_RADIUS == 20, "the scan ceiling is the largest aura the sandbox can name")

local attacker = { className = "IsoPlayer" }
players[5] = attacker

-- ---------------------------------------------------------------------------
-- No attacker, no cell
-- ---------------------------------------------------------------------------
local jugg = place(special(100, 10, 10), 10, 10)
RQRegistry.register(100, "Juggernaut")
place(zombie(1), 12, 10)
check(RQMuster.muster(jugg, 99, 3) == 0 and #spots == 0 and RQMuster.stats.noAttacker == 1,
    "an attacker this client has not loaded commands nobody, and is counted")
cellPresent = false
check(RQMuster.muster(jugg, 5, 3) == 0 and #spots == 0, "with no cell there is nothing to walk")
cellPresent = true

-- ---------------------------------------------------------------------------
-- The circle, on the special's floor
-- ---------------------------------------------------------------------------
place(zombie(2), 13, 10)        -- exactly the radius, inclusive
place(zombie(3), 14, 10)        -- one past it
place(zombie(4), 12, 12)        -- sqrt(8): inside the circle
place(zombie(5), 13, 13)        -- sqrt(18): inside the square, outside the circle
place(zombie(6), 11, 10, 1)     -- upstairs
check(RQMuster.muster(jugg, 5, 3) == 3, "three escorts inside the circle are commanded")
local who = {}
for i = 1, #spots do who[spots[i].who.oid] = true end
check(who[1] and who[2] and who[4], "the ones at 2, 3 and sqrt(8) tiles")
check(not who[3] and not who[5], "not the one past the radius nor the one in the square's corner")
check(not who[6], "not the one on the floor above")
check(spots[1].other == attacker and spots[1].forced == true,
    "each is a FORCED spot of the attacker - target plus path in one call")
check(RQMuster.stats.musters == 1 and RQMuster.stats.commanded == 3, "the counters record the muster and the count")
check(#logged == 1 and logged[1].zType == "Juggernaut", "one diagnostic line, attributed to the special's type")

-- ---------------------------------------------------------------------------
-- Who is never commanded
-- ---------------------------------------------------------------------------
squares, spots = {}, {}
local boss = place(special(200, 20, 20), 20, 20)
RQRegistry.register(200, "Boss")
place(zombie(7, { remote = true }), 21, 20)
place(zombie(8, { dead = true }), 22, 20)
local screamer = place(zombie(9), 20, 21)
RQRegistry.register(9, "Screamer")
local escort = place(zombie(10), 20, 22)
check(RQMuster.muster(boss, 5, 3) == 1 and #spots == 1 and spots[1].who == escort,
    "a remote zombie, a corpse, a special and the protector itself are all passed over")
check(spots[1].who ~= screamer, "a Screamer in the aura keeps its own behaviour")

-- ---------------------------------------------------------------------------
-- The ceiling
-- ---------------------------------------------------------------------------
lookups = 0
RQMuster.muster(boss, 5, 999)
check(lookups <= (2 * RQMuster.MAX_RADIUS + 1) ^ 2, "a malformed radius is clamped, not walked")
lookups = 0
RQMuster.muster(boss, 5, 2)
check(lookups == 13, "a radius of 2 walks the 13 squares inside its circle, not the 25 in its square")

print(string.format("RQMuster: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
