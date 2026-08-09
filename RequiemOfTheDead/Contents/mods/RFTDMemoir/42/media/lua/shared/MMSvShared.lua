-- SPDX-License-Identifier: GPL-3.0-or-later
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

RDShared.registerMod("RFTDMemoir", "1.0.0")   -- keep in sync with mod.info

MMShared.MODULE = "RFTDMemoir"   -- wire token = mod id (was "RFTDDragonflyMemoir" pre-shakeout; client+server ship atomically in the bundle, so the flip needs no dual-accept)

-- client <-> server command names
MMShared.CMD = {
    WRITE_REQUEST = "mm_write",   -- client asks server to snapshot into the journal
    READ_REQUEST  = "mm_read",    -- client asks server to restore from the journal
    RESULT        = "mm_result",  -- server -> client feedback (ok/deny + say text)
    DUMP          = "mm_dump",    -- debug: dump authoritative journal/player state
}

-- v5 stores traits/profession as FULLY-QUALIFIED registry ids ("base:organized")
-- instead of getName() (see the IDENTITY KEYS header below for why). Purely a
-- record: nothing GATES on this number, because the reader is tolerant per entry
-- - a v4 book's bare names resolve vanilla-first and read correctly forever.
-- v4 adds snap.lifeId (same-life read guard); v3 faith; v2 nutrition.
MMShared.SCHEMA_VERSION = 5

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

-- Auto-repair on login (sandbox MemoirAutoFixShadowedTraits). When a character
-- connects, swap any mod trait that SHADOWS a vanilla one back to the vanilla
-- original - see MMTraitRepair for the whole story.
--
-- DEFAULT OFF, deliberately, and not out of timidity: this suite ships to the
-- Workshop, and the repair rule is generic ("a mod trait occupying a vanilla
-- path"). On Mosaic that describes exactly one thing - Seinar's creation-screen
-- placeholders, which Seinar's OWN CreatePlayer.lua swaps to base, so repairing
-- them agrees with the author's intent. On somebody else's server it could
-- describe a mod trait a player deliberately chose and is meant to keep, and
-- silently editing characters on a server whose mod list we have never seen is
-- not a default we get to pick for them. Turn it on for the migration restart,
-- leave it on or off afterwards - the repair is idempotent either way.
function MMShared.autoFixShadowedTraits()
    local sv = SandboxVars and SandboxVars.RFTDMemoir
    return (sv and sv.MemoirAutoFixShadowedTraits == true) or false
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
--  IDENTITY KEYS + LOOKUPS
--
--  THE LANDMINE (found live 2026-08-09, Mox's Organized): getName() IS NOT
--  UNIQUE. CharacterTrait.getName() returns ResourceLocation.getPath() - the
--  namespace is stripped and what is left is lowercased (CharacterTrait.java
--  :118, ResourceLocation.java:24-25). So base:Organized and
--  SeinarExtendedProfessions:Organized BOTH answer "organized", and a
--  name-keyed lookup table silently resolves to whichever was registered last.
--  Vanilla scripts always parse before mod scripts (ScriptManager.Reset() ->
--  Load()), so the MOD always wins - a memoir read swapped the player's real
--  base:organized for Seinar's inert profession-trait placeholder, and the
--  container bonus (ItemContainer.getEffectiveCapacity, hard-keyed to
--  CharacterTrait.ORGANIZED) vanished. Capture logged "organized" either way,
--  so the forensics agreed with the player that nothing had happened.
--  CharacterProfession has the identical getName() (CharacterProfession.java
--  :46-48); it does not collide with anything on Mosaic today, but it is the
--  same defect and is keyed the same way here.
--
--  THE RULE: the fully-qualified registry id ("base:organized") is the ONLY
--  safe key. Never store, compare, or look up a trait or profession by
--  getName(). Resolution goes through the live registry (CharacterTrait.get /
--  CharacterProfession.get), which is unambiguous and never stale.
-- =====================================================================

-- The registry id of a CharacterTrait / CharacterProfession, lowercased
-- ("base:organized"). Both classes' toString() is
-- Registries.X.getLocation(this).toString() - VERIFIED live in-game via
-- print(tostring(...)) on 2026-08-09, which is what proved the collision.
-- Returns nil for a stale object (getLocation() null after a registry reset ->
-- toString NPEs -> pcall catches), which is what makes staleness detectable.
local function fqid(obj)
    if obj == nil then return nil end
    local ok, s = pcall(tostring, obj)
    if not ok or type(s) ~= "string" or s == "" then return nil end
    s = s:lower()
    if not s:find(":", 1, true) then return nil end -- not an id; refuse to guess
    return s
end
MMShared.fqid = fqid

-- ---------------------------------------------------------------------
--  Legacy by-name scan (fallback ONLY - see findTrait below)
-- ---------------------------------------------------------------------
-- Dedi guard: trait definitions are populated by the character-creation Lua
-- (BaseGameCharacterDetails.DoTraits), which a dedicated server never runs on
-- its own. Without the guard the first server-side applyIdentity dies inside
-- getTraits() - a "Restore Saved" that errors before the reply and looks to the
-- player like nothing happened at all.
local traitByName = nil

-- Collisions are reported ONCE per cache build, unconditionally (not gated by
-- MemoirDebug). This is the diagnostic that would have turned Mox's ticket into
-- a boot-time line: any mod that shadows a vanilla trait path announces itself
-- here instead of six weeks later through a player.
local function reportCollisions(kind, dupes)
    if not dupes or #dupes == 0 then return end
    table.sort(dupes)
    MMwarn(kind .. " NAME COLLISIONS (" .. tostring(#dupes) .. ") - these share a getName() and are"
        .. " only distinguishable by namespace: " .. table.concat(dupes, ", "))
    MMwarn("  Memoir keys on the full id so it restores the right one; any OTHER mod comparing"
        .. " " .. kind:lower() .. "s by name on this server is resolving them ambiguously.")
end

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
        local dupes = {}
        for i = 0, defs:size() - 1 do
            local t = defs:get(i):getType()
            local nm = t:getName()
            local prev = traitByName[nm]
            if prev ~= nil and prev ~= t then
                dupes[#dupes + 1] = tostring(nm) .. " [" .. tostring(fqid(prev) or "?")
                    .. " vs " .. tostring(fqid(t) or "?") .. "]"
            end
            traitByName[nm] = t
        end
        reportCollisions("TRAIT", dupes)
    end
    local t = traitByName[name]
    -- Staleness self-heal: ScriptManager.Reset() drops every non-base registry
    -- entry and Load() re-registers NEW objects, so a cached mod trait can
    -- outlive its registry. A stale object has no location, so fqid() is nil -
    -- rebuild once rather than hand back a ghost that NPEs on use.
    if t ~= nil and fqid(t) == nil then
        traitByName = nil
        return MMShared.findTraitByName(name)
    end
    return t
end

-- Resolve a STORED trait key to its CharacterTrait.
--   * "namespace:path" -> exact registry lookup. Unambiguous, never stale.
--   * bare "path"      -> LEGACY key, from a snapshot written before ids. It
--     cannot say which namespace it meant, so VANILLA WINS: base:<path> if the
--     registry has it, else the by-name scan for mod-only traits. That bias is
--     deliberate - every pre-id book was written by a character who picked from
--     the creation screen, where the vanilla trait is the one with the effect.
function MMShared.findTrait(key)
    if type(key) ~= "string" or key == "" then return nil end
    key = key:lower()
    local function reg(id)
        local ok, t = pcall(function() return CharacterTrait.get(ResourceLocation.of(id)) end)
        if ok then return t end
        return nil
    end
    if key:find(":", 1, true) then return reg(key) end
    return reg("base:" .. key) or MMShared.findTraitByName(key)
end

-- Canonical comparison key for a stored trait key, so a legacy bare name and a
-- modern id for the SAME trait compare equal. Unresolvable keys fall back to the
-- lowercased input so an unknown trait still compares equal to itself.
function MMShared.canonTraitKey(key)
    local t = MMShared.findTrait(key)
    if t then return fqid(t) or (type(key) == "string" and key:lower()) or nil end
    return (type(key) == "string" and key:lower()) or nil
end

-- True once the trait-definition cache is (or can be) built on this side.
-- applyIdentity checks this BEFORE stripping traits. Registry resolution alone
-- no longer needs the definitions, but modifyTraitXPBoost and buildGrantLevels
-- read getXpBoosts() off them, so a swap with no defs loaded would re-add every
-- trait with none of its boosts - still worth aborting for.
function MMShared.traitDefsReady()
    if traitByName then return true end
    MMShared.findTraitByName("") -- triggers a cache-build attempt (with the DoTraits guard)
    return traitByName ~= nil
end

-- ---------------------------------------------------------------------
--  Professions (same shape, same landmine - see the header)
-- ---------------------------------------------------------------------
-- BaseGameCharacterDetails.DoProfessions() must have populated the table - it
-- runs at creation/boot; we guard-call it lazily in case a snapshot read is the
-- first thing that needs it.
local profByName = nil
function MMShared.findProfessionDefByName(name)
    if not profByName then
        if BaseGameCharacterDetails and BaseGameCharacterDetails.DoProfessions then
            pcall(BaseGameCharacterDetails.DoProfessions)
        end
        profByName = {}
        local dupes = {}
        local list = CharacterProfessionDefinition.getProfessions()
        for i = 0, list:size() - 1 do
            local def = list:get(i)
            local t = def:getType()
            local nm = t:getName()
            local prev = profByName[nm]
            if prev ~= nil and prev:getType() ~= t then
                dupes[#dupes + 1] = tostring(nm) .. " [" .. tostring(fqid(prev:getType()) or "?")
                    .. " vs " .. tostring(fqid(t) or "?") .. "]"
            end
            profByName[nm] = def
        end
        reportCollisions("PROFESSION", dupes)
    end
    local def = profByName[name]
    if def ~= nil and fqid(def:getType()) == nil then -- stale (see findTraitByName)
        profByName = nil
        return MMShared.findProfessionDefByName(name)
    end
    return def
end

-- Resolve a STORED profession key to its CharacterProfessionDefinition (carries
-- getType() + getXpBoosts()). Same id-first / vanilla-wins-on-legacy rule as
-- findTrait.
function MMShared.findProfessionDef(key)
    if type(key) ~= "string" or key == "" then return nil end
    key = key:lower()
    local function reg(id)
        local ok, def = pcall(function()
            local p = CharacterProfession.get(ResourceLocation.of(id))
            return p and CharacterProfessionDefinition.getCharacterProfessionDefinition(p)
        end)
        if ok then return def end
        return nil
    end
    if key:find(":", 1, true) then return reg(key) end
    return reg("base:" .. key) or MMShared.findProfessionDefByName(key)
end

-- Canonical comparison key for a stored profession key (see canonTraitKey).
function MMShared.canonProfessionKey(key)
    if key == nil then return nil end
    local def = MMShared.findProfessionDef(key)
    if def then return fqid(def:getType()) or (type(key) == "string" and key:lower()) or nil end
    return (type(key) == "string" and key:lower()) or nil
end

-- Plain display name for a profession ("base:securityguard" -> "Security Guard").
function MMShared.professionUIName(key)
    if not key or key == "" then return "?" end
    local def = MMShared.findProfessionDef(key)
    if def and def.getUIName then
        local ok, n = pcall(function() return def:getUIName() end)
        if ok and n and n ~= "" then return n end
    end
    return key
end

-- Drop both caches. ScriptManager.Reset() clears and rebuilds the definition
-- maps (and re-registers every non-base registry entry as a NEW object), so a
-- cache built before a reload describes a world that no longer exists. The
-- per-lookup fqid() check above self-heals, but a clean boot hook is cheaper
-- than discovering it one ghost at a time.
function MMShared.resetLookups()
    traitByName, profByName = nil, nil
end
if Events then
    if Events.OnGameBoot then Events.OnGameBoot.Add(MMShared.resetLookups) end
    if Events.OnServerStarted then Events.OnServerStarted.Add(MMShared.resetLookups) end
end

return MMShared

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
