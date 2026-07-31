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

if isServer() then return end

require "OEShared"
require "ISUI/ISInventoryPaneContextMenu"

RipIt = RipIt or {}
local RI = RipIt

-- Two sets, because they are two different asks. RIP reduces cloth to rags and
-- strips; CUT takes the things you cut rather than tear - belts and tanned
-- hides - down to leather strips.
--
-- CutLeatherInHalf is deliberately ABSENT: it subdivides a large hide into two
-- mediums rather than salvaging it, so it competes with CutUpLeather_* for the
-- same inputs and a "cut all" that hit it would quietly halve your hides
-- instead of stripping them.
RI.RIP_RECIPES = { "RipClothing", "RipDenimClothing", "RipSheets" }
RI.CUT_RECIPES = { "CutUpBelt", "CutUpLeather_Large", "CutUpLeather_Medium", "CutUpLeather_Small" }

function RI.isEnabled()
    return OEShared.enabled("RipItEnable")
end

-- Resolve names to CraftRecipe objects once per menu build. A name that no
-- longer exists is skipped rather than fatal, so a vanilla recipe rename
-- costs that one recipe instead of the whole option.
local function resolve(names)
    local out = {}
    local sm = getScriptManager()
    if not sm then return out end
    for _, name in ipairs(names) do
        local ok, recipe = pcall(function() return sm:getCraftRecipe(name) end)
        if ok and recipe then table.insert(out, recipe) end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Candidate search
-- ---------------------------------------------------------------------------

-- Intrinsic "may this item be destroyed at all" test. pcall'd as a whole
-- because it runs against every item in every open container on every
-- right-click: one odd item missing one accessor must not take out the menu.
--
-- Worn and held are checked against the PLAYER, deliberately. A corpse's
-- clothing sits in its container while the body still "wears" it, and that is
-- exactly what Rip All is for - the test is "am I wearing it", never "is
-- anything wearing it".
local function isRippable(item, playerObj)
    if not item then return false end
    local ok, safe = pcall(function()
        if item:isFavorite() then return false end                  -- the universal "hands off" marker
        if item:isEquipped() then return false end                  -- in your hands
        if playerObj:isEquippedClothing(item) then return false end -- on your back
        return true
    end)
    return ok and safe == true
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
    local ok, found = pcall(function()
        local owner = item:getContainer()
        if not owner then return false end
        for i = 0, containers:size() - 1 do
            if containers:get(i) == owner then return true end
        end
        return false
    end)
    return ok and found == true
end

-- Can this exact item feed this exact recipe, as a CONSUMED input?
local function feeds(recipe, item, playerObj)
    local ok, valid = pcall(function()
        if not CraftRecipeManager.isItemValidForRecipe(recipe, item, playerObj) then return false end
        if CraftRecipeManager.isItemToolForRecipe(recipe, item, playerObj) then return false end
        return true
    end)
    if not ok or not valid then return false end
    -- The recipe's own veto (IsNotWorn and friends). Absent on some recipes,
    -- so a failed call means "no opinion", not "no".
    local okTest, passed = pcall(function() return recipe:OnTestItem(item, playerObj) end)
    if okTest and passed == false then return false end
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
local function resolvedSetIsSafe(logic, item, playerObj)
    local ok, safe = pcall(function()
        local data = logic:getRecipeData()
        if not data then return false end
        local inputs  = data:getAllInputItems()
        local putBack = data:getAllPutBackInputItems()
        if not inputs then return false end

        local ourItemConsumed = false
        for i = 1, inputs:size() do
            local it = inputs:get(i - 1)
            local isTool = putBack and putBack:contains(it)
            if it and not isTool then
                if it == item then ourItemConsumed = true end
                if not isRippable(it, playerObj) then return false end
            end
        end
        return ourItemConsumed
    end)
    return ok and safe == true
end

-- Full confirmation: everything above plus tools in reach, skill, craft
-- surface, somewhere to put the output - and that the set the engine resolved
-- is the set we meant. Running the last gate here too keeps the count in the
-- menu label honest: it promises only what will actually be acted on.
local function canRun(playerObj, recipe, item, containers)
    local ok, result = pcall(function()
        local logic = HandcraftLogic.new(playerObj, nil, nil)
        logic:setContainers(containers)
        logic:setRecipeFromContextClick(recipe, item)
        if not logic:canPerformCurrentRecipe() then return false end
        return resolvedSetIsSafe(logic, item, playerObj)
    end)
    return ok and result == true
end

-- ONE walk, both sets. This runs on every right-click that reaches either menu
-- and canPerformCurrentRecipe is not free - it builds a HandcraftLogic per
-- candidate - so the cheap tests gate the expensive one, each item is examined
-- once, and RIP and CUT share the pass rather than each paying for their own.
--
-- Each item is paired with the FIRST recipe in its set that will take it.
-- First-match is intentional: a leather jacket answers to RipDenimClothing and
-- nothing else in the set today, but if that stops being true, the set order
-- declared above is the tiebreak and it is readable.
function RI.gatherAll(playerObj)
    local out = { rip = {}, cut = {} }
    if not playerObj then return out end
    local containers = ISInventoryPaneContextMenu.getContainers(playerObj)
    if not containers then return out end

    local sets = {
        { key = "rip", recipes = resolve(RI.RIP_RECIPES) },
        { key = "cut", recipes = resolve(RI.CUT_RECIPES) },
    }

    local seen = {}
    for i = 0, containers:size() - 1 do
        local cont = containers:get(i)
        local items = cont and cont:getItems()
        if items then
            for j = 0, items:size() - 1 do
                local item = items:get(j)
                local id = item and item:getID()
                if item and not seen[id] and isRippable(item, playerObj) then
                    for _, set in ipairs(sets) do
                        if seen[id] then break end
                        for _, recipe in ipairs(set.recipes) do
                            if feeds(recipe, item, playerObj) and canRun(playerObj, recipe, item, containers) then
                                seen[id] = true
                                table.insert(out[set.key], { item = item, recipe = recipe })
                                break
                            end
                        end
                    end
                end
            end
        end
    end
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
    local found = RI.gatherAll(playerObj)
    addOption(context, playerObj, found.rip,
              "ContextMenu_OE_RipAll", "ContextMenu_OE_RipAll_Tooltip", newTooltip)
    addOption(context, playerObj, found.cut,
              "ContextMenu_OE_CutAll", "ContextMenu_OE_CutAll_Tooltip", newTooltip)
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
