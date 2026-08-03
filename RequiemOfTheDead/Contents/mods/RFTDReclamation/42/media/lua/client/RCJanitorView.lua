-- RCJanitorView - the "Janitor" section of the Vehicles tab.
--
-- NOT A TAB. This registers nothing with DFRegistry; RCVehicleTab hosts it as
-- one of two views behind an inner strip. It was briefly a top-level tab
-- ("Lifecycle") and that was wrong twice over: the panel's tab bar was already
-- at nine entries across the family, and a top-level name has to explain
-- itself to someone scanning a row of unrelated words, whereas a sibling only
-- has to differ from Fleet. Hosting it also puts the policy and its
-- consequences one click apart instead of one tab apart.
--
-- IT OWNS ALMOST NO DRAWING. The dials are rendered by DFForm (Core) straight
-- off RCTuning.SCHEMA - spacing, group rules, number steppers, the "?" popout
-- and every hit test live there, shared with the deck's own settings window.
-- This file used to carry its own copy of all of that, roughly two hundred
-- lines, and the moment a second surface needed the same widget that copy
-- became the thing standing between one fix and two. What is left here is the
-- part that is genuinely about the Janitor: the transport, the status column,
-- and the retrofit controls.
--
-- WHAT IT DOES NOT OWN. "Which cars is the Janitor coming for" is the Fleet
-- view's Due scope, not a list here. Every fleet row already carries
-- RCJanitor.assess's verdict and dueIn, so a due list is that same list sorted
-- differently - and building a second, read-only copy here would mean an admin
-- could see a doomed car but not click through to inspect it.
--
-- WHY AN OVERRIDE LAYER, NOT A SANDBOX WRITE. The sandbox screen is a wall of
-- options set once, before the world existed, by someone who cannot yet know
-- what the server will feel like. These dials are the ones an admin wants to
-- move at 200 hours in, having just watched the Janitor eat a parking lot -
-- and that screen cannot be reached without stopping the server. So values
-- live in an override layer (RCTuning) resolving on top of SandboxVars, and a
-- change takes effect on the next sweep. The sandbox file is never written, so
-- Reset restores exactly what the admin originally configured.
--
-- NOTHING POLLS. The view asks when it is shown, and again after any change -
-- the server's reply IS the confirmation, so it never renders an optimistic
-- value it has not been told is true. A refused change re-renders the server's
-- truth and the control visibly snaps back.

if isServer() then return end

require "ISUI/ISPanel"
require "RCShared"
require "RCTuning"
require "DFForm"
require "DFHelp"

RCJanitorView = RCJanitorView or {}
local V = RCJanitorView

local M = RCShared.MODULE

-- Read live, never captured in a file-scope local: text size is a client
-- preference now (DFPrefs) and a font captured at load time can never change.
local function font() return DFKit.font.small or UIFont.Small end

local STATUS_W   = 214
local STATUS_MIN = 168

local T = {
    data    = nil,   -- last server payload
    survey  = nil,   -- last retrofit census
    status  = "",
    pending = false,
}

local function isAdmin()
    local p = getPlayer()
    return p and RCShared.isAdmin(p) or false
end

local function setStatus(s) T.status = s or "" end

-- ---------------------------------------------------------------------------
-- Transport
-- ---------------------------------------------------------------------------
local function requestState()
    if not isAdmin() then setStatus("Admin only."); return end
    T.pending = true
    sendClientCommand(getPlayer(), M, "lifecycle", {})
end

-- Registered at file scope, not on show: a tuningpush broadcast must be applied
-- whether or not this view happens to be open.
Events.OnServerCommand.Add(function(module, command, args)
    if module ~= M then return end

    if command == "lifecycle" then
        T.pending = false
        T.data = args
        setStatus("")

    elseif command == "tuningpush" then
        -- Authoritative override set, broadcast to every client so the
        -- decorative client-side gates agree with the server's.
        if RCTuning then RCTuning.apply(args and args.values) end

    elseif command == "novanillasurvey" then
        T.survey = args
        if args then
            setStatus(string.format(
                "Survey: %d vanilla vehicle(s) removable of %d loaded.",
                args.purge or 0, args.loaded or 0))
        end

    elseif command == "novanillapurged" then
        setStatus(string.format("Removed %d vehicle(s); %d item(s) dropped to the ground.",
            (args and args.removed) or 0, (args and args.dumped) or 0))
    end
end)

-- ---------------------------------------------------------------------------
-- Status column
-- ---------------------------------------------------------------------------
local function line(el, x, y, text, col, alpha)
    local c = col or DFKit.col.text
    el:drawText(text, x, y, c.r, c.g, c.b, alpha or 1, font())
    return y + 16
end

local function drawStatus(el)
    local r = T.statRect
    if not r then return end
    local c = DFKit.col
    local a = DFKit.alpha

    el:drawRect(r.x, r.y, r.w, r.h, a.inset, c.bg.r, c.bg.g, c.bg.b)
    el:drawRectBorder(r.x, r.y, r.w, r.h, 0.4, c.line.r, c.line.g, c.line.b)

    local x = r.x + 10
    local y = r.y + 10
    local d = T.data

    y = line(el, x, y, "TOKEN POOLS", c.textDim, 0.9)
    if d then
        y = line(el, x, y, string.format("vehicles   %d", d.tokensVehicle or 0))
        y = line(el, x, y, string.format("trailers   %d", d.tokensTrailer or 0))
    else
        y = line(el, x, y, "-", c.textDim)
    end
    y = y + 10

    -- PARKING reports the LAST SEARCH, not an index size. There is no index to
    -- describe - bulk enumeration of parking zones is unreachable from Lua in
    -- 42.20 (see RCParking's header) - so what an admin can actually act on is
    -- "did the last attempt find anywhere, and how hard did it look".
    y = line(el, x, y, "PARKING", c.textDim, 0.9)
    local pk = d and d.parking
    if pk and (pk.probes or 0) > 0 then
        if pk.found then
            y = line(el, x, y, string.format("found at %d tiles", pk.dist or 0), c.ok)
        else
            y = line(el, x, y, "no stall in range", c.warn)
        end
        y = line(el, x, y, string.format("%d probes", pk.probes or 0), c.textDim, 0.9)
    else
        y = line(el, x, y, "not searched yet", c.textDim, 0.9)
    end
    y = y + 10

    y = line(el, x, y, "LAST SWEEP", c.textDim, 0.9)
    local ls = d and d.last
    if ls and (ls.at or 0) > 0 then
        y = line(el, x, y, string.format("placed     %d", ls.placed or 0))
        y = line(el, x, y, string.format("attempts   %d", ls.tried or 0))
        if (ls.noSpot or 0) > 0 then
            y = line(el, x, y, "no legal spot", c.warn, 0.9)
        end
        if (ls.noToken or 0) > 0 then
            y = line(el, x, y, "pool empty", c.textDim, 0.9)
        end
    else
        y = line(el, x, y, "not yet run", c.textDim, 0.9)
    end
    y = y + 10

    y = line(el, x, y, "RETROFIT", c.textDim, 0.9)
    local s = T.survey
    if s then
        y = line(el, x, y, string.format("%d loaded", s.loaded or 0))
        y = line(el, x, y, string.format("%d removable", s.purge or 0),
            (s.purge or 0) > 0 and c.warn or c.textDim)
        local held = (s.claimed or 0) + (s.held or 0) + (s.occupied or 0) + (s.safehouse or 0)
        if held > 0 then
            y = line(el, x, y, string.format("%d protected", held), c.textDim, 0.9)
        end
    else
        y = line(el, x, y, "not surveyed", c.textDim, 0.9)
    end
end

-- Called by RCVehicleTab's chrome pass when this view is the active one.
function V.draw(el)
    local r = T.dialRect
    if r then
        local c, a = DFKit.col, DFKit.alpha
        el:drawRect(r.x, r.y, r.w, r.h, a.inset, c.bg.r, c.bg.g, c.bg.b)
        el:drawRectBorder(r.x, r.y, r.w, r.h, 0.4, c.line.r, c.line.g, c.line.b)
        if not T.data then
            DFKit.drawEmpty(el, r.x, r.y, r.w, r.h,
                T.pending and "loading..." or (isAdmin() and "no data - refresh" or "admin only"))
        elseif T.form then
            T.form:draw(el)
        end
    end

    drawStatus(el)

    if T.status ~= "" and T.dialRect then
        local c = DFKit.col
        el:drawText(T.status, T.dialRect.x, T.dialRect.y + T.dialRect.h + 5,
            c.textDim.r, c.textDim.g, c.textDim.b, 1, font())
    end
end

-- ---------------------------------------------------------------------------
-- Host contract: attach / layout / onShow. RCVehicleTab owns the panel and the
-- strip; this owns everything inside its own rect.
-- ---------------------------------------------------------------------------

-- Build the widgets into the host panel. Returns the flat widget list so the
-- host can toggle visibility without knowing what any of them are.
function V.attach(panel)
    T.data, T.survey = nil, nil
    setStatus("")

    -- The form is the whole dial surface. Note `set` sends to the SERVER and
    -- does not touch local state: the reply is what updates the panel, so a
    -- refused change snaps the control back instead of leaving a value on
    -- screen that the server never accepted.
    T.form = DFForm.new{
        schema  = RCTuning.SCHEMA,
        title   = "Janitor",
        enabled = isAdmin,
        get     = function(k) return T.data and T.data.values and T.data.values[k] end,
        moved   = function(k) return T.data and T.data.moved and T.data.moved[k] end,
        set     = function(k, v)
            if not isAdmin() then return end
            sendClientCommand(getPlayer(), M, "settuning", { key = k, value = v })
        end,
    }
    local widgets = T.form:attach(panel)

    local function add(w) widgets[#widgets + 1] = w end

    T.btnRefresh = DFKit.button(panel, 0, 0, 90, "Refresh", panel, requestState)
    add(T.btnRefresh)

    T.btnReset = DFKit.button(panel, 0, 0, 130, "Reset to sandbox", panel, function()
        if not isAdmin() then return end
        sendClientCommand(getPlayer(), M, "resettuning", {})
        setStatus("Overrides cleared - sandbox values restored.")
    end, "warn", { hold = true,
        tooltip = "Drop every override and go back to exactly what the server's sandbox file configures. Nothing is lost - the sandbox file was never written to." })
    add(T.btnReset)

    T.btnSurvey = DFKit.button(panel, 0, 0, 84, "Survey", panel, function()
        if not isAdmin() then return end
        sendClientCommand(getPlayer(), M, "novanillasurvey", {})
        setStatus("Surveying loaded vehicles...")
    end, "action",
    { tooltip = "Count vanilla vehicles already written into this save. Only sees vehicles in loaded chunks - a full retrofit means surveying as you travel. Reads only; removes nothing." })
    add(T.btnSurvey)

    -- Destructive, and recessive on purpose: the rarest action here and the
    -- only irreversible one. Hold-to-fire, and it refuses until a survey has
    -- actually shown the admin a number.
    T.btnPurge = DFKit.button(panel, 0, 0, 110, "Remove vanilla", panel, function()
        if not isAdmin() then return end
        if not T.survey then
            setStatus("Survey first - this removes vehicles permanently.")
            return
        end
        if (T.survey.purge or 0) <= 0 then
            setStatus("Nothing removable in the loaded area.")
            return
        end
        sendClientCommand(getPlayer(), M, "novanillapurge", { budget = 25 })
        setStatus("Removing...")
    end, "danger", { hold = true,
        tooltip = "Permanently remove loaded vanilla vehicles, up to 25 per press. Contents drop to the ground first. Claimed, occupied, safehouse and still-in-use vehicles are always spared, as are wrecks and trailers." })
    add(T.btnPurge)

    T.widgets = widgets
    return widgets
end

-- x/y/w/h is the body rect the host has left after its own strip.
function V.layout(panel, x, y, w, h)
    if not T.form then return end
    local m = DFKit.metrics

    local btnY = y + h - m.btnH
    local statW = math.max(math.min(STATUS_W, math.floor(w * 0.32)), STATUS_MIN)
    if statW > w - 300 then statW = math.max(w - 300, STATUS_MIN) end

    local dialW = w - statW - m.gap
    local bodyH = h - m.btnH - m.gap - 18   -- 18: the status line under the dials

    T.dialRect = { x = x, y = y, w = dialW, h = bodyH }
    T.statRect = { x = x + dialW + m.gap, y = y, w = statW, h = bodyH }

    T.form:layout(x, y, dialW, bodyH)

    local bx = x
    if T.btnRefresh then T.btnRefresh:setX(bx); T.btnRefresh:setY(btnY) end
    bx = bx + 90 + m.gap
    T.btnReset:setX(bx); T.btnReset:setY(btnY)

    local sx = x + dialW + m.gap
    T.btnSurvey:setX(sx); T.btnSurvey:setY(btnY)
    T.btnPurge:setX(sx + 84 + m.gap); T.btnPurge:setY(btnY)
end

-- Asked for fresh state on every show rather than caching: the dials are
-- server state and an admin returning to this view after changing something
-- elsewhere should not be reading a stale snapshot.
function V.onShow()
    requestState()
end
