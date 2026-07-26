-- DFPatch_PhunLewt.lua - Dragonfly removable third-party patch
--
-- Silences an error storm from "PhunLewt 2.1" during loot generation.
-- The VANILLA engine is at fault: on nested-bag fill paths it fires
-- OnFillContainer with containerDist.bags - an internal
-- ItemPickerJava$ItemPickerContainer distribution record, not an
-- ItemContainer (ItemPickerJava.java:602/1029/1243, each immediately
-- followed by a second, correct event carrying the real ItemContainer).
-- That class is not exposed to Lua, so PhunLewt's handler throws
-- "attempted index: getSourceGrid of non-table" (server_main.lua:14)
-- on every bag-in-container/zombie loot roll - 82 stack traces in one
-- morning session on the live box.
--
-- No functional loss either way: the paired correct event covers the
-- same bag, so rejecting the bogus one drops nothing. The guard must
-- be instanceof, not duck-typing - indexing ANY key on the opaque
-- userdata is itself what throws.
--
-- PhunLewt's event closure calls Core.removeItemsFromContainer(...)
-- as a table-field lookup at call time, so wrapping the field on the
-- PhunLewt global intercepts it without touching the Workshop files.
--
-- REMOVABLE: delete this file to drop the patch. PhunLewt keeps working
-- with its original behaviour; nothing else in Dragonfly depends on this.

if not isServer() then return end

local applied = false

local function apply()
    if applied then return end

    local PL = PhunLewt
    if type(PL) ~= "table" or type(PL.removeItemsFromContainer) ~= "function" then
        return -- PhunLewt not present
    end
    applied = true

    local orig = PL.removeItemsFromContainer
    PL.removeItemsFromContainer = function(container, isZed)
        if not container or not instanceof(container, "ItemContainer") then return end
        return orig(container, isZed)
    end

    print("[Dragonfly] DFPatch_PhunLewt applied (OnFillContainer ItemContainer guard)")
end

Events.OnServerStarted.Add(apply)
