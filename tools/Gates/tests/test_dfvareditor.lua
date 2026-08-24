-- DFVarEditor fixture - one variable: its definition, and who holds it.
--
-- Split out of test_dfvarsview on 2026-08-23 with the code. Every assertion
-- below was written against the old combined panel and is carried over
-- unchanged in substance: the risks did not move when the file did.
--
-- WHAT IS AT RISK. Four things, and none of them looks like a bug on screen.
--
-- 1. buildDef turns a form into a DEFINITION. Two of its rules exist to stop a
--    variable nobody meant: `death = false` must not be STORED as a revoker
--    (RDVarDefs treats an absent revoker and a false one as different, and the
--    false one leaves a key behind that makes the flag read as revocable while
--    nothing revokes it), and a counter must not be created without somebody
--    actually choosing resetOnDeath. A boolean toggle would have quietly
--    defeated the second - a toggle always shows something, so whichever way it
--    starts IS a default - which is why the form uses a three-way choice.
--
--    modelOf is the inverse and is tested as a ROUND TRIP, because this window
--    now opens on existing variables: a model that dropped a revoker would
--    silently strip it from one an admin opened only to rename.
--
-- 2. ABSENT IS NOT ZERO, at the pixel. A counter nobody has touched and one
--    somebody set to zero must not render alike; that difference is the entire
--    reason flags and counters are two kinds.
--
-- 3. A LATE REPLY. Holder lists arrive per variable and an admin clicks faster
--    than a round trip. A reply for a variable this window is not showing must
--    be DROPPED, not drawn - one variable's holders under another's heading
--    reads as fact and is false.
--
-- 4. THE SELECTION SURVIVING A REFRESH, which is the one that modifies the
--    wrong player. Every verb is followed by a server push, the push rebuilds
--    the list, and refillList calls the widget's clear() - which sets
--    `selected = 1` (ISScrollingListBox.lua:340-345). A window that read its
--    target off the widget would act on Alice, refresh, silently point at
--    whoever is first, and modify THEM on the next click.
--
--    The fake list box below reproduces that clear() faithfully, on purpose: a
--    stub that preserved the selection would test the fixture's idea of a list
--    widget rather than the one PZ ships.
--
-- The drawing is not covered; it needs ISUI and a Mosaic boot.

local ROOT = arg[1] or "."
local CORE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua"
local DIR  = ROOT .. "/RequiemOfTheDead/Contents/mods/Dragonfly/42/media/lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then passed = passed + 1
    else failed = failed + 1; print("FAIL DFVarEditor: " .. message) end
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
-- A list box that behaves like the one PZ ships, in the one respect that
-- matters here: clear() drops the selection to row 1.
local function fakeBox()
    local box = { items = {}, selected = 1 }
    function box:clear() self.items = {}; self.selected = 1 end
    function box:addItem(name, item)
        local i = { text = name, item = item }
        self.items[#self.items + 1] = i
        return i
    end
    return box
end

DFKit = { font = { small = "small" }, metrics = { btnH = 24, pad = 8, gap = 6 },
          col = { text = {}, textDim = {}, accent = {}, accentDim = {}, line = {} },
          rowHeight = function() return 22 end,
          -- Faithful to DFKit.refillList in the one respect under test: it
          -- clears before it fills.
          refillList = function(box, fill)
              box:clear()
              if fill then fill(box) end
              return box
          end,
          fitText = function(s) return s end }
DFForm   = { new = function(o) return o end }
DFConfirm = { ask = function() end }
DFCore   = { MODULE = "RFTDDragonfly" }
function getPlayer() return { name = "me", getPlayerNum = function() return 0 end } end

local sent = {}
function sendClientCommand(_, _, command, args)
    sent[#sent + 1] = { command = command, args = args }
end
Events = { OnServerCommand = { Add = function() end } }

-- The REAL RDVarDefs. The form calls normalizeName so the admin gets the
-- server's own answer at the keyboard; a stub would test the fixture's idea of
-- a legal name rather than the store's.
RDVarDefs = nil
local okD, errD = pcall(dofile, CORE .. "/shared/RDVarDefs.lua")
check(okD, "RDVarDefs loads: " .. tostring(errD))

DFVarEditor = nil
local ok, err = pcall(dofile, DIR .. "/client/Admin/DFVarEditor.lua")
check(ok, "module loads: " .. tostring(err))

-- ---- buildDef: flags ---------------------------------------------------

local def, why = DFVarEditor.buildDef{
    name = "Anomaly", kind = "flag", death = true, expires = 240, kit = "crossbow" }
check(def ~= nil, "a complete flag was refused: " .. tostring(why))
check(def.kind == "flag" and def.name == "Anomaly", "the flag came out wrong")
check(def.revokers.death == true, "the death revoker was dropped")
check(def.revokers.expires == 240, "the expiry was dropped")
check(def.revokers.kit == "crossbow", "the kit revoker was dropped")

-- Every unset revoker is ABSENT, not false and not zero.
local bare = DFVarEditor.buildDef{ name = "Wave", kind = "flag",
                                  death = false, expires = 0, kit = "" }
check(bare ~= nil, "a flag with no revokers was refused")
check(bare.revokers.death == nil,
    "death = false was STORED as a revoker. RDVarDefs treats an absent revoker "
    .. "and a false one as different things, and the key left behind makes the "
    .. "var read as revocable while nothing actually revokes it.")
check(bare.revokers.expires == nil, "an expiry of 0 was stored as a revoker")
check(bare.revokers.kit == nil, "an empty kit id was stored as a revoker")
check(RDVarDefs.isPermanent((RDVarDefs.validate(bare))) == true,
    "a flag with nothing set did not come out PERMANENT - which is what the "
    .. "form told the admin it would be")

-- The real definition validator must accept what the form builds. If these two
-- ever disagree the admin gets a refusal they cannot act on.
local vOk, vWhy = RDVarDefs.validate(def)
check(vOk ~= nil, "the form built a flag the store refuses: " .. tostring(vWhy))

-- ---- buildDef: counters --------------------------------------------------

local counter = DFVarEditor.buildDef{ name = "Loot", kind = "counter", resetOnDeath = "yes" }
check(counter ~= nil, "a counter was refused")
check(counter.resetOnDeath == true, "'yes' did not become true")
check(DFVarEditor.buildDef{ name = "Loot", kind = "counter",
                           resetOnDeath = "no" }.resetOnDeath == false,
    "'no' did not become false")
local cOk, cWhy = RDVarDefs.validate(counter)
check(cOk ~= nil, "the form built a counter the store refuses: " .. tostring(cWhy))

-- The one that matters. "" is the dial nobody moved.
local unset, unsetWhy = DFVarEditor.buildDef{ name = "Loot", kind = "counter",
                                             resetOnDeath = "" }
check(unset == nil,
    "A COUNTER WAS CREATED WITHOUT ANYBODY CHOOSING resetOnDeath. RDVarDefs "
    .. "refuses an unset one precisely so the behaviour is decided rather than "
    .. "inherited, and a form that supplies a value for the unmoved dial hands "
    .. "that decision back to whichever way the control happened to start.")
check(tostring(unsetWhy):find("no default", 1, true) ~= nil,
    "the refusal did not explain itself: " .. tostring(unsetWhy))
check(DFVarEditor.buildDef{ name = "Loot", kind = "counter" } == nil,
    "a counter with no resetOnDeath field at all was accepted")
check(DFVarEditor.buildDef{ name = "Loot", kind = "counter",
                           resetOnDeath = true } == nil,
    "a raw boolean was accepted where the form's three-way choice is expected - "
    .. "which would mean the dial and the builder disagree about the shape")

-- ---- buildDef: names and kinds -------------------------------------------
-- Validated by the SERVER'S OWN function, so the two cannot drift.

check(DFVarEditor.buildDef{ name = "", kind = "flag" } == nil, "an empty name was accepted")
check(DFVarEditor.buildDef{ name = "9Lives", kind = "flag" } == nil,
    "a name starting with a digit was accepted - it reads as an array index in "
    .. "half the places these keys land")
check(DFVarEditor.buildDef{ name = "has space", kind = "flag" } == nil,
    "a name with a space was accepted")
check(DFVarEditor.buildDef{ name = string.rep("n", RDVarDefs.NAME_MAX + 1),
                           kind = "flag" } == nil, "an over-long name was accepted")
check(DFVarEditor.buildDef{ name = "  Anomaly  ", kind = "flag" }.name == "Anomaly",
    "the name was not trimmed the way the store trims it")
check(DFVarEditor.buildDef{ name = "Ok", kind = "wat" } == nil, "an unknown kind was accepted")
check(DFVarEditor.buildDef{ name = "Ok" } == nil, "a definition with no kind was accepted")
check(DFVarEditor.buildDef(nil) == nil, "buildDef(nil) built something")

-- ---- modelOf: the round trip ---------------------------------------------
-- This window now OPENS on an existing variable, so the definition has to come
-- back into the form and out again unchanged. A model that dropped a revoker
-- would strip it from a variable an admin opened only to fix its name - and the
-- save would look completely successful.

local function roundTrip(def, why)
    local model = DFVarEditor.modelOf(def)
    local back, reason = DFVarEditor.buildDef(model)
    check(back ~= nil, (why or "definition") .. " did not survive the trip: "
        .. tostring(reason))
    return back
end

local full = roundTrip({ kind = "flag", name = "Anomaly",
    revokers = { death = true, expires = 240, kit = "crossbow" } }, "a full flag")
check(full and full.revokers.death == true, "death was lost in the round trip")
check(full and full.revokers.expires == 240, "the expiry was lost")
check(full and full.revokers.kit == "crossbow", "the kit revoker was lost")
check(full and full.name == "Anomaly", "the name was lost")

local perm = roundTrip({ kind = "flag", name = "Wave", revokers = {} },
    "a permanent flag")
check(perm and perm.revokers.death == nil,
    "a permanent flag came back carrying a death revoker")
check(RDVarDefs.isPermanent((RDVarDefs.validate(perm))) == true,
    "a permanent flag stopped being permanent by being opened")

-- The counter's three-way dial opens on its ANSWER, not on "- choose -". The
-- window would otherwise ask a question that was already settled, and an admin
-- who did not notice would be refused a save on a variable they only renamed.
local yes = DFVarEditor.modelOf{ kind = "counter", name = "Loot", resetOnDeath = true }
check(yes.resetOnDeath == "yes", "an existing counter reopened undecided")
local no = DFVarEditor.modelOf{ kind = "counter", name = "Loot", resetOnDeath = false }
check(no.resetOnDeath == "no", "resetOnDeath = false reopened as something else")
check(roundTrip({ kind = "counter", name = "Loot", resetOnDeath = false },
    "a counter").resetOnDeath == false, "the counter's answer flipped")

-- No definition at all is the Create New case: a blank form on Flag, with the
-- counter dial UNSET so it must be answered.
local blank = DFVarEditor.modelOf(nil)
check(blank.name == "" and blank.kind == "flag", "the new-variable model was not blank")
check(blank.resetOnDeath == "",
    "the new-variable model pre-answered resetOnDeath, which is the default "
    .. "nobody chose that RDVarDefs exists to refuse")
check(DFVarEditor.buildDef(blank) == nil, "the blank model built a variable")

-- ---- ABSENT IS NOT ZERO --------------------------------------------------

check(DFVarEditor.cellFor("string", { value = 0 }) == "0", "zero rendered as something else")
check(DFVarEditor.cellFor("string", { value = nil }) == "-", "absent rendered as something else")
check(DFVarEditor.cellFor("string", { value = 0 }) ~= DFVarEditor.cellFor("string", {}),
    "A COUNTER SET TO ZERO AND A COUNTER NOBODY TOUCHED RENDER ALIKE. That is "
    .. "the one distinction the two-kind design exists to keep, and every "
    .. "repeatable quest built on this loses its 'have you started' test.")
check(DFVarEditor.cellFor("flag", { holds = true }) == "holds", "a holder said nothing")
-- The list carries online NON-holders too, so a flag row has two states. Draw
-- them alike and the panel tells an admin that everybody online holds it.
check(DFVarEditor.cellFor("flag", { online = true }) == "-",
    "AN ONLINE PLAYER WHO DOES NOT HOLD THE MARKER RENDERED AS A HOLDER. The "
    .. "list includes non-holders precisely so they can be granted one; drawing "
    .. "them identically makes the column meaningless.")
check(DFVarEditor.cellFor("flag", { holds = true }) ~= DFVarEditor.cellFor("flag", {}),
    "holding and not holding a flag render alike")
check(DFVarEditor.cellFor("flag", nil) == "-", "cellFor faulted on a nil row")
check(DFVarEditor.cellFor("string", { value = 12 }) == "12", "a counter value was mangled")

-- ---- the roster caption --------------------------------------------------
--
-- The line that has to answer "how many hold this" without ever being able to
-- report a row count instead. The list it sits above contains online players
-- who hold nothing (DFVars_Server.holdersOf keeps them so the verbs have a
-- target), so counting rows means a brand new flag opens saying it has one
-- holder: the admin reading it.

local none = DFVarEditor.rosterLine{ kind = "flag", rows = {
    { user = "Omen", online = true } }, total = 1 }
check(none:find("Holders: 0") ~= nil,
    "A FLAG NOBODY HOLDS DID NOT SAY SO. The caption counted the rows, and the "
    .. "only row is the admin who just created it: " .. none)
check(none:find("1 more online") ~= nil,
    "the caption did not account for the roster row it is not counting: " .. none)

local some = DFVarEditor.rosterLine{ kind = "flag", rows = {
    { user = "A", holds = true, online = true },
    { user = "B", holds = true },
    { user = "Zed", online = true } }, total = 3 }
check(some:find("Holders: 2") ~= nil, "the holder count was wrong: " .. some)
check(some:find("1 more online") ~= nil, "the roster count was wrong: " .. some)
check(some:find("not shown") == nil,
    "a complete list claimed rows were hidden: " .. some)

-- Truncated: the difference between total and rows is holders the bound cut,
-- and saying nothing about them is the panel showing 200 and implying that is
-- everyone.
local cut = DFVarEditor.rosterLine{ kind = "flag", rows = {
    { user = "A", holds = true } }, total = 9 }
check(cut:find("8 not shown") ~= nil, "the bound was hidden: " .. cut)

-- A counter counts differently and says so differently. "Holders" is the wrong
-- word for a number, and ZERO IS SET - testing truthiness here would report a
-- player deliberately set to 0 as never having been touched, which is the one
-- distinction the two kinds exist to keep.
local ctr = DFVarEditor.rosterLine{ kind = "counter", rows = {
    { user = "A", value = 0 },
    { user = "B", value = 12 },
    { user = "Zed", online = true } }, total = 3 }
check(ctr:find("Set for: 2") ~= nil,
    "A COUNTER SET TO ZERO WAS NOT COUNTED AS SET: " .. ctr)
check(ctr:find("Holders") == nil,
    "a counter borrowed the flag's vocabulary: " .. ctr)

check(DFVarEditor.rosterLine(nil) == "Loading...",
    "a window that has not been answered yet claimed a count")
check(DFVarEditor.rosterLine{ kind = "flag", rows = {} }:find("Holders: 0") ~= nil,
    "an empty holder list faulted or miscounted")

-- The world half of the caption. There is nobody to count, so the line
-- reports the number - and absent is still not zero, because a counter nothing
-- has written to has never run.
local w0 = DFVarEditor.rosterLine{ kind = "counter", scope = "world", rows = {} }
check(w0:find("Never set") ~= nil,
    "AN UNTOUCHED WORLD COUNTER DID NOT SAY SO: " .. w0)
local w1 = DFVarEditor.rosterLine{ kind = "counter", scope = "world", rows = {},
                                   value = 0 }
check(w1:find("0") ~= nil and w1:find("Never set") == nil,
    "A WORLD COUNTER SET TO ZERO READ AS NEVER SET. Absent means nothing has "
    .. "ever written to it; zero means it ran and was reset: " .. w1)
check(DFVarEditor.rosterLine{ kind = "counter", scope = "world", rows = {},
                              value = 43 }:find("43") ~= nil,
    "the world value was not reported")
check(w0:find("Holders") == nil and w0:find("Set for") == nil,
    "a world counter borrowed the per-player vocabulary: " .. w0)

-- ---- scope, through the form ---------------------------------------------

local wdef = DFVarEditor.buildDef{ name = "Runs", kind = "counter",
                                   scope = "world" }
check(wdef ~= nil and wdef.scope == "world", "the world scope was not built")
check(wdef and wdef.resetOnDeath == nil,
    "A WORLD COUNTER WAS SENT WITH resetOnDeath. RDVarDefs refuses the key "
    .. "outright, so the save would fail for a reason the form already knew.")

-- And a world counter does NOT have to answer the resetOnDeath dial, which is
-- required of every per-player one.
check(DFVarEditor.buildDef{ name = "Samples", kind = "counter",
                            scope = "player" } == nil,
    "a per-player counter escaped the resetOnDeath requirement")

local pdef = DFVarEditor.buildDef{ name = "Samples", kind = "counter",
                                    scope = "player", resetOnDeath = "no" }
check(pdef and pdef.scope == "player", "the player scope was not written out")

-- The round trip has to be exact, or opening a world counter to rename it
-- would save it back as a per-player one.
local back = DFVarEditor.modelOf{ kind = "counter", name = "Runs", scope = "world" }
check(back.scope == "world", "modelOf lost the scope")
check(DFVarEditor.buildDef(back).scope == "world",
    "A WORLD COUNTER ROUND-TRIPPED INTO A PER-PLAYER ONE. Its values live in a "
    .. "different half of the store and RDVars has no move between them.")
check(DFVarEditor.modelOf{ kind = "counter", name = "S", resetOnDeath = true }.scope
      == "player",
    "a definition written before scopes existed did not read as per-player")
check(DFVarEditor.modelOf(nil).scope == "player",
    "the new-variable model did not open on the status quo")

-- ---- the lifecycle line --------------------------------------------------

check(DFVarEditor.lifecycleOf{ kind = "flag", revokers = {} } == "permanent",
    "a flag with no revokers did not read as permanent")
check(DFVarEditor.lifecycleOf{ kind = "flag" } == "permanent",
    "a flag with no revokers TABLE did not read as permanent")
local life = DFVarEditor.lifecycleOf{ kind = "flag",
    revokers = { death = true, expires = 30, kit = "k" } }
check(life:find("on death", 1, true) and life:find("30 min", 1, true)
      and life:find("kit k", 1, true),
    "the lifecycle line dropped a revoker: " .. life)
check(DFVarEditor.lifecycleOf{ kind = "counter", resetOnDeath = true } == "resets on death",
    "a resetting counter did not say so")
check(DFVarEditor.lifecycleOf{ kind = "counter", resetOnDeath = false } == "survives death",
    "a surviving counter did not say so - and 'no lifecycle' is not the same "
    .. "sentence as 'permanent', which is a flag's word")
check(DFVarEditor.lifecycleOf(nil) == "", "lifecycleOf(nil) faulted")

-- ---- the late reply ------------------------------------------------------

DFVarEditor.defs = { { name = "Anomaly", kind = "flag", holders = 2 },
                    { name = "Loot", kind = "counter" } }
DFVarEditor.win = { varName = "Anomaly", holderBox = fakeBox() }
DFVarEditor.holders = nil

check(DFVarEditor.receive("AdminVarHolders",
    { name = "Anomaly", kind = "flag", rows = { { user = "A" } }, total = 1 }) == true,
    "a holder reply for the selected var was ignored")
check(DFVarEditor.holders ~= nil and #DFVarEditor.holders.rows == 1,
    "the holder list did not land")

-- The admin has clicked Loot; Anomaly's answer is still in flight.
DFVarEditor.win.varName = "Loot"
DFVarEditor.holders = nil
DFVarEditor.receive("AdminVarHolders",
    { name = "Anomaly", kind = "flag", rows = { { user = "A" } }, total = 1 })
check(DFVarEditor.holders == nil,
    "A LATE REPLY WAS DRAWN UNDER THE NEW SELECTION. Anomaly's holders would "
    .. "appear beneath Loot's heading, which reads as fact and is false.")

DFVarEditor.receive("AdminVarHolders",
    { name = "Loot", kind = "counter", rows = { { user = "B", value = 0 } }, total = 1 })
check(DFVarEditor.holders ~= nil and DFVarEditor.holders.name == "Loot",
    "the reply that DID match was dropped too")

check(DFVarEditor.receive("SomethingElse", {}) == false, "an unrelated command was consumed")

-- ---- the selection, across a refresh ------------------------------------

DFVarEditor.win = { varName = "Anomaly", holderBox = fakeBox() }
DFVarEditor.holders   = { name = "Anomaly", kind = "flag", rows = {
    { user = "Alice", holds = true, online = true },
    { user = "Bob",   online = true },
    { user = "Carol", holds = true },
} }
DFVarEditor.selectedUser = "Carol"
DFVarEditor.rebuild()

check(DFVarEditor.win.holderBox.selected == 3,
    "the widget index was not re-derived from the remembered username: "
    .. tostring(DFVarEditor.win.holderBox.selected))
check(DFVarEditor.targetUser() == "Carol", "the target was lost by a rebuild")

-- The refresh that follows every action. Carol is still present but the list
-- came back in a different order, which is exactly what happens when somebody
-- logs in or out between one action and the next.
DFVarEditor.holders.rows = {
    { user = "Bob",   online = true },
    { user = "Carol", holds = true, online = true },
    { user = "Alice", holds = true, online = true },
}
DFVarEditor.rebuild()
check(DFVarEditor.targetUser() == "Carol",
    "THE SELECTION MOVED TO ANOTHER PLAYER ACROSS A REFRESH. Every verb here is "
    .. "followed by a push that rebuilds the list, and clear() drops the widget "
    .. "to row 1 - so the second click of a grant/revoke pair would modify "
    .. "whoever happened to be first. Got: " .. tostring(DFVarEditor.targetUser()))
check(DFVarEditor.win.holderBox.selected == 2,
    "the highlight and the target disagree, so the panel would draw the "
    .. "selection on one row and act on another")

-- Carol logs off and drops out of the list. That must become NO target, not
-- row one: guessing here modifies somebody the admin never chose.
DFVarEditor.holders.rows = {
    { user = "Bob",   online = true },
    { user = "Alice", holds = true, online = true },
}
DFVarEditor.rebuild()
check(DFVarEditor.targetUser() == nil,
    "a player who left the list was replaced by whoever is now first, instead "
    .. "of the panel simply having no target: " .. tostring(DFVarEditor.targetUser()))
check(DFVarEditor.win.holderBox.selected == -1,
    "the widget kept a highlight on a row the verbs will not act on")

-- ...and when she logs back IN she must not be silently re-selected. This is
-- what the rebuild's cleanup buys that targetUser's own check does not: without
-- it the remembered name simply waits, and a player reappearing in the list
-- becomes the target of the next click without the admin ever choosing them.
DFVarEditor.holders.rows = {
    { user = "Bob",   online = true },
    { user = "Carol", holds = true, online = true },
    { user = "Alice", holds = true, online = true },
}
DFVarEditor.rebuild()
check(DFVarEditor.targetUser() == nil,
    "A PLAYER WHO LEFT AND CAME BACK WAS SILENTLY RE-SELECTED. The admin "
    .. "chose them before they logged off; the next click would act on them "
    .. "again with nobody having pointed at them: "
    .. tostring(DFVarEditor.targetUser()))
check(DFVarEditor.win.holderBox.selected == -1, "the stale highlight came back too")

-- The other half of the pair. targetUser confirms against the CURRENT rows
-- rather than trusting the remembered name, which is what covers a change to
-- the list that has not been through a rebuild - the state spliceRecord itself
-- passes through on its way in.
DFVarEditor.holders.rows = { { user = "Dave", online = true } }
DFVarEditor.selectedUser = "Dave"
check(DFVarEditor.targetUser() == "Dave", "a present player was not the target")
DFVarEditor.holders.rows = { { user = "Erin", online = true } }
check(DFVarEditor.targetUser() == nil,
    "targetUser trusted the remembered name against a list that no longer "
    .. "holds it, without waiting for a rebuild to notice")
DFVarEditor.selectedUser = nil

-- Selecting a different var drops the player selection with it.
DFVarEditor.selectedUser = "Alice"
DFVarEditor.win.varName = "Anomaly"
DFVarEditor.receive("AdminVarHolders",
    { name = "Anomaly", kind = "flag", rows = { { user = "Alice", holds = true } }, total = 1 })
check(DFVarEditor.targetUser() == "Alice", "the target was dropped by its own var's reply")

-- ---- By name splices a player in ----------------------------------------
-- The escape hatch has to make ALL FOUR verbs reachable, not two. Firing one
-- verb by name left a holder past the row bound grantable forever and never
-- revocable.

DFVarEditor.holders = { name = "Anomaly", kind = "flag", rows = {
    { user = "Alice", holds = true, online = true },
} }
DFVarEditor.selectedUser = nil

check(DFVarEditor.spliceRecord{ username = "Offline",
        flags = { { key = "anomaly", name = "Anomaly" } }, numbers = {} } == true,
    "a fetched record was not spliced into the list")
check(#DFVarEditor.holders.rows == 2, "the fetched player did not become a row")
check(DFVarEditor.targetUser() == "Offline",
    "the fetched player was not selected, so the verbs still have no target "
    .. "for them - which is the whole point of fetching them")
local spliced
for _, r in ipairs(DFVarEditor.holders.rows) do if r.user == "Offline" then spliced = r end end
check(spliced.holds == true, "the record's flag did not reach the row")
check(spliced.pinned == true, "the fetched row was not marked as fetched")


-- A player who IS already listed must be selected, not duplicated: two rows for
-- one player is two answers to one question.
check(DFVarEditor.spliceRecord{ username = "Alice", flags = {}, numbers = {} } == true,
    "splicing an already-listed player failed")
check(#DFVarEditor.holders.rows == 2, "an already-listed player was duplicated")
check(DFVarEditor.targetUser() == "Alice", "the already-listed player was not selected")

-- A record carries EVERYTHING that player holds. Only the selected var's entry
-- may reach the row, or the panel reports somebody as holding the var on screen
-- because they hold a different one entirely.
DFVarEditor.spliceRecord{ username = "Elsewhere",
    flags = { { key = "other", name = "Other" } }, numbers = {} }
local wrong
for _, r in ipairs(DFVarEditor.holders.rows) do
    if r.user == "Elsewhere" then wrong = r end
end
check(wrong ~= nil, "the record was not spliced at all")
check(wrong.holds == nil,
    "A PLAYER WHO HOLDS A DIFFERENT MARKER WAS SHOWN AS HOLDING THIS ONE. The "
    .. "record lists everything they have; only the selected var's entry "
    .. "belongs in a row under the selected var's heading.")


-- The row is derived for the SELECTED var only. A record carries everything
-- that player holds; a row that showed another var's value would be a number
-- under the wrong heading.
DFVarEditor.holders = { name = "Loot", kind = "counter", rows = {} }
DFVarEditor.spliceRecord{ username = "Zed", flags = {},
    numbers = { { key = "loot", name = "Loot", value = 0 },
                { key = "other", name = "Other", value = 99 } } }
check(DFVarEditor.holders.rows[1].value == 0,
    "the spliced row took the wrong var's value: "
    .. tostring(DFVarEditor.holders.rows[1].value))
check(DFVarEditor.spliceRecord(nil) == false, "spliceRecord faulted on nothing")

print(string.format("DFVarEditor: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)


print(string.format("DFVarEditor: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
