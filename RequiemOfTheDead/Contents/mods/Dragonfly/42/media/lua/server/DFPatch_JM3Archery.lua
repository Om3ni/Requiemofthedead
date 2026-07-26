-- DFPatch_JM3Archery.lua — Dragonfly removable third-party patch
--
-- Restores JM3_ArcheryMP's bonus-yield crafting on the dedicated server.
-- Same disease as DFPatch_SOTO: the recipe callback `Crear_Materiales`
-- (referenced by craftRecipe Make_Arrow_Fletching and Make_arrow_shaft in
-- JM3_recetas.txt) is defined only in CLIENT lua (JM3_recetas.lua:97), and
-- its helpers (BuscarTexto, JM3jugador) live in the author's base mod's
-- client lua too (ModTemplate/.../client/JM3_utils.lua). Client lua never
-- loads on a dedi, so every craft logs
--   WARN CraftLogic: Could not find lua function: Crear_Materiales
-- (54x in one live morning) and the bonus materials are never granted.
-- The recipes' scripted base outputs still work — only the bonus is lost.
--
-- Define-missing-global variant (file scope, `== nil` guard): we only fill
-- the hole on a dedi; on a co-op host the real client definition loads
-- first and we never clobber it.
--
-- Mirror of the original logic (bug-for-bug: substring match, so e.g.
-- Base.Brochure gets no bonus — only Card*/Photo* inputs do):
--   input contains "Base.Card" or "Base.Photo"          -> +2 JM3.Arrow_fletching
--   input contains "Base.LongStick"/"Base.PercedWood"/
--                  "Base.Plank"/"Base.SpadeWood"        -> +4 JM3.Ashaft
-- Differences from the client original: crafter comes from
-- CraftRecipeData:getCharacter() (not the client-cached JM3jugador), and
-- items are granted AddItem + sendAddItemToContainer so the remote client
-- sees them immediately (house idiom from DFInventory_Server/MMServer).
--
-- REMOVABLE: delete this file to drop the patch. JM3 keeps working minus
-- the bonus yield; nothing else in Dragonfly depends on this.

if not isServer() then return end

if Crear_Materiales == nil then

    local FLETCHING_WORDS = { "Base.Card", "Base.Photo" }
    local SHAFT_WORDS = { "Base.LongStick", "Base.PercedWood", "Base.Plank", "Base.SpadeWood" }

    local function containsAny(fullType, words)
        for i = 1, #words do
            if string.find(fullType, words[i], 1, true) then return true end
        end
        return false
    end

    local function grant(inv, fullType, count)
        for _ = 1, count do
            local item
            pcall(function() item = inv:AddItem(fullType) end)
            if item then pcall(function() sendAddItemToContainer(inv, item) end) end
        end
    end

    function Crear_Materiales(receta)
        if not receta or not receta.getAllInputItems then return end
        local character = receta.getCharacter and receta:getCharacter() or nil
        local inv = character and character:getInventory() or nil
        if not inv then return end
        local items = receta:getAllInputItems()
        for i = 0, items:size() - 1 do
            local obj = items:get(i)
            local fullType = obj and tostring(obj:getFullType() or "") or ""
            if containsAny(fullType, FLETCHING_WORDS) then
                grant(inv, "JM3.Arrow_fletching", 2)
            elseif containsAny(fullType, SHAFT_WORDS) then
                grant(inv, "JM3.Ashaft", 4)
            end
        end
    end

    print("[Dragonfly] DFPatch_JM3Archery: defined server-side Crear_Materiales (bonus fletching/shaft yield)")
end
