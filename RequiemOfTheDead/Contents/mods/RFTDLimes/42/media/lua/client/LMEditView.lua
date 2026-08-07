-- SPDX-License-Identifier: GPL-3.0-or-later
-- LMEditView - "Zone Selector": the map, the zone tree, and one zone's policies.
--
-- SHAPE (§11.3, decided from the first render). Every control is in one bar
-- along the top, the Husbandry/Vehicles idiom. Nothing runs along the bottom -
-- the selection line, the help line and the reserved problem rows all went,
-- because they were a fixed strip of mostly-blank that the map was paying for.
-- The map is full height on the right. The left column is two stacked cells:
--
-- The left column is the zone TREE, full height: zones drawn inside zones are
-- children, and children display under their parent, indented, because that is
-- what they are.
--
-- THE SPLIT IS GEOMETRY vs POLICY. This tab finds a zone, draws it, shapes it
-- and says where it lives; Details says what it does. Every settable field -
-- including LMCore's own tier/priority/announce - lives on Details, so a dial
-- has exactly one home. The one exception is Disable, which is a toolbar button
-- here because it changes what the MAP means.
--
-- CONTAINMENT MAKES A CHILD, with one guard. Drop a zone inside another and it
-- adopts that zone as its parent (LMEdit:reparentByContainment). The guard is
-- for imported data: a zone whose current parent is a geometry-less TEMPLATE has
-- a deliberate link - `Riverside inherits Hard` is the tier ladder, not a
-- position - and a drag must not silently break it. So auto-reparenting applies
-- when the zone has no parent, or a parent that occupies space; a template link
-- is only changed on purpose, with the Reparent button, which says what it will
-- do before it does it.
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

-- Client-side mirror of the census switch, for the button's label only. The
-- server owns the real state; this is never read back as truth, so a rebuild
-- showing "off" while the server is still on costs a wrong caption and nothing
-- else. Not persisted, matching the server's own refusal to persist it.
local censusAuto = false

local LEFT_W  = 268
-- No split any more: the tree owns the whole left column (2026-08-05). The
-- properties form that used to sit under it moved to Details, which is now
-- "everything you can set on this zone, grouped by who owns it" - LMCore's own
-- vocabulary included. The tree is the NAVIGATION surface once zones nest, and
-- it was getting 58% of a 268px column while a form sat underneath.
local FONT_HGT   = getTextManager():getFontHeight(UIFont.Small)

local rebuildTree, refreshChrome, selectZone, frameSelected

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

    if n.name == selected then
        self:drawRect(0, y, self.width, h - 1, 0.55, 0.20, 0.35, 0.55)
    elseif alt then
        self:drawRect(0, y, self.width, h - 1, 0.18, 0.08, 0.08, 0.08)
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
    self:drawRect(x, sy, 8, 8, n.template and 0.35 or 1, c[1], c[2], c[3])
    if n.template then self:drawRectBorder(x, sy, 8, 8, 0.8, c[1], c[2], c[3]) end

    local tx = x + 14
    local ty = y + rowText(h)
    local a  = n.off and 0.45 or 1
    self:drawText(n.name, tx, ty, 0.92, 0.92, 0.92, a, UIFont.Small)

    -- The badge says what the row IS, on the right where it does not push the
    -- name around: a folder count, a rect count, "off", or nothing at all.
    local badge = n.badge
    if badge and badge ~= "" then
        local bw = getTextManager():MeasureStringX(UIFont.Small, badge)
        self:drawText(badge, self.width - bw - 8, ty, 0.62, 0.68, 0.75, a, UIFont.Small)
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
local function onStoreChanged()
    if not draft then return end
    if draft:isDirty() then
        setStatus("Another admin saved (store is now revision " .. tostring(Limes.revision)
            .. "). Your edits are against revision " .. draft:revision()
            .. " and will be refused - Revert and redo them.")
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

-- Auto-reparent after a geometry change. See the header for why a template
-- parent is left alone.
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

local function reparentNow()
    if not selected then return end
    local parent = draft:containerOf(selected)
    local cur    = draft:get(selected).inherits
    if parent == cur then
        setStatus(parent and (selected .. " already inherits from " .. parent .. ".")
                         or  (selected .. " is not inside any zone, and inherits from nothing."))
        return
    end
    draft:reparentByContainment(selected)
    setStatus(parent
        and (selected .. " now inherits from " .. parent .. " (was "
             .. (cur or "nothing") .. ").")
        or  (selected .. " now inherits from nothing (was " .. (cur or "nothing") .. ")."), true)
    LMEditView.refresh()
end

-- ---------------------------------------------------------------------------
-- Chrome
-- ---------------------------------------------------------------------------

rebuildTree = function()
    if not (ui and ui.tree and draft) then return end
    local nodes = draft:tree()
    DFKit.refillList(ui.tree, function(box)
        for i = 1, #nodes do
            local n   = nodes[i]
            local rec = draft:get(n.name)
            local nr  = rec.rects and #rec.rects or 0
            n.template = (nr == 0)
            n.off = rec.fields and (rec.fields.disabled == true or rec.fields.disabled == "true")
            if nr == 0        then n.badge = "template"
            elseif nr > 1     then n.badge = nr .. " rects"
            else                   n.badge = nil end
            if n.off then n.badge = (n.badge and (n.badge .. " - off")) or "off" end
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

    local rec = selected and draft:get(selected)
    local nr  = rec and rec.rects and #rec.rects or 0
    ui.delRectBtn.enable  = (nr > 0)
    ui.frameBtn.enable    = (nr > 0)
    ui.reparentBtn.enable = (nr > 0)
    ui.renameBtn.enable   = (selected ~= nil)
    ui.deleteBtn.enable   = (selected ~= nil)
    ui.toggleBtn.enable   = (selected ~= nil)
    if rec then
        local off = rec.fields and (rec.fields.disabled == true or rec.fields.disabled == "true")
        ui.toggleBtn:setTitle(off and "Enable" or "Disable")
    else
        ui.toggleBtn:setTitle("Disable")
    end

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
            pcall(function() map.parent:removeChild(map) end)
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
        pcall(function()
            local api = map:getAPI()
            api:setBoolean("CellGrid",    false)
            api:setBoolean("CellGrid300", false)
        end)
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

    local addBtn      = btn("Add zone", 84, addZone, "action",
        "Create a zone in the draft. Names take letters, digits, _ - and . only:"
        .. " anything else is silently lost when the server re-reads its file, so it"
        .. " is refused here instead.")
    local renameBtn   = btn("Rename", 68, renameZone, "action",
        "Rename the selected zone AND repoint every zone that inherits from it, in"
        .. " one step. Done separately the children spend the interval pointing at a"
        .. " zone that no longer exists.")
    local deleteBtn   = btn("Delete", 64, deleteZone, "danger",
        "Remove the selected zone from the draft. Nothing leaves this machine until Save.")
    local toggleBtn   = btn("Disable", 72, toggleZone, "action",
        "Turn the selected zone off without deleting it. It keeps its geometry and"
        .. " stops answering lookups.")
    local delRectBtn  = btn("Delete rect", 88, deleteRect, "action",
        "Remove the highlighted rectangle. A zone with none left is a template: it"
        .. " still exists and can still be inherited from, it just has no place on the map.")
    local frameBtn    = btn("Frame", 58, function() frameSelected() end, "action",
        "Zoom and centre on the whole selected zone, including parts of it elsewhere"
        .. " on the map.")
    local reparentBtn = btn("Reparent", 78, reparentNow, "action",
        "Point the selected zone at whatever now contains it. Runs automatically"
        .. " after a drag - EXCEPT when the current parent is a template, because"
        .. " that link is a deliberate one (a tier, not a place) and a drag must not"
        .. " silently break it. This is how you change it on purpose.")
    local importBtn   = btn("Import...", 78, function()
            if LMImportWindow then LMImportWindow.toggle() end
        end, "action",
        "Paste a PhunZones layer, wipe the store, or teleport to a zone - in a window"
        .. " with its own log, so a long import reports somewhere you can scroll and copy.")

    -- THE CENSUS PAIR. Global operations, so they sit with Import rather than
    -- with the per-zone buttons - nothing here acts on the selection.
    --
    -- They exist because zeds enforcement is SILENT by design (a corpse in a
    -- walled safe zone is worse than the spawn it replaces), which leaves no way
    -- to watch it work from inside the game. The census is that way: it counts
    -- what is actually standing in each zone, prints it next to the settings that
    -- produced it, and reconciles its own totals so the report says whether to
    -- trust it. Server log, not here - it is evidence to read beside the .ini.
    local censusBtn = btn("Census", 62, function()
            if LMSync and LMSync.printCensus then
                LMSync.printCensus(false)
                setStatus("Census requested - the report is in the server log.")
            end
        end, "action",
        "Count the zombies actually standing in every zone right now and print them"
        .. " to the SERVER log beside each zone's settings. Zones on unloaded ground"
        .. " report 'unloaded' rather than a zero they have not earned.")

    local censusAutoBtn = btn("Auto: off", 74, function()
            censusAuto = not censusAuto
            if LMSync and LMSync.setCensus then LMSync.setCensus(censusAuto) end
            pcall(function() ui.censusAutoBtn:setTitle("Auto: " .. (censusAuto and "on" or "off")) end)
        end, "action",
        "Repeat the census every ten GAME minutes. Off by default and never"
        .. " persisted: a diagnostic that survives a restart is one somebody"
        .. " forgot to turn off.")

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
        addBtn = addBtn, renameBtn = renameBtn, deleteBtn = deleteBtn, toggleBtn = toggleBtn,
        delRectBtn = delRectBtn, frameBtn = frameBtn, reparentBtn = reparentBtn,
        importBtn = importBtn, censusBtn = censusBtn, censusAutoBtn = censusAutoBtn,
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

    -- One toolbar across the top; the body is everything under it.
    local tx, ty = x + PAD, y + PAD
    local function place(b) b:setX(tx); b:setY(ty); tx = tx + b:getWidth() + GAP end
    place(ui.addBtn); place(ui.renameBtn); place(ui.deleteBtn)
    tx = tx + 8
    place(ui.toggleBtn); place(ui.delRectBtn); place(ui.frameBtn); place(ui.reparentBtn)
    tx = tx + 8
    place(ui.importBtn); place(ui.censusBtn); place(ui.censusAutoBtn)

    -- Save and Revert at the far right, away from Delete: one careless click
    -- apart and opposite in meaning. On a pane too narrow for both - the
    -- deck's minimum leaves ~650px of content and this toolbar wants ~840 -
    -- they take a SECOND row instead of landing on top of Import, which was
    -- the other half of "the toolbar falls apart when the deck is small".
    local saveX   = x + w - PAD - ui.saveBtn:getWidth()
    local revertX = saveX - GAP - ui.revertBtn:getWidth()
    local wrapped = revertX < tx + 8
    local rowY    = wrapped and (ty + BTN + GAP) or ty
    ui.saveBtn:setX(saveX);     ui.saveBtn:setY(rowY)
    ui.revertBtn:setX(revertX); ui.revertBtn:setY(rowY)

    -- The status line takes whatever its row leaves - beside the toolbar
    -- normally, beside Save/Revert on the wrapped row - and layout() records
    -- that budget so setStatus can clip every future message to it too.
    local stX = wrapped and (x + PAD) or (tx + 8)
    ui.status:setX(stX)
    ui.status:setY(rowY + 5)
    statusW = math.max(0, revertX - GAP - stX)
    ui.status:setName(statusW > 0
        and DFKit.fitText(statusMsg, DFKit.font.small, statusW)
        or statusMsg)

    local bodyY = rowY + BTN + PAD
    local bodyH = math.max(120, (y + h) - bodyY - PAD)

    -- Left column: the tree, full height, with one counts line under it. The
    -- strip under the tree is the counts glyph's height, MEASURED - the old
    -- fixed 18 was only true at the font it was tuned against, and at a larger
    -- text-size preference the counts line drew into the tree's border.
    local colX   = x + PAD
    local countH = FONT_HGT + 5
    pcall(function()
        countH = getTextManager():getFontHeight(DFKit.font.small or UIFont.Small) + 5
    end)
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
