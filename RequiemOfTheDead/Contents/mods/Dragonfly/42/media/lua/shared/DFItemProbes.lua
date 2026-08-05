-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFItemProbes - feature-detected field reflection for InventoryItem editing.
--
-- PZ Lua has no true Java reflection so this is a hand-maintained probe list:
-- each entry names a getter / setter pair and the field's type. At runtime we
-- pcall the getter; if it returns a usable value we surface the field in the
-- editor. Setters are gated the same way - server only applies fields whose
-- probe says they're writable AND whose value type matches.
--
-- Server uses the same table so the client / server share the same whitelist
-- of editable fields. Adding a new field is one line here and it shows up in
-- the editor automatically.
--
-- Live on client AND server (shared/).

DFItemProbes = DFItemProbes or {}

-- Probe entries: { label, get, set, kind, group?, requires?, max?, min? }
--   label    - display string in the editor
--   get      - method name on the item that returns the current value (no args)
--   set      - method name on the item that writes the value (one arg), OR a
--              function(item, value) for fields the engine has no plain setter
--              for. nil = read-only. A function setter may report a clean
--              refusal by returning (false, reason) - see Holes below.
--   kind     - "number" | "int" | "bool" | "string"
--   group    - optional grouping for the editor (Meta / Condition / Combat / Food / Clothing)
--   requires - optional Java class name (e.g. "Food", "HandWeapon"); probe only
--              applies when instanceof(item, requires). Without this every
--              probe whose getter returns a value (even 0 for an irrelevant
--              field) gets rendered, which makes the editor noisy.
--   max      - optional getter for max value OR a literal number (for clamping)
--   min      - optional literal lower bound
--
-- Ordering here drives editor field order.
DFItemProbes.LIST = {
    -- Meta (universal - present on every InventoryItem)
    { label = "Custom Name",   get = "getName",            set = "setName",            kind = "string", group = "Meta" },
    { label = "Item Type",     get = "getFullType",        set = nil,                  kind = "string", group = "Meta" },
    { label = "Module",        get = "getModule",          set = nil,                  kind = "string", group = "Meta" },
    { label = "Weight",        get = "getActualWeight",    set = "setActualWeight",    kind = "number", group = "Meta" },

    -- Condition (most items; left universal because clothing, weapons, tools
    --   and many drainables all carry a meaningful condition)
    { label = "Condition",     get = "getCondition",       set = "setCondition",       kind = "int",    group = "Condition", max = "getConditionMax" },
    { label = "Condition Max", get = "getConditionMax",    set = nil,                  kind = "int",    group = "Condition" },

    -- Drainable (torches, lighters, batteries, cleaning fluid bottles, etc.)
    { label = "Used Delta",    get = "getUsedDelta",       set = "setUsedDelta",       kind = "number", group = "Drainable", requires = "DrainableComboItem", min = 0, max = 1 },

    -- Food
    { label = "Age",           get = "getAge",             set = "setAge",             kind = "number", group = "Food", requires = "Food" },
    { label = "Hunger reduce", get = "getHungChange",      set = "setHungChange",      kind = "number", group = "Food", requires = "Food" },
    { label = "Thirst reduce", get = "getThirstChange",    set = "setThirstChange",    kind = "number", group = "Food", requires = "Food" },
    { label = "Unhappiness",   get = "getUnhappyChange",   set = "setUnhappyChange",   kind = "number", group = "Food", requires = "Food" },
    { label = "Boredom",       get = "getBoredomChange",   set = "setBoredomChange",   kind = "number", group = "Food", requires = "Food" },
    { label = "Calories",      get = "getCalories",        set = "setCalories",        kind = "number", group = "Food", requires = "Food" },
    { label = "Proteins",      get = "getProteins",        set = "setProteins",        kind = "number", group = "Food", requires = "Food" },
    { label = "Carbs",         get = "getCarbohydrates",   set = "setCarbohydrates",   kind = "number", group = "Food", requires = "Food" },
    { label = "Lipids",        get = "getLipids",          set = "setLipids",          kind = "number", group = "Food", requires = "Food" },
    { label = "Days Fresh",    get = "getDaysFresh",       set = "setDaysFresh",       kind = "int",    group = "Food", requires = "Food" },
    { label = "Days Rotten",   get = "getDaysTotallyRotten", set = "setDaysTotallyRotten", kind = "int", group = "Food", requires = "Food" },
    { label = "Poison Power",  get = "getPoisonPower",     set = "setPoisonPower",     kind = "int",    group = "Food", requires = "Food" },
    { label = "Cooked",        get = "isCooked",           set = "setCooked",          kind = "bool",   group = "Food", requires = "Food" },
    { label = "Burnt",         get = "isBurnt",            set = "setBurnt",           kind = "bool",   group = "Food", requires = "Food" },
    { label = "Frozen",        get = "isFrozen",           set = "setFrozen",          kind = "bool",   group = "Food", requires = "Food" },

    -- Weapons
    { label = "Sharpness",     get = "getSharpness",       set = "setSharpness",       kind = "number", group = "Combat", requires = "HandWeapon" },
    { label = "Damage Min",    get = "getMinDamage",       set = "setMinDamage",       kind = "number", group = "Combat", requires = "HandWeapon" },
    { label = "Damage Max",    get = "getMaxDamage",       set = "setMaxDamage",       kind = "number", group = "Combat", requires = "HandWeapon" },
    { label = "Range Min",     get = "getMinRange",        set = "setMinRange",        kind = "number", group = "Combat", requires = "HandWeapon" },
    { label = "Range Max",     get = "getMaxRange",        set = "setMaxRange",        kind = "number", group = "Combat", requires = "HandWeapon" },
    { label = "Aiming Time",   get = "getAimingTime",      set = "setAimingTime",      kind = "int",    group = "Combat", requires = "HandWeapon" },
    { label = "Recoil Delay",  get = "getRecoilDelay",     set = "setRecoilDelay",     kind = "int",    group = "Combat", requires = "HandWeapon" },
    { label = "Reload Time",   get = "getReloadTime",      set = "setReloadTime",      kind = "int",    group = "Combat", requires = "HandWeapon" },
    { label = "Clip Size",     get = "getClipSize",        set = "setClipSize",        kind = "int",    group = "Combat", requires = "HandWeapon" },
    { label = "Angle",         get = "getAngle",           set = "setAngle",           kind = "number", group = "Combat", requires = "HandWeapon" },
    { label = "Current Ammo",  get = "getCurrentAmmoCount", set = "setCurrentAmmoCount", kind = "int", group = "Combat", requires = "HandWeapon" },

    -- Clothing
    { label = "Bloody",        get = "getBloodLevel",      set = "setBloodLevel",      kind = "number", group = "Clothing", requires = "Clothing" },
    { label = "Dirty",         get = "getDirtyness",       set = "setDirtyness",       kind = "number", group = "Clothing", requires = "Clothing" },
    { label = "Wetness",       get = "getWetness",         set = "setWetness",         kind = "number", group = "Clothing", requires = "Clothing" },
    -- Holes have no engine setter (getHolesNumber counts the ItemVisual's per-part
    -- hole array), so this is a function setter over RDClothing. Remove-only: it
    -- refuses to raise the count rather than letting an admin punch new holes in
    -- someone's coat. Writing 0 mends everything and credits the condition back.
    { label = "Holes",         get = "getHolesNumber",
      set = function(item, value) return RDClothing.mendHoles(item, value) end,
      kind = "int", group = "Clothing", requires = "Clothing", min = 0 },

    -- Literature / book
    { label = "Already Read",  get = "isAlreadyReadByPlayer", set = nil,               kind = "bool",   group = "Literature", requires = "Literature" },
}

-- Action buttons (Repair / Refill / Refresh / Restore / Dump) - each is a
-- compound write that touches multiple probe fields. Feature-detected at
-- editor build time by checking the `detect` getter exists on the item.
-- `apply(item)` runs server-side after a capability check.
DFItemProbes.ACTIONS = {
    {
        id = "Repair",
        label = "Repair",
        detect = "getCondition",
        apply = function(item)
            pcall(function()
                local maxc = item.getConditionMax and item:getConditionMax() or 100
                item:setCondition(maxc)
            end)
            pcall(function() item:setBloodLevel(0) end)
            pcall(function() item:setDirtyness(0) end)
            pcall(function() item:setWetness(0) end)
        end,
    },
    {
        id = "Refill",
        label = "Refill",
        detect = "getUsedDelta",
        apply = function(item)
            pcall(function() item:setUsedDelta(1.0) end)
        end,
    },
    {
        id = "Refresh",
        label = "Refresh",
        detect = "getAge",
        apply = function(item)
            pcall(function() item:setAge(0) end)
            pcall(function() item:setFrozen(false) end)
            pcall(function() item:setBurnt(false) end)
            pcall(function() item:setPoisonPower(0) end)
        end,
    },
    {
        id = "RestoreWeapon",
        label = "Restore Weapon",
        detect = "getMaxDamage",
        apply = function(item)
            pcall(function()
                local maxc = item.getConditionMax and item:getConditionMax() or 100
                item:setCondition(maxc)
            end)
            pcall(function()
                local maxs = item.getSharpnessMax and item:getSharpnessMax() or 10
                item:setSharpness(maxs)
            end)
        end,
    },
    {
        id = "DumpContainer",
        label = "Dump Contents",
        detect = "getInventory",
        apply = function(item)
            pcall(function()
                local inv = item:getInventory()
                if inv and inv.clear then inv:clear() end
            end)
        end,
    },
}

-- Read a single probe value off the item; returns (value, ok). ok=false means
-- the getter doesn't exist or threw - skip rendering this field.
function DFItemProbes.read(item, probe)
    if not item or not probe or not probe.get then return nil, false end
    local fn = item[probe.get]
    if type(fn) ~= "function" then return nil, false end
    local ok, val = pcall(fn, item)
    if not ok then return nil, false end
    if val == nil then return nil, false end
    if probe.kind == "bool" then return val == true, true end
    return val, true
end

-- Apply a single field write. Returns ok, err. Server-side use; safe to call
-- on values from the wire because we pcall the setter and the value-type
-- check matches probe.kind.
function DFItemProbes.write(item, probeLabel, value)
    if not item then return false, "no item" end
    local probe
    for _, p in ipairs(DFItemProbes.LIST) do
        if p.label == probeLabel then probe = p; break end
    end
    if not probe then return false, "unknown field: " .. tostring(probeLabel) end
    if not probe.set then return false, "field is read-only: " .. tostring(probeLabel) end

    -- Two setter shapes. Usually probe.set names a method on the item; for fields
    -- the engine exposes no setter for (Holes) it is a function(item, value) that
    -- does the work itself and may report a clean refusal.
    local fn, isFuncSetter
    if type(probe.set) == "function" then
        fn, isFuncSetter = probe.set, true
    else
        fn = item[probe.set]
        if type(fn) ~= "function" then return false, "setter not on item" end
    end

    -- Coerce + validate
    if probe.kind == "bool" then
        value = value == true or value == "true" or value == 1
    elseif probe.kind == "int" then
        value = tonumber(value); if value then value = math.floor(value) end
    elseif probe.kind == "number" then
        value = tonumber(value)
    end
    if probe.kind ~= "bool" and value == nil then
        return false, "bad value for " .. probe.label
    end
    if probe.min and value < probe.min then value = probe.min end
    -- probe.max may be a number or a getter name; resolve at apply time
    if type(probe.max) == "number" and value > probe.max then value = probe.max end
    if type(probe.max) == "string" then
        local maxFn = item[probe.max]
        if type(maxFn) == "function" then
            local ok, mx = pcall(maxFn, item)
            if ok and mx and value > mx then value = mx end
        end
    end

    local ok, res, resErr = pcall(fn, item, value)
    if not ok then return false, "setter threw: " .. tostring(res) end
    -- A function setter returning (false, reason) is a refusal we should show the
    -- admin verbatim, not a thrown error. Method setters return nothing, so res is
    -- nil for them and this never fires.
    if isFuncSetter and res == false then
        return false, tostring(resErr or "refused")
    end
    return true, nil
end

-- Apply a named action by id (Repair / Refill / Refresh / etc.).
function DFItemProbes.runAction(item, actionId)
    for _, a in ipairs(DFItemProbes.ACTIONS) do
        if a.id == actionId then
            local fn = item[a.detect]
            if type(fn) ~= "function" then return false, "action not applicable" end
            a.apply(item)
            return true, nil
        end
    end
    return false, "unknown action: " .. tostring(actionId)
end

-- Helper: probe applies to this item only if either (a) it declares no class
-- requirement, or (b) the item passes instanceof for the named class.
-- Wrapped in pcall because instanceof can throw on unfamiliar class names.
local function probeAppliesTo(item, probe)
    if not probe.requires then return true end
    local ok, isInst = pcall(instanceof, item, probe.requires)
    return ok and isInst == true
end

-- Serialize readable fields applicable to this item's actual class. Skips
-- probes whose `requires` doesn't match (so a knife doesn't get Calories,
-- bread doesn't get Sharpness, etc.) and probes whose getter returns nil.
function DFItemProbes.serializeItem(item)
    local out = { fields = {}, actions = {} }
    for _, p in ipairs(DFItemProbes.LIST) do
        if probeAppliesTo(item, p) then
            local val, ok = DFItemProbes.read(item, p)
            if ok then
                out.fields[#out.fields + 1] = {
                    label    = p.label,
                    value    = val,
                    kind     = p.kind,
                    group    = p.group,
                    writable = p.set ~= nil,
                }
            end
        end
    end
    for _, a in ipairs(DFItemProbes.ACTIONS) do
        local fn = item[a.detect]
        if type(fn) == "function" then
            out.actions[#out.actions + 1] = { id = a.id, label = a.label }
        end
    end
    return out
end

-- Dragonfly v0.2.0

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
