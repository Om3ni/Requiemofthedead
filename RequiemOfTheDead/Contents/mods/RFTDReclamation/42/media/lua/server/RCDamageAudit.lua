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

local function val(x)
    if x == nil then return "-" end
    local s = tostring(x)
    if s == "" then return "-" end
    return s
end

-- getSteamID is a field return (IsoPlayer.java:5954); the existence check
-- covers a sender that is not an IsoPlayer.
local function steamIdOf(player)
    if not (player and player.getSteamID) then return "-" end
    local id = player:getSteamID()
    if id and tostring(id) ~= "0" then return tostring(id) end
    return "-"
end

local function write(line)
    -- guarded: file I/O through the getFileWriter allowlist can throw
    local ok, writer = pcall(getFileWriter, FILE, true, true) -- createIfNull, append (never truncate)
    if not ok or not writer then return end
    -- guarded: disk write/close; a full disk must not break the damage path
    pcall(function()
        writer:write(line .. "\n")
        writer:close()
    end)
end

local function onClientCommand(module, command, player, args)
    if module ~= "vehicle" then return end
    if not RCShared.cfg().enabled then return end
    local how = EVENTS[command]
    if not how then return end
    if not player or not args then return end

    local vehicle = nil
    if args.vehicle then
        -- args.vehicle comes off the wire: a non-number would blow the (short)
        -- cast inside getVehicleById, so the guard stays.
        local ok, v = pcall(getVehicleById, args.vehicle)
        if ok then vehicle = v end
    end

    local username = (player.getUsername and player:getUsername()) or "-"
    local key = username .. "@" .. tostring(args.vehicle)
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
    -- guarded: foreign module doing file I/O; its failure must not break ours
    pcall(function()
        RDLog.forensic("rc-damage", "RC.DAMAGE", player, {
            how = how, vehicle = vname, vid = args.vehicle,
            owner = owner, griefing = griefing == true,
            claimId = vehicle and RCClaim.getClaimId and RCClaim.getClaimId(vehicle) or nil,
            x = x, y = y, z = z, part = part, amount = args.amount,
        }, "RFTDReclamation")
    end)
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
