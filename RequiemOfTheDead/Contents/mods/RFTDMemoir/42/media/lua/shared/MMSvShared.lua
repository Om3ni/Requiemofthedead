-- MMSvShared.lua - Memoir (snapshot/restore) shared constants, lookups, and
-- debug layer. RFTD convention: two-letter prefix (MM), <Px>SvShared = shared tokens.
--
-- This subsystem turns a craftable journal into a CONVENIENCE SAVE (not a
-- reincarnation): write captures a full character snapshot; read restores it onto
-- whatever body you respawned as. Locked design rules (2026-07-13 overwrite model):
--   * MEMOIR IS THE SOURCE OF TRUTH: reading it OVERWRITES whatever was built at the
--     respawn screen - identity (profession/traits), body, faith: snapshot wins. No
--     reconcile window, no choice: the creation screen picks a loaner body, the
--     memoir returns the real character.
--   * XP: memoir restore (grants + earned*knob) PLUS whatever was EARNED playing the
--     new body - post-respawn grinding is real play, it adds on top. The respawn
--     build's starting grants - XP levels, traits/profession, AND granted recipes -
--     are DISMISSED with the build (no chef->die->engineer->read laundering of
--     profession-locked abilities). Additive is safe ONLY because the two earning
--     windows are disjoint lives - the life-id guarantees it.
--   * SAME-LIFE READS REFUSE (and do not consume): a memoir read by the life that
--     wrote it would double-count its own history. The life-id stamped at write
--     detects this; death wipes player modData, so a respawn never matches.
--   * Single-use: on read the server CONSUMES the memoir and hands back a plain notebook,
--     so a memoir can't be read twice. Reuse = craft a fresh memoir (pen/pencil gated).
--   * Identity gate (steamID/username) preserved.
--   * Grant math mirrors engine creation (IsoGameCharacter.applyTraits: passive base 5
--     + boosts, clamped 0..10); the XP knob taxes MEMOIR-earned XP only. No restore
--     lands below a fresh spawn of the saved build; remake cycles net zero (no
--     min/max laundering). See MMSnapshotCodec header for the full rule.
--   * Legacy (pre-v4, no life-id) books bridge via the old identity compare:
--     match -> the old harmless top-up (could be the same life); mismatch -> overwrite.

MMShared = MMShared or {}

-- LOAD ORDER (landmine, verified 42.19): the CLIENT walks media/lua/shared
-- ALPHABETICALLY ACROSS ALL MODS - "MMSvShared.lua" runs before Core's
-- "RDShared.lua", so RDShared was still nil here and this file died with
-- "attempted index: registerMod of non-table" (taking MMClient with it). The
-- dedicated server resolves require= into mod order and loads Core first, so
-- the dedi never saw it. require() pulls Core's file forward and is a no-op if
-- the walk already ran it - every shared file that touches an RD* global at
-- file scope needs this line.
require "RDShared"

RDShared.registerMod("RFTDMemoir", "0.7.0")   -- keep in sync with mod.info

MMShared.MODULE = "RFTDMemoir"   -- wire token = mod id (was "RFTDDragonflyMemoir" pre-shakeout; client+server ship atomically in the bundle, so the flip needs no dual-accept)

-- client <-> server command names
MMShared.CMD = {
    WRITE_REQUEST = "mm_write",   -- client asks server to snapshot into the journal
    READ_REQUEST  = "mm_read",    -- client asks server to restore from the journal
    RESULT        = "mm_result",  -- server -> client feedback (ok/deny + say text)
    DUMP          = "mm_dump",    -- debug: dump authoritative journal/player state
}

MMShared.SCHEMA_VERSION = 4 -- v4 adds snap.lifeId (same-life read guard); v3 faith; v2 nutrition

-- WIPE EPOCH: read-time amnesty gate. Every write stamps the current epoch into the
-- snapshot; reading a book stamped with an OLDER epoch (or none) refuses - "the ink
-- has faded" - and KEEPS the book, so the owner just writes over it for a fresh
-- snapshot. Bump the number to void every memoir written before the bump, wherever
-- it is stored (unloaded chunks, offline inventories - no scrub can reach those).
-- Epoch 1 retires all books written before the 2026-07-20 double-read dupe fix.
MMShared.WIPE_EPOCH = 1

-- =====================================================================
--  CONFIG. Server-tunable knobs (SandboxVars, MP-synced to clients so the shared
--  codec computes the same result on the server authority and the owning client's
--  mirror-apply).
-- =====================================================================

-- XP restore mode (sandbox MemoirXPRestoreMode): 1 = Global (one % for every skill,
-- default / legacy behaviour), 2 = Per Individual (each vanilla skill has its own %).
-- Per-category was deliberately dropped - only these two tiers are wanted.
function MMShared.xpRestoreMode()
    local sv = SandboxVars and SandboxVars.RFTDMemoir
    local m = sv and sv.MemoirXPRestoreMode
    return (type(m) == "number") and m or 1
end

-- 0..100 integer -> 0..1 fraction, clamped. Returns nil for a missing/non-number knob so
-- callers can tell "knob absent" apart from "knob set to 0" and fall back accordingly.
local function pctToFraction(pct)
    if type(pct) ~= "number" then return nil end
    if pct < 0 then pct = 0 elseif pct > 100 then pct = 100 end
    return pct / 100.0
end

-- XP restore fraction for ONE skill on restore (0..1). Scales that skill's recorded RAW XP
-- (90 = give back 90% of its saved XP). Identity (traits/profession), recipes, kills and
-- Faith are NOT scaled - they always restore in full - so the journal stays a true snapshot
-- and only XP potential dials down.
--   Global mode     : every skill uses MemoirXPRestore.
--   Individual mode : skill uses MemoirXPRestore_<perkId> if declared, else falls back to the
--                     global MemoirXPRestore. So any skill without its own knob (a modded
--                     skill, or a vanilla one we didn't list) degrades to the global value -
--                     never silently to 100%.
-- perkId optional: omit it (or in Global mode) and you get the single global fraction.
function MMShared.xpRestoreFraction(perkId)
    local sv = SandboxVars and SandboxVars.RFTDMemoir
    local globalFrac = pctToFraction(sv and sv.MemoirXPRestore) or 1.0
    if not perkId or MMShared.xpRestoreMode() ~= 2 then return globalFrac end
    return pctToFraction(sv and sv["MemoirXPRestore_" .. perkId]) or globalFrac
end

-- =====================================================================
--  DEBUG LAYER. Read/write/dump traces (tagged [MM_DBG]) are gated by the
--  MemoirDebug sandbox option (default OFF) - silent unless an admin turns it on.
--  MM_DEBUG_FORCE is a local dev override (set true to force prints on).
-- =====================================================================
MM_DEBUG_FORCE = false

local function debugOn()
    if MM_DEBUG_FORCE then return true end
    local sv = SandboxVars and SandboxVars.RFTDMemoir
    return (sv and sv.MemoirDebug == true) or false
end
MMShared.debugOn = debugOn

local function sideTag()
    if isServer() then return "SERVER" end
    if isClient() then return "CLIENT" end
    return "SP"
end

function MMname(player)
    if not player then return "?" end
    local ok, n = pcall(function() return player:getUsername() end)
    if ok and n and n ~= "" then return n end
    ok, n = pcall(function() return player:getFullName() end)
    return (ok and n) or tostring(player)
end

function MMlog(...)
    if not debugOn() then return end
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
    print("[MM_DBG][" .. sideTag() .. "] " .. table.concat(parts, " "))
end

-- Unconditional warn - NOT gated by MemoirDebug. Apply failures must reach the console
-- on live servers: a failed recall that logs nothing is how "Restore Saved did nothing"
-- tickets stay unsolvable for weeks after the logs rotate away.
function MMwarn(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
    print("[MM][" .. sideTag() .. "] " .. table.concat(parts, " "))
end

local function dump(v, depth, maxDepth)
    if type(v) ~= "table" then
        if type(v) == "number" then return (string.format("%.2f", v):gsub("%.00$", "")) end
        return tostring(v)
    end
    if depth >= maxDepth then return "{...}" end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local out = {}
    for _, k in ipairs(keys) do out[#out + 1] = tostring(k) .. "=" .. dump(v[k], depth + 1, maxDepth) end
    return "{" .. table.concat(out, ", ") .. "}"
end

function MMlogTable(label, tbl, maxDepth)
    if not debugOn() then return end
    print("[MM_DBG][" .. sideTag() .. "] " .. tostring(label) .. " = " .. dump(tbl, 0, maxDepth or 3))
end

-- =====================================================================
--  LOOKUPS (engine has no by-name static getters exposed; scan + cache)
-- =====================================================================

-- Traits: resolve a saved trait NAME back to its CharacterTrait.
-- Dedi guard (same gap findProfessionDefByName guards below for professions): trait
-- definitions are populated by the character-creation Lua (BaseGameCharacterDetails
-- .DoTraits), which a dedicated server never runs on its own. Without the guard the
-- first server-side applyIdentity dies inside getTraits() - a "Restore Saved" that
-- errors before the reply and looks to the player like nothing happened at all.
local traitByName = nil
function MMShared.findTraitByName(name)
    if not traitByName then
        local ok, defs = pcall(function() return CharacterTraitDefinition.getTraits() end)
        if (not ok or not defs or defs:size() == 0)
                and BaseGameCharacterDetails and BaseGameCharacterDetails.DoTraits then
            pcall(BaseGameCharacterDetails.DoTraits)
            ok, defs = pcall(function() return CharacterTraitDefinition.getTraits() end)
        end
        if not ok or not defs or defs:size() == 0 then
            MMwarn("findTraitByName: trait definitions unavailable - lookup for '"
                .. tostring(name) .. "' fails; will retry on next call")
            return nil -- leave the cache unbuilt so a later call retries
        end
        traitByName = {}
        for i = 0, defs:size() - 1 do
            local t = defs:get(i):getType()
            traitByName[t:getName()] = t
        end
    end
    return traitByName[name]
end

-- True once the trait-definition cache is (or can be) built on this side. applyIdentity
-- checks this BEFORE stripping traits: resolving zero defs mid-swap would wipe every
-- trait and re-add none, which is far worse than aborting the whole apply.
function MMShared.traitDefsReady()
    if traitByName then return true end
    MMShared.findTraitByName("") -- triggers a cache-build attempt (with the DoTraits guard)
    return traitByName ~= nil
end

-- Professions: resolve a saved profession NAME back to its
-- CharacterProfessionDefinition (carries getType() + getXpBoosts()).
-- BaseGameCharacterDetails.DoProfessions() must have populated the table - it runs
-- at creation/boot; we guard-call it lazily in case a snapshot read is the first
-- thing that needs it.
local profByName = nil
function MMShared.findProfessionDefByName(name)
    if not profByName then
        if BaseGameCharacterDetails and BaseGameCharacterDetails.DoProfessions then
            pcall(BaseGameCharacterDetails.DoProfessions)
        end
        profByName = {}
        local list = CharacterProfessionDefinition.getProfessions()
        for i = 0, list:size() - 1 do
            local def = list:get(i)
            profByName[def:getType():getName()] = def
        end
    end
    return profByName[name]
end

-- Plain display name for a profession ("securityguard" -> "Security Guard").
function MMShared.professionUIName(name)
    if not name or name == "" then return "?" end
    local def = MMShared.findProfessionDefByName(name)
    if def and def.getUIName then
        local ok, n = pcall(function() return def:getUIName() end)
        if ok and n and n ~= "" then return n end
    end
    return name
end

return MMShared
