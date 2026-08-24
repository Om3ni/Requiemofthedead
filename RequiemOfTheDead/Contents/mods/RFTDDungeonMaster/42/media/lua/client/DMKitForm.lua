-- SPDX-License-Identifier: GPL-3.0-or-later
-- DMKitForm - one kit: what it is, what it requires, what it grants.
--
-- The other half of DMKitsTab. That file owns the catalogue; this one owns a
-- single kit's shape, and they change for different reasons - a list gains a
-- sort, a kit gains a grant kind.
--
-- ---------------------------------------------------------------------------
-- THE FORM NEVER VALIDATES A KIT. DMKitDefs does, on the server, at save time,
-- and its refusals are written to be shown verbatim. Re-implementing those
-- rules here would be a second copy of the schema that drifts the first time
-- one of them changes - and the one that drifts is always the copy the DM is
-- looking at. What this file does instead is BUILD a candidate and show the
-- server's sentence when it is refused.
--
-- The exception is per-field shape inside the row modal - "an item count must
-- be a whole number" - because a dial that accepts text the schema will refuse
-- is a round trip to learn something the control already knew. Those are
-- DFForm validators on individual fields, never a rule about the kit.
--
-- ---------------------------------------------------------------------------
-- ROULETTE GRANTS ARE CARRIED, NOT EDITED (owner, 2026-08-23: pause before the
-- roulette UI). A kit authored externally, or by a later build, can contain
-- one; this form lists it, says how many branches it has, and writes it back
-- BYTE FOR BYTE on save.
--
-- That is the whole reason the grants list holds the original tables rather
-- than a per-row model rebuilt from dials. A form that could only express what
-- its dials cover would silently strip a roulette from any kit an admin opened
-- to fix a typo in - and the DM would find out when a player claimed the kit
-- and got the consolation branch every time, because the rare one was gone.
--
-- ---------------------------------------------------------------------------
-- ONE KIT, ONE REWARD TYPE. The kind dial is not decoration: DMKitDefs refuses
-- a kit whose grants include a reward of another kind, and refuses one that
-- grants nothing of its own kind. The Add menu therefore offers the kit's own
-- reward kind plus the two bookkeeping kinds, and nothing else - offering all
-- five and letting the save fail would be teaching the rule by refusal.

if isServer() then return end

require "DFKit"
require "DFForm"
require "DFItemQuery"
require "DFConfirm"
require "DMKitDefs"
require "ISUI/ISScrollingListBox"
require "ISUI/ISCollapsableWindow"
require "ISUI/ISContextMenu"

DMKitForm = DMKitForm or {}
local F = DMKitForm

local TOKEN = "RFTDDungeonMaster"
local FONT  = DFKit.font.small

-- One at a time. Two editors on one kit would disagree the moment either saved,
-- and the loser would not know it had lost.
F.win = nil

-- ---------------------------------------------------------------------------
-- Pure
-- ---------------------------------------------------------------------------

-- The form's model -> a candidate definition. NOT a validated one: this returns
-- the table the server is asked to accept, and every rule about it lives there.
-- Returns (def) or (nil, reason) for the two things the form itself knows -
-- there is no kind, and there is nothing to grant.
function DMKitForm.buildDef(model, grants, requires)
    model = model or {}
    if not DMKitDefs.KIT_KINDS[model.kind] then
        return nil, "Choose what kind of kit this is."
    end
    if #(grants or {}) == 0 then
        return nil, "A kit must grant something."
    end

    -- claim.once is written from a THREE-state dial, and "" is refused here
    -- rather than defaulted. DMKitDefs gives the reason: the unchosen answer is
    -- a kit that can be farmed, and it would be discovered months later.
    if model.answered ~= "set" then
        -- NAMES THE DIAL, not just the question. A refusal that describes a
        -- setting without naming it sends the reader hunting, which is exactly
        -- how this window's sizing bug was found: the message asked for an
        -- answer and the control it wanted was off the bottom of the pane.
        return nil, "Set 'Claim policy', then the wait beneath it. There is no "
            .. "default: the unchosen answer is a kit with no wait, which can "
            .. "be farmed. Zero is a fine answer - it just has to be chosen."
    end

    local def = {
        id    = model.id,
        kind  = model.kind,
        label = (model.label ~= "" and model.label) or nil,
        note  = (model.note ~= "" and model.note) or nil,
        claim = { cooldownHours = DMKitDefs.joinCooldown(model.waitDays,
                                                        model.waitHours) },
        grants = grants,
    }

    -- An empty requirement set is OMITTED rather than sent as two empty lists.
    -- DMKitDefs normalizes either into the same thing, but the wire payload and
    -- the stored document read differently, and "requires: nothing" is clearer
    -- as an absent field than as two empty arrays.
    local flags, counters = requires.flags or {}, requires.counters or {}
    if #flags > 0 or #counters > 0 then
        def.requires = { flags = flags, counters = counters }
    end
    return def
end

-- A stored definition -> the form's model. The exact inverse of buildDef, and
-- it has to be: a round trip that dropped a field would strip it from a kit an
-- admin only opened to read.
function DMKitForm.modelOf(def)
    if not def then
        return { id = "", kind = DMKitDefs.ITEM, label = "", note = "",
                 answered = "", waitDays = 0, waitHours = 0 }
    end
    return {
        id    = def.id or "",
        kind  = def.kind or DMKitDefs.ITEM,
        label = def.label or "",
        note  = def.note or "",
        -- An existing kit HAS an answer, so the dial opens on it. The
        -- "- choose -" state exists for a kit nobody has decided about yet.
        -- An existing kit HAS an answer, whatever it is - including zero.
        answered = "set",
        waitDays = select(1, DMKitDefs.splitCooldown(
            def.claim and def.claim.cooldownHours)),
        waitHours = select(2, DMKitDefs.splitCooldown(
            def.claim and def.claim.cooldownHours)),
    }
end

-- A DEEP copy of the stored grants, so editing a row cannot mutate the
-- catalogue this client is still drawing behind the window. Roulette branches
-- come through whole - see the header: they are carried, not editable, and a
-- shallow copy would let a later edit reach into the shared table anyway.
function DMKitForm.copyGrants(def)
    local function clone(v)
        if type(v) ~= "table" then return v end
        local out = {}
        for k, inner in pairs(v) do out[k] = clone(inner) end
        return out
    end
    return clone((def and def.grants) or {})
end

function DMKitForm.copyRequires(def)
    local req = (def and def.requires) or {}
    local out = { flags = {}, counters = {} }
    for _, name in ipairs(req.flags or {}) do out.flags[#out.flags + 1] = name end
    for _, c in ipairs(req.counters or {}) do
        out.counters[#out.counters + 1] = { name = c.name, atLeast = c.atLeast }
    end
    return out
end

-- Which grant kinds this kit may hold. The kit's own reward kind, then the two
-- bookkeeping kinds - never the other two rewards, because DMKitDefs refuses
-- them and an Add menu that offers a refusal is a rule taught the hard way.
function DMKitForm.addableKinds(kitKind)
    local out = {}
    if DMKitDefs.KIT_KINDS[kitKind] then out[#out + 1] = kitKind end
    out[#out + 1] = DMKitDefs.FLAG
    out[#out + 1] = DMKitDefs.COUNTER
    return out
end

-- Can this row be opened? A roulette cannot, yet, and saying so is the whole
-- of the pause: a row that opened an empty editor would read as a grant with
-- nothing in it.
function DMKitForm.isEditable(g)
    return type(g) == "table" and g.kind ~= DMKitDefs.ROULETTE
end

-- ---------------------------------------------------------------------------
-- ADDING ITEMS IN BULK
--
-- One at a time is right when you are deciding as you go. It is the wrong tool
-- entirely when the list already exists - somebody has written the event loot
-- down, and typing twelve rows through a modal is transcription, not authoring
-- (owner, 2026-08-23).
--
-- THE SYNTAX IS WHAT THE GRANTS LIST ALREADY PRINTS. grantLine renders an item
-- as `item  Base.Axe x1`, so the parser accepts `Base.Axe x1` - which means the
-- list an admin READS in the pane below is a list they can retype, paste, or
-- lift out of one kit and into another. That symmetry is the reason for the
-- `xN` form rather than `*N` or `5 Base.Axe`; it was already the house
-- notation and nobody has to learn a second one.
--
-- NO NAME RESOLUTION HERE, deliberately. The type-ahead resolves "nails" to
-- "Base.Nails" one entry at a time, with a human looking at the candidates.
-- Doing that silently for twelve tokens means twelve chances to pick a
-- plausible wrong item, and the DM would find out when a player claimed the
-- kit. A list is full types; the search is for when you do not know one.
--
-- SHAPE ONLY, per this file's standing rule: whether `Base.Axe` EXISTS is the
-- server's answer at save time. What is refused here is what the field itself
-- can see - an empty list, a token with no module, a count that is not a
-- positive whole number, and a type carrying whitespace, which is always a
-- mistyped separator rather than a real item.
-- ---------------------------------------------------------------------------

-- Returns (entries, why). Each entry is { type = , count = }.
function DMKitForm.parseItemList(text, defaultCount)
    if type(text) ~= "string" then return nil, "An item type is required." end
    local fallback = tonumber(defaultCount) or 1
    if fallback < 1 then fallback = 1 end

    local out = {}
    -- The trailing comma is forgiven: it is what a list being built ends with,
    -- and refusing it teaches nothing.
    for token in (text .. ","):gmatch("(.-),") do
        local piece = token:match("^%s*(.-)%s*$")
        if piece ~= "" then
            local count = fallback
            -- ` xN` at the end, the same way the list prints it. The head
            -- cannot come back empty: the token was trimmed before this, so
            -- the required whitespace before the x guarantees something
            -- precedes it. A bare "x5" simply never matches here and is
            -- refused below for having no module.
            local head, n = piece:match("^(.-)%s+[xX]%s*(%d+)$")
            if head then
                piece = head:match("^%s*(.-)%s*$")
                count = tonumber(n)
                if not count or count < 1 then
                    return nil, "'" .. token
                        .. "' asks for a count below one - leave it off for a single item."
                end
            end
            if piece:find("%s") then
                return nil, "'" .. piece .. "' has a space in it. An item type "
                    .. "has none, so this is usually a missing comma - or a "
                    .. "count written without its x."
            end
            if not piece:find(".", 1, true) then
                return nil, "'" .. piece .. "' needs its module - it is "
                    .. "probably 'Base." .. piece .. "'."
            end
            out[#out + 1] = { type = piece, count = count }
        end
    end

    if #out == 0 then return nil, "An item type is required." end
    return out
end

-- How many items a parsed list hands over in total. The whole-kit cap is the
-- server's rule, but a list is the one input that can blow past it in a single
-- keystroke, and learning that after typing forty entries is the round trip
-- this file exists to avoid.
function DMKitForm.itemTotal(entries)
    local n = 0
    for _, e in ipairs(entries or {}) do n = n + (tonumber(e.count) or 0) end
    return n
end

-- One row model -> the grants it produces. A list yields many; everything else
-- yields one, so the caller has a single shape to append.
function DMKitForm.expandGrants(kind, model, allowList)
    if kind ~= DMKitDefs.ITEM or not allowList then
        local g = DMKitForm.rowGrant(kind, model)
        return g and { g } or {}, nil
    end
    local entries, why = DMKitForm.parseItemList((model or {}).type,
                                                 (model or {}).count)
    if not entries then return nil, why end
    local out = {}
    for _, e in ipairs(entries) do
        out[#out + 1] = { kind = DMKitDefs.ITEM, type = e.type, count = e.count }
    end
    return out
end

-- The dials for one grant, by kind. Field-level shape only - see the header.
--
-- `allowList` is on for Add and OFF for Edit: one row edits one item, and a
-- list typed into an existing row would silently turn it into several, which
-- is a thing nobody asked a row editor to do.
function DMKitForm.rowSchema(kind, allowList)
    if kind == DMKitDefs.ITEM then
        return {
            { key = "type", kind = "text", label = "Item type",
              rule = allowList
                  and "One type, or a comma-separated list: Base.Nails x5, Base.Axe"
                  or  "Type a few letters and pick from the list, e.g. nails",
              help = "The full script type, module included. Start typing and "
                  .. "the list narrows - the same search as the admin panel's "
                  .. "Add Item field, and the same one behind it. The server "
                  .. "checks the type against the item scripts when the kit is "
                  .. "saved, so a typo is refused now rather than handing a "
                  .. "player nothing."
                  .. (allowList and ("  A COMMA-SEPARATED LIST adds one grant "
                      .. "per entry: 'Base.Nails x5, Base.Axe, Base.Hammer x2'. "
                      .. "That is exactly how the grants list below prints them, "
                      .. "so a list can be read off one kit and pasted into "
                      .. "another. An entry without its own xN uses the Count "
                      .. "dial. The search only fills one type at a time - a "
                      .. "list is for when you already know them.") or ""),
              -- ONE search for both surfaces (DFItemQuery, in Core). A second
              -- ranker here would drift from the one an admin already knows,
              -- and "nails finds it over there but not in here" is the kind of
              -- difference nobody reports as a bug.
              suggest = function(q)
                  local out = {}
                  for _, r in ipairs(DFItemQuery.search(q, 8)) do
                      out[#out + 1] = { value = r.full, label = r.disp }
                  end
                  return out
              end,
              validate = function(s)
                  if type(s) ~= "string" or s == "" then
                      return false, "An item type is required."
                  end
                  if allowList then
                      -- The parser IS the validator here, so the message a
                      -- typo produces is the same one either way and there is
                      -- no second rule to drift from it.
                      local entries, why = DMKitForm.parseItemList(s, 1)
                      if not entries then return false, why end
                      return true
                  end
                  if s:find(",", 1, true) then
                      return false, "One item per row here. Use Add to enter a list."
                  end
                  if not s:find(".", 1, true) then
                      return false, "Needs its module - 'Base.Axe', not '" .. s .. "'."
                  end
                  return true
              end },
            { key = "count", kind = "int", label = "Count",
              min = 1, max = DMKitDefs.TOTAL_ITEMS_MAX, step = 1,
              help = "Every unit is its own pair of network packets, which is "
                  .. "why the whole kit is capped at "
                  .. DMKitDefs.TOTAL_ITEMS_MAX .. " items."
                  .. (allowList and ("  With a list, this is the count for "
                      .. "entries that do not carry their own xN.") or "") },
        }
    elseif kind == DMKitDefs.TRAIT then
        return {
            { key = "id", kind = "text", label = "Trait id",
              rule = "The namespaced registry id",
              help = "The full id, namespace included - a mod trait and a "
                  .. "vanilla one can share a short name, so the short form is "
                  .. "ambiguous. The server checks it against the trait "
                  .. "registry when the kit is saved.",
              validate = function(s)
                  if type(s) ~= "string" or s == "" then
                      return false, "A trait id is required."
                  end
                  return true
              end },
        }
    elseif kind == DMKitDefs.XP then
        return {
            { key = "perk", kind = "text", label = "Skill",
              rule = "A perk name, e.g. Woodwork",
              help = "The server resolves it against the perk list when the "
                  .. "kit is saved.",
              validate = function(s)
                  if type(s) ~= "string" or s == "" then
                      return false, "A skill is required."
                  end
                  return true
              end },
            { key = "amount", kind = "int", label = "XP", min = 1, max = 1000000,
              step = 100,
              help = "Raw XP, NOT multiplied by the player's trait boosts - "
                  .. "the number authored here is the number that lands." },
        }
    elseif kind == DMKitDefs.FLAG then
        return {
            { key = "name", kind = "text", label = "Flag",
              rule = "The variable's name",
              help = "The flag this kit gives. It must already be defined on "
                  .. "the Variables tab; the server refuses a kit naming one "
                  .. "that is not.",
              validate = function(s)
                  if type(s) ~= "string" or s == "" then
                      return false, "A flag name is required."
                  end
                  return true
              end },
        }
    elseif kind == DMKitDefs.COUNTER then
        return {
            { key = "name", kind = "text", label = "Counter",
              rule = "The variable's name",
              help = "Must already be defined on the Variables tab.",
              validate = function(s)
                  if type(s) ~= "string" or s == "" then
                      return false, "A counter name is required."
                  end
                  return true
              end },
            { key = "op", kind = "choice", label = "Operation",
              values = { "add", "set" }, labels = { "Add to it", "Set it to" },
              help = "ADD moves the counter by this much every claim. SET "
                  .. "replaces it. They differ on a repeatable kit, which is "
                  .. "exactly where the difference matters, so there is no "
                  .. "default that covers both." },
            { key = "value", kind = "int", label = "Value",
              min = -1000000, max = 1000000, step = 1,
              help = "Adding zero does nothing and is refused; setting zero is "
                  .. "a real instruction, and neither is the same as clearing "
                  .. "the counter." },
        }
    end
    return {}
end

-- A grant table -> the row model its schema reads. Split from the schema so
-- the two cannot disagree about a field name.
function DMKitForm.rowModel(g)
    g = g or {}
    if g.kind == DMKitDefs.COUNTER then
        return { name = g.name or "", op = (g.set ~= nil) and "set" or "add",
                 value = (g.set ~= nil) and g.set or (g.add or 1) }
    end
    return { type = g.type or "", count = g.count or 1,
             id = g.id or "", perk = g.perk or "", amount = g.amount or 100,
             name = g.name or "" }
end

-- ...and back. Returns only the fields that kind carries, so a grant cannot
-- pick up a stray key from a kind the row used to be.
function DMKitForm.rowGrant(kind, model)
    model = model or {}
    if kind == DMKitDefs.ITEM then
        return { kind = kind, type = model.type, count = model.count }
    elseif kind == DMKitDefs.TRAIT then
        return { kind = kind, id = model.id }
    elseif kind == DMKitDefs.XP then
        return { kind = kind, perk = model.perk, amount = model.amount }
    elseif kind == DMKitDefs.FLAG then
        return { kind = kind, name = model.name }
    elseif kind == DMKitDefs.COUNTER then
        local out = { kind = kind, name = model.name }
        out[model.op == "set" and "set" or "add"] = model.value
        return out
    end
    return nil
end

-- One grant, in one line. It lives HERE rather than on the tab because the tab
-- already requires this file and the reverse would be a cycle - the form has no
-- reason to know a catalogue exists. ONE function, so the catalogue's summary
-- pane and this window's grants list cannot describe the same grant differently
-- and leave an admin deciding which to believe.
function DMKitForm.grantLine(g)
    if type(g) ~= "table" then return "(malformed grant)" end
    local kind = g.kind
    if kind == DMKitDefs.ITEM then
        return "item  " .. tostring(g.type) .. " x" .. tostring(g.count or 1)
    elseif kind == DMKitDefs.TRAIT then
        return "trait  " .. tostring(g.id)
    elseif kind == DMKitDefs.XP then
        return "xp  " .. tostring(g.perk) .. " +" .. tostring(g.amount)
    elseif kind == DMKitDefs.FLAG then
        return "flag  " .. tostring(g.name)
    elseif kind == DMKitDefs.COUNTER then
        if g.add ~= nil then
            return "counter  " .. tostring(g.name)
                .. (g.add >= 0 and " +" or " ") .. tostring(g.add)
        end
        return "counter  " .. tostring(g.name) .. " = " .. tostring(g.set)
    elseif kind == DMKitDefs.ROULETTE then
        local n = #(g.from or {})
        return "roulette  pick " .. tostring(g.pick or 1) .. " of " .. n
            .. " branch" .. (n == 1 and "" or "es")
    end
    return tostring(kind)
end

-- One requirement, in one line. The counter half names its bound because
-- "Samples" and "Samples at least 10" are different requirements and a list
-- showing only the name would make them look identical.
function DMKitForm.requireLine(entry)
    if type(entry) == "string" then return "flag  " .. entry end
    if type(entry) == "table" then
        return "counter  " .. tostring(entry.name) .. "  >= "
            .. tostring(entry.atLeast)
    end
    return "(malformed requirement)"
end

-- ---------------------------------------------------------------------------
-- Geometry
--
-- THE DEFINITION FORM IS SIZED FROM ITS SCHEMA, NOT FROM WHAT THE LISTS LEFT
-- OVER. This window first shipped splitting the body by a tuned fraction and
-- handing the form the remainder, which put "Claimable" - a dial with no
-- default, the one answer a kit cannot be saved without - below the fold at any
-- font taller than the one the fraction was tuned against. DFForm scrolls, and
-- correctly refuses to draw or hit-test a row that is out of view, so the
-- control was not merely awkward to reach: it was absent, and the save refused
-- with a sentence naming it (owner, 2026-08-23).
--
-- DFSettingsWindow has sized itself from its own schema since it shipped, for
-- this exact reason and in those words - "so adding a preference grows the
-- window instead of silently pushing a row off the bottom"
-- (DFSettingsWindow.lua:155-158). This is that pattern with two lists to feed
-- afterwards.
--
-- Pure, and split from the window, so a fixture can sweep the font heights a
-- fixture can never render.
-- ---------------------------------------------------------------------------

-- Rows each list shows before it starts scrolling. FLOORS, not fits: a kit may
-- hold DMKitDefs.GRANTS_MAX grants, so the grants list was always going to
-- scroll, and any surplus height goes to it because that is where the work is.
local REQ_ROWS, GRANT_ROWS, MIN_ROWS = 3, 5, 2

-- The body height this window would like: the form's own content, plus a
-- usable list each. The caller adds its own chrome.
function DMKitForm.wants(formNeeds, rowH)
    return math.max(0, formNeeds or 0) + (REQ_ROWS + GRANT_ROWS) * math.max(1, rowH or 1)
end

-- Split a body between the three panes: definition form, requirements list,
-- grants list.
function DMKitForm.panes(body, formNeeds, rowH)
    rowH = math.max(1, rowH or 1)
    local formH  = math.max(rowH, formNeeds or 0)
    local reqH   = REQ_ROWS * rowH
    local grantH = GRANT_ROWS * rowH

    local short = (formH + reqH + grantH) - math.max(0, body or 0)
    if short <= 0 then
        -- Surplus to the grants list.
        return formH, reqH, grantH - short
    end

    -- Short. THE LISTS GIVE FIRST, down to MIN_ROWS. They scroll by nature and
    -- carry a bar the whole time, so a short list is inconvenient; a short form
    -- hides a required dial, which is a dead end with a refusal attached.
    local spare = (reqH - MIN_ROWS * rowH) + (grantH - MIN_ROWS * rowH)
    local take  = math.min(short, spare)
    if spare > 0 then
        local fromReq = math.floor(take * (reqH - MIN_ROWS * rowH) / spare)
        reqH   = reqH - fromReq
        grantH = grantH - (take - fromReq)
    end

    short = short - take
    -- Still short, which means the screen itself could not hold the window.
    -- Now the form scrolls after all - two lists too short to show the row
    -- being edited is not a better answer, and the form at least has a bar.
    if short > 0 then formH = math.max(rowH, formH - short) end
    return formH, reqH, grantH
end

-- ---------------------------------------------------------------------------
-- Replies
-- ---------------------------------------------------------------------------

-- Called by DMKitsTab when one of ITS verbs succeeded. Only kitDefine closes
-- this window: a delete or a re-open aimed at another kit must not shut an
-- editor somebody is halfway through.
function DMKitForm.acknowledge(args)
    if not F.win or not args then return end
    if args.command ~= "kitDefine" then return end
    if args.id and F.win.savingId and args.id ~= F.win.savingId then return end
    F.win:close()
end

-- ---------------------------------------------------------------------------
-- The two lists
-- ---------------------------------------------------------------------------

local RowList = ISScrollingListBox:derive("DMKitRowList")

function RowList:doDrawItem(y, item, alt)
    if item.item == nil then return y + item.height end
    if self.selected == item.index then
        local a = DFKit.col.accentDim
        self:drawRect(0, y, self.width, item.height - 1, 0.55, a.r, a.g, a.b)
    elseif alt then
        self:drawRect(0, y, self.width, item.height - 1, 0.10, 1, 1, 1)
    end
    self:drawRectBorder(0, y, self.width, item.height, 0.12, 1, 1, 1)
    -- A carried roulette draws dimmed and says so. It is a real part of the
    -- kit and will be saved untouched; drawing it like an editable row would
    -- invite a click that does nothing and read as a broken control.
    local editable = self.isGrants and DMKitForm.isEditable(item.item)
    local c = (self.isGrants and not editable) and DFKit.col.textDim
              or DFKit.col.text
    local text = item.text .. ((self.isGrants and not editable)
                               and "   (edit externally)" or "")
    self:drawText(DFKit.fitText(text, FONT, self.width - 12), 6, y + 3,
                  c.r, c.g, c.b, 1, FONT)
    return y + item.height
end

function RowList:onMouseDown(x, y)
    local idx = self:rowAt(x, y)
    if idx < 1 or idx > #self.items then return end
    self.selected = idx
    if F.win then F.win.status = nil end
end

-- ---------------------------------------------------------------------------
-- The row modal - one grant, or one counter requirement
--
-- ONE modal driven by a schema, rather than one window per kind. The kinds
-- differ only in which dials they show, which is exactly what a schema is, and
-- five near-identical windows is five places for the Save button to behave
-- differently.
-- ---------------------------------------------------------------------------

local RowModal = ISCollapsableWindow:derive("DMKitRowModal")

function RowModal:createChildren()
    ISCollapsableWindow.createChildren(self)
    local m, pad = DFKit.metrics, DFKit.metrics.pad
    local top   = self:titleBarHeight() + pad
    local footH = m.btnH + pad * 2
    local win   = self

    self.form = DFForm.new{
        title      = self.formTitle or "Grant",
        inlineHelp = true,
        schema     = self.schema,
        get        = function(k) return win.model[k] end,
        set        = function(k, v) win.model[k] = v end,
        enabled    = function() return true end,
    }
    self.form:attach(self)
    self.form:layout(pad, top, self.width - pad * 2,
                     self.height - top - footH - pad)

    local bx = self.width - pad
    for _, spec in ipairs({ { 80, "OK", function() win:commit() end, "action" },
                            { 80, "Cancel", function() win:close() end, nil } }) do
        bx = bx - spec[1]
        DFKit.button(self, bx, self.height - footH, spec[1], spec[2], self,
                     spec[3], spec[4])
        bx = bx - m.gap
    end
    self.footY = self.height - footH + 4
end

function RowModal:commit()
    -- The schema's own validators, run before the row is accepted. DFForm
    -- validates on entry, but a field never touched was never validated - so
    -- an empty required box would otherwise ride out of here as "".
    for _, e in ipairs(self.schema) do
        if e.validate then
            local ok, why = e.validate(self.model[e.key])
            if not ok then
                self.status = tostring(why or ("Check " .. tostring(e.label) .. "."))
                return
            end
        end
    end
    self.onOk(self.model)
    self:close()
end

function RowModal:prerender()
    ISCollapsableWindow.prerender(self)
    self.form:draw(self)
    if self.status then
        local a = DFKit.col.accent
        self:drawText(DFKit.fitText(self.status, FONT, self.width - 180),
                      DFKit.metrics.pad, self.footY, a.r, a.g, a.b, 1, FONT)
    end
end

function RowModal:close()
    self:removeFromUIManager()
end

local function openRow(title, schema, model, onOk)
    local w, h = 460, 380
    local win = RowModal:new(getCore():getScreenWidth() / 2 - w / 2,
                             getCore():getScreenHeight() / 2 - h / 2, w, h)
    win.schema, win.model, win.onOk = schema, model, onOk
    win.formTitle = title
    win:setTitle(title)
    win:setResizable(false)
    win:initialise(); win:instantiate(); win:addToUIManager()
    return win
end

-- ---------------------------------------------------------------------------
-- The kit window
-- ---------------------------------------------------------------------------

local Editor = ISCollapsableWindow:derive("DMKitFormWindow")

local function kitSchema(locked)
    return {
        { key = "id", kind = "text", label = "Id",
          rule = "Letters, digits, underscore and hyphen. At most "
              .. DMKitDefs.ID_MAX .. " characters.",
          -- Locked when editing for the reason DMKitDefs gives: the id is what
          -- a quest's reward field, a flag's revokers.kit and the claim ledger
          -- all point at. Changing it under a live kit orphans every one of
          -- them silently, and the store would file the result as a NEW kit
          -- while the old one carried on existing.
          locked = locked,
          help = locked
              and "A kit's id cannot change once it exists - quests, flags and "
               .. "the claim record all point at it. Create a new kit and "
               .. "delete this one if you need a different id."
              or "The stable key. Quests reference it, a flag's 'cleared by "
               .. "kit' names it, and the claim record is keyed by it - so it "
               .. "is the one thing here that should never be renamed.",
          validate = function(s)
              local id, why = DMKitDefs.normalizeId(s)
              if not id then return false, why end
              return true
          end },
        { key = "kind", kind = "choice", label = "Reward type",
          values = { DMKitDefs.ITEM, DMKitDefs.TRAIT, DMKitDefs.XP },
          labels = { "Items", "Trait", "Skill XP" },
          help = "ONE kit carries ONE reward type. Handing out loot and a "
              .. "skill boost after an event is two kits offered together, "
              .. "each claimed on its own - they are revealed differently, "
              .. "they fail separately, and they can sit on different claim "
              .. "clocks. Flags and counters are bookkeeping and ride in any "
              .. "kit." },
        { key = "label", kind = "text", label = "Name", empty = "(use the id)",
          help = "What a player sees in their Kits window. At most "
              .. DMKitDefs.LABEL_MAX .. " characters." },
        { key = "note", kind = "text", label = "Note", empty = "(none)",
          help = "Free text for whoever reads this next. Never shown to a "
              .. "player and never interpreted." },
        { key = "answered", kind = "choice", label = "Claim policy",
          values = { "", "set" }, labels = { "- choose -", "Set below" },
          help = "There is deliberately no default. The unchosen answer is a "
              .. "kit with no wait at all, which is a farm - and it would be "
              .. "found months later by whoever noticed the loot. Answer this, "
              .. "then set the wait underneath: leaving both at zero is a "
              .. "legitimate choice, but it has to be a CHOICE." },
        { key = "waitDays", kind = "int", label = "Wait: days",
          min = 0, max = math.floor(DMKitDefs.COOLDOWN_MAX_HOURS / 24), step = 1,
          unit = "days", zero = "none",
          help = "How long before a player may take this kit again, in REAL "
              .. "time - hours off a wall clock, not game time, so a day is a "
              .. "day whatever the day-length sandbox option says. Add the "
              .. "hours field underneath for anything finer.  A wait longer "
              .. "than your season is how you write 'once per wipe': there is "
              .. "no separate once-ever setting, because the claim record is "
              .. "cleared by a wipe anyway." },
        { key = "waitHours", kind = "int", label = "Wait: hours",
          min = 0, max = 23, step = 1, unit = "hr", zero = "none",
          help = "Hours ON TOP of the days above. Capped at 23 - 24 hours is a "
              .. "day, and two ways to write the same wait is two numbers to "
              .. "keep in step." },
    }
end

function Editor:createChildren()
    ISCollapsableWindow.createChildren(self)
    local m, pad = DFKit.metrics, DFKit.metrics.pad
    local top   = self:titleBarHeight() + pad
    local footH = m.btnH + pad * 2
    local bandH = DFKit.rowHeight()
    local win   = self

    self.form = DFForm.new{
        title      = "Kit",
        inlineHelp = true,
        schema     = kitSchema(self.existing ~= nil),
        get        = function(k) return win.model[k] end,
        set        = function(k, v)
            win.model[k] = v
            -- The kit's kind decides which grants may exist at all, so a change
            -- has to reach the Add menu. Existing grants are NOT pruned here:
            -- silently deleting a DM's work because they touched a dial is
            -- worse than a save the server refuses with a sentence naming the
            -- grant that no longer belongs.
            if k == "kind" then win.status = nil end
        end,
        enabled    = function() return true end,
    }
    self.form:attach(self)

    -- Three panes down the window: the definition form, the requirements, the
    -- grants. Every band is reserved rather than drawn over the top of the
    -- widget below it - the mistake that cost two screens in this suite on
    -- 2026-08-23 (DFVarsView, DFVarEditor) - and the form is sized from its
    -- schema rather than from what the lists left, which is the OTHER way to
    -- put a control where nobody can reach it. See the Geometry section.
    local avail   = self.height - top - footH
    local verbRow = m.btnH + m.gap
    local fixed   = bandH * 2 + verbRow * 2 + pad * 3

    -- MEASURED, and it has to be laid out once first: with inline help on, the
    -- wrap width decides how tall every row is, and layout() is what records
    -- that width (DFForm.lua:341-346). contentHeight() with no argument then
    -- answers for the width the form will actually be drawn at.
    self.form:layout(pad, top, self.width - pad * 2, avail - fixed)
    local formH, reqH, grantH =
        DMKitForm.panes(avail - fixed, self.form:contentHeight(), bandH)

    self.form:layout(pad, top, self.width - pad * 2, formH)

    local function mkList(y, h, isGrants)
        local box = RowList:new(pad, y, self.width - pad * 2, h)
        box.itemheight = DFKit.rowHeight()
        box.drawBorder = true
        box.isGrants = isGrants
        DFKit.well(box)
        box:initialise(); box:instantiate()
        self:addChild(box)
        return box
    end

    self.reqBandY = top + formH + pad
    self.reqBox   = mkList(self.reqBandY + bandH, reqH, false)
    local reqVerbY = self.reqBox:getY() + reqH + m.gap

    local bx = pad
    for _, spec in ipairs({
        { 96, "Add flag", function() win:addFlagRequirement() end, "action" },
        { 110, "Add counter", function() win:addCounterRequirement() end, "action" },
        { 84, "Remove", function() win:removeRequirement() end, nil },
    }) do
        DFKit.button(self, bx, reqVerbY, spec[1], spec[2], self, spec[3], spec[4])
        bx = bx + spec[1] + m.gap
    end

    self.grantBandY = reqVerbY + verbRow + pad
    self.grantBox   = mkList(self.grantBandY + bandH, grantH, true)
    local grantVerbY = self.grantBox:getY() + grantH + m.gap

    bx = pad
    for _, spec in ipairs({
        { 84, "Add", function() win:addGrant() end, "action" },
        { 84, "Edit", function() win:editGrant() end, nil },
        { 84, "Remove", function() win:removeGrant() end, nil },
        { 74, "Up", function() win:moveGrant(-1) end, nil },
        { 74, "Down", function() win:moveGrant(1) end, nil },
    }) do
        DFKit.button(self, bx, grantVerbY, spec[1], spec[2], self, spec[3], spec[4])
        bx = bx + spec[1] + m.gap
    end

    bx = self.width - pad
    local saveLabel = self.existing and "Save" or "Create"
    for _, spec in ipairs({ { 80, saveLabel, function() win:commit() end, "action" },
                            { 80, "Cancel", function() win:close() end, nil } }) do
        bx = bx - spec[1]
        DFKit.button(self, bx, self.height - footH, spec[1], spec[2], self,
                     spec[3], spec[4])
        bx = bx - m.gap
    end
    self.footY = self.height - footH + 4

    self:rebuild()
end

function Editor:rebuild()
    if self.reqBox then
        DFKit.refillList(self.reqBox, function(box)
            for _, name in ipairs(self.requires.flags) do
                box:addItem(DMKitForm.requireLine(name), name).height = DFKit.rowHeight()
            end
            for _, c in ipairs(self.requires.counters) do
                box:addItem(DMKitForm.requireLine(c), c).height = DFKit.rowHeight()
            end
        end)
        self.reqBox.selected = -1
    end
    if self.grantBox then
        DFKit.refillList(self.grantBox, function(box)
            for _, g in ipairs(self.grants) do
                box:addItem(DMKitForm.grantLine(g), g).height = DFKit.rowHeight()
            end
        end)
        self.grantBox.selected = -1
    end
end

-- The selected row's INDEX is used here and only here, immediately, inside one
-- click. That is safe in a way DMKitsTab's is not: nothing about this window
-- refills from the server, so a list cannot reorder under a selection. The
-- moment it can, this becomes an identity like every other list in the suite.
local function selectedIndex(box)
    if not box then return nil end
    local i = box.selected
    if not i or i < 1 or i > #box.items then return nil end
    return i
end

function Editor:addFlagRequirement()
    local win = self
    openRow("Flag requirement", {
        { key = "name", kind = "text", label = "Flag",
          rule = "The variable's name",
          help = "The player must hold this flag to claim the kit. It must "
              .. "already be defined on the Variables tab.",
          validate = function(s)
              if type(s) ~= "string" or s == "" then
                  return false, "A flag name is required."
              end
              return true
          end },
    }, { name = "" }, function(model)
        win.requires.flags[#win.requires.flags + 1] = model.name
        win:rebuild()
    end)
end

function Editor:addCounterRequirement()
    local win = self
    openRow("Counter requirement", {
        { key = "name", kind = "text", label = "Counter",
          rule = "The variable's name",
          help = "Must already be defined on the Variables tab.",
          validate = function(s)
              if type(s) ~= "string" or s == "" then
                  return false, "A counter name is required."
              end
              return true
          end },
        { key = "atLeast", kind = "int", label = "At least",
          min = -1000000, max = 1000000, step = 1,
          help = "The player's counter must be at or above this. A player who "
              .. "has never touched the counter fails the test - absent is not "
              .. "zero, and that is what makes 'have you started' answerable." },
    }, { name = "", atLeast = 1 }, function(model)
        win.requires.counters[#win.requires.counters + 1] =
            { name = model.name, atLeast = model.atLeast }
        win:rebuild()
    end)
end

function Editor:removeRequirement()
    local i = selectedIndex(self.reqBox)
    if not i then self.status = "Select a requirement first."; return end
    local nFlags = #self.requires.flags
    if i <= nFlags then
        table.remove(self.requires.flags, i)
    else
        table.remove(self.requires.counters, i - nFlags)
    end
    self:rebuild()
end

function Editor:addGrant()
    local win = self
    local menu = ISContextMenu.get(getPlayer() and getPlayer():getPlayerNum() or 0,
                                   getMouseX(), getMouseY())
    if not menu then return end
    local LABELS = {
        [DMKitDefs.ITEM]    = "Item",
        [DMKitDefs.TRAIT]   = "Trait",
        [DMKitDefs.XP]      = "Skill XP",
        [DMKitDefs.FLAG]    = "Flag",
        [DMKitDefs.COUNTER] = "Counter",
    }
    for _, kind in ipairs(DMKitForm.addableKinds(self.model.kind)) do
        menu:addOption(LABELS[kind] or kind, nil, function()
            openRow("New " .. (LABELS[kind] or kind) .. " grant",
                DMKitForm.rowSchema(kind, true),
                DMKitForm.rowModel{ kind = kind },
                function(model)
                    local made, why = DMKitForm.expandGrants(kind, model, true)
                    if not made then win.status = why; return end
                    for _, g in ipairs(made) do
                        win.grants[#win.grants + 1] = g
                    end
                    -- Said out loud, because adding twelve rows from one OK is
                    -- a big enough jump that silence reads as nothing happening.
                    if #made > 1 then
                        win.status = "Added " .. #made .. " items."
                    end
                    win:rebuild()
                end)
        end)
    end
end

function Editor:editGrant()
    local i = selectedIndex(self.grantBox)
    if not i then self.status = "Select a grant first."; return end
    local g = self.grants[i]
    if not DMKitForm.isEditable(g) then
        self.status = "A roulette is carried through unchanged for now - edit "
            .. "it in the kits-defs store file. Saving this kit keeps it exactly as it is."
        return
    end
    local win = self
    openRow("Edit grant", DMKitForm.rowSchema(g.kind, false), DMKitForm.rowModel(g),
        function(model)
            local out = DMKitForm.rowGrant(g.kind, model)
            if out then win.grants[i] = out end
            win:rebuild()
        end)
end

function Editor:removeGrant()
    local i = selectedIndex(self.grantBox)
    if not i then self.status = "Select a grant first."; return end
    local line = DMKitForm.grantLine(self.grants[i])
    local win = self
    -- A roulette is the one row whose contents are not on screen, so removing
    -- it is the one removal an admin cannot eyeball. It gets a confirmation;
    -- the others are one Add away from being back.
    if not DMKitForm.isEditable(self.grants[i]) then
        DFConfirm.ask("Remove " .. line .. "?\n\nThis form cannot recreate a "
            .. "roulette, so it would have to be written back into the store file by hand.",
            function() table.remove(win.grants, i); win:rebuild() end)
        return
    end
    table.remove(self.grants, i)
    self:rebuild()
end

-- Order matters on screen and in the delivery report, and a DM building a
-- reveal cares which item lands first.
function Editor:moveGrant(delta)
    local i = selectedIndex(self.grantBox)
    if not i then self.status = "Select a grant first."; return end
    local j = i + delta
    if j < 1 or j > #self.grants then return end
    self.grants[i], self.grants[j] = self.grants[j], self.grants[i]
    self:rebuild()
    self.grantBox.selected = j
end

function Editor:commit()
    local def, why = DMKitForm.buildDef(self.model, self.grants, self.requires)
    if not def then self.status = why; return end
    -- Remembered so the reply can be matched: a KitResult naming another kit
    -- must not close this window, and a define answering for THIS one must.
    self.savingId = def.id
    self.status = "Saving..."
    RDNet.send(TOKEN, "kitDefine", { kit = def })
end

function Editor:prerender()
    ISCollapsableWindow.prerender(self)
    self.form:draw(self)
    local t = DFKit.col.textDim
    local pad = DFKit.metrics.pad
    if self.reqBandY then
        local n = #self.requires.flags + #self.requires.counters
        self:drawText(n == 0 and "REQUIRES  (nothing - anyone may claim it)"
                             or ("REQUIRES  (" .. n .. ")"),
                      pad, self.reqBandY, t.r, t.g, t.b, 1, FONT)
    end
    if self.grantBandY then
        self:drawText("GRANTS  (" .. #self.grants .. ")", pad, self.grantBandY,
                      t.r, t.g, t.b, 1, FONT)
    end
    if self.status then
        local a = DFKit.col.accent
        self:drawText(DFKit.fitText(self.status, FONT, self.width - 180),
                      pad, self.footY, a.r, a.g, a.b, 1, FONT)
    end
end

function Editor:close()
    F.win = nil
    self:removeFromUIManager()
end

-- ---------------------------------------------------------------------------

-- The floor is the old fixed height, so nothing gets SMALLER than it was at the
-- font this window was built against - a form that now fits would otherwise
-- shrink the grants list to make the point. The margin keeps the title bar and
-- the footer buttons on screen when the schema wants more than the display has.
local MIN_H, SCREEN_MARGIN = 720, 40

local function openWindow(existing)
    if F.win then F.win:close() end

    local pad, m = DFKit.metrics.pad, DFKit.metrics
    local w      = 620
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()

    -- Measured on a THROWAWAY form, because the real one does not exist until
    -- the window it is being sized for does. Same schema and same width, so it
    -- measures what will actually be drawn; layout() records the wrap width
    -- that inline help is wrapped against, and nothing else about it is used.
    local probe = DFForm.new{ schema = kitSchema(existing ~= nil),
                              inlineHelp = true }
    probe:layout(0, 0, w - pad * 2, 0)

    local win = Editor:new(math.floor(sw / 2 - w / 2), 0, w, MIN_H)

    -- titleBarHeight() reads titleFontHgt, which ISCollapsableWindow:new has
    -- already measured (ISCollapsableWindow.lua:398-399), so it answers before
    -- initialise() - which is the whole reason the window can be sized here
    -- rather than resized from inside its own createChildren.
    local rowH = DFKit.rowHeight()
    local h = win:titleBarHeight() + pad
            + rowH * 2 + (m.btnH + m.gap) * 2 + pad * 3
            + DMKitForm.wants(probe:contentHeight(), rowH)
            + m.btnH + pad * 2
    if h < MIN_H then h = MIN_H end
    if h > sh - SCREEN_MARGIN then h = sh - SCREEN_MARGIN end

    win:setHeight(h)
    win:setY(math.max(0, math.floor((sh - h) / 2)))
    win.existing = existing
    win.model    = DMKitForm.modelOf(existing)
    win.grants   = DMKitForm.copyGrants(existing)
    win.requires = DMKitForm.copyRequires(existing)
    win:setTitle(existing and ("Kit: " .. (existing.label or existing.id))
                          or "New kit")
    win:setResizable(false)
    win:initialise(); win:instantiate(); win:addToUIManager()

    F.win = win
    return win
end

function DMKitForm.openNew() return openWindow(nil) end
function DMKitForm.open(def) return openWindow(def) end

return DMKitForm

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
