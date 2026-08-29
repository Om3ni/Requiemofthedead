-- RQEMPStatic fixture - EMP'd radios and TVs sit on dead air until power-cycled.
--
-- The properties worth pinning here are the ones that would do lasting harm if
-- they broke quietly: the stored original frequency must survive a second
-- blast, a restore must never overwrite someone else's retune, and the registry
-- must not grow without bound or strand a device it evicts. None of those are
-- visible in game until a player complains that their radio never came back.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDirge/42/media/lua/client/RQEMPStatic.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL RQEMPStatic: " .. message)
    end
end

local tickCallbacks = {}
Events = { OnTick = { Add = function(fn) tickCallbacks[#tickCallbacks + 1] = fn end } }

local logs = {}
RQDirgeLog = { write = function(_, line) logs[#logs + 1] = line end }

local nowMs = 0
function getTimestampMs() return nowMs end
function instanceof(obj, className) return obj and obj.className == className end

-- A device stands in for DeviceData: the four methods RQEMPStatic actually
-- calls, each matching the verified engine surface. setChannelRaw assigns and
-- does nothing else (DeviceData.java:556-558) - if this fixture ever grows a
-- transmit side effect it is modelling the WRONG method, which is the mistake
-- the shipped code exists to avoid.
local function makeDevice(channel, on, minRange)
    local d = {
        channel = channel,
        on      = on,
        min     = minRange or 8800,
    }
    d.getChannel          = function(self) return self.channel end
    d.setChannelRaw       = function(self, c) self.channel = c end
    d.getIsTurnedOn       = function(self) return self.on end
    d.getMinChannelRange  = function(self) return self.min end
    return d
end

local function makeRadio(device)
    return { className = "IsoWaveSignal", getDeviceData = function() return device end }
end

local worldObjects = {}
local function javaList(items)
    return {
        size = function() return #items end,
        get  = function(_, i) return items[i + 1] end,
    }
end
local blastSquare = { getObjects = function() return javaList(worldObjects) end }
function getCell()
    return { getGridSquare = function() return blastSquare end }
end

local function runPoll()
    for i = 1, #tickCallbacks do tickCallbacks[i]() end
end

RQEMPStatic = nil
local ok, err = pcall(dofile, SOURCE)
check(ok, "module loads: " .. tostring(err))
check(#tickCallbacks == 1, "the power-cycle watch registers exactly one tick handler")

-- ---------------------------------------------------------------------------
-- Scrambling one device
-- ---------------------------------------------------------------------------
local radio = makeDevice(9600, true)
check(RQEMPStatic.scrambleDevice(makeRadio(radio)) == true,
    "a powered device is scrambled")
check(radio.channel == 8799,
    "the dead frequency is one below the device's own minimum, where nothing can broadcast")
check(RQEMPStatic.trackedCount() == 1, "the scrambled device is tracked for restore")

-- A second blast must NOT re-scramble: storing 8799 as the "original" would
-- strand the device on dead air permanently.
check(RQEMPStatic.scrambleDevice(makeRadio(radio)) == false,
    "an already-scrambled device is refused a second time")
check(RQEMPStatic.trackedCount() == 1, "a refused re-scramble does not add a second row")

-- ---------------------------------------------------------------------------
-- The power cycle
-- ---------------------------------------------------------------------------
nowMs = 1000
runPoll()
check(radio.channel == 8799 and RQEMPStatic.trackedCount() == 1,
    "a device left switched on stays on static")

radio.on = false
nowMs = 2000
runPoll()
check(radio.channel == 8799 and RQEMPStatic.trackedCount() == 1,
    "switching off alone does not restore - the cycle is not complete")

radio.on = true
nowMs = 3000
runPoll()
check(radio.channel == 9600, "off and on again restores the original frequency")
check(RQEMPStatic.trackedCount() == 0, "a restored device is no longer tracked")

-- ---------------------------------------------------------------------------
-- The poll is throttled off the wall clock
-- ---------------------------------------------------------------------------
RQEMPStatic.reset()
local throttled = makeDevice(9600, true)
RQEMPStatic.scrambleDevice(makeRadio(throttled))
nowMs = 10000
runPoll()
throttled.on = false
nowMs = 10100          -- inside POLL_MS of the previous run
runPoll()
throttled.on = true
nowMs = 10200
runPoll()
check(throttled.channel == 8799 and RQEMPStatic.trackedCount() == 1,
    "a cycle that happens entirely inside one poll window is not observed")

-- ---------------------------------------------------------------------------
-- Someone else's retune outranks our bookkeeping
-- ---------------------------------------------------------------------------
RQEMPStatic.reset()
local retuned = makeDevice(9600, true)
RQEMPStatic.scrambleDevice(makeRadio(retuned))
retuned.channel = 10500        -- a player tuned it by hand after the blast
retuned.on = false
nowMs = 20000
runPoll()
retuned.on = true
nowMs = 21000
runPoll()
check(retuned.channel == 10500,
    "a restore never overwrites a frequency someone chose after the blast")
check(RQEMPStatic.trackedCount() == 0, "the row is still released after a declined restore")

-- ---------------------------------------------------------------------------
-- Devices that leave scope
-- ---------------------------------------------------------------------------
RQEMPStatic.reset()
local unloaded = makeDevice(9600, true)
RQEMPStatic.scrambleDevice(makeRadio(unloaded))
unloaded.getIsTurnedOn = function() return nil end   -- chunk streamed out
nowMs = 30000
runPoll()
check(RQEMPStatic.trackedCount() == 0,
    "a device whose chunk unloaded is dropped rather than held forever")

-- ---------------------------------------------------------------------------
-- The registry is bounded, and eviction restores rather than strands
-- ---------------------------------------------------------------------------
RQEMPStatic.reset()
local first = makeDevice(9600, true)
RQEMPStatic.scrambleDevice(makeRadio(first))
for _ = 1, 31 do
    RQEMPStatic.scrambleDevice(makeRadio(makeDevice(9600, true)))
end
check(RQEMPStatic.trackedCount() == 32, "the registry fills to its ceiling")
check(first.channel == 8799, "the oldest entry is still scrambled at the ceiling")

RQEMPStatic.scrambleDevice(makeRadio(makeDevice(9600, true)))
check(RQEMPStatic.trackedCount() == 32, "the registry never exceeds its ceiling")
check(first.channel == 9600,
    "an evicted device is restored, never abandoned on dead air")

-- ---------------------------------------------------------------------------
-- Devices the blast should not touch
-- ---------------------------------------------------------------------------
RQEMPStatic.reset()
local alreadyOff = makeDevice(9600, false)
check(RQEMPStatic.scrambleDevice(makeRadio(alreadyOff)) == false,
    "a device that is already off is left alone")
check(alreadyOff.channel == 9600 and RQEMPStatic.trackedCount() == 0,
    "skipping an off device changes nothing and tracks nothing")

local noData = { className = "IsoWaveSignal", getDeviceData = function() return nil end }
check(RQEMPStatic.scrambleDevice(noData) == false, "an object with no device data is skipped")

-- ---------------------------------------------------------------------------
-- The world walk
-- ---------------------------------------------------------------------------
RQEMPStatic.reset()
local a, b = makeDevice(9600, true), makeDevice(9700, true)
local generator = { className = "IsoGenerator" }
worldObjects = { makeRadio(a), generator, makeRadio(b) }
local hit = RQEMPStatic.scramble(10, 20, 0, 0)
check(hit == 2, "the walk scrambles every wave-signal device and ignores the rest")
check(a.channel == 8799 and b.channel == 8799, "both devices land on dead air")
check(logs[#logs]:find("devices=2", 1, true) ~= nil,
    "the scramble reports how many devices it took, not merely that it ran")

print("RQEMPStatic: " .. passed .. " passed, " .. failed .. " failed")
os.exit(failed == 0 and 0 or 1)
