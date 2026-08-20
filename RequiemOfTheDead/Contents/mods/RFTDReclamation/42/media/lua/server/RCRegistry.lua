-- SPDX-License-Identifier: GPL-3.0-or-later
-- RCRegistry - the claim index (server only).
--
-- AUTHORITY MODEL (this is the important part - an earlier version got it
-- backwards and deleted claims on restart):
--   * The VEHICLE'S modData is the durable source of truth for "who owns this
--     car." It is saved with the vehicle (vehicles.db) and travels with it.
--   * This global-ModData registry is a DERIVED INDEX, kept only to answer the
--     questions per-vehicle modData can't, because a player's cars may be
--     UNLOADED: (1) how many vehicles does a player claim (MaxClaims), and
--     (2) when did a player last log in (inactivity expiry).
--   * The index REBUILDS itself from vehicle modData (syncFromVehicle) and
--     MUST NEVER delete a claim merely because the index lacks it. A claim is
--     only ever cleared on explicit unclaim, or on POSITIVE evidence the owner
--     is inactive (a persisted lastSeen that is genuinely old). Absence of
--     index data => assume active => keep the claim. This makes claims survive
--     a lost/stale registry (e.g. a save that didn't flush on a hard restart).
--
-- Two unchanged rules from before: NEVER transmitted (server-only), and never
-- iterated on a per-tick timer (only low-frequency bounded passes).
--
-- Shape:
--   reg.players[username] = { lastSeen = <real epoch>, claims = { [claimId] = {name,x,y,z} } }
--   reg.meta.heartbeat    = <real epoch>   (for server-downtime credit)

if not isServer() then return end

require "RCLoadedVehicles"

RCRegistry = RCRegistry or {}

local REG_NAME = "RC_ClaimRegistry"
local reg

local function ensure()
    if reg then return reg end
    reg = ModData.getOrCreate(REG_NAME)
    reg.players = reg.players or {}
    reg.meta    = reg.meta or {}
    return reg
end

local function entry(username, create)
    if not username then return nil end
    local r = ensure()
    local e = r.players[username]
    if not e and create then
        e = { lastSeen = os.time(), claims = {} }
        r.players[username] = e
    end
    return e
end

local function isEmpty(t)
    for _ in pairs(t) do return false end
    return true
end

-- Is this username currently in-world? Bounded by player count.
local function isOnline(username)
    if not username then return false end
    local players = getOnlinePlayers()
    if not players then return false end
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        if p and p.getUsername and p:getUsername() == username then return true end
    end
    return false
end

-- Stable claim id (the vehicle:getId()-is-not-stable fix). Generated once,
-- stored in vehicle modData, never regenerated. Caller transmits modData.
function RCRegistry.newClaimId(vehicle)
    local md = vehicle:getModData()
    local id = md[RCClaim.KEY_ID]
    if id and id ~= "" then return id end
    id = string.format("RC-%d-%04d", os.time(), ZombRand(10000))
    md[RCClaim.KEY_ID] = id
    return id
end

-- Record a fresh claim (called from the claim handler). Stores position for
-- later (admin recovery / respawn weighting). Returns the id.
function RCRegistry.add(username, vehicle)
    local e = entry(username, true)
    local id = RCRegistry.newClaimId(vehicle)
    e.claims[id] = {
        name = vehicle:getScriptName(),
        x = math.floor(vehicle:getX()),
        y = math.floor(vehicle:getY()),
        z = math.floor(vehicle:getZ()),
        seen = os.time(),   -- last time this car was confirmed loaded (orphan prune)
        -- category flag for the split cap (MaxClaims vs MaxClaimTrailers).
        -- stored as true/nil, not true/false: nil reads as "motor vehicle",
        -- which is also what pre-0.4.2 records mean until self-heal stamps them.
        trailer = RCShared.isTrailer(vehicle) or nil,
    }
    e.lastSeen = os.time()
    return id
end

function RCRegistry.remove(username, claimId)
    local e = entry(username, false)
    if e and e.claims and claimId then
        e.claims[claimId] = nil
        -- prune an empty entry (next() is unavailable in B42 Kahlua).
        if isEmpty(e.claims) then ensure().players[username] = nil end
    end
end

-- Count ONE category of a player's claims: trailers=true counts trailers,
-- else motor vehicles. Records without a category flag (pre-0.4.2, or a
-- self-heal that hasn't stamped them yet) count as motor vehicles - the
-- bigger pool, so the drift direction is the forgiving one, and it
-- self-corrects the next time the car loads.
function RCRegistry.count(username, trailers)
    local e = entry(username, false)
    if not e or not e.claims then return 0 end
    local n = 0
    for _, rec in pairs(e.claims) do
        if (rec.trailer == true) == (trailers == true) then n = n + 1 end
    end
    return n
end

-- At/over the ceiling for this vehicle's category? Trailers have their own
-- pool (MaxClaimTrailers) so a full garage doesn't block hitching a trailer,
-- and vice versa. 0 = unlimited. NOTE: right after a restart the index may
-- under-count a player's still-unloaded cars until they load and self-heal;
-- the cap is a soft protection, so a brief over-cap window is acceptable and
-- self-corrects (far better than deleting claims to keep the count "honest").
function RCRegistry.atLimit(username, trailer)
    local c = RCShared.cfg()
    local max = trailer and c.maxTrailers or c.maxClaims
    if not max or max <= 0 then return false end
    return RCRegistry.count(username, trailer) >= max
end

-- Does this player's index hold this claim? Ownership proof for My Vehicles
-- actions: the index is keyed by owner username, so a hit means the requester
-- (an authenticated sender) owns it. (A claim missing from the index - e.g. a
-- pre-registry claim - simply isn't manageable from the panel yet.)
function RCRegistry.owns(username, claimId)
    local e = entry(username, false)
    return (e and e.claims and claimId and e.claims[claimId] ~= nil) or false
end

-- The player's own slice as a plain array, safe to transmit (their data only -
-- NEVER the whole registry). Feeds the My Vehicles panel.
function RCRegistry.slice(username)
    local out = {}
    local e = entry(username, false)
    if not e or not e.claims then return out end
    for id, rec in pairs(e.claims) do
        out[#out + 1] = {
            claimId = id,
            name = rec.name,
            x = rec.x, y = rec.y, z = rec.z,
            seen = rec.seen,
            trailer = rec.trailer or false,
        }
    end
    return out
end

-- EVERY claim in the index, flattened and stamped with its owner (2026-08-02).
--
-- The staff fleet view's only route to a car nobody has streamed in: the engine
-- exposes no enumerator for unloaded vehicles, so an index walk is the whole
-- of what is knowable about them.
--
-- This does NOT breach the "never transmitted" rule above. That rule protects
-- the registry TABLE - its shape, per-player lastSeen, pending releases, the
-- token pools - none of which appear here. What comes out is a derived
-- projection of exactly the fields a fleet list renders, and RCFleet is
-- admin-gated before it ever calls this. Bounded by MaxClaims x players and
-- built on demand, never on a timer, so the second rule holds too.
function RCRegistry.allClaims()
    local out = {}
    local r = ensure()
    for username, e in pairs(r.players) do
        if e.claims then
            for id, rec in pairs(e.claims) do
                out[#out + 1] = {
                    claimId = id,
                    owner   = username,
                    name    = rec.name,
                    x = rec.x, y = rec.y, z = rec.z,
                    seen    = rec.seen,
                    trailer = rec.trailer or false,
                }
            end
        end
    end
    return out
end

-- Deferred release: an owner released an UNLOADED car from My Vehicles. We can't
-- touch its (unloaded) modData now, so we flag the claimId; syncFromVehicle
-- clears the modData the next time that vehicle loads. Stored in registry
-- ModData so it survives a restart (and if it doesn't flush, the worst case is a
-- forgotten release - the claim stays with the owner, never a wrongful loss).
function RCRegistry.markPendingRelease(claimId)
    if not claimId then return end
    local r = ensure()
    r.meta.pendingRelease = r.meta.pendingRelease or {}
    r.meta.pendingRelease[claimId] = os.time()   -- timestamp, for TTL pruning
end

-- Bound the deferred-release set - the ONE unbounded vector in an otherwise
-- current-state index. A pendingRelease flag is normally cleared when its car
-- next loads (syncFromVehicle), but a car that is destroyed or never re-loads
-- would keep the flag forever. Drop flags older than the inactivity window
-- (floored at 14 real days, so it's bounded even with expiry off). Forgetting a
-- pending release is the SAFE direction: the claim's modData is untouched, so the
-- car just stays claimed by its owner (who can release it again) - never a
-- wrongful loss. Meta-only; touches no vehicle modData. Run from the hourly pass.
function RCRegistry.prunePendingRelease()
    local r = ensure()
    local pr = r.meta.pendingRelease
    if not pr then return 0 end
    local days = RCShared.cfg().inactivityDays
    if not days or days <= 0 then days = 14 end
    local horizon = days * 86400
    local now = os.time()
    local pruned = 0
    for id, ts in pairs(pr) do
        if type(ts) == "number" then
            if (now - ts) > horizon then pr[id] = nil; pruned = pruned + 1 end
        else
            pr[id] = now   -- upgrade a legacy bool flag to a stamp so it can age out
        end
    end
    if isEmpty(pr) then r.meta.pendingRelease = nil end
    if pruned > 0 then RCShared.dbg("pending-release prune: dropped %d stale flag(s)", pruned) end
    return pruned
end

-- One bounded pass over loaded vehicles -> { [claimId] = vehicle }. Built on
-- demand for a single action (release, a perm edit, a slice request); NEVER on a
-- timer. Uses the Set :iterator() path (get(i) on the vehicle Set crashes). This
-- is the "is it loaded right now (anywhere on the server)?" oracle the fleet
-- panel needs - a car is editable only when some player has it loaded.
--
-- ALSO self-heals via syncFromVehicle on every vehicle it sees. Previously that
-- only ran on the hourly RCSession pass, so on a server with autosave off
-- (SaveWorldEveryMinutes=0 - global ModData, i.e. the registry, only flushes to
-- disk on a graceful full SaveAll) a restart before that ever fires wipes the
-- in-RAM registry with no file to reload, and "My Vehicles" reads empty for up
-- to an hour even while standing right next to an owned, loaded, still-claimed
-- car (its modData - the real source of truth - was never touched). Folding the
-- self-heal into this ALREADY-bounded on-demand pass means a fleet-panel
-- request repairs the index immediately for anything currently loaded, at zero
-- extra scan cost (one iterator pass serves both jobs).
function RCRegistry.loadedClaimMap()
    local map = {}
    -- A self-heal can transmit claim state or finish a deferred release. Only a
    -- completed self-heal may publish the vehicle as editable; a failed one is
    -- retried by the next request/hourly pass instead of exposing its stale id.
    local sweep = RCLoadedVehicles.each(function(v)
        RCRegistry.syncFromVehicle(v)
        local id = v:getModData()[RCClaim.KEY_ID]
        if id and id ~= "" then map[id] = v end
    end)
    if sweep.failed > 0 then
        print("[RC] loaded-claim map: skipped " .. sweep.failed .. " of " .. sweep.visited
            .. " vehicle(s); first error: " .. tostring(sweep.firstError))
    end
    return map
end

-- Find a currently-loaded vehicle by its stable claim id (nil if unloaded).
function RCRegistry.findLoadedByClaimId(claimId)
    if not claimId then return nil end
    return RCRegistry.loadedClaimMap()[claimId]
end

-- Refresh activity. Only updates an EXISTING entry - a player with no claims
-- has nothing to expire, so we don't create a row just to stamp them.
function RCRegistry.stampSeen(username)
    local e = entry(username, false)
    if e then e.lastSeen = os.time() end
end

function RCRegistry.updatePosition(username, claimId, vehicle)
    local e = entry(username, false)
    if e and e.claims and e.claims[claimId] then
        local c = e.claims[claimId]
        c.x = math.floor(vehicle:getX())
        c.y = math.floor(vehicle:getY())
        c.z = math.floor(vehicle:getZ())
    end
end

-- Positive-evidence inactivity test. Returns true ONLY when we are sure the
-- owner is inactive: expiry enabled, not exempt, not online, and a persisted
-- lastSeen that is genuinely older than the window. A missing/zero lastSeen
-- (e.g. an index we just self-healed after a restart) returns false - we never
-- expire on absence of evidence.
function RCRegistry.isExpired(username, e)
    local c = RCShared.cfg()
    local days = c.inactivityDays
    if not days or days <= 0 then return false end                 -- 0 = never
    if c.exemptUsers and c.exemptUsers[string.lower(username)] then return false end
    if isOnline(username) then return false end
    local last = e and e.lastSeen
    if not last or last <= 0 then return false end
    return (os.time() - last) > days * 86400
end

-- The ONLY routine that clears a claim from a vehicle (used by expiry). Wipes
-- the ownership modData (keeping RC_ClaimId for audit continuity), drops the
-- index entry, and audits. Unclaim has its own path in RCServer.
function RCRegistry.clearClaim(vehicle, owner, id, reason)
    if vehicle then
        local md = vehicle:getModData()
        md[RCClaim.KEY_OWNER]   = nil
        md[RCClaim.KEY_ALLOWED] = nil
        md[RCClaim.KEY_PUBLIC]  = nil
        md[RCClaim.KEY_USED]    = nil
        vehicle:transmitModData()
    end
    RCRegistry.remove(owner, id)
    RCAudit.log("EXPIRE", nil, {
        user = owner, claimId = id, reason = reason or "expire",
        vehicle = vehicle and vehicle:getScriptName() or "-",
    })
end

-- Reconcile the index TOWARD the vehicle's modData (modData is truth). Called
-- on loaded vehicles by the low-frequency pass. Two jobs:
--   1. Self-heal: if this claimed vehicle isn't in the index, add it. A brand
--      new player entry gets lastSeen = now (fail-safe: a lost index means a
--      lost expiry clock, so we must NOT expire). An EXISTING entry keeps its
--      persisted lastSeen, so genuine expiry still works.
--   2. Expiry: clear the claim ONLY if isExpired (positive evidence).
-- Also finishes a deferred panel-release (see pendingRelease) when the car loads.
-- Returns "expired"/"released" if it cleared the claim, else nil.
function RCRegistry.syncFromVehicle(vehicle)
    if not vehicle then return end
    local md = vehicle:getModData()
    local owner = md[RCClaim.KEY_OWNER]
    if not owner or owner == "" then return end   -- unclaimed / legacy-only: not ours to index

    local id = md[RCClaim.KEY_ID]
    if not id or id == "" then
        id = RCRegistry.newClaimId(vehicle)        -- claimed but missing an id: mint one
        vehicle:transmitModData()
    end

    local r = ensure()

    -- Deferred panel release: the owner released this car while it was unloaded;
    -- now that it's loaded we finish the job by clearing its modData. This is
    -- POSITIVE evidence (an explicit owner action), so it's a safe clear.
    if r.meta.pendingRelease and r.meta.pendingRelease[id] then
        r.meta.pendingRelease[id] = nil
        RCRegistry.clearClaim(vehicle, owner, id, "panel-release")
        return "released"
    end

    local e = r.players[owner]
    if not e then
        e = { lastSeen = os.time(), claims = {} }  -- self-heal: fresh clock => no expiry
        r.players[owner] = e
    end
    local rec = e.claims[id]
    if not rec then
        rec = {}
        e.claims[id] = rec
    end
    -- Keep the record's name + position fresh from the loaded car, so My
    -- Vehicles shows where a car actually is (not just where it was claimed).
    rec.name = vehicle:getScriptName()
    rec.x = math.floor(vehicle:getX())
    rec.y = math.floor(vehicle:getY())
    rec.z = math.floor(vehicle:getZ())
    rec.seen = os.time()   -- confirmed loaded this pass (keeps it off the orphan list)
    rec.trailer = RCShared.isTrailer(vehicle) or nil   -- category for the split cap

    if RCRegistry.isExpired(owner, e) then
        RCRegistry.clearClaim(vehicle, owner, id, "expire")
        return "expired"
    end
end

-- Heartbeat + downtime credit. The heartbeat records "the server was alive at
-- T". On boot, the gap since the last heartbeat is real downtime - we shift
-- every persisted lastSeen forward by it so an outage doesn't mass-expire. (If
-- the index didn't persist there's nothing to credit, and self-heal will set
-- lastSeen = now anyway, so this is purely a refinement, not load-bearing.)
function RCRegistry.heartbeat()
    ensure().meta.heartbeat = os.time()
end

function RCRegistry.creditDowntime()
    local r = ensure()
    local last = r.meta.heartbeat
    local now = os.time()
    if not last then r.meta.heartbeat = now; return 0 end
    local downtime = now - last
    if downtime <= 0 then r.meta.heartbeat = now; return 0 end
    for _, e in pairs(r.players) do
        if e.lastSeen and e.lastSeen > 0 then e.lastSeen = e.lastSeen + downtime end
    end
    -- Running total of all downtime ever credited. Janitor stamps record the
    -- total AT STAMP TIME and subtract the delta at eligibility time, so an
    -- outage can't age an abandoned-vehicle clock (we can't shift stamps that
    -- live in UNLOADED vehicles' modData, so the credit is applied on read).
    r.meta.downtimeTotal = (r.meta.downtimeTotal or 0) + downtime
    -- the all-players presence map gets the same shift as claim lastSeen
    if r.meta.seen then
        for u, ts in pairs(r.meta.seen) do
            if type(ts) == "number" then r.meta.seen[u] = ts + downtime end
        end
    end
    r.meta.heartbeat = now
    RCShared.dbg("downtime credit: +%d s applied to all lastSeen", downtime)
    return downtime
end

function RCRegistry.downtimeTotal()
    return ensure().meta.downtimeTotal or 0
end

-- ---------------------------------------------------------------------------
-- Presence map - lastSeen for ALL players, not just claim holders. This is
-- what lets the Janitor apply the owner's law ("if the player logs in, their
-- stuff is preserved") to UNCLAIMED vehicles attributed to a last user.
-- Bounded: one epoch per distinct username, pruned hourly past 4x the widest
-- window. Server-only, flushed with the registry.
-- ---------------------------------------------------------------------------
function RCRegistry.notePresence(username)
    if not username then return end
    local m = ensure().meta
    m.seen = m.seen or {}
    m.seen[username] = os.time()
end

-- Best lastSeen we hold for this username from EITHER source (presence map,
-- or their claim row if they have one). nil = never seen.
function RCRegistry.lastSeenAny(username)
    if not username then return nil end
    local r = ensure()
    local t = r.meta.seen and r.meta.seen[username] or nil
    local e = r.players[username]
    local c = e and e.lastSeen or nil
    if t and c then return math.max(t, c) end
    return t or c
end

function RCRegistry.prunePresence()
    local m = ensure().meta
    if not m.seen then return 0 end
    local cfgv = RCShared.cfg()
    local days = math.max(cfgv.inactivityDays or 0, cfgv.janitorDays or 0, 14)
    local horizon = days * 4 * 86400
    local now = os.time()
    local pruned = 0
    for u, ts in pairs(m.seen) do
        if type(ts) ~= "number" or (now - ts) > horizon then
            m.seen[u] = nil
            pruned = pruned + 1
        end
    end
    if isEmpty(m.seen) then m.seen = nil end
    return pruned
end

-- ---------------------------------------------------------------------------
-- Token pools (§4's currency). The Janitor and the field-dismantle trickle
-- MINT; nothing spends yet - the respawn side isn't built, so these are two
-- bounded ints quietly accumulating in registry meta (server-only, never
-- transmitted, flushed with the save like the rest of the index).
-- ---------------------------------------------------------------------------
function RCRegistry.addToken(kind)
    if kind ~= "vehicle" and kind ~= "trailer" then
        return nil, "invalid-kind"
    end

    -- Token currency is a secondary reward, not authority to remove a car.
    -- Refuse malformed persisted state explicitly so a completed dismantle can
    -- withhold the reward and remain auditable instead of throwing after the
    -- irreversible world mutation.
    local m = ensure().meta
    if type(m) ~= "table" then return nil, "registry-meta-invalid" end
    if m.tokens == nil then m.tokens = { vehicle = 0, trailer = 0 } end
    if type(m.tokens) ~= "table" then return nil, "token-pool-invalid" end

    local current = m.tokens[kind]
    if current ~= nil and (type(current) ~= "number" or current < 0
        or current ~= math.floor(current)) then
        return nil, "token-count-invalid"
    end
    m.tokens[kind] = (current or 0) + 1
    return m.tokens[kind], nil
end

-- Returns vehicleTokens, trailerTokens.
function RCRegistry.tokens()
    local t = ensure().meta.tokens
    return (t and t.vehicle) or 0, (t and t.trailer) or 0
end

-- Spend one token. The redemption half of the pool, added 2026-08-03 when
-- RCRespawn became the first spender.
--
-- Returns true only if a token was actually taken, and the caller must treat
-- false as "do nothing" rather than "spawn anyway". Deliberately spends BEFORE
-- the placement rather than after: a placement that then fails costs the pool
-- one token, which is the harmless direction. The reverse - place first, spend
-- after - lets a failure between the two mint free cars forever.
function RCRegistry.spendToken(kind)
    local m = ensure().meta
    local k = (kind == "trailer") and "trailer" or "vehicle"
    local have = m.tokens and m.tokens[k] or 0
    if have <= 0 then return false end
    m.tokens[k] = have - 1
    return true
end

-- Orphan prune (cap-correctness, NOT a storage fix - the index is already
-- KB-scale and cannot blow up like an append-log). B42 gives no vehicle-removal
-- event and no way to tell an UNLOADED claimed car from a DELETED one, so a
-- fully-safe auto-prune is impossible. This is built to be NON-DESTRUCTIVE and
-- self-correcting instead:
--   * It only removes the INDEX entry, NEVER the vehicle's claim modData. If a
--     pruned car still exists, it self-heals back into the index the next time
--     it loads (syncFromVehicle). So a false prune costs only a brief, self-
--     correcting cap slot - it can never lose a real claim.
--   * It errs hard toward keeping: it considers a claim only when the owner is
--     CURRENTLY ONLINE (strong "owner is active" signal) and the car has not
--     been confirmed loaded for a long horizon (2x the inactivity window).
--     Offline owners are never orphan-pruned (whole-account expiry covers them).
-- Coupled to expiry: off when ClaimInactivityDays = 0. Returns count pruned.
function RCRegistry.pruneOrphans()
    local days = RCShared.cfg().inactivityDays
    if not days or days <= 0 then return 0 end
    local horizon = days * 2 * 86400
    local now = os.time()

    local online = {}
    local players = getOnlinePlayers()
    if players then
        for i = 0, players:size() - 1 do
            local p = players:get(i)
            if p and p.getUsername then online[p:getUsername()] = true end
        end
    end

    local r = ensure()
    local pruned = 0
    for username, e in pairs(r.players) do
        if online[username] and e.claims then
            local gone = {}
            for id, rec in pairs(e.claims) do
                if (now - (rec.seen or now)) > horizon then gone[#gone + 1] = id end
            end
            for _, id in ipairs(gone) do
                e.claims[id] = nil   -- index only; modData claim is untouched
                pruned = pruned + 1
                RCAudit.log("ORPHAN-PRUNE", nil, { user = username, claimId = id })
            end
            if isEmpty(e.claims) then r.players[username] = nil end
        end
    end
    if pruned > 0 then RCShared.dbg("orphan prune: dropped %d index entr(ies)", pruned) end
    return pruned
end

-- Re-bind to the authoritative table AFTER global ModData has loaded, so we
-- never keep a stale empty reference created by an earlier call.
Events.OnInitGlobalModData.Add(function() reg = nil; ensure() end)

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
