-- test_dfentry.lua - geometry contract for the shared text-entry popout.

local ROOT = arg[1] or "."
local SRC = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/client/DFEntry.lua"

local pass, fail = 0, 0
local function eq(name, got, want)
    if got == want then pass = pass + 1
    else
        fail = fail + 1
        print("FAIL " .. name .. " (got " .. tostring(got) .. ", want " .. tostring(want) .. ")")
    end
end

local function ok(name, cond)
    if cond then pass = pass + 1
    else fail = fail + 1; print("FAIL " .. name) end
end

isServer = function() return false end
require = function() end
UIFont = { Small = "small" }
DFKit = {
    font = { small = "small", label = "small" },
    metrics = { btnH = 24, gap = 6 },
    wrapText = function(text) return { text } end,
}
getTextManager = function()
    return {
        getFontHeight = function() return 20 end,
        MeasureStringX = function(_, _, text) return #text * 10 end,
    }
end
getCore = function()
    return { getScreenWidth = function() return 1280 end, getScreenHeight = function() return 720 end }
end

ISPanel = {}
function ISPanel:derive()
    local derived = {}
    setmetatable(derived, { __index = self })
    return derived
end
function ISPanel:new(x, y, w, h)
    return {
        x = x, y = y, width = w, height = h,
        initialise = function() end,
        instantiate = function() end,
        addToUIManager = function() end,
        -- show() closes whatever was open first, and teardown unfocuses the
        -- box before removing the window. Both have to exist here or the
        -- SECOND show() in this file is the thing under test failing.
        removeFromUIManager = function() end,
    }
end

DFEntryState = nil
dofile(SRC)

local rule = string.rep("w", 50)
local win = DFEntry.show({ title = "Rule", rule = rule })
eq("rule width uses the direct string measurement", win.width, 532)
eq("height uses direct title, line, and entry measurements", win.height, 172)
eq("window is centered after measured geometry", win.x, 374)
eq("window state retains the opened instance", DFEntryState.instance, win)

win.entry = { getInternalText = function() return "edited value" end,
              unfocus = function() end }
eq("text reads the current direct internal value", win:text(), "edited value")

-- ---- SUGGESTIONS ---------------------------------------------------------
--
-- The type-ahead band. Its logic is pulled out of the drawing so it can be
-- tested at all: rowAt is the piece that fails SILENTLY when it is wrong - an
-- off-by-one puts the neighbouring item in the field and the list it came from
-- looked perfectly correct - and the collapse-after-pick state is what stops
-- the band announcing that the value just chosen matches nothing.

-- normalize: providers hand back what their registry gave them.
eq("a bare string row keeps its value",
   DFEntry.normalize({ "Base.Axe" })[1].value, "Base.Axe")
eq("a bare string row labels itself",
   DFEntry.normalize({ "Base.Axe" })[1].label, "Base.Axe")
eq("a table row keeps its label",
   DFEntry.normalize({ { value = "Base.Nails", label = "Nails" } })[1].label, "Nails")
eq("A ROW WITH NO VALUE IS DROPPED - drawing it is offering a click that puts "
   .. "nil in the field",
   #DFEntry.normalize({ { label = "orphan" }, { value = "" }, 7 }), 0)
eq("a non-table answer does not fault", #DFEntry.normalize("nonsense"), 0)
local many = {}
for i = 1, 40 do many[i] = "Base.Item" .. i end
eq("THE BAND NEVER TAKES MORE ROWS THAN IT RESERVED SPACE TO DRAW - the extras "
   .. "would be invisible and unclickable, which is how a list lies",
   #DFEntry.normalize(many), 8)

-- rowText: both halves, and only when they differ.
eq("a row shows the name and the type it fills in",
   DFEntry.rowText({ value = "Base.Nails", label = "Nails" }), "Nails  -  Base.Nails")
eq("a row whose label IS its value does not say it twice",
   DFEntry.rowText({ value = "Base.Nails", label = "Base.Nails" }), "Base.Nails")

-- rowAt: the boundaries, in both directions.
eq("the first pixel of the band is the first row", DFEntry.rowAt(83, 83, 22, 3), 1)
eq("the last pixel of a row is still that row",    DFEntry.rowAt(104, 83, 22, 3), 1)
eq("the next pixel is the next row",               DFEntry.rowAt(105, 83, 22, 3), 2)
eq("above the band is nothing",                    DFEntry.rowAt(82, 83, 22, 3), nil)
eq("PAST THE LAST ROW IS NOTHING, not the last row - the band is taller than "
   .. "the matches it currently holds",             DFEntry.rowAt(149, 83, 22, 3), nil)
eq("an empty list answers no click",               DFEntry.rowAt(90, 83, 22, 0), nil)
eq("above the band is nothing, without a guard of its own",
   DFEntry.rowAt(40, 83, 22, 3), nil)

-- The window that carries one.
local calls, lastQ = 0, nil
local sug = DFEntry.show{
    title = "Item type", value = "",
    suggest = function(q) calls = calls + 1; lastQ = q; return {
        { value = "Base.Nails", label = "Nails" },
        { value = "Base.NailsBox", label = "Box of Nails" },
    } end,
}
eq("a searching window opens wider than a plain one", sug.width, 520)
eq("the band is reserved whole, matches or not", sug.suggestH, 8 * 22 + 6)
eq("the rule and the message sit BELOW the band", sug.bodyY, sug.suggestY + sug.suggestH)
eq("row one starts inside the band, clear of its border", sug.rowsY, sug.suggestY + 3)
-- ONE number behind the drawing, the hover and the click. If the band is ever
-- shorter than the rows it reserves space for, the last match draws outside its
-- own frame and the click that reaches it looks like a miss.
ok("THE LAST ROW FITS INSIDE THE BAND",
   sug.rowsY + 8 * 22 <= sug.suggestY + sug.suggestH)
eq("it opens collapsed on an empty value", #sug.suggestions, 0)

local boxText = ""
sug.entry = { getInternalText = function() return boxText end,
              setText = function(_, t) boxText = t end,
              unfocus = function() end }

boxText = "nail"
sug:refreshSuggestions()
eq("the provider is asked for exactly what is in the box", lastQ, "nail")
eq("the matches are offered", #sug.suggestions, 2)

local before = calls
sug:refreshSuggestions()
eq("AN UNCHANGED BOX DOES NOT RE-QUERY - this runs every frame, and the poll "
   .. "is what keeps a registry scan on the keystroke", calls, before)

sug:pick("Base.Nails")
eq("picking fills the field", boxText, "Base.Nails")
eq("picking collapses the list it came from", #sug.suggestions, 0)
eq("the pick is remembered", sug.picked, "Base.Nails")
sug:refreshSuggestions()
eq("THE COLLAPSE SURVIVES THE NEXT FRAME. lastQuery has to match what pick() "
   .. "put in the box, or the poll re-opens the list over the answer",
   #sug.suggestions, 0)

boxText = "hamme"
sug:refreshSuggestions()
eq("typing again searches again", #sug.suggestions, 2)
eq("...and the window stops calling the old value picked", sug.picked, nil)

-- Opened on an existing value: collapsed, and it knows why.
local seeded = DFEntry.show{ value = "Base.Axe", suggest = function() return { "Base.Axe" } end }
eq("a window opened on a value starts collapsed", #seeded.suggestions, 0)
eq("A SEEDED VALUE COUNTS AS PICKED - otherwise editing an existing grant "
   .. "opens under a list offering the one item already in the box",
   seeded.picked, "Base.Axe")
seeded.entry = { getInternalText = function() return "Base.Axe" end,
                 unfocus = function() end }

-- And a caller that declares nothing is untouched.
local plain = DFEntry.show{ title = "Plain", rule = rule }
eq("no provider means no band", plain.suggestH, 0)
eq("no provider means the old width", plain.width, 532)
eq("NO PROVIDER MEANS THE OLD HEIGHT - every caller written before this option "
   .. "must be pixel-identical", plain.height, 172)

print(string.format("DFEntry: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
