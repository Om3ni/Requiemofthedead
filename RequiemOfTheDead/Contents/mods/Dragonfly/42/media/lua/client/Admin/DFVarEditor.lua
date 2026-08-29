-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFVarEditor - one variable: what it is, and who holds it (client only).
--
-- Split from DFVarsView on 2026-08-23 when the panel became two lists. The tab
-- owns NAVIGATION - which variables exist, in two columns - and this window
-- owns ONE of them. They change for different reasons: a column gains a sort,
-- a variable gains a revoker.
--
-- ---------------------------------------------------------------------------
-- WHY MEMBERSHIP LIVES HERE AND NOT ON THE TAB.
--
-- Grant, Revoke, Set and Reset used to sit in the tab's footer, acting on
-- whichever row of a second list was highlighted. That put the four most
-- destructive verbs one click away from a list that refills after every action,
-- and it meant an admin could not see a variable's DEFINITION and its HOLDERS
-- at the same time - which is the pairing every real question needs ("it says
-- it clears on death; why does Alice still have it?").
--
-- Inside a window opened for one named variable, the verbs cannot be pointed at
-- the wrong variable at all. That is not a smaller mistake, it is a mistake the
-- shape of the screen no longer permits.
--
-- ---------------------------------------------------------------------------
-- ONE WINDOW, TWO MODES, and the difference is not cosmetic. `openNew` has no
-- membership half because the variable does not exist yet - there is nothing to
-- hold it. `open` has both. A single window that greyed the holder list out
-- while creating would be telling an admin the list is temporarily unavailable,
-- when the truth is that it is not applicable.
--
-- ---------------------------------------------------------------------------
-- THE SELECTED PLAYER IS A USERNAME, NEVER A ROW INDEX. Inherited verbatim from
-- DFVarsView because the reason is unchanged: every verb triggers a server push,
-- the push refills the list, and DFKit.refillList calls the widget's clear(),
-- which sets `selected = 1` (ISScrollingListBox.lua:340-345). Reading the target
-- off the widget means: act on Alice, list refreshes, selection lands on
-- whoever is first, act again and modify THEM. On a membership screen that is
-- the worst available failure and it leaves no trace.
--
-- ---------------------------------------------------------------------------
-- ABSENT IS NOT ZERO, drawn. A counter nobody has touched shows "-", one set to
-- zero shows "0", and Clear returns a row to the first rather than the second.
-- If those ever render alike, every repeatable quest built on this loses its
-- "have you started" test.

if isServer() then return end

require "DFKit"
require "DFForm"
require "DFConfirm"
require "RDVarDefs"
require "ISUI/ISScrollingListBox"
require "ISUI/ISCollapsableWindow"
require "ISUI/ISTextBox"

DFVarEditor = DFVarEditor or {}
local E = DFVarEditor

local FONT = DFKit.font.small

-- The open window, or nil. One at a time: two editors on one variable would
-- disagree the moment either saved.
E.win = nil

E.holders      = nil   -- { name, kind, rows, total }
E.selectedUser = nil   -- see the header - never an index
E.pending      = nil   -- username fetched by name, waiting for its record

-- ---------------------------------------------------------------------------
-- Pure - the parts a fixture can reach
-- ---------------------------------------------------------------------------

-- The form's model -> a definition. Returns (def) or (nil, reason); the reason
-- is shown verbatim.
function DFVarEditor.buildDef(model)
    model = model or {}
    local key, display = RDVarDefs.normalizeName(model.name)
    if not key then return nil, display end

    if model.kind == RDVarDefs.FLAG then
        -- Only revokers the admin actually set. `death = false` is deliberately
        -- NOT written: RDVarDefs treats the absence of a revoker and one set to
        -- false as different things, and storing the second leaves a key behind
        -- that makes the flag read as revocable while nothing revokes it
        -- (RDVarDefs.lua, validateRevokers).
        local revokers = {}
        if model.death == true then revokers.death = true end
        if type(model.expires) == "number" and model.expires > 0 then
            revokers.expires = model.expires
        end
        if type(model.kit) == "string" and model.kit ~= "" then
            revokers.kit = model.kit
        end
        return { kind = RDVarDefs.FLAG, name = display, revokers = revokers }
    end

    if model.kind == RDVarDefs.COUNTER then
        -- A WORLD COUNTER CARRIES NO resetOnDeath AT ALL, and this omits the
        -- field rather than sending false. RDVarDefs refuses the key outright
        -- on a world counter - there is no holder whose death it could mean -
        -- so sending it would be a save that fails for a reason the form
        -- already knows about.
        if model.scope == RDVarDefs.SCOPE_WORLD then
            return { kind = RDVarDefs.COUNTER, name = display,
                     scope = RDVarDefs.SCOPE_WORLD }
        end
        -- The three-way choice. "" is the unmoved dial, refused rather than
        -- read as false - see the header.
        if model.resetOnDeath ~= "yes" and model.resetOnDeath ~= "no" then
            return nil, "Choose whether this counter resets on death. There is "
                .. "no default - a counter that quietly picked one would be "
                .. "behaviour nobody chose."
        end
        return { kind = RDVarDefs.COUNTER, name = display,
                 scope = RDVarDefs.SCOPE_PLAYER,
                 resetOnDeath = model.resetOnDeath == "yes" }
    end

    return nil, "Choose a kind."
end

-- A stored definition -> the form's model. The inverse of buildDef, and it has
-- to be exact: a round trip that dropped a revoker would silently strip it from
-- a variable an admin only opened to rename.
function DFVarEditor.modelOf(def)
    if not def then
        return { name = "", kind = RDVarDefs.FLAG, death = false,
                 expires = 0, kit = "", resetOnDeath = "",
                 -- Scope DOES open on an answer, unlike resetOnDeath. Every
                 -- counter that has ever existed is per-player, so this is the
                 -- status quo rather than a default nobody chose - see
                 -- RDVarDefs' header for why the two are not the same call.
                 scope = RDVarDefs.SCOPE_PLAYER }
    end
    local r = def.revokers or {}
    return {
        name         = def.name or "",
        kind         = def.kind or RDVarDefs.FLAG,
        death        = r.death == true,
        expires      = tonumber(r.expires) or 0,
        kit          = r.kit or "",
        -- An existing counter HAS an answer, so the dial opens on it. The
        -- "- choose -" state exists for a counter nobody has decided about yet,
        -- and re-presenting it here would ask a question already answered.
        resetOnDeath = (def.resetOnDeath == true and "yes")
                    or (def.resetOnDeath == false and "no") or "",
        -- An older definition, or a flag, has no scope. Reading that as
        -- per-player is exactly what an absent scope has always meant.
        scope        = (def.scope == RDVarDefs.SCOPE_WORLD)
                       and RDVarDefs.SCOPE_WORLD or RDVarDefs.SCOPE_PLAYER,
    }
end

-- One row's value column. The flag/counter split again, and BOTH dashes are
-- load-bearing: a flag's is "does not hold it", a counter's is "nobody has ever
-- touched this", and the second is emphatically not zero.
function DFVarEditor.cellFor(kind, row)
    row = row or {}
    if kind == RDVarDefs.FLAG then return row.holds and "holds" or "-" end
    if row.value == nil then return "-" end
    return tostring(row.value)
end

-- THE BAND ABOVE THE HOLDER LIST, and it leads with the holder count on
-- purpose. holdersOf hands back every ONLINE player alongside the actual
-- holders (DFVars_Server.lua) so the Add and Set verbs have something to aim at
-- without an admin typing a username. That roster is right. The caption was
-- not: it read "Players: 1", so a brand new flag nobody holds opened with the
-- admin's own name on row one under a number that counted ROWS - which reads,
-- correctly, as "it added me".
--
-- So the line answers three questions in the order they get asked: how many
-- hold it, how many of the rest are merely online and pickable, and how many
-- the row bound is hiding. PURE, because it is the sentence the whole window
-- exists to say and it must not be able to lie about it.
function DFVarEditor.rosterLine(holders)
    if not holders then return "Loading..." end

    -- A world counter has nobody to count. It reports the number it holds, and
    -- ABSENT IS NOT ZERO here either: a counter nothing has touched has never
    -- run, and drawing that as 0 would report a quest as completed zero times
    -- when the truth is that the counter has never been written at all. Every
    -- repeatable thing built on this gates on the difference.
    if holders.scope == RDVarDefs.SCOPE_WORLD then
        if holders.value == nil then
            return "Server-wide.   Never set - nothing has written to it yet."
        end
        return "Server-wide.   Value: " .. tostring(holders.value)
    end

    local counter = holders.kind == RDVarDefs.COUNTER
    local rows, held = holders.rows or {}, 0
    for _, row in ipairs(rows) do
        -- The absent/zero split again: a counter row counts as "set" when it
        -- has a value at all, INCLUDING zero. Testing truthiness here would
        -- report a player deliberately set to 0 as never having been touched.
        if counter then
            if row.value ~= nil then held = held + 1 end
        elseif row.holds then held = held + 1 end
    end

    local line = (counter and "Set for: " or "Holders: ") .. held
    local others = #rows - held
    if others > 0 then
        line = line .. "   -   " .. others .. " more online, listed to pick from"
    end
    local total = tonumber(holders.total) or #rows
    if total > #rows then
        line = line .. "   -   " .. (total - #rows) .. " not shown"
    end
    return line
end

-- What a definition says about itself, in one line.
function DFVarEditor.lifecycleOf(d)
    if not d then return "" end
    if d.kind == RDVarDefs.COUNTER then
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

-- One player's record -> a row in this variable's holder list, selected.
-- PURE apart from the module fields it writes, so a fixture can drive it.
function DFVarEditor.spliceRecord(record)
    if not record or not record.username or not E.holders then return false end

    local row = { user = record.username, pinned = true }
    for _, c in ipairs(record.flags or {}) do
        if c.name == E.holders.name then row.holds = true end
    end
    for _, n in ipairs(record.numbers or {}) do
        if n.name == E.holders.name then row.value = n.value end
    end

    -- Already listed - online, or a holder inside the bound. Select, do not
    -- duplicate: two rows for one player is two answers to one question.
    for _, existing in ipairs(E.holders.rows) do
        if existing.user == row.user then
            E.selectedUser = row.user
            DFVarEditor.rebuild()
            return true
        end
    end

    table.insert(E.holders.rows, row)
    E.selectedUser = row.user
    DFVarEditor.rebuild()
    return true
end

-- The selected player, or nil. Answers from the remembered USERNAME and
-- confirms it is still listed, so somebody who dropped out between refreshes
-- yields no target rather than the wrong one.
function DFVarEditor.targetUser()
    if not E.selectedUser or not E.holders then return nil end
    for _, row in ipairs(E.holders.rows or {}) do
        if row.user == E.selectedUser then return row.user end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Wire
--
-- sendClientCommand is written out at each call site rather than wrapped. That
-- is DFLayout's pattern in this same folder, and it is not a style choice: a
-- local `send` here would be a character-for-character copy of DFVarsView's,
-- which check-helpers reads as exactly what it is.
-- ---------------------------------------------------------------------------

-- Holder traffic belongs to whichever editor is open. DFVarsView owns the one
-- OnServerCommand listener and forwards here, so there is one intake rather
-- than two racing listeners for the same replies.
function DFVarEditor.receive(command, args)
    if command == "AdminVarHolders" then
        -- Answers arrive unordered against clicks. A reply for a variable this
        -- window is not showing is dropped rather than drawn under the wrong
        -- heading, which would attribute one variable's holders to another.
        if E.win and args and args.name == E.win.varName then
            E.holders = args
            DFVarEditor.rebuild()
        end
        return true

    elseif command == "AdminVarsPlayer" then
        -- Two callers, one reply. Every grant/revoke/set/reset is followed by a
        -- per-player push - including a refused one - and this window is
        -- organised by VARIABLE, so for those the useful part is simply that
        -- something changed and the holder list should be re-read.
        --
        -- The other caller is "By name": somebody offline AND past the row
        -- bound appears in no list, so the window fetches their record and
        -- SPLICES them in, which is what makes every verb reach them rather
        -- than only the two an ask-and-send button could perform.
        if args and args.username and args.username == E.pending then
            E.pending = nil
            DFVarEditor.spliceRecord(args)
            return true
        end
        if E.win then
            sendClientCommand(getPlayer(), DFCore.MODULE, "varHolders",
                { name = E.win.varName })
        end
        return true
    end
    return false
end

-- ---------------------------------------------------------------------------
-- The form's schema
-- ---------------------------------------------------------------------------

local function defineSchema(model, locked)
    local out = {
        { key = "name", kind = "text", label = "Name",
          rule = "Starts with a letter, then letters, digits, underscore or "
              .. "hyphen. At most " .. RDVarDefs.NAME_MAX .. " characters.",
          help = "The name consumers use. Case is kept for display and ignored "
              .. "for matching, so Anomaly and anomaly are the same variable.",
          validate = function(s)
              local key, why = RDVarDefs.normalizeName(s)
              if not key then return false, why end
              return true
          end },
        { key = "kind", kind = "choice", label = "Kind",
          values = { RDVarDefs.FLAG, RDVarDefs.COUNTER },
          labels = { "Flag", "Counter" },
          -- Locked on an existing variable: RDVars refuses a kind change under
          -- a live name outright, because every holder's state is in the wrong
          -- half of their record the moment it moves (RDVars.define). Offering
          -- the dial and refusing the save is a worse version of not offering
          -- it.
          locked = locked,
          help = locked
              and "A variable's kind cannot change once it exists - every "
               .. "holder's value lives in the half that matches it. Delete it "
               .. "and create it again to change this."
              or "A FLAG is present or absent and has a lifecycle - cleared on "
               .. "death, after an interval, or when a kit is claimed. A "
               .. "COUNTER is a number. They are not one thing with a switch: a "
               .. "flag's absence and a counter's zero mean different things, "
               .. "and quests depend on the difference." },
    }
    if model.kind == RDVarDefs.FLAG then
        out[#out + 1] = { group = "Cleared by" }
        out[#out + 1] = { key = "death", kind = "bool", label = "Death",
            help = "Cleared when the holder dies." }
        out[#out + 1] = { key = "expires", kind = "int", label = "Time limit",
            min = 0, max = 100000, step = 15, unit = "minutes", zero = "no limit",
            help = "Real minutes from the moment it is granted. Re-granting "
                .. "starts the clock again." }
        -- The "none of the above" case rides on the LAST field's help rather
        -- than a schema row of its own: DFForm's rows are dials and group
        -- headers, and a third kind that is neither would draw as a dial with
        -- no key.
        out[#out + 1] = { key = "kit", kind = "text", label = "Kit id",
            empty = "(none)",
            help = "Cleared when that kit is claimed. Leave empty for none. "
                .. "With none of these three set, the flag is permanent until "
                .. "an admin removes it." }
    elseif model.kind == RDVarDefs.COUNTER then
        out[#out + 1] = { key = "scope", kind = "choice", label = "Counted for",
            values = { RDVarDefs.SCOPE_PLAYER, RDVarDefs.SCOPE_WORLD },
            labels = { "Each player", "The whole server" },
            -- Locked for the same reason kind is: the value lives in a
            -- different half of the store depending on the answer, and RDVars
            -- has no move between them. Offering the dial and failing the save
            -- is a worse version of not offering it.
            locked = locked,
            help = locked
                and "A counter's scope cannot change once it exists - a "
                 .. "per-player counter's values live in the player records "
                 .. "and a world counter's lives once. Delete it and create it "
                 .. "again to change this."
                or "EACH PLAYER gives everybody their own number - 'Alice has "
                 .. "5 of 10 samples'. THE WHOLE SERVER keeps one, for "
                 .. "'this quest has been finished 43 times'. A world counter "
                 .. "has no holders and appears on nobody's variables list." }
        if model.scope ~= RDVarDefs.SCOPE_WORLD then
            out[#out + 1] = { key = "resetOnDeath", kind = "choice",
                label = "Reset on death",
                values = { "", "yes", "no" },
                labels = { "- choose -", "Yes", "No" },
                help = "There is no default, deliberately. A counter that quietly "
                    .. "picked one would be behaviour nobody chose, found months "
                    .. "later." }
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- The holder list
-- ---------------------------------------------------------------------------

local HolderList = ISScrollingListBox:derive("DFVarEditorHolders")

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
    -- holds both on purpose, so which is which has to be visible without
    -- spending a column on it.
    local c = row.online and DFKit.col.text or DFKit.col.textDim
    -- A row fetched by name is marked: it is the one row not there because the
    -- server volunteered it.
    local label = row.pinned and (row.user .. "  *") or row.user
    self:drawText(DFKit.fitText(label, FONT, self.width - 90), 6, y + 3,
                  c.r, c.g, c.b, 1, FONT)
    local cell = DFVarEditor.cellFor(E.holders and E.holders.kind, row)
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
    E.selectedUser = row and row.user or nil
    if E.win then E.win.status = nil end
end

function DFVarEditor.rebuild()
    local win = E.win
    if not win or not win.holderBox then return end
    DFKit.refillList(win.holderBox, function(box)
        for _, row in ipairs((E.holders and E.holders.rows) or {}) do
            local i = box:addItem(row.user, row)
            i.height = DFKit.rowHeight()
        end
    end)

    -- Put the widget back where the USERNAME says it is. refillList calls
    -- clear(), which sets selected = 1; left alone this window would highlight -
    -- and act on - whoever happens to be first after every single action.
    local box = win.holderBox
    box.selected = -1
    if E.selectedUser then
        for i, item in ipairs(box.items) do
            if item.item and item.item.user == E.selectedUser then
                box.selected = i
                break
            end
        end
        -- Gone from the list entirely: forget it rather than leaving a stale
        -- name behind a highlight nobody can see.
        if box.selected == -1 then E.selectedUser = nil end
    end
end

-- ---------------------------------------------------------------------------
-- The window
-- ---------------------------------------------------------------------------

local Editor = ISCollapsableWindow:derive("DFVarEditorWindow")

-- The one-line text prompt lives in Core now: DFKit.askText, promoted
-- 2026-08-25 from the identical copy this file and its sibling both carried.

function Editor:needUser()
    local user = DFVarEditor.targetUser()
    if not user then self.status = "Select a player first."; return nil end
    return user
end

function Editor:createChildren()
    ISCollapsableWindow.createChildren(self)
    local m   = DFKit.metrics
    local pad = m.pad
    local top = self:titleBarHeight() + pad
    local footH = m.btnH + pad * 2
    local win = self

    -- THE ROSTER CAPTION GETS ITS OWN BAND. It used to be drawn at
    -- holderBox:getY() - pad - 2, which is two pixels ABOVE the form's bottom
    -- edge - so the caption rendered inside the form's clip rect and the form's
    -- last visible row rendered through the caption. Exactly the collision the
    -- Variables tab had with its column headings, and the same fix: reserve the
    -- band, then place the list under it.
    --
    -- rowHeight() measures the font (DFKit.lua:325-333); the text tier is a
    -- client preference, so a hard-coded band is only correct at one of them.
    local bandH = DFKit.rowHeight()
    local avail = self.height - top - footH

    self.form = DFForm.new{
        title      = "Definition",
        inlineHelp = true,
        schema     = defineSchema(self.model, self.existing ~= nil),
        get        = function(k) return win.model[k] end,
        set        = function(k, v)
            win.model[k] = v
            -- Both of these decide which fields exist at all, so changing
            -- either rebuilds rather than greys: the kind decides between
            -- revokers and resetOnDeath, and the scope decides whether
            -- resetOnDeath is a row at all. Neither is a disabled control -
            -- they are fields that do not apply.
            if k == "kind" or k == "scope" then
                win.form.schema = defineSchema(win.model, win.existing ~= nil)
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

    -- SIZED FROM THE FORM'S OWN CONTENT, not from a tuned fraction - the
    -- DMKitForm rule (its Geometry section has the full argument), applied
    -- here 2026-08-25 before anyone hit it. The old split was
    -- `listH = floor((avail - fixed) * 0.42)`, which handed the form whatever
    -- the fraction left: at any font taller than the one it was tuned
    -- against, the last rows slid below the fold, and a verb refusing over a
    -- control that is not on screen is a dead end with a refusal attached.
    -- The holder list gives first, down to a floor - it scrolls by nature and
    -- carries a bar the whole time, so a short list is an inconvenience where
    -- a short form is a trap. Only if the SCREEN cannot hold even that does
    -- the form scroll after all.
    --
    -- A world counter gets the definition form and a verb row but NO holder
    -- list - there is nobody to list. It keeps the band, because the value is
    -- the one thing that window exists to show, and it keeps the verb row, so
    -- the fixed height is the same for both; only the list is missing, and
    -- its space goes to the form.
    local hasList = self.existing and not self.world
    local fixed = self.existing and (bandH + m.btnH + pad * 2 + m.gap) or pad
    local body = avail - fixed
    local formH, listH
    if hasList then
        -- Measured, and laid out once first: with inline help on, the wrap
        -- width decides how tall every row is, and layout() is what records
        -- that width (DFForm.lua:341-346); contentHeight() then answers for
        -- the width the form is actually drawn at.
        self.form:layout(pad, top, self.width - pad * 2, body)
        local LIST_MIN = DFKit.rowHeight() * 2
        formH = math.min(self.form:contentHeight(), math.max(0, body - LIST_MIN))
        listH = body - formH
    else
        formH, listH = body, 0
    end
    self.form:layout(pad, top, self.width - pad * 2, formH)

    if self.existing and not self.world then
        self.bandY = top + formH + pad
        local list = HolderList:new(pad, self.bandY + bandH,
                                    self.width - pad * 2, listH)
        list.itemheight = DFKit.rowHeight()
        list.drawBorder = true
        DFKit.well(list)
        list:initialise(); list:instantiate()
        self:addChild(list)
        self.holderBox = list

        local isFlag = self.existing.kind == RDVarDefs.FLAG
        local by = list:getY() + list:getHeight() + m.gap
        local bx = pad

        -- Labelled for what they do HERE. "Grant" and "Revoke" are the server's
        -- verbs; on a membership list the admin is adding and removing people.
        local specs = isFlag
            and { { 84, "Add", function()
                        local u = win:needUser(); if not u then return end
                        sendClientCommand(getPlayer(), DFCore.MODULE,
                            "varGrant", { user = u, name = win.varName })
                    end, "action",
                    "Give this flag to the selected player." },
                  { 84, "Remove", function()
                        local u = win:needUser(); if not u then return end
                        sendClientCommand(getPlayer(), DFCore.MODULE,
                            "varRevoke", { user = u, name = win.varName })
                    end, nil,
                    "Take this flag off the selected player." } }
            or  { { 84, "Set", function()
                        local u = win:needUser(); if not u then return end
                        DFKit.askText("Set '" .. win.varName .. "' for " .. u .. " to:",
                            function(text)
                                local n = tonumber(text)
                                if not n then win.status = "That is not a number."; return end
                                sendClientCommand(getPlayer(), DFCore.MODULE,
                                    "varSet", { user = u, name = win.varName, value = n })
                            end)
                    end, "action",
                    "Set the selected player's counter." },
                  { 84, "Clear", function()
                        local u = win:needUser(); if not u then return end
                        sendClientCommand(getPlayer(), DFCore.MODULE,
                            "varReset", { user = u, name = win.varName })
                    end, nil,
                    "Return the selected player's counter to ABSENT, which is "
                    .. "not the same as zero." } }

        -- The escape hatch for anybody the list does not show: an offline
        -- holder past the row bound, or somebody who has never held this and is
        -- not online now.
        --
        -- It FETCHES rather than acting. An earlier version performed one verb,
        -- which meant the two REMOVING verbs had no by-name route at all - so a
        -- holder past the bound could be given things forever and never have
        -- them taken away. Bringing them into the list makes every verb reach
        -- them, and reuses the varsOfPlayer read that already existed.
        specs[#specs + 1] = { 96, "By name", function()
            DFKit.askText("Look up which username?", function(user)
                E.pending  = user
                win.status = "Looking up " .. user .. "..."
                sendClientCommand(getPlayer(), DFCore.MODULE, "varsOfPlayer",
                    { user = user })
            end)
        end, nil, "Bring somebody into the list who is not in it - offline, or "
               .. "someone who has never held this. Every verb then reaches them." }

        for _, s in ipairs(specs) do
            DFKit.button(self, bx, by, s[1], s[2], self, s[3], s[4],
                         { tooltip = s[5] })
            bx = bx + s[1] + m.gap
        end
    end

    if self.world then
        -- The same two verbs the per-player half has, minus the player. Set
        -- and Clear rather than Set and "zero": clearing returns the counter to
        -- ABSENT, which is not the same as a run that finished zero times.
        self.bandY = top + formH + pad
        local by = self.bandY + bandH + m.gap
        local bx2 = pad
        for _, spec in ipairs({
            { 84, "Set", function()
                DFKit.askText("Set '" .. win.varName .. "' to:", function(text)
                    local n = tonumber(text)
                    if not n then win.status = "That is not a number."; return end
                    sendClientCommand(getPlayer(), DFCore.MODULE, "varWorldSet",
                        { name = win.varName, value = n })
                end)
            end, "action", "Set the server-wide value." },
            { 84, "Clear", function()
                sendClientCommand(getPlayer(), DFCore.MODULE, "varWorldReset",
                    { name = win.varName })
            end, nil, "Return this counter to ABSENT, which is not the same as "
                   .. "zero - absent means nothing has ever written to it." },
        }) do
            DFKit.button(self, bx2, by, spec[1], spec[2], self, spec[3], spec[4],
                         { tooltip = spec[5] })
            bx2 = bx2 + spec[1] + m.gap
        end
    end

    local bx = self.width - pad
    local saveLabel = self.existing and "Save" or "Create"
    for _, spec in ipairs({ { 80, saveLabel, function() win:commit() end, "action" },
                            { 80, "Cancel", function() win:close() end, nil } }) do
        bx = bx - spec[1]
        DFKit.button(self, bx, self.height - footH, spec[1], spec[2], self,
                     spec[3], spec[4])
        bx = bx - m.gap
    end
    self.footY = self.height - footH + 4
end

function Editor:commit()
    local def, why = DFVarEditor.buildDef(self.model)
    if not def then self.status = why; return end
    sendClientCommand(getPlayer(), DFCore.MODULE, "varDefine", { def = def })
    -- A rename creates a NEW variable rather than moving the old one: the name
    -- IS the key, and RDVars has no rename. Say so instead of leaving an admin
    -- to discover two variables where they expected one.
    if self.existing and def.name ~= self.existing.name then
        self.status = "Saved as '" .. def.name .. "'. The old '"
            .. self.existing.name .. "' still exists - delete it if you meant "
            .. "to rename."
        return
    end
    self:close()
end

function Editor:prerender()
    ISCollapsableWindow.prerender(self)
    self.form:draw(self)
    -- The world half has a band and a value but no list, so the caption is
    -- drawn on its own. Same line, same source: rosterLine answers for both.
    if self.world and self.bandY then
        local t = DFKit.col.textDim
        self:drawText(DFKit.fitText(DFVarEditor.rosterLine(E.holders), FONT,
                                    self.width - DFKit.metrics.pad * 2),
                      DFKit.metrics.pad, self.bandY, t.r, t.g, t.b, 1, FONT)
    end
    if self.existing and self.holderBox and self.bandY then
        local t   = DFKit.col.textDim
        local pad = DFKit.metrics.pad
        -- The value column's caption, right-aligned to the exact x the cells
        -- draw at: HolderList puts its cell at listW - w - 6 and the list sits
        -- at x = pad, so the screen column is width - pad - w - 6. Naming it is
        -- what turns a lone "-" from "something is missing" into "does not hold
        -- it", which is the whole answer for a non-holder row.
        local cap = (self.existing.kind == RDVarDefs.FLAG) and "HOLDS" or "VALUE"
        local cw  = getTextManager():MeasureStringX(FONT, cap)
        local capX = self.width - pad - cw - 6
        self:drawText(cap, capX, self.bandY, t.r, t.g, t.b, 1, FONT)
        self:drawText(DFKit.fitText(DFVarEditor.rosterLine(E.holders), FONT,
                                    capX - pad - DFKit.metrics.gap),
                      pad, self.bandY, t.r, t.g, t.b, 1, FONT)
    end
    if self.status then
        local a = DFKit.col.accent
        self:drawText(DFKit.fitText(self.status, FONT, self.width - 180),
                      DFKit.metrics.pad, self.footY, a.r, a.g, a.b, 1, FONT)
    end
end

function Editor:close()
    E.win, E.holders, E.selectedUser, E.pending = nil, nil, nil, nil
    self:removeFromUIManager()
end

-- ---------------------------------------------------------------------------

local function openWindow(existing)
    if E.win then E.win:close() end

    local w = existing and 560 or 460
    -- The world editor is shorter by the list it does not have.
    local h = (existing and not RDVarDefs.isWorld(existing)) and 620 or 420
    local win = Editor:new(getCore():getScreenWidth() / 2 - w / 2,
                           getCore():getScreenHeight() / 2 - h / 2, w, h)
    win.existing = existing
    win.world    = RDVarDefs.isWorld(existing)
    win.varName  = existing and existing.name or nil
    win.model    = DFVarEditor.modelOf(existing)
    win:setTitle(existing
        and (((existing.kind == RDVarDefs.FLAG and "Flag: ")
              or (RDVarDefs.isWorld(existing) and "World counter: ")
              or "Counter: ") .. existing.name)
        or "New variable")
    win:setResizable(false)
    win:initialise(); win:instantiate(); win:addToUIManager()

    E.win = win
    E.holders, E.selectedUser, E.pending = nil, nil, nil
    if existing then
        sendClientCommand(getPlayer(), DFCore.MODULE, "varHolders",
            { name = existing.name })
    end
    return win
end

-- A new variable: the definition form alone. There is nothing to hold it yet.
function DFVarEditor.openNew() return openWindow(nil) end

-- An existing one: its definition AND its membership, which is the pairing
-- every real question needs.
function DFVarEditor.open(def) return openWindow(def) end

return DFVarEditor

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
