-- ============================================================================
-- CREDIT: this file patches "Lifestyle: Hobbies" by [Angry]
--   https://steamcommunity.com/sharedfiles/filedetails/?id=3403870858
-- The patch code here is Requiem of the Dead's own work; the mod it patches is
-- theirs. All original Lifestyle content, code and design belong to its author.
-- ============================================================================

-- RDLS_TransferHelperFix.lua - anti-dupe / anti-mint overlay of TransferHelper.transferItem (server only).
--
-- TransferHelper is a GLOBAL table in Lifestyle: Hobbies (shared/Helper/TransferHelper.lua),
-- so a file that loads AFTER Lifestyle can replace transferItem outright. The Companion
-- requires LifestyleHobbies, so it loads later and this reassignment wins. Stays current
-- across Lifestyle content updates; only breaks if the author changes transferItem's body
-- or signature, which RDSelfTest's hash guard is meant to catch.
--
-- THE BUG (verified against the 42.20 decompile): the `item` handed to the server transfer
-- is a fresh InventoryItem.loadItem() copy rebuilt from the wire - a brand-new object, not
-- a reference to anything in a server container. ItemContainer.Remove / DoRemoveItem match
-- by OBJECT REFERENCE (InventoryItem does not override equals), so removing that copy from
-- the source is a silent no-op, while addItemToContainer still adds it to the destination.
-- Net server state: original stays in source + copy in destination => DUPLICATION. A wholly
-- fabricated item (never in any container) is likewise "kept" => MINTING.
--
-- THE FIX: on the server, before moving anything, resolve `item` to the REAL object living
-- in its claimed source container (by id, recursing into sub-containers), and REFUSE the
-- transfer if it isn't actually there. From then on every Remove/Add operates on the real
-- server object, so identity matches and nothing is duplicated or conjured.
--
-- Client and single-player are untouched: the client branch only sends commands (no dupe
-- risk) and in SP `item` is already the real object (no wire copy). Server-only overlay.

if not isServer() then return end

require "Helper/TransferHelper"   -- ensure Lifestyle's original is defined before we wrap

if not TransferHelper then
    print("[RFTDLifestyleCompanion] TransferHelperFix: TransferHelper global missing; Lifestyle not loaded? Skipping.")
    return
end

-- Resolve the real server-side item in a container by id, recursing into bags.
local function resolveRealItem(container, id)
    if not container or not id then return nil end
    if container.getItemWithID then
        local it = container:getItemWithID(id)
        if it then return it end
    end
    if container.getFirstEvalRecurse then
        local ok, it = pcall(function()
            return container:getFirstEvalRecurse(function(candidate)
                return candidate and candidate.getID and candidate:getID() == id
            end)
        end)
        if ok and it then return it end
    end
    return nil
end

-- Faithful copy of Lifestyle's getDropItemOffset (file-local in the original, so not
-- reachable from here). Kept behaviourally identical.
local function getDropItemOffset(character, square, item)
    local dropX = ZombRandFloat(0.0, 1.0)
    local dropY = ZombRandFloat(0.0, 1.0)
    local dropZ = character:getZ() - math.floor(character:getZ())
    dropZ = square:getApparentZ(dropX, dropY) - square:getZ()
    if character:isSeatedInVehicle() then
        dropZ = math.floor(character:getZ())
    end
    if getCore():getOptionDropItemsOnSquareCenter() then
        dropX = ZombRand(3, 7) / 10.0
        dropY = ZombRand(3, 7) / 10.0
        dropZ = square:getApparentZ(dropX, dropY) - square:getZ()
    end
    return dropX, dropY, dropZ
end

local function addItemToContainer(destContainer, item)
    if not destContainer then return; end
    destContainer:setDrawDirty(true)
    destContainer:AddItem(item)
    if isServer() then sendAddItemToContainer(destContainer, item); end
end

TransferHelper.transferItem = function(character, item, srcContainer, destContainer, dropSquare, autoWear, srcOvr, destOvr)
    LSUtil.debugPrint("(RFTDLS) TransferHelper.transferItem - start")

    local srcContType  = srcOvr or (srcContainer and srcContainer.getType and srcContainer:getType())
    local destContType = destOvr or (destContainer and destContainer.getType and destContainer:getType())
    local worldItem = item.getWorldItem and item:getWorldItem()

    if (not srcOvr and not srcContainer) or (not destOvr and not destContainer) or (srcContainer and destContainer and srcContainer == destContainer) then
        LSUtil.debugPrint("(RFTDLS) TransferHelper.transferItem - not cont or same cont, returning"); return item;
    end
    local fromPlayer = character:getInventory() ~= destContainer

    -- Client branch is unchanged: it only forwards to the server, no state mutation.
    if isClient() and not isServer() then
        if srcContType and srcContType == "floor" then
            local sqr = worldItem and worldItem:getSquare()
            if sqr then sendClientCommand(character, "LS", "TransferItemWorld", {item, fromPlayer, autoWear, {sqr:getX(),sqr:getY(),sqr:getZ()}}); end
        elseif destContType and destContType == "floor" and dropSquare then
            sendClientCommand(character, "LS", "TransferItemWorld", {item, fromPlayer, autoWear, {dropSquare:getX(),dropSquare:getY(),dropSquare:getZ()}})
        else
            local parentObj = srcContainer.getParent and srcContainer:getParent()
            if fromPlayer then parentObj = destContainer.getParent and destContainer:getParent(); end
            if parentObj then
                sendClientCommand(character, "LS", "TransferItem", {item, fromPlayer, autoWear, {parentObj:getX(),parentObj:getY(),parentObj:getZ(),parentObj:getSprite():getName()}})
            end
        end
        return item
    end

    -- ===================================================================
    -- SERVER (and SP) path.
    -- ANTI-DUPE / ANTI-MINT: resolve the wire copy to the real source object.
    -- Only for real container sources; the "floor" path re-finds the world item
    -- by id in the caller (TransferItemWorld) and is handled below unchanged.
    -- ===================================================================
    if srcContainer and srcContType ~= "floor" then
        local id = item and item.getID and item:getID()
        local real = resolveRealItem(srcContainer, id)
        if not real then
            LSUtil.debugPrint("(RFTDLS) TransferHelper.transferItem - item id "..tostring(id)
                .." not present in claimed source container; refusing transfer (anti-dupe/mint)")
            return item
        end
        item = real
        worldItem = item.getWorldItem and item:getWorldItem()
    end

    if srcContainer then
        srcContainer:DoRemoveItem(item);
        if isServer() then sendRemoveItemFromContainer(srcContainer, item); end
    end

    if destContType == "floor" then
        if dropSquare then
            local addToWorld = LSUtil.removeItemOnChar(character, item)
            if addToWorld then
                if destContainer then destContainer:DoAddItemBlind(item); end
                local dropX,dropY,dropZ = getDropItemOffset(character, dropSquare, item)
                dropSquare:AddWorldInventoryItem(item, dropX, dropY, dropZ)
            end
        else
            LSUtil.debugPrint("(RFTDLS) TransferHelper.transferItem - error, not dropSquare")
        end
    elseif srcContType == "floor" and item:getWorldItem() ~= nil then
        DesignationZoneAnimal.removeItemFromGround(item:getWorldItem())
        item:getWorldItem():getSquare():transmitRemoveItemFromSquare(item:getWorldItem())
        item:getWorldItem():getSquare():removeWorldObject(item:getWorldItem())
        item:setWorldItem(nil)
        addItemToContainer(destContainer, item)
    else
        addItemToContainer(destContainer, item)
        if fromPlayer then LSUtil.removeItemOnChar(character, item); end
    end

    if destContainer and destContainer:getParent() and instanceof(destContainer:getParent(), "BaseVehicle") and destContainer:getParent():getPartById(destContType) then
        local part = destContainer:getParent():getPartById(destContType)
        part:setContainerContentAmount(part:getItemContainer():getCapacityWeight())
    end

    if srcContainer and srcContainer:getParent() and instanceof(srcContainer:getParent(), "BaseVehicle") and srcContainer:getParent():getPartById(srcContType) then
        local part = srcContainer:getParent():getPartById(srcContType)
        part:setContainerContentAmount(part:getItemContainer():getCapacityWeight())
    end

    if autoWear then
        local canEquip = item.canBeEquipped and item:canBeEquipped()
        if canEquip and canEquip ~= "" then
            character:setWornItem(item:getBodyLocation(), item)
            if instanceof(item, "InventoryContainer") then getPlayerInventory(character:getPlayerNum()):refreshBackpacks(); end
            triggerEvent("OnClothingUpdated", character)
        end
    end
    return item
end

print("[RFTDLifestyleCompanion] TransferHelper.transferItem hardened (anti-dupe/anti-mint).")
