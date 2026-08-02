-- LMCore.lua - the zone store, and the only door into it (both sides).
--
-- THE public surface (docs/limes-design.md §4-§5). Satellites never touch the
-- store; they call Limes.getLocation(x, y), register typed fields, and listen
-- for change callbacks. Everything else in this mod is a producer feeding this
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

-- spec: { type = "number"|"boolean"|"string", default = ?, min = ?, max = ? }
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
    specs[name] = {
        owner = owner, type = spec.type,
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
        out[i] = { name = names[i], owner = s.owner, type = s.type,
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

Limes.fields.register("LMCore", "title",      { type = "string",  default = "" })
Limes.fields.register("LMCore", "subtitle",   { type = "string",  default = "" })
Limes.fields.register("LMCore", "order",      { type = "number",  default = 0 })
Limes.fields.register("LMCore", "noannounce", { type = "boolean", default = false })
Limes.fields.register("LMCore", "disabled",   { type = "boolean", default = false })
Limes.fields.register("LMCore", "priority",   { type = "number",  default = 0 })
Limes.fields.register("LMCore", "tier",       { type = "number",  default = 0, min = 0, max = 10 })

-- ---------------------------------------------------------------------------
-- Store state
-- ---------------------------------------------------------------------------

local rawStore   = {}    -- name -> raw zone (ownership transfers to LMCore on apply)
local resolved   = {}    -- name -> resolved zone
local index      = {}    -- array of resolved zones with geometry, lookup order
local warnedKeys = {}    -- unknown field key -> true (warn once per key, not per zone)
local listeners  = {}

Limes.revision = 0

function Limes.onChanged(fn)
    listeners[#listeners + 1] = fn
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

local function rebuild(warnings)
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
    rebuild(warnings)
    Limes.revision = tonumber(rev) or (Limes.revision + 1)
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
    rebuild(warnings)
    Limes.revision = tonumber(rev) or (Limes.revision + 1)
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

return LMCore

-- ---------------------------------------------------------------------------
-- Copyright Project_Omen
