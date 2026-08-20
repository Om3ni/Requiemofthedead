-- SPDX-License-Identifier: GPL-3.0-or-later
-- RIClient.lua - RIPIT: rip and cut everything in the containers you have open.
--
-- Build 42 moved ripping into the crafting UI and left nothing on the
-- inventory right-click, so salvaging a corpse's wardrobe is a trip through
-- the craft panel per garment. RIPIT puts one option back on the menu you are
-- already in - your inventory, or the loot window - and runs the whole visible
-- pile in one go.
--
-- SCOPE IS THE PANELS YOU HAVE OPEN, exactly. ISInventoryPaneContextMenu
-- .getContainers returns the backpacks of the inventory page plus those of the
-- loot page (and skips IsoThumpables locked to someone else), which is already
-- "everything loaded" - so there is no world scan, no radius, and nothing gets
-- ripped that you cannot currently see. Loot a corpse and its clothes are in
-- scope because its container is open, not because we went looking for bodies.
--
-- IT ONLY ASKS THE ENGINE. Rather than carrying a table of item tags that
-- would rot on the next build and miss every modded garment, each candidate is
-- put to the recipe itself:
--   CraftRecipeManager.isItemValidForRecipe  - can this item feed this recipe
--   CraftRecipeManager.isItemToolForRecipe   - ...or is it the TOOL (the flags
--                                              ToolLeft/ToolRight). This is the
--                                              guard that stops RIPIT cutting
--                                              up the scissors it is holding.
--   recipe:OnTestItem                        - the recipe's own veto hook
--   HandcraftLogic:canPerformCurrentRecipe   - skill, tools, surface, space
-- Modded clothing that carries the vanilla rip tags is picked up for free.
--
-- Execution is vanilla's own path, lifted from ISInventoryPaneContextMenu
-- .OnNewCraft: build a HandcraftLogic, point it at the recipe and the item,
-- move inputs to the player if the recipe cannot be done from the floor, then
-- ISEntityUI.HandcraftStart and queue. That means MP sync, XP, tool wear and
-- item mappers all behave exactly as they do from the craft panel, because it
-- IS the craft panel's route.
--
-- Prior art: "Rip All Clothes" by Notone (Workshop 3633056642) does the
-- world-menu version of this and is what confirmed HandcraftLogic as the sane
-- approach rather than reimplementing the rip maths. No code taken - the path
-- below is vanilla's OnNewCraft - but the pointer saved a day and is worth the
-- line.
--
-- Speed: the recipes below are also listed in ActionSpeed's RECIPE_VAR under
-- ASRipIt. That duplication is deliberate - house rule is that no module may
-- depend on a sibling, so each carries its own list and either can be deleted
-- outright. If you add a recipe here, add it there too, or it will run at
-- vanilla speed and nobody will know why.
--
-- ASRipIt is deliberately a SUPERSET: it still scales CutUpBelt and the three
-- CutUpLeather_* that this file dropped. Those recipes did not go away, only
-- the bulk button for them did (see the note on RIP_RECIPES), and you still
-- craft them by hand from the panel - so they should still run at the tuned
-- speed. Do not "resync" the two lists by deleting them there.

if isServer() then return end

require "OEShared"
require "RDShared"
require "ISUI/ISInventoryPaneContextMenu"

RipIt = RipIt or {}
local RI = RipIt

-- One set. Ripping only.
--
-- THERE WAS A CUT SET AND IT WAS A TRAP - do not add it back without reading
-- this. It listed CutUpBelt and CutUpLeather_Large/Medium/Small, and the reason
-- no such feature exists anywhere is that the inputs are not junk:
--
--   base:scrapasbelt, the whole CutUpBelt population, is seven items and six of
--   them are gear you went looking for - HolsterDouble, Holster_Hide, and the
--   four AmmoStrap_* bandoliers. Exactly one, Belt2, is a plain belt. A "cut
--   all" button is therefore mostly an offer to turn your holsters and
--   bandoliers into a buckle and a leather strip each. The recipe's IsEmpty
--   flag only spares them while they are loaded, so an empty bandolier between
--   runs is fair game.
--
--   CutUpLeather_* are Tags = AnySurfaceCraft at time = 300, and tanned hide is
--   a scarce multi-use input. You are already standing at a bench with the
--   craft panel open when you touch those; there is no pile to sweep.
--
-- Ripping is worth it precisely because it has the pile the cut set lacks: a
-- corpse wardrobe is bulk junk with no alternative use and a 40-tick recipe.
--
-- Leather clothing is NOT lost with the cut set gone - RipDenimClothing carries
-- an itemMapper that turns Jacket_Leather, Trousers_LeatherBlack and the rest
-- straight into LeatherStrips. Shoes genuinely lost their leather salvage
-- around 42.11 and no recipe below brings it back.
RI.RIP_RECIPES = { "RipClothing", "RipDenimClothing", "RipSheets" }

function RI.isEnabled()
    return OEShared.enabled("RipItEnable")
end

-- Resolve the fixed vanilla names to CraftRecipe objects once per menu build.
-- A recipe removed by a future build is the ordinary nil result and costs only
-- that recipe. These are suite-owned Base recipe names, not arbitrary mod
-- input; ScriptManager performs the two registry lookups directly
-- (ScriptManager.java:975-982).
local function resolve(names)
    local out = {}
    local sm = getScriptManager()
    if not sm then return out end
    for _, name in ipairs(names) do
        local recipe = sm:getCraftRecipe(name)
        if recipe then table.insert(out, recipe) end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Candidate search
-- ---------------------------------------------------------------------------

-- Intrinsic "may this item be destroyed at all" test. No guard - the premise
-- "one odd item missing one accessor" is false. All three accessors exist on
-- every item and every player by construction: isFavorite and isEquipped are
-- declared on InventoryItem itself with zero overrides tree-wide (:3365-3367,
-- :3166-3181), and isEquippedClothing on IsoGameCharacter, IsoPlayer's own
-- superclass (IsoGameCharacter.java:9388-9391) - it only scans the player's
-- wornItems by identity, so an item in a corpse's container answers false
-- safely (WornItems.java:200-207). None of them can throw, and being exposed
-- methods, even a body fault would reach us as nil, not an error.
--
-- Worn and held are checked against the PLAYER, deliberately. A corpse's
-- clothing sits in its container while the body still "wears" it, and that is
-- exactly what Rip All is for - the test is "am I wearing it", never "is
-- anything wearing it".
local function isRippable(item, playerObj)
    if not item then return false end
    if item:isFavorite() then return false end                  -- the universal "hands off" marker
    if item:isEquipped() then return false end                  -- in your hands
    if playerObj:isEquippedClothing(item) then return false end -- on your back
    return true
end

-- Is this item sitting in one of the panels the player currently has open?
--
-- During the menu walk this is true by construction. It earns its keep in
-- RI.run, which executes over many seconds while the queue drains: a container
-- can be closed, a corpse can rot away, another player can take the garment,
-- or the player can simply walk out of range. Re-asking at execution time is
-- the difference between "acts on what you had open" and "acts on what you had
-- open several seconds ago".
local function inOpenContainers(item, containers)
    if not item or not containers then return false end
    -- getContainer is a field return (safe-listed) and the walk is a
    -- bounds-checked ArrayList scan - nothing here can throw.
    local owner = item:getContainer()
    if not owner then return false end
    for i = 0, containers:size() - 1 do
        if containers:get(i) == owner then return true end
    end
    return false
end

-- Can this exact item feed this exact recipe, as a CONSUMED input?
--
-- No guards, and the old reason was wrong twice. Both statics resolve through
-- getValidInputScriptForItem (:275-282) into isItemValidForInputScript, whose
-- consumeInputItem call is at :306 (isItemToolForRecipe :294-297,
-- isItemValidForRecipe :299-302) - but "mappers can throw in there" is
-- refuted: mappers are parsed script DATA with zero Lua in them
-- (InputScript.java:787-799; no Lua invocation anywhere in OutputMapper /
-- OverlayMapper / InputScript), and the one mod-supplied Lua hook on the path,
-- OnTest, is invoked through protectedCallBoolean INSIDE the engine
-- (CraftRecipe.java:1027-1047 at :1042) - a throwing mod hook reads as false
-- there and can never propagate. Every entry point is an exposed static, so
-- even an internal fault reaches us as nil, which the boolean tests below
-- already treat as "no".
--
-- OnTestItem likewise cannot throw: it is a method every CraftRecipe carries
-- (the old "absent on some recipes" conflated the method with the optional
-- OnTest HOOK, whose absence makes it return true at :1046).
local function feeds(recipe, item, playerObj)
    if not CraftRecipeManager.isItemValidForRecipe(recipe, item, playerObj) then return false end
    if CraftRecipeManager.isItemToolForRecipe(recipe, item, playerObj) then return false end
    -- The recipe's own veto (IsNotWorn and friends). nil means "no opinion".
    if recipe:OnTestItem(item, playerObj) == false then return false end
    return true
end

-- THE LAST GATE, used by both phases. setRecipeFromContextClick is asked to
-- pin our item, but the logic is also handed every open container so it can
-- find tools - so the set it finally resolves is the engine's decision, not
-- ours. This re-reads that decision and refuses it unless:
--
--   * the item we actually chose is in the consumed set, and
--   * nothing else in the consumed set is something we would have skipped.
--
-- The consumed set is inputs MINUS put-backs: put-backs are the tools, handed
-- straight back, so the scissors appearing in the inputs is normal and must not
-- trip this. Without this check, the one way a favourite or a worn garment
-- could still be destroyed is the logic quietly substituting it for our pick -
-- so this guards exactly the failure you would never forgive.
-- CraftRecipeData.getAllNotKeepInputItems() is the list, and it took being
-- wrong TWICE to land on it. Both wrong answers failed the same way - an empty
-- list, every candidate rejected, no menu option at all, and not one error in
-- the log - so neither looked like a bug. Read this before "improving" it:
--
--   getAllInputItems() minus getAllPutBackInputItems() reads as "everything,
--   minus the tools handed back". It is not. getAllPutBackInputItems keeps an
--   input unless `dontPutBack()`, which is the DontPutBack FLAG, and none of
--   these recipes set it - so put-back contains every input, the difference is
--   empty, and nothing is ever rippable.
--
--   getAllDestroyInputItems() reads as "what gets consumed". It is not.
--   ItemApplyMode has THREE values - Normal, Keep, Destroy (ItemApplyMode.java)
--   - and isDestroy() is `mode == Destroy` exactly (InputScript.java:209).
--   Destroy is an opt-in special case; an ordinary consumed input is the
--   DEFAULT, Normal (InputScript.java:74). RipClothing declares no mode, so it
--   is Normal, so getAllDestroyInputItems() is empty for it forever. This is
--   the one that shipped, and the diagnostic that caught it read
--   `inputs=1 doomed=0` - applied items present, destroy-filtered list empty.
--
-- getAllNotKeepInputItems() (CraftRecipeData.java:1661) filters on
-- `inputScript.isKeep()`, so it drops only mode:keep - which IS how the tools
-- are declared (`tags[base:scissors;base:sharpknife] mode:keep`) - and keeps
-- Normal and Destroy alike. That is the consumed set, tools excluded, which is
-- exactly the question this gate is asking.
-- No guard - the nil tests below were always the whole mechanism. Both
-- accessors are exposed methods, so an internal fault reaches us as nil, and
-- getAllNotKeepInputItems cannot even do that ordinarily: it allocates and
-- returns a fresh list every call (CraftRecipeData.java:1661-1669). "A throw
-- must read as not safe" was describing a thing that cannot happen; nil
-- reading as not safe is what actually does.
local function resolvedSetIsSafe(logic, item, playerObj)
    local data = logic:getRecipeData()
    if not data then return false end
    local doomed = data:getAllNotKeepInputItems()
    if not doomed then return false end

    local ourItemConsumed = false
    for i = 1, doomed:size() do
        local it = doomed:get(i - 1)
        if it then
            if it == item then ourItemConsumed = true end
            if not isRippable(it, playerObj) then return false end
        end
    end
    return ourItemConsumed
end

-- Full confirmation for the MENU: tools in reach, skill, craft surface,
-- somewhere to put the output - and that the set the engine resolved is the
-- set we meant. The safety gate belongs here as well as at execution now that
-- it is built on getAllDestroyInputItems and actually answers the question; it
-- keeps the count in the label honest rather than promising work that will be
-- refused a moment later.
-- The surface is set here for PARITY, and right now it changes nothing you can
-- see - say so plainly rather than let a future reader mistake it for load
-- bearing. All three RIP recipes are Tags = InHandCraft, which never consults
-- it.
--
-- It stays because the menu must not be stricter than the executor it exists to
-- predict. Leaving setIsoObject unset does not mean "no surface bonus", it means
-- AnySurfaceCraft recipes are refused outright: canPerformCurrentRecipe zeroes
-- itself on `isAnySurfaceCraft() and not isCharacterInRangeOfWorkbench()`
-- (BaseCraftingLogic.java:876), and HandcraftLogic overrides that range test to
-- `isoObject ~= nil and dist < 3` (HandcraftLogic.java:226) - false forever with
-- no isoObject. That is how the old cut set could offer a belt and never a hide.
-- Both the engine's own equivalent (CraftRecipeManager.getUniqueRecipeItems,
-- line 1113) and RI.run below set it. Add one AnySurfaceCraft recipe above and
-- this line is the difference between working and silently absent.
-- No guard. The one lane in this chain that genuinely throws is the
-- CONSTRUCTOR - ConstructorCaller does not catch and LuaJavaInvoker rethrows -
-- and both ctor bodies were read: with a valid player and nil bench/surface
-- nothing derefs beyond storage (HandcraftLogic.java:43-54 guards the bench;
-- BaseCraftingLogic.java:83-100 never derefs the player), and vanilla itself
-- constructs this from Lua bare with the same shape
-- (ISHandCraftPanel.lua:347-360). Everything after it is exposed methods:
-- findCraftSurface legitimately returns nil (:349-369) and setIsoObject
-- stores it; an internal fault in canPerformCurrentRecipe reaches us as nil,
-- which the `not` below already reads as "cannot".
local function canRun(playerObj, recipe, item, containers)
    local logic = HandcraftLogic.new(playerObj, nil, nil)
    logic:setIsoObject(logic:findCraftSurface(playerObj, 2))
    logic:setContainers(containers)
    logic:setRecipeFromContextClick(recipe, item)
    if not logic:canPerformCurrentRecipe() then return false end
    return resolvedSetIsSafe(logic, item, playerObj)
end

-- ONE walk, both sets. This runs on every right-click that reaches either menu
-- and canPerformCurrentRecipe is not free - it builds a HandcraftLogic per
-- candidate - so the cheap tests gate the expensive one and each item is
-- examined once.
--
-- Each item is paired with the FIRST recipe that will take it. First-match is
-- intentional: a leather jacket answers to RipDenimClothing and nothing else
-- in the set today, but if that stops being true, the set order declared above
-- is the tiebreak and it is readable.
function RI.gatherAll(playerObj)
    local out = {}
    if not playerObj then return out end
    local containers = ISInventoryPaneContextMenu.getContainers(playerObj)
    if not containers then return out end

    local recipes = resolve(RI.RIP_RECIPES)

    local seen = {}
    for i = 0, containers:size() - 1 do
        local cont = containers:get(i)
        local items = cont and cont:getItems()
        if items then
            for j = 0, items:size() - 1 do
                local item = items:get(j)
                local id = item and item:getID()
                if item and not seen[id] and isRippable(item, playerObj) then
                    for _, recipe in ipairs(recipes) do
                        if feeds(recipe, item, playerObj) and canRun(playerObj, recipe, item, containers) then
                            seen[id] = true
                            table.insert(out, { item = item, recipe = recipe })
                            break
                        end
                    end
                end
            end
        end
    end
    -- Silent unless RFTDCore.Debug is on. The option simply not appearing is
    -- indistinguishable from "nothing here is rippable", so this is the only
    -- way to tell an empty room from a broken gate without a second boot.
    RDShared.dbg("RIPIT: containers=" .. tostring(containers:size())
        .. " rip=" .. tostring(#out))
    return out
end

-- ---------------------------------------------------------------------------
-- Execution - vanilla's OnNewCraft path, once per item
-- ---------------------------------------------------------------------------

local function onCraftComplete(logic)
    if logic and logic.stopCraftAction then logic:stopCraftAction() end
end


function RI.run(playerObj, entries)
    if not playerObj or not entries then return end
    local containers = ISInventoryPaneContextMenu.getContainers(playerObj)

    for _, entry in ipairs(entries) do
        local item, recipe = entry.item, entry.recipe
        -- Re-check at execution time: the queue runs over many seconds and the
        -- pile can change under us - another player loots the corpse, the
        -- scissors break, a container fills up, the player closes the window
        -- or walks away. Both tests are repeats of the menu-time ones, and both
        -- are repeated precisely because the answer can have changed since.
        if item and recipe and isRippable(item, playerObj)
           and inOpenContainers(item, containers) then
            -- RETAINED - unlike canRun's chain, this one has real Lua-lane
            -- throws. `logic:getRecipeData():getAllInputItems()` is a two-step
            -- chain: an internal fault in the first step hands back nil and
            -- the second call is then an error a pcall CAN catch. The transfer
            -- and queue calls are vanilla Lua with genuine nil-derefs
            -- (ISTimedActionQueue.lua:158 throws on a nil action; the transfer
            -- helpers deref container parents). And this is one item of a
            -- queued batch running over seconds: one failing must cost itself,
            -- never the rest of the queue - the batch-member class exactly.
            pcall(function()
                local logic = HandcraftLogic.new(playerObj, nil, nil)
                logic:setIsoObject(logic:findCraftSurface(playerObj, 2))
                logic:setContainers(containers)
                logic:setRecipeFromContextClick(recipe, item)

                if logic:canPerformCurrentRecipe() then
                    local inputs = logic:getRecipeData():getAllInputItems()
                    local putBack = logic:getRecipeData():getAllPutBackInputItems()

                    if logic:isUsingRecipeAtHandBenefit() then
                        local atHand = logic:getUsingRecipeAtHandItem()
                        if atHand then
                            inputs:add(atHand)
                            putBack:add(atHand)
                        end
                    end

                    -- Recipes that cannot be done from the floor need their
                    -- inputs in the player's own inventory first; tools get
                    -- handed back afterwards.
                    local returnToContainer = {}
                    if not recipe:isCanBeDoneFromFloor() then
                        local moved = false
                        for k = 1, inputs:size() do
                            local it = inputs:get(k - 1)
                            if it and it:getContainer() ~= playerObj:getInventory() then
                                ISInventoryPaneContextMenu.transferIfNeeded(playerObj, it)
                                if putBack and putBack:contains(it) then
                                    table.insert(returnToContainer, it)
                                end
                                moved = true
                            end
                        end
                        if moved then logic:setRecipeFromContextClick(recipe, item) end
                    end

                    -- Checked AFTER the transfer re-pin, because that re-pin is
                    -- itself a fresh resolve and could land somewhere else.
                    if resolvedSetIsSafe(logic, item, playerObj) then
                        local action = ISEntityUI.HandcraftStart(playerObj, logic, false, true)
                        if action then
                            action:setOnComplete(onCraftComplete, logic)
                            logic:startCraftAction(action)
                        end
                    end

                    ISCraftingUI.ReturnItemsToOriginalContainer(playerObj, returnToContainer)
                end
            end)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Context menu
-- ---------------------------------------------------------------------------

-- The count goes in the label on purpose: queuing is uncapped, so the number
-- is the only warning you get before committing to it. Naming the first few
-- items in the tooltip is the second.
--
-- newTooltip is passed in because the two menus keep separate tooltip pools -
-- ISInventoryPaneContextMenu.addToolTip vs ISWorldObjectContextMenu.addToolTip
-- - and borrowing the wrong one leaks a tooltip into the wrong pool's reset.
local function addOption(context, playerObj, entries, labelKey, tooltipKey, newTooltip)
    if #entries == 0 then return end
    local option = context:addOption(getText(labelKey, #entries), playerObj, RI.run, entries)
    local tooltip = newTooltip()
    tooltip:setName(getText(tooltipKey))
    local lines = ""
    for i, entry in ipairs(entries) do
        if i <= 10 then
            lines = lines .. " - " .. entry.item:getDisplayName() .. " <LINE> "
        else
            lines = lines .. getText("ContextMenu_OE_RipIt_More", #entries - 10)
            break
        end
    end
    tooltip.description = lines
    option.toolTip = tooltip
end

-- BOTH MENUS, ONE BEHAVIOUR. The inventory/loot menu is where you already are
-- when you are sorting a corpse's pockets; the world menu is where your hand
-- goes when you are standing over the pile and have not opened anything yet.
-- Offering only one means guessing which mood the player is in.
--
-- The scope is identical either way, and that is on purpose rather than a
-- shortcut: both are bounded by getContainers, so the world option can never
-- reach further than the loot window would. Right-clicking the ground does not
-- give you longer arms - it just saves you the click into the panel.
local function offer(context, playerObj, newTooltip)
    addOption(context, playerObj, RI.gatherAll(playerObj),
              "ContextMenu_OE_RipAll", "ContextMenu_OE_RipAll_Tooltip", newTooltip)
end

local function invTooltip() return ISInventoryPaneContextMenu.addToolTip() end
local function worldTooltip() return ISWorldObjectContextMenu.addToolTip() end

local function onFillInventoryMenu(player, context, items)
    if not RI.isEnabled() then return end
    local playerObj = getSpecificPlayer(player)
    if not playerObj then return end
    offer(context, playerObj, invTooltip)
end
Events.OnFillInventoryObjectContextMenu.Add(onFillInventoryMenu)

local function onFillWorldMenu(player, context, worldobjects, test)
    if test then return true end
    if not RI.isEnabled() then return end
    local playerObj = getSpecificPlayer(player)
    if not playerObj then return end
    offer(context, playerObj, worldTooltip)
end
Events.OnFillWorldObjectContextMenu.Add(onFillWorldMenu)

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
