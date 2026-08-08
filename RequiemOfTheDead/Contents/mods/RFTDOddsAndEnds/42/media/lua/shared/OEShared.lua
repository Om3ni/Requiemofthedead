-- SPDX-License-Identifier: GPL-3.0-or-later
-- OEShared.lua - Odds & Ends: the mod's brain stem, loaded on both sides.
--
-- Odds & Ends is the family's catch-all: small self-contained modules that are
-- too slight to earn a mod id of their own and too player-facing to live in
-- Core. Core is the wrong home on purpose - everything hard-requires Core, so
-- anything parked there can never be switched off, and a server that wants one
-- of these modules but not another should be able to say so.
--
-- The house rules for a module in here:
--   * its own subfolder and file prefix (Lumberjack/LJ*)
--   * its own sandbox kill switch, default ON, read through OEShared.enabled
--   * no dependency on any sibling module - each must survive the others
--     being switched off, or deleted outright
--   * one wire token for the whole mod (below), dispatched by RDNet; no
--     module registers its own OnClientCommand listener
--
-- Modules today:
--   ActionSpeed    (ActionSpeed/AS*)    per-family timed-action speed scaling.
--                                       Lived in Dragonfly until 2026-07-30,
--                                       where it had landed because Dragonfly
--                                       owned a sandbox page - proximity, not
--                                       kind.
--   RIPIT          (RipIt/RI*)          Rip All on the inventory and world
--                                       right-click menus, scoped to the
--                                       containers you have open.
--   StickyHeadwear (StickyHeadwear/SH*) pins worn headwear so a hit does not
--                                       knock it off.
--   QuietHorn      (QuietHorn/QH*)      the vehicle horn still sounds but no
--                                       longer emits a world sound, so it
--                                       cannot be used to herd zombies. A full
--                                       replacement rather than a tweak: the
--                                       engine fuses the audible horn and the
--                                       herding sound into one method and
--                                       exposes no way to separate them.
--   Lumberjack     (Lumberjack/LJ*)     forestry. LJWeight scales the weight
--                                       of wooden items, reversibly, against
--                                       their vanilla values; LJSweep fells a
--                                       stand of trees off one context-menu
--                                       click. Renamed from Timber/TB* when
--                                       the sweep landed - weight scaling was
--                                       one feature, forestry is a module.
--   ContainerOrder (ContainerOrder/CO*) drag the container buttons in your own
--                                       inventory sidebar into the order you
--                                       want. Lived in Core until 2026-07-31,
--                                       parked there waiting on Wardrobe - and
--                                       it is the case study for why that rule
--                                       exists. Core cannot be switched off, and
--                                       this reorders a column that Better
--                                       Containers and Clean UI also reorder, so
--                                       players who wanted Dirge got a silent
--                                       fight over their sidebar with no error
--                                       to point at. Its kill switch is
--                                       therefore a compatibility control, not
--                                       a taste one.
--   InventoryCollapse                   fold the equipped and hotbar blocks out
--                  (InventoryCollapse/IC*)  of your own inventory list. Came out
--                                       of Core with ContainerOrder on the same
--                                       day and the same argument: it puts two
--                                       buttons in the inventory control row that
--                                       third-party UI mods also arrange. Note
--                                       that unlike its sibling it was never
--                                       dormant - the filtering was conditional
--                                       but the button registration never was,
--                                       so every player carried it whether they
--                                       used it or not.
--   Bookmark       (Bookmark/BM*)       a public-domain literature quote in a
--                                       popup on login. Client-only with no
--                                       counterpart on the other side, so it
--                                       is the one deliberate exception to the
--                                       "own sandbox kill switch" rule above -
--                                       its switch is a "Welcome Message"
--                                       toggle on the Dragonfly player panel,
--                                       because the whole point is a toggle
--                                       the player controls, not a server-wide
--                                       dial.
--
-- OEPrefs.lua is mod-wide infrastructure (not a module of its own - no
-- subfolder, prefix, or kill switch): a flat key=value client-prefs file for
-- player-facing cosmetic toggles, mirroring RFTDLastRites' LRPrefs. Toggles
-- register on the family's player panel (Dragonfly.registerPlayerSettings -
-- see Bookmark/BMPlayerPanel.lua) and persist through OEPrefs.get/set. The
-- history of WHERE the toggle lives is its own cautionary tale: hand-placed
-- rows on the vanilla Client panel died of checkbox collisions with other
-- mods (2026-08-08), the PZAPI.ModOptions berth that replaced them was an
-- explicit stopgap, and the player panel is the permanent home.
--
-- That second one is the reason this mod earns its id. A feature needing
-- sandbox dials must pick its home by WHAT IT IS and pay for its own sandbox
-- page; it must never inherit a namespace just because one already exists.
-- Sandbox namespaces are a gravity well - the same binding that attracts a
-- feature is what later makes it expensive to move - and before this mod
-- existed, the only well in the family was the admin panel's.
--
-- Owns: the wire token, the version handshake, and the per-module enable
-- reads. Nothing else - behaviour belongs to the modules.

OEShared = OEShared or {}

-- LOAD ORDER (landmine, verified 42.19): the CLIENT walks media/lua/shared
-- ALPHABETICALLY ACROSS ALL MODS, and "OEShared.lua" sorts before Core's
-- "RDShared.lua" - which would be nil on the line below. require() pulls
-- Core's file forward and is a no-op if the walk already ran it. (The dedi
-- resolves require= into mod order and loads Core first, so this only bites
-- clients.)
require "RDShared"

-- Wire token = mod id, per family convention. Every client<->server command
-- in this mod, from any module, travels under this one token and is
-- dispatched by RDNet's default-deny registry.
OEShared.MODULE  = "RFTDOddsAndEnds"
OEShared.VERSION = "1.0.0"   -- keep in sync with mod.info

RDShared.registerMod(OEShared.MODULE, OEShared.VERSION)

-- ---------------------------------------------------------------------------
-- Sandbox
-- ---------------------------------------------------------------------------

-- Read a module's kill switch. Defaults to ON when SandboxVars are not up yet
-- (main menu, early init) so nothing silently breaks before the world exists,
-- and so a fresh server that has never seen these options gets the shipped
-- behaviour rather than a dead mod.
function OEShared.enabled(flag)
    local sv = SandboxVars and SandboxVars.RFTDOddsAndEnds
    if not sv then return true end
    return sv[flag] ~= false
end

return OEShared

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
