-- test_rdwire.lua - behavioural tests for RDWire under real Lua 5.1.
--
-- RDWire is deliberately engine-free (type, pairs, pcall and nothing else), so
-- it runs here with no stubs. The wire-format constants it encodes are the whole
-- point of the module - if someone "tidies" string to #s+1 or number to 4, every
-- traffic report silently shifts and no in-game symptom appears. These pin them.
--
-- Usage (normally via tools\run-tests.bat):
--   lua5.1.exe tools/tests/test_rdwire.lua <repo-root>

local ROOT = arg[1] or "."
local SRC  = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/shared/RDWire.lua"

local okLoad, err = pcall(dofile, SRC)
if not okLoad then
    print("FATAL: could not load " .. SRC)
    print("  " .. tostring(err))
    os.exit(2)
end

local pass, fail = 0, 0

local function eq(name, got, want)
    if got == want then
        pass = pass + 1
    else
        fail = fail + 1
        print("FAIL " .. name)
        print("  got:  " .. tostring(got))
        print("  want: " .. tostring(want))
    end
end

local function isTrue(name, cond, detail)
    if cond then pass = pass + 1
    else fail = fail + 1; print("FAIL " .. name .. ": " .. tostring(detail)) end
end

local est = function(t) local n = RDWire.estimate(t); return n end
local part = function(t) local _, p = RDWire.estimate(t); return p end

-- ---------------------------------------------------------------------------
-- Non-tables and the wire-format constants
-- ---------------------------------------------------------------------------

eq("nil is not a payload",     est(nil),   0)
eq("number is not a payload",  est(42),    0)
eq("string is not a payload",  est("abc"), 0)

-- Empty table = the table marker alone.
eq("empty table = 1 marker", est({}), 1)

-- string = #s + 2 (length-prefixed UTF). {a=true} => 1 marker + 3 key + 1 value
eq("string key costs #s+2", est({ a = true }), 5)
eq("longer string key",     est({ ab = true }), 6)

-- number = 8 (Double; Kahlua has no integer subtype, so every number is 8)
-- {1} => 1 marker + 8 (numeric key) + 8 (numeric value)
eq("number costs 8", est({ 1 }), 17)

-- boolean = 1
eq("boolean costs 1", est({ [0] = true }), 10)   -- 1 + 8 (key) + 1

-- Array of one 2-char string: 1 marker + 8 (index) + 4 (string)
eq("array of one string", est({ "ab" }), 13)

-- functions/userdata are stripped before send, so they cost nothing but the key
eq("function value costs 0", est({ a = function() end }), 4)   -- 1 + 3 + 0

-- ---------------------------------------------------------------------------
-- Nesting
-- ---------------------------------------------------------------------------

-- {x={y=1}} => 1 + 3 ("x") + (1 + 3 ("y") + 8 (1)) = 16
eq("nested table", est({ x = { y = 1 } }), 16)

-- Depth cap: a table AT the cap collapses to a single marker byte rather than
-- being walked, matching the wire serializer's own nesting limit.
local deep, cur = {}, nil
cur = deep
for _ = 1, 20 do cur.n = {}; cur = cur.n end
local okDeep, outDeep = pcall(RDWire.estimate, deep)
isTrue("deep chain estimates without error", okDeep, outDeep)
isTrue("deep chain is bounded, not walked forever", okDeep and outDeep < 200, outDeep)
eq("DEPTH_CAP is the documented 8", RDWire.DEPTH_CAP, 8)

-- ---------------------------------------------------------------------------
-- Cycles vs DAGs - the distinction that matters for a BYTE count
-- ---------------------------------------------------------------------------

local cyc = { a = true }
cyc.self = cyc
local okCyc, outCyc = pcall(RDWire.estimate, cyc)
isTrue("cyclic table estimates without error", okCyc, outCyc)
isTrue("cyclic table terminates small", okCyc and outCyc < 100, outCyc)

-- A table reachable by two SIBLING paths is a DAG, not a cycle, and the wire
-- really does carry it twice - so it must be counted twice. `seen` is
-- path-scoped for exactly this reason (same as RDJson). A walk-global `seen`
-- would undercount every payload that reuses a subtable, which is most of them.
local shared = { a = 1 }                       -- 1 + 3 + 8 = 12
eq("shared subtable counted once alone", est({ x = shared }), 16)          -- 1 + 3 + 12
eq("shared subtable counted TWICE as siblings",
    est({ x = shared, y = shared }), 31)                                   -- 1 + 3 + 12 + 3 + 12

-- ---------------------------------------------------------------------------
-- Node budget: report partial rather than stall a send
-- ---------------------------------------------------------------------------

eq("NODE_BUDGET is the documented 20000", RDWire.NODE_BUDGET, 20000)

local small = {}
for i = 1, 500 do small["k" .. i] = i end
isTrue("a normal payload is never marked partial", part(small) == false, "unexpected partial")

local huge = {}
for i = 1, 15000 do huge["k" .. i] = i end
local okHuge, outHuge = pcall(RDWire.estimate, huge)
isTrue("oversized payload estimates without error", okHuge, outHuge)
isTrue("oversized payload is marked partial", part(huge) == true, "budget did not trip")
-- partial means "at least this big" - it must still report a real floor, since
-- under-reporting is what would hide the 74MB-blob case the probe exists for.
isTrue("partial estimate is still a useful floor", est(huge) > 10000, est(huge))

-- ---------------------------------------------------------------------------
-- parseSend: the optional-leading-player overload
-- ---------------------------------------------------------------------------

local m, c, a = RDWire.parseSend("Mod", "Cmd", { z = 1 })
eq("3-arg form: module", m, "Mod")
eq("3-arg form: command", c, "Cmd")
eq("3-arg form: args", type(a), "table")

local fakePlayer = {}   -- any non-string in slot 1 means the 4-arg form
local m2, c2, a2 = RDWire.parseSend(fakePlayer, "Mod", "Cmd", { z = 1 })
eq("4-arg form: module", m2, "Mod")
eq("4-arg form: command", c2, "Cmd")
eq("4-arg form: args", type(a2), "table")

-- ---------------------------------------------------------------------------
-- commandEstimate = payload + both name strings + framing
-- ---------------------------------------------------------------------------

eq("commandEstimate with no args", (RDWire.commandEstimate("M", "C", nil)), 5)      -- 0 + 1 + 1 + 3
eq("commandEstimate adds payload", (RDWire.commandEstimate("M", "C", { a = true })), 10)  -- 5 + 5

print(string.format("RDWire: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
