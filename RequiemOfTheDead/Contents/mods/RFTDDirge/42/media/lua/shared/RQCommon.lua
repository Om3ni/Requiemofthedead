-- RQCommon.lua - Dirge's shared brain stem (both sides).
--
-- Exists to kill two classes of drift that shipped in 1.0.x:
--
--   1. WIRE TOKEN. Dirge historically dispatched on the bare token "RQ",
--      which Husbandry also squatted on - a live cross-dispatch collision
--      that survived only because command names never overlapped. The token
--      is the mod id now, per family law, and the bare token is fully dead:
--      the bundle ships every client and server atomically, so no wire
--      transition period was ever needed.
--
--   2. ENUM TABLES. The sandbox enum value arrays existed twice (client
--      RQConfig, server RQSvShared) and had already drifted: DEVOUR_TIME
--      index 1 was 10s on the client and 15s on the server - players saw a
--      10-second cast bar for a 15-second devour. The server was
--      authoritative all along, so these tables carry the server values and
--      both sides now read from here. If you change a value, you change it
--      once.
--
-- Also owns the mod's Lua-side VERSION (mod.info stays in sync by hand, and
-- the RD.HELLO handshake catches it when it doesn't) and Dirge's RFTDCore
-- registration.

RQCommon = RQCommon or {}

RQCommon.MODULE  = "RFTDDirge"   -- wire token = mod id
RQCommon.VERSION = "1.0.0"

-- Receive-side gate. The legacy "RQ" token is DEAD: the bundle is a brand-new
-- Workshop item, so no subscriber can ever hold old-wire clients, and
-- Husbandry (the other "RQ" squatter) took its own token in the same bundle.
-- The collision that survived two years by luck is now structurally gone.
function RQCommon.acceptsModule(m)
    return m == RQCommon.MODULE
end

-- RFTDCore adoption (hard require - no guards, per family law).
--
-- LOAD ORDER: the CLIENT walks media/lua/shared ALPHABETICALLY ACROSS ALL
-- MODS. "RQCommon.lua" happens to sort AFTER Core's "RDShared.lua", so this
-- file survives on luck alone - the same pattern killed MMSvShared/DFCore.
-- The require() lines make the dependency real instead of alphabetical.
require "RDShared"
require "RDEvents"

RDShared.registerMod(RQCommon.MODULE, RQCommon.VERSION)
RDEvents.registerNamespace("RQ", RQCommon.MODULE, {
    -- one record per server-confirmed special-zombie death, attributed to the
    -- reporting (owning/killing) client
    SPECIAL_KILL = { scope = "p", req = { "ztype" }, loc = { "x", "y", "z" } },
})

-- ---------------------------------------------------------------------------
-- Sandbox enum arrays (index -> value) - SERVER-TRUTH VALUES, single copy.
-- ---------------------------------------------------------------------------

-- SPAWN_CHANCE and TYPE_WEIGHT used to live here as 7- and 8-step enums. Both
-- are plain 0-100 integer sandbox options now (1% granularity), so the tables
-- are gone rather than left to rot -- see RQCommon.pct below. The one thing
-- that broke in the move: a saved SpawnChance/*Weight is a raw PERCENT now,
-- where it used to be a 1-based index into those arrays. Servers upgrading
-- from 1.1.0 must re-set those six options once; nothing can migrate them for
-- us, because index 5 and 5% are indistinguishable in the saved file.
RQCommon.ENUMS = {
    CAST_4             = {1, 2, 3, 5},                     -- 4-tier cast time (seconds)
    SCREAMER_INTERVAL  = {15, 30, 45, 60, 90, 120},        -- default idx=4 -> 60s
    SCREAMER_CAST      = {1, 2, 3, 5, 8},                  -- default idx=3 -> 3s
    SCREAMER_RANGE     = {10, 15, 20, 30, 40},             -- default idx=3 -> 20
    SCREAMER_SOUND     = {20, 40, 60, 80, 100},            -- default idx=3 -> 60
    SCREAMER_SPAWN_MIN = {10, 15, 20, 25},                 -- default idx=1 -> 10
    SCREAMER_SPAWN_MAX = {15, 20, 25, 30},                 -- default idx=3 -> 25
    SCREAMER_THRESHOLD = {3, 5, 8, 10, 15},                -- default idx=2 -> 5
    JUGG_RADIUS        = {3, 5, 8, 12, 20},                -- default idx=3 -> 8
    JUGG_BUFF          = {5, 10, 15, 20, 25},              -- default idx=2 -> 10%
    EMP_RANGE          = {5, 10, 15, 20, 30},              -- default idx=3 -> 15
    EMP_CAST           = {1, 2, 3, 5, 8},                  -- default idx=3 -> 3s
    EMP_RADIUS         = {3, 5, 8, 12, 20},                -- default idx=3 -> 8
    EMP_DRAIN          = {20, 35, 50, 75},                 -- default idx=2 -> 35%
    GLUTTON_RADIUS     = {1, 2, 3, 5, 8, 12, 20},          -- default idx=7 -> 20
    GLUTTON_MULT       = {2, 3, 5, 8, 10},                 -- default idx=3 -> 5
    DEVOUR_TIME        = {15, 20, 30, 45, 60, 90},         -- default idx=1 -> 15s (server truth; client had 10)
    BOSS_COOLDOWN      = {5, 10, 15, 20, 30, 60},          -- default idx=3 -> 15s
}

-- Get actual value from enum index, fall back to default when out of bounds.
function RQCommon.ev(tbl, idx, defaultIdx)
    local i = idx or defaultIdx
    return tbl[i] or tbl[defaultIdx]
end

-- Read a 0-100 percent sandbox option, clamped, with a percent default.
-- Every spawn-chance knob (global + the five type weights) reads through this
-- on BOTH sides, so the clamp exists once instead of twelve times -- the same
-- reason the enum tables were pulled up here.
function RQCommon.pct(v, defaultPct)
    local n = tonumber(v)
    if n == nil then return defaultPct end
    return math.max(0, math.min(100, n))
end

-- Base health multipliers per type (was duplicated client + server).
RQCommon.HEALTH_MULTIPLIER = {
    Screamer   = 2,
    Juggernaut = 10,
    EMP        = 2,
    Glutton    = 2,
    Scavenger  = 2,
    Boss       = 10,
}

RQCommon.JUGGERNAUT_MIN_BASE_HEALTH = 1.0

return RQCommon
