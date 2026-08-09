-- SPDX-License-Identifier: GPL-3.0-or-later
-- RDTally.lua - fingerprint index over the forensic ring (server only).
--
-- ===========================================================================
-- THE RING ANSWERS "WHAT HAPPENED". THIS ANSWERS "WHAT DOMINATED".
--
-- A forensic stream is a record of every event in order, which is the right
-- shape for reconstructing an incident and the wrong shape for noticing one. To
-- learn that three distinct faults produced fourteen thousand records you have
-- to read fourteen thousand records - and by then the ring has rolled and the
-- early ones are gone.
--
-- So alongside the stream this keeps a tally: fingerprint -> how many, first
-- seen, last seen, one sample. It is a few hundred rows no matter how much
-- traffic passes through, it survives the ring rolling because it is written
-- separately, and it turns a report from a transcript into a finding.
--
-- This is the shape that made the PhunZones traffic result legible: not "here
-- are the packets" but "one mod is 63% of this". A transcript could not have
-- said that without someone reading all of it.
-- ===========================================================================
--
-- CALLED FROM INSIDE RDLog.forensic, behind an `if RDTally then` guard - the
-- same removable-file idiom as RDCmdRelay and RDTripwire, and for the same
-- reason RDGuardian's header gives at length: a second listener on a hot path to
-- re-walk a table the first one already has is the mistake this family keeps
-- choosing not to repeat. Delete this file and the tally disappears with no
-- other edit.
--
-- BOUNDED, AND IT SAYS SO WHEN IT BINDS. Distinct fingerprints are capped; past
-- the cap, further NEW keys accumulate into a single overflow row rather than
-- growing the table. The overflow row is written to the summary like any other,
-- because a tally that silently stops counting reads as a quiet server - the
-- same rule RDCmdRelay follows for its dropped-command counter.
--
-- Counts are advisory. This is a monitoring aid, not a ledger: it is rebuilt
-- empty on restart, and nothing downstream should treat a tally as evidence
-- when the ring holds the records themselves.

if not isServer() then return end

require "RDShared"

RDTally = RDTally or { streams = {} }

local MAX_KEYS    = 200     -- distinct fingerprints per stream before overflow
local SAMPLE_MAX  = 200     -- chars of the sample kept per fingerprint
local KEY_MAX     = 120
local OVERFLOW    = "(other)"

local dirty = false
local armed = nil           -- nil = not yet resolved; see enabled()

-- ---------------------------------------------------------------------------
-- Arming
-- ---------------------------------------------------------------------------
--
-- ON BY DEFAULT, the family rule: logging is on unless you turn it off, so the
-- record already exists when a question appears. The option exists so a sensor
-- can be disarmed when the sensor ITSELF is the suspect - which is the only
-- reason to turn a recorder off, and a reason that must not require a redeploy.
--
-- Resolved lazily and cached: SandboxVars is not populated at file scope, and
-- re-reading it per forensic record would cost more than the tally does.
local function enabled()
    if armed ~= nil then return armed end
    local v
    local ok = pcall(function() v = SandboxVars.RFTDCore and SandboxVars.RFTDCore.TallyEnabled end)
    if not ok or v == nil then return true end   -- absent option = on, don't latch
    armed = (v == true)
    return armed
end

-- ---------------------------------------------------------------------------
-- Clock
-- ---------------------------------------------------------------------------
--
-- CACHED, because the naive version made an engine call per forensic record.
-- RDGuardian writes one record per inbound client command, so on a busy server
-- that is a getTimestamp() - through a pcall - on the hottest path in the game,
-- purely to stamp a "last seen" nobody reads more than once a minute.
--
-- The cache refreshes when a NEW fingerprint appears (bounded by MAX_KEYS) and
-- when the summary is written (once a minute). Repeats reuse it.
--
-- THE TRADE-OFF, stated because it is a real loss of precision: `last` can be up
-- to one write interval stale. That is deliberate - the summary it feeds is
-- rewritten on the minute, so sub-minute accuracy on "when did this last happen"
-- would be thrown away by the consumer anyway. `first` is exact, because it is
-- only ever set on the refresh path.
local clockSec = 0

local function refreshClock()
    clockSec = RDShared.nowSec()
    return clockSec
end

-- ---------------------------------------------------------------------------
-- Fingerprinting
-- ---------------------------------------------------------------------------
--
-- The caller knows best what makes two of its records "the same", so an explicit
-- `fp` in the payload always wins. Below that, the conventional shapes already in
-- use in this family are recognised so existing producers get a useful tally
-- without being touched:
--
--   module + command   RDGuardian's RD.CMD - the traffic question
--   code               RDTripwire's RD.TRIP - which wire keeps tripping
--   act                RDTripwire's RD.LIFE - which lifecycle act
--
-- Falling back to the bare event name is always correct, just coarse.
local function fingerprint(evt, payload)
    local p = (type(payload) == "table") and payload or {}

    local key
    if p.fp then
        key = tostring(p.fp)
    elseif p.module and p.command then
        key = tostring(p.module) .. ":" .. tostring(p.command)
    elseif p.code then
        key = tostring(p.code)
    elseif p.act then
        key = tostring(p.act)
    end

    local out = tostring(evt or "?")
    if key and key ~= "" then out = out .. " " .. key end
    if #out > KEY_MAX then out = string.sub(out, 1, KEY_MAX) .. "~" end
    return out
end

local function sampleOf(payload)
    local p = (type(payload) == "table") and payload or {}
    local s = p.text or p.args or p.command or nil
    if s == nil then return nil end
    s = tostring(s)
    if #s > SAMPLE_MAX then s = string.sub(s, 1, SAMPLE_MAX) .. "~" end
    return s
end

-- ---------------------------------------------------------------------------
-- Note
-- ---------------------------------------------------------------------------
--
-- Hot path: one call per forensic record. Everything here is table lookups and
-- integer bumps; the string work is done once, on the first sighting of a
-- fingerprint, and never again for repeats. That asymmetry is the point - the
-- records this exists to summarise are by definition the repetitive ones.

function RDTally.note(streamName, evt, payload)
    if not enabled() then return end

    local name = tostring(streamName or "?")
    local st = RDTally.streams[name]
    if not st then
        st = { keys = {}, n = 0, total = 0 }
        RDTally.streams[name] = st
    end

    st.total = st.total + 1
    dirty = true

    local key = fingerprint(evt, payload)
    local row = st.keys[key]

    -- The repeat path is the hot one and does no engine calls and no string work:
    -- a lookup, an increment, and a cached stamp. That asymmetry is the point -
    -- the records this exists to summarise are by definition the repetitive ones.
    if row then
        row.n    = row.n + 1
        row.last = clockSec
        return
    end

    if st.n >= MAX_KEYS then
        local o = st.keys[OVERFLOW]
        if o then
            o.n    = o.n + 1
            o.last = clockSec
        else
            local now = refreshClock()
            st.keys[OVERFLOW] = {
                n = 1, first = now, last = now,
                sample = "distinct fingerprints beyond the " .. MAX_KEYS .. " cap",
            }
            st.n = st.n + 1
        end
        return
    end

    local now = refreshClock()
    st.keys[key] = { n = 1, first = now, last = now, sample = sampleOf(payload) }
    st.n = st.n + 1
end

-- ---------------------------------------------------------------------------
-- Summary
-- ---------------------------------------------------------------------------

-- Rows sorted by count, descending - the first screen of the file should be the
-- answer. A tally you have to sort yourself is a transcript again.
function RDTally.summary(streamName)
    local st = RDTally.streams[tostring(streamName or "?")]
    if not st then return nil end

    local rows = {}
    for key, row in pairs(st.keys) do
        rows[#rows + 1] = {
            fp = key, n = row.n, first = row.first, last = row.last, sample = row.sample,
        }
    end
    table.sort(rows, function(a, b)
        if a.n ~= b.n then return a.n > b.n end
        return tostring(a.fp) < tostring(b.fp)
    end)

    return {
        stream   = tostring(streamName),
        unique   = st.n,
        total    = st.total,
        capped   = (st.n >= MAX_KEYS) or nil,
        since    = RDShared.nowSec(),
        rows     = rows,
    }
end

-- One document per stream, rewritten in place. EXT_DOC (".json.txt"), not the
-- stream extension: this is a derived snapshot that is replaced whole, which is
-- exactly the distinction RDShared draws between EXT_DOC and EXT_STREAM. The
-- ".txt" tail is also what the 42.20 getFileWriter allowlist requires - see
-- RDLog's header on why an extensionless or ".json" name is refused.
local function summaryPath(name)
    return RDShared.DIR .. "forensic/" .. name .. "/summary" .. RDShared.EXT_DOC
end

function RDTally.write()
    if not dirty then return end
    dirty = false
    refreshClock()   -- also the once-a-minute refresh the repeat path rides on

    for name in pairs(RDTally.streams) do
        local doc = RDTally.summary(name)
        if doc then
            pcall(function()
                local w = getFileWriter(summaryPath(name), true, false)  -- truncate
                if w then
                    w:write(RDJson.encode(doc) .. "\n")
                    w:close()
                end
            end)
        end
    end
end

-- Written on the minute rather than per record. The tally is live in memory for
-- anything that asks; the file exists so a reader who arrives after a restart, or
-- who is not in the game at all, still gets the answer. Once a minute is far more
-- often than anyone reads it and far less often than it changes.
Events.EveryOneMinute.Add(function() pcall(RDTally.write) end)

return RDTally

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
