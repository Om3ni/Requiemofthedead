-- =============================================
-- RQSvDormant.lua - Dormant special registry (server only)
-- World-anchored identity records for converted specials, backed by the
-- global ModData table "RQDormant". Zombie objects cannot carry identity
-- across chunk unload (virtualization keeps only pos/dir/persistentOutfitID/
-- state flags and modData is wiped on pooling -- see the engine-facts table
-- in DORMANT_PERSISTENCE_PLAN.md), so the record lives here and is re-bound
-- to a fresh object by position + outfitID when the special realizes again.
--
-- PHASE 1: this module is INERT bookkeeping. Nothing reads findMatch to
-- change gameplay yet; svCheckZombie only calls the probe (log-only) so we
-- can calibrate ADOPT_RADIUS and confirm outfitID stability on the dedi
-- before adoption ships.
--
-- "RQDormant" is its own ModData table on purpose: RQZombieState is
-- transmitted to every connecting client, this table must NEVER ride a
-- transmit/request. Do not nest it there, do not ModData.transmit it.
-- =============================================

if not isServer() then return end

require "RQSvShared"

RQSvDormant = RQSvDormant or {}

-- Phase 1 instrumentation switch. Remove (or flip false) in Phase 3.
RQSvDormant.DEBUG = true

-- ========================
-- Tuning knobs (defaults from the plan; calibrate from Phase 1 data)
-- ========================

local SCHEMA_VERSION = 1
local ADOPT_RADIUS   = 8            -- tiles; walkers drift while virtual
local EXPIRY_MS      = 120 * 60 * 1000  -- 120 real minutes
local HARD_CAP       = 500          -- evict lowest lastSeen beyond this
local PROBE_LOG_GAP  = 60000        -- per-record throttle for probe spam (ms)

local ADOPT_RADIUS_SQ = ADOPT_RADIUS * ADOPT_RADIUS

-- Non-persistent probe-log throttle (pidStr -> last log ms). Deliberately a
-- plain local so it never touches the .bin.
local probeLogTimes = {}

-- ========================
-- Backing store
-- ========================

local store = nil

local function dbg(msg)
    if RQSvDormant.DEBUG then print("[RQDormant] " .. msg) end
end

-- A number that is nil, NaN (v ~= v) or infinite corrupts distance math
-- forever; treat the whole row as garbage.
local function badNum(v)
    return type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge
end

local function rowValid(rec)
    if type(rec) ~= "table" then return false end
    if type(rec.zType) ~= "string" then return false end
    if badNum(rec.x) or badNum(rec.y) or badNum(rec.z) then return false end
    if badNum(rec.lastSeen) then return false end
    return true
end

-- Load-time sanitation: schema mismatch or malformed rows rebuild/clear the
-- table. global_mod_data.bin is a full atomic rewrite each save, so anything
-- we drop here vanishes from disk at the next autosave -- this IS the
-- self-cleaning layer.
local function sanitize(t)
    if t.schemaVersion ~= SCHEMA_VERSION or type(t.records) ~= "table" then
        t.schemaVersion = SCHEMA_VERSION
        t.nextPid       = 1
        t.records       = {}
        dbg("store rebuilt (schema mismatch or first run)")
        return t
    end
    if badNum(t.nextPid) then t.nextPid = 1 end
    local dropped = 0
    for pidStr, rec in pairs(t.records) do
        if not rowValid(rec) then
            t.records[pidStr] = nil
            dropped = dropped + 1
        end
    end
    -- A reset/lost nextPid alongside surviving records would hand out a pid
    -- that overwrites a live identity on the next mint. Never let it trail
    -- the highest surviving record.
    local maxPid = 0
    for pidStr in pairs(t.records) do
        local n = tonumber(pidStr)
        if n and n > maxPid then maxPid = n end
    end
    if t.nextPid <= maxPid then t.nextPid = maxPid + 1 end
    if dropped > 0 then dbg("sanitize dropped " .. dropped .. " malformed record(s)") end
    return t
end

local function getStore()
    if not store then
        store = sanitize(ModData.getOrCreate("RQDormant"))
    end
    return store
end

Events.OnInitGlobalModData.Add(function()
    -- Re-fetch on every init: after a server restart the engine has loaded a
    -- fresh table from disk and any cached reference would be stale.
    store = sanitize(ModData.getOrCreate("RQDormant"))
    local n = 0
    for _ in pairs(store.records) do n = n + 1 end
    dbg("initialized, " .. n .. " dormant record(s) loaded")
end)

-- ========================
-- API
-- ========================

function RQSvDormant.mint()
    local t = getStore()
    local pid = t.nextPid
    t.nextPid = pid + 1
    return tostring(pid)
end

function RQSvDormant.record(pid, zType, x, y, z, outfitID, hp)
    if not pid or not zType then return end
    if badNum(x) or badNum(y) or badNum(z) then return end
    getStore().records[pid] = {
        zType    = zType,
        x        = x,
        y        = y,
        z        = z,
        outfitID = (not badNum(outfitID)) and outfitID or nil,
        hp       = (not badNum(hp)) and math.min(hp, RQSvShared.MAX_NETWORK_HP) or nil,
        lastSeen = getTimestampMs(),
    }
end

-- Per-tick refresh while the special is live. outfitID rides along only to
-- verify the Phase 0 assumption (stable across the object's loaded life);
-- a change is loud because the whole re-bind strategy leans on it.
-- Returns false when no record exists so the caller can re-record instead of
-- silently losing the identity.
function RQSvDormant.touch(pid, x, y, z, hp, outfitID)
    local rec = getStore().records[pid]
    if not rec then return false end
    if not (badNum(x) or badNum(y) or badNum(z)) then
        rec.x, rec.y, rec.z = x, y, z
    end
    if not badNum(hp) then rec.hp = math.min(hp, RQSvShared.MAX_NETWORK_HP) end
    rec.lastSeen = getTimestampMs()
    if outfitID ~= nil then
        if rec.outfitID == nil then
            -- Backfill: the pcall failed at record time but works now. Better
            -- a late outfitID than a record the matcher can only tiebreak by
            -- position.
            rec.outfitID = outfitID
        elseif outfitID ~= rec.outfitID then
            dbg("WARN outfitID changed on live special pid=" .. pid
                .. " type=" .. rec.zType
                .. " was=" .. tostring(rec.outfitID) .. " now=" .. tostring(outfitID))
            rec.outfitID = outfitID
        end
    end
    return true
end

-- The special's object vanished without a confirmed death (virtualized /
-- stale ref). The record stays -- it already carries the last touched
-- position -- and becomes an adoption candidate.
function RQSvDormant.demote(pid)
    local rec = getStore().records[pid]
    if not rec then return end
    rec.lastSeen = getTimestampMs()
    dbg("demote pid=" .. pid .. " type=" .. rec.zType
        .. string.format(" at (%.1f,%.1f,%d)", rec.x, rec.y, math.floor(rec.z))
        .. " outfitID=" .. tostring(rec.outfitID))
end

function RQSvDormant.remove(pid)
    if not pid then return end
    local t = getStore()
    if t.records[pid] then
        t.records[pid] = nil
        probeLogTimes[pid] = nil
    end
end

function RQSvDormant.isEmpty()
    -- Kahlua has no global next(); a single pairs() step is the cheap test.
    for _ in pairs(getStore().records) do return false end
    return true
end

-- Nearest record within ADOPT_RADIUS on the same floor; an exact outfitID
-- match beats a nearer non-match (outfitID is not unique, position does most
-- of the work -- the outfit only breaks ties between overlapping records).
function RQSvDormant.findMatch(x, y, z, outfitID)
    if badNum(x) or badNum(y) or badNum(z) then return nil end
    local zi = math.floor(z)
    local bestPid, bestRec, bestD = nil, nil, math.huge
    local bestOutfitPid, bestOutfitRec, bestOutfitD = nil, nil, math.huge
    for pidStr, rec in pairs(getStore().records) do
        if math.floor(rec.z) == zi then
            local dx, dy = rec.x - x, rec.y - y
            local d = dx * dx + dy * dy
            if d <= ADOPT_RADIUS_SQ then
                if d < bestD then
                    bestPid, bestRec, bestD = pidStr, rec, d
                end
                if outfitID and rec.outfitID == outfitID and d < bestOutfitD then
                    bestOutfitPid, bestOutfitRec, bestOutfitD = pidStr, rec, d
                end
            end
        end
    end
    if bestOutfitPid then return bestOutfitPid, bestOutfitRec, bestOutfitD end
    return bestPid, bestRec, bestD
end

-- Phase 1 probe: log what adoption WOULD have done, change nothing. The
-- per-record throttle keeps a lingering record near a horde from spamming
-- every conversion-scan pass.
function RQSvDormant.probeMatch(x, y, z, outfitID)
    local pid, rec, dSq = RQSvDormant.findMatch(x, y, z, outfitID)
    if not pid then return end
    local now = getTimestampMs()
    if probeLogTimes[pid] and (now - probeLogTimes[pid]) < PROBE_LOG_GAP then return end
    probeLogTimes[pid] = now
    dbg(string.format(
        "probe WOULD-ADOPT pid=%s type=%s drift=%.1f outfit=%s (rec=%s zed=%s)",
        pid, rec.zType, math.sqrt(dSq or 0),
        (outfitID and rec.outfitID == outfitID) and "MATCH" or "miss",
        tostring(rec.outfitID), tostring(outfitID)))
end

-- Expiry + hard-cap eviction; piggybacks the caller's existing cleanup timer.
function RQSvDormant.sweep()
    local t = getStore()
    local now = getTimestampMs()
    local expired, kept = 0, 0
    for pidStr, rec in pairs(t.records) do
        if not rowValid(rec) or (now - rec.lastSeen) > EXPIRY_MS then
            t.records[pidStr] = nil
            probeLogTimes[pidStr] = nil
            expired = expired + 1
        else
            kept = kept + 1
        end
    end
    -- Cap eviction is O(n^2) worst case but only runs while over 500 records,
    -- which the expiry above should make unreachable in practice.
    while kept > HARD_CAP do
        local oldestPid, oldestSeen = nil, math.huge
        for pidStr, rec in pairs(t.records) do
            if rec.lastSeen < oldestSeen then
                oldestPid, oldestSeen = pidStr, rec.lastSeen
            end
        end
        if not oldestPid then break end
        t.records[oldestPid] = nil
        probeLogTimes[oldestPid] = nil
        expired = expired + 1
        kept = kept - 1
    end
    if expired > 0 then
        dbg("sweep evicted " .. expired .. ", " .. kept .. " remain")
    end
end

if getDebug() then
    print("[RQSvDormant] dormant special registry loaded (Phase 1: inert)")
end
