-- DFOverlay fixture - the admin layout overlay.
--
-- WHAT IS AT RISK, and it is one thing above all others: THE OVERLAY MUST NOT
-- BE ABLE TO HIDE AN OPTION.
--
-- This panel is reflection-based precisely so that a new sandbox option appears
-- the moment a mod ships one, with nobody having to remember to list it. An
-- overlay that could drop an option would put a filter in front of the one
-- screen that shows what a server is configured to do, and the failure is
-- silent by construction: the option is still there, still doing whatever it
-- does, and the panel now says otherwise. That is the same defect as a
-- registration API, arriving by the back door.
--
-- apply() is written so there is no branch in which an option goes unwritten -
-- every reflected option is in exactly one of head / placed / after, and all
-- three are emitted. A structural guarantee nobody tests is a comment, so the
-- tests below attack it from the outside: overlays that name one option, that
-- name none of them, that name only things which no longer exist.
--
-- The second risk is the wire. A stored overlay is a client payload the server
-- keeps and hands to every other admin, so sanitize() is a door and is tested
-- as one.

local ROOT = arg[1] or "."
local SRC = ROOT
    .. "/RequiemOfTheDead/Contents/mods/Dragonfly/42/media/lua/shared/DFOverlay.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then passed = passed + 1
    else failed = failed + 1; print("FAIL DFOverlay: " .. message) end
end

DFOverlay = nil
local ok, err = pcall(dofile, SRC)
check(ok, "module loads: " .. tostring(err))

-- ---- a reflected page, in the shape DFSandboxModel emits -----------------

local function opt(name)
    return { name = name, short = name, label = name, type = "boolean" }
end

local function samplePage()
    return {
        page  = "RFTDDirge",
        label = "Dirge",
        count = 5,
        sections = {
            { title = nil,       options = { opt("A") } },
            { title = "Visuals", options = { opt("B"), opt("C") } },
            { title = "Audio",   options = { opt("D"), opt("E") } },
        },
    }
end

-- Every option name in a shaped page, in draw order.
local function namesOf(page)
    local out = {}
    for _, sec in ipairs(page.sections or {}) do
        for _, o in ipairs(sec.options or {}) do out[#out + 1] = o.name end
    end
    return out
end

local function joined(page) return table.concat(namesOf(page), ",") end

local function titlesOf(page)
    local out = {}
    for _, sec in ipairs(page.sections or {}) do
        out[#out + 1] = tostring(sec.title)
    end
    return table.concat(out, "|")
end

-- ---- flatten -------------------------------------------------------------

local page = samplePage()
local flat = DFOverlay.flatten(page)
check(#flat == 7, "flatten emitted " .. #flat .. " entries, expected 5 options + 2 headers")
check(flat[1] == "A", "flatten lost the leading untitled section's option")
check(type(flat[2]) == "table" and flat[2].h == "Visuals", "flatten dropped a section header")
check(flat[7] == "E", "flatten ended somewhere unexpected")
check(#DFOverlay.flatten(nil) == 0, "flatten(nil) did not return an empty layout")
check(#DFOverlay.flatten({}) == 0, "flatten of a page with no sections was not empty")

-- The identity property. An admin who opens the editor and saves without
-- touching anything must get back exactly what they were looking at - otherwise
-- "save" is a leap of faith and nobody will take it twice.
local same, sameStats = DFOverlay.apply(samplePage(), flat)
check(joined(same) == "A,B,C,D,E", "the identity layout reordered the page: " .. joined(same))
check(titlesOf(same) == "nil|Visuals|Audio",
    "the identity layout lost or moved a section: " .. titlesOf(same))
check(sameStats.added == 0 and sameStats.stale == 0,
    "the identity layout reported drift where there is none")
check(sameStats.placed == 5, "the identity layout placed " .. sameStats.placed .. " of 5")

-- ---- THE NEVER-HIDE CONTRACT --------------------------------------------

local function assertAllPresent(shaped, why)
    local got = namesOf(shaped)
    local seen = {}
    for _, n in ipairs(got) do seen[n] = (seen[n] or 0) + 1 end
    local missing, dupes = {}, {}
    for _, n in ipairs({ "A", "B", "C", "D", "E" }) do
        if not seen[n] then missing[#missing + 1] = n
        elseif seen[n] > 1 then dupes[#dupes + 1] = n end
    end
    check(#missing == 0,
        "AN OPTION WAS HIDDEN BY THE OVERLAY (" .. why .. "): " ..
        table.concat(missing, ", ") .. " never rendered. A settings panel that "
        .. "silently omits a live option is worse than one that has none.")
    check(#dupes == 0, "an option rendered twice (" .. why .. "): "
        .. table.concat(dupes, ", "))
    check(#got == 5, "expected 5 options (" .. why .. "), got " .. #got)
    check(shaped.count == 5, "count disagrees with the rows (" .. why .. "): "
        .. tostring(shaped.count))
end

assertAllPresent(select(1, DFOverlay.apply(samplePage(), { "C" })),
                 "an overlay naming ONE option")
assertAllPresent(select(1, DFOverlay.apply(samplePage(), { { h = "Only a header" } })),
                 "an overlay of headers and nothing else")
assertAllPresent(select(1, DFOverlay.apply(samplePage(), { "Gone.One", "Gone.Two" })),
                 "an overlay naming only options that no longer exist")
assertAllPresent(select(1, DFOverlay.apply(samplePage(), { "E", "D", "C", "B", "A" })),
                 "a fully reversed overlay")

-- ---- fall-through position ----------------------------------------------
-- An option the overlay does not mention follows the last option BEFORE it, in
-- reflected order, that the overlay did place. That is what makes a newly
-- shipped option land beside a neighbour instead of at the bottom of the page.

local moved = DFOverlay.apply(samplePage(), { "D", "A" })
check(joined(moved) == "D,E,A,B,C",
    "fall-through did not anchor to the preceding placed option. Expected "
    .. "D,E,A,B,C - E follows D and B,C follow A - got " .. joined(moved))

-- Nothing placed before them: they go to the top of the page, ahead of the
-- first authored header. Anywhere else and an unplaced option would be filed
-- under a heading the admin never chose for it.
local headed = DFOverlay.apply(samplePage(), { { h = "Top" }, "C" })
check(titlesOf(headed) == "nil|Top",
    "the overlay's sections came out as " .. titlesOf(headed))
check(headed.sections[1].options[1].name == "A"
      and headed.sections[1].options[2].name == "B",
    "options with no placed predecessor did not land above the first header")
check(joined(headed) == "A,B,C,D,E", "got " .. joined(headed))

local _, s2 = DFOverlay.apply(samplePage(), { "C" })
check(s2.placed == 1 and s2.added == 4,
    "stats wrong: placed=" .. s2.placed .. " added=" .. s2.added
    .. ". `added` is the only signal an admin gets that the page grew since "
    .. "they arranged it.")

local _, s3 = DFOverlay.apply(samplePage(), { "A", "Gone.One", "Gone.Two", "B" })
check(s3.stale == 2, "stale counted " .. s3.stale .. ", expected 2")
check(s3.placed == 2, "a stale entry disturbed the placed count")

-- Authored headers re-section the page completely, including moving an option
-- out of the section the mod declared it in.
local resect = DFOverlay.apply(samplePage(),
    { { h = "Mine" }, "E", "A", { h = "Rest" }, "B" })
check(titlesOf(resect) == "Mine|Rest", "got sections " .. titlesOf(resect))
check(joined(resect) == "E,A,B,C,D", "got " .. joined(resect))
assertAllPresent(resect, "a re-sectioning overlay")

-- ---- the no-overlay case -------------------------------------------------
-- Not an equivalent rebuild - the SAME table. The common path must not be able
-- to differ from the model by any amount at all.

local p = samplePage()
check(DFOverlay.apply(p, nil) == p, "a nil overlay rebuilt the page instead of returning it")
check(DFOverlay.apply(p, {}) == p, "an empty overlay rebuilt the page")
check(DFOverlay.apply(nil, { "A" }) == nil, "apply(nil) invented a page")

-- apply must not mutate the model's page: the model is rebuilt on show and
-- shared with the nav, which counts options off it.
local orig = samplePage()
DFOverlay.apply(orig, { "E", "A" })
check(joined(orig) == "A,B,C,D,E", "apply mutated the page it was given: " .. joined(orig))
check(#orig.sections == 3, "apply mutated the page's sections")

-- ---- sanitize, which is the server's door -------------------------------

local clean, dropped = DFOverlay.sanitize({ "A", "B", "A", { h = "Head" } })
check(#clean == 3 and dropped == 1, "duplicate option name survived: #" .. #clean)
check(clean[1] == "A" and clean[2] == "B", "sanitize reordered the layout")
check(type(clean[3]) == "table" and clean[3].h == "Head", "a header did not survive")

local _, badDropped = DFOverlay.sanitize({ 123, true, {}, { h = 5 }, { x = "y" } })
check(badDropped == 5, "sanitize accepted a malformed entry: dropped " .. badDropped)
check(#select(1, DFOverlay.sanitize({ 123, true })) == 0, "a malformed entry reached the store")

check(DFOverlay.sanitize("not a table") ~= nil, "sanitize faulted on a non-table")
check(#select(1, DFOverlay.sanitize(nil)) == 0, "sanitize(nil) was not empty")

-- Titles are authored text bound for drawText and a JSON file. A header is one
-- line by definition, so a pasted newline is collapsed rather than escaped -
-- the stored form and the drawn form must not differ.
local nl = DFOverlay.sanitize({ { h = "Two\nLines\tHere" } })
check(nl[1].h == "Two Lines Here", "a control character survived a title: " .. tostring(nl[1].h))
check(#select(1, DFOverlay.sanitize({ { h = "   " } })) == 0, "a blank title was stored")
local long = DFOverlay.sanitize({ { h = string.rep("x", 100) } })
check(#long[1].h == DFOverlay.MAX_TITLE,
    "a title was not clamped: " .. #long[1].h .. " chars")

-- Bounds. This is stored server-side and handed back to every admin, so the
-- ceiling is about a payload that stops being a layout, not about taste.
local big = {}
for i = 1, DFOverlay.MAX_ENTRIES + 5 do big[i] = "Opt" .. i end
local bounded, bigDropped = DFOverlay.sanitize(big)
check(#bounded == DFOverlay.MAX_ENTRIES,
    "an oversized payload was stored whole: " .. #bounded .. " entries")
check(bigDropped == 5, "the overflow was not counted: " .. bigDropped)

check(#select(1, DFOverlay.sanitize({ string.rep("n", DFOverlay.MAX_NAME) })) == 1,
    "a name at the length limit was refused")
check(#select(1, DFOverlay.sanitize({ string.rep("n", DFOverlay.MAX_NAME + 1) })) == 0,
    "an over-long option name was stored")

-- ---- page keys -----------------------------------------------------------
-- A key is a table key on the stored document. An unbounded key is an unbounded
-- document, and this is the only place that is checked.

check(DFOverlay.validKey("RFTDDirge") == true, "a real sandbox page name was refused")
check(DFOverlay.validKey("__server") == true, "the server page's sentinel was refused")
check(DFOverlay.validKey("") == false, "an empty key was accepted")
check(DFOverlay.validKey(nil) == false, "a nil key was accepted")
check(DFOverlay.validKey(42) == false, "a non-string key was accepted")
check(DFOverlay.validKey("has space") == false, "a key with a space was accepted")
check(DFOverlay.validKey("dots.are.out") == false, "a dotted key was accepted")
check(DFOverlay.validKey(string.rep("k", DFOverlay.MAX_KEY)) == true,
    "a key at the length limit was refused")
check(DFOverlay.validKey(string.rep("k", DFOverlay.MAX_KEY + 1)) == false,
    "an over-long key was accepted")

print(string.format("DFOverlay: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
