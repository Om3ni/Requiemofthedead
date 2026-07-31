-- RDShared.lua - RFTDCore root: identity, clocks, and the family mod registry.
--
-- RFTDCore is the harness the rest of the RFTD family depends on. Everything in
-- Core hangs off the RD* globals defined across these files; consumers declare
-- require=RFTDCore in the same release they first call a Core API, and from then
-- on the dependency is hard - no `if not RDLog` guards at call sites.
--
-- VERSION lives here and NOWHERE else in Lua. Keep it in sync with mod.info
-- (both copies). The family has already shipped a drift bug of exactly this
-- kind (DFCore.VERSION 0.6.2 vs mod.info 0.6.3), which is why the HELLO
-- version handshake exists at all.

RDShared = RDShared or {}

RDShared.VERSION = "0.1.0"
RDShared.MODULE  = "RFTDCore"   -- command-module wire token; RD is taken, this is not
RDShared.DIR     = "RFTD/"      -- everything Core writes lives under <cacheDir>/Lua/RFTD/

-- ---------------------------------------------------------------------------
-- WRITE EXTENSIONS - forced by the engine, not a naming preference.
--
-- Since 42.20, getFileWriter returns nil unless the extension is in
-- Set.of("ini","cfg","txt","log") (LuaManager.java:9884, gate at :5514). The set
-- does not exist in 42.19.1; it was added mid-season and silently killed every
-- .jsonl/.json/.tsv write in the family - silently because our writers all guard
-- `if w then`, so pcall never errored and RDLog.chronicle went on returning true.
--
-- getFileExtension() reads the substring after the LAST dot, so a compound name
-- keeps the real format visible while presenting an allowed extension. Suffix by
-- WRITE SEMANTICS so the mode is legible on disk:
--   EXT_STREAM (.log)  append-only, one record per line
--   EXT_DOC    (.txt)  rewritten whole, in place
--
-- Traps: the check is case-sensitive and unlowercased (".LOG" fails);
-- extensionless names fail; only the last path segment is inspected, so dots in
-- a "<SafeName>.<SteamID>" directory are harmless. Reads are NOT gated, which is
-- what makes the *_LEGACY names below readable - see RDLog's header for why
-- nothing migrates them (Lua cannot rename or delete, and their extension is now
-- refused for writing, so truncate-as-delete is gone too).
-- ---------------------------------------------------------------------------

RDShared.EXT_STREAM = ".jsonl.log"
RDShared.EXT_DOC    = ".json.txt"

-- Pre-42.20 names. Write paths must NEVER use these - readers only.
RDShared.EXT_STREAM_LEGACY = ".jsonl"
RDShared.EXT_DOC_LEGACY    = ".json"

-- ---------------------------------------------------------------------------
-- Clocks. getTimestamp() = epoch seconds, getTimestampMs() = epoch millis;
-- both engine-provided. gameDay() is in-game world age in days so gameplay
-- questions ("was that before the horde night?") answer without converting
-- real-world timestamps.
-- ---------------------------------------------------------------------------

function RDShared.nowSec()
    local ok, t = pcall(getTimestamp)
    if ok and type(t) == "number" then return t end
    return 0
end

function RDShared.nowMs()
    local ok, t = pcall(getTimestampMs)
    if ok and type(t) == "number" then return t end
    local ok2, t2 = pcall(function() return getTimeInMillis() end)
    if ok2 and type(t2) == "number" then return t2 end
    return 0
end

function RDShared.worldAgeHours()
    local ok, h = pcall(function() return getGameTime():getWorldAgeHours() end)
    if ok and type(h) == "number" then return h end
    return nil
end

function RDShared.gameDay()
    local h = RDShared.worldAgeHours()
    if h then return h / 24.0 end
    return nil
end

-- ---------------------------------------------------------------------------
-- Family registry. Each RFTD mod calls RDShared.registerMod at load; the HELLO
-- handshake reports the set so version skew between separately-published items
-- (dedi runs published builds, dev client symlinks the working tree) becomes a
-- log line instead of a silent mystery.
-- ---------------------------------------------------------------------------

RDShared.mods = RDShared.mods or {}

function RDShared.registerMod(id, version)
    RDShared.mods[tostring(id)] = tostring(version or "?")
end

RDShared.registerMod(RDShared.MODULE, RDShared.VERSION)

-- ---------------------------------------------------------------------------
-- Debug gate. Off by default; flipped by SandboxVars.RFTDCore.Debug when the
-- sandbox page exists client/server-side. Print-only - never writes files.
-- ---------------------------------------------------------------------------

function RDShared.debugOn()
    local ok, v = pcall(function() return SandboxVars.RFTDCore and SandboxVars.RFTDCore.Debug end)
    return ok and v == true
end

function RDShared.dbg(msg)
    if RDShared.debugOn() then print("[RFTDCore] " .. tostring(msg)) end
end

return RDShared
