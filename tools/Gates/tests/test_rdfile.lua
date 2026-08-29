-- RDFile fixture - the one open/write/close, and its refusal accounting.
--
-- WHY. Thirteen files hand-rolled this mechanism before 2026-08-25, and the
-- 42.20 allowlist change silently destroyed two archives for a day because
-- every copy guarded `if w then` and said nothing. The properties pinned here
-- are the ones a regression would re-lose silently: the refusal is COUNTED
-- and printed once per path, a batch is ONE open, and a rewrite truncates.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/shared/RDFile.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL RDFile: " .. message)
    end
end

-- In-memory FS modelling the verified engine surface: nil for a refused
-- extension (LuaManager.java:1045/:5526), append vs truncate, reads as lists.
local files, opens = {}, 0
local ALLOWED = { ini = true, cfg = true, txt = true, log = true, json = true }
local function extOf(path)
    local base = path:match("([^/\\]+)$") or path
    return base:match("%.([^%.]+)$")
end
function getFileWriter(path, createIfNull, append)
    local ext = extOf(path)
    if not (ext and ALLOWED[ext]) then return nil end
    opens = opens + 1
    if not append then files[path] = "" else files[path] = files[path] or "" end
    return {
        write = function(_, s) files[path] = files[path] .. s end,
        close = function() end,
    }
end
function getFileReader(path)
    local content = files[path]
    if not content then return nil end
    local rest = content
    return {
        readLine = function()
            if rest == "" or rest == nil then return nil end
            local line, tail = rest:match("^([^\n]*)\n(.*)$")
            if not line then line, rest = rest, "" else rest = tail end
            return line
        end,
        close = function() end,
    }
end

local printed = {}
local realPrint = print
print = function(s) printed[#printed + 1] = tostring(s) end

RDFile = nil
local ok, err = pcall(dofile, SOURCE)
print = realPrint
check(ok, "module loads: " .. tostring(err))

-- ---- writes ---------------------------------------------------------------
check(RDFile.appendLine("a.txt", "one") == true, "appendLine reports the open")
RDFile.appendLine("a.txt", "two")
check(files["a.txt"] == "one\ntwo\n", "appendLine appends with a newline: "
    .. tostring(files["a.txt"]))

opens = 0
check(RDFile.appendMany("b.log", { "r1", "r2", "r3" }) == true, "appendMany opens")
check(opens == 1, "a batch is ONE open, not one per line: " .. opens)
check(files["b.log"] == "r1\nr2\nr3\n", "appendMany wrote every row")

RDFile.rewrite("a.txt", "fresh")
check(files["a.txt"] == "fresh", "rewrite truncates - it is the only delete Lua has")

RDFile.rewriteLines("c.json.txt", { "l1", "l2" })
check(files["c.json.txt"] == "l1\nl2\n", "rewriteLines truncates and lines out")

-- ---- the refusal ----------------------------------------------------------
printed = {}
print = function(s) printed[#printed + 1] = tostring(s) end
check(RDFile.appendLine("bad.jsonl", "x") == false,
    "a refused extension reports false - .jsonl is outside the allowlist")
check(RDFile.stats.refused == 1, "the refusal was counted")
RDFile.appendLine("bad.jsonl", "y")
RDFile.rewrite("bad.jsonl", "z")
check(RDFile.stats.refused == 3, "every refusal counts: " .. RDFile.stats.refused)
print = realPrint
local shouts = 0
for _, line in ipairs(printed) do
    if line:find("REFUSED", 1, true) then shouts = shouts + 1 end
end
check(shouts == 1,
    "a refused path prints ONCE, not per attempt - a flood is as unreadable "
    .. "as silence: " .. shouts)

-- ---- reads ----------------------------------------------------------------
check(RDFile.readFirstLine("b.log") == "r1", "readFirstLine reads the head")
check(RDFile.readFirstLine("absent.txt") == nil, "an absent file reads nil")
local lines = RDFile.readLines("b.log")
check(lines and #lines == 3 and lines[3] == "r3", "readLines reads every row")
check(RDFile.readLines("absent.txt") == nil,
    "an unopenable file is NIL - distinct from empty")
files["empty.txt"] = ""
local empty = RDFile.readLines("empty.txt")
check(type(empty) == "table" and #empty == 0,
    "an empty file is an EMPTY TABLE - the caller gets to see the difference")

print(string.format("RDFile: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
