-- DMClaimants fixture - the two staff read-outs over the claim record.
--
-- WHAT IS AT RISK. These windows are how a staff member answers "who took
-- what, when" after the fact, so every failure here is a wrong answer delivered
-- confidently: a claimant list sorted so the heaviest user is not at the top, a
-- timestamp rendered as local time when it is the server's, a delivery that
-- never finished drawn as though it had, and - the one that matters most - a
-- reply for one kit rendered under another kit's name.
--
-- The drawing is not covered; it needs ISUI. What is covered is every function
-- that decides what a row SAYS.

local ROOT = arg[1] or "."
local DM   = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDungeonMaster/42/media/lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then passed = passed + 1
    else failed = failed + 1; print("FAIL DMClaimants: " .. message) end
end

-- ---- stubs ---------------------------------------------------------------

function isServer() return false end
require = function() return true end

local function stubClass()
    local C = {}; C.__index = C
    function C:derive() local D = {}; D.__index = D; setmetatable(D, { __index = C }); return D end
    return C
end
ISScrollingListBox  = stubClass()
ISCollapsableWindow = stubClass()

DFKit = { font = { small = "small" }, metrics = { btnH = 24, pad = 8, gap = 6 },
          col = { text = {}, textDim = {} },
          rowHeight = function() return 22 end,
          fitText = function(s) return s end,
          refillList = function(box, fill) box:clear(); if fill then fill(box) end end,
          well = function(e) return e end,
          button = function() return {} end }

local sent = {}
RDNet = { send = function(_, command, args)
    sent[#sent + 1] = { command = command, args = args }
end }
Events = { OnServerCommand = { Add = function() end } }

DMClaimants = nil
local ok, err = pcall(dofile, DM .. "/client/DMClaimants.lua")
check(ok, "module loads: " .. tostring(err))

-- ---- the stamp -----------------------------------------------------------

-- 2026-08-23T14:05:00Z, in milliseconds.
local WHEN = 1787493900000
local text = DMClaimants.stamp(WHEN)
check(text:find("2026%-08%-23") ~= nil, "the date did not render: " .. text)
check(text:find("Z$") ~= nil,
    "A TIMESTAMP WITHOUT ITS ZONE. This is the SERVER's clock; rendered bare "
    .. "it reads as local time and quietly misleads anyone comparing it to a "
    .. "chat log. Got: " .. text)
check(DMClaimants.stamp(nil) == "", "a missing stamp invented a time")
check(DMClaimants.stamp(0) == "", "a zero stamp rendered as the epoch")

-- ---- claimants -----------------------------------------------------------

local ROWS = {
    { user = "Aaron", n = 1, at = WHEN },
    { user = "Zed",   n = 9, at = WHEN },
    { user = "Mara",  n = 9 },
}
local sorted = DMClaimants.sortClaimants(ROWS)
check(sorted[1].n == 9 and sorted[2].n == 9,
    "the heaviest claimants were not first - that is the question this window "
    .. "is opened to answer")
-- SWEPT ACROSS EVERY PERMUTATION, not sampled. A comparator with no tiebreak
-- still returns SOME order, and which one depends on where the equal elements
-- started - so one arrangement, or two, can agree by luck. Three rows have six
-- arrangements and all six must land identically, which no tiebreak-less
-- comparator can manage.
local A = { user = "Aaron", n = 1, at = WHEN }
local Z = { user = "Zed",   n = 9, at = WHEN }
local R = { user = "Mara",  n = 9 }
local PERMS = { { A, Z, R }, { A, R, Z }, { Z, A, R },
                { Z, R, A }, { R, A, Z }, { R, Z, A } }
for i, perm in ipairs(PERMS) do
    local got = DMClaimants.sortClaimants(perm)
    local names = got[1].user .. "/" .. got[2].user .. "/" .. got[3].user
    check(names == "Mara/Zed/Aaron",
        "THE ORDER DEPENDS ON THE INPUT ORDER (arrangement " .. i .. " gave "
        .. names .. "). Two equal counts would swap places between openings of "
        .. "the same window, which reads as the data changing under you.")
end

check(sorted[3].user == "Aaron", "the lightest claimant did not sort last")

local line = DMClaimants.claimantLine(ROWS[2])
check(line:find("Zed") ~= nil and line:find("9") ~= nil,
    "a claimant line lost its name or count: " .. line)
check(DMClaimants.claimantLine({ user = "Mara", n = 9 }):find("last:") == nil,
    "a row with no timestamp invented a 'last' column")
check(DMClaimants.claimantLine({ user = "A", n = 1, by = "Omen" }):find("Omen") ~= nil,
    "a staff grant did not name who handed it over")
check(DMClaimants.claimantLine("junk"):find("malformed") ~= nil,
    "a malformed row drew as a real claimant")

-- ---- the log -------------------------------------------------------------

local L = DMClaimants.logLine{ at = WHEN, id = "loot", label = "Anomaly Loot",
                               user = "Kriegan", items = "Fire Axe x1" }
check(L:find("2026%-08%-23") ~= nil, "the log line lost its date")
check(L:find("Anomaly Loot") ~= nil, "the log line lost the kit name")
check(L:find("Kriegan") ~= nil, "the log line lost the player")
check(L:find("Fire Axe x1") ~= nil, "the log line lost what was received")

local noItems = DMClaimants.logLine{ at = WHEN, label = "K", user = "U" }
check(noItems:find("not recorded") ~= nil,
    "A CLAIM WHOSE DELIVERY NEVER FINISHED DREW AS A NORMAL LINE. The summary "
    .. "attaches after the grants run, so a line without one is the record of "
    .. "something that went wrong and must not look like something that did not.")

local granted = DMClaimants.logLine{ at = WHEN, label = "K", user = "U",
                                     by = "Omen", items = "x" }
check(granted:find("granted by Omen") ~= nil,
    "a staff grant was not distinguished from a self-claim in the log")

-- Falls back to the id for a kit whose label was never set.
check(DMClaimants.logLine{ at = WHEN, id = "loot", user = "U" }:find("loot") ~= nil,
    "a kit with no label lost its identity in the log")

-- ---- the empty states ----------------------------------------------------

check(DMClaimants.emptyLine(nil, "kit") == "Reading...",
    "loading and empty read alike")
check(DMClaimants.emptyLine({}, "kit"):find("Nobody") ~= nil,
    "an unclaimed kit did not say so")
check(DMClaimants.emptyLine({}, "log"):find("log was added") ~= nil,
    "THE EMPTY LOG DID NOT EXPLAIN ITSELF. Claims made before the log existed "
    .. "have ledger rows and no lines, and an admin who has just watched a "
    .. "claim happen needs to know which of the two they are looking at.")

-- ---- observe: the reply must match the window ----------------------------

check(DMClaimants.observe("KitClaimants", { id = "loot", rows = {} }) == false,
    "a reply was absorbed with no window open")

local rebuilt = 0
DMClaimants.win = { mode = "kit", kitId = "loot",
                    rebuild = function() rebuilt = rebuilt + 1 end }

check(DMClaimants.observe("KitClaimants", { id = "other", rows = ROWS }) == false,
    "ANOTHER KIT'S CLAIMANTS WERE DRAWN UNDER THIS KIT'S NAME. Answers arrive "
    .. "unordered against clicks, so this is the ordinary case.")
check(rebuilt == 0, "a mismatched reply still redrew the window")

check(DMClaimants.observe("KitClaimants", { id = "loot", rows = ROWS }) == true,
    "the matching reply was not taken")
check(rebuilt == 1, "the matching reply did not redraw")
check(DMClaimants.win.rows[1].n == 9, "the rows arrived unsorted")

-- A log reply must not land in a claimants window, or vice versa. Tested with
-- an id ON the payload: the mode check has to be doing the work, not the id
-- check happening to fail for a payload that carries none.
check(DMClaimants.observe("KitLog", { id = "loot", rows = { { at = WHEN } } }) == false,
    "A LOG REPLY WAS RENDERED IN THE CLAIMANTS WINDOW. Two queries, one "
    .. "window, and the rows mean entirely different things.")
check(rebuilt == 1, "the mis-routed log reply still redrew the window")

DMClaimants.win = { mode = "log", rebuild = function() rebuilt = rebuilt + 1 end }
check(DMClaimants.observe("KitClaimants", { id = "loot", rows = ROWS }) == false,
    "a claimants reply was rendered in the log window")
check(DMClaimants.observe("KitLog", { rows = { { at = WHEN } } }) == true,
    "the log reply was not taken")

DMClaimants.win = nil

print(string.format("DMClaimants: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
