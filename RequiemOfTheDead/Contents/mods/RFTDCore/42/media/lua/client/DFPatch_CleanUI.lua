-- DFPatch_CleanUI.lua - Dragonfly removable third-party patch (CLIENT)
--
-- Stops CleanUI's always-present loot window from auto-requesting server-side
-- loot generation for every container a player walks past while the window is
-- collapsed.
--
-- Cause: CleanUI keeps the loot window on-screen at all times, collapsing it to a
-- titlebar instead of closing it. Its :update() still runs the vanilla dir/square
-- branch with NO collapsed guard:
--     if self.lastDir ~= playerObj:getDir() then self:refreshBackpacks()
--     elseif self.lastSquare ~= playerObj:getCurrentSquare() then self:refreshBackpacks()
-- and :refreshBackpacks() calls :checkExplored() on every adjacent container,
-- static-object container, CORPSE container and vehicle part it finds. For any
-- unexplored container that is a client->server send:
--     ItemContainer.requestServerItemsForContainer()  -- decompiled 42.16.1:
--         INetworkPacket.send(PacketTypes.PacketType.RequestItemsForContainer, this)
-- which makes the server run procedural loot (ItemPicker) and transmit it back.
--
-- It is NOT a packet flood - checkExplored gates on isExplored() and sets it true,
-- so each container fires once. (The sibling requestSync() call IS a no-op on
-- 42.16.1 - its decompiled body sends nothing - so the hover collapse/expand
-- churn costs nothing on the wire.) The real cost is timing: because the window
-- is never closed, a player auto-explores EVERY container/corpse they step next
-- to, even ones they never open, turning deliberate-on-open loot generation into
-- walk-past loot generation. Across 30+ players that multiplies server ItemPicker
-- work and RequestItemsForContainer traffic, plus the full 9-square object rescan
-- runs every step client-side while collapsed.
--
-- Fix: wrap :checkExplored() on CleanUI's inventory page classes to no-op while
-- self.isCollapsed. Loot is still fetched on demand the moment the window is
-- expanded and a container is selected (selectContainer -> requestServerItems...,
-- still gated by isExplored). Open-window behaviour is byte-for-byte unchanged;
-- only the collapsed/idle window stops reaching out to the server.
--
-- CleanUI swaps the live ISInventoryPage global between two classes at runtime
-- (CleanUI_Vanilla_ISInventoryPage and CleanUI_Clean_ISInventoryPage) via its UI
-- mode switcher. We patch both class tables by reference, so whichever one is the
-- active alias is covered regardless of the selected mode.
--
-- TRADE-OFF: a never-before-seen container is no longer pre-explored as you walk
-- past it collapsed, so its first expand+select does the fetch then (a one-frame
-- delay) instead of having pre-fetched. Acceptable, and it also stops the
-- "SearchNewContainer" music sting firing for containers you never opened.
--
-- REMOVABLE: delete this file to restore stock CleanUI behaviour. CleanUI keeps
-- working unchanged; nothing else in Dragonfly depends on this. Client file: the
-- patched calls only send on isClient().

local applied = false

-- Candidate CleanUI page-class globals. Both are real tables once CleanUI has
-- loaded; the live ISInventoryPage is an alias to one of them (mode switcher).
local function candidateClasses()
    return {
        rawget(_G, "CleanUI_Vanilla_ISInventoryPage"),
        rawget(_G, "CleanUI_Clean_ISInventoryPage"),
    }
end

local function patchClass(cls, seen)
    if type(cls) ~= "table" then return false end
    if seen[cls] then return false end             -- both globals may be the same table
    seen[cls] = true
    if cls.__dfCleanUICollapsedGuard then return false end
    if type(cls.checkExplored) ~= "function" then return false end

    local orig = cls.checkExplored
    cls.checkExplored = function(self, container, playerObj)
        -- Skip the walk-past server fetch while the window is collapsed; the
        -- expand/select path explores on demand (still isExplored-gated).
        if self.isCollapsed then return end
        return orig(self, container, playerObj)
    end
    cls.__dfCleanUICollapsedGuard = true
    return true
end

local function apply()
    if applied then return end
    if not rawget(_G, "CleanUI_Vanilla_ISInventoryPage") then
        return -- CleanUI not present
    end

    local seen = {}
    local patched = 0
    for _, cls in ipairs(candidateClasses()) do
        if patchClass(cls, seen) then patched = patched + 1 end
    end
    if patched == 0 then return end -- nothing to wrap yet; OnGameStart retry covers late loads
    applied = true

    print("[Dragonfly] DFPatch_CleanUI applied (collapsed loot window no longer auto-fetches containers; " .. patched .. " class(es) patched)")
end

-- CleanUI's classes and its mode switcher are resolved during the client load
-- pass; OnGameStart guarantees both named globals exist and are cached.
if rawget(_G, "CleanUI_Vanilla_ISInventoryPage") then apply() end
Events.OnGameStart.Add(apply)

Events.OnGameStart.Add(function()
    if applied and DFRegistry and DFRegistry.registerStatusBadge then
        DFRegistry.registerStatusBadge{
            id   = "cleanUILootFetchGuard",
            text = "CleanUI collapsed-window loot-fetch guard active",
        }
    end
end)
