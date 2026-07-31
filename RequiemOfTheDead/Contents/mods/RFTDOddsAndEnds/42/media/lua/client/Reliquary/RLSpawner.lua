-- RLSpawner.lua - Reliquary: vanilla's admin item list, pointed at the box.
--
-- Filling a Reliquary used to mean typing "qty;fulltype" from memory into a
-- text box, which is the worst kind of admin UI: it fails silently and late,
-- after you have already committed, and only tells you the type was wrong once
-- the items did not appear. Vanilla already ships the right tool - the admin
-- panel's item list, with categories, search, filters and a quantity prompt -
-- so this borrows it whole rather than rebuilding a worse one.
--
-- The retarget is a two-line job because ISItemsListTable funnels EVERY add
-- path through one method: addItem(). The 1x / 2x / 5x buttons and the
-- quantity modal all call it (ISItemsListTable.lua:203-232). Override that and
-- every route redirects at once.
--
-- Its only other coupling is `self.viewer`, used in exactly two places
-- (lines 189 and 299) and only ever to read viewer.playerSelect.selected. One
-- of those is addItem, which we replace; the other is update(). A stub viewer
-- satisfies both, so no vanilla file is touched and no fork is maintained.
--
-- CAVEAT worth knowing: ISItemsListTable:new assigns ISItemsListTable.instance
-- = o, so opening this panel takes over that singleton from the admin panel's
-- own list. Harmless in practice - they are never usefully open at once - but
-- it is the one thing borrowing the class costs.

if isServer() then return end

require "ISUI/AdminPanel/ISItemsListTable"
require "OEShared"
require "RDNet"

RLSpawner = ISItemsListTable:derive("RLSpawner")

function RLSpawner:new(x, y, width, height, square)
    -- The stub stands in for the admin panel's player selector. selected = 1
    -- resolves to player 0 in update()'s getSpecificPlayer(selected - 1),
    -- which is the local player - correct, since staff is the one filling.
    local o = ISItemsListTable.new(self, x, y, width, height,
                                   { playerSelect = { selected = 1 } })
    setmetatable(o, self)
    self.__index = self
    o.square = square
    o.title = "Reliquary - fill"
    return o
end

-- The whole point. Vanilla sends items to a player; this sends them to the
-- box, through the same capability-gated, rate-limited RDNet command the
-- server already validates.
--
-- BUFFERED, NOT SENT PER CALL. Vanilla expresses quantity by CALLING addItem
-- in a loop - the 2x/5x buttons and the quantity modal fire up to 100 calls in
-- one frame - while reliquaryFill is registered at rate = 2 per second, so a
-- command per call would see everything past the second send bounced off the
-- rate limiter, one DFFeedback error per bounce, items silently short. The
-- calls are collected here and update() (below, runs every frame) flushes the
-- batch as ONE command: one click, one send, whatever the multiplier.
function RLSpawner:addItem(item)
    if not self.square then return end
    local full = item:getFullName()
    self.pendingFill = self.pendingFill or {}
    self.pendingFill[full] = (self.pendingFill[full] or 0) + 1
end

function RLSpawner:update()
    ISItemsListTable.update(self)
    if not self.pendingFill then return end
    local entries = {}
    for full, qty in pairs(self.pendingFill) do
        table.insert(entries, { qty = qty, type = full })
    end
    self.pendingFill = nil
    if #entries == 0 then return end
    RDNet.send(OEShared.MODULE, "reliquaryFill", {
        x = self.square:getX(), y = self.square:getY(), z = self.square:getZ(),
        entries = entries,
    })
end

function RLSpawner.open(square)
    local w, h = 900, 600
    local x = getCore():getScreenWidth() / 2 - w / 2
    local y = getCore():getScreenHeight() / 2 - h / 2
    local panel = RLSpawner:new(x, y, w, h, square)
    panel:initialise()
    panel:addToUIManager()

    -- createChildren builds an EMPTY table: the population step lives in the
    -- VIEWER, not the class - ISItemsListViewer:initList gathers getAllItems(),
    -- drops obsolete/hidden, and hands each tab its share via initList
    -- (ISItemsListViewer.lua:41-77). Standalone, nobody does that for us, so
    -- without this block the window opens looking plausible and permanently
    -- empty. After addToUIManager on purpose: instantiation is what creates
    -- self.datas, and initList writes into it.
    local all = {}
    local ok = pcall(function()
        local items = getAllItems()
        for i = 0, items:size() - 1 do
            local item = items:get(i)
            if not item:getObsolete() and not item:isHidden() then
                table.insert(all, item)
            end
        end
    end)
    if ok then panel:initList(all) end
    return panel
end
