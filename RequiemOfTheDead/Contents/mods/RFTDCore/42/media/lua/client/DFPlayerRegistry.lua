-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFPlayerRegistry - registration for the PLAYER panel's two tenant classes
-- (client only).
--
-- THE PLAYER PANEL IS A DECK FOR EVERYONE. The family rule is that
-- player-facing config lives IN the game, where players already are - not on
-- the ESC options screen. Hand-placed rows in shared vanilla panels are
-- structurally collision-prone (Bookmark's checkbox died of exactly that,
-- 2026-08-08), and PZAPI.ModOptions was only ever the stopgap. This registry
-- is the permanent answer: one surface, owned by the family, that every mod
-- rents space in.
--
-- AND EVERY MOD MEANS EVERY MOD. DFModOptionsBridge registers itself here as
-- one more settings tenant and fills that tenancy by walking
-- PZAPI.ModOptions.Data - the engine's own parking lot, which MainOptions
-- reads and nothing else owns - so a mod that has never heard of this registry
-- still lands on the sheet. One handshake with the engine instead of forty
-- with mod authors. Nothing in this file knows that happened: the adopted mods
-- arrive through the same front door a family mod uses.
--
-- TWO TENANT CLASSES, deliberately unequal:
--
--   SETTINGS SHEET  registerPlayerSettings{} - for a mod whose whole
--     player-facing surface is a handful of toggles. The panel renders ONE
--     flat sheet holding every registration, grouped by mod, through DFForm -
--     the tenant ships schema + get/set against its own pref store and writes
--     NO UI code at all. This is the third use of the proven
--     schema-registration pattern (RCTuning's server dials, Limes' zone
--     fields), now pointed at client prefs.
--
--   OWN TAB  registerPlayerTab{} - for a mod with a real client-facing panel
--     (a fleet manager, not a tick-box). Same build contract as the admin
--     deck's DFRegistry: spec.build(spec, panel, x, y, w, h) into a host
--     panel, optional spec.resize(spec, panel, w, h) for live reflow,
--     optional spec.disabled = true to reserve a greyed slot in the strip
--     before the content exists. Optional spec.prefW / spec.prefH declare
--     the size the tab wants: the shell resizes itself to that as the tab
--     is shown (clamped to the screen), so a wide inspector and a modest
--     sheet can share one panel without either opening in the wrong room.
--     A size the player drags a tab to is remembered per tab and outranks
--     the preference.
--
-- WHY A SEPARATE REGISTRY AND NOT A FLAG ON DFRegistry. The admin deck's
-- roster is capability-gated staff tooling; the player panel is ungated by
-- definition. One registry with a "which surface" flag means every consumer
-- of either has to remember to filter, and the one who forgets ships an admin
-- tool to every player. Two registries make the mistake unrepresentable.
--
-- THE SHEET IS COMPOSED HERE, NOT IN THE SHELL. sheetForm() returns a ready
-- DFForm binding (schema + get + set) with every tenant's keys namespaced and
-- routed back to the owning store. It lives in Core so the composition logic
-- exists once, whichever shell renders it - the skin mod stays presentation
-- only, per its standing order.
--
-- SCHEMA MAY BE A FUNCTION. Tenants label their dials with getText(), and
-- registration happens at boot while translations are surer at open time - a
-- schema supplied as a function is called fresh on every compose, so labels
-- translate when the panel opens, not when the mod loaded.
--
-- Core's own DFPrefs (text size, opacity) registers itself at the bottom as
-- the sheet's first tenant: the player panel draws with those tokens too, so
-- the dials that resize it belong on it.

if isServer() then return end

require "DFPrefs"

DFPlayerRegistry = DFPlayerRegistry or {
    tabs   = {},  -- [id] = spec
    sheets = {},  -- [id] = spec
}

function DFPlayerRegistry.registerPlayerTab(spec)
    if not spec or not spec.id then
        print("[Dragonfly] registerPlayerTab refused: missing spec or id")
        return
    end
    DFPlayerRegistry.tabs[spec.id] = spec
    print("[Dragonfly] registerPlayerTab ok: " .. tostring(spec.id)
        .. " (" .. tostring(spec.label or "?") .. ")")
end

function DFPlayerRegistry.registerPlayerSettings(spec)
    if not spec or not spec.id then
        print("[Dragonfly] registerPlayerSettings refused: missing spec or id")
        return
    end
    if type(spec.get) ~= "function" then
        print("[Dragonfly] registerPlayerSettings refused (" .. tostring(spec.id)
            .. "): no get function")
        return
    end
    DFPlayerRegistry.sheets[spec.id] = spec
    print("[Dragonfly] registerPlayerSettings ok: " .. tostring(spec.id)
        .. " (" .. tostring(spec.title or "?") .. ")")
end

-- A consumer mod's schema function that throws would otherwise drop its whole
-- settings sheet silently - indistinguishable from a mod that registered none.
-- Bounded to one line per sheet per session: the panel rebuilds on every open,
-- so an unbounded report would fire every time the window is shown.
local sheetFaults = {}

local function noteSheetFault(id, err)
    local key = tostring(id)
    if sheetFaults[key] then return end
    sheetFaults[key] = true
    print("[Dragonfly] player-settings sheet '" .. key
        .. "' failed to build its schema and was dropped: " .. tostring(err))
end

local function sortedSpecs(map, nameKey)
    local out = {}
    for _, spec in pairs(map) do out[#out + 1] = spec end
    table.sort(out, function(a, b)
        local oa = a.order or 100
        local ob = b.order or 100
        if oa ~= ob then return oa < ob end
        return tostring(a[nameKey] or "") < tostring(b[nameKey] or "")
    end)
    return out
end

function DFPlayerRegistry.getTabs()
    return sortedSpecs(DFPlayerRegistry.tabs, "label")
end

-- Same placeholder semantics as the admin registry: disabled reserves a slot.
function DFPlayerRegistry.isSelectable(spec)
    return spec ~= nil and spec.disabled ~= true
end

-- ---------------------------------------------------------------------------
-- Sheet composition
-- ---------------------------------------------------------------------------
--
-- Keys are namespaced "<sheetId>\31<key>" - \31 (unit separator) because it
-- cannot appear in a pref key anyone typed - and routed through a table built
-- at compose time, so get/set do no string surgery per call. The composed
-- schema is shallow copies: DFForm may read any field a tenant supplied
-- (help, unit, min, values, validate...), so everything is carried over and
-- only the key is rewritten.
--
-- A tenant whose schema already opens with a { group = } header keeps it (it
-- chose its own heading); otherwise one is injected from spec.title, so the
-- sheet always reads as sections-by-mod.
--
-- Tenant get/set run under pcall: one mod's error must cost that mod's rows
-- their values, not the whole sheet its click handling.

function DFPlayerRegistry.sheetForm()
    local schema = {}
    local route  = {}   -- nsKey -> { spec = tenant, key = original }

    local sheets = sortedSpecs(DFPlayerRegistry.sheets, "title")
    -- (see noteSheetFault above: one line per faulting sheet per session)
    for i = 1, #sheets do
        local spec = sheets[i]
        local body = spec.schema
        if type(body) == "function" then
            -- RETAINED, foreign-callback class: body is a schema function
            -- supplied by a CONSUMER mod, unverifiable by construction, and one
            -- bad sheet must drop itself rather than the whole settings panel.
            --
            -- REPORTED now, once per sheet per session. It dropped silently,
            -- which meant a mod whose schema threw simply had no settings - and
            -- looked identical to a mod that registered none.
            local ok, r = pcall(body)
            if not ok then
                noteSheetFault(spec.id, r)
            end
            body = ok and r or nil
        end
        if type(body) == "table" and #body > 0 then
            if not body[1].group then
                schema[#schema + 1] = { group = tostring(spec.title or spec.id) }
            end
            for j = 1, #body do
                local e = body[j]
                if e.group then
                    schema[#schema + 1] = e
                elseif e.key then
                    local copy = {}
                    for k, v in pairs(e) do copy[k] = v end
                    local ns = tostring(spec.id) .. "\31" .. tostring(e.key)
                    copy.key = ns
                    route[ns] = { spec = spec, key = e.key }
                    schema[#schema + 1] = copy
                end
            end
        end
    end

    return {
        schema = schema,
        get = function(ns)
            local r = route[ns]
            if not r then return nil end
            local ok, v = pcall(r.spec.get, r.key)
            if ok then return v end
            return nil
        end,
        set = function(ns, v)
            local r = route[ns]
            if not r or type(r.spec.set) ~= "function" then return end
            local ok, err = pcall(r.spec.set, r.key, v)
            if not ok then
                print("[Dragonfly] player setting write failed ("
                    .. tostring(ns):gsub("\31", ":") .. "): " .. tostring(err))
            end
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Cross-tab navigation. A tab that wants the panel to land somewhere (My
-- Vehicles' part rows opening the Workshop pre-filtered) asks the REGISTRY,
-- and whichever shell is hosting subscribes and does the landing - so a
-- domain mod never reaches into a shell global, and a future second shell
-- inherits the behaviour by subscribing, not by being named anywhere.
-- Listeners run under pcall for the usual reason: a stale closure from a
-- hot-reloaded shell is the expected failure, not an exception.
-- ---------------------------------------------------------------------------
DFPlayerRegistry.showListeners = DFPlayerRegistry.showListeners or {}

function DFPlayerRegistry.onShowRequest(fn)
    if type(fn) == "function" then
        DFPlayerRegistry.showListeners[#DFPlayerRegistry.showListeners + 1] = fn
    end
end

function DFPlayerRegistry.requestShow(id)
    if not id then return end
    for i = 1, #DFPlayerRegistry.showListeners do
        -- guarded, and per-listener on purpose: these are foreign callbacks, so this is
        -- granularity - one listener that throws must not cost the others their turn.
        pcall(DFPlayerRegistry.showListeners[i], id)
    end
end

-- Friendly aliases in the family style, beside registerTab and friends.
Dragonfly = Dragonfly or {}
Dragonfly.registerPlayerTab      = DFPlayerRegistry.registerPlayerTab
Dragonfly.registerPlayerSettings = DFPlayerRegistry.registerPlayerSettings
Dragonfly.showPlayerTab          = DFPlayerRegistry.requestShow

-- ---------------------------------------------------------------------------
-- Core's own tenancy: the display preferences. First on the sheet (order 10)
-- because they are the only group every install is guaranteed to have, and
-- because "make the text bigger" is the dial a struggling player needs to
-- find first. DFPrefs.SCHEMA opens with its own { group = "Display" } header,
-- so none is injected for it.
-- ---------------------------------------------------------------------------
DFPlayerRegistry.registerPlayerSettings{
    id     = "display",
    title  = "Display",
    order  = 10,
    schema = function() return DFPrefs.SCHEMA end,
    get    = function(k) return DFPrefs.get(k) end,
    set    = function(k, v) DFPrefs.set(k, v) end,
}

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
