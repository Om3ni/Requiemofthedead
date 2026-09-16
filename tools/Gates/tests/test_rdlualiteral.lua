-- test_rdlualiteral.lua - grammar-edge tests for the restricted Lua-literal
-- parser, under real Lua 5.1.
--
-- These cases came over from test_lmimport.lua with the parser's promotion to
-- Core (2026-08-26): they pin the grammar edges (escapes, bracket keys,
-- comments, depth cap, error line numbers) that the well-behaved production
-- fixtures never reach. test_lmimport keeps the mapping and the live fixture;
-- test_lstours keeps the consumer-side load contract. What is new here is the
-- %q round trip: LSTours serializes with string.format("%q"), so the escape
-- forms %q actually emits - including a backslash-newline for a literal
-- newline - are a shared contract now, proven by parsing them back.
--
-- Usage (normally via tools\run-tests.bat):
--   lua5.1.exe tools/tests/test_rdlualiteral.lua <repo-root>

local ROOT = arg[1] or "."
local SRC  = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/shared/RDLuaLiteral.lua"

local okLoad, err = pcall(dofile, SRC)
if not okLoad then
    print("FATAL: could not load " .. SRC)
    print("  " .. tostring(err))
    os.exit(2)
end

local pass, fail = 0, 0
local function eq(name, got, want)
    if got == want then pass = pass + 1
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

-- ---------------------------------------------------------------------------
-- Grammar edges
-- ---------------------------------------------------------------------------

local t = RDLuaLiteral.parse('return { a = 1, b = "two", c = true, d = { 1, 2; 3 }, }')
eq("number value",        t.a, 1)
eq("string value",        t.b, "two")
eq("boolean value",       t.c, true)
eq("positional entries",  t.d[3], 3)

t = RDLuaLiteral.parse('{ ["with space"] = -4.5, [7] = "seven" }')
eq("bracket string key",  t["with space"], -4.5)
eq("bracket number key",  t[7], "seven")

t = RDLuaLiteral.parse('-- leading comment\nreturn { -- inline\n  x = "a\\"b\\nc" -- trailing\n}')
eq("escapes in strings",  t.x, 'a"b\nc')

t = RDLuaLiteral.parse("{ s = 'single quotes' }")
eq("single-quoted string", t.s, "single quotes")

local bad, perr = RDLuaLiteral.parse('return { a = 1,\n  b = @ }')
eq("garbage rejected", bad, nil)
isTrue("error carries a line number", tostring(perr):find("line 2"), perr)

bad, perr = RDLuaLiteral.parse('{ a = "unterminated }')
eq("unterminated string rejected", bad, nil)

bad, perr = RDLuaLiteral.parse('{ a = 1 } trailing')
eq("trailing content rejected", bad, nil)

bad, perr = RDLuaLiteral.parse('return 42')
eq("non-table top level rejected", bad, nil)

bad, perr = RDLuaLiteral.parse(nil)
eq("non-string input rejected", bad, nil)

local deep = string.rep("{ x = ", 40) .. "1" .. string.rep(" }", 40)
bad, perr = RDLuaLiteral.parse(deep)
eq("depth cap holds", bad, nil)
isTrue("depth cap names itself", tostring(perr):find("nesting"), perr)

-- ---------------------------------------------------------------------------
-- The quote() round trip - the escape contract LSTours.serialize leans on.
--
-- quote() replaced %q here on 2026-08-30, and the reason is the test itself:
-- the game VM's %q does not escape backslashes (StringLib.java:406-409), so
-- the old %q round trip FAILED there - a mid-string backslash was swallowed,
-- and a trailing one produced a literal parse() refuses whole. quote() is the
-- module's own write half; this pins that its output reads back byte-
-- identical on BOTH VMs. Do not reintroduce %q into anything parse() reads.
-- ---------------------------------------------------------------------------

local nasty = 'The "Deep" \\ End\nSecond line'
local literal = "return { name = " .. RDLuaLiteral.quote(nasty) .. ", n = 7 }"
t = RDLuaLiteral.parse(literal)
isTrue("quote() round trip parses", t ~= nil, literal)
eq("quote() quotes and backslash survive", t and t.name, nasty)
eq("quote() neighbour field intact", t and t.n, 7)

-- The two shapes that LOST WHOLE FILES under %q on the game VM: a trailing
-- backslash, and backslash-then-quote. Each must round-trip, not merely parse.
for i, edge in ipairs({ 'ends in backslash \\', 'pair \\" inside', '\\',
                        '', 'tabs\tand\rreturns' }) do
    local et = RDLuaLiteral.parse("return { v = " .. RDLuaLiteral.quote(edge) .. " }")
    isTrue("quote() edge case " .. i .. " parses", et ~= nil, edge)
    eq("quote() edge case " .. i .. " survives", et and et.v, edge)
end

-- parseString's fall-through ("any other escaped character stands for
-- itself") is what lets a file written by REAL 5.1's %q - which emits a
-- backslash followed by a REAL newline for a newline - read back correctly.
-- quote() never emits that form, but hand tooling on a real 5.1 install
-- might; the literal is built by hand so this pin holds on both VMs.
t = RDLuaLiteral.parse('return { s = "a\\' .. '\n' .. 'b" }')
eq("backslash-newline fall-through reads as a newline", t and t.s, "a\nb")

-- The exact record shape LSTours.serialize emits: verbatim format string,
-- name quoted the way serialize now quotes it.
local tour = string.format(
    "    {id=%d, name=%s, color={%g,%g,%g}, region={%d,%d,%d,%d}},\n",
    3, RDLuaLiteral.quote('Quote " in name'), 0.95, 0.55, 0.10, 100, 200, 300, 400)
t = RDLuaLiteral.parse("return {\n  tours={\n" .. tour .. "  },\n}")
isTrue("tour record shape parses", t ~= nil and t.tours ~= nil, tour)
eq("tour name with quote",  t.tours[1].name, 'Quote " in name')
eq("tour color float",      t.tours[1].color[1], 0.95)
eq("tour region corner",    t.tours[1].region[4], 400)

print(string.format("RDLuaLiteral: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
