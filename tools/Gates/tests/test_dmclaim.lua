-- DMClaim fixture - the player's Kits window.
--
-- WHAT IS AT RISK.
--
-- 1. THE SHARED REPLY ENVELOPE, the player's half. One client can be both an
--    admin authoring kits and a player with this window open, and every kit
--    command answers on one KitResult. A window rendering every reply would
--    show a delete confirmation as what the player had just been handed.
--
-- 2. THE DOUBLE CLAIM. kitClaim is rated at one per second and RDNet does NOT
--    answer a refused flood - replying to one re-amplifies it - so a second
--    click inside that window buys SILENCE. A player who read that silence as
--    a claim that worked would walk away believing they had taken something
--    twice. The window has to refuse the second click itself.
--
-- 3. THREE EMPTY STATES, not two. "Not asked yet" and "nothing to claim" are
--    different facts, and a player told the second while the first is true
--    walks away from a reward they have earned.
--
-- 4. THE SELECTION SURVIVING THE RE-READ that follows every claim. Same rule as
--    every other list in the suite, and here the cost is claiming the wrong
--    kit - a one-time reward spent on a click nobody made.

local ROOT = arg[1] or "."
local DM   = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDungeonMaster/42/media/lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then passed = passed + 1
    else failed = failed + 1; print("FAIL DMClaim: " .. message) end
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

local function fakeBox()
    local box = { items = {}, selected = 1 }
    function box:clear() self.items = {}; self.selected = 1 end
    function box:addItem(name, item)
        local i = { text = name, item = item }
        self.items[#self.items + 1] = i
        return i
    end
    return box
end

DFKit = { font = { small = "small" }, metrics = { btnH = 24, pad = 8, gap = 6 },
          col = { text = {}, textDim = {}, accentDim = {}, accent = {} },
          rowHeight = function() return 22 end,
          fitText = function(s) return s end,
          refillList = function(box, fill) box:clear(); if fill then fill(box) end end,
          well = function(e) return e end,
          button = function() return {} end }

local sent = {}
RDNet = { send = function(_, command, args)
    sent[#sent + 1] = { command = command, args = args }
end }
-- OnGameStart carries the registration; captured so the fixture can drive it
-- and prove the tab actually reaches the player deck.
local onGameStart = nil
Events = {
    OnServerCommand = { Add = function() end },
    OnGameStart     = { Add = function(fn) onGameStart = fn end },
}
function isClient() return true end
function getText(k) return k end

-- The registry, recording. Dragonfly may legitimately be absent, so the
-- fixture drives both worlds.
local registered = nil
Dragonfly = { registerPlayerTab = function(spec) registered = spec end }

-- DMIcons turns a contents row into a picture and words. Textures need the
-- engine; only the WORDS matter to linesFor, which is what this fixture reads.
-- The REAL DMKitDefs, not the two-constant stub this used to carry: the
-- display order this fixture pins moved into it (displayOrder, promoted
-- 2026-08-25), and a stub implementing the behaviour under test would be the
-- fixture testing itself. Its two deps are cheap, the same loader shape
-- test_dmkitstab already uses.
RDVarDefs, DMRoll, DMKitDefs = nil, nil, nil
for _, spec in ipairs({ { ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/shared/RDVarDefs.lua", "RDVarDefs" },
                        { DM .. "/shared/DMRoll.lua", "DMRoll" },
                        { DM .. "/shared/DMKitDefs.lua", "DMKitDefs" } }) do
    local okL, errL = pcall(dofile, spec[1])
    check(okL, spec[2] .. " loads: " .. tostring(errL))
end

DMIcons = {
    label = function(r) return tostring(r and r.ref or "?")
        .. ((tonumber(r and r.count) or 1) > 1 and ("  x" .. r.count) or "") end,
    rouletteHeading = function(row)
        return "ONE OF THESE " .. #((row and row.branches) or {}) .. ":"
    end,
    oddsText = function(b)
        local p = b and tonumber(b.percent)
        return p and (tostring(p) .. "%") or ""
    end,
    texture = function() return nil end,
}

DMClaim = nil
local ok, err = pcall(dofile, DM .. "/client/DMClaim.lua")
check(ok, "module loads: " .. tostring(err))

-- ---- the list ------------------------------------------------------------

local MINE = {
    { id = "zeta",  label = "Zeta Stipend", kind = "xp",
      repeatable = true, taken = 3 },
    { id = "loot",  label = "Anomaly Loot", kind = "item", repeatable = false,
      taken = 0 },
    { id = "alpha", label = "Anomaly Loot", kind = "trait", repeatable = false,
      taken = 0 },
}

local sorted = DMKitDefs.displayOrder(MINE)
check(#sorted == 3, "a kit was lost")
check(sorted[1].id == "alpha" and sorted[2].id == "loot",
    "two kits sharing a label are not ordered, so they would trade places on "
    .. "every refresh - under a selection aimed at one of them")
-- The tiebreak's real job is INDEPENDENCE FROM THE INPUT ORDER. The wire
-- delivers whatever the store's pairs() produced, which is not stable between
-- two reads, so a comparator that calls two rows equal lets table.sort hand
-- back a different arrangement of the same catalogue - under a selection aimed
-- at one of them.
-- EVERY permutation, not a second one. table.sort's arrangement of two
-- "equal" rows depends on where they started, and only some starting orders
-- expose it - a two-case check passes against a comparator that is wrong for
-- a third of the inputs the wire can deliver.
local PERMS = { {3,2,1}, {3,1,2}, {2,3,1}, {2,1,3}, {1,3,2}, {1,2,3} }
local reference
for _, perm in ipairs(PERMS) do
    local input = {}
    for _, idx in ipairs(perm) do input[#input + 1] = MINE[idx] end
    local got = DMKitDefs.displayOrder(input)
    local ids = {}
    for _, k in ipairs(got) do ids[#ids + 1] = tostring(k.id) end
    ids = table.concat(ids, ",")
    reference = reference or ids
    check(ids == reference,
        "THE ORDER DEPENDS ON HOW THE WIRE HAPPENED TO DELIVER IT. The store's "
        .. "pairs() is not stable between two reads, so the catalogue would "
        .. "rearrange itself under a selection aimed at one of its rows: got "
        .. ids .. ", expected " .. reference)
end
check(#DMKitDefs.displayOrder(nil) == 0, "sorted faulted on nothing")

-- ---- the row tag ---------------------------------------------------------
-- A one-time kit says nothing, because being in this list AT ALL means the
-- player has not had it. A repeatable one reports the only number they can act
-- on.

check(DMClaim.tagFor(MINE[1]):find("3") ~= nil,
    "a repeatable kit did not report how many times it had been taken")
-- The tag is a DURATION now, not a yes/no: "once ever" stopped existing when
-- the policy collapsed to one number (owner, 2026-08-24).
check(DMClaim.tagFor{ claimText = "every 121 days", taken = 0 } == "every 121 days",
    "an untaken kit did not show how often it comes round")
check(DMClaim.tagFor{ claimText = "any time", taken = 3 }:find("3") ~= nil,
    "a kit already taken lost its count")
check(DMClaim.tagFor{ taken = 0 } == "",
    "a kit whose policy did not arrive invented one")
check(DMClaim.tagFor(nil) == "", "tagFor faulted on nil")

-- ---- the empty states ----------------------------------------------------

check(DMClaim.emptyLine(nil) ~= DMClaim.emptyLine({}),
    "A REQUEST STILL IN FLIGHT AND AN EMPTY ANSWER READ ALIKE. One is a fact "
    .. "about the network and the other is a fact about the player, and a "
    .. "player told the second walks away from something they have earned.")
check(DMClaim.emptyLine(nil):find("Checking") ~= nil,
    "the in-flight state did not say it was still waiting")

-- ---- receive -------------------------------------------------------------

check(DMClaim.receive("KitMine", { kits = MINE }) == true,
    "the catalogue reply was ignored")
check(#DMClaim.kits == 3, "the catalogue did not land")

-- THE SHARED ENVELOPE, from this side.
DMClaim.busy, DMClaim.status = true, nil
check(DMClaim.receive("KitResult",
        { ok = true, command = "kitDelete", message = "Deleted 'loot'." }) == false,
    "THE CLAIM WINDOW RENDERED AN ADMIN'S REPLY. A staff member with this "
    .. "window open would read a deletion notice as what they had just been "
    .. "handed.")
check(DMClaim.status == nil, "an admin verb's message reached the player")
check(DMClaim.busy == true,
    "another command's reply released the claim button, so the next click "
    .. "would land inside the rate window and be answered with silence")

check(DMClaim.receive("KitResult",
        { ok = true, command = "kitGrantTo", message = "..." }) == false,
    "a staff grant to somebody else was rendered here")

sent = {}
check(DMClaim.receive("KitResult",
        { ok = true, command = "kitClaim", message = "You received an axe." }) == true,
    "the player's own claim answer was not handled")
check(DMClaim.status == "You received an axe.", "the delivery report was lost")
check(DMClaim.busy == false, "the claim button was left disabled forever")
check(sent[1] and sent[1].command == "kitMine",
    "a successful claim did not re-read the list - a one-time kit just spent "
    .. "would stay on screen as something still available")

-- A refusal reports its reason AND re-reads: the list this window is showing
-- is the thing that turned out to be wrong.
sent = {}
DMClaim.busy = true
DMClaim.receive("KitResult",
    { ok = false, command = "kitClaim", reason = "That kit is not available to you." })
check(DMClaim.status == "That kit is not available to you.",
    "a refusal lost its reason")
check(DMClaim.busy == false, "a refusal left the button disabled")
check(sent[1] and sent[1].command == "kitMine", "a refusal did not re-read the list")

check(DMClaim.receive("SomethingElse", {}) == false,
    "an unrelated command was consumed")

-- OFF SCREEN, THE ANSWER STILL LANDS. The deck destroys the tab's panel the
-- moment another tab is picked, so a player who claims and switches away must
-- not return to a Claim button still disabled by a send that has since been
-- answered.
DMClaim.listBox = nil
DMClaim.busy = true
local okC = pcall(DMClaim.receive, "KitResult", { ok = true, command = "kitClaim" })
check(okC, "a claim answer arriving with the tab off screen faulted")
check(DMClaim.busy == false,
    "THE BUSY LATCH SURVIVED THE TAB. Coming back to a permanently disabled "
    .. "Claim button reads as a broken control with nothing to explain it.")

-- ---- the selection across the re-read ------------------------------------

DMClaim.listBox = fakeBox()
DMClaim.kits = MINE
DMClaim.selected = "loot"
DMClaim.rebuild()
check(DMClaim.listBox.selected == 2,
    "the highlight was not re-derived from the remembered id: "
    .. tostring(DMClaim.listBox.selected))

-- The kit was one-time and has just been spent, so it is gone from the answer.
DMClaim.kits = { MINE[1], MINE[3] }
DMClaim.rebuild()
check(DMClaim.selected == nil,
    "THE SELECTION SLID ONTO A NEIGHBOUR after the claimed kit left the list. "
    .. "The next Claim would spend a different one-time reward on a click "
    .. "nobody made.")
check(DMClaim.listBox.selected == -1,
    "a highlight survived the kit it pointed at")

-- ---- REGISTRATION ---------------------------------------------------------
--
-- The tab moved off the vanilla Client panel onto the player deck (owner,
-- 2026-08-23). What is at risk is the direction of the dependency: this must
-- reach the deck through CORE's registry and must vanish quietly when
-- Dragonfly is not there, or a satellite has taken a hard edge on the
-- presentation layer - the one sect. 12 forbids.

check(onGameStart ~= nil, "no OnGameStart registration hook was bound")

onGameStart()
check(registered ~= nil, "THE TAB NEVER REACHED THE PLAYER DECK")
check(registered.id == "dm_kits", "the tab registered under an unexpected id")
check(type(registered.build) == "function", "the tab registered no build")
check(type(registered.resize) == "function",
    "no resize - the tab would keep its first size through every reflow")
check(registered.label == "IGUI_DM_Kits",
    "the tab label did not come from the translation table")

-- Without Dragonfly: nothing, and no error.
registered = nil
local savedDF = Dragonfly
Dragonfly = nil
local okNoDF = pcall(onGameStart)
check(okNoDF, "REGISTRATION FAULTED WITH DRAGONFLY ABSENT. Kits must degrade, "
    .. "not break - the whole mod would fail to load behind this.")
check(registered == nil, "a tab was registered with no registry present")

-- A registry that exists but lacks the verb (an older Dragonfly) is the same
-- answer, and is why the guard tests the FUNCTION rather than the table.
Dragonfly = {}
check(pcall(onGameStart), "an older Dragonfly without registerPlayerTab faulted")
Dragonfly = savedDF

-- Singleplayer: a kit catalogue is authored on a server, so a tab here could
-- only ever read "Checking..." forever.
registered = nil
isClient = function() return false end
onGameStart()
check(registered == nil,
    "THE TAB REGISTERED IN SINGLEPLAYER, where kitMine has no server to "
    .. "answer it - an empty tab that never fills is worse than no tab.")

-- ---- THE CONTENTS PANE ----------------------------------------------------
--
-- Flattened here rather than in the drawing so the nesting is worked out in a
-- function that can be read. What is at risk: a roulette drawn as though its
-- branches were all guaranteed, odds repeated down a branch so one chance
-- reads as several, and - the rule the owner set - a weight reaching a player
-- at all.

local WITH = {
    id = "loot", label = "Anomaly Loot",
    contents = {
        { kind = "item", ref = "Base.Axe", count = 2 },
        { kind = "roulette", pick = 1, branches = {
            { rows = { { kind = "item", ref = "Base.Katana", count = 1 },
                       { kind = "item", ref = "Base.Sheath", count = 1 } } },
            { rows = {} },
        } },
    },
}

local lines = DMClaim.linesFor(WITH)
check(lines[1].text:find("Base.Axe") ~= nil, "the guaranteed item did not lead")
check(lines[1].icon ~= nil, "a guaranteed item row carried no icon reference")
check(lines[2].text:find("ONE OF THESE") ~= nil,
    "the roulette drew without a heading, so its branches would read as "
    .. "guaranteed alongside the item above them")
check(lines[3].indent == 1, "a branch row was not indented under its heading")
check(lines[4].text:find("Base.Sheath") ~= nil and lines[4].indent == 1,
    "a branch's SECOND row was lost or un-indented, so a two-item branch would "
    .. "read as one prize: " .. tostring(lines[4].text))
check(lines[5].text:find("something unseen") ~= nil,
    "A BRANCH OF PURE BOOKKEEPING VANISHED. It is still an outcome, and "
    .. "dropping it makes the visible branches read likelier than they are.")

-- THE STRIP, proved against a payload that DOES carry weights. The server
-- builds kitMine without them, so this is the second gate on the same rule -
-- and the one that would still hold if the first were ever edited wrong.
local WEIGHTED = {
    id = "loot", label = "Anomaly Loot",
    contents = { { kind = "roulette", pick = 1, branches = {
        { percent = 10, rows = { { kind = "item", ref = "Base.Katana" } } },
        { percent = 90, rows = { { kind = "item", ref = "Base.Crowbar" } } },
    } } },
}
for _, l in ipairs(DMClaim.linesFor(WEIGHTED)) do
    check((l.odds or "") == "",
        "A WEIGHT REACHED THE PLAYER'S PANE. Odds are the admin surface only, "
        .. "and this projection is the last gate before one hits a screen.")
    check(tostring(l.text):find("%%") == nil,
        "a percentage was written into a player-facing line: " .. tostring(l.text))
end

-- A kit whose every grant is bookkeeping is authorable and must say something.
local bare = DMClaim.linesFor({ id = "x", contents = {} })
check(#bare == 1 and bare[1].text:find("Nothing you can carry") ~= nil,
    "a kit with nothing visible drew an empty pane with no explanation")
check(#DMClaim.linesFor(nil) == 1, "a nil kit faulted the pane")

-- ---- THE COUNTDOWN --------------------------------------------------------
--
-- A cooling kit STAYS on the player's list, because they have already earned
-- it and are only waiting - a kit that vanished after being claimed and came
-- back hours later with no explanation reads as a bug.

check(DMClaim.waitText(nil) == "", "a kit with no wait rendered one")
check(DMClaim.waitText(0) == "", "a lifted wait still rendered")
check(DMClaim.waitText(90 * 1000) == "2 min",
    "a part-minute did not round UP - telling somebody 1 min when 90 seconds "
    .. "remain sends them back too early: " .. DMClaim.waitText(90 * 1000))
check(DMClaim.waitText(59 * 60000) == "59 min", "an hour boundary rendered wrong")
check(DMClaim.waitText(3 * 3600 * 1000) == "3 hr", "hours did not render")
check(DMClaim.waitText(5 * 24 * 3600 * 1000) == "5 days", "days did not render")

check(DMClaim.tagFor({ readyInMs = 3600 * 1000, repeatable = true, taken = 4 })
      :find("in 1 hr") ~= nil,
    "A COOLING KIT SHOWED ITS CLAIM COUNT INSTEAD OF ITS WAIT. The wait is the "
    .. "only thing the player can act on.")
check(DMClaim.tagFor({ repeatable = true, taken = 4 }):find("4") ~= nil,
    "a ready repeatable kit lost its count")

check(DMClaim.isReady({ readyInMs = 1 }) == false, "a cooling kit read as ready")
check(DMClaim.isReady({ readyInMs = 0 }) == true, "a lifted kit read as cooling")
check(DMClaim.isReady({}) == true, "a kit with no cooldown read as cooling")

print(string.format("DMClaim: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
