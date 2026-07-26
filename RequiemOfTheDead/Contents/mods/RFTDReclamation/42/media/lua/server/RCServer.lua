-- RCServer - the SINGLE OnClientCommand dispatcher (RFTD house rule).
--
-- All authoritative claim writes happen here and ONLY here. Every handler
-- re-validates server-side (the client gate is decorative), writes vehicle
-- modData + the registry, syncs with transmitModData, audits to the ledger,
-- and notifies the player. The client never writes claim fields itself.

if not isServer() then return end

RCServer = RCServer or {}

local M = RCShared.MODULE

-- Server -> client halo feedback. Keyed translation string; the client
-- (RCNotify) resolves it. error=true tints it red.
local function notify(player, key, isError)
    if player and sendServerCommand then
        sendServerCommand(player, M, "Notify", { key = key, error = isError and true or false })
    end
end

-- Tell an open management GUI to re-read (whitelist changed).
local function claimUpdate(player, vehicleId)
    if player and sendServerCommand then
        sendServerCommand(player, M, "ClaimUpdate", { vehicleId = vehicleId })
    end
end

-- Debounced modData sync. The claim modData is written to the vehicle IMMEDIATELY
-- by each handler (server state stays authoritative); only the network sync is
-- coalesced. Rapid GUI checkbox toggling would otherwise fire a full-vehicle
-- transmitModData per click - a burst of redundant re-transmits. Instead we
-- queue the vehicle and flush one transmit per ~1/3s while writes are arriving,
-- then stop the ticker when idle (event-driven, never an always-on scan).
local pendingTransmit = {}
local FLUSH_TICKS = 20   -- ~0.33s at 60fps
local flushTicks = 0
local flushTicking = false

local function pendingEmpty()
    for _ in pairs(pendingTransmit) do return false end
    return true
end

local function flushTransmits()
    flushTicks = flushTicks + 1
    if flushTicks < FLUSH_TICKS then return end
    flushTicks = 0
    if pendingEmpty() then
        flushTicking = false
        Events.OnTick.Remove(flushTransmits)
        return
    end
    local batch = pendingTransmit
    pendingTransmit = {}
    for _, veh in pairs(batch) do
        pcall(function() veh:transmitModData() end)
    end
end

local function queueTransmit(v)
    if not v then return end
    pendingTransmit[v:getId()] = v
    if not flushTicking then
        flushTicking = true
        flushTicks = 0
        Events.OnTick.Add(flushTransmits)
    end
end

-- Resolve the target vehicle from either a live vehicleId (at-the-car: radial /
-- world menu) OR a claimId (fleet panel, possibly-remote). The claimId path only
-- resolves when the car is loaded SOMEWHERE on the server - an unloaded car has
-- no object to write, which is exactly why the panel greys its edit controls.
local function resolveVehicle(args)
    if not args then return nil end
    if args.vehicleId then
        local ok, v = pcall(getVehicleById, args.vehicleId)
        if ok and v then return v end
    end
    if args.claimId then
        return RCRegistry.findLoadedByClaimId(args.claimId)
    end
    return nil
end

-- Build + push the player's fleet slice. Their data ONLY (never the whole
-- registry). Each row is enriched with a `loaded` flag and, when loaded, the
-- live whitelist/public perms read straight off the vehicle - so the access
-- manager can render + edit a loaded car by claimId, and grey out an unloaded
-- one. One bounded loaded-vehicle pass per request (never on a timer) - and
-- that pass ALSO self-heals the index (see RCRegistry.loadedClaimMap), so it
-- MUST run before RCRegistry.slice reads the index, not after.
local function sendSlice(player)
    if not (player and sendServerCommand) then return end
    local loaded = RCRegistry.loadedClaimMap()   -- self-heals first
    local list   = RCRegistry.slice(player:getUsername())
    for _, rec in ipairs(list) do
        local v = loaded[rec.claimId]
        if v then
            rec.loaded  = true
            rec.allowed = RCClaim.getAllowedMap(v)   -- normalized map (legacy upgraded)
            rec.public  = RCClaim.getPublic(v)
        else
            rec.loaded = false
        end
    end
    sendServerCommand(player, M, "MyVehicles", { list = list })
end

-- Signal both open UIs after a claim/whitelist change: the live access manager
-- (ClaimUpdate, reads synced modData) AND any fleet-panel/snapshot manager (a
-- fresh slice). Both are cheap + rate-limited; sending both means neither UI can
-- miss a refresh regardless of which door the edit came through.
local function signalChange(player, args)
    claimUpdate(player, args and args.vehicleId)   -- at-the-car access manager
    sendSlice(player)                               -- fleet panel + remote manager
end

local REASON_KEY = {
    disabled  = "IGUI_RC_ClaimErr_Disabled",
    wreck     = "IGUI_RC_ClaimErr_Wreck",
    claimed   = "IGUI_RC_ClaimErr_Claimed",
    novehicle = "IGUI_RC_ClaimErr_NoVehicle",
}

-- After any authoritative write, log the resulting SERVER-side claim state.
-- Compare against the [cl] dump to spot a sync gap.
local function dbgState(tag, v)
    if RCShared.cfg().debug then RCShared.dbg("[srv] %s -> %s", tag, RCClaim.describe(v)) end
end

-- ---------------------------------------------------------------------------
-- Handlers
-- ---------------------------------------------------------------------------

local function hClaim(player, args)
    local v = resolveVehicle(args)
    if not v then notify(player, "IGUI_RC_ClaimErr_NoVehicle", true); return end

    local name = player:getUsername()
    local ok, reason = RCClaim.canClaim(v, player)
    if not ok then
        notify(player, REASON_KEY[reason] or "IGUI_RC_ClaimErr_NoVehicle", true)
        RCAudit.log("CLAIM-DENY", player, { vehicle = v:getScriptName(), reason = reason })
        return
    end

    -- Cap (registry-counted, split by category: MaxClaims for motor vehicles,
    -- MaxClaimTrailers for trailers - a full garage doesn't block a trailer).
    -- Re-claiming a car you already own (native or legacy WG) skips the
    -- ceiling; staff bypass it.
    local owner = RCClaim.getOwner(v)
    local reclaimingOwn = owner and owner == name
    local isTrailer = RCShared.isTrailer(v)
    if not reclaimingOwn and not RCShared.isAdmin(player) and RCRegistry.atLimit(name, isTrailer) then
        notify(player, isTrailer and "IGUI_RC_ClaimErr_TrailerLimit" or "IGUI_RC_ClaimErr_Limit", true)
        RCAudit.log("CLAIM-DENY", player, {
            vehicle = v:getScriptName(), reason = isTrailer and "trailer-limit" or "limit",
        })
        return
    end

    local md = v:getModData()
    md[RCClaim.KEY_OWNER] = name
    md[RCClaim.KEY_USED]  = os.time()
    local claimId = RCRegistry.add(name, v) -- generates id + registers
    queueTransmit(v)
    dbgState("claim", v)

    RCAudit.log("CLAIM", player, { vehicle = v:getScriptName(), claimId = claimId })
    notify(player, "IGUI_RC_Claimed", false)
end

local function hUnclaim(player, args)
    local v = resolveVehicle(args)
    if not v then notify(player, "IGUI_RC_ClaimErr_NoVehicle", true); return end

    local owner = RCClaim.getOwner(v)
    if not owner then notify(player, "IGUI_RC_NotClaimed", true); return end

    local name = player:getUsername()
    if owner ~= name and not RCShared.isAdmin(player) then
        notify(player, "IGUI_RC_NotOwner", true); return
    end

    local md = v:getModData()
    local claimId = md[RCClaim.KEY_ID]
    md[RCClaim.KEY_OWNER]   = nil
    md[RCClaim.KEY_ALLOWED] = nil
    md[RCClaim.KEY_PUBLIC]  = nil
    md[RCClaim.KEY_USED]    = nil
    -- keep RC_ClaimId for audit continuity
    if claimId then RCRegistry.remove(owner, claimId) end
    queueTransmit(v)

    RCAudit.log("UNCLAIM", player, { vehicle = v:getScriptName(), claimId = claimId, owner = owner })
    notify(player, "IGUI_RC_Unclaimed", false)
end

-- Whitelist entries are a map (username -> perm flags). Bound it with MaxAllowed.
local function allowedCount(map)
    local n = 0
    for _ in pairs(map) do n = n + 1 end
    return n
end

local function isValidPerm(perm)
    return perm == "driver" or perm == "passenger" or perm == "mechanic" or perm == "inventory"
end

-- Shared owner/admin guard for the access handlers. The vehicle must be CLAIMED
-- and the caller must own it (or be staff). Returns vehicle, owner or nil.
local function requireOwner(player, args)
    local v = resolveVehicle(args)
    if not v then
        -- A claimId edit that didn't resolve => the car unloaded since the panel
        -- last refreshed. Tell the player + push a fresh slice so its Manage
        -- button greys out to match reality.
        if args and args.claimId then
            notify(player, "IGUI_RC_OutOfRange", true)
            sendSlice(player)
        end
        return nil
    end
    local owner = RCClaim.getOwner(v)
    if not owner then notify(player, "IGUI_RC_NotClaimed", true); return nil end
    if owner ~= player:getUsername() and not RCShared.isAdmin(player) then
        notify(player, "IGUI_RC_NotOwner", true)
        return nil
    end
    return v, owner
end

-- Add a player to the whitelist. Default = Passenger only; the owner ticks on
-- more in the GUI. target is client-supplied: the OWNERSHIP check gates the
-- action, so a name nobody holds is harmless.
local function hAllow(player, args)
    local v, owner = requireOwner(player, args)
    if not v then return end

    local target = args and args.target
    if type(target) ~= "string" or target == "" or #target > 64 then return end
    if target == owner then notify(player, "IGUI_RC_AllowSelf", true); return end

    local md = v:getModData()
    local map = RCClaim.getAllowedMap(v) -- normalized (upgrades any legacy array)
    if map[target] then notify(player, "IGUI_RC_AlreadyAllowed", true); return end
    if allowedCount(map) >= RCShared.cfg().maxAllowed then notify(player, "IGUI_RC_AllowFull", true); return end

    map[target] = { driver = false, passenger = true, mechanic = false, inventory = false }
    md[RCClaim.KEY_ALLOWED] = map
    queueTransmit(v)
    dbgState("allow " .. target, v)

    RCAudit.log("CLAIM-ALLOW", player, { vehicle = v:getScriptName(), target = target })
    notify(player, "IGUI_RC_Granted", false)
    signalChange(player, args)
end

-- Remove a player from the whitelist entirely.
local function hDeny(player, args)
    local v = requireOwner(player, args)
    if not v then return end

    local target = args and args.target
    if type(target) ~= "string" or target == "" then return end

    local md = v:getModData()
    local map = RCClaim.getAllowedMap(v)
    local removed = map[target] ~= nil
    map[target] = nil
    md[RCClaim.KEY_ALLOWED] = map
    queueTransmit(v)

    if removed then RCAudit.log("CLAIM-REVOKE", player, { vehicle = v:getScriptName(), target = target }) end
    notify(player, "IGUI_RC_Revoked", false)
    signalChange(player, args)
end

-- Toggle ONE permission for ONE whitelisted player. No halo (toggles are
-- frequent); the GUI refresh on ClaimUpdate is the feedback.
local function hSetPerm(player, args)
    local v = requireOwner(player, args)
    if not v then return end
    local target = args and args.target
    local perm = args and args.perm
    if type(target) ~= "string" or target == "" or not isValidPerm(perm) then return end

    local md = v:getModData()
    local map = RCClaim.getAllowedMap(v)
    local entry = map[target]
    if not entry then return end -- not on the whitelist
    entry[perm] = (args.value == true)
    md[RCClaim.KEY_ALLOWED] = map
    queueTransmit(v)
    dbgState(string.format("setperm %s.%s=%s", target, perm, tostring(args.value == true)), v)

    RCAudit.log("CLAIM-PERM", player, {
        vehicle = v:getScriptName(), target = target, perm = perm, value = tostring(args.value == true),
    })
    signalChange(player, args)
end

-- Toggle ONE public (everyone) permission for the vehicle.
local function hSetPublic(player, args)
    local v = requireOwner(player, args)
    if not v then return end
    local perm = args and args.perm
    if not isValidPerm(perm) then return end

    local md = v:getModData()
    local pub = md[RCClaim.KEY_PUBLIC] or {}
    pub[perm] = (args.value == true)
    md[RCClaim.KEY_PUBLIC] = pub
    queueTransmit(v)
    dbgState(string.format("setpublic %s=%s", perm, tostring(args.value == true)), v)

    RCAudit.log("CLAIM-PUBLIC", player, {
        vehicle = v:getScriptName(), perm = perm, value = tostring(args.value == true),
    })
    signalChange(player, args)
end

-- On-demand: print the SERVER's authoritative view of this vehicle's claim
-- state to the server console. Compare against the client's [cl] DUMP line to
-- catch a sync gap (client modData != server modData). Always responds (it is
-- an explicit request), and also sends the string back so the requester sees
-- the server view in their own console next to their client view.
local function hDumpClaim(player, args)
    local v = resolveVehicle(args)
    local who = player and player.getUsername and player:getUsername() or "?"
    local line = v and RCClaim.describe(v) or ("vehicle not found id=" .. tostring(args and args.vehicleId))
    print("[RC][srv] DUMP (req " .. tostring(who) .. ") " .. line)
    if player and sendServerCommand then
        sendServerCommand(player, M, "DumpReply", { text = line })
    end
end

-- ---------------------------------------------------------------------------
-- My Vehicles (fleet panel). The player asks for their own registry slice; we
-- send it back enriched (see sendSlice, defined up top with the resolvers).
-- ---------------------------------------------------------------------------
local function hMyVehicles(player, args)
    sendSlice(player)
end

-- Release a claim BY claim id (not vehicleId), so it works for UNLOADED cars the
-- player can't be standing next to. Ownership is proven by the registry (keyed
-- by owner username). If the car is currently loaded we clear its modData now;
-- if not, we defer the modData clear to the next load (RCRegistry pending set)
-- and drop the index entry immediately so the panel + the cap update at once.
local function hReleaseClaim(player, args)
    local claimId = args and args.claimId
    if type(claimId) ~= "string" or claimId == "" then return end

    local name = player:getUsername()
    if not RCRegistry.owns(name, claimId) then
        notify(player, "IGUI_RC_NotOwner", true)
        sendSlice(player)
        return
    end

    local v = RCRegistry.findLoadedByClaimId(claimId)
    if v then
        -- Loaded: full immediate release (same effect as right-click Release).
        local owner = RCClaim.getOwner(v)
        if owner and owner ~= name and not RCShared.isAdmin(player) then
            notify(player, "IGUI_RC_NotOwner", true); sendSlice(player); return
        end
        local md = v:getModData()
        md[RCClaim.KEY_OWNER]   = nil
        md[RCClaim.KEY_ALLOWED] = nil
        md[RCClaim.KEY_PUBLIC]  = nil
        md[RCClaim.KEY_USED]    = nil
        queueTransmit(v)
        RCRegistry.remove(name, claimId)
        RCAudit.log("UNCLAIM", player, { vehicle = v:getScriptName(), claimId = claimId, owner = name, via = "panel" })
    else
        -- Unloaded: defer the modData clear to next load; free the index now.
        RCRegistry.markPendingRelease(claimId)
        RCRegistry.remove(name, claimId)
        RCAudit.log("UNCLAIM", player, { claimId = claimId, owner = name, via = "panel-deferred" })
    end

    notify(player, "IGUI_RC_Unclaimed", false)
    sendSlice(player)
end

-- ---------------------------------------------------------------------------
-- Dismantle + engine-lock telemetry (DESIGN §1/§2). Both are LEDGER events on
-- rare one-shot actions - the client-gate + audit model, not server veto (the
-- teardown itself is client-driven in MP; PZ offers no Lua veto). A forged
-- command therefore costs nothing but a ledger line naming its sender, and
-- the only state it can touch is the claim INDEX - which self-heals from
-- modData, the same safe failure direction as pruneOrphans.
-- ---------------------------------------------------------------------------

-- Client finished a vehicle removal: a FIELD dismantle (radial/right-click,
-- args.delete absent) or the admin tab's plain DELETE (args.delete=true -
-- vanilla remove semantics, no dismantle framing). Ledger it under the
-- matching verb; if the car carried a claim (staff paths only - field gates
-- block claimed cars for players), prune the index entry so the owner's cap
-- + fleet panel update - its modData died with the vehicle.
local function hDismantled(player, args)
    if args.claimId and args.owner then
        pcall(RCRegistry.remove, args.owner, args.claimId)
    end
    RCAudit.log(args.delete and "VEHICLE-DELETE" or "DISMANTLE", player, {
        vehicle = args.vehicle, wreck = args.wreck and true or false,
        via = args.via or "field", x = args.x, y = args.y, z = args.z,
        engine = args.engine, owner = args.owner, claimId = args.claimId,
        cheat = args.cheat,   -- e.g. "eternal-torch" (staff no-wear dismantle)
    })
    -- The §4 token trickle: a FIELD dismantle of a non-wreck mints one token
    -- into the matching pool. Wrecks and panel deletes mint nothing (the
    -- free-wreck-supply rule; deletion is cleanup, not economy). The wreck
    -- flag is client-reported (the vehicle is already gone) - a forged mint
    -- is possible but worthless-until-§4 and fully attributed in the ledger.
    if not args.delete and not args.wreck and args.vehicle then
        local kind = string.contains(tostring(args.vehicle), "Trailer") and "trailer" or "vehicle"
        pcall(RCRegistry.addToken, kind)
    end
end

-- Engine parts actually pulled (RCEngineLock's ISTakeEngineParts telemetry).
-- The lock should stop every non-staff player BEFORE this point, so a
-- BYPASS-flagged line = a defeated client. admin is decided by OUR access
-- check on the sender - the client's word is never consulted.
local function hEnginePull(player, args)
    local admin = RCShared.isAdmin(player)
    local bypass = RCShared.cfg().engineLockEnabled and not admin
    RCAudit.log("ENGINE-PULL", player, {
        vehicle = args.vehicle, vid = args.vid, x = args.x, y = args.y, z = args.z,
        admin = admin, flag = bypass and "BYPASS-block-defeated" or "-",
    })
end

-- Driver-entry attribution (RCUsage client hook). A player who ENTERS an
-- unclaimed car as its DRIVER is using it - the case the vanilla 'vehicle'
-- command channel misses (hotwiring and raw driving send no such command),
-- which let the Janitor reclaim players' hotwired daily drivers. Stamp
-- attribution here (RCJanitor.attribute) so the Presence Law shields it like a
-- key-holder's car. The vehicle is re-resolved from the trusted sender; a
-- forged 'used' only refreshes an unclaimed car's clock in the sender's own
-- name - worthless, and fully within the sender's own rights anyway.
local function hUsed(player, args)
    if not (player and args and args.vehicleId) then return end
    local name = player:getUsername()
    if not name then return end
    RCRegistry.notePresence(name)
    if RCJanitor and RCJanitor.attribute then
        RCJanitor.attribute(name, resolveVehicle(args))
    end
end

-- Staff vehicle spawn (window + click-to-place; see RCSpawnWindow). The
-- client flow is decorative; THIS is the gate. Access = the sandbox-tunable
-- staff ladder, checked on the server-trusted sender - the donor mod's server
-- handler trusted any packet that knew its command name, which is the
-- exploited cheat-panel hole this replaces. Every spawn AND every denial
-- writes a ledger line, so a forged command now costs its sender a named
-- SPAWN-DENY entry instead of a free car. No radius clamp by design: RCSpawn
-- already requires a LOADED square, and a teleporting admin shouldn't fight a
-- leash. The dispatcher's rate limit is the flood ceiling.
local SPAWN_ERR = {
    badmodel = "IGUI_RC_SpawnErr_BadModel",
    nosquare = "IGUI_RC_SpawnErr_NoSquare",
    failed   = "IGUI_RC_SpawnErr_Failed",
}

local function hSpawnVehicle(player, args)
    if not RCShared.cfg().spawnerEnabled then
        notify(player, "IGUI_RC_SpawnErr_Disabled", true)
        RCAudit.log("SPAWN-DENY", player, { reason = "disabled", model = tostring(args.model) })
        return
    end
    if not RCShared.canUseSpawner(player) then
        notify(player, "IGUI_RC_NoPermission", true)
        RCAudit.log("SPAWN-DENY", player, {
            reason = "access", model = tostring(args.model),
            level = tostring(player and player.getAccessLevel and player:getAccessLevel() or "?"),
        })
        return
    end

    local vehicle, reason, removed = RCSpawn.spawn(args)
    if not vehicle then
        notify(player, SPAWN_ERR[reason] or "IGUI_RC_SpawnErr_Failed", true)
        RCAudit.log("SPAWN-DENY", player, { reason = tostring(reason or "failed"), model = tostring(args.model) })
        return
    end

    RCAudit.log("VEHICLE-SPAWN", player, {
        model = vehicle:getScriptName(), vid = vehicle:getId(),
        x = args.x, y = args.y, z = args.z,
        cond = tostring(args.condition), dir = tostring(args.direction),
        nofuel = args.noFuel == true, nobattery = args.noBattery == true,
        key = args.keyGlovebox == true,
        missing = args.missingParts == true, removed = removed or 0,
    })
    notify(player, "IGUI_RC_Spawned", false)
end

local handlers = {
    claim       = hClaim,
    unclaim     = hUnclaim,
    allow       = hAllow,
    deny        = hDeny,
    setperm     = hSetPerm,
    setpublic   = hSetPublic,
    dumpclaim   = hDumpClaim,
    myvehicles  = hMyVehicles,
    releaseclaim = hReleaseClaim,
    dismantled  = hDismantled,
    enginePull  = hEnginePull,
    used        = hUsed,
    spawnvehicle = hSpawnVehicle,
}

-- ---------------------------------------------------------------------------
-- Dispatch + a light per-player rate limit (a reply is itself a packet, so an
-- over-limit command is dropped silently). 20/sec is far above human cadence.
-- ---------------------------------------------------------------------------
local RATE_MAX = 20
local rate = {}

local function underRate(player)
    local nm = player and player.getUsername and player:getUsername()
    if not nm then return true end
    local ok, now = pcall(getTimestampMs)
    if not ok or type(now) ~= "number" then return true end
    local r = rate[nm]
    if not r or (now - r.start) >= 1000 then rate[nm] = { start = now, count = 1 }; return true end
    r.count = r.count + 1
    return r.count <= RATE_MAX
end

local function onClientCommand(module, command, player, args)
    if module ~= M then return end
    local h = handlers[command]
    if not h then return end
    if not underRate(player) then return end
    local ok, err = pcall(h, player, args or {})
    if not ok then print("[RC] handler error (" .. tostring(command) .. "): " .. tostring(err)) end
end
Events.OnClientCommand.Add(onClientCommand)

local function onDisconnect(a)
    local nm = (type(a) == "string") and a or (a and a.getUsername and a:getUsername())
    if nm then rate[nm] = nil end
end
if Events.OnPlayerDisconnect then Events.OnPlayerDisconnect.Add(onDisconnect) end

print("[RC] RCServer loaded (v" .. tostring(RCShared.VERSION) .. ")")
