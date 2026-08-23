-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFVarsView - the Admin tab's third sub-tab: player attributes.
--
-- Two panes and one question each. LEFT: what vars exist on this server. RIGHT:
-- who has the selected one, and what it says about them. Every verb the panel
-- offers is a server command; nothing here decides anything.
--
-- ---------------------------------------------------------------------------
-- MARKERS AND COUNTERS ARE NOT ONE THING WITH A FLAG, and this surface is where
-- that stops being an implementation note. A marker is present or absent and has
-- a lifecycle - revoked on death, after an interval, when a kit is claimed. A
-- counter is a number and has none of that; it resets or it does not. The two
-- get different verbs (Grant/Revoke against Set/Reset), different columns, and
-- different halves of the definition form, because a panel that flattened them
-- into "value" would be the first step back toward the merged design RDVarDefs
-- rejected.
--
-- ABSENT IS NOT ZERO is the same rule, drawn. A counter nobody has touched shows
-- "-", a counter somebody was set to zero shows "0", and Reset returns a row to
-- the first of those rather than the second. If those two ever render alike,
-- every repeatable quest built on this loses its "have you started" test.
--
-- ---------------------------------------------------------------------------
-- resetOnDeath HAS NO DEFAULT, ON PURPOSE, AND THE FORM HONOURS THAT. RDVarDefs
-- refuses a counter that does not declare it, because "an unset default is how
-- behaviour nobody chose gets discovered months later". A boolean dial would
-- quietly undo that - a toggle always shows SOMETHING, so whichever way it
-- happens to start is a default by another name. So it is a three-way choice
-- that begins on "- choose -" and Create refuses until it moves.
--
-- ---------------------------------------------------------------------------
-- THE SELECTED PLAYER IS A USERNAME, NEVER A ROW INDEX, and that is a bug fix
-- rather than a preference. Every action here is followed by a server push, the
-- push rebuilds the list, and DFKit.refillList calls the widget's clear() -
-- which sets `selected = 1` (ISScrollingListBox.lua:340-345). Reading the verb's
-- target off the widget therefore meant: act on Alice, list refreshes,
-- selection silently lands on whoever is first, click again and modify THEM. On
-- a surface whose whole job is granting and revoking, that is the worst
-- available failure and it leaves no trace on screen.
--
-- So `V.selectedUser` is the truth, the widget index is re-derived from it after
-- every rebuild, and a selection whose player has left the list becomes NO
-- selection rather than row one. The verbs refuse rather than guess.
--
-- ---------------------------------------------------------------------------
-- THE NAME IS VALIDATED BY THE SERVER'S OWN FUNCTION. RDVarDefs is shared, so
-- the form calls RDVarDefs.normalizeName - the same code the store will run -
-- rather than carrying a second pattern that agrees with it today. This is not
-- the client gate being trusted: the server validates again regardless. It is
-- the admin finding out at the keyboard instead of after a round trip.

if isServer() then return end

require "DFKit"
require "DFForm"
require "DFConfirm"
require "RDVarDefs"
require "ISUI/ISScrollingListBox"
require "ISUI/ISCollapsableWindow"
require "ISUI/ISTextBox"

DFVarsView = DFVarsView or {}
local V = DFVarsView

local FONT    = DFKit.font.small
local NAV_MIN = 180

V.defs     = {}      -- summary rows from the server
V.selected     = nil   -- var NAME
V.selectedUser = nil   -- holder USERNAME; see the header - never an index
V.holders      = nil   -- { name, kind, rows, total }
V.status       = nil
V.pending      = nil   -- username fetched by name, waiting for its record

local function selectedDef()
    for _, d in ipairs(V.defs) do if d.name == V.selected then return d end end
end

local function isMarker(d) return d and d.kind == RDVarDefs.CHAR end

-- ---------------------------------------------------------------------------
-- The definition form's model -> a definition. PURE, and split out because it
-- is the one place a mis-built payload turns into a var nobody meant.
--
-- Returns (def) or (nil, reason). The reasons are shown verbatim.
-- ---------------------------------------------------------------------------
function DFVarsView.buildDef(model)
    model = model or {}
    local key, display = RDVarDefs.normalizeName(model.name)
    if not key then return nil, display end

    if model.kind == RDVarDefs.CHAR then
        -- Only revokers the admin actually set. `death = false` is deliberately
        -- NOT written: RDVarDefs treats the absence of a revoker and a revoker
        -- set to false as different things, and storing the second would leave a
        -- key behind that makes the var read as revocable while nothing revokes
        -- it (RDVarDefs.lua, validateRevokers).
        local revokers = {}
        if model.death == true then revokers.death = true end
        if type(model.expires) == "number" and model.expires > 0 then
            revokers.expires = model.expires
        end
        if type(model.kit) == "string" and model.kit ~= "" then
            revokers.kit = model.kit
        end
        return { kind = RDVarDefs.CHAR, name = display, revokers = revokers }
    end

    if model.kind == RDVarDefs.STRING then
        -- The three-way choice. "" is the unmoved dial, and it is refused rather
        -- than read as false - see the header.
        if model.resetOnDeath ~= "yes" and model.resetOnDeath ~= "no" then
            return nil, "Choose whether this counter resets on death. There is "
                .. "no default - a counter that quietly picked one would be "
                .. "behaviour nobody chose."
        end
        return { kind = RDVarDefs.STRING, name = display,
                 resetOnDeath = model.resetOnDeath == "yes" }
    end

    return nil, "Choose a kind."
end

-- One row's value column. The marker/counter split again, and BOTH dashes are
-- load-bearing: a marker's is "does not hold it", a counter's is "nobody has
-- ever touched this", and the second is emphatically not zero.
function DFVarsView.cellFor(kind, row)
    row = row or {}
    if kind == RDVarDefs.CHAR then return row.holds and "holds" or "-" end
    if row.value == nil then return "-" end
    return tostring(row.value)
end

-- What a definition says about itself, in one line. An admin scanning a list of
-- vars is asking "what happens to this one", and the lifecycle IS the answer.
function DFVarsView.lifecycleOf(d)
    if not d then return "" end
    if d.kind == RDVarDefs.STRING then
        return d.resetOnDeath and "resets on death" or "survives death"
    end
    local r = d.revokers or {}
    local parts = {}
    if r.death then parts[#parts + 1] = "on death" end
    if r.expires then parts[#parts + 1] = r.expires .. " min" end
    if r.kit then parts[#parts + 1] = "kit " .. tostring(r.kit) end
    if #parts == 0 then return "permanent" end
    return "cleared: " .. table.concat(parts, ", ")
end

-- ---------------------------------------------------------------------------
-- Wire
-- ---------------------------------------------------------------------------

local function send(command, args)
    sendClientCommand(getPlayer(), DFCore.MODULE, command, args or {})
end

function DFVarsView.refresh()
    send("varsList")
    if V.selected then send("varHolders", { name = V.selected }) end
end

function DFVarsView.receive(command, args)
    if command == "AdminVars" then
        V.defs = (args and args.defs) or {}
        if V.selected and not selectedDef() then V.selected = nil; V.holders = nil end
        if not V.selected and V.defs[1] then
            V.selected = V.defs[1].name
            send("varHolders", { name = V.selected })
        end
        DFVarsView.rebuild()
        return true
    elseif command == "AdminVarHolders" then
        -- Answers arrive unordered against clicks. A reply for a var the admin
        -- has already moved off is dropped rather than drawn under the new
        -- selection's heading, which would attribute one var's holders to
        -- another - the most misleading thing this panel could do.
        if args and args.name == V.selected then
            V.holders = args
            DFVarsView.rebuild()
        end
        return true
    elseif command == "AdminVarsPlayer" then
        -- Two callers, one reply. A per-player push follows every grant, revoke,
        -- set and reset - including a refused one - and this panel is organised
        -- by VAR, so for those the useful part is simply that something changed
        -- and the holder list should be re-read.
        --
        -- The other caller is "By name": a player who is offline AND past the
        -- row bound appears in no list, so the panel fetches their record and
        -- SPLICES them in. That is what makes every verb reachable for them
        -- rather than only the two an ask-and-send button could perform.
        if args and args.username and args.username == V.pending then
            V.pending = nil
            DFVarsView.spliceRecord(args)
            return true
        end
        if V.selected then send("varHolders", { name = V.selected }) end
        return true
    elseif command == "AdminVarsStale" then
        DFVarsView.refresh()
        return true
    end
    return false
end

-- One player's record -> a row in the current var's holder list, selected.
--
-- PURE apart from the two module fields it writes, so a fixture can drive it.
-- The row is derived for the SELECTED var only: the record carries everything
-- that player holds, and the list is about one var.
function DFVarsView.spliceRecord(record)
    if not record or not record.username or not V.holders then return false end

    local row = { user = record.username, pinned = true }
    for _, c in ipairs(record.chars or {}) do
        if c.name == V.holders.name then row.holds = true end
    end
    for _, n in ipairs(record.numbers or {}) do
        if n.name == V.holders.name then row.value = n.value end
    end

    -- Already listed - online, or a holder inside the bound. Select, do not
    -- duplicate: two rows for one player is two answers to one question.
    for _, existing in ipairs(V.holders.rows) do
        if existing.user == row.user then
            V.selectedUser = row.user
            DFVarsView.rebuild()
            return true
        end
    end

    table.insert(V.holders.rows, row)
    V.selectedUser = row.user
    DFVarsView.rebuild()
    return true
end

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= DFCore.MODULE then return end
    DFVarsView.receive(command, args)
end)

-- ---------------------------------------------------------------------------
-- The definition window
--
-- Lives in this file rather than its own: it has exactly one consumer, it is
-- the other half of one responsibility ("administer vars"), and CLAUDE.md
-- sect. 11 keeps a small private helper beside the thing it supports.
-- ---------------------------------------------------------------------------

local Define = ISCollapsableWindow:derive("DFVarDefine")

local function defineSchema(model)
    local out = {
        { key = "name", kind = "text", label = "Name",
          rule = "Starts with a letter, then letters, digits, underscore or "
              .. "hyphen. At most " .. RDVarDefs.NAME_MAX .. " characters.",
          help = "The name consumers use. Case is kept for display and ignored "
              .. "for matching, so Anomaly and anomaly are the same var.",
          validate = function(s)
              local key, why = RDVarDefs.normalizeName(s)
              if not key then return false, why end
              return true
          end },
        { key = "kind", kind = "choice", label = "Kind",
          values = { RDVarDefs.CHAR, RDVarDefs.STRING },
          labels = { "Marker", "Counter" },
          help = "A MARKER is present or absent and has a lifecycle - it can be "
              .. "cleared on death, after an interval, or when a kit is claimed. "
              .. "A COUNTER is a number. They are not the same thing with a "
              .. "flag: a marker's absence and a counter's zero mean different "
              .. "things, and quests depend on the difference." },
    }
    if model.kind == RDVarDefs.CHAR then
        out[#out + 1] = { group = "Cleared by" }
        out[#out + 1] = { key = "death", kind = "bool", label = "Death",
            help = "Cleared when the holder dies." }
        out[#out + 1] = { key = "expires", kind = "int", label = "Time limit",
            min = 0, max = 100000, step = 15, unit = "minutes", zero = "no limit",
            help = "Real minutes from the moment it is granted. Re-granting "
                .. "starts the clock again." }
        -- The "none of the above" case rides on the LAST field's help rather
        -- than on a schema row of its own: DFForm's rows are dials and group
        -- headers, and a third kind that is neither would draw as a dial with
        -- no key.
        out[#out + 1] = { key = "kit", kind = "text", label = "Kit id",
            empty = "(none)",
            help = "Cleared when that kit is claimed. Leave empty for none. "
                .. "With none of these three set, the marker is permanent "
                .. "until an admin removes it." }
    elseif model.kind == RDVarDefs.STRING then
        out[#out + 1] = { key = "resetOnDeath", kind = "choice",
            label = "Reset on death",
            values = { "", "yes", "no" },
            labels = { "- choose -", "Yes", "No" },
            help = "There is no default, deliberately. A counter that quietly "
                .. "picked one would be behaviour nobody chose, found months "
                .. "later." }
    end
    return out
end

function Define:createChildren()
    ISCollapsableWindow.createChildren(self)
    local pad = DFKit.metrics.pad
    local top = self:titleBarHeight() + pad
    local footH = DFKit.metrics.btnH + pad * 2

    local win = self
    self.form = DFForm.new{
        title      = "Definition",
        inlineHelp = true,
        schema     = defineSchema(self.model),
        get        = function(k) return win.model[k] end,
        set        = function(k, v)
            win.model[k] = v
            -- The kind decides which fields exist at all, so changing it
            -- rebuilds rather than greying: a revoker on a counter is not a
            -- disabled control, it is a field that does not apply.
            if k == "kind" then
                win.form.schema = defineSchema(win.model)
                win.form._helpCache = nil
                if win.form.rect then
                    win.form:layout(win.form.rect.x, win.form.rect.y,
                                    win.form.rect.w, win.form.rect.h)
                end
            end
        end,
        enabled    = function() return true end,
    }
    self.form:attach(self)
    self.form:layout(pad, top, self.width - pad * 2,
                     self.height - top - footH - pad)

    local bx = self.width - pad
    for _, spec in ipairs({ { 80, "Create", function() win:create() end, "action" },
                            { 80, "Cancel", function() win:close() end, nil } }) do
        bx = bx - spec[1]
        DFKit.button(self, bx, self.height - footH, spec[1], spec[2], self,
                     spec[3], spec[4])
        bx = bx - DFKit.metrics.gap
    end
    self.footY = self.height - footH + 4
end

function Define:create()
    local def, why = DFVarsView.buildDef(self.model)
    if not def then self.status = why; return end
    send("varDefine", { def = def })
    self:close()
end

function Define:prerender()
    ISCollapsableWindow.prerender(self)
    self.form:draw(self)
    if self.status then
        local a = DFKit.col.accent
        self:drawText(DFKit.fitText(self.status, FONT, self.width - 180),
                      DFKit.metrics.pad, self.footY, a.r, a.g, a.b, 1, FONT)
    end
end

function Define:close() self:removeFromUIManager() end

local function openDefine()
    local w, h = 460, 420
    local win = Define:new(getCore():getScreenWidth() / 2 - w / 2,
                           getCore():getScreenHeight() / 2 - h / 2, w, h)
    -- Kind DOES start on Marker, and that is not a hidden default: it is a
    -- two-way visible choice whose position is on screen and whose two answers
    -- shape the rest of the form, so there is nothing for a reader to fail to
    -- notice. resetOnDeath is the opposite case - a third state that means "not
    -- answered", which the form will refuse to submit - and name starts empty.
    win.model = { name = "", kind = RDVarDefs.CHAR, death = false,
                  expires = 0, kit = "", resetOnDeath = "" }
    win:setTitle("Define a var")
    win:setResizable(false)
    win:initialise(); win:instantiate(); win:addToUIManager()
    return win
end

-- ---------------------------------------------------------------------------
-- Lists
-- ---------------------------------------------------------------------------

local DefList = ISScrollingListBox:derive("DFVarsDefs")

function DefList:doDrawItem(y, item, alt)
    local d = item.item
    if not d then return y + item.height end
    local on = (V.selected == d.name)
    if on then
        local a = DFKit.col.accentDim
        self:drawRect(0, y, self.width, item.height - 1, 0.55, a.r, a.g, a.b)
    elseif alt then
        self:drawRect(0, y, self.width, item.height - 1, 0.10, 1, 1, 1)
    end
    local c = on and DFKit.col.text or DFKit.col.textDim
    self:drawText(DFKit.fitText(d.name, FONT, self.width - 60), 6, y + 3,
                  c.r, c.g, c.b, 1, FONT)
    local tag = isMarker(d) and tostring(d.holders or 0) or "#"
    local w = getTextManager():MeasureStringX(FONT, tag)
    local t = DFKit.col.textDim
    self:drawText(tag, self.width - w - 6, y + 3, t.r, t.g, t.b, 1, FONT)
    return y + item.height
end

function DefList:onMouseDown(x, y)
    local idx = self:rowAt(x, y)
    if idx < 1 or idx > #self.items then return end
    local d = self.items[idx].item
    if not d then return end
    self.selected  = idx
    V.selected     = d.name
    V.holders      = nil
    -- A different var means a different list; carrying the player selection
    -- across would leave a verb pointed at somebody the new list may not hold.
    V.selectedUser = nil
    V.pending      = nil
    V.status       = nil
    send("varHolders", { name = d.name })
    DFVarsView.rebuild()
end

local HolderList = ISScrollingListBox:derive("DFVarsHolders")

function HolderList:doDrawItem(y, item, alt)
    local row = item.item
    if not row then return y + item.height end
    if self.selected == item.index then
        local a = DFKit.col.accentDim
        self:drawRect(0, y, self.width, item.height - 1, 0.55, a.r, a.g, a.b)
    elseif alt then
        self:drawRect(0, y, self.width, item.height - 1, 0.10, 1, 1, 1)
    end
    -- Online players read at full strength and offline ones dimmed. The list
    -- deliberately holds both, so which is which has to be visible without
    -- spending a column on it.
    local c = row.online and DFKit.col.text or DFKit.col.textDim
    -- A row fetched by name is marked, because it is the one row in the list
    -- that is not there because the server volunteered it.
    local label = row.pinned and (row.user .. "  *") or row.user
    self:drawText(DFKit.fitText(label, FONT, self.width - 90), 6, y + 3,
                  c.r, c.g, c.b, 1, FONT)
    local kind = V.holders and V.holders.kind
    local cell = DFVarsView.cellFor(kind, row)
    local w = getTextManager():MeasureStringX(FONT, cell)
    local d = DFKit.col.textDim
    self:drawText(cell, self.width - w - 6, y + 3, d.r, d.g, d.b, 1, FONT)
    return y + item.height
end

function HolderList:onMouseDown(x, y)
    local idx = self:rowAt(x, y)
    if idx < 1 or idx > #self.items then return end
    self.selected = idx
    -- The USERNAME is what is remembered. See the header: the index does not
    -- survive the next refill.
    local row = self.items[idx].item
    V.selectedUser = row and row.user or nil
    V.status = nil
end

-- The selected player, or nil. Answers from the remembered USERNAME and
-- confirms it is still in the list, so a player who dropped out of it between
-- refreshes yields no target rather than the wrong one.
--
-- A MODULE FUNCTION rather than a file-local, because this is the answer to
-- "who is about to be modified" and the RPNecroTab lesson says a file-local
-- inside a UI module is one no fixture will ever load (TODO.md). Getting this
-- wrong modifies the wrong player, which is the defect it exists to prevent.
function DFVarsView.targetUser()
    if not V.selectedUser or not V.holders then return nil end
    for _, row in ipairs(V.holders.rows or {}) do
        if row.user == V.selectedUser then return row.user end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Verbs
-- ---------------------------------------------------------------------------

local function askUser(prompt, then_)
    local modal
    modal = ISTextBox:new(getCore():getScreenWidth() / 2 - 150,
        getCore():getScreenHeight() / 2 - 60, 300, 120, prompt, "", nil,
        function(_, btn)
            if btn.internal ~= "OK" or not (modal and modal.entry) then return end
            local text = modal.entry:getText()
            if text and text ~= "" then then_(text) end
        end, getPlayer() and getPlayer():getPlayerNum() or 0)
    modal:initialise(); modal:addToUIManager()
end

local function needSelection()
    if not V.selected then V.status = "Select a var first."; return true end
    return false
end

local function needUser()
    local user = DFVarsView.targetUser()
    if not user then V.status = "Select a player row first."; return nil end
    return user
end

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------

function DFVarsView.rebuild()
    if not V.defBox then return end
    DFKit.refillList(V.defBox, function(box)
        for _, d in ipairs(V.defs) do
            local i = box:addItem(d.name, d)
            i.height = DFKit.rowHeight()
        end
    end)
    DFKit.refillList(V.holderBox, function(box)
        for _, row in ipairs((V.holders and V.holders.rows) or {}) do
            local i = box:addItem(row.user, row)
            i.height = DFKit.rowHeight()
        end
    end)

    -- Put the widget back where the USERNAME says it is. refillList calls
    -- clear(), which sets selected = 1 (ISScrollingListBox.lua:340-345); left
    -- alone, the panel would highlight - and act on - whoever happens to be
    -- first after every single action.
    local box = V.holderBox
    box.selected = -1
    if V.selectedUser then
        for i, item in ipairs(box.items) do
            if item.item and item.item.user == V.selectedUser then
                box.selected = i
                break
            end
        end
        -- Gone from the list entirely: forget it rather than letting a stale
        -- name sit behind a highlight nobody can see.
        if box.selected == -1 then V.selectedUser = nil end
    end
end

function DFVarsView.attach(panel)
    local defs = DefList:new(0, 0, 10, 10)
    defs.itemheight = DFKit.rowHeight()
    defs.drawBorder = true
    DFKit.well(defs)
    defs:initialise(); defs:instantiate()
    panel:addChild(defs)
    V.defBox = defs

    local holders = HolderList:new(0, 0, 10, 10)
    holders.itemheight = DFKit.rowHeight()
    holders.drawBorder = true
    DFKit.well(holders)
    holders:initialise(); holders:instantiate()
    panel:addChild(holders)
    V.holderBox = holders

    V.defineBtn = DFKit.button(panel, 0, 0, 76, "Define", panel,
        function() openDefine() end, "action",
        { tooltip = "Create a new var. Definitions are server-wide." })

    V.removeBtn = DFKit.button(panel, 0, 0, 76, "Remove", panel, function()
        if needSelection() then return end
        local name = V.selected
        local d = selectedDef()
        local held = isMarker(d) and (d.holders or 0) or nil
        DFConfirm.ask("Remove '" .. name .. "'?"
            .. (held and (" It is currently held by " .. held .. " player(s), "
                          .. "and removing it clears it from all of them.")
                     or " Every player's value for it is cleared.")
            .. " This cannot be undone.",
            function() send("varUndefine", { name = name }) end)
    end, nil, { tooltip = "Delete the selected var and clear it from every "
                       .. "player who holds it." })

    V.grantBtn = DFKit.button(panel, 0, 0, 76, "Grant", panel, function()
        if needSelection() then return end
        local user = needUser(); if not user then return end
        send("varGrant", { user = user, name = V.selected })
    end, nil, { tooltip = "Grant the selected marker to the selected player. "
                       .. "Everyone online is listed, whether they hold it or not." })

    -- The escape hatch for anybody the list does not show: an offline holder
    -- past the row bound, or somebody who has never held this var and is not
    -- online right now.
    --
    -- It FETCHES rather than acting. An earlier version performed one verb -
    -- Grant for a marker, Set for a counter - which meant the two REMOVING
    -- verbs had no by-name route at all, so a holder past the row bound could
    -- be granted things forever and never revoked. Bringing the player into the
    -- list instead makes all four verbs reach them, and it reuses the
    -- varsOfPlayer read that already existed.
    V.byNameBtn = DFKit.button(panel, 0, 0, 84, "By name", panel, function()
        if needSelection() then return end
        askUser("Look up which username?", function(user)
            V.pending = user
            V.status  = "Looking up " .. user .. "..."
            send("varsOfPlayer", { user = user })
        end)
    end, nil, { tooltip = "Bring somebody into the list who is not in it - an "
                       .. "offline player, or one who has never held this var. "
                       .. "They can then be granted, revoked, set or reset like "
                       .. "any other row." })

    V.revokeBtn = DFKit.button(panel, 0, 0, 76, "Revoke", panel, function()
        if needSelection() then return end
        local user = needUser(); if not user then return end
        send("varRevoke", { user = user, name = V.selected })
    end)

    V.setBtn = DFKit.button(panel, 0, 0, 76, "Set", panel, function()
        if needSelection() then return end
        local user = needUser(); if not user then return end
        askUser("Set '" .. V.selected .. "' for " .. user .. " to:", function(text)
            local n = tonumber(text)
            if not n then V.status = "That is not a number."; return end
            send("varSet", { user = user, name = V.selected, value = n })
        end)
    end, nil, { tooltip = "Set the selected player's counter." })

    V.resetBtn = DFKit.button(panel, 0, 0, 76, "Reset", panel, function()
        if needSelection() then return end
        local user = needUser(); if not user then return end
        send("varReset", { user = user, name = V.selected })
    end, nil, { tooltip = "Return the selected player's counter to ABSENT - "
                       .. "which is not the same as zero." })

    DFVarsView.refresh()
    return { defs, holders, V.defineBtn, V.removeBtn, V.grantBtn, V.revokeBtn,
             V.setBtn, V.resetBtn, V.byNameBtn }
end

function DFVarsView.layout(panel, x, y, w, h)
    if not V.defBox then return end
    local m = DFKit.metrics
    local R = DFKit.layout(panel, x, y, w, h)

    local foot = R:footer(m.btnH + m.pad)
    V.footRect = { x = foot.x, y = foot.y, w = foot.w, h = foot.h }
    local bx = foot.x + foot.w
    for _, b in ipairs({ V.byNameBtn, V.resetBtn, V.setBtn, V.revokeBtn,
                         V.grantBtn, V.removeBtn, V.defineBtn }) do
        if b then
            bx = bx - b:getWidth()
            b:setX(bx); b:setY(foot.y)
            bx = bx - m.gap
        end
    end
    V.footTextW = bx - foot.x - m.gap

    local left, right = R:splitH(0.34, NAV_MIN, 320)
    DFKit.sizeList(V.defBox, left.x, left.y, left.w, left.h)
    DFKit.sizeList(V.holderBox, right.x, right.y, right.w, right.h)
    V.rightRect = right
end

function DFVarsView.draw(el)
    local d = DFKit.col.textDim

    -- The verbs that apply are the ones for THIS kind. A marker has no value to
    -- set and a counter has nothing to grant, and offering both would invite an
    -- admin to try the wrong one and read the refusal as a fault.
    local def = selectedDef()
    local marker = isMarker(def)
    if V.grantBtn then
        V.grantBtn:setVisible(def ~= nil and marker)
        V.revokeBtn:setVisible(def ~= nil and marker)
        V.setBtn:setVisible(def ~= nil and not marker)
        V.resetBtn:setVisible(def ~= nil and not marker)
        V.removeBtn:setVisible(def ~= nil)
        V.byNameBtn:setVisible(def ~= nil)
    end

    if #V.defs == 0 then
        local r = V.rightRect
        if r then
            DFKit.drawEmpty(el, r.x, r.y + 20, r.w, 40,
                "No vars are defined. Define one to start.")
        end
    elseif V.holders and V.rightRect then
        local h = V.holders
        local text
        if #h.rows == 0 then
            text = "Nobody online, and nobody holds " .. tostring(h.name) .. "."
        elseif h.total > #h.rows then
            -- Truncated, and it says so with the true total. A list that stops
            -- at 200 without saying so is a lie about who holds what.
            text = string.format("%d of %d shown", #h.rows, h.total)
        else
            text = h.total .. (marker and " holder(s)" or " player(s) with a value")
        end
        el:drawText(text, V.rightRect.x, V.rightRect.y - 15, d.r, d.g, d.b, 1, FONT)
    end

    local r = V.footRect
    if not r then return end
    local text, col = V.status, DFKit.col.accent
    if not text then
        if def then
            text = def.name .. " - " .. (marker and "marker" or "counter")
                .. " - " .. DFVarsView.lifecycleOf(def)
        else
            text = #V.defs .. " var(s) defined."
        end
        col = d
    end
    el:drawText(DFKit.fitText(text, FONT, V.footTextW or r.w),
                r.x, r.y + 5, col.r, col.g, col.b, 1, FONT)
end

function DFVarsView.onShow()
    V.status = nil
    DFVarsView.refresh()
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
