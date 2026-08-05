-- SPDX-License-Identifier: GPL-3.0-or-later
-- LMEditView - "Zone Selector": the map, the zone tree, and one zone's policies.
--
-- SHAPE (§11.3, decided from the first render). Every control is in one bar
-- along the top, the Husbandry/Vehicles idiom. Nothing runs along the bottom -
-- the selection line, the help line and the reserved problem rows all went,
-- because they were a fixed strip of mostly-blank that the map was paying for.
-- The map is full height on the right. The left column is two stacked cells:
--
--   top     the zone TREE. Zones drawn inside zones are children, and children
--           display under their parent, indented, because that is what they are.
--   bottom  the selected zone's own policies - the ones that are true for it
--           absent any other mod. Other mods' overrides live on Details.
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

local LEFT_W  = 268
local TREE_SPLIT = 0.58   -- share of the left column the tree takes

local rebuildTree, refreshChrome, selectZone

-- ---------------------------------------------------------------------------
-- The tree widget
--
-- Drawn rather than assembled from indented strings so the depth guides survive
-- a long zone name: a name that runs past the column would otherwise take its
-- own indentation with it and the nesting would read as noise.
-- ---------------------------------------------------------------------------

local TreeList = ISScrollingListBox:derive("LMZoneTree")
local INDENT   = 12

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
    self:drawRect(x, y + 5, 8, 8, n.template and 0.35 or 1, c[1], c[2], c[3])
    if n.template then self:drawRectBorder(x, y + 5, 8, 8, 0.8, c[1], c[2], c[3]) end

    local tx = x + 14
    local a  = n.off and 0.45 or 1
    self:drawText(n.name, tx, y + 2, 0.92, 0.92, 0.92, a, UIFont.Small)

    -- The badge says what the row IS, on the right where it does not push the
    -- name around: a folder count, a rect count, "off", or nothing at all.
    local badge = n.badge
    if badge and badge ~= "" then
        local bw = getTextManager():MeasureStringX(UIFont.Small, badge)
        self:drawText(badge, self.width - bw - 8, y + 2, 0.62, 0.68, 0.75, a, UIFont.Small)
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

-- ---------------------------------------------------------------------------
-- Draft lifecycle
-- ---------------------------------------------------------------------------

local function setStatus(msg, good)
    statusMsg, statusGood = msg or "", good and true or false
    if ui and ui.status then
        ui.status:setName(statusMsg)
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

    -- The header over the properties cell names the zone and where its
    -- unset values come from, which is the one thing a form of inherited
    -- numbers cannot show by itself.
    if selected then
        local parent = rec and rec.inherits
        ui.propHead:setName(selected .. (parent and ("   <  " .. parent) or "   (no parent)"))
    else
        ui.propHead:setName("No zone selected")
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

    ui.counts:setName(string.format("%d zones   |   draft rev %d, %d change%s%s",
        #draft:names(), draft:revision(), n, n == 1 and "" or "s",
        errs > 0 and ("   |   " .. errs .. " blocking") or ""))
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
        setStatus("Created " .. name .. ". Ctrl-drag on the map to draw it; drawn inside"
            .. " another zone, it becomes that zone's child.", true)
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

local function frameZone()
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
    tree.itemheight = 18
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

    -- The properties cell: LMCore's own vocabulary only. Other mods' per-zone
    -- overrides are the Details view's whole subject, and putting them here too
    -- would give an admin two places to change one number.
    local form = LMFieldForm.new{
        owner = "LMCore",
        title = "Zone policy",
        zone  = function() return selected end,
        draft = function() return draft end,
        onChange = function() LMEditView.refresh() end,
    }
    for _, el in ipairs(form:attach(panel)) do w[#w + 1] = el end

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
    local frameBtn    = btn("Frame", 58, frameZone, "action",
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

    local saveBtn   = btn("Save to server", 118, save, "primary",
        "Send this draft's changes - and only its changes - as one command. The"
        .. " server checks nobody else saved since you started, re-validates, writes"
        .. " RFTDLimes.ini and tells every client what moved.")
    local revertBtn = btn("Revert", 64, revert, "action",
        "Throw the draft away and start again from what the server currently holds.")

    local status   = DFKit.label(panel, 0, 0, "")
    local counts   = DFKit.label(panel, 0, 0, "", C.textDim)
    local propHead = DFKit.label(panel, 0, 0, "No zone selected", C.textDim)
    for _, l in ipairs({ status, counts, propHead }) do w[#w + 1] = l end

    ui = {
        tree = tree, form = form, status = status, counts = counts, propHead = propHead,
        addBtn = addBtn, renameBtn = renameBtn, deleteBtn = deleteBtn, toggleBtn = toggleBtn,
        delRectBtn = delRectBtn, frameBtn = frameBtn, reparentBtn = reparentBtn,
        importBtn = importBtn, saveBtn = saveBtn, revertBtn = revertBtn,
    }

    newDraft()
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
    place(ui.importBtn)

    -- Save and Revert at the far right, away from Delete: one careless click
    -- apart and opposite in meaning.
    ui.saveBtn:setX(x + w - PAD - ui.saveBtn:getWidth())
    ui.saveBtn:setY(ty)
    ui.revertBtn:setX(x + w - PAD - ui.saveBtn:getWidth() - GAP - ui.revertBtn:getWidth())
    ui.revertBtn:setY(ty)

    -- The status line takes whatever the toolbar left between the buttons and
    -- Revert, so it never overruns either.
    ui.status:setX(tx + 8)
    ui.status:setY(ty + 5)

    local bodyY = ty + BTN + PAD
    local bodyH = math.max(120, (y + h) - bodyY - PAD)

    -- Left column: tree over properties, with a one-line header on the
    -- properties cell naming the zone and its parent.
    local colX  = x + PAD
    local treeH = math.floor(bodyH * TREE_SPLIT)
    DFKit.sizeList(ui.tree, colX, bodyY, LEFT_W, treeH)

    ui.counts:setX(colX)
    ui.counts:setY(bodyY + treeH + 2)

    local propY = bodyY + treeH + 20
    ui.propHead:setX(colX)
    ui.propHead:setY(propY)
    ui.form:layout(colX, propY + 18, LEFT_W, math.max(60, (bodyY + bodyH) - (propY + 18)))

    -- Right: the map takes the rest, full height.
    local mapX = colX + LEFT_W + PAD
    local mapW = math.max(120, (x + w) - mapX - PAD)
    if map then
        map:setX(mapX); map:setY(bodyY)
        map:setMapSize(mapW, bodyH)
    end
end

-- The drawn form is chrome, not widgets, so it needs a draw pass. DFViews routes
-- this to whichever view is active; the host installs the single chain.
function LMEditView.draw(el)
    if ui and ui.form then ui.form:draw(el) end
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

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= "RFTDLimes" or command ~= "notice" then return end
    if args and args.msg and ui then setStatus(tostring(args.msg), true) end
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
