-- DFRegistry - tab/action/badge registration for consumer mods.
--
-- Reaper, Husbandry, Dirge, and Ladybug all call into this if Dragonfly is
-- loaded. Each registration is just a table description; DFPanel reads it
-- at panel-open time to build the UI. No registration means no surface,
-- which is how consumer mods stay shippable without Dragonfly.
--
-- Registration order doesn't matter; tabs are sorted by an optional `order`
-- field then alphabetically by label.

if isServer() then return end

DFRegistry = DFRegistry or {
    tabs         = {},  -- [id] = spec
    rowActions   = {},  -- [tabId] = { spec, spec, ... }
    statusBadges = {},  -- [id] = spec
}

function DFRegistry.registerTab(spec)
    if not spec or not spec.id then
        print("[Dragonfly] registerTab refused: missing spec or id")
        return
    end
    DFRegistry.tabs[spec.id] = spec
    print("[Dragonfly] registerTab ok: " .. tostring(spec.id) .. " (" .. tostring(spec.label or "?") .. ")")
end

function DFRegistry.registerRowAction(spec)
    if not spec or not spec.tabId then return end
    local list = DFRegistry.rowActions[spec.tabId]
    if not list then list = {}; DFRegistry.rowActions[spec.tabId] = list end
    list[#list + 1] = spec
end

function DFRegistry.registerStatusBadge(spec)
    if not spec or not spec.id then return end
    DFRegistry.statusBadges[spec.id] = spec
end

function DFRegistry.getTabs()
    local out = {}
    for _, spec in pairs(DFRegistry.tabs) do
        -- supersededBy hides this tab if the named successor is also registered.
        -- Used by Dragonfly's basic Zombies tab to step aside for Reaper's Necro.
        local hide = spec.supersededBy and DFRegistry.tabs[spec.supersededBy] ~= nil
        if not hide then out[#out + 1] = spec end
    end
    table.sort(out, function(a, b)
        local oa = a.order or 100
        local ob = b.order or 100
        if oa ~= ob then return oa < ob end
        return tostring(a.label or "") < tostring(b.label or "")
    end)
    return out
end

-- PLACEHOLDER TABS. `spec.disabled = true` reserves a slot in the roster - the
-- label renders greyed and cannot be selected - without the tab having any
-- content behind it. It exists so a planned tab can take its final position in
-- the nav NOW, while the order is being settled, rather than shuffling every
-- other tab sideways on the day it ships.
--
-- Distinct from `capability`, which greys a REAL tab for a player whose role
-- lacks the permission: that one is per-player and flips live, this one is a
-- property of the build. Both shells render them the same way; only the reason
-- differs.
function DFRegistry.isSelectable(spec)
    return spec ~= nil and spec.disabled ~= true
end

-- The tab a shell should land on. NOT simply tabs[1]: a disabled tab sorted to
-- the front would leave the panel opening onto an empty content area with no
-- way to tell it apart from a tab that failed to build. Returns nil when every
-- registered tab is disabled, which callers treat as the empty state.
function DFRegistry.firstSelectable(tabs)
    for _, spec in ipairs(tabs or DFRegistry.getTabs()) do
        if DFRegistry.isSelectable(spec) then return spec.id end
    end
    return nil
end

function DFRegistry.getRowActions(tabId)
    return DFRegistry.rowActions[tabId] or {}
end

function DFRegistry.getStatusBadges()
    local out = {}
    for _, spec in pairs(DFRegistry.statusBadges) do out[#out + 1] = spec end
    table.sort(out, function(a, b) return tostring(a.id) < tostring(b.id) end)
    return out
end

-- Friendly alias for consumer mods. They write `Dragonfly.registerTab{...}`
-- rather than `DFRegistry.registerTab{...}`; reads cleaner from outside.
Dragonfly = Dragonfly or {}
Dragonfly.registerTab         = DFRegistry.registerTab
Dragonfly.registerRowAction   = DFRegistry.registerRowAction
Dragonfly.registerStatusBadge = DFRegistry.registerStatusBadge
