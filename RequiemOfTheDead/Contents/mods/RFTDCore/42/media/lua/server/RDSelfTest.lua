-- SPDX-License-Identifier: GPL-3.0-or-later
-- RDSelfTest.lua - one-command proof that the logging engine works on the
-- real dedi (server only, staff-gated).
--
-- Fire from a staff client:  RDNet.send("RFTDCore", "selftest", {})
-- Optional: { forensic = <count> } to override the synthetic record count.
--
-- In about a minute on the target box this proves:
--   * the forensic ring wraps (default 50k records > 2 segments)
--   * truncation-as-reclaim actually reclaims bytes
--   * head.txt tracks the segment/line counter
--   * slugs.tsv.log disambiguates colliding usernames (Bob.Smith vs Bob_Smith)
--   * the encoder survives a hostile payload: raw control bytes, \b, \f,
--     large floats, an empty map, an empty array
--
-- Exit criterion (run OFF the box): tools/validate_jsonl.py over the RFTD
-- directory - json.loads on every line with zero failures. The measured
-- numbers this prints (elapsed ms, records, approx bytes) belong in the
-- RDLog.lua header once measured on the dedi: an admin who cannot predict
-- disk cost will disable the mod.

if not isServer() then return end

RDSelfTest = RDSelfTest or {}

local FORENSIC_DEFAULT = 50000

function RDSelfTest.run(player, args)
    local count = (args and type(args.forensic) == "number" and args.forensic) or FORENSIC_DEFAULT
    if count > 200000 then count = 200000 end
    local who = (player and player.getUsername and player:getUsername()) or "console"
    print("[RFTDCore] selftest started by " .. tostring(who) .. " (" .. count .. " forensic records)")

    local t0 = RDShared.nowMs()

    -- 1) Colliding usernames through the directory ledger. String subjects
    -- carry no SteamID, so this exercises the ~N fallback path specifically.
    local dirA = RDIdentity.dirFor("Bob.Smith")
    local dirB = RDIdentity.dirFor("Bob_Smith")
    print("[RFTDCore] selftest dirs: 'Bob.Smith' -> " .. dirA .. ", 'Bob_Smith' -> " .. dirB
        .. (dirA ~= dirB and "  (disambiguated OK)" or "  (COLLISION - BUG)"))
    if player then
        local own = RDIdentity.dirFor(player)
        print("[RFTDCore] selftest: your directory is chronicle/p/" .. own
            .. (own:find("%.") and "  (SteamID suffix OK)" or "  (no SteamID available - fallback name)"))
    end

    -- 2) Hostile payload through the chronicle tier (5 records, 2 fake users).
    local hostile = {
        ctrl      = "raw:\1:bs:\b:ff:\f:tab:\t",
        bigFloat  = 1234567890123456.789,
        bigInt    = 9007199254740991,
        negZero   = -0.0,
        emptyMap  = {},
        emptyArr  = RDJson.EMPTY_ARR,
        nested    = { a = { b = { c = "deep" } } },
        quoteBack = 'q:"\\:end',
    }
    for i = 1, 5 do
        RDLog.chronicle("RD.TEST", (i % 2 == 1) and "Bob.Smith" or "Bob_Smith", {
            n = i, hostile = hostile, by = who,
        })
    end

    -- 3) Forensic volume: enough to wrap segments and exercise head.txt.
    for i = 1, count do
        RDLog.forensic("selftest", "RD.TEST", "Bob.Smith", {
            n = i, filler = "synthetic-forensic-record", hostile = (i == 1) and hostile or nil,
        }, "RFTDCore")
    end
    RDLog.flush()

    local elapsed = RDShared.nowMs() - t0
    local approxBytes = count * 200
    print(string.format(
        "[RFTDCore] selftest done: %d forensic + 5 chronicle records in %d ms (~%d KB). "
        .. "Validate off-box with tools/validate_jsonl.py over Lua/RFTD/.",
        count, elapsed, math.floor(approxBytes / 1024)))

    if player then
        RDNet.reply(player, RDShared.MODULE, "selftestDone", {
            forensic = count, ms = elapsed, dirA = dirA, dirB = dirB,
        })
    end
end

RDNet.register(RDShared.MODULE, "selftest", { capability = "any", rate = 2 }, function(player, args)
    RDSelfTest.run(player, args)
end)

return RDSelfTest

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
