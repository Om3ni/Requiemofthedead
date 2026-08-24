-- DMKitsTab fixture - the kit catalogue's navigation half.
--
-- WHAT IS AT RISK.
--
-- 1. THE SHARED REPLY ENVELOPE. One client is both this authoring tab and a
--    player with a Kits window, and every kit command answers on one KitResult.
--    A tab that rendered every reply would show an admin their own claim's
--    delivery report in the authoring footer; a claim window that did the same
--    would show them a delete confirmation as what they had just received.
--    Both surfaces filter on the command name, and this file pins the tab's
--    half of that.
--
-- 2. SELECTION SURVIVING A REFRESH. Every verb here triggers a server push, the
--    push rebuilds the list, and DFKit.refillList calls clear() - which sets
--    selected = 1 (ISScrollingListBox.lua:340-345). A tab reading its target
--    off the widget would delete a kit, refresh, silently point at whatever is
--    now first, and delete THAT on the next click.
--
-- 3. THE SUMMARY TELLING THE TRUTH. It is what an admin reads INSTEAD of
--    opening the editor, so a grant it omits is a kit that does more than the
--    panel says it does - and the omission an admin would never suspect is the
--    roulette, because its contents are not on screen anywhere else.
--
-- 4. CLAIMANT ANSWERS LANDING UNDER THE RIGHT KIT. They arrive unordered
--    against clicks, and one drawn under the wrong heading attributes one
--    kit's claim history to another.

local ROOT = arg[1] or "."
local CORE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua"
local DM   = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDungeonMaster/42/media/lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then passed = passed + 1
    else failed = failed + 1; print("FAIL DMKitsTab: " .. message) end
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
ISContextMenu = { get = function() return nil end }

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
          col = { text = {}, textDim = {}, accent = {}, accentDim = {} },
          rowHeight = function() return 22 end,
          fitText = function(s) return s end,
          refillList = function(box, fill) box:clear(); if fill then fill(box) end end,
          well = function(e) return e end,
          button = function() return {} end }
DFForm    = { new = function(o) return o end }
DFConfirm = { ask = function() end }

-- DMIcons resolves a contents row to a picture and words. Textures need the
-- engine, so the icon half is absent here and only the WORDS are stubbed - the
-- summary pane's odds lines are text, which is what this fixture reads.
DMIcons = {
    rouletteHeading = function(row)
        local pick = tonumber(row and row.pick) or 1
        return (pick > 1 and ("ONE DRAW OF " .. pick .. ", from ") or "ONE OF THESE ")
            .. #((row and row.branches) or {}) .. ":"
    end,
    oddsText = function(b)
        local p = b and tonumber(b.percent)
        return p and (string.format("%d", p) .. "%") or ""
    end,
    label = function(r) return tostring(r and r.ref or "?") end,
    texture = function() return nil end,
}
DMClaimants = { observe = function() return false end,
                open = function() end, openLog = function() end }
function getPlayer() return { getPlayerNum = function() return 0 end } end

local sent = {}
RDNet = { send = function(_, command, args)
    sent[#sent + 1] = { command = command, args = args }
end }

Events = { OnServerCommand = { Add = function() end },
           OnGameStart = { Add = function() end } }

RDVarDefs, DMRoll, DMKitDefs = nil, nil, nil
for _, spec in ipairs({ { CORE .. "/shared/RDVarDefs.lua", "RDVarDefs" },
                        { DM .. "/shared/DMRoll.lua", "DMRoll" },
                        { DM .. "/shared/DMKitDefs.lua", "DMKitDefs" },
                        { DM .. "/client/DMKitForm.lua", "DMKitForm" } }) do
    local okL, errL = pcall(dofile, spec[1])
    check(okL, spec[2] .. " loads: " .. tostring(errL))
end

DMKitsTab = nil
local ok, err = pcall(dofile, DM .. "/client/DMKitsTab.lua")
check(ok, "module loads: " .. tostring(err))

-- ---- the catalogue -------------------------------------------------------

local KITS = {
    { id = "zeta",  kind = "xp",    label = "Zeta Stipend",
      claim = { cooldownHours = 0 }, grants = { { kind = "xp", perk = "Fitness", amount = 100 } } },
    { id = "loot",  kind = "item",  label = "Anomaly Loot",
      claim = { cooldownHours = 2160 },
      requires = { flags = { "delver" },
                   counters = { { name = "samples", atLeast = 10 } } },
      grants = { { kind = "item", type = "Base.Axe", count = 2 },
                 { kind = "roulette", pick = 1, from = {
                     { weight = 10, grants = { { kind = "item", type = "Base.Katana" } } },
                     { weight = 90, grants = { { kind = "item", type = "Base.Crowbar" } } } } } } },
    { id = "alpha", kind = "trait", label = "Anomaly Loot",   -- same LABEL
      claim = { cooldownHours = 2160 }, grants = { { kind = "trait", id = "M:Delver" } } },
}

local sorted = DMKitsTab.sorted(KITS)
check(#sorted == 3, "the catalogue lost a kit")
check(sorted[1].label == "Anomaly Loot" and sorted[2].label == "Anomaly Loot",
    "the list was not sorted by the text it draws")
-- The tiebreak makes the order TOTAL. Two seasons of "Anomaly Loot" is the
-- ordinary case, and without it those two swap places on every refresh.
check(sorted[1].id == "alpha" and sorted[2].id == "loot",
    "TWO KITS SHARING A LABEL ARE NOT ORDERED. They would trade places on "
    .. "every refresh, under a selection aimed at one of them.")
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
    for _, idx in ipairs(perm) do input[#input + 1] = KITS[idx] end
    local got = DMKitsTab.sorted(input)
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
check(#DMKitsTab.sorted(nil) == 0, "sorted faulted on nothing")

-- ---- the row tag ---------------------------------------------------------
-- "Which of these can be taken twice" is the question behind every farm, so it
-- is on the row rather than behind a click.

check(DMKitsTab.tagFor(KITS[1]):find("any time") ~= nil,
    "a freely repeatable kit did not say how often it comes round: "
    .. DMKitsTab.tagFor(KITS[1]))
check(DMKitsTab.tagFor(KITS[2]):find("days") ~= nil
      or DMKitsTab.tagFor(KITS[2]):find("hr") ~= nil,
    "a kit with a wait did not show it: " .. DMKitsTab.tagFor(KITS[2]))
check(DMKitsTab.tagFor(KITS[1]):find("xp") ~= nil, "the row did not name the kind")
check(DMKitsTab.tagFor(nil) == "", "tagFor faulted on nil")

-- ---- the summary ---------------------------------------------------------

local function joined(k) return table.concat(DMKitsTab.summaryOf(k), "\n") end

local loot = joined(KITS[2])
check(loot:find("delver") ~= nil, "the summary omitted a required flag")
check(loot:find("samples") ~= nil and loot:find("10") ~= nil,
    "the summary omitted a counter requirement or its bound")
check(loot:find("Base.Axe") ~= nil, "the summary omitted an item grant")
check(loot:find("roulette") ~= nil,
    "THE SUMMARY OMITTED A ROULETTE. It is the one grant whose contents are "
    .. "nowhere else on this screen, so a summary without it describes a kit "
    .. "that hands over less than it does.")

local zeta = joined(KITS[1])
check(zeta:find("nothing") ~= nil,
    "A KIT WITH NO REQUIREMENTS SAID NOTHING ABOUT THEM. Silence there reads "
    .. "as a section that failed to render, not as 'anyone may claim it'.")
check(zeta:find("Fitness") ~= nil, "the summary omitted an xp grant")

check(#DMKitsTab.summaryOf(nil) == 0, "summaryOf faulted on nothing")

-- ---- receive -------------------------------------------------------------

check(DMKitsTab.receive("KitList", { kits = KITS }) == true,
    "the catalogue reply was ignored")
check(#DMKitsTab.kits == 3, "the catalogue did not land")

sent = {}
check(DMKitsTab.receive("KitsStale", {}) == true, "a stale push was ignored")
check(sent[1] and sent[1].command == "kitList",
    "a stale push did not re-read the catalogue")

-- ---- THE SHARED ENVELOPE -------------------------------------------------

DMKitsTab.status = nil
check(DMKitsTab.receive("KitResult",
        { ok = true, command = "kitDefine", message = "Saved." }) == true,
    "this tab's own verb was not rendered")
check(DMKitsTab.status == "Saved.", "the message did not reach the footer")

DMKitsTab.status = nil
check(DMKitsTab.receive("KitResult",
        { ok = true, command = "kitClaim", message = "You received an axe." }) == false,
    "THE AUTHORING TAB RENDERED A CLAIM. An admin claiming a kit would watch "
    .. "the delivery report land in the authoring footer, under whatever kit "
    .. "they happened to have selected.")
check(DMKitsTab.status == nil, "a claim's message reached the authoring footer")

DMKitsTab.status = nil
check(DMKitsTab.receive("KitResult",
        { ok = true, command = "kitMine" }) == false,
    "the tab claimed the player's catalogue read")

-- An UNNAMED reply is not this tab's either. Silence beats guessing: the
-- server stamps every envelope, so an unstamped one came from somewhere that
-- has not been updated and rendering it would be rendering an unknown.
DMKitsTab.status = nil
check(DMKitsTab.receive("KitResult", { ok = true, message = "?" }) == false,
    "an unstamped reply was rendered as this tab's own")

-- A refusal reaches the footer as the reason, not as a blank success.
DMKitsTab.receive("KitResult",
    { ok = false, command = "kitDelete", reason = "no kit called 'x'" })
check(DMKitsTab.status == "no kit called 'x'", "a refusal lost its reason")

check(DMKitsTab.receive("SomethingElse", {}) == false,
    "an unrelated command was consumed")

-- ---- claimants -----------------------------------------------------------

DMKitsTab.selected = "loot"
DMKitsTab.claimants = nil
check(DMKitsTab.receive("KitClaimants", { id = "zeta", rows = { "a" } }) == true,
    "a claimant reply was not handled")
check(DMKitsTab.claimants == nil,
    "A CLAIMANT LIST FOR ANOTHER KIT WAS DRAWN. Answers arrive unordered "
    .. "against clicks, so this attributes one kit's claim history to another.")
DMKitsTab.receive("KitClaimants", { id = "loot", rows = { "a", "b" } })
check(DMKitsTab.claimants and #DMKitsTab.claimants.rows == 2,
    "the claimant list for the selected kit was dropped")

-- ---- the selection, across a refresh -------------------------------------

DMKitsTab.listBox = fakeBox()
DMKitsTab.kits = KITS
DMKitsTab.selected = "loot"
DMKitsTab.rebuild()
check(DMKitsTab.listBox.selected == 2,
    "the widget index was not re-derived from the remembered id: "
    .. tostring(DMKitsTab.listBox.selected))

-- The refresh that follows every action, with the catalogue in a new order -
-- which is what another admin adding a kit does.
DMKitsTab.kits = { KITS[2], KITS[1] }
DMKitsTab.rebuild()
check(DMKitsTab.selected == "loot",
    "THE SELECTION MOVED ACROSS A REFRESH. clear() drops the widget to row 1, "
    .. "so the next Delete would remove whichever kit happened to be first.")

-- Deleted out from under the selection: no selection, rather than sliding onto
-- a neighbour that Delete would then remove.
DMKitsTab.kits = { KITS[1] }
DMKitsTab.rebuild()
check(DMKitsTab.selected == nil,
    "the selection slid onto a neighbour after its own kit was deleted: "
    .. tostring(DMKitsTab.selected))
check(DMKitsTab.claimants == nil,
    "a claimant list outlived the kit it belonged to")

-- The catalogue reply clears a selection whose kit is gone even with no list
-- attached - which is exactly what a stale push from another admin does before
-- this tab has ever been opened.
DMKitsTab.listBox = nil
DMKitsTab.selected = "loot"
DMKitsTab.receive("KitList", { kits = { KITS[1] } })
check(DMKitsTab.selected == nil,
    "the selection stayed on a kit removed from under it, with no list "
    .. "attached to clean up after it")

-- ---- CLEAR ALL, from the row ---------------------------------------------
--
-- The event-rerun verb (owner, 2026-08-24): one act instead of duplicating the
-- kit or unpicking two hundred players. What is at risk is it firing WITHOUT
-- the confirmation, or firing on a kit nobody has claimed - a frightening
-- question asked about nothing teaches an admin to click through the dialog,
-- which is how the real one gets waved past later.

local asked, sentClear = nil, nil
DFConfirm.ask = function(text, fn) asked = text; sentClear = fn end
local realSend = RDNet.send
RDNet.send = function(_, command, args)
    if command == "kitForget" then sentClear = { id = args and args.id } end
end

DMKitsTab.totals = { [KITS[1].id] = 3 }
asked = nil
DMKitsTab.clearAll(KITS[1])
check(asked ~= nil,
    "CLEARING EVERY CLAIM DID NOT CONFIRM. It re-opens a reward to everybody "
    .. "who already took it.")
check(asked:find("3") ~= nil,
    "the confirmation did not say how many claims it would clear: " .. asked)
check(asked:find("one player") ~= nil,
    "the confirmation did not point at the per-player alternative, which is "
    .. "the thing an admin usually meant")

asked = nil
DMKitsTab.totals = {}
DMKitsTab.clearAll(KITS[1])
check(asked == nil,
    "A KIT WITH NO CLAIMS STILL ASKED. Asking a frightening question about "
    .. "nothing is how an admin learns to click through it.")

local okNil = pcall(DMKitsTab.clearAll, nil)
check(okNil, "clearAll faulted on no kit")
RDNet.send = realSend

print(string.format("DMKitsTab: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
