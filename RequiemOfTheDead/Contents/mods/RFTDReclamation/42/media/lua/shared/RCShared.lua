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
RCShared.VERSION = "1.0.0"   -- 1.0.0: suite lockstep; NoVanilla - vanilla-spawn suppression
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
-- ---------------------------------------------------------------------------
local cfg

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
    local sv = SandboxVars and SandboxVars.RFTDReclamation or {}
    cfg = {
        enabled        = sv.Enabled ~= false,          -- default true
        debug          = sv.Debug == true,             -- default false
        claimsEnabled  = sv.ClaimsEnabled ~= false,    -- default true
        maxClaims      = tonumber(sv.MaxClaims) or 2,  -- motor vehicles; 0 = unlimited
        maxTrailers    = tonumber(sv.MaxClaimTrailers) or 1, -- trailers, own pool; 0 = unlimited
        maxAllowed     = tonumber(sv.MaxAllowed) or 8,
        inactivityDays = tonumber(sv.ClaimInactivityDays) or 14, -- real days, 0 = never
        exemptUsers    = parseCSV(sv.ClaimExemptUsers), -- set keyed by lowercase username
        -- dismantle + engine-lock slice
        adminOnlyDismantle = sv.AdminOnly == true,               -- default false
        engineThreshold    = tonumber(sv.EngineThreshold) or 40, -- engine cond >= this blocks
        engineTooGoodText  = flavorText(sv.EngineTooGoodText),   -- nil = translated default
        dismantleTimePct   = tonumber(sv.DismantleTimePercent) or 100,
        engineLockEnabled  = sv.EngineLockEnabled ~= false,      -- default true
        respectClaims      = sv.RespectClaims ~= false,          -- default true
        respectPhunZones   = sv.RespectPhunZones ~= false,       -- default true
        -- janitor (abandoned-vehicle reclamation -> token pools)
        janitorEnabled = sv.JanitorEnabled ~= false,             -- default true
        janitorDays    = tonumber(sv.JanitorAbandonDays) or 14,  -- REAL days; fractions ok; 0 = off
        janitorBudget  = tonumber(sv.JanitorFeedsBudget) or 3,   -- max reclaims per sweep
        -- staff vehicle spawner
        spawnerEnabled = sv.SpawnerEnabled ~= false,             -- default true
        spawnerAccess  = tonumber(sv.SpawnerAccess) or 2,        -- 1=admin, 2=+moderator, 3=all staff
        spawnerMissingMax = tonumber(sv.SpawnerMissingPartsMax) or 6, -- "Missing parts" tick: max N stripped/spawn
        -- vanilla-spawn suppression (RCNoVanilla.lua)
        noVanillaVehicles = sv.NoVanillaVehicles ~= false,       -- default true; map spawns
        noVanillaStories  = sv.NoVanillaStoryVehicles ~= false,  -- default true; story spawns -> burnt hulls
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
-- Pure helpers
-- ---------------------------------------------------------------------------

local function scriptName(vehicle)
    if not vehicle then return nil end
    local ok, name = pcall(function() return vehicle:getScriptName() end)
    if ok then return name end
    return nil
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

-- Float a halo message over a character. Client-side use only (HaloTextHelper
-- is client UI). Green for confirmations, red for denials. Uses the verified
-- int-color overload addText(player, text, separator, r, g, b) - the float
-- form does NOT exist and would throw+log on every call.
function RCShared.halo(character, text, isError)
    if not character or not text then return end
    local r, g, b = 100, 255, 100
    if isError then r, g, b = 255, 90, 90 end
    local ok = pcall(function() HaloTextHelper.addText(character, text, "", r, g, b) end)
    if not ok then pcall(function() character:setHaloNote(text) end) end
end

-- Halo variant for IN-CHARACTER thoughts ("I shouldn't do this..."). PZ has
-- no italic font or <i> tag on any text surface, so the convention here is
-- the next best representation: a soft blue-white instead of alarm red - the
-- character musing, not the system refusing.
function RCShared.haloThought(character, text)
    if not character or not text then return end
    local ok = pcall(function() HaloTextHelper.addText(character, text, "", 190, 205, 255) end)
    if not ok then pcall(function() character:setHaloNote(text) end) end
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

-- PhunZones gate: a zone with "No Vehicle Dismantle" ticked blocks NON-WRECK
-- dismantle (wreck cleanup is always allowed - callers skip this for wrecks).
-- RCPhunZones registers the field on PhunZones' schema; here we only read it.
-- Inert without PhunZones2.
function RCShared.phunZoneBlocks(x, y)
    if not RCShared.cfg().respectPhunZones then return false end
    if not (PhunZones and PhunZones.getLocation) then return false end
    local ok, zone = pcall(PhunZones.getLocation, x, y)
    if not ok or not zone then return false end
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
    local cond
    pcall(function()
        local eng = vehicle:getPartById("Engine")
        if eng then cond = eng:getCondition() end
    end)
    if cond == nil then return false, nil end
    return cond >= RCShared.cfg().engineThreshold, cond
end

-- Empty every vehicle-part container onto the vehicle's square before
-- teardown - loot is NEVER vaporized. Per-part AND per-item pcall guarded:
-- modded (KI5) part layouts throw on vanilla assumptions and one bad part
-- must not abort the rest of the dump (the Nep lesson). The InventoryItem
-- overload of AddWorldInventoryItem transmits each drop - that is the vanilla
-- loot idiom (dedi-verified retrievable pre-scrape) and a one-shot burst on a
-- rare event, not a recurring network cost.
function RCShared.dumpVehicleContainers(vehicle)
    if not vehicle then return 0 end
    local square = vehicle:getSquare()
    if not square then return 0 end
    local dumped = 0
    local count = 0
    pcall(function() count = vehicle:getPartCount() end)
    for i = 0, count - 1 do
        pcall(function()
            local part = vehicle:getPartByIndex(i)
            local container = part and part:getItemContainer()
            if container then
                -- snapshot first: never mutate the Java list while walking it
                local items = container:getItems()
                local grab = {}
                for j = 0, items:size() - 1 do grab[#grab + 1] = items:get(j) end
                for _, it in ipairs(grab) do
                    pcall(function()
                        container:Remove(it)
                        square:AddWorldInventoryItem(it, ZombRandFloat(0.1, 0.9), ZombRandFloat(0.1, 0.9), 0)
                        dumped = dumped + 1
                    end)
                end
            end
        end)
    end
    return dumped
end
