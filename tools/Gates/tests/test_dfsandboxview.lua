-- DFSandboxView fixture - schema translation and the apply transaction.
--
-- WHAT IS ACTUALLY AT RISK. This surface writes to a LIVE server's sandbox
-- configuration, and the packet carries the whole option set, so a mistake here
-- does not corrupt one dial - it rewrites every option on the server. Two
-- specific ways that happens, and both are pinned below:
--
--   1. Apply builds its copy from a SNAPSHOT rather than from the live options,
--      and silently reverts everything another admin changed in between. This
--      is not hypothetical: it is what vanilla's own editor does
--      (ISServerSandboxOptionsUI.lua:790 snapshots at open, :763 pushes at
--      apply), and avoiding it is the reason this view stages deltas.
--   2. A type maps to the wrong dial and writes the wrong shape into an option.
--      A `double` through an integer stepper cannot express 0.6 at all.
--
-- Neither is visible in a screenshot, and both are only observable on a live
-- server after the damage.
--
-- The engine surfaces are INJECTED into applyTo rather than stubbed globally,
-- because what the function does with them IS the behaviour under test.

local ROOT = arg[1] or "."
local SOURCE = ROOT
    .. "/RequiemOfTheDead/Contents/mods/Dragonfly/42/media/lua/client/Admin/DFSandboxView.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then passed = passed + 1
    else failed = failed + 1; print("FAIL DFSandboxView: " .. message) end
end

-- ---- stubs ---------------------------------------------------------------

function isServer() return false end
require = function() return true end

DFKit = {
    font    = { small = "small" },
    metrics = { pad = 8, gap = 6, btnH = 24, rowH = 22, headerH = 20 },
    col     = { text = {}, textDim = {}, line = {}, accent = {}, accentDim = {} },
    rowHeight = function() return 22 end,
    wrapText  = function() return {} end,
    fitText   = function(s) return s end,
    refillList = function(box, fill)
        box:clear()
        if fill then fill(box) end
        return box
    end,
}
-- filterSchema and countRows are RECORDED rather than reimplemented: what
-- they do with a query is test_dfform's business now that both option views
-- share them. This file has to prove the view routes through them with the
-- typed query - a rebuild that filtered on "" leaves a box that types and does
-- nothing - and that the nav's per-mod counts come from the same rule as the
-- page, because two rules would let the nav promise a match the page cannot
-- show.
local filterQueries = {}
DFForm = {
    new = function(o) return o end,
    filterSchema = function(schema, query)
        filterQueries[#filterQueries + 1] = query
        if query == "" then return schema end
        local out = {}
        for _, e in ipairs(schema or {}) do
            if e.key and tostring(e.key):lower():find(tostring(query):lower(), 1, true) then
                out[#out + 1] = e
            end
        end
        return out
    end,
    countRows = function(schema)
        local n = 0
        for _, e in ipairs(schema or {}) do if e.key then n = n + 1 end end
        return n
    end,
}

-- DFLayout is the server-wide arrangement document and is not this file's
-- subject. Shape is identity: the arranger reorders and groups but can never
-- add or hide an option, which is exactly why the nav may count matches off
-- the raw page instead.
DFLayout = {
    shape     = function(page) return page, {} end,
    request   = function() end,
    onChanged = function() end,
    noteFor   = function() return nil end,
    held      = function() return false end,
    forget    = function() end,
}
DFSandboxModel = { build = function() return {} end }
ISScrollingListBox = { derive = function() return {} end }
function getSandboxOptions() return nil end

-- Real, not stubbed: pure Lua, and the model reads its SERVER_KEY.
dofile(ROOT .. "/RequiemOfTheDead/Contents/mods/Dragonfly/42/media/lua/shared/DFOverlay.lua")

local DIR = ROOT .. "/RequiemOfTheDead/Contents/mods/Dragonfly/42/media/lua/client/Admin"
DFStaged = nil
local okS, errS = pcall(dofile, DIR .. "/DFStaged.lua")
check(okS, "DFStaged loads: " .. tostring(errS))

DFSandboxView = nil
local ok, err = pcall(dofile, SOURCE)
check(ok, "module loads: " .. tostring(err))

-- ---- schema translation --------------------------------------------------

local function opt(name, otype, extra)
    local short = name:match("%.(.+)$") or name
    local o = { name = name, short = short, label = short, type = otype,
                tooltip = short .. " does a thing" }
    for k, v in pairs(extra or {}) do o[k] = v end
    return o
end

local mod = { page = "RFTDDirge", sections = {
    { title = nil,       options = { opt("RFTDDirge.Debug", "boolean") } },
    { title = "Visuals", options = {
        opt("RFTDDirge.Mode",  "enum", { values = { "Off", "Some", "All" } }),
        opt("RFTDDirge.Count", "integer"),
        opt("RFTDDirge.Rate",  "double"),
        opt("RFTDDirge.Name",  "string"),
        opt("RFTDDirge.Blurb", "text"),
    } },
} }

local schema, skipped = DFSandboxView.schemaFor(mod)
check(skipped == 0, "a supported type was skipped")

local by = {}
for _, e in ipairs(schema) do if e.key then by[e.key] = e end end

check(schema[1].group == nil, "an untitled section emitted a group header")
local groups = 0
for _, e in ipairs(schema) do if e.group then groups = groups + 1 end end
check(groups == 1, "expected exactly 1 group header, got " .. groups)

check(by["RFTDDirge.Debug"].kind == "bool", "boolean did not map to a bool dial")
check(by["RFTDDirge.Name"].kind == "text", "string did not map to a text dial")
check(by["RFTDDirge.Blurb"].kind == "text", "text did not map to a text dial")
check(by["RFTDDirge.Count"].kind == "int", "integer did not map to an int dial")

-- enum: both sides store a 1-based INDEX, so nothing is translated. Mapping it
-- to `choice` (which stores the STRING) would write "Some" into an option that
-- expects 2.
local en = by["RFTDDirge.Mode"]
check(en.kind == "enum", "enum did not map to an enum dial")
check(en.numValues == 3, "enum lost its value count")
check(en.values[2] == "Some", "enum lost its value labels")

-- double is the one that must NOT be an int: DFForm's int is a whole-number
-- stepper, and a sandbox double is routinely 0.6.
local dbl = by["RFTDDirge.Rate"]
check(dbl.kind == "text",
    "double mapped to '" .. tostring(dbl.kind) .. "' - an integer stepper "
    .. "cannot express 0.6, so every fractional option becomes unreachable")
check(type(dbl.validate) == "function", "double got no validator")
check(select(1, dbl.validate("0.6")) == true, "the validator refused a decimal")
check(select(1, dbl.validate("abc")) == false, "the validator accepted 'abc'")

check(by["RFTDDirge.Debug"].help ~= nil, "the engine tooltip was not carried into help")

-- An unknown type is skipped, not guessed. Writing the wrong shape into a live
-- server option is worse than the dial being absent.
local weird = { sections = { { options = {
    opt("X.Ok", "boolean"), opt("X.Odd", "colour") } } } }
local ws, wskip = DFSandboxView.schemaFor(weird)
check(wskip == 1, "an unknown option type was not counted as skipped")
local kinds = 0
for _, e in ipairs(ws) do if e.kind then kinds = kinds + 1 end end
check(kinds == 1, "an unknown option type produced a dial anyway")

check(#DFSandboxView.schemaFor(nil) == 0, "a nil mod produced a schema")

-- The view builds its store in attach(); fixtures never call attach, so it
-- is built here the same way.
DFSandboxView.staged = DFStaged.new(DFSandboxView.liveValue)

-- ---- the apply transaction ----------------------------------------------
-- A fake SandboxOptions pair: `live` is what the server has right now, `copy`
-- is what applyTo builds and pushes.

local function mkOptions(values)
    local self = { values = {}, types = {}, sent = false, copiedFrom = nil }
    for k, v in pairs(values or {}) do self.values[k] = v end
    self.types = { ["a.Bool"] = "boolean", ["a.Int"] = "integer",
                   ["a.Dbl"] = "double",  ["a.Str"] = "string",
                   ["a.Enum"] = "enum" }
    function self:getOptionByName(n)
        if self.types[n] == nil then return nil end
        local o = {}
        function o:getType() return self.owner.types[n] end
        function o:setValue(v) self.owner.values[n] = v end
        function o:parse(s) self.owner.values[n] = "parsed:" .. tostring(s) end
        o.owner = self
        return o
    end
    function self:copyValuesFrom(other)
        self.copiedFrom = other
        for k, v in pairs(other.values) do self.values[k] = v end
    end
    function self:sendToServer() self.sent = true end
    function self:set(n, v) self.values[n] = v end
    return self
end

local live = mkOptions{ ["a.Bool"] = false, ["a.Int"] = 1, ["a.Str"] = "old" }
local built
local function mk() built = mkOptions{}; return built end

local okA, n = DFSandboxView.applyTo(live, mk, { ["a.Bool"] = true }, function() return true end)
check(okA == true and n == 1, "apply reported " .. tostring(okA) .. "/" .. tostring(n))
check(built.sent == true, "the copy was never sent to the server")
check(built.copiedFrom == live,
    "THE COPY WAS NOT BUILT FROM THE LIVE OPTIONS - this is the vanilla "
    .. "lost-update bug: a snapshot taken earlier reverts every change another "
    .. "admin made in between, across the whole option set")
check(built.values["a.Bool"] == true, "the staged change did not reach the copy")
check(built.values["a.Str"] == "old",
    "an untouched option did not carry the live value through")
check(live.sent ~= true, "the LIVE options object was sent instead of the copy")

-- Numbers go through parse(), which is what vanilla does for both numeric
-- types - the option owns its own string-to-number rules.
local live2 = mkOptions{}
DFSandboxView.applyTo(live2, mk, { ["a.Int"] = 7, ["a.Dbl"] = 0.6 },
                      function() return true end)
check(built.values["a.Int"] == "parsed:7", "integer did not go through parse()")
check(built.values["a.Dbl"] == "parsed:0.6", "double did not go through parse()")

-- Strings and booleans go through setValue, not parse.
local live3 = mkOptions{}
DFSandboxView.applyTo(live3, mk, { ["a.Str"] = "new" }, function() return true end)
check(built.values["a.Str"] == "new", "a string was parsed instead of set")

-- An option the copy does not know is skipped rather than faulting the whole
-- apply - a mod unloaded since the panel opened must not cost the other edits.
local live4 = mkOptions{}
local ok4 = DFSandboxView.applyTo(live4, mk,
    { ["a.Bool"] = true, ["ghost.Gone"] = 1 }, function() return true end)
check(ok4 == true, "an unknown option name aborted the whole apply")
check(built.values["a.Bool"] == true, "the good edit was lost alongside the unknown one")

-- Nothing staged must not push. sendToServer serialises the ENTIRE set, so an
-- empty apply is a full-set write for no reason.
local live5 = mkOptions{}
local ok5, why5 = DFSandboxView.applyTo(live5, mk, {}, function() return true end)
check(ok5 == false, "an empty apply pushed the whole option set anyway")
check(tostring(why5):find("nothing", 1, true) ~= nil, "the empty apply gave no reason")

-- Singleplayer / listen host: no packet, write straight through. Same branch
-- vanilla takes at ISServerSandboxOptionsUI.lua:737-739.
local live6 = mkOptions{ ["a.Bool"] = false }
local ok6 = DFSandboxView.applyTo(live6, mk, { ["a.Bool"] = true },
                                  function() return false end)
check(ok6 == true, "the non-client branch failed")
check(built.sent == false, "a packet was sent with no client")
check(live6.values["a.Bool"] == true,
    "the non-client branch did not write through to the live options")

-- ---- the search ----------------------------------------------------------
--
-- Nine mod pages of roughly forty options each. Without a filter the surface is
-- something an admin scrolls past rather than reads, and the failure this
-- guards is not cosmetic: a search that quietly drops a match is an admin
-- concluding a sandbox option does not exist.

local function page(name, ...)
    local opts = {}
    for _, key in ipairs({ ... }) do
        opts[#opts + 1] = opt(name .. "." .. key, "boolean")
    end
    return { page = name, label = name, count = #opts,
             sections = { { title = name, options = opts } } }
end

DFSandboxView.mods = { page("Dirge", "ZombieRate", "ScreamerRate"),
                       page("Husbandry", "EggRate") }
DFSandboxView.selected = "Dirge"
DFSandboxView.form = DFForm.new{ schema = {} }

-- No query: the nav shows totals, and the form is handed the whole page. The
-- empty query still has to REACH the filter, or clearing the box would leave
-- the last search stuck on screen with nothing to say so.
DFSandboxView.filter = ""
filterQueries = {}
DFSandboxView.recount()
DFSandboxView.rebuildForm()
check(DFSandboxView.matches == nil,
    "an empty search left per-mod match counts on the nav, so every row would "
    .. "report a number that answers no question anybody asked")
check(filterQueries[1] == "", "clearing the box did not reach the filter")
check(DFSandboxView.shown == 2 and DFSandboxView.shownOf == 2,
    "the unfiltered page did not report itself whole: "
    .. tostring(DFSandboxView.shown) .. " of " .. tostring(DFSandboxView.shownOf))

-- A query: the page narrows and the nav counts the OTHER mods, which is the
-- whole reason the search is worth having across nine pages rather than one.
DFSandboxView.filter = "screamer"
filterQueries = {}
DFSandboxView.recount()
DFSandboxView.rebuildForm()
check(filterQueries[#filterQueries] == "screamer",
    "the typed query never reached the filter: "
    .. tostring(filterQueries[#filterQueries]))
check(DFSandboxView.shown == 1 and DFSandboxView.shownOf == 2,
    "the page did not report N of M: " .. tostring(DFSandboxView.shown)
    .. " of " .. tostring(DFSandboxView.shownOf))
check(DFSandboxView.matches ~= nil, "the nav was not given match counts")
check(DFSandboxView.matches["Dirge"] == 1,
    "the selected mod counted wrong: " .. tostring(DFSandboxView.matches["Dirge"]))
check(DFSandboxView.matches["Husbandry"] == 0,
    "A MOD WITH NO MATCH DID NOT REPORT ZERO. Absent and zero read alike on a "
    .. "nav row, and an admin would click through it looking for the option "
    .. "the panel already knows is not there.")

-- The nav's counts and the page's filtering must come from ONE rule. Two would
-- let the nav promise a match on a page that then shows nothing.
DFSandboxView.selected = "Husbandry"
DFSandboxView.rebuildForm()
check(DFSandboxView.shown == DFSandboxView.matches["Husbandry"],
    "THE NAV AND THE PAGE DISAGREE about how many options match. The nav said "
    .. tostring(DFSandboxView.matches["Husbandry"]) .. ", the page shows "
    .. tostring(DFSandboxView.shown))

DFSandboxView.selected = "Dirge"
DFSandboxView.rebuildForm()
check(DFSandboxView.shown == DFSandboxView.matches["Dirge"],
    "the nav and the page disagree on the selected mod too")

-- A query nobody matches empties the page rather than falling back to all of
-- it. A filter that silently gives up is worse than one that finds nothing:
-- the admin reads a full list and concludes their search term is in it.
DFSandboxView.filter = "nosuchoption"
DFSandboxView.recount()
DFSandboxView.rebuildForm()
check(DFSandboxView.shown == 0,
    "a search matching nothing fell back to showing everything")
check(DFSandboxView.matches["Dirge"] == 0 and DFSandboxView.matches["Husbandry"] == 0,
    "the nav still claimed matches for a query nothing matched")

-- Reopening the tab keeps whatever is in the search box, and the mod list is
-- rebuilt from scratch. Counts computed against the OLD list would survive as
-- promises about pages that no longer hold what they claim.
DFSandboxView.filter = "screamer"
DFSandboxView.recount()
-- onShow goes through the real reload(), which refills the nav from the model.
-- That is the path the bug lives on, so the fixture drives it rather than
-- poking V.mods: recounting has to happen after the list is rebuilt, and a
-- test that set the list by hand could not tell the two orders apart.
DFSandboxView.navBox = { items = {}, clear = function(b) b.items = {} end,
    addItem = function(b, name, item)
        local i = { text = name, item = item }
        b.items[#b.items + 1] = i
        return i
    end }
DFSandboxModel.build = function() return { page("Dirge", "ZombieRate") } end
DFSandboxView.selected = "Dirge"
DFSandboxView.onShow()
check(DFSandboxView.matches["Dirge"] == 0,
    "THE NAV KEPT A COUNT FROM THE PREVIOUS MOD LIST. It said "
    .. tostring(DFSandboxView.matches["Dirge"]) .. " for a page that no longer "
    .. "holds a matching option.")

print(string.format("DFSandboxView: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
