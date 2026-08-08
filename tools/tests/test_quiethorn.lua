-- test_quiethorn.lua - behavioural tests for Quiet Horn under real Lua 5.1.
--
-- WHAT THIS PINS. The module exists because BaseVehicle.onHornStart() sets the
-- horn flag AND calls WorldSoundManager.addSound(..., 150, 150, ...) in the same
-- method, and nothing in the engine lets a mod ask for one without the other:
-- hornEnable is a public field with no setter on a struct Kahlua cannot write,
-- and WorldSoundManager has no removal call. So the module's whole correctness
-- rests on ONE property:
--
--   the engine's onHornStart must never be called while Quiet Horn is on.
--
-- If it ever is, the herding sound is created and cannot be taken back - and the
-- symptom is invisible in-game, because the horn still sounds exactly the same.
-- Nothing would tell you except zombies quietly walking toward the noise. That
-- is precisely the kind of silent regression a test has to hold, so the vehicle
-- stub below records the call and every path is checked against it.
--
-- The second thing worth pinning is the sound mapping. A vehicle's own horn name
-- is unreadable from Lua (public field), so the module recovers it from the
-- script name, and a prefix table is easy to break by reordering.
--
-- Usage (normally via tools\run-tests.bat):
--   lua5.1.exe tools/tests/test_quiethorn.lua <repo-root>

local ROOT = arg[1] or "."
local SRC  = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDOddsAndEnds"
             .. "/42/media/lua/client/QuietHorn/QHClient.lua"

local pass, fail = 0, 0
local function eq(name, got, want)
    if got == want then pass = pass + 1
    else
        fail = fail + 1
        print("FAIL " .. name)
        print("  got:  " .. tostring(got))
        print("  want: " .. tostring(want))
    end
end
local function ok(name, cond, detail)
    if cond then pass = pass + 1
    else
        fail = fail + 1
        print("FAIL " .. name)
        if detail then print("  " .. tostring(detail)) end
    end
end

-- ---------------------------------------------------------------------------
-- Engine stubs
-- ---------------------------------------------------------------------------

require  = function() end
isServer = function() return false end

local clientMode = true
isClient = function() return clientMode end

local now = 1000
getTimestampMs = function() return now end

local enabled = true
OEShared = {
    MODULE  = "RFTDOddsAndEnds",
    enabled = function() return enabled end,
}

local sent = {}
RDNet = { send = function(module, command, args)
    sent[#sent + 1] = { module = module, command = command, args = args }
end }

local tickHandlers, serverCommandHandlers = {}, {}
Events = {
    OnTick          = { Add = function(f) tickHandlers[#tickHandlers + 1] = f end },
    OnServerCommand = { Add = function(f) serverCommandHandlers[#serverCommandHandlers + 1] = f end },
}

-- The originals Quiet Horn captures. Reaching either of these means the kill
-- switch handed control back to vanilla, which is only correct when off.
local vanillaCalls = {}
ISVehicleMenu = {
    onHornStart = function() vanillaCalls[#vanillaCalls + 1] = "start" end,
    onHornStop  = function() vanillaCalls[#vanillaCalls + 1] = "stop" end,
}

-- A vehicle that records the two things that must never happen (the engine horn
-- call) and the two that must (looped play, stop).
local nextHandle = 0
local vehicles = {}

local function mkVehicle(id, scriptName, hasHorn)
    local v = {
        id = id, scriptName = scriptName, horn = hasHorn ~= false,
        engineHornCalls = 0, played = {}, stopped = {}, live = nil,
    }
    function v:getId() return self.id end
    function v:getScriptName() return self.scriptName end
    function v:hasHorn() return self.horn end
    function v:isDriver() return true end
    -- The method the whole module exists to avoid.
    function v:onHornStart() self.engineHornCalls = self.engineHornCalls + 1 end
    function v:onHornStop()  self.engineHornCalls = self.engineHornCalls + 1 end
    function v:getEmitter()
        local owner = self
        return {
            playSoundLooped = function(_, name)
                nextHandle = nextHandle + 1
                owner.played[#owner.played + 1] = name
                owner.live = nextHandle
                return nextHandle
            end,
            stopSound = function(_, handle)
                owner.stopped[#owner.stopped + 1] = handle
                owner.live = nil
                return 1
            end,
        }
    end
    vehicles[id] = v
    return v
end

getVehicleById = function(id) return vehicles[id] end

local function mkPlayer(vehicle)
    return { getVehicle = function() return vehicle end }
end

local function tick() for _, f in ipairs(tickHandlers) do f() end end
local function serverCommand(module, command, args)
    for _, f in ipairs(serverCommandHandlers) do f(module, command, args) end
end

-- ---------------------------------------------------------------------------

local QuietHorn = dofile(SRC)
ok("QHClient loads and returns its table", type(QuietHorn) == "table")
ok("it took over onHornStart", ISVehicleMenu.onHornStart ~= nil)
ok("it registered a tick reaper", #tickHandlers == 1)
ok("it listens for other players' horns", #serverCommandHandlers == 1)

-- ---------------------------------------------------------------------------
-- The property the module exists for
-- ---------------------------------------------------------------------------

local car = mkVehicle(1, "Base", true)
local player = mkPlayer(car)

ISVehicleMenu.onHornStart(player)
eq("the engine horn is never called on start", car.engineHornCalls, 0)
eq("but a horn is played",                     #car.played, 1)
eq("and vanilla is not consulted",             #vanillaCalls, 0)

ISVehicleMenu.onHornStop(player)
eq("the engine horn is never called on stop", car.engineHornCalls, 0)
eq("and the sound is stopped",                #car.stopped, 1)
eq("nothing is left playing",                 car.live, nil)

-- Hammer every entry point repeatedly: the engine call must stay at zero.
for _ = 1, 20 do
    ISVehicleMenu.onHornStart(player)
    ISVehicleMenu.onHornStop(player)
end
eq("still zero after 20 honks", car.engineHornCalls, 0)

-- ---------------------------------------------------------------------------
-- Multiplayer relay
-- ---------------------------------------------------------------------------

sent = {}
clientMode = true
ISVehicleMenu.onHornStart(player)
eq("a client tells the server",     #sent, 1)
eq("under the mod's own token",     sent[1].module, "RFTDOddsAndEnds")
eq("with the start command",        sent[1].command, "hornStart")
ISVehicleMenu.onHornStop(player)
eq("and again on stop",             sent[2].command, "hornStop")

-- Singleplayer must not try to talk to a server that is not there.
sent = {}
clientMode = false
ISVehicleMenu.onHornStart(player)
eq("singleplayer sends nothing",            #sent, 0)
eq("but still plays locally",               car.live ~= nil, true)
eq("and still never calls the engine horn", car.engineHornCalls, 0)
ISVehicleMenu.onHornStop(player)
clientMode = true

-- ---------------------------------------------------------------------------
-- Hearing someone else
-- ---------------------------------------------------------------------------

local otherCar = mkVehicle(2, "Base", true)
serverCommand("RFTDOddsAndEnds", "hornStart", { vehicle = 2 })
eq("a broadcast starts a remote horn", #otherCar.played, 1)
serverCommand("RFTDOddsAndEnds", "hornStop", { vehicle = 2 })
eq("and stops it",                     otherCar.live, nil)

serverCommand("SomeOtherMod", "hornStart", { vehicle = 2 })
eq("another mod's token is ignored", #otherCar.played, 1)

-- The server echoes to everyone including the honking player, who already
-- started locally. That must not stack a second looped instance.
local echoCar = mkVehicle(3, "Base", true)
local echoPlayer = mkPlayer(echoCar)
ISVehicleMenu.onHornStart(echoPlayer)
serverCommand("RFTDOddsAndEnds", "hornStart", { vehicle = 3 })
eq("the echo does not double-play", #echoCar.played, 1)

-- ---------------------------------------------------------------------------
-- Vehicles with no horn
-- ---------------------------------------------------------------------------

local trailer = mkVehicle(4, "Trailer", false)
serverCommand("RFTDOddsAndEnds", "hornStart", { vehicle = 4 })
eq("a vehicle with no horn does not grow one", #trailer.played, 0)

-- ---------------------------------------------------------------------------
-- The orphan reaper
-- ---------------------------------------------------------------------------

local lost = mkVehicle(5, "Base", true)
serverCommand("RFTDOddsAndEnds", "hornStart", { vehicle = 5 })
ok("the orphan is sounding", lost.live ~= nil)
now = now + 5000
tick()
ok("and is left alone before the deadline", lost.live ~= nil)
now = now + 20000
tick()
eq("but is reaped after it", lost.live, nil)

-- ---------------------------------------------------------------------------
-- Sound mapping
--
-- Recovered from the script name because the vehicle's own horn name is a public
-- Java field. Checked against media/scripts/generated/vehicles.
-- ---------------------------------------------------------------------------

local function hornFor(scriptName)
    local id = 100 + #vehicles
    local v = mkVehicle(id, scriptName, true)
    serverCommand("RFTDOddsAndEnds", "hornStart", { vehicle = id })
    serverCommand("RFTDOddsAndEnds", "hornStop", { vehicle = id })
    return v.played[1]
end

eq("a plain car takes the standard horn", hornFor("Base"),        "VehicleHornStandard")
eq("Van takes the van horn",              hornFor("Van"),         "VehicleHornVan")
eq("so does VanMail",                     hornFor("VanMail"),     "VehicleHornVan")
eq("and Van_Leather",                     hornFor("Van_Leather"), "VehicleHornVan")
eq("SportsCar takes the sports horn",     hornFor("SportsCar"),   "VehicleHornSportsCar")
eq("and SportsCar_ez with it",            hornFor("SportsCar_ez"),"VehicleHornSportsCar")
eq("OffRoad takes the jeep horn",         hornFor("OffRoad"),     "VehicleHornJeep")
eq("an unknown modded vehicle falls back", hornFor("SomeModdedTruck"), "VehicleHornStandard")
eq("and so does a nameless one",          hornFor(""),            "VehicleHornStandard")

-- ---------------------------------------------------------------------------
-- The kill switch
--
-- Off must hand control back to the captured originals - that is what restores
-- vanilla's herding horn without a restart - and must NOT keep playing our own.
-- ---------------------------------------------------------------------------

local offCar = mkVehicle(200, "Base", true)
local offPlayer = mkPlayer(offCar)
vanillaCalls = {}
enabled = false

ISVehicleMenu.onHornStart(offPlayer)
eq("disabled defers to vanilla",        #vanillaCalls, 1)
eq("and plays nothing of its own",      #offCar.played, 0)
ISVehicleMenu.onHornStop(offPlayer)
eq("on stop too",                       #vanillaCalls, 2)

serverCommand("RFTDOddsAndEnds", "hornStart", { vehicle = 200 })
eq("and ignores broadcasts while off",  #offCar.played, 0)

enabled = true

print(string.format("QuietHorn: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
