-- SPDX-License-Identifier: GPL-3.0-or-later
-- ICClient.lua - Inventory Collapse: fold the equipped and hotbar blocks out of
-- your own inventory list, independently.
--
-- MOVED OUT OF CORE 2026-07-31, alongside ContainerOrder/COClient.lua and for the
-- same reason. It was parked in RFTDCore as RDEquippedCollapse.lua waiting on RFTD
-- Wardrobe to be scoped, and Core is hard-required by every mod in the family, so
-- it could never be switched off.
--
-- IT IS NOT DORMANT THE WAY ITS SIBLING WAS, and that distinction is worth being
-- precise about because it is what makes this a collision risk rather than a
-- tidiness question. Only the FILTERING is conditional - applyToPane returns at
-- `#active == 0` unless the player has actually collapsed a block. Registration is
-- not: registerHandlers() calls ISInventoryWindowContainerControls.AddHandler at
-- install time, unconditionally, so every player gets two buttons added to the
-- inventory control row forever. The refreshContainer wrap is unconditional too.
-- That control row is contested surface - it is packed and re-arranged by the same
-- third-party UI mods (Clean UI and friends) that this file already patches BY
-- NAME below, which is the tell. Two permanent buttons on someone else's arranged
-- row, from a mod nobody can uninstall, is the same shape of problem that got
-- reported against RDContainerOrder.
--
-- So the kill switch here does its work in shouldBeVisible(): with
-- InventoryCollapseEnable off, the handlers stay registered (vanilla's AddHandler
-- has no unregister, and SandboxVars is not up when it runs) but report themselves
-- invisible, so no button is ever laid out and the row is untouched.
--
-- WHAT VANILLA ALREADY DOES, so this file does not redo it: B42 sorts equipped
-- items to the BOTTOM of the pane by itself. All four of its comparators open with
--     if a.equipped and not b.equipped then return false end
-- and it is vanilla, not CleanUI, that tags entries by rewriting the group key to
-- "equipped:"/"keyring:"/"hotbar:" in refreshContainer. So every itemslist entry
-- already carries .equipped and .inHotbar, and "move equipped below" needs no code
-- at all. What is missing is the ability to COLLAPSE those blocks.
--
-- TWO BLOCKS, NOT ONE, and this is the important part. Current vanilla tags them
-- differently and it is easy to get wrong:
--
--     if isEquipped[item] then ... equipped = true          -- worn, hands, keyring
--     if self.hotbar then
--         inHotbar = isInHotbar[item]
--         if inHotbar and not equipped then ... end          -- NOTE: no equipped = true
--     end
--
-- A hotbar-attached item is therefore inHotbar WITHOUT being equipped. An earlier
-- version of this file filtered on .equipped alone, which silently left every
-- holstered weapon on screen. Older forks (CleanUI's copy) DO set equipped = true
-- for hotbar items, so the two flags overlap there. The classification below is
-- written to be correct under both:
--     hotbar group = inHotbar
--     worn group   = equipped AND NOT inHotbar
--
-- That flag difference also moves them: with equipped false, `inHotbar` wins the
-- comparators' second tiebreak, so the hotbar block sorts to the HEAD of the list
-- while the equipped block sits at the TAIL. Removing from the head shifts every
-- row after it, which is why selection is remapped by item identity below rather
-- than clamped - a clamp only works for tail truncation.
--
-- NO FORK. Two hooks, both narrow:
--   * buttons register through ISInventoryWindowContainerControls.AddHandler,
--     which is VANILLA API (media/lua/client/ISUI/InventoryWindow/) - CleanUI only
--     extends that registry, so they show up in both worlds.
--   * the hiding wraps refreshContainer on the pane CLASS TABLE, patching all
--     three known tables by reference, because CleanUI swaps the live
--     ISInventoryPane between two classes at runtime.
--
-- The two CleanUI_* probes in patchAll are kept although CleanUI was retired from
-- the server collection on 2026-07-31 (its logic reimplemented in-house, and
-- Core's DFPatch_CleanUI deleted in the same cleanup). They are rawget lookups
-- that return nil and cost one comparison, so keeping them means a client who
-- runs CleanUI on their own is still covered.
--
-- Preferences live in player modData, not a written file: since 42.20 getFileWriter
-- refuses anything outside ini/cfg/txt/log (see RDShared.EXT_*), and a UI toggle is
-- not worth the compound-extension dance.

if isServer() then return end

require "OEShared"
require "ISUI/InventoryWindow/ISInventoryWindowControlHandler"
require "ISUI/InventoryWindow/ISInventoryWindowContainerControls"

InventoryCollapse = InventoryCollapse or {}

-- ---------------------------------------------------------------------------
-- Kill switch
-- ---------------------------------------------------------------------------

-- Read at use time, not at load: SandboxVars is not up when this file is walked,
-- and OEShared.enabled defaults ON until it is. Same idiom as RipIt/RIClient.
function InventoryCollapse.isEnabled()
    return OEShared.enabled("InventoryCollapseEnable")
end

-- Group definitions. Adding a third block here is a table entry plus one
-- AddHandler call at the bottom; nothing else in the file is group-specific.
--
-- modKey values are deliberately still "RD*": they are live player-modData keys,
-- and anyone who has already collapsed a block on the RotD server has their
-- preference stored under them. Renaming to match the new module prefix would
-- silently reset all of them for nothing but cosmetic consistency.
InventoryCollapse.GROUPS = {
    worn = {
        key      = "worn",
        modKey   = "RDEquippedCollapsed",
        label    = "Equipped",
        order    = 1,
        -- Worn clothing, jewellery, hand items, keyrings.
        matches  = function(v) return v.equipped == true and v.inHotbar ~= true end,
        -- Worn/held encumbrance is the equipped multiplier.
        weightOf = "getEquippedWeight",
    },
    hotbar = {
        key      = "hotbar",
        modKey   = "RDHotbarCollapsed",
        label    = "Hotbar",
        order    = 2,
        matches  = function(v) return v.inHotbar == true end,
        -- Attached items have their own encumbrance rule (0.7x, or the equipped
        -- multiplier when tagged LIGHT_WHEN_ATTACHED), so ask for that one.
        weightOf = "getHotbarEquippedWeight",
    },
}

-- ---------------------------------------------------------------------------
-- Preference
-- ---------------------------------------------------------------------------

-- getModData is a lazy-alloc table return (IsoObject.java:1110) and cannot
-- throw on the nil-checked receivers here.
function InventoryCollapse.isCollapsed(playerObj, group)
    if not playerObj or not group then return false end
    local md = playerObj:getModData()
    return md ~= nil and md[group.modKey] == true
end

function InventoryCollapse.setCollapsed(playerObj, group, collapsed)
    if not playerObj or not group then return end
    local md = playerObj:getModData()
    if not md then return end
    -- nil rather than false when off, so the key does not accumulate in saves for
    -- players who never use this.
    md[group.modKey] = collapsed and true or nil
    -- Player modData is persisted server-side, so a purely local write would not
    -- survive a relog on a dedicated server. transmitModData null-checks the
    -- square and the send is try/catch'd (IsoObject.java:4470,
    -- INetworkPacket.send:127) - cannot throw.
    playerObj:transmitModData()
end

-- ---------------------------------------------------------------------------
-- Pane filtering
-- ---------------------------------------------------------------------------

-- Stack count and total weight for one group.
--
-- Items start at index 2. Vanilla appends a dummy duplicate of items[1] at the
-- front of every entry ("Adding the first item in list additionally at front as a
-- dummy" in refreshContainer), so summing from 1 double-counts one item per stack.
function InventoryCollapse.summarize(itemslist, group)
    local count, weight = 0, 0
    for _, v in ipairs(itemslist or {}) do
        if group.matches(v) and v.items then
            count = count + 1
            for i = 2, #v.items do
                local it = v.items[i]
                local w = nil
                if it then
                    -- No guards - the chain the old comment called "too deep
                    -- to certify" is now certified end to end. Both group
                    -- accessors and the fallback are trivial arithmetic over
                    -- getActualWeight + getContentsWeight
                    -- (InventoryItem.java:3137-3164), every branch of which
                    -- is null-checked or reads final fields; the exotic
                    -- residues (container self-cycle, a Lua-nulled bag
                    -- container) are Java body faults, which an exposed
                    -- method delivers as nil, never as an error. What CAN
                    -- fail here is the by-name lookup itself - a future
                    -- build renaming the accessor indexes nil - so the
                    -- presence test carries that, and the number test
                    -- carries the swallowed-fault nil.
                    local wf = it[group.weightOf]
                    local r = wf and wf(it)
                    if type(r) == "number" then
                        w = r
                    elseif it.getUnequippedWeight then
                        r = it:getUnequippedWeight()
                        if type(r) == "number" then w = r end
                    end
                end
                if type(w) == "number" then weight = weight + w end
            end
        end
    end
    return count, weight
end

-- pairs(), NOT next(): B42's Kahlua registers no global `next` (BaseLib exposes
-- pcall/print/select/type/tostring/tonumber/getmetatable/setmetatable/error/
-- unpack/setfenv/getfenv/rawequal/rawset/rawget/collectgarbage/debugstacktrace/
-- bytecodeloader and nothing else), so `next(t) == nil` throws "Object tried to
-- call nil" at runtime. It passes tools/run-tests, which uses real Lua 5.1 where
-- next exists - the harness cannot catch this class of bug.
local function isEmptyTable(t)
    for _ in pairs(t) do return false end
    return true
end

-- Which items are currently selected, by identity. self.selected is keyed by
-- display row, and those keys stop meaning anything the moment we remove entries -
-- so capture the values, filter, then rebuild the keys.
local function capturedSelection(pane)
    local items = {}
    if type(pane.selected) ~= "table" then return items end
    for _, v in pairs(pane.selected) do
        if v ~= nil then items[v] = true end
    end
    return items
end

-- Rebuild self.selected against the filtered list. This mirrors vanilla's own
-- restoreSelection walk exactly - one row per entry, plus one per sub-item when
-- the group is expanded - so a surviving item keeps its selection wherever it
-- ended up, whether we removed from the head, the tail, or both.
local function reindexSelection(pane, items)
    if isEmptyTable(items) then
        pane.selected = {}
        return
    end

    local out = {}
    local collapsedGroups = pane.collapsed or {}
    local row = 1
    for _, v in ipairs(pane.itemslist or {}) do
        local first = v.items and v.items[1]
        if first ~= nil and items[first] then out[row] = first end
        row = row + 1
        if not collapsedGroups[v.name] and v.items then
            for j = 2, #v.items do
                local it = v.items[j]
                if it ~= nil and items[it] then out[row] = it end
                row = row + 1
            end
        end
    end
    pane.selected = out
end

function InventoryCollapse.applyToPane(pane)
    if not InventoryCollapse.isEnabled() then return end
    if not pane or not pane.itemslist then return end

    -- The player's own inventory only. The loot pane has nothing equipped in it,
    -- and the parent window is what knows which of the two this is.
    if not (pane.parent and pane.parent.onCharacter) then return end

    -- Summarise BEFORE filtering - once the entries are gone the buttons have
    -- nothing left to count.
    pane.icGroupStats = pane.icGroupStats or {}
    local playerObj = getSpecificPlayer(pane.player)
    local active = {}

    for key, group in pairs(InventoryCollapse.GROUPS) do
        local count, weight = InventoryCollapse.summarize(pane.itemslist, group)
        pane.icGroupStats[key] = { count = count, weight = weight }
        if count > 0 and InventoryCollapse.isCollapsed(playerObj, group) then
            active[#active + 1] = group
        end
    end

    if #active == 0 then return end

    local selectedItems = capturedSelection(pane)

    local removed = 0
    for i = #pane.itemslist, 1, -1 do
        local v = pane.itemslist[i]
        for _, group in ipairs(active) do
            if group.matches(v) then
                table.remove(pane.itemslist, i)
                removed = removed + 1
                break
            end
        end
    end
    if removed == 0 then return end

    reindexSelection(pane, selectedItems)

    -- ISInventoryPane.lua invokes updateScrollbars itself after normal pane
    -- updates (:1787, :2196); a pane exposing this method is a valid UI pane.
    if pane.updateScrollbars then
        pane:updateScrollbars()
    end
end

-- ---------------------------------------------------------------------------
-- The buttons
-- ---------------------------------------------------------------------------

-- One handler class per group. They must be distinct class tables: vanilla's
-- AddHandler dedupes on handlerClass.Type, so a shared class would register once
-- and only ever draw one button.
--
-- The Type string stays "RDCollapseHandler_*" from the Core days on purpose. If a
-- player ends up with a stale RFTDCore and this mod at the same time - the two
-- ship together, but workshop subscribers do update out of step - matching Types
-- make vanilla's dedupe collapse them to ONE set of buttons. A fresh "IC*" name
-- would register alongside the old one and draw "Equipped (5)" twice.
local function defineHandler(group)
    local H = ISInventoryWindowControlHandler:derive("RDCollapseHandler_" .. group.key)

    function H:shouldBeVisible()
        -- The kill switch lives here: AddHandler has no unregister and runs before
        -- SandboxVars exists, so "off" means every button reports itself invisible
        -- and the control row is laid out exactly as if this mod were absent.
        if not InventoryCollapse.isEnabled() then return false end
        if getCore():getGameMode() == "Tutorial" then return false end
        local win = self.inventoryWindow
        if not (win and win.onCharacter == true) then return false end
        -- Nothing in this block: no button. Avoids a dead "Hotbar (0)" sitting in
        -- the control row for players who never attach anything.
        return self:stats().count > 0
    end

    function H:pane()
        return self.inventoryWindow and self.inventoryWindow.inventoryPane or nil
    end

    function H:stats()
        local pane = self:pane()
        if not pane then return { count = 0, weight = 0 } end

        local s = pane.icGroupStats and pane.icGroupStats[group.key]
        if s then return s end

        -- No cache yet. arrange() can run before the first refreshContainer, and
        -- shouldBeVisible gates on the count - without this fallback both buttons
        -- would be missing until something else forced a rebuild. Safe to compute
        -- straight off itemslist here precisely BECAUSE applyToPane has not run,
        -- so nothing has been filtered out of it yet.
        local count, weight = InventoryCollapse.summarize(pane.itemslist, group)
        return { count = count, weight = weight }
    end

    function H:getControl()
        local collapsed = InventoryCollapse.isCollapsed(self.playerObj, group)
        local s = self:stats()

        -- +/- prefix rather than differing words: the two states render at the SAME
        -- width for a given count, so relabelling in perform() cannot leave the
        -- control row mis-packed until the next arrange().
        local btn = self:getButtonControl(string.format("%s %s (%d)",
            collapsed and "+" or "-", group.label, s.count))

        btn.tooltip = string.format("%s %s items - %d item(s), %.2f weight",
            collapsed and "Show" or "Hide", group.label, s.count, s.weight)
        return btn
    end

    function H:perform()
        InventoryCollapse.setCollapsed(self.playerObj, group,
            not InventoryCollapse.isCollapsed(self.playerObj, group))

        local pane = self:pane()
        if pane and pane.refreshContainer then
            pane:refreshContainer()
        end

        -- Relabel in place, AFTER the refresh so the count is current. The page's
        -- controlsUI:arrange() would also relabel, but it removes and re-adds every
        -- child of the control row and we are inside this very button's click
        -- handler; re-running getControl only touches the cached button.
        if self.control then self:getControl() end
    end

    function H:handleJoypadContextMenu(context)
        local collapsed = InventoryCollapse.isCollapsed(self.playerObj, group)
        self:addJoypadContextMenuOption(context,
            string.format("%s %s items", collapsed and "Show" or "Hide", group.label))
    end

    function H:new()
        local o = ISInventoryWindowControlHandler.new(self)
        o.altColor = false
        return o
    end

    return H
end

InventoryCollapse.HANDLERS = {}

-- ---------------------------------------------------------------------------
-- Install
-- ---------------------------------------------------------------------------

-- Weak keys: a class table we patched should not be kept alive by this set.
local patched = setmetatable({}, { __mode = "k" })

local function patchPane(cls)
    if type(cls) ~= "table" then return false end
    if patched[cls] then return false end
    if type(cls.refreshContainer) ~= "function" then return false end
    patched[cls] = true

    local orig = cls.refreshContainer
    cls.refreshContainer = function(self, ...)
        local r = orig(self, ...)
        -- This is our own synchronous filter pass. If its preconditions drift,
        -- surface that at the wrapper instead of silently showing unfiltered data.
        InventoryCollapse.applyToPane(self)
        return r
    end
    return true
end

-- All three tables by reference. CleanUI swaps the live ISInventoryPane global
-- between its two classes at runtime, so patching whichever is currently the alias
-- is not enough. Identity-keyed `patched` means the aliases cannot double-wrap.
local function patchAll()
    local n = 0
    if patchPane(rawget(_G, "ISInventoryPane"))                 then n = n + 1 end
    if patchPane(rawget(_G, "CleanUI_Clean_ISInventoryPane"))   then n = n + 1 end
    if patchPane(rawget(_G, "CleanUI_Vanilla_ISInventoryPane")) then n = n + 1 end
    return n
end

local function registerHandlers()
    if InventoryCollapse.registered then return end
    if not ISInventoryWindowContainerControls then return end
    if type(ISInventoryWindowContainerControls.AddHandler) ~= "function" then return end

    -- Sorted so button order on screen is stable rather than pairs() order.
    local ordered = {}
    for _, group in pairs(InventoryCollapse.GROUPS) do ordered[#ordered + 1] = group end
    table.sort(ordered, function(a, b) return a.order < b.order end)

    for _, group in ipairs(ordered) do
        local H = defineHandler(group)
        InventoryCollapse.HANDLERS[group.key] = H
        -- Vanilla AddHandler dedupes on handlerClass.Type, so this is idempotent.
        ISInventoryWindowContainerControls.AddHandler(H)
    end
    InventoryCollapse.registered = true
end

local function install()
    registerHandlers()
    patchAll()
end

install()
Events.OnGameStart.Add(install)

-- CleanUI creates its namespaced vanilla clone lazily (its mode switcher requires
-- the file on a bootstrap tick), so a class we want can appear after OnGameStart.
-- Sweep briefly, then stop - this is a bounded retry, not a poll.
local ticksLeft = 60
local function sweep()
    ticksLeft = ticksLeft - 1
    patchAll()
    if ticksLeft <= 0 then
        Events.OnTick.Remove(sweep)
    end
end
Events.OnTick.Add(sweep)

return InventoryCollapse

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
