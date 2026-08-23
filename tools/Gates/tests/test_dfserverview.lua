-- DFServerView fixture - the /changeoption line, the echo, and the filter.
--
-- WHAT IS AT RISK. This surface writes a live server's INI by building console
-- command lines as STRINGS. Every failure mode is therefore a quoting failure,
-- and quoting failures on this path are silent: CommandBase splits on
-- whitespace and applies `(.*)` to the SECOND TOKEN ONLY
-- (CommandBase.java:147-150, ChangeOptionCommand.java:21), so an unquoted
-- multi-word value does not error - it writes the first word and discards the
-- rest. A welcome message becomes "Welcome".
--
-- The other half is honesty. changeOption tells no client
-- (ServerOptions.java:335-344), so nothing this panel shows after a write is
-- read back from the server; it is an echo of what we asked for. The tests
-- below pin that it stays an echo and does not quietly present itself as truth.

local ROOT = arg[1] or "."
local DIR  = ROOT .. "/RequiemOfTheDead/Contents/mods/Dragonfly/42/media/lua/client/Admin"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then passed = passed + 1
    else failed = failed + 1; print("FAIL DFServerView: " .. message) end
end

-- ---- stubs ---------------------------------------------------------------

function isServer() return false end
require = function() return true end

DFKit = {
    font = { small = "small" },
    metrics = { pad = 8, gap = 6, btnH = 24, rowH = 22, headerH = 20 },
    col = { text = {}, textDim = {}, line = {}, accent = {}, accentDim = {} },
    rowHeight = function() return 22 end,
    wrapText = function() return {} end,
    fitText = function(s) return s end,
    well = function() end,
    button = function() return {} end,
    layout = function() end,
    sizeList = function() end,
    refillList = function() end,
    drawEmpty = function() end,
}
DFForm = { new = function(o) return o end }
ISScrollingListBox = { derive = function() return {} end }
ISTextEntryBox = { new = function() return {} end }
function getText(k) return k end
function isClient() return true end

-- A server-options registry: flat, no pages, exactly as the engine presents it.
local OPTS = {}
local function addOpt(name, otype, value, default)
    OPTS[#OPTS + 1] = {
        name = name, otype = otype, value = value, default = default,
        getName = function(s) return s.name end,
        getType = function(s) return s.otype end,
        getPageName = function() return nil end,
        isCustom = function() return false end,
        getTranslatedName = function(s) return s.name end,
        getTooltip = function(s) return s.name .. " tip" end,
        getDefaultValue = function(s) return s.default end,
        getValue = function(s) return s.value end,
        getValueAsString = function(s) return tostring(s.value) end,
        getNumValues = function() return 0 end,
        getValueTranslationByIndex = function(_, k) return "v" .. k end,
    }
end
addOpt("PVP", "boolean", true, true)
addOpt("PVPLogToolChat", "boolean", true, true)
addOpt("SafehouseAllowRespawn", "boolean", false, false)
addOpt("ServerWelcomeMessage", "string", "Hi", "Hi")
addOpt("Password", "string", "", "")
addOpt("MaxPlayers", "integer", 32, 16)
addOpt("Zzz", "boolean", false, false)   -- matches no prefix -> Other
-- CONTAINS "Safehouse" but does not START with it. This is the name that tells
-- a prefix rule apart from a substring one, and it is a real engine option.
addOpt("DisableSafehouseWhenOwnerConnected", "boolean", false, false)

local SO = {}
function SO:getNumOptions() return #OPTS end
function SO:getOptionByIndex(i) return OPTS[i + 1] end
function SO:getOptionByName(n)
    for _, o in ipairs(OPTS) do if o.name == n then return o end end
end
function getServerOptions() return SO end
function getSandboxOptions() return nil end

local sent = {}
function SendCommandToServer(line) sent[#sent + 1] = line end

DFSandboxModel = nil; DFSandboxView = nil; DFServerFlags = nil; DFServerView = nil
for _, f in ipairs({ "DFStaged", "DFSandboxModel", "DFSandboxView", "DFServerFlags", "DFServerView" }) do
    local ok, err = pcall(dofile, DIR .. "/" .. f .. ".lua")
    check(ok, f .. " loads: " .. tostring(err))
end

-- ---- the model's server side --------------------------------------------

local page = DFSandboxModel.buildServer()
check(page ~= nil, "buildServer returned nothing")
check(page.count == #OPTS, "buildServer lost options: " .. tostring(page.count))

local titles = {}
for i, sec in ipairs(page.sections) do titles[i] = sec.title end
check(titles[#titles] == "Other",
    "Other is not last - it is the leftovers bucket and reads as one at the "
    .. "bottom, not wedged between real sections")

local function sectionOf(name)
    for _, sec in ipairs(page.sections) do
        for _, o in ipairs(sec.options) do if o.name == name then return sec.title end end
    end
end
check(sectionOf("PVP") == "PVP", "PVP did not land in its own section")
check(sectionOf("PVPLogToolChat") == "PVP", "a PVP-prefixed option was not grouped with it")
check(sectionOf("SafehouseAllowRespawn") == "Safehouse", "Safehouse prefix missed")
check(sectionOf("Zzz") == "Other", "an unmatched name did not fall to Other")
-- The rule is a PREFIX rule. "Password" starts with "P" but not with any
-- section word, so it must not be swept into PVP by a looser match.
check(sectionOf("Password") == "Other", "'Password' matched no section prefix")
check(sectionOf("DisableSafehouseWhenOwnerConnected") == "Other",
    "'DisableSafehouseWhenOwnerConnected' was filed under Safehouse - the rule "
    .. "is a whole-PREFIX test, not a substring search. A substring rule files "
    .. "options under a word that happens to appear in the middle of the name, "
    .. "which is exactly where nobody will look for them")

-- ---- quoting, which is the silent failure -------------------------------

check(DFServerView.commandFor("PVP", true) == '/changeoption PVP "true"',
    "got: " .. DFServerView.commandFor("PVP", true))

-- The one that matters. Unquoted, CommandBase's (.*) sees only "Welcome" and
-- the rest is discarded with no error.
local multi = DFServerView.commandFor("ServerWelcomeMessage", "Welcome to the server")
check(multi == '/changeoption ServerWelcomeMessage "Welcome to the server"',
    "A MULTI-WORD VALUE WAS NOT QUOTED - the server would keep the first word "
    .. "and silently drop the rest. got: " .. multi)

-- CommandBase strips every quote from a token, so an embedded one cannot
-- survive by escaping; dropping it is deliberate, and reported.
local cleaned, changed = DFServerView.sanitize('say "hi" now')
check(cleaned == "say hi now", "embedded quotes were not removed: " .. cleaned)
check(changed == true, "sanitize did not report that it altered the value")
check(select(2, DFServerView.sanitize("plain")) == false,
    "sanitize reported a change it did not make")
check(DFServerView.sanitize("two\nlines") == "two lines",
    "a newline survived - it would terminate the command line")

DFServerView.staged = DFStaged.new(DFServerView.liveValue)

-- ---- apply ---------------------------------------------------------------

local lines = {}
local function capture(l) lines[#lines + 1] = l end

local ok, n = DFServerView.applyWith(capture,
    { PVP = false, MaxPlayers = 64, Zzz = true, Password = "x",
      SafehouseAllowRespawn = true, ServerWelcomeMessage = "hello there" })
check(ok == true and n == 6, "applyWith reported " .. tostring(ok) .. "/" .. tostring(n))
check(#lines == 6, "expected one command per option, got " .. #lines)

-- Asserted as a SORTED SEQUENCE, not by spot-checking one entry. pairs() order
-- is unspecified and CAN coincidentally match sorted order - with two keys it
-- did, and a weaker version of this assertion survived its mutation. Six keys
-- makes the coincidence unlikely, and comparing against the sorted list tests
-- the property itself rather than a symptom of it.
local names = {}
for i, l in ipairs(lines) do
    names[i] = l:match("^/changeoption ([%w_]+)")
end
local sorted = {}
for i, v in ipairs(names) do sorted[i] = v end
table.sort(sorted)
local inOrder = true
for i = 1, #names do if names[i] ~= sorted[i] then inOrder = false end end
check(inOrder,
    "commands were not sorted - a run of changes should reach the admin log in "
    .. "a stable order. got: " .. table.concat(names, ", "))

local ok2, why = DFServerView.applyWith(capture, {})
check(ok2 == false and tostring(why):find("nothing", 1, true) ~= nil,
    "an empty apply sent something")

-- The echo. changeOption never tells a client anything, so after sending we
-- must show what we ASKED for or the row appears not to have changed.
check(DFServerView.readValue("PVP") == false,
    "the sent value was not echoed locally - the row would still read `true` "
    .. "and the admin would click it again")
check(DFServerView.liveValue("PVP") == false, "the echo did not become the baseline")

-- ...and staging back to the echoed value clears the edit rather than queueing
-- a second identical write.
DFServerView.staged:set("PVP", false)
check(DFServerView.staged:count() == 0,
    "staging a value equal to what was already sent queued a redundant write")

-- ---- filter --------------------------------------------------------------

local schema = {
    { group = "PVP" },
    { key = "PVP", label = "PVP" },
    { key = "PVPLogToolChat", label = "PVPLogToolChat" },
    { group = "Other" },
    { key = "Zzz", label = "Zzz" },
}
check(#DFServerView.filterSchema(schema, "") == #schema, "an empty filter changed the schema")

local hits = DFServerView.filterSchema(schema, "pvplog")
local groups, rows = 0, 0
for _, e in ipairs(hits) do
    if e.group then groups = groups + 1 else rows = rows + 1 end
end
check(rows == 1, "filter matched " .. rows .. " rows, expected 1")
check(groups == 1, "a section header with nothing under it survived the filter")

check(#DFServerView.filterSchema(schema, "PVPLOG") == #DFServerView.filterSchema(schema, "pvplog"),
    "the filter is case-sensitive")
check(#DFServerView.filterSchema(schema, "zzzz") == 0,
    "a filter matching nothing left headers behind")

-- ---- restart flags -------------------------------------------------------
-- Three states, and the third is the honest one: an option nobody has read
-- carries no claim in either direction.

check(DFServerFlags.stateOf("Password") == DFServerFlags.LIVE,
    "Password should be LIVE - ChangeOptionCommand.java:35-37 re-sets it")
check(DFServerFlags.stateOf("ClientCommandFilter") == DFServerFlags.LIVE,
    "ClientCommandFilter should be LIVE - :38-40 re-inits the filter")
check(DFServerFlags.stateOf("MaxPlayers") == nil,
    "an unread option must return nil, not a guess - marking the unread "
    .. "majority as 'needs restart' makes the mark meaningless")
check(select(2, DFServerFlags.stateOf("Password")) ~= nil,
    "a flag carries no citation, so a later session cannot check it")

print(string.format("DFServerView: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
