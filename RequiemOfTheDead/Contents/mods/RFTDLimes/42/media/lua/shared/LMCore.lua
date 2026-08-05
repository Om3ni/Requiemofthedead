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
        -- Presentation, carried but never interpreted here (§11.3). The Details
        -- panel groups registered fields by owner and renders them, and it can
        -- only do that if the registrant gets to say what the dial IS - a name
        -- an admin recognises, what it does, and which control it deserves. A
        -- registry that stores only type and range forces every consumer to
        -- publish a second, parallel description somewhere else, and the two
        -- then disagree. Absent `ui`, the type decides.
        label = spec.label, help = spec.help, ui = spec.ui, group = spec.group,
        values = spec.values, step = spec.step, unit = spec.unit, zero = spec.zero,
        order = tonumber(spec.order) or 0,
    }
    return true
end

function Limes.fields.spec(name)
    return specs[name]
end

-- Sorted view for the editor / form panel to render from. `owner` filters to one
-- registrant, which is what the Details panel's per-mod pane is.
function Limes.fields.list(owner)
    local names = {}
    for n, s in pairs(specs) do
        if not owner or s.owner == owner then names[#names + 1] = n end
    end
    -- Within one owner the registrant's `order` leads, so a mod can put its
    -- headline dial above its footnotes; name breaks ties so the panel never
    -- reshuffles between frames.
    table.sort(names, function(a, b)
        local sa, sb = specs[a], specs[b]
        if sa.order ~= sb.order then return sa.order < sb.order end
        return a < b
    end)
    local out = {}
    for i = 1, #names do
        local s = specs[names[i]]
        out[i] = { name = names[i], owner = s.owner, type = s.type, side = s.side,
                   default = s.default, min = s.min, max = s.max,
                   label = s.label, help = s.help, ui = s.ui, group = s.group,
                   values = s.values, step = s.step, unit = s.unit, zero = s.zero,
                   order = s.order }
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Mod registry - who owns fields, and what to call them (§11.3)
--
-- Limes is a surface other mods bind to: Dirge registers its weights and
-- spacings, Reclamation its dismantle flag, and a third-party mod whatever it
-- likes. `owner` on a field spec has carried that relationship since M0, but an
-- owner id is a file prefix, not a name an admin should have to recognise.
-- This is the display half, and it is DELIBERATELY OPTIONAL: a mod that never
-- calls register still shows up in the Details panel under its raw id, because
-- losing a mod's dials from the UI is a worse failure than an ugly heading.
-- ---------------------------------------------------------------------------

Limes.mods = Limes.mods or {}
local modInfo = {}

-- spec = { label = "Dirge", description = "...", order = 10 }
function Limes.mods.register(id, spec)
    id = tostring(id or "")
    if id == "" then return false end
    spec = spec or {}
    modInfo[id] = {
        id    = id,
        label = tostring(spec.label or id),
        description = spec.description and tostring(spec.description) or nil,
        order = tonumber(spec.order) or 100,
    }
    return true
end

function Limes.mods.info(id)
    return modInfo[id]
end

-- Every mod that owns at least one field, registered or not, with its field
-- count. Ordered by declared order then label, so the list is stable.
function Limes.mods.list()
    local seen = {}
    for _, s in pairs(specs) do
        seen[s.owner] = (seen[s.owner] or 0) + 1
    end
    local out = {}
    for id, n in pairs(seen) do
        local info = modInfo[id]
        out[#out + 1] = {
            id = id, count = n,
            label = info and info.label or id,
            description = info and info.description or nil,
            order = info and info.order or 100,
            registered = info ~= nil,
        }
    end
    table.sort(out, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        return a.label < b.label
    end)
    return out
end

-- Field read with the registry default applied. `zone` may be nil (not in any
-- zone) - returns the default, so call sites need no nil-dance.
function Limes.fields.get(zone, name)
    local v = zone and zone.fields and zone.fields[name]
    if v ~= nil then return v end
    -- NOT `s and s.default or nil`. `disabled` and `noannounce` are registered
    -- with a default of FALSE, and that idiom turns a false default into nil -
    -- so a caller distinguishing "unset" from "set to false", or comparing
    -- `== false`, gets the wrong answer for exactly the two boolean fields
    -- LMCore ships. Both are falsey, which is why it went unnoticed.
    local s = specs[name]
    if s then return s.default end
    return nil
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
Limes.mods.register("LMCore", { label = "Zone basics", order = 0,
    description = "The fields every zone has, whatever else is installed." })

Limes.fields.register("LMCore", "tier",       { type = "number",  default = 0,     side = "both", min = 0, max = 10,
    order = 1, group = "Zone", label = "Difficulty tier", unit = "",
    help = "The one number other modules read to decide how hard this zone is."
        .. " The shipped ladder runs 0 (Very Easy) to 5 (Very Hard); 6-10 are"
        .. " headroom. A zone drawn inside another starts from its parent's tier"
        .. " and overrides it only if you set one here." })
Limes.fields.register("LMCore", "priority",   { type = "number",  default = 0,     side = "both",
    order = 2, group = "Zone", label = "Overlap priority",
    help = "Breaks a tie when two zones of the SAME total area cover a tile."
        .. " Smaller area already wins, so this only matters for exact ties." })
Limes.fields.register("LMCore", "disabled",   { type = "boolean", default = false, side = "both",
    order = 3, group = "Zone", label = "Disabled",
    help = "Keeps the zone and its geometry but stops it answering lookups." })
Limes.fields.register("LMCore", "noannounce", { type = "boolean", default = false, side = "client",
    order = 4, group = "Announce", label = "No entry announce",
    help = "Suppress the on-screen title when a player walks in." })
Limes.fields.register("LMCore", "title",      { type = "string",  default = "",    side = "client",
    order = 5, group = "Announce", label = "Announce title" })
Limes.fields.register("LMCore", "subtitle",   { type = "string",  default = "",    side = "client",
    order = 6, group = "Announce", label = "Announce subtitle" })
Limes.fields.register("LMCore", "order",      { type = "number",  default = 0,     side = "client",
    order = 7, group = "Announce", label = "Display order" })

-- ---------------------------------------------------------------------------
-- THE ZONE'S OWN POLICY VOCABULARY - restrictions, zombies, loot, sprinters.
--
-- These are declared HERE, by LMCore, and that is deliberate. They are "the
-- policies that are true for a zone absent any other mod" (§11.3): the store has
-- carried them since the import, the .ini shows them, and until now the editor
-- was the only thing in the suite that could not see them - because
-- LMFieldForm renders REGISTERED fields and nothing had registered these.
-- Twelve keys sitting in the file, invisible in the panel, is the worst of both.
--
-- Declaring is not enforcing. LMRestrict (M4), LMZeds (M4), LMStats (M2) and
-- LMLoot (M3) will CONSUME these; they do not own them, and first-claim-wins in
-- the registry keeps it that way. Where nothing is enforcing yet the help text
-- says so outright rather than letting a dial imply an effect it does not have.
--
-- side = "both" throughout except lewtkey: restrictions gate client menus AND
-- server actions, so both halves need them. Loot is read only where containers
-- are filled, which is the server.
-- ---------------------------------------------------------------------------

local NOT_YET = "  NOTE: no module is enforcing this yet - the value is stored,"
             .. " replicated and preserved, but nothing reads it."

local RESTRICTIONS = {
    { "nobuilding",    "No building",        "Blocks the build menu inside this zone." },
    { "nodestruction", "No destruction",     "Blocks sledging and structural damage." },
    { "nopickup",      "No pickup",          "Movable furniture cannot be picked up." },
    { "noplacing",     "No placing",         "Movable furniture cannot be put down." },
    { "noscrap",       "No scrapping",       "Blocks dismantling for materials." },
    { "nosafehouse",   "No safehouse claim", "The zone cannot be claimed as a safehouse." },
    { "nofire",        "No fire",            "Suppresses ignition and fire spread." },
    { "noplayers",     "No player entry",    "Players are turned back at the boundary." },
}
for i, r in ipairs(RESTRICTIONS) do
    Limes.fields.register("LMCore", r[1], { type = "boolean", default = false, side = "both",
        order = 10 + i, group = "Restrictions", label = r[2], help = r[3] .. NOT_YET })
end

Limes.fields.register("LMCore", "zeds", { type = "string", default = "", side = "both",
    order = 30, group = "Zombies", label = "Zombie handling",
    help = "'remove' clears zombies standing in the zone; 'none' stops them spawning."
        .. " Blank leaves the zone alone." .. NOT_YET })
Limes.fields.register("LMCore", "minSprinterRisk", { type = "number", default = 0, side = "both",
    min = 0, max = 100, order = 31, group = "Zombies", label = "Sprinter risk (min)",
    help = "Lower bound of the per-zone sprinter chance band." .. NOT_YET })
Limes.fields.register("LMCore", "maxSprinterRisk", { type = "number", default = 0, side = "both",
    min = 0, max = 100, order = 32, group = "Zombies", label = "Sprinter risk (max)",
    help = "Upper bound of the per-zone sprinter chance band." .. NOT_YET })

-- side = "both" for the same reason as the dirge vocabulary: the editor has
-- to show it to let anyone set it. Genuinely large or secret payloads - the
-- loot TABLES themselves, when M3 brings them - stay server-only.
Limes.fields.register("LMCore", "lewtkey", { type = "string", default = "", side = "both",
    order = 40, group = "Loot", label = "Loot table key",
    help = "Names the loot profile applied to containers in this zone." .. NOT_YET })

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
