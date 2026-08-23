-- DFLayoutEditor fixture - the operations that edit a working layout.
--
-- WHAT IS AT RISK. Every function here is a way to lose a row, and one of them
-- is a way to lose an OPTION - which is the single thing this whole feature
-- promises cannot happen. DFOverlay.apply already guarantees it at the data
-- level: an option the layout never mentions is emitted anyway. This file is
-- the second half of the rule, at the gesture:
--
--   REMOVE IS A HEADER-ONLY VERB.
--
-- Both halves matter and neither substitutes for the other. Without the data
-- rule, a layout that lost an option would hide it silently forever. Without
-- this rule, an option could be dropped out of the layout, reappear by
-- fall-through next to a neighbour, and read as a bug in the panel rather than
-- as a refusal - so the refusal carries a sentence, and the sentence is tested.
--
-- The working list IS the wire shape, which is the other property under test
-- here: what these operations edit is exactly what gets sent, with no
-- conversion at either end for an option to fall through.
--
-- The widget half - drag, buttons, the window - is not covered. It needs ISUI
-- and belongs on a Mosaic boot.

local ROOT = arg[1] or "."
local BASE = ROOT .. "/RequiemOfTheDead/Contents/mods/Dragonfly/42/media/lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then passed = passed + 1
    else failed = failed + 1; print("FAIL DFLayoutEditor: " .. message) end
end

-- ---- stubs ---------------------------------------------------------------
-- Enough ISUI for the file to LOAD. The derive() calls run at file scope, so a
-- missing base class is a load error rather than a nil at first use.

function isServer() return false end
require = function() return true end

local function stubClass()
    local C = {}
    C.__index = C
    function C:derive() local D = {}; D.__index = D; setmetatable(D, { __index = C }); return D end
    return C
end
ISScrollingListBox = stubClass()
ISCollapsableWindow = stubClass()
DFKit = { font = { small = "small" }, metrics = { btnH = 24, pad = 8 },
          col = { text = {}, textDim = {}, accent = {}, accentDim = {} } }
DFConfirm = { ask = function() end }
DFLayout = { held = function() return nil end, save = function() end,
             recover = function() end, shape = function(p) return p end }

DFOverlay = nil
local okO, errO = pcall(dofile, BASE .. "/shared/DFOverlay.lua")
check(okO, "DFOverlay loads: " .. tostring(errO))

DFLayoutEditor = nil
local ok, err = pcall(dofile, BASE .. "/client/Admin/DFLayoutEditor.lua")
check(ok, "module loads: " .. tostring(err))

-- ---- the working list ----------------------------------------------------
-- Seeded with DFOverlay.flatten, so the list under test is byte-for-byte the
-- thing that goes on the wire.

local function opt(n) return { name = n, short = n, label = "The " .. n, type = "boolean" } end
local function page()
    return { page = "RFTDDirge", label = "Dirge", count = 4, sections = {
        { title = nil,       options = { opt("A") } },
        { title = "Visuals", options = { opt("B"), opt("C") } },
        { title = "Audio",   options = { opt("D") } },
    } }
end

local function joined(work)
    local out = {}
    for i, e in ipairs(work) do
        out[i] = (type(e) == "table") and ("<" .. e.h .. ">") or e
    end
    return table.concat(out, ",")
end

local work = DFOverlay.flatten(page())
check(joined(work) == "A,<Visuals>,B,C,<Audio>,D", "seeded as " .. joined(work))

-- Labels are resolved for DRAWING only; the list holds names, because a name is
-- what the server stores and a label is presentation that a translation change
-- would invalidate.
local labels = DFLayoutEditor.labelsOf(page())
check(labels["A"] == "The A", "labelsOf lost a label")
check(labels["<Visuals>"] == nil, "labelsOf invented an entry for a header")
local emptyLabels = DFLayoutEditor.labelsOf(nil)
check(emptyLabels ~= nil and emptyLabels["A"] == nil, "labelsOf(nil) faulted")

-- ---- move ----------------------------------------------------------------

check(DFLayoutEditor.move(work, 6, 1) == 1, "a move to the top was refused")
check(joined(work) == "D,A,<Visuals>,B,C,<Audio>", "after move: " .. joined(work))
check(DFLayoutEditor.move(work, 1, 6) == 6, "a move to the bottom was refused")
check(joined(work) == "A,<Visuals>,B,C,<Audio>,D", "after move back: " .. joined(work))

-- A refused move is a NO-OP, not a clamp. A drag that ended off the list is a
-- drag the admin abandoned, and clamping would silently drop the row at the end
-- of the page.
local before = joined(work)
check(DFLayoutEditor.move(work, 1, 0) == nil, "a move above the list was accepted")
check(DFLayoutEditor.move(work, 1, 99) == nil, "a move past the end was accepted")
check(DFLayoutEditor.move(work, 0, 1) == nil, "a move FROM outside the list was accepted")
check(DFLayoutEditor.move(work, 3, 3) == nil, "a move onto itself reported a change")
check(DFLayoutEditor.move(work, nil, 1) == nil, "a nil index was accepted")
check(joined(work) == before,
    "a refused move still changed the list: " .. joined(work) .. " was " .. before)
check(#work == 6, "a refused move changed the row count")

-- ---- headers -------------------------------------------------------------

local i = DFLayoutEditor.insertHeader(work, 1, "Tuning")
check(i == 1, "the header did not land where it was asked for: " .. tostring(i))
check(joined(work) == "<Tuning>,A,<Visuals>,B,C,<Audio>,D", "after insert: " .. joined(work))

check(DFLayoutEditor.insertHeader(work, 999, "End") == #work,
    "an out-of-range position did not append")
check(DFLayoutEditor.insertHeader(work, nil, "AlsoEnd") == #work, "a nil position did not append")

check(DFLayoutEditor.insertHeader(work, 1, "   ") == nil, "a blank header was inserted")
check(DFLayoutEditor.insertHeader(work, 1, "") == nil, "an empty header was inserted")
check(select(2, DFLayoutEditor.insertHeader(work, 1, "")) ~= nil,
    "a refused insert gave no reason")

-- Titles go through DFOverlay.sanitize, so the editor cannot create a title the
-- server would then clean differently - the stored form and the form the admin
-- typed must not diverge.
DFLayoutEditor.insertHeader(work, 1, "Two\nLines")
check(work[1].h == "Two Lines", "a control character survived: " .. tostring(work[1].h))
DFLayoutEditor.insertHeader(work, 1, string.rep("x", 100))
check(#work[1].h == DFOverlay.MAX_TITLE, "an over-long title was not clamped")

check(DFLayoutEditor.rename(work, 1, "Renamed") == true, "a header could not be renamed")
check(work[1].h == "Renamed", "rename did not take")
check(DFLayoutEditor.rename(work, 1, "  ") == false, "a header was renamed to nothing")
check(work[1].h == "Renamed", "a refused rename still changed the title")

-- An OPTION row must be refused, and refused rather than thrown at. The row is
-- a bare string; assigning a field to one is an error in Lua, so a rename that
-- only checked for nil would take down the click handler instead of answering.
local optRow
for k, e in ipairs(work) do if type(e) == "string" then optRow = k; break end end
local okRen, whyRen = pcall(DFLayoutEditor.rename, work, optRow, "Nope")
check(okRen, "renaming an option row THREW instead of refusing: " .. tostring(whyRen))
check(okRen and whyRen == false, "an option row was renamed")
check(DFLayoutEditor.rename(work, 999, "Nope") == false, "an out-of-range row was renamed")
check(DFLayoutEditor.rename(nil, 1, "Nope") == false, "rename faulted on a nil list")

-- ---- THE REFUSAL ---------------------------------------------------------

local fresh = DFOverlay.flatten(page())
local optionRow
for k, e in ipairs(fresh) do if type(e) == "string" then optionRow = k; break end end

local removed, why = DFLayoutEditor.removeAt(fresh, optionRow)
check(removed == false,
    "AN OPTION WAS REMOVED FROM THE LAYOUT. The model would carry it back in by "
    .. "fall-through, so nothing is lost on the server - but the admin asked to "
    .. "hide an option, appeared to succeed, and will read its reappearance as "
    .. "the panel being broken.")
check(#fresh == 6, "the refused removal changed the list anyway")
check(type(why) == "string" and why:find("cannot be removed", 1, true) ~= nil,
    "the refusal gave no reason - 'why can I not do this' is answered by a "
    .. "sentence here, not by a greyed-out button: " .. tostring(why))
check(why:find("Move it instead", 1, true) ~= nil,
    "the refusal did not say what the admin CAN do instead")

local headerRow
for k, e in ipairs(fresh) do if type(e) == "table" then headerRow = k; break end end
check(DFLayoutEditor.removeAt(fresh, headerRow) == true, "a header could not be removed")
check(#fresh == 5, "removing a header did not shorten the list")
check(joined(fresh) == "A,B,C,<Audio>,D", "after removing a header: " .. joined(fresh))

check(DFLayoutEditor.removeAt(fresh, 99) == false, "an out-of-range row was removed")
check(DFLayoutEditor.removeAt(fresh, nil) == false, "a nil row was removed")
check(DFLayoutEditor.removeAt(nil, 1) == false, "removeAt faulted on a nil list")

-- ---- the round trip ------------------------------------------------------
-- The working list goes to the server AS IS. So an edited list must survive
-- sanitize unchanged, and applying it must still produce every option.

local edited = DFOverlay.flatten(page())
DFLayoutEditor.insertHeader(edited, 1, "Top")
DFLayoutEditor.move(edited, #edited, 2)

local clean, dropped = DFOverlay.sanitize(edited)
check(dropped == 0,
    "the editor produced entries the server would refuse - the working list is "
    .. "the wire shape precisely so this cannot happen")
check(#clean == #edited, "sanitize changed the length of an edited list")

local shaped = DFOverlay.apply(page(), clean)
local names = {}
for _, sec in ipairs(shaped.sections) do
    for _, o in ipairs(sec.options) do names[#names + 1] = o.name end
end
table.sort(names)
check(table.concat(names, ",") == "A,B,C,D",
    "an edited layout lost an option on the way through: " .. table.concat(names, ","))

print(string.format("DFLayoutEditor: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
