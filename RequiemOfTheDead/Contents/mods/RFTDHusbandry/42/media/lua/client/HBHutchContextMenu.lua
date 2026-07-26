-- HBHutchContextMenu — right-click "Add Hay Bedding" on a hutch.
--
-- Player-facing diegetic path: if you have a HayTuft (gathered from hay), you
-- can pour it into a coop/hutch as bedding. Runs HBAddHayAction, which consumes
-- the hay and asks the server to top up the hutch's bedding charge (HBBedding
-- continuously eats dirt while bedding lasts, then it decays).
--
-- Uses OnPreFillWorldObjectContextMenu, NOT OnFillWorldObjectContextMenu: in
-- B42 the non-pre event is gated (safehouse-interact + Java early-returns) and
-- can be swallowed on claimed buildings. The PRE event fires unconditionally
-- for every world right-click with the same signature. (See Sandman's
-- SMBedAction for the same rationale.)

if isServer() then return end

require "ISUI/ISToolTip"
require "TimedActions/ISTimedActionQueue"

local HAY_TYPE = "Base.HayTuft"

-- Find the live MASTER hutch from the right-clicked objects: check the objects
-- themselves, then their squares. Skips slave halves of multi-tile coops
-- (isSlave: linkedX>0 && linkedY>0) — the master holds the real bedding/dirt.
local function findHutch(worldobjects)
    if not worldobjects then return nil end
    local function masterOrNil(o)
        if not o or not instanceof(o, "IsoHutch") then return nil end
        local slave = false
        pcall(function() slave = o:isSlave() end)
        return (not slave) and o or nil
    end
    local squares = {}
    for i = 1, #worldobjects do
        local o = worldobjects[i]
        if o then
            local m = masterOrNil(o)
            if m then return m end
            local sq; pcall(function() sq = o:getSquare() end)
            if sq then squares[sq] = true end
        end
    end
    for sq in pairs(squares) do
        local objs = sq:getObjects()
        if objs then
            for k = 0, objs:size() - 1 do
                local m = masterOrNil(objs:get(k))
                if m then return m end
            end
        end
    end
    return nil
end

Events.OnPreFillWorldObjectContextMenu.Add(function(playerNum, context, worldobjects, test)
    if test then return end

    local hutch = findHutch(worldobjects)
    if not hutch then return end

    local player = getSpecificPlayer(playerNum)
    if not player or player:isDead() then return end

    -- Need hay in inventory to offer the option at all.
    local hay
    pcall(function() hay = player:getInventory():getFirstTypeRecurse(HAY_TYPE) end)
    if not hay then return end

    local max     = (HBBedding and HBBedding.MAX) or 100
    local bedding = (HBBedding and HBBedding.getAmount and HBBedding.getAmount(hutch)) or 0

    local option = context:addOption("Add Hay Bedding", worldobjects, function()
        ISTimedActionQueue.add(HBAddHayAction:new(player, hutch, hay))
    end)

    -- Bedding already full → show it, greyed, so it's discoverable but inert.
    if bedding >= max then
        option.onSelect = nil
        option.notAvailable = true
        local tip = ISToolTip:new()
        tip:setName("Add Hay Bedding")
        tip.description = "Bedding is already full."
        option.toolTip = tip
    end
end)
