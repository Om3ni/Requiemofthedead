-- SPDX-License-Identifier: GPL-3.0-or-later
-- RCJanitor - reclaims ABANDONED vehicles and feeds the token pools (§5).
--
-- The economy's PRIMARY fuel (DESIGN §0): on a big server the high-volume,
-- self-replenishing input is players going inactive - their claims expire,
-- the cars sit as unclaimed husks, the Janitor reclaims them into respawn
-- tokens. Server-confirmed destruction and field dismantle are smaller side
-- channels; wrecks themselves are NEVER touched.
--
-- THE PRESENCE LAW (owner's rule, 2026-07-03): abandonment is a property of
-- the PLAYER, not the object. "If the player logs in, their stuff is
-- preserved" - they do not have to touch it. So the layers are:
--   * CLAIMED: held by the claim system (owner login within
--     ClaimInactivityDays refreshes ALL claims). Janitor never looks.
--   * UNCLAIMED, ATTRIBUTED (RC_LastUser known): held as long as that player
--     has been online within JanitorAbandonDays. Logging in is the gate -
--     the "log in to keep your things" ritual every survival game teaches.
--   * UNCLAIMED, NO KNOWN USER: nobody's stuff - world loot. Reclaimed after
--     JanitorAbandonDays without any observed use.
--
-- ATTRIBUTION is free and event-driven: every benign vanilla 'vehicle'
-- client-command names BOTH the acting player and the vehicle (engine start,
-- doors, trunk lock, horn, keys, headlights, towing...), so we listen on
-- that channel (the RCDamageAudit pattern) and stamp RC_LastUser. Damage
-- commands are excluded - a vandal smashing your windshield must not become
-- its keeper. HOTWIRING and raw driving send NO 'vehicle' command, so a
-- driver-entry relay (RCUsage -> 'used') attributes those too - otherwise a
-- player who lost the key and hotwired a car was never attributed and the
-- Janitor reclaimed their daily driver. The hourly sweep also attributes
-- anyone in the driver's seat at sweep time.
--
-- Usage clock (fallback for the unattributed): a signature of parked tile +
-- fuel + occupancy, sampled by the existing hourly pass; any change restarts
-- the clock. All stamps live in the vehicle's own modData (RC_LastSeen /
-- RC_JanSig / RC_JanDt / RC_LastUser) - they survive chunk unloads and
-- restarts and are NEVER transmitted (server-side bookkeeping, zero network).
--
-- Fairness + safety rails:
--   * a released/expired claim clears ALL janitor fields -> fresh clock,
--     unattributed. Deliberate release = giving the car back to the world;
--     if the releaser keeps using it, attribution re-catches them anyway.
--   * server downtime is credited (presence map is shifted on boot; vehicle
--     stamps subtract the cumulative-downtime delta on read)
--   * PhunZones "No Vehicle Dismantle" zones shield their vehicles
--   * SAFEHOUSE vehicles are never reclaimed (vanilla safehouse expiry
--     decides when that shield ends)
--   * per-sweep budget (JanitorFeedsBudget) bounds work + token mint rate
--   * loot is NEVER vaporized: contents dump to the ground before removal
-- Rides RCSession's EXISTING hourly pass - no new timer, no second scan.

if not isServer() then return end

RCJanitor = RCJanitor or {}

local KEY_SEEN = "RC_LastSeen" -- real-epoch stamp of last observed use
local KEY_SIG  = "RC_JanSig"   -- usage signature at stamp time
local KEY_DT   = "RC_JanDt"    -- RCRegistry.downtimeTotal() at stamp time
local KEY_USER = "RC_LastUser" -- username the vehicle is attributed to

local budget = 0

-- Rounded fuel litres in the tank - driving burns fuel, so this catches a
-- car that was used and re-parked on the exact same tile.
local function fuelInt(vehicle)
    local tank = vehicle:getPartById("GasTank")
    if not tank then return 0 end
    return math.floor((tank:getContainerContentAmount() or 0) + 0.5)
end

-- Driver first (the person USING it), any occupant as fallback.
-- This is also the janitor's whole occupancy test: a nil return is "nobody
-- who counts is aboard". A seat-scan predicate stood beside it until
-- 2026-08-27 with no callers - occupancy only ever matters here as an
-- attribution, never as a bare boolean.
local function occupantName(vehicle)
    local d = vehicle:getDriver()
    if d and d.getUsername then
        local name = d:getUsername()
        if name then return name end
    end
    local script = vehicle:getScript()
    local seats = script and script:getPassengerCount() or 0
    for s = 0, seats - 1 do
        local ch = vehicle:getCharacter(s)
        if ch and ch.getUsername then
            local name = ch:getUsername()
            if name then return name end
        end
    end
    return nil
end

local function signature(vehicle)
    local x = math.floor(vehicle:getX())
    local y = math.floor(vehicle:getY())
    local z = math.floor(vehicle:getZ())
    return string.format("%d:%d:%d:%d", x, y, z, fuelInt(vehicle))
end

-- Called by RCSession at the top of each hourly pass.
function RCJanitor.beginSweep()
    local b = RCShared.cfg().janitorBudget
    budget = (type(b) == "number" and b > 0) and b or 3
end

local function reclaim(vehicle, lastUser)
    local report = {}
    report.vehicle = vehicle:getScriptName()
    report.x = math.floor(vehicle:getX())
    report.y = math.floor(vehicle:getY())
    report.z = math.floor(vehicle:getZ())
    report.trailer = RCShared.isTrailer(vehicle)

    -- No guard. dumpVehicleContainers is OURS, and it already owns the only
    -- boundary in there: it returns 0 for a nil vehicle or square, nil-checks
    -- every part and container, and wraps the one operation that actually
    -- throws - the per-item drop - in its own per-item guard (RCShared.lua:415).
    -- Wrapping a function whose throwing step is already isolated adds no
    -- granularity, and the outer guard could only have converted a partial dump
    -- into a reported-as-zero one.
    local dumped = RCShared.dumpVehicleContainers(vehicle)

    -- We ARE the server: permanentlyRemove() here is the authoritative call
    -- (the same one VehicleCommands.remove makes) and propagates to clients.
    -- The NPE sites the old pcall named (BaseVehicle.java:7127, :7148, :7158,
    -- :7220) are Java BODY throws in an exposed method - swallowed and
    -- stack-traced by MethodCaller (MethodCaller.java:33-56) - so `removed`
    -- was always true and the skip branch below had never once run. The
    -- postcondition replaces it with the first REAL check this sweep has had:
    -- a successful teardown sets removedFromWorld at :7146 and drops cell
    -- membership at :7177 (HashSet is exposed, LuaManager.java:1667), so a
    -- fault at any cited site leaves at least one of the two false. Blind
    -- spot: a fault at the final DB delete (:7220) reads as success and the
    -- row can respawn on reload - engine-logged when it happens.
    vehicle:permanentlyRemove()
    if not (vehicle:isRemovedFromWorld()
            and not getCell():getVehicles():contains(vehicle)) then
        RCShared.dbg("janitor: removal INCOMPLETE on %s at %s,%s (engine trace has the fault)",
            tostring(report.vehicle), tostring(report.x), tostring(report.y))
        return false
    end

    RCRegistry.addToken(report.trailer and "trailer" or "vehicle")
    local tv, tt = RCRegistry.tokens()
    RCAudit.log("JANITOR", nil, {
        vehicle = report.vehicle, x = report.x, y = report.y, z = report.z,
        trailer = report.trailer and true or false, dumped = dumped,
        lastUser = lastUser, tokensVehicle = tv, tokensTrailer = tt,
    })
    RCShared.dbg("janitor: reclaimed %s at %s,%s (lastUser=%s, loot dumped: %d, pools v=%d t=%d)",
        tostring(report.vehicle), tostring(report.x), tostring(report.y),
        tostring(lastUser), dumped, tv, tt)
    return true
end

-- One vehicle, one look. Attribute/stamp it, or - unclaimed, its person
-- gone, unchanged past the window, unshielded, within budget - reclaim it.
function RCJanitor.consider(vehicle)
    local c = RCShared.cfg()
    if not (c.enabled and c.janitorEnabled) then return end
    if not c.janitorDays or c.janitorDays <= 0 then return end
    if not vehicle then return end

    local md = vehicle:getModData()
    if not md then return end

    if RCClaim.isClaimed(vehicle) then
        -- claimed cars carry no janitor state at all; clearing here is what
        -- gives a released/expired car a fresh, unattributed clock later
        -- (a deliberate release = giving the car back to the world)
        if md[KEY_SEEN] ~= nil or md[KEY_SIG] ~= nil or md[KEY_USER] ~= nil then
            md[KEY_SEEN] = nil
            md[KEY_SIG]  = nil
            md[KEY_DT]   = nil
            md[KEY_USER] = nil
        end
        return
    end
    if RCShared.isWreck(vehicle) then return end

    -- someone is in it right now: attribute + restart the clock
    local who = occupantName(vehicle)
    local sig = signature(vehicle)
    local now = os.time()
    if md[KEY_SEEN] == nil or md[KEY_SIG] ~= sig or who then
        md[KEY_SEEN] = now
        md[KEY_SIG]  = sig
        md[KEY_DT]   = RCRegistry.downtimeTotal()
        if who then md[KEY_USER] = who end
        return
    end

    -- untouched since the stamp: past the window, downtime-credited?
    local idle = (now - md[KEY_SEEN]) - (RCRegistry.downtimeTotal() - (md[KEY_DT] or 0))
    if idle <= c.janitorDays * 86400 then return end

    -- THE PRESENCE LAW: if the last known user has been online within the
    -- window, their stuff is preserved - touched or not. (The presence map
    -- is downtime-shifted on boot, so the plain comparison is credited.)
    local lastUser = md[KEY_USER]
    if lastUser then
        local seen = RCRegistry.lastSeenAny(lastUser)
        if seen and (now - seen) <= c.janitorDays * 86400 then return end
    end

    local x, y = vehicle:getX(), vehicle:getY()
    if RCShared.phunZoneBlocks(x, y) then return end

    -- Safehouse shield: presence protection for cars nobody was ever seen
    -- with but that sit inside a player base. Checked last - it only runs
    -- for cars that already passed every other gate (rare).
    -- getSafeHouse handles a nil square itself (SafeHouse.java:186).
    if SafeHouse.getSafeHouse(vehicle:getSquare()) ~= nil then return end

    if budget <= 0 then return end
    budget = budget - 1
    reclaim(vehicle, lastUser)
end

-- ---------------------------------------------------------------------------
-- ASSESS - the read-only mirror of consider()'s ladder (2026-08-02).
--
-- The admin fleet panel needs to show WHY a car stands where it does, and the
-- one thing it must never do is compute that itself. A second implementation
-- of the Presence Law would drift from this one, and a panel that disagrees
-- with the sweep is worse than a panel with no verdict at all - it would be
-- read as authoritative right up until it deleted someone's car.
--
-- So the law is stated ONCE, above, and this walks the same gates in the same
-- order without acting on them. Two hard rules:
--   * it WRITES NOTHING. consider() owns the stamps; if this stamped anything,
--     opening the panel would restart the clock on every car the admin looked
--     at - observation would grant immunity.
--   * it never consults the budget. Budget decides how many cars a SWEEP
--     eats, not whether a car is eligible; a car that is due but out of budget
--     this hour is still due, and the panel must say so.
--
-- Returns a table (never nil) with:
--   verdict  "off" | "claimed" | "wreck" | "clock" | "held" | "shielded" | "due"
--   lastUser attributed keeper, if any
--   idle     seconds since last observed use, downtime-credited (nil if unstamped)
--   window   the configured abandonment window in seconds
--   dueIn    seconds until eligible; <= 0 means eligible now (nil when N/A)
--   userIdle seconds since lastUser was last online (nil if never seen)
--   shields  { claimed, wreck, phunzone, safehouse } - true only when APPLYING
-- ---------------------------------------------------------------------------
function RCJanitor.assess(vehicle)
    local out = { verdict = "off", shields = {} }
    local c = RCShared.cfg()
    if not (c.enabled and c.janitorEnabled) then return out end
    if not c.janitorDays or c.janitorDays <= 0 then return out end
    if not vehicle then return out end

    local md = vehicle:getModData()
    if not md then return out end

    out.window = c.janitorDays * 86400

    if RCClaim.isClaimed(vehicle) then
        out.verdict = "claimed"
        out.shields.claimed = true
        return out
    end
    if RCShared.isWreck(vehicle) then
        out.verdict = "wreck"
        out.shields.wreck = true
        return out
    end

    local now = os.time()
    out.lastUser = md[KEY_USER]

    -- Unstamped, or in use right now: the clock is at zero either way. We do
    -- NOT re-derive the signature here - comparing it would tell us the sweep
    -- is about to restart the clock, which is a fact about the next sweep, not
    -- about the car.
    if md[KEY_SEEN] == nil then
        out.verdict = "clock"
        out.dueIn = out.window
        return out
    end

    out.idle = (now - md[KEY_SEEN]) - (RCRegistry.downtimeTotal() - (md[KEY_DT] or 0))
    out.dueIn = out.window - out.idle

    if out.lastUser then
        local seen = RCRegistry.lastSeenAny(out.lastUser)
        if seen then out.userIdle = now - seen end
    end

    if out.idle <= out.window then
        out.verdict = "clock"
        return out
    end

    -- THE PRESENCE LAW: their stuff is preserved while they keep logging in.
    if out.userIdle and out.userIdle <= out.window then
        out.verdict = "held"
        return out
    end

    -- Past every clock gate; only the location shields remain. Both are read
    -- exactly as consider() reads them, including the deliberate ordering -
    -- safehouse last, because it is the expensive one.
    local x, y = vehicle:getX(), vehicle:getY()
    if RCShared.phunZoneBlocks(x, y) then
        out.verdict = "shielded"
        out.shields.phunzone = true
        return out
    end

    if SafeHouse.getSafeHouse(vehicle:getSquare()) ~= nil then
        out.verdict = "shielded"
        out.shields.safehouse = true
        return out
    end

    out.verdict = "due"
    return out
end

-- ---------------------------------------------------------------------------
-- Attribution feed: observe the vanilla 'vehicle' command channel (the
-- RCDamageAudit pattern - a listener, never a wrap; the module string is
-- vanilla's, not ours, so this does NOT belong in RCServer's dispatcher).
-- Every benign command carries (player, args.vehicle): engine start, doors,
-- trunk lock, horn, keys, lights, tow. One modData write per interaction -
-- event-driven, no polling, nothing transmitted.
-- ---------------------------------------------------------------------------
-- WHAT COUNTS AS USING A VEHICLE. An ALLOWLIST since 2026-08-19, and the switch
-- from a blacklist is the whole point.
--
-- This listener sits on vanilla's "vehicle" command channel, not on RCServer's
-- dispatcher, so nothing rate-limits it and every message reaching it came
-- straight off the wire. While the rule was "ignore these, count everything
-- else", any name NOT on the ignore list counted as use - including names
-- vanilla does not implement. Vanilla's own dispatcher silently drops unknown
-- commands (VehicleCommands.lua:457-465), so a client could invent a name that
-- does nothing at all, aim it at any vehicle id, and be recorded as that car's
-- keeper. Presence Law then shields it from reclamation. Loop the ids and the
-- entire reclaimable fleet is immune, without going near a single car.
--
-- Naming what counts inverts that: an invented name is simply not in the table.
--
-- THE POLICY (maintainer, 2026-08-19). Use means a person operated the car.
--   * Driving and its controls - engine, doors, lights, horn, tyres, heater.
--   * setTrunkLocked IS use: securing your own vehicle is caring for it.
--   * Keys on DOORS are not (putKeyOnDoor / removeKeyFromDoor). Handling a key
--     near a car is not operating it; putKeyInIgnition is, and is listed.
--   * Trailers are not - including attach/detach. Towing requires driving,
--     which fires startEngine and setDoorOpen anyway, so nothing legitimate
--     loses its claim by leaving these out.
--   * Cosmetic and debug state is not: paint, skin, blood, headlight config.
--   * fixPart IS use, deliberately - the PLAYER mechanic repair, skill-checked
--     and ungated. Staff repair paths (repair / repairPart / setPartCondition)
--     are not, so a maintenance sweep cannot silently adopt every car it
--     touches; that reasoning predates this table and is preserved.
--   * Damage is never use: a vandal must not inherit the car he wrecked.
local USE_COMMANDS = {
    startEngine            = true,
    putKeyInIgnition       = true,
    removeKeyFromIgnition  = true,
    setDoorOpen            = true,
    setTrunkLocked         = true,
    setHeadlightsOn        = true,
    setStoplightsOn        = true,
    setLightbarLightsMode  = true,
    setLightbarSirenMode   = true,
    onHorn                 = true,
    onBackSignal           = true,
    toggleHeater           = true,
    setTirePressure        = true,
    fixPart                = true,
}

-- Attribute a vehicle to `name` as USED right now: stamp the keeper + restart
-- the usage clock. Unclaimed, non-wreck cars only (a claimed car carries no
-- janitor state; a wreck mints nothing). Shared by the vanilla 'vehicle'
-- command listener below AND the driver-entry relay (RCServer 'used'), so the
-- Presence Law shields a hotwired/keyless daily driver exactly like a
-- key-holder's car. Idempotent - re-stamping just refreshes the timestamp.
function RCJanitor.attribute(name, vehicle)
    if not (name and vehicle) then return end
    local c = RCShared.cfg()
    if not (c.enabled and c.janitorEnabled) then return end
    if RCClaim.isClaimed(vehicle) or RCShared.isWreck(vehicle) then return end
    local md = vehicle:getModData()
    md[KEY_USER] = name
    md[KEY_SEEN] = os.time()
    md[KEY_DT]   = RCRegistry.downtimeTotal()
end

local function onVehicleCommand(module, command, player, args)
    if module ~= "vehicle" then return end
    if not USE_COMMANDS[command] then return end
    if not (player and args and args.vehicle) then return end
    local c = RCShared.cfg()
    if not (c.enabled and c.janitorEnabled) then return end
    local name = player:getUsername()
    if not name then return end
    RCRegistry.notePresence(name)
    -- Wire value VALIDATED rather than guarded - and this one arrives on
    -- VANILLA's channel, so it is genuinely untrusted input rather than our own
    -- payload. getVehicleById takes an int (LuaManager.java:8208-8211), so
    -- tonumber() is both the type check and the precondition.
    local vid = tonumber(args.vehicle)
    local v = vid and getVehicleById(vid)
    if v then RCJanitor.attribute(name, v) end
end
Events.OnClientCommand.Add(onVehicleCommand)

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
