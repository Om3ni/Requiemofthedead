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

require "RDNet"
require "LMCore"

LMSync = LMSync or {}

local TOKEN = "RFTDLimes"   -- wire token = mod id, per family conventions

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

    local function baselinePayload()
        return { rev = Limes.revision, zones = forClients(Limes.raw()) }
    end

    -- Join baseline and gap recovery are the same request: "give me everything,
    -- on my connection only".
    RDNet.register(TOKEN, "pull", { rate = 2 }, function(player)
        RDNet.reply(player, TOKEN, "baseline", baselinePayload())
    end)

    -- Full-store replacement announcement (import today, wholesale editor
    -- operations later).
    function LMSync.broadcastBaseline()
        RDNet.broadcast(TOKEN, "baseline", baselinePayload())
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
    function LMSync.broadcastDelta(changed, removed)
        RDNet.broadcast(TOKEN, "delta",
            { rev = Limes.revision, changed = forClients(changed or {}), removed = removed or {} })
    end

    -- Admin gate shared by both import routes. Returns the username, or nil
    -- after telling the caller no.
    local function adminGate(player)
        if not RDAccess.isTopAdmin(player) then
            forensic("LM.IMPORT_DENIED", player, {})
            RDNet.reply(player, TOKEN, "notice", { msg = "import is admin-only" })
            return nil
        end
        local who = "?"
        pcall(function() who = player:getUsername() end)
        return who
    end

    -- Shared tail: parse AUTHORITATIVELY (the tab's preview is UX, not
    -- trust), persist, apply, re-baseline every client, report back.
    local function finishImport(player, who, source, text)
        local ok, res = LMImport.parsePhunZones(text)
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

        LMPersist.save(res.zones, "import from " .. source, who)
        local warnings = Limes.apply(res.zones)
        for i = 1, #warnings do
            print("[Limes] resolve: " .. warnings[i])
        end
        LMSync.broadcastBaseline()
        forensic("LM.IMPORT", player, { source = source, zones = res.count,
                                        warnings = #res.warnings + #warnings })
        RDNet.reply(player, TOKEN, "notice", {
            msg = string.format("imported %d zones from %s (%d import warnings, %d resolve warnings), revision %d",
                res.count, source, #res.warnings, #warnings, Limes.revision),
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
    RDNet.register(TOKEN, "pasteImport", { capability = "any", rate = 1 }, function(player, args)
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

    -- The chunked paste route: layers past MAX_PASTE arrive in pieces and are
    -- reassembled here, then take the same finishImport tail as everything
    -- else - the server still parses ONE text authoritatively.
    --
    -- RATE 30, NOT 1 like the single-shot routes, and this is not a preference:
    -- RDRate's buckets are keyed by USERNAME ALONE and shared across every
    -- RDNet command, then compared against whichever command's max is being
    -- checked (RDRate.lua:38-52). At rate 1, chunk 1 opens the bucket and
    -- chunk 2 is rejected the moment count reaches 2 - the send would lose its
    -- tail silently, which is the exact failure mode this route exists to fix.
    -- The real bound is MAX_ASSEMBLY plus MAX_CHUNKS, not the rate.
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
        elseif p and p.getUsername then pcall(function() name = p:getUsername() end) end
        if name then assembly[name] = nil end
    end
    if Events.OnDisconnect then Events.OnDisconnect.Add(dropAssembly) end
    if Events.OnPlayerDisconnect then Events.OnPlayerDisconnect.Add(dropAssembly) end

    -- The filename route, against the Zomboid/Lua/ jail.
    RDNet.register(TOKEN, "import", { capability = "any", rate = 1 }, function(player, args)
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

    Events.OnGameStart.Add(pull)

    Events.OnServerCommand.Add(function(module, command, args)
        if module ~= TOKEN then return end
        if command == "baseline" and args and args.zones then
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
-- Copyright Project_Omen
