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
--                Dragonfly Zones tab (LMImportTab) and shipped whole in one
--                command (~40KB against the 1MB connection buffer; the engine
--                limiter counts packets, not bytes)
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

    local function baselinePayload()
        return { rev = Limes.revision, zones = Limes.raw() }
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
    function LMSync.broadcastDelta(changed, removed)
        RDNet.broadcast(TOKEN, "delta",
            { rev = Limes.revision, changed = changed or {}, removed = removed or {} })
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
        LMPersist.save(res.zones, "import from " .. source, who)
        local warnings = Limes.apply(res.zones)
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
    local MAX_PASTE = 512 * 1024
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
