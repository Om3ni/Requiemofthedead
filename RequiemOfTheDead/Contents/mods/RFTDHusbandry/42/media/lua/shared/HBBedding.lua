-- SPDX-License-Identifier: GPL-3.0-or-later
-- HBBedding - hutch bedding (hay) that keeps coops clean.
--
-- WHY: vanilla IsoHutch accumulates hutchDirt / nestBoxDirt over time
-- (IsoHutch.update + doMeta). Animals only REGENERATE health while
-- getHutchDirt() < 20, and take minor damage above it
-- (IsoHutch.updateAnimalHealthInside). Vanilla's only remedy is the manual
-- "clean floor" action. This adds a cozy upkeep loop: lay hay bedding in a
-- hutch and it soaks up the dirt the coop generates, keeping animals healthy -
-- the bedding is spent as it absorbs that dirt (no time decay), so a busy coop
-- has to be re-bedded sooner than a quiet one.
--
-- SHAPE (mirrors HBData): read helpers are shared (the Dragonfly Hutches tab
-- reads bedding level client-side); all WRITES are server-only. The per-pass
-- cleaning runs as applyBedding(hutch), called from HBKeepAlive's existing
-- loaded-square hutch scan - NOT a second grid scan, and NEVER the un-pruned
-- DesignationZoneAnimal hutch list (that list holds stale/orphaned hutches and
-- is exactly STA Better Hutches' type-1/-1 ObjectModData bug). Adding hay is an
-- admin action that routes client → HBCmd.ADD_BEDDING → server handler in
-- HBCommands, which calls HBBedding.addBedding here. This module owns the
-- ModData schema (HBData.NS_HUTCH) and every write to it.
--
-- API safety: this only touches getHutchDirt/setHutchDirt/getNestBoxDirt/
-- setNestBoxDirt and getModData - none read the hutch script def, so none can
-- hit the engine-internal NPE that getMaxAnimals() does (see HBKeepAlive).

HBBedding = {}

-- Tunables (module-level for now; promote to SandboxVars later if wanted).
HBBedding.MAX            = 100  -- max bedding "charge" a hutch can hold (shown as %)
HBBedding.CLEAN_PER_PASS = 5    -- max dirt absorbed per pass (rate limit, for visuals)
HBBedding.DEFAULT_TUFTS  = 4    -- fallback if the HayTuftsPerBedding option is gone
HBBedding.DEFAULT_RATIO  = 3    -- fallback dirt-absorbed-per-bedding ratio

-- Hay tufts required to fully bed a hutch - server-tunable via the
-- RFTDHusbandry.HayTuftsPerBedding sandbox option (default 4 → each tuft = 25%).
function HBBedding.tuftsPerFull()
    local sv = SandboxVars and SandboxVars.RFTDHusbandry
    local n  = sv and sv.HayTuftsPerBedding
    if type(n) ~= "number" or n < 1 then n = HBBedding.DEFAULT_TUFTS end
    return n
end

-- Bedding charge granted per HayTuft. Exactly tuftsPerFull() adds reach MAX.
function HBBedding.perAdd()
    return HBBedding.MAX / HBBedding.tuftsPerFull()
end

-- Dirt absorbed per 1 unit of bedding consumed - server-tunable via
-- RFTDHusbandry.BeddingDirtRatio (default 3 → 1 bedding soaks up 3 dirt, so a
-- full 100 bed absorbs ~300 dirt of natural buildup before it runs out).
function HBBedding.dirtPerBedding()
    local sv = SandboxVars and SandboxVars.RFTDHusbandry
    local n  = sv and sv.BeddingDirtRatio
    if type(n) ~= "number" or n < 0.5 then n = HBBedding.DEFAULT_RATIO end
    return n
end

-- If true, bedding is never consumed - placing hay once keeps a coop clean
-- forever (RFTDHusbandry.BeddingNeverDepletes). Cleaning still happens; only
-- the bedding spend is skipped.
function HBBedding.neverDepletes()
    local sv = SandboxVars and SandboxVars.RFTDHusbandry
    return sv and sv.BeddingNeverDepletes == true
end

-- -------------------------------------------------------------------------
-- Read helpers (both sides). ModData is replicated to clients on transmit.
-- -------------------------------------------------------------------------

-- Remaining bedding charge on a hutch (0..MAX), 0 if never bedded.
function HBBedding.getAmount(hutch)
    if not hutch then return 0 end
    local md = hutch:getModData()
    local t  = md and md[HBData.NS_HUTCH]
    return (t and t.bedding) or 0
end

-- Convenience snapshot for UI: dirt, nest-box dirt, bedding charge.
--
-- Dirt is read from the ModData MIRROR first, falling back to the native
-- getHutchDirt(). WHY: hutchDirt is a native IsoObject field; transmitModData
-- only replicates ModData, so on a dedicated server the client never receives
-- native dirt changes (it would show a stale 0). The server mirrors dirt into
-- ModData whenever applyBedding runs, so reading the mirror gives
-- the client an accurate, synced view. On host/SP (no mirror yet) the native
-- read is correct. Authority stays server-side native; this is display only.
function HBBedding.getStatus(hutch)
    local md = hutch and hutch:getModData()
    local t  = md and md[HBData.NS_HUTCH]
    -- getHutchDirt/getNestBoxDirt are field returns (IsoHutch:965/973); the
    -- guards here were only ever standing in for the nil-hutch case above.
    local dirt, nbDirt
    if t and t.dirt ~= nil then dirt = t.dirt
    elseif hutch then dirt = hutch:getHutchDirt() or 0 end
    if t and t.nbDirt ~= nil then nbDirt = t.nbDirt
    elseif hutch then nbDirt = hutch:getNestBoxDirt() or 0 end
    return {
        dirt    = dirt or 0,
        nbDirt  = nbDirt or 0,
        bedding = (t and t.bedding) or 0,
        max     = HBBedding.MAX,
    }
end

-- -------------------------------------------------------------------------
-- Server-side writes
-- -------------------------------------------------------------------------

if not isServer() then return end

print("[HB] HBBedding loaded - hutch bedding/cleaning (server)")

-- Merge a key into the hutch's NS_HUTCH ModData table (create on demand).
local function putState(hutch, k, v)
    local md = hutch:getModData()
    if not md[HBData.NS_HUTCH] then md[HBData.NS_HUTCH] = {} end
    md[HBData.NS_HUTCH][k] = v
end

-- One cleaning pass for a single LIVE hutch, called per HBKeepAlive tick.
--
-- Bedding has NO time decay. It is consumed only by ABSORBING the dirt the coop
-- naturally generates: each pass we take the dirt that has built up (vanilla
-- raises hutchDirt/nestBoxDirt over time, scaled by occupancy) and soak it back
-- to 0, spending bedding at dirtPerBedding() dirt per 1 bedding. So a busy coop
-- burns bedding faster than a quiet one, and nothing depends on day-length or
-- wall-clock. Absorption is rate-limited to CLEAN_PER_PASS dirt/pass so a coop
-- that was already filthy when bedded cleans down visibly rather than instantly.
-- When bedding runs out, leftover dirt simply stays and accrues as normal.
--
-- Mirrors resulting dirt into ModData so dedicated-server clients can see it
-- (native hutchDirt isn't replicated by transmitModData - see getStatus), and
-- auto-prunes the record once a hutch is clean and out of bedding.
function HBBedding.applyBedding(hutch)
    if not hutch then return end
    local amount = HBBedding.getAmount(hutch)
    if amount <= 0 then return end

    -- KEEP: the dirt getters/setters are field accesses, but transmitModData
    -- (IsoObject:4470) pushes an ObjectModData packet through GameServer, and
    -- this runs once per hutch per HBKeepAlive tick - a send failure must not
    -- abort the keep-alive sweep mid-scan.
    pcall(function()
        local dirt = hutch:getHutchDirt()   or 0
        local nb   = hutch:getNestBoxDirt() or 0
        if dirt + nb <= 0 then return end  -- coop is clean; bedding just sits, no write

        local ratio    = HBBedding.dirtPerBedding()
        local infinite = HBBedding.neverDepletes()

        -- Dirt we can absorb this pass: limited by the rate cap, by how much
        -- dirt exists, and (unless bedding never depletes) by what the remaining
        -- bedding can soak (amount*ratio).
        local soakCap = infinite and (dirt + nb) or (amount * ratio)
        local absorb  = math.min(HBBedding.CLEAN_PER_PASS, dirt + nb, soakCap)
        if absorb <= 0 then return end

        if not infinite then
            amount = math.max(0, amount - absorb / ratio)
        end
        local fromDirt = math.min(dirt, absorb)
        dirt = dirt - fromDirt
        local fromNb = math.min(nb, absorb - fromDirt)
        nb = nb - fromNb
        hutch:setHutchDirt(dirt)
        hutch:setNestBoxDirt(nb)

        if amount <= 0 and dirt <= 0 and nb <= 0 then
            -- Clean AND out of bedding: drop the record so idle hutches store
            -- nothing (auto-flush - keeps per-hutch ModData from lingering).
            hutch:getModData()[HBData.NS_HUTCH] = nil
        else
            putState(hutch, "bedding", amount)
            putState(hutch, "dirt",    dirt)
            putState(hutch, "nbDirt",  nb)
        end
        -- Safe transmit: this hutch came from a loaded-square getObjects()
        -- scan, so it is live and in its square's object list - not the stale
        -- zone-list case that produces junk type-1/-1 ObjectModData packets.
        hutch:transmitModData()
    end)
end

-- Add bedding charge to a hutch (admin "spawn hay"). Caps at MAX. Returns the
-- new total. Server-authoritative; transmits so clients see the new level.
function HBBedding.addBedding(hutch, amount)
    if not hutch then return 0 end
    amount = amount or HBBedding.perAdd()
    local newAmt = math.min(HBBedding.MAX, HBBedding.getAmount(hutch) + amount)
    putState(hutch, "bedding", newAmt)
    -- KEEP: transmitModData (IsoObject:4470) is a network send, not a getter.
    pcall(hutch.transmitModData, hutch)
    return newAmt
end

-- Resolve the live MASTER hutch on a given square (client sends coords).
-- A multi-tile coop puts a linked slave IsoHutch on its other squares and keeps
-- the dirt, animals and bedding on the master alone, so the coords that arrive
-- here may name either half - see HBHutchContextMenu's header for the shape of
-- it. getHutch resolves both to the master.
function HBBedding.resolveHutchAt(x, y, z)
    local cell = getCell()
    if not cell then return nil end
    -- KEEP: getGridSquare (IsoCell:2791) dereferences the ServerMap.instance
    -- singleton; client-supplied coordinates can land off any loaded chunk.
    local ok, sq = pcall(cell.getGridSquare, cell, x, y, z)
    if not ok or not sq then return nil end
    local objs = sq:getObjects()   -- IsoGridSquare:8005, field return
    if not objs then return nil end
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        if o and instanceof(o, "IsoHutch") then
            -- getHutch (IsoHutch:127) returns itself for a master and follows
            -- linkedX/linkedY home for a slave. It answers nil when that linked
            -- square is not loaded, so keep walking the square rather than
            -- calling the whole lookup a miss on the strength of one object.
            local master = o:getHutch()
            if master then return master end
        end
    end
    return nil
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
