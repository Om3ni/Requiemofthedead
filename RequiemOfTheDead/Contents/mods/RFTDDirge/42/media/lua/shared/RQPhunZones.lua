-- RQPhunZones - Soft-dependency integration with PhunZones2.
--
-- Registers per-zone fields on PhunZones' field schema so admins can
-- override Dirge's global spawn rules on a per-zone basis via the
-- PhunZones2 zone editor UI. Also exposes a helper that merges those
-- overrides onto an RQConfig snapshot.
--
-- Loaded from shared/ so the registration runs on BOTH the dedicated
-- server (where svCheckZombie lives) AND the SP client (where
-- checkZombie lives). Mirrors PhunSprinters2's integration pattern.
--
-- Fields registered:
--   Legacy persisted fields stay in the built-in "mods" group at their
--   original orders so existing saved PhunZones data does not get remapped.
--   dirgeSpawnChance      (0-100 override for global SpawnChance)
--   dirgeScreamerWeight   (0-100 override for Screamer weight)
--   dirgeJuggernautWeight (0-100)
--   dirgeEMPWeight        (0-100)
--   dirgeGluttonWeight    (0-100)
--   dirgeScavengerWeight  (0-100)
--   New spacing fields live under the "dirge" group header so they do not
--   disturb the legacy table layout already persisted in saves.
--   dirgeScreamerSpacing   (0-300 override for Screamer spacing)
--   dirgeJuggernautSpacing (0-300)
--   dirgeEMPSpacing        (0-300)
--   dirgeGluttonSpacing    (0-300)
--   dirgeScavengerSpacing  (0-300)
--   Zone spacing intentionally allows up to 300 -- twice the sandbox
--   slider's 150 cap -- because production zones were already tuned with
--   160/200 values that the old 150 clamp silently crushed.
--
-- Zone overrides ALWAYS win over sandbox defaults when set. Blank
-- fields inherit from the cached RQConfig snapshot (which comes from
-- sandbox-options.txt).

RQPhunZones = RQPhunZones or {}

local activeMods = getActivatedMods()
if (activeMods:contains("phunzones2") or activeMods:contains("phunzones2test")) then
    require "PhunZones/core"
    local PZ = PhunZones
    print("[Dirge]: PhunZones2 detected, registering zone fields for Dirge")
    if PZ and PZ.fields then
        local function field(labelKey, order)
            return {
                label   = "Dirge" .. labelKey,
                type    = "string",
                tooltip = "Dirge" .. labelKey .. "_Tooltip",
                default = "",
                group   = "mods",
                order   = order,
            }
        end

        PZ.fields.dirgeSpawnChance       = field("SpawnChance",      100)
        PZ.fields.dirgeScreamerWeight    = field("ScreamerWeight",   200)
        PZ.fields.dirgeJuggernautWeight  = field("JuggernautWeight", 201)
        PZ.fields.dirgeEMPWeight         = field("EMPWeight",        202)
        PZ.fields.dirgeGluttonWeight     = field("GluttonWeight",    203)
        PZ.fields.dirgeScavengerWeight   = field("ScavengerWeight",  204)
        PZ.fields.dirgeScreamerSpacing   = field("ScreamerSpacing",   300)
        PZ.fields.dirgeJuggernautSpacing = field("JuggernautSpacing", 301)
        PZ.fields.dirgeEMPSpacing        = field("EMPSpacing",        302)
        PZ.fields.dirgeGluttonSpacing    = field("GluttonSpacing",    303)
        PZ.fields.dirgeScavengerSpacing  = field("ScavengerSpacing",  304)
    end
else
    print("[Dirge]: PhunZones2 not detected, using default zone rules")
end

-- ---------------------------------------------------------------------------
-- Helper: getEffectiveRules
--
-- Returns a config table with per-zone overrides merged on top of `cfg`.
-- If PhunZones2 is not installed, or the point is not inside any zone,
-- or the containing zone defines none of the dirge* fields, returns the
-- original `cfg` reference unchanged (allocation-free fast path).
--
-- Accepts either:
--   (zombie, nil, cfg) - reads zombie:getX(), zombie:getY()
--   (x,      y,   cfg) - uses explicit tile coords (used by admin debug menu)
-- ---------------------------------------------------------------------------
function RQPhunZones.getEffectiveRules(zombieOrX, yOrNil, cfg)
    if not PhunZones or not PhunZones.getLocation then
        return cfg
    end

    local x, y
    if type(zombieOrX) == "number" then
        x, y = zombieOrX, yOrNil
    else
        local z = zombieOrX
        if not z or not z.getX then return cfg end
        x, y = z:getX(), z:getY()
    end

    local ok, zone = pcall(PhunZones.getLocation, x, y)
    if not ok or not zone then return cfg end

    -- Per-zone weight overrides
    local sc  = tonumber(zone.dirgeSpawnChance)
    local w1  = tonumber(zone.dirgeScreamerWeight)
    local w2  = tonumber(zone.dirgeJuggernautWeight)
    local w3  = tonumber(zone.dirgeEMPWeight)
    local w4  = tonumber(zone.dirgeGluttonWeight)
    local w5  = tonumber(zone.dirgeScavengerWeight)
    -- Per-zone spacing overrides (new in 0.1.3)
    local s1  = tonumber(zone.dirgeScreamerSpacing)
    local s2  = tonumber(zone.dirgeJuggernautSpacing)
    local s3  = tonumber(zone.dirgeEMPSpacing)
    local s4  = tonumber(zone.dirgeGluttonSpacing)
    local s5  = tonumber(zone.dirgeScavengerSpacing)

    -- Fast path: no overrides at all on this zone -> return cfg unchanged
    if sc == nil and w1 == nil and w2 == nil and w3 == nil and w4 == nil and w5 == nil
       and s1 == nil and s2 == nil and s3 == nil and s4 == nil and s5 == nil then
        return cfg
    end

    local clampPct     = function(v) return math.max(0, math.min(100, v)) end
    local clampSpacing = function(v) return math.max(0, math.min(300, v)) end
    local overlay = setmetatable({}, { __index = cfg })

    -- Weight overrides (percentage, 0-100)
    if sc ~= nil then overlay.spawnChance      = clampPct(sc) end
    if w1 ~= nil then overlay.screamerWeight   = clampPct(w1) end
    if w2 ~= nil then overlay.juggernautWeight = clampPct(w2) end
    if w3 ~= nil then overlay.empWeight        = clampPct(w3) end
    if w4 ~= nil then overlay.gluttonWeight    = clampPct(w4) end
    if w5 ~= nil then overlay.scavengerWeight  = clampPct(w5) end

    -- Spacing overrides (tiles, 0-300)
    if s1 ~= nil then overlay.screamerSpacing   = clampSpacing(s1) end
    if s2 ~= nil then overlay.juggernautSpacing = clampSpacing(s2) end
    if s3 ~= nil then overlay.empSpacing        = clampSpacing(s3) end
    if s4 ~= nil then overlay.gluttonSpacing    = clampSpacing(s4) end
    if s5 ~= nil then overlay.scavengerSpacing  = clampSpacing(s5) end

    return overlay
end

-- ---------------------------------------------------------------------------
-- Copyright Project_Omen
