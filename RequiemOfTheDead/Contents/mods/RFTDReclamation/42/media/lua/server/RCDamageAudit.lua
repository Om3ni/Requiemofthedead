-- SPDX-License-Identifier: GPL-3.0-or-later
-- RCDamageAudit - forensic vehicle-damage log (server only, write-only).
--
-- We cannot VETO vehicle damage in Lua: it is server-applied through the
-- vanilla 'vehicle' client-commands (VehicleCommands.lua), whose Commands
-- table is file-local - no handle to wrap. What we CAN do is OBSERVE those
-- commands with our own OnClientCommand listener and write a durable line.
-- (This is a separate listener from RCServer's dispatcher; it watches the
-- vanilla "vehicle" module, not ours - so the single-dispatcher house rule
-- for OUR module is intact.)
--
-- The log is APPEND-ONLY and never read at runtime - pure forensics for an
-- admin to grep after a grief report. Each line records:
--   GMT time . event(how) . attacker username + Steam ID . target vehicle +
--   claim owner . a griefing flag . world coordinates.
--
-- "player" in OnClientCommand is the command SENDER = the attacker.

if not isServer() then return end

RCDamageAudit = RCDamageAudit or {}

local FILE = "RFTDReclamation_Damage.txt"

-- The player-sourced damage commands worth logging. damageFromHitChr is
-- excluded: it is the driver's OWN vehicle taking damage from running into a
-- character (normal gameplay), not griefing another player's car.
local EVENTS = {
    damageWindow = "window-smash", -- melee vandalism of a window
    crash        = "crash",        -- collision / ramming
}

-- GMT/UTC timestamp. The leading "!" makes os.date format in UTC. A fixed
-- all-numeric format is plain Calendar reads in Kahlua (OsLib.java:110/149).
local function gmtStamp()
    return os.date("!%Y-%m-%d %H:%M:%S") .. " GMT"
end

-- Light per-(attacker,vehicle) throttle so a melee flurry doesn't write
-- hundreds of near-identical lines. One line per pair per window.
local THROTTLE_MS = 3000
local lastMs = {}
local lastCount = 0

local function throttled(key)
    local now = getTimestampMs() -- System.currentTimeMillis (LuaManager.java:7470)
    if type(now) ~= "number" then return false end -- no clock: never throttle
    local prev = lastMs[key]
    if prev and (now - prev) < THROTTLE_MS then return true end
    lastMs[key] = now
    -- crude bound: wipe the table if it grows large (it's only a dedup cache)
    lastCount = lastCount + 1
    if lastCount > 500 then lastMs = {}; lastCount = 0 end
    return false
end

-- Delegates to the family ledger sanitiser. This used to be a bare tostring
-- with an empty-string default, which meant a newline inside args.vehicle,
-- args.part or args.amount forged arbitrary complete lines in the damage
-- ledger - including lines carrying somebody else's user= and steam=. That
-- ledger is what an admin reads to adjudicate a griefing report, so a forgeable
-- line was worse than no line at all.
local function val(x)
    return RCShared.ledgerSafe(x)
end

-- getSteamID is a field return (IsoPlayer.java:5954); the existence check
-- covers a sender that is not an IsoPlayer.
local function steamIdOf(player)
    if not (player and player.getSteamID) then return "-" end
    local id = player:getSteamID()
    if id and tostring(id) ~= "0" then return tostring(id) end
    return "-"
end

-- No guards, same reading as RCAudit: getFileWriter returns nil rather than
-- throwing (LuaManager.java:5523-5555), and LuaFileWriter.write/close delegate
-- to PrintWriter, which records I/O errors internally rather than raising
-- (:9850-9868). "A full disk must not break the damage path" described a throw
-- that cannot happen.
local function write(line)
    local writer = getFileWriter(FILE, true, true) -- createIfNull, append (never truncate)
    if not writer then return end
    writer:write(line .. "\n")
    writer:close()
end

local function onClientCommand(module, command, player, args)
    if module ~= "vehicle" then return end
    if not RCShared.cfg().enabled then return end
    local how = EVENTS[command]
    if not how then return end
    if not player or not args then return end

    -- Wire value VALIDATED rather than guarded: getVehicleById takes an int
    -- (LuaManager.java:8208-8211), so a non-number fails the Kahlua coercion at
    -- the call boundary and tonumber() answers it deterministically. A bad id
    -- leaves `vehicle` nil, which every branch below already handles - the
    -- audit line still gets written, which matters, because a damage event with
    -- an unresolvable vehicle id is exactly the shape a spoofed packet has.
    local vid = tonumber(args.vehicle)
    local vehicle = vid and getVehicleById(vid) or nil

    -- Key on the RESOLVED id, not the raw wire string. The throttle is the only
    -- volume control on this file writer - this listener sits on vanilla's
    -- "vehicle" token rather than RCServer's dispatcher, so RDRate never runs on
    -- it - and keying on tostring(args.vehicle) meant "1", "1.0", " 1", "0x1"
    -- and any unresolvable garbage each opened a fresh bucket, one written line
    -- per packet. Unresolvable ids still get audited (see the note above), but
    -- they now share ONE bucket instead of minting a new one per spelling.
    local username = (player.getUsername and player:getUsername()) or "-"
    local key = username .. "@" .. (vid and tostring(vid) or "?")
    if throttled(key) then return end

    local owner, griefing, x, y, z, vname, part
    if vehicle then
        owner    = RCClaim.getOwner(vehicle)
        griefing = not RCClaim.canInteract(vehicle, player) -- true => no rights to this car
        x = math.floor(vehicle:getX()); y = math.floor(vehicle:getY()); z = math.floor(vehicle:getZ())
        vname = vehicle:getScriptName() -- field return (BaseVehicle.java:1593)
    end
    part = args.part

    write(string.format(
        "[%s] event=%s user=%s steam=%s vehicle=%s id=%s owner=%s griefing=%s x=%s y=%s z=%s part=%s amount=%s",
        gmtStamp(), how, val(username), steamIdOf(player),
        val(vname), val(args.vehicle), val(owner), val(griefing),
        val(x), val(y), val(z), val(part), val(args.amount)))

    -- Dual-write (RFTDCore adoption): the same observation, structured, into
    -- Core's forensic archive. claimId included when the vehicle carries one so a
    -- reader can join damage rows onto the claim timeline.
    -- Bare. "Foreign module" was wrong twice over: RDLog is Core, which this
    -- mod hard-requires, and its forensic path is total for a scalar payload
    -- - buffered push, nil-safe writer, and the tally hook carries its own
    -- boundary inside RDLog. A real fault in it would be our bug and should
    -- be loud, not absorbed here after the primary write() already landed.
    RDLog.forensic("rc-damage", "RC.DAMAGE", player, {
        how = how, vehicle = vname, vid = args.vehicle,
        owner = owner, griefing = griefing == true,
        claimId = vehicle and RCClaim.getClaimId and RCClaim.getClaimId(vehicle) or nil,
        x = x, y = y, z = z, part = part, amount = args.amount,
    }, "RFTDReclamation")
end

Events.OnClientCommand.Add(onClientCommand)

print("[RC] RCDamageAudit loaded (vehicle-damage log -> " .. FILE .. ")")

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
