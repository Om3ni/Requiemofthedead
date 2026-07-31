-- LJSweep.lua - Lumberjack: fell a stand of trees without re-clicking each one.
--
-- WHAT VANILLA ALREADY DOES, so this does not reinvent it: one
-- ISChopTreeAction fells one whole tree. Its getDuration() returns -1, and
-- LuaTimedActionNew.update() (line 98) reads that as "take the duration from
-- the animation" - EXCEPT when the animation is looped, which Chop_tree is, in
-- which case there is no duration at all and the action simply runs, firing
-- ChopTree anim events, until isValid() fails: tree gone, endurance spent, axe
-- broken or unequipped. The auto-swinging is free. What is missing is doing
-- that to the NEXT tree, and knowing when to stop.
--
-- Which is why this file is mostly stop conditions. A queued chain of walk-and
-- -chop across a stand is unattended time in the woods, and while an individual
-- timed action aborts on damage, the QUEUE does not - it marches on to the next
-- tree with you bleeding. Aborting has to be explicit.
--
-- ONE TREE IN FLIGHT AT A TIME. The obvious build queues every tree up front;
-- this queues one, and on its completion re-evaluates and queues the next.
-- Costs nothing, and it means aborting is simply "do not queue another" rather
-- than clearing a queue out from under the engine. It also re-checks freshness
-- for free: a tree someone else felled while you worked is skipped rather than
-- swung at.
--
-- HOW THE CHAIN IS HELD TOGETHER - third design, with the receipts, because
-- the first two both failed SILENTLY and someone will be tempted back to them.
--
-- Design one used chop:setOnComplete. Not on ISBaseTimedAction - eight
-- unrelated subclasses each declare their own, which is exactly why it reads
-- like base API - so on ISChopTreeAction it is a nil call that pcall swallows
-- into a one-tree sweep.
--
-- Design two queued the engine's own ISQueueActionsAction behind the chop, and
-- died on MP to a race vanilla structurally cannot lose. A net-synced chop
-- ENDS by whichever of two packets lands first. If the ActionManager "done"
-- packet is first, forceComplete is set and the driver
-- (IsoGameCharacter.java:8284-8296) calls perform() - the queue advances and
-- a queued chain link runs. But the tree's REMOVAL travels on the world-sync
-- channel, and the moment the client tree's getObjectIndex() goes -1,
-- ISChopTreeAction:isValid() is false and the same driver takes its OTHER
-- exit: stop(), which is ISBaseTimedAction.stop, which is resetQueue - the
-- pending chain link cancelled with everything else. Removal-first = sweep
-- over after one tree, not one line in the log. In SP both signals are set in
-- the same call stack (animEvent forceCompletes the instant the index goes -1)
-- so the race does not exist there; in vanilla MP nothing is ever queued
-- behind a chop, so the race has no victim. Our chain was precisely the thing
-- that made it fatal.
--
-- So the chain is NOT A QUEUED THING AT ALL. The next step rides the chop's
-- own ending: perform and stop are wrapped on the INSTANCE (rawget-visible to
-- LuaTimedActionNew's pcalls; the metatable is untouched, so the
-- rawget("complete") probe that keeps the action net-synced still passes), and
-- success is decided by the WORLD, not the lifecycle - however the action
-- ended, tree down means continue, tree standing means a genuine interruption
-- and the sweep is over. Abort therefore stays structural: an interrupt stops
-- a chop with its tree still up, nothing new is ever queued, done.
--
-- One flag (ljAdvanced) makes advancing exactly-once, because the driver can
-- legally run perform() AND stop() for the same action in the same tick - the
-- two conditions at IsoGameCharacter.java:8285/8293 are not exclusive.
--
-- THE SELECTION SEAM: LJSweep.run takes a LIST of trees and does not care where
-- it came from. The radius scan below is one supplier. A drag-selected area is
-- another, and slots in without touching the engine.
--
-- Deliberately NOT a stop condition: zombie proximity. In this game it would
-- fire constantly, and "player took damage" catches the case that actually
-- matters - including the zombie that was already next to you when you began.

if isServer() then return end

require "OEShared"

Lumberjack = Lumberjack or {}
Lumberjack.Sweep = Lumberjack.Sweep or {}
local LJS = Lumberjack.Sweep

function LJS.isEnabled()
    return OEShared.enabled("LumberjackSweepEnable")
end

local function dial(name, fallback)
    local sv = SandboxVars and SandboxVars.RFTDOddsAndEnds
    local v = sv and tonumber(sv[name])
    if v == nil then return fallback end
    return v
end

-- ---------------------------------------------------------------------------
-- Stop conditions
-- ---------------------------------------------------------------------------

-- Checked BEFORE each tree, never mid-swing, so a sweep never abandons a
-- half-felled trunk - you always end on a clean boundary.
local function axeSpent(axe)
    if not axe then return true end
    local ok, spent = pcall(function()
        if axe:isBroken() then return true end
        local maxc = axe:getConditionMax()
        if not maxc or maxc <= 0 then return false end
        return (axe:getCondition() / maxc) <= dial("LumberjackSweepAxeFloor", 0.05)
    end)
    return (not ok) or spent == true
end

-- Without this the sweep does not politely pause: every remaining
-- ISChopTreeAction fails isValid instantly (it tests
-- isEnduranceSufficientForAction), so the whole queue evaporates in seconds
-- with trees still standing and nothing said about why.
-- There is no getEndurance(). Not on Stats, not on IsoGameCharacter, and no
-- shipped Lua file reads endurance at all - so the obvious guess compiles,
-- passes the syntax gate, and silently never fires. The live value is
-- Stats.get(CharacterStat.ENDURANCE) (Stats.java:76), a float registered
-- 0.0-1.0 (CharacterStat.java:17), with CharacterStat setExposed to Lua.
--
-- The fallback is the engine's own coarse answer and what
-- ISChopTreeAction:isValid already uses: isEnduranceSufficientForAction(),
-- which is simply "not at the maximum exhaustion moodle". If the dial cannot
-- be honoured, the sweep still stops - it just stops later than asked.
local function tooTired(playerObj)
    local ok, tired = pcall(function()
        local stats = playerObj:getStats()
        if stats and stats.get and CharacterStat and CharacterStat.ENDURANCE then
            return stats:get(CharacterStat.ENDURANCE) < dial("LumberjackSweepEnduranceFloor", 0.15)
        end
        return not playerObj:isEnduranceSufficientForAction()
    end)
    return (not ok) or tired == true
end

local function health(playerObj)
    local ok, hp = pcall(function() return playerObj:getBodyDamage():getOverallBodyHealth() end)
    return ok and hp or nil
end

-- ---------------------------------------------------------------------------
-- Axe selection - mirrors vanilla's own choice in ISWorldObjectContextMenu:
-- the best available chopper by TreeDamage, not the first one found.
--
-- RE-PICKED BEFORE EVERY TREE, ON PURPOSE (owner decision, 2026-07-31).
-- 42.20 scales getTreeDamage() by the blade's current sharpness
-- (HandWeapon.java:1523-1528), so as the axe in use dulls, the sweep hands
-- you the sharpest chopper you carry - with two similar axes it will even
-- alternate as each dulls below the other. That is the INTENDED model: the
-- sweep always swings the best tool you have, like a worker who owns both.
-- In play it can look like the axe was sharpened or repaired for free; it was
-- not - that is the spare arriving with its own bars. A sticky-axe version
-- (pick once, hold until spent, announce the handover) was built and rolled
-- back the same morning as over-engineering a non-problem. Do not rebuild it.
-- ---------------------------------------------------------------------------

local function isAxe(item)
    if not item then return false end
    local ok, yes = pcall(function() return item:hasTag(ItemTag.CHOP_TREE) and not item:isBroken() end)
    return ok and yes == true
end

-- getItems() is the top level of the main inventory only, which is the one
-- place a lumberjack's spare axe is NOT: it is in the bag. getAllEvalRecurse
-- descends into containers, which is why vanilla's own chop option uses it.
--
-- Seeded with the axe already in hand so that ties keep it. Strictly-better
-- still wins, but without the seed a second axe of identical TreeDamage sorts
-- ahead on iteration order alone and the sweep re-equips between every tree.
function LJS.bestAxe(playerObj)
    local best = nil
    local ok = pcall(function()
        local held = playerObj:getPrimaryHandItem()
        if isAxe(held) then best = held end

        local axes = playerObj:getInventory():getAllEvalRecurse(isAxe)
        if not axes then return end
        for i = 0, axes:size() - 1 do
            local item = axes:get(i)
            if not best or item:getTreeDamage() > best:getTreeDamage() then best = item end
        end
    end)
    if not ok then return nil end
    return best
end

-- ---------------------------------------------------------------------------
-- Selection supplier: everything within a radius. One of several possible.
-- ---------------------------------------------------------------------------

function LJS.findTrees(playerObj, radius)
    local found = {}
    local cell = getCell()
    if not cell then return found end
    local px, py, pz = math.floor(playerObj:getX()), math.floor(playerObj:getY()), math.floor(playerObj:getZ())

    for dx = -radius, radius do
        for dy = -radius, radius do
            local sq = cell:getGridSquare(px + dx, py + dy, pz)
            local ok, tree = pcall(function()
                if sq and sq:HasTree() then return sq:getTree() end
                return nil
            end)
            if ok and tree then
                table.insert(found, { tree = tree, square = sq, d = dx * dx + dy * dy })
            end
        end
    end
    -- Nearest first: less walking, and if a sweep is cut short you have cleared
    -- the ground around you rather than a scatter of stumps at the edges.
    table.sort(found, function(a, b) return a.d < b.d end)
    return found
end

-- ---------------------------------------------------------------------------
-- The engine
-- ---------------------------------------------------------------------------

local function halt(reason)
    if DFFeedback then DFFeedback.bad(reason) end
end

local function stillStanding(entry)
    local ok, alive = pcall(function()
        return entry.tree ~= nil and entry.tree:getObjectIndex() >= 0
    end)
    return ok and alive == true
end

-- step queues the walk and the chop; the chop's own ending calls step again
-- through the wrappers below. Forward declared for the closures.
local step

-- The single advance point, however the chop's life ended. Exactly-once via
-- ljAdvanced: perform() and stop() can BOTH run for one action in one tick
-- (the driver's two exit conditions are not exclusive), and advancing twice
-- would double-count the tree and queue the next one twice.
local function fellAndContinue(chop, state)
    if chop.ljAdvanced then return end
    chop.ljAdvanced = true
    state.felled = state.felled + 1
    step(state)
end

step = function(state)
    local playerObj = state.player
    if not playerObj then return end

    state.index = state.index + 1
    local entry = state.trees[state.index]
    if not entry then
        if DFFeedback and state.felled > 0 then
            DFFeedback.good(getText("IGUI_OE_SweepDone", state.felled))
        end
        return
    end

    -- Stop rules, in the order you would want to hear about them.
    local axe = LJS.bestAxe(playerObj)
    if axeSpent(axe) then return halt(getText("IGUI_OE_SweepStoppedAxe")) end
    if tooTired(playerObj) then return halt(getText("IGUI_OE_SweepStoppedTired")) end
    local hp = health(playerObj)
    if hp and state.health and hp < state.health then
        return halt(getText("IGUI_OE_SweepStoppedHurt"))
    end
    if hp then state.health = hp end

    if not stillStanding(entry) then return step(state) end  -- felled by someone else; move on

    -- Walk, equip, chop - queued in that order because that is the order they
    -- must run in, and vanilla's doChopTree walks before it equips too.
    local ok, reachable = pcall(function()
        -- walkAdj over a raw AdjacentFreeTileFinder.Find: it skips the walk
        -- entirely when you are already standing in range, which on a dense
        -- stand is most trees. keepActions=true because the default CLEARS the
        -- queue first: called from a perform wrapper that would only re-wipe
        -- an already-advanced queue, but called from stop's race path it would
        -- fire resetQueue a second time mid-teardown, and from the menu click
        -- it would eat whatever the player had queued.
        if not luautils.walkAdj(playerObj, entry.square, true) then return false end

        -- ISChopTreeAction:isValid tests the item in the PRIMARY HAND, not the
        -- inventory, so an unequipped axe rejects every swing.
        if playerObj:getPrimaryHandItem() ~= axe then
            ISWorldObjectContextMenu.equip(playerObj, playerObj:getPrimaryHandItem(), axe, true,
                                           not playerObj:getSecondaryHandItem())
        end

        local chop = ISChopTreeAction:new(playerObj, entry.tree)
        local basePerform, baseStop = chop.perform, chop.stop

        chop.perform = function(self)
            basePerform(self)
            fellAndContinue(self, state)
        end

        chop.stop = function(self)
            -- perform already advanced: the queue now holds the NEXT tree's
            -- walk and chop, and baseStop's resetQueue would wipe them. Fully
            -- swallowing loses nothing - perform already reset the job delta
            -- and the farming flag; the only work left in stop is the reset
            -- that must not happen. (Vanilla runs this stop-after-perform
            -- every SP chop - harmless there because nothing is ever queued
            -- behind a chop.)
            if self.ljAdvanced then return end
            baseStop(self)
            -- Stopped rather than performed - but if the tree is DOWN, that
            -- was the removal packet outrunning the done packet, not an
            -- interruption: keep going. A standing tree is a real interrupt
            -- (damage, player input, queue cleared) and ends the sweep.
            local ok, down = pcall(function()
                return self.tree == nil or self.tree:getObjectIndex() < 0
            end)
            if ok and down then fellAndContinue(self, state) end
        end

        ISTimedActionQueue.add(chop)
        return true
    end)

    -- Nothing was queued in either case - no walk is added before the bail out
    -- - so moving on cannot strand a half-built chain.
    if not ok then return end
    if not reachable then return step(state) end   -- no free tile beside it; leave it standing
end

-- Entry point. `trees` is a list of { tree =, square = } - the radius scan is
-- one way to build it, a selected area would be another.
function LJS.run(playerObj, trees)
    if not playerObj or not trees or #trees == 0 then return end
    step({ player = playerObj, trees = trees, index = 0, felled = 0, health = health(playerObj) })
end

-- ---------------------------------------------------------------------------
-- World context menu
-- ---------------------------------------------------------------------------

local function onFillWorldMenu(player, context, worldobjects, test)
    if test then return true end
    if not LJS.isEnabled() then return end
    local playerObj = getSpecificPlayer(player)
    if not playerObj then return end
    if not LJS.bestAxe(playerObj) then return end   -- no axe, no offer

    local radius = math.floor(dial("LumberjackSweepRadius", 8))
    local trees = LJS.findTrees(playerObj, radius)
    if #trees == 0 then return end

    local option = context:addOption(getText("ContextMenu_OE_ChopNearby", #trees),
                                     playerObj, LJS.run, trees)
    local tooltip = ISWorldObjectContextMenu.addToolTip()
    tooltip:setName(getText("ContextMenu_OE_ChopNearby_Tooltip"))
    tooltip.description = getText("ContextMenu_OE_ChopNearby_Desc", radius,
                                  math.floor(dial("LumberjackSweepAxeFloor", 0.05) * 100))
    option.toolTip = tooltip
end
Events.OnFillWorldObjectContextMenu.Add(onFillWorldMenu)
