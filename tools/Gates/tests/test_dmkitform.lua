-- DMKitForm fixture - one kit's shape, in the authoring window.
--
-- WHAT IS AT RISK.
--
-- 1. THE ROULETTE ROUND TRIP, and it is the reason this file exists. The
--    roulette editor is deliberately unbuilt (owner, 2026-08-23: pause before
--    the roulette UI), so this form must CARRY a roulette it cannot edit. A
--    form that could only express what its dials cover would silently strip one
--    from any kit an admin opened to fix a typo - and nobody would find out
--    until a player claimed the kit and got the consolation branch every time,
--    because the rare one was gone. There is no error, no log line and no way
--    to notice from the panel.
--
-- 2. THE DEEP COPY. The window edits a copy. A shallow one would let a row edit
--    reach into the catalogue table DMKitsTab is still drawing behind it, so
--    Cancel would leave the change on screen and the next refresh would put it
--    back - a change nobody saved and nobody can undo.
--
-- 3. ONE KIT, ONE REWARD TYPE, offered rather than refused. DMKitDefs rejects a
--    kit whose grants carry a foreign reward kind; an Add menu that offered all
--    five would teach that rule by failed save, one kit at a time.
--
-- 4. THE add/set SPLIT on a counter grant. "+5 samples" and "stage becomes 5"
--    differ on every re-claim of a repeatable kit, which is exactly where a
--    silent swap would be found last.
--
-- 5. THE REPLY MATCH. acknowledge() closes this window, and it must close it
--    for THIS kit's save and nothing else - not for a delete aimed elsewhere,
--    and not for another kit's define landing while somebody is halfway
--    through a form.
--
-- The drawing and the widget geometry are not covered; they need ISUI and
-- Mosaic. What is covered is every function that decides what gets SENT.

local ROOT = arg[1] or "."
local CORE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua"
local DM   = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDungeonMaster/42/media/lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then passed = passed + 1
    else failed = failed + 1; print("FAIL DMKitForm: " .. message) end
end

-- ---- stubs ---------------------------------------------------------------

function isServer() return false end
require = function() return true end

local function stubClass()
    local C = {}; C.__index = C
    function C:derive() local D = {}; D.__index = D; setmetatable(D, { __index = C }); return D end
    return C
end
ISScrollingListBox  = stubClass()
ISCollapsableWindow = stubClass()
ISContextMenu = { get = function() return nil end }

DFKit = { font = { small = "small" }, metrics = { btnH = 24, pad = 8, gap = 6 },
          col = { text = {}, textDim = {}, accent = {}, accentDim = {} },
          rowHeight = function() return 22 end,
          fitText = function(s) return s end,
          refillList = function(box, fill) box:clear(); if fill then fill(box) end end,
          well = function(e) return e end,
          button = function() return {} end }
DFForm    = { new = function(o) return o end }
DFConfirm = { ask = function() end }
function getPlayer() return { getPlayerNum = function() return 0 end } end

RDVarDefs = nil
local okV, errV = pcall(dofile, CORE .. "/shared/RDVarDefs.lua")
check(okV, "RDVarDefs loads: " .. tostring(errV))
DMRoll = nil
local okR, errR = pcall(dofile, DM .. "/shared/DMRoll.lua")
check(okR, "DMRoll loads: " .. tostring(errR))
DMKitDefs = nil
local okD, errD = pcall(dofile, DM .. "/shared/DMKitDefs.lua")
check(okD, "DMKitDefs loads: " .. tostring(errD))

DMKitForm = nil
local ok, err = pcall(dofile, DM .. "/client/DMKitForm.lua")
check(ok, "module loads: " .. tostring(err))

-- ---- a kit with a roulette in it -----------------------------------------

local ROULETTE = {
    kind = "roulette", pick = 1,
    from = {
        { weight = 10, grants = { { kind = "item", type = "Base.Katana", count = 1 } } },
        { weight = 90, grants = { { kind = "item", type = "Base.Crowbar", count = 1 } } },
    },
}

local KIT = {
    id = "anomaly_loot", kind = "item", label = "Anomaly Loot",
    note = "handed out after the 2026 event",
    claim = { cooldownHours = 123 },
    requires = { flags = { "delver" },
                 counters = { { name = "samples", atLeast = 10 } } },
    grants = {
        { kind = "item", type = "Base.Axe", count = 2 },
        { kind = "counter", name = "runs", add = 1 },
        ROULETTE,
    },
}

-- ---- the model round trip ------------------------------------------------

local model = DMKitForm.modelOf(KIT)
check(model.id == "anomaly_loot", "the id was lost")
check(model.kind == "item", "the kind was lost")
check(model.label == "Anomaly Loot", "the label was lost")
check(model.note == "handed out after the 2026 event", "the note was lost")
check(model.durationDays == 5 and model.durationHours == 3,
    "the stored wait did not split into the two dials: "
    .. tostring(model.durationDays) .. "d " .. tostring(model.durationHours) .. "h")
check(DMKitForm.modelOf{ id = "x", kind = "xp",
                         claim = { cooldownHours = 0 } }.durationDays == 0,
    "a kit with no wait opened showing one")

-- A new kit opens with both duration dials at zero - no wait - and that is a
-- valid kit. The "- choose -" gate was removed on 2026-08-24: two visible
-- number fields already show what the policy is, so a dial whose only job was
-- to make somebody acknowledge them was ceremony.
local blank = DMKitForm.modelOf(nil)
check(blank.durationDays == 0 and blank.durationHours == 0,
    "a new kit opened with a wait nobody typed")
local fresh = DMKitForm.buildDef(blank, { { kind = "item", type = "Base.Axe" } },
                                 { flags = {}, counters = {} })
check(fresh ~= nil, "a new kit could not be built")
check(fresh.claim.cooldownHours == 0,
    "a kit with both dials at zero did not come out with no wait")

-- ---- THE ROULETTE ROUND TRIP ---------------------------------------------

local grants = DMKitForm.copyGrants(KIT)
check(#grants == 3, "the grants did not come through: " .. #grants)

local carried = grants[3]
check(carried.kind == "roulette", "the roulette moved position")
check(#carried.from == 2, "A ROULETTE BRANCH WAS LOST IN THE COPY")
check(carried.from[1].weight == 10 and carried.from[2].weight == 90,
    "the branch weights did not survive - the odds are the roulette")
check(carried.from[1].grants[1].type == "Base.Katana",
    "a branch's own grants were flattened away")

local requires = DMKitForm.copyRequires(KIT)
local def = DMKitForm.buildDef(model, grants, requires)
check(def ~= nil, "the round trip could not be rebuilt")
check(#def.grants == 3, "a grant was dropped on the way out")
check(def.grants[3].kind == "roulette",
    "THE ROULETTE WAS STRIPPED ON SAVE. The editor cannot author one yet, so "
    .. "any kit carrying one would lose it the moment an admin opened the kit "
    .. "to fix a typo - with no error and nothing on screen to notice.")
check(def.grants[3].from[1].grants[1].type == "Base.Katana",
    "the rare branch's prize was lost on save")

-- And the whole thing survives DMKitDefs, which is the only opinion that
-- counts: a form that produced something the schema refuses is a form that
-- cannot save.
local validated, why = DMKitDefs.validate(def)
check(validated ~= nil, "the form built a kit the schema refuses: " .. tostring(why))
check(validated and #validated.grants == 3, "the schema dropped a grant")

-- ---- THE DEEP COPY -------------------------------------------------------

grants[1].type = "Base.Crowbar"
grants[3].from[1].weight = 999
check(KIT.grants[1].type == "Base.Axe",
    "EDITING A ROW REACHED INTO THE CATALOGUE. Cancel would leave the change "
    .. "on screen and the next refresh would put it back - a change nobody "
    .. "saved and nobody can undo.")
check(KIT.grants[3].from[1].weight == 10,
    "a roulette branch was shared with the catalogue rather than copied")

requires.flags[1] = "somethingelse"
requires.counters[1].atLeast = 999
check(KIT.requires.flags[1] == "delver", "the flag list was shared")
check(KIT.requires.counters[1].atLeast == 10,
    "a counter requirement was shared with the catalogue")

-- ---- requires ------------------------------------------------------------

local r = DMKitForm.copyRequires(KIT)
check(#r.flags == 1 and #r.counters == 1, "the requirements did not come through")
local bare = DMKitForm.buildDef(DMKitForm.modelOf(KIT),
    { { kind = "item", type = "Base.Axe" } }, { flags = {}, counters = {} })
check(bare.requires == nil,
    "an empty requirement set was sent as two empty lists rather than omitted")

-- ---- what may be added ---------------------------------------------------

local function has(list, want)
    for _, v in ipairs(list) do if v == want then return true end end
    return false
end

for _, kitKind in ipairs({ "item", "trait", "xp" }) do
    local kinds = DMKitForm.addableKinds(kitKind)
    check(has(kinds, kitKind), kitKind .. " kits cannot add their own reward")
    check(has(kinds, "flag") and has(kinds, "counter"),
        kitKind .. " kits lost the bookkeeping kinds - they ride in any kit")
    for _, other in ipairs({ "item", "trait", "xp" }) do
        if other ~= kitKind then
            check(not has(kinds, other),
                "A " .. kitKind .. " KIT WAS OFFERED A " .. other
                .. " GRANT. DMKitDefs refuses it, so the menu would be "
                .. "teaching the one-kit-one-reward rule by failed save.")
        end
    end
    check(not has(kinds, "roulette"),
        "the Add menu offered a roulette, which this form cannot author")
end
check(#DMKitForm.addableKinds(nil) == 2,
    "a kit with no kind yet offered a reward kind anyway")

-- ---- editability ---------------------------------------------------------

check(DMKitForm.isEditable{ kind = "item" } == true, "an item row was not editable")
check(DMKitForm.isEditable(ROULETTE) == false,
    "A ROULETTE ROW OPENED THE ROW EDITOR. Its schema is empty, so the admin "
    .. "would get a window with no dials and read it as a grant containing "
    .. "nothing.")
check(DMKitForm.isEditable(nil) == false, "isEditable faulted on nothing")

-- ---- the row round trip, per kind ----------------------------------------

local function roundTrip(g)
    return DMKitForm.rowGrant(g.kind, DMKitForm.rowModel(g))
end

local item = roundTrip{ kind = "item", type = "Base.Axe", count = 3 }
check(item.type == "Base.Axe" and item.count == 3, "an item grant did not survive")

local trait = roundTrip{ kind = "trait", id = "MyMod:Delver" }
check(trait.id == "MyMod:Delver",
    "a trait id was mangled - the namespace is what makes it unambiguous")

local xp = roundTrip{ kind = "xp", perk = "Woodwork", amount = 2500 }
check(xp.perk == "Woodwork" and xp.amount == 2500, "an xp grant did not survive")

local flag = roundTrip{ kind = "flag", name = "delver" }
check(flag.name == "delver", "a flag grant did not survive")

-- THE add/set SPLIT. They differ on every re-claim of a repeatable kit.
local addG = roundTrip{ kind = "counter", name = "runs", add = 5 }
check(addG.add == 5 and addG.set == nil,
    "AN ADD BECAME A SET. '+5 each claim' and 'becomes 5' are the same on the "
    .. "first claim and never again.")
local setG = roundTrip{ kind = "counter", name = "stage", set = 3 }
check(setG.set == 3 and setG.add == nil, "a set became an add")

-- A NEGATIVE add is a real instruction - spending a counter - and must not be
-- clamped away by the row.
local spend = roundTrip{ kind = "counter", name = "tokens", add = -1 }
check(spend.add == -1, "a counter grant could not take something away")

-- Zero: set 0 is a real instruction, add 0 is refused by the schema. The row
-- must carry both faithfully and let DMKitDefs be the one to say no.
local zeroSet = roundTrip{ kind = "counter", name = "stage", set = 0 }
check(zeroSet.set == 0, "SETTING A COUNTER TO ZERO WAS LOST - absent and zero "
    .. "are different, and this is the only way to say zero")

-- A row cannot pick up a field from the kind it used to be.
local swapped = DMKitForm.rowGrant("flag",
    { name = "delver", type = "Base.Axe", count = 9, amount = 100 })
check(swapped.type == nil and swapped.count == nil and swapped.amount == nil,
    "a grant carried fields from another kind, which DMKitDefs refuses as an "
    .. "unknown field on a grant it otherwise accepts")

check(DMKitForm.rowGrant("roulette", {}) == nil,
    "the row builder produced a roulette it cannot author")

-- ---- the row schemas -----------------------------------------------------

for _, kind in ipairs({ "item", "trait", "xp", "flag", "counter" }) do
    local schema = DMKitForm.rowSchema(kind)
    check(#schema > 0, "no dials for a " .. kind .. " grant")
    for _, e in ipairs(schema) do
        check(e.key ~= nil and e.kind ~= nil and e.label ~= nil,
            "a " .. kind .. " dial is missing key, kind or label")
        -- Every dial the row builder reads must exist in the schema, or the
        -- grant would carry whatever rowModel defaulted it to and no admin
        -- would ever have seen the value.
        check(DMKitForm.rowModel{ kind = kind }[e.key] ~= nil,
            "the " .. kind .. " row model has no default for '" .. e.key .. "'")
    end
end
check(#DMKitForm.rowSchema("roulette") == 0,
    "the row editor offered dials for a roulette")

-- The item count dial cannot exceed the kit ceiling, because a dial that goes
-- past what the schema accepts is a refusal the control already knew about.
for _, e in ipairs(DMKitForm.rowSchema("item")) do
    if e.key == "count" then
        check(e.max == DMKitDefs.TOTAL_ITEMS_MAX,
            "the count dial and the schema's ceiling disagree: "
            .. tostring(e.max) .. " vs " .. DMKitDefs.TOTAL_ITEMS_MAX)
        check(e.min == 1, "the count dial allowed zero items")
    end
end

-- ---- the lines -----------------------------------------------------------

check(DMKitForm.grantLine{ kind = "item", type = "Base.Axe", count = 2 }
      :find("Base.Axe") ~= nil, "an item line did not name its type")
check(DMKitForm.grantLine{ kind = "counter", name = "runs", add = 1 }
      ~= DMKitForm.grantLine{ kind = "counter", name = "runs", set = 1 },
    "ADD AND SET DRAW ALIKE. They are different instructions and the list is "
    .. "where an admin checks which one they wrote.")
check(DMKitForm.grantLine(ROULETTE):find("2") ~= nil,
    "a roulette line did not say how many branches it carries - it is the one "
    .. "row whose contents are not on screen")
check(DMKitForm.grantLine("nonsense"):find("malformed") ~= nil,
    "a malformed grant drew as something legitimate")

check(DMKitForm.requireLine("delver"):find("delver") ~= nil,
    "a flag requirement did not name itself")
check(DMKitForm.requireLine{ name = "samples", atLeast = 10 }:find("10") ~= nil,
    "A COUNTER REQUIREMENT DID NOT SHOW ITS BOUND. 'Samples' and 'Samples at "
    .. "least 10' are different requirements and would look identical.")

-- ---- acknowledge ---------------------------------------------------------
--
-- The window closes on ITS OWN save and nothing else. One client is both this
-- form and the catalogue tab, and every one of the tab's verbs answers on the
-- same envelope.

local closed = false
DMKitForm.win = { savingId = "anomaly_loot", close = function() closed = true end }

DMKitForm.acknowledge{ command = "kitDelete", id = "anomaly_loot" }
check(closed == false,
    "A DELETE CLOSED THE EDITOR. Deleting some other kit would throw away a "
    .. "form somebody was halfway through.")

DMKitForm.acknowledge{ command = "kitDefine", id = "something_else" }
check(closed == false,
    "another kit's save closed this window - two admins authoring at once is "
    .. "the ordinary case, not the exotic one")

DMKitForm.acknowledge{ command = "kitDefine", id = "anomaly_loot" }
check(closed == true, "the editor did not close on its own save")

DMKitForm.win = nil
local okAck = pcall(DMKitForm.acknowledge, { command = "kitDefine" })
check(okAck, "acknowledge faulted with no window open")

-- ---- THE ITEM TYPE-AHEAD -------------------------------------------------
--
-- The item field is registry-backed, not prose: "Base.Nails" is a spelling the
-- game never shows anyone. It searches through DFItemQuery, which is the SAME
-- search behind the admin panel's Add Item field - a second ranker here would
-- drift, and "nails finds it over there but not in here" is a difference nobody
-- reports as a bug.

local askedFor = nil
DFItemQuery = { search = function(q, limit)
    askedFor = { q = q, limit = limit }
    return { { full = "Base.Nails", disp = "Nails" },
             { full = "Base.NailsBox", disp = "Box of Nails" } }
end }

local itemSchema = DMKitForm.rowSchema("item")
local typeRow
for _, e in ipairs(itemSchema) do if e.key == "type" then typeRow = e end end
check(typeRow ~= nil, "the item grant lost its type field")
check(type(typeRow.suggest) == "function",
    "THE ITEM FIELD HAS NO TYPE-AHEAD. It is a registry field, and asking for "
    .. "an exact fullType from memory is what the admin panel stopped doing.")

local rows = typeRow.suggest("nail")
check(askedFor and askedFor.q == "nail",
    "the field did not pass what was typed to the search")
check(askedFor and askedFor.limit == 8,
    "the field asked for a row count the band cannot draw: "
    .. tostring(askedFor and askedFor.limit))
check(#rows == 2, "the matches did not come back: " .. #rows)
check(rows[1].value == "Base.Nails",
    "A ROW'S VALUE MUST BE THE FULL TYPE - it is what lands in the field and "
    .. "what the server resolves. The display name resolves to nothing.")
check(rows[1].label == "Nails",
    "the row lost the name an admin is actually searching for")

-- The other kinds are unaffected: a trait id and a perk are still typed, and a
-- count is still a number. Declaring a provider on a row that has no registry
-- behind it would open a band that never fills.
local counterSchema = DMKitForm.rowSchema("counter")
for _, e in ipairs(counterSchema) do
    check(e.suggest == nil,
        "a counter field declared a type-ahead with nothing to search: " .. e.key)
end

-- ---- BULK ITEM ENTRY ------------------------------------------------------
--
-- One at a time is right while deciding; it is transcription when the list
-- already exists (owner, 2026-08-23). What is at risk is a parser that
-- SILENTLY misreads: a missing comma turning two items into one nonsense type,
-- a count swallowed as part of a name, or a stray separator inventing a grant.
-- Every one of those saves cleanly and hands out the wrong loot.
--
-- THE SYNTAX IS WHAT grantLine PRINTS. That round trip - read the pane, retype
-- or paste the list - is the whole reason for `xN`, so it is pinned here
-- directly rather than assumed.

local function parsed(text, dflt)
    local e, why = DMKitForm.parseItemList(text, dflt)
    return e, why
end

local one = parsed("Base.Axe", 1)
check(one and #one == 1 and one[1].type == "Base.Axe" and one[1].count == 1,
    "a single type did not parse")

local many = parsed("Base.Nails x5, Base.Axe, Base.Hammer x2", 1)
check(many and #many == 3, "the list did not split: " .. tostring(many and #many))
check(many and many[1].count == 5, "an inline count was lost")
check(many and many[2].type == "Base.Axe" and many[2].count == 1,
    "an entry without a count did not fall back")
check(many and many[3].count == 2, "the last entry's count was lost")

-- THE ROUND TRIP. What the grants pane prints must parse back.
local printed = DMKitForm.grantLine{ kind = "item", type = "Base.Axe", count = 3 }
local tail = printed:match("item%s+(.*)$")
local back = parsed(tail, 1)
check(back and back[1].type == "Base.Axe" and back[1].count == 3,
    "THE LIST DOES NOT ROUND TRIP. grantLine prints '" .. tostring(tail)
    .. "' and the parser could not read it back, so a list cannot be lifted "
    .. "from one kit into another - which is the point of the syntax.")

-- The Count dial is the fallback, and inline beats it.
local dflt = parsed("Base.Axe, Base.Nails x9", 4)
check(dflt and dflt[1].count == 4, "the dial's count was not used as the default")
check(dflt and dflt[2].count == 9, "an inline count lost to the dial")

-- Forgiving where forgiving costs nothing.
check(#parsed("Base.Axe,  Base.Nails ,", 1) == 2,
    "a trailing comma or loose spacing broke the list")

-- REFUSALS, each naming what it saw.
check(parsed("", 1) == nil, "an empty list was accepted")
check(parsed("   ", 1) == nil, "whitespace parsed as an item")
check(parsed(",,,", 1) == nil, "a list of separators invented grants")
check(parsed(nil, 1) == nil, "a nil input did not refuse")

local _, whyMod = parsed("Axe", 1)
check(whyMod and whyMod:find("Base.Axe") ~= nil,
    "a module-less type was refused without suggesting the fix")

local _, whySpace = parsed("Base.Fire Axe", 1)
check(whySpace ~= nil,
    "A TYPE WITH A SPACE WAS ACCEPTED. That is a missing comma every time, and "
    .. "it would save as one item type that cannot exist.")

local _, whyBare = parsed("x5", 1)
check(whyBare ~= nil, "a count with no item was accepted")

-- expandGrants: the seam the Add flow uses.
local made = DMKitForm.expandGrants("item",
    { type = "Base.Nails x2, Base.Axe", count = 1 }, true)
check(made and #made == 2, "expandGrants did not produce one grant per entry")
check(made[1].kind == "item" and made[1].type == "Base.Nails" and made[1].count == 2,
    "an expanded grant came out malformed")

-- ...and with lists OFF (the Edit path) it is exactly the old one-row behaviour.
local single = DMKitForm.expandGrants("item",
    { type = "Base.Nails x2, Base.Axe", count = 1 }, false)
check(single and #single == 1,
    "AN EDIT EXPLODED ONE ROW INTO SEVERAL. Editing a row must edit that row; "
    .. "silently turning it into three is not something a row editor does.")
check(single[1].type == "Base.Nails x2, Base.Axe",
    "the edit path parsed a list it was told not to")

-- Other kinds are untouched by any of this.
local tr = DMKitForm.expandGrants("trait", { id = "base:Brave" }, true)
check(tr and #tr == 1 and tr[1].id == "base:Brave",
    "a trait grant was disturbed by the list logic")

check(DMKitForm.itemTotal(many) == 8, "the item total did not add up: "
    .. tostring(DMKitForm.itemTotal(many)))

-- The schema says so, and only where it is true.
local addSchema  = DMKitForm.rowSchema("item", true)
local editSchema = DMKitForm.rowSchema("item", false)
-- "comma", not "list": the Edit rule legitimately says "pick from the list",
-- meaning the type-ahead. Only the comma syntax is the thing Edit refuses.
check(addSchema[1].rule:find("comma") ~= nil,
    "the Add field does not mention that a comma-separated list is allowed")
check(editSchema[1].rule:find("comma") == nil,
    "the Edit field advertises a comma list it will refuse")
local okAdd = addSchema[1].validate("Base.Nails x5, Base.Axe")
check(okAdd == true, "the Add field refused a valid list")
local okEdit, whyEdit = editSchema[1].validate("Base.Nails, Base.Axe")
check(okEdit == false and whyEdit ~= nil,
    "the Edit field accepted a list and would have stored it as one type")

-- ---- THE PANE ARITHMETIC -------------------------------------------------
--
-- The bug this section exists for, found in play on 2026-08-23: the definition
-- form was given whatever two fixed list shares left over, so at a font taller
-- than the one the fraction was tuned against its last rows fell below the
-- fold. DFForm scrolls, and correctly draws and hit-tests NOTHING that is out
-- of view - so "Claimable", a dial with no default that a kit cannot be saved
-- without, was not awkward to reach. It was absent, and Create refused with a
-- sentence naming a control that was not on screen.
--
-- A fixture cannot render a font. What it CAN do is sweep the heights a font
-- would produce and hold the rule that survives all of them: THE FORM IS NEVER
-- THE FIRST PANE CUT.

local ROWH = 22

-- What it asks for is what it gets, when it gets what it asks for.
local wantBody = DMKitForm.wants(300, ROWH)
local fH, rH, gH = DMKitForm.panes(wantBody, 300, ROWH)
check(fH == 300, "the form did not get its content height in a body sized for "
    .. "exactly that: " .. fH)
check(fH + rH + gH == wantBody, "the panes did not add up to the body they "
    .. "were split from: " .. (fH + rH + gH) .. " of " .. wantBody)
check(rH >= 2 * ROWH and gH >= 2 * ROWH,
    "a list came out below its own floor in a body that had room for both")

-- Surplus goes to the grants list, not to the form. A form padded past its
-- content is empty space under the last dial; a taller grants list is rows.
local sfH, srH, sgH = DMKitForm.panes(wantBody + 200, 300, ROWH)
check(sfH == 300, "the form grew past its own content and swallowed the surplus")
check(sgH == gH + 200, "THE SURPLUS DID NOT REACH THE GRANTS LIST. It is the "
    .. "pane a kit is actually built in - 32 grants is a legal kit.")
check(srH == rH, "the requirements list took the surplus")

-- THE SWEEP. A form that grows with the font must keep every pixel it asked
-- for until BOTH lists have been squeezed to their floor. This is the whole
-- invariant: at no font does the form give up a row while a list still has one
-- to spare.
local body = DMKitForm.wants(300, ROWH)
local squeezed = 0
for needs = 100, 900, 17 do
    local a, b, c = DMKitForm.panes(body, needs, ROWH)
    local floors = (b <= 2 * ROWH) and (c <= 2 * ROWH)
    if a < needs then
        squeezed = squeezed + 1
        check(floors, "THE FORM WAS CUT WHILE A LIST STILL HAD ROWS TO GIVE, "
            .. "at a content height of " .. needs .. " (lists " .. b .. "/" .. c
            .. " against a floor of " .. (2 * ROWH) .. "). This is the bug: a "
            .. "required dial goes off the bottom while two lists sit half "
            .. "empty above it.")
    else
        check(a == needs, "the form got something other than what it asked for "
            .. "at " .. needs .. ": " .. a)
    end
    check(b >= 2 * ROWH and c >= 2 * ROWH,
        "a list was cut below its floor at a content height of " .. needs)
    check(a >= ROWH, "the form pane collapsed to nothing at " .. needs)
end
check(squeezed > 0, "the sweep never reached a form too tall for the body, so "
    .. "it proved nothing about which pane gives first")

-- And the window asks for enough that the ordinary case never squeezes at all.
local askH, askR, askG = DMKitForm.panes(DMKitForm.wants(480, 30), 480, 30)
check(askH == 480 and askR == 3 * 30 and askG == 5 * 30,
    "the height the window asks for does not produce the panes it asked for - "
    .. "wants() and panes() disagree, so the window would open already short")

print(string.format("DMKitForm: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
