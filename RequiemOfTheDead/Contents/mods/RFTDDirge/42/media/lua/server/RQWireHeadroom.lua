-- SPDX-License-Identifier: GPL-3.0-or-later
-- Observes oversized zombie deltas without becoming part of their delivery path.

if not isServer() then return end

require "RDLog"
require "RDWire"

RQWireHeadroom = RQWireHeadroom or {}

local LARGE_DELTA_BYTES = 6144

function RQWireHeadroom.observe(delta)
    local estimate = RDWire.estimate(delta)
    if estimate <= LARGE_DELTA_BYTES then return end

    local changed = 0
    if delta.changed then
        for _ in pairs(delta.changed) do changed = changed + 1 end
    end

    -- No guard, and the concern behind it was answered STRUCTURALLY instead.
    -- It said the telemetry must not suppress "the authoritative zombieDelta
    -- broadcast that follows this observer" - which was true, and was an
    -- ORDERING problem wearing a pcall, the same shape as LSTour's teardown.
    -- The caller now broadcasts FIRST and observes after (RQServer.lua:1365),
    -- so nothing authoritative can be lost to a telemetry fault regardless of
    -- what this function grows into.
    --
    -- RDLog.forensic is total. The whole path
    -- was read for the RCAudit slice and holds for every caller: envelope() is
    -- RDJson.encode, which handles EVERY Lua type (cycles, depth and node count
    -- bounded, non-table values falling through to escape(), RDJson.lua:103-139),
    -- push/flushStream build on getFileWriter - which returns nil rather than
    -- throwing (LuaManager.java:5523-5555) - and writes through PrintWriter,
    -- which records I/O errors in an internal flag instead of raising them
    -- (:9850-9868). Core itself calls appendLine BARE on that reading
    -- (RDLog.lua:192-198). The one real boundary in there is around RDTally
    -- (:459) and is owned there, not out here.
    RDLog.forensic("wire", "RQ.DELTA_LARGE", nil, {
        fp      = "zombieDelta",
        est     = estimate,
        changed = changed,
        removed = delta.removed and #delta.removed or 0,
    }, "RFTDDirge")
end

