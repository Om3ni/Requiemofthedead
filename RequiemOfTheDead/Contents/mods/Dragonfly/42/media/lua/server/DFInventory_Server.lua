-- DFInventory_Server - handlers for the Players-tab inventory modal.
--
-- Five actions: snapshot (read), editItem (write fields by probe label),
-- runAction (compound writes: Repair/Refill/etc.), addItem, removeItem,
-- dumpAll. Cross-player operations: caller is the admin, target is named in
-- args.username, server resolves via getPlayerFromUsername.
--
-- Items don't have stable cross-session IDs. We address by (slotIdx,
-- fullType) - the client snapshot capture slotIdx, edits carry it back, and
-- the server re-resolves with a fullType sanity check. If the inventory
-- shifted since snapshot the edit fails loud and the client refreshes.
--
-- Capability split:
--   playerInventorySnapshot  - InspectPlayerInventory (read)
--   playerInventoryEdit      - EditItem               (write)
--   playerInventoryAction    - EditItem               (Repair / Refill / ...)
--   playerInventoryAdd       - AddItem                (introduce new item)
--   playerInventoryRemove    - EditItem               (remove one item)
--   playerInventoryDump      - EditItem               (clear whole inventory)

if not isServer() then return end

local function resolveTarget(username)
    if not username or username == "" then return nil, "missing username" end
    local target = getPlayerFromUsername(username)
    if target then return target, nil end
    -- Fallback walk: getPlayerFromUsername sometimes returns nil on dedicated
    -- for the admin's own session and occasionally for other players too.
    -- getOnlinePlayers() is the canonical list and never has that gap.
    local players = getOnlinePlayers()
    if players then
        for i = 0, players:size() - 1 do
            local p = players:get(i)
            if p and p:getUsername() == username then
                return p, nil
            end
        end
    end
    return nil, "player not online"
end

-- Walk every addressable item on the target in a stable order. Returns a
-- list of { item, source } entries where source is "main" / "worn" / "bag".
-- The snapshot builds modal rows from this list and the slot index on the
-- wire is the 0-based index into it, so resolveItem can map back to the same
-- item. Keep this as the single source of truth - two parallel walks will
-- drift.
local function listAddressableItems(target)
    local out = {}
    local seen = {}
    local function add(it, source, prefix)
        if not it or seen[it] then return end
        seen[it] = true
        out[#out + 1] = { item = it, source = source, prefix = prefix }
    end

    -- 1) Main inventory
    local inv = target:getInventory()
    if inv then
        local items
        pcall(function() items = inv:getItems() end)
        if items then
            for i = 0, items:size() - 1 do add(items:get(i), "main", nil) end
        end
    end

    -- 2) Worn clothing
    local worn
    pcall(function() worn = target:getWornItems() end)
    if worn then
        local n = 0
        pcall(function() n = worn:size() end)
        for i = 0, n - 1 do
            local item
            pcall(function() item = worn:getItemByIndex(i) end)
            if not item then
                local entry
                pcall(function() entry = worn:get(i) end)
                if entry then pcall(function() item = entry:getItem() end) end
            end
            add(item, "worn", "[Worn] ")
        end
    end

    -- 3) One-level bag contents
    if inv then
        local items
        pcall(function() items = inv:getItems() end)
        if items then
            for i = 0, items:size() - 1 do
                local container = items:get(i)
                local sub
                -- getInventory() lives ONLY on the InventoryContainer subclass
                -- (bags), not base InventoryItem. Calling it on an ordinary
                -- item is a nil-method call: pcall catches it functionally but
                -- PZ still dumps a full stack trace to the log EVERY time, so a
                -- snapshot of an inventory full of non-bag items floods the log.
                -- Gate on the method's existence so the nil-call never fires.
                if container and type(container.getInventory) == "function" then
                    pcall(function() sub = container:getInventory() end)
                end
                if sub then
                    local subItems
                    pcall(function() subItems = sub:getItems() end)
                    local prefix = "[in bag] "
                    if container then
                        pcall(function() prefix = "[in " .. (container:getName() or "bag") .. "] " end)
                    end
                    if subItems then
                        for j = 0, subItems:size() - 1 do add(subItems:get(j), "bag", prefix) end
                    end
                end
            end
        end
    end

    return out
end

-- Exposed so other server modules (e.g. DFBanBox's login scrub) can reuse the
-- one canonical carried-items walk (main + worn + one-level bags) instead of
-- writing a second one that drifts from this.
DFInventory = DFInventory or {}
DFInventory.listAddressableItems = listAddressableItems

local function resolveItem(target, slotIdx, fullType)
    if not target then return nil, "no target" end
    local rows = listAddressableItems(target)
    -- Slot is 0-based on the wire (matches snapshot's row index), so we
    -- shift to 1-based for the Lua array.
    if not slotIdx or slotIdx < 0 or slotIdx >= #rows then
        return nil, "slot index out of range"
    end
    local it = rows[slotIdx + 1] and rows[slotIdx + 1].item
    if not it then return nil, "slot empty" end
    -- Sanity: confirm fullType matches what the client thought it was. If the
    -- inventory shifted between snapshot and edit this catches it before we
    -- write to the wrong item.
    if fullType and fullType ~= "" then
        local ok, ft = pcall(function() return it:getFullType() end)
        if ok and ft ~= fullType then
            return nil, "inventory changed; refresh"
        end
    end
    return it, nil
end

local function syncTarget(target)
    pcall(function() target:transmitModData() end)
    -- transmitModData only covers ModData. Item field changes (condition,
    -- usedDelta, etc.) need sendItemStats per-item or the owning client's
    -- next sync overwrites our writes - same client-authoritative pattern
    -- as zombie HP. See callers of syncItem below.
end

-- Push a single item's field state to the owning client. Without this the
-- server's setCondition/setUsedDelta/etc. is invisible to the owner and gets
-- clobbered by their next inbound inventory sync.
local function syncItem(item)
    if not item then return end
    pcall(function() sendItemStats(item) end)
end

-- Container-level sync for add/remove. The state-field sendItemStats isn't
-- enough when the item itself is new or gone.
local function syncAdded(container, item)
    if not container or not item then return end
    pcall(function() sendAddItemToContainer(container, item) end)
end

local function syncRemoved(container, item)
    if not container or not item then return end
    pcall(function() sendRemoveItemFromContainer(container, item) end)
end

-- ─────────────────────────────────────────────────────────────────────────
-- Handler registration (deferred so DFServer is loaded - same fix pattern
-- as DFPlayersTab_Server.lua).
-- ─────────────────────────────────────────────────────────────────────────

Events.OnServerStarted.Add(function()
    if not DFServer or not DFServer.registerHandler then
        print("[Dragonfly] DFInventory_Server: DFServer missing, handlers not registered")
        return
    end

    DFServer.registerHandler{
        action     = "playerInventorySnapshot",
        capability = Capability.InspectPlayerInventory,
        run = function(player, args)
            print(string.format(
                "[Dragonfly] DEBUG playerInventorySnapshot enter: username=%s",
                tostring(args and args.username or "?")))
            local target, err = resolveTarget(args.username)
            if not target then
                print(string.format(
                    "[Dragonfly] DEBUG playerInventorySnapshot resolveTarget FAILED: %s",
                    tostring(err)))
                return { ok = false, reason = err }
            end
            print(string.format(
                "[Dragonfly] DEBUG playerInventorySnapshot resolved: target=%s",
                tostring(target:getUsername())))

            -- Resolve hand items up front so we can tag equipped weapons.
            local primary, secondary
            pcall(function() primary   = target:getPrimaryHandItem()   end)
            pcall(function() secondary = target:getSecondaryHandItem() end)

            local rows = listAddressableItems(target)
            local out = {}
            local wornCount = 0
            for i, entry in ipairs(rows) do
                local it = entry.item
                local tag = entry.prefix or ""
                if it == primary   then tag = "[Primary] "   end
                if it == secondary then tag = "[Secondary] " end
                if entry.source == "worn" then wornCount = wornCount + 1 end
                local ft, name, kind, cond, condMax, count
                pcall(function() ft      = it:getFullType()     end)
                pcall(function() name    = it:getName()         end)
                pcall(function() kind    = it:getCategory()     end)
                pcall(function() cond    = it:getCondition()    end)
                pcall(function() condMax = it:getConditionMax() end)
                pcall(function() count   = it:getCount()        end)
                out[#out + 1] = {
                    slot     = i - 1,
                    fullType = ft or "?",
                    name     = tag .. (name or ft or "?"),
                    kind     = tostring(kind or "Item"),
                    count    = count or 1,
                    cond     = cond,
                    condMax  = condMax,
                }
            end

            print(string.format(
                "[Dragonfly] playerInventorySnapshot target=%s items=%d worn=%d primary=%s secondary=%s",
                args.username or "?", #out, wornCount,
                primary   and tostring(primary:getFullType())   or "-",
                secondary and tostring(secondary:getFullType()) or "-"))

            pcall(sendServerCommand, player, DFCore.MODULE, "PlayerInventory",
                { username = args.username, items = out })
            return { ok = true }
        end,
    }

    DFServer.registerHandler{
        action     = "playerInventoryItemSnapshot",
        capability = Capability.InspectPlayerInventory,
        run = function(player, args)
            local target, err = resolveTarget(args.username)
            if not target then return { ok = false, reason = err } end
            local item, ierr = resolveItem(target, args.slot, args.fullType)
            if not item then return { ok = false, reason = ierr } end
            local snap = DFItemProbes.serializeItem(item)
            snap.username = args.username
            snap.slot     = args.slot
            snap.fullType = args.fullType
            pcall(sendServerCommand, player, DFCore.MODULE, "PlayerInventoryItem", snap)
            return { ok = true }
        end,
    }

    DFServer.registerHandler{
        action     = "playerInventoryEdit",
        capability = Capability.EditItem,
        run = function(player, args)
            local target, err = resolveTarget(args.username)
            if not target then return { ok = false, reason = err } end
            local item, ierr = resolveItem(target, args.slot, args.fullType)
            if not item then return { ok = false, reason = ierr } end
            local fields = args.fields or {}
            local applied, failed = 0, {}
            for label, value in pairs(fields) do
                local ok, ferr = DFItemProbes.write(item, label, value)
                if ok then applied = applied + 1
                else failed[#failed + 1] = label .. ":" .. tostring(ferr) end
            end
            if applied > 0 then syncItem(item) end
            syncTarget(target)
            DFCore.audit("playerInventoryEdit", player,
                string.format("target=%s slot=%d ft=%s applied=%d",
                    args.username, args.slot or -1, args.fullType or "?", applied))
            if #failed > 0 then
                return { ok = false, reason = string.format(
                    "%d applied, %d failed: %s", applied, #failed,
                    table.concat(failed, "; ")) }
            end
            return { ok = true,
                message = string.format("Applied %d field(s) to %s's %s.",
                    applied, args.username, args.fullType or "item") }
        end,
    }

    DFServer.registerHandler{
        action     = "playerInventoryAction",
        capability = Capability.EditItem,
        run = function(player, args)
            local target, err = resolveTarget(args.username)
            if not target then return { ok = false, reason = err } end
            local item, ierr = resolveItem(target, args.slot, args.fullType)
            if not item then return { ok = false, reason = ierr } end
            local ok, aerr = DFItemProbes.runAction(item, args.actionId)
            if not ok then return { ok = false, reason = aerr } end
            syncItem(item)
            syncTarget(target)
            DFCore.audit("playerInventoryAction", player,
                string.format("target=%s slot=%d ft=%s action=%s",
                    args.username, args.slot or -1, args.fullType or "?",
                    tostring(args.actionId)))
            return { ok = true,
                message = string.format("%s applied to %s's %s.",
                    args.actionId, args.username, args.fullType or "item") }
        end,
    }

    DFServer.registerHandler{
        action     = "playerInventoryAdd",
        capability = Capability.AddItem,
        run = function(player, args)
            local target, err = resolveTarget(args.username)
            if not target then return { ok = false, reason = err } end
            local ft = tostring(args.fullType or "")
            -- Clamp the client-supplied count: each unit fires an AddItem +
            -- sendAddItemToContainer packet, so an unbounded count is a one-tick
            -- packet flood (and an easy way to lag the server). 100 is plenty for
            -- any legitimate admin top-up.
            local MAX_ADD = 100
            local count = math.max(1, math.min(MAX_ADD, math.floor(tonumber(args.count) or 1)))
            local inv = target:getInventory()
            if not inv then return { ok = false, reason = "no inventory" } end
            local added = 0
            for _ = 1, count do
                local newItem
                local ok = pcall(function() newItem = inv:AddItem(ft) end)
                if ok and newItem then
                    added = added + 1
                    syncAdded(inv, newItem)
                end
            end
            syncTarget(target)
            DFCore.audit("playerInventoryAdd", player,
                string.format("target=%s ft=%s count=%d added=%d",
                    args.username, ft, count, added))
            if added == 0 then
                return { ok = false, reason = "AddItem refused (bad type?): " .. ft }
            end
            return { ok = true,
                message = string.format("Added %d x %s to %s.", added, ft, args.username) }
        end,
    }

    DFServer.registerHandler{
        action     = "playerInventoryRemove",
        capability = Capability.EditItem,
        run = function(player, args)
            local target, err = resolveTarget(args.username)
            if not target then return { ok = false, reason = err } end
            local item, ierr = resolveItem(target, args.slot, args.fullType)
            if not item then return { ok = false, reason = ierr } end
            local inv = target:getInventory()
            -- Capture the item's actual container before removal - if it was
            -- in a sub-container (bag) we need to sync against that container,
            -- not the player's main inventory.
            local container = inv
            pcall(function() container = item:getContainer() or inv end)
            pcall(function() inv:Remove(item) end)
            syncRemoved(container, item)
            syncTarget(target)
            DFCore.audit("playerInventoryRemove", player,
                string.format("target=%s slot=%d ft=%s",
                    args.username, args.slot or -1, args.fullType or "?"))
            return { ok = true,
                message = string.format("Removed %s from %s.",
                    args.fullType or "item", args.username) }
        end,
    }

    -- Bulk Repair: walk every addressable item (main + worn + one-level bag
    -- contents) and run Repair on anything with getCondition. Skips items
    -- where the action isn't applicable silently.
    DFServer.registerHandler{
        action     = "playerInventoryRepairAll",
        capability = Capability.EditItem,
        run = function(player, args)
            local target, err = resolveTarget(args.username)
            if not target then return { ok = false, reason = err } end

            local repaired = 0
            for _, entry in ipairs(listAddressableItems(target)) do
                local it = entry.item
                if it and type(it.getCondition) == "function" then
                    local ok = DFItemProbes.runAction(it, "Repair")
                    if ok then
                        repaired = repaired + 1
                        syncItem(it)
                    end
                end
            end

            syncTarget(target)
            DFCore.audit("playerInventoryRepairAll", player,
                string.format("target=%s repaired=%d", args.username, repaired))
            return { ok = true,
                message = string.format("Repaired %d item(s) on %s.",
                    repaired, args.username) }
        end,
    }

    DFServer.registerHandler{
        action     = "playerInventoryDump",
        capability = Capability.EditItem,
        run = function(player, args)
            local target, err = resolveTarget(args.username)
            if not target then return { ok = false, reason = err } end
            local inv = target:getInventory()
            if not inv then return { ok = false, reason = "no inventory" } end
            -- Snapshot item refs before clear() wipes them so we can fire a
            -- remove-from-container packet per item afterwards. Otherwise the
            -- owner's client still thinks they have all the loot.
            local toRemove = {}
            local items = inv:getItems()
            if items then
                for i = 0, items:size() - 1 do
                    toRemove[#toRemove + 1] = items:get(i)
                end
            end
            local before = #toRemove
            pcall(function() inv:clear() end)
            for _, it in ipairs(toRemove) do
                syncRemoved(inv, it)
            end
            syncTarget(target)
            DFCore.audit("playerInventoryDump", player,
                string.format("target=%s cleared=%d", args.username, before))
            return { ok = true,
                message = string.format("Dumped %d items from %s.", before, args.username) }
        end,
    }

    print("[Dragonfly] DFInventory_Server handlers registered")
end)

print("[Dragonfly] DFInventory_Server loaded (registration deferred to OnServerStarted)")

-- Dragonfly v0.2.0
