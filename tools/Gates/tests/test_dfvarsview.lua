-- DFVarsView fixture - the pure half of the vars admin sub-tab.
--
-- WHAT IS AT RISK. Three things, and none of them looks like a bug on screen.
--
-- 1. buildDef turns a form into a DEFINITION. Two of its rules exist to stop a
--    var nobody meant: `death = false` must not be STORED as a revoker (RDVarDefs
--    treats an absent revoker and a false one as different, and the false one
--    leaves a key behind that makes the var read as revocable while nothing
--    revokes it), and a counter must not be created without somebody actually
--    choosing resetOnDeath. A boolean toggle would have quietly defeated the
--    second - a toggle always shows something, so whichever way it starts IS a
--    default - which is why the form uses a three-way choice and why the empty
--    third state is tested here rather than assumed away.
--
-- 2. ABSENT IS NOT ZERO, at the pixel. A counter nobody has touched and a
--    counter somebody set to zero must not render alike; that difference is the
--    entire reason markers and counters are two kinds.
--
-- 3. A LATE REPLY. Holder lists arrive per var and an admin clicks faster than a
--    round trip. A reply for a var they have moved off must be DROPPED, not
--    drawn - rendering one var's holders under another var's heading is the most
--    misleading thing this panel could do, and it would look completely normal.
--
-- The widgets are not covered; they need ISUI and a Mosaic boot.

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
ISScrollingListBox  = stubClass()
ISCollapsableWindow = stubClass()
DFKit = { font = { small = "small" }, metrics = { btnH = 24, pad = 8, gap = 6 },
          col = { text = {}, textDim = {}, accent = {}, accentDim = {}, line = {} },
          rowHeight = function() return 22 end,
          refillList = function() end, fitText = function(s) return s end }
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

DFVarsView = nil
local ok, err = pcall(dofile, DIR .. "/client/Admin/DFVarsView.lua")
check(ok, "module loads: " .. tostring(err))

-- ---- buildDef: markers ---------------------------------------------------

local def, why = DFVarsView.buildDef{
    name = "Anomaly", kind = "char", death = true, expires = 240, kit = "crossbow" }
check(def ~= nil, "a complete marker was refused: " .. tostring(why))
check(def.kind == "char" and def.name == "Anomaly", "the marker came out wrong")
check(def.revokers.death == true, "the death revoker was dropped")
check(def.revokers.expires == 240, "the expiry was dropped")
check(def.revokers.kit == "crossbow", "the kit revoker was dropped")

-- Every unset revoker is ABSENT, not false and not zero.
local bare = DFVarsView.buildDef{ name = "Wave", kind = "char",
                                  death = false, expires = 0, kit = "" }
check(bare ~= nil, "a marker with no revokers was refused")
check(bare.revokers.death == nil,
    "death = false was STORED as a revoker. RDVarDefs treats an absent revoker "
    .. "and a false one as different things, and the key left behind makes the "
    .. "var read as revocable while nothing actually revokes it.")
check(bare.revokers.expires == nil, "an expiry of 0 was stored as a revoker")
check(bare.revokers.kit == nil, "an empty kit id was stored as a revoker")
check(RDVarDefs.isPermanent((RDVarDefs.validate(bare))) == true,
    "a marker with nothing set did not come out PERMANENT - which is what the "
    .. "form told the admin it would be")

-- The real definition validator must accept what the form builds. If these two
-- ever disagree the admin gets a refusal they cannot act on.
local vOk, vWhy = RDVarDefs.validate(def)
check(vOk ~= nil, "the form built a marker the store refuses: " .. tostring(vWhy))

-- ---- buildDef: counters --------------------------------------------------

local counter = DFVarsView.buildDef{ name = "Loot", kind = "string", resetOnDeath = "yes" }
check(counter ~= nil, "a counter was refused")
check(counter.resetOnDeath == true, "'yes' did not become true")
check(DFVarsView.buildDef{ name = "Loot", kind = "string",
                           resetOnDeath = "no" }.resetOnDeath == false,
    "'no' did not become false")
local cOk, cWhy = RDVarDefs.validate(counter)
check(cOk ~= nil, "the form built a counter the store refuses: " .. tostring(cWhy))

-- The one that matters. "" is the dial nobody moved.
local unset, unsetWhy = DFVarsView.buildDef{ name = "Loot", kind = "string",
                                             resetOnDeath = "" }
check(unset == nil,
    "A COUNTER WAS CREATED WITHOUT ANYBODY CHOOSING resetOnDeath. RDVarDefs "
    .. "refuses an unset one precisely so the behaviour is decided rather than "
    .. "inherited, and a form that supplies a value for the unmoved dial hands "
    .. "that decision back to whichever way the control happened to start.")
check(tostring(unsetWhy):find("no default", 1, true) ~= nil,
    "the refusal did not explain itself: " .. tostring(unsetWhy))
check(DFVarsView.buildDef{ name = "Loot", kind = "string" } == nil,
    "a counter with no resetOnDeath field at all was accepted")
check(DFVarsView.buildDef{ name = "Loot", kind = "string",
                           resetOnDeath = true } == nil,
    "a raw boolean was accepted where the form's three-way choice is expected - "
    .. "which would mean the dial and the builder disagree about the shape")

-- ---- buildDef: names and kinds -------------------------------------------
-- Validated by the SERVER'S OWN function, so the two cannot drift.

check(DFVarsView.buildDef{ name = "", kind = "char" } == nil, "an empty name was accepted")
check(DFVarsView.buildDef{ name = "9Lives", kind = "char" } == nil,
    "a name starting with a digit was accepted - it reads as an array index in "
    .. "half the places these keys land")
check(DFVarsView.buildDef{ name = "has space", kind = "char" } == nil,
    "a name with a space was accepted")
check(DFVarsView.buildDef{ name = string.rep("n", RDVarDefs.NAME_MAX + 1),
                           kind = "char" } == nil, "an over-long name was accepted")
check(DFVarsView.buildDef{ name = "  Anomaly  ", kind = "char" }.name == "Anomaly",
    "the name was not trimmed the way the store trims it")
check(DFVarsView.buildDef{ name = "Ok", kind = "wat" } == nil, "an unknown kind was accepted")
check(DFVarsView.buildDef{ name = "Ok" } == nil, "a definition with no kind was accepted")
check(DFVarsView.buildDef(nil) == nil, "buildDef(nil) built something")

-- ---- ABSENT IS NOT ZERO --------------------------------------------------

check(DFVarsView.cellFor("string", { value = 0 }) == "0", "zero rendered as something else")
check(DFVarsView.cellFor("string", { value = nil }) == "-", "absent rendered as something else")
check(DFVarsView.cellFor("string", { value = 0 }) ~= DFVarsView.cellFor("string", {}),
    "A COUNTER SET TO ZERO AND A COUNTER NOBODY TOUCHED RENDER ALIKE. That is "
    .. "the one distinction the two-kind design exists to keep, and every "
    .. "repeatable quest built on this loses its 'have you started' test.")
check(DFVarsView.cellFor("char", { holds = true }) == "holds", "a holder said nothing")
-- The list carries online NON-holders too, so a marker row has two states. Draw
-- them alike and the panel tells an admin that everybody online holds it.
check(DFVarsView.cellFor("char", { online = true }) == "-",
    "AN ONLINE PLAYER WHO DOES NOT HOLD THE MARKER RENDERED AS A HOLDER. The "
    .. "list includes non-holders precisely so they can be granted one; drawing "
    .. "them identically makes the column meaningless.")
check(DFVarsView.cellFor("char", { holds = true }) ~= DFVarsView.cellFor("char", {}),
    "holding and not holding a marker render alike")
check(DFVarsView.cellFor("char", nil) == "-", "cellFor faulted on a nil row")
check(DFVarsView.cellFor("string", { value = 12 }) == "12", "a counter value was mangled")

-- ---- the lifecycle line --------------------------------------------------

check(DFVarsView.lifecycleOf{ kind = "char", revokers = {} } == "permanent",
    "a marker with no revokers did not read as permanent")
check(DFVarsView.lifecycleOf{ kind = "char" } == "permanent",
    "a marker with no revokers TABLE did not read as permanent")
local life = DFVarsView.lifecycleOf{ kind = "char",
    revokers = { death = true, expires = 30, kit = "k" } }
check(life:find("on death", 1, true) and life:find("30 min", 1, true)
      and life:find("kit k", 1, true),
    "the lifecycle line dropped a revoker: " .. life)
check(DFVarsView.lifecycleOf{ kind = "string", resetOnDeath = true } == "resets on death",
    "a resetting counter did not say so")
check(DFVarsView.lifecycleOf{ kind = "string", resetOnDeath = false } == "survives death",
    "a surviving counter did not say so - and 'no lifecycle' is not the same "
    .. "sentence as 'permanent', which is a marker's word")
check(DFVarsView.lifecycleOf(nil) == "", "lifecycleOf(nil) faulted")

-- ---- the late reply ------------------------------------------------------

DFVarsView.defs = { { name = "Anomaly", kind = "char", holders = 2 },
                    { name = "Loot", kind = "string" } }
DFVarsView.selected = "Anomaly"
DFVarsView.holders  = nil

check(DFVarsView.receive("AdminVarHolders",
    { name = "Anomaly", kind = "char", rows = { { user = "A" } }, total = 1 }) == true,
    "a holder reply for the selected var was ignored")
check(DFVarsView.holders ~= nil and #DFVarsView.holders.rows == 1,
    "the holder list did not land")

-- The admin has clicked Loot; Anomaly's answer is still in flight.
DFVarsView.selected = "Loot"
DFVarsView.holders  = nil
DFVarsView.receive("AdminVarHolders",
    { name = "Anomaly", kind = "char", rows = { { user = "A" } }, total = 1 })
check(DFVarsView.holders == nil,
    "A LATE REPLY WAS DRAWN UNDER THE NEW SELECTION. Anomaly's holders would "
    .. "appear beneath Loot's heading, which reads as fact and is false.")

DFVarsView.receive("AdminVarHolders",
    { name = "Loot", kind = "string", rows = { { user = "B", value = 0 } }, total = 1 })
check(DFVarsView.holders ~= nil and DFVarsView.holders.name == "Loot",
    "the reply that DID match was dropped too")

check(DFVarsView.receive("SomethingElse", {}) == false, "an unrelated command was consumed")

-- A definition disappearing under the selection clears it rather than leaving
-- the panel pointed at a var that no longer exists.
DFVarsView.selected = "Anomaly"
sent = {}
DFVarsView.receive("AdminVars", { defs = { { name = "Loot", kind = "string" } } })
check(DFVarsView.selected == "Loot",
    "the selection stayed on a var that was removed from under it: "
    .. tostring(DFVarsView.selected))
check(#sent >= 1 and sent[1].command == "varHolders",
    "moving the selection did not fetch the new var's holders")

print(string.format("DFVarsView: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
