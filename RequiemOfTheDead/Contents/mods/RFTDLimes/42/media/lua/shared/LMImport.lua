-- SPDX-License-Identifier: GPL-3.0-or-later
-- LMImport.lua - the dialect door: every text that becomes a zone store
-- (both sides). Reads our own .ini (backup restore), schema-1 JSON (the
-- sharing surface), migrates old-ladder stores, and writes the export.
--
-- THE PHUNZONES DIALECT DIED HERE 2026-08-27 (S2 of the redesign). The
-- in-game importer spoke it from M0 so a fresh install could eat the
-- production layer with zero ceremony; that door closed once the redesign
-- made the offline converter (tools/limes-zone-converter.html) the one
-- translation path - it does the full restructuring (archetypes to tier
-- records, behavior templates to profiles, lewtkey to profile stubs) that a
-- boot-time importer never could. In game, PhunZones text is refused with
-- directions to the converter. What SURVIVES from that era is the ladder
-- vocabulary (DIFF_TO_TIER) and migrateLadder below, because stores WRITTEN
-- by the old importer or the old seed still exist on disk and must keep
-- loading forever.
--
-- Engine-free on purpose, same contract as LMCore: stock Lua 5.1 only, so the
-- behavioural suite drives every dialect through the real code path.

require "RDJson"
require "LMCore"

LMImport = LMImport or {}

-- ---------------------------------------------------------------------------
-- The ladder vocabulary. Old stores speak difficulty NUMBERS (0-5) and the
-- six archetype template names; the record-kind model speaks the five rung
-- names. One map, shared with the offline converter's tables, so every door
-- folds the same way (Medium and Intermediate collapse onto Medium).
-- ---------------------------------------------------------------------------

LMImport.DIFF_TO_TIER = {
    [0] = "Newcomer", [1] = "Easy", [2] = "Medium",
    [3] = "Medium",   [4] = "Spicy", [5] = "IDDQL",
}

-- The old six-rung template ladder, name -> ladder position (1-5 in the new
-- vocabulary; Medium and Intermediate share a rung). OLD_ORDER fixes the
-- iteration so the rung collision resolves the same way on every machine -
-- Medium is processed before Intermediate, so Medium's dials win, matching
-- the offline converter.
local OLD_LADDER = { Very_Easy = 1, Easy = 2, Medium = 3,
                     Intermediate = 3, Hard = 4, Very_Hard = 5 }
local OLD_ORDER  = { "Very_Easy", "Easy", "Medium", "Intermediate", "Hard", "Very_Hard" }
local RUNG       = { "Newcomer", "Easy", "Medium", "Spicy", "IDDQL" }   -- rank -> name

-- Fields the redesign retired: the sprinter band is superseded by tier
-- sprinter rules (dirgeSprinterShare, live since S8), lewtkey by profile
-- loot rules (lootReduce, enforced by LMLoot). Stripped by migration and
-- no longer registered - a store carrying them resolves them as unknown keys.
local STRIPPED = { minSprinterRisk = true, maxSprinterRisk = true, lewtkey = true }

-- ---------------------------------------------------------------------------
-- migrateLadder - one-shot rewrite of a pre-redesign store, IN PLACE.
--
-- What "old" looks like after LMIni.parse: the six archetype templates as
-- kind-less rect-less records whose own `tier = N` line landed in the SLOT as
-- a numeric string, zones with `inherits = Very_Hard`-style chains, and no
-- kind anywhere. The rewrite:
--
--   1. numeric tier slots map to rung names (DIFF_TO_TIER),
--   2. a chain through an archetype is cut at the archetype: the zone gets
--      the archetype's rung in its SLOT (unless it already set one) and
--      inherits whatever survives beyond the ladder,
--   3. archetypes become the tier RECORDS for their rungs, dials carried,
--      rank stamped; a rung referenced by a slot this migration wrote is
--      backfilled bare if no archetype carried it,
--   4. minSprinterRisk/maxSprinterRisk/lewtkey are stripped everywhere.
--
-- IDEMPOTENT AND CONSERVATIVE: a new-model store has no numeric slots, no
-- kind-less ladder templates and no stripped keys, so every pass over one is
-- a no-op - which is why this can run on every boot and every ini paste
-- instead of needing a version stamp in the file. It never resurrects a rung
-- the admin deleted: backfill only covers slots the migration itself wrote.
-- Returns the notes list; empty means the store was already current.
-- ---------------------------------------------------------------------------

function LMImport.migrateLadder(zones)
    local notes = {}
    local function note(msg) notes[#notes + 1] = msg end

    -- The archetypes present in THIS store, old-shape only: kind-less and
    -- rect-less. The new seed's Easy/Medium are kind = "tier" and never match.
    local arch = {}
    for _, name in ipairs(OLD_ORDER) do
        local rec = zones[name]
        if rec and rec.kind == nil and (not rec.rects or #rec.rects == 0) then
            arch[name] = rec
        end
    end

    -- Pass 1: slots and chains, on every record.
    local assigned = {}          -- rungs this migration wrote into slots
    local repointed, stripped = 0, 0
    for name, rec in pairs(zones) do
        if not arch[name] then
            -- Numeric slot -> rung name.
            local n = tonumber(rec.tier)
            if n ~= nil then
                local rung = LMImport.DIFF_TO_TIER[math.floor(n)]
                if rung then
                    rec.tier = rung
                    assigned[rung] = true
                else
                    note(name .. ": tier '" .. tostring(rec.tier)
                        .. "' is not on the 0-5 ladder - cleared")
                    rec.tier = nil
                end
            end
            -- Chain through an archetype: cut, and carry the rung.
            if rec.inherits and arch[rec.inherits] then
                local rung = RUNG[OLD_LADDER[rec.inherits]]
                if rec.tier == nil then
                    rec.tier = rung
                    assigned[rung] = true
                end
                -- Follow the ladder upward to whatever survives; "_default"
                -- is the implicit root and goes back to absent.
                local cur, seen = arch[rec.inherits].inherits, { [name] = true }
                while cur and arch[cur] and not seen[cur] do
                    seen[cur] = true
                    cur = arch[cur].inherits
                end
                if cur == "_default" then cur = nil end
                rec.inherits = cur
                repointed = repointed + 1
            end
        end
        -- Retired fields, everywhere (moon overlays included - old stores
        -- have none, but a half-edited one must not smuggle them back).
        for k in pairs(STRIPPED) do
            if rec.fields and rec.fields[k] ~= nil then
                rec.fields[k] = nil
                stripped = stripped + 1
            end
            if rec.moon and rec.moon.fields and rec.moon.fields[k] ~= nil then
                rec.moon.fields[k] = nil
                stripped = stripped + 1
            end
        end
    end
    if repointed > 0 then
        note(repointed .. " zone(s) stepped off the template ladder onto tier slots")
    end
    if stripped > 0 then
        note("retired field(s) stripped from " .. stripped .. " place(s)"
            .. " (minSprinterRisk/maxSprinterRisk/lewtkey)")
    end

    -- Pass 2: archetypes become tier records. Delete first so Easy/Medium can
    -- be re-created under their own names with the new shape.
    local carried = {}           -- rung -> the archetype whose dials it carries
    for name in pairs(arch) do zones[name] = nil end
    for _, name in ipairs(OLD_ORDER) do
        local rec = arch[name]
        if rec then
            local rank = OLD_LADDER[name]
            local rung = RUNG[rank]
            if carried[rung] then
                note(name .. ": also maps to tier " .. rung .. " - "
                    .. carried[rung] .. "'s dials kept, this one's dropped")
            elseif zones[rung] then
                note(name .. ": cannot become tier " .. rung .. " - the name is"
                    .. " already taken by another record; dials dropped")
            else
                carried[rung] = name
                local fields = { rank = rank }
                for k, v in pairs(rec.fields or {}) do
                    if not STRIPPED[k] then fields[k] = v end
                end
                zones[rung] = { kind = "tier", fields = fields }
                note(name .. ": archetype became tier " .. rung
                    .. (name ~= rung and " (renamed)" or ""))
            end
        end
    end

    -- Backfill: a rung this migration pointed slots at must exist, even bare.
    for rank, rung in ipairs(RUNG) do
        if assigned[rung] and not zones[rung] then
            zones[rung] = { kind = "tier", fields = { rank = rank } }
            note("tier " .. rung .. " referenced but no archetype carried its"
                .. " dials - created with rank only")
        end
    end

    return notes
end

-- ---------------------------------------------------------------------------
-- THE ONE DOOR IN, whichever dialect is knocking (2026-08-05; PhunZones lane
-- removed 2026-08-27).
--
-- Sniffing is a POSITIVE test per dialect - our .ini opens with a [section],
-- schema-1 JSON opens with a brace and a QUOTED key - and anything
-- unrecognised is refused with directions to the offline converter, which is
-- where PhunZones data goes now. Both lanes return the same shape -
-- ok, { zones, warnings, count, format } - and both routes end at the same
-- authoritative apply on the server.
-- ---------------------------------------------------------------------------
-- SCHEMA-1 JSON - the sharing surface (2026-08-26 redesign).
--
-- The offline converter (tools/limes-zone-converter.html) emits this, the
-- in-game Export will emit it, and it is the ONLY dialect zone setups are
-- shared in. Envelope { schema = 1, revision, records }; records are keyed by
-- id and discriminated by `kind` (absent = zone, "tier", "profile"). The JSON
-- nests a tier's moon overlay as moon = { phases, fields } and a profile's
-- loot rules as an array of { kind = "item"|"category", name, pct }; the
-- STORE holds the same data as the flat moon_/lootReduce encodings, and this
-- function is where the two shapes meet.
--
-- UNTRUSTED INPUT, NORMALIZED SAVEABLE. The server re-parses what a client
-- pastes (LMSync), and validate() ERRORS block every later save - so illegal
-- structure on a terminal record (a tier with ground, a profile with a
-- parent) is dropped HERE with a warning that names it, rather than imported
-- into a store the editor would then refuse to save. Unknown kinds and
-- unknown fields ride through verbatim (forward compat), exactly like the
-- other dialects.
-- ---------------------------------------------------------------------------

local function lootToString(list, id, warnings)
    local good = {}
    for i = 1, #list do
        local e = list[i]
        local kind = e and e.kind
        local name = e and tostring(e.name or "")
        local pct  = e and tonumber(e.pct)
        local okName = (kind == "item" and name:match("^[%w_%.]+$"))
                    or (kind == "category" and name:match("^[%w_]+$"))
        if okName and pct and pct >= 0 and pct <= 100 then
            good[#good + 1] = { kind = kind, name = name, pct = pct }
        else
            warnings[#warnings + 1] = id .. ": loot rule " .. i
                .. " does not fit the grammar, skipped"
        end
    end
    if #good == 0 then return nil end
    return Limes.formatLootReduce(good)
end

local RESERVED_FIELD = { rects = true, inherits = true, name = true,
                         profiles = true, kind = true, tier = true, moon = true }

function LMImport.parseSchema1(text)
    local doc, derr = RDJson.decode(text)
    if doc == nil then return false, "JSON parse failed: " .. tostring(derr) end
    if type(doc) ~= "table" then return false, "not a JSON object" end
    if doc.schema ~= 1 then
        return false, "schema " .. tostring(doc.schema)
            .. " is not a version this build reads (expected 1)"
    end
    if type(doc.records) ~= "table" then return false, "no records in the document" end

    local warnings, zones, count = {}, {}, 0
    for id, src in pairs(doc.records) do
        id = tostring(id)
        if type(src) ~= "table" then
            warnings[#warnings + 1] = id .. ": not a record, skipped"
        elseif not id:match("^[%w_%-%.]+$") then
            warnings[#warnings + 1] = id .. ": id unusable as an .ini section, skipped"
        else
            local kind = src.kind
            if kind == "zone" or kind == "" then kind = nil end
            if kind ~= nil then kind = tostring(kind) end
            local terminal = kind == "tier" or kind == "profile"
            local rec = { kind = kind, fields = {} }

            -- Structure, zones only; on a terminal record it is dropped loudly
            -- so the imported store stays saveable (see header).
            local function dropTerminal(what)
                warnings[#warnings + 1] = id .. ": a " .. kind .. " record cannot have "
                    .. what .. " - dropped"
            end
            if src.parent ~= nil then
                if terminal then dropTerminal("a parent")
                else rec.inherits = tostring(src.parent) end
            end
            if src.tier ~= nil then
                if terminal then dropTerminal("a tier")
                else rec.tier = tostring(src.tier) end
            end
            if type(src.rects) == "table" and #src.rects > 0 then
                if terminal then dropTerminal("ground")
                else
                    rec.rects = {}
                    for i, r in ipairs(src.rects) do
                        local x1, y1 = tonumber(r and r[1]), tonumber(r and r[2])
                        local x2, y2 = tonumber(r and r[3]), tonumber(r and r[4])
                        if x1 and y1 and x2 and y2 then
                            rec.rects[#rec.rects + 1] = { x1, y1, x2, y2 }
                        else
                            warnings[#warnings + 1] = id .. ": rects[" .. i
                                .. "] is not four numbers, skipped"
                        end
                    end
                end
            end
            if type(src.profiles) == "table" and #src.profiles > 0 then
                if terminal then dropTerminal("profiles")
                else
                    rec.profiles = {}
                    for i = 1, #src.profiles do
                        rec.profiles[#rec.profiles + 1] = tostring(src.profiles[i])
                    end
                end
            end

            -- The moon overlay, tiers only.
            if type(src.moon) == "table" then
                if kind ~= "tier" then
                    warnings[#warnings + 1] = id
                        .. ": only a tier carries a moon overlay - dropped"
                else
                    local moon = { fields = {} }
                    if src.moon.phases ~= nil then moon.phases = tostring(src.moon.phases) end
                    for k, v in pairs(src.moon.fields or {}) do
                        if type(v) == "table" then
                            warnings[#warnings + 1] = id .. ".moon." .. tostring(k)
                                .. ": table-valued, dropped"
                        else
                            moon.fields[tostring(k)] = v
                        end
                    end
                    rec.moon = moon
                end
            end

            -- Fields, verbatim but flat and never shadowing structure.
            for k, v in pairs(src.fields or {}) do
                k = tostring(k)
                if RESERVED_FIELD[k] or k:match("^moon_") then
                    warnings[#warnings + 1] = id .. "." .. k
                        .. ": field name shadows record structure, dropped"
                elseif not k:match("^[%w_]+$") then
                    warnings[#warnings + 1] = id .. "." .. k
                        .. ": field name unusable as an .ini key, dropped"
                elseif type(v) == "table" then
                    warnings[#warnings + 1] = id .. "." .. k .. ": table-valued, dropped"
                else
                    rec.fields[k] = v
                end
            end

            -- The display name is the announce title (the converter derived it
            -- FROM title; this is the inverse). An explicit title field wins.
            if src.name ~= nil and rec.fields.title == nil then
                rec.fields.title = tostring(src.name)
            end

            -- Loot rules -> the lootReduce grammar. An explicit field wins.
            if type(src.loot) == "table" and #src.loot > 0 then
                if rec.fields.lootReduce ~= nil then
                    warnings[#warnings + 1] = id
                        .. ": carries both a loot array and a lootReduce field - the field wins"
                else
                    rec.fields.lootReduce = lootToString(src.loot, id, warnings)
                end
            end

            zones[id] = rec
            count = count + 1
        end
    end

    if count == 0 then return false, "the document contains no records" end

    -- The same dangling-reference reports the other dialects give.
    for name, z in pairs(zones) do
        if z.inherits and not zones[z.inherits] then
            warnings[#warnings + 1] = name .. " inherits '" .. z.inherits
                .. "', which is not in this import"
        end
        if z.tier and not zones[z.tier] then
            warnings[#warnings + 1] = name .. " stands on tier '" .. z.tier
                .. "', which is not in this import"
        end
    end

    table.sort(warnings)
    return true, { zones = zones, warnings = warnings, count = count }
end

-- Does this text read as schema-1 JSON rather than a PhunZones Lua literal?
-- Both can open with "{", but a JSON object's first token after it is a
-- QUOTED key (or "}") and a Lua table's is a bare name or "[" - so the quote
-- is the discriminator, and anything unrecognised still falls through to the
-- PhunZones path with its detailed errors.
function LMImport.looksLikeJson(text)
    return tostring(text or ""):match('^%s*{%s*["}]') ~= nil
end

function LMImport.parseAny(text)
    if LMIni and LMIni.looksLikeIni and LMIni.looksLikeIni(text) then
        local zones, warnings = LMIni.parse(text)
        local count = 0
        for _ in pairs(zones) do count = count + 1 end
        if count == 0 then
            return false, "reads as an RFTDLimes .ini but contains no [sections]"
        end
        -- An old backup is a legitimate thing to restore, so the ini lane
        -- migrates the ladder inline; on a current store this is a no-op.
        local mnotes = LMImport.migrateLadder(zones)
        for i = 1, #mnotes do
            warnings[#warnings + 1] = "migrated: " .. mnotes[i]
        end
        local recount = 0
        for _ in pairs(zones) do recount = recount + 1 end
        count = recount
        -- The dangling-parent report, because it is the warning that matters
        -- most when restoring a partial backup.
        for name, z in pairs(zones) do
            if z.inherits and not zones[z.inherits] then
                warnings[#warnings + 1] = name .. " inherits '" .. z.inherits
                    .. "', which is not in this import"
            end
        end
        table.sort(warnings)
        return true, { zones = zones, warnings = warnings, count = count, format = "ini" }
    end

    if LMImport.looksLikeJson(text) then
        local ok, res = LMImport.parseSchema1(text)
        if ok then res.format = "json" end
        return ok, res
    end

    return false, "not an RFTDLimes .ini or a schema-1 zones JSON. A PhunZones"
        .. " layer converts OFFLINE now: open tools/limes-zone-converter.html"
        .. " (in the mod's repo/workshop tools), feed it the export, and paste"
        .. " the JSON it produces here."
end

-- ---------------------------------------------------------------------------
-- THE DOOR OUT - the whole store as schema-1 JSON (2026-08-27).
--
-- Everything ships: zones, tiers, profiles, loot, moon overlays. The inverse
-- of parseSchema1's mapping, so export -> import is lossless (pinned in the
-- suite): inherits -> parent, the slot -> tier, moon flat -> nested, and a
-- lootReduce field -> the structured loot array WHEN the whole field parses -
-- a field carrying rules the grammar rejects rides verbatim instead, because
-- an export must never destroy what it is exporting. No `name` key is
-- emitted: our display name IS the title field, and it rides in fields.
--
-- Deterministic (RDJson.encode sorts object keys), so two exports of the same
-- store diff clean - the property that makes shared setups reviewable.
--
-- Callable on either side. A client exports its replica, which today is the
-- whole store; if a server-only field is ever registered in Limes, a client
-- export will omit it by construction (stripServerOnly), which is the correct
-- reading of a SHARING surface - secrets do not ship because someone clicked
-- Export.
-- ---------------------------------------------------------------------------

function LMImport.exportSchema1(rawZones, revision)
    local records = {}
    for name, rec in pairs(rawZones or {}) do
        local out = {}
        if rec.kind ~= nil and rec.kind ~= "zone" then out.kind = rec.kind end
        if rec.inherits then out.parent = rec.inherits end
        if rec.tier then out.tier = rec.tier end
        if rec.rects and #rec.rects > 0 then
            out.rects = {}
            for i, r in ipairs(rec.rects) do
                out.rects[i] = { r[1], r[2], r[3], r[4] }
            end
        end
        if rec.profiles and #rec.profiles > 0 then
            out.profiles = {}
            for i, p in ipairs(rec.profiles) do out.profiles[i] = p end
        end
        if rec.moon then
            local m = {}
            if rec.moon.phases and rec.moon.phases ~= "" then m.phases = rec.moon.phases end
            local mf, anyM = {}, false
            for k, v in pairs(rec.moon.fields or {}) do mf[k] = v; anyM = true end
            if anyM then m.fields = mf end
            if m.phases or anyM then out.moon = m end
        end
        local fields, anyF = {}, false
        for k, v in pairs(rec.fields or {}) do fields[k] = v end
        local lr = fields.lootReduce
        if lr ~= nil and lr ~= "" then
            local entries, bad = Limes.parseLootReduce(lr)
            if #bad == 0 and #entries > 0 then
                out.loot = {}
                for i, e in ipairs(entries) do
                    out.loot[i] = { kind = e.kind, name = e.name, pct = e.pct }
                end
                fields.lootReduce = nil
            end
        end
        for _ in pairs(fields) do anyF = true break end
        if anyF then out.fields = fields end
        records[name] = out
    end
    return RDJson.encode({ schema = 1, revision = tonumber(revision) or 0,
                           records = records })
end

return LMImport

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
