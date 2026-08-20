-- SPDX-License-Identifier: GPL-3.0-or-later
-- RCVehicleTab - the "Vehicles" tab on Dragonfly's admin panel (DESIGN §7).
--
-- THE INSPECTOR. One car at a time, in depth: what it is, what shape it is in,
-- who holds it, and how long it has left. The fleet-level view (what the
-- Janitor is about to eat, the token pools) is the Lifecycle tab's job - this
-- one answers "what am I looking at".
--
-- WHAT CHANGED AND WHY (2026-08-02). The old tab was a flat table of the cars
-- streamed to the admin's own client: seven columns, three buttons, zero
-- network. It was honest and cheap and it could not do the job. Two reasons:
--
--   * SCOPE. getCell():getVehicles() on the CLIENT is the admin's personal
--     bubble. Triage means finding the car you are NOT standing next to, and
--     that list could never contain it. The scan now runs server-side over
--     every loaded chunk (RCFleet), with the claim index as a third scope for
--     cars nobody has streamed in at all.
--   * THE VERDICT. RCJanitor has always computed abandonment in full - the
--     Presence Law, the downtime-credited clock, the PhunZone and safehouse
--     shields - and this tab referenced NONE of it, because those stamps live
--     in server-only modData that is deliberately never transmitted. So the
--     admin re-derived by eye what the server already knew exactly. Every row
--     now carries RCJanitor.assess's verdict as a 3px stripe, and the selected
--     car's full reasoning sits in the lifecycle block.
--
-- THE COST, stated plainly: this tab is no longer free. It was the only tab in
-- the family that touched no network, and that property is spent. It is spent
-- carefully - one request per Refresh, replies arrive as pages the admin can
-- read while they land, and nothing polls. See the transport section.
--
-- ACTIONS WORK ON ROWS, NOT OBJECTS. Both destructive paths resolve
-- server-side by id (VehicleCommands.remove does getVehicleById on the SERVER)
-- and teleport only needs coordinates, so both work on a car this client has
-- never streamed. That is what makes the wider scope actionable rather than
-- merely informative - a list you can see but not act on is a worse tool than
-- the bubble was.

if isServer() then return end

require "ISUI/ISPanel"
require "ISUI/ISScrollingListBox"
require "ISUI/ISButton"
require "ISUI/ISLabel"
require "ISUI/ISModalDialog"

-- Shared selection model (Core). Same click semantics as the necro and players
-- tabs, so the muscle memory transfers between tabs.
require "RDSelect"
local Select = RDSelect

-- Shared scroll primitive (Core). Same thumb, same wheel distance, same
-- track-click as the Janitor dial form - the parts grid is not its own dialect.
require "DFScroll"
require "DFViews"

RCVehicleTab = RCVehicleTab or {}
local T = RCVehicleTab

local M    = RCShared.MODULE

-- Monospace: ids and columns line up only while the face is fixed-width, so
-- this slot must never fall back to a proportional font.
--
-- NOT a constant, despite reading like one. Text size is a client preference
-- (DFPrefs) and the whole point of that preference is that it applies without
-- a restart - so a DFPrefs listener at the bottom of this file REASSIGNS these
-- two upvalues and re-lays-out. Every draw call below reads the upvalue at
-- draw time, which is what lets one listener resize the entire tab instead of
-- thirty call sites having to ask.
local FONT  = UIFont.Code
local ROW_H = 18

-- Ceiling on one bulk delete. Deliberately below RCServer's DISMANTLE_BATCH_MAX
-- so the panel never promises more than the ledger will accept, and low because
-- each target costs a separate vanilla removal packet - see deleteRows.
local BULK_MAX = 10

-- Geometry. Floors matter: the deck can be dragged small, and the failure mode
-- to avoid is a detail pane so narrow the lifecycle values overprint their keys.
-- BASE values, tuned against UIFont.Code at its default size. Nothing reads
-- these directly - recomputeMetrics() derives the live values below from them
-- and the CURRENT font, because text size is a client preference and every one
-- of these numbers is only correct at the size it was measured at.
local LIST_W_B,  LIST_MIN_B  = 248, 176
local PARTS_W_B, PARTS_MIN_B = 250, 170
local MEAT_MIN_B             = 208
local BAND_H_B               = 40
local LIST_HEAD_B            = 16

-- The diagram column does NOT scale, deliberately. Its content is the vanilla
-- mechanic-overlay art, which is 263x600 pixels whatever the font is doing;
-- widening the column for a larger font would just add empty space around a
-- fixed-size image.
local DIAG_W,  DIAG_MIN  = 292, 200

-- Live geometry, assigned by recomputeMetrics().
local LIST_W,  LIST_MIN  = LIST_W_B, LIST_MIN_B
local PARTS_W, PARTS_MIN = PARTS_W_B, PARTS_MIN_B
local MEAT_MIN           = MEAT_MIN_B
local BAND_H             = BAND_H_B
local LIST_HEAD_H        = LIST_HEAD_B

-- Row internals. GLYPH_X / VID_X / NAME_X are the three columns of a list row,
-- and they are MEASURED rather than fixed: a five-digit vehicle id at
-- CodeLarge is far wider than at Code, so a hard-coded name column is exactly
-- how ids and names ended up drawn on top of each other. Shared by the row
-- draw and the column header so the two cannot drift apart.
local GLYPH_X = 8
local VID_X   = 22
local NAME_X  = 66
local TEXT_DY = 2      -- vertical centring of row text, derived from row height

-- ---------------------------------------------------------------------------
-- Verdict vocabulary. The single place a Janitor verdict becomes a colour and
-- a sentence; RCJanitor.assess owns what the verdict IS, this owns how it
-- reads. Keys must track that function's return values exactly.
-- ---------------------------------------------------------------------------
local VERDICT = {
    claimed  = { col = "ok",      label = "HELD",     line = "claimed - the Janitor never looks at a claimed car" },
    held     = { col = "ok",      label = "HELD",     line = "past the window, but its keeper has logged in since" },
    shielded = { col = "ok",      label = "SHIELDED", line = "eligible, but it is parked inside a safehouse" },
    clock    = { col = "warn",    label = "ON CLOCK", line = "unclaimed and counting down" },
    due      = { col = "danger",  label = "DUE",      line = "past every gate - next sweep with budget takes it" },
    wreck    = { col = "textDim", label = "WRECK",    line = "wrecks are never reclaimed and mint nothing" },
    off      = { col = "textDim", label = "-",        line = "the Janitor is disabled" },
}
local function verdictOf(row)
    return VERDICT[row and row.verdict or "off"] or VERDICT.off
end

-- ---------------------------------------------------------------------------
-- Formatting
-- ---------------------------------------------------------------------------

-- Coarse duration. Deliberately never finer than minutes: these clocks are
-- measured in real days and a seconds figure would imply a precision the
-- downtime credit does not actually have.
local function fmtAgo(sec)
    if type(sec) ~= "number" then return "-" end
    local neg = sec < 0
    if neg then sec = -sec end
    local d = math.floor(sec / 86400)
    local h = math.floor((sec % 86400) / 3600)
    local m = math.floor((sec % 3600) / 60)
    local s
    if d > 0 then s = string.format("%dd %02dh", d, h)
    elseif h > 0 then s = string.format("%dh %02dm", h, m)
    else s = string.format("%dm", m) end
    return neg and ("-" .. s) or s
end

local function fmtTile(row)
    if not row or not row.x then return "-" end
    return string.format("%d, %d, %d", row.x, row.y, row.z or 0)
end

-- Live distance from the local player. Computed per frame from the row's
-- coordinates rather than sent by the server, so it stays true while the admin
-- walks instead of freezing at snapshot time.
local function distOf(row)
    local me = getPlayer()
    if not (me and row and row.x) then return nil end
    local dx, dy = me:getX() - row.x, me:getY() - row.y
    return math.floor(math.sqrt(dx * dx + dy * dy))
end

-- ---------------------------------------------------------------------------
-- Transport. Pages arrive from RCFleet and are rendered AS THEY LAND - the
-- list is useful from the first page and there is no spinner to sit behind.
--
-- The watchdog is not optional, and Necro paid for that lesson: its first
-- paged snapshot had no seq tracking and no timeout, so one dropped chunk left
-- an empty tab forever with no error. A partial fleet list is worse than that,
-- because it does not look broken - it looks like a short fleet. So a stalled
-- stream says so, out loud, and the status line stays marked partial.
-- ---------------------------------------------------------------------------
local STALL_TICKS = 300   -- ~10s at 30Hz with no new page

T.rows    = T.rows or {}
T.scope   = T.scope or "loaded"
-- Which inner view is showing is DFViews' state now, not a field here. The
-- resize hook can still reach layout() before build() has ever run, so every
-- read of T.views is guarded - a nil one falls through to the Fleet path, which
-- returns immediately on its own missing listBox.
local pending = nil       -- { seq, rows, pages, idle, capped, seen }

local function isAdmin()
    return RCShared.isAdmin(getPlayer())
end

-- Nearby scope keeps the ORIGINAL zero-network path: read the client cell
-- directly. It is the fallback when the server half is unavailable (an older
-- server, or a non-admin), and it is genuinely the right tool when the admin is
-- standing in the middle of what they want to look at.
local function forEachClientVehicle(fn)
    local cell = getCell and getCell()
    if not cell then return end
    local vs = cell:getVehicles()
    if not vs then return end
    local it = vs:iterator()
    if not it then return end
    local failed, firstErr = 0, nil
    while it:hasNext() do
        -- RETAINED, one member of an independent batch: the walk holds live
        -- refs that can stream out under it, and one car mid-removal must not
        -- cost the admin the rest of the nearby list. Counted now - a nearby
        -- list quietly short of cars reads as "it despawned", which is the
        -- same silent failure the fleet scan just had corrected.
        local v = it:next()
        if v then
            local ok, err = pcall(fn, v)
            if not ok then
                failed = failed + 1
                firstErr = firstErr or err
            end
        end
    end
    if failed > 0 then
        print(string.format(
            "[RC] nearby: %d car(s) omitted from the list (first: %s)",
            failed, tostring(firstErr)))
    end
end

-- Row reads are all field returns / null-checked chains verified in the
-- decompile (BaseVehicle getters, VehicleParts.java:125, VehicleScript.java:1917).
local function nearbyRows()
    local rows = {}
    forEachClientVehicle(function(v)
        local r = { vid = v:getId(), loaded = true, occupied = 0 }
        r.script = v:getScriptName() or "?"
        r.x, r.y, r.z = math.floor(v:getX()), math.floor(v:getY()), math.floor(v:getZ())
        r.kind = RCShared.isWreck(v) and "wreck"
            or (RCShared.isTrailer(v) and "trailer" or "car")
        local eng = v:getPartById("Engine")
        if eng then r.engine = math.floor(eng:getCondition()) end
        local script = v:getScript()
        local seats = script and script:getPassengerCount() or 0
        for s = 0, seats - 1 do
            if v:isSeatOccupied(s) then r.occupied = r.occupied + 1 end
        end
        r.owner   = RCClaim.getOwner(v)
        r.claimId = RCClaim.getClaimId(v)
        -- No verdict: the janitor stamps are server-side and this path never
        -- sees them. The stripe renders neutral, which is honest - "unknown",
        -- not "clean".
        rows[#rows + 1] = r
    end)
    return rows
end

local function sortRows(rows)
    -- The DUE scope orders by URGENCY, not proximity. The question that scope
    -- answers is "what goes next", and a car one sweep from reclamation matters
    -- whether it is twenty tiles away or two thousand - distance is exactly the
    -- wrong key there. Negative dueIn (already overdue) sorts to the top, which
    -- is correct: those are the ones the next budgeted sweep actually takes.
    --
    -- Sorted HERE rather than on the server because a progressive paged scan
    -- cannot sort - rows leave in the order they were found, across many pages
    -- - and the client is where the whole set finally exists at once.
    if T.scope == "due" then
        table.sort(rows, function(a, b)
            local da = a.dueIn or 999999999
            local db = b.dueIn or 999999999
            if da ~= db then return da < db end
            return (a.script or "") < (b.script or "")
        end)
        return rows
    end
    table.sort(rows, function(a, b)
        local da = distOf(a) or 999999
        local db = distOf(b) or 999999
        if da ~= db then return da < db end
        return (a.script or "") < (b.script or "")
    end)
    return rows
end

-- THE INVISIBLE-LIST BUG (2026-08-03) was found here: the list stayed fully
-- populated and clickable while drawing nothing, and only a relog recovered it.
-- The cause is vanilla's clear()/addItem scroll-height accounting and it was
-- latent in every list in the suite, so the fix lives in DFKit.refillList -
-- see that function's header. This tab refills progressively, once per page.
local function rebuildList()
    if not T.listBox then return end
    DFKit.refillList(T.listBox, function(box)
        for _, r in ipairs(T.rows) do box:addItem("", r) end
    end)
end

local function orderedVids(list)
    local out = {}
    if not list or not list.items then return out end
    for _, it in ipairs(list.items) do
        -- unloaded registry rows have no vid; they are viewable, not selectable
        if it.item and it.item.vid then out[#out + 1] = it.item.vid end
    end
    return out
end

local function setStatus(txt)
    if T.status then T.status:setName(txt) end
end

function T.refresh()
    if T.scope == "nearby" or not isAdmin() then
        pending = nil
        T.rows = sortRows(nearbyRows())
        T.partial = false
        rebuildList()
        if T.sel then T.sel:prune(orderedVids(T.listBox)) end
        T.syncSelectionUI()
        setStatus(string.format("%d loaded nearby - no lifecycle data on this scope.", #T.rows))
        return
    end
    pending = nil
    T.rows, T.partial = {}, false
    rebuildList()
    setStatus("Requesting fleet...")
    sendClientCommand(getPlayer(), M, "fleet", { scope = T.scope })
end

local function onFleetPage(args)
    if not args then return end
    -- A page from a superseded scan. Dropping it is what stops a Refresh spam
    -- from interleaving two snapshots into one list.
    if pending and args.seq ~= pending.seq then return end
    if not pending then
        pending = { seq = args.seq, rows = {}, pages = 0, idle = 0 }
    end
    pending.idle = 0
    pending.pages = pending.pages + 1
    for _, r in ipairs(args.rows or {}) do pending.rows[#pending.rows + 1] = r end
    pending.capped = args.capped
    pending.seen   = args.seen

    -- Render progressively: the admin reads while it fills.
    T.rows = sortRows(pending.rows)
    rebuildList()
    if T.sel then T.sel:prune(orderedVids(T.listBox)) end
    T.syncSelectionUI()

    if args.done then
        local msg = string.format("%d vehicle(s) - %s scope", #T.rows, tostring(T.scope))
        if args.capped then
            msg = msg .. string.format("  CAPPED at %d of %d seen - narrow the scope",
                #T.rows, tonumber(args.seen) or 0)
        end
        setStatus(msg)
        pending = nil
        T.partial = false
    else
        setStatus(string.format("%d vehicle(s) and counting...", #T.rows))
    end
end

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= M then return end
    if command == "Fleet" then onFleetPage(args) end
end)

-- Stall watchdog. Says so out loud AND leaves the list marked partial, because
-- a half-filled fleet list does not look broken - it looks like a short fleet.
Events.OnTick.Add(function()
    local p = pending
    if not p then return end
    p.idle = p.idle + 1
    if p.idle < STALL_TICKS then return end
    pending = nil
    T.partial = true
    setStatus(string.format("PARTIAL - stream stalled after %d row(s). Refresh to retry.", #T.rows))
    if DFFeedback then
        DFFeedback.bad(string.format(
            "Fleet snapshot incomplete: %d row(s) arrived before the stream stalled.", #T.rows))
    end
end)

-- ---------------------------------------------------------------------------
-- Selection helpers
-- ---------------------------------------------------------------------------

local function selectedRow()
    if not T.listBox then return nil end
    local it = T.listBox.items[T.listBox.selected]
    return it and it.item or nil
end

local function selectedRows()
    local out = {}
    if not (T.sel and T.listBox) then return out end
    local want = {}
    for _, vid in ipairs(T.sel:list(orderedVids(T.listBox))) do want[vid] = true end
    for _, it in ipairs(T.listBox.items or {}) do
        if it.item and it.item.vid and want[it.item.vid] then out[#out + 1] = it.item end
    end
    return out
end

function T.syncSelectionUI()
    local n = #selectedRows()
    if T.btnDelete then
        T.btnDelete:setTitle(n > 1 and ("Delete (" .. n .. ")") or "Delete")
    end
    return n
end

function T.onSelectionChanged()
    -- New car, top of its part list. DFScroll's own clamp would catch the
    -- dangerous case, but carrying an offset across a selection is disorienting
    -- when the next car happens to be long enough to keep it.
    if T.partsScroll then T.partsScroll:reset() end
    local n = T.syncSelectionUI()
    if n > 1 then
        local row = selectedRow()
        setStatus(string.format("%d selected - Delete applies to all %d; Teleport uses %s",
            n, n, row and tostring(row.vid or "-") or "?"))
    end
end

-- ---------------------------------------------------------------------------
-- Actions. Both work on ROW data, never on a live object, so they reach a car
-- this client has never streamed.
-- ---------------------------------------------------------------------------

-- Exposed on T (not a file local) because the right-click menu in
-- RCVehicleCheats drives the same action. One implementation, two doors.
function T.teleportTo(row)
    if not (row and row.x) then setStatus("That row has no position."); return end
    local me = getPlayer()
    -- Bare: teleportTo is an exposed method (IsoGameCharacter.java:
    -- 14980-14990), so body faults are swallowed by MethodCaller
    -- (MethodCaller.java:33-56), and the OnExitVehicle it fires en route
    -- (:14992-14997) runs every foreign listener under the dispatcher's
    -- per-listener catch plus its own protectedCallVoid (Event.java:52-63) -
    -- doubly contained. Nothing here can throw back.
    me:teleportTo(row.x + 0.5, row.y + 0.5, math.floor(row.z or 0))
end
local teleportToRow = T.teleportTo

-- Ledger report built from the SNAPSHOT rather than by reading the vehicle.
-- The old code re-read modData off the live object, which meant a car the admin
-- could see in the list but not stream was un-deletable. The server already
-- enriched every field this needs.
local function reportFor(row)
    return {
        via = "panel", delete = true,
        vehicle = row.script,
        wreck = row.kind == "wreck",
        x = row.x, y = row.y, z = row.z,
        owner = row.owner, claimId = row.claimId,
    }
end

-- Delete a SELECTION. The two halves travel differently on purpose:
--
--   * the removals are vanilla's own "vehicle"/remove channel and cannot be
--     batched - one packet per car, and it must be the SERVER that removes,
--     because a client-side permanentlyRemove() is local-only and the server
--     re-streams the car (the "panel dismantle respawned the vehicle" bug,
--     found live 2026-07-02). getVehicleById runs SERVER-side there, which is
--     also why this reaches unstreamed cars.
--   * the ledger is ONE dismantledMany carrying every report, never a loop of
--     dismantled: RCServer drops commands past 20/sec silently, so a loop could
--     destroy ten cars and ledger only the first few. An audit that
--     under-reports a destructive staff action is worse than none, because it
--     reads as authoritative.
local function deleteRows(rows)
    local me = getPlayer()
    local reports, skipped = {}, 0
    local capped = false

    for _, row in ipairs(rows) do
        if #reports >= BULK_MAX then capped = true; break end
        if not row.vid then
            -- an unloaded registry row: there is no object anywhere to remove
            skipped = skipped + 1
        else
            -- Bare. Every failure the old guard named is body-swallowed:
            -- sendClientCommand is an exposed global (LuaManager.java:
            -- 7219-7236), getVehicleById takes an int and answers nil for a
            -- stale id (LuaManager.java:8208-8211), and permanentlyRemove's
            -- teardown NPEs (BaseVehicle.java:7205-7221) never reach Lua
            -- (MethodCaller.java:33-56). `sent` was always true and `failed`
            -- had never counted - the ledger already rode on every row with a
            -- vid, and now says so.
            if isClient() then
                sendClientCommand(me, "vehicle", "remove", { vehicle = row.vid })
            else
                local v = getVehicleById(row.vid)
                if v then v:permanentlyRemove() end
            end
            reports[#reports + 1] = reportFor(row)
        end
    end

    if #reports > 0 then
        sendClientCommand(me, M, "dismantledMany", { reports = reports })
    end

    -- Say what actually happened, including what was NOT done. A silent
    -- shortfall on a destructive action reads as "all of them went".
    local parts = { string.format("Deleted %d", #reports) }
    if skipped > 0 then parts[#parts + 1] = string.format("%d unloaded (skipped)", skipped) end
    if capped      then parts[#parts + 1] = string.format("cap %d per click", BULK_MAX) end
    setStatus(table.concat(parts, " - ") .. ".")

    if T.sel then T.sel:clear() end
    T.refresh()
end

-- Exposed for the same reason as teleportTo: the context menu's Delete must go
-- through THIS path, so the modal, the claimed-car warning and the ledger
-- report are identical whichever door the delete came through. A second,
-- shorter delete path is how an unaudited destructive action gets born.
function T.confirmDeleteRows(rows)
    local label
    if #rows == 1 then
        local row = rows[1]
        label = string.format(
            "Delete %s (id %s)%s?\n\nThe vehicle and everything inside it are removed from the world for good.",
            RCShared.prettyVehicleName(row.script), tostring(row.vid or "-"),
            row.owner and ("\n\nCLAIMED by " .. tostring(row.owner)) or "")
    else
        -- Count claimed cars separately: deleting someone's claimed vehicle is a
        -- different act from clearing wrecks, and at six rows the admin cannot
        -- see the owner field behind this dialog.
        local claimed = 0
        for _, r in ipairs(rows) do if r.owner then claimed = claimed + 1 end end
        label = string.format("Delete %d selected vehicles?%s\n\n"
            .. "They and everything inside them are removed from the world\n"
            .. "for good. This cannot be undone.",
            #rows, claimed > 0 and ("\n\n" .. claimed .. " of them are CLAIMED.") or "")
    end
    local modal = ISModalDialog:new(
        getCore():getScreenWidth() / 2 - 220,
        getCore():getScreenHeight() / 2 - 80,
        440, 180, label, true, nil,
        function(_, button)
            if button.internal == "YES" then deleteRows(rows) end
        end)
    modal:initialise()
    modal:addToUIManager()
end

-- ---------------------------------------------------------------------------
-- List widget
-- ---------------------------------------------------------------------------
local VehList = ISScrollingListBox:derive("RCVehicleTabList")

function VehList:doDrawItem(y, item, alt)
    local r = item.item
    if not r then return y + self.itemheight end
    local C = DFKit.col
    local h = self.itemheight

    local selected = r.vid and T.sel and T.sel:has(r.vid)
    if selected then
        if self.selected == item.index then
            self:drawRect(0, y, self.width, h - 1, 0.35, C.accent.r, C.accent.g, C.accent.b)
        else
            self:drawRect(0, y, self.width, h - 1, 0.22, C.accent.r, C.accent.g, C.accent.b)
        end
    elseif alt then
        self:drawRect(0, y, self.width, h - 1, 0.14, C.panel.r, C.panel.g, C.panel.b)
    end

    -- The lifecycle stripe. This is the whole reason the tab talks to the
    -- server: four states the Janitor already knew and the admin could not see.
    local v = verdictOf(r)
    local sc = C[v.col] or C.textDim
    self:drawRect(0, y, 3, h - 1, r.verdict and 1 or 0.35, sc.r, sc.g, sc.b)

    local dim = r.loaded == false
    local tc = dim and C.textDim or C.text
    local glyph = (r.kind == "wreck" and "x") or (r.kind == "trailer" and "=") or "o"

    self:drawText(glyph, GLYPH_X, y + TEXT_DY, C.textDim.r, C.textDim.g, C.textDim.b, 1, FONT)
    self:drawText(r.vid and tostring(r.vid) or "--", VID_X, y + TEXT_DY,
        C.textDim.r, C.textDim.g, C.textDim.b, 1, FONT)

    -- Right column first, so the name knows how much room it actually has.
    local right = (r.loaded == false) and "unloaded" or tostring(distOf(r) or "?")
    local tw = getTextManager():MeasureStringX(FONT, right)
    self:drawText(right, self.width - 8 - tw, y + TEXT_DY,
        C.textDim.r, C.textDim.g, C.textDim.b, 1, FONT)

    -- CLIP the name. "Pick Up Van Smashed Front" ran straight through the
    -- distance column and out of the list; a name is the least important thing
    -- in the row to read in full, and the one most likely to be long.
    local name = RCShared.prettyVehicleName(r.script)
    local avail = (self.width - 8 - tw) - NAME_X - 6
    if avail > 12 then
        if DFTheme and DFTheme.fitText then
            name = DFTheme.fitText(name, FONT, avail)
        elseif getTextManager():MeasureStringX(FONT, name) > avail then
            -- No skin loaded (classic panel): trim by hand rather than overrun.
            while #name > 1 and getTextManager():MeasureStringX(FONT, name .. "..") > avail do
                name = string.sub(name, 1, #name - 1)
            end
            name = name .. ".."
        end
        self:drawText(name, NAME_X, y + TEXT_DY, tc.r, tc.g, tc.b, dim and 0.75 or 1, FONT)
    end

    return y + h
end

function VehList:onMouseDown(mx, my)
    ISScrollingListBox.onMouseDown(self, mx, my)
    local it = self.items[self.selected]
    local vid = it and it.item and it.item.vid
    if vid == nil or not T.sel then return end

    local ctrl, shift = Select.modifiers()
    T.sel:click(vid, orderedVids(self), ctrl, shift)

    -- A ctrl-click that DEselected the clicked row must not leave it primary, or
    -- Teleport/Delete would act on a row drawn as unselected.
    if not T.sel:has(vid) then
        local first = T.sel:list(orderedVids(self))[1]
        for i, row in ipairs(self.items) do
            if row.item and row.item.vid == first then self.selected = i; break end
        end
    end
    T.onSelectionChanged()
end

-- Seam for the cheat menus (wired in RCVehicleCheats). Declared here so the
-- widget never has to know whether that surface exists.
--
-- Does NOT chain to the base: ISScrollingListBox defines onMouseDown but no
-- onRightMouseUp, so ISScrollingListBox.onRightMouseUp(self, ...) is a nil
-- call - the same shape as the getTooltip() crash on 2026-08-02. And rowAt is
-- the right source anyway: right-clicking a row should act on the row under
-- the cursor, not on whatever was left-selected earlier.
function VehList:onRightMouseUp(mx, my)
    local idx = self:rowAt(mx, my)
    if idx <= 0 then return end
    local item = self.items[idx]
    local row = item and item.item
    if row and T.showVehicleMenu then T.showVehicleMenu(row) end
end

-- ---------------------------------------------------------------------------
-- Diagram hotspot. The parts diagram is DRAWN in prerender, not a widget, so
-- it cannot receive a click on its own - this is an invisible panel parked over
-- the image rect whose only job is to turn a right-click into a part.
--
-- A widget rather than a handler on the tab panel because event delivery to a
-- bare parent is not something to rely on, and because this keeps the hit area
-- exactly congruent with the drawn rect: both are positioned from T.imgRect in
-- layout(), so they cannot drift apart.
--
-- No base chaining: ISPanel defines onMouseUp but NOT onRightMouseUp, the same
-- nil-call trap as the list widget above.
-- ---------------------------------------------------------------------------
local PartsHotspot = ISPanel:derive("RCPartsHotspot")

-- Two of these exist: one over the diagram, one over the parts grid. They differ
-- only in how a click becomes a part, so that is the one thing they carry - the
-- rest (coordinate lift, selection check, menu call) is identical and lives here.
--
-- The grid one matters more than it looks. A wing mirror is a handful of pixels
-- even on the rotated diagram, and "aim at a 12px sprite" is not a control
-- surface; the grid gives every part a full-width row to hit. The diagram is for
-- finding the damage, the list is for acting on it.
function PartsHotspot:onRightMouseUp(mx, my)
    local row = selectedRow()
    if not row or not self.resolve then return end
    -- Resolvers work in PANEL space (that is where both the diagram transform
    -- and the grid rects were computed), so lift these local coords back up.
    local rec = self.resolve(self:getX() + mx, self:getY() + my)
    if rec and T.showPartMenu then T.showPartMenu(row, rec) end
end

-- ---------------------------------------------------------------------------
-- Scrolling, GRID INSTANCE ONLY (self.scrolls). Both hotspots share this class
-- and the diagram has nothing to scroll - its content is one fixed-size sprite.
--
-- These chain to ISPanel for the cases they do not claim. That is safe here and
-- deliberately unlike onRightMouseUp above: ISPanel really does define
-- onMouseDown/Move/Up, it is only onRightMouseUp (and onMouseWheel) it lacks.
-- ---------------------------------------------------------------------------
function PartsHotspot:onMouseWheel(del)
    if not self.scrolls then return false end
    return T.partsScroll:wheel(del)
end

function PartsHotspot:onMouseDown(x, y)
    if self.scrolls and T.partsScroll:press(self:getX() + x, self:getY() + y) then
        self:setCapture(true)
        return true
    end
    return ISPanel.onMouseDown(self, x, y)
end

function PartsHotspot:onMouseMove(dx, dy)
    if self.scrolls and T.partsScroll:drag(self:getY() + self:getMouseY()) then return end
    return ISPanel.onMouseMove(self, dx, dy)
end

function PartsHotspot:onMouseMoveOutside(dx, dy)
    if self.scrolls and T.partsScroll:drag(self:getY() + self:getMouseY()) then return end
    return ISPanel.onMouseMoveOutside(self, dx, dy)
end

function PartsHotspot:onMouseUp(x, y)
    self:setCapture(false)
    if self.scrolls then T.partsScroll:release() end
    return ISPanel.onMouseUp(self, x, y)
end

function PartsHotspot:onMouseUpOutside(x, y)
    self:setCapture(false)
    if self.scrolls then T.partsScroll:release() end
    return ISPanel.onMouseUpOutside(self, x, y)
end

-- Which grid row is under a panel-space point. T.partRows is rebuilt by
-- drawParts every frame, so it can never describe a layout that is no longer
-- on screen.
local function partRowAt(px, py)
    for _, r in ipairs(T.partRows or {}) do
        if px >= r.x and px <= r.x + r.w and py >= r.y and py <= r.y + r.h then
            return r.rec
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Chrome: verdict band, parts pane, meat column. Drawn, not widgets - it is
-- read-only text that changes every frame (the Necro idiom).
-- ---------------------------------------------------------------------------

local function drawBand(el)
    local b = T.bandRect
    if not b then return end
    local C  = DFKit.col
    local fL = DFKit.font.label or UIFont.Small
    el:drawRect(b.x, b.y, b.w, b.h, DFKit.alpha.card, C.panel.r, C.panel.g, C.panel.b)

    local row = selectedRow()
    if not row then
        DFKit.drawEmpty(el, b.x, b.y, b.w, b.h, "select a vehicle")
        return
    end

    local v  = verdictOf(row)
    local c  = C[v.col] or C.textDim
    el:drawRect(b.x, b.y, 3, b.h, 1, c.r, c.g, c.b)

    local head = v.label
    if row.verdict == "clock" and row.dueIn then
        head = head .. "  due in " .. fmtAgo(row.dueIn)
    elseif row.verdict == nil then
        head = "NO VERDICT"
    end
    -- Two stacked lines in the band. The second used to sit at a fixed +20,
    -- which drew it through the first as soon as the glyphs got taller.
    -- No guard. getFontHeight/MeasureStringX cannot NPE on an unknown font:
    -- getFontFromEnum returns the DEFAULT font both when the enum is nil and
    -- when enumToFont has no entry for it (TextManager.java:119-124), so the
    -- deref one line below - the very line these guards cited - is on a value
    -- that method guarantees. MeasureStringX additionally returns 0 for a null
    -- string (:294). The fallback constants stay as the initial values, which
    -- is all they ever were.
    local bfh = getTextManager():getFontHeight(fL)
    local line2 = 4 + bfh + 2

    el:drawText(head, b.x + 12, b.y + 4, c.r, c.g, c.b, 1, fL)

    local why = row.verdict and v.line
        or "nearby scope carries no lifecycle data - switch scope for a verdict"
    el:drawText(why, b.x + 12, b.y + line2, C.textDim.r, C.textDim.g, C.textDim.b, 0.9, fL)
end

local function drawImage(el)
    local i = T.imgRect
    if not i then return end
    local C = DFKit.col
    el:drawRect(i.x, i.y, i.w, i.h, DFKit.alpha.inset, C.panel.r, C.panel.g, C.panel.b)

    local row = selectedRow()
    if not row then return end

    -- The parts diagram owns this box when it is available. Keeping the call
    -- behind a nil check means the tab renders correctly before that file
    -- exists and if it ever fails to load.
    if RCPartsView and RCPartsView.draw then
        RCPartsView.draw(el, i, row)
    else
        DFKit.drawEmpty(el, i.x, i.y, i.w, i.h, "parts view unavailable")
    end
end

-- Per-part breakdown, in two columns under the diagram.
--
-- The diagram answers "where is the damage"; this answers "how bad, exactly".
-- Both read the SAME list (RCPartsView.partsFor), so a part cannot appear
-- healthy in one and broken in the other.
--
-- The grid itself LIVES IN RCPartsView now (drawBreakdown, moved 2026-08-13
-- when the player panel's My Vehicles tab grew the same grid) - this tab owns
-- only its pane, its scroll state, and the hit rows its right-click cheat
-- surface consumes.

-- Scroll state for the parts grid. One DFScroll, kept on T because the grid is
-- redrawn from scratch every frame and the offset has to outlive the frame.
-- The behaviour - thumb size, wheel distance, track-click - is Core's, shared
-- with the Janitor dial form; this file owns only its own layout.
T.partsScroll = T.partsScroll or DFScroll.new()

local function drawParts(el)
    T.partRows = {}
    if not (RCPartsView and RCPartsView.drawBreakdown) then return end
    T.partRows = RCPartsView.drawBreakdown(el, T.partsRect, selectedRow(), T.partsScroll)
end

local function drawMeat(el)
    local d = T.meatRect
    if not d then return end
    local C  = DFKit.col
    local fL = DFKit.font.label or UIFont.Small
    el:drawRect(d.x, d.y, d.w, d.h, DFKit.alpha.inset, C.panel.r, C.panel.g, C.panel.b)

    local row = selectedRow()
    if not row then
        DFKit.drawEmpty(el, d.x, d.y, d.w, d.h, "select a vehicle")
        return
    end

    local yy = d.y + 8

    -- Line advance from the ACTUAL font. Fixed 16/17px steps overlapped their
    -- own glyphs the moment the text size went up, which is what turned this
    -- column into a smear rather than a list.
    -- No guard - see the getFontFromEnum note earlier in this file. The floor
    -- stays; it is a layout minimum, not an error path.
    local lh = getTextManager():getFontHeight(fL) + 3
    if lh < 14 then lh = 14 end

    local function section(title)
        el:drawText(title, d.x + 10, yy, C.textDim.r, C.textDim.g, C.textDim.b, 0.8, fL)
        yy = yy + lh
    end
    local function kv(k, val, colour)
        local c = colour or C.text
        el:drawText(k, d.x + 10, yy, C.textDim.r, C.textDim.g, C.textDim.b, 0.85, fL)
        -- Value clipped against the KEY's measured width, not a remembered
        -- 108px gutter: at a larger font the key itself grows, and a fixed
        -- gutter is how the two ends of the row ended up printed on top of
        -- each other.
        local kw = getTextManager():MeasureStringX(fL, k)
        local avail = d.w - 20 - kw - 10
        local s = tostring(val == nil and "-" or val)
        if avail > 12 then
            s = DFTheme and DFTheme.fitText and DFTheme.fitText(s, fL, avail) or s
        end
        local tw = getTextManager():MeasureStringX(fL, s)
        el:drawText(s, d.x + d.w - 10 - tw, yy, c.r, c.g, c.b, 1, fL)
        yy = yy + lh + 1
    end
    local function rule()
        yy = yy + 3
        el:drawRect(d.x + 10, yy, d.w - 20, 1, 0.35, C.line.r, C.line.g, C.line.b)
        yy = yy + 7
    end

    section("PROVENANCE")
    -- The script name's prefix IS the defining module ("Base.Van"), which is the
    -- whole of what we can say about origin - see the removed "defined by" note
    -- in RCFleet.lua for why the richer version is gone.
    kv("script", row.script)
    kv("kind", row.kind)
    if row.overlay then kv("overlay", row.overlay) end
    rule()

    section("OWNERSHIP")
    kv("owner", row.owner or "unclaimed", row.owner and C.ok or C.textDim)
    kv("claim id", row.claimId)
    rule()

    section("LIFECYCLE")
    if not row.verdict then
        kv("verdict", "not available on this scope", C.textDim)
    else
        kv("last user", row.lastUser or "never seen")
        kv("last touched", row.idle and fmtAgo(row.idle) or "-",
            (row.idle and row.window and row.idle > row.window) and C.warn or nil)
        kv("user seen", row.userIdle and fmtAgo(row.userIdle) or "-",
            (row.userIdle and row.window and row.userIdle > row.window) and C.danger or nil)
        kv("window", row.window and fmtAgo(row.window) or "-")
        local due = row.dueIn
        kv("eligible", due and (due <= 0 and "now" or ("in " .. fmtAgo(due))) or "-",
            (due and due <= 0) and C.danger or C.warn)
    end
    rule()

    section("SHIELDS")
    local sh = row.shields or {}
    -- Greyed chips are as informative as lit ones: "why is this car NOT
    -- protected" is the question an admin arrives with.
    --
    -- No phunzone chip (2026-08-03, owner's call): PhunZones is on its way out
    -- and Limes replaces it, so the chip would be permanently dark and reading
    -- as a shield that exists but never fires.
    --
    -- RCJanitor still CHECKS phunZoneBlocks - deliberately left alone. That gate
    -- decides what the sweep actually reclaims, so removing it is a reclamation
    -- decision rather than a panel one, and it is already inert without
    -- PhunZones loaded (RCShared.phunZoneBlocks returns false when the global is
    -- absent). When Limes lands its zone rule takes that slot, and this list
    -- gains a "limes" chip.
    -- Chip height and wrap step follow the font: a 17px chip around a 20px
    -- glyph is a box with text hanging out of it, and a 20px wrap step stacks
    -- the second row of chips on top of the first.
    local chipH = math.max(17, lh + 1)
    local cx = d.x + 10
    for _, k in ipairs({ "claimed", "wreck", "safehouse" }) do
        local on = sh[k] == true
        local c = on and C.ok or C.textDim
        local tw = getTextManager():MeasureStringX(fL, k)
        if cx + tw + 12 > d.x + d.w - 10 then cx = d.x + 10; yy = yy + chipH + 3 end
        el:drawRect(cx, yy, tw + 10, chipH, on and 0.22 or 0.08, c.r, c.g, c.b)
        el:drawText(k, cx + 5, yy, c.r, c.g, c.b, on and 1 or 0.5, fL)
        cx = cx + tw + 14
    end
    yy = yy + chipH + 7
    rule()

    section("POSITION")
    kv("tile", fmtTile(row))
    local dist = distOf(row)
    kv("distance", dist and (dist .. " tiles") or "-")
    kv("occupants", (row.occupied and row.occupied > 0) and row.occupied or "none")
end

-- Column header for the list. The columns were unlabelled: an admin had a kind
-- glyph, a bare number and a second bare number with nothing to say which was
-- the id and which the distance.
local function drawListHead(el)
    local hd = T.listHeadRect
    if not hd then return end
    local C  = DFKit.col
    local fL = DFKit.font.label or UIFont.Small
    el:drawText("ID", hd.x + 22, hd.y, C.textDim.r, C.textDim.g, C.textDim.b, 0.8, fL)
    el:drawText("VEHICLE", hd.x + NAME_X, hd.y, C.textDim.r, C.textDim.g, C.textDim.b, 0.8, fL)
    -- The right column changes meaning per row (tiles away, or "unloaded"), so
    -- the header names the common case rather than inventing a word for both.
    local lbl = "DIST"
    local tw = getTextManager():MeasureStringX(fL, lbl)
    el:drawText(lbl, hd.x + hd.w - 8 - tw, hd.y, C.textDim.r, C.textDim.g, C.textDim.b, 0.8, fL)
    el:drawRect(hd.x, hd.y + hd.h - 1, hd.w, 1, 0.35, C.line.r, C.line.g, C.line.b)
end

local function attachChrome(panel)
    panel.drawVehicleChrome = function(self_)
        -- The Janitor view draws its own body. Returning here rather than
        -- letting the fleet chrome run first is what keeps a hidden view's
        -- panes from bleeding through - drawn chrome has no visibility flag of
        -- its own, so the branch IS its visibility.
        if T.views and T.views:active() ~= "fleet" then
            T.views:draw(self_)
            return
        end
        drawListHead(self_)
        drawBand(self_)
        drawImage(self_)
        drawParts(self_)
        drawMeat(self_)
        if #T.rows == 0 and T.listRect then
            local l = T.listRect
            DFKit.drawEmpty(self_, l.x, l.y, l.w, l.h,
                T.partial and "partial - refresh" or "no vehicles")
        end
    end
    local orig = panel.prerender
    panel.prerender = function(self_)
        if orig then orig(self_) end
        self_:drawVehicleChrome()
    end
end

-- ---------------------------------------------------------------------------
-- Layout. Positioning only, computed up front so each zone lands where the
-- design wants it rather than wherever a running cursor arrived. Hoisted to
-- file scope (with refresh and syncSelectionUI) so the resize hook can call it
-- - the old build() closed over its widgets, which is why this tab was one of
-- the three with no resize at all.
-- ---------------------------------------------------------------------------
local function layout(panel, x, y, w, h)
    if not T.listBox then return end
    local m = DFKit.metrics
    local R = DFKit.layout(panel, x, y, w, h)

    -- Remembered so setView can re-lay-out without the caller's rect. The
    -- resize hook and the strip buttons both need to trigger a relayout, and
    -- only one of them has coordinates to hand.
    T.host = panel
    T.hostX, T.hostY, T.hostW, T.hostH = x, y, w, h

    -- The view strip is claimed FIRST, above everything either view owns, so
    -- it stays in one place while the body underneath changes completely.
    local strip = R:header(m.btnH + m.gap)
    if T.views then T.views:layoutStrip(strip.x, strip.y) end

    -- Anything that is not the Fleet view owns its whole body rect and lays
    -- itself out; DFViews dispatches to whichever is active, so adding a third
    -- view later needs no change here.
    if T.views and T.views:active() ~= "fleet" then
        local body = R:rest()
        T.views:layoutActive(panel, body.x, body.y, body.w, body.h)
        return
    end

    local tools = R:header(m.btnH + m.gap)
    local foot  = R:footer(m.btnH + m.gap)

    -- toolbar
    local tx = tools.x
    T.btnRefresh:setX(tx);         T.btnRefresh:setY(tools.y)
    tx = tx + 90 + m.gap
    for _, b in ipairs(T.scopeBtns) do
        b:setX(tx); b:setY(tools.y)
        tx = tx + b:getWidth() + 2
    end
    T.status:setX(tx + m.gap);     T.status:setY(tools.y + 4)

    -- footer
    local fy = foot.y + m.gap
    T.btnTeleport:setX(foot.x);        T.btnTeleport:setY(fy)
    if T.btnSpawn then T.btnSpawn:setX(foot.x + 120); T.btnSpawn:setY(fy) end
    T.btnDelete:setX(foot.x + foot.w - 120); T.btnDelete:setY(fy)

    -- FOUR columns: list | diagram | parts | meat, with the verdict band
    -- spanning everything right of the list.
    --
    -- The diagram gets a TALL column rather than a wide one. Its art is 263x600
    -- portrait, so in a landscape pane it fits to the height and renders about
    -- 95px across - too small to click a part on. Given a column the full height
    -- of the body it sits at nearly 1:1, roughly six times the area, with no
    -- rotation needed (see the dead-end note in RCPartsView).
    local body = R:rest()

    local listX = body.x
    local listW = LIST_W
    local restW = body.w - listW - m.gap

    -- Shrink order under pressure: meat, then parts, then the diagram, then the
    -- list. The diagram resists because shrinking it is what made it unusable in
    -- the first place; the list resists last because it is how you navigate.
    local diagW, partsW = DIAG_W, PARTS_W
    local meatW = restW - diagW - partsW - m.gap * 2
    if meatW < MEAT_MIN then
        local deficit = MEAT_MIN - meatW
        local take = math.min(deficit, PARTS_W - PARTS_MIN)
        partsW, deficit = partsW - take, deficit - take
        take = math.min(deficit, DIAG_W - DIAG_MIN)
        diagW, deficit = diagW - take, deficit - take
        listW = math.max(LIST_MIN, listW - deficit)
        restW = body.w - listW - m.gap
        meatW = restW - diagW - partsW - m.gap * 2
    end
    if meatW < 60 then meatW = 60 end

    local restX  = listX + listW + m.gap
    local diagX  = restX
    local partsX = diagX + diagW + m.gap
    local meatX  = partsX + partsW + m.gap

    T.listHeadRect = { x = listX, y = body.y, w = listW, h = LIST_HEAD_H }
    local listY = body.y + LIST_HEAD_H
    local listH = body.h - LIST_HEAD_H
    -- sizeList, not four setters: the scrollbar is built at construction size
    -- and a bare resize leaves it stale, which clips every row away. See DFKit.
    DFKit.sizeList(T.listBox, listX, listY, listW, listH)
    T.listRect = { x = listX, y = listY, w = listW, h = listH }

    -- The verdict leads, across the full width of the evidence below it.
    T.bandRect = { x = restX, y = body.y, w = restW, h = BAND_H }
    local by = body.y + BAND_H + m.gap
    local bh = math.max(60, body.h - BAND_H - m.gap)

    T.imgRect = { x = diagX, y = by, w = diagW, h = bh }
    if T.hotspot then
        T.hotspot:setX(diagX);    T.hotspot:setY(by)
        T.hotspot:setWidth(diagW); T.hotspot:setHeight(bh)
    end

    T.partsRect = { x = partsX, y = by, w = partsW, h = bh }
    if T.partsHotspot then
        T.partsHotspot:setX(partsX);    T.partsHotspot:setY(by)
        T.partsHotspot:setWidth(partsW); T.partsHotspot:setHeight(bh)
    end

    T.meatRect = { x = meatX, y = by, w = meatW, h = bh }
end

-- ---------------------------------------------------------------------------
-- The inner view strip: Fleet | Janitor.
--
-- Two views, one tab. The family's panel bar was already at nine entries, and
-- these two are the same domain - what the fleet IS, and what the Janitor does
-- to it over time. Splitting them across top-level tabs cost a slot and made
-- the policy and its consequences feel unrelated.
--
-- The mechanism used to live here and now lives in DFViews (Core), because
-- Husbandry wants the same thing for Animals|Hutches and this is forty lines
-- whose subtlest part - that setVisible(false) also stops an element receiving
-- MOUSE events, which is why switching is visibility and not drawing over the
-- top - is exactly what a second copy would get wrong. See that file's header.
--
-- What stays here is the only part that is about vehicles: which views exist,
-- what they are called, and that entering the Janitor re-reads server state
-- (its onShow), which DFViews calls after the relayout.
-- ---------------------------------------------------------------------------
local function setView(view)
    if T.views then T.views:set(view) end
end
T.setView = setView

-- ---------------------------------------------------------------------------
-- Tab build (DFPanel calls build(spec, panel, x, y, w, h) at panel-open)
-- ---------------------------------------------------------------------------
local function build(spec, panel, x, y, w, h)
    -- Fresh selection every time the tab is built. A stale set of vehicle ids
    -- from a previous panel session would point at cars that may since have been
    -- removed, and this is the one tab where acting on the wrong row is
    -- unrecoverable.
    T.sel = Select.new()
    T.rows, T.partial = {}, false
    pending = nil

    local list = VehList:new(0, 0, 10, 10)
    list.itemheight = ROW_H
    list.drawBorder = true
    DFKit.well(list)
    list:initialise()
    list:instantiate()
    panel:addChild(list)
    T.listBox = list

    T.status = DFKit.label(panel, 0, 0, "", DFKit.col.textDim, FONT)

    -- Invisible: what is underneath is drawn by the chrome pass, and these exist
    -- only to catch right-clicks. backgroundColor a=0 rather than
    -- setVisible(false), because an invisible element gets no mouse events.
    local function hotspot(resolve)
        local hs = PartsHotspot:new(0, 0, 10, 10)
        hs.backgroundColor = { r = 0, g = 0, b = 0, a = 0 }
        hs.borderColor     = { r = 0, g = 0, b = 0, a = 0 }
        hs.resolve         = resolve
        hs:initialise()
        hs:instantiate()
        panel:addChild(hs)
        return hs
    end
    T.hotspot = hotspot(function(px, py)
        return RCPartsView and RCPartsView.partAt(px, py) or nil
    end)
    T.partsHotspot = hotspot(partRowAt)
    -- Only the grid scrolls; the diagram is one fixed-size sprite.
    T.partsHotspot.scrolls = true

    T.btnRefresh = DFKit.button(panel, 0, 0, 90, "Refresh", panel, T.refresh)

    -- Scope. Loaded server-wide is the default because triage means finding the
    -- car you are NOT standing next to; Nearby stays one click away and is the
    -- only scope a non-admin can use, since the other two are server-gated.
    local admin = isAdmin()
    local SCOPES = {
        { id = "loaded",  label = "Loaded",  w = 74,
          tip = "Every vehicle in a loaded chunk, server-wide." },
        { id = "nearby",  label = "Nearby",  w = 74,
          tip = "Only what this client has streamed. Costs no network, carries no lifecycle data." },
        { id = "claimed", label = "Claimed", w = 78,
          tip = "Every claimed vehicle from the registry, including cars nobody has streamed in." },
        -- The triage scope, and the reason the Janitor view carries no list of
        -- its own: this IS the due list. Same scan, filtered server-side to the
        -- two verdicts that lead to reclamation and ordered here by urgency -
        -- so a doomed car is one click from the full inspector rather than a
        -- read-only row in a second table.
        { id = "due",     label = "Due",     w = 60,
          tip = "Only vehicles on the reclamation path, soonest first. Excludes claimed, wrecked, held and shielded vehicles - they are not 'not due yet', they are not coming at all." },
    }
    T.scopeBtns = {}
    for _, s in ipairs(SCOPES) do
        local needsAdmin = (s.id ~= "nearby")
        local b = DFKit.button(panel, 0, 0, s.w, s.label, panel, function()
            T.scope = s.id
            for _, o in ipairs(T.scopeBtns) do
                o.borderColor = (o.dfScope == T.scope)
                    and { r = DFKit.col.accent.r, g = DFKit.col.accent.g, b = DFKit.col.accent.b, a = 0.9 }
                    or  { r = DFKit.col.line.r,   g = DFKit.col.line.g,   b = DFKit.col.line.b,   a = 0.4 }
            end
            T.refresh()
        end, s.id == T.scope and "primary" or "action",
        { tooltip = needsAdmin and not admin
            and (s.tip .. "  Requires admin.") or s.tip })
        b.dfScope = s.id
        if needsAdmin and not admin then b:setEnable(false) end
        T.scopeBtns[#T.scopeBtns + 1] = b
    end
    if not admin then T.scope = "nearby" end

    T.btnTeleport = DFKit.button(panel, 0, 0, 110, "Teleport to", panel, function()
        local row = selectedRow()
        if row then teleportToRow(row) else setStatus("Select a vehicle first.") end
    end, "primary")

    -- Spawner door #2 (the world right-click is #1; both open RCSpawnWindow).
    -- Decorative gate - the server re-checks the sender on every spawn command.
    T.btnSpawn = nil
    if RCShared.canUseSpawner(getPlayer()) then
        T.btnSpawn = DFKit.button(panel, 0, 0, 110,
            getText("IGUI_RC_SpawnOpenBtn"), panel, function()
                if RCSpawnWindow and RCSpawnWindow.open then RCSpawnWindow.open(getPlayer()) end
            end)
    end

    -- No fallback to list.selected on purpose. Ctrl-clicking the only selected
    -- row empties the set while the base widget still has that row as
    -- self.selected - falling back would then delete the row the admin had just
    -- UNSELECTED. On a destructive action, an empty selection means do nothing.
    T.btnDelete = DFKit.button(panel, 0, 0, 110, "Delete", panel, function()
        local rows = selectedRows()
        if #rows > 0 then T.confirmDeleteRows(rows)
        else setStatus("Select a vehicle first.") end
    end, "danger", { hold = true })

    -- ----- the inner view strip -------------------------------------------
    -- Built last so both views' widgets already exist to be hidden. Fleet is
    -- always the landing view: it is the one an admin opens the tab to use,
    -- and the Janitor's dials are a place you go deliberately.
    -- Fleet leads because it is what an admin opens the tab to use; the
    -- Janitor's dials are a place you go deliberately.
    T.views = DFViews.new{
        views = {
            { id = "fleet",   label = "Fleet",   w = 72,
              tip = "The fleet itself - find a vehicle, inspect it, act on it." },
            { id = "janitor", label = "Janitor", w = 82, view = RCJanitorView,
              tip = "How reclamation and replacement behave: the dials, the token pools, and the vanilla retrofit. To see WHICH vehicles are about to be reclaimed, use the Due scope on Fleet." },
        },
        -- The strip lives above both views, so a switch has to re-run the
        -- host's layout: the body rect underneath changes shape completely.
        relayout = function()
            if T.host then layout(T.host, T.hostX, T.hostY, T.hostW, T.hostH) end
        end,
    }
    -- Strip buttons belong to the TAB, not to either view - they are never
    -- hidden by a switch, so they go in neither widget list.
    T.views:attachStrip(panel)

    -- APPENDED, never a literal list. T.btnSpawn is nil when the player lacks
    -- spawner access, and a nil in the middle of a table constructor truncates
    -- ipairs at the hole - every widget after it would silently never be shown
    -- or hidden again. Delete was the one sitting behind that hole.
    T.fleetWidgets = {}
    local function keep(wdg)
        if wdg then T.fleetWidgets[#T.fleetWidgets + 1] = wdg end
    end
    keep(T.listBox); keep(T.status); keep(T.hotspot); keep(T.partsHotspot)
    keep(T.btnRefresh); keep(T.btnTeleport); keep(T.btnSpawn); keep(T.btnDelete)
    for _, b in ipairs(T.scopeBtns) do keep(b) end

    -- Fleet is built inline by this file, so its widgets are handed over
    -- directly. Every other view builds its own into the same panel and hands
    -- back a flat list, which attachViews collects.
    T.views:setWidgets("fleet", T.fleetWidgets)
    T.views:attachViews(panel)

    attachChrome(panel)
    setView("fleet")
    layout(panel, x, y, w, h)
    T.refresh()
end

-- ---------------------------------------------------------------------------
-- METRICS. Every number this tab lays out with is derived here from the
-- CURRENT font, against a baseline measured from UIFont.Code rather than
-- assumed. This is the whole fix for "raising the text size breaks the list":
-- the geometry was tuned at one font and treated as constant, so at a larger
-- one the id column ran under the name column, rows clipped their own glyphs,
-- and the meat column's label/value pairs overprinted each other.
--
-- The three row columns are measured against real content - a five-digit id -
-- instead of being positioned at a remembered pixel. Column WIDTHS scale by
-- the font ratio, except the diagram, whose content is a fixed-size sprite.
-- ---------------------------------------------------------------------------
local baseCodeFH
local function recomputeMetrics()
    FONT = DFKit.font.code or UIFont.Code

    if not baseCodeFH then
        -- No guard - see the note on getFontFromEnum below. The floor stays:
        -- a legitimately tiny line height would still break the grid rhythm.
        baseCodeFH = getTextManager():getFontHeight(UIFont.Code)
        if not baseCodeFH or baseCodeFH < 1 then baseCodeFH = 18 end
    end

    -- No guard. getFontHeight/MeasureStringX cannot NPE on an unknown font:
    -- getFontFromEnum returns the DEFAULT font both when the enum is nil and
    -- when enumToFont has no entry for it (TextManager.java:119-124), so the
    -- deref one line below - the very line these guards cited - is on a value
    -- that method guarantees. MeasureStringX additionally returns 0 for a null
    -- string (:294). The fallback constants stay as the initial values, which
    -- is all they ever were.
    local fh = getTextManager():getFontHeight(FONT)
    if not fh or fh < 1 then fh = baseCodeFH end

    local s = fh / baseCodeFH
    if s < 1 then s = 1 end

    ROW_H       = math.max(18, fh + 4)
    TEXT_DY     = math.max(1, math.floor((ROW_H - fh) / 2))
    LIST_HEAD_H = math.max(LIST_HEAD_B, fh + 2)
    BAND_H      = math.max(BAND_H_B, math.floor(BAND_H_B * s))

    LIST_W    = math.floor(LIST_W_B * s)
    LIST_MIN  = math.floor(LIST_MIN_B * s)
    PARTS_W   = math.floor(PARTS_W_B * s)
    PARTS_MIN = math.floor(PARTS_MIN_B * s)
    MEAT_MIN  = math.floor(MEAT_MIN_B * s)

    -- Measured columns. "88888" is the widest realistic vehicle id; the glyph
    -- is one character. Both get a real gap after them rather than a gap that
    -- happened to be big enough at one size.
    -- No guard - same getFontFromEnum reading as the heights above; a null
    -- string additionally returns 0 (TextManager.java:294), and neither of
    -- these is null.
    local gw = getTextManager():MeasureStringX(FONT, "o")
    local iw = getTextManager():MeasureStringX(FONT, "88888")
    GLYPH_X = 8
    VID_X   = GLYPH_X + gw + 6
    NAME_X  = VID_X + iw + 8

    if T.listBox then T.listBox.itemheight = ROW_H end
end

-- Computed once at load so the tab is correct even if the panel is opened
-- before any preference change has ever fired.
recomputeMetrics()

-- Text size is a client preference, and a tab that only honoured it at build
-- time would need closing and reopening to apply - exactly the "did that
-- work?" ambiguity the settings window should not create. So metrics are
-- recomputed and the tab re-lays-out in place.
if DFPrefs and DFPrefs.onChange then
    DFPrefs.onChange(function()
        recomputeMetrics()
        if T.host then layout(T.host, T.hostX, T.hostY, T.hostW, T.hostH) end
    end)
end

-- Deferred registration: DFRegistry may not exist (no Dragonfly) and load
-- order within a session is alphabetical - OnGameStart is the level ground.
Events.OnGameStart.Add(function()
    if not DFRegistry then return end
    -- Bare: a throw out of this listener is caught by the event
    -- dispatcher's per-listener boundary and logged with a full stack trace
    -- at throw time (Event.java:53-63; KahluaThread.java:865, :1100). The
    -- pcall here bought a shorter message than the engine already prints,
    -- and "never allowed to kill our OnGameStart" was the containment the
    -- engine provides on its own.
    DFRegistry.registerTab{
        id         = "rcVehicles",
        label      = "Vehicles",
        capability = Capability.ChangeWeather,
        -- Deck nav order, set as one decision 2026-08-18 (live review):
        -- Admin 10, Players 20, Necro 30, Vehicles 40, Husbandry 50,
        -- Longstrider 60, Zones 70, Console 1000 (always last).
        -- Spaced by ten so a new tab can land between two without
        -- renumbering five files across five mods again.
        order = 40,
        build      = build,
        resize     = function(_, panel, w, h) layout(panel, 0, 0, w, h) end,
    }
end)

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
