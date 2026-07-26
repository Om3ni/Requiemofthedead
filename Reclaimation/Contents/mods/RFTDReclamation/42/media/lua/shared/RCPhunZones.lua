-- RCPhunZones - soft-dependency integration with PhunZones2 (DESIGN §6; the
-- Dirge RQPhunZones pattern - reuse zone frameworks, never reinvent them).
--
-- Registers ONE boolean per-zone field, "No Vehicle Dismantle", on
-- PhunZones' field schema, so admins can protect curated areas (trader
-- camps, quest lots) from vehicle scrapping via the PhunZones zone editor.
-- The gate that READS the field is RCShared.phunZoneBlocks; callers skip it
-- for wrecks (wreck cleanup is always allowed). Loaded from shared/ so both
-- sides see the same schema. Inert if PhunZones2 is absent.

RCPhunZones = RCPhunZones or {}

local activeMods = getActivatedMods()
if activeMods:contains("phunzones2") or activeMods:contains("phunzones2test") then
    require "PhunZones/core"
    local PZ = PhunZones
    print("[RC] PhunZones2 detected, registering the No-Vehicle-Dismantle zone field")
    if PZ and PZ.fields then
        PZ.fields.reclamationNoDismantle = {
            label   = "ReclamationNoDismantle",
            type    = "boolean",
            tooltip = "ReclamationNoDismantle_Tooltip",
            default = false,
            group   = "mods",
            order   = 400, -- after Dirge's 100-304 block in the shared "mods" group
        }
    end
else
    print("[RC] PhunZones2 not detected, zone dismantle rules inactive")
end
