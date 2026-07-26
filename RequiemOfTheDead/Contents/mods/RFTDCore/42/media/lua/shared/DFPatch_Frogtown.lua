-- DFPatch_Frogtown.lua - Dragonfly removable third-party patch (SHARED: client + server)
--
-- Fixes the Frogtown map mod's "Frogtown: Infestation" flier, which is broken
-- three ways in B42 (all verified against the game jar + Frogtown 1.21). The
-- flier itself IS correctly registered and does enter the random flier loot
-- pool; everything after the item spawns is what breaks.
--
--   1. WRONG MiscDetails KEY. Frogtown registers Flier.register(
--      "Frogtown:FrogFlier"), but the engine stamps the spawned item's media
--      id as ResourceLocation.getPath() - lowercased, namespace dropped:
--      "frogflier" (ItemCodeOnCreate.onCreateFlier -> Flier.toString()). The
--      case-sensitive lookups PrintMediaDefinitions.MiscDetails[mediaID]
--      (ISReadABook:304, ISWorldMap:472) never match Frogtown's mixed-case
--      key, so reading the flier reveals nothing and no world-map icon shows.
--      -> re-key the entry to "frogflier".
--
--   2. DEAD TRANSLATIONS. Frogtown ships Print_Media_EN.txt/Print_Text_EN.txt,
--      but B42's Translator loads .json only (the one path template in
--      zombie.core.Translator is "%s/media/lua/shared/Translate/%s/%s.json"),
--      so the flier renders raw keys / a blank page. Not fixable from Lua -
--      Dragonfly ships the keys instead, in its own Translate/EN/
--      Print_Media.json + Print_Text.json (the Translator merges every active
--      mod's files). The key names keep Frogtown's raw registration string
--      ("Print_Media_Frogtown:FrogFlier_title" etc.) because the Flier
--      constructor builds them from the unmodified register() argument.
--
--   3. ENGINE NAMESPACE ROUND-TRIP BUG (only reachable once fix 1 lands).
--      ISWorldMap:496/:537 does Flier.get(ResourceLocation.of(mediaID));
--      of("frogflier") defaults to namespace "base" -> "base:frogflier",
--      which can never match the "frogtown:frogflier" registry entry - get()
--      returns nil and val:getTranslationKey() throws on icon hover/click.
--      True for EVERY flier registered outside the "base" namespace; vanilla
--      never trips it. -> shadow the global Flier with a pass-through proxy
--      whose get() falls back to a stub carrying the correct key names.
--
-- REMOVABLE: delete this file plus Translate/EN/Print_Media.json and
-- Print_Text.json to drop the patch. If Frogtown fixes the key upstream,
-- part 1 no-ops; parts 2/3 stay correct and harmless (duplicate translation
-- keys with identical values just overwrite each other).

local applied = false

-- Raw register() names by their runtime getPath() id, so the stub can hand
-- back the exact translation keys the registration would have produced.
local RAW_NAME_BY_PATH = {
    frogflier = "Frogtown:FrogFlier",
}

local function rekeyMiscDetails()
    local details = PrintMediaDefinitions.MiscDetails
    local bad = details["Frogtown:FrogFlier"]
    if not bad then return end
    if details["frogflier"] == nil then
        details["frogflier"] = bad
    end
    details["Frogtown:FrogFlier"] = nil
    print("[Dragonfly] DFPatch_Frogtown: MiscDetails re-keyed Frogtown:FrogFlier -> frogflier")
end

local function shadowFlierGlobal()
    if isServer() then return end       -- ISWorldMap is client-side only
    if type(Flier) == "table" then return end -- already shadowed
    local java = Flier
    local function stubFor(path)
        local raw = RAW_NAME_BY_PATH[path] or path
        return {
            getTranslationKey     = function() return "Print_Media_" .. raw .. "_title" end,
            getTranslationInfoKey = function() return "Print_Media_" .. raw .. "_info" end,
            getTranslationTextKey = function() return "Print_Text_" .. raw .. "_info" end,
        }
    end
    Flier = setmetatable({
        get = function(location)
            local v = java.get(location)
            if v ~= nil then return v end
            -- Registry miss: the engine lost the namespace on the round trip.
            -- Hand back a stub so hover/click render instead of erroring; for
            -- unknown modded fliers the path-derived keys simply miss in
            -- getTextOrNull and the tooltip is skipped gracefully.
            return stubFor(location:getPath())
        end,
        register = function(...) return java.register(...) end,
    }, { __index = java }) -- anything else passes through to the Java class
    print("[Dragonfly] DFPatch_Frogtown: Flier.get namespace-miss guard installed")
end

local function apply()
    if applied then return end
    local details = PrintMediaDefinitions and PrintMediaDefinitions.MiscDetails
    if not details then return end
    if details["Frogtown:FrogFlier"] == nil and details["frogflier"] == nil then
        return -- Frogtown not present
    end
    applied = true
    rekeyMiscDetails()
    shadowFlierGlobal()
end

-- Cover every context: OnServerStarted (dedicated server) and OnGameBoot
-- (client / single-player). The `applied` guard keeps it idempotent.
Events.OnServerStarted.Add(apply)
Events.OnGameBoot.Add(apply)
