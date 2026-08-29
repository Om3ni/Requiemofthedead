-- SPDX-License-Identifier: GPL-3.0-or-later
-- HBHutchesView - the Hutches view behind the Husbandry tab.
--
-- NOT A TAB. HBHusbandryTab hosts this as one of two views behind an inner
-- strip; see HBAnimalsView's header for why the pair was merged. The exported
-- table is the host contract (DFViews): attach / layout / draw / onShow.
--
-- THREE PANES, same shape as Animals (2026-08-04):
--
--   list | portrait + card | occupants
--
-- WHY A PORTRAIT WORKS HERE, AND WHY IT IS NOT THE SAME MECHANISM AS ANIMALS.
-- An animal is a skinned 3D character, so that view hands an IsoAnimal to a
-- UI3DModel and gets a live render. A hutch is a plain IsoObject and renders
-- from SPRITES - verified, not assumed:
--
--   * IsoObject.render() (:3389) calls renderModel() and RETURNS EARLY if it
--     succeeds, so a modelled tile never draws its sprite. Model and sprite are
--     alternatives, never layers.
--   * renderModel() (:5762) returns false unless getSpriteModel() is non-null,
--     which resolves through IsoSprite.spriteModel, which is populated from
--     exactly one file: media/spriteModels.txt. That file binds tilesets like
--     appliances_radio_01 - and contains ZERO farm_accesories entries. Every
--     hutch tile is location_farm_accesories_01_*.
--
-- So: hutches are sprites, and the picture is a sprite composite.
--
-- IT IS A COMPOSITE because a coop is not one tile. entity_chickenhutch.txt
-- lays ChickenHutch out as a 2x2 (rows "41 43" / "50 42"), so one
-- getTextureForCurrentFrame gives you a QUARTER of a coop. We rebuild the whole
-- thing from getAllHutchObjects(), which walks the 5x5 around the master and
-- collects every tile of THIS hutch - def-free, so it works for modded coops
-- that HutchDefinitions knows nothing about.

if isServer() then return end

require "ISUI/ISScrollingListBox"
require "ISUI/ISButton"
require "ISUI/ISLabel"

local FONT       = UIFont.Code
local LABEL_FONT = UIFont.Small

local SCAN_RANGE = 20   -- ±squares around the player (matches HBKeepAlive)
local STRIPE_W   = 3
local BAR_H      = 7
local GUTTER     = 78
local PIC_H      = 150

-- Animals stop healing at/above this much dirt - the number the whole Dirt and
-- Nest display exists to keep you under.
local DIRT_LIMIT = 20

HBHutchesView = HBHutchesView or {}

local HutchesTab = {
    rows        = {},
    listBox     = nil,
    occBox      = nil,
    statsLabel  = nil,
    selectedKey = nil,   -- "x,y,z" of the selected hutch row
    picKey      = nil,   -- which hutch the sprite composite was built for
    picParts    = nil,
}

-- ─────────────────────────────────────────────────────────────────────────
-- Live reads (row.hutch is a live IsoHutch ref captured at scan time)
-- ─────────────────────────────────────────────────────────────────────────

-- Read via HBBedding.getStatus, which prefers the synced ModData mirror over
-- the native hutchDirt field (the latter isn't replicated to dedicated-server
-- clients). Falls back to zeros if HBBedding isn't present.
local function status(hutch)
    if HBBedding and HBBedding.getStatus then return HBBedding.getStatus(hutch) end
    return { dirt = 0, nbDirt = 0, bedding = 0, max = 100 }
end
local function liveDirt(hutch)     return status(hutch).dirt end
local function liveNestDirt(hutch) return status(hutch).nbDirt end
local function liveBedding(hutch)  return status(hutch).bedding end
local function beddingMax()        return (HBBedding and HBBedding.MAX) or 100 end

-- CAPACITY IS THE ONE THING THAT CAN THROW HERE. getMaxAnimals() and
-- getMaxNestBox() both do `this.def.rawgetInt(...)` with NO null guard
-- (IsoHutch.java:910-922), and def is null for any hutch the definitions do not
-- cover. That native NPE escapes Lua's pcall, so it must surface; the numeric
-- checks below still retain the UI's ordinary unknown-capacity presentation.
local function maxAnimals(hutch)
    local n = hutch:getMaxAnimals()
    if type(n) == "number" and n > 0 then return n end
    return nil
end

-- Vanilla's own comment: "zero-based counting, max=3 means 4 boxes :-("
-- (ISHutchUI.lua:238). getMaxNestBox() is a max INDEX, unlike getMaxAnimals()
-- which ISHutchMenu.lua:57 uses as an exclusive bound, i.e. a count.
local function nestBoxCount(hutch)
    local n = hutch:getMaxNestBox()
    if type(n) == "number" and n >= 0 then return n + 1 end
    return nil
end

-- Occupants. getAnimalInside():size() is the exact count (the HashMap is
-- reachable from Lua - ISHutchMenu.lua:57 does exactly this), but ENUMERATING
-- needs the indexed getter: positions are assigned Rand.Next(0, maxAnimals)
-- (IsoHutch.java:688) so they are sparse, and a Java HashMap does not iterate
-- cleanly through Kahlua. 0..63 is a safe superset of any real capacity.
local function occupantCount(hutch)
    return hutch:getAnimalInside():size() or 0
end

local function eachOccupant(hutch, fn)
    for pos = 0, 63 do
        local a = hutch:getAnimal(pos)
        if a then fn(a, pos) end
    end
end

-- Dead animals left inside are exactly the kind of thing an admin wants to
-- know about and nothing in the game tells them.
local function deadCount(hutch)
    local n = 0
    for pos = 0, 63 do
        if hutch:getDeadBody(pos) then n = n + 1 end
    end
    return n
end

-- Nest boxes: eggs and any sitting hen.
-- getNestBox(i) returns the inner NestBox, whose getEggsNb() is a METHOD so it
-- is reachable; its `animal` is a public INSTANCE FIELD and is not, which is
-- why the occupant comes from getAnimalInNestBox(i) - a method on the hutch
-- that does the field read on the Java side.
-- getNestBox (IsoHutch:961) and getAnimalInNestBox (:954) are HashMap.get on a
-- final map created at its declaration (:71), and NestBox.getEggsNb (:1035) is
-- eggs.size() on a list the NestBox constructor allocates - none of the three
-- touches the hutch def, so none can throw. Only the CAPACITY read above can.
local function nestSurvey(hutch)
    local boxes, eggs, sitting = nestBoxCount(hutch), 0, 0
    local used = 0
    for i = 0, (boxes and boxes - 1 or 15) do
        local nb = hutch:getNestBox(i)
        if nb then
            local n = nb:getEggsNb()
            if type(n) == "number" and n > 0 then eggs = eggs + n; used = used + 1 end
        end
        if hutch:getAnimalInNestBox(i) then sitting = sitting + 1 end
    end
    return { boxes = boxes, eggs = eggs, used = used, sitting = sitting }
end

-- isOpen (IsoHutch:616), isAllDoorClosed (:985) and isEggHatchDoorOpen (:942)
-- are field reads. haveEggHatchDoor (:938) is NOT - it reads
-- this.def.rawgetStr("openHatchSprite"), and def is null for any hutch the
-- definitions do not cover, which is the engine-internal NPE this file's header
-- describes. That native failure escapes Lua's pcall, so it must surface rather
-- than pretending this renderer can turn it into a "none" hatch state.
local function doorState(hutch)
    if hutch:isOpen() then return "open" end
    if hutch:isAllDoorClosed() then return "closed" end
    return "?"
end

local function hatchState(hutch)
    if not hutch:haveEggHatchDoor() then return "none" end
    return hutch:isEggHatchDoorOpen() and "open" or "closed"
end

-- ─────────────────────────────────────────────────────────────────────────
-- Severity - what the stripe and State column read
-- ─────────────────────────────────────────────────────────────────────────

-- A hutch is "in trouble" for reasons of its own (filth, no bedding) AND for
-- its occupants' reasons. Both belong in one verdict, because an admin scanning
-- the list is asking one question: which of these do I have to walk to.
local function hutchSeverity(row)
    local worst, why = 0, ""
    local function bid(level, reason)
        if level > worst then worst, why = level, reason end
    end
    local h = row.hutch
    if not h then return 0, "" end

    local dirt = liveDirt(h)
    if dirt >= DIRT_LIMIT * 2 then bid(3, "filthy") elseif dirt >= DIRT_LIMIT then bid(2, "dirty") end

    local nest = liveNestDirt(h)
    if nest >= DIRT_LIMIT * 2 then bid(3, "nest foul") elseif nest >= DIRT_LIMIT then bid(2, "nest dirty") end

    if (row.animals or 0) > 0 and liveBedding(h) <= 0 then bid(2, "no bedding") end
    if (row.dead or 0) > 0 then bid(3, "dead inside") end

    -- Worst occupant, via the shared thresholds. See HBVitals' header for why
    -- this is not re-implemented here.
    if (row.occWorst or 0) >= 2 then bid(row.occWorst, row.occWhy or "animal") end

    return worst, why
end

-- ─────────────────────────────────────────────────────────────────────────
-- Column model
-- ─────────────────────────────────────────────────────────────────────────

local COLS = {
    { key = "label", label = "Hutch", w = 150,
      format = function(r) return string.format("%d, %d", r.x or 0, r.y or 0) end },
    { key = "state", label = "State", w = 88,
      format = function(r) local _, why = hutchSeverity(r); return why end,
      color  = function(r)
          local lvl = hutchSeverity(r)
          if lvl <= 0 then return { 0.45, 0.45, 0.45 } end
          local c = HBVitals.sevColor(lvl)
          return { c.r, c.g, c.b }
      end },
    { key = "anim",  label = "In", w = 40, align = "right",
      format = function(r)
          local cap = r.cap
          if cap then return string.format("%d/%d", r.animals or 0, cap) end
          return tostring(r.animals or 0)
      end },
    { key = "dist",  label = "Dist", w = 46, align = "right",
      format = function(r) return string.format("%d", r.dist or 0) end },
}

-- ─────────────────────────────────────────────────────────────────────────
-- The portrait: composite the hutch's tile sprites
-- ─────────────────────────────────────────────────────────────────────────

-- Collect every tile of this hutch as { tex, dx, dy }, relative to the master
-- square. getAllHutchObjects() is the def-free route - it walks the 5x5 around
-- the master and asks each square for ITS hutch tiles (IsoHutch.java:858-869),
-- so a modded coop of any shape comes back whole.
local function collectParts(row)
    local parts = {}
    local h = row and row.hutch
    if not h then return parts end

    -- A detached hutch's native square failure is not recoverable through Lua
    -- pcall. For a live hutch, the bounded list and sprite getter are direct;
    -- missing square, sprite, or texture is ordinary nil control flow.
    local all = h:getAllHutchObjects()
    if not all then return parts end
    local n = all:size() or 0
    for i = 0, n - 1 do
        local o = all:get(i)
        if o then
            local sq = o:getSquare()
            local sp = o:getSprite()
            if sq and sp then
                local tex = sp:getTextureForCurrentFrame(IsoDirections.N)
                if tex then
                    parts[#parts + 1] = {
                        tex = tex,
                        dx  = sq:getX() - row.x,
                        dy  = sq:getY() - row.y,
                    }
                end
            end
        end
    end

    -- Back to front, or the near tiles get painted over by the far ones.
    table.sort(parts, function(a, b) return (a.dx + a.dy) < (b.dx + b.dy) end)
    return parts
end

local function partsFor(row)
    if not row then return nil end
    if HutchesTab.picKey ~= row.key then
        HutchesTab.picKey   = row.key
        HutchesTab.picParts = collectParts(row)
    end
    return HutchesTab.picParts
end

-- Standard PZ isometric placement: one tile step east is (+w/2, +w/4) on
-- screen, one step south is (-w/2, +w/4). Everything is measured off the
-- texture's own width so this does not care about tile scale.
local function drawPortrait(el, row, x, y, w, h)
    el:drawRectBorder(x, y, w, h, 0.5, 0.3, 0.3, 0.3)

    local parts = partsFor(row)
    if not parts or #parts == 0 then
        DFKit.drawEmpty(el, x, y, w, h,
            row and "no sprite for this hutch" or "no hutch selected")
        return
    end

    -- Lay the composite out in its own space first, then fit it to the pane.
    local minX, minY, maxX, maxY
    for _, p in ipairs(parts) do
        local tw, th = p.tex:getWidth(), p.tex:getHeight()
        if not (tw and th and tw > 0 and th > 0) then return end
        p.sx = (p.dx - p.dy) * (tw / 2)
        p.sy = (p.dx + p.dy) * (tw / 4)
        p.tw, p.th = tw, th
        minX = math.min(minX or p.sx, p.sx);           minY = math.min(minY or p.sy, p.sy)
        maxX = math.max(maxX or p.sx + tw, p.sx + tw); maxY = math.max(maxY or p.sy + th, p.sy + th)
    end
    if not minX then return end

    local cw, ch = maxX - minX, maxY - minY
    if cw <= 0 or ch <= 0 then return end

    local pad   = 8
    local scale = math.min((w - pad * 2) / cw, (h - pad * 2) / ch)
    if scale > 1 then scale = 1 end   -- never upscale; tile art blurs badly

    local ox = x + (w - cw * scale) / 2 - minX * scale
    local oy = y + (h - ch * scale) / 2 - minY * scale

    for _, p in ipairs(parts) do
        el:drawTextureScaled(p.tex, ox + p.sx * scale, oy + p.sy * scale,
                             p.tw * scale, p.th * scale, 1)
    end
end

-- ─────────────────────────────────────────────────────────────────────────
-- The card
-- ─────────────────────────────────────────────────────────────────────────

-- Constant shape: every field renders every time, so flicking between two
-- hutches shows you what MOVED rather than what re-flowed.
local CARD = {
    { group = "HUTCH" },
    { label = "At",   get = function(r) return string.format("%d, %d  (z%d)", r.x, r.y, r.z or 0) end },
    { label = "Dist", get = function(r) return string.format("%d tiles", r.dist or 0) end },
    { label = "Tiles", get = function(r) return tostring(r.tiles or 1) end, dim = true },

    { group = "UPKEEP" },
    { label = "Dirt",    bar = function(r) return math.min(1, liveDirt(r.hutch) / 100) end,
      get = function(r) return string.format("%.0f", liveDirt(r.hutch)) end },
    { label = "Nest",    bar = function(r) return math.min(1, liveNestDirt(r.hutch) / 100) end,
      get = function(r) return string.format("%.0f", liveNestDirt(r.hutch)) end },
    { label = "Bedding", bar = function(r) return liveBedding(r.hutch) / beddingMax() end,
      invert = true,
      get = function(r)
          return string.format("%d%%",
              math.floor((liveBedding(r.hutch) / beddingMax()) * 100 + 0.5))
      end },

    { group = "OCCUPANCY" },
    { label = "Animals", get = function(r)
        if r.cap then return string.format("%d / %d", r.animals or 0, r.cap) end
        return string.format("%d  (capacity unknown)", r.animals or 0)
      end },
    { label = "Nests",  get = function(r)
        local n = r.nest or {}
        if n.boxes then return string.format("%d / %d in use", n.used or 0, n.boxes) end
        return string.format("%d in use", n.used or 0)
      end },
    { label = "Eggs",   get = function(r) return tostring((r.nest or {}).eggs or 0) end },
    { label = "Sitting", get = function(r) return tostring((r.nest or {}).sitting or 0) end },
    { label = "Dead",   get = function(r) return tostring(r.dead or 0) end },

    { group = "STATE" },
    { label = "Doors", get = function(r) return doorState(r.hutch) end },
    { label = "Hatch", get = function(r) return hatchState(r.hutch) end },
}

local function drawBar(el, x, y, w, frac, invert)
    frac = math.max(0, math.min(1, frac or 0))
    local c = HBVitals.barColor(frac, invert)
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
    local rowH, groupH = fh + 4, lh + 8
    local dim, txt, line = DFKit.col.textDim, DFKit.col.text, DFKit.col.line

    local cy = y
    for _, f in ipairs(CARD) do
        if cy + rowH > y + h then break end

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
                local c = f.dim and dim or txt
                el:drawText(DFColumns.truncate(value, FONT, w - GUTTER),
                            x + GUTTER, cy, c.r, c.g, c.b, row and 1 or 0.4, FONT)
            end
            cy = cy + rowH
        end
    end
end

-- ─────────────────────────────────────────────────────────────────────────
-- List rendering
-- ─────────────────────────────────────────────────────────────────────────

local HutchList = ISScrollingListBox:derive("HBHutchList")

function HutchList:doDrawItem(y, item, alt)
    local row = item.item
    if not row then return y + self.itemheight end

    if HutchesTab.selectedKey and row.key == HutchesTab.selectedKey then
        self:drawRect(0, y, self.width, self.itemheight - 1, 0.35, 0.25, 0.55, 0.85)
    elseif alt then
        self:drawRect(0, y, self.width, self.itemheight - 1, 0.18, 0.08, 0.08, 0.08)
    end
    self:drawRectBorder(0, y, self.width, self.itemheight, 0.12, 1, 1, 1)

    local lvl = hutchSeverity(row)
    if lvl > 0 then
        local c, a = HBVitals.sevColor(lvl)
        self:drawRect(0, y + 1, STRIPE_W, self.itemheight - 3, a, c.r, c.g, c.b)
    end

    DFColumns.drawRow(self, COLS, row, STRIPE_W + 4, y, FONT,
                      { 0.92, 0.92, 0.92 }, 4, self.itemheight)
    return y + self.itemheight
end

local function selectedRow()
    if not HutchesTab.selectedKey then return nil end
    for _, r in ipairs(HutchesTab.rows) do
        if r.key == HutchesTab.selectedKey then return r end
    end
    return nil
end

local refillOccupants   -- forward decl; defined with the occupant pane below

function HutchList:onMouseDown(x, y)
    local idx = self:rowAt(x, y)
    if idx <= 0 then return end
    local item = self.items[idx]
    if item and item.item then
        HutchesTab.selectedKey = item.item.key
        self.selected = idx
        refillOccupants()
    end
end

-- No render override here. ISScrollingListBox:prerender draws every row
-- ITSELF inside a stencil it sets and clears (ISScrollingListBox.lua:505,
-- :541, scrollbar clamp :494-496), and :render draws no rows at all - it is
-- a joypad focus border (:642-647). The setStencil/render/clearStencil
-- wrapper that sat here clipped nothing; rows never could escape.

-- ─────────────────────────────────────────────────────────────────────────
-- Occupant pane - what is actually inside the selected hutch
-- ─────────────────────────────────────────────────────────────────────────

local OccList = ISScrollingListBox:derive("HBHutchOccList")

function OccList:doDrawItem(y, item, alt)
    local e = item.item
    if not e then return y + self.itemheight end
    if alt then self:drawRect(0, y, self.width, self.itemheight - 1, 0.18, 0.08, 0.08, 0.08) end

    if e.kind == "head" then
        local d = DFKit.col.textDim
        self:drawText(e.text, 4, y + 2, d.r, d.g, d.b, 0.9, LABEL_FONT)
        return y + self.itemheight
    end

    if e.kind == "animal" then
        local lvl = HBVitals.severity(e.vitals)
        local c, a = HBVitals.sevColor(lvl)
        if lvl > 0 then self:drawRect(0, y + 1, STRIPE_W, self.itemheight - 3, a, c.r, c.g, c.b) end
        self:drawText(DFColumns.truncate(e.text, FONT, self.width - 100),
                      STRIPE_W + 6, y + 2, 0.92, 0.92, 0.92, 1, FONT)
        local rightX = self.width - 92
        if lvl > 0 then
            self:drawText(e.why, rightX, y + 2, c.r, c.g, c.b, 1, FONT)
        else
            self:drawText("ok", rightX, y + 2, 0.45, 0.45, 0.45, 1, FONT)
        end
        return y + self.itemheight
    end

    self:drawText(e.text, STRIPE_W + 6, y + 2, 0.80, 0.80, 0.80, 1, FONT)
    return y + self.itemheight
end

-- No render override here. ISScrollingListBox:prerender draws every row
-- ITSELF inside a stencil it sets and clears (ISScrollingListBox.lua:505,
-- :541, scrollbar clamp :494-496), and :render draws no rows at all - it is
-- a joypad focus border (:642-647). The setStencil/render/clearStencil
-- wrapper that sat here clipped nothing; rows never could escape.

-- NOTE THE GAP: there is no getter for animalOutside. IsoHutch exposes
-- addAnimalOutside() but nothing to read the list back (it is a public instance
-- field, which Kahlua does not surface), so "animals that belong to this hutch
-- but are currently out" is not something this pane can honestly show. What is
-- listed is what is INSIDE.
refillOccupants = function()
    local box = HutchesTab.occBox
    if not box then return end
    local row = selectedRow()

    DFKit.refillList(box, function(b)
        if not row or not row.hutch then
            b:addItem("", { kind = "note", text = "no hutch selected" })
            return
        end
        local h = row.hutch

        b:addItem("", { kind = "head", text = "INSIDE" })
        local any = false
        eachOccupant(h, function(a, pos)
            any = true
            local v = HBVitals.read(a)
            local _, why = HBVitals.severity(v)
            b:addItem("", {
                kind = "animal", vitals = v, why = why,
                text = string.format("%-2d  %s", pos, HBVitals.nameOf(a)),
            })
        end)
        if not any then b:addItem("", { kind = "note", text = "     empty" }) end

        local n = row.nest or {}
        b:addItem("", { kind = "head", text = "NEST BOXES" })
        if (n.boxes or 0) > 0 then
            for i = 0, n.boxes - 1 do
                -- See nestSurvey: getNestBox / getEggsNb / getAnimalInNestBox are
                -- all def-free map and list reads.
                local eggs, sitter = 0, nil
                local nb = h:getNestBox(i)
                if nb then eggs = nb:getEggsNb() or 0 end
                local a = h:getAnimalInNestBox(i)
                if a then sitter = HBVitals.nameOf(a) end
                b:addItem("", { kind = "note", text = string.format(
                    "%-2d  %d egg%s%s", i, eggs, eggs == 1 and "" or "s",
                    sitter and ("  <- " .. sitter) or "") })
            end
        else
            b:addItem("", { kind = "note", text = "     none" })
        end

        if (row.dead or 0) > 0 then
            b:addItem("", { kind = "head", text = "DEAD" })
            b:addItem("", { kind = "note", text = string.format(
                "     %d body/bodies left inside", row.dead) })
        end
    end)
end

-- ─────────────────────────────────────────────────────────────────────────
-- Chrome
-- ─────────────────────────────────────────────────────────────────────────

-- Called by the host for the ACTIVE view only. Drawn chrome has no visibility
-- flag, so two views chaining their own prerender onto one shared panel would
-- both draw and the hidden header would bleed through. See HBAnimalsView.draw.
function HBHutchesView.draw(el)
    DFColumns.drawHeader(el, COLS, HutchesTab.headerX or 8, HutchesTab.headerY or 8, FONT)

    local p = HutchesTab.picRect
    if p then drawPortrait(el, selectedRow(), p.x, p.y, p.w, p.h) end

    local c = HutchesTab.card
    if c then drawCard(el, selectedRow(), c.x, c.y, c.w, c.h) end

    local o = HutchesTab.occHdr
    if o then
        local d, ln = DFKit.col.textDim, DFKit.col.line
        el:drawText("CONTENTS", o.x, o.y, d.r, d.g, d.b, 0.9, LABEL_FONT)
        local lw = getTextManager():MeasureStringX(LABEL_FONT, "CONTENTS")
        el:drawRect(o.x + lw + 6, o.y + 7, o.w - lw - 6, 1, 0.35, ln.r, ln.g, ln.b)
    end
end

-- ─────────────────────────────────────────────────────────────────────────
-- Scan: walk grid squares around the player and collect loaded hutches.
-- ─────────────────────────────────────────────────────────────────────────

local function scanHutches()
    local rows = {}
    local cell = getCell()
    local player = getPlayer()
    if not cell or not player then return rows end

    local sq = player:getCurrentSquare()
    if not sq then return rows end
    local px, py, pz = sq:getX(), sq:getY(), sq:getZ()
    local seen = {}

    for dx = -SCAN_RANGE, SCAN_RANGE do
        for dy = -SCAN_RANGE, SCAN_RANGE do
            -- A cold coordinate returns nil directly (IsoCell.java:2800-2818),
            -- so the scan handles the loaded-edge case as ordinary control flow.
            local s = cell:getGridSquare(px + dx, py + dy, pz)
            if s then
                local objs = s:getObjects()
                if objs then
                    for k = 0, objs:size() - 1 do
                        local obj = objs:get(k)
                        if obj and instanceof(obj, "IsoHutch") then
                            -- Skip slave halves of multi-tile coops; they share the
                            -- master's square (→ duplicate rows) and hold no real
                            -- dirt/animals. isSlave (IsoHutch:827) is
                            -- `linkedX > 0 && linkedY > 0` - two field reads.
                            local slave = obj:isSlave()
                            local key = tostring(obj)
                            if not slave and not seen[key] then
                                seen[key] = true
                                local hx, hy, hz = s:getX(), s:getY(), s:getZ()

                            -- Worst occupant, computed once per scan rather than
                            -- per frame: the stripe needs it and walking 64 slots
                            -- inside doDrawItem would do it for every visible row
                            -- of every frame.
                            local worst, why = 0, ""
                            eachOccupant(obj, function(a)
                                local lvl, w = HBVitals.severity(HBVitals.read(a))
                                if lvl > worst then worst, why = lvl, w end
                            end)

                            -- A valid scanned hutch has a live square; an absent
                            -- collection still presents as one master tile.
                            local tiles = 1
                            local all = obj:getAllHutchObjects()
                            if all then tiles = all:size() or 1 end

                                rows[#rows + 1] = {
                                    key      = string.format("%d,%d,%d", hx, hy, hz),
                                    hutch    = obj,
                                    x = hx, y = hy, z = hz,
                                    animals  = occupantCount(obj),
                                    cap      = maxAnimals(obj),
                                    dead     = deadCount(obj),
                                    nest     = nestSurvey(obj),
                                    tiles    = tiles,
                                    occWorst = worst,
                                    occWhy   = why,
                                    dist     = math.max(math.abs(dx), math.abs(dy)),
                                }
                            end
                        end
                    end
                end
            end
        end
    end

    table.sort(rows, function(a, b) return (a.dist or 0) < (b.dist or 0) end)
    return rows
end

-- ─────────────────────────────────────────────────────────────────────────
-- Data + actions
-- ─────────────────────────────────────────────────────────────────────────

local function refresh()
    if not HutchesTab.listBox then return end
    local rows = scanHutches()
    HutchesTab.rows = rows

    DFKit.refillList(HutchesTab.listBox, function(box)
        for _, row in ipairs(rows) do box:addItem("", row) end
    end)

    -- Keep the selection on the same HUTCH, not the same index.
    if HutchesTab.selectedKey then
        local found
        for i, row in ipairs(rows) do
            if row.key == HutchesTab.selectedKey then found = i break end
        end
        HutchesTab.listBox.selected = found or -1
        if not found then HutchesTab.selectedKey = nil end
    end

    -- The composite is keyed on the selection, and the IsoHutch refs are fresh
    -- after a rescan - drop it so the next draw rebuilds against live objects.
    HutchesTab.picKey = nil
    refillOccupants()

    if HutchesTab.statsLabel then
        local needy = 0
        for _, row in ipairs(rows) do
            if hutchSeverity(row) >= 2 then needy = needy + 1 end
        end
        HutchesTab.statsLabel:setName(string.format("%d hutches near you  -  %d need attention",
                                                     #rows, needy))
    end
end

-- Send the server an "add hay" for one hutch (admin spawn - no item cost).
-- The server derives the per-add amount from the sandbox option.
local function spawnHay(row)
    if not row then return end
    sendClientCommand(getPlayer(), "RFTDHusbandry", HBCmd.ADD_BEDDING,
        { x = row.x, y = row.y, z = row.z })
end

local function addHaySelected()
    local row = selectedRow()
    if not row then
        if DFFeedback then DFFeedback.bad("No hutch selected.") end
        return
    end
    spawnHay(row)
    if DFFeedback then DFFeedback.good(string.format("Hay added to hutch %d,%d.", row.x, row.y)) end
end

local function addHayAll()
    local n = 0
    for _, row in ipairs(HutchesTab.rows) do
        spawnHay(row); n = n + 1
    end
    if DFFeedback then
        if n > 0 then DFFeedback.good(string.format("Hay added to %d hutch(es).", n))
        else DFFeedback.bad("No hutches in range.") end
    end
end

local function teleportToSelected()
    local row = selectedRow()
    if not row then
        if DFFeedback then DFFeedback.bad("No hutch selected.") end
        return
    end
    local p = getPlayer()
    if not p then return end
    -- setX/setY/setZ (IsoMovingObject:478/495/512) are field sets.
    p:setX(row.x + 0.5); p:setY(row.y + 0.5); p:setZ(row.z or 0)
    if DFFeedback then DFFeedback.good(string.format("Teleported to hutch %d,%d.", row.x, row.y)) end
end

-- ─────────────────────────────────────────────────────────────────────────
-- Layout
-- ─────────────────────────────────────────────────────────────────────────

local function layout(panel, x, y, w, h)
    local m = DFKit.metrics
    local R = DFKit.layout(panel, x, y, w, h)

    local bar = R:header(m.btnH + m.pad)
    local bx  = bar.x
    for _, b in ipairs(HutchesTab.btns or {}) do
        b:setX(bx); b:setY(bar.y)
        bx = bx + b:getWidth() + m.gap
    end

    local left, rest  = R:splitH(0.34, 240)
    local mid,  right = rest:splitH(0.50, 250)

    -- ── left: column header, list, count line ──────────────────────────
    local fixed = COLS[2].w + COLS[3].w + COLS[4].w + 12 + STRIPE_W + 8
    COLS[1].w = math.max(90, left.w - fixed)

    local ls = left:stack(0)
    local _, hy = ls:row(m.headerH)
    HutchesTab.headerX, HutchesTab.headerY = left.x + STRIPE_W + 4, hy

    -- Measured from the region's own BOTTOM edge, never `h - cursor`.
    local listH = (left.y + left.h) - ls.y - (16 + m.gap)
    if listH < 60 then listH = 60 end
    DFKit.sizeList(HutchesTab.listBox, left.x, ls.y, left.w, listH)
    ls:row(listH)
    HutchesTab.statsLabel:setX(left.x); HutchesTab.statsLabel:setY(ls.y)

    -- ── middle: picture over card ──────────────────────────────────────
    local picH = math.min(PIC_H, math.floor(mid.h * 0.40))
    HutchesTab.picRect = { x = mid.x, y = mid.y, w = mid.w, h = picH }
    HutchesTab.card = {
        x = mid.x, y = mid.y + picH + m.pad,
        w = mid.w, h = mid.h - picH - m.pad,
    }

    -- ── right: contents ────────────────────────────────────────────────
    HutchesTab.occHdr = { x = right.x, y = right.y, w = right.w }
    local occY = right.y + m.headerH
    DFKit.sizeList(HutchesTab.occBox, right.x, occY, right.w,
                   (right.y + right.h) - occY)
end

-- ─────────────────────────────────────────────────────────────────────────
-- Host contract
-- ─────────────────────────────────────────────────────────────────────────

function HBHutchesView.attach(panel)
    HutchesTab.selectedKey = nil
    HutchesTab.picKey      = nil

    HutchesTab.btns = {
        DFKit.button(panel, 0, 0, 90,  "Refresh",      panel, refresh),
        DFKit.button(panel, 0, 0, 110, "Teleport to",  panel, teleportToSelected),
        DFKit.button(panel, 0, 0, 90,  "Add Hay",      panel, addHaySelected),
        DFKit.button(panel, 0, 0, 110, "Add Hay: all", panel, addHayAll),
    }

    local list = HutchList:new(0, 0, 10, 10)
    list.itemheight = DFKit.metrics.rowH
    list.drawBorder = true
    DFKit.well(list)
    list:initialise(); list:instantiate()
    panel:addChild(list)
    HutchesTab.listBox = list

    local occ = OccList:new(0, 0, 10, 10)
    occ.itemheight = 18
    occ.drawBorder = true
    DFKit.well(occ)
    occ:initialise(); occ:instantiate()
    panel:addChild(occ)
    HutchesTab.occBox = occ

    HutchesTab.statsLabel = DFKit.label(panel, 0, 0, "0 hutches near you")

    -- Appended rather than a table literal: a nil in the middle of a
    -- constructor truncates ipairs at the hole and silently strands every
    -- widget after it.
    local widgets = {}
    local function keep(wdg) if wdg then widgets[#widgets + 1] = wdg end end
    for _, b in ipairs(HutchesTab.btns) do keep(b) end
    keep(HutchesTab.listBox); keep(HutchesTab.occBox); keep(HutchesTab.statsLabel)
    return widgets
end

HBHutchesView.layout = layout

-- Rescan on entry: hutch state drifts while you are on the other view.
function HBHutchesView.onShow() refresh() end

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
