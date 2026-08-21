-- SPDX-License-Identifier: GPL-3.0-or-later
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

RDShared.VERSION = "1.2.0"   -- suite version: every RFTD mod moves in lockstep (README > Conventions)
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
    -- LuaManager:7466 - System.currentTimeMillis()/1000, cannot throw
    return getTimestamp()
end

function RDShared.nowMs()
    -- LuaManager:7471 - System.currentTimeMillis(), cannot throw
    return getTimestampMs()
end

function RDShared.worldAgeHours()
    -- getGameTime() is a bare read of GameTime.instance (LuaManager:4733) -
    -- nil before a world exists; getWorldAgeHours (GameTime:829) is
    -- arithmetic over field reads once the instance is there
    local gt = getGameTime()
    if not gt then return nil end
    return gt:getWorldAgeHours()
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

-- Make one untrusted value safe to put in a LINE-ORIENTED TEXT FILE.
--
-- The threat is log/record injection. Several places in the family format
-- wire-supplied values into delimited text lines - "k=v k=v" audit rows, and
-- tab-delimited override records - and append them to a .txt. A newline inside
-- any value ends the attacker's line and begins one they fully control,
-- including fields naming somebody else; a delimiter inside a value shifts
-- every field after it. Those files are what an admin reads to adjudicate a
-- dispute, so a forgeable line is worse than no line.
--
-- JSON sinks never needed this: RDJson.escape already handles newlines,
-- quotes, backslashes and every control byte (RDJson.lua:56-63). This is for
-- the legacy text sinks that predate it.
--
-- Control bytes become a VISIBLE escape rather than being dropped - silently
-- deleting them would let two different payloads print identically, and these
-- records exist to be unambiguous. `extra` names additional literal characters
-- to escape, for callers whose format has its own delimiter (a tab, a comma).
-- Length is capped because a wire string has no bound and one record must not
-- be able to fill the disk.
RDShared.TEXT_MAXLEN = 200

function RDShared.textSafe(v, extra)
    if v == nil then return "-" end
    local s = tostring(v)
    if s == "" then return "-" end
    s = s:gsub("[%c]", function(c) return string.format("\\x%02X", string.byte(c)) end)
    if extra then
        s = s:gsub("[" .. extra .. "]", function(c) return string.format("\\x%02X", string.byte(c)) end)
    end
    if #s > RDShared.TEXT_MAXLEN then s = s:sub(1, RDShared.TEXT_MAXLEN) .. "~" end
    return s
end

RDShared.registerMod(RDShared.MODULE, RDShared.VERSION)

-- ---------------------------------------------------------------------------
-- Debug gate. Off by default; flipped by SandboxVars.RFTDCore.Debug when the
-- sandbox page exists client/server-side. Print-only - never writes files.
-- ---------------------------------------------------------------------------

-- Core's own sandbox numbers, read defensively and clamped. Promoted
-- 2026-08-20 from identical sb/sbNum pairs in RDMeter and RDStall - the
-- clamp-to-envelope rule is the stable part (an operator's fat-fingered
-- 100000 must land at the bound, not in the hot path), and two copies of a
-- clamp is two chances for the bounds semantics to drift. RFTDCore namespace
-- only, on purpose: satellites read their own namespaces through their own
-- cfg() surfaces, and a namespace parameter here would just be a longer way
-- to write SandboxVars.
function RDShared.sbNum(key, default, lo, hi)
    local v = SandboxVars and SandboxVars.RFTDCore and SandboxVars.RFTDCore[key]
    if type(v) ~= "number" then return default end
    if lo and v < lo then return lo end
    if hi and v > hi then return hi end
    return v
end

function RDShared.debugOn()
    -- SandboxVars is nil until options load; the chain replaces the guard
    return (SandboxVars and SandboxVars.RFTDCore and SandboxVars.RFTDCore.Debug) == true
end

function RDShared.dbg(msg)
    if RDShared.debugOn() then print("[RFTDCore] " .. tostring(msg)) end
end

return RDShared

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
