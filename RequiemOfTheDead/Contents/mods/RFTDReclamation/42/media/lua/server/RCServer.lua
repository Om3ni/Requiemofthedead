-- SPDX-License-Identifier: GPL-3.0-or-later
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
require "RCDismantleAuthority"

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
        -- No guard, and the premise was refuted at both ends. The serialization
        -- it feared is already contained: every packet send runs setData and
        -- sendToConnection inside the engine's own try/catch, which logs and
        -- swallows any Exception per connection (INetworkPacket.java:127-137),
        -- so an unserializable modData value written by a foreign mod cannot
        -- reach us. A vehicle removed between queue and flush is handled too -
        -- transmitModData returns immediately for a null square
        -- (IsoObject.java:4469-4471).
        --
        -- And the shape was wrong regardless: what remains unguarded in there
        -- is the connections walk (INetworkPacket.java:174-181), whose failure
        -- would be SYSTEMIC - null udpEngine, or a concurrent modification -
        -- hitting every vehicle in the batch identically. Per-vehicle isolation
        -- buys nothing against a failure that is not per-vehicle. §2: a guard
        -- earns its place by granularity, and there is none here.
        veh:transmitModData()
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
    -- Wire value VALIDATED rather than guarded: getVehicleById takes an int
    -- (LuaManager.java:8208-8211), so a non-number fails the Kahlua coercion at
    -- the call boundary. tonumber() is the deterministic precondition, and a
    -- bad id now falls through to the claimId path exactly as an unknown id
    -- already did.
    local vid = tonumber(args.vehicleId)
    if vid then
        local v = getVehicleById(vid)
        if v then return v end
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
            -- Inspector fields for the player panel's My Vehicles tab - the
            -- same facts a fleet row carries (RCFleet.buildRow), because the
            -- tab draws the same diagram. vid keys the parts cache client-
            -- side; overlay/kind drive the diagram family ladder; engine is
            -- the one-glance summary. Loaded cars only: an unloaded car has
            -- no object to read, which is exactly why the tab greys its
            -- inspector pane on loaded=false.
            rec.vid = v:getId()
            local eng = v:getPartById("Engine")
            if eng then rec.engine = math.floor(eng:getCondition()) end
            rec.kind = RCShared.isWreck(v) and "wreck"
                or (RCShared.isTrailer(v) and "trailer" or "car")
            -- getScript/getCarMechanicsOverlay are field returns
            -- (BaseVehicle.java:1403, VehicleScript.java:2224); only the
            -- script can be nil.
            local vs = v:getScript()
            local overlay = vs and vs:getCarMechanicsOverlay()
            if overlay and overlay ~= "" then rec.overlay = tostring(overlay) end
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
-- Gated on the server's own debug switch since 2026-08-19.
--
-- This returned a vehicle's full claim state - owner, every whitelisted
-- username, and each of their permission flags - to any client that named an id,
-- with no access check of ANY kind, and printed a console line per request
-- besides. resolveVehicle also accepts args.claimId, so the surface was
-- enumerable two ways.
--
-- The gate is cfg().debug rather than isAdmin deliberately. The client only
-- offers this option when debug is on, and it offers it REGARDLESS of the
-- caller's access on purpose, so a locked-out tester can inspect why a car
-- refuses them (RCClaimMenu.lua:140-141). Mirroring the client's own gate
-- server-side preserves that workflow exactly while closing the endpoint on
-- every ordinary server, where debug is off and nothing legitimate calls it.
local function hDumpClaim(player, args)
    if not RCShared.cfg().debug then return end
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
-- Dismantle authority + engine-lock telemetry (DESIGN §1/§2).
-- ---------------------------------------------------------------------------

local function hAuthoritativeDismantle(player, args)
    -- One explicit permit request; completion travels through Build 42's native
    -- NetTimedAction and is therefore absent from this client-command surface.
    if not RDRate.allow(player, 6, 5000, M .. ".dismantled") then
        sendServerCommand(player, M, "DismantleRefused", {
            vehicleId = args.vehicleId,
            key = RCDismantleAuthority.reasonKey("rate"),
        })
        return
    end

    if args.stage == "begin" then
        local result = RCDismantleAuthority.begin(player, args)
        if result.ok then
            sendServerCommand(player, M, "DismantlePermit", {
                vehicleId = result.vehicleId,
                ticket = result.ticket,
                expiresAt = result.expiresAt,
            })
        else
            sendServerCommand(player, M, "DismantleRefused", {
                vehicleId = result.vehicleId or args.vehicleId,
                key = RCDismantleAuthority.reasonKey(result.reason),
            })
            RCDismantleAuthority.auditRefusal(player, result)
        end
        return
    end

    local result = { stage = tostring(args.stage), reason = "stage" }
    notify(player, RCDismantleAuthority.reasonKey(result.reason), true)
    RCDismantleAuthority.auditRefusal(player, result)
end

-- Compatibility/report path for the admin tab's already-authorized deletes and
-- old clients. New field dismantles request a permit above; engine-native timed
-- action completion never returns through this client-command surface.
local function hDismantledReport(player, args)
    local staff = RCShared.isAdmin(player)
    local reportedDelete = args.delete == true
    local acceptedDelete = reportedDelete and staff

    local claimMutation = "none"
    if args.claimId ~= nil or args.owner ~= nil then
        if not staff then
            claimMutation = "refused-nonstaff"
        elseif type(args.owner) ~= "string" or args.owner == ""
            or type(args.claimId) ~= "string" or args.claimId == "" then
            claimMutation = "refused-malformed"
        elseif not RCRegistry.owns(args.owner, args.claimId) then
            claimMutation = "refused-mismatch"
        else
            -- Local in-memory table mutation after exact owner/id proof;
            -- RCRegistry.remove has no recoverable failure path.
            RCRegistry.remove(args.owner, args.claimId)
            claimMutation = "pruned"
        end
    end

    local tokenMutation = "none"
    if not reportedDelete and not args.wreck and type(args.vehicle) == "string"
        and args.vehicle ~= "" then
        if staff then
            local kind = string.contains(args.vehicle, "Trailer") and "trailer" or "vehicle"
            RCRegistry.addToken(kind)
            tokenMutation = "minted-" .. kind
        else
            -- A plain report cannot prove the separate vanilla removal occurred.
            tokenMutation = "refused-unverified"
        end
    end

    RCAudit.log(acceptedDelete and "VEHICLE-DELETE" or "DISMANTLE", player, {
        vehicle = args.vehicle, wreck = args.wreck and true or false,
        via = args.via or "field", x = args.x, y = args.y, z = args.z,
        engine = args.engine, owner = args.owner, claimId = args.claimId,
        cheat = args.cheat,   -- e.g. "eternal-torch" (staff no-wear dismantle)
        authority = staff and "staff" or "player-audit-only",
        claimMutation = claimMutation,
        tokenMutation = tokenMutation,
        flag = (reportedDelete and not staff) and "UNAUTHORIZED-DELETE-REPORT" or nil,
    })
end

-- THE STAGE-LESS SHAPE IS REFUSED FROM THE WIRE (2026-08-19, with approval).
--
-- `dismantled` has two shapes. The staged one carries args.stage and goes to
-- hAuthoritativeDismantle, which is rate-limited per player. The stage-less one
-- fell through to hDismantledReport, and a comment above that function called it
-- a "compatibility path for the admin tab's already-authorized deletes and old
-- clients". That comment is stale: the ONLY sender of this command anywhere in
-- the suite is RCDismantleMenu.lua:80, and it always sends stage = "begin".
-- The admin tab moved to dismantledMany; field completion goes server-side
-- through RCDismantleAuthority.finish and never touches the wire.
--
-- What accepting it cost: every state change in hDismantledReport already
-- refuses non-staff (claimMutation = "refused-nonstaff", tokenMutation =
-- "refused-unverified"), so the world was never at risk - but the LEDGER ROW is
-- written either way, from wire-supplied fields. Any player could hand-craft
-- this message and mint audit entries of their choosing, including ones reading
-- as though somebody defeated an engine lock. That ledger is what an admin
-- reads to settle a griefing dispute, so a forgeable row is worse than none.
--
-- hDismantledReport itself is untouched and still called internally by
-- hDismantledMany, which is staff-gated at its own door. Only the wire door
-- closes here.
local function hDismantled(player, args)
    if args.stage == nil then
        RCAudit.log("DISMANTLE-STAGELESS-REFUSED", player, {
            vehicle = args and args.vehicle, via = args and args.via,
        })
        return
    end
    hAuthoritativeDismantle(player, args)
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
-- and each accepted staff report may prune one exact indexed claim, so an
-- unbounded list would be an unbounded write loop on the tick thread.
local DISMANTLE_BATCH_MAX = 16

local function hDismantledMany(player, args)
    local list = args and args.reports
    if type(list) ~= "table" then return end

    -- STAFF ONLY: this is the admin panel's destructive batch. The per-report
    -- handler still verifies each exact owner/claim pair, but only a staff sender
    -- may reach that mutation policy at all.
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
            -- RETAINED, one member of an independent batch, and the stakes are
            -- named because they are unusually high: each entry ledgers a car
            -- the client has ALREADY destroyed in the world. Abandoning the
            -- batch on one malformed entry leaves the rest destroyed and
            -- unledgered - a partial success that is genuinely valid here,
            -- because a ledgered car and a lost one are not equally bad.
            local ok, err = pcall(hDismantledReport, player, rep)
            if not ok then print("[RC] dismantledMany entry failed: " .. tostring(err)) end
        end
    end
end

-- Engine parts actually pulled (RCEngineLock's ISTakeEngineParts telemetry).
-- The lock should stop every non-staff player BEFORE this point, so a
-- BYPASS-flagged line = a defeated client. admin is decided by OUR access
-- check on the sender - the client's word is never consulted.
-- The identity is RE-DERIVED, not believed. `flag` and `admin` were always
-- server-computed, but everything describing WHICH engine was pulled came
-- straight off the wire with no vehicle resolution at all - so any non-staff
-- client could mint unlimited rows reading "BYPASS-block-defeated" against
-- vehicles and coordinates of its choosing, and that flag is the whole
-- evidentiary basis of the engine-lock design (RCEngineLock.lua:11-14).
--
-- Resolving the id first costs nothing legitimate: the one real sender
-- (RCEngineLock.lua:94-95) reports a vehicle it has just finished working on,
-- so it resolves. A row that cannot be resolved is still recorded - silence
-- would be its own blind spot - but it is labelled as unresolved rather than
-- dressed up with attacker-supplied coordinates.
local function hEnginePull(player, args)
    local admin = RCShared.isAdmin(player)
    local bypass = RCShared.cfg().engineLockEnabled and not admin
    local v = getVehicleById(tonumber(args and args.vid))
    if not v then
        RCAudit.log("ENGINE-PULL", player, {
            vid = args and args.vid, resolved = "no",
            admin = admin, flag = bypass and "BYPASS-block-defeated" or "-",
        })
        return
    end
    RCAudit.log("ENGINE-PULL", player, {
        vehicle = v:getScriptName(), vid = v:getId(),
        x = math.floor(v:getX()), y = math.floor(v:getY()), z = math.floor(v:getZ()),
        resolved = "yes",
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
-- PROXIMITY IS THE PRECONDITION. Attribution decides which vehicles the
-- reclamation sweep will spare, so naming any loaded id used to be enough to
-- become a vehicle's recognised keeper AND restart its idle clock - one forged
-- packet per id, and a client could immunise the server's entire reclaimable
-- fleet against Presence Law.
--
-- Distance rather than a driver check, deliberately. The legitimate sender
-- already filters to driver-only client-side (RCUsage.lua:33) and fires from
-- OnEnterVehicle, which the file notes runs after the seat is set - so the
-- server can process the packet before its own seat state agrees, or just after
-- a fast exit. A strict getDriver() test would intermittently drop honest
-- attributions and bring back the hotwired-daily-driver bug this feature exists
-- to fix. Being NEAR the car you just got into is true in every legitimate case
-- and false for an id you picked off a list, which is the distinction that
-- matters. MAX_USE_DISTANCE_SQ matches RCDismantleAuthority's proven envelope.
local MAX_USE_DISTANCE_SQ = 16

local function hUsed(player, args)
    if not (player and args and args.vehicleId) then return end
    local name = player:getUsername()
    if not name then return end
    RCRegistry.notePresence(name)

    local v = resolveVehicle(args)
    if not v then return end
    local dx = player:getX() - v:getX()
    local dy = player:getY() - v:getY()
    if (dx * dx + dy * dy) > MAX_USE_DISTANCE_SQ then
        RCShared.dbg("used: %s named vehicle %s from %.1f tiles away - not attributed",
            tostring(name), tostring(args.vehicleId), math.sqrt(dx * dx + dy * dy))
        return
    end

    if RCJanitor and RCJanitor.attribute then
        RCJanitor.attribute(name, v)
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

-- One of MY cars' parts, for the player panel's My Vehicles tab. The gate is
-- OWNERSHIP, not access level: the caller names a claim, the registry proves
-- it is theirs, and the vid handed to RCFleet.parts comes from the resolved
-- vehicle - never from the client - so this door opens onto exactly the cars
-- the player already owns and nothing else. Unloaded resolves to nothing and
-- stays silent: the client greys its inspector pane on loaded=false and does
-- not ask; a hand-rolled request for an unloaded claim deserves no reply.
local function hMyVehicleParts(player, args)
    local claimId = args and args.claimId
    if type(claimId) ~= "string" or claimId == "" then return end
    if not RCRegistry.owns(player:getUsername(), claimId) then return end
    local v = RCRegistry.findLoadedByClaimId(claimId)
    if not v then return end
    if RCShared.need("RCFleet", RCFleet,
        "the parts diagram will stay on 'reading parts...'") then
        RCFleet.parts(player, v:getId())
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
    myvehicleparts = hMyVehicleParts,
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
    -- No guard, and this is deliberately NOT the same call as Dragonfly's
    -- dispatcher, which keeps one. There, a client is waiting on a Result and
    -- an escaping throw answers it with nothing; that reply is the recovery.
    -- Here nothing is owed back - RCServer's handlers reply for themselves when
    -- they have something to say - so the guard bought only a one-line message
    -- in place of the full Lua stack trace the engine already writes at throw
    -- time (KahluaThread.java:865, :1100), and the listener itself is contained
    -- per-listener regardless (Event.java:53-63). Strictly less information for
    -- no protection.
    h(player, args or {})
end
Events.OnClientCommand.Add(onClientCommand)

print("[RC] RCServer loaded (v" .. tostring(RCShared.VERSION) .. ")")

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
