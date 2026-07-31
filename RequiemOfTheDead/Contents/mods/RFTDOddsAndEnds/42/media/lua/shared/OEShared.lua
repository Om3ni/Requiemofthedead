-- OEShared.lua - Odds & Ends: the mod's brain stem, loaded on both sides.
--
-- Odds & Ends is the family's catch-all: small self-contained modules that are
-- too slight to earn a mod id of their own and too player-facing to live in
-- Core. Core is the wrong home on purpose - everything hard-requires Core, so
-- anything parked there can never be switched off, and a server that wants one
-- of these modules but not another should be able to say so.
--
-- The house rules for a module in here:
--   * its own subfolder and file prefix (Reliquary/RL*)
--   * its own sandbox kill switch, default ON, read through OEShared.enabled
--   * no dependency on any sibling module - each must survive the others
--     being switched off, or deleted outright
--   * one wire token for the whole mod (below), dispatched by RDNet; no
--     module registers its own OnClientCommand listener
--
-- Modules today:
--   Reliquary      (Reliquary/RL*)      staff-placed, whitelist-gated stash
--                                       that dissolves once it has been emptied.
--   ActionSpeed    (ActionSpeed/AS*)    per-family timed-action speed scaling.
--                                       Lived in Dragonfly until 2026-07-30,
--                                       where it had landed because Dragonfly
--                                       owned a sandbox page - proximity, not
--                                       kind.
--   RIPIT          (RipIt/RI*)          Rip All / Cut All on the inventory and
--                                       world right-click menus, scoped to the
--                                       containers you have open.
--   StickyHeadwear (StickyHeadwear/SH*) pins worn headwear so a hit does not
--                                       knock it off.
--   Timber         (Timber/TB*)         scales the weight of wooden items,
--                                       reversibly, against their vanilla
--                                       values.
--
-- That second one is the reason this mod earns its id. A feature needing
-- sandbox dials must pick its home by WHAT IT IS and pay for its own sandbox
-- page; it must never inherit a namespace just because one already exists.
-- Sandbox namespaces are a gravity well - the same binding that attracts a
-- feature is what later makes it expensive to move - and before this mod
-- existed, the only well in the family was the admin panel's.
--
-- Chandler (artisan soap and candle crafting, derived from SoapZ by
-- DarylMasterGG) shares this mod id back in PZMod but is deliberately NOT in
-- the bundle yet - it brings ~3.5k lines, 30 textures, and a third-party
-- attribution obligation, and it migrates on its own turn.
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
OEShared.VERSION = "0.2.0"   -- keep in sync with mod.info

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
