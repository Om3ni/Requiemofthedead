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
        pcall(function() sendClientCommand(tostring(module), tostring(command), args or {}) end)
    end
end

-- ---------------------------------------------------------------------------
-- Server side
-- ---------------------------------------------------------------------------

if isServer() then

    local modules = {}   -- token -> { command -> { capability, rate, handler } }

    -- Claim a wire token for the family. From this moment every command on the
    -- token is default-deny: only registered commands execute.
    function RDNet.adopt(module)
        module = tostring(module)
        modules[module] = modules[module] or {}
        return modules[module]
    end

    function RDNet.register(module, command, opts, handler)
        if type(opts) == "function" and handler == nil then
            handler, opts = opts, {}
        end
        if type(handler) ~= "function" then
            print("[RFTDCore] RDNet.register: no handler for " .. tostring(module) .. "." .. tostring(command))
            return
        end
        local reg = RDNet.adopt(module)
        reg[tostring(command)] = {
            capability = (opts or {}).capability,
            rate       = (opts or {}).rate,
            handler    = handler,
        }
    end

    local function reject(module, command, player, reason)
        RDLog.forensic("rdnet", "RD.NET_REJECT", player, {
            module  = tostring(module),
            command = tostring(command),
            reason  = reason,
        })
    end

    Events.OnClientCommand.Add(function(module, command, player, args)
        local reg = modules[module]
        if not reg then return end                    -- not a family token; Guardian still records it
        local cmd = reg[command]
        if not cmd then
            reject(module, command, player, "unregistered-command")
            return
        end
        if not RDRate.allow(player, cmd.rate, 1000) then
            reject(module, command, player, "rate")
            return
        end
        if not RDAccess.can(player, cmd.capability) then
            reject(module, command, player, "capability")
            return
        end
        local ok, err = pcall(cmd.handler, player, args)
        if not ok then
            RDLog.forensic("rdnet", "RD.NET_ERROR", player, {
                module  = tostring(module),
                command = tostring(command),
                err     = tostring(err),
            })
            print("[RFTDCore] RDNet: handler error in " .. tostring(module) .. "."
                .. tostring(command) .. ": " .. tostring(err))
        end
    end)

    function RDNet.reply(player, module, command, args)
        pcall(function() sendServerCommand(player, tostring(module), tostring(command), args or {}) end)
    end

    function RDNet.broadcast(module, command, args)
        pcall(function() sendServerCommand(tostring(module), tostring(command), args or {}) end)
    end

    -- Core's own token is adopted from the start; Core commands register onto
    -- it. LITERAL, not RDShared.MODULE: PZ loads shared/ files alphabetically
    -- and RDNet < RDShared, so RDShared does not exist yet when this line
    -- runs (proven by a boot-log stack trace on 2026-07-26).
    RDNet.adopt("RFTDCore")
end

return RDNet
