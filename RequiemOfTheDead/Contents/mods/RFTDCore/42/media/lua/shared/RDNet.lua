-- SPDX-License-Identifier: GPL-3.0-or-later
-- RDNet.lua - the family's command channel (both sides).
--
-- THE PERMISSION WALL, and its honest limits: the engine fires OnClientCommand
-- to every registered listener unconditionally and discards return values, so
-- Lua cannot veto delivery of anyone else's commands. What CAN be locked down
-- is our own namespace. Once a family module token routes through RDNet, it
-- has exactly ONE server listener - this dispatcher - and a command that is
-- unregistered, over-rate, or outside the sender's capabilities is genuinely
-- rejected: no handler exists to execute it, and the rejection is recorded
-- with full context. Injection aimed at family commands hits a locked door.
-- Everything outside the family remains observe-only (RDGuardian).
--
-- Server-side usage (a satellite adopts this at its migration turn and stops
-- registering its own OnClientCommand listener - the single-dispatcher rule):
--
--     RDNet.adopt("RFTDReclamation")   -- claim the wire token, once
--     RDNet.register("RFTDReclamation", "claimVehicle", {
--         capability = nil,        -- open to players (server logic re-checks)
--         rate       = 10,         -- max hits/second (default 20)
--     }, function(player, args) ... end)
--
--     staff-only:  capability = "any"           (any capability at all)
--     specific:    capability = Capability.X or "CapabilityName"
--     open:        public = true                (no capability, ON PURPOSE)
--     elsewhere:   gate = "handler"             (gated, but not by RDNet)
--
-- A command with no capability must declare WHY. It buys nothing at runtime; it
-- exists so an open endpoint cannot be created by forgetting to write a gate,
-- and so the intended-open set stays greppable rather than inferred.
--
-- `gate = "handler"` is for a gate RDNet cannot express statically - a
-- sandbox-configurable access tier, an ownership test, a proximity check. Dirge's
-- admin commands are the case that forced it: they gate on
-- RDAccess.meetsTier(player, SandboxVars.RFTDDirge.ConvertAccess), a tier the
-- OPERATOR sets at runtime, so no fixed capability names the same set of people.
-- Declaring those `public = true` would have been a lie that quietly polluted
-- the intended-open list with six admin commands.
--
-- A token may pass a reject hook when it adopts, to answer refused callers in
-- its own reply contract:
--
--     RDNet.adopt("RFTDDragonfly", {
--         onReject = function(player, command, reason) ... end,
--     })
--
-- Client-side usage:
--
--     RDNet.send("RFTDReclamation", "claimVehicle", { ... })
--
-- Server->client traffic goes through RDNet.reply / RDNet.broadcast so both
-- directions share one choke point.
--
-- Rejections land in the "rdnet" forensic stream as RD.NET_REJECT with the
-- reason (unregistered-command / rate / capability). Accepted commands are
-- not separately logged here - RDGuardian already records every client
-- command with args; a second copy would be noise.
--
-- Handler FAULTS land in the same stream as RD.NET_ERROR, and that symmetry is
-- the point: a rejection is the benign, expected case, while a fault is a
-- command that passed both gates and then half-executed - the strictly more
-- interesting record. Guardian does not cover it; Guardian sees the command
-- ARRIVE, not that serving it threw. The console print is kept alongside
-- because that is where an operator actually notices a fault mid-session; the
-- forensic line is the one that survives to be queried later.

RDNet = RDNet or {}

-- ---------------------------------------------------------------------------
-- Client side
-- ---------------------------------------------------------------------------

if not isServer() then
    function RDNet.send(module, command, args)
        -- LuaManager:7208 - client/SP branches only reachable here (the file is
        -- side-gated); its server-side throw cannot be hit
        sendClientCommand(tostring(module), tostring(command), args or {})
    end
end

-- ---------------------------------------------------------------------------
-- Server side
-- ---------------------------------------------------------------------------

if isServer() then

    local modules = {}   -- token -> { command -> { capability, rate, handler } }

    local rejectHooks = {}   -- token -> function(player, command, reason)

    -- Claim a wire token for the family. From this moment every command on the
    -- token is default-deny: only registered commands execute.
    --
    -- opts.onReject(player, command, reason) is OPTIONAL and lets the token
    -- owner answer a refused caller. RDNet deliberately does not invent a wire
    -- shape for that: who hears about a refusal, and in what form, is the
    -- token's business - an admin panel wants a message in its own Result
    -- contract, a telemetry channel wants nothing at all. Without a hook a
    -- rejection stays silent, which is the behaviour every existing token has
    -- today.
    --
    -- WHY IT EXISTS: a refused interactive command that answers nothing leaves
    -- its UI waiting forever, and the fairness invariant already requires a
    -- bounded refusal where that would happen. DFServer is currently the only
    -- surface in the family that does it, which is why folding DFServer into
    -- RDNet needed this first.
    function RDNet.adopt(module, opts)
        module = tostring(module)
        modules[module] = modules[module] or {}
        if opts and type(opts.onReject) == "function" then
            rejectHooks[module] = opts.onReject
        end
        return modules[module]
    end

    -- Registration is a CONFIGURATION step, so its mistakes are announced at
    -- boot rather than discovered in play. Two are caught here:
    --
    --   A duplicate (token, command) used to overwrite silently, which made the
    --   surviving handler a function of Lua file load order - the one thing the
    --   single-intake invariant exists to prevent. First registration wins and
    --   the collision is shouted; whichever file is wrong, somebody sees it.
    --
    --   A capability-less registration is a PUBLIC endpoint, because
    --   RDAccess.can(player, nil) returns true unconditionally (RDAccess.lua:62).
    --   That is a legitimate thing to want - telemetry and player-facing actions
    --   both need it - but it must be a decision rather than an omission, so it
    --   has to be spelled `public = true`. A registration with neither is the
    --   shape a forgotten gate takes, and it says so out loud.
    function RDNet.register(module, command, opts, handler)
        if type(opts) == "function" and handler == nil then
            handler, opts = opts, {}
        end
        opts = opts or {}
        module, command = tostring(module), tostring(command)

        if type(handler) ~= "function" then
            print("[RFTDCore] RDNet.register: no handler for " .. module .. "." .. command)
            return
        end

        local reg = RDNet.adopt(module)
        if reg[command] then
            print("[RFTDCore] RDNet.register: DUPLICATE registration for "
                .. module .. "." .. command
                .. " - keeping the first; load order must not pick the winner."
                .. " One of the two registering files is wrong.")
            return
        end

        if opts.capability == nil and opts.public ~= true and opts.gate == nil then
            print("[RFTDCore] RDNet.register: " .. module .. "." .. command
                .. " has no capability, and declares neither public = true nor"
                .. ' gate = "handler". RDAccess.can(player, nil) admits everyone,'
                .. " so RDNet is NOT gating this - say which it is.")
        end

        reg[command] = {
            capability = opts.capability,
            public     = opts.public == true,
            gate       = opts.gate,
            rate       = opts.rate,
            handler    = handler,
        }
    end

    -- Read-only view for tests and bounded diagnostics: token -> command ->
    -- { capability, public, rate }. Handlers are deliberately not exposed -
    -- this answers "what is registered and under what policy", not "run it".
    function RDNet.registry()
        local out = {}
        for token, cmds in pairs(modules) do
            local t = {}
            for name, c in pairs(cmds) do
                t[name] = { capability = c.capability, public = c.public,
                            gate = c.gate, rate = c.rate }
            end
            out[token] = t
        end
        return out
    end

    local function reject(module, command, player, reason)
        RDLog.forensic("rdnet", "RD.NET_REJECT", player, {
            module  = tostring(module),
            command = tostring(command),
            reason  = reason,
        }, "RFTDCore")
    end

    -- Rate refusals are deliberately NOT answered, and that asymmetry is the
    -- point: a reply is itself a packet, so answering a flood re-amplifies the
    -- exact thing the limiter is there to stop. An unknown command and a
    -- capability refusal are both single, terminal events for a caller who is
    -- probably a confused UI rather than an attacker - those get an answer if
    -- the token asked for one. Same split DFServer arrived at independently
    -- (DFServer.lua:30-34).
    local function answerRefusal(module, command, player, reason)
        local hook = rejectHooks[module]
        if hook then hook(player, command, reason) end
    end

    Events.OnClientCommand.Add(function(module, command, player, args)
        local reg = modules[module]
        if not reg then return end                    -- not a family token; Guardian still records it
        local cmd = reg[command]
        if not cmd then
            reject(module, command, player, "unregistered-command")
            answerRefusal(module, command, player, "unregistered-command")
            return
        end
        -- Scope the bucket to THIS command. By this line `module` matched a
        -- registered token and `command` a registered command, so the key is
        -- code-owned, not wire-controlled. Without the scope, every command a
        -- user sends drains one shared bucket that each command then compares
        -- against its own max - fatal to anything registered with a small
        -- rate (see RDRate.allow).
        if not RDRate.allow(player, cmd.rate, 1000, module .. "." .. command) then
            reject(module, command, player, "rate")
            return
        end
        if not RDAccess.can(player, cmd.capability) then
            reject(module, command, player, "capability")
            answerRefusal(module, command, player, "capability")
            return
        end
        -- foreign code: the handler belongs to a satellite mod; containment
        -- (RD.NET_ERROR below) is the feature
        local ok, err = pcall(cmd.handler, player, args)
        if not ok then
            RDLog.forensic("rdnet", "RD.NET_ERROR", player, {
                module  = tostring(module),
                command = tostring(command),
                err     = tostring(err),
            }, "RFTDCore")
            print("[RFTDCore] RDNet: handler error in " .. tostring(module) .. "."
                .. tostring(command) .. ": " .. tostring(err))
        end
    end)

    -- sendServerCommand (GameServer:3256) returns early for an unmapped player
    -- and a closed connection - disconnects need no guard (pcall-safe.json)
    function RDNet.reply(player, module, command, args)
        sendServerCommand(player, tostring(module), tostring(command), args or {})
    end

    function RDNet.broadcast(module, command, args)
        sendServerCommand(tostring(module), tostring(command), args or {})
    end

    -- Send to VERIFIED STAFF ONLY, one connection at a time.
    --
    -- Why this exists, and why here: "a hidden panel on a non-staff client is
    -- not confidentiality" is the family's audience rule, and the broadcast
    -- overload above walks every connection (GameServer.java:3209-3213), so
    -- anything sent through it reaches every player's Lua regardless of what
    -- their UI chooses to draw. Staff audit lines were going out that way -
    -- from Dragonfly's DFCore.audit and both of Reaper's audit paths - which
    -- put admin usernames, actions and targets on every client in the game.
    --
    -- Built now rather than earlier because it finally has consumers: those
    -- three, plus RDCmdRelay.flush, which had privately grown the identical
    -- walk. Four call sites is the promotion threshold CLAUDE.md sect. 5 sets,
    -- and RDNet is where the roles table puts recipient-aware sends.
    --
    -- isTopAdmin OR hasAnyCapability is the family's "any staff" notion:
    -- isTopAdmin alone misses capability-granted roles. A nil RDAccess means
    -- the gate cannot be evaluated, and the default is DENY - an audit line
    -- that reaches nobody is a bug, but one that reaches everybody is a leak.
    --
    -- getOnlinePlayers can answer nil before the world is up; size/get are
    -- bounds-safe, and sendServerCommand (GameServer:3256) early-returns for an
    -- unmapped player or a closed connection, so a disconnect mid-walk is the
    -- engine's no-op rather than ours to catch.
    function RDNet.sendStaff(module, command, args)
        if not RDAccess then return 0 end
        local players = getOnlinePlayers()
        if not players then return 0 end
        local sent = 0
        for i = 0, players:size() - 1 do
            local p = players:get(i)
            if p and RDAccess.isStaff(p) then
                sendServerCommand(p, tostring(module), tostring(command), args or {})
                sent = sent + 1
            end
        end
        return sent
    end

    -- Core's own token is adopted from the start; Core commands register onto
    -- it. LITERAL, not RDShared.MODULE: PZ loads shared/ files alphabetically
    -- and RDNet < RDShared, so RDShared does not exist yet when this line
    -- runs (proven by a boot-log stack trace on 2026-07-26).
    RDNet.adopt("RFTDCore")
end

return RDNet

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
