-- DFVarsView fixture - the Variables sub-tab's navigation half.
--
-- The tab became two lists on 2026-08-23 and everything about ONE variable
-- moved to DFVarEditor, along with the assertions that guarded it. What is left
-- here is the catalogue: which column a variable belongs in, what its row says,
-- and the selection that Delete is aimed at.
--
-- WHAT IS AT RISK.
--
-- 1. THE SPLIT ITSELF. A variable in the wrong column is a variable an admin
--    reads as the other kind - and the two take opposite verbs. A kind the
--    server sends that matches neither must land in NEITHER list rather than
--    defaulting into one, because a silent default here is a row that lies
--    about what it is.
--
-- 2. THE SELECTION SURVIVING A REFRESH, aimed at Delete. Every action triggers
--    a server push, the push rebuilds both lists, and DFKit.refillList calls
--    clear() - which sets `selected = 1` (ISScrollingListBox.lua:340-345). A
--    tab that read its target off a widget would delete Anomaly, refresh,
--    silently point at whatever is now first, and delete THAT on the next
--    click. Two lists make it worse, not better: without a side, the same name
--    in both columns is ambiguous.
--
-- 3. FORWARDING. There is one OnServerCommand listener and holder traffic
--    belongs to the editor. A reply this file swallowed would leave an open
--    editor showing nothing, and one it failed to forward is the same bug.
--
-- The fake list box reproduces clear() faithfully, on purpose: a stub that
-- preserved the selection would test the fixture's idea of a list widget rather
-- than the one PZ ships. The drawing is not covered; it needs ISUI and Mosaic.

local ROOT = arg[1] or "."
local CORE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua"
local DIR  = ROOT .. "/RequiemOfTheDead/Contents/mods/Dragonfly/42/media/lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then passed = passed + 1
    else failed = failed + 1; print("FAIL DFVarsView: " .. message) end
end

-- ---- stubs ---------------------------------------------------------------

function isServer() return false end
require = function() return true end

local function stubClass()
    local C = {}; C.__index = C
    function C:derive() local D = {}; D.__index = D; setmetatable(D, { __index = C }); return D end
    return C
end
ISScrollingListBox = stubClass()

local function fakeBox(side)
    local box = { items = {}, selected = 1, side = side }
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
          refillList = function(box, fill)
              box:clear()
              if fill then fill(box) end
              return box
          end,
          fitText = function(s) return s end }
DFConfirm = { ask = function() end }
DFCore    = { MODULE = "RFTDDragonfly" }
function getPlayer() return { name = "me", getPlayerNum = function() return 0 end } end

local sent = {}
function sendClientCommand(_, _, command, args)
    sent[#sent + 1] = { command = command, args = args }
end
Events = { OnServerCommand = { Add = function() end } }

-- Both downstream surfaces are stubbed to recorders: this file's job is to
-- forward, and what either DOES with a reply is that fixture's business.
local forwarded = {}
DFVarEditor = { receive = function(command, args)
    forwarded[#forwarded + 1] = { command = command, args = args }
    return command == "AdminVarHolders" or command == "AdminVarsPlayer"
end }

-- The player modal OBSERVES. Its answer is deliberately ignored by the
-- forwarder, and the stub returns true for the traffic it cares about so that
-- a version of DFVarsView which started gating on it would be caught here
-- rather than in game.
local observed = {}
DFPlayerVarsModal = { observe = function(command, args)
    observed[#observed + 1] = { command = command, args = args }
    return command == "AdminVarsPlayer"
end }

RDVarDefs = nil
local okD, errD = pcall(dofile, CORE .. "/shared/RDVarDefs.lua")
check(okD, "RDVarDefs loads: " .. tostring(errD))

DFVarsView = nil
local ok, err = pcall(dofile, DIR .. "/client/Admin/DFVarsView.lua")
check(ok, "module loads: " .. tostring(err))

-- ---- the split -----------------------------------------------------------

local DEFS = {
    { name = "Zeta",    kind = "counter", resetOnDeath = true },
    { name = "Anomaly", kind = "flag", holders = 2 },
    { name = "Loot",    kind = "counter", resetOnDeath = false },
    { name = "Beacon",  kind = "flag", holders = 0 },
}

local flags, counters = DFVarsView.split(DEFS)
check(#flags == 2, "the flag column held " .. #flags .. ", expected 2")
check(#counters == 2, "the counter column held " .. #counters .. ", expected 2")
check(flags[1].name == "Anomaly" and flags[2].name == "Beacon",
    "the flag column was not sorted by name")
check(counters[1].name == "Loot" and counters[2].name == "Zeta",
    "the counter column was not sorted by name - the two lists are read side by "
    .. "side and must behave the same way whatever order the wire delivered")

-- A kind matching neither is dropped from BOTH, rather than defaulting into
-- one. A row in the wrong column tells an admin it is the other kind, and the
-- two take opposite verbs.
local f2, c2 = DFVarsView.split({ { name = "Odd", kind = "sigil" },
                                  { name = "None" } })
check(#f2 == 0 and #c2 == 0,
    "a variable of an unknown kind was filed into a column anyway")

local f3, c3 = DFVarsView.split(nil)
check(#f3 == 0 and #c3 == 0, "split faulted on nothing")

-- ---- the row's tag -------------------------------------------------------
-- A flag reports how many hold it. A counter cannot report the same thing -
-- "how many have a value" is not "how many hold it" - so it reports its
-- lifecycle instead of a number that would read as a holder count.

check(DFVarsView.tagFor{ kind = "flag", holders = 3 } == "3",
    "a flag row did not show its holder count")
check(DFVarsView.tagFor{ kind = "flag" } == "0",
    "a flag nobody holds showed something other than zero")
check(DFVarsView.tagFor{ kind = "counter", resetOnDeath = true } == "resets",
    "a resetting counter did not say so")
check(DFVarsView.tagFor{ kind = "counter", resetOnDeath = false } == "keeps",
    "a surviving counter did not say so")
check(DFVarsView.tagFor{ kind = "counter", resetOnDeath = true }
      ~= DFVarsView.tagFor{ kind = "counter", resetOnDeath = false },
    "both counter lifecycles render alike")
-- A world counter has no resetOnDeath at all, so "keeps" would be a lifecycle
-- answer invented for a question that does not apply. It reports its SCOPE
-- instead - which is also the fact that decides whether the row can appear on
-- any player's variables list.
check(DFVarsView.tagFor{ kind = "counter", scope = "world" } == "world",
    "a world counter reported a lifecycle it does not have: "
    .. DFVarsView.tagFor{ kind = "counter", scope = "world" })
check(DFVarsView.tagFor{ kind = "counter", scope = "player", resetOnDeath = true }
      == "resets", "the per-player tag changed when scopes arrived")
check(DFVarsView.tagFor(nil) == "", "tagFor faulted on nil")

-- ---- receive -------------------------------------------------------------

sent = {}
check(DFVarsView.receive("AdminVars", { defs = DEFS }) == true,
    "the catalogue reply was ignored")
check(#DFVarsView.defs == 4, "the catalogue did not land")

check(DFVarsView.receive("AdminVarsStale", {}) == true,
    "the stale push was ignored")
check(sent[#sent].command == "varsList",
    "a stale push did not re-read the catalogue")

-- Holder traffic is the editor's. One listener, one intake - two would race for
-- the same replies.
forwarded, observed = {}, {}
check(DFVarsView.receive("AdminVarHolders", { name = "Anomaly" }) == true,
    "a holder reply was not handled")
check(#forwarded == 1 and forwarded[1].command == "AdminVarHolders",
    "a holder reply was swallowed instead of forwarded to the editor")
check(DFVarsView.receive("AdminVarsPlayer", { username = "A" }) == true,
    "a per-player reply was not handled")
check(#forwarded == 2, "a per-player reply was not forwarded")

-- THE MODAL OBSERVES, IT DOES NOT CLAIM. Both surfaces can legitimately want
-- the same per-player push: the modal is showing that player, and the editor
-- reads any such push as "a verb landed somewhere, re-read the holders". The
-- stub above returns true for it, so a forwarder that short-circuited on that
-- answer would starve the editor here.
check(#observed == 2,
    "a reply reached the editor without being offered to the player modal")
check(forwarded[2].command == "AdminVarsPlayer",
    "THE MODAL CLAIMED A REPLY THE EDITOR ALSO NEEDED. An open editor would go "
    .. "stale the moment somebody opened a player's variables, with nothing on "
    .. "screen to say it had.")

forwarded, observed = {}, {}
check(DFVarsView.receive("SomethingElse", {}) == false,
    "an unrelated command was consumed")
check(#forwarded == 1,
    "an unrelated command was not offered to the editor before being declined")
check(#observed == 1,
    "an unrelated command skipped the modal, so a command it later learns to "
    .. "handle would never reach it")

-- ---- the selection, across a refresh -------------------------------------

DFVarsView.flagBox    = fakeBox("flag")
DFVarsView.counterBox = fakeBox("counter")
DFVarsView.defs       = DEFS
DFVarsView.selected   = "Beacon"
DFVarsView.side       = "flag"
DFVarsView.rebuild()

check(DFVarsView.flagBox.selected == 2,
    "the widget index was not re-derived from the remembered name: "
    .. tostring(DFVarsView.flagBox.selected))
check(DFVarsView.counterBox.selected == -1,
    "the OTHER column kept a highlight, so the tab would show two selections "
    .. "and Delete would be aimed at an ambiguous one")

-- The refresh that follows every action, with the list back in a different
-- order - which is what happens the moment another admin adds a variable.
DFVarsView.defs = {
    { name = "Beacon",  kind = "flag", holders = 0 },
    { name = "Aardvark", kind = "flag", holders = 1 },
    { name = "Anomaly", kind = "flag", holders = 2 },
}
DFVarsView.rebuild()
check(DFVarsView.selected == "Beacon",
    "THE SELECTION MOVED ACROSS A REFRESH. clear() drops the widget to row 1, "
    .. "so the next Delete would remove whichever variable happened to be "
    .. "first: " .. tostring(DFVarsView.selected))
check(DFVarsView.flagBox.selected == 3,
    "the highlight and the selection disagree, so the tab would draw one row "
    .. "and delete another")

-- The same NAME in the other column is a different variable. Without the side,
-- the tab would highlight a counter because a flag of that name was selected.
DFVarsView.defs = {
    { name = "Echo", kind = "flag", holders = 0 },
    { name = "Echo", kind = "counter", resetOnDeath = true },
}
DFVarsView.selected, DFVarsView.side = "Echo", "counter"
DFVarsView.rebuild()
check(DFVarsView.counterBox.selected == 1, "the counter column lost its selection")
check(DFVarsView.flagBox.selected == -1,
    "A FLAG WAS HIGHLIGHTED BECAUSE A COUNTER OF THE SAME NAME WAS SELECTED. "
    .. "The two columns hold different variables and Delete would take the "
    .. "wrong one.")

-- Deleted out from under the selection: no selection, rather than sliding onto
-- a neighbour that Delete would then remove.
DFVarsView.defs = { { name = "Other", kind = "flag", holders = 0 } }
DFVarsView.rebuild()
check(DFVarsView.selected == nil,
    "the selection slid onto a neighbour after its own variable was deleted: "
    .. tostring(DFVarsView.selected))
check(DFVarsView.flagBox.selected == -1 and DFVarsView.counterBox.selected == -1,
    "a highlight survived the variable it pointed at")

-- ...and a variable of that name reappearing must NOT silently re-select it.
DFVarsView.defs = DEFS
DFVarsView.rebuild()
check(DFVarsView.selected == nil,
    "a variable that came back was silently re-selected, so the next Delete "
    .. "would act on something nobody pointed at")

-- The catalogue reply clears a selection whose variable is gone. This looks
-- redundant with the rebuild's own cleanup and is not: rebuild() returns
-- immediately when the lists do not exist yet, so a catalogue arriving BEFORE
-- the tab was ever attached - which is exactly what a stale push from another
-- admin does - would leave the selection pointing at a deleted variable with
-- nothing to clear it.
DFVarsView.flagBox, DFVarsView.counterBox = nil, nil
DFVarsView.selected, DFVarsView.side = "Anomaly", "flag"
DFVarsView.receive("AdminVars", { defs = { { name = "Loot", kind = "counter" } } })
check(DFVarsView.selected == nil,
    "the selection stayed on a variable removed from under it, with no lists "
    .. "attached to clean up after it: " .. tostring(DFVarsView.selected))
check(DFVarsView.side == nil, "the side outlived the selection")

-- And with the lists attached, both paths agree.
DFVarsView.flagBox    = fakeBox("flag")
DFVarsView.counterBox = fakeBox("counter")
DFVarsView.selected, DFVarsView.side = "Anomaly", "flag"
DFVarsView.receive("AdminVars", { defs = { { name = "Loot", kind = "counter" } } })
check(DFVarsView.selected == nil, "the attached path disagreed with the bare one")

print(string.format("DFVarsView: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
