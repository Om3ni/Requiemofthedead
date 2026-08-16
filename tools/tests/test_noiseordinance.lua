-- test_noiseordinance.lua - behavioural tests for Noise Ordinance under Lua 5.1.
--
-- WHAT THIS PINS. The module exists because BaseVehicle.onHornStart() sets the
-- horn flag AND calls WorldSoundManager.addSound(..., 150, 150, ...) in the same
-- method, and nothing in the engine lets a mod ask for one without the other:
-- hornEnable is a public field with no setter on a struct Kahlua cannot write,
-- and WorldSoundManager has no removal call. So the module's whole correctness
-- rests on ONE property:
--
--   the engine's onHornStart must never be called while Noise Ordinance is on.
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
--   lua5.1.exe tools/tests/test_noiseordinance.lua <repo-root>

local ROOT = arg[1] or "."
local SRC  = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDOddsAndEnds"
             .. "/42/media/lua/client/NoiseOrdinance/NOClient.lua"
local SERVER_SRC = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDOddsAndEnds"
                   .. "/42/media/lua/server/NoiseOrdinance/NOServer.lua"
local SIREN_SRC = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDOddsAndEnds"
                  .. "/42/media/lua/shared/NoiseOrdinance/NOSirenPolicy.lua"

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
local serverMode = false
isServer = function() return serverMode end

local clientMode = true
isClient = function() return clientMode end

local now = 1000
getTimestampMs = function() return now end

local enabled = true
local enabledFlag
OEShared = {
    MODULE  = "RFTDOddsAndEnds",
    enabled = function(flag)
        enabledFlag = flag
        return enabled
    end,
}

local sent = {}
local registered, broadcasts = {}, {}
RDNet = {
    send = function(module, command, args)
        sent[#sent + 1] = { module = module, command = command, args = args }
    end,
    register = function(module, command, opts, handler)
        registered[module .. "." .. command] = { opts = opts, handler = handler }
    end,
    broadcast = function(module, command, args)
        broadcasts[#broadcasts + 1] = { module = module, command = command, args = args }
    end,
}

local tickHandlers, serverCommandHandlers = {}, {}
local gameStartHandlers, serverStartedHandlers = {}, {}
Events = {
    OnTick          = { Add = function(f) tickHandlers[#tickHandlers + 1] = f end },
    OnServerCommand = { Add = function(f) serverCommandHandlers[#serverCommandHandlers + 1] = f end },
    OnGameStart     = { Add = function(f) gameStartHandlers[#gameStartHandlers + 1] = f end },
    OnServerStarted = { Add = function(f) serverStartedHandlers[#serverStartedHandlers + 1] = f end },
}

-- The originals Noise Ordinance captures. Reaching either means the kill
-- switch handed control back to vanilla, which is only correct when off.
local vanillaCalls = {}
ISVehicleMenu = {
    onHornStart = function() vanillaCalls[#vanillaCalls + 1] = "start" end,
    onHornStop  = function() vanillaCalls[#vanillaCalls + 1] = "stop" end,
}

-- A vehicle that distinguishes the local-only FMOD methods from their
-- network-capable counterparts. The old harness gave both paths the same fake,
-- which is how playSoundLooped's hidden PlayWorldSound packet escaped review.
local nextHandle = 0
local vehicles = {}

local function mkVehicle(id, scriptName, hasHorn)
    local v = {
        id = id, scriptName = scriptName, horn = hasHorn ~= false,
        engineHornCalls = 0, played = {}, stopped = {}, live = nil,
        networkedStarts = 0, networkedStops = 0,
    }
    function v:getId() return self.id end
    function v:getScriptName() return self.scriptName end
    function v:getScript() return self.scriptName and {} or nil end
    function v:hasHorn() return self.horn end
    function v:isDriver() return true end
    -- The method the whole module exists to avoid.
    function v:onHornStart() self.engineHornCalls = self.engineHornCalls + 1 end
    function v:onHornStop()  self.engineHornCalls = self.engineHornCalls + 1 end
    function v:getEmitter()
        local owner = self
        return {
            playSoundLooped = function()
                owner.networkedStarts = owner.networkedStarts + 1
                return 0
            end,
            playSoundLoopedImpl = function(_, name)
                nextHandle = nextHandle + 1
                owner.played[#owner.played + 1] = name
                owner.live = nextHandle
                return nextHandle
            end,
            stopSound = function()
                owner.networkedStops = owner.networkedStops + 1
                return 0
            end,
            stopSoundLocal = function(_, handle)
                owner.stopped[#owner.stopped + 1] = handle
                owner.live = nil
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

local NoiseOrdinance = dofile(SRC)
ok("NOClient loads and returns its table", type(NoiseOrdinance) == "table")
ok("it took over onHornStart", ISVehicleMenu.onHornStart ~= nil)
ok("it registered a tick reaper", #tickHandlers == 1)
ok("it listens for other players' horns", #serverCommandHandlers == 1)

-- ---------------------------------------------------------------------------
-- The property the module exists for
-- ---------------------------------------------------------------------------

local car = mkVehicle(1, "Base", true)
local player = mkPlayer(car)

ISVehicleMenu.onHornStart(player)
eq("it reads the renamed sandbox key",          enabledFlag, "NoiseOrdinanceEnable")
eq("the engine horn is never called on start", car.engineHornCalls, 0)
eq("but a horn is played",                     #car.played, 1)
eq("the networked sound start is never used",  car.networkedStarts, 0)
eq("and vanilla is not consulted",             #vanillaCalls, 0)

ISVehicleMenu.onHornStop(player)
eq("the engine horn is never called on stop", car.engineHornCalls, 0)
eq("and the sound is stopped",                #car.stopped, 1)
eq("the networked sound stop is never used",  car.networkedStops, 0)
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

-- ---------------------------------------------------------------------------
-- Server-owned lease
--
-- A disconnect has no server Lua event in 42.20.2. Not sending hornStop is the
-- deterministic reproduction: the lease must still broadcast a stop.
-- ---------------------------------------------------------------------------

serverMode = true
tickHandlers = {}
registered = {}
broadcasts = {}
now = 100000

local NoiseOrdinanceSv = dofile(SERVER_SRC)
ok("NOServer loads and returns its table", type(NoiseOrdinanceSv) == "table")
ok("it registers hornStart", registered["RFTDOddsAndEnds.hornStart"] ~= nil)
ok("it registers hornStop", registered["RFTDOddsAndEnds.hornStop"] ~= nil)
eq("it registers one lease reaper", #tickHandlers, 1)

local serverCar = mkVehicle(300, "Base", true)
local serverPlayer = {
    getUsername = function() return "lease-test" end,
    getVehicle = function() return serverCar end,
}

registered["RFTDOddsAndEnds.hornStart"].handler(serverPlayer, {})
eq("server start broadcasts once", #broadcasts, 1)
eq("server broadcasts hornStart", broadcasts[1].command, "hornStart")
eq("server broadcasts the authoritative vehicle", broadcasts[1].args.vehicle, 300)
eq("server never invokes the engine horn", serverCar.engineHornCalls, 0)

now = now + 9000
tick()
eq("the server lease survives before its deadline", #broadcasts, 1)

-- Simulated disconnect: no hornStop command arrives.
now = now + 1001
tick()
eq("a disconnected horn gets an authoritative stop", #broadcasts, 2)
eq("the lease expiry broadcasts hornStop", broadcasts[2].command, "hornStop")
eq("the lease expiry stops the right vehicle", broadcasts[2].args.vehicle, 300)

-- A normal stop must clear the lease so the reaper cannot emit a duplicate.
broadcasts = {}
now = 200000
registered["RFTDOddsAndEnds.hornStart"].handler(serverPlayer, {})
registered["RFTDOddsAndEnds.hornStop"].handler(serverPlayer, {})
eq("a normal stop follows its start", #broadcasts, 2)
eq("a normal stop broadcasts hornStop", broadcasts[2].command, "hornStop")
now = now + 20000
tick()
eq("a released lease does not stop twice", #broadcasts, 2)

-- ---------------------------------------------------------------------------
-- Siren policy
--
-- Both loaded and virtualized vehicles consult the native
-- SirenEffectsZombies option before creating a repeating WorldSound. Noise
-- Ordinance owns that value only while enabled and restores the prior policy.
-- ---------------------------------------------------------------------------

clientMode = false
tickHandlers = {}
gameStartHandlers = {}
serverStartedHandlers = {}
enabled = true

local sirenOption = { value = true, writes = {} }
function sirenOption:getValue() return self.value end
function sirenOption:setValue(value)
    self.value = value
    self.writes[#self.writes + 1] = value
end

getSandboxOptions = function()
    return {
        getOptionByName = function(_, name)
            if name == "SirenEffectsZombies" then return sirenOption end
        end,
    }
end

local NoiseOrdinanceSirenPolicy = dofile(SIREN_SRC)
ok("NOSirenPolicy loads and returns its table", type(NoiseOrdinanceSirenPolicy) == "table")
eq("it waits for world startup before ticking", #tickHandlers, 0)
eq("it registers for singleplayer startup", #gameStartHandlers, 1)
eq("it registers for server startup", #serverStartedHandlers, 1)

serverStartedHandlers[1]()
eq("startup installs one policy tick", #tickHandlers, 1)
eq("enabled disables siren attraction", sirenOption.value, false)

gameStartHandlers[1]()
eq("a second startup event does not double-register", #tickHandlers, 1)

enabled = false
tick()
eq("disabled restores the prior native siren policy", sirenOption.value, true)

-- While dormant, deliberate native changes become the next restore target.
sirenOption.value = false
tick()
enabled = true
tick()
enabled = false
tick()
eq("it restores the latest dormant native policy", sirenOption.value, false)

print(string.format("NoiseOrdinance: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
