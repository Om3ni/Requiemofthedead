-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFDebugGate.lua - gate PZ's admin/debug right-click options behind a keypress.
--
-- Vanilla shows debug-styled context options (the "Tools" admin submenu, the
-- *Report options, etc.) to admins/moderators at all times, which clutters the
-- menu. The engine already supports hiding them: every addDebugOption() call site
-- honors the DebugOptions flag UI.HideDebugContextMenuOptions. We default that flag
-- ON (hidden) and let the admin reveal them on demand with a bindable key.
--
-- Pure client-side: it's a per-admin UI preference, no server round-trip. The whole
-- feature is just driving one engine boolean from a keypress.
--
-- Config (SandboxVars.RFTDDragonfly):
--   DebugGateEnabled       master toggle for this feature (default true)
--   DebugGateKey           LWJGL keycode that toggles visibility (default 68 = F10)
--   DebugGateRequiresShift require Shift held alongside the key (default false)

if isServer() then return end

-- F10. NOT unbound in vanilla, whatever an earlier version of this comment said:
-- media/lua/shared/keyBinding.lua:191 binds F10 to "Take screenshot". Pressing it
-- therefore ALSO writes a ~10 MB png to Zomboid/Screenshots, which is the visible
-- half of the "F10 does nothing" report - the screenshots are the key working, just
-- not the half anyone wanted.
--
-- It does not block us. GameWindow.java:426 polls GameKeyboard.isKeyPressed("Take
-- screenshot") and never calls eatKeyPress, so the release still reaches
-- LuaEventManager.triggerEvent("OnKeyPressed") at GameKeyboard.java:51 and this
-- gate still gets its event. Both handlers fire, independently.
--
-- Sharing the key with a vanilla binding is still a poor default. DebugGateKey
-- rebinds it; 41 (backtick) and 43 (backslash) are genuinely unbound.
local DEFAULT_KEY = 68

local DFDebugGate = {}

-- Live session state: are the debug options currently hidden? Starts hidden when
-- the feature is enabled, then flips on each keypress.
DFDebugGate.hidden = true

local function cfg()
    return SandboxVars.RFTDDragonfly or {}
end

-- Feature is live only when both the master panel toggle and this feature's own
-- toggle allow it. (Per-feature enable toggle, consistent across Dragonfly options.)
local function enabled()
    local s = cfg()
    if s.Enabled == false then return false end
    return s.DebugGateEnabled ~= false
end

-- Push the engine flag. hidden == true -> debug context options suppressed.
local function setHidden(hidden)
    local ok, opts = pcall(getDebugOptions)
    if ok and opts then
        opts:setBoolean("UI.HideDebugContextMenuOptions", hidden == true)
    end
end

local function shiftDown()
    local ok, held = pcall(function()
        return isKeyDown(Keyboard.KEY_LSHIFT) or isKeyDown(Keyboard.KEY_RSHIFT)
    end)
    return ok and held == true
end

-- Apply the starting state: hidden when enabled, vanilla (visible) when disabled.
local function applyDefault()
    if enabled() then
        DFDebugGate.hidden = true
        setHidden(true)
    else
        setHidden(false)
    end
end

local function toggle()
    if not enabled() then return end
    -- Who may REVEAL the debug options is a sandbox policy
    -- (RFTDDragonfly.DebugGateAccess): 1 = Admin only (shipped default),
    -- 2 = all staff. The engine decides who gets debug options at all; this
    -- gate decides who can unhide them. Silent return: the gate's existence
    -- isn't advertised to whoever doesn't clear the tier.
    if not RDAccess.meetsTier(getPlayer(), cfg().DebugGateAccess) then return end
    DFDebugGate.hidden = not DFDebugGate.hidden
    setHidden(DFDebugGate.hidden)
    if DFFeedback then
        DFFeedback.good(DFDebugGate.hidden and "Debug options hidden" or "Debug options shown")
    end
end

local function onKeyPressed(key)
    if not enabled() then return end
    local s = cfg()
    local bound = tonumber(s.DebugGateKey) or DEFAULT_KEY
    if bound <= 0 or key ~= bound then return end
    if s.DebugGateRequiresShift == true and not shiftDown() then return end
    toggle()
end

Events.OnGameStart.Add(applyDefault)
Events.OnKeyPressed.Add(onKeyPressed)

print("[Dragonfly] DFDebugGate loaded (default key F10, hides debug context options).")

return DFDebugGate

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
