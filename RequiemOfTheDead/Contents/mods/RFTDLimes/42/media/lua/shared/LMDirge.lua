-- SPDX-License-Identifier: GPL-3.0-or-later
-- LMDirge.lua - Dirge's per-zone spawn overrides, read from Limes (§7.1).
--
-- THE FLIP. Dirge already knows how to take per-zone overrides: RQPhunZones
-- exposes getEffectiveRules(zombieOrX, yOrNil, cfg) and RQServer calls it at
-- three sites (RQServer.lua:336, :618, :646). This file does not touch any of
-- them. It takes over the LOOKUP behind that function so the same three calls
-- answer from the Limes store instead of PhunZones', with identical semantics:
-- a zone value wins when set, a blank one inherits the RQConfig snapshot, and
-- a point with no overrides returns the caller's own cfg table unchanged.
--
-- The bridge lives HERE, in Limes, and not as an edit to Dirge, because that is
-- what keeps both mods independent: Dirge with PhunZones still works, Dirge
-- alone still works, and deleting this one file restores the previous
-- behaviour with no other edit (§1's modularity order, the DFPatch pattern).
--
-- SHARED, not server/, for the same reason RQPhunZones is: the consumers are
-- svCheckZombie on a dedicated server AND checkZombie on a single-player
-- client, so the override has to exist on whichever side is authoritative.
--
-- FIELD REGISTRATION happens at file load, which is before LMPersist applies
-- the store at OnServerStarted - the ordering §5 requires ("consumers declare
-- before boot completes"). It matters twice over: the editor renders from the
-- registry, and resolution COERCES against it. PhunZones persisted these as
-- strings ("15"), so registering them as numbers is what turns zone.fields.
-- dirgeSpawnChance from "15" into 15, clamped, at resolve time rather than at
-- every lookup. It also silences the "no registered consumer yet" warnings
-- that these keys have been producing since the import.
--
-- SIDE = both, revised 2026-08-05. These were server-only - only the spawn path
-- reads them, so shipping them was join bytes for nothing - until the Details
-- panel arrived, whose whole job is tuning them per zone. A field the client is
-- never sent renders as its registered default, so an admin would be editing
-- blanks over values they cannot see. See the registration block below.

require "LMCore"

LMDirge = LMDirge or {}

-- ---------------------------------------------------------------------------
-- Vocabulary
--
-- Weights and spawn chance are percentages. Spacing allows up to 300 - twice
-- the sandbox slider's 150 - because production zones were tuned with 160/200
-- values that the old clamp silently crushed; that ceiling is Dirge's
-- decision and is preserved here rather than re-litigated.
-- ---------------------------------------------------------------------------

local WEIGHT_FIELDS = {
    dirgeSpawnChance      = "spawnChance",
    dirgeScreamerWeight   = "screamerWeight",
    dirgeJuggernautWeight = "juggernautWeight",
    dirgeEMPWeight        = "empWeight",
    dirgeGluttonWeight    = "gluttonWeight",
    dirgeScavengerWeight  = "scavengerWeight",
}

local SPACING_FIELDS = {
    dirgeScreamerSpacing   = "screamerSpacing",
    dirgeJuggernautSpacing = "juggernautSpacing",
    dirgeEMPSpacing        = "empSpacing",
    dirgeGluttonSpacing    = "gluttonSpacing",
    dirgeScavengerSpacing  = "scavengerSpacing",
}

-- The zone-risk sprinter dial (S8). Deliberately absent from Dirge's base
-- config and its sandbox page: the share only EXISTS as zone ground, so the
-- overlay is its sole delivery path and Dirge reads nil -> 0 everywhere the
-- zone layer is silent. RQSvShared.svCheckZoneSprinter owns the semantics
-- (one roll per zombie, standing on ground with a share above zero).
local SHARE_FIELDS = {
    dirgeSprinterShare = "sprinterShare",
}

-- The three vocabularies as one map, for the two walks that do not care which
-- table a dial came from (the any-set fast scan and the overlay copy).
local ALL_FIELDS = {}
for _, t in pairs({ WEIGHT_FIELDS, SPACING_FIELDS, SHARE_FIELDS }) do
    for name, key in pairs(t) do ALL_FIELDS[name] = key end
end

-- Presentation for the Details panel (§11.3). A registrant is the only thing
-- that knows what its own dial means, so the label and the help travel WITH the
-- registration rather than being restated in the panel - the panel would then be
-- a second description of Dirge that drifts from Dirge.
Limes.mods.register("LMDirge", { label = "Dirge", order = 10,
    description = "Per-zone override of the special-infected spawn table. A zone that"
        .. " sets nothing here inherits the sandbox values; a blank field means"
        .. " inherit, not zero." })

-- Pretty name from the field name, so eleven near-identical registrations do not
-- need eleven hand-written strings that can disagree with the key they describe.
-- dirgeJuggernautWeight -> "Juggernaut weight".
local function prettify(name)
    local body = name:gsub("^dirge", "")
    body = body:gsub("(%l)(%u)", "%1 %2")       -- juggernautWeight -> ...t W...
    body = body:gsub("(%u)(%u%l)", "%1 %2")     -- EMPWeight -> EMP Weight
    return (body:sub(1, 1):upper() .. body:sub(2))
end

-- side = "both", REVISED 2026-08-05, and the reason is the editor.
--
-- These were server-only on the §5 argument that only the spawn path reads them,
-- so they were dead weight in every client's memory. True, until Limes grew a
-- Details panel whose entire job is tuning them per zone: a field the client is
-- never sent renders as its default, so the admin would be editing blanks and
-- writing over values they cannot see. The wire cost is a one-time join baseline
-- of a dozen numbers per zone that sets them - a few KB across the whole layer -
-- against a panel that otherwise cannot work. PhunZones' 62.8% was never
-- baseline size; it was re-broadcasting the whole table per player per change.
--
-- LMSync's save path carries server-only fields across regardless, so `side`
-- stays a wire-cost decision rather than a correctness one.
for name in pairs(WEIGHT_FIELDS) do
    Limes.fields.register("LMDirge", name,
        { type = "number", min = 0, max = 100, side = "both",
          order = (name == "dirgeSpawnChance") and 1 or 2, label = prettify(name),
          help = "Relative share of this zone's special spawns. 0 means never." })
end
for name in pairs(SPACING_FIELDS) do
    Limes.fields.register("LMDirge", name,
        { type = "number", min = 0, max = 300, side = "both",
          order = 3, unit = "tiles", label = prettify(name),
          help = "Minimum tiles between two of this kind in this zone." })
end
-- The mockup's A4 board shipped this dial's slot labeled "reserved - pending
-- Dirge sprinter mechanic". The mechanic is RQSvShared.svCheckZoneSprinter
-- now, so the label below is the live one. The help states the roll contract
-- because it is the part an admin can misread: the dial is a share of the
-- POPULATION, decided one zombie at a time, not a switch on the ground.
Limes.fields.register("LMDirge", "dirgeSprinterShare",
    { type = "number", min = 0, max = 100, side = "both",
      order = 4, label = "Sprinter share",
      help = "Percent of ordinary zombies on this ground that become sprinters."
          .. " Each zombie rolls once, the first time it is checked standing"
          .. " where this is above zero; raising the share later only affects"
          .. " zombies that have not rolled yet. Specials never sprint." })

-- ---------------------------------------------------------------------------
-- Authority
--
-- An EMPTY Limes store does not take over. A server that has installed Limes
-- but not yet imported or drawn anything would otherwise lose the per-zone
-- Dirge rules PhunZones was still providing - the flip would look like a
-- regression at exactly the moment an admin is least able to explain it. So
-- the takeover is conditional on Limes actually having zones, and the original
-- lookup stays reachable underneath until then.
--
-- Cached rather than recomputed: this sits on the zombie spawn path.
-- Limes.onChanged fires on every apply and delta, which is the only way the
-- answer can change.
-- ---------------------------------------------------------------------------

local previous  = nil
local haveZones = false

local function refreshAuthority()
    haveZones = #Limes.zoneNames() > 0
end
Limes.onChanged(refreshAuthority)
refreshAuthority()

-- ---------------------------------------------------------------------------
-- The lookup
-- ---------------------------------------------------------------------------

local function getEffectiveRules(zombieOrX, yOrNil, cfg)
    if not haveZones then
        -- Not migrated yet: let whatever was here before answer.
        return previous(zombieOrX, yOrNil, cfg)
    end

    local x, y
    if type(zombieOrX) == "number" then
        x, y = zombieOrX, yOrNil
    else
        local z = zombieOrX
        if not z or not z.getX then return cfg end
        x, y = z:getX(), z:getY()
    end

    local zone = Limes.getLocation(x, y)
    if not zone then return cfg end
    local f = zone.fields
    if not f then return cfg end

    -- Fast path: this zone sets none of ours, so the caller keeps its own
    -- table and no overlay is allocated. Worth the scan - most zones set some
    -- Dirge fields and none of the rest, but plenty set nothing at all.
    local any = false
    for name in pairs(ALL_FIELDS) do
        if f[name] ~= nil then any = true break end
    end
    if not any then return cfg end

    -- __index to cfg is the blank-inherits contract made structural: anything
    -- the zone did not set reads through to the sandbox snapshot, and nothing
    -- has to be copied to make that true.
    local overlay = setmetatable({}, { __index = cfg })

    -- No clamping here. The registry already coerced and clamped these at
    -- resolve time (LMCore, per the min/max above), so a second clamp on the
    -- spawn path would be dead code pretending to be a safety net.
    for name, key in pairs(ALL_FIELDS) do
        local v = f[name]
        if v ~= nil then overlay[key] = v end
    end

    return overlay
end

-- Exposed for tests and for the admin debug menu, which wants to ask "what
-- would this point resolve to" without a zombie in hand.
LMDirge.getEffectiveRules = getEffectiveRules

-- ---------------------------------------------------------------------------
-- Installation
--
-- DEFERRED, because mod load order is not ours to assume. Limes and Dirge are
-- separate mods and the server's Mods= line decides which parses first; if
-- Limes wins, RQPhunZones does not exist yet at this point in the file and a
-- top-level check would silently skip the bridge forever. Mosaic's list
-- happens to load Dirge first, which is exactly the kind of luck that hides a
-- defect until someone reorders their mods.
--
-- So: install now if Dirge is already there, and otherwise retry on the boot
-- events, by which point every mod's shared files have been parsed. Idempotent
-- via `previous`, so being called twice cannot chain the wrapper onto itself.
-- ---------------------------------------------------------------------------

function LMDirge.install()
    if previous then return true end                  -- already bridged
    if not RQPhunZones or not RQPhunZones.getEffectiveRules then return false end
    previous = RQPhunZones.getEffectiveRules
    RQPhunZones.getEffectiveRules = getEffectiveRules
    print("[Limes] LMDirge: Dirge zone overrides now read from Limes")
    return true
end

if not LMDirge.install() and Events then
    local function retry()
        if not LMDirge.install() then
            print("[Limes] LMDirge: Dirge not present, no zone spawn bridge installed")
        end
    end
    if Events.OnGameBoot      then Events.OnGameBoot.Add(retry)      end
    if Events.OnServerStarted then Events.OnServerStarted.Add(retry) end
end

return LMDirge

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
