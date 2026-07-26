-- RFTDSunset.lua - end-of-life notice for the standalone RFTD Workshop items.
--
-- SHIPS IN THE FINAL RELEASE OF EACH LEGACY ITEM (source: PZMod), never in
-- the bundle. Copy this file into <mod>/42/media/lua/client/ as
-- RFTDSunset_<ModName>.lua, set the two constants below, done. It is fully
-- self-contained on purpose: the legacy items have no RFTDCore and never
-- will - zero dependencies, vanilla UI only.
--
-- Audience: STAFF ONLY (any access level above None), once per session,
-- dismissible. Players on the 11+ servers running these mods can't act on a
-- migration notice - their operators can. A server-side console line covers
-- operators who never log in with a staff account.

local MOD_NAME   = "Requiem of the Dead: <ModName>"   -- e.g. "Requiem of the Dead: Dirge"
local BUNDLE_URL = "https://steamcommunity.com/sharedfiles/filedetails/?id=<BUNDLE_ID>"  -- fill after the bundle publishes

local MESSAGE = MOD_NAME .. " has moved!\n\n"
    .. "This standalone Workshop item has been replaced by\n"
    .. "\"Requiem of the Dead: Season One\" - one Workshop item\n"
    .. "containing the whole updated RFTD mod family.\n\n"
    .. "This standalone version keeps working, but will NOT be\n"
    .. "maintained after October 1, 2026. Please migrate your\n"
    .. "server's WorkshopItems= entry to the new item.\n\n"
    .. BUNDLE_URL

-- Server side: one log line per boot so operators see it in the console
-- file even if no staff account ever logs in.
if isServer() then
    print("[RFTD SUNSET] " .. MOD_NAME .. " is superseded by 'Requiem of the Dead: Season One' "
        .. "and will not be maintained after 2026-10-01. " .. BUNDLE_URL)
    return
end

-- Client side: staff-only, once per session, after the game is actually up.
local shown = false

local function isStaff()
    local p = getPlayer()
    if not p then return false end
    -- SP/host: the "operator" is the player.
    if not isClient() then return true end
    local ok, access = pcall(function() return p:getAccessLevel() end)
    return ok and type(access) == "string" and access ~= "" and string.lower(access) ~= "none"
end

local function showSplash()
    if shown then return end
    shown = true
    if not isStaff() then return end
    local ok = pcall(function()
        local w, h = 420, 260
        local x = (getCore():getScreenWidth() - w) / 2
        local y = (getCore():getScreenHeight() - h) / 2
        local modal = ISModalDialog:new(x, y, w, h, MESSAGE, false, nil, nil)
        modal:initialise()
        modal:addToUIManager()
    end)
    if not ok then
        -- UI failed for any reason: fall back to console, never break login.
        print("[RFTD SUNSET] " .. MOD_NAME .. " superseded - see " .. BUNDLE_URL)
    end
end

Events.OnGameStart.Add(showSplash)
