-- SPDX-License-Identifier: GPL-3.0-or-later
-- LMSync.lua - the zone store's wire, both directions, both sides (§6).
--
-- PLACEMENT NOTE: the design doc's module map files this under server/. It
-- lives in shared/ instead, on RDNet's own precedent - one file owning one
-- channel end to end, each half behind its isServer() branch - so "LMSync is
-- the only writer on the wire" is true by construction on both sides, and
-- deleting this one file severs the channel whole rather than leaving a
-- half-registered client. Nothing else about the §6 contract moved.
--
-- THE CONTRACT, under the verified networking constraints (all mods share one
-- 300/sec-per-connection client-command budget; broadcast re-serializes per
-- player): server-push only, zero steady state.
--
--   JOIN     client sends one "pull" on OnGameStart; server replies the full
--            raw store to that connection alone (RDNet.reply). Raw, not
--            resolved: the resolver is shared code in LMCore, so shipping the
--            unflattened form keeps the payload small and both sides provably
--            resolving identically.
--   EDIT     rare, human-rate. Import (and the M4 editor after it) applies on
--            the server, persists via LMPersist, then broadcasts - a delta for
--            surgical edits, the full baseline for wholesale replacement.
--   RUNTIME  nothing. Every consumer read is a local lookup.
--
-- GAP RECOVERY, the RQReconcile pattern by revision counter: deltas arrive as
-- a strict +1 sequence; a client seeing rev jump re-pulls the baseline. The
-- re-pull is clockless - one pull per observed revision value, re-armed when
-- the store actually moves - because zone edits are rare enough that a gap is
-- a curiosity, not an emergency, and the server's rate gate bounds abuse.
--
-- IMPORT commands are the client->server route with teeth: capability-gated
-- at RDNet ("any" staff capability to enter the dispatcher) and then
-- admin-tier inside the handler (RDAccess.isTopAdmin - the §9 admin command),
-- because rewriting every zone on the server is top-shelf power. Two routes,
-- one shared tail:
--   pasteImport  the PRIMARY route - the export text itself, pasted into the
--                Dragonfly Zones tab (LMImportTab) and shipped in one command
--                when it fits under MAX_PASTE (an ENGINE ceiling, not a
--                policy - see there)
--   pasteChunk   the same route for layers past that ceiling: split client
--                side, reassembled by index here, then one authoritative parse
--   import       fallback by filename in the Zomboid/Lua/ jail, for a box
--                where the export already sits next to the server
--                (LMSync.requestImport("phunzones.txt") from the Lua console)
--   saveZones    the M4 editor's Save: a DIFF against a stated revision, which
--                comes straight back out as a delta. The only edit route that
--                does not replace the whole store.

require "RDNet"
require "RDWire"     -- the chunker sizes itself with RDWire's model (Reaper's rule)
require "LMCore"
require "LMIni"
require "LMEdit"

LMSync = LMSync or {}

local TOKEN = "RFTDLimes"   -- wire token = mod id, per family conventions

-- ---------------------------------------------------------------------------
-- BASELINE CHUNKING (2026-08-08) - the store never leaves as one blob again.
--
-- The wire probe caught its own family: RFTDLimes:baseline, 20 KB, S2C,
-- reason "unsplit". Not because anything was lost - sendServerCommand goes
-- out RELIABLE_ORDERED (UdpConnection.endPacket, reliability 3), so RakNet
-- fragments and retransmits and the data always arrives - but because one
-- big blob on ordering channel 0 stalls EVERYTHING ordered behind it for a
-- retransmit round-trip whenever a fragment drops, and it does so at join
-- time, when the wire is at its busiest. It also grows with the store, and
-- it makes our own telemetry cry wolf on every join, which is how a wire
-- stream stops being read.
--
-- So baselines page exactly the way Reaper's snapshot does (RPServer is the
-- reference implementation): slices sized against RDWire's OWN model - the
-- same model the meter judges the result by - declared to RDWire so the
-- meter reports "declared paged" instead of "unsplit", and PACED, a byte
-- budget per tick, so a join never sees the whole store in one burst.
--
-- Frame: { gen, seq, total, rev, zones = {name -> raw} }. gen is a
-- monotonic stream id - the client keys reassembly on it, so a re-pull
-- mid-stream supersedes cleanly. rev rides every chunk; it is applied once,
-- at assembly.
--
-- DELTAS STAY WHOLE while they are small - one zone per human edit is the
-- steady state and one packet is the right cost for it. A delta too big for
-- the budget (a rename touching hundreds of children) is sent as a chunked
-- BASELINE instead: a full-store replace is idempotent and always correct,
-- and the rare mass operation is precisely when re-syncing everything is
-- worth it. §6.1 rule 4 holds - it is still ONE announcement per edit,
-- just paged when the edit is huge.
-- ---------------------------------------------------------------------------

local CHUNK_BYTES    = 3072      -- per-chunk ceiling, envelope included
local CHUNK_ENVELOPE = 160       -- gen/seq/total/rev + module/command framing
local CHUNK_TICK_BYTES = 4096    -- send budget per tick, all pending streams

-- Slice a zones map into chunk-sized maps. Pure and shared so the test suite
-- can drive it without a wire: returns { {zones=..., est=...}, ... }, never
-- empty - an empty store still yields one empty slice, because a client
-- must receive total=1 to know the stream is complete (Reaper's lesson).
--
-- Names sorted so the slicing is deterministic across machines and reruns;
-- a zone LARGER than the budget still ships (alone, oversized) rather than
-- being dropped - the meter will name it, which is the correct outcome for
-- a single record nothing can split.
function LMSync.sliceZones(zones, budget)
    budget = (budget or CHUNK_BYTES) - CHUNK_ENVELOPE
    local names = {}
    for name in pairs(zones or {}) do names[#names + 1] = name end
    table.sort(names)

    local slices = {}
    local cur, curEst, curN = {}, 0, 0
    local function flush()
        if curN == 0 then return end
        slices[#slices + 1] = { zones = cur, est = curEst + CHUNK_ENVELOPE }
        cur, curEst, curN = {}, 0, 0
    end
    for i = 1, #names do
        local name = names[i]
        local est = RDWire.estimate(zones[name]) + #name + 8
        if curN > 0 and curEst + est > budget then flush() end
        cur[name] = zones[name]
        curEst = curEst + est
        curN = curN + 1
    end
    flush()
    if #slices == 0 then
        slices[1] = { zones = {}, est = CHUNK_ENVELOPE }
    end
    return slices
end

-- ---------------------------------------------------------------------------
-- Server half
-- ---------------------------------------------------------------------------

if isServer() then

    RDNet.adopt(TOKEN)

    local function forensic(evt, player, payload)
        if RDLog and RDLog.forensic then
            RDLog.forensic("limes", evt, player, payload, TOKEN)
        end
    end

    -- Everything leaving the server for a client goes through the §5 side tag:
    -- loot tables and dirge weights are read only by server code, so they cost
    -- join bytes for nothing and sit in every client's memory where a curious
    -- player can read them. Unregistered keys still ship - forward compat must
    -- never silently drop an admin's data.
    local function forClients(rawZones)
        return Limes.fields.stripServerOnly(rawZones)
    end

    -- The paged baseline pipeline. Declared so the wire meter classifies the
    -- stream as paged rather than flagging every chunk-adjacent size, and
    -- paced so a join drains gently instead of in one burst.
    RDWire.declareChunked(TOKEN .. ":baselineChunk", { budget = CHUNK_BYTES })

    local chunkGen   = 0
    local chunkSends = {}   -- { player|nil, chunks, sizes, nextIdx }; nil player = broadcast

    -- Queue the full store for one connection (or everyone, player = nil).
    local function queueBaseline(player)
        local zones = forClients(Limes.raw())
        local rev   = Limes.revision
        chunkGen = chunkGen + 1

        local slices = LMSync.sliceZones(zones, CHUNK_BYTES)
        local total  = #slices
        local chunks, sizes = {}, {}
        for i = 1, total do
            chunks[i] = { gen = chunkGen, seq = i, total = total,
                          rev = rev, zones = slices[i].zones }
            sizes[i]  = slices[i].est
        end
        chunkSends[#chunkSends + 1] =
            { player = player, chunks = chunks, sizes = sizes, nextIdx = 1 }
    end

    -- Paced by BYTES, not by chunk count, for Reaper's reason: one command per
    -- tick is a rate only if every command weighs the same. At 4 KB/tick a
    -- 20 KB store drains in ~5 ticks - imperceptible to the admin, gentle on a
    -- join that has every other mod's handshake in flight around it.
    local function pumpChunkSends()
        local spent = 0
        while spent < CHUNK_TICK_BYTES do
            local send = chunkSends[1]
            if not send then return end
            local chunk = send.chunks[send.nextIdx]
            if not chunk then
                table.remove(chunkSends, 1)
            else
                if send.player then
                    RDNet.reply(send.player, TOKEN, "baselineChunk", chunk)
                else
                    RDNet.broadcast(TOKEN, "baselineChunk", chunk)
                end
                spent = spent + (send.sizes[send.nextIdx] or CHUNK_BYTES)
                send.nextIdx = send.nextIdx + 1
            end
        end
    end

    if Events and Events.OnTick then
        -- No guard. A send that throws - a dropped connection inside RDNet.reply,
        -- a slice that will not serialise - is contained by Event.trigger, which
        -- runs every listener through protectedCallVoid inside a per-listener
        -- try/catch (Event.java:53-63); it cannot reach another listener. It would
        -- still log every tick, but a pcall never stopped that either: KahluaThread
        -- logs at throw time (:865/:1100) before Lua pcall sees the error.
        Events.OnTick.Add(function() pumpChunkSends() end)
    end

    -- Join baseline and gap recovery are the same request: "give me everything,
    -- on my connection only".
    --
    -- RATE 10, NOT 2. The bug this once compensated for is fixed at the
    -- source - RDRate buckets are now scoped per command, so other traffic no
    -- longer drains this one's budget - but the rate stays high because two
    -- eaters remain that no bucket fix reaches: RDNet's rejection path is
    -- still SILENT to the client, and since 42.16 the engine itself throttles
    -- client packets by type underneath us, join floods included. A dropped
    -- pull costs a session (empty store, every save refused on revision 0),
    -- so this route gets headroom, not a razor's edge. The real gate is that
    -- it fires once per observed revision; the rate is only flood cover.
    RDNet.register(TOKEN, "pull", { rate = 10 }, function(player)
        queueBaseline(player)
    end)

    -- Full-store replacement announcement (import today, wholesale editor
    -- operations later).
    function LMSync.broadcastBaseline()
        queueBaseline(nil)
    end

    -- Surgical edit announcement for the M4 editor: changed maps name -> raw
    -- zone, removed lists names. The ONLY steady-state broadcast in the design,
    -- and it fires at human edit rate.
    --
    -- ONE ANNOUNCEMENT PER EDIT (§6.1 rule 4). A save calls this OR
    -- broadcastBaseline, never both, and never "and re-baseline to be safe" -
    -- that reflex, in one line, is the whole of PhunZones' 62.8% wire share
    -- (Appendix A.3: it broadcasts a correct delta and then transmits the entire
    -- ModData table on top of it, per connection).
    --
    -- A delta that outgrows the chunk budget goes out as a paged BASELINE
    -- instead: a full replace is idempotent and always lands the client on
    -- exactly the server's state, and an edit that big (a rename rewriting
    -- hundreds of children) is precisely when a full re-sync earns its bytes.
    -- Still one announcement.
    function LMSync.broadcastDelta(changed, removed)
        local payload = { rev = Limes.revision,
                          changed = forClients(changed or {}), removed = removed or {} }
        if RDWire.estimate(payload) > CHUNK_BYTES then
            queueBaseline(nil)
            return
        end
        RDNet.broadcast(TOKEN, "delta", payload)
    end

    -- Admin gate shared by both import routes. Returns the username, or nil
    -- after telling the caller no.
    local function adminGate(player)
        if not RDAccess.isTopAdmin(player) then
            forensic("LM.IMPORT_DENIED", player, {})
            RDNet.reply(player, TOKEN, "notice", { msg = "import is admin-only" })
            return nil
        end
        -- getUsername is a field return; RDAccess.isTopAdmin has already
        -- resolved `player` above, so it is an IsoPlayer and non-nil.
        return player:getUsername() or "?"
    end

    -- Shared tail: parse AUTHORITATIVELY (the tab's preview is UX, not
    -- trust), persist, apply, re-baseline every client, report back.
    local function finishImport(player, who, source, text)
        local ok, res = LMImport.parseAny(text)
        if not ok then
            forensic("LM.IMPORT_FAIL", player, { source = source, err = tostring(res) })
            RDNet.reply(player, TOKEN, "notice", { msg = "import failed: " .. tostring(res) })
            return
        end
        -- Print every warning on the AUTHORITATIVE side, the way the boot path
        -- already does. The client preview shows these too, but that is one
        -- admin's screen at one moment; an import rewrites every zone on the
        -- server, so what it objected to belongs in the server's own record.
        -- The reply below still carries the counts for the admin.
        for i = 1, #res.warnings do
            print("[Limes] import: " .. res.warnings[i])
        end

        -- SNAPSHOT FIRST. An import replaces the store WHOLESALE - it is exactly
        -- as destructive as clearAll, which has snapshotted since the day it was
        -- written, while this path did not. That asymmetry cost a 76-zone layer
        -- on 2026-08-04: an import replaced it with 44 zones (no backup taken),
        -- and the clear three minutes later then spent the single backup slot on
        -- the 44 that had already overwritten them. Both destructive routes
        -- snapshot now.
        --
        -- Still ONE slot, because the jail has no rename and no delete - so the
        -- reply says so rather than letting an admin infer a safety net with
        -- more depth than it has.
        local snapped = LMPersist.snapshot("before import from " .. source, who)
        LMPersist.save(res.zones, "import from " .. source, who)
        local warnings = Limes.apply(res.zones)
        for i = 1, #warnings do
            print("[Limes] resolve: " .. warnings[i])
        end
        LMSync.broadcastBaseline()
        forensic("LM.IMPORT", player, { source = source, zones = res.count,
                                        warnings = #res.warnings + #warnings })
        RDNet.reply(player, TOKEN, "notice", {
            ok = true,
            msg = string.format("imported %d zones (%s) from %s (%d import warnings, %d resolve warnings), revision %d. %s",
                res.count, tostring(res.format or "?"), source, #res.warnings, #warnings, Limes.revision,
                snapped and ("Previous store snapshotted to " .. LMPersist.BACKUP
                    .. " - one level of undo, overwritten by the next import or clear.")
                    or "SNAPSHOT FAILED - the previous store was not saved."),
        })
        print("[Limes] " .. who .. " imported " .. res.count .. " zones from " .. source)
    end

    -- The paste route: the export text arrives in the command itself.
    --
    -- HARD ENGINE CEILING, 32767 BYTES PER STRING - verified the expensive way
    -- on Mosaic 2026-08-04. ByteBufferReader.getUTF reads its length as a
    -- SIGNED SHORT (`short length = this.bb.getShort()`, then
    -- `new byte[length]`, ByteBufferReader.java:52), so a 38453-byte payload
    -- wraps to -27083 and the server throws NegativeArraySizeException inside
    -- GameServer.receiveClientCommand - BEFORE any Lua handler runs. No reply
    -- is possible from there, which is why the admin's status line hung on
    -- "waiting for the verdict" forever.
    --
    -- The old 512KB cap came from reading the 1MB connection buffer as the
    -- limit. The buffer is not the constraint; the per-string length prefix is,
    -- and it is 16x smaller. A live PhunZones layer (~38KB) does not fit in one
    -- command, which is what "pasteChunk" below exists for.
    local MAX_PASTE = 32000
    RDNet.register(TOKEN, "pasteImport", { capability = "any", rate = 6 }, function(player, args)
        local who = adminGate(player)
        if not who then return end
        local text = args and args.text
        if type(text) ~= "string" or text == "" then
            RDNet.reply(player, TOKEN, "notice", { msg = "paste import: no text arrived" })
            return
        end
        if #text > MAX_PASTE then
            RDNet.reply(player, TOKEN, "notice", { msg = "paste import: over the "
                .. math.floor(MAX_PASTE / 1024) .. "KB cap" })
            return
        end
        finishImport(player, who, "(pasted " .. math.floor(#text / 1024 + 0.5) .. "KB)", text)
    end)

    -- CLEAR ALL. Built for the test rig: the way to prove a dial does what it
    -- claims is to wipe the map to nothing, draw a handful of zones with the
    -- dial at 100%, and see whether the world obeys - which is impossible while
    -- 76 production zones are still answering lookups.
    --
    -- Destructive and admin-only, so it snapshots first. That snapshot is ONE
    -- level of undo, not a backup: the jail has no rename and no delete, so
    -- each clear overwrites the previous snapshot. The reply says so rather
    -- than letting an admin infer a safety net that is not there.
    --
    -- Deliberately NOT re-seeding the templates. seedIfEmpty runs at boot, so a
    -- cleared store stays genuinely empty until the next restart - which is
    -- what a controlled experiment wants. An admin who wants the ladder back
    -- restarts, or re-imports.
    RDNet.register(TOKEN, "clearAll", { capability = "any", rate = 6 }, function(player)
        local who = adminGate(player)
        if not who then return end

        local had = #Limes.zoneNames()
        local snapped = LMPersist.snapshot("before clearAll", who)

        LMPersist.save({}, "clearAll by " .. who, who)
        Limes.apply({})
        LMSync.broadcastBaseline()

        forensic("LM.CLEAR", player, { zones = had, snapshot = snapped })
        RDNet.reply(player, TOKEN, "notice", {
            ok = true,
            msg = string.format("cleared %d zones, revision %d. %s", had, Limes.revision,
                snapped and ("Previous store snapshotted to " .. LMPersist.BACKUP
                    .. " - one level of undo, overwritten by the next clear.")
                    or "SNAPSHOT FAILED - the previous store was not saved."),
        })
        print("[Limes] " .. who .. " cleared all zones (" .. had .. " removed)")
    end)

    -- THE CENSUS, and its master switch.
    --
    -- Registered HERE rather than in LMZeds because this file is the only writer
    -- on the wire by construction (see the placement note at the top) - a second
    -- file registering commands on this token would make that claim false and
    -- leave a half-severed channel behind if either were deleted.
    --
    -- The full report goes to the SERVER log, which is the point: it is evidence
    -- to read next to the settings that produced it, not a status line. The
    -- admin gets back the one line that says whether it reconciled, so a census
    -- can be triggered and judged without alt-tabbing to the console.
    --
    -- Both are guarded on LMZeds existing: it is a removable file (delete it and
    -- `zeds` goes inert), and a removable file that leaves an RDNet command
    -- answering into a nil is not removable, it is a crash waiting for an admin.
    RDNet.register(TOKEN, "census", { capability = "any", rate = 4 }, function(player, args)
        local who = adminGate(player)
        if not who then return end
        if not LMZeds then
            RDNet.reply(player, TOKEN, "notice", { msg = "census unavailable: LMZeds is not installed" })
            return
        end
        local rep = LMZeds.census(args and args.verbose == true)
        local ok = (rep.inZone + rep.outside) == rep.total
        RDNet.reply(player, TOKEN, "notice", { ok = ok, msg = string.format(
            "census printed to the server log: %d zombies in cell, %d inside zones,"
            .. " %d suppressed since boot%s",
            rep.total, rep.inZone, rep.removed,
            ok and "" or " - TOTALS DID NOT RECONCILE, see the log") })
        print("[Limes] " .. who .. " printed the zone census")
    end)

    RDNet.register(TOKEN, "censusSwitch", { capability = "any", rate = 4 }, function(player, args)
        local who = adminGate(player)
        if not who then return end
        if not LMZeds then
            RDNet.reply(player, TOKEN, "notice", { msg = "census unavailable: LMZeds is not installed" })
            return
        end
        local on = LMZeds.setCensus(args and args.on == true)
        RDNet.reply(player, TOKEN, "notice", { ok = true, msg = on
            and "census ON - the server log gets a full report every ten game minutes"
            or  "census OFF" })
        print("[Limes] " .. who .. " turned the zone census " .. (on and "on" or "off"))
    end)

    -- SAVE, the M4 editor's one command (§6.1 rules 2, 4, 7, 8).
    --
    -- The editor edits a local draft and sends the DIFF once, on an explicit
    -- Save - never on a drag, never on field-blur, never on a timer. What
    -- arrives is { rev, changed, removed }, and it is the same shape that goes
    -- straight back out as a delta, which is why an edit to one zone costs one
    -- zone on the wire in both directions.
    --
    -- OPTIMISTIC CONCURRENCY (rule 7). The revision the draft was taken against
    -- has to still be the store's, or the save is refused. Server Lua is
    -- single-threaded so two saves cannot interleave mid-apply, but two admins
    -- with the tab open is otherwise a silent lost update: the second Save
    -- overwrites zones the first one moved, with no symptom on either screen.
    -- Refusing costs the loser their unsaved edits and tells them why; the
    -- alternative costs the winner their saved ones and tells nobody.
    --
    -- VALIDATED AGAIN HERE. The client validated before offering Save; that
    -- validation ran on a machine we do not own. LMEdit is shared code precisely
    -- so the authoritative check is the same check, rather than a second
    -- implementation that drifts.
    --
    -- ERRORS ARE SCOPED TO WHAT THIS SAVE TOUCHED. A pre-existing defect
    -- elsewhere in the store - a name from some other importer that will not
    -- round-trip, a dangling chain nobody has fixed - must not wedge every
    -- future edit. The check asks "is this save making things wrong", not "is
    -- the store perfect".
    local MAX_SAVE_ZONES = 512    -- a rename can legitimately touch every child
    local MAX_RECTS      = 128    -- the live layer's worst zone has nine
    local MAX_PROFILES   = 16     -- matches LMEdit.MAX_PROFILES; test pins them equal

    -- RATE 8, NOT 1. The shared-bucket bug that made rate=1 a coin flip is
    -- fixed at the source (RDRate now scopes buckets per command), but a
    -- dropped save is the worst outcome this mod has - the admin's work
    -- silently never written, the status line hung on "waiting for the
    -- verdict..." - and RDNet rejections are still silent while the engine's
    -- own per-type packet throttle (42.16+) sits underneath us. Real
    -- protections here are adminGate, the revision gate and re-validation;
    -- the rate is flood cover and 8/second is still nothing.
    RDNet.register(TOKEN, "saveZones", { capability = "any", rate = 8 }, function(player, args)
        local who = adminGate(player)
        if not who then return end

        local changed = (args and type(args.changed) == "table") and args.changed or {}
        local removed = (args and type(args.removed) == "table") and args.removed or {}

        local rev = tonumber(args and args.rev)
        if rev == nil or rev ~= Limes.revision then
            -- REVISION 0 IS NOT A CONFLICT. The store is stamped revision 1 the
            -- moment it boots, so a draft taken against 0 was taken against a
            -- client that never received a baseline at all - its join pull was
            -- dropped and nothing re-armed. Blaming "someone else saved first"
            -- there sends an admin hunting a second admin who does not exist,
            -- while the actual state is that their whole zone list is missing
            -- and anything they build on top of it is a new store, not an edit.
            -- Cost a session on 2026-08-06: the .ini was fine and holding 44
            -- zones the entire time.
            local msg
            if rev == 0 then
                msg = "save refused: your client never received the zone list"
                    .. " (it is on revision 0, the store is on " .. Limes.revision
                    .. "). Nobody else saved - your draft is built on an EMPTY"
                    .. " store, so saving it would not be an edit. Rejoin to pull"
                    .. " the zones, then redo your changes."
            else
                msg = string.format(
                    "save refused: you were editing revision %s, the store is on %d."
                    .. " Someone else saved first - reopen the tab to pick up their"
                    .. " changes before redoing yours.", tostring(rev), Limes.revision)
            end
            RDNet.reply(player, TOKEN, "notice", { msg = msg })
            return
        end

        local nChanged = 0
        for name, rec in pairs(changed) do
            nChanged = nChanged + 1
            if type(name) ~= "string" or type(rec) ~= "table" then
                RDNet.reply(player, TOKEN, "notice", { msg = "save refused: malformed change set" })
                return
            end
            if rec.rects and #rec.rects > MAX_RECTS then
                RDNet.reply(player, TOKEN, "notice", { msg = "save refused: '" .. name
                    .. "' has " .. #rec.rects .. " rectangles, over the " .. MAX_RECTS .. " cap" })
                return
            end
            -- Shape, not just size: profiles is admin-typed data arriving over
            -- the wire, and a non-string entry would flow into flattenChain's
            -- raw[pname] lookup as a table key. Refuse the save rather than
            -- store a shape the resolver was never written for.
            if rec.profiles ~= nil then
                if type(rec.profiles) ~= "table" or #rec.profiles > MAX_PROFILES then
                    RDNet.reply(player, TOKEN, "notice", { msg = "save refused: '" .. name
                        .. "' has a bad profiles list (max " .. MAX_PROFILES .. " names)" })
                    return
                end
                for i = 1, #rec.profiles do
                    if type(rec.profiles[i]) ~= "string" then
                        RDNet.reply(player, TOKEN, "notice", { msg = "save refused: '" .. name
                            .. "' profiles entry " .. i .. " is not a name" })
                        return
                    end
                end
            end
        end
        if nChanged + #removed > MAX_SAVE_ZONES then
            RDNet.reply(player, TOKEN, "notice", { msg = "save refused: " .. (nChanged + #removed)
                .. " zones in one save, over the " .. MAX_SAVE_ZONES .. " cap" })
            return
        end
        if nChanged == 0 and #removed == 0 then
            RDNet.reply(player, TOKEN, "notice", { msg = "nothing to save" })
            return
        end

        -- A CLIENT CANNOT DESTROY WHAT IT WAS NEVER SENT.
        --
        -- A save carries whole pruned RECORDS, not per-field deltas, and
        -- forClients() strips every field registered `side = "server"` on the
        -- way out. Put those together and an editor that touches one dial on a
        -- zone sends back a record with no server-only fields in it at all -
        -- and applyChangeSet replaces the record wholesale. Every dirge weight
        -- and spacing on that zone would have been silently erased by editing
        -- its title, and the .ini rewritten to match before anyone noticed.
        --
        -- So the authoritative side carries them across. This is not a
        -- courtesy: the client was never shown these values, so its silence
        -- about them is not an instruction. Clearing a server-only field is
        -- consequently not possible from the editor, which is the correct
        -- trade - it is done in the .ini, by someone who can see it.
        local existing = Limes.raw()
        for name, rec in pairs(changed) do
            local was = existing[name]
            if was and was.fields then
                for k, v in pairs(was.fields) do
                    local spec = Limes.fields.spec(k)
                    if spec and spec.side == "server" then
                        rec.fields = rec.fields or {}
                        if rec.fields[k] == nil then rec.fields[k] = v end
                    end
                end
            end
        end

        -- Fold, then validate the result. Folding first is what makes a cycle or
        -- an orphan visible at all: neither is a property of the change set on
        -- its own, only of the store it lands in.
        local merged = LMEdit.applyChangeSet(Limes.raw(), changed, removed)
        local touched = {}
        for name in pairs(changed) do touched[name] = true end
        local errs = {}
        for _, p in ipairs(LMEdit.new(merged, Limes.revision):validate()) do
            if p.level == "error" and touched[p.zone] then
                errs[#errs + 1] = p.zone .. ": " .. p.msg
            end
        end
        if #errs > 0 then
            for i = 1, #errs do print("[Limes] save refused: " .. errs[i]) end
            forensic("LM.SAVE_INVALID", player, { errors = #errs, first = errs[1] })
            RDNet.reply(player, TOKEN, "notice", { msg = "save refused: " .. errs[1]
                .. (#errs > 1 and ("  (and " .. (#errs - 1) .. " more - see the server log)") or "") })
            return
        end

        -- The pruned records come out of the fold, so the store, the file and
        -- the broadcast all carry the identical shape rather than three
        -- near-copies of what the client happened to send.
        local pruned = {}
        for name in pairs(changed) do pruned[name] = merged[name] end

        local warnings = Limes.applyDelta(pruned, removed)
        for i = 1, #warnings do print("[Limes] resolve: " .. warnings[i]) end
        LMPersist.save(Limes.raw(), "editor save by " .. who, who)

        -- ONE announcement (rule 4). A delta, and nothing after it.
        LMSync.broadcastDelta(pruned, removed)

        forensic("LM.SAVE", player, { changed = nChanged, removed = #removed,
                                      rev = Limes.revision, warnings = #warnings })
        -- ok = true is what paints this green on the admin's status line; every
        -- refusal above deliberately omits it (see LMEditView's notice handler).
        RDNet.reply(player, TOKEN, "notice", { ok = true, msg = string.format(
            "saved: %d zone%s changed, %d removed, revision %d%s",
            nChanged, nChanged == 1 and "" or "s", #removed, Limes.revision,
            #warnings > 0 and (" (" .. #warnings .. " resolve warnings - see the server log)") or "") })
        print("[Limes] " .. who .. " saved " .. nChanged .. " changed / "
            .. #removed .. " removed, revision " .. Limes.revision)
    end)

    -- The chunked paste route: layers past MAX_PASTE arrive in pieces and are
    -- reassembled here, then take the same finishImport tail as everything
    -- else - the server still parses ONE text authoritatively.
    --
    -- RATE 30, NOT 1 like the single-shot routes: a chunked send fires many
    -- commands in one second BY DESIGN, so its budget must cover a full burst
    -- - at rate 1, chunk 2 would be dropped the moment count reached 2 and
    -- the send would lose its tail silently, the exact failure mode this
    -- route exists to fix. (Historically the hazard was doubled: RDRate
    -- buckets were keyed by username alone and SHARED across every command,
    -- so any concurrent traffic drained this budget too. That is fixed -
    -- buckets are now scoped per command - which makes 30 mean what it says:
    -- thirty chunks per second on this route, regardless of what else the
    -- admin's client is doing.) The real bound is MAX_ASSEMBLY plus
    -- MAX_CHUNKS, not the rate.
    local MAX_ASSEMBLY = 512 * 1024
    local MAX_CHUNKS   = 64      -- bounds the completeness scan against a hostile `total`
    local assembly     = {}      -- username -> { parts, total, bytes }

    RDNet.register(TOKEN, "pasteChunk", { capability = "any", rate = 30 }, function(player, args)
        local who = adminGate(player)
        if not who then return end

        local seq   = tonumber(args and args.seq)
        local total = tonumber(args and args.total)
        local text  = args and args.text
        if not seq or not total or total < 1 or total > MAX_CHUNKS
            or seq < 1 or seq > total or type(text) ~= "string" then
            assembly[who] = nil
            RDNet.reply(player, TOKEN, "notice", { msg = "chunked import: malformed chunk, aborted" })
            return
        end

        -- A fresh seq 1, or a changed plan, discards whatever was half-built:
        -- a restarted import must never splice into the previous attempt.
        local a = assembly[who]
        if seq == 1 or not a or a.total ~= total then
            a = { parts = {}, total = total, bytes = 0 }
            assembly[who] = a
            RDNet.reply(player, TOKEN, "notice", { msg = "receiving " .. total .. " chunks..." })
        end

        if not a.parts[seq] then a.bytes = a.bytes + #text end   -- a resend must not double-count
        a.parts[seq] = text
        if a.bytes > MAX_ASSEMBLY then
            assembly[who] = nil
            RDNet.reply(player, TOKEN, "notice", { msg = "chunked import: over the "
                .. math.floor(MAX_ASSEMBLY / 1024) .. "KB assembly cap, aborted" })
            return
        end

        -- Assemble by INDEX, never by arrival: correctness must not rest on
        -- the wire delivering these in order.
        for i = 1, total do
            if not a.parts[i] then return end    -- still short a piece; stay quiet
        end

        assembly[who] = nil
        finishImport(player, who, "(pasted " .. math.floor(a.bytes / 1024 + 0.5)
            .. "KB in " .. total .. " chunks)", table.concat(a.parts))
    end)

    -- Half-finished assemblies die with the connection, so an admin who drops
    -- mid-send leaves nothing behind. Dual-event shape copied from RDRate:
    -- different engine paths hand this event different argument types.
    local function dropAssembly(p)
        local name
        if type(p) == "string" then name = p
        elseif p and p.getUsername then name = p:getUsername() end
        if name then assembly[name] = nil end
    end
    if Events.OnDisconnect then Events.OnDisconnect.Add(dropAssembly) end
    if Events.OnPlayerDisconnect then Events.OnPlayerDisconnect.Add(dropAssembly) end

    -- The filename route, against the Zomboid/Lua/ jail.
    RDNet.register(TOKEN, "import", { capability = "any", rate = 6 }, function(player, args)
        local who = adminGate(player)
        if not who then return end
        local file = args and tostring(args.file or "") or ""
        local text
        if file == "" then
            file, text = LMPersist.findImportCandidate()
            if not text then
                RDNet.reply(player, TOKEN, "notice",
                    { msg = "no import candidate found in Zomboid/Lua/ (tried "
                        .. table.concat(LMPersist.IMPORT_CANDIDATES, ", ") .. ")" })
                return
            end
        else
            if file:find("[/\\]") or file:find("%.%.") then
                RDNet.reply(player, TOKEN, "notice", { msg = "bare filename only (Zomboid/Lua/)" })
                return
            end
            text = LMPersist.readAll(file)
            if not text then
                RDNet.reply(player, TOKEN, "notice", { msg = file .. " not found in Zomboid/Lua/" })
                return
            end
        end
        finishImport(player, who, file, text)
    end)

-- ---------------------------------------------------------------------------
-- Client half
-- ---------------------------------------------------------------------------

else

    local lastRev     = 0
    local pulledAtRev = -1   -- one pull per observed revision; -1 arms the join pull

    local function pull()
        if pulledAtRev == lastRev then return end
        pulledAtRev = lastRev
        RDNet.send(TOKEN, "pull", {})
    end

    function LMSync.requestImport(file)
        RDNet.send(TOKEN, "import", { file = file })
    end

    -- The census pair. Both are fire-and-forget: the report lands in the server
    -- log and the verdict comes back as an ordinary notice, so neither needs a
    -- reply path of its own.
    function LMSync.printCensus(verbose)
        RDNet.send(TOKEN, "census", { verbose = verbose == true })
    end

    function LMSync.setCensus(on)
        RDNet.send(TOKEN, "censusSwitch", { on = on == true })
    end

    -- The editor's Save. One command, on an explicit click, carrying the draft's
    -- revision so the server can refuse a stale write (§6.1 rules 2 and 7).
    --
    -- Nothing is applied locally. The saving client learns about its own edit
    -- from the delta broadcast, exactly like every other client (rule 3) - so
    -- there is no second code path where the editor's view and the store can
    -- disagree, and no window where the admin is looking at state nobody else
    -- has. Returns the count so the caller can say what it sent.
    function LMSync.save(changed, removed, rev)
        changed, removed = changed or {}, removed or {}
        local n = #removed
        for _ in pairs(changed) do n = n + 1 end
        if n == 0 then return 0 end
        RDNet.send(TOKEN, "saveZones", { rev = rev, changed = changed, removed = removed })
        return n
    end

    Events.OnGameStart.Add(pull)

    -- BASELINE INSURANCE. The join pull is one command with no delivery
    -- guarantee: RDNet's rejection paths are silent to the client, and since
    -- 42.16 the engine itself throttles client packets by type - and a join
    -- is exactly when every mod's handshake floods the wire at once. If the
    -- pull is eaten, pulledAtRev already equals lastRev, so nothing would
    -- ever re-arm - this client shows an empty store for the whole session
    -- and every save it attempts carries revision 0, which reads as "zones
    -- did not survive the restart" even though the ini on disk is fine.
    -- Until the first baseline lands, ask again every GAME minute -
    -- EveryOneMinute is DayLength-compressed game time, so at a 1-hour day
    -- that is roughly every 2.5 real seconds, which is fine for one tiny
    -- command against a rate of 10. The moment the baseline lands (lastRev
    -- moves off 0) this costs nothing forever. isClient() gates the resend
    -- because SP is neither client nor server: the server half above never
    -- registered, no baseline can ever arrive, and without the gate this
    -- would ping the void every game minute for the whole session.
    Events.EveryOneMinute.Add(function()
        if lastRev == 0 and isClient() then
            pulledAtRev = -1
            pull()
        end
    end)

    -- Chunked-baseline reassembly, keyed by gen. A chunk from a NEWER gen
    -- supersedes an in-flight older stream outright (a re-pull mid-stream, an
    -- import landing during a join); a chunk from an older gen is dropped.
    -- Chunks within a gen can arrive in any order - reliable-ordered delivery
    -- means they will not, but the assembly does not lean on that.
    local assembling = nil   -- { gen, rev, total, zones, got }

    local function onBaselineChunk(args)
        local gen   = tonumber(args and args.gen)
        local seq   = tonumber(args and args.seq)
        local total = tonumber(args and args.total)
        if not (gen and seq and total) or type(args.zones) ~= "table" then return end

        if not assembling or gen > assembling.gen then
            assembling = { gen = gen, rev = tonumber(args.rev) or 0,
                           total = total, zones = {}, got = {} }
        elseif gen < assembling.gen then
            return                                    -- a dead stream's straggler
        end

        local a = assembling
        if a.got[seq] then return end                 -- duplicate
        a.got[seq] = true
        for name, rec in pairs(args.zones) do a.zones[name] = rec end

        local n = 0
        for _ in pairs(a.got) do n = n + 1 end
        if n < a.total then return end

        -- Complete: one apply, exactly like the old single-packet baseline.
        local rev = a.rev > 0 and a.rev or (lastRev + 1)
        assembling = nil
        Limes.apply(a.zones, rev)
        lastRev = rev
    end

    Events.OnServerCommand.Add(function(module, command, args)
        if module ~= TOKEN then return end
        if command == "baselineChunk" and args then
            onBaselineChunk(args)
        elseif command == "baseline" and args and args.zones then
            -- The pre-chunking shape, kept so a NEW client on an OLD server
            -- (mid-rollout skew) still receives its store. The suite versions
            -- in lockstep, so this is a one-release courtesy, not a contract.
            local rev = tonumber(args.rev) or (lastRev + 1)
            Limes.apply(args.zones, rev)
            lastRev = rev
        elseif command == "delta" and args then
            local rev = tonumber(args.rev) or 0
            if rev <= lastRev then return end        -- stale or duplicate
            if rev == lastRev + 1 then
                Limes.applyDelta(args.changed, args.removed, rev)
                lastRev = rev
            else
                pull()                               -- gap: pull the baseline
            end
        elseif command == "notice" and args and args.msg then
            print("[Limes] server: " .. tostring(args.msg))
        end
    end)

end

return LMSync

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
