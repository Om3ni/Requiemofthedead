-- DFBanBox.lua - server-side item ban ENGINE (neutral mechanism, no content).
--
-- Prevention, not a world sweep: strips banned item types from the merged loot
-- distribution at startup so no NEW copies spawn. Already-spawned items are left
-- alone - the engine caches an item's identity per instance and in the save, so a
-- non-destructive pass can't reach them. That's the accepted trade: it shuts the
-- faucet; it does not hunt down existing copies.
--
-- This file ships ZERO bans of its own. It is pure mechanism. The ban LIST is
-- policy and lives elsewhere - either the optional "BBLibrary" submod (which ships
-- the Requiem of the Dead defaults) or any server's own ban-list mod. Both attach the
-- same way:
--
--     require "DFBanBox"
--     DFBanBox.ban("Mod.ItemType")   -- one line per item, full type (Module.Type)
--
-- `require` forces this engine to load first, so a list file works regardless of
-- mod load order.
--
-- Master toggle: SandboxVars.RFTDBanBox.BanBoxEnabled (default ON). With the
-- engine disabled, registered bans are ignored and nothing is stripped. With it
-- enabled but no list attached, the engine is simply a no-op.

require "RDShared"   -- explicit: file-scope RD* use must not ride on load order (see MMSvShared header)

DFBanBox = DFBanBox or {}
RDShared.registerMod("RFTDBanBox", "0.7.0")   -- keep in sync with mod.info
DFBanBox._bans = DFBanBox._bans or {}   -- fullType -> true

local function cfg() return SandboxVars.RFTDBanBox or {} end

-- Verbose tracing, gated by the BanBoxDebug sandbox toggle (default off). The
-- confiscation audit (DFCore.audit) is a staff feature, NOT routed through here -
-- it always logs. dbg() adds the "[DFBanBox] " prefix itself.
local function dbg(fmt, ...)
    if cfg().BanBoxDebug ~= true then return end
    if select("#", ...) > 0 then print("[DFBanBox] " .. string.format(fmt, ...))
    else print("[DFBanBox] " .. tostring(fmt)) end
end

-- Live only when both the master panel toggle and BanBox's own toggle allow it.
local function featureOn()
    local s = cfg()
    if s.Enabled == false then return false end
    return s.BanBoxEnabled ~= false   -- default ON
end

-- Register a ban. Applies whenever the engine is enabled. PUBLIC API - this is
-- the single hook a ban-list mod calls.
function DFBanBox.ban(fullType)
    if type(fullType) == "string" and fullType ~= "" then
        DFBanBox._bans[fullType] = true
    end
end

-- Strip each banned type from the merged loot tables. Distributions key items by
-- SHORT name ("Yoyo"), but mod injections sometimes use the module-qualified form,
-- so strip both. RemoveItemFromDistribution is recursive: one call per top-level
-- table clears every nested container list.
local function applyBans()
    if not featureOn() then return end
    local n = 0
    for fullType in pairs(DFBanBox._bans) do
        local short = fullType:match("%.([^%.]+)$") or fullType
        local names = (short == fullType) and { fullType } or { short, fullType }
        for _, name in ipairs(names) do
            if Distributions and Distributions.list then
                RemoveItemFromDistribution(Distributions.list, name)
            end
            if ProceduralDistributions and ProceduralDistributions.list then
                RemoveItemFromDistribution(ProceduralDistributions.list, name)
            end
        end
        n = n + 1
    end
    if n > 0 then
        dbg("stripped %d item type(s) from loot distribution.", n)
    end
end

-- Apply once, after all loot tables are built and merged (before any container fills).
if not DFBanBox._hooked then
    DFBanBox._hooked = true
    Events.OnPostDistributionMerge.Add(applyBans)
end

-- ─────────────────────────────────────────────────────────────────────────
-- Login confiscation (opt-in, server-side).
--
-- Optional second layer: when a player connects, remove any banned item they
-- are CARRYING (distribution prevention can't reach copies already in hand).
-- Deliberately bounded - one connecting player's carried inventory, at a natural
-- event - so it never becomes the recursive world-walk antipattern. It does NOT
-- touch base storage, vehicles, or the world, and it NEVER punishes the player:
-- it removes the item, tells the player (so an innocent holder has recourse),
-- and writes an audit line for staff. Acting on a person is a human decision.
--
-- Gated by SandboxVars.RFTDBanBox.BanBoxConfiscateOnLogin (default OFF) AND
-- the master BanBox toggles. Applies to EVERYONE, admins included - a banned
-- item is banned regardless of who holds it.
-- ─────────────────────────────────────────────────────────────────────────

-- Player-facing line shown when an item is removed. POLICY, not mechanism: a
-- content mod (e.g. BBLibrary) overrides this with its own wording. %s = item name.
DFBanBox.removalMessage =
    "%s has been removed from your inventory because it is on the server's banned list."

local function confiscateOn()
    if not featureOn() then return false end
    return cfg().BanBoxConfiscateOnLogin == true   -- default OFF
end

-- Remove every carried banned item from one player. Bounded to that player's
-- main inventory, worn items, and one level of bags (the shared walker).
local function scrubPlayer(player)
    if not player then return end
    local who = (player.getUsername and player:getUsername()) or "?"
    if not confiscateOn() then
        dbg("scrub skip: confiscate-on-login is OFF (" .. tostring(who) .. ")")
        return
    end
    if not (DFInventory and DFInventory.listAddressableItems) then
        dbg("scrub skip: inventory walker unavailable (" .. tostring(who) .. ")")
        return
    end

    local scanned = 0
    local removed = {}   -- fullType -> { count, name }
    for _, entry in ipairs(DFInventory.listAddressableItems(player)) do
        scanned = scanned + 1
        local it = entry.item
        local ft
        pcall(function() ft = it:getFullType() end)
        if ft and DFBanBox._bans[ft] then
            local nm = ft
            pcall(function() nm = it:getName() or ft end)
            local container
            pcall(function() container = it:getContainer() end)
            container = container or player:getInventory()
            -- Unequip from hands first so removal can't leave a dangling ref.
            pcall(function() if player:isEquipped(it) then player:removeFromHands(it) end end)
            pcall(function() container:Remove(it) end)
            pcall(function() sendRemoveItemFromContainer(container, it) end)
            local r = removed[ft] or { count = 0, name = nm }
            r.count = r.count + 1
            removed[ft] = r
        end
    end

    local any = false
    for ft, r in pairs(removed) do
        any = true
        -- Tell the player (server formats so BBLibrary's override is honoured).
        local msg = string.format(DFBanBox.removalMessage or "%s has been removed.", r.name)
        pcall(function() sendServerCommand(player, "DFBanBox", "removed", { message = msg }) end)
        -- Audit for staff - input to the two-owner process, never an auto-action.
        if DFCore and DFCore.audit then
            DFCore.audit("BanBox confiscate", player, string.format("item=%s x%d", ft, r.count))
        else
            print(string.format("[Dragonfly] BanBox confiscate from %s: %s x%d",
                tostring(player:getUsername()), ft, r.count))
        end
    end
    if any then pcall(function() player:resetModelNextFrame() end) end  -- refresh if a worn item went
    dbg("scrub %s: scanned=%d, removed=%s",
        tostring(who), scanned, any and "yes" or "none banned")
end

-- Player-ready trigger: Core owns the family's ONLY standing OnTick poll now
-- (RDLife - same throttle / square+inventory gates / 5-minute give-up this
-- file pioneered; RDLife's header carries the dedicated-server trigger
-- facts). BanBox subscribes and scrubs once per connection; RDLife keys by
-- onlineID and prunes on disconnect, so a relog is re-scrubbed exactly as
-- before. BEHAVIOR NOTE: the confiscate toggle is read at ready time - a
-- mid-session sandbox enable now applies from each player's NEXT connection
-- rather than mid-connection (the old poll re-checked every second; nobody
-- legitimately flips this mid-session).
-- CONTEXT GUARD (load-bearing): the CLIENT loads media/lua/server too, and
-- every RDLife/RDLog/RDIdentity file in Core opens with `if not isServer()
-- then return end` - so on a connected client RDLife is nil and this line
-- threw "attempted index: onPlayerReady of non-table" during world load
-- (observed 42.19, client console 2026-07-26). Existence guards are still
-- banned per family law; the guard is on CONTEXT, which is the honest test.
if isServer() and not DFBanBox._connectHooked then
    DFBanBox._connectHooked = true
    RDLife.onPlayerReady(function(p)
        if confiscateOn() then scrubPlayer(p) end
    end)
    dbg("login scrub armed (via RDLife.onPlayerReady)")
end
