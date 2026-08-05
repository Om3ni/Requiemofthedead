-- SPDX-License-Identifier: GPL-3.0-or-later
-- RCTuning - the dial schema for the Lifecycle tab (client + server).
--
-- ONE SCHEMA, both sides. The panel renders from this table and the server
-- VALIDATES against the same table, so a slider's range and the server's
-- accepted range cannot drift apart. That is the same UX/enforcement split the
-- claim system uses: the client's copy is a convenience, the server's is the
-- law, and they are the same declaration so the law is never a surprise.
--
-- WHY AN OVERLAY AND NOT A SANDBOX WRITE. SandboxVars is the admin's stated
-- intent, set before the world existed, and the server's sandbox file lives
-- outside anything Lua may write to anyway. So a change here is stored as an
-- OVERRIDE in global ModData - save-scoped, server-authoritative, flushed with
-- the rest of the registry - and RCShared.cfg() resolves override-then-sandbox.
-- Clearing an override restores the sandbox value exactly, which means the
-- panel can never permanently lose the admin's original configuration.
--
-- LIVE vs RESTART. Most dials are read through cfg() at the moment they are
-- used, so an override takes effect on the next sweep. A few are not, and the
-- panel must say so rather than presenting a slider that silently lies:
--
--   NoVanillaVehicles is the one real case. Layer 1 strips the zone
--   distribution at OnLoadedTileDefinitions, and VehicleType.init() SNAPSHOTS
--   that table on the first spawn request of the session (VehicleType.java:147).
--   After the snapshot the table is decorative - the engine is working from
--   its own copy - so toggling this mid-session changes nothing whatsoever
--   until the world reloads. Marked restart, and the tab renders it as such.
--
-- Everything else here resolves per-call and is genuinely live.

RCShared = RCShared or {}
require "RCShared"

RCTuning = RCTuning or {}

RCTuning.MODDATA = "RC_Tuning"

-- HELP TEXT IS THE SANDBOX TOOLTIP, not a second description. Every dial here
-- already has a written explanation in Translate/EN/Sandbox.json, shown on the
-- sandbox screen; the "?" popout reads that SAME string. Two copies would
-- drift the moment behaviour changed, and the one an admin happened to read
-- would decide whether they were misled. Resolved at load: a missing key makes
-- getText return the key itself, which is a visible failure rather than a
-- silent blank.
local function tip(key)
    return getText("Sandbox_RC_" .. key .. "_tooltip")
end

-- kind: "bool" | "int" | "enum"
-- key:  the SandboxVars option name, which is also the override key
-- live: false means the value only takes effect after a restart
-- help: the ? popout body (see tip() above)
RCTuning.SCHEMA = {
    { group = "Reclamation" },
    { key = "JanitorEnabled",       kind = "bool", live = true,
      label = "Reclaim abandoned vehicles",
      help = tip("JanitorEnabled") },
    { key = "JanitorAbandonDays",   kind = "int",  live = true, min = 0, max = 365, step = 1,
      label = "Abandonment window", unit = "real days", zero = "off",
      help = tip("JanitorAbandonDays") },
    { key = "JanitorFeedsBudget",   kind = "int",  live = true, min = 1, max = 50, step = 1,
      label = "Max reclaims per sweep",
      help = tip("JanitorFeedsBudget") },
    { key = "ClaimInactivityDays",  kind = "int",  live = true, min = 0, max = 365, step = 1,
      label = "Claim inactivity expiry", unit = "real days", zero = "never",
      help = tip("ClaimInactivityDays") },

    { group = "Replacement" },
    { key = "RespawnEnabled",       kind = "bool", live = true,
      label = "Replacement lifecycle",
      help = tip("RespawnEnabled") },
    { key = "RespawnPerSweep",      kind = "int",  live = true, min = 0, max = 20, step = 1,
      label = "Replacements per hour", zero = "paused",
      help = tip("RespawnPerSweep") },
    { key = "RespawnOnDestruction", kind = "bool", live = true,
      label = "Destroyed vehicles mint tokens",
      help = tip("RespawnOnDestruction") },
    { key = "RespawnMinDistance",   kind = "int",  live = true, min = 0, max = 400, step = 5,
      label = "Minimum distance", unit = "tiles",
      help = tip("RespawnMinDistance") },
    { key = "RespawnMaxDistance",   kind = "int",  live = true, min = 20, max = 1000, step = 10,
      label = "Search ceiling", unit = "tiles",
      help = tip("RespawnMaxDistance") },
    { key = "RespawnCondition",     kind = "enum", live = true, numValues = 4,
      label = "Replacement condition",
      values = { "Random", "Perfect", "Average", "Poor" },
      help = tip("RespawnCondition") },

    { group = "Vanilla suppression" },
    { key = "RespawnModdedOnly",    kind = "bool", live = true,
      label = "Lifecycle places modded only",
      help = tip("RespawnModdedOnly") },
    { key = "NoVanillaStoryVehicles", kind = "bool", live = true,
      label = "Story vehicles spawn burnt",
      help = tip("NoVanillaStoryVehicles") },
    { key = "NoVanillaVehicles",    kind = "bool", live = false,
      label = "Suppress vanilla map spawns",
      note = "Applies on world reload - the engine snapshots the spawn table once per session",
      help = tip("NoVanillaVehicles") },
    -- LIVE, unlike its neighbour above: this one is read per vehicle as chunks
    -- stream, so switching it takes effect on the next chunk rather than the
    -- next world load. It converts as you travel, and stops the moment it is
    -- turned off.
    { key = "NoVanillaRetrofit",    kind = "bool", live = true,
      label = "Convert saved vanilla cars",
      note = "Rewrites cars already in the save, in place - skips any holding items",
      help = tip("NoVanillaRetrofit") },
}

-- Index the schema by key, skipping group headers.
local byKey
function RCTuning.field(key)
    if not byKey then
        byKey = {}
        for i = 1, #RCTuning.SCHEMA do
            local f = RCTuning.SCHEMA[i]
            if f.key then byKey[f.key] = f end
        end
    end
    return byKey[key]
end

-- Validate and normalise one value against the schema. Returns the coerced
-- value, or nil plus a reason. THE SERVER'S GATE - a client can send anything,
-- so an unknown key or an out-of-range number is refused here rather than
-- written into the override table and read back forever after.
function RCTuning.coerce(key, value)
    local f = RCTuning.field(key)
    if not f then return nil, "unknown" end

    if f.kind == "bool" then
        if type(value) ~= "boolean" then return nil, "type" end
        return value
    end

    local n = tonumber(value)
    if not n then return nil, "type" end
    n = math.floor(n)

    if f.kind == "enum" then
        if n < 1 or n > (f.numValues or 1) then return nil, "range" end
        return n
    end

    -- int: clamped rather than refused. A slider that has been dragged to its
    -- own maximum should not error just because the schema moved under it in a
    -- version bump; clamping is the forgiving direction and still bounded.
    if f.min and n < f.min then n = f.min end
    if f.max and n > f.max then n = f.max end
    return n
end

-- ---------------------------------------------------------------------------
-- Persistence (server only). Guarded rather than split into its own file: the
-- schema and its storage are one concern, and the client half of this file is
-- purely the schema plus coerce().
-- ---------------------------------------------------------------------------

function RCTuning.load()
    if not isServer() then return RCShared.getOverrides() end
    local t = ModData.getOrCreate(RCTuning.MODDATA)
    t.values = t.values or {}
    return t.values
end

-- Apply the stored overrides to this side's cfg. Called on boot (server) and
-- on every push (client).
function RCTuning.apply(values)
    RCShared.setOverrides(values or {})
    -- The roster is cached against the modded-only flag, so a change to it
    -- must drop the cache or the next placement uses the previous answer.
    if RCNoVanilla and RCNoVanilla.clearRoster then RCNoVanilla.clearRoster() end
end

-- Write one override. Server only. Returns the coerced value or nil, reason.
function RCTuning.set(key, value)
    if not isServer() then return nil, "notserver" end
    local coerced, reason = RCTuning.coerce(key, value)
    if coerced == nil then return nil, reason end
    local values = RCTuning.load()
    values[key] = coerced
    RCTuning.apply(values)
    return coerced
end

-- Drop every override, restoring the sandbox configuration exactly.
function RCTuning.reset()
    if not isServer() then return end
    local t = ModData.getOrCreate(RCTuning.MODDATA)
    t.values = {}
    RCTuning.apply(t.values)
end

-- The values the panel should display: the override if there is one, otherwise
-- whatever SandboxVars resolved to. Returned as a flat map plus an `overridden`
-- set, so the tab can mark which dials have been moved away from the sandbox.
function RCTuning.snapshot()
    local sv = SandboxVars and SandboxVars.RFTDReclamation or {}
    local overrides = isServer() and RCTuning.load() or RCShared.getOverrides()
    local out, moved = {}, {}
    for i = 1, #RCTuning.SCHEMA do
        local f = RCTuning.SCHEMA[i]
        if f.key then
            local v = overrides[f.key]
            if v ~= nil then
                moved[f.key] = true
            else
                v = sv[f.key]
            end
            -- Bake the schema default in so the panel never renders a blank
            -- control for an option the sandbox file predates.
            if v == nil then
                if f.kind == "bool" then v = true
                elseif f.kind == "enum" then v = 1
                else v = f.min or 0 end
            end
            out[f.key] = v
        end
    end
    return out, moved
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
