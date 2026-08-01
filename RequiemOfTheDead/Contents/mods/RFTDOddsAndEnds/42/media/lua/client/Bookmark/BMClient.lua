-- BMClient.lua - Bookmark: a short public-domain quote on login, purely for
-- flavor. Client-only by design - there is nothing here for a server to know
-- about, so there is no server file, no RDNet token, and no sandbox option.
-- The only switch is a "Welcome Message" tick-box on the vanilla Client
-- panel, added by BMUserPanel.lua - the Client menu the family already uses
-- for player-facing toggles, NOT the vanilla ESC -> Options -> Mods screen
-- (this family does not use PZAPI.ModOptions at all). One checkbox does not
-- earn a settings window of its own. This is an intentional exception to O&E's
-- usual "own sandbox kill switch" house rule (see OEShared.lua's header): the
-- whole point is a toggle a player controls for themselves, not a server-wide
-- dial.
--
-- State is persisted via OEPrefs (a flat key=value client-prefs file, see
-- OEPrefs.lua) - the same mechanism Last Rites' LRPrefs uses for its own
-- cosmetic toggles.
--
-- Trigger is OnGameStart, not OnServerCommand: this has no server counterpart
-- to send one. Popup construction wraps the whole thing in pcall and waits
-- ~1 second of ticks before showing, matching RDSeasonNotice's defensive
-- pattern (RFTDCore/client/RDSeasonNotice.lua) - the HUD can still be settling
-- when OnGameStart first fires. Sizing builds with height=0 so
-- ISModalDialog.CalcSize computes the true wrapped height, and only THEN is the
-- box placed using its real width/height - RDSeasonNotice's own fixed box only
-- worked because its text was fixed-length; our quotes vary. Placement, opacity
-- and draggability are all deliberate and explained at the call site.

if isServer() then return end

require "Bookmark/BMQuoteLoader"
require "ISUI/ISModalDialog"

Bookmark = Bookmark or {}
local BM = Bookmark

-- ---------------------------------------------------------------------------
-- The switch. BMUserPanel.lua owns the checkbox that drives these; this file
-- owns the state so the popup logic below never reaches into the UI.
-- ---------------------------------------------------------------------------

-- DEFAULT OFF, on purpose. A popup nobody asked for, appearing the instant a
-- player spawns into a world that can kill them, is opt-IN - not opt-out. A
-- player who wants it ticks the box once and it sticks from then on.
local PREF_KEY = "oe_bookmark_enabled"

function BM.isEnabled()
    return OEPrefs.get(PREF_KEY, false) == true
end

function BM.setEnabled(on)
    OEPrefs.set(PREF_KEY, on and true or false)
end

-- ---------------------------------------------------------------------------
-- Shuffle-bag picker. Mirrors RFTDLastRites/LRDangerQuips.lua's algorithm
-- (draw-without-replacement, refill on empty, swap away from an immediate
-- repeat across the refill boundary), adapted to compare INDEX (our pool is
-- {text=,author=,work=} tables) instead of the string LRDangerQuips compares.
--
-- In-memory only, session-scoped - deliberately not persisted via
-- getPlayer():getModData(). Two reasons, in order of weight:
--   1. Player modData is networked/saved with the character in MP - writing a
--      "last quote seen" key there would be a real (if trivial) server-side
--      footprint for a feature whose whole design point is having none.
--   2. It doesn't buy anything the in-memory bag doesn't already give: the
--      requirement is "no repeat back-to-back across a session or relogs",
--      which a process-lifetime bag satisfies exactly. The only gap is across
--      a full game-client relaunch, where Lua state is gone anyway - an
--      accepted, cheap tradeoff for a fortune-cookie feature.
-- ---------------------------------------------------------------------------

local bag = {}
local lastIndex = nil

local function refill(n)
    bag = {}
    for i = 1, n do bag[i] = i end
end

local function pickIndex()
    local pool = BM.Quotes
    local n = pool and #pool or 0
    if n == 0 then return nil end
    if n == 1 then return 1 end

    if #bag == 0 then refill(n) end

    local pos = ZombRand(#bag) + 1
    local idx = bag[pos]
    bag[pos] = bag[#bag]
    bag[#bag] = nil

    if idx == lastIndex and #bag > 0 then
        local pos2 = ZombRand(#bag) + 1
        local idx2 = bag[pos2]
        bag[pos2] = idx
        idx = idx2
    end

    lastIndex = idx
    return idx
end

-- ---------------------------------------------------------------------------
-- Popup
-- ---------------------------------------------------------------------------

local function show()
    local idx = pickIndex()
    if not idx then return end
    local q = BM.Quotes[idx]

    -- Layout is the smoke test's, which is the one the owner liked: the quote in
    -- quotation marks, the wry aside on the line under it, then the straight
    -- citation last. `quip` is optional - an entry without one just loses that
    -- middle line, so a future extraction pipeline can add quote-only chunks
    -- without touching this.
    -- Skip the wrapping quote marks when the entry already opens with one: a
    -- passage quoting dialogue (the Cheshire Cat exchange) would otherwise
    -- render with a doubled " at the front.
    local text = q.text
    if text:sub(1, 1) ~= '"' then text = '"' .. text .. '"' end
    if q.quip then text = text .. "\n- " .. q.quip end
    text = text .. "\n\n" .. q.author .. ", " .. q.work

    local ok = pcall(function()
        local w = 460
        local modal = ISModalDialog:new(0, 0, w, 0, text, false)
        modal:initialise()

        -- Pinned to the right edge, deliberately NOT centred. ISModalDialog does
        -- not actually input-lock the game (no Lua anywhere calls
        -- UIManager.setModal, and addToUIManager is a plain UIManager.AddUI, so
        -- it is "modal" in name only) - but it does swallow clicks that land on
        -- it, and dead centre is where you click to move or swing. A box there
        -- the moment you spawn is a good way to get someone killed.
        local margin = 24
        modal:setX(getCore():getScreenWidth() - modal:getWidth() - margin)
        modal:setY(math.floor((getCore():getScreenHeight() - modal:getHeight()) / 2))

        -- Draggable, so it can be moved aside and read later instead of being
        -- dismissed. ISModalDialog gates its own drag handlers behind this flag
        -- and ships with it false (see its onMouseDown/onMouseMove).
        modal.moveWithMouse = true

        -- Near-transparent: it must never hide what is behind it. Text draws at
        -- full opacity regardless (prerender uses its own colour), so this only
        -- thins the backing panel and its border.
        modal.backgroundColor = { r = 0, g = 0, b = 0, a = 0.25 }
        modal.borderColor     = { r = 0.6, g = 0.6, b = 0.6, a = 0.5 }

        modal:setAlwaysOnTop(true)
        modal:addToUIManager()
    end)

    if not ok then
        print("[RFTDOddsAndEnds] Bookmark: " .. text:gsub("\n", " "))
    end
end

-- One second of ticks so the HUD has settled - see header.
local DELAY_TICKS = 60
local pending = false
local ticks = 0

Events.OnGameStart.Add(function()
    if not BM.isEnabled() then return end
    pending = true
    ticks = 0
end)

Events.OnTick.Add(function()
    if not pending then return end
    ticks = ticks + 1
    if ticks < DELAY_TICKS then return end
    pending = false
    ticks = 0
    show()
end)

-- Exposed for manual testing from the Lua console: Bookmark.debugShow()
function BM.debugShow() show() end
