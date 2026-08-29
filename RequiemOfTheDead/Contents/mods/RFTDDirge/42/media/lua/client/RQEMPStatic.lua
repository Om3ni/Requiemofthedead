-- SPDX-License-Identifier: GPL-3.0-or-later
-- RQEMPStatic - radios and televisions caught in an EMP blast play nothing but
-- static until someone switches them off and on again.
--
-- WHY THIS IS CLIENT-SIDE AND NOT A SERVER EFFECT. Device audio is presentation,
-- not replicated state: DeviceData.updateEmitter opens with
-- `if (GameServer.server) return;` (DeviceData.java:685-688). The server has no
-- device audio to change and no way to push one - the sibling fix in
-- RQSvShared.svDamageWorldElectronics documents that dead end at length. Here
-- there is nothing to push: every client renders its own devices, so each one
-- applies this to its own copy off the detonation broadcast it already
-- receives. No packets, no authority question, no desync to prevent.
--
-- WHY IT SHIPS NO SOUND FILE. The engine already owns a "device is on but
-- receiving nothing" state and the whole presentation for it. updateEmitter
-- picks its loop off ONE variable (DeviceData.java:715-738):
--
--     signalCounter >  0  -> RadioTalk / BroadcastEmergency / VehicleRadioProgram
--     signalCounter <= 0  -> RadioStatic, TelevisionTestBeep in a set,
--                            VehicleRadioStatic in a car
--
-- and it fires a RadioZap transition on the way in. So this does not author an
-- effect; it puts devices into an effect the engine already has, which is why
-- there is no .ogg in this mod for it and should not be one.
--
-- HOW, given signalCounter is unreachable. It is a `protected float` with no
-- getter and no setter (:108), and Kahlua exposes methods but never instance
-- fields - so it cannot be written from Lua at all. It is fed by the CHANNEL:
-- set to 300 when a transmission arrives on the device's current frequency
-- (:897) and decaying ~1.25 per update otherwise (:791-792). Retune the device
-- to a frequency nothing broadcasts on and the counter drains on its own, over
-- roughly four seconds, and the engine drops the device into static by itself.
-- The program fading into hiss rather than cutting dead is a better EMP than
-- anything we would have written.
--
-- setChannelRaw (:556) is the exact primitive: it assigns the channel and does
-- NOTHING else. Compare setChannel (:531-554), which range-checks, plays a zap,
-- stops the loop sound, and calls transmitDeviceDataState((short)1). We want
-- none of those - especially not the transmit, which would make one client's
-- presentation everyone's state.
--
-- TWO PROPERTIES FALL OUT OF THAT, both load-bearing:
--   * The server's authoritative channel is never touched. A chunk streaming
--     out and back in restores the true frequency for free, because the client
--     rebuilds DeviceData from the server's copy, which never learned about us.
--   * A player can always recover manually. The radio UI tunes through
--     setChannel, which range-checks and accepts any legal frequency, so a
--     scrambled device is never soft-locked.
--
-- KNOWN AND ACCEPTED: the radio window reads getChannel(), so an EMP'd device
-- shows a frequency that does not match the server's. Owner call 2026-08-27 -
-- a scrambled dial IS the fiction here, and the alternative is not having the
-- effect at all.

RQEMPStatic = RQEMPStatic or {}

-- How often the power-cycle watch runs. This is a poll rather than a hook
-- because the engine raises no event for a device being switched on, and it is
-- throttled off the wall clock rather than a tick count because OnTick sags
-- under load - the same reason RQSvShared.due exists.
local POLL_MS = 500

-- Ceiling on tracked devices. A blast radius holds a handful, but a server can
-- run many EMPs before anyone power-cycles anything, and an unbounded registry
-- of stale object references is how a client leaks for a session. On overflow
-- the OLDEST entry is restored and dropped rather than abandoned - dropping a
-- scrambled device without restoring it would strand it on dead air with
-- nothing left that knows to fix it.
local MAX_TRACKED = 32

-- device -> tracking row, kept as an array because Kahlua has no next() and
-- this is walked in order anyway.
local tracked = {}
local lastPoll = 0

-- A frequency nothing can be broadcasting on. One below the device's own
-- minimum is the strongest guarantee available without enumeration: a station
-- outside the tunable range would be one no player could ever legally tune to,
-- so nothing is put there. Enumeration is not available - ZomboidRadio's
-- GetChannelList and getFullChannelList both return java.util.Map
-- (ZomboidRadio.java:161, 186), and Kahlua cannot iterate a Java collection.
local function deadChannel(dd)
    local min = dd:getMinChannelRange()
    if type(min) ~= "number" then return nil end
    return min - 1
end

local function restore(row)
    -- Only put the original frequency back if the dial is still where we left
    -- it. If it reads anything else, someone re-tuned this device after the
    -- blast - by hand, or from another client through a type-1 packet - and
    -- their choice outranks our bookkeeping.
    if row.device:getChannel() == row.scrambled then
        row.device:setChannelRaw(row.original)
    end
end

local function forget(index, alsoRestore)
    local row = tracked[index]
    if not row then return end
    if alsoRestore then restore(row) end
    table.remove(tracked, index)
end

-- Puts every powered radio and television in the blast onto dead air.
function RQEMPStatic.scramble(x, y, z, radius)
    local cell = getCell()
    if not cell then return 0 end

    local rSq = radius * radius
    local hit = 0
    for dx = -radius, radius do
        for dy = -radius, radius do
            if dx * dx + dy * dy <= rSq then
                local sq = cell:getGridSquare(x + dx, y + dy, z)
                if sq then
                    local objects = sq:getObjects()
                    if objects then
                        for oi = 0, objects:size() - 1 do
                            local obj = objects:get(oi)
                            -- One test covers both: IsoTelevision and IsoRadio
                            -- both extend IsoWaveSignal, which is where
                            -- getDeviceData lives (IsoWaveSignal.java:142).
                            if obj and instanceof(obj, "IsoWaveSignal") then
                                if RQEMPStatic.scrambleDevice(obj) then
                                    hit = hit + 1
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    RQDirgeLog.write("EMP", "[INFO] static scramble at (" .. x .. "," .. y .. "," .. z .. ")"
        .. " radius=" .. radius .. " devices=" .. hit .. " tracked=" .. #tracked)
    return hit
end

-- Split out so the fixture can drive one device without building a world, and
-- so the "should this device be touched at all" rules live in one place.
function RQEMPStatic.scrambleDevice(obj)
    local dd = obj:getDeviceData()
    if not dd then return false end

    -- A device that is already off has no audio to change and, more to the
    -- point, would give us no power-cycle to watch for: it is already in the
    -- state the restore is waiting on, so it would snap back the instant the
    -- player switched it on to listen. Leave it alone.
    if not dd:getIsTurnedOn() then return false end

    -- Already scrambled by an earlier blast. Re-scrambling would overwrite the
    -- stored original with our own dead frequency and strand the device there
    -- permanently - the one way this feature could do lasting harm.
    for i = 1, #tracked do
        if tracked[i].device == dd then return false end
    end

    local dead = deadChannel(dd)
    if not dead then return false end

    local original = dd:getChannel()
    if type(original) ~= "number" then return false end

    dd:setChannelRaw(dead)
    if #tracked >= MAX_TRACKED then forget(1, true) end
    tracked[#tracked + 1] = {
        device    = dd,
        original  = original,
        scrambled = dead,
        sawOff    = false,
    }
    return true
end

-- The power cycle. `sawOff` has to latch before a restore can fire, so merely
-- being on is not enough - the device has to go off and come back, which is
-- exactly what the player is told to do. A blast that kills the generator
-- supplies the off half by itself (the engine turns unpowered devices off in
-- DeviceData.update:773-780), so "the lights came back and I flipped the radio
-- on" restores it too, with no special case here.
local function poll()
    local now = getTimestampMs()
    if now - lastPoll < POLL_MS then return end
    lastPoll = now

    local i = 1
    while i <= #tracked do
        local row = tracked[i]
        local on  = row.device:getIsTurnedOn()
        if on == nil then
            -- The device went out of scope with its chunk. Drop the row without
            -- restoring: the client rebuilds DeviceData from the server's copy
            -- on reload, and the server's channel never changed, so the true
            -- frequency is already back.
            table.remove(tracked, i)
        elseif not on then
            row.sawOff = true
            i = i + 1
        elseif row.sawOff then
            forget(i, true)
        else
            i = i + 1
        end
    end
end

Events.OnTick.Add(poll)

-- Test seam. Nothing in the mod calls these; they exist so the fixture can
-- assert the registry empties and the poll is not holding references.
function RQEMPStatic.trackedCount()
    return #tracked
end

function RQEMPStatic.reset()
    for i = #tracked, 1, -1 do
        table.remove(tracked, i)
    end
    lastPoll = 0
end

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
