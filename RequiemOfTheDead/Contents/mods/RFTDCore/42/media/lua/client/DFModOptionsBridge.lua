-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFModOptionsBridge - the player panel adopts the engine's mod settings
-- (client only).
--
-- ONE HANDSHAKE, WITH THE ENGINE - NOT ONE PER MOD. The player panel's first
-- tab is meant to be the single place a player adjusts anything, not just the
-- family's own dials (owner, 2026-08-09). The obvious way to get there is to
-- ask every mod to register with DFPlayerRegistry, which is a handshake we
-- would have to negotiate 40 times and would still lose to any mod that never
-- heard of us. The engine already solved it: PZAPI.ModOptions is the parking
-- lot where a mod leaves its settings, and MainOptions does nothing cleverer
-- than walk `PZAPI.ModOptions.Data` and draw what it finds
-- (MainOptions:addModOptionsPanel). So we walk the same list. A mod that
-- parked there appears on our sheet whether or not it has ever heard of this
-- suite - which is the whole point.
--
-- WHAT THAT COVERS. On the owner's own install: 161 workshop mods, 41 of them
-- parked here. The rest either ship no options at all or hand-build their rows
-- straight into MainOptions, where there is no registry to walk and nothing
-- generic to adopt - those stay on the ESC screen by construction, not by
-- choice. (Two use the older third-party ModOptions framework; that is a
-- separate bridge, and a small one, if it ever earns its place.)
--
-- ONE SHEET, NOT ONE PER MOD, and the schema is a FUNCTION. Mods call
-- PZAPI.ModOptions:create() while their files load, in an order nobody
-- controls, and some do it later still. A sheet registered per mod would have
-- to be registered after the last of them - a race with no finish line. One
-- sheet whose schema walks Data at compose time has no such problem: the panel
-- composes on every open (DFPlayerRegistry.sheetForm), so whatever exists when
-- the player looks is what the player sees. Mods are sorted by display name
-- rather than registration order, because load order is arbitrary and a player
-- hunting for a mod name wants the alphabet.
--
-- WE MUST READ THE INI BEFORE WE EVER WRITE IT. PZAPI.ModOptions:save()
-- rewrites the whole file from two sources: the options loaded this session,
-- and `OtherOptions` - the verbatim lines belonging to mods that are NOT
-- active right now. `OtherOptions` is populated by :load() and by nothing
-- else. So a save that was not preceded by a load silently deletes every
-- absent mod's saved settings. :load() is only ever called by
-- MainOptions:addModOptionsPanel(), i.e. when the options screen was built
-- with mods present - which we cannot assume happened. Hence ensureLoaded(),
-- called at OnGameStart and again defensively before any read or write, and a
-- write that REFUSES outright if the read never succeeded. That refusal is the
-- most important line in this file.
--
-- COMMIT SEMANTICS ARE MAINOPTIONS', MINUS THE APPLY BUTTON. There, `onChange`
-- fires on interaction, `onChangeApply` fires at Apply and only if the value
-- actually moved, then every mod's `apply()` runs and the ini is saved. Our
-- sheet has no Apply button - a dial is live the moment it is clicked - so the
-- same sequence runs per change, in the same order. Every tenant call is
-- pcall'd: these are strangers' functions, some written against the assumption
-- that the options screen is on screen when they run.
--
-- WHAT DOES NOT SURVIVE THE CROSSING. DFForm speaks bool/int/enum/choice/text.
-- ModOptions also has colour pickers, key binds and buttons, which have no
-- control here yet; they are rendered as rows that show their current value
-- and refuse the edit with a line saying where to make it. Shown-and-refusing
-- beats absent: a player looking for a key bind that silently vanished
-- concludes we lost it. Descriptions and separators are dropped - DFForm has
-- no paragraph row, and the group headers already do the separating.
--
-- SYNC IS FREE IN BOTH DIRECTIONS. An option's `setValue` writes the mod's
-- value AND its live widget if the options screen ever built one, and that
-- screen writes `option.value`, which is what we read. Neither surface has to
-- know the other exists.

if isServer() then return end

require "DFPlayerRegistry"

-- Survives reloadLuaFile: the load flag in particular, so a hot reload cannot
-- talk us into a save that never read the file.
DFModOptionsBridge = DFModOptionsBridge or { loaded = false, hooked = false }

-- The registry namespaces our keys with \31, so ours may use \30 freely. Both
-- are unit/record separators no human typed into a mod option id.
local SEP      = "\30"
local SHEET_ID = "modoptions"

local NO_EDIT = "This control has no equivalent here yet. Set it on the ESC options screen."

-- Types we show but will not write.
local REFUSED = { colorpicker = true, keybind = true, button = true }

local function api()
    local a = PZAPI and PZAPI.ModOptions
    if type(a) ~= "table" or type(a.Data) ~= "table" or type(a.Dict) ~= "table" then
        return nil
    end
    return a
end

-- Mods label their dials with translation keys, exactly as MainOptions assumes
-- when it calls getText on them; a mod that passed literal text gets it back
-- unchanged.
local function label(name, fallback)
    if name == nil or name == "" then return tostring(fallback or "?") end
    return getText(tostring(name))
end

-- ---------------------------------------------------------------------------
-- Reading the ini. See the header: this gates every write.
-- ---------------------------------------------------------------------------

-- One line per (option, callback) per session. A third-party handler that
-- throws on every interaction would otherwise write a line per keystroke, and
-- the point of reporting is to be readable.
local callbackFaults = {}

local function noteCallbackFault(who, hook, ok, err)
    if ok then return end
    local key = tostring(who) .. "/" .. hook
    if callbackFaults[key] then return end
    callbackFaults[key] = true
    print(string.format(
        "[Dragonfly] mod options: %s's %s failed; that setting may not have taken: %s",
        tostring(who), hook, tostring(err)))
end

function DFModOptionsBridge.ensureLoaded()
    if DFModOptionsBridge.loaded then return true end
    local a = api()
    if not a or type(a.load) ~= "function" then return false end
    -- foreign code: ModOptions' own loader; a fault refuses the bridge
    -- (see header - refusing to write ungated is the point)
    local ok, err = pcall(a.load, a)
    if not ok then
        print("[Dragonfly] mod options load failed: " .. tostring(err))
        return false
    end
    DFModOptionsBridge.loaded = true
    return true
end

-- ---------------------------------------------------------------------------
-- Keys
-- ---------------------------------------------------------------------------

local function keyFor(modId, optId, idx)
    if idx then return modId .. SEP .. optId .. SEP .. tostring(idx) end
    return modId .. SEP .. optId
end

-- Returns group, option, index - or nil for a key naming a mod that has since
-- gone away, which is the expected outcome of a stale form, not an error.
local function resolve(k)
    local a = api()
    if not a then return nil end
    k = tostring(k or "")

    local p1 = string.find(k, SEP, 1, true)
    if not p1 then return nil end
    local modId = string.sub(k, 1, p1 - 1)
    local rest  = string.sub(k, p1 + 1)

    local optId, idx = rest, nil
    local p2 = string.find(rest, SEP, 1, true)
    if p2 then
        optId = string.sub(rest, 1, p2 - 1)
        idx   = tonumber(string.sub(rest, p2 + 1))
    end

    local group = a.Dict[modId]
    if not group or type(group.dict) ~= "table" then return nil end
    local option = group.dict[optId]
    if not option then return nil end
    return group, option, idx
end

-- ---------------------------------------------------------------------------
-- Sliders. ModOptions sliders may step in fractions; DFForm's stepper is plain
-- arithmetic, so a value walked with 0.1 accumulates float dust and renders as
-- 0.30000000000000004. Every write is snapped back onto the step grid and
-- rounded to the step's own precision, so what is stored is what was shown.
-- ---------------------------------------------------------------------------

local function decimalsOf(step)
    step = tonumber(step) or 1
    if step <= 0 or step >= 1 then return 0 end
    local d, s = 0, step
    while d < 4 and math.abs(s - math.floor(s + 0.5)) > 1e-6 do
        s = s * 10
        d = d + 1
    end
    return d
end

local function quantize(v, step, dec)
    v = tonumber(v) or 0
    step = tonumber(step) or 1
    if step > 0 then v = math.floor(v / step + 0.5) * step end
    local m = 10 ^ (dec or 0)
    return math.floor(v * m + 0.5) / m
end

-- ---------------------------------------------------------------------------
-- The schema, rebuilt on every compose
-- ---------------------------------------------------------------------------

function DFModOptionsBridge.schema()
    local a = api()
    if not a then return {} end
    DFModOptionsBridge.ensureLoaded()

    local groups = {}
    for i = 1, #a.Data do groups[#groups + 1] = a.Data[i] end
    table.sort(groups, function(x, y)
        return string.lower(label(x.name, x.modOptionsID))
             < string.lower(label(y.name, y.modOptionsID))
    end)

    local out = {}
    for gi = 1, #groups do
        local g    = groups[gi]
        local rows = {}

        for oi = 1, #(g.data or {}) do
            local o    = g.data[oi]
            -- Titles, descriptions and separators are rows with no id at all;
            -- only a real dial gets a key built for it.
            local k    = o.id and keyFor(g.modOptionsID, o.id) or nil
            local name = label(o.name, o.id)
            local help = (o.tooltip and o.tooltip ~= "") and getText(tostring(o.tooltip)) or nil

            if o.type == "title" then
                rows[#rows + 1] = { group = name }

            elseif o.type == "tickbox" then
                rows[#rows + 1] = { key = k, kind = "bool", label = name, help = help }

            elseif o.type == "multipletickbox" then
                -- One dial in ModOptions, one row per box here: DFForm has no
                -- multi-select control, and N labelled ON/OFF rows under the
                -- dial's own heading says the same thing.
                rows[#rows + 1] = { group = name }
                for vi = 1, #(o.values or {}) do
                    rows[#rows + 1] = {
                        key   = keyFor(g.modOptionsID, o.id, vi),
                        kind  = "bool",
                        label = label(o.values[vi].name, vi),
                        help  = help,
                    }
                end

            elseif o.type == "combobox" then
                -- ModOptions stores the SELECTED INDEX, which is exactly what
                -- DFForm's enum stores. No translation needed either way:
                -- addItem already ran the names through getText.
                local vals = {}
                for vi = 1, #(o.values or {}) do vals[vi] = tostring(o.values[vi]) end
                if #vals > 0 then
                    rows[#rows + 1] = {
                        key = k, kind = "enum", label = name,
                        values = vals, numValues = #vals, help = help,
                    }
                end

            elseif o.type == "slider" then
                rows[#rows + 1] = {
                    key = k, kind = "int", label = name,
                    min  = tonumber(o.min) or 0,
                    max  = tonumber(o.max) or 100,
                    step = tonumber(o.step) or 1,
                    help = help,
                }

            elseif o.type == "textentry" then
                rows[#rows + 1] = { key = k, kind = "text", label = name, help = help }

            elseif REFUSED[o.type] then
                rows[#rows + 1] = {
                    key   = k,
                    kind  = "text",
                    label = name,
                    rule  = NO_EDIT,
                    help  = help and (help .. "\n\n" .. NO_EDIT) or NO_EDIT,
                    validate = function() return false, NO_EDIT end,
                }
            end
            -- description / separator: deliberately dropped, see the header.
        end

        -- A mod that contributed only headings gets no heading of its own: an
        -- empty section reads as a broken mod rather than a quiet one.
        local hasDial = false
        for ri = 1, #rows do
            if rows[ri].key then hasDial = true break end
        end
        if hasDial then
            out[#out + 1] = { group = label(g.name, g.modOptionsID) }
            for ri = 1, #rows do out[#out + 1] = rows[ri] end
        end
    end

    return out
end

-- ---------------------------------------------------------------------------
-- Reads
-- ---------------------------------------------------------------------------

function DFModOptionsBridge.get(k)
    local _, o, idx = resolve(k)
    if not o then return nil end

    if o.type == "tickbox" then
        return o.value == true

    elseif o.type == "multipletickbox" then
        local row = o.values and idx and o.values[idx]
        return (row ~= nil) and (row.value == true) or false

    elseif o.type == "combobox" then
        return tonumber(o.selected) or 1

    elseif o.type == "slider" then
        return quantize(o.value, o.step, decimalsOf(o.step))

    elseif o.type == "textentry" then
        return o.value

    elseif o.type == "keybind" then
        local code = tonumber(o.key) or 0
        -- No guard. getKeyName is not in the Java decompile below the Lua
        -- wrapper (LuaManager.java:8588-8591 into Input.getKeyName,
        -- core/input/Input.java:28-38, which bottoms out in LWJGL's Keyboard) -
        -- but vanilla Lua calls it BARE in six places on exactly this input
        -- class, a persisted keycode straight out of getCore():getKey(...)
        -- (ISDuplicateKeybindDialog.lua:17, 96, 112, 121;
        -- ISPrintMediaTextPanel.lua:295). Vanilla ships working with those, and
        -- that is the evidence rule 1 asks for where the decompile stops.
        --
        -- It CAN return nil - Input.getKeyName falls through to a possibly-null
        -- Keyboard name when no IGUI_Key_ translation exists (:33-37) - so the
        -- raw-code fallback stays. That was always the useful half.
        return getKeyName(code) or tostring(code)

    elseif o.type == "colorpicker" then
        local c = o.color or {}
        local function b(x) return math.floor((tonumber(x) or 0) * 255 + 0.5) end
        return string.format("%d, %d, %d", b(c.r), b(c.g), b(c.b))

    elseif o.type == "button" then
        return ""
    end

    return nil
end

-- ---------------------------------------------------------------------------
-- Writes - MainOptions' sequence, run per change because there is no Apply
-- button to run it at. Refused outright if the ini was never read.
-- ---------------------------------------------------------------------------

function DFModOptionsBridge.set(k, v)
    local g, o, idx = resolve(k)
    if not o or REFUSED[o.type] then return end

    if not DFModOptionsBridge.ensureLoaded() then
        print("[Dragonfly] mod settings write refused: ModOptions.ini was never read, "
            .. "and saving without it would erase the settings of every inactive mod")
        return
    end

    local old, new
    if o.type == "tickbox" then
        old, new = (o.value == true), (v == true)

    elseif o.type == "multipletickbox" then
        local row = o.values and idx and o.values[idx]
        if not row then return end
        old, new = (row.value == true), (v == true)

    elseif o.type == "combobox" then
        old = tonumber(o.selected) or 1
        new = tonumber(v) or old

    elseif o.type == "slider" then
        old = tonumber(o.value) or 0
        new = quantize(v, o.step, decimalsOf(o.step))
        local lo, hi = tonumber(o.min), tonumber(o.max)
        if lo and new < lo then new = lo end
        if hi and new > hi then new = hi end

    elseif o.type == "textentry" then
        old = o.value
        new = (v == nil) and "" or tostring(v)

    else
        return
    end

    -- RETAINED, all four: these are STRANGERS' callbacks in the literal sense
    -- this bridge exists for - it mirrors options registered by third-party
    -- mods, so onChange, onChangeApply, setValue and apply are code we do not
    -- own, cannot read and cannot preflight. That is the foreign-callback class
    -- exactly, and one mod's broken handler must not stop the settings sheet
    -- writing the other mods' values.
    --
    -- What they were NOT doing is reporting. All four discarded the error
    -- outright, so a third-party option that threw on every interaction looked
    -- identical to one that worked - and the user's setting silently did not
    -- take. Now named and bounded: once per option per session, so a
    -- persistently broken handler cannot fill the log.
    --
    -- Order is MainOptions': onChangeApply only fires on real movement,
    -- onChange fires on the interaction.
    local who = label(o.name, o.id)
    if type(o.onChange) == "function" then
        noteCallbackFault(who, "onChange", pcall(o.onChange, o, new))
    end
    if new ~= old and type(o.onChangeApply) == "function" then
        noteCallbackFault(who, "onChangeApply", pcall(o.onChangeApply, o, new))
    end

    if o.type == "multipletickbox" then
        noteCallbackFault(who, "setValue", pcall(o.setValue, o, idx, new))
    else
        noteCallbackFault(who, "setValue", pcall(o.setValue, o, new))
    end

    -- The mod's own settled hook, then the file. Both optional in practice:
    -- apply() defaults to a no-op, and a failed save must not take the value
    -- change down with it.
    if type(g.apply) == "function" then
        noteCallbackFault(who, "apply", pcall(g.apply, g))
    end

    local a = api()
    if a and type(a.save) == "function" then
        local ok, err = pcall(a.save, a)
        if not ok then
            print("[Dragonfly] mod options save failed: " .. tostring(err))
        end
    end
end

-- ---------------------------------------------------------------------------
-- Tenancy. order 200 seats the adopted mods below the family's own sheets:
-- the suite's dials and the display prefs are what this panel is FOR, and a
-- player who opened it to change text size should not have to scroll past
-- forty strangers to reach them. Below that line it is strict alphabet, with
-- no privilege for anything of ours.
--
-- No title header is injected for this sheet (the schema opens with a mod's
-- own group), and an empty schema means no section at all - an install with no
-- adopted mods sees no trace of this file.
-- ---------------------------------------------------------------------------

DFPlayerRegistry.registerPlayerSettings{
    id     = SHEET_ID,
    title  = "Mods",
    order  = 200,
    schema = function() return DFModOptionsBridge.schema() end,
    get    = function(k) return DFModOptionsBridge.get(k) end,
    set    = function(k, v) DFModOptionsBridge.set(k, v) end,
}

-- Read the ini once the world is up, which is after every mod that was going
-- to park an option has loaded. Guarded because a hot reload re-runs this file
-- and Events has no way to remove an anonymous listener.
if not DFModOptionsBridge.hooked then
    DFModOptionsBridge.hooked = true
    Events.OnGameStart.Add(function() DFModOptionsBridge.ensureLoaded() end)
end

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
