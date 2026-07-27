-- RDEvents.lua - the closed chronicle event enum and namespace registry.
--
-- Chronicle streams are permanent: they are never rotated, so what is allowed
-- into them must be finite and declared. RDLog.chronicle REJECTS any event not
-- registered here - a chatty producer physically cannot write to a permanent
-- stream. Forensic streams are unconstrained (they rotate; volume is bounded
-- by the ring, not the enum).
--
-- Namespacing: every chronicle event is "<NS>.<NAME>". Core owns only "RD.*".
-- A consumer mod claims its prefix once at load:
--
--     RDEvents.registerNamespace("RC", "RFTDReclamation", {
--         VEHICLE_CLAIM = { scope = "p", req = { "claimId" } },
--         ...
--     })
--
-- and then logs with RDLog.chronicle("RC.VEHICLE_CLAIM", player, {...}).
-- Core validates the prefix and knows nothing about vehicles.
--
-- The registry is the single source of truth for the on-disk contract: the
-- server emits it as RFTD/schema.json at boot (RDSeasonServer calls
-- RDEvents.schemaTable), and external tooling reads that artifact rather than
-- carrying its own copy. Registry<->tooling drift is therefore structurally
-- impossible instead of merely tested for.
--
-- Event def fields:
--   scope : "p" (per-player stream) or "w" (world stream). Required.
--   req   : payload keys that must be present. Missing keys write anyway but
--           print a warning - losing a season record over a lint is worse than
--           a noisy console.
--   loc   : payload keys that are location-sensitive (coordinates, buildings).
--           Any future aggregate artifact must strip these mechanically.
--
-- Schema policy: ADDITIVE-ONLY within a season. New events and new optional
-- keys are free; renames and removals require a season bump.

RDEvents = RDEvents or {}

RDEvents.SCHEMA_V = 2   -- envelope version stamped on every record ("v")

-- prefix -> { mod = <mod id>, events = { NAME -> def } }
--
-- Parked on the global, not a bare `local ... = {}`, so a second execution of
-- this file cannot silently empty it. Satellites now `require "RDEvents"`
-- before claiming a namespace (the client's alphabetical shared-dir walk
-- otherwise runs them first); if the walk ever re-ran this file afterwards, a
-- fresh table would drop RC.*/RQ.* and RDLog would start REJECTING those
-- events as unregistered - a silent hole in the chronicle, which is exactly
-- the failure this season cannot have.
RDEvents._namespaces = RDEvents._namespaces or {}
local namespaces = RDEvents._namespaces

function RDEvents.registerNamespace(prefix, modId, events)
    prefix = tostring(prefix)
    if namespaces[prefix] and namespaces[prefix].mod ~= tostring(modId) then
        print("[RFTDCore] RDEvents: prefix '" .. prefix .. "' already owned by "
            .. namespaces[prefix].mod .. "; ignoring claim by " .. tostring(modId))
        return false
    end
    local ns = namespaces[prefix] or { mod = tostring(modId), events = {} }
    for name, def in pairs(events or {}) do
        if type(def) == "table" and (def.scope == "p" or def.scope == "w") then
            ns.events[tostring(name)] = def
        else
            print("[RFTDCore] RDEvents: bad def for " .. prefix .. "." .. tostring(name)
                .. " (scope must be 'p' or 'w'); skipped")
        end
    end
    namespaces[prefix] = ns
    pcall(function()
        if RDSeasonServer then RDSeasonServer.markSchemaDirty() end
    end)
    return true
end

-- "NS.NAME" -> def, owning mod id. nil when unregistered.
function RDEvents.get(evt)
    local prefix, name = tostring(evt):match("^(%w+)%.(.+)$")
    if not prefix then return nil end
    local ns = namespaces[prefix]
    if not ns then return nil end
    local def = ns.events[name]
    if not def then return nil end
    return def, ns.mod
end

-- Plain-table schema for RFTD/schema.json (encoded by RDJson at emit time).
function RDEvents.schemaTable()
    local out = {
        v = RDEvents.SCHEMA_V,
        envelope = { "v", "t", "d", "s", "e", "m", "u", "l", "x" },
        namespaces = {},
    }
    for prefix, ns in pairs(namespaces) do
        local events = {}
        for name, def in pairs(ns.events) do
            events[name] = {
                scope = def.scope,
                req   = def.req or RDJson.EMPTY_ARR,
                loc   = def.loc or RDJson.EMPTY_ARR,
            }
        end
        out.namespaces[prefix] = { mod = ns.mod, events = events }
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Core's own events. RD.* is the only namespace Core owns.
-- ---------------------------------------------------------------------------

RDEvents.registerNamespace("RD", "RFTDCore", {
    -- life-cycle (per player)
    SPAWN        = { scope = "p", req = { "x", "y", "z", "hours" }, loc = { "x", "y", "z", "house" } },
    LOGIN        = { scope = "p", req = { "hours" }, loc = { "x", "y", "z" } },
    DEATH        = { scope = "p", req = { "x", "y", "z", "hours" }, loc = { "x", "y", "z" } },
    SAMPLE       = { scope = "p", req = { "hours" } },
    HOME_SET     = { scope = "p", req = { "x", "y" }, loc = { "x", "y", "w", "h", "title" } },
    HOME_CHANGE  = { scope = "p", req = { "x", "y" }, loc = { "x", "y", "w", "h", "title" } },
    HELLO        = { scope = "p", req = { "mods" } },
    -- Season bookkeeping (world stream). SEASON_BEGIN is written once, the
    -- first time anything is recorded into a season folder. There is no
    -- SEASON_END: seasons are renamed by hand now, so no moment exists that the
    -- server could recognise as one ending.
    SEASON_BEGIN = { scope = "w", req = { "season" } },
    -- synthetic records emitted by the admin selftest; never from real play
    TEST         = { scope = "p", req = {} },
})

return RDEvents
