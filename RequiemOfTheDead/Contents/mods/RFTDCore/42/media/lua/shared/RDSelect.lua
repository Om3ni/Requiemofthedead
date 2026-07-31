-- RDSelect.lua - multi-row selection model for the family's data tabs.
--
-- Lifted out of RPNecroTab, which had the only working multi-select anywhere in
-- the family (a ctrl-toggle set) and is now one of three consumers rather than a
-- one-off. Dragonfly's players tab and Reclaimation's vehicle tab are the others.
--
-- WHY THIS IS IN CORE AND NOT NEXT TO DFColumns, since that is the obvious
-- alternative and the wrong one: DFColumns DRAWS, this only decides membership.
-- There are no widgets here, no ISUI, no drawing, nothing reaching outside the
-- file - it is a set with range arithmetic. Its consumers happen to be UI today,
-- which no more makes it UI than RDJson is logging because RDLog is its only
-- caller. Contrast DFRegistry, which belongs with Dragonfly precisely because
-- it is an interface whose implementation (DFPanel) lives there; Core holding
-- that one creates a contract nothing enforces. This holds no such contract.
--
-- Every satellite hard-requires Core, so consumers just `require "RDSelect"` at
-- file scope. When this lived in Dragonfly, Reaper - which only SOFT-depends on
-- Dragonfly - had to defer creating its selection until build() to avoid
-- hard-breaking on a server without Dragonfly. That workaround is gone.
--
-- Semantics, matching every table UI a server admin has ever used:
--   plain click   select exactly this row, and make it the anchor
--   ctrl + click  toggle this row, and make it the anchor
--   shift + click select the whole span between the anchor and this row
--
-- The anchor is what makes shift feel right: after a shift-range, shifting to a
-- different row re-extends from the ORIGINAL anchor rather than creeping from
-- the last row touched. That is what people expect and what a naive "last
-- clicked" implementation gets wrong.
--
-- ENGINE-FREE, and there is no isServer() guard because there is nothing to
-- guard - the model touches no engine global at all, so it loads identically on
-- both sides and runs under stock Lua 5.1 with ZERO stubs in
-- tools/run-tests.bat. Keep it that way: no drawing, no widgets, no sending.
-- RDSelect.modifiers below is the single exception, and it is a function, so it
-- only reaches for the engine when a client actually calls it.
--
-- Ids are opaque. Vehicle ids, usernames and zombie online-ids all work.

RDSelect = RDSelect or {}
RDSelect.__index = RDSelect

function RDSelect.new()
    return setmetatable({ ids = {}, anchor = nil }, RDSelect)
end

-- Modifier state at click time. The ONLY engine-touching thing in this file,
-- and deliberately a function rather than something click() reads for itself -
-- that keeps the model pure, and the test suite simply never calls it. Each tab
-- used to roll its own isCtrlDown(); there is no engine global for it, only
-- isKeyDown() plus the Keyboard constants. pcall'd per modifier so a keycode
-- missing on some build degrades to "not held" rather than breaking clicking.
function RDSelect.modifiers()
    local ctrl, shift = false, false
    pcall(function()
        ctrl = isKeyDown(Keyboard.KEY_LCONTROL) or isKeyDown(Keyboard.KEY_RCONTROL)
    end)
    pcall(function()
        shift = isKeyDown(Keyboard.KEY_LSHIFT) or isKeyDown(Keyboard.KEY_RSHIFT)
    end)
    return ctrl == true, shift == true
end

function RDSelect:has(id)
    return self.ids[id] == true
end

function RDSelect:count()
    local n = 0
    for _ in pairs(self.ids) do n = n + 1 end
    return n
end

-- pairs(), NOT next(). B42's Kahlua registers no global `next` - BaseLib exposes
-- pcall/print/select/type/tostring/tonumber/getmetatable/setmetatable/error/
-- unpack/setfenv/getfenv/rawequal/rawset/rawget/collectgarbage/debugstacktrace/
-- bytecodeloader and nothing more - so `next(t) == nil` throws "Object tried to
-- call nil" the moment it runs in game. This had no callers yet, so it was latent
-- rather than broken; test_rdselect asserts it and passes, because the harness
-- runs real Lua 5.1 where next exists. The harness cannot catch this class of bug,
-- which is why the family documents the rule in RDWire, RQCastBar, RQSvDormant,
-- RCRegistry and DFPlayerRoles_Server as well.
function RDSelect:isEmpty()
    for _ in pairs(self.ids) do return false end
    return true
end

function RDSelect:clear()
    self.ids = {}
    self.anchor = nil
end

-- Select exactly one row (what a plain click does, exposed for callers that need
-- to force it - a refresh landing on a single result, say).
function RDSelect:only(id)
    self.ids = { [id] = true }
    self.anchor = id
end

function RDSelect:add(id)
    self.ids[id] = true
    if self.anchor == nil then self.anchor = id end
end

-- Selection in the order the rows are currently displayed, so a bulk action
-- applies top-to-bottom rather than in random hash order. Ids no longer present
-- are dropped, which is also how a stale selection cleans up after a refresh.
function RDSelect:list(ordered)
    local out = {}
    if ordered then
        for _, id in ipairs(ordered) do
            if self.ids[id] then out[#out + 1] = id end
        end
    else
        for id in pairs(self.ids) do out[#out + 1] = id end
    end
    return out
end

local function indexOf(ordered, id)
    if not ordered then return nil end
    for i, v in ipairs(ordered) do
        if v == id then return i end
    end
    return nil
end

-- The one entry point a list widget calls from onMouseDown.
--   id      : the row that was clicked
--   ordered : ids in display order, needed only for shift ranges
--   ctrl    : ctrl held
--   shift   : shift held
-- Returns true when the selection changed, so a caller can skip redundant work
-- (re-highlighting a zombie, rebuilding a detail pane).
function RDSelect:click(id, ordered, ctrl, shift)
    if id == nil then return false end

    -- Shift with no anchor behaves as a plain click rather than doing nothing:
    -- clicking into an empty list with shift held should still select something,
    -- or the UI feels broken.
    if shift and self.anchor ~= nil then
        local a = indexOf(ordered, self.anchor)
        local b = indexOf(ordered, id)
        if a and b then
            if a > b then a, b = b, a end
            -- A range REPLACES the selection. Additive ranges are what produce
            -- the "I clicked twice and now forty things are doomed" surprise on
            -- a destructive action.
            self.ids = {}
            for i = a, b do self.ids[ordered[i]] = true end
            return true
        end
        -- Anchor filtered out of the current list: fall through to a plain click
        -- rather than silently doing nothing.
    end

    if ctrl then
        if self.ids[id] then self.ids[id] = nil else self.ids[id] = true end
        self.anchor = id
        return true
    end

    self:only(id)
    return true
end

-- Drop ids no longer in the list (post-refresh, post-filter). Returns how many
-- were dropped so a caller can tell the admin their selection shrank, rather
-- than letting a bulk action quietly apply to fewer rows than they can see.
function RDSelect:prune(ordered)
    local keep, dropped = {}, 0
    local present = {}
    for _, id in ipairs(ordered or {}) do present[id] = true end
    for id in pairs(self.ids) do
        if present[id] then keep[id] = true else dropped = dropped + 1 end
    end
    self.ids = keep
    if self.anchor ~= nil and not present[self.anchor] then self.anchor = nil end
    return dropped
end

return RDSelect
