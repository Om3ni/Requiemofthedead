-- SPDX-License-Identifier: GPL-3.0-or-later
-- HBAnimalsView - the Animals view behind the Husbandry tab.
--
-- NOT A TAB. This registers nothing with DFRegistry; HBHusbandryTab hosts it as
-- one of two views behind an inner strip (see DFViews). The exported table is
-- the host contract: attach / layout / draw / onShow.
--
-- TWO PANES, ONE JOB EACH (rewritten 2026-08-04):
--
--   list  |  portrait + card
--
-- The list answers ONE question - which of these needs me, and can I get there.
-- The card answers "what is wrong with this one".
--
-- THERE IS NO PROBE HERE ANY MORE. It briefly had a third pane running
-- HBAPIProbe on the selected animal, and the card made it redundant: the probe
-- existed to read stats the display could not show, and the display now shows
-- them. The probe itself is not gone - HBDebugPanel still owns it
-- (HBDebugPanel.lua:755), which is the right home for a raw API dump. An admin
-- panel should not carry a diagnostic that duplicates its own readout.
--
-- WHAT THIS REPLACED, AND WHY. The view carried a twelve-column table: OID,
-- RQHB, Species, Name, Sex, Age, HP, Hng:get, Hng:stat, Thr:get, Thr:stat,
-- Strs, Loc. Four of those columns were a live A/B of two hunger/thirst APIs,
-- amber whenever they disagreed - a question HBAPIProbe.lua:6-9 already
-- ANSWERED (stats:get is engine-authoritative) and which every writer in the
-- mod already acted on: HBKeepAlive.lua:48-49 and HBCommands.lua:91-92 both go
-- through getStats():set(). Nothing outside the probe reads getHunger() at all.
-- So the table was rendering two columns of an API we deliberately do not use
-- and colouring them for a disagreement we expect. The comparison keeps its
-- home in the probe, where an experiment belongs.
--
-- The rest went to the card because it is not scan data: OID and the RQHB id
-- are keys the machine needs and the eye does not, and sex/age/stress never
-- make you look twice while scanning. What is left - name, state, distance,
-- and a severity stripe - is what triage actually reads.

if isServer() then return end

-- DFRegistry is not consulted here at all any more; the host owns registration.

require "ISUI/ISScrollingListBox"
require "ISUI/ISButton"
require "ISUI/ISLabel"
require "ISUI/ISUI3DModel"
require "HBAnimalMenu"

local FONT       = UIFont.Code    -- data: monospace so columns and cards align
local LABEL_FONT = UIFont.Small   -- group headings

local STRIPE_W = 3     -- severity stripe down the left edge of a list row
local BAR_H    = 7     -- condition bar
local GUTTER   = 66    -- card label column
local AV_H     = 156   -- portrait pane

HBAnimalsView = HBAnimalsView or {}

local AnimalsTab = {
    rows            = {},
    listBox         = nil,
    statsLabel      = nil,
    selectedOid     = nil,
    highlightTarget = nil,  -- IsoAnimal kept lit while its row is selected
    avatar          = nil,
    avatarOid       = nil,  -- which OID the 3D panel is currently showing
    card            = nil,  -- rect the card draws into, set by layout
}

-- ─────────────────────────────────────────────────────────────────────────
-- World highlight
-- ─────────────────────────────────────────────────────────────────────────

-- World-outline pattern lifted from RPNecroTab. Outline state on the animal
-- decays when the panel stops re-asserting it each frame, so we (re)apply
-- in the list's prerender and clear when selection moves away.
--
-- setOutlineHighlight (IsoObject:5133/5154) writes a per-player array behind a
-- lazily-created FBORenderObjectOutline singleton - no guard needed, which is
-- how RQNecroTab calls it. getAnimal (LuaManager:3167) is a map lookup on
-- AnimalInstanceManager's `static final` instance (:24), so it returns nil for
-- a stale id rather than throwing.
local function clearHighlight()
    if AnimalsTab.highlightTarget then
        AnimalsTab.highlightTarget:setOutlineHighlight(false)
        AnimalsTab.highlightTarget = nil
    end
end

local function applyHighlight(oid)
    clearHighlight()
    if not oid or oid == 0 then return end
    local a = getAnimal(tonumber(oid))
    if a then AnimalsTab.highlightTarget = a end
end

-- ─────────────────────────────────────────────────────────────────────────
-- Severity - the one thing the list exists to show
-- ─────────────────────────────────────────────────────────────────────────

-- Thresholds live in HBVitals, not here. The Hutches view's occupant pane asks
-- the same question about the same animals, and two copies of "is this one in
-- trouble" would drift - a threshold that disagrees between two panels of the
-- SAME TAB is worse than either, because you stop trusting both.
--
-- A scanned row carries hp / hunger / thirst / stress under exactly the names
-- HBVitals.read produces, so severity() takes either without caring which.
local function severityOf(row) return HBVitals.severity(row) end
local function sevColor(level) return HBVitals.sevColor(level) end
local function barColor(frac, invert) return HBVitals.barColor(frac, invert) end

-- ─────────────────────────────────────────────────────────────────────────
-- Column model - three columns, and one of them is a word not a number
-- ─────────────────────────────────────────────────────────────────────────

local COLS = {
    { key = "name",  label = "Animal", w = 150 },
    { key = "state", label = "State",  w = 80,
      format = function(r) local _, why = severityOf(r); return why end,
      color  = function(r)
          local lvl = severityOf(r)
          local c = sevColor(lvl)
          if lvl <= 0 then return { 0.45, 0.45, 0.45 } end
          return { c.r, c.g, c.b }
      end },
    { key = "dist",  label = "Dist",   w = 54, align = "right",
      format = function(r) return r.dist and string.format("%d", r.dist) or "-" end,
      color  = function(r)
          if not r.dist then return { 0.45, 0.45, 0.45 } end
          return { 0.80, 0.80, 0.80 }
      end },
}

-- ─────────────────────────────────────────────────────────────────────────
-- The card - fixed gutter, constant shape, every field every time
-- ─────────────────────────────────────────────────────────────────────────

-- A field that vanishes when nil shifts everything under it, and you lose the
-- ability to flick between two animals and see what moved. That property is the
-- entire point of the card, so nothing here is conditional: a missing value
-- renders as "-" in the same place it would have rendered a number.
local CARD = {
    { group = "IDENTITY" },
    { label = "Name",    get = function(r) return r.name end },
    { label = "Species", get = function(r) return r.species end },
    { label = "Sex",     get = function(r)
        if r.sex == "F" then return "Female" end
        if r.sex == "M" then return "Male" end
        return "?"
      end },
    { label = "Age",     get = function(r) return r.age end },
    { label = "OID",     get = function(r) return tostring(r.oid or 0) end,
      dim = true },

    { group = "CONDITION" },
    { label = "Health",  bar = function(r) return (r.hp or 0) / 100 end, invert = true,
      get = function(r) return string.format("%.0f%%", r.hp or 0) end },
    { label = "Hunger",  bar = function(r) return r.hunger or 0 end,
      get = function(r) return string.format("%.2f", r.hunger or 0) end },
    { label = "Thirst",  bar = function(r) return r.thirst or 0 end,
      get = function(r) return string.format("%.2f", r.thirst or 0) end },
    { label = "Stress",  bar = function(r) return r.stress or 0 end,
      get = function(r) return string.format("%.2f", r.stress or 0) end },

    { group = "WHERE" },
    { label = "Loc",     get = function(r) return r.loc end },
    { label = "Dist",    get = function(r)
        return r.dist and string.format("%d tiles", r.dist) or "unresolved"
      end },
}

local function drawBar(el, x, y, w, frac, invert)
    frac = math.max(0, math.min(1, frac or 0))
    local c = barColor(frac, invert)
    el:drawRect(x, y, w, BAR_H, 0.20, 1, 1, 1)
    if frac > 0 then
        el:drawRect(x, y, math.floor(w * frac), BAR_H, 0.85, c.r, c.g, c.b)
    end
    el:drawRectBorder(x, y, w, BAR_H, 0.25, 1, 1, 1)
end

local function drawCard(el, row, x, y, w, h)
    local tm = getTextManager()
    local fh = tm:getFontHeight(FONT)
    local lh = tm:getFontHeight(LABEL_FONT)
    local rowH   = fh + 4
    local groupH = lh + 8
    local dim    = DFKit.col.textDim
    local txt    = DFKit.col.text
    local line   = DFKit.col.line

    local cy = y
    for _, f in ipairs(CARD) do
        if cy + rowH > y + h then break end   -- ran out of pane; stop cleanly

        if f.group then
            cy = cy + 4
            el:drawText(f.group, x, cy, dim.r, dim.g, dim.b, 0.9, LABEL_FONT)
            local lw = tm:MeasureStringX(LABEL_FONT, f.group)
            el:drawRect(x + lw + 6, cy + math.floor(lh / 2), w - lw - 6, 1,
                        0.35, line.r, line.g, line.b)
            cy = cy + groupH
        else
            el:drawText(f.label, x, cy, dim.r, dim.g, dim.b, 1, FONT)

            local value = "-"
            if row then
                local v = f.get(row)
                if v ~= nil and tostring(v) ~= "" then value = tostring(v) end
            end

            if f.bar then
                -- Bar first, value right of it: within one animal you compare
                -- the bars, and the number is there when you need the exact.
                local barW = w - GUTTER - 52
                if barW < 24 then barW = 24 end
                local frac = 0
                if row then
                    local v = f.bar(row)
                    if type(v) == "number" then frac = v end
                end
                drawBar(el, x + GUTTER, cy + math.floor((fh - BAR_H) / 2) + 1,
                        barW, frac, f.invert)
                el:drawText(value, x + GUTTER + barW + 8, cy,
                            txt.r, txt.g, txt.b, row and 1 or 0.4, FONT)
            else
                local a = row and 1 or 0.4
                local c = f.dim and dim or txt
                el:drawText(DFColumns.truncate(value, FONT, w - GUTTER),
                            x + GUTTER, cy, c.r, c.g, c.b, a, FONT)
            end
            cy = cy + rowH
        end
    end
end

-- ─────────────────────────────────────────────────────────────────────────
-- Portrait
-- ─────────────────────────────────────────────────────────────────────────

-- Derived straight from ISUI3DModel rather than ISCharacterScreenAvatar, which
-- is what vanilla's ISAnimalUI.lua:369 uses. That class adds nothing but a
-- pass-through onMouseUp and new (ISCharacterScreen.lua), and it lives in
-- XpSystem - depending on it would tie this file to that one's load order for
-- no gain. Drag-to-rotate comes free from the base class either way.
local AnimalAvatar = ISUI3DModel:derive("HBAnimalAvatar")

-- Vanilla indexes AnimalAvatarDefinition raw (ISAnimalUI.lua:622), so a modded
-- species with no entry nil-crashes vanilla's own window. We fall back instead.
local AVATAR_FALLBACK = {
    zoom = 0, xoffset = 0, yoffset = 0,
    avatarDir = IsoDirections and IsoDirections.SE or nil,
}

local function avatarDef(animalType)
    local def = AnimalAvatarDefinition and AnimalAvatarDefinition[animalType]
    return def or AVATAR_FALLBACK
end

-- Point the panel at a row's animal. Only re-seats the model when the OID
-- actually changes: setCharacter restarts the anim state, so calling it every
-- frame (or every refresh) would leave the animal permanently twitching.
local function updateAvatar(row)
    local av = AnimalsTab.avatar
    if not av then return end

    local animal
    if row and row.oid and row.oid ~= 0 then
        animal = getAnimal(tonumber(row.oid))   -- LuaManager:3167, map lookup
    end

    if not animal then
        AnimalsTab.avatarOid = nil
        av:setVisible(false)
        return
    end

    if AnimalsTab.avatarOid ~= row.oid then
        AnimalsTab.avatarOid = row.oid
        local def  = avatarDef(animal:getAnimalType())   -- IsoAnimal:1487, field
        -- getData (IsoAnimal:1185) returns the raw field, which is nil on an
        -- animal whose constructor bailed early - hence the nil-check.
        local data = animal:getData()
        local size = (data and data:getSize()) or 1

        -- Vanilla animal and hutch portraits configure the same model directly
        -- (ISAnimalUI.lua:368-376; ISHutchUI.lua:836-839).
        av:setAnimSetName(animal:GetAnimSetName())
        av:setCharacter(animal)
        av:setState("idle")
        av:setIsometric(false)
        av:setDirection(def.avatarDir or IsoDirections.S)
        -- Per-species framing that TIS already hand-tuned, scaled by the
        -- animal's own size so a calf frames like a calf.
        av:setZoom((def.zoom or 0) * size)
        av:setXOffset((def.xoffset or 0) * size)
        av:setYOffset((def.yoffset or 0) * size)
    end
    av:setVisible(true)
end

-- ─────────────────────────────────────────────────────────────────────────
-- List rendering
-- ─────────────────────────────────────────────────────────────────────────

local AnimalsList = ISScrollingListBox:derive("HBAnimalsList")

function AnimalsList:doDrawItem(y, item, alt)
    local row = item.item
    if not row then return y + self.itemheight end

    -- Compare via tonumber - getOnlineID() returns a Java short; if either
    -- side stays Java-boxed the equality fails silently and the highlight
    -- never appears even though the click handler ran.
    local sel = AnimalsTab.selectedOid
    if sel and row.oid and tonumber(sel) == tonumber(row.oid) then
        self:drawRect(0, y, self.width, self.itemheight - 1, 0.35, 0.25, 0.55, 0.85)
    elseif alt then
        self:drawRect(0, y, self.width, self.itemheight - 1, 0.18, 0.08, 0.08, 0.08)
    end
    self:drawRectBorder(0, y, self.width, self.itemheight, 0.12, 1, 1, 1)

    -- The stripe answers the list's question before any text is read.
    local lvl = severityOf(row)
    if lvl > 0 then
        local c, a = sevColor(lvl)
        self:drawRect(0, y + 1, STRIPE_W, self.itemheight - 3, a, c.r, c.g, c.b)
    end

    DFColumns.drawRow(self, COLS, row, STRIPE_W + 4, y, FONT,
                      { 0.92, 0.92, 0.92 }, 4, self.itemheight)
    return y + self.itemheight
end

local function selectRow(idx)
    local item = AnimalsTab.listBox and AnimalsTab.listBox.items[idx]
    local row  = item and item.item
    if not row then return nil end
    -- Force to Lua number so the doDrawItem equality check doesn't get tripped
    -- up by Java short vs Lua number.
    AnimalsTab.selectedOid = tonumber(row.oid) or 0
    AnimalsTab.listBox.selected = idx
    applyHighlight(AnimalsTab.selectedOid)
    updateAvatar(row)
    return row
end

function AnimalsList:onMouseDown(x, y)
    local idx = self:rowAt(x, y)
    if idx <= 0 then return end
    selectRow(idx)
end

-- Right-click a row -> vanilla's AnimalContextMenu for the underlying animal:
-- the same menu the player gets right-clicking it in the world (Feed, Water,
-- Pet, Milk, Shear, Slaughter, Add to Trailer), plus the cheat-only entries.
-- Ported from HBDebugPanel.lua:325 - which this view never had.
--
-- rowAt(), NOT hand-rolled arithmetic. HBDebugPanel computes the row as
-- `math.floor((y - self:getYScroll()) / self.itemheight) + 1` and that
-- double-subtracts the scroll: ISScrollingListBox's draw loop starts at
-- `local y = 0` (:507) and only the BACKGROUND is drawn at -getYScroll() (:485),
-- because the scroll is a Java-layer translate. Lua coords and incoming mouse
-- coords are both already content-space - which is why vanilla's own
-- onMouseDown passes the raw y straight to rowAt (:579). The hand-rolled
-- version is correct only at scroll position zero.
function AnimalsList:onRightMouseUp(x, y)
    if not self.items or #self.items == 0 then return false end
    local idx = self:rowAt(x, y)
    if idx <= 0 or idx > #self.items then return false end

    local row = selectRow(idx)
    if not row or not row.oid or row.oid == 0 then return false end

    local animal = getAnimal(row.oid)
    if not animal then return false end
    local player = getPlayer()
    if not player then return false end

    local ok, err = HBAnimalMenu.openCaretakerMenu(
        player, self:getAbsoluteX() + x, self:getAbsoluteY() + y, animal)
    if not ok then
        print("[HB] Animals right-click context menu error: " .. tostring(err))
    end
    return true
end

-- Re-assert the outline every frame while a row is selected. The engine's
-- outline flag is consumed/cleared by the render loop, so a single setter
-- call would only persist for one frame.
function AnimalsList:prerender()
    ISScrollingListBox.prerender(self)
    if AnimalsTab.highlightTarget then
        AnimalsTab.highlightTarget:setOutlineHighlight(true)
    end
end

-- No render override here. ISScrollingListBox:prerender draws every row
-- ITSELF inside a stencil it sets and clears (ISScrollingListBox.lua:505,
-- :541, scrollbar clamp :494-496), and :render draws no rows at all - it is
-- a joypad focus border (:642-647). The setStencil/render/clearStencil
-- wrapper that sat here clipped nothing; rows never could escape.

-- ─────────────────────────────────────────────────────────────────────────
-- Chrome
-- ─────────────────────────────────────────────────────────────────────────

local function selectedRow()
    if not AnimalsTab.selectedOid then return nil end
    for _, e in ipairs(AnimalsTab.rows) do
        if e.oid == AnimalsTab.selectedOid then return e end
    end
    return nil
end

-- DRAWN CHROME HAS NO VISIBILITY FLAG, which is why this is a plain function
-- the host calls rather than a prerender hook this file installs. Two views
-- sharing one panel would each chain their own prerender and BOTH draw, so the
-- hidden view's chrome would bleed through the visible one - widgets can be
-- hidden, a drawRect cannot. The host routes this to whichever view is active
-- (DFViews:draw), so the branch IS the visibility.
function HBAnimalsView.draw(el)
    DFColumns.drawHeader(el, COLS, AnimalsTab.headerX or 8, AnimalsTab.headerY or 8, FONT)

    local c = AnimalsTab.card
    if c then
        -- Frame the portrait the way vanilla frames its own (ISAnimalUI.lua:38).
        local a = AnimalsTab.avatarRect
        if a then
            el:drawRectBorder(a.x, a.y, a.w, a.h, 0.5, 0.3, 0.3, 0.3)
            if not AnimalsTab.avatarOid then
                DFKit.drawEmpty(el, a.x, a.y, a.w, a.h, "no animal selected")
            end
        end
        drawCard(el, selectedRow(), c.x, c.y, c.w, c.h)
    end
end

-- ─────────────────────────────────────────────────────────────────────────
-- Data + actions
-- ─────────────────────────────────────────────────────────────────────────

-- Everything the new columns need that scanCell does not itself produce.
-- Kept HERE rather than pushed into HBDebugPanel.buildRow because that scan is
-- shared with the standalone panel, which still wants the raw A/B fields.
local function derive(rows)
    local p = getPlayer()
    local px, py
    if p then px, py = p:getX(), p:getY() end

    for _, r in ipairs(rows) do
        -- Authoritative reads only. getHunger()/getThirst() are the OTHER API;
        -- HBAPIProbe settled which one the engine writes, and every writer in
        -- the mod goes through getStats():set(). Fall back to the getter only
        -- so a row is never blank if the stats read itself failed.
        r.hunger = r.hngB or r.hngA or 0
        r.thirst = r.thrB or r.thrA or 0

        -- getAnimal (LuaManager:3167) is a map lookup on a `static final`
        -- manager (AnimalInstanceManager:24): a stale id gives nil, not an
        -- error, and getX/getY are field reads. Distance stays nil either way.
        r.dist = nil
        if px and r.oid and r.oid ~= 0 then
            local a = getAnimal(tonumber(r.oid))
            if a then
                local ax, ay = a:getX(), a:getY()
                if ax and ay then
                    r.dist = math.floor(math.sqrt((ax - px) ^ 2 + (ay - py) ^ 2) + 0.5)
                end
            end
        end
    end
end

local function refresh()
    if not AnimalsTab.listBox then return end
    local rows = (HBDebugPanel and HBDebugPanel.scanCell) and HBDebugPanel.scanCell() or {}
    derive(rows)

    -- Nearest first. A triage list sorted by proximity puts what you can
    -- actually reach at the top; severity is already carried by the stripe.
    table.sort(rows, function(a, b)
        local da = a.dist or math.huge
        local db = b.dist or math.huge
        if da ~= db then return da < db end
        return tostring(a.name or "") < tostring(b.name or "")
    end)

    AnimalsTab.rows = rows

    -- DFKit.refillList: a bare clear() leaves the scroll height behind and
    -- addItem stacks onto it, which eventually scrolls the list off its own
    -- rows. See that function's header.
    DFKit.refillList(AnimalsTab.listBox, function(box)
        for _, row in ipairs(rows) do box:addItem("", row) end
    end)

    -- Keep the selection pointed at the same ANIMAL, not the same index - the
    -- sort above moves rows around as the admin walks.
    if AnimalsTab.selectedOid then
        local found
        for i, row in ipairs(rows) do
            if tonumber(row.oid) == tonumber(AnimalsTab.selectedOid) then found = i break end
        end
        AnimalsTab.listBox.selected = found or -1
        if not found then
            AnimalsTab.selectedOid = nil
            clearHighlight()
        end
    end
    updateAvatar(selectedRow())

    if AnimalsTab.statsLabel then
        local needy = 0
        for _, row in ipairs(rows) do
            if severityOf(row) >= 2 then needy = needy + 1 end
        end
        AnimalsTab.statsLabel:setName(string.format("%d loaded  -  %d need attention",
                                                    #rows, needy))
    end
end

local function teleportToSelected()
    local row = selectedRow()
    if not row then
        if DFFeedback then DFFeedback.bad("No animal selected.") end
        return
    end
    local animal = getAnimal(row.oid)
    if not animal then
        if DFFeedback then DFFeedback.bad("Animal no longer resolvable.") end
        return
    end
    -- getCurrentSquare (IsoMovingObject:1819) is `return this.current` and is nil
    -- for a containerised animal - the getX/getY/getZ fallback is for that, not
    -- for an error. setX/setY/setZ (IsoMovingObject:478/495/512) are field sets.
    local sq = animal:getCurrentSquare()
    local tx, ty, tz
    if sq then
        tx, ty, tz = sq:getX() + 0.5, sq:getY() + 0.5, sq:getZ()
    else
        tx, ty, tz = animal:getX(), animal:getY(), animal:getZ()
    end
    if not (tx and ty) then return end
    local p = getPlayer()
    if not p then return end
    p:setX(tx); p:setY(ty); p:setZ(tz or 0)
    if DFFeedback then
        DFFeedback.good(string.format("Teleported to %s.", row.name or row.species or "animal"))
    end
end

-- Receipts go to DFFeedback, which every other tab in the family already uses
-- and which the Console tab mirrors. They used to go to an inline log pane that
-- only existed to catch probe output; with the probe gone there was nothing
-- left for that pane to say that the toast does not.
local function refillAll()
    sendClientCommand(getPlayer(), "RFTDHusbandry", HBCmd.DEBUG_REFILL, { value = 0.0, label = "refill" })
    if DFFeedback then DFFeedback.good("Refill sent - all loaded animals to full.") end
end

-- ─────────────────────────────────────────────────────────────────────────
-- Layout
-- ─────────────────────────────────────────────────────────────────────────

-- Buttons are positioned by walking their OWN widths plus one gap, not from a
-- hardcoded offset table. The old `offs = { 0, 100, 220, ... }` was measured
-- against one font size and overlapped at every other one.
local function layout(panel, x, y, w, h)
    local m = DFKit.metrics
    local R = DFKit.layout(panel, x, y, w, h)

    local bar = R:header(m.btnH + m.pad)
    local bx  = bar.x
    for _, b in ipairs(AnimalsTab.btns or {}) do
        b:setX(bx); b:setY(bar.y)
        bx = bx + b:getWidth() + m.gap
    end

    -- list | portrait + card. The probe pane's width went to the other two
    -- rather than leaving a gap: the list can now show a full name without
    -- truncating, and the card's bars are long enough to read as bars.
    local left, mid = R:splitH(0.44, 260, 300)

    -- ── left: column header, list, count line ──────────────────────────
    -- Name column absorbs the slack so the three columns always fill the pane.
    local fixed = COLS[2].w + COLS[3].w + 8 + STRIPE_W + 8
    COLS[1].w = math.max(90, left.w - fixed)

    local ls = left:stack(0)
    local _, hy = ls:row(m.headerH)
    AnimalsTab.headerX, AnimalsTab.headerY = left.x + STRIPE_W + 4, hy

    -- Measured from the region's own BOTTOM edge, never `h - cursor`: h is a
    -- height and the cursor is absolute, so mixing them only balances while the
    -- view happens to start at y = 0. Hosted behind a view strip it does not.
    local listH = (left.y + left.h) - ls.y - (16 + m.gap)
    if listH < 60 then listH = 60 end
    DFKit.sizeList(AnimalsTab.listBox, left.x, ls.y, left.w, listH)
    ls:row(listH)
    AnimalsTab.statsLabel:setX(left.x); AnimalsTab.statsLabel:setY(ls.y)

    -- ── middle: portrait over card ─────────────────────────────────────
    local avH = math.min(AV_H, math.floor(mid.h * 0.42))
    local av  = AnimalsTab.avatar
    if av then
        av:setX(mid.x);     av:setY(mid.y)
        av:setWidth(mid.w); av:setHeight(avH)
    end
    AnimalsTab.avatarRect = { x = mid.x, y = mid.y, w = mid.w, h = avH }
    AnimalsTab.card = {
        x = mid.x, y = mid.y + avH + m.pad,
        w = mid.w, h = mid.h - avH - m.pad,
    }
end

-- ─────────────────────────────────────────────────────────────────────────
-- Host contract
-- ─────────────────────────────────────────────────────────────────────────

-- Builds every widget ONCE into the host's panel and hands back a flat list;
-- the host toggles visibility on it and never asks what any of them are.
-- Deliberately does NOT lay out or refresh - the host owns layout, and onShow
-- owns the first scan, so entering the view is what reads the world rather
-- than constructing it.
function HBAnimalsView.attach(panel)
    AnimalsTab.selectedOid = nil
    AnimalsTab.avatarOid   = nil
    clearHighlight()

    -- Three buttons, down from seven. "Starve all" set every animal's hunger to
    -- 0.9 to prove the write path worked - a debugging tool that could wreck a
    -- live herd. "Probe", "Clear log" and "Copy log" all served the probe pane
    -- that the card replaced. Everything the right-click menu already does
    -- (feed, water, milk, shear, slaughter, set age) is not duplicated here.
    AnimalsTab.btns = {
        DFKit.button(panel, 0, 0, 90,  "Refresh",     panel, refresh),
        DFKit.button(panel, 0, 0, 110, "Teleport to", panel, teleportToSelected),
        DFKit.button(panel, 0, 0, 100, "Refill all",  panel, refillAll),
    }

    local list = AnimalsList:new(0, 0, 10, 10)
    list.itemheight = DFKit.metrics.rowH
    list.drawBorder = true
    DFKit.well(list)
    list:initialise(); list:instantiate()
    panel:addChild(list)
    AnimalsTab.listBox = list

    local av = AnimalAvatar:new(0, 0, 10, 10)
    av:initialise(); av:instantiate()
    av:setVisible(false)
    panel:addChild(av)
    AnimalsTab.avatar = av

    AnimalsTab.statsLabel = DFKit.label(panel, 0, 0, "0 loaded")

    -- APPENDED, never a table constructor. A nil in the middle of a literal
    -- truncates ipairs at the hole and every widget after it would silently
    -- never be shown or hidden again.
    local widgets = {}
    local function keep(wdg) if wdg then widgets[#widgets + 1] = wdg end end
    for _, b in ipairs(AnimalsTab.btns) do keep(b) end
    keep(AnimalsTab.listBox); keep(AnimalsTab.avatar); keep(AnimalsTab.statsLabel)
    return widgets
end

HBAnimalsView.layout = layout

-- Entering the view rescans. The cell's animals change while you are looking at
-- the other view, so a snapshot taken at build time would be stale by the time
-- anybody came back to it.
--
-- DFViews runs the setVisible pass BEFORE onShow (DFViews.lua:118-141), so the
-- refresh here gets the last word on the portrait: the host's blanket
-- setVisible(true) would otherwise leave an empty 3D pane showing when nothing
-- is selected.
function HBAnimalsView.onShow()
    refresh()
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
