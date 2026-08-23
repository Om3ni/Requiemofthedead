-- SPDX-License-Identifier: GPL-3.0-or-later
-- RCShared - the brain stem, loaded on both client and server.
--
-- Owns: the net-command module token, the cached sandbox-config accessor
-- (read once, defaults baked in), the [RC] debug tracer, and tiny pure
-- helpers that several files need (wreck / trailer detection, staff check).
-- Deliberately has NO state of its own beyond the config cache.

RCShared = RCShared or {}

-- Net-command module string. Every client<->server command for this mod
-- travels under this token: sendClientCommand(player, RCShared.MODULE, cmd, args).
RCShared.MODULE  = "RFTDReclamation"
RCShared.VERSION = "1.2.1"   -- 1.0.0: suite lockstep; NoVanilla - vanilla-spawn suppression
                             -- (zone strip + story burnt-swap). 0.7.0: RFTDCore adoption
                             -- (hard require) - dual-write audit + RC.* chronicle events.

-- ---------------------------------------------------------------------------
-- RFTDCore adoption (hard require - no guards, per family law). Register with
-- the family version handshake and claim the RC.* chronicle namespace. The
-- namespace is additive-only within a season: the planned vehicle-economy
-- events (token mint/redeem) join this table when they are built, free.
-- ---------------------------------------------------------------------------
-- LOAD ORDER (landmine, verified 42.19): the CLIENT walks media/lua/shared
-- ALPHABETICALLY ACROSS ALL MODS, and "RCShared.lua" sorts before Core's
-- "RDShared.lua"/"RDEvents.lua" - both would be nil below. require() pulls
-- Core's files forward; no-op if the walk already ran them. (The dedi resolves
-- require= into mod order and loads Core first, so this only bites clients.)
require "RDShared"
require "RDEvents"

RDShared.registerMod(RCShared.MODULE, RCShared.VERSION)
RDEvents.registerNamespace("RC", RCShared.MODULE, {
    VEHICLE_CLAIM   = { scope = "p", req = { "claimId" }, loc = {} },
    VEHICLE_RELEASE = { scope = "p", req = { "claimId" }, loc = {} },
    VEHICLE_EXPIRE  = { scope = "p", req = { "claimId" }, loc = {} },
})

-- ---------------------------------------------------------------------------
-- Sandbox config (cached). SandboxVars are fixed for a session; we read them
-- once and bake the defaults in so every caller sees the same resolved values.
--
-- LIVE TUNING OVERLAY (2026-08-03). The Lifecycle tab edits these dials at
-- runtime, so a value now resolves in two layers: an override table wins, and
-- SandboxVars is the floor underneath it. Three things make that safe:
--
--   * The overlay is a PLAIN LUA TABLE here, deliberately. RCTuning (server)
--     owns where it persists and RCServer owns who may write it; this file
--     only knows how to READ one. That keeps the schema, the authority and
--     the accessor in three separate places instead of one god-object.
--   * cfg() is CACHED (the `if cfg then` below), so an override that is not
--     followed by clearCfg() changes nothing at all. setOverrides() therefore
--     clears the cache itself rather than trusting every caller to remember -
--     a silently-stale cfg is exactly the class of bug that makes a tuning
--     panel lie about what the server is doing.
--   * SandboxVars is never written. The sandbox file is the admin's stated
--     intent and lives outside Lua's writable jail anyway; overrides are a
--     save-scoped layer on top, so wiping them restores the sandbox exactly.
--
-- Clients keep their own copy, pushed by the server on change, so the
-- decorative client-side gates (hiding tools) agree with the authoritative
-- server-side ones. A client that misses the push is cosmetically stale and
-- self-corrects on the next push or relog - the server still gates.
-- ---------------------------------------------------------------------------
local cfg
local overrides = {}

-- Replace the whole override set and invalidate the cache. Whole-set rather
-- than per-key so the server can push one authoritative snapshot and a client
-- can never end up holding a half-applied mixture of two different pushes.
function RCShared.setOverrides(t)
    overrides = (type(t) == "table") and t or {}
    RCShared.clearCfg()
end

function RCShared.getOverrides() return overrides end

local function parseCSV(s)
    local set = {}
    if type(s) == "string" then
        for token in string.gmatch(s, "[^,]+") do
            local t = token:gsub("^%s+", ""):gsub("%s+$", "")
            if t ~= "" then set[string.lower(t)] = true end
        end
    end
    return set
end

-- Admin-writable flavor text: trim, and hard-cap the length in ONE place so
-- both consumers (halo + tooltip) stay one-liners no matter what gets typed
-- into the server settings box. Returns nil for blank (= use the default).
local MAX_FLAVOR_CHARS = 120
local function flavorText(s)
    if type(s) ~= "string" then return nil end
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return nil end
    if #s > MAX_FLAVOR_CHARS then s = string.sub(s, 1, MAX_FLAVOR_CHARS) end
    return s
end

function RCShared.cfg()
    if cfg then return cfg end
    local raw = SandboxVars and SandboxVars.RFTDReclamation or {}
    -- Resolve one option name through the overlay. A plain function, not an
    -- __index metatable: Kahlua's handling of a FUNCTION __index is not
    -- something this suite has verified, and cfg() is on every gate in the mod
    -- - not the place to find out. Indexed per key rather than copied
    -- wholesale, because SandboxVars entries are engine-backed and iterating
    -- them is not something to rely on (the loadedScriptBodies lesson).
    local function S(k)
        local v = overrides[k]
        if v ~= nil then return v end
        return raw[k]
    end
    cfg = {
        enabled        = S("Enabled") ~= false,          -- default true
        debug          = S("Debug") == true,             -- default false
        claimsEnabled  = S("ClaimsEnabled") ~= false,    -- default true
        maxClaims      = tonumber(S("MaxClaims")) or 2,  -- motor vehicles; 0 = unlimited
        maxTrailers    = tonumber(S("MaxClaimTrailers")) or 1, -- trailers, own pool; 0 = unlimited
        maxAllowed     = tonumber(S("MaxAllowed")) or 8,
        inactivityDays = tonumber(S("ClaimInactivityDays")) or 14, -- real days, 0 = never
        exemptUsers    = parseCSV(S("ClaimExemptUsers")), -- set keyed by lowercase username
        -- dismantle + engine-lock slice
        adminOnlyDismantle = S("AdminOnly") == true,               -- default false
        engineThreshold    = tonumber(S("EngineThreshold")) or 40, -- engine cond >= this blocks
        engineTooGoodText  = flavorText(S("EngineTooGoodText")),   -- nil = translated default
        dismantleTimePct   = tonumber(S("DismantleTimePercent")) or 100,
        engineLockEnabled  = S("EngineLockEnabled") ~= false,      -- default true
        respectClaims      = S("RespectClaims") ~= false,          -- default true
        respectPhunZones   = S("RespectPhunZones") ~= false,       -- default true
        -- janitor (abandoned-vehicle reclamation -> token pools)
        janitorEnabled = S("JanitorEnabled") ~= false,             -- default true
        janitorDays    = tonumber(S("JanitorAbandonDays")) or 14,  -- REAL days; fractions ok; 0 = off
        janitorBudget  = tonumber(S("JanitorFeedsBudget")) or 3,   -- max reclaims per sweep
        -- staff vehicle spawner
        spawnerEnabled = S("SpawnerEnabled") ~= false,             -- default true
        spawnerAccess  = tonumber(S("SpawnerAccess")) or 2,        -- 1=admin, 2=+moderator, 3=all staff
        spawnerMissingMax = tonumber(S("SpawnerMissingPartsMax")) or 6, -- "Missing parts" tick: max N stripped/spawn
        -- vanilla-spawn suppression (RCNoVanilla.lua)
        -- Default OFF, and it is the one suppression dial that must be: the
        -- strip is destructive and irreversible for the session (Layer 1 nils
        -- the zone entries, VehicleType then snapshots the table), so a default
        -- of ON means a server that never touched the setting still cannot get
        -- vanilla cars back without a restart. Opt in, deliberately.
        noVanillaVehicles = S("NoVanillaVehicles") == true,        -- default false; map spawns
        noVanillaStories  = S("NoVanillaStoryVehicles") ~= false,  -- default true; story spawns -> burnt hulls
        noVanillaRetrofit = S("NoVanillaRetrofit") == true,        -- default false; convert SAVED vanilla cars in place
        -- REPLACEMENT LIFECYCLE (RCRespawn.lua): reclaimed/destroyed cars mint
        -- tokens, a metered worker spends tokens back into the world near
        -- players who have nothing.
        respawnEnabled     = S("RespawnEnabled") ~= false,             -- default true
        respawnPerSweep    = tonumber(S("RespawnPerSweep")) or 2,      -- placements per hourly pass; 0 = paused
        respawnMinDist     = tonumber(S("RespawnMinDistance")) or 40,  -- tiles: never in a player's lap
        respawnMaxDist     = tonumber(S("RespawnMaxDistance")) or 250, -- tiles: outward search limit
        respawnModdedOnly  = S("RespawnModdedOnly") ~= false,          -- default true; no vanilla in the lifecycle
        respawnCondition   = tonumber(S("RespawnCondition")) or 4,     -- 1 random 2 perfect 3 average 4 low
        respawnOnDestroy   = S("RespawnOnDestruction") ~= false,       -- default true; wreck-transition minting
    }
    return cfg
end

-- Drop the cache so the next cfg() re-reads SandboxVars (e.g. admin edits mid-session).
function RCShared.clearCfg() cfg = nil end
Events.OnGameStart.Add(RCShared.clearCfg)
if Events.OnServerStarted then Events.OnServerStarted.Add(RCShared.clearCfg) end

-- ---------------------------------------------------------------------------
-- Debug tracer. Gated on the Debug sandbox option; self-prefixes [RC].
-- ---------------------------------------------------------------------------
function RCShared.dbg(fmt, ...)
    if not RCShared.cfg().debug then return end
    if select("#", ...) > 0 then
        print("[RC] " .. string.format(fmt, ...))
    else
        print("[RC] " .. tostring(fmt))
    end
end

-- Throttled trace: like dbg but coalesced to ~1 line/second PER key, so it can
-- sit on a hot path (gate isValid that fires every tick) without flooding the
-- log. Use a distinct key per call site. Side (client/server) is prefixed so
-- client and server lines are distinguishable in a merged log.
local lastTrace = {}
local SIDE = isServer() and "srv" or "cl"
function RCShared.trace(key, fmt, ...)
    if not RCShared.cfg().debug then return end
    local now = os.time()
    if lastTrace[key] and (now - lastTrace[key]) < 1 then return end
    lastTrace[key] = now
    local msg = (select("#", ...) > 0) and string.format(fmt, ...) or tostring(fmt)
    print("[RC][" .. SIDE .. "] " .. msg)
end

-- ---------------------------------------------------------------------------
-- Missing-dependency report.
--
-- Several surfaces call a sibling module behind `if RCX then RCX.f() end`. The
-- guard itself is right - a half-deployed tree must not throw on every packet -
-- but on its own it is SILENT, and a silently dropped request is indisting-
-- uishable from a healthy server with nothing to say.
--
-- 2026-08-03 is what this costs: Steam re-validated the workshop item and
-- reverted the dedi's tree to the PUBLISHED build. Brand-new files survived
-- (nothing upstream to revert them to) but RCServer.lua went back to a copy
-- with no fleet/lifecycle/settuning handlers. RCFleet.lua sat on disk with
-- nothing able to call it, the Vehicles tab read "Requesting fleet..." forever,
-- and the only clue anywhere was the absence of a reply. Hours went into
-- reading UI code for a bug that was never in it.
--
-- So an absent module says so, LOUDLY - and exactly once per module per
-- session. Once, because these guards sit in per-packet and per-sweep paths:
-- a line per call would bury the first one under thousands of copies, which is
-- its own kind of silence. Unconditional, NOT gated on the Debug option - the
-- whole point is to be seen on a server nobody thought to put in debug.
--
-- Returns the module (truthy) or nil, so it drops into the guard position:
--     if RCShared.need("RCFleet", RCFleet, "...") then RCFleet.begin(...) end
-- ---------------------------------------------------------------------------
local reportedMissing = {}
function RCShared.need(name, mod, consequence)
    if mod ~= nil then return mod end
    if not reportedMissing[name] then
        reportedMissing[name] = true
        print(string.format(
            "[RC] !! MISSING MODULE: %s is not loaded - %s. The mod tree is incomplete "
            .. "or out of date (a Steam workshop re-validate reverts it to the published "
            .. "build); re-deploy and RESTART. Reported once per module per session.",
            tostring(name),
            tostring(consequence or "the features that depend on it will not respond")))
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Pure helpers
-- ---------------------------------------------------------------------------

local function scriptName(vehicle)
    if not vehicle then return nil end
    -- field return (BaseVehicle.java:1593); may be nil, never throws
    return vehicle:getScriptName()
end

-- Burnt/Smashed hull. Wrecks are exempt from claiming (and dismantle later).
function RCShared.isWreck(vehicle)
    local name = scriptName(vehicle)
    if not name then return false end
    return string.contains(name, "Burnt") or string.contains(name, "Smashed")
end

-- Trailers ARE BaseVehicle; vanilla's own TowMenu.isTrailer keys off the name.
function RCShared.isTrailer(vehicle)
    local name = scriptName(vehicle)
    return (name ~= nil) and string.contains(name, "Trailer") or false
end

-- Display name for a vehicle script: drop the module prefix and space out the
-- CamelCase ("Base.PickUpVanMccoy" -> "Pick Up Van Mccoy"). Lives here because
-- two surfaces render vehicle names to players - the fleet panel and the admin
-- vehicles tab - and they must not disagree about what a car is called.
-- (RCMyVehicles still carries its own twin of this; it migrates the next time
-- that file is touched. Incremental adoption, same as DFKit's.)
function RCShared.prettyVehicleName(scriptName)
    if not scriptName or scriptName == "" then return "?" end
    local s = scriptName:gsub("^%a+%.", "")
    s = s:gsub("_", " ")
    s = s:gsub("(%l)(%u)", "%1 %2")
    return s
end

-- Float a halo message over a character. Client-side use only (HaloTextHelper
-- is client UI). Green for confirmations, red for denials. Uses the verified
-- int-color overload addText(player, text, separator, r, g, b) - the float
-- form does NOT exist and would throw+log on every call.
function RCShared.halo(character, text, isError)
    if not character or not text then return end
    local r, g, b = 100, 255, 100
    if isError then r, g, b = 255, 90, 90 end
    HaloTextHelper.addText(character, text, "", r, g, b)
end

-- Halo variant for IN-CHARACTER thoughts ("I shouldn't do this..."). PZ has
-- no italic font or <i> tag on any text surface, so the convention here is
-- the next best representation: a soft blue-white instead of alarm red - the
-- character musing, not the system refusing.
function RCShared.haloThought(character, text)
    if not character or not text then return end
    HaloTextHelper.addText(character, text, "", 190, 205, 255)
end

-- Staff bypass everything (interaction lock + claim cap). Matches the levels
-- PZ exposes from IsoPlayer:getAccessLevel().
function RCShared.isAdmin(player)
    if not player or not player.getAccessLevel then return false end
    local a = player:getAccessLevel()
    if not a then return false end
    a = string.lower(tostring(a))
    return a == "admin" or a == "moderator" or a == "overseer" or a == "gm" or a == "observer"
end

-- Spawner access ladder (sandbox-tunable). Rank: admin=1, moderator=2, all
-- other staff=3; SpawnerAccess picks the deepest rank allowed in. Shared
-- because the client uses it to HIDE the tools (decorative) and the server
-- uses it to GATE the command on the trusted sender (authoritative) - one
-- brain, so the two can never diverge.
local SPAWNER_RANK = { admin = 1, moderator = 2, overseer = 3, gm = 3, observer = 3 }

-- Reclamation's two text ledgers (RCAudit, RCDamageAudit) write wire-supplied
-- values into "k=v k=v" lines, where a newline forges a whole extra row. The
-- mechanism is Core's - StaffTools' tab-delimited override file has the same
-- exposure - so this is a named alias for it rather than a second copy.
RCShared.ledgerSafe = RDShared.textSafe

function RCShared.spawnerRank(player)
    if not player or not player.getAccessLevel then return nil end
    local a = player:getAccessLevel()
    if not a then return nil end
    return SPAWNER_RANK[string.lower(tostring(a))]
end

function RCShared.canUseSpawner(player)
    local c = RCShared.cfg()
    if not c.enabled or not c.spawnerEnabled then return false end
    local r = RCShared.spawnerRank(player)
    return r ~= nil and r <= c.spawnerAccess
end

-- ---------------------------------------------------------------------------
-- Dismantle gates (DESIGN §1). Shared because the client menus, the timed
-- action's isValid backstop, and the admin tab all consult the same brain -
-- the same UX/enforcement split the claim system uses.
-- ---------------------------------------------------------------------------

-- Claim gate: a CLAIMED vehicle cannot be dismantled until it is RELEASED -
-- even by its owner. The two-step (release, then scrap) is deliberate, not
-- friction: it makes self-dismantle a conscious act and kills the "I
-- accidentally dismantled my car, can you respawn it?" ticket. Do not
-- "improve" this into a one-click auto-release.
--   nil -> no block · "self" -> caller's own claim (release first)
--   "other" -> someone else's claim (off-limits)
-- Staff get a field override (their dismantles still hit the ledger).
function RCShared.claimDismantleBlock(vehicle, player)
    if not RCShared.cfg().respectClaims then return nil end
    if not (RCClaim and RCClaim.isClaimed(vehicle)) then return nil end
    if RCShared.isAdmin(player) then return nil end
    local owner = RCClaim.getOwner(vehicle)
    local name = player and player.getUsername and player:getUsername()
    if owner == name then return "self" end
    return "other"
end

local phunZoneFaultSaid = false

-- PhunZones gate: a zone with "No Vehicle Dismantle" ticked blocks NON-WRECK
-- dismantle (wreck cleanup is always allowed - callers skip this for wrecks).
-- RCPhunZones registers the field on PhunZones' schema; here we only read it.
-- Inert without PhunZones2.
function RCShared.phunZoneBlocks(x, y)
    if not RCShared.cfg().respectPhunZones then return false end
    if not (PhunZones and PhunZones.getLocation) then return false end
    -- guarded: foreign-mod callback - PhunZones' internals are not ours to trust
    local ok, zone = pcall(PhunZones.getLocation, x, y)
    if not ok then
        if not phunZoneFaultSaid then
            phunZoneFaultSaid = true
            print("[RC] PhunZones lookup failed; dismantle zone gate is open: "
                .. tostring(zone))
        end
        return false
    end
    if not zone then return false end
    local v = zone.reclamationNoDismantle
    -- the zone editor may persist the flag as a boolean or a string
    return v == true or v == "true" or v == "1"
end

-- Engine gate: dismantle is blocked while the Engine PART condition sits at
-- or above EngineThreshold - it must be worn below the bar first (in practice
-- mostly crashes do that; this is what makes field-dismantle a trickle, not a
-- farm). Uses getPartById("Engine"):getCondition(), NOT getEngineQuality
-- (quality stat, not wear). Wrecks exempt; trailers have no engine (cond=nil)
-- and are never blocked. Returns blocked, condition.
function RCShared.engineBlocksDismantle(vehicle)
    if not vehicle then return false, nil end
    if RCShared.isWreck(vehicle) then return false, nil end
    -- getPartById is a null-checked map read, getCondition a field return
    -- (VehicleParts.java:125, VehiclePart.java:891)
    local eng = vehicle:getPartById("Engine")
    local cond = eng and eng:getCondition()
    if cond == nil then return false, nil end
    return cond >= RCShared.cfg().engineThreshold, cond
end

-- Empty every vehicle-part container onto the vehicle's square before
-- teardown - loot is NEVER vaporized. Per-item pcall guarded: one bad item
-- must not abort the rest of the dump (the Nep lesson). The InventoryItem
-- overload of AddWorldInventoryItem transmits each drop - that is the vanilla
-- loot idiom (dedi-verified retrievable pre-scrape) and a one-shot burst on a
-- rare event, not a recurring network cost.
function RCShared.dumpVehicleContainers(vehicle, removedVehicleSquare)
    if not vehicle then return 0 end
    local square = removedVehicleSquare or vehicle:getSquare()
    if not square then return 0 end
    local dumped, failed, firstErr = 0, 0, nil
    -- the part walk and container reads are bounds-checked field returns
    -- (VehicleParts.java:111, VehiclePart.java:99); only the drop itself throws
    local count = vehicle:getPartCount()
    for i = 0, count - 1 do
        local part = vehicle:getPartByIndex(i)
        local container = part and part:getItemContainer()
        if container then
            -- snapshot first: never mutate the Java list while walking it
            local items = container:getItems()
            local grab = {}
            for j = 0, items:size() - 1 do grab[#grab + 1] = items:get(j) end
            for _, it in ipairs(grab) do
                -- No pcall - the InventoryItem overload of
                -- AddWorldInventoryItem returns the item itself on every
                -- normal path and has no null return of its own
                -- (IsoGridSquare.java:5406-5485), so a nil back means the
                -- body faulted, swallowed and stack-traced by MethodCaller
                -- (MethodCaller.java:33-56). That return IS the loot-loss
                -- diagnostic the old guard promised and could never deliver -
                -- its throw never reached Lua, so `failed` had never counted.
                -- A nil is counted as UNCONFIRMED, not absent: the square
                -- mutates at :5474-5475 before the last throw-capable lines
                -- (:5476-5483), so the item may be on the ground; never
                -- re-add it.
                container:Remove(it)
                local placed = square:AddWorldInventoryItem(it,
                    ZombRandFloat(0.1, 0.9), ZombRandFloat(0.1, 0.9), 0)
                if placed then
                    dumped = dumped + 1
                else
                    failed = failed + 1
                    firstErr = firstErr or "AddWorldInventoryItem faulted (see engine trace)"
                end
            end
        end
    end
    if failed > 0 then
        print(string.format(
            "[RC] dump: %d item(s) UNCONFIRMED while emptying %s - removed from the "
            .. "container, ground placement unverified (first: %s)",
            failed, tostring(vehicle:getScriptName()), tostring(firstErr)))
    end
    return dumped
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
