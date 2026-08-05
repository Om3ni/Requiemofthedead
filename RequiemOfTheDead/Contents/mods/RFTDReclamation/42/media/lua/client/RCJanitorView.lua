-- SPDX-License-Identifier: GPL-3.0-or-later
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

-- How many placement coordinates the status column lists before summarising.
-- The burst ceiling is 25 and the column is not tall enough for that many on
-- top of everything above it; six is a legible batch and the rest is counted.
local MAX_SPOT_LINES = 6

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
    -- Cleared HERE rather than when the reply lands. Every action on this view
    -- ends with the server pushing a fresh lifecycle packet, so blanking the
    -- status on arrival wiped each action's own receipt ("Removed 3; 3 tokens
    -- banked") a frame after it appeared - the admin pressed a destructive
    -- button and was told nothing. An explicit refresh is the one moment the
    -- previous result is genuinely stale.
    setStatus("")
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
        -- A sweep we have not walked yet: park the cursor before its first
        -- entry so "Go to placement" starts at the top of the NEW batch rather
        -- than continuing to count through the last one.
        local at = args and args.last and args.last.at or 0
        if at ~= T.lastAt then
            T.lastAt  = at
            T.gotoIdx = 0
        end

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
        -- Says the tokens out loud. Removal now FUNDS replacement, and an admin
        -- who is not told that reads the pool jumping as a bug.
        setStatus(string.format(
            "Removed %d vehicle(s); %d item(s) dropped; %d replacement token(s) banked.",
            (args and args.removed) or 0, (args and args.dumped) or 0,
            (args and args.minted) or 0))

    elseif command == "nopark" then
        if args and args.ok then
            setStatus(string.format(
                "Marked \"%s\" (%dx%d at %d,%d) as no-parking - %d exclusion(s) total.",
                tostring(args.label), args.w or 0, args.h or 0,
                args.x or 0, args.y or 0, args.total or 0))
        else
            setStatus("Not marked: " .. tostring(args and args.reason or "unknown"))
        end

    elseif command == "respawnnow" then
        local placed = (args and args.placed) or 0
        if placed > 0 then
            setStatus(string.format("Placed %d vehicle(s) near players.", placed))
        else
            -- The two ways this legitimately does nothing, named - otherwise a
            -- button that reports "0" reads as broken rather than as blocked.
            setStatus("Placed nothing - the pool is empty, or no legal parking is loaded nearby.")
        end
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
            -- Said out loud: the area was too full to honour the spacing rule,
            -- so the search fell back to "clear of this sweep's own placements"
            -- to place at all. An admin reading "found" should know which of
            -- the two answers they got.
            if pk.relaxed then
                y = line(el, x, y, "crowded - spacing relaxed", c.warn, 0.9)
            end
        else
            y = line(el, x, y, "no stall in range", c.warn)
        end
        y = line(el, x, y, string.format("%d probes", pk.probes or 0), c.textDim, 0.9)
        -- Only on a failure, and only because it is usually the ANSWER there:
        -- a full car park now fails the search, and without this the admin
        -- reads "no stall in range" while looking straight at a car park.
        if not pk.found and (pk.spacing or 0) > 0 then
            y = line(el, x, y, string.format("min gap %d tiles", pk.spacing), c.textDim, 0.9)
        end
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
        -- WHERE they went. "placed 3" is a claim the admin cannot check: the
        -- cars land in loaded chunks near whoever needed one, which is usually
        -- not the person who pressed the button. Coordinates make the number
        -- falsifiable, and the Go to button walks them.
        local sp = ls.spots
        if sp and #sp > 0 then
            local cur = T.gotoIdx or 0
            for i = 1, math.min(#sp, MAX_SPOT_LINES) do
                local s = sp[i]
                y = line(el, x, y,
                    string.format("%s %d,%d", i == cur and ">" or " ", s.x or 0, s.y or 0),
                    i == cur and c.ok or c.textDim, 0.9)
            end
            -- Named, not silently dropped: a truncated list that looks complete
            -- is how an admin concludes the other placements never happened.
            if #sp > MAX_SPOT_LINES then
                y = line(el, x, y, string.format("  +%d more", #sp - MAX_SPOT_LINES),
                    c.textDim, 0.9)
            end
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
        tooltip = "Permanently remove loaded vanilla vehicles, up to 25 per press. Contents drop to the ground first. Claimed, occupied, safehouse and still-in-use vehicles are always spared, as are wrecks and trailers.\n\nEach removal banks one replacement token, so clearing the vanilla fleet pays for the modded one." })
    add(T.btnPurge)

    -- The other half of the retrofit. NOT hold-to-fire, unlike its neighbour:
    -- this is additive and reversible - the Janitor reclaims anything unwanted
    -- on its own schedule - so it does not deserve the same friction as a
    -- permanent deletion sitting next to it.
    T.btnPlace = DFKit.button(panel, 0, 0, 96, "Place now", panel, function()
        if not isAdmin() then return end
        sendClientCommand(getPlayer(), M, "respawnnow", { burst = 10 })
        setStatus("Placing...")
    end, "primary",
    { tooltip = "Spend banked replacement tokens immediately instead of waiting for the hourly sweep, up to 10 per press. Vehicles go to the players holding fewest claims first.\n\nPlacements can only land in chunks that are currently loaded, so this repopulates the area around online players - not the whole map. It never creates tokens: if the pool is empty, nothing happens." })
    add(T.btnPlace)

    -- The verification half of "Place now". Teleport is the vanilla
    -- /teleportto, sent as a chat command exactly like Longstrider's tour: it
    -- is SERVER authoritative, so it re-checks the caller's access level and
    -- streams the destination in. Moving the player locally with setX would be
    -- rubber-banded by the server on a dedicated host, which is the only place
    -- this button matters.
    T.btnGoto = DFKit.button(panel, 0, 0, 120, "Go to placement", panel, function()
        if not isAdmin() then return end
        local sp = T.data and T.data.last and T.data.last.spots
        if not sp or #sp == 0 then
            setStatus("No placements recorded - press Place now first.")
            return
        end
        local i = ((T.gotoIdx or 0) % #sp) + 1   -- cycles, so one button walks the batch
        T.gotoIdx = i
        local s = sp[i]
        -- RDTeleport (Core) is the family's one gated coordinate teleport. This
        -- button used to send the command itself behind a bare isAdmin(), which
        -- is a different and looser gate than the Capability.TeleportToCoordinates
        -- the other call sites use; routing through Core settles that at one
        -- answer.
        local ok, why = RDTeleport.toCoords(s.x, s.y, s.z)
        if not ok then setStatus(why or "Teleport refused."); return end
        setStatus(string.format("%d of %d: %s at %d,%d - placed near %s.",
            i, #sp, tostring(s.model or "?"), s.x or 0, s.y or 0, tostring(s.near or "?")))
    end, "action",
    { tooltip = "Teleport to the vehicles the last sweep placed, one press per vehicle, cycling. This is how you check that a placement is real and standing in a parking space rather than in a field.\n\nOnly the last sweep is listed. The permanent record of every placement is the RESPAWN line in the server's RFTDReclamation_Dismantle.txt." })
    add(T.btnGoto)

    -- The other half of "indoor stalls are legal": when one turns out not to
    -- be, this is how it gets recorded. Stand in the room and press once - the
    -- room's own bounds are what gets stored, so there is nothing to measure.
    T.btnNoPark = DFKit.button(panel, 0, 0, 128, "No parking here", panel, function()
        if not isAdmin() then return end
        sendClientCommand(getPlayer(), M, "noparkhere", {})
        setStatus("Marking this room...")
    end, "warn",
    { tooltip = "Record the room you are standing in as somewhere the lifecycle must never place a vehicle, and keep it excluded from now on.\n\nIndoor parking zones are allowed by default because most of them - fire station bays, showrooms, carports - are real parking. This is for the ones that are not.\n\nStand INSIDE the room, not in the car park outside it. Entries are appended to RFTDReclamation_NoPark.txt on the server and can be hand-edited or removed." })
    add(T.btnNoPark)

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

    -- Left row is LIFECYCLE operations, right column is the vanilla RETROFIT
    -- pair. "Place now" sits left rather than beside its conceptual partner
    -- because the status column cannot hold three buttons - Survey (84) and
    -- Remove vanilla (110) already fill it - and a third would have run under
    -- the dials. The split also reads correctly: Survey/Remove is a two-step
    -- sequence, and everything on the left is a single action.
    local bx = x
    if T.btnRefresh then T.btnRefresh:setX(bx); T.btnRefresh:setY(btnY) end
    bx = bx + 90 + m.gap
    T.btnReset:setX(bx); T.btnReset:setY(btnY)
    bx = bx + 130 + m.gap
    if T.btnPlace then T.btnPlace:setX(bx); T.btnPlace:setY(btnY) end
    bx = bx + 96 + m.gap
    -- Directly after its partner: place, then go and look at what you placed.
    if T.btnGoto then T.btnGoto:setX(bx); T.btnGoto:setY(btnY) end
    bx = bx + 120 + m.gap
    -- Last in the row, because it is the one you press AFTER going to look and
    -- finding the car somewhere it should not be.
    if T.btnNoPark then T.btnNoPark:setX(bx); T.btnNoPark:setY(btnY) end

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

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
