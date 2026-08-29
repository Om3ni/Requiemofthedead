-- SPDX-License-Identifier: GPL-3.0-or-later
-- =============================================
-- RQSvDormant.lua - Dormant special registry (server only)
-- World-anchored identity records for converted specials, backed by the
-- global ModData table "RQDormant". Zombie objects cannot carry identity
-- across chunk unload (virtualization keeps only pos/dir/persistentOutfitID/
-- state flags and modData is wiped on pooling -- see the engine-facts table
-- in DORMANT_PERSISTENCE_PLAN.md), so the record lives here and is re-bound
-- to a fresh object by position + outfitID when the special realizes again.
--
-- Records are ACTIVE while their current IsoZombie object is loaded and become
-- DORMANT only when RQServer demotes a stale/virtualized object. A realizing
-- zombie may claim only a dormant record. This distinction is deliberately
-- session-local: after a server restart every persisted record is dormant until
-- a realizing zombie claims it.
--
-- "RQDormant" is its own ModData table on purpose: RQZombieState is
-- transmitted to every connecting client, this table must NEVER ride a
-- transmit/request. Do not nest it there, do not ModData.transmit it.
--
-- WHY GLOBAL MODDATA (owner-approved exception to the family's
-- don't-touch-GMD principle): during high-population cell churn, converted
-- specials lost their identity on chunk unload and the conversion scanner
-- re-rolled them IN FRONT OF PLAYERS - "a Screamer just spawned on top of
-- me". GMD is the only store that is already in RAM, survives cell churn by
-- definition, and needs no sync plumbing. Known accepted limit: GMD
-- durability rides the engine-save cadence (30-min saves on the prod dedi;
-- saves OFF locally), so a force-kill restart can lose up to one save
-- interval of registry changes - conversions from the final minutes
-- despecialize at the boundary. If that ever bites, the fix is a
-- write-through mirror via RFTDCore's file layer (replay at boot), NOT a
-- redesign of this table.
-- =============================================

if not isServer() then return end

require "RDShared"   -- badNum is read at file scope below; declare it (CLAUDE.md sect. 4)
require "RQSvShared"

RQSvDormant = RQSvDormant or {}

-- Bounded lifecycle diagnostics: one line per demotion/adoption, plus sweeps.
RQSvDormant.DEBUG = true

-- ========================
-- Tuning knobs (defaults from the plan; calibrate from Phase 1 data)
-- ========================

local SCHEMA_VERSION = 1
local ADOPT_RADIUS   = 8            -- tiles; walkers drift while virtual
local EXPIRY_MS      = 120 * 60 * 1000  -- 120 real minutes
local HARD_CAP       = 500          -- evict lowest lastSeen beyond this
local ADOPT_RADIUS_SQ = ADOPT_RADIUS * ADOPT_RADIUS

-- ========================
-- Backing store
-- ========================

local store = nil
local livePids = {}       -- pidStr -> true while bound to a loaded IsoZombie
local dormantCount = 0

local function dbg(msg)
    if RQSvDormant.DEBUG then print("[RQDormant] " .. msg) end
end

-- A number that is nil, NaN (v ~= v) or infinite corrupts distance math
-- forever; treat the whole row as garbage.
-- badNum lives in RDShared (promoted 2026-08-25).
local badNum = RDShared.badNum

local function rowValid(rec)
    if type(rec) ~= "table" then return false end
    if type(rec.zType) ~= "string" then return false end
    if not RQSvShared.HEALTH_MULTIPLIER[rec.zType] then return false end
    if badNum(rec.x) or badNum(rec.y) or badNum(rec.z) then return false end
    if badNum(rec.lastSeen) then return false end
    return true
end

local function sanitizeOptionalNumber(rec, key)
    if rec[key] ~= nil and badNum(rec[key]) then rec[key] = nil end
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
        else
            -- Additive schema fields: old records legitimately omit them.
            sanitizeOptionalNumber(rec, "baseHP")
            sanitizeOptionalNumber(rec, "juggMaxHP")
            sanitizeOptionalNumber(rec, "gluttonBaseHealth")
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


local function adoptLoadedStore(t)
    store = sanitize(t)
    livePids = {}
    dormantCount = 0
    for _ in pairs(store.records) do dormantCount = dormantCount + 1 end
    return store
end

local function getStore()
    if not store then
        adoptLoadedStore(ModData.getOrCreate("RQDormant"))
    end
    return store
end

Events.OnInitGlobalModData.Add(function()
    -- Re-fetch on every init: after a server restart the engine has loaded a
    -- fresh table from disk and any cached reference would be stale.
    adoptLoadedStore(ModData.getOrCreate("RQDormant"))
    dbg("initialized, " .. dormantCount .. " dormant record(s) loaded")
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

function RQSvDormant.record(pid, zType, x, y, z, outfitID, hp,
                            baseHP, juggMaxHP, gluttonBaseHealth)
    if not pid or not zType then return end
    if badNum(x) or badNum(y) or badNum(z) then return end
    local t = getStore()
    if t.records[pid] and not livePids[pid] then
        dormantCount = math.max(0, dormantCount - 1)
    end
    t.records[pid] = {
        zType    = zType,
        x        = x,
        y        = y,
        z        = z,
        outfitID = (not badNum(outfitID)) and outfitID or nil,
        hp       = (not badNum(hp)) and math.min(hp, RQSvShared.MAX_NETWORK_HP) or nil,
        baseHP   = (not badNum(baseHP)) and baseHP or nil,
        juggMaxHP = (not badNum(juggMaxHP)) and juggMaxHP or nil,
        gluttonBaseHealth = (not badNum(gluttonBaseHealth)) and gluttonBaseHealth or nil,
        lastSeen = getTimestampMs(),
    }
    livePids[pid] = true
end

-- Per-tick refresh while the special is live. outfitID rides along only to
-- verify the Phase 0 assumption (stable across the object's loaded life);
-- a change is loud because the whole re-bind strategy leans on it.
-- Returns false when no record exists so the caller can re-record instead of
-- silently losing the identity.
function RQSvDormant.touch(pid, x, y, z, hp, outfitID,
                           baseHP, juggMaxHP, gluttonBaseHealth)
    local rec = getStore().records[pid]
    if not rec then return false end
    if not livePids[pid] then
        livePids[pid] = true
        dormantCount = math.max(0, dormantCount - 1)
    end
    if not (badNum(x) or badNum(y) or badNum(z)) then
        rec.x, rec.y, rec.z = x, y, z
    end
    if not badNum(hp) then rec.hp = math.min(hp, RQSvShared.MAX_NETWORK_HP) end
    if not badNum(baseHP) then rec.baseHP = baseHP end
    if not badNum(juggMaxHP) then rec.juggMaxHP = juggMaxHP end
    if not badNum(gluttonBaseHealth) then rec.gluttonBaseHealth = gluttonBaseHealth end
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
    if livePids[pid] then
        livePids[pid] = nil
        dormantCount = dormantCount + 1
    end
    rec.lastSeen = getTimestampMs()
    dbg("demote pid=" .. pid .. " type=" .. rec.zType
        .. string.format(" at (%.1f,%.1f,%d)", rec.x, rec.y, math.floor(rec.z))
        .. " outfitID=" .. tostring(rec.outfitID))
end

function RQSvDormant.remove(pid)
    if not pid then return end
    local t = getStore()
    if t.records[pid] then
        if not livePids[pid] then dormantCount = math.max(0, dormantCount - 1) end
        t.records[pid] = nil
        livePids[pid] = nil
    end
end

function RQSvDormant.isEmpty()
    -- Kahlua has no global next(); a single pairs() step is the cheap test.
    for _ in pairs(getStore().records) do return false end
    return true
end

function RQSvDormant.hasDormant()
    return dormantCount > 0
end

-- THE OUTFIT DISCRIMINATOR is the complete persistent outfit id.
--
-- ZombiePopulationManager.removeChunkFromWorld passes the complete integer to
-- n_addZombie (ZombiePopulationManager.java:350-388), and realization passes
-- that integer straight to setPersistentOutfitID
-- (VirtualZombieManager.java:197-230). PersistentOutfits.pickOutfit's low bits
-- are a seed chosen only when the outfit is first picked; virtualization does
-- not pick again (PersistentOutfits.java:142-167). Matching only the high half
-- would discard identity evidence and let two nearby zombies in the same outfit
-- steal one another's subtype.
--
-- Only dormant records participate. A record belonging to a still-loaded
-- special is never a candidate, even if an ordinary zombie stands on top of it.
function RQSvDormant.findMatch(x, y, z, outfitID)
    if badNum(x) or badNum(y) or badNum(z) then return nil end
    if badNum(outfitID) or outfitID == 0 then return nil end
    local zi = math.floor(z)
    local bestPid, bestRec, bestD = nil, nil, math.huge
    for pidStr, rec in pairs(getStore().records) do
        if not livePids[pidStr] and rec.outfitID == outfitID
            and math.floor(rec.z) == zi then
            local dx, dy = rec.x - x, rec.y - y
            local d = dx * dx + dy * dy
            if d <= ADOPT_RADIUS_SQ and d < bestD then
                bestPid, bestRec, bestD = pidStr, rec, d
            end
        end
    end
    return bestPid, bestRec, bestD
end

-- Claim and remove in one module operation so no second zombie can observe the
-- same dormant identity between lookup and consumption.
function RQSvDormant.claimMatch(x, y, z, outfitID)
    local pid, rec, dSq = RQSvDormant.findMatch(x, y, z, outfitID)
    if not pid then return nil end
    RQSvDormant.remove(pid)
    return pid, rec, dSq
end

-- Expiry + hard-cap eviction; piggybacks the caller's existing cleanup timer.
function RQSvDormant.sweep()
    local t = getStore()
    local now = getTimestampMs()
    local expired, kept = 0, 0
    for pidStr, rec in pairs(t.records) do
        if not rowValid(rec) or (now - rec.lastSeen) > EXPIRY_MS then
            if not livePids[pidStr] then dormantCount = math.max(0, dormantCount - 1) end
            t.records[pidStr] = nil
            livePids[pidStr] = nil
            expired = expired + 1
        else
            kept = kept + 1
        end
    end
    -- Cap eviction is O(n^2) worst case but only runs while over 500 records,
    -- which the expiry above should make unreachable in practice. Never evict
    -- an ACTIVE identity merely to satisfy the persistence cap; active rows will
    -- become eligible after demotion and a later sweep can trim them then.
    while kept > HARD_CAP do
        local oldestPid, oldestSeen = nil, math.huge
        for pidStr, rec in pairs(t.records) do
            if not livePids[pidStr] and rec.lastSeen < oldestSeen then
                oldestPid, oldestSeen = pidStr, rec.lastSeen
            end
        end
        if not oldestPid then break end
        t.records[oldestPid] = nil
        if not livePids[oldestPid] then dormantCount = math.max(0, dormantCount - 1) end
        livePids[oldestPid] = nil
        expired = expired + 1
        kept = kept - 1
    end
    if expired > 0 then
        dbg("sweep evicted " .. expired .. ", " .. kept .. " remain")
    end
end

if getDebug() then
    print("[RQSvDormant] dormant special registry loaded (adoption enabled)")
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
