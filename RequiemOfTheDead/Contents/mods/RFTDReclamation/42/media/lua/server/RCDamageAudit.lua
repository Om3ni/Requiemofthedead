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

-- GMT/UTC timestamp. The leading "!" makes os.date format in UTC.
local function gmtStamp()
    local ok, s = pcall(function() return os.date("!%Y-%m-%d %H:%M:%S") end)
    if ok and s then return s .. " GMT" end
    return tostring(os.time()) .. " epoch"
end

-- Light per-(attacker,vehicle) throttle so a melee flurry doesn't write
-- hundreds of near-identical lines. One line per pair per window.
local THROTTLE_MS = 3000
local lastMs = {}
local lastCount = 0

local function throttled(key)
    local ok, now = pcall(getTimestampMs)
    if not ok or type(now) ~= "number" then return false end -- no clock: never throttle
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

local function steamIdOf(player)
    local ok, id = pcall(function() return player:getSteamID() end)
    if ok and id and tostring(id) ~= "0" then return tostring(id) end
    return "-"
end

local function write(line)
    local ok, writer = pcall(getFileWriter, FILE, true, true) -- createIfNull, append (never truncate)
    if not ok or not writer then return end
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
        local okn, n = pcall(function() return vehicle:getScriptName() end)
        vname = okn and n or nil
    end
    part = args.part

    write(string.format(
        "[%s] event=%s user=%s steam=%s vehicle=%s id=%s owner=%s griefing=%s x=%s y=%s z=%s part=%s amount=%s",
        gmtStamp(), how, val(username), steamIdOf(player),
        val(vname), val(args.vehicle), val(owner), val(griefing),
        val(x), val(y), val(z), val(part), val(args.amount)))

    -- Dual-write (RFTDCore adoption): the same observation, structured, into
    -- Core's forensic ring. claimId included when the vehicle carries one so a
    -- reader can join damage rows onto the claim timeline.
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
