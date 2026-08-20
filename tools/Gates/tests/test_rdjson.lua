-- test_rdjson.lua - behavioural tests for RDJson under real Lua 5.1.
--
-- RDJson is the one Core module that depends on NOTHING from the engine -
-- string.format, math, table, pairs/ipairs and nothing else - so it runs
-- unmodified under stock Lua with no stubs at all. That is why it is the first
-- module to get real tests rather than a syntax check.
--
-- Version matters: PZ B42 runs Kahlua, which is Lua 5.1, and 5.1's all-doubles
-- number model is exactly what fmtNum's correctness rests on. Lua 5.3+ added an
-- integer subtype that changes math.floor and %.0f, so testing there would give
-- confident green results on the wrong semantics. Hence tools/lua5.1.exe.
--
-- Usage (normally via tools\run-tests.bat):
--   lua5.1.exe tools/tests/test_rdjson.lua <repo-root> [jsonl-out-dir]
--
-- When jsonl-out-dir is given, every encoder output is also written there as
-- one .jsonl record per case, so tools/validate_jsonl.py can independently
-- confirm that everything this file produced is real, parseable JSON. Lua
-- asserting on its own output only proves the string matched; the Python pass
-- proves a JSON reader accepts it.

local ROOT   = arg[1] or "."
local OUTDIR = arg[2]

local SRC = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/shared/RDJson.lua"

local okLoad, err = pcall(dofile, SRC)
if not okLoad then
    print("FATAL: could not load " .. SRC)
    print("  " .. tostring(err))
    os.exit(2)
end

-- ---------------------------------------------------------------------------
-- Harness
-- ---------------------------------------------------------------------------

local pass, fail = 0, 0
local emitted = {}

local function record(label, s)
    if type(s) == "string" then emitted[#emitted + 1] = { label = label, json = s } end
end

local function eq(name, got, want)
    record(name, got)
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
    if cond then
        pass = pass + 1
    else
        fail = fail + 1
        print("FAIL " .. name .. ": " .. tostring(detail))
    end
end

local function has(s, needle) return s:find(needle, 1, true) ~= nil end

-- ---------------------------------------------------------------------------
-- Scalars and escaping
-- ---------------------------------------------------------------------------

eq("nil -> null",        RDJson.encode(nil),   "null")
eq("true",               RDJson.encode(true),  "true")
eq("false",              RDJson.encode(false), "false")
eq("plain string",       RDJson.encode("hi"),  '"hi"')

eq("escape quote",       RDJson.encode('a"b'),  '"a\\"b"')
eq("escape backslash",   RDJson.encode("a\\b"), '"a\\\\b"')
eq("escape newline",     RDJson.encode("a\nb"), '"a\\nb"')
eq("escape tab",         RDJson.encode("a\tb"), '"a\\tb"')
eq("escape return",      RDJson.encode("a\rb"), '"a\\rb"')
-- The third inherited defect the header documents: a bare control byte used to
-- produce an invalid line.
eq("escape control 0x01", RDJson.encode("a\1b"), '"a\\u0001b"')

-- ---------------------------------------------------------------------------
-- fmtNum, including the documented six-decimal floor
-- ---------------------------------------------------------------------------

eq("integer",            RDJson.encode(42),   "42")
eq("negative integer",   RDJson.encode(-7),   "-7")
eq("simple fraction",    RDJson.encode(0.5),  "0.5")
eq("trailing zeros trimmed", RDJson.encode(0.1), "0.1")
eq("NaN -> null",        RDJson.encode(0 / 0),  "null")
eq("+inf -> null",       RDJson.encode(1 / 0),  "null")
eq("-inf -> null",       RDJson.encode(-1 / 0), "null")

-- No scientific notation at the top of the exact-integer range - the original
-- motivation for having fmtNum at all.
eq("2^53 renders plain", RDJson.encode(2 ^ 53), "9007199254740992")
isTrue("no scientific notation for big values",
    not has(RDJson.encode(1.78e9), "e") and not has(RDJson.encode(1.78e9), "E"),
    RDJson.encode(1.78e9))

-- The floor is a KNOWN LIMITATION, pinned here so a future precision change is
-- a deliberate edit to this test rather than a silent behaviour drift.
eq("below floor collapses to 0", RDJson.encode(1e-7),  "0")
eq("just above floor survives",  RDJson.encode(9e-7),  "0.000001")

-- ---------------------------------------------------------------------------
-- Table shapes
-- ---------------------------------------------------------------------------

eq("empty table is a map",   RDJson.encode({}),               "{}")
eq("EMPTY_ARR sentinel",     RDJson.encode(RDJson.EMPTY_ARR), "[]")
eq("dense array",            RDJson.encode({ 1, 2, 3 }),      "[1,2,3]")
eq("keys are sorted",        RDJson.encode({ b = 1, a = 2 }), '{"a":2,"b":1}')
eq("nesting",                RDJson.encode({ a = { b = { c = 1 } } }), '{"a":{"b":{"c":1}}}')

-- Diffability: identical state must encode identically regardless of insertion
-- order, which is what makes chronicle records comparable across sessions.
eq("deterministic across insertion order",
    RDJson.encode({ b = 1, a = 2, c = 3 }),
    RDJson.encode({ c = 3, a = 2, b = 1 }))

-- ---------------------------------------------------------------------------
-- Encoder bounds
-- ---------------------------------------------------------------------------

-- Depth: unbounded recursion here used to be reachable from a satellite
-- dispatcher handing a raw client args table to RDLog.forensic.
local deep, cur = {}, nil
cur = deep
for _ = 1, 40 do cur.n = {}; cur = cur.n end
local okDeep, outDeep = pcall(RDJson.encode, deep)
isTrue("deep table encodes without error", okDeep, outDeep)
isTrue("deep table hits the depth cap", okDeep and has(outDeep, "<max-depth>"),
    okDeep and outDeep:sub(1, 90) or outDeep)
record("deep", okDeep and outDeep or nil)

-- Cycles.
local cyc = { name = "x" }
cyc.self = cyc
local okCyc, outCyc = pcall(RDJson.encode, cyc)
isTrue("cyclic table encodes without error", okCyc, outCyc)
isTrue("cyclic table is marked", okCyc and has(outCyc, "<cycle>"), outCyc)
record("cycle", okCyc and outCyc or nil)

-- REGRESSION: `seen` is path-scoped, so a table reachable by two sibling paths
-- is a DAG and must encode fully both times. A walk-global `seen` would call
-- the second one a cycle and silently drop real data.
local shared = { v = 1 }
eq("DAG encodes both branches", RDJson.encode({ x = shared, y = shared }),
    '{"x":{"v":1},"y":{"v":1}}')
-- The shared EMPTY_ARR sentinel is the case that hits this constantly.
eq("shared sentinel used twice", RDJson.encode({ a = RDJson.EMPTY_ARR, b = RDJson.EMPTY_ARR }),
    '{"a":[],"b":[]}')

-- Node budget: depth alone bounds a deeply nested payload but not one very wide
-- table, which is the cheaper of the two to send.
-- Sized defensively rather than straight off RDJson.MAX_NODES: this suite must
-- still RUN (and fail with readable FAIL lines) against a version of the module
-- that predates the constant, which is exactly the case you hit when checking
-- that a regression test actually catches its regression.
local wide = {}
for i = 1, (RDJson.MAX_NODES or 20000) + 10000 do wide["k" .. i] = i end
local okWide, outWide = pcall(RDJson.encode, wide)
isTrue("very wide table encodes without error", okWide, outWide)
isTrue("very wide table is truncated", okWide and has(outWide, "<truncated>"), "no truncation marker")

-- The other half of that bound, and the more important half: a legitimately
-- large record must pass through UNTOUCHED. The widest real producer is a
-- Memoir snapshot - perks, traits, and several hundred known recipes.
local memoir = { perks = {}, recipes = {}, profession = "Chef" }
for i = 1, 40 do memoir.perks["Perk" .. i] = i end
for i = 1, 600 do memoir.recipes[i] = "Recipe" .. i end
local outMemoir = RDJson.encode(memoir)
isTrue("memoir-scale record is not truncated", not has(outMemoir, "<truncated>"), "unexpected truncation")
isTrue("memoir-scale record is not depth-capped", not has(outMemoir, "<max-depth>"), "unexpected depth cap")
isTrue("memoir-scale record has no cycle marker", not has(outMemoir, "<cycle>"), "unexpected cycle")
record("memoir", outMemoir)

-- ---------------------------------------------------------------------------
-- Hand every produced string to the Python validator as independent proof
-- ---------------------------------------------------------------------------

if OUTDIR then
    local path = OUTDIR .. "/rdjson_cases.jsonl"
    local fh, ferr = io.open(path, "w")
    if not fh then
        print("WARN could not write " .. path .. ": " .. tostring(ferr))
    else
        for _, c in ipairs(emitted) do
            -- Each case is wrapped so the line is always a JSON *object*,
            -- matching the envelope shape the real streams use.
            fh:write('{"case":' .. RDJson.encode(c.label) .. ',"out":' .. c.json .. "}\n")
        end
        fh:close()
    end
end

print(string.format("RDJson: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
