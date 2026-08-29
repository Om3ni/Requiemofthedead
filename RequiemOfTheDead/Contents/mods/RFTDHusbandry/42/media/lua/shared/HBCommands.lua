-- SPDX-License-Identifier: GPL-3.0-or-later
-- HBCommands - command string constants and the token's RDNet registration.
-- Constants are shared; handlers route to HBData / HBAPIProbe / HBBedding /
-- HBSexCheck_Server / HBPartWatch.

-- LOAD ORDER (landmine, verified 42.19): the CLIENT walks media/lua/shared
-- ALPHABETICALLY ACROSS ALL MODS, so "HBCommands.lua" runs before Core's
-- "RDShared.lua" and RDShared would be nil below. require() pulls Core's file
-- forward; no-op if the walk already ran it. (The dedi loads Core first via
-- require=, so this only bites clients.)
require "RDShared"

RDShared.registerMod("RFTDHusbandry", "1.2.1")   -- keep in sync with mod.info

HBCmd = {}

HBCmd.ADD_SEEN           = "hbAddSeen"
-- RESERVED, NOT WIRED. The registration block below deliberately does not
-- register these two - see the note there. The names are kept because they are
-- the vocabulary the Ledger panel will claim, and HBData.register/unregister
-- already implement the behaviour behind them.
HBCmd.REGISTER           = "hbRegister"
HBCmd.UNREGISTER         = "hbUnregister"
HBCmd.SYNC_ANIMAL        = "hbSyncAnimal"
HBCmd.DEBUG_PROBE        = "hbDebugProbe"
HBCmd.DEBUG_REFILL       = "hbDebugRefill"
HBCmd.DEBUG_PROBE_RESULT = "hbDebugProbeResult"
HBCmd.ADD_BEDDING        = "hbAddBedding"     -- player: add hay bedding to a hutch
HBCmd.SEX_CHECK          = "hbSexCheck"       -- admin: authoritative sex diagnostic
HBCmd.PART_PLACED        = "hbPartPlaced"     -- player: floor-drop report (HBPartDropClient -> HBPartWatch)

if not isServer() then return end

-- RDNet is Core's one dispatcher for family tokens. Same load-order reason as
-- RDShared above: pulled forward explicitly rather than trusted to the walk.
require "RDNet"

print("[HB] server dispatch loaded (HBCommands)")

local TOKEN = "RFTDHusbandry"

-- Staff gate: RDAccess capability model (RFTDCore adoption). The old check
-- admitted ANY non-None access level; family policy is "any role holding at
-- least one capability". Debug-mode escape kept for dev sessions - this file
-- is dedicated-server-only (isServer() is false in SP), so the escape only
-- applies to a server launched with -Ddebug, which has already turned its own
-- anti-cheat enforcement off.
local function isAdminLike(player)
    if not player then return false end
    if isDebugEnabled and isDebugEnabled() then return true end
    return RDAccess.hasAnyCapability(player)
end

-- ---------------------------------------------------------------------------
-- RDNet adoption, 2026-08-25.
--
-- Replaces this file's own Events.OnClientCommand listener. The token is now
-- default-deny: an unregistered name reaches no handler at all and is recorded
-- as RD.NET_REJECT, where before it fell silently off the end of an if/elseif
-- chain that had no else arm. Rate limiting is per (token, command) rather
-- than absent, and a handler fault becomes RD.NET_ERROR instead of a bare
-- stack trace.
--
-- NO onReject HOOK, deliberately. Every staff gate on this token is
-- `gate = "handler"` (below), so RDNet itself can only ever reject for
-- unregistered-command or rate. Rate refusals are never answered by design -
-- a reply re-amplifies the flood - and answering an unregistered command would
-- mint a packet for a name nobody registered: RDNet tests the command BEFORE
-- the rate limiter (RDNet.lua:206-221), so that answer would be unmetered. The
-- one refusal a caller genuinely needs to hear about, DEBUG_REFILL's, is sent
-- from inside the handler, which is where its gate now lives.
--
-- THE PER-COMMAND CONSOLE PRINT IS GONE. It ran on every inbound command on
-- this token, unbounded and wire-driven. RDGuardian already records every
-- client command with its args (RDGuardian.lua:127), so it was a second copy
-- of a line Core writes anyway.
--
-- WHY THE GATES ARE `gate = "handler"` AND NOT `capability = "any"`. The three
-- staff commands gate on isAdminLike, which is `isDebugEnabled() OR
-- hasAnyCapability`. RDNet's gate is a single RDAccess.can call and cannot
-- express the OR, so declaring `capability = "any"` would quietly drop the
-- debug escape. `gate = "handler"` is the honest declaration for a gate RDNet
-- cannot state statically - the same call RQSvAdminCmds made for its
-- sandbox-tier gate.
--
-- hbRegister / hbUnregister ARE NOT REGISTERED, on purpose (2026-08-20).
--
-- They were scaffolding for the unbuilt Ledger panel - no UI ever sent them,
-- and nothing anywhere reads the herd list they wrote - so the only way to
-- reach them was to forge the command, which made them two unauthenticated
-- writes that each fired two transmitModData calls.
--
-- They are ABSENT rather than gated because there is nothing yet to gate
-- against: ownership is not recorded on the animal at all today (the RQHB
-- record holds one field, `id`), so no owner check is expressible. The real
-- feature puts a player-designed brand ON the animal with append-only history,
-- and the owner-or-admin rule gets written once, against that contract, when
-- the panel lands. HBData.register/unregister are untouched and still correct;
-- only the wire door is closed. Under RDNet that door is now default-deny
-- rather than a missing branch, so a forged hbRegister is refused and recorded
-- instead of ignored. Git holds the branches.
-- ---------------------------------------------------------------------------

RDNet.adopt(TOKEN)

-- ---- open, self-reporting ------------------------------------------------

-- A client saying which animals it just looked at. Open on purpose: it carries
-- no authority, and HBData.addSeen only touches an in-memory index (no
-- transmitModData), so the most a forged one can do is name an animal id that
-- already exists. The rate is sized for the FAN-OUT, not for a flood:
-- OnClickedAnimalForContext hands the client every animal under the cursor and
-- HBContextMenu sends one command per animal, so a right-click inside a full
-- pen is legitimately several in a frame.
RDNet.register(TOKEN, HBCmd.ADD_SEEN, { public = true, rate = 20 },
    function(player, args)
        local id = tonumber(args and args.id)
        if not id then return end
        local animal = getAnimal(id)
        if animal then HBData.addSeen(animal) end
    end)

-- Add hay bedding to a hutch. Open to any player: the diegetic path is a
-- client timed action that consumes a HayTuft and then sends this; the server
-- just tops up the charge (capped at MAX).
--
-- RATE SIZED FOR "Add Hay: all", which loops HBHutchesTab's scan results and
-- sends ONE COMMAND PER HUTCH with no batching, so a dense coop row is
-- legitimately a dozen or more in a frame. 30 is chosen to clear a realistic
-- pour rather than to be tight - a limit that silently dropped half a bulk
-- action while the client toasted success would be worse than none. The real
-- fix is to batch the way DEBUG_REFILL already batches OIDs; that changes the
-- payload contract, so it is written down rather than done here (TODO.md).
RDNet.register(TOKEN, HBCmd.ADD_BEDDING, { public = true, rate = 30 },
    function(player, args)
        if not (HBBedding and HBBedding.resolveHutchAt) then
            print("[HB] ADD_BEDDING: HBBedding not loaded")
            return
        end
        local x = tonumber(args and args.x)
        local y = tonumber(args and args.y)
        local z = tonumber(args and args.z) or 0
        -- Ignore any client-supplied amount; the server decides the per-add
        -- value so a client can't inflate it (addBedding still caps at MAX).
        if not (x and y) then return end
        local hutch = HBBedding.resolveHutchAt(x, y, z)
        if not hutch then
            print(string.format("[HB] ADD_BEDDING: no hutch at %s,%s,%s",
                tostring(x), tostring(y), tostring(z)))
            return
        end
        local added = HBBedding.perAdd()
        local total = HBBedding.addBedding(hutch, added)
        print(string.format("[HB] ADD_BEDDING: +%.0f at %d,%d,%d -> %.0f/%d",
            added, x, y, z, total, HBBedding.MAX))
    end)

-- Client-asserted forensic report; open like ADD_BEDDING - the sender reports
-- on itself. Bounds, the watchlist re-check and the MAX_ITEMS cap all live in
-- HBPartWatch.onClientReport, one boundary stated there.
--
-- The rate moved OUT of that handler and onto this registration (2026-08-25).
-- It was written inline because this command entered through the legacy
-- dispatcher, which had no per-command limiter of its own; RDNet's bucket is
-- already scoped to (token, command) with the same 4/sec, so keeping both
-- would have been two limiters counting the same traffic.
RDNet.register(TOKEN, HBCmd.PART_PLACED, { public = true, rate = 4 },
    function(player, args)
        if HBPartWatch and HBPartWatch.onClientReport then
            HBPartWatch.onClientReport(player, args)
        else
            print("[HB] PART_PLACED: HBPartWatch not loaded")
        end
    end)

-- ---- staff ---------------------------------------------------------------

-- Folded in 2026-08-19 from HBSexCheck_Server's own listener, which was a
-- second executable intake on this token. The logic still lives in that file;
-- only intake moved. HBSexCheck_Server is in server/ and this file is in
-- shared/, so it loads AFTER us - but dispatch happens at runtime, long past
-- load, so resolving it here is safe.
RDNet.register(TOKEN, HBCmd.SEX_CHECK, { gate = "handler", rate = 4 },
    function(player, args)
        if not isAdminLike(player) then
            print("[HBSexCheck] rejected (not admin)")
            return
        end
        if HBSexCheck_Server and HBSexCheck_Server.handle then
            HBSexCheck_Server.handle(player, args)
        else
            print("[HB] SEX_CHECK: HBSexCheck_Server not loaded")
        end
    end)

RDNet.register(TOKEN, HBCmd.DEBUG_PROBE, { gate = "handler", rate = 4 },
    function(player, args)
        if not isAdminLike(player) then
            print("[HB] DEBUG_PROBE rejected (not admin)")
            return
        end
        local id = tonumber(args and args.id)
        if not id then return end
        if HBAPIProbe and HBAPIProbe.runOn then
            HBAPIProbe.runOn(id, player)
        else
            print("[HB] DEBUG_PROBE: HBAPIProbe not loaded")
        end
    end)

-- One click, one batch write across every OID the panel selected - so the rate
-- bounds clicks, not animals.
RDNet.register(TOKEN, HBCmd.DEBUG_REFILL, { gate = "handler", rate = 2 },
    function(player, args)
        if not isAdminLike(player) then
            RDNet.reply(player, TOKEN, HBCmd.DEBUG_PROBE_RESULT,
                { line = "[set] rejected (not admin)" })
            return
        end
        -- Bidirectional stat write. value=0 → fully fed/watered (refill);
        -- value≈0.9 → starving/parched (starve). Comma-separated OID batch.
        -- updateLastTimeSinceUpdate() resets the elapsed-time clock on the
        -- way down (refill) so chunk reload doesn't immediately re-drain;
        -- harmless on the way up.
        local oidStr = tostring(args and args.oids or "")
        local target = tonumber(args and args.value) or 0
        local count, missing = 0, 0
        for s in string.gmatch(oidStr, "[^,]+") do
            local oid = tonumber(s)
            local animal = oid and getAnimal(oid)
            if not animal then
                missing = missing + 1
            else
                -- The current Build 42 stat object and CharacterStat enum are
                -- established engine contracts; unexpected mutation faults must
                -- surface instead of turning a manual admin action into a
                -- misleading partial success.
                animal:getStats():set(CharacterStat.HUNGER, target)
                animal:getStats():set(CharacterStat.THIRST, target)
                animal:updateLastTimeSinceUpdate()
                count = count + 1
            end
        end
        local label = (target <= 0.05) and "refill" or "starve"
        local msg = string.format("[%s value=%.2f] applied=%d  missing=%d",
            label, target, count, missing)
        print("[HB] " .. msg)
        RDNet.reply(player, TOKEN, HBCmd.DEBUG_PROBE_RESULT, { line = msg })
    end)

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
