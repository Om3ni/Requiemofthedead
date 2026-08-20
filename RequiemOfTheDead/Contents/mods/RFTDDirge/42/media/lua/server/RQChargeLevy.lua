-- SPDX-License-Identifier: GPL-3.0-or-later
-- Owns EMP charge removal from player-carried electronics.

if not isServer() then return end

RQChargeLevy = RQChargeLevy or {}

-- Switch off and partially drain active electronics plus loose batteries.
-- setUsedDelta exists only on the engine's DrainableComboItem, Clothing, and
-- WeaponPart implementations; method presence is therefore a subtype gate,
-- not a speculative exception probe.
function RQChargeLevy.drain(player, drainPercent)
    local inv = player and player:getInventory()
    if not inv then return 0 end
    local items = inv:getItems()
    if not items then return 0 end

    local drainFrac = drainPercent / 100.0
    local hit = 0
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if item then
            local wasActive = item:isActivated()
            if wasActive then item:setActivated(false) end

            local isBattery = item:getType() == "Battery"
            -- InventoryItem.java:2322-2333;
            -- DrainableComboItem.java:80-100; Clothing.java:1250-1266;
            -- WeaponPart.java:301-319.
            if (wasActive or isBattery) and item.setUsedDelta then
                local current = item:getCurrentUsesFloat() or 0
                item:setUsedDelta(math.max(0.0, current - drainFrac))
                hit = hit + 1
            end
        end
    end
    return hit
end

