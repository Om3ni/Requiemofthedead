-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFPrefs - per-client presentation preferences for the whole family.
--
-- WHAT THIS IS FOR. Font size and panel opacity are not gameplay and not
-- server policy - they are one person's eyesight and one person's monitor.
-- They belong to the CLIENT, they must survive a relog, and they must apply
-- everywhere at once: the deck chrome and every tab inside it, across every
-- mod in the suite. So they live in Core, which is the only layer both
-- Dragonfly's chrome and the individual tabs already depend on.
--
-- WHY A FILE AND NOT MODDATA. ModData is save state - it belongs to a world,
-- syncs with a server, and would mean an admin's font size resets when they
-- join a different box. A preference is about the person, not the save.
-- getFileWriter lands in Zomboid/Lua/ and is gated by a CASE-SENSITIVE
-- lowercase extension allowlist of ini|cfg|txt|log (LuaManager.java:9884), so
-- the name below is .txt and must stay that way - ".TXT" fails the gate, and
-- so does no extension at all.
--
-- THE CACHED-FONT PROBLEM, stated plainly because it bounds what this can do.
-- Most tabs in the family capture their font once, at file scope:
--
--     local FONT = UIFont.Small
--
-- A local captured at load time cannot see a preference changed at runtime, so
-- changing the scale does NOT resize those tabs until they are migrated to
-- read DFKit.font at draw time. The deck chrome and the Reclamation tabs read
-- live and respond immediately; the rest keep their old size until touched.
-- That is deliberate incrementalism, matching how DFKit adoption itself has
-- gone - but it means "across the board" is a direction of travel here, not a
-- claim about today.
--
-- APPLY IS IDEMPOTENT and safe to call before anything else has loaded: every
-- target is checked for existence first, so load order cannot break it.

if isServer() then return end

DFPrefs = DFPrefs or {}

DFPrefs.FILE = "RFTDPrefs.txt"

-- Defaults. opacity is a PERCENT integer rather than a float: it is what the
-- control shows the user, and keeping the stored form identical to the
-- displayed form means there is no rounding to disagree about.
local DEFAULTS = {
    fontScale = 1,    -- 1 small, 2 medium, 3 large
    opacity   = 60,   -- panel ground alpha, percent - DFKit.alpha.window default is 0.60
}

DFPrefs.state = DFPrefs.state or {}

-- The font ladder. Three steps, each a real PZ font - there is no arbitrary
-- scaling in this engine, only a fixed enum (UIFont.java), so a "scale" is a
-- choice among named fonts rather than a multiplier.
--
-- `code` tracks the ladder separately because monospace is load-bearing on
-- list tabs: ids and columns line up only while the font is fixed-width, so
-- the code slot must never fall back to a proportional face.
local LADDER = {
    [1] = { small = UIFont.Small,  label = UIFont.Small,  body = UIFont.Small,
            title = UIFont.Medium, code  = UIFont.Code },
    [2] = { small = UIFont.Medium, label = UIFont.Medium, body = UIFont.Medium,
            title = UIFont.Large,  code  = UIFont.CodeMedium },
    [3] = { small = UIFont.Large,  label = UIFont.Large,  body = UIFont.Large,
            title = UIFont.Large,  code  = UIFont.CodeLarge },
}

DFPrefs.SCALE_NAMES = { "Small", "Medium", "Large" }

-- The settings window renders this through DFForm, exactly as the Janitor view
-- renders RCTuning's. Same vocabulary, same widget, same spacing - which is
-- the whole reason the form renderer is in Core rather than in a tab.
DFPrefs.SCHEMA = {
    { group = "Display" },
    { key = "fontScale", kind = "enum", numValues = 3, label = "Text size",
      values = DFPrefs.SCALE_NAMES,
      help = "How large text is drawn across the deck and its tabs. Project Zomboid has no continuous font scaling - it ships a fixed set of fonts - so this picks between three real sizes rather than stretching one.\n\nTabs that captured their font when the game loaded keep their old size until they are updated; the deck chrome and the Reclamation tabs follow this setting immediately." },
    { key = "opacity", kind = "int", min = 20, max = 100, step = 5,
      label = "Panel opacity", unit = "%",
      help = "How much of the game world shows through the panel behind the text.\n\nLower values let you keep an eye on what is happening around you; higher values make dense text far easier to read against a bright or busy background. This affects panel grounds only - text and borders always draw at full strength, so raising it never dims the content.\n\nIt will not go below 20%: a fully transparent panel is one you cannot find again to fix, and the control that would undo it is drawn on the thing that just vanished." },
}

-- ---------------------------------------------------------------------------
-- Listeners. A panel that is already open needs to re-lay-out when the font
-- changes, because every row height it computed is now wrong.
-- ---------------------------------------------------------------------------
DFPrefs.listeners = DFPrefs.listeners or {}

function DFPrefs.onChange(fn)
    if type(fn) == "function" then
        DFPrefs.listeners[#DFPrefs.listeners + 1] = fn
    end
end

local function notify()
    for i = 1, #DFPrefs.listeners do
        -- One bad listener must not stop the others: a stale closure from a
        -- hot-reloaded panel is the expected failure here, not an exception.
        pcall(DFPrefs.listeners[i])
    end
end

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------
local function clampState()
    local s = DFPrefs.state
    s.fontScale = math.floor(tonumber(s.fontScale) or DEFAULTS.fontScale)
    if s.fontScale < 1 then s.fontScale = 1 elseif s.fontScale > 3 then s.fontScale = 3 end
    s.opacity = math.floor(tonumber(s.opacity) or DEFAULTS.opacity)
    -- Floored at 20 rather than 0. A fully transparent panel is not a
    -- preference, it is a panel you cannot find again to fix - and the control
    -- that would undo it is drawn on the thing that just vanished.
    if s.opacity < 20 then s.opacity = 20 elseif s.opacity > 100 then s.opacity = 100 end
end

function DFPrefs.load()
    for k, v in pairs(DEFAULTS) do DFPrefs.state[k] = v end

    pcall(function()
        local r = getFileReader(DFPrefs.FILE, false)
        if not r then return end
        while true do
            local line = r:readLine()
            if not line then break end
            local k, v = string.match(line, "^(%w+)=(.*)$")
            if k and v and DEFAULTS[k] ~= nil then
                DFPrefs.state[k] = tonumber(v) or DEFAULTS[k]
            end
        end
        r:close()
    end)

    clampState()
    return DFPrefs.state
end

function DFPrefs.save()
    clampState()
    pcall(function()
        -- create = true, append = false: this file is a complete snapshot
        -- every time, so appending would grow it forever with stale lines that
        -- the reader would then apply in order and the last one would win by
        -- accident rather than by intent.
        local w = getFileWriter(DFPrefs.FILE, true, false)
        if not w then return end
        -- writeln, not write with an embedded \n. getFileWriter returns a
        -- LuaManager.LuaFileWriter (LuaManager.java:9889) whose writeln appends
        -- System.lineSeparator(); hand-rolling "\n" writes a bare LF that
        -- Windows tooling renders as one long line. BufferedReader.readLine
        -- strips either on the way back in, so this is about the file being
        -- readable by a human, not about the parser.
        for k in pairs(DEFAULTS) do
            w:writeln(string.format("%s=%d", k, math.floor(DFPrefs.state[k] or 0)))
        end
        w:close()
    end)
end

-- ---------------------------------------------------------------------------
-- Apply - push the preference into every token table that renders from it
-- ---------------------------------------------------------------------------
function DFPrefs.apply()
    clampState()
    local f = LADDER[DFPrefs.state.fontScale] or LADDER[1]

    -- DFKit: what the tabs draw with.
    if DFKit and DFKit.font then
        DFKit.font.small = f.small
        DFKit.font.label = f.label
        DFKit.font.code  = f.code
        -- Added by this file rather than assumed to exist, so an older DFKit
        -- still gains the slots the newer tabs ask for.
        DFKit.font.body  = f.body
        DFKit.font.title = f.title
    end
    if DFKit and DFKit.alpha then
        DFKit.alpha.window = DFPrefs.state.opacity / 100
    end

    -- DFTheme: what the deck chrome draws with. Present only when Dragonfly's
    -- skinned deck is installed, hence the guard.
    if DFTheme and DFTheme.font then
        DFTheme.font.label = f.label
        DFTheme.font.body  = f.body
        DFTheme.font.title = f.title
    end

    notify()
end

-- Set one preference, persist, and apply. Whole-value, not a delta, so a
-- control that has drifted out of sync with the store cannot compound its
-- error every time it is clicked.
function DFPrefs.set(key, value)
    if DEFAULTS[key] == nil then return end
    DFPrefs.state[key] = tonumber(value) or DEFAULTS[key]
    DFPrefs.save()
    DFPrefs.apply()
end

function DFPrefs.get(key)
    if DFPrefs.state[key] == nil then return DEFAULTS[key] end
    return DFPrefs.state[key]
end

function DFPrefs.reset()
    for k, v in pairs(DEFAULTS) do DFPrefs.state[k] = v end
    DFPrefs.save()
    DFPrefs.apply()
end

-- Boot. OnGameStart rather than file scope: DFKit and DFTheme are separate
-- files with their own load order, and applying into tables that do not exist
-- yet would silently do nothing.
Events.OnGameStart.Add(function()
    DFPrefs.load()
    DFPrefs.apply()
end)

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
