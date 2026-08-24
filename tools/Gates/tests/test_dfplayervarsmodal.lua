-- DFPlayerVarsModal fixture - one player's variables, the inverse read.
--
-- DFVarEditor asks "who holds this variable". This window asks "what does this
-- player hold", and an admin looking at a stuck quest is holding a PLAYER in
-- mind, not a variable.
--
-- WHAT IS AT RISK.
--
-- 1. THE THREE EMPTY STATES. "Not asked yet", "asked, holds none" and "asked,
--    holds none of THIS kind" are three different facts. Render the first two
--    alike and an admin concludes "no flags" from a request that never landed -
--    which is the exact shape of a wrong call about somebody's progression.
--
-- 2. ABSENT IS NOT ZERO, one layer further out than the editor's version: a
--    counter reaches this window only when the player HAS a value, and a value
--    of zero must survive both the split and the cell.
--
-- 3. OBSERVING RATHER THAN CLAIMING. DFVarsView owns the single
--    OnServerCommand listener and offers per-player pushes here first. An open
--    editor wants the same push - it reads any of them as "a verb landed
--    somewhere, re-read the holders" - so a window that consumed one would
--    leave the editor stale with no way to notice. observe() therefore reports
--    whether the push was FOR its player and never gates the chain, and the
--    forwarding in DFVarsView ignores its answer on purpose.
--
-- 4. A REPLY FOR THE WRONG PLAYER. Answers arrive unordered against clicks.
--    One drawn under this window's title would attribute one player's flags to
--    another, which is the worst thing a read-only screen can do.
--
-- The drawing is not covered; it needs ISUI and Mosaic.

local ROOT = arg[1] or "."
local CORE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua"
local DIR  = ROOT .. "/RequiemOfTheDead/Contents/mods/Dragonfly/42/media/lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then passed = passed + 1
    else failed = failed + 1; print("FAIL DFPlayerVarsModal: " .. message) end
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
ISCollapsableWindow = stubClass()

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
          col = { text = {}, textDim = {} },
          rowHeight = function() return 22 end,
          refillList = function(box, fill)
              box:clear()
              if fill then fill(box) end
              return box
          end,
          fitText = function(s) return s end }
DFCore = { MODULE = "RFTDDragonfly" }
function getPlayer() return { name = "me", getPlayerNum = function() return 0 end } end

local sent = {}
function sendClientCommand(_, _, command, args)
    sent[#sent + 1] = { command = command, args = args }
end

RDVarDefs = nil
local okD, errD = pcall(dofile, CORE .. "/shared/RDVarDefs.lua")
check(okD, "RDVarDefs loads: " .. tostring(errD))

DFPlayerVarsModal = nil
local ok, err = pcall(dofile, DIR .. "/client/Admin/DFPlayerVarsModal.lua")
check(ok, "module loads: " .. tostring(err))
local M = DFPlayerVarsModal

-- ---- the split -----------------------------------------------------------

local RECORD = {
    username = "Alice",
    flags   = { { key = "zeta", name = "Zeta", by = "Omen" },
                { key = "anomaly", name = "anomaly" } },
    numbers = { { key = "samples", name = "Samples", value = 0 },
                { key = "loot", name = "Loot", value = 12 } },
}

local flags, counters = M.split(RECORD)
check(#flags == 2 and #counters == 2, "the two halves did not come through")
-- Case-insensitive, because the wire sorts by KEY and the screen shows the
-- NAME. Those differ only in case, which is enough to put "anomaly" after
-- "Zeta" in an order the eye reads as broken.
check(flags[1].name == "anomaly" and flags[2].name == "Zeta",
    "the flag column sorted case-sensitively, so display order and the drawn "
    .. "names disagree: " .. tostring(flags[1].name))
check(counters[1].name == "Loot" and counters[2].name == "Samples",
    "the counter column was not sorted by name")

local f0, c0 = M.split(nil)
check(#f0 == 0 and #c0 == 0, "split faulted on nothing")
local f1, c1 = M.split({ username = "Bob" })
check(#f1 == 0 and #c1 == 0, "split faulted on a record with neither half")

-- A counter set to zero is IN the record and must survive the split. If it
-- were filtered here, a player deliberately reset to 0 would read as one who
-- had never started.
local z = select(2, M.split{ numbers = { { name = "S", value = 0 } } })
check(#z == 1 and z[1].value == 0, "A ZERO COUNTER WAS DROPPED BY THE SPLIT")

-- ---- the cells -----------------------------------------------------------

check(M.cellFor("counter", { value = 0 }) == "0", "zero rendered as something else")
check(M.cellFor("counter", { value = 0 }) ~= M.cellFor("counter", {}),
    "A COUNTER SET TO ZERO AND ONE NOBODY TOUCHED RENDER ALIKE. Absent is not "
    .. "zero, and every repeatable quest built on this loses its 'have you "
    .. "started' test.")
check(M.cellFor("counter", { value = 12 }) == "12", "a counter value was mangled")

-- A flag's cell is WHO granted it, because that is the follow-up question
-- every unexpected flag produces.
check(M.cellFor("flag", { by = "Omen" }) == "Omen", "the granter was lost")
check(M.cellFor("flag", {}) == "-", "a flag with no recorded granter faulted")
check(M.cellFor("flag", { by = "" }) == "-", "an empty granter drew as a name")
check(M.cellFor("flag", nil) == "-", "cellFor faulted on a nil row")

-- ---- the empty states ----------------------------------------------------

check(M.emptyLine(nil, "flag") ~= M.emptyLine({}, "flag"),
    "A REQUEST THAT NEVER LANDED AND A PLAYER WITH NO FLAGS READ ALIKE. One is "
    .. "a fact about the player and the other is a fact about the network, and "
    .. "an admin acting on the first when it was the second acts on nothing.")
check(M.emptyLine({}, "flag") ~= M.emptyLine({}, "counter"),
    "both kinds report emptiness in the same words")

-- ---- observe -------------------------------------------------------------

M.win = { user = "Alice", flagBox = fakeBox(), counterBox = fakeBox() }

check(M.observe("SomethingElse", { username = "Alice" }) == false,
    "an unrelated command was taken")
check(M.record == nil, "an unrelated command overwrote the record")

-- A reply for somebody else is DROPPED, not drawn under this title.
check(M.observe("AdminVarsPlayer", { username = "Bob", flags = {}, numbers = {} }) == false,
    "A REPLY FOR THE WRONG PLAYER WAS ACCEPTED. Answers arrive unordered "
    .. "against clicks, and one drawn here attributes Bob's flags to Alice.")
check(M.record == nil, "the wrong player's record was stored")

check(M.observe("AdminVarsPlayer", RECORD) == true, "the reply for the shown player was dropped")
check(M.record == RECORD, "the record did not land")
check(#M.win.flagBox.items == 2 and #M.win.counterBox.items == 2,
    "the lists were not refilled from the reply")

-- Nothing is selectable here: every verb lives in DFVarEditor, so a highlight
-- would arm nothing on a screen full of panels whose highlights arm something.
check(M.win.flagBox.selected == -1 and M.win.counterBox.selected == -1,
    "a row was left highlighted, which reads as a target for a verb this "
    .. "window does not have")

-- With no window open the push belongs to somebody else entirely.
M.win = nil
M.record = nil
check(M.observe("AdminVarsPlayer", RECORD) == false,
    "a closed window claimed a reply")
check(M.record == nil, "a closed window stored a record")

-- ---- refresh -------------------------------------------------------------

sent = {}
M.refresh()
check(#sent == 0, "a closed window asked the server for a player")

M.win = { user = "Alice" }
sent = {}
M.refresh()
check(#sent == 1 and sent[1].command == "varsOfPlayer"
      and sent[1].args.user == "Alice",
    "the read did not name its player")

-- rebuild before the widgets exist is the ordinary case for a reply that beats
-- createChildren, and must not fault.
M.record = RECORD
local okR = pcall(M.rebuild)
check(okR, "rebuild faulted with no lists attached")

print(string.format("DFPlayerVarsModal: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
