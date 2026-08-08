-- SPDX-License-Identifier: GPL-3.0-or-later
-- BMModOptions.lua  (client)
--
-- Bookmark's one switch - "Welcome Message", default OFF - lives on the
-- engine's native mod-options screen: ESC -> Options -> Mods -> Odds and Ends.
--
-- IT USED TO LIVE ON THE CLIENT PANEL (BMUserPanel.lua, retired 2026-08-08),
-- beside vanilla's Show Connection Info tick-boxes, per the family rule that
-- player-facing toggles go where players already look. That placement died of
-- the disease every hand-placed row in a shared panel carries: another mod on
-- the server's list appends its own checkbox by the same trick - borrow
-- `cancel`'s row, push Close down - and whichever hook runs second lands its
-- box on top of the first. Hook order against a third-party mod is not ours
-- to control, so there is NO robust fix inside that panel; the collision is
-- structural. (Ours hit a safehouse-boundaries checkbox from another mod.)
--
-- PZAPI.ModOptions is the engine's answer, native since B42: each mod gets
-- its own SECTION in a scrolling list - no coordinates, no anchors, nothing
-- to contend for - and TIS's own guidance files client-side UI toggles here
-- (gameplay dials stay sandbox options, which is exactly O&E's split: every
-- other module keeps its sandbox kill switch, and this stays the one
-- player-personal toggle). This amends the family's older "we don't use
-- ModOptions" note, which predates B42 shipping a native one.
--
-- LIFECYCLE, verified in MainOptions.lua: the options screen loads
-- ModOptions.ini when it builds (:2796) and calls each mod's apply() on
-- Accept, then saves (:3760-3766). So: register at file load (the screen
-- reads the registry when opened), seed the tick-box from OEPrefs so an
-- existing user's choice migrates, and push the value back into OEPrefs in
-- apply() - OEPrefs stays the single source BMClient reads, and this file
-- stays the only one that knows where the checkbox lives.
--
-- A side effect worth naming: the old Client panel exists only in MP, so in
-- solo the toggle was unreachable (harmless - default off). The Mods screen
-- exists everywhere, so the quote works in solo now too. Not a goal, not a
-- problem.

if isServer() and not isClient() then return end

require "Bookmark/BMClient"   -- explicit: isEnabled/setEnabled must not ride on load order

-- The registry is read when the options screen opens, so registration happens
-- at file load - no event to wait for. Guarded so a build without the API
-- (dedicated server contexts load no client files, but belt and braces) just
-- leaves the toggle unreachable rather than erroring the file out.
if PZAPI and PZAPI.ModOptions then
    -- KEYS, not translated strings: MainOptions getText()s the section name,
    -- every option name and every tooltip at render time (:2806, :2815,
    -- :2817). Passing pre-translated text here would translate twice - which
    -- happens to fall through, and "happens to" is not a contract.
    local options = PZAPI.ModOptions:create("RFTDOddsAndEnds", "IGUI_OE_ModName")

    options:addDescription("IGUI_OE_BookmarkBlurb")

    local tick = options:addTickBox("bookmarkEnabled",
        "IGUI_OE_BookmarkEnable",
        Bookmark.isEnabled(),                       -- migrate the OEPrefs choice
        "IGUI_OE_BookmarkTip")

    -- Called on Accept, AFTER the engine's own GameOption.apply pass has
    -- written every widget's state back into option.value (MainOptions
    -- :3760 runs the widget sync, :3762 runs this) - so reading tick.value
    -- here reads what the player just clicked. OEPrefs stays the owner:
    -- BMClient reads it, and a future surface can write it too without
    -- either knowing about the other.
    function options:apply()
        Bookmark.setEnabled(tick and tick.value == true)
    end
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
