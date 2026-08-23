-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFSandboxModel - the suite's sandbox options, read off the engine and shaped
-- for the Admin tab. No ISUI here on purpose: this is the half that can be
-- tested, and it is the half that was worth getting right first.
--
-- REFLECTION, NOT REGISTRATION. Nothing registers with this. It walks
-- getSandboxOptions() and takes what is already there, which is strictly better
-- than an API contract for one reason: a registry has two sources of truth -
-- the sandbox-options.txt the engine parses and the Lua somebody remembered to
-- write - and they drift. Two separate drifts were found in this repo on
-- 2026-08-20 alone (five reported mod versions against mod.info, and ES
-- translations against the options they name). Reflection has one source, and
-- it is the one the engine itself is using. A new RFTD mod appears in this
-- panel the moment it ships a sandbox-options.txt, with no code at all.
--
-- The Lua surface is vanilla's own, not inferred: ServerSettingsScreen.lua
-- builds its mod pages from exactly these calls (:5133-5190) - getNumOptions,
-- getOptionByIndex (ZERO-based), isCustom, getPageName, getName,
-- getTranslatedName, getTooltip, getType, getDefaultValue, and for enums
-- getNumValues with getValueTranslationByIndex (ONE-based).
--
-- WHY THE PREFIX IS THE WHOLE MEMBERSHIP TEST. isCustom() is true for EVERY
-- mod's options - PhunZones, New Music, anything else on the server - so it is
-- not by itself a filter for ours. After the 2026-08-22 page convergence every
-- RFTD page is named for its mod id and all nine begin "RFTD", so the prefix
-- is the test. No allowlist to maintain, nothing to keep in step, and a future
-- mod is included by existing rather than by being remembered.

if isServer() then return end

require "DFKit"

DFSandboxModel = DFSandboxModel or {}

local PREFIX = "RFTD"

-- THE HEADER PROMISE, and it is a promise rather than a rule the engine keeps.
--
-- The settings screen has no sub-categories - CustomSandboxOption carries
-- exactly id/page/translation - so a section divider can only be a real option
-- that means nothing. Dirge established the convention and the suite adopted
-- it on 2026-08-22: a boolean named <Something>Header, defaulting false, read
-- by no code.
--
-- Matching on the NAME alone would catch a genuine option called ShowHeader,
-- so the type is checked too. That is not proof - a real boolean ending in
-- "Header" would still be swallowed - and the honest fix is a gate that
-- asserts every *Header option is a false-defaulting boolean nothing reads.
-- Filed rather than guessed at; see TODO.md.
local function isHeader(short, otype)
    return otype == "boolean" and short:sub(-6) == "Header"
end

-- "_________ Visuals _________" -> "Visuals". The underscore rules are there to
-- fake a divider in the vanilla screen, which can only draw a checkbox. This
-- panel draws a real divider, so it wants the words and not the scenery.
local function sectionTitle(translated, short)
    local s = tostring(translated or ""):gsub("_", " ")
    s = s:match("^%s*(.-)%s*$")
    if s ~= "" then return s end
    -- No translation: fall back to the option's own name minus the suffix, so
    -- a missing string degrades to "Visuals" rather than to an empty rule.
    return (short:sub(1, -7))
end

-- One option, flattened to what a row needs. Enum values are resolved here
-- rather than at draw time: getValueTranslationByIndex is a per-call lookup and
-- a redraw is sixty frames a second.
local function readOption(o)
    local name  = o:getName()
    local short = name:match("%.(.+)$") or name
    local otype = o:getType()
    local row = {
        name    = name,
        short   = short,
        type    = otype,
        label   = o:getTranslatedName(),
        tooltip = o:getTooltip(),
    }
    if otype == "enum" then
        row.values = {}
        for k = 1, o:getNumValues() do
            row.values[k] = o:getValueTranslationByIndex(k)
        end
    end
    return row
end

-- Every RFTD option, grouped by mod and split into sections.
--
-- Index order is declaration order, which is the only ordering the engine
-- preserves and therefore the only one a section boundary can rely on. Options
-- appearing before a mod's first header land in a leading section with no
-- title - which is also what a mod that uses no headers at all produces: one
-- untitled section holding everything. That mod is not broken by declining the
-- convention; it just renders flat.
function DFSandboxModel.build()
    local so = getSandboxOptions()
    if not so then return {} end

    local byPage, order = {}, {}

    for i = 0, so:getNumOptions() - 1 do
        local o = so:getOptionByIndex(i)
        -- isCustom is the cheaper test and excludes every vanilla option, so it
        -- runs first; getPageName is nil for vanilla ones anyway.
        if o and o:isCustom() then
            local page = o:getPageName()
            if page and page:sub(1, #PREFIX) == PREFIX then
                local mod = byPage[page]
                if not mod then
                    mod = { page = page, label = getText("Sandbox_" .. page),
                            sections = { { title = nil, options = {} } } }
                    byPage[page] = mod
                    order[#order + 1] = mod
                end
                local row = readOption(o)
                if isHeader(row.short, row.type) then
                    mod.sections[#mod.sections + 1] =
                        { title = sectionTitle(row.label, row.short), options = {} }
                else
                    local sec = mod.sections[#mod.sections]
                    sec.options[#sec.options + 1] = row
                end
            end
        end
    end

    -- A leading section nobody wrote into is an artefact of always creating
    -- one, not a section. Drop it rather than draw a rule above the first row.
    for _, mod in ipairs(order) do
        if #mod.sections > 1 and #mod.sections[1].options == 0 then
            table.remove(mod.sections, 1)
        end
        mod.count = 0
        for _, sec in ipairs(mod.sections) do
            mod.count = mod.count + #sec.options
        end
    end

    table.sort(order, function(a, b)
        return tostring(a.label or a.page) < tostring(b.label or b.page)
    end)
    return order
end

-- ---------------------------------------------------------------------------
-- SERVER OPTIONS
--
-- A different registry with the SAME enumeration surface - getNumOptions,
-- getOptionByIndex (zero-based), getOptionByName, and per-option getName /
-- getTooltip / getType / getValueAsString / getDefaultValue. getServerOptions
-- is a real Lua global (LuaManager.java:3558), and vanilla gameplay code reads
-- it client-side for live decisions (ISChat.lua:179 for the chat character
-- limit, ISInventoryPage.lua:420 for TrashDeleteAll), which is the proof that a
-- client's copy holds the server's real values rather than defaults.
--
-- WHAT IS DIFFERENT, and it decides the whole shape of the view:
--
--   NO PAGES. ServerOption carries no category of any kind - 144 options in one
--   flat list. Sandbox options group themselves by mod page; these cannot, so
--   the grouping below is OURS.
--
--   NO RE-BROADCAST. changeOption parses the value and saves the server ini
--   (ServerOptions.java:335-344) and tells no client. Contrast the sandbox
--   path, which re-sends the whole set to every connection
--   (GameServer.java:1623-1630). So a client's copy is whatever it received at
--   connect, for the whole session, and a panel that writes has to echo the
--   value locally or appear to have done nothing. Vanilla does exactly that
--   (ISServerOptions.lua:184-189).
--
-- GROUPING IS A MECHANICAL PREFIX RULE, not a hand-classification. 144 options
-- is too many to sort by judgement without the list going stale the first time
-- the engine adds one, and a wrong guess is worse than no guess: it files an
-- option where nobody will look for it. A name that literally starts with one
-- of these words goes in that section; everything else goes to Other. The rule
-- is auditable by reading it, and a new option lands correctly or lands in
-- Other, never somewhere misleading. It catches 61 of the current 144.
local SERVER_SECTIONS = {
    "AntiCheat", "Safehouse", "PVP", "Discord", "Voice", "Safety",
    "Player", "Backup", "Faction", "Chat", "Steam", "Sleep",
    "Server", "Map", "Login", "War", "Workshop", "Mod",
}

local function serverSection(name)
    for _, prefix in ipairs(SERVER_SECTIONS) do
        if name:sub(1, #prefix) == prefix then return prefix end
    end
    return "Other"
end

-- Returns ONE page-shaped table, the same shape build() emits per mod, so the
-- view and its schema translation do not need to know which registry they are
-- looking at.
function DFSandboxModel.buildServer()
    local so = getServerOptions()
    if not so then return nil end

    local order, bySection = {}, {}
    for i = 0, so:getNumOptions() - 1 do
        local o = so:getOptionByIndex(i)
        if o then
            local row = readOption(o)
            -- Server option names are not namespaced, so short == name. Kept
            -- distinct anyway: everything downstream keys on `name`.
            local sec = serverSection(row.short)
            local bucket = bySection[sec]
            if not bucket then
                bucket = { title = sec, options = {} }
                bySection[sec] = bucket
                order[#order + 1] = bucket
            end
            bucket.options[#bucket.options + 1] = row
        end
    end

    -- Sections alphabetical, Other last: it is the leftovers bucket and reads
    -- as one at the bottom, not wedged between Map and PVP.
    table.sort(order, function(a, b)
        if (a.title == "Other") ~= (b.title == "Other") then return b.title == "Other" end
        return a.title < b.title
    end)
    for _, sec in ipairs(order) do
        table.sort(sec.options, function(a, b) return a.short < b.short end)
    end

    local count = 0
    for _, sec in ipairs(order) do count = count + #sec.options end
    return { page = "__server", label = "Server", sections = order, count = count }
end

function DFSandboxModel.serverValueOf(name)
    local so = getServerOptions()
    local o = so and so:getOptionByName(name)
    if not o then return nil end
    if o:getType() == "string" or o:getType() == "text" then return o:getValue() end
    return o:getValueAsString()
end

function DFSandboxModel.serverIsDefault(name)
    local so = getServerOptions()
    local o = so and so:getOptionByName(name)
    if not o then return true end
    return tostring(o:getDefaultValue()) == tostring(DFSandboxModel.serverValueOf(name))
end

-- The current value, read fresh. Deliberately NOT cached into the model: the
-- model describes the SHAPE of the options, which cannot change while the panel
-- is open, whereas a value can be changed by another admin at any moment. One
-- lookup per row per redraw is a hash get.
function DFSandboxModel.valueOf(name)
    local so = getSandboxOptions()
    if not so then return nil end
    local o = so:getOptionByName(name)
    if not o then return nil end
    if o:getType() == "string" or o:getType() == "text" then return o:getValue() end
    return o:getValueAsString()
end

-- True when the option still holds its declared default, for the panel's
-- "changed from default" mark.
function DFSandboxModel.isDefault(name)
    local so = getSandboxOptions()
    if not so then return true end
    local o = so:getOptionByName(name)
    if not o then return true end
    return tostring(o:getDefaultValue()) == tostring(DFSandboxModel.valueOf(name))
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
