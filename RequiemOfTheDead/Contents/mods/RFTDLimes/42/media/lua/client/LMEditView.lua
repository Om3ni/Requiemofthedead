-- SPDX-License-Identifier: GPL-3.0-or-later
-- LMEditView - "Zone Selector": the tree of PLACES, the map, and the actions.
--
-- REBUILT FOR THE 2026-08-26 REDESIGN (S3). The shape the owner signed off in
-- the interactive prototype (docs/limes-editor-mockup.html):
--
--   TOOLBAR      New Zone on the left; status, Revert and Save on the right.
--                That is ALL of it - the nine-button bar read as amateur hour
--                and each of those actions belongs to a zone anyway, so they
--                live where the zone is: the right-click menu. Share... opens
--                the operations window (import/export/census/clear/teleport).
--
--   THE TREE     places only (LMEdit:tree() filters tier/profile records) -
--                inherits-nested, family-striped, with per-row depth guides.
--                Each row: swatch, name, the resolved TIER as a right-aligned
--                badge (bright when the zone sets its own slot, dim lowercase
--                when it inherits it - the prototype's affordance), and a
--                profile-count chip. Click selects, double-click frames.
--
--   RIGHT-CLICK  the actions, per zone: Edit Details..., New Child Zone,
--                Set Tier > (the ladder, by rank), Apply Profile > (toggle),
--                Set Parent > (geometry-holding zones only), Rename,
--                Duplicate, Disable/Enable, Delete Rectangle, Zoom on Map,
--                and Delete last, separated. External row actions registered
--                via DFRegistry under tab id "limes" append after ours.
--
-- CONTAINMENT MAKES A CHILD, unchanged: drop a zone inside another and it
-- adopts that zone as its parent (LMEdit:reparentByContainment); Set Parent >
-- is the precise path. A tier link can no longer be broken by a drag because
-- tier is not a parent any more - it is the slot, and only Set Tier moves it.
--
-- EVERYTHING STILL WRITES TO A DRAFT. No packets until Save (§6.1 rules 2-4).

if isServer() then return end

require "LMCore"
require "LMEdit"

LMEditView = LMEditView or {}

local ui       = nil    -- widget bag
local draft    = nil    -- LMEdit draft
local editor   = nil    -- LMMapEditor
local map      = nil    -- LSMap
local selected = nil    -- zone name
local statusMsg, statusGood = "", false
local statusW = 0       -- px the status label may occupy; layout() measures it

local LEFT_W  = 268
-- No split any more: the tree owns the whole left column (2026-08-05). The
-- properties form that used to sit under it moved to Details, which is now
-- "everything you can set on this zone, grouped by who owns it" - LMCore's own
-- vocabulary included. The tree is the NAVIGATION surface once zones nest, and
-- it was getting 58% of a 268px column while a form sat underneath.
local FONT_HGT   = getTextManager():getFontHeight(UIFont.Small)

local rebuildTree, refreshChrome, selectZone, frameSelected, showZoneMenu, treeDrop

-- ---------------------------------------------------------------------------
-- The tree widget
--
-- Drawn rather than assembled from indented strings so the depth guides survive
-- a long zone name: a name that runs past the column would otherwise take its
-- own indentation with it and the nesting would read as noise.
-- ---------------------------------------------------------------------------

local TreeList = ISScrollingListBox:derive("LMZoneTree")
local INDENT   = 12
-- Rows are font-derived now (DFKit.rowHeight), so nothing inside one may be
-- pinned to a constant: text and swatch centre themselves against whatever
-- height the row turned out to be, or a larger UI font gets taller rows with
-- the content still stuck to the top of them.
local function rowText(h) return math.floor((h - FONT_HGT) / 2) end

function TreeList:doDrawItem(y, item, alt)
    local n = item.item
    if not n then return y + self.itemheight end
    local h = self.itemheight

    -- FAMILY striping, not row striping: every row of one top-level family
    -- shares a ground, so the eye reads "this block belongs together" instead
    -- of counting zebra lines - the prototype's idiom, kept exactly.
    if n.name == selected then
        self:drawRect(0, y, self.width, h - 1, 0.55, 0.20, 0.35, 0.55)
    elseif n.fam and n.fam % 2 == 1 then
        self:drawRect(0, y, self.width, h - 1, 0.05, 1, 1, 1)
    end

    -- The live drop target (S4): a bright border on the whole row - "onto",
    -- never "between". Selection green is the constitution's attention colour
    -- and this is precisely an attention moment.
    --
    -- Vanilla rows are keyed `itemindex` (ISScrollingListBox.lua:146); the
    -- first build compared `item.index`, a key vanilla never sets, so the
    -- border never drew on a real target and the whole gesture read as flat
    -- until the release popup (owner-reported 2026-08-28). The dragMoved and
    -- dragTarget guards matter as much as the key: on a plain click both
    -- sides of the old comparison were nil, and nil == nil lit every row.
    local lifted = self.dragMoved and self.dragName == n.name
    if self.dragMoved and self.dragTarget
            and self.dragTarget == item.itemindex then
        self:drawRectBorder(0, y, self.width, h - 1, 0.9, 0.56, 0.89, 0.20)
    end
    -- The row in hand: dimmed in place under an ash hairline, while the ghost
    -- chip drawn in render() carries its name with the cursor - the lift half
    -- of the prototype's A3 gesture.
    if lifted then
        self:drawRectBorder(0, y, self.width, h - 1, 0.35, 0.79, 0.81, 0.76)
    end

    local x = 4 + n.depth * INDENT

    -- Depth guides, one faint rule per level crossed.
    for d = 0, n.depth - 1 do
        self:drawRect(4 + d * INDENT + 4, y, 1, h, 0.25, 1, 1, 1)
    end

    -- The zone's own colour swatch, the same hash the map draws it with, so the
    -- list and the map name the same thing the same way.
    local c = LMMapEditor and LMMapEditor.colourFor and LMMapEditor.colourFor(n.name)
             or { 0.8, 0.8, 0.8 }
    local sy = y + math.floor((h - 8) / 2)
    self:drawRect(x, sy, 8, 8,
        (n.template and 0.35 or 1) * (lifted and 0.4 or 1), c[1], c[2], c[3])
    if n.template then self:drawRectBorder(x, sy, 8, 8, 0.8, c[1], c[2], c[3]) end

    local tx = x + 14
    local ty = y + rowText(h)
    local a  = (n.off and 0.45 or 1) * (lifted and 0.4 or 1)
    self:drawText(n.name, tx, ty, 0.92, 0.92, 0.92, a, UIFont.Small)

    -- Right-aligned, right to left: the profile chip, then the tier badge.
    -- The tier reads BRIGHT when this zone sets its own slot and dim
    -- lowercase when it inherits one - a value that is yours versus a value
    -- that is merely visible, the same distinction the forms draw.
    local bx = self.width - 8
    if n.prof and n.prof > 0 then
        local ptxt = n.prof .. " prof"
        local pw = getTextManager():MeasureStringX(UIFont.Small, ptxt)
        bx = bx - pw
        self:drawText(ptxt, bx, ty, 0.44, 0.73, 0.89, a * 0.9, UIFont.Small)
        bx = bx - 8
    end
    local badge = n.badge
    if badge and badge ~= "" then
        local bw = getTextManager():MeasureStringX(UIFont.Small, badge)
        bx = bx - bw
        if n.ownTier then
            self:drawText(badge, bx, ty, 0.79, 0.81, 0.76, a, UIFont.Small)
        else
            self:drawText(badge, bx, ty, 0.43, 0.46, 0.42, a, UIFont.Small)
        end
    end
    return y + h
end

function TreeList:onMouseDown(x, y)
    local idx = self:rowAt(x, y)
    if idx <= 0 then return end
    local row = self.items[idx]
    if not (row and row.item) then return end
    self.selected = idx
    selectZone(row.item.name)
    -- Arm the drag (S4). It only BECOMES one after the pointer has moved -
    -- a click is not a five-pixel journey - and only commits on a valid
    -- middle-band target at release.
    self.dragName  = row.item.name
    self.pressY    = y
    self.dragMoved = false
    self.dragTarget = nil
end

-- Drag-to-reparent (S4), the DFLayoutEditor row-drag idiom with two
-- deliberate differences: the live band is the target row's MIDDLE and its
-- edges are dead - this tree is name-sorted identically on every machine, so
-- there is no "between rows" to drop into - and the drop ASKS before acting,
-- because a new parent rewrites what half the zone's fields resolve to.
function TreeList:onMouseMove(dx, dy)
    ISScrollingListBox.onMouseMove(self, dx, dy)
    if not self.dragName then return end
    local my = self:getMouseY()
    if not self.dragMoved then
        if math.abs(my - (self.pressY or my)) < 5 then return end
        self.dragMoved = true
    end
    self.dragTarget = nil
    local i = self:rowAt(self:getMouseX(), my)
    if i >= 1 and i <= #self.items then
        local row = self.items[i]
        local name = row and row.item and row.item.name
        if name and name ~= self.dragName then
            local off = (my - self:getYScroll()) - (i - 1) * self.itemheight
            if off > self.itemheight * 0.2 and off < self.itemheight * 0.8 then
                self.dragTarget = i
            end
        end
    end
end

function TreeList:onMouseUp(x, y)
    -- Through to the base FIRST: its whole body is `vscroll.scrolling =
    -- false`, and skipping it leaves a scrollbar drag latched on
    -- (ISScrollingListBox.lua:135-139 - the DFLayoutEditor lesson).
    ISScrollingListBox.onMouseUp(self, x, y)
    local name, target, moved = self.dragName, self.dragTarget, self.dragMoved
    self.dragName, self.dragTarget, self.dragMoved = nil, nil, false
    if not (name and moved and target) then return end
    local row = self.items[target]
    local tname = row and row.item and row.item.name
    if tname then treeDrop(name, tname) end
end

-- Releasing off the list CANCELS rather than dropping on the last row the
-- pointer crossed: a drag that left the list is a drag the admin abandoned.
function TreeList:onMouseUpOutside(x, y)
    ISScrollingListBox.onMouseUpOutside(self, x, y)
    self.dragName, self.dragTarget, self.dragMoved = nil, nil, false
end

-- The drag ghost: from the first real drag frame the zone's name rides the
-- cursor as a chip - "Renfield > Louisville" once a live target is under it -
-- so the gesture is visibly a lift instead of a held click that surprises
-- with a popup at release (the prototype's A3 promise; the rows alone could
-- not show it, owner-reported 2026-08-28). Drawn in render(), after the base
-- has painted rows and children, so it rides above both. Sight-green on the
-- chip only while a drop would land; ash means "release does nothing here".
function TreeList:render()
    ISScrollingListBox.render(self)
    if not (self.dragMoved and self.dragName) then return end
    local txt = self.dragName
    if self.dragTarget then
        local row = self.items[self.dragTarget]
        local tname = row and row.item and row.item.name
        if tname then txt = self.dragName .. " > " .. tname end
    end
    local w  = getTextManager():MeasureStringX(UIFont.Small, txt) + 12
    local h  = FONT_HGT + 6
    local gx = self:getMouseX() + 14
    local gy = self:getMouseY() - math.floor(h / 2)
    self:drawRect(gx, gy, w, h, 0.92, 0.07, 0.09, 0.07)
    if self.dragTarget then
        self:drawRectBorder(gx, gy, w, h, 0.9, 0.56, 0.89, 0.20)
    else
        self:drawRectBorder(gx, gy, w, h, 0.6, 0.43, 0.46, 0.42)
    end
    self:drawText(txt, gx + 6, gy + 3, 0.79, 0.81, 0.76, 1, UIFont.Small)
end

-- DOUBLE-CLICK GOES THERE. Selecting a zone and then hunting for it on a
-- 15,000-tile map is the single most repeated action in this panel, and Frame
-- is a button two hundred pixels away from the name you just clicked. The
-- button stays for discoverability; this is the gesture you actually use.
--
-- Selection happens on the first click of the pair, so this only has to frame -
-- and it frames the whole zone rather than one rectangle, because a zone split
-- across the map is exactly the case where you cannot find it by eye.
function TreeList:onMouseDoubleClick(x, y)
    local idx = self:rowAt(x, y)
    if idx <= 0 then return end
    local row = self.items[idx]
    if not (row and row.item) then return end
    selectZone(row.item.name)
    frameSelected()
end

-- Right-click is where the zone's actions live (see header). Selection
-- follows the click first, so the menu and the map agree about which zone is
-- being acted on - a menu on an unselected row would read as acting on the
-- highlighted one.
function TreeList:onRightMouseUp(x, y)
    local idx = self:rowAt(x, y)
    if idx <= 0 then return end
    local row = self.items[idx]
    if not (row and row.item) then return end
    selectZone(row.item.name)
    showZoneMenu(row.item.name)
end

-- ---------------------------------------------------------------------------
-- Draft lifecycle
-- ---------------------------------------------------------------------------

local function setStatus(msg, good)
    statusMsg, statusGood = msg or "", good and true or false
    if ui and ui.status then
        -- CLIPPED to the room layout() measured. ISLabel does not clip, and
        -- the messages on this line are sentences ("Created X in the middle of
        -- the view - drag its handles..."): unclipped they ran under Save and
        -- Revert and off the pane, which was most of "text falls out of its
        -- box" on this view. statusMsg keeps the full text, so a wider
        -- re-layout always re-fits it.
        ui.status:setName(statusW > 0
            and DFKit.fitText(statusMsg, DFKit.font.small, statusW)
            or statusMsg)
        if statusGood then ui.status.r, ui.status.g, ui.status.b = 0.75, 0.95, 0.75
        else               ui.status.r, ui.status.g, ui.status.b = 0.95, 0.85, 0.65 end
    end
end
LMEditView.setStatus = setStatus

local function newDraft()
    draft = LMEdit.new(Limes.raw(), Limes.revision)
    if selected and not draft:exists(selected) then selected = nil end
    if editor then editor:setDraft(draft); editor:setSelected(selected) end
end

-- Shared with the Details view, which edits the same draft and the same zone.
function LMEditView.draft()    return draft end
function LMEditView.selected() return selected end
function LMEditView.refresh()
    if ui then rebuildTree(); refreshChrome() end
end

-- The store moved. Nothing being edited: take a fresh draft, which is also what
-- re-arms Save after a save of our own (the draft's revision has to match the
-- store's). Edits pending: say so and keep them. The save will be refused by the
-- revision gate with a message naming both revisions, so the admin is warned
-- before spending more work - and nobody's typing is thrown away by an event.
--
-- SAME REVISION MEANS REPAINT, NOT CONFLICT (2026-08-07). Limes.refresh() -
-- the moon moved, a phased profile switched on - fires onChanged WITHOUT
-- bumping the revision, because nothing replicated and every open draft is
-- still saveable. Before this guard, a phase flip under a dirty draft printed
-- "Another admin saved" naming two IDENTICAL revisions - an accusation about
-- an admin who does not exist, over an edit that would have saved fine.
local function onStoreChanged()
    if not draft then return end
    if Limes.revision == draft:revision() then
        LMEditView.refresh()
        return
    end
    if draft:isDirty() then
        -- A dirty draft whose changes ALREADY MATCH the new store is our own
        -- save coming back as the delta broadcast, not a conflict. Before
        -- this test, every successful save left the draft dirty against a
        -- bumped revision, the panel accused "another admin", and the second
        -- save was refused with advice (reopen the tab) that rebuilt nothing
        -- - the draft is module state and survives the tab. Rebase and say
        -- what actually happened.
        if draft:landedIn(Limes.raw()) then
            newDraft()
            setStatus("Saved - store now revision " .. tostring(Limes.revision) .. ".", true)
        else
            setStatus("Another admin saved (store is now revision " .. tostring(Limes.revision)
                .. "). Your edits are against revision " .. draft:revision()
                .. " and will be refused - Revert to take theirs, then redo yours.")
        end
    else
        newDraft()
        setStatus("Store updated to revision " .. tostring(Limes.revision) .. ".", true)
    end
    LMEditView.refresh()
end

selectZone = function(name, rectIdx)
    selected = name
    if editor then editor:setSelected(name, rectIdx) end
    rebuildTree()
    refreshChrome()
end
LMEditView.select = selectZone

-- ---------------------------------------------------------------------------
-- Containment
-- ---------------------------------------------------------------------------

local function isTemplate(name)
    local rec = draft and draft:get(name)
    return not (rec and rec.rects and #rec.rects > 0)
end

-- Auto-reparent after a geometry change. The template guard survives the
-- redesign for a different reason than it was born with: tier links are slots
-- now and no drag can touch them, but a LEGACY kind-less template can still
-- be somebody's deliberate parent, and a drag must not silently break that
-- either. Set Parent > in the right-click menu is the on-purpose path.
local function autoReparent(name)
    if not (draft and draft:get(name)) then return end
    local cur = draft:get(name).inherits
    if cur and draft:exists(cur) and isTemplate(cur) then return end
    local parent, moved = draft:reparentByContainment(name)
    if moved then
        setStatus(parent
            and (name .. " is inside " .. parent .. " - it now inherits from it.")
            or  (name .. " is no longer inside anything - it inherits from nothing now."), true)
    end
end

-- ---------------------------------------------------------------------------
-- Chrome
-- ---------------------------------------------------------------------------

rebuildTree = function()
    if not (ui and ui.tree and draft) then return end
    local nodes = draft:tree()
    local fam = -1
    DFKit.refillList(ui.tree, function(box)
        for i = 1, #nodes do
            local n   = nodes[i]
            local rec = draft:get(n.name)
            local nr  = rec.rects and #rec.rects or 0
            if n.depth == 0 then fam = fam + 1 end
            n.fam = fam
            n.template = (nr == 0)
            n.off = rec.fields and (rec.fields.disabled == true or rec.fields.disabled == "true")
            -- The badge is the resolved TIER - the one thing the redesign puts
            -- on every row - bright for an own slot, dim lowercase for an
            -- inherited one. "off" outranks it: a dead zone's rung is trivia.
            local tname = draft:effectiveTier(n.name)
            n.ownTier = rec.tier ~= nil
            if n.off then
                n.badge, n.ownTier = "off", true
            elseif tname then
                n.badge = n.ownTier and tname or tname:lower()
            elseif n.template then
                n.badge, n.ownTier = "template", false
            else
                n.badge = nil
            end
            n.prof = #draft:profilesOf(n.name)
            box:addItem(n.name, n)
            if n.name == selected then box.selected = box:size() end
        end
    end)
end

refreshChrome = function()
    if not (ui and draft) then return end

    local probs = draft:validate()
    local n     = select(3, draft:changeSet())
    local errs  = 0
    for _, p in ipairs(probs) do if p.level == "error" then errs = errs + 1 end end

    ui.saveBtn.enable   = (n > 0 and errs == 0)
    ui.revertBtn.enable = (n > 0)

    -- The status line is only rewritten by the things that have something to
    -- say. Left alone here it keeps the last real message instead of being
    -- overwritten by a count on every frame - but a blocking error outranks
    -- whatever was there, because Save is greyed and the reason has to be
    -- somewhere.
    if errs > 0 then
        for _, p in ipairs(probs) do
            if p.level == "error" then
                setStatus(p.zone .. ": " .. p.msg)
                break
            end
        end
    elseif n > 0 and statusMsg == "" then
        setStatus(n .. " unsaved change" .. (n == 1 and "" or "s") .. ".")
    end

    -- SHORT ENOUGH FOR THE COLUMN IT LIVES IN. ISLabel does not clip, so the
    -- old wording ("44 zones | draft rev 1, 0 changes") simply ran out over the
    -- map. The column is LEFT_W wide and that is the budget: counts as digits,
    -- the revision abbreviated, and the change count only when there ARE
    -- changes - which is also when it is worth reading.
    local bits = { #draft:names() .. " zones", "r" .. draft:revision() }
    if n > 0 then bits[#bits + 1] = n .. (n == 1 and " edit" or " edits") end
    if errs > 0 then bits[#bits + 1] = errs .. " blocking" end
    ui.counts:setName(table.concat(bits, "  -  "))
end

-- ---------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------

local function askText(title, initial, onOk)
    local player = getPlayer()
    if not player then return end
    local modal
    modal = ISTextBox:new(getCore():getScreenWidth() / 2 - 170, getCore():getScreenHeight() / 2 - 60,
        340, 120, title, initial or "", nil, function(_, btn)
            if btn.internal == "OK" and modal and modal.entry then onOk(modal.entry:getText()) end
        end, player:getPlayerNum())
    modal:initialise(); modal:addToUIManager()
end

local function addZone()
    askText("New zone name (letters, digits, _ - . only):", "", function(name)
        local ok, why = draft:create(name)
        if not ok then setStatus(why); return end
        selectZone(name)
        -- A NEW ZONE ARRIVES WITH A BOX. Creating a geometry-less record and
        -- telling the admin to ctrl-drag made Add produce a template, which is
        -- not what anyone pressing Add wanted, and left nothing on the map to
        -- grab. Longstrider's Add has always dropped a region at the view centre;
        -- this now matches it.
        local placed = editor and editor:addRectAtView(name)
        if placed then
            selectZone(name, placed)
            autoReparent(name)
            setStatus("Created " .. name .. " in the middle of the view - drag its handles"
                .. " to shape it. Ctrl-drag adds another rectangle; drawn inside another"
                .. " zone, it becomes that zone's child.", true)
        else
            setStatus("Created " .. name .. " as a template (no map available)."
                .. " Ctrl-drag on the map to give it geometry.", true)
        end
    end)
end

local function renameZone()
    if not selected then return end
    local old = selected
    askText("Rename " .. old .. " to:", old, function(name)
        local ok, moved = draft:rename(old, name)
        if not ok then setStatus(moved); return end
        selectZone(name)
        setStatus(moved > 0
            and string.format("Renamed to %s and repointed %d child zone%s.", name, moved,
                              moved == 1 and "" or "s")
            or  ("Renamed to " .. name .. "."), true)
    end)
end

local function deleteZone()
    if not selected then return end
    local name = selected
    local kids = draft:childrenOf(name)
    local msg  = "Delete zone '" .. name .. "' from the draft?"
    if #kids > 0 then
        msg = msg .. "\n\n" .. #kids .. " zone" .. (#kids == 1 and "" or "s")
            .. " inherit from it and will lose those policies: " .. table.concat(kids, ", ")
    end
    msg = msg .. "\n\nNothing leaves this machine until you press Save."
    local function go()
        draft:remove(name)
        selectZone(nil)
        setStatus("Deleted " .. name .. " from the draft. Save to apply, Revert to undo.", true)
    end
    if DFConfirm and DFConfirm.ask then DFConfirm.ask(msg, go) else go() end
end

local function toggleZone()
    if not selected then return end
    local rec = draft:get(selected)
    if not rec then return end
    local off = rec.fields and (rec.fields.disabled == true or rec.fields.disabled == "true")
    -- Cleared, not written as false: absent means inherit, and an explicit false
    -- on every zone anyone ever toggled is how a store fills with fields that
    -- say nothing (§6.1 rule 5).
    draft:setField(selected, "disabled", off and nil or true)
    setStatus(selected .. (off and " enabled" or " disabled") .. " in the draft.", true)
    LMEditView.refresh()
end

local function deleteRect()
    if not (selected and editor and editor.rectIdx) then return end
    local rec = draft:get(selected)
    if not (rec and rec.rects and #rec.rects > 0) then return end
    local idx = editor.rectIdx
    draft:removeRect(selected, idx)
    local left = #(draft:get(selected).rects or {})
    editor:setSelected(selected, left > 0 and math.min(idx, left) or nil)
    setStatus(string.format("Removed rectangle %d of %s%s.", idx, selected,
        left == 0 and " - it is a template now, with no place on the map" or ""), true)
    LMEditView.refresh()
end

frameSelected = function()
    if not (selected and editor) then return end
    if not editor:frameZone(selected) then setStatus(selected .. " has no geometry to frame.") end
end

local function revert()
    newDraft()
    setStatus("Draft discarded; back to the server's revision " .. tostring(Limes.revision) .. ".", true)
    LMEditView.refresh()
end

local function save()
    if not draft then return end
    local changed, removed, n = draft:changeSet()
    if n == 0 then setStatus("Nothing to save."); return end
    if draft:errorCount() > 0 then
        setStatus("Fix the blocking problem above first - the server would refuse this save.")
        return
    end
    local sent = LMSync.save(changed, removed, draft:revision())
    setStatus("Sent " .. sent .. " zone change" .. (sent == 1 and "" or "s")
        .. " to the server - waiting for the verdict...")
end

-- The Tiers and Profiles panels (S5/S6) edit THIS view's draft - one draft,
-- one Save, exactly as the Details view has always worked - and each carries
-- its own Save/Revert pair, so they call in here rather than owning a second
-- save path that could disagree about revisions.
LMEditView.saveDraft   = save
LMEditView.revertDraft = revert
function LMEditView.draftCounts()
    if not draft then return 0, 0 end
    local n = select(3, draft:changeSet())
    return n, draft:errorCount()
end

-- ---------------------------------------------------------------------------
-- The right-click menu - the zone's actions, where the zone is
-- ---------------------------------------------------------------------------

-- A child arrives INSIDE its parent: named first (the same grammar gate as
-- Add), pointed at the parent, and given a starter box centred in the
-- parent's largest rectangle so the relationship is visible the moment the
-- menu closes. A template parent (legacy) gets the view-centre box instead.
local function newChildZone(parent)
    askText("New child of " .. parent .. " (letters, digits, _ - . only):", "",
        function(name)
            local ok, why = draft:create(name)
            if not ok then setStatus(why); return end
            draft:setInherits(name, parent)
            local prec = draft:get(parent)
            local placed = nil
            local best, bestArea = nil, -1
            for i = 1, #(prec.rects or {}) do
                local r = prec.rects[i]
                local area = (r[3] - r[1] + 1) * (r[4] - r[2] + 1)
                if area > bestArea then best, bestArea = r, area end
            end
            if best then
                local rw = best[3] - best[1] + 1
                local rh = best[4] - best[2] + 1
                local cw = math.max(4, math.floor(rw / 3))
                local ch = math.max(4, math.floor(rh / 3))
                local x1 = best[1] + math.floor((rw - cw) / 2)
                local y1 = best[2] + math.floor((rh - ch) / 2)
                draft:addRect(name, { x1, y1, x1 + cw - 1, y1 + ch - 1 })
                placed = 1
            elseif editor then
                placed = editor:addRectAtView(name)
            end
            selectZone(name, placed)
            setStatus("Created " .. name .. " inside " .. parent
                .. " - drag its handles to shape it.", true)
        end)
end

local function duplicateZone(name)
    local rec = draft:get(name)
    if not rec then return end
    local copy = name .. "_2"
    local i = 2
    while draft:exists(copy) do i = i + 1; copy = name .. "_" .. i end
    draft:create(copy, rec)
    -- Nudged off the original so the twin is visible AND grabbable; identical
    -- geometry would be an invisible duplicate that only the tree betrays.
    local crec = draft:get(copy)
    for j = 1, #(crec.rects or {}) do
        local r = crec.rects[j]
        r[1], r[2], r[3], r[4] = r[1] + 10, r[2] + 10, r[3] + 10, r[4] + 10
    end
    selectZone(copy)
    setStatus("Duplicated " .. name .. " as " .. copy
        .. " (policies, profiles and tier carried; geometry nudged).", true)
    LMEditView.refresh()
end

local function setTierTo(name, tier)
    local ok, why = draft:setTier(name, tier)
    if not ok then setStatus(why); return end
    setStatus(tier and (name .. " stands on " .. tier .. " now.")
                    or (name .. " inherits its tier again."), true)
    LMEditView.refresh()
end

local function toggleProfileOn(name, prof)
    local have = false
    for _, p in ipairs(draft:profilesOf(name)) do
        if p == prof then have = true break end
    end
    if have then
        draft:removeProfile(name, prof)
        setStatus("Removed profile " .. prof .. " from " .. name .. ".", true)
    else
        local ok, why = draft:addProfile(name, prof)
        if not ok then setStatus(why); return end
        setStatus("Applied profile " .. prof .. " to " .. name
            .. " (later profiles beat earlier - reorder in Details).", true)
    end
    LMEditView.refresh()
end

local function setParentTo(name, parent)
    local ok, why = draft:setInherits(name, parent)
    if not ok then setStatus(why); return end
    setStatus(parent and (name .. " is a child of " .. parent .. " now.")
                     or  (name .. " is top-level now."), true)
    LMEditView.refresh()
end

-- Everything reachable by walking inherits DOWN from `name` - adopting one of
-- these as a parent would close a loop, so Set Parent > never offers them.
local function descendantsOf(name)
    local out, frontier = {}, { [name] = true }
    local moved = true
    while moved do
        moved = false
        for _, other in ipairs(draft:names()) do
            local r = draft:get(other)
            if r and r.inherits and frontier[r.inherits]
                and not frontier[other] then
                frontier[other] = true
                out[other] = true
                moved = true
            end
        end
    end
    return out
end

-- The drop half of drag-to-reparent (S4). Refusals are stated, never silent;
-- the commit goes through the same confirm shape every destructive gesture
-- in the suite uses, wording pinned to the prototype's popup.
treeDrop = function(name, target)
    if not draft then return end
    local rec, trec = draft:get(name), draft:get(target)
    if not (rec and trec) then return end
    if trec.kind ~= nil then
        setStatus(target .. " is not a place - zones can only be children of zones.")
        return
    end
    if rec.inherits == target then
        setStatus(name .. " is already a child of " .. target .. ".")
        return
    end
    if descendantsOf(name)[target] then
        setStatus("That would make " .. name .. " its own ancestor - not done.")
        return
    end
    local eff = draft:effectiveTier(target)
    local msg = "Make " .. name .. " a child of " .. target .. "?"
        .. (eff and ("\n\nIt will take " .. target .. "'s tier (" .. eff
            .. ") unless it sets its own.") or "")
        .. "\n\nNothing leaves this machine until you press Save."
    local function go()
        draft:setInherits(name, target)
        setStatus(name .. " is a child of " .. target .. " now.", true)
        LMEditView.refresh()
    end
    if DFConfirm and DFConfirm.ask then DFConfirm.ask(msg, go) else go() end
end

showZoneMenu = function(name)
    if not (draft and draft:get(name)) then return end
    local rec = draft:get(name)
    local context = ISContextMenu.get(0, getMouseX() + 8, getMouseY() + 8)

    context:addOption("Edit Details...", nil, function()
        if LMDetailsWindow and not LMDetailsWindow.instance then
            LMDetailsWindow.toggle()
        end
        -- Already open: the window follows the shared selection on its own.
    end)
    context:addOption("New Child Zone...", nil, function() newChildZone(name) end)

    -- Set Tier >: the ladder by rank, "(inherit)" first, the current OWN slot
    -- marked. Submenu idiom verified: ISContextMenu.lua:1075 (addSubMenu),
    -- :1199 (getNew); usage ISInventoryPaneContextMenu.lua:506-507.
    local tiers = {}
    for _, tn in ipairs(draft:names()) do
        local tr = draft:get(tn)
        if tr.kind == "tier" then tiers[#tiers + 1] = tn end
    end
    table.sort(tiers, function(a, b)
        local ra = tonumber(draft:get(a).fields and draft:get(a).fields.rank) or 99
        local rb = tonumber(draft:get(b).fields and draft:get(b).fields.rank) or 99
        if ra ~= rb then return ra < rb end
        return a < b
    end)
    local tierOpt = context:addOption("Set Tier", nil, nil)
    local tierSub = context:getNew(context)
    context:addSubMenu(tierOpt, tierSub)
    local inhLabel = "(inherit)"
    if rec.tier == nil then
        local eff = draft:effectiveTier(name)
        if eff then inhLabel = "(inherit: " .. eff .. ")  <" end
    end
    tierSub:addOption(inhLabel, nil, function() setTierTo(name, nil) end)
    for _, tn in ipairs(tiers) do
        local rank = draft:get(tn).fields and draft:get(tn).fields.rank
        local label = (rank and (tostring(rank) .. "  ") or "") .. tn
        if rec.tier == tn then label = label .. "  <" end
        tierSub:addOption(label, nil, function() setTierTo(name, tn) end)
    end

    -- Apply Profile >: a toggle - applied ones are marked and click off,
    -- candidates click on.
    local applied = draft:profilesOf(name)
    local cands   = draft:profileCandidates(name)
    if #applied > 0 or #cands > 0 then
        local profOpt = context:addOption("Apply Profile", nil, nil)
        local profSub = context:getNew(context)
        context:addSubMenu(profOpt, profSub)
        for _, p in ipairs(applied) do
            profSub:addOption(p .. "  <", nil, function() toggleProfileOn(name, p) end)
        end
        for _, p in ipairs(cands) do
            profSub:addOption(p, nil, function() toggleProfileOn(name, p) end)
        end
    end

    -- Set Parent >: places with geometry only, minus self and descendants.
    local desc = descendantsOf(name)
    local parentOpt = context:addOption("Set Parent", nil, nil)
    local parentSub = context:getNew(context)
    context:addSubMenu(parentOpt, parentSub)
    parentSub:addOption(rec.inherits == nil and "(top level)  <" or "(top level)",
        nil, function() setParentTo(name, nil) end)
    for _, other in ipairs(draft:names()) do
        local o = draft:get(other)
        if other ~= name and not desc[other] and o.kind == nil
            and o.rects and #o.rects > 0 then
            local label = other
            if rec.inherits == other then label = label .. "  <" end
            parentSub:addOption(label, nil, function() setParentTo(name, other) end)
        end
    end

    context:addOption("Rename...", nil, function() renameZone() end)
    context:addOption("Duplicate", nil, function() duplicateZone(name) end)

    local off = rec.fields and (rec.fields.disabled == true or rec.fields.disabled == "true")
    context:addOption(off and "Enable" or "Disable", nil, function() toggleZone() end)

    if editor and editor.rectIdx and rec.rects and #rec.rects > 0 then
        context:addOption("Delete Rectangle " .. editor.rectIdx, nil,
            function() deleteRect() end)
    end
    if rec.rects and #rec.rects > 0 then
        context:addOption("Zoom on Map", nil, function() frameSelected() end)
    end

    -- External row actions (other mods extending the Zones tab) land between
    -- ours and Delete, which stays LAST and alone - the danger slot.
    if DFRegistry and DFRegistry.addRowActions then
        DFRegistry.addRowActions(context, "limes", { name = name })
    end
    context:addOption("Delete...", nil, function() deleteZone() end)
end

-- ---------------------------------------------------------------------------
-- The DFViews contract
-- ---------------------------------------------------------------------------

function LMEditView.attach(panel)
    local player = getPlayer()
    if not player then return {} end

    local C, w = DFKit.col, {}

    -- The map. LSMap belongs to Dragonfly; Limes soft-deps on it the way the tab
    -- does. A DEDICATED cache key: an overlay hooks the widget permanently, so
    -- sharing Longstrider's instance would stack two overlays on one map.
    if LSMap and LSMap.acquire then
        map = LSMap.acquire(player, 400, 300, "limes")
        if map.parent and map.parent ~= panel then
            -- Vanilla ISUIElement.removeChild() is nil-safe when the old
            -- parent's backing object has already been torn down
            -- (ISUIElement.lua:1480-1485).
            map.parent:removeChild(map)
        end
        panel:addChild(map)
        w[#w + 1] = map

        editor = map._lmEditor
        if not editor then
            editor = LMMapEditor:new(map)
            map._lmEditor = editor
        end
        editor:hookNow()
        editor.onSelect = function(name, idx) selectZone(name, idx) end
        editor.onEdited = function(name)
            autoReparent(name)
            LMEditView.refresh()
        end

        -- No cell lattice. The engine defaults it off and LSMap no longer turns
        -- it on, but it is stated rather than assumed because it is load-bearing
        -- here: a grid over the whole map is visually the same thing as a zone
        -- rectangle, and this view's entire job is telling those apart.
        -- No guard - the claimed failure mode does not exist. setBoolean
        -- resolves the STRING through getOrDefault(name, null) and an unknown
        -- name simply fails the instanceof test: a silent no-op, no throw, no
        -- log (WorldMapRenderer.java:685-687, 697-703). And both names are
        -- live registered options in this build, consumed by the renderer
        -- (:140-141, :2027-2034). A future rename would cost us the lattice
        -- turning off, never the map.
        local api = map:getAPI()
        api:setBoolean("CellGrid",    false)
        api:setBoolean("CellGrid300", false)
    end

    local tree = TreeList:new(0, 0, 10, 10)
    tree:initialise(); tree:instantiate()
    tree.itemheight = DFKit.rowHeight()
    tree.drawBorder = true
    tree.selected   = 0
    DFKit.well(tree)
    local origTreeRender = tree.render
    tree.render = function(self_)
        if origTreeRender then origTreeRender(self_) end
        if self_:size() == 0 then
            DFKit.drawEmpty(self_, 0, 0, self_.width, self_.height, "No zones in the store")
        end
    end
    panel:addChild(tree)
    w[#w + 1] = tree

    local function btn(label, width, cb, kind, tip)
        local b = DFKit.button(panel, 0, 0, width, label, panel, cb, kind,
            tip and { tooltip = tip } or nil)
        w[#w + 1] = b
        return b
    end

    -- THE WHOLE TOOLBAR (redesign): New Zone, Share..., and the draft strip.
    -- Everything else lives on the zone, in the right-click menu.
    local addBtn = btn("New Zone", 84, addZone, "action",
        "Create a zone in the draft. Names take letters, digits, _ - and . only:"
        .. " anything else is silently lost when the server re-reads its file, so it"
        .. " is refused here instead.\n\nRight-click any zone for everything else -"
        .. " tier, profiles, parent, rename, delete.")
    local shareBtn = btn("Share...", 72, function()
            if LMImportWindow then LMImportWindow.toggle() end
        end, "action",
        "The operations window: import or export a zone setup (zones JSON), run the"
        .. " zombie census, wipe the store, or teleport to a zone - with its own"
        .. " scrollable log.")

    local saveBtn   = btn("Save to server", 118, save, "primary",
        "Send this draft's changes - and only its changes - as one command. The"
        .. " server checks nobody else saved since you started, re-validates, writes"
        .. " RFTDLimes.ini and tells every client what moved.")
    local revertBtn = btn("Revert", 64, revert, "action",
        "Throw the draft away and start again from what the server currently holds.")

    local status   = DFKit.label(panel, 0, 0, "")
    local counts   = DFKit.label(panel, 0, 0, "", C.textDim)
    for _, l in ipairs({ status, counts }) do w[#w + 1] = l end

    ui = {
        tree = tree, status = status, counts = counts,
        addBtn = addBtn, shareBtn = shareBtn,
        saveBtn = saveBtn, revertBtn = revertBtn,
    }

    -- A REBUILD IS NOT AN EXCUSE TO LOSE WORK. The deck tears this tab down
    -- and calls attach() again on EVERY roster switch, on every close/reopen,
    -- and on a font-tier change - and this line used to be an unconditional
    -- newDraft(), which silently discarded every unsaved zone the moment the
    -- admin glanced at Players and came back. That was the whole of "zones
    -- don't survive tab switching". Same policy as onShow now: only replace a
    -- draft with nothing in it to lose. The widgets are new either way; the
    -- draft was never theirs to reset.
    if not draft or not draft:isDirty() then
        newDraft()
    elseif editor then
        editor:setDraft(draft)
        editor:setSelected(selected)
    end
    rebuildTree()
    refreshChrome()
    setStatus(statusMsg, statusGood)
    return w
end

function LMEditView.layout(panel, x, y, w, h)
    if not ui then return end
    local m = DFKit.metrics
    local PAD, BTN, GAP = m.pad, m.btnH, 4

    -- One short toolbar: two buttons left, the draft strip right, the status
    -- line breathing in between. It fits the deck's minimum with room to
    -- spare now, so the old second-row wrap is gone with the buttons that
    -- forced it.
    local tx, ty = x + PAD, y + PAD
    local function place(b) b:setX(tx); b:setY(ty); tx = tx + b:getWidth() + GAP end
    place(ui.addBtn); place(ui.shareBtn)

    local saveX   = x + w - PAD - ui.saveBtn:getWidth()
    local revertX = saveX - GAP - ui.revertBtn:getWidth()
    ui.saveBtn:setX(saveX);     ui.saveBtn:setY(ty)
    ui.revertBtn:setX(revertX); ui.revertBtn:setY(ty)

    -- The status line takes whatever the row leaves, and layout() records
    -- that budget so setStatus can clip every future message to it too.
    local stX = tx + 8
    ui.status:setX(stX)
    ui.status:setY(ty + 5)
    statusW = math.max(0, revertX - GAP - stX)
    ui.status:setName(statusW > 0
        and DFKit.fitText(statusMsg, DFKit.font.small, statusW)
        or statusMsg)

    local bodyY = ty + BTN + PAD
    local bodyH = math.max(120, (y + h) - bodyY - PAD)

    -- Left column: the tree, full height, with one counts line under it. The
    -- strip under the tree is the counts glyph's height, MEASURED - the old
    -- fixed 18 was only true at the font it was tuned against, and at a larger
    -- text-size preference the counts line drew into the tree's border.
    local colX   = x + PAD
    local countH = FONT_HGT + 5
    -- No guard - the old claim missed getFontFromEnum's own double fallback:
    -- a null argument AND an unpopulated enum slot both return this.font
    -- (TextManager.java:119-125), so a "font this build does not carry" cannot
    -- NPE. The only null this.font states are pre-Init and a headless server
    -- (Init is gated on guiCommandline, GameServer.java:1359-1364) - and this
    -- is client layout code drawing a view, which cannot run in either. DFKit
    -- itself already calls this bare with the same argument (DFKit.lua:330).
    countH = getTextManager():getFontHeight(DFKit.font.small or UIFont.Small) + 5
    local treeH = math.max(80, bodyH - countH)
    DFKit.sizeList(ui.tree, colX, bodyY, LEFT_W, treeH)
    ui.counts:setX(colX)
    ui.counts:setY(bodyY + treeH + 2)

    -- Right: the map takes the rest, full height.
    local mapX = colX + LEFT_W + PAD
    local mapW = math.max(120, (x + w) - mapX - PAD)
    if map then
        map:setX(mapX); map:setY(bodyY)
        map:setMapSize(mapW, bodyH)
    end
end

-- Entering the view re-syncs with the server, but ONLY when there is nothing to
-- lose: a draft with pending edits survives a trip to Details and back, because
-- discarding an admin's work as a side effect of clicking a strip button is
-- indefensible.
function LMEditView.onShow()
    if not draft then newDraft()
    elseif not draft:isDirty() then newDraft() end
    if editor then editor:setDraft(draft); editor:setSelected(selected) end
    LMEditView.refresh()
end

-- The server's verdict, in the server's own words.
--
-- ONLY `ok` PAINTS IT GREEN. This handler used to pass good=true for every
-- notice, so "save refused: you were editing revision 0" arrived in the same
-- reassuring green as "saved: 3 zones changed" - a refusal dressed as a
-- success, on the one line an admin reads to find out whether their work
-- survived. Notices carry an explicit ok flag now; anything without one is
-- treated as a warning, because the failure modes are what this line is for
-- and an unmarked notice is far more likely to be one.
Events.OnServerCommand.Add(function(module, command, args)
    if module ~= "RFTDLimes" or command ~= "notice" then return end
    if args and args.msg and ui then setStatus(tostring(args.msg), args.ok == true) end
end)

Limes.onChanged(onStoreChanged)

return LMEditView

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
