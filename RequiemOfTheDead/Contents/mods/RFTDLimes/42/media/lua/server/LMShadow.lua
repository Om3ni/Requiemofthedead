-- LMShadow.lua - read-only divergence watch against live PhunZones (server).
--
-- THE M0 EXIT CRITERION (§11): Limes ships alongside PhunZones2, answers every
-- lookup in parallel, and this file is how we learn whether the answers agree
-- BEFORE any consumer flips. It writes evidence, changes nothing, and is the
-- DFPatch removable-file idiom: delete it and the shadow disappears with no
-- other edit. It is dead weight after M1 flips the consumers - retire it with
-- PhunZones itself.
--
-- WHAT IS COMPARED, and why not zone names: PhunZones' internal record shape
-- is its own business (§2 - ideas, never code; we do not read their store).
-- The only surface consumed is the one the family already trusts in
-- production: PhunZones.getLocation(x, y) and the fields Dirge reads off its
-- return (RQPhunZones.getEffectiveRules). So the comparison vector is
-- presence, title, difficulty-vs-tier, both sprinter risks, and the eleven
-- dirge* dials - the exact values whose agreement decides whether the M1 flip
-- is safe. Values compare as strings: PhunZones stores "25", the Limes
-- registry coerces to 25, tostring folds both to "25".
--
-- CADENCE AND BOUND: EveryTenMinutes (game time), online players' positions as
-- the sample points - the places players actually are, which is the coverage
-- that matters, accumulated over days of shadow uptime. Each distinct
-- (player, divergence) signature logs ONCE to the "limes" forensic ring
-- (LM.SHADOW_DIVERGE), deduped in memory and capped, so a systematic mismatch
-- is a handful of lines, not a firehose.

if not isServer() then return end

require "LMCore"

LMShadow = LMShadow or {}

local active = false
pcall(function()
    local mods = getActivatedMods()
    active = mods:contains("phunzones2") or mods:contains("phunzones2test")
end)
if not active then
    print("[Limes] shadow: PhunZones2 not active, nothing to diverge from")
    return LMShadow
end

-- Same-name pairs compare PhunZones field -> Limes field; difficulty crosses
-- to tier per the §9 import mapping.
local COMPARE = {
    { "title",                  "title" },
    { "difficulty",             "tier" },
    { "minSprinterRisk",        "minSprinterRisk" },
    { "maxSprinterRisk",        "maxSprinterRisk" },
    { "dirgeSpawnChance",       "dirgeSpawnChance" },
    { "dirgeScreamerWeight",    "dirgeScreamerWeight" },
    { "dirgeJuggernautWeight",  "dirgeJuggernautWeight" },
    { "dirgeEMPWeight",         "dirgeEMPWeight" },
    { "dirgeGluttonWeight",     "dirgeGluttonWeight" },
    { "dirgeScavengerWeight",   "dirgeScavengerWeight" },
    { "dirgeScreamerSpacing",   "dirgeScreamerSpacing" },
    { "dirgeJuggernautSpacing", "dirgeJuggernautSpacing" },
    { "dirgeEMPSpacing",        "dirgeEMPSpacing" },
    { "dirgeGluttonSpacing",    "dirgeGluttonSpacing" },
    { "dirgeScavengerSpacing",  "dirgeScavengerSpacing" },
}

local seen, seenCount = {}, 0
local SEEN_CAP = 500

local function fold(v)
    if v == nil or v == "" then return "" end
    return tostring(v)
end

-- Returns a comma-joined description of every differing field, or nil.
local function diff(pz, lm)
    if not pz and not lm then return nil end
    if not pz then return "presence: phun=outside limes=" .. lm.name end
    if not lm then return "presence: phun=inside limes=outside" end
    local out = nil
    for i = 1, #COMPARE do
        local pk, lk = COMPARE[i][1], COMPARE[i][2]
        local a, b = fold(pz[pk]), fold(lm.fields[lk])
        if a ~= b then
            local part = pk .. ": phun='" .. a .. "' limes='" .. b .. "'"
            out = out and (out .. ", " .. part) or part
        end
    end
    return out
end

local function sweep()
    if not PhunZones or not PhunZones.getLocation then return end
    if Limes.revision == 0 then return end          -- store not up yet
    local players = getOnlinePlayers()
    if not players then return end
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        if p then
            local x, y = math.floor(p:getX()), math.floor(p:getY())
            local okPz, pz = pcall(PhunZones.getLocation, x, y)
            if okPz then
                local d = diff(pz, Limes.getLocation(x, y))
                if d then
                    local who = "?"
                    pcall(function() who = p:getUsername() end)
                    local sig = who .. "|" .. d
                    if not seen[sig] and seenCount < SEEN_CAP then
                        seen[sig] = true
                        seenCount = seenCount + 1
                        if RDLog and RDLog.forensic then
                            RDLog.forensic("limes", "LM.SHADOW_DIVERGE", p,
                                { x = x, y = y, diff = d }, "RFTDLimes")
                        end
                        print("[Limes] shadow divergence at " .. x .. "," .. y .. ": " .. d)
                    end
                end
            end
        end
    end
end

Events.EveryTenMinutes.Add(function() pcall(sweep) end)

if Events.OnServerStarted then
    Events.OnServerStarted.Add(function()
        print("[Limes] shadow watch armed against PhunZones2 (EveryTenMinutes, "
            .. SEEN_CAP .. "-signature cap)")
    end)
end

return LMShadow

-- ---------------------------------------------------------------------------
-- Copyright Project_Omen
