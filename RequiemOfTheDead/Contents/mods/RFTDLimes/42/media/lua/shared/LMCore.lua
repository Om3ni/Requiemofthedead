-- SPDX-License-Identifier: GPL-3.0-or-later
-- LMCore.lua - the zone store, and the only door into it (both sides).
--
-- THE public surface (docs/limes-design.md §4-§5). Satellites never touch the
-- store; they call Limes.getLocation(x, y), register typed fields, and listen
-- for change callbacks - Limes.onChanged(fn) for "the store moved, re-derive"
-- and Limes.onZoneEvent(fn) for per-zone added/edited/enabled/disabled/deleted,
-- which is what a consumer holding a standing side effect needs in order to
-- unwind it (§5.1). Everything else in this mod is a producer feeding this
-- file: LMPersist reads the .ini into it, LMSync carries it over the wire,
-- LMImport translates a PhunZones export into its raw shape. Consumers on the
-- client and the server read the SAME resolved records through the SAME
-- functions, which is the whole zero-steady-state-wire design: a lookup is a
-- local table scan, never a packet.
--
-- DELIBERATELY ENGINE-FREE. No isServer(), no Events, no SandboxVars at file
-- scope or below - stock Lua 5.1 only - so tools\run-tests.bat exercises the
-- resolver, the registry, and the lookup under the real Kahlua semantics
-- (every number a double, no integer subtype) without a stub layer. Keep it
-- that way: engine wiring belongs in LMSync/LMPersist, not here.
--
-- RAW vs RESOLVED, the two shapes this file speaks:
--
--   raw zone      { inherits = "Name"|nil,
--                   rects    = { {x1,y1,x2,y2}, ... },   -- may be empty: template
--                   fields   = { key = value, ... } }    -- sparse; unset = inherit
--
--   resolved zone { name, template, disabled, priority, area, inherits,
--                   rects = normalized copy,
--                   fields = full inheritance-flattened map }
--
-- Resolution happens ONCE per apply (boot, baseline, delta), never per lookup:
-- inheritance chains are flattened (cycle-guarded, "_default" as the implicit
-- root under everything), registered fields are coerced to their declared type
-- and clamped, unknown fields ride along verbatim (forward compat - the key a
-- future satellite will register is not an error today, it is warned once and
-- preserved). A resolved record contains only fields that are SET somewhere in
-- its chain: consumers distinguish "unset, use my own default" from "explicitly
-- zero", which is the Dirge blank-inherits contract (RQPhunZones.getEffectiveRules).
-- Limes.fields.get(zone, name) is the convenience that applies the registry
-- default when a consumer does not care about that distinction.
--
-- Lookup: linear scan, per-zone bounding box first (~90 zones x few rects is
-- microseconds; the 256-tile grid index drops in behind this same function if
-- the live box ever says otherwise). Containment is tile-inclusive on all four
-- edges. Overlaps resolve smallest-total-area-first - the nested-zone intuition:
-- the gun store inside Louisville is the gun store - with the explicit
-- "priority" field (higher wins) as the tiebreak, then name order so equal
-- claims resolve the same way on every machine.

Limes  = Limes or {}
LMCore = LMCore or {}

local function warn(msg)
    print("[Limes] " .. tostring(msg))
end

-- ---------------------------------------------------------------------------
-- Field registry. Consumers declare before boot completes; the editor renders
-- what is declared here (§5) - keep specs complete, they are UI later.
-- ---------------------------------------------------------------------------

Limes.fields = Limes.fields or {}

local specs = {}     -- field name -> { owner, type, default, min, max }

-- Names the record structure itself uses; a field by these names would shadow
-- them in the .ini section and in resolved records.
local RESERVED = { rects = true, inherits = true, name = true }

-- Fields the RESOLVER itself reads (rebuild/getLocation). These must reach every
-- machine or the two sides resolve differently in silence - the worst class of
-- bug this store can have - so side is forced to "both" no matter what a
-- registrant asks for.
local RESOLVER_CRITICAL = { disabled = true, priority = true }

local SIDES = { server = true, client = true, both = true }

-- spec: { type = "number"|"boolean"|"string", default = ?, min = ?, max = ?,
--         side = "server"|"client"|"both" }
--
-- `side` declares where a field is CONSUMED, not where it lives (§5). LMSync
-- strips server-only fields from what it sends clients: smaller baseline, and
-- loot tables / difficulty stop riding in every client's memory. It never
-- affects resolution on the authoritative side.
function Limes.fields.register(owner, name, spec)
    owner, name = tostring(owner), tostring(name)
    spec = spec or {}
    if RESERVED[name] then
        warn("fields.register: '" .. name .. "' is reserved (" .. owner .. ")")
        return false
    end
    if spec.type ~= "number" and spec.type ~= "boolean" and spec.type ~= "string" then
        warn("fields.register: bad type for '" .. name .. "' (" .. owner .. ")")
        return false
    end
    local have = specs[name]
    if have and have.owner ~= owner then
        -- First claim wins: load order inside a milestone is alphabetical and
        -- stable, so this is deterministic - and loud, because two owners for
        -- one key is a design defect, not a runtime condition to arbitrate.
        warn("fields.register: '" .. name .. "' already owned by " .. have.owner
            .. ", ignoring claim from " .. owner)
        return false
    end
    -- An unusable side is corrected to "both" and never to a narrower value:
    -- over-sending is a wire cost, under-sending is a correctness bug.
    local side = spec.side or "both"
    if not SIDES[side] then
        warn("fields.register: '" .. name .. "' has unknown side '" .. tostring(side)
            .. "' (" .. owner .. "), treating as both")
        side = "both"
    end
    if RESOLVER_CRITICAL[name] and side ~= "both" then
        warn("fields.register: '" .. name .. "' is resolver-critical, side forced to both ("
            .. owner .. ")")
        side = "both"
    end
    specs[name] = {
        owner = owner, type = spec.type, side = side,
        default = spec.default, min = spec.min, max = spec.max,
    }
    return true
end

function Limes.fields.spec(name)
    return specs[name]
end

-- Sorted view for the editor / form panel to render from.
function Limes.fields.list()
    local names = {}
    for n in pairs(specs) do names[#names + 1] = n end
    table.sort(names)
    local out = {}
    for i = 1, #names do
        local s = specs[names[i]]
        out[i] = { name = names[i], owner = s.owner, type = s.type, side = s.side,
                   default = s.default, min = s.min, max = s.max }
    end
    return out
end

-- Field read with the registry default applied. `zone` may be nil (not in any
-- zone) - returns the default, so call sites need no nil-dance.
function Limes.fields.get(zone, name)
    local v = zone and zone.fields and zone.fields[name]
    if v ~= nil then return v end
    local s = specs[name]
    return s and s.default or nil
end

-- Raw zones with server-only fields removed, for LMSync to put on the wire
-- (§6). Returns a NEW table - the caller must never hand the live store to the
-- serializer with fields deleted out of it.
--
-- Rules, all in the safe direction: unregistered keys ship (forward compat must
-- never silently drop an admin's data), a zone whose every field was stripped
-- still ships because its geometry and its place in the inheritance chain both
-- matter to the client, and rects are shared by reference because stripping
-- does not touch them and the wire copies them anyway.
function Limes.fields.stripServerOnly(rawZones)
    local out = {}
    for name, rec in pairs(rawZones or {}) do
        local fields = nil
        if rec.fields then
            fields = {}
            for k, v in pairs(rec.fields) do
                local s = specs[k]
                if not s or s.side ~= "server" then fields[k] = v end
            end
        end
        out[name] = { inherits = rec.inherits, rects = rec.rects, fields = fields }
    end
    return out
end

-- Coerce a stored value to its registered type. nil = unusable/unset, which
-- resolution treats as "inherit": the value simply is not there.
local function coerce(spec, v)
    if v == nil then return nil end
    if spec.type == "number" then
        local n = tonumber(v)
        if n == nil then return nil end
        if spec.min and n < spec.min then n = spec.min end
        if spec.max and n > spec.max then n = spec.max end
        return n
    elseif spec.type == "boolean" then
        if v == true  or v == "true"  or v == 1 or v == "1" then return true  end
        if v == false or v == "false" or v == 0 or v == "0" then return false end
        return nil
    else
        return tostring(v)
    end
end

-- ---------------------------------------------------------------------------
-- Core's own fields. Satellite vocabularies (dirge*, sprinter risks, no*
-- restriction flags, lewtkey, zeds) are registered by their consumers at their
-- milestone; until then those keys ride the unknown-key path - preserved,
-- warned once - which doubles as the admin-visible list of fields that have no
-- consumer installed yet.
-- ---------------------------------------------------------------------------

-- side: the widget's vocabulary is client-consumed; disabled/priority are
-- resolver-critical (forced "both" regardless); tier is a scalar both halves
-- read. Satellites declare their own - loot tables and dirge weights are the
-- server-only cases the tag exists for.
Limes.fields.register("LMCore", "title",      { type = "string",  default = "",    side = "client" })
Limes.fields.register("LMCore", "subtitle",   { type = "string",  default = "",    side = "client" })
Limes.fields.register("LMCore", "order",      { type = "number",  default = 0,     side = "client" })
Limes.fields.register("LMCore", "noannounce", { type = "boolean", default = false, side = "client" })
Limes.fields.register("LMCore", "disabled",   { type = "boolean", default = false, side = "both" })
Limes.fields.register("LMCore", "priority",   { type = "number",  default = 0,     side = "both" })
Limes.fields.register("LMCore", "tier",       { type = "number",  default = 0,     side = "both", min = 0, max = 10 })

-- ---------------------------------------------------------------------------
-- Store state
-- ---------------------------------------------------------------------------

local rawStore   = {}    -- name -> raw zone (ownership transfers to LMCore on apply)
local resolved   = {}    -- name -> resolved zone
local index      = {}    -- array of resolved zones with geometry, lookup order
local warnedKeys = {}    -- unknown field key -> true (warn once per key, not per zone)
local listeners  = {}    -- onChanged   : fn(rev)
local zoneListeners = {} -- onZoneEvent : fn(event, name, zone, rev)

Limes.revision = 0

function Limes.onChanged(fn)
    listeners[#listeners + 1] = fn
end

-- ---------------------------------------------------------------------------
-- Zone lifecycle events (§5.1)
--
-- onChanged says THAT the store moved. Consumers holding standing side effects
-- need to know WHICH zone and HOW, because their undo path is a zone exit that
-- never fires if the zone stops existing under the player's feet: LMStats
-- modulates global sandbox values and restores on exit, LMWidget announces a
-- title, LMZeds runs a standing sweep.
--
--   fn(event, name, zone, rev)
--   event = "added" | "edited" | "enabled" | "disabled" | "deleted"
--
-- DERIVED, NEVER TRANSMITTED. Events are diffed out of rebuild(), which both
-- apply() and applyDelta() funnel through, so both sides compute the identical
-- sequence from the baseline or delta they already received - no event ever
-- costs a packet (§6.1 rule 1). Order is name-sorted so the sequence matches
-- machine to machine.
--
-- One event per zone per rebuild, prioritised added > deleted > enabled/
-- disabled > edited: a zone that is disabled AND edited in one delta reports
-- the transition, because that is the actionable half. `zone` is the new
-- resolved record except on "deleted", which carries the last-known one so a
-- consumer can unwind by geometry.
--
-- The diff is CONTENT-based, so a redundant baseline (a gap re-pull that turns
-- out to match) fires nothing at all. First boot on an empty store does report
-- every zone as "added"; consumers that only care about teardown should watch
-- "disabled" and "deleted".
-- ---------------------------------------------------------------------------

function Limes.onZoneEvent(fn)
    zoneListeners[#zoneListeners + 1] = fn
end

local function sameFields(a, b)
    for k, v in pairs(a) do if b[k] ~= v then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

local function sameRecord(a, b)
    if a.inherits ~= b.inherits or a.template ~= b.template
        or a.disabled ~= b.disabled or a.priority ~= b.priority
        or a.area ~= b.area or #a.rects ~= #b.rects then
        return false
    end
    for i = 1, #a.rects do
        local r, s = a.rects[i], b.rects[i]
        if r[1] ~= s[1] or r[2] ~= s[2] or r[3] ~= s[3] or r[4] ~= s[4] then return false end
    end
    -- Comparing RESOLVED records means a zone whose parent template moved
    -- reports "edited" too, which is the point: its effective config changed
    -- even though its own raw record did not.
    return sameFields(a.fields, b.fields)
end

local function diffEvents(prev, cur)
    local names, seen = {}, {}
    for n in pairs(prev) do names[#names + 1] = n; seen[n] = true end
    for n in pairs(cur) do if not seen[n] then names[#names + 1] = n end end
    table.sort(names)

    local events = {}
    for i = 1, #names do
        local n = names[i]
        local a, b = prev[n], cur[n]
        if not a then
            events[#events + 1] = { event = "added",   name = n, zone = b }
        elseif not b then
            events[#events + 1] = { event = "deleted", name = n, zone = a }
        elseif a.disabled ~= b.disabled then
            events[#events + 1] = { event = b.disabled and "disabled" or "enabled",
                                    name = n, zone = b }
        elseif not sameRecord(a, b) then
            events[#events + 1] = { event = "edited",  name = n, zone = b }
        end
    end
    return events
end

local function fireZoneEvents(events)
    for i = 1, #events do
        local e = events[i]
        for j = 1, #zoneListeners do
            local ok, err = pcall(zoneListeners[j], e.event, e.name, e.zone, Limes.revision)
            if not ok then warn("onZoneEvent listener error: " .. tostring(err)) end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Resolution
-- ---------------------------------------------------------------------------

local function normalizeRects(name, rects, warnings)
    local out = {}
    for i = 1, #(rects or {}) do
        local r = rects[i]
        local x1, y1, x2, y2 = tonumber(r and r[1]), tonumber(r and r[2]),
                               tonumber(r and r[3]), tonumber(r and r[4])
        if x1 and y1 and x2 and y2 then
            if x2 < x1 then x1, x2 = x2, x1 end
            if y2 < y1 then y1, y2 = y2, y1 end
            out[#out + 1] = { x1, y1, x2, y2 }
        else
            warnings[#warnings + 1] = name .. ": rect " .. i .. " is not four numbers, skipped"
        end
    end
    return out
end

-- Flatten one zone's inheritance chain into a fresh field map. Chain order:
-- "_default" first (implicit root under every zone), then each ancestor from
-- the top down, the zone's own fields last - so nearer always wins.
local function flattenChain(name, raw, warnings)
    local chain, seen, cur = {}, {}, name
    while cur do
        if seen[cur] then
            warnings[#warnings + 1] = name .. ": inheritance cycle at '" .. cur .. "', chain cut"
            break
        end
        seen[cur] = true
        local rec = raw[cur]
        if not rec then
            warnings[#warnings + 1] = name .. ": inherits unknown zone '" .. cur .. "'"
            break
        end
        table.insert(chain, 1, rec)
        cur = rec.inherits
    end
    if name ~= "_default" and raw["_default"] and not seen["_default"] then
        table.insert(chain, 1, raw["_default"])
    end

    local out = {}
    for i = 1, #chain do
        for k, v in pairs(chain[i].fields or {}) do
            local spec = specs[k]
            if spec then
                local typed = coerce(spec, v)
                if typed ~= nil then
                    out[k] = typed
                elseif v ~= "" then
                    -- "" is PhunZones-style explicit unset, silently inherited;
                    -- anything else that will not coerce is a data defect.
                    warnings[#warnings + 1] = name .. ": field '" .. k .. "' = '"
                        .. tostring(v) .. "' does not coerce to " .. spec.type .. ", inherited instead"
                end
            else
                out[k] = v
                if not warnedKeys[k] then
                    warnedKeys[k] = true
                    warn("field '" .. k .. "' has no registered consumer yet - preserved verbatim")
                end
            end
        end
    end
    return out
end

-- Returns the lifecycle events this rebuild implies (§5.1). Callers stamp the
-- revision before firing them, so listeners see the rev the events belong to.
local function rebuild(warnings)
    local prev = resolved
    resolved, index = {}, {}
    local names = {}
    for name in pairs(rawStore) do names[#names + 1] = name end
    table.sort(names)

    for i = 1, #names do
        local name = names[i]
        local rects = normalizeRects(name, rawStore[name].rects, warnings)
        local area = 0
        local bbox = nil
        for j = 1, #rects do
            local r = rects[j]
            area = area + (r[3] - r[1] + 1) * (r[4] - r[2] + 1)
            if bbox then
                if r[1] < bbox[1] then bbox[1] = r[1] end
                if r[2] < bbox[2] then bbox[2] = r[2] end
                if r[3] > bbox[3] then bbox[3] = r[3] end
                if r[4] > bbox[4] then bbox[4] = r[4] end
            else
                bbox = { r[1], r[2], r[3], r[4] }
            end
        end
        local fields = flattenChain(name, rawStore, warnings)
        local rec = {
            name     = name,
            inherits = rawStore[name].inherits,
            template = (#rects == 0),
            disabled = fields.disabled == true,
            priority = tonumber(fields.priority) or 0,
            area     = area,
            rects    = rects,
            fields   = fields,
        }
        resolved[name] = rec
        if bbox and not rec.disabled then
            index[#index + 1] = { rec = rec, bbox = bbox }
        end
    end

    return diffEvents(prev, resolved)
end

local function fireChanged()
    for i = 1, #listeners do
        local ok, err = pcall(listeners[i], Limes.revision)
        if not ok then warn("onChanged listener error: " .. tostring(err)) end
    end
end

-- Install a full raw zone set. `rev` stamps the store's revision (the sync
-- domain owns the numbering); omitted, the store self-increments (local edits).
-- Returns the warnings list - callers decide whether it is worth a log line.
function Limes.apply(rawZones, rev)
    rawStore = rawZones or {}
    local warnings = {}
    local events = rebuild(warnings)
    Limes.revision = tonumber(rev) or (Limes.revision + 1)
    -- Zone events first, so standing side effects unwind against the rebuilt
    -- store before the wholesale re-derivers run.
    fireZoneEvents(events)
    fireChanged()
    return warnings
end

-- Merge an edit delta: `changed` maps name -> raw zone, `removed` lists names.
-- Same re-resolution as apply - inheritance means one changed template can
-- reshape half the map, so partial re-resolution is a bug farm, not a win.
function Limes.applyDelta(changed, removed, rev)
    for _, name in ipairs(removed or {}) do
        rawStore[name] = nil
    end
    for name, rec in pairs(changed or {}) do
        rawStore[name] = rec
    end
    local warnings = {}
    local events = rebuild(warnings)
    Limes.revision = tonumber(rev) or (Limes.revision + 1)
    fireZoneEvents(events)
    fireChanged()
    return warnings
end

-- ---------------------------------------------------------------------------
-- Reads
-- ---------------------------------------------------------------------------

-- The lookup. Returns the resolved zone containing (x, y), or nil. Smallest
-- total area wins overlaps; priority (higher first), then name break ties.
function Limes.getLocation(x, y)
    if not x or not y then return nil end
    local best = nil
    for i = 1, #index do
        local e = index[i]
        local b = e.bbox
        if x >= b[1] and x <= b[3] and y >= b[2] and y <= b[4] then
            local rects = e.rec.rects
            for j = 1, #rects do
                local r = rects[j]
                if x >= r[1] and x <= r[3] and y >= r[2] and y <= r[4] then
                    local z = e.rec
                    if not best
                        or z.area < best.area
                        or (z.area == best.area and z.priority > best.priority)
                        or (z.area == best.area and z.priority == best.priority and z.name < best.name) then
                        best = z
                    end
                    break
                end
            end
        end
    end
    return best
end

-- Resolved record by name; templates and disabled zones included (the editor
-- and the persist layer see everything, the spatial lookup does not).
function Limes.getZone(name)
    return resolved[name]
end

-- A point guaranteed to be INSIDE the named zone, for "take me there".
--
-- NOT the bounding-box centre, which is the obvious implementation and is
-- wrong: zones are multi-rect and frequently L-shaped or split across the map
-- (Irvington is two rects, SunstarMotel is nine, HavenOutpost's two sit 5000
-- tiles apart). The centre of the box enclosing those can easily be empty
-- field, which for a teleport means arriving outside the zone you asked to
-- inspect - the exact thing that makes someone doubt the zone rather than the
-- button.
--
-- Largest rect by area, centre of that. Always inside, and it picks the part of
-- the zone worth standing in when the others are slivers. Ties break on rect
-- order so the answer is stable between calls and between machines.
--
-- Returns x, y (tile coords), or nil for a template / unknown zone.
function Limes.getZoneCenter(name)
    local z = resolved[name]
    if not z or not z.rects or #z.rects == 0 then return nil end
    local best, bestArea = nil, -1
    for i = 1, #z.rects do
        local r = z.rects[i]
        local area = (r[3] - r[1] + 1) * (r[4] - r[2] + 1)
        if area > bestArea then best, bestArea = r, area end
    end
    return math.floor((best[1] + best[3]) / 2), math.floor((best[2] + best[4]) / 2)
end

function Limes.zoneNames()
    local names = {}
    for name in pairs(resolved) do names[#names + 1] = name end
    table.sort(names)
    return names
end

-- The raw store, for the layers that own persistence and sync. Consumers have
-- no business here - read resolved records.
function Limes.raw()
    return rawStore
end

-- ---------------------------------------------------------------------------
-- Shipped seed (§8.1) - TEMPLATES ONLY, never geography.
--
-- Baked rectangles would be deleted by the first thing we tell an admin to do:
-- import replaces the store wholesale. Baked coordinates also assume a map set.
-- Geometry-less templates have neither problem - they cannot affect a zone that
-- does not name them - and they buy three things: the editor has something to
-- inherit from on day one, "_default" becomes a real editable record instead of
-- an implicit root (flattenChain already prepends raw["_default"] when it
-- exists), and the inheritance contract is demonstrated rather than described.
--
-- Only `tier` carries values here, because tier is the one scalar LMCore itself
-- registers that means anything to a satellite later. LMDirge's vocabulary
-- lands on these same templates at M1 - that is the intended growth path, not a
-- second ladder.
--
-- THE NAMES ARE THE FAMILY'S EXISTING LADDER, deliberately (corrected
-- 2026-08-04). An earlier revision shipped a namespaced Tier_Calm/Normal/
-- Harsh/Lethal set on a 0-10 scale, reasoning that a prefix avoids colliding
-- with imported PhunZones names. It avoided a collision that could not happen -
-- the seed only ever lands in an EMPTY store, and an import replaces the store
-- wholesale - while creating a worse problem: a fresh install and a migrated
-- install would speak different vocabularies for the same concept, and an
-- admin reading an inherits chain would have to know which kind of server they
-- were on. Measured against the live layer, all six rungs are in real use
-- (0:4 zones, 1:3, 2:6, 3:4, 4:7, 5:4), so six is what ships.
--
-- `tier` stays registered 0-10. The ladder occupies 0-5 and the headroom costs
-- nothing, whereas narrowing a registered range is how stored values get
-- silently eaten.
--
-- Known wart, not fixed here: Medium (2) and Intermediate (3) are English
-- synonyms on adjacent rungs, which is very likely why Intermediate was
-- deleted from the live layer in the first place. Renaming means rewriting
-- every child's `inherits`, so it waits for the M4 editor, which can do the
-- rename and the rewrite atomically.
-- ---------------------------------------------------------------------------

Limes.SEED = {
    _default     = {                        fields = { tier = 2 } },
    Very_Easy    = { inherits = "_default", fields = { tier = 0 } },
    Easy         = { inherits = "_default", fields = { tier = 1 } },
    Medium       = { inherits = "_default", fields = { tier = 2 } },
    Intermediate = { inherits = "_default", fields = { tier = 3 } },
    Hard         = { inherits = "_default", fields = { tier = 4 } },
    Very_Hard    = { inherits = "_default", fields = { tier = 5 } },
}

local function copyRaw(src)
    local out = {}
    for name, rec in pairs(src) do
        local fields = {}
        for k, v in pairs(rec.fields or {}) do fields[k] = v end
        local rects = {}
        for i, r in ipairs(rec.rects or {}) do rects[i] = { r[1], r[2], r[3], r[4] } end
        out[name] = { inherits = rec.inherits, rects = rects, fields = fields }
    end
    return out
end

-- Seed ONLY into an empty store - first boot, no .ini, no import candidate.
-- Never a merge on every boot: that would resurrect templates an admin
-- deliberately deleted, which is the tombstone trap from the other side.
-- Returns true if it seeded. The copy matters - without it the module constant
-- becomes the live store and the first edit mutates the shipped defaults.
function Limes.seedIfEmpty()
    -- pairs(), NOT next(): B42's Kahlua registers no global `next`, so
    -- `next(t) ~= nil` throws "Object tried to call nil" on a dedicated server
    -- while passing green under real Lua 5.1 in tools\run-tests. A single
    -- pairs() step is the family idiom for the same test (RDSelect, RDWire,
    -- RQSvDormant, COClient, ICClient all carry this note).
    for _ in pairs(rawStore) do return false end
    Limes.apply(copyRaw(Limes.SEED))
    return true
end

return LMCore

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
