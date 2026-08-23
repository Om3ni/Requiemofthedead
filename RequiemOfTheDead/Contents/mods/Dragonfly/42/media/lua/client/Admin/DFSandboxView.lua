-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFSandboxView - the suite's sandbox options, rendered and editable.
--
-- Pairs with DFSandboxModel, which does the reflection and the grouping. This
-- file owns the left nav, the schema translation, and the apply transaction.
-- The dials themselves are DFForm's.
--
-- ---------------------------------------------------------------------------
-- WHY DFForm AND NOT A BESPOKE LIST. The first version of this view drew its
-- own rows in an ISScrollingListBox, and that was wrong twice over: DFForm's
-- own header says it exists because two surfaces had already grown "roughly two
-- hundred lines of bespoke drawing, hit-testing and value formatting" and a
-- third copy would drift from both. It also already had, unbuilt-here, three
-- things this view needs:
--
--   enum stores an INDEX          exactly how a sandbox enum works -
--                                 getValue() is the index and
--                                 getValueTranslationByIndex(k) is 1-based
--   group = "Name"                the section header our *Header decoys mean
--   live = false                  the restart mark, needed the moment the
--                                 Server sub-tab lands
--
-- What it did NOT have was help ON the page rather than behind a ? glyph, which
-- is the whole point of this surface: an admin scanning forty options they have
-- never seen is asking "what does this do" about every one of them, and forty
-- hovers is not an answer. So DFForm grew an opt-in `inlineHelp`, off by
-- default, and every other form is untouched.
--
-- ---------------------------------------------------------------------------
-- THE APPLY TRANSACTION, which is the part worth reading.
--
-- SandboxOptions.sendToServer serialises the ENTIRE option set - it is
-- save(bb) of every option, not a delta (SandboxOptions.java:1059,
-- GameClient.java:2643). The server loads the lot, applies it, writes its own
-- Lua file and re-broadcasts to every connection (GameServer.java:1617-1634).
--
-- Vanilla's own editor therefore has a lost-update race, and it is not subtle:
-- ISServerSandboxOptionsUI snapshots a COPY when the window opens
-- (`o.options:copyValuesFrom(getSandboxOptions())`, :790) and pushes that whole
-- copy on Apply (:763-766). Two admins with the panel open, one changes zombie
-- count, the other changes a Dirge rate ten minutes later - and the second
-- Apply reverts the first, silently, along with anything else that moved in
-- between.
--
-- We do not snapshot. Edits are held as a PENDING SET of deltas, and Apply
-- builds its copy at the moment of pushing, from the live options this client
-- holds right then, and lays only our own changes over it. Everything we did
-- not touch carries whatever the server currently has. The re-broadcast above
-- is what makes that safe: another admin's Apply reaches this client and
-- updates getSandboxOptions() before ours is built.
--
-- It is not a transaction in the database sense - there is no compare-and-swap
-- on the wire and there cannot be, because the packet has no room for one. Two
-- admins editing THE SAME option within a frame of each other still resolves
-- last-write-wins. It removes the collateral, which is the part that loses work
-- nobody was editing.
--
-- ---------------------------------------------------------------------------
-- AUTHORITY. The tab is gated on Capability.SandboxOptions and so is the
-- packet: PacketTypes.java:393 declares it, and onServerPacket runs the handler
-- only inside `if (PacketAuthorization.isAuthorized(...))` (:666, test at
-- :830). So this is not a client-side courtesy over an open door - the same
-- capability is enforced at the server's packet gate, and a client without it
-- gets an AntiCheat report instead of a write. Our gate exists so the UI does
-- not offer an action the server will refuse.

if isServer() then return end

require "DFKit"
require "DFForm"
-- Path-relative to the lua TIER root, not a bare name: this module sits in
-- client/Admin/, so a bare "DFSandboxModel" does not resolve and the require
-- throws at load. check-lua is syntax only, so a wrong path here parses clean
-- and fails in game (CLAUDE.md sect. 1).
require "Admin/DFSandboxModel"
require "Admin/DFStaged"
require "Admin/DFLayout"
require "ISUI/ISScrollingListBox"

DFSandboxView = DFSandboxView or {}
local V = DFSandboxView

local FONT    = DFKit.font.small
local NAV_MIN = 150

V.mods    = {}
V.selected = nil     -- page name of the chosen mod
V.staged   = nil     -- DFStaged, built in attach() once liveValue exists

-- ---------------------------------------------------------------------------
-- Model -> DFForm schema. PURE, and separated from every widget on purpose.
--
-- This is the arithmetic-and-mapping half, and the RPNecroTab lesson says a
-- file-local inside a UI module is one no fixture will ever load (TODO.md). It
-- takes a model page and returns plain tables.
--
-- TYPE MAPPING, and the one that matters is `double`:
--
--   boolean          -> bool
--   enum             -> enum, numValues + values. Both store a 1-based INDEX,
--                       so no translation is needed in either direction.
--   integer          -> int, with a stepper
--   double           -> TEXT, not int. DFForm's int is a stepper over whole
--                       numbers; a sandbox double is commonly 0.6 or 1.35, and
--                       a stepper would make those unreachable. Text with a
--                       numeric validator keeps them typeable and still
--                       refuses "abc" at the door.
--   string / text    -> text
--
-- An unknown type is SKIPPED rather than guessed at. A dial that writes the
-- wrong shape into a live server option is worse than a dial that is absent,
-- and the count line tells the admin some were left out.
-- ---------------------------------------------------------------------------
function DFSandboxView.schemaFor(mod)
    local out, skipped = {}, 0
    if not mod then return out, skipped end

    for _, sec in ipairs(mod.sections or {}) do
        if sec.title then out[#out + 1] = { group = sec.title } end
        for _, opt in ipairs(sec.options or {}) do
            local row = {
                key   = opt.name,
                label = opt.label or opt.short,
                help  = opt.tooltip,
            }
            local t = opt.type
            if t == "boolean" then
                row.kind = "bool"
            elseif t == "enum" then
                row.kind = "enum"
                row.numValues = #(opt.values or {})
                row.values = opt.values
            elseif t == "integer" then
                row.kind = "int"
                row.min, row.max, row.step = -999999, 999999, 1
            elseif t == "double" then
                row.kind = "text"
                row.rule = "A number, decimals allowed."
                row.validate = function(s)
                    if tonumber(s) == nil then return false, "Not a number." end
                    return true
                end
            elseif t == "string" or t == "text" then
                row.kind = "text"
            end
            if row.kind then out[#out + 1] = row else skipped = skipped + 1 end
        end
    end
    return out, skipped
end

-- ---------------------------------------------------------------------------
-- Values. Reads go LIVE to the engine unless an edit is staged over them, so a
-- knob turned in the vanilla screen (or by another admin, via the server's
-- re-broadcast) moves on this panel without anything having to notice.
-- ---------------------------------------------------------------------------

local function optionType(name)
    local so = getSandboxOptions()
    local o = so and so:getOptionByName(name)
    return o and o:getType() or nil
end

function DFSandboxView.readValue(name)
    return V.staged and V.staged:get(name) or DFSandboxView.liveValue(name)
end

-- The engine's current value, ignoring anything staged.
function DFSandboxView.liveValue(name)
    local t = optionType(name)
    if not t then return nil end
    local o = getSandboxOptions():getOptionByName(name)
    if t == "boolean" or t == "enum" then return o:getValue() end
    if t == "string" or t == "text" then return o:getValue() end
    if t == "integer" then return tonumber(o:getValueAsString()) end
    return o:getValueAsString()
end

-- ---------------------------------------------------------------------------
-- Apply
--
-- Split from the button so a fixture can drive it. `so` and `mk` are injected -
-- the live options and a constructor for a fresh set - because both are engine
-- surfaces and the whole point of the test is what this does with them.
--
-- Returns (pushed, count) or (false, reason).
-- ---------------------------------------------------------------------------
function DFSandboxView.applyTo(so, mk, pending, isClientFn)
    local n = 0
    for _ in pairs(pending) do n = n + 1 end
    if n == 0 then return false, "nothing staged" end
    if not so then return false, "no sandbox options" end

    -- Built HERE, not when the panel opened. See THE APPLY TRANSACTION.
    local copy = mk()
    if not copy then return false, "could not build an options set" end
    copy:copyValuesFrom(so)

    for name, value in pairs(pending) do
        local o = copy:getOptionByName(name)
        if o then
            local t = o:getType()
            if t == "integer" or t == "double" then
                -- parse(), not setValue(): vanilla's own editor uses parse for
                -- both numeric types (ISServerSandboxOptionsUI.lua:726, :730)
                -- because the option owns its own string-to-number rules.
                o:parse(tostring(value))
            else
                o:setValue(value)
            end
        end
    end

    if isClientFn() then
        copy:sendToServer()
    else
        -- Singleplayer or a listen host: no packet, write straight through.
        -- Same branch vanilla takes (ISServerSandboxOptionsUI.lua:737-739).
        for name, value in pairs(pending) do
            so:set(name, value)
        end
    end
    return true, n
end

function DFSandboxView.apply()
    local ok, res = DFSandboxView.applyTo(
        getSandboxOptions(),
        function() return SandboxOptions.new() end,
        V.staged and V.staged.pending or {},
        isClient)
    if ok then
        print("[Dragonfly] sandbox: applied " .. tostring(res) .. " change(s).")
        V.staged:clear()
        V.status = tostring(res) .. " change(s) applied."
    else
        V.status = tostring(res)
    end
    DFSandboxView.rebuildForm()
    return ok
end

-- ---------------------------------------------------------------------------
-- The left nav
-- ---------------------------------------------------------------------------

local NavList = ISScrollingListBox:derive("DFSandboxNav")

function NavList:doDrawItem(y, item, alt)
    local mod = item.item
    if not mod then return y + item.height end
    local on = (V.selected == mod.page)
    if on then
        local a = DFKit.col.accentDim
        self:drawRect(0, y, self.width, item.height - 1, 0.55, a.r, a.g, a.b)
    elseif alt then
        self:drawRect(0, y, self.width, item.height - 1, 0.10, 1, 1, 1)
    end
    local c = on and DFKit.col.text or DFKit.col.textDim
    self:drawText(DFKit.fitText(mod.label or mod.page, FONT, self.width - 46),
                  6, y + 3, c.r, c.g, c.b, 1, FONT)

    -- Staged edits on a mod the admin is not currently looking at are the
    -- easiest thing to lose track of, so the count is on the nav row.
    local names = {}
    for _, sec in ipairs(mod.sections or {}) do
        for _, opt in ipairs(sec.options or {}) do names[#names + 1] = opt.name end
    end
    local staged = V.staged and V.staged:countIn(names) or 0
    local txt = staged > 0 and ("+" .. staged) or tostring(mod.count or 0)
    local col = staged > 0 and DFKit.col.accent or DFKit.col.textDim
    local w = getTextManager():MeasureStringX(FONT, txt)
    self:drawText(txt, self.width - w - 6, y + 3, col.r, col.g, col.b, 1, FONT)
    return y + item.height
end

function NavList:onMouseDown(x, y)
    local idx = self:rowAt(x, y)
    if idx <= 0 then return end
    local item = self.items[idx]
    if item and item.item then
        V.selected = item.item.page
        self.selected = idx
        -- One request per page per session; DFLayout drops a repeat itself.
        -- Asking on selection rather than up front means nine requests only
        -- ever go out if an admin visits all nine mods.
        DFLayout.request(V.selected)
        DFSandboxView.rebuildForm()
    end
end

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------

local function selectedMod()
    for _, m in ipairs(V.mods) do if m.page == V.selected then return m end end
end

function DFSandboxView.rebuildForm()
    -- Shaped, not raw. DFLayout hands back the reflected page untouched when
    -- the server holds no layout for it, so there is one path here rather than
    -- a branch that could drift.
    local shaped, stats = DFLayout.shape(selectedMod())
    V.shapeStats = stats
    local schema, skipped = DFSandboxView.schemaFor(shaped)
    V.skipped = skipped
    V.form.schema = schema
    -- The wrap cache is keyed on width and font, neither of which changed - but
    -- the SCHEMA did, and a stale entry would size a row for another mod's
    -- description. Cleared rather than versioned: it refills in one frame.
    V.form._helpCache = nil
    if V.form.rect then
        V.form:layout(V.form.rect.x, V.form.rect.y, V.form.rect.w, V.form.rect.h)
    end
end

local function reload()
    V.mods = DFSandboxModel.build() or {}
    if not V.selected and V.mods[1] then V.selected = V.mods[1].page end
    DFLayout.request(V.selected)
    DFKit.refillList(V.navBox, function(box)
        for _, mod in ipairs(V.mods) do
            local i = box:addItem(mod.label or mod.page, mod)
            i.height = DFKit.rowHeight()
        end
    end)
    DFSandboxView.rebuildForm()
end

function DFSandboxView.attach(panel)
    local nav = NavList:new(0, 0, 10, 10)
    nav.itemheight = DFKit.rowHeight()
    nav.drawBorder = true
    DFKit.well(nav)
    nav:initialise(); nav:instantiate()
    panel:addChild(nav)
    V.navBox = nav

    V.staged = DFStaged.new(DFSandboxView.liveValue)

    -- Once. attach runs when the tab is built, and a second registration would
    -- rebuild the form twice for every broadcast.
    if not V.subscribed then
        V.subscribed = true
        -- key == nil means "every page" - a recover replaced the whole
        -- document, so there is no page-shaped correction to match against.
        DFLayout.onChanged(function(key)
            if key == nil or key == V.selected then
                DFLayout.request(V.selected)
                DFSandboxView.rebuildForm()
            end
        end)
    end

    V.form = DFForm.new{
        title      = "Sandbox",
        inlineHelp = true,
        schema     = {},
        get        = DFSandboxView.readValue,
        -- Bound inline rather than through a named wrapper: a two-line
        -- delegate per view is the shape check-helpers counts as a copy, and
        -- there is nothing here for a wrapper to add. DFStaged owns the
        -- "an edit back to the current value is not an edit" rule.
        set        = function(k, v) V.staged:set(k, v) end,
        -- The accent tick in the gutter. NOT "differs from default" - that is
        -- DFSandboxModel.isDefault and it is a different question. This marks
        -- what YOU have staged and not yet pushed, which is the one thing a
        -- reader cannot recover by looking anywhere else.
        moved      = function(key) return V.staged and V.staged:has(key) end,
        enabled    = function() return true end,
    }
    local formWidgets = V.form:attach(panel)

    V.applyBtn = DFKit.button(panel, 0, 0, 90, "Apply", panel,
        function() DFSandboxView.apply() end, "action",
        { tooltip = "Push staged changes to the server. Only the options you "
                 .. "changed are written; everything else keeps whatever the "
                 .. "server has right now." })
    V.discardBtn = DFKit.button(panel, 0, 0, 90, "Discard", panel,
        function() V.staged:clear(); V.status = nil; DFSandboxView.rebuildForm() end)

    reload()

    local out = { nav, V.applyBtn, V.discardBtn }
    for _, wdg in ipairs(formWidgets or {}) do out[#out + 1] = wdg end
    return out
end

function DFSandboxView.layout(panel, x, y, w, h)
    if not V.navBox then return end
    local R = DFKit.layout(panel, x, y, w, h)

    local foot = R:footer(DFKit.metrics.btnH + DFKit.metrics.pad)
    V.footRect = { x = foot.x, y = foot.y, w = foot.w, h = foot.h }
    local bx = foot.x + foot.w
    for _, b in ipairs({ V.applyBtn, V.discardBtn }) do
        if b then
            bx = bx - b:getWidth()
            b:setX(bx); b:setY(foot.y)
            bx = bx - DFKit.metrics.gap
        end
    end
    V.footTextW = bx - foot.x - DFKit.metrics.gap

    local navR, formR = R:splitH(0.20, NAV_MIN, 300)
    DFKit.sizeList(V.navBox, navR.x, navR.y, navR.w, navR.h)
    V.form:layout(formR.x, formR.y, formR.w, formR.h)
end

function DFSandboxView.draw(el)
    V.form:draw(el)

    local r = V.footRect
    if not r then return end
    local n = V.staged and V.staged:count() or 0
    local text, col
    if n > 0 then
        text = n .. " change" .. (n == 1 and "" or "s") .. " staged - not applied"
        col = DFKit.col.accent
    elseif V.status then
        text, col = V.status, DFKit.col.textDim
    else
        text, col = "No changes staged.", DFKit.col.textDim
    end
    if (V.skipped or 0) > 0 then
        text = text .. "   (" .. V.skipped .. " option(s) of an unsupported type hidden)"
    end
    -- The layout note goes at the HEAD, not the tail: fitText truncates the
    -- end, and the states this reports - a stranded layout file, options the
    -- arrangement has never seen - are the ones that must not be the part that
    -- gets cut.
    local note = DFLayout.noteFor(V.selected, V.shapeStats)
    if note then
        text = note .. "   -   " .. text
        if DFLayout.held(V.selected) then col = DFKit.col.accent end
    end
    el:drawText(DFKit.fitText(text, FONT, V.footTextW or r.w),
                r.x, r.y + 5, col.r, col.g, col.b, 1, FONT)

    if #V.mods == 0 then
        DFKit.drawEmpty(el, r.x, r.y - 40, r.w, 30, "No RFTD sandbox options found.")
    end
end

-- No hit routing here, deliberately: DFForm:attach installs its own invisible
-- Hotspot panel over the whole form, and that panel already owns mouse down,
-- move, up and wheel (DFForm.lua:175-215). Adding a second router in the host
-- would double-handle every click.
function DFSandboxView.onShow()
    -- Forget first. `asked` is what stops a redraw re-sending a request sixty
    -- times a second, and it is also what would strand a page whose reply never
    -- came back; reopening the tab is the retry.
    DFLayout.forget(V.selected)
    reload()
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
