-- SPDX-License-Identifier: GPL-3.0-or-later
-- RDTripwire.lua - raises, records and relays tripwires (server only).
--
-- A tripwire is "this should not have been possible". It is not a verdict and it
-- is not a gate - by the time Lua hears about a client command the server has
-- already accepted it (RDCmdRelay's header sets out why, with the decompile line
-- numbers). A tripwire makes an impossibility VISIBLE while someone is looking,
-- and puts it in the forensic archive for when nobody was.
--
-- ===========================================================================
-- TWO SOURCES, AND THEY ARE NOT EQUALLY TRUSTWORTHY. Keeping them apart is the
-- most important thing this file does.
--
--   SERVER-OBSERVED ("impossible")
--     Guardian sees every inbound client command with the sender's real access
--     level. A command declared staff-only arriving from a non-staff account is
--     observed HERE, on our side of the wire. The client cannot suppress it,
--     cannot forge it, and does not know it happened. This is the only tier that
--     is evidence, and the only tier that flashes the deck badge.
--
--   CLIENT-REPORTED ("reported")
--     DFSendWatch and DFIntentWatch wrap client-side call sites and report what
--     they saw. This closes real blind spots - the 42.20 faction packets leave
--     no server-side Lua trace at all, so without a client-side wrapper those
--     acts are invisible to us - but a client that does not want to report
--     simply does not load the wrapper. It is telemetry for honest clients.
--     Useful for disputes, griefing and accidents; worthless against an
--     adversary, and never presented as if it were not.
--
-- The tier that would make client reports trustworthy is a Lua checksum stream
-- (does this client run the code we shipped?). That is deliberately NOT in this
-- pass. Until it lands, "reported" means reported.
-- ===========================================================================
--
-- WHAT THE ENGINE ALREADY GATES, so we do not claim credit for it: exactly one
-- client command is refused before Lua is told. GameServer.receiveClientCommand
-- returns at :2136 for vehicle:remove from a connection lacking
-- Capability.GeneralCheats, BEFORE triggerEvent at :2138. So a blocked
-- vehicle:remove never reaches Guardian and registering it here would only ever
-- match authorised ones. Every OTHER module:command passes through unfiltered -
-- which is precisely why a mod's own admin commands are the real exposure, and
-- why this registry is seeded from ours rather than from vanilla's.
--
-- A REGISTERED COMMAND IS NOT REFUSED BY REGISTERING IT. The handler still owns
-- its own access check. This records the ATTEMPT; it cannot stop one.
--
-- Called from inside RDGuardian's existing OnClientCommand handler - never its
-- own listener, for the reason Guardian's header gives at length.

if not isServer() then return end

require "RDShared"
require "RDAccess"
require "RDNet"      -- intake is REGISTERED, not listened for; see the tail of this file

RDTripwire = RDTripwire or {
    privileged = {},   -- [module][command] = true
    recent     = {},   -- [username.."|"..code] = lastMs, client-report throttle
}

local REPORT_THROTTLE_MS = 10000   -- per player per code
local RECENT_SWEEP       = 400     -- entries before the throttle map is swept
local TEXT_MAXLEN        = 300

-- ON BY DEFAULT, the family rule: the record exists before anyone thinks to ask
-- for it. The off switch is for the case where this file is the suspect, and for
-- a server under enough load that even a cheap sensor is worth questioning.
--
-- Turning it off silences BOTH tiers - the server-observed impossibilities and
-- the client-reported claims - and with them the deck badge's alert. It does not
-- silence RDGuardian, which keeps recording every client command either way.
--
-- Resolved lazily and cached: SandboxVars is not ready at file scope, and
-- RDTripwire.inspect runs per client command.
local armed = nil

local function enabled()
    if armed ~= nil then return armed end
    local v = SandboxVars and SandboxVars.RFTDCore and SandboxVars.RFTDCore.TripwireEnabled
    if v == nil then return true end   -- absent option = on, don't latch
    armed = (v == true)
    return armed
end

-- ---------------------------------------------------------------------------
-- Registry
-- ---------------------------------------------------------------------------

-- Declare a module:command as staff-only. Any non-staff sender trips a wire.
function RDTripwire.registerPrivileged(module, command)
    if type(module) ~= "string" or type(command) ~= "string" then return end
    local m = RDTripwire.privileged[module]
    if not m then m = {}; RDTripwire.privileged[module] = m end
    m[command] = true
end

-- Seeded with OUR OWN admin commands, because those are the ones the engine does
-- not gate and whose handlers we are responsible for. Other mods in the family
-- register theirs from their own server files - the registry is the extension
-- point, and a command nobody registers simply never trips a wire.
RDTripwire.registerPrivileged("RFTDDirge", "adminReroll")

-- Staff classification is RDAccess.isStaff, called directly - the promoted
-- predicate this file used to hold a copy of. Shared tier loads before server
-- tier, so RDAccess is structurally present; the require below states it.

local function usernameOf(player)
    local u = player and player:getUsername()
    return u or "?"
end

local function clip(s)
    s = tostring(s or "")
    if #s > TEXT_MAXLEN then s = string.sub(s, 1, TEXT_MAXLEN) .. "~" end
    return s
end

-- ---------------------------------------------------------------------------
-- Raise
-- ---------------------------------------------------------------------------
--
-- Every tripwire lands in the forensic archive FIRST and is broadcast second. The
-- ring is the record; the broadcast is a courtesy to whoever is online. If the
-- broadcast fails or nobody is watching, the record still exists - never the
-- other way round.

local function broadcast(payload)
    local players = getOnlinePlayers()
    if not players then return end
    -- size/get are bounds-safe in the loop; isStaff routes through RDAccess
    -- (non-throwing); sendServerCommand (GameServer:3256) early-returns for
    -- unmapped/closed connections - the record already exists either way
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        if p and RDAccess.isStaff(p) then
            sendServerCommand(p, RDShared.MODULE, "tripwire", payload)
        end
    end
end

-- severity: "impossible" (server-observed) | "reported" (client-reported)
function RDTripwire.raise(severity, code, player, text, extra)
    severity = (severity == "impossible") and "impossible" or "reported"
    code     = tostring(code or "unknown")
    text     = clip(text)

    local user   = usernameOf(player)
    local access = (player and player:getAccessLevel()) or ""

    local fields = {
        severity = severity,
        code     = code,
        access   = access,
        text     = text,
    }
    if RDIdentity then
        -- sidApprox probes for getSteamID itself and cannot throw
        fields.sid = RDIdentity.sidApprox(player) or "0"
    end
    if player then
        fields.onlineid = player:getOnlineID() or -1
        fields.x = math.floor(player:getX())
        fields.y = math.floor(player:getY())
        fields.z = math.floor(player:getZ())
    end
    if type(extra) == "table" then
        for k, v in pairs(extra) do
            if fields[k] == nil and (type(v) == "string" or type(v) == "number" or type(v) == "boolean") then
                fields[k] = v
            end
        end
    end

    -- No guard - see RDLog's totality reading in RDForage/RCAudit. The
    -- presence check stays: RDLog is Core's, but this file can load in a
    -- context where the server half has not.
    if RDLog and RDLog.forensic then
        RDLog.forensic("tripwire", "RD.TRIP", player, fields, RDShared.MODULE)
    end

    broadcast{
        sev  = severity,
        code = code,
        u    = user,
        a    = access,
        t    = text,
    }
end

-- ---------------------------------------------------------------------------
-- Server-observed: the privileged-command wire
-- ---------------------------------------------------------------------------
--
-- Called from RDGuardian's handler, which already has module, command, player
-- and access in hand. Cheap by construction: two table lookups on the miss path,
-- which is every command that is not registered - i.e. essentially all of them.

function RDTripwire.inspect(module, command, player, access)
    -- Registry lookup FIRST: it is two table reads and it misses for essentially
    -- every command, so the disarm check - which is a cached boolean but still a
    -- function call - is not worth paying on the firehose path.
    local m = RDTripwire.privileged[module]
    if not m or not m[command] then return end
    if not enabled() then return end
    if RDAccess.isStaff(player) then return end

    RDTripwire.raise("impossible", "privilegedCommand", player,
        tostring(module) .. ":" .. tostring(command)
            .. " sent by an account with no staff capability",
        { module = tostring(module), command = tostring(command) })
end

-- ---------------------------------------------------------------------------
-- Client-reported intake
-- ---------------------------------------------------------------------------
--
-- THROTTLED PER PLAYER PER CODE, because an unbounded intake that fans out to
-- every staff console is an amplifier: one broken or hostile client turns into N
-- packets per staff member per report. The throttle is the whole defence, so it
-- runs BEFORE the forensic write as well - a dropped report costs one line in a
-- ring that is already sampling, and a ring flooded by one client loses the
-- records that mattered.
--
-- CORROBORATED WHERE WE CAN. A client claiming "I opened the admin panel without
-- access" is making a statement about ITS OWN access level, and the server holds
-- the authoritative copy. When the reporter is in fact staff the claim is stale
-- or fabricated, and it is dropped rather than recorded - a tripwire log full of
-- admins tripping over their own permissions trains people to ignore it.

local recentCount = 0

local function throttled(user, code)
    local key = user .. "|" .. code
    local now = RDShared.nowMs()
    if now == 0 then return false end

    local last = RDTripwire.recent[key]
    if last and (now - last) < REPORT_THROTTLE_MS then return true end

    if recentCount > RECENT_SWEEP then
        RDTripwire.recent = {}
        recentCount = 0
    end
    RDTripwire.recent[key] = now
    recentCount = recentCount + 1
    return false
end

function RDTripwire.receiveReport(player, args)
    if type(args) ~= "table" then return end
    local code = tostring(args.code or "")
    local text = clip(args.text)
    if code == "" or text == "" then return end

    local user = usernameOf(player)
    if throttled(user, code) then return end

    -- A claim of "without accesslevel" made by an account that HAS the access
    -- level is not evidence of anything; drop it rather than record noise.
    if args.claimsUnauthorised and RDAccess.isStaff(player) then return end

    RDTripwire.raise("reported", code, player, text, { channel = tostring(args.channel or "") })
end

-- Lifecycle telemetry that is not a tripwire at all - faction and safehouse acts
-- that 42.20 moved onto INetworkPacket, where no server-side Lua hook exists.
-- Recorded in the forensic archive on its own stream, not broadcast and never
-- flashed: it is a ledger, not an alarm.
function RDTripwire.receiveLifecycle(player, args)
    if type(args) ~= "table" then return end
    local text = clip(args.text)
    if text == "" then return end

    local user = usernameOf(player)
    if throttled(user, "lifecycle") then return end

    if RDLog and RDLog.forensic then
        -- Bare: RDLog is our own module and its forensic path is total for a
        -- scalar payload (buffered push, nil-safe writer, internally-bounded
        -- tally); getAccessLevel's faults arrive as nil (exposed method,
        -- MethodCaller.java:33-56) and the `or ""` carries them. A real fault
        -- here would be our bug and should be loud.
        RDLog.forensic("lifecycle", "RD.LIFE", player, {
            act    = tostring(args.act or "?"),
            text   = text,
            access = (player and player:getAccessLevel()) or "",
        }, RDShared.MODULE)
    end
end

-- ---------------------------------------------------------------------------
-- Intake, through RDNet - the RFTDCore token's ONE executable listener.
--
-- This file used to add its own OnClientCommand listener here, which made a
-- SECOND executable intake on a token RDNet had already adopted
-- (RDNet.lua:294, at file scope, which puts the token in default-deny). Neither
-- command was ever RDNet-REGISTERED, so every report arriving from
-- DFIntentWatch/DFSendWatch was written to the forensic archive as an
-- RD.NET_REJECT and then executed anyway by the listener below it.
--
-- The 2026-08-18 live capture priced that: 95 lifecycle reports, 95 matching
-- false rejects, 86% of the entire rdnet stream. The one record an operator
-- would search for intrusion was filling up with rejections of legitimate,
-- handled traffic. Registering here is what makes that stream mean what it
-- says - and this file's own header already stated the rule ("never its own
-- listener") for the Guardian pathway, so the listener was out of step with
-- the design it was written beside.
--
-- capability = nil is deliberate and load-bearing. Both commands are telemetry
-- from ORDINARY clients; a capability gate would silence exactly the reporters
-- they exist to hear from. RDAccess.can(player, nil) returns true
-- unconditionally (RDAccess.lua:62), so these are public endpoints and are
-- meant to be. That is a declared entry on the intended-open set, not an
-- oversight.
--
-- rate is the anti-flood layer ONLY. Per-code throttling is stricter and lives
-- in throttled() - 10s per player per code - but a flood of DISTINCT codes
-- passes that untouched, so RDNet's per-command bucket is what bounds it. One
-- constant for both because the cadence is genuinely the same: low-rate,
-- human-driven client wrappers (measured 1.2/h across 31 senders). 10/s sits
-- far above any hand at a keyboard and far below a script.
--
-- enabled() stays here rather than moving into the receive functions: it is
-- this file's operator switch, not RDNet's. Turning the sensor off must stop
-- intake WITHOUT unregistering the commands, so the rejection stream keeps
-- telling the truth about what arrived while the sensor was dark.
--
-- No guard on the receive calls. They are the tail of the handler, and RDNet
-- already isolates handler faults into RD.NET_ERROR (RDNet.lua:124) - a
-- strictly better boundary than the engine's per-listener try/catch this
-- replaced, because a fault now lands in the archive instead of only the log.
-- ---------------------------------------------------------------------------
local INTAKE_RATE = 10

RDNet.register(RDShared.MODULE, "tripwireReport", { public = true, rate = INTAKE_RATE }, function(player, args)
    if not enabled() then return end
    RDTripwire.receiveReport(player, args)
end)

RDNet.register(RDShared.MODULE, "lifecycleReport", { public = true, rate = INTAKE_RATE }, function(player, args)
    if not enabled() then return end
    RDTripwire.receiveLifecycle(player, args)
end)

return RDTripwire

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
