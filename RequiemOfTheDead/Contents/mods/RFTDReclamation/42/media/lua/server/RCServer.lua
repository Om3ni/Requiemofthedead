-- RCServer - the SINGLE OnClientCommand dispatcher (RFTD house rule).
--
-- All authoritative claim writes happen here and ONLY here. Every handler
-- re-validates server-side (the client gate is decorative), writes vehicle
-- modData + the registry, syncs with transmitModData, audits to the ledger,
-- and notifies the player. The client never writes claim fields itself.

if not isServer() then return end

-- Explicit, not riding on load order: "RCServer.lua" sorts BEFORE "RDRate.lua"
-- in PZ's merged virtual tree (RC < RD), so Core's limiter does not exist yet
-- when this file runs. The call site is inside a command handler and would
-- resolve fine at runtime, but the family's rule since the 42.19 boot-log
-- crashes is that a cross-file RD* dependency is declared, not assumed. Safe
-- above the isServer() guard's reach because that guard already returned on
-- the client, where RDRate.lua self-aborts and would resolve to nil.
require "RDRate"

-- Same rule, applied to the lifecycle surface. RCParking/RCRespawn/RCTuning all
-- happen to sort before this file today, so these requires are currently no-ops
-- - which is exactly when a load-order dependency is cheapest to declare and
-- most likely to be silently broken later by a rename.
require "RCTuning"
require "RCParking"
require "RCRespawn"

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

-- Bulk sibling of the above, for the admin tab's multi-select delete. ONE
-- command carrying N reports rather than N commands, and the reason is the
-- ledger rather than performance: the dispatcher below drops everything past
-- RATE_MAX per second SILENTLY, so a client loop could delete ten vehicles and
-- ledger only the first few. An audit that under-reports a destructive staff
-- action is worse than no audit, because it reads as authoritative.
--
-- The vanilla "vehicle"/remove commands that actually destroy the cars cannot be
-- batched - they are the engine's own channel, one per vehicle - so the client
-- sends those individually and this one line covers the whole set.
--
-- Capped independently of whatever the client believes: args arrive untrusted,
-- and hDismantled prunes claim-index entries, so an unbounded list is an
-- unbounded write loop on the tick thread.
local DISMANTLE_BATCH_MAX = 16

local function hDismantledMany(player, args)
    local list = args and args.reports
    if type(list) ~= "table" then return end

    -- STAFF ONLY, unlike its single-report sibling. hDismantled is deliberately
    -- ungated because a field dismantle is an ordinary player action, but it
    -- also prunes a claim-index entry from client-supplied owner/claimId - so a
    -- forged report can unclaim someone else's car in the index. That hole
    -- predates this handler; what is new is that ONE bulk command could work it
    -- sixteen times instead of once, and the only legitimate sender is the admin
    -- panel. Gate the amplifier, leave the field path alone.
    if not RCShared.isAdmin(player) then
        RCAudit.log("VEHICLE-DELETE-REFUSED", player, { via = "panel-bulk", n = #list })
        return
    end

    local n = 0
    for _, rep in ipairs(list) do
        if n >= DISMANTLE_BATCH_MAX then
            print("[RC] dismantledMany: batch capped at " .. DISMANTLE_BATCH_MAX
                .. " for " .. tostring(player and player.getUsername and player:getUsername()))
            break
        end
        if type(rep) == "table" then
            n = n + 1
            -- pcall per report: one malformed entry must not abandon the rest of
            -- the batch, leaving cars destroyed in the world and unledgered.
            local ok, err = pcall(hDismantled, player, rep)
            if not ok then print("[RC] dismantledMany entry failed: " .. tostring(err)) end
        end
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

-- Staff fleet snapshot for the Dragonfly vehicles tab. Admin-gated HERE (the
-- authoritative check - the tab's own capability gate is decorative, same split
-- as the spawner), then handed to RCFleet, which owns the paging and the tick
-- budget. Deliberately silent on denial: an unauthorised caller learns nothing,
-- and a reply is itself a packet.
--
-- One request supersedes the caller's previous one inside RCFleet, so Refresh
-- spam costs a dropped scan rather than N concurrent scans - which is why this
-- needs no throttle of its own beyond the dispatcher's rate limit.
local function hFleet(player, args)
    if not RCShared.isAdmin(player) then
        RCAudit.log("FLEET-DENY", player, {
            level = tostring(player and player.getAccessLevel and player:getAccessLevel() or "?"),
        })
        return
    end
    if RCShared.need("RCFleet", RCFleet,
        "the Vehicles tab will sit on 'Requesting fleet...' forever") then
        RCFleet.begin(player, args and args.scope)
    end
end

local function hFleetCancel(player)
    if RCFleet then RCFleet.cancel(player) end   -- nothing to cancel; silence is correct
end

-- One car's parts for the inspector's diagram. Same admin gate; silent denial.
local function hVehicleParts(player, args)
    if not RCShared.isAdmin(player) then return end
    if RCShared.need("RCFleet", RCFleet,
        "the parts diagram will stay on 'select a vehicle'") then
        RCFleet.parts(player, args and args.vid)
    end
end

-- ---------------------------------------------------------------------------
-- LIFECYCLE TAB (2026-08-03) - the tuning surface.
--
-- Everything below is admin-gated and silent on denial, matching hFleet. The
-- dials are server state: the client renders a copy and asks for changes, it
-- never applies one locally and hopes the server agrees. RCTuning.coerce is
-- the gate - an unknown key or an out-of-range value dies there rather than
-- being written into the override table and read back forever.
-- ---------------------------------------------------------------------------

-- One packet with everything the tab paints: dial values, which of them have
-- been moved off the sandbox, the token pools, how the parking oracle is
-- operating, and last sweep's outcome. Sent to the ASKING player only.
local function hLifecycle(player)
    if not RCShared.isAdmin(player) then return end
    -- Guarded rather than assumed: RCTuning is a shared/ file and a partial
    -- deploy can leave it behind, in which case snapshot() throws inside a
    -- packet handler and the Janitor tab reads "loading..." with no reply.
    if not RCShared.need("RCTuning", RCTuning,
        "the Janitor tab will stay on 'loading...'") then return end
    local values, moved = RCTuning.snapshot()
    local tv, tt = RCRegistry.tokens()
    sendServerCommand(player, M, "lifecycle", {
        values  = values,
        moved   = moved,
        tokensVehicle = tv,
        tokensTrailer = tt,
        parking = RCParking and RCParking.status() or nil,
        last    = RCRespawn and RCRespawn.last or nil,
    })
end

-- Move one dial. Broadcasts the new override set to EVERY client, not just the
-- caller: the decorative client-side gates (which tools to show) read cfg too,
-- and a client holding stale overrides would disagree with the server about
-- what is enabled. The push is one small packet on a rare, human-paced event.
local function hSetTuning(player, args)
    if not RCShared.isAdmin(player) then
        RCAudit.log("TUNING-DENY", player, {
            key = tostring(args and args.key),
            level = tostring(player and player.getAccessLevel and player:getAccessLevel() or "?"),
        })
        return
    end
    local key = args and args.key
    if type(key) ~= "string" then return end
    local applied, reason = RCTuning.set(key, args.value)
    if applied == nil then
        RCShared.dbg("tuning: refused %s (%s)", tostring(key), tostring(reason))
        hLifecycle(player)   -- resend truth so the panel snaps back
        return
    end
    RCAudit.log("TUNING", player, { key = key, value = tostring(applied) })
    sendServerCommand(M, "tuningpush", { values = RCTuning.load() })
    hLifecycle(player)
end

local function hResetTuning(player)
    if not RCShared.isAdmin(player) then return end
    RCTuning.reset()
    RCAudit.log("TUNING-RESET", player, {})
    sendServerCommand(M, "tuningpush", { values = RCTuning.load() })
    hLifecycle(player)
end

-- Retrofit census. Read-only; safe to run as often as an admin likes, bounded
-- by the loaded vehicle count.
local function hNoVanillaSurvey(player)
    if not RCShared.isAdmin(player) then return end
    if not RCShared.need("RCNoVanilla", RCNoVanilla,
        "Survey will report nothing and Remove vanilla will refuse") then return end
    sendServerCommand(player, M, "novanillasurvey", RCNoVanilla.survey())
end

-- Retrofit purge. The destructive half, and the reason survey exists: the tab
-- will not send this until it has shown the admin a count first.
local function hNoVanillaPurge(player, args)
    if not RCShared.isAdmin(player) then
        RCAudit.log("PURGE-DENY", player, {})
        return
    end
    if not RCShared.need("RCNoVanilla", RCNoVanilla,
        "the retrofit purge cannot run") then return end
    local budget = tonumber(args and args.budget) or 25
    if budget < 1 then budget = 1 end
    if budget > 200 then budget = 200 end
    local removed, dumped, minted = RCNoVanilla.purge(budget)
    RCAudit.log("PURGE", player, { removed = removed, dumped = dumped, minted = minted })
    -- `minted` travels back so the panel can SAY that removal funded
    -- replacement. A destructive action that silently also credits an economy
    -- is the wrong kind of surprise, even when the credit is the point.
    sendServerCommand(player, M, "novanillapurged",
        { removed = removed, dumped = dumped, minted = minted })
    sendServerCommand(player, M, "novanillasurvey", RCNoVanilla.survey())
    -- Fresh lifecycle payload: the token pool just moved and the panel's status
    -- column is the only place an admin can see that it did.
    hLifecycle(player)
end

-- Force a replacement sweep now, instead of waiting on the hourly pass.
--
-- This is what makes the retrofit usable: purge banks tokens, this spends them.
-- Without it an admin who clears fifty vanilla cars has to leave the server
-- running for a day to see them come back, which is why the pair read as
-- "cleanup works, replacement does not".
--
-- It cannot mint. RCRespawn.sweep spends from the pool and refunds what it
-- cannot place, so the worst this button can do is fail to find parking.
local function hRespawnNow(player, args)
    if not RCShared.isAdmin(player) then
        RCAudit.log("RESPAWN-NOW-DENY", player, {})
        return
    end
    if not RCShared.need("RCRespawn", RCRespawn,
        "replacements cannot be placed") then return end
    local burst = tonumber(args and args.burst) or 10
    if burst < 1 then burst = 1 end
    if burst > 25 then burst = 25 end
    local placed = RCRespawn.sweep(burst) or 0
    RCAudit.log("RESPAWN-NOW", player, { burst = burst, placed = placed })
    sendServerCommand(player, M, "respawnnow", { placed = placed, burst = burst })
    hLifecycle(player)
end

-- Mark the room the admin is standing in as "never park here".
--
-- The reporting half of a deliberate decision: indoor vehicle zones stay legal
-- (see RCParking.canPlace) because most of them are real parking, so the bad
-- ones are collected as they are found rather than guessed at up front. One
-- press, no coordinates to type - the room's own bounds are recorded.
local function hNoParkHere(player)
    if not RCShared.isAdmin(player) then
        RCAudit.log("NOPARK-DENY", player, {})
        return
    end
    if not RCShared.need("RCNoPark", RCNoPark,
        "the exclusion list is unavailable") then return end
    local rect, why = RCNoPark.addRoomAt(player)
    if not rect then
        sendServerCommand(player, M, "nopark", { ok = false, reason = tostring(why) })
        return
    end
    RCAudit.log("NOPARK", player, {
        x = rect.x, y = rect.y, z = rect.z, w = rect.w, h = rect.h,
        room = tostring(rect.label or "-"),
    })
    sendServerCommand(player, M, "nopark", {
        ok = true, x = rect.x, y = rect.y, w = rect.w, h = rect.h,
        label = tostring(rect.label or "room"),
        total = #RCNoPark.all(),
    })
end

local handlers = {
    lifecycle       = hLifecycle,
    settuning       = hSetTuning,
    resettuning     = hResetTuning,
    novanillasurvey = hNoVanillaSurvey,
    novanillapurge  = hNoVanillaPurge,
    respawnnow      = hRespawnNow,
    noparkhere      = hNoParkHere,
    fleet        = hFleet,
    fleetcancel  = hFleetCancel,
    vehicleparts = hVehicleParts,
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
    dismantledMany = hDismantledMany,
    enginePull  = hEnginePull,
    used        = hUsed,
    spawnvehicle = hSpawnVehicle,
}

-- ---------------------------------------------------------------------------
-- Dispatch + a light per-player rate limit (a reply is itself a packet, so an
-- over-limit command is dropped silently). 20/sec is far above human cadence.
--
-- The limiter itself used to live here as a private copy of the same
-- fixed-window algorithm Core absorbed into RDRate - identical defaults,
-- identical fail-open policy, maintained twice. It is now the one in RDRate.
--
-- ONE BEHAVIOUR CHANGE, deliberate: RDRate keys buckets by username alone, not
-- by module, so this budget is now shared with every other RDRate consumer
-- rather than being Reclamation's private 20/sec. That is the correct shape -
-- what wants bounding is a player's total command cost to the server - but it
-- does mean a client spamming claims can throttle its own commands elsewhere
-- in the family. No observable change today (RDNet has no satellite traffic
-- yet); it becomes real at the RDNet migration, which is when a per-scope key
-- should be reconsidered if any command ends up registered below rate 5.
--
-- Disconnect pruning also moves: RDRate hooks OnDisconnect and
-- OnPlayerDisconnect itself, so the local cleanup here is gone rather than
-- duplicated.
-- ---------------------------------------------------------------------------
local RATE_MAX = 20

-- An unrecognised command used to return in silence, and that silence is what
-- cost 2026-08-03: the dedi was running a REVERTED RCServer.lua with no fleet /
-- lifecycle / settuning handlers, so the client's requests landed here, matched
-- nothing, and vanished. The tab waited on a reply that was never coming and
-- the only symptom anywhere was an empty list.
--
-- A version-skewed client is the normal cause and it is worth one line each.
-- BOUNDED, though, and deliberately: this sits BEFORE the rate limit (an
-- unknown command never reaches RDRate), so an unbounded report would be a
-- log-flood vector for any client that can invent names. One line per distinct
-- command, and no more than UNKNOWN_CAP distinct names for the whole session.
local UNKNOWN_CAP = 24
local unknownSeen, unknownCount = {}, 0

local function reportUnknown(command, player)
    if unknownSeen[command] or unknownCount >= UNKNOWN_CAP then return end
    unknownSeen[command] = true
    unknownCount = unknownCount + 1
    print(string.format(
        "[RC] !! UNKNOWN COMMAND '%s' from %s - this server's RCServer.lua does not "
        .. "implement it. Usually a version skew: the client is newer than the server's "
        .. "mod tree (a Steam workshop re-validate reverts the dedi to the published "
        .. "build). Re-deploy and RESTART. Reported once per command name.",
        tostring(command),
        tostring(player and player.getUsername and player:getUsername() or "?")))
    if unknownCount >= UNKNOWN_CAP then
        print("[RC] !! unknown-command reporting capped at "
            .. UNKNOWN_CAP .. " distinct names for this session.")
    end
end

local function onClientCommand(module, command, player, args)
    if module ~= M then return end
    local h = handlers[command]
    if not h then
        reportUnknown(command, player)
        return
    end
    if not RDRate.allow(player, RATE_MAX, 1000) then return end
    local ok, err = pcall(h, player, args or {})
    if not ok then print("[RC] handler error (" .. tostring(command) .. "): " .. tostring(err)) end
end
Events.OnClientCommand.Add(onClientCommand)

print("[RC] RCServer loaded (v" .. tostring(RCShared.VERSION) .. ")")
