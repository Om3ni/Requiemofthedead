-- ============================================================================
-- CREDIT: this file patches "Lifestyle: Hobbies" by [Angry]
--   https://steamcommunity.com/sharedfiles/filedetails/?id=3403870858
-- The patch code here is Requiem of the Dead's own work; the mod it patches is
-- theirs. All original Lifestyle content, code and design belong to its author.
-- ============================================================================

-- LSservercommands.lua  (RFTDLifestyleCompanion SHADOW of Lifestyle: Hobbies' server file)
-- ============================================================================
-- This file SHADOWS mods/Lifestyle/.../server/LSservercommands.lua. Because the
-- Companion requires LifestyleHobbies it loads later, and PZ loads only ONE file
-- per relative lua path (the later one wins), so the upstream file NEVER runs.
-- Everything the upstream file did is reproduced here, hardened, and its single
-- unguarded Events.OnClientCommand listener is replaced by RFTDCore's RDNet
-- single-dispatcher permission wall.
--
-- WHAT CHANGES vs upstream:
--   * The "LS" wire token is adopted into RDNet -> default-deny. Every command is
--     registered with a per-command rate limit and (where relevant) a capability
--     gate; unregistered "LS" commands a cheater invents are rejected + logged.
--   * Item/amount/coord/range args are validated and clamped (kills the unbounded
--     -loop DoS, the type-confusion crash, and mass-spawn).
--   * Item ops resolve the REAL server item by id (kills forgery/dupe); the
--     transfer helper itself is additionally hardened in RDLS_TransferHelperFix.
--   * Admin/debug/global-state commands are gated to top-admin.
--   * Cross-player relays require the target to be in proximity of the caller.
--   * DEAD / caller-less griefing commands are intentionally NOT registered:
--       TeleportSittingLocation, makeNauseous, ModifyItemStat, JukeTurnedOn
--     (RDNet default-denies + logs any forged attempt).
--   * Latent upstream typo-bugs fixed inline (bad/bag, movableData/movabledata,
--     traitName, mood/upMood, implicit global objSpriteName).
--
-- SINGLE PLAYER / LISTEN HOST: RDNet's dispatcher only runs under isServer(). When
-- that is false we fall back to the original local-dispatch behaviour, UNHARDENED
-- (SP needs no gating), so the mod plays identically offline. All gates below are
-- written to no-op when not on a dedicated server.
--
-- Ported from LifestyleHobbies modversion 0.4.0. On upstream update, re-diff;
-- RDSelfTest (RDLS_SelfTest.lua) warns loudly if the upstream file changed.
-- ============================================================================

require "RDNet"
require "RDAccess"

local WIRE = "LS"
local SERVER = isServer()

-- ---------------------------------------------------------------------------
-- Validation / hardening helpers (all gates no-op when not on a real server)
-- ---------------------------------------------------------------------------
local MAX_AMOUNT = 64      -- cap on any client-driven spawn/remove loop count
local RANGE_MAX  = 8       -- cap on RemoveDirtTileDebug scan radius (legit uses 6/8)
local DIST_OBJ   = 8       -- proximity (tiles) for world-object edits
local DIST_PLR   = 12      -- proximity (tiles) for cross-player relays
local XP_MAX     = 10000   -- cap on a single AddXP grant
local KEYS_MAX   = 300     -- cap on keys merged into player/global modData

local function isNum(v) return type(v) == "number" end

local function clampInt(v, lo, hi)
    if not isNum(v) then return nil end
    v = math.floor(v)
    if v < lo then v = lo elseif v > hi then v = hi end
    return v
end

local function clampNum(v, lo, hi)
    if not isNum(v) then return nil end
    if v < lo then v = lo elseif v > hi then v = hi end
    return v
end

-- top-admin gate; passes in SP so offline play is unaffected
local function gAdmin(player)
    if not SERVER then return true end
    return RDAccess.isTopAdmin(player) == true
end

-- proximity of a coordinate to the caller; passes in SP
local function nearXY(player, x, y, d)
    if not SERVER then return true end
    if not player or not isNum(x) or not isNum(y) then return false end
    local ok, px, py = pcall(function() return player:getX(), player:getY() end)
    if not ok or not px then return false end
    return math.abs(px - x) <= d and math.abs(py - y) <= d
end

local function nearObj(player, objInfo, d)
    if type(objInfo) ~= "table" then return false end
    return nearXY(player, objInfo[1], objInfo[2], d or DIST_OBJ)
end

-- resolve a target player by online id (returns nil if not found)
local function targetById(id)
    if not isNum(id) then return nil end
    local ok, p = pcall(getPlayerByOnlineID, id)
    if ok then return p end
    return nil
end

-- strip newlines/CR and cap length before writing to a server file
local function sanitizeLine(s, maxLen)
    s = tostring(s or "")
    s = s:gsub("[\r\n]", " ")
    maxLen = maxLen or 128
    if #s > maxLen then s = s:sub(1, maxLen) end
    return s
end

-- forensic note (safe if RDLog missing)
local function note(tag, event, player, data)
    if RDLog and RDLog.forensic then
        pcall(RDLog.forensic, tag, event, player, data, "RFTDLifestyleCompanion")
    end
end

-- ---------------------------------------------------------------------------
-- Ported file-local helpers (from upstream; fixes noted)
-- ---------------------------------------------------------------------------
local function getObjFromSqr(x, y, z, spriteName)
    local square = getCell():getGridSquare(x, y, z)
    if not square then return false; end
    for i=0,square:getObjects():size()-1 do
        local object = square:getObjects():get(i);
        local objSprite = object.getSprite and object:getSprite()
        if objSprite then
            local objSpriteName = objSprite.getName and objSprite:getName()   -- FIX: was implicit global
            if objSpriteName and objSpriteName == spriteName then return object; end
        end
        local objSpriteOrTextureName = object.getSpriteName and object:getSpriteName()
        if not objSpriteOrTextureName then objSpriteOrTextureName = object.getTextureName and object:getTextureName(); end
        if objSpriteOrTextureName and objSpriteOrTextureName == spriteName then return object; end
    end
    for i=0,square:getObjects():size()-1 do
        local object = square:getObjects():get(i);
        local attached = object.getAttachedAnimSprite and object:getAttachedAnimSprite()
        if attached then
            for n=1,attached:size() do
                local sprite = attached:get(n-1)
                if sprite and sprite:getParentSprite() and sprite:getParentSprite():getName() and luautils.stringStarts(sprite:getParentSprite():getName(), spriteName) then
                    return object
                end
            end
        end
    end
    return false
end

local function checkAndRemoveClothingItem(player, container, item, fullType)
    for x=0,container:getItems():size() - 1 do
        local newItem = container:getItems():get(x);
        if newItem then
            if (item and newItem:getID() == item:getID()) or (fullType and newItem.getFullType and newItem:getFullType() == fullType) then
                if player:isEquippedClothing(newItem) then player:removeWornItem(newItem); end
                container:Remove(newItem)
                sendRemoveItemFromContainer(container, newItem)
                break
            end
        end
    end
end

local function checkAndRemoveItem(container, item, fullType)
    for x=0,container:getItems():size() - 1 do
        local newItem = container:getItems():get(x);
        if newItem then
            if (item and newItem:getID() == item:getID()) or (fullType and newItem.getFullType and newItem:getFullType() == fullType) then
                container:Remove(newItem)
                sendRemoveItemFromContainer(container, newItem)
                break
            end
        end
    end
end

local function getItemByID(container, itemID)
    for x=0,container:getItems():size() - 1 do
        local newItem = container:getItems():get(x);
        if newItem and newItem:getID() == itemID then return newItem end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Global ModData init (ported verbatim from upstream)
-- ---------------------------------------------------------------------------
local function LS_OnInitGlobalModData()
    local lsModData = ModData.getOrCreate("LSDATA")
    if not lsModData["SO"] then lsModData["SO"] = {}; end
    if LSgetSandboxOptions then LSgetSandboxOptions(lsModData["SO"]); end
    if not lsModData["AMBT"] then lsModData["AMBT"] = {}; end
    if not lsModData["BTY"] then lsModData["BTY"] = {}; end
end
Events.OnInitGlobalModData.Add(LS_OnInitGlobalModData)

-- ===========================================================================
-- Hardened command bodies. H[name] = function(player, args)
-- Commands deliberately ABSENT (default-deny): TeleportSittingLocation,
-- makeNauseous, ModifyItemStat, JukeTurnedOn.
-- ===========================================================================
local H = {}

-- ---- Item / inventory / transfer -----------------------------------------

H["SyncItemData_FromPlayer"] = function(player, arg)
    local playerInv = player:getInventory()
    local item = LSSync.getItemServer(arg[1], playerInv)
    if not item then
        local items = playerInv:getItems()
        for n=0,items:size()-1 do
            local bag = items:get(n)
            local bagContainer = bag and bag:getContainer()   -- FIX: was `bad and bag`
            if bagContainer then
                item = LSSync.getItemServer(arg[1], bagContainer)
                if item then break; end
            end
        end
    end
    if item then LSSync.transmitItemMovData(item, player, nil, arg[2], arg[3], arg[4]); end
end

H["SyncItemData_FromObj"] = function(player, arg)
    local objInfo = arg[2]
    if not nearObj(player, objInfo) then return end
    local obj = getObjFromSqr(objInfo[1], objInfo[2], objInfo[3], objInfo[4])
    if not obj then return; end
    local item = LSSync.getItemServer(arg[1], obj:getContainer())
    if item then LSSync.updateAndSend(item, arg[3], arg[4], arg[5]); end
end

H["SyncObjMovData"] = function(player, arg)
    local objInfo = arg[1]
    if not nearObj(player, objInfo) then return end
    local obj = getObjFromSqr(objInfo[1], objInfo[2], objInfo[3], objInfo[4])
    if not obj then return; end
    LSSync.updateAndSend(obj, arg[2], arg[3])
end

H["CreateFluidCont_Obj"] = function(player, arg)
    local objInfo = arg[1]
    if not nearObj(player, objInfo) then return end
    local obj = getObjFromSqr(objInfo[1], objInfo[2], objInfo[3], objInfo[4])
    if not obj then return; end
    LSUtil.getOrCreateFluidContainer(obj, arg[2])
end

H["UseFluid_Obj"] = function(player, arg)
    local objInfo = arg[1]
    if not nearObj(player, objInfo) then return end
    local obj = getObjFromSqr(objInfo[1], objInfo[2], objInfo[3], objInfo[4])
    if not obj then return; end
    LSUtil.useObjFluid(obj, arg[2])
end

H["AddItems_Player"] = function(player, arg)
    local playerInv = player:getInventory()
    local itemFullType = arg[1]
    local amount = clampInt(arg[2], 1, MAX_AMOUNT)
    if type(itemFullType) ~= "string" or not amount then return; end
    note("lifestyle", "LS.SPAWN", player, { cmd = "AddItems_Player", item = itemFullType, amount = amount })
    local itemInfo = arg[3]
    local destCont
    if itemInfo then
        local item = LSSync.getItemServer(itemInfo, playerInv)
        destCont = item and item.getInventory and item:getInventory()
    end
    if not destCont then destCont = playerInv; end
    local items = destCont:AddItems(itemFullType, amount)
    sendAddItemsToContainer(destCont, items)
end

H["AddItemToPlayer"] = function(player, arg)
    local itemFN = arg[1]
    local amount = clampInt(arg[2], 1, MAX_AMOUNT)
    if type(itemFN) ~= "string" or not amount then return; end
    note("lifestyle", "LS.SPAWN", player, { cmd = "AddItemToPlayer", item = itemFN, amount = amount })
    local playerInv = player:getInventory()
    playerInv:setDrawDirty(true)
    for n=1,amount do
        local item = playerInv:AddItem(itemFN)
        sendAddItemToContainer(playerInv, item)
    end
end

H["RemoveItemFromPlayer"] = function(player, arg)
    local itemFN = arg[1]
    local amount = clampInt(arg[2], 1, MAX_AMOUNT)
    if type(itemFN) ~= "string" or not amount then return; end
    local playerInv = player:getInventory()
    playerInv:setDrawDirty(true)
    for n=1,amount do checkAndRemoveItem(playerInv, false, itemFN) end
end

H["AddWorldItem"] = function(player, arg)
    local item, amount = arg[1], clampInt(arg[2], 1, MAX_AMOUNT)
    local posX, posY, posZ = arg[3], arg[4], arg[5]
    local sqrX, sqrY, sqrZ = arg[6], arg[7], arg[8]
    if type(item) ~= "string" or not amount then return; end
    if not nearXY(player, sqrX, sqrY, DIST_OBJ) then return; end
    local square = getCell():getGridSquare(sqrX, sqrY, sqrZ)
    if not square then return end
    note("lifestyle", "LS.SPAWN", player, { cmd = "AddWorldItem", item = item, amount = amount })
    for n=1, amount do
        local newPosX, newPosY = posX, posY
        if not posX then newPosX = ZombRandFloat(0.0, 1.0); end
        if not posY then newPosY = ZombRandFloat(0.0, 1.0); end
        square:AddWorldInventoryItem(item, newPosX, newPosY, posZ)
    end
end

H["RemoveItems"] = function(player, arg)
    local t = arg[1]
    if type(t) ~= "table" then return; end
    local inv, hands
    if arg[2] then
        if not nearObj(player, arg[2]) then return end
        local obj = getObjFromSqr(arg[2][1], arg[2][2], arg[2][3], arg[2][4])
        if obj then inv = obj:getContainer(); end
    else
        hands = true
        inv = player:getInventory()
    end
    if not inv then return; end
    for n=1,#t do
        local predicateItem = function(item) return item and item:getID() == t[n] end
        local item = inv:containsEvalRecurse(predicateItem) and inv:getFirstEvalRecurse(predicateItem)
        local cont = item and item:getContainer()
        if cont then
            if hands then player:removeFromHands(item); end
            cont:Remove(item)
            sendRemoveItemFromContainer(cont, item)
        end
    end
end

-- Transfers route through TransferHelper.transferItem, hardened in
-- RDLS_TransferHelperFix.lua (by-id resolution + refuse-if-absent).
H["TransferItemWorld"] = function(player, arg)
    local item = arg[1]; local fromPlayer = arg[2]; local wear = arg[3]; local coords = arg[4]
    if not item or type(coords) ~= "table" then return; end
    if not nearXY(player, coords[1], coords[2], DIST_OBJ) then return; end
    local square = getCell():getGridSquare(coords[1], coords[2], coords[3])
    local floorObjects = square and square.getWorldObjects and square:getWorldObjects()
    local floorItem
    if not fromPlayer then
        if not floorObjects then return; end
        for i=0,floorObjects:size()-1 do
            local worldItem = floorObjects:get(i)
            local newItem = worldItem and worldItem.getItem and worldItem:getItem()
            if newItem and newItem:getID() == item:getID() then
                floorItem = newItem.getWorldItem and newItem:getWorldItem()
                if floorItem then item = newItem; break; end
            end
        end
    end
    local playerInv = player and player.getInventory and player:getInventory()
    if (not fromPlayer and not floorItem) or not playerInv then return; end
    if not fromPlayer then
        TransferHelper.transferItem(player, item, false, playerInv, false, wear, "floor")
    else
        TransferHelper.transferItem(player, item, playerInv, false, square, wear, false, "floor")
    end
end

H["TransferItem"] = function(player, arg)
    local item = arg[1]; local fromPlayer = arg[2]; local wear = arg[3]; local objInfo = arg[4]
    if not item or type(objInfo) ~= "table" then return; end
    if not nearObj(player, objInfo) then return; end
    local obj = getObjFromSqr(objInfo[1], objInfo[2], objInfo[3], objInfo[4])
    local objCont = obj and obj.getContainer and obj:getContainer()
    local playerInv = player and player.getInventory and player:getInventory()
    if not objCont or not playerInv then return; end
    if not fromPlayer then
        TransferHelper.transferItem(player, item, objCont, playerInv, false, wear)
    else
        TransferHelper.transferItem(player, item, playerInv, objCont, false, wear)
    end
end

-- TransferItemFrom: forged-item injection risk -> resolve real item in the
-- object container by id and refuse if absent.
H["TransferItemFrom"] = function(player, arg)
    local item = arg[1]; local wear = arg[2]; local objInfo = arg[3]
    if not item or type(objInfo) ~= "table" then return; end
    if not nearObj(player, objInfo) then return; end
    local obj = getObjFromSqr(objInfo[1], objInfo[2], objInfo[3], objInfo[4])
    local destCont = obj and obj:getContainer()
    if not destCont then return; end
    local realItem = item.getID and destCont:getItemWithID(item:getID())
    if not realItem then
        note("lifestyle", "LS.REJECT", player, { cmd = "TransferItemFrom", reason = "item-not-in-source" })
        return
    end
    item = realItem
    destCont:setDrawDirty(true)
    destCont:Remove(item)
    sendRemoveItemFromContainer(destCont, item)
    local playerInv = player:getInventory()
    playerInv:setDrawDirty(true)
    playerInv:AddItem(item)
    sendAddItemToContainer(playerInv, item)
    if wear then
        if (instanceof(item, "InventoryContainer") and item:canBeEquipped() ~= "") then
            player:setWornItem(item:canBeEquipped(), item);
        else
            player:setWornItem(item:getBodyLocation(), item);
        end
        triggerEvent("OnClothingUpdated", player)
    end
end

H["TransferItemTo"] = function(player, arg)
    local item = arg[1]; local objInfo = arg[2]
    if not item or type(objInfo) ~= "table" then return; end
    if not nearObj(player, objInfo) then return; end
    local playerInv = player:getInventory()
    local realItem = item.getID and getItemByID(playerInv, item:getID())
    if not realItem then
        note("lifestyle", "LS.REJECT", player, { cmd = "TransferItemTo", reason = "item-not-on-player" })
        return
    end
    item = realItem
    local obj = getObjFromSqr(objInfo[1], objInfo[2], objInfo[3], objInfo[4])
    local destCont = obj and obj:getContainer()
    if player:isEquippedClothing(item) then player:removeWornItem(item); end
    playerInv:setDrawDirty(true)
    if destCont then
        playerInv:Remove(item)
        sendRemoveItemFromContainer(playerInv, item)
        destCont:setDrawDirty(true);
        destCont:AddItem(item)
        sendAddItemToContainer(destCont, item)
        checkAndRemoveClothingItem(player, playerInv, item)
    end
end

H["ModifyItemData"] = function(player, arg)
    local oldItem = arg[1]; local movData = arg[2]; local data = arg[3]; local nested = arg[4]
    if not oldItem or not oldItem.getID then return; end
    local item = getItemByID(player:getInventory(), oldItem:getID())
    if not item then return; end
    LSUtil.syncItemModdata(item, movData, data, nested)
end

H["AdjustFluidItem"] = function(player, arg)
    local oldItem = arg[1]; local useDelta = arg[2]
    if not oldItem or not oldItem.getID then return; end
    local item = getItemByID(player:getInventory(), oldItem:getID())
    if not item then return; end
    LSUtil.adjustFluid(item, useDelta, player)
end

H["ChangeTexture_Item"] = function(player, arg)
    local id = arg[1]; local choice = arg[2]
    local item = getItemByID(player:getInventory(), id)
    if not item then return; end
    LSUtil.changeTexture_Item(player, item, choice)
end

H["UseItem_Player"] = function(player, arg)
    local item = LSSync.getItemServer(arg[1], player:getInventory())
    if not LSUtil.isValidDrainableItem(item) then return; end
    LSUtil.useItem(item, player, nil, arg[2])
end

H["CreateFluidCont_Item"] = function(player, arg)
    local item = LSSync.getItemServer(arg[1], player:getInventory())
    if not item then return; end
    LSUtil.getOrCreateFluidContainer(item, arg[2])
end

H["renameItem"] = function(player, arg)
    local item = LSSync.getItemServer(arg[1], player:getInventory())
    if not item then return; end
    LSUtil.renameItem(player, item, sanitizeLine(arg[2], 64))
end

H["CreateArtworkItem"] = function(player, arg)
    local author = sanitizeLine(arg[1], 64)
    local data = arg[2]
    if type(data) ~= "table" then return; end
    local newItem = player:getInventory():AddItem('Moveables.Moveable')
    newItem:ReadFromWorldSprite(data.result)
    local md = newItem:getModData()
    md.movableData = md.movableData or {}
    md.movableData['artAuthor']  = author
    md.movableData['artBeauty']  = clampNum(data["beauty"], -100000, 100000) or 0
    md.movableData['artStyle']   = data["style"]
    md.movableData['artSize']    = data["size"]
    md.movableData['artQuality'] = clampNum(data["quality"], -100000, 100000) or 0
    if data['meltTime'] then md.movableData['meltTime'] = data["meltTime"]; end
    note("lifestyle", "LS.ART", player, { beauty = md.movableData['artBeauty'], quality = md.movableData['artQuality'] })
    sendAddItemToContainer(player:getInventory(), newItem)
    newItem:syncItemFields()
    player:getInventory():setDrawDirty(true);
    sendServerCommand(player, "LS", "OpenArtworkReview", {player:getPlayerNum(), newItem, data.result})
end

-- ---- Character / stats / progression -------------------------------------

H["SetMirrorMakeup"] = function(player, arg) LSMirrorMenu_server.setMirrorChanges(player, arg) end
H["MakeWellFed"]      = function(player, arg) LSUtil.MakeCharWellFed(player, arg) end
H["learnRecipes"]     = function(player, arg) LSUtil.learnRecipes(player, arg) end
H["Character_Explosion"] = function(player, arg) LSUtil.makeCharExplode(player, arg) end
H["Character_MakeWet"]   = function(player, arg) LSUtil.makeCharWet(player, arg[1]) end
H["Character_CleanSelf"] = function(player, arg) LSUtil.changeCharVisualDirt(player, arg[1], arg[2], arg[3]) end
H["dropHeavyItems"]      = function(player, arg) if player then forceDropHeavyItems(player); end end

H["RemoveBrokenGlass"] = function(player, arg)
    local x, y, z = arg[1], arg[2], arg[3]
    if not nearXY(player, x, y, DIST_OBJ) then return end
    local square = getCell():getGridSquare(x, y, z)
    if not square then return end
    for i=0,square:getObjects():size()-1 do
        local object = square:getObjects():get(i)
        if object then
            local texName = object.getTextureName and object:getTextureName()
            if texName and luautils.stringStarts(texName, "brokenglass_") and ISMoveableTools.isObjectMoveable(object) then
                ISMoveableTools.isObjectMoveable(object):pickUpMoveable(player, square, object, true)
                break
            end
        end
    end
end

H["reduceAllStiffness"] = function(player, arg)
    local value = arg[1]
    if not isNum(value) then return; end
    local bodyDamage = player:getBodyDamage()
    if not bodyDamage then return; end
    local bodyParts = bodyDamage:getBodyParts()
    if not bodyParts then return; end
    for i=0,bodyParts:size()-1 do
        local bodyPart = bodyParts:get(i)
        if bodyPart then
            local stiff = bodyPart:getStiffness()
            if stiff and stiff > 0 then
                bodyPart:setStiffness(math.max(0, stiff-value))
                player:getFitness():removeStiffnessValue(BodyPartType.ToString(bodyPart:getType()))
            end
        end
    end
end

H["AddGeneralHealth"] = function(player, arg)
    local value = arg[1]
    if not isNum(value) then return; end
    local bodyDamage = player:getBodyDamage()
    if not bodyDamage then return; end
    bodyDamage:AddGeneralHealth(value)
end

H["addPainBodyPart"] = function(player, arg)
    local bP = arg[1]; local value = arg[2]
    if not isNum(value) then return; end
    local bodyDamage = player:getBodyDamage()
    if not bodyDamage then return; end
    if not BodyPartType[bP] then return; end
    local bodyPart = bodyDamage:getBodyPart(BodyPartType[bP])
    if bodyPart then bodyPart:setAdditionalPain(value); end
end

H["ChangeCharacterMoodGroup"] = function(player, arg)
    local stats = player:getStats()
    if not stats then return; end
    local moodList = arg[1]
    if type(moodList) ~= "table" then return; end
    for n=1, #moodList do
        local moodInfo = moodList[n]
        if moodInfo and moodInfo[1] and moodInfo[2] and CharacterStat[moodInfo[2]] and type(stats[moodInfo[1]]) == "function" and moodInfo[3] then
            stats[moodInfo[1]](stats, CharacterStat[moodInfo[2]], moodInfo[3])
            sendPlayerStat(player, CharacterStat[moodInfo[2]])
        end
    end
end

H["ChangeCharacterMood"] = function(player, arg)
    local method = arg[1]; local upMood = arg[2]; local value = arg[3]
    local stats = player:getStats()
    if not stats then return; end
    if not CharacterStat[upMood] then return; end
    if type(stats[method]) ~= "function" then return; end
    if upMood == "WETNESS" then   -- FIX: was `mood` (nil global) -> dead branch
        local bodyDamage = player:getBodyDamage()
        local wetMethod = "decreaseBodyWetness"
        if method == "add" then wetMethod = "increaseBodyWetness"; elseif method == "set" then wetMethod = "setWetness"; end
        if type(bodyDamage[wetMethod]) == "function" then bodyDamage[wetMethod](bodyDamage, value); end
    end
    stats[method](stats, CharacterStat[upMood], value)
    sendPlayerStat(player, CharacterStat[upMood])
end

H["AddXP"] = function(player, arg)
    local perkName = arg[1]; local xp = clampNum(arg[2], 0, XP_MAX)
    if not Perks[perkName] or not xp then return; end
    note("lifestyle", "LS.XP", player, { perk = perkName, xp = xp })
    addXp(player, Perks[perkName], xp)
    SyncXp(player)
end

H["AddXPBatch"] = function(player, arg) LSUtil.giveXPBatch(player, arg) end

H["SavePlayerData"] = function(player, arg)
    local data = arg[1]
    if type(data) ~= "table" then return; end
    local playerData = player:getModData()
    local n = 0
    for k, v in pairs(data) do
        n = n + 1
        if n > KEYS_MAX then note("lifestyle", "LS.REJECT", player, { cmd = "SavePlayerData", reason = "too-many-keys" }); break; end
        if type(k) == "string" then playerData[k] = v; end
    end
end

H["ChangeMaxWeight"] = function(player, arg)
    local newWeight = clampNum(arg[1], 1, 100)
    if newWeight then player:setMaxWeightBase(newWeight); end
end

H["ChangeTrait"] = function(player, arg)
    local trait = arg[1]; local method = arg[2]
    local self = player:getCharacterTraits()
    if not CharacterTrait[trait] then return; end
    if type(self[method]) ~= "function" then return; end
    local hasTrait = player:hasTrait(CharacterTrait[trait])
    if method == "add" and hasTrait then return; end
    if method == "remove" and not hasTrait then return; end
    self[method](self, CharacterTrait[trait]);
    player:modifyTraitXPBoost(CharacterTrait[trait], method == "remove");   -- FIX: was CharacterTrait[traitName] (nil)
    SyncXp(player)
end

H["RemoveMakeup"] = function(player, arg)
    local group = arg[1]; local all = arg[2]
    local makeupList = { face = {"FullFace","Eyes","EyesShadow","Lips"}, mouth = {"Lips"}, eyes = {"Eyes","EyesShadow"} }
    local function doRemove(item)
        if item then
            player:removeWornItem(item)
            player:getInventory():Remove(item)
            sendRemoveItemFromContainer(player:getInventory(), item)
        end
    end
    local wornItems = player:getWornItems()
    for i = wornItems:size() - 1, 0, -1 do
        local worn = wornItems:get(i)
        local item = worn and worn.getItem and worn:getItem()
        local location = item and item.getBodyLocation and item:getBodyLocation()
        if location and luautils.stringStarts(location:getTranslationName(), "MakeUp") then
            for _,makeup in ipairs(MakeUpDefinitions.makeup) do
                if makeup.item == item:getFullType() then
                    if all then doRemove(item); break;
                    elseif makeupList[group] then
                        for n=1,#makeupList[group] do
                            if makeup.category == makeupList[group][n] then doRemove(item); break; end
                        end
                    end
                end
            end
        end
    end
end

-- ---- World / objects / dirt ------------------------------------------------

H["ModifySprite"] = function(player, arg)
    local objInfo = arg[1]; local sprite = arg[2]; local overlaySprite = arg[3]; local get = arg[4]
    if not nearObj(player, objInfo) then return end
    local obj = getObjFromSqr(objInfo[1], objInfo[2], objInfo[3], objInfo[4])
    if not obj then return; end
    if get then
        sprite = getSprite(sprite)
    else
        if not overlaySprite then overlaySprite = ""; end
        obj:setOverlaySprite(overlaySprite, true)
    end
    obj:setSprite(sprite)
    obj:transmitUpdatedSpriteToClients()
end

H["ModifyOverlaySprite"] = function(player, arg)
    local objInfo = arg[1]; local overlaySprite = arg[2]
    if not nearObj(player, objInfo) then return end
    local obj = getObjFromSqr(objInfo[1], objInfo[2], objInfo[3], objInfo[4])
    if not obj or not obj.setOverlaySprite then return; end
    if not overlaySprite then overlaySprite = ""; end
    obj:setOverlaySprite(overlaySprite, true)
    obj:transmitUpdatedSpriteToClients()
end

H["RemoveObject"] = function(player, arg)
    if not nearXY(player, arg[1], arg[2], DIST_OBJ) then return end
    local obj = getObjFromSqr(arg[1], arg[2], arg[3], arg[4])
    if not obj then return; end
    local movData = obj:getModData().movableData
    if not movData or not movData['artBeauty'] then return; end
    local square = getCell():getGridSquare(arg[1], arg[2], arg[3])
    square:transmitRemoveItemFromSquare(obj)
    square:RemoveTileObject(obj)
end

H["ModifyObjData"] = function(player, arg)
    local objInfo = arg[1]; local movabledata = arg[2]; local data = arg[3]; local nested = arg[4]
    if not nearObj(player, objInfo) then return end
    local obj = getObjFromSqr(objInfo[1], objInfo[2], objInfo[3], objInfo[4])
    if not obj then return; end
    local itemData = obj:getModData()
    if movabledata then                                   -- FIX: was `movableData` (nil global) -> dead branch
        itemData.movableData = itemData.movableData or {}
        for k, v in pairs(movabledata) do itemData.movableData[k] = v end
    end
    if data then
        if nested then
            itemData[nested] = itemData[nested] or {}
            for k, v in pairs(data) do itemData[nested][k] = v end
        else
            for k, v in pairs(data) do itemData[k] = v end
        end
    end
    obj:transmitModData()
end

H["SyncSqrData"] = function(player, arg)
    local sqrInfo = arg[1]; local data = arg[2]
    if type(sqrInfo) ~= "table" or not nearXY(player, sqrInfo[1], sqrInfo[2], DIST_OBJ) then return end
    local square = getCell():getGridSquare(sqrInfo[1], sqrInfo[2], sqrInfo[3])
    if not square then return end
    local sqrData = square:getModData()
    if data and sqrData then
        for k, v in pairs(data) do sqrData[k] = v end
    end
    square:transmitModdata()
end

H["AddDirtPuddle"] = function(player, arg)
    local coords = arg[1]; local isOverlay = arg[2]
    if type(coords) ~= "table" or not nearXY(player, coords[1], coords[2], DIST_OBJ) then return end
    local entity
    if isOverlay then
        entity = getObjFromSqr(coords[1], coords[2], coords[3], coords[4])
    else
        entity = getCell():getGridSquare(coords[1], coords[2], coords[3])
    end
    if not entity then return; end
    LSServerCommandHandler("CreateDirtPuddle", {entity, isOverlay, arg[3]})
end

-- DebugAddLitter: player-facing (dirt from actions). Bounded 3x3 scan already;
-- add proximity + coord validation.
H["DebugAddLitter"] = function(player, arg)
    local Sx, Sy, Sz = arg[1], arg[2], arg[3]
    local SolidOrOverlay = arg[4]; local LitterSprite = arg[5]
    if not isNum(Sx) or not isNum(Sy) or not isNum(Sz) then return; end
    if not nearXY(player, Sx, Sy, DIST_OBJ) then return; end
    local AvailableFloorList = {}
    local targetFloor
    local sSquare = getCell():getGridSquare(Sx, Sy, Sz)
    for x = Sx-1,Sx+1 do
        for y = Sy-1,Sy+1 do
            local thisSquare = getCell():getGridSquare(x, y, Sz)
            if thisSquare and sSquare and thisSquare:getRoom() == sSquare:getRoom() and thisSquare:isOutside() == sSquare:isOutside() and thisSquare:isInARoom() and thisSquare:getFloor() and not
            thisSquare:isSolid() and not thisSquare:isSolidTrans() then
                for i=0,thisSquare:getObjects():size()-1 do
                    local ThisObject = thisSquare:getObjects():get(i);
                    if instanceof(ThisObject, "IsoObject") then
                        local object = ThisObject
                        local hasSolidL = false
                        if object then
                            local hasOverlayL = false
                            local attachedsprite = object:getAttachedAnimSprite()
                            if object:getTextureName() and
                            (luautils.stringStarts(object:getTextureName(), "overlay_messages") or
                            luautils.stringStarts(object:getTextureName(), "overlay_graffiti") or
                            luautils.stringStarts(object:getTextureName(), "overlay_blood") or
                            luautils.stringStarts(object:getTextureName(), "blood_floor") or
                            luautils.stringStarts(object:getTextureName(), "overlay_grime") or
                            luautils.stringStarts(object:getTextureName(), "trash&junk") or
                            luautils.stringStarts(object:getTextureName(), "d_floorleaves") or
                            luautils.stringStarts(object:getTextureName(), "d_trash")) then
                                hasSolidL = true
                            end
                            if object:getOverlaySprite() and object:getOverlaySprite():getName() and
                            (luautils.stringStarts(object:getOverlaySprite():getName(), "overlay_messages") or
                            luautils.stringStarts(object:getOverlaySprite():getName(), "overlay_graffiti") or
                            luautils.stringStarts(object:getOverlaySprite():getName(), "overlay_blood") or
                            luautils.stringStarts(object:getOverlaySprite():getName(), "blood_floor") or
                            luautils.stringStarts(object:getOverlaySprite():getName(), "overlay_grime") or
                            luautils.stringStarts(object:getOverlaySprite():getName(), "trash_") or
                            luautils.stringStarts(object:getOverlaySprite():getName(), "trash&junk") or
                            luautils.stringStarts(object:getOverlaySprite():getName(), "d_floorleaves") or
                            luautils.stringStarts(object:getOverlaySprite():getName(), "d_trash") or
                            luautils.stringStarts(object:getOverlaySprite():getName(), "LS_HScraps") or
                            luautils.stringStarts(object:getOverlaySprite():getName(), "LS_Scraps")) then
                                hasOverlayL = true
                            end
                            if object and attachedsprite and object:isFloor() then
                                for n=1,attachedsprite:size() do
                                    local sprite = attachedsprite:get(n-1)
                                    if sprite and sprite:getParentSprite() and sprite:getParentSprite():getName() and
                                    (luautils.stringStarts(sprite:getParentSprite():getName(), "overlay_messages") or
                                    luautils.stringStarts(sprite:getParentSprite():getName(), "overlay_graffiti") or
                                    luautils.stringStarts(sprite:getParentSprite():getName(), "overlay_blood") or
                                    luautils.stringStarts(sprite:getParentSprite():getName(), "blood_floor") or
                                    luautils.stringStarts(sprite:getParentSprite():getName(), "overlay_grime") or
                                    luautils.stringStarts(sprite:getParentSprite():getName(), "trash_") or
                                    luautils.stringStarts(sprite:getParentSprite():getName(), "trash&junk") or
                                    luautils.stringStarts(sprite:getParentSprite():getName(), "d_floorleaves") or
                                    luautils.stringStarts(sprite:getParentSprite():getName(), "LS_HScraps") or
                                    luautils.stringStarts(sprite:getParentSprite():getName(), "d_trash")) then
                                        hasOverlayL = true
                                    end
                                end
                            end
                            if SolidOrOverlay == 2 and not hasOverlayL then table.insert(AvailableFloorList, object) end
                        end
                        if SolidOrOverlay == 1 and not hasSolidL then table.insert(AvailableFloorList, thisSquare) end
                    end
                end
            end
        end
    end
    if #AvailableFloorList > 0 then
        local randomTile = ZombRand(#AvailableFloorList) + 1
        targetFloor = AvailableFloorList[randomTile]
        if targetFloor then
            if SolidOrOverlay == 1 then
                local NewLitterObj = IsoObject.new(targetFloor, LitterSprite)
                targetFloor:AddTileObject(NewLitterObj)
                NewLitterObj:transmitCompleteItemToClients()
                targetFloor:transmitAddObjectToSquare(NewLitterObj, -1)
            elseif SolidOrOverlay == 2 then
                local square = targetFloor:getSquare()
                local objOnFloor
                if square then
                    for i=1,square:getObjects():size() do
                        local thisObject = square:getObjects():get(i-1)
                        if thisObject then
                            local objSprite = thisObject:getSprite()
                            if objSprite then
                                local objProperties = objSprite:getProperties()
                                if objProperties:has("BlocksPlacement") then objOnFloor = true end
                            end
                        end
                    end
                    if not objOnFloor then
                        targetFloor:setOverlaySprite(LitterSprite, 1, 1, 1, 1)
                        targetFloor:transmitUpdatedSpriteToClients()
                    end
                end
            end
        end
    end
end

-- RemoveDirtTileDebug: player-facing (Clean Room menu / cleaning action).
-- HARD-CLAMP the attacker-controllable scan radius (kills the O(range^2) DoS).
H["RemoveDirtTileDebug"] = function(player, arg)
    local x, y, z = arg[1], arg[2], arg[3]
    local range = clampInt(arg[4], 0, RANGE_MAX)
    if not isNum(x) or not isNum(y) or not isNum(z) or not range then return; end
    if not nearXY(player, x, y, RANGE_MAX + DIST_OBJ) then return; end
    local square = getCell():getGridSquare(x,y,z)
    if not square then return; end
    local sqrX, sqrY = square:getX(), square:getY()
    local listFull = {"overlay_grime","trash&junk","trash_","d_floorleaves","d_trash","LS_Scraps","brokenglass_",
    "overlay_messages","overlay_graffiti","overlay_blood","LS_HScraps","blood_floor"}
    for xx = sqrX-range,sqrX+range do
        for yy = sqrY-range,sqrY+range do
            local thisSqr = getCell():getGridSquare(xx,yy,z)
            if thisSqr then
                local mustRemove = {}
                for j=0,thisSqr:getObjects():size()-1 do
                    local object = thisSqr:getObjects():get(j)
                    if object then
                        local texName = object:getTextureName()
                        local spriteName = object:getOverlaySprite() and object:getOverlaySprite():getName()
                        local hasChange
                        for n=1, #listFull do
                            if texName and luautils.stringStarts(texName, listFull[n]) then table.insert(mustRemove, object); break; end
                            if spriteName and luautils.stringStarts(spriteName, listFull[n]) then object:setOverlaySprite("", true); hasChange = true; spriteName = false; end
                            local attachedsprite = object:getAttachedAnimSprite()
                            if attachedsprite then
                                for i=0,attachedsprite:size()-1 do
                                    local sprite = attachedsprite:get(i)
                                    local spriteParentName = sprite and sprite:getParentSprite() and sprite:getParentSprite():getName()
                                    if spriteParentName and luautils.stringStarts(spriteParentName, listFull[n]) then hasChange = true; object:RemoveAttachedAnim(i); break; end
                                end
                            end
                        end
                        if hasChange then object:transmitUpdatedSpriteToClients(); end
                    end
                end
                if #mustRemove > 0 then
                    for n=1, #mustRemove do
                        thisSqr:transmitRemoveItemFromSquare(mustRemove[n]); thisSqr:RemoveTileObject(mustRemove[n]);
                    end
                end
            end
        end
    end
end

H["RemoveDirtTile"] = function(player, arg)
    local x, y, z = arg[1], arg[2], arg[3]; local isHeavy = arg[4]
    if not isNum(x) or not isNum(y) or not isNum(z) then return; end
    if not nearXY(player, x, y, DIST_OBJ) then return; end
    local thisSqr = getCell():getGridSquare(x, y, z)
    if not thisSqr then return; end
    local listDirt = {"overlay_grime","trash&junk","trash_","d_floorleaves","d_trash","LS_Scraps"}
    local listBlood = {"overlay_messages","overlay_graffiti","overlay_blood","LS_HScraps","blood_floor"}
    local list = isHeavy and listBlood or listDirt
    local mustRemove = {}
    for j=0,thisSqr:getObjects():size()-1 do
        local object = thisSqr:getObjects():get(j)
        if object then
            local attachedsprite = object:getAttachedAnimSprite()
            local texName = object:getTextureName()
            local spriteName = object:getOverlaySprite() and object:getOverlaySprite():getName()
            for n=1, #list do
                if texName and luautils.stringStarts(texName, list[n]) then table.insert(mustRemove, object); break; end
                if spriteName and luautils.stringStarts(spriteName, list[n]) then object:setOverlaySprite("", true); object:transmitUpdatedSpriteToClients(); break; end
                if attachedsprite then
                    local removed
                    for i=0,attachedsprite:size()-1 do
                        local sprite = attachedsprite:get(i)
                        local spriteParentName = sprite and sprite:getParentSprite() and sprite:getParentSprite():getName()
                        if spriteParentName and luautils.stringStarts(spriteParentName, list[n]) then removed = true; object:RemoveAttachedAnim(i); object:transmitUpdatedSpriteToClients(); break; end
                    end
                    if removed then break; end
                end
            end
        end
    end
    if #mustRemove > 0 then
        for n=1, #mustRemove do thisSqr:transmitRemoveItemFromSquare(mustRemove[n]); thisSqr:RemoveTileObject(mustRemove[n]); end
    end
end

-- ---- Cross-player animation (proximity-gated) -----------------------------

H["ChangeAnimVarMulti"] = function(player, arg)
    local SourcePlayerName = arg[1]
    local AnimType, AnimVar   = arg[2], arg[3]
    local AnimType2, AnimVar2 = arg[4], arg[5]
    sendServerCommand("LS", "ChangeAnimVarMulti", {SourcePlayerName, AnimType, AnimVar, AnimType2, AnimVar2})
    local otherPlayers = getOnlinePlayers()
    if not otherPlayers then return; end
    for index = 1, otherPlayers:size() do
        local sourcePlayer = otherPlayers:get(index-1)
        if sourcePlayer and sourcePlayer:getDisplayName() == SourcePlayerName then
            if SERVER and not nearXY(player, sourcePlayer:getX(), sourcePlayer:getY(), DIST_PLR) then return end
            if AnimVar then
                sourcePlayer:setVariable(AnimType, AnimVar)
                if AnimType == "SittingToggleStart" and ((AnimVar == "N") or (AnimVar == "S")) then sourcePlayer:reportEvent("EventSitOnGround") end
            else
                sourcePlayer:clearVariable(AnimType)
            end
            if AnimVar2 then
                sourcePlayer:setVariable(AnimType2, AnimVar2)
                if AnimType2 == "SittingToggleStart" and ((AnimVar2 == "N") or (AnimVar2 == "S")) then sourcePlayer:reportEvent("EventSitOnGround") end
            else
                sourcePlayer:clearVariable(AnimType2)
            end
            break
        end
    end
end

H["ChangeAnimVar"] = function(player, arg)
    local TargetName = targetById(arg[1])
    local SourcePlayerName = arg[2]; local args = arg[3]
    if TargetName then sendServerCommand(TargetName, "LS", "ChangeAnimVar", {SourcePlayerName, args}) end
    if type(args) ~= "table" then return; end
    local otherPlayers = getOnlinePlayers()
    if not otherPlayers then return; end
    for index = 1, otherPlayers:size() do
        local sourcePlayer = otherPlayers:get(index-1)
        if sourcePlayer and sourcePlayer:getDisplayName() == SourcePlayerName then
            if SERVER and not nearXY(player, sourcePlayer:getX(), sourcePlayer:getY(), DIST_PLR) then return end
            for n=1, #args, 2 do
                if n == #args then break; end
                if args[n] and type(args[n]) == "string" then
                    if args[n+1] then
                        sourcePlayer:setVariable(args[n], args[n+1])
                        if args[n] == "SittingToggleStart" then sourcePlayer:reportEvent("EventSitOnGround"); end
                    else
                        sourcePlayer:clearVariable(args[n])
                    end
                end
            end
            break
        end
    end
end

-- ---- Social / music / dance relays (target by online id) ------------------

local function relayToTarget(player, idArg, outCmd, outArgs, proximity)
    local target = targetById(idArg)
    if not target then return end
    if proximity and SERVER and not nearXY(player, target:getX(), target:getY(), DIST_PLR) then return end
    sendServerCommand(target, "LS", outCmd, outArgs)
end

H["SendGetEmbarrassed"] = function(player, arg)
    relayToTarget(player, arg[1], "GetEmbarrassed", {arg[1]}, true)
end
H["Social_sendInfo"] = function(player, arg)
    relayToTarget(player, arg[1], "Social_InfoSent", {arg[2]})
end
H["Social_requestInfo"] = function(player, arg)
    relayToTarget(player, arg[1], "Social_InfoRequested", {player:getOnlineID()})
end
H["InteractionStart"] = function(player, arg)
    relayToTarget(player, arg[1], "WasAskedToInteract", {arg[1], arg[2], arg[3], arg[4], arg[5]}, true)
end
H["StopOrStartInteraction"] = function(player, arg)
    relayToTarget(player, arg[1], "ChangeInteractionState", {arg[1], arg[2]})
end
H["CompleteTargetAmbt"] = function(player, arg)
    if not gAdmin(player) then return end
    relayToTarget(player, arg[1], "CompleteAmbtSelf", {arg[1], arg[2]})
end
H["ResetTargetAmbt"] = function(player, arg)
    if not gAdmin(player) then return end
    relayToTarget(player, arg[1], "ResetAmbtSelf", {arg[1], arg[2]})
end
H["IsPlayingMusic"] = function(player, arg)
    relayToTarget(player, arg[1], "IsListeningToMusic", {arg[1], arg[2]})
end
H["IsStartingDuet"] = function(player, arg)
    relayToTarget(player, arg[1], "IsStartingDuet", {arg[1], arg[2]})
end
H["IsPlayingDJ"] = function(player, arg)
    relayToTarget(player, arg[1], "IsListeningToDJ", {arg[1], arg[2], arg[3], arg[4]})
end
H["AskIfIsDancing"] = function(player, arg)
    relayToTarget(player, arg[1], "WasAskedIfIsDancing", {arg[1], arg[2]}, true)
end
H["OtherPlayerIsDancing"] = function(player, arg)
    relayToTarget(player, arg[1], "OtherPlayerIsDancingResponse", {arg[1], arg[2]})
end
H["AskToDance"] = function(player, arg)
    relayToTarget(player, arg[1], "WasAskedToDance", {arg[1], arg[2]}, true)
end
H["AcceptedDance"] = function(player, arg)
    relayToTarget(player, arg[1], "DanceWasAccepted", {arg[1], arg[2], arg[3], arg[4]})
end
H["StopDance"] = function(player, arg)
    relayToTarget(player, arg[1], "PartnerStoppedDancing", {arg[1]})
end
H["FaceDanceProposer"] = function(player, arg)
    relayToTarget(player, arg[1], "FaceDancingProposer", {arg[1], arg[2], arg[3]})
end

H["LSSCTest"] = function(_, _) end   -- no-op self test kept for compatibility

-- ---- Jukebox / disco (object at coords, proximity-gated) ------------------

local function findNamedObject(x, y, z, customName)
    local sqr = getCell():getGridSquare(x, y, z)
    if not sqr then return nil, nil end
    for i=1,sqr:getObjects():size() do
        local thisObject = sqr:getObjects():get(i-1)
        local thisSprite = thisObject and thisObject:getSprite()
        if thisSprite then
            local properties = thisSprite:getProperties()
            if properties and properties:has("CustomName") and properties:get("CustomName") == customName then
                return thisObject, sqr
            end
        end
    end
    return nil, sqr
end

H["ChangeDiscoStyle"] = function(player, arg)
    local style, x, y, z, s = arg[1], arg[2], arg[3], arg[4], arg[5]
    if not nearXY(player, x, y, DIST_OBJ) then return end
    sendServerCommand("LS", "ChangeDiscoStyle", {style, x, y, z, s})
    local DiscoBall = findNamedObject(x, y, z, "Disco Ball")
    if not DiscoBall then return end   -- FIX: upstream nil-derefs here
    if DiscoBall:hasModData() and DiscoBall:getModData().OnOff == "on" then
        DiscoBall:getModData().Mode = style
        DiscoBall:getModData().Shuffle = s
    end
end

H["TurnDiscoBallOff"] = function(player, arg)
    local playerDiscoCommand, x, y, z = arg[1], arg[2], arg[3], arg[4]
    if not nearXY(player, x, y, DIST_OBJ) then return end
    sendServerCommand("LS", "TurnDiscoBallOff", {playerDiscoCommand, x, y, z})
    local DiscoBall = findNamedObject(x, y, z, "Disco Ball")
    if not DiscoBall then return end
    if DiscoBall:hasModData() and DiscoBall:getModData().OnOff == "on" then
        DiscoBall:getModData().OnOff = playerDiscoCommand
    end
end

H["JukeboxStart"] = function(player, arg)
    local x, y, z = arg[1], arg[2], arg[3]
    if not nearXY(player, x, y, DIST_OBJ) then return end
    sendServerCommand("LS", "JukeboxStart", {x, y, z})
end

H["TurnJukeboxOff"] = function(player, arg)
    local x, y, z = arg[1], arg[2], arg[3]
    if not nearXY(player, x, y, DIST_OBJ) then return end
    sendServerCommand("LS", "TurnJukeboxOff", {x, y, z})
    local Jukebox = findNamedObject(x, y, z, "Jukebox")
    if not Jukebox then return end
    if Jukebox:hasModData() and Jukebox:getModData().OnOff == "on" then
        Jukebox:getModData().OnOff = "off"
        Jukebox:getModData().OnPlay = "nothing"
    end
end

H["JukeboxStyleChangePlayerPlaylist"] = function(player, arg)
    local x, y, z, style, length, genre, customPlaylist = arg[1], arg[2], arg[3], arg[4], arg[5], arg[6], arg[7]
    if not nearXY(player, x, y, DIST_OBJ) then return end
    sendServerCommand("LS", "JukeboxStyleChangeCustom", {x, y, z, style, length, genre, customPlaylist})
    local Jukebox = findNamedObject(x, y, z, "Jukebox")
    if not Jukebox then return end
    if Jukebox:hasModData() and Jukebox:getModData().OnOff == "on" then
        Jukebox:getModData().OnPlay = "playing"
        Jukebox:getModData().Style = style
        Jukebox:getModData().customPlaylist = customPlaylist
    end
end

H["JukeboxStyleChange"] = function(player, arg)
    local x, y, z, style, length, genre = arg[1], arg[2], arg[3], arg[4], arg[5], arg[6]
    if not nearXY(player, x, y, DIST_OBJ) then return end
    sendServerCommand("LS", "JukeboxStyleChange", {x, y, z, style, length, genre})
    local Jukebox = findNamedObject(x, y, z, "Jukebox")
    if not Jukebox then return end
    if Jukebox:hasModData() and Jukebox:getModData().OnOff == "on" then
        Jukebox:getModData().OnPlay = "playing"
        Jukebox:getModData().Style = style
    end
end

H["StopJukeSong"] = function(player, arg)
    local x, y, z = arg[1], arg[2], arg[3]
    if not nearXY(player, x, y, DIST_OBJ) then return end
    sendServerCommand("LS", "StopJukeSong", {x, y, z})
end

H["isPlayingJuke"] = function(player, arg)
    local genre = arg[2]; local JukeReusableID = arg[1]; local playercommand = arg[6]
    local x, y, z = arg[3], arg[4], arg[5]
    if not nearXY(player, x, y, DIST_OBJ) then return end
    if playercommand == "beforeplay" or playercommand == "stop" then
        sendServerCommand("LS", "isPlayingJuke", {genre, x, y, z, JukeReusableID, playercommand})
    end
end

-- ---- Global / admin state --------------------------------------------------

H["UpdateAmbt"] = function(player, args)
    if not gAdmin(player) then return end
    local lsModData = ModData.getOrCreate("LSDATA")
    local ogAmbt = args[1]; local name = args[2]; local key = args[3]; local value = args[4]; local forceReset = args[5]
    if type(name) ~= "string" then return; end
    if (not lsModData["AMBT"][name]) or (not lsModData["AMBT"][name].custom) then lsModData["AMBT"][name] = ogAmbt; end
    if type(lsModData["AMBT"][name]) ~= "table" then return; end
    if (key ~= "resetAdm") and (lsModData["AMBT"][name][key] == value) then return; end
    lsModData["AMBT"][name][key] = value
    if (key == "resetAdm") and value then lsModData["AMBT"][name].custom = false;
    else lsModData["AMBT"][name].custom = true; lsModData["AMBT"][name].resetAdm = false; end
    lsModData["AMBT"][name].resetF = forceReset
    ModData.transmit("LSDATA")
    sendServerCommand("LS", "ResetAmbt", {name, lsModData["AMBT"][name].resetAdm})
end

H["ChangePlayerState"] = function(playerObj, args)
    if type(args) ~= "table" then return; end
    local n = 0
    for _ in pairs(args) do n = n + 1 end
    if n > KEYS_MAX then note("lifestyle", "LS.REJECT", playerObj, { cmd = "ChangePlayerState", reason = "too-many-keys" }); return; end
    local d = ModData.getOrCreate("LSDATA")
    d[playerObj:getUsername()] = args
    ModData.transmit("LSDATA")
end

-- logCustomBeauty (ported; sanitized writes)
local function logCustomBeauty(data, args)
    if isClient() then return; end
    if not data then return; end
    local key = sanitizeLine(args[1], 64):gsub("=", "")   -- key must not contain the delimiter or newlines
    local file = getFileReader("LSCustomBeautyValues.ini", true)
    if not file then return; end
    local oldValue
    while true do
        local line = file:readLine()
        if not line then file:close(); break; end
        local splitedLine = string.split(line, "=")
        if splitedLine[1] == key then oldValue = true; file:close(); break; end
    end
    if not oldValue then
        file = getFileWriter("LSCustomBeautyValues.ini", true, true)
        file:write(key .. "=" .. tostring(clampNum(args[2], -100000, 100000) or 0) .. "\n")
    else
        file = getFileWriter("LSCustomBeautyValues.ini", true, false)
        for k, v in pairs(data) do
            file:write(sanitizeLine(k, 64):gsub("=", "") .. "=" .. tostring(v) .. "\n")
        end
    end
    file:close()
end

H["UpdateServerBeauty"] = function(player, args)
    if not gAdmin(player) then return end
    local spriteName = args[1]; local val = clampNum(args[2], -100000, 100000)
    if type(spriteName) ~= "string" or not val then return; end
    local lsModData = ModData.getOrCreate("LSDATA")
    lsModData["BTY"][spriteName] = val
    ModData.transmit("LSDATA")
    sendServerCommand("LS", "UpdateClientBeauty", {spriteName, val})
    logCustomBeauty(lsModData["BTY"], {spriteName, val})
end

local function getBeautyLines()
    local file = getFileReader("LSCustomBeautyValues.ini", false)
    if not file then return false; end
    local t, n = {}, 0
    while true do
        local line = file:readLine()
        if not line then file:close(); break; end
        local splitedLine = string.split(line, "=")
        t[splitedLine[1]] = tonumber(splitedLine[2])
        n = n + 1
    end
    return t, n
end

H["ImportServerBeauty"] = function(player, args)
    if not gAdmin(player) then return end
    if isClient() then return; end
    local lsModData = ModData.getOrCreate("LSDATA")
    local allLines, num = getBeautyLines()
    if not allLines or num == 0 then return; end
    lsModData["BTY"] = allLines
    ModData.transmit("LSDATA")
    sendServerCommand("LS", "ReloadClientBeauty", {})
end

H["logAmbition"] = function(_, arg)
    local currentTime = " on ["..tostring(PZCalendar.getInstance():getTime()).."] "
    local admin = arg[5] and " with admin rights." or ""
    local id     = sanitizeLine(arg[1], 64)
    local pName  = sanitizeLine(arg[2], 64)
    local charN  = sanitizeLine(arg[6], 64)
    local ambt   = sanitizeLine(arg[4], 64)
    local text = id.." - [Player:"..pName.."/Char:"..charN.."] concluded ambition ["..ambt.."] "..currentTime..admin
    local file = getFileWriter("LSAmbitionLog.log", true, true)
    if not file then return; end
    file:write(text.."\n")
    file:close()
end

H["UpdateOuthouseRangeMap"] = function(player, args)
    local x, y = args[1], args[2]
    if not isNum(x) or not isNum(y) then return; end   -- FIX: type-check kills the crash-poison
    local lsModData = ModData.getOrCreate("LSDATA")
    if not lsModData["SO"] or not lsModData["SO"]["OUTHOUSEAREAS"] then return; end
    if LSHygiene.TF.isInOuthouseArea(x, y, lsModData["SO"]["OUTHOUSEAREAS"]) then return; end
    table.insert(lsModData["SO"]["OUTHOUSEAREAS"], {x, y})
    ModData.transmit("LSDATA")
    sendServerCommand("LS", "UpdateClientOuthouseAreas", {x, y})
end

-- ===========================================================================
-- Per-command policy.  rate = max hits/sec (RDRate).  cap = "admin" -> gate to
-- top-admin (via gAdmin() inside the body; RDNet capability="any" pre-filters
-- to staff so non-staff are rejected+logged before the body runs).
-- ===========================================================================
local POLICY = {
    -- admin / global-state
    UpdateAmbt          = { rate = 3,  cap = "any" },
    UpdateServerBeauty  = { rate = 3,  cap = "any" },
    ImportServerBeauty  = { rate = 2,  cap = "any" },
    CompleteTargetAmbt  = { rate = 5,  cap = "any" },
    ResetTargetAmbt     = { rate = 5,  cap = "any" },
    -- item grants (open + caps)
    AddItemToPlayer     = { rate = 5 },
    AddItems_Player     = { rate = 5 },
    AddWorldItem        = { rate = 5 },
    CreateArtworkItem   = { rate = 3 },
    RemoveItemFromPlayer= { rate = 10 },
    -- transfers / item ops
    TransferItem        = { rate = 10 },
    TransferItemWorld   = { rate = 10 },
    TransferItemFrom    = { rate = 10 },
    TransferItemTo      = { rate = 10 },
    RemoveItems         = { rate = 10 },
    -- file/log
    logAmbition         = { rate = 2 },
    -- dirt/world
    RemoveDirtTileDebug = { rate = 5 },
    DebugAddLitter      = { rate = 10 },
}
local DEFAULT_RATE = 15

-- ===========================================================================
-- Wire-up
-- ===========================================================================
if SERVER and RDNet then
    RDNet.adopt(WIRE)
    for name, fn in pairs(H) do
        local p = POLICY[name] or {}
        RDNet.register(WIRE, name, { rate = p.rate or DEFAULT_RATE, capability = p.cap }, fn)
    end
    if RDShared and RDShared.registerMod and RDLSShared then
        pcall(RDShared.registerMod, RDLSShared.MODULE, RDLSShared.VERSION)
    end
    print("[RFTDLifestyleCompanion] adopted \"LS\" into RDNet: "
        .. tostring((function() local c=0 for _ in pairs(H) do c=c+1 end return c end)())
        .. " commands registered; TeleportSittingLocation/makeNauseous/ModifyItemStat/JukeTurnedOn left default-denied.")
else
    -- Single-player / listen host: original local dispatch, unhardened.
    local function onCmd(module, command, playerObj, args)
        if module == WIRE and H[command] then H[command](playerObj, args) end
    end
    if isServer() or (not isServer() and not isClient()) then
        Events.OnClientCommand.Add(onCmd)
    end
end
