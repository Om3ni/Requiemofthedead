-- LSTours fixture - tour persistence, and the malformed-record isolation that
-- replaced a blanket pcall over the whole load.
--
-- THE DEFECT THIS PINS: normalizeRegion runs math.min/max over r[1]..r[4], and
-- the old accept test only checked #region == 4. A hand-edited region with a
-- string in it therefore threw MID-LOOP, and the blanket swallowed it - leaving
-- LSTours.list partially populated with _loaded already true, so the rest of the
-- operator's tours silently vanished for the session. One bad tour must now cost
-- only itself.

local ROOT = arg[1] or "."
local BASE = ROOT .. "/RequiemOfTheDead/Contents/mods/Dragonfly/42/media/lua/"

local passed, failed = 0, 0
local realPrint = print
local function check(ok, message)
    if ok then passed = passed + 1
    else failed = failed + 1; realPrint("FAIL LSTours: " .. message) end
end

function isServer() return false end
local gameStart = {}
Events = { OnGameStart = { Add = function(fn) gameStart[#gameStart + 1] = fn end } }

local fileBody, writerMode, written = nil, "ok", {}
function getFileWriter(filename, createIfNull, append)
    if writerMode == "nil" then return nil end
    return {
        write = function(_, s) written[#written + 1] = s end,
        close = function() end,
    }
end
local readerMode = "ok"
function getFileReader(filename, createIfNull)
    if fileBody == nil then return nil end
    local i, lines = 0, {}
    for l in (fileBody .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = l end
    return {
        readLine = function()
            i = i + 1
            -- "truncate" is EARLY EOF, not a throw: BufferedReader is exposed
            -- (LuaManager.java:1651), so an IOException inside readLine is a
            -- Java body throw MethodCaller swallows, and the call returns nil
            -- (MethodCaller.java:33-56). Corrected 2026-08-19 - this used to
            -- call error(), modelling an impossible event.
            if readerMode == "truncate" and i == 2 then return nil end
            return lines[i]
        end,
        close = function() end,
    }
end

local logged = {}
local function capture() print = function(s) logged[#logged + 1] = tostring(s) end end
local function release() print = realPrint end

require = function() return true end
DFFile, LSTours = nil, nil
capture()
-- The REAL RDFile (write mechanism since 2026-08-25) and the REAL
-- RDLuaLiteral (read mechanism since 2026-08-26, when 42.20.4 removed
-- loadstring and the parser was promoted from LMImport).
dofile(ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/shared/RDFile.lua")
dofile(ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/shared/RDLuaLiteral.lua")
local okf = pcall(dofile, BASE .. "shared/DFFile.lua")
local ok, err = pcall(dofile, BASE .. "client/Longstrider/LSTours.lua")
release()
check(okf and ok, "modules load: " .. tostring(err))

local function reload(body)
    fileBody = body
    LSTours._loaded = false
    LSTours.list, LSTours.selectedId = {}, nil
    logged = {}
    capture(); LSTours.load(); release()
end

-- ---- absent / partial ---------------------------------------------------
reload(nil)
check(#LSTours.list == 0, "an absent tour file leaves an empty list")

-- Integrity for this file comes from the CONTENT, not the read layer: the tour
-- file carries a whole Lua literal and RDLuaLiteral.parse rejects a partial
-- one. That is the documented reason LSTours survives an undetectable
-- truncation.
readerMode = "truncate"
reload("return {\n  tours={\n    {id=1, name=\"A\", color={1,1,1}, region={0,0,4,4}},\n  },\n}")
check(#LSTours.list == 0, "a truncated file is rejected outright, not half-parsed")
readerMode = "ok"

-- ---- a good file --------------------------------------------------------
reload([[return {
  cellSize=60,
  dwellMs=1500,
  nextId=9,
  selectedId=2,
  tours={
    {id=1, name="Alpha", color={1,0,0}, region={10,10,4,4}},
    {id=2, name="Bravo", color={0,1,0}, region={0,0,20,20}},
  },
}]])
check(#LSTours.list == 2, "both well-formed tours load")
check(LSTours.cellSize == 60 and LSTours.dwellMs == 1500, "scalar preferences load")
check(LSTours.selectedId == 2, "the selection survives the round trip")
check(LSTours.list[1].region[1] == 4 and LSTours.list[1].region[3] == 10,
      "normalizeRegion orders the corners")

-- ---- THE ISOLATION ------------------------------------------------------
-- A string in the region is what used to throw inside normalizeRegion.
reload([[return {
  tours={
    {id=1, name="Good", color={1,0,0}, region={0,0,4,4}},
    {id=2, name="BadRegion", color={0,1,0}, region={1,"x",3,4}},
    {id=3, name="ShortRegion", color={0,1,0}, region={1,2}},
    {id=4, name="NoColor", region={0,0,4,4}},
    {id=5, name="AlsoGood", color={0,0,1}, region={5,5,9,9}},
  },
}]])
check(#LSTours.list == 2, "three malformed tours are skipped, both good ones survive")
check(LSTours.list[1].name == "Good" and LSTours.list[2].name == "AlsoGood",
      "the survivors are the well-formed pair, in order")
check(#logged == 1 and logged[1]:find("skipped 3 malformed tour(s)", 1, true)
      and logged[1]:find("kept 2", 1, true),
      "one bounded diagnostic names how many were dropped and how many kept")

-- ---- untrusted text -----------------------------------------------------
-- Since 42.20.4 / the RDLuaLiteral promotion, the file is never EXECUTED at
-- all: code in it is not a run failure to contain, it is simply outside the
-- data grammar. Every rejection reaches the operator as a parse report with a
-- line number.
reload("return error('hand edited badly')")
check(#LSTours.list == 0, "code in the file yields no tours - it is not data")
check(#logged == 1 and logged[1]:find("does not parse", 1, true),
      "code is rejected as a parse failure; nothing was executed")

reload("return ][ not lua")   -- has the return sentinel, but not the grammar
check(#logged == 1 and logged[1]:find("does not parse", 1, true),
      "a syntax error is reported as a parse failure")
check(logged[1] and logged[1]:find("line ", 1, true) ~= nil,
      "the parse report carries a line number for the operator")

reload("local x = 1")   -- valid Lua, but not a literal
check(#LSTours.list == 0 and #logged == 1
      and logged[1]:find("does not parse", 1, true),
      "a non-literal file is reported, not silently ignored")

reload("   \n\n  ")   -- blank is a non-event, not corruption
check(#LSTours.list == 0 and #logged == 0, "a blank file stays quiet")

-- ---- save ---------------------------------------------------------------
reload([[return {
  tours={ {id=1, name="Alpha", color={1,0,0}, region={0,0,4,4}} },
}]])
written, writerMode = {}, "ok"
check(LSTours.save() == true, "save reports success")
local out = table.concat(written)
check(out:find("Alpha", 1, true) and out:find("tours=", 1, true), "the serialized set reaches the writer")

-- ---- the round trip -----------------------------------------------------
-- serialize() and RDLuaLiteral.parse are two halves of one format contract;
-- this is the pass that holds them together, %q-escaped name included.
LSTours.rename(1, 'Alpha "quoted" \\ renamed')
LSTours.setCellSize(75)
written = {}
LSTours.save()
local roundTrip = table.concat(written)
reload(roundTrip)
check(#logged == 0, "the round trip parses without complaint")
check(#LSTours.list == 1 and LSTours.list[1].name == 'Alpha "quoted" \\ renamed',
      "an escaped name survives serialize -> parse intact")
check(LSTours.cellSize == 75, "scalar preferences survive the round trip")

writerMode = "nil"
check(LSTours.save() == false, "a denied path is the engine's nil, reported as a failed save")

realPrint(string.format("LSTours: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
