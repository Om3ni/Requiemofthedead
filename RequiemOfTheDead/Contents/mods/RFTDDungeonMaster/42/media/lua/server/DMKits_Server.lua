-- SPDX-License-Identifier: GPL-3.0-or-later
-- DMKits_Server - the wire surface for kits (server only).
--
-- No domain logic. This file checks the SHAPE of a payload, decides who may ask,
-- calls DMKits and DMGrant, and answers. Every rule about what a kit is lives in
-- DMKitDefs; every rule about who has claimed what lives in DMKits. If a
-- decision is being made here that a fixture for one of those could have made
-- instead, it is in the wrong file.
--
-- ---------------------------------------------------------------------------
-- THE INVARIANT THIS FILE EXISTS TO HOLD: the player supplies EVENTS, the DM
-- supplies DEFINITIONS.
--
-- A client may say "I claim delvers_reward". It may never say what
-- delvers_reward contains, what it requires, or what it rolled. So `kitClaim`
-- takes ONE field - an id - and re-derives everything: entitlement, once-ness,
-- the draw, and every grant. A payload carrying a grant list is not partially
-- honoured, it is ignored, because the handler never looks at anything but the
-- id. That is a property of the code rather than a validation step, which is
-- the only kind of guarantee worth having here.
--
-- ---------------------------------------------------------------------------
-- WHY RDNET AND NOT DFServer. Dragonfly's dispatcher is Dragonfly's, and this
-- mod requires only Core (see mod.info). RDNet is the family channel a new mod
-- adopts, one token with one intake, and unlike DFServer it can express "staff,
-- any capability at all" natively - RDAccess.can treats the literal "any" as
-- hasAnyCapability (RDAccess.lua:80-84). So every gate here is DECLARED and the
-- dispatcher enforces it; nothing self-gates, and no refusal is logged as an
-- accepted command.
--
-- ---------------------------------------------------------------------------
-- WHAT A PLAYER IS ALLOWED TO LEARN, which is a smaller thing than what an
-- admin sees. DMKits.entitlement's refusal names the missing flag and the
-- counter shortfall, because an admin debugging "why can't they claim it" needs
-- exactly that. Sent to a player it is a readout of the requirement list of
-- every kit they have not earned - so `kitMine` sends only what they CAN claim,
-- and `kitClaim` answers a failed entitlement with a flat refusal. The detailed
-- reason goes to the forensic stream, where staff can read it.

if not isServer() then return end

require "RDShared"
require "RDNet"
require "RDLog"
require "RDVars"
require "DMKitDefs"
require "DMKits"
require "DMGrant"

DMKits_Server = DMKits_Server or {}

local TOKEN = "RFTDDungeonMaster"

-- A username arriving off the wire becomes a table key in a persisted store.
-- RDVars and DMKits both accept a bare string on purpose - an admin has to be
-- able to act on somebody who is offline - so the bound lives at this door.
-- Same value and same reasoning as DFVars_Server.
local USER_MAX = 64

-- Core's. Server-only file, so no presence guard is needed here - RDLog is
-- required above and the channel carries its own anyway.
local forensic = RDLog.channel("kits", TOKEN)

local function reply(player, command, args)
    RDNet.reply(player, TOKEN, command, args or {})
end

-- EVERY KitResult NAMES THE COMMAND IT ANSWERS, success or refusal.
--
-- Refusals already did, through the onReject hook. Successes did not, and that
-- asymmetry stopped being survivable the moment a second client surface
-- appeared: one client is BOTH the authoring tab and a player with a Kits
-- window, both are answered on this one envelope, and without the command each
-- would have to guess whether the reply was theirs. Two surfaces rendering the
-- same "Saved" is the benign version; the bad one is the claim window showing
-- an admin's delete confirmation as what the player just received.
--
-- Passed explicitly per call site rather than captured from the registration,
-- because RDNet hands a handler its player and args and not its own name -
-- and a wrapper that closed over the name would be a second registration API.
local function ok(player, command, message, extra)
    local args = extra or {}
    args.ok = true
    args.command = command
    args.message = message
    reply(player, "KitResult", args)
end

local function refuse(player, command, reason, extra)
    local args = extra or {}
    args.ok = false
    args.command = command
    args.reason = reason
    reply(player, "KitResult", args)
end

-- A kit id off the wire. Normalized through the same function the store uses,
-- so "Reward" and "reward" cannot address different kits depending on which
-- door they came through.
local function wireId(args)
    local raw = args and args.id
    if type(raw) ~= "string" then return nil, "no kit id" end
    return DMKitDefs.normalizeId(raw)
end

local function wireUser(args)
    local raw = args and args.username
    if type(raw) ~= "string" or raw == "" then return nil, "no player named" end
    if #raw > USER_MAX then
        return nil, "that username is longer than " .. USER_MAX .. " characters"
    end
    return raw
end

-- ---------------------------------------------------------------------------
-- Registration
--
-- Deferred to OnServerStarted rather than run at file scope, because DMKits
-- resolves its store on first use and the store's boot must land after the
-- world exists. Registering early would be harmless on its own; doing the work
-- early is not.
-- ---------------------------------------------------------------------------

Events.OnServerStarted.Add(function()

    RDNet.adopt(TOKEN, {
        -- A refused caller gets the same envelope a failed one does, so the
        -- panel has a single reply shape to render. RDNet does not answer rate
        -- refusals at all - replying to a flood re-amplifies it - which is why
        -- a client must not treat silence as success.
        onReject = function(player, command, reason)
            refuse(player, command, "refused: " .. tostring(reason))
        end,
    })

    -- ---- staff reads ------------------------------------------------------

    -- The whole catalogue, for the authoring tab. "any" is the honest gate:
    -- reading what kits exist is not the same authority as writing one, and no
    -- single named capability means "is this person staff".
    RDNet.register(TOKEN, "kitList", { capability = "any", rate = 4 },
        function(player)
            local out = {}
            for _, def in ipairs(DMKits.definitions()) do
                out[#out + 1] = def
            end
            -- Definitions ride WHOLE to this surface - weights included - so
            -- the authoring tab projects its own view without a second round
            -- trip. Only the claim panel gets a filtered projection, and that
            -- filtering happens server-side where a client cannot undo it.
            reply(player, "KitList", { kits = out, totals = DMKits.claimTotals() })
        end)

    -- CLEAR ONE PLAYER'S CLAIM. The lost-packet fix: a claim is recorded
    -- before the grants run, so a delivery that dies leaves a player charged
    -- for nothing and, on a once-ever kit, locked out for good.
    --
    -- ITS OWN COMMAND, never kitForget with an optional user. The two acts
    -- differ by the whole roster, and a `user` that failed to serialise would
    -- silently turn "give Kriegan his axe back" into "re-open this for
    -- everybody". Here a missing user is a refusal.
    --
    -- SandboxOptions, matching the other verb that edits the claim record: it
    -- hands somebody a second go at a one-time reward, which is authoring
    -- authority rather than the item-handling authority kitGrantTo needs.
    RDNet.register(TOKEN, "kitForgetOne",
        { capability = Capability.SandboxOptions, rate = 4 },
        function(player, args)
            local id, why = wireId(args)
            if not id then return refuse(player, "kitForgetOne", why) end
            local who = args and args.user
            if type(who) ~= "string" or who == "" then
                return refuse(player, "kitForgetOne",
                    "name the player whose claim should be cleared")
            end
            -- NOT named `ok`: that is the reply helper at the top of this
            -- file, and shadowing it here would make every success below a
            -- call on a boolean.
            local done, had = DMKits.forgetClaim(who, id)
            if not done then return refuse(player, "kitForgetOne", tostring(had)) end
            forensic("DM.KIT_CLAIM_CLEARED", player,
                     { id = id, user = who, had = had and true or false })
            -- "Nothing to clear" is reported as what it is. Calling it a
            -- success hides a mistyped name behind a reassuring message.
            if not had then
                return ok(player, "kitForgetOne",
                           who .. " had no claim on '" .. id .. "' to clear.",
                           { id = id, cleared = 0 })
            end
            return ok(player, "kitForgetOne",
                       "Cleared " .. who .. "'s claim on '" .. id .. "'.",
                       { id = id, cleared = 1 })
        end)

    -- WHO TOOK WHAT, WHEN. Staff-read, like the rest of this group: it names
    -- players and what they were handed, which is not a player-facing fact.
    -- The window is bounded by the store (DMKits.LOG_MAX); `limit` only
    -- narrows it further, and a caller asking for more gets the cap.
    RDNet.register(TOKEN, "kitLog", { capability = "any", rate = 4 },
        function(player, args)
            local n = tonumber(args and args.limit)
            reply(player, "KitLog", { rows = DMKits.log(n) })
        end)

    RDNet.register(TOKEN, "kitClaimants", { capability = "any", rate = 4 },
        function(player, args)
            local id, why = wireId(args)
            if not id then return refuse(player, "kitClaimants", why) end
            local rows = DMKits.claimants(id)
            reply(player, "KitClaimants", { id = id, rows = rows or {} })
        end)

    -- ---- authoring --------------------------------------------------------
    --
    -- SandboxOptions rather than ChangeAndReloadServerOptions: a kit is
    -- server-wide authored content, which is the same shape of authority as a
    -- sandbox page, and the strictest capability available is not the same as
    -- the fitting one. (The suite's standing question about an operator-set
    -- tier instead of a fixed capability is filed in TODO.md and applies here
    -- too.)

    RDNet.register(TOKEN, "kitDefine", { capability = Capability.SandboxOptions,
        rate = 4 }, function(player, args)
        local raw = args and args.kit
        if type(raw) ~= "table" then
            return refuse(player, "kitDefine", "no kit definition was sent")
        end
        local def, why = DMKits.define(raw, RDShared.username(player))
        if not def then
            forensic("DM.KIT_DEFINE_REFUSED", player, { reason = why })
            return refuse(player, "kitDefine", why)
        end
        forensic("DM.KIT_DEFINED", player, { id = def.id, kind = def.kind,
            rev = def.rev })
        ok(player, "kitDefine", "Saved '" .. def.label .. "'.", { id = def.id })
        RDNet.sendStaff(TOKEN, "KitsStale", {})
    end)

    RDNet.register(TOKEN, "kitDelete", { capability = Capability.SandboxOptions,
        rate = 4 }, function(player, args)
        local id, why = wireId(args)
        if not id then return refuse(player, "kitDelete", why) end
        local done, reason = DMKits.undefine(id)
        if not done then return refuse(player, "kitDelete", reason) end
        forensic("DM.KIT_DELETED", player, { id = id })
        -- Says what it did NOT do, because "deleting a kit clears its claims"
        -- is the reasonable assumption and it is wrong - claims survive so a
        -- one-time reward cannot be re-opened by deleting and retyping it.
        ok(player, "kitDelete", "Deleted '" .. id .. "'. Claims are kept; use Re-open to "
            .. "clear them.", { id = id })
        RDNet.sendStaff(TOKEN, "KitsStale", {})
    end)

    -- Re-opening a kit is the most destructive verb here and the only one whose
    -- effect is invisible afterwards: everyone who already took a one-time
    -- reward can take it again and nothing on screen says so. Hence its own
    -- command rather than a flag on delete, and a count in the answer.
    RDNet.register(TOKEN, "kitForget", { capability = Capability.SandboxOptions,
        rate = 2 }, function(player, args)
        local id, why = wireId(args)
        if not id then return refuse(player, "kitForget", why) end
        local cleared, reason = DMKits.forgetClaims(id)
        if not cleared then return refuse(player, "kitForget", reason) end
        forensic("DM.KIT_REOPENED", player, { id = id, cleared = cleared })
        ok(player, "kitForget",
            "Re-opened '" .. id .. "' for " .. cleared .. " player(s).",
            { id = id, cleared = cleared })
        RDNet.sendStaff(TOKEN, "KitsStale", {})
    end)

    -- ---- an admin hands a kit over ----------------------------------------
    --
    -- Capability.AddItem is the engine's own gate for putting things in
    -- somebody's inventory, and what Dragonfly already uses for the same act
    -- (DFInventory_Server.lua:457). A kit can also move a counter and add a
    -- trait, but the item path is the one with a named engine capability and
    -- the one an operator recognises.
    --
    -- Entitlement is NOT checked. That is the point of a staff grant: the DM is
    -- the authority the requirements were standing in for. `once` is still
    -- honoured, because re-granting a one-time reward is almost always a
    -- mis-click and the DM can Re-open deliberately if it is not.
    RDNet.register(TOKEN, "kitGrantTo", { capability = Capability.AddItem,
        rate = 4 }, function(player, args)
        local id, why = wireId(args)
        if not id then return refuse(player, "kitGrantTo", why) end
        local username, userWhy = wireUser(args)
        if not username then return refuse(player, "kitGrantTo", userWhy) end

        local def = DMKits.definition(id)
        if not def then
            return refuse(player, "kitGrantTo", "no kit called '" .. id .. "'")
        end

        -- THE WAIT BINDS A STAFF GRANT TOO. Handing somebody a kit they are
        -- still cooling down on is almost always a mis-click, and the two
        -- deliberate ways to do it - Re-open for everyone, Clear claim for one
        -- person - both exist and both say what they are.
        local waiting = DMKits.cooldownLeft(username, id)
        if waiting and waiting > 0 then
            return refuse(player, "kitGrantTo", username .. " claimed '"
                .. def.label .. "' too recently (" .. DMKitDefs.claimText(def)
                .. ") - use Clear claim, or Re-open, if that is deliberate")
        end

        local target = DMKits_Server.findOnline(username)
        if not target then
            return refuse(player, "kitGrantTo", username .. " is not online - a kit needs a "
                .. "live character to receive it")
        end

        DMKits_Server.deliver(target, def, RDShared.username(player), player)
    end)

    -- ---- the player's own two verbs ---------------------------------------
    --
    -- public = true, declared rather than omitted. RDNet shouts at a
    -- registration with no capability and no declaration precisely so an open
    -- endpoint cannot be created by forgetting, and both of these are open ON
    -- PURPOSE: a player must be able to see and take what they have earned.
    -- The authority is not in the gate, it is in what the handler will read
    -- from the payload - an id, and nothing else.

    RDNet.register(TOKEN, "kitMine", { public = true, rate = 2 },
        function(player)
            local user = RDShared.username(player)
            if not user then return end
            local out = {}
            for _, def in ipairs(DMKits.definitions()) do
                -- A COOLING KIT STAYS ON THE LIST. Everything else about
                -- entitlement is a gate the player may not know exists, and
                -- silence is the rule for those. A cooldown is different: they
                -- have already earned this and are only waiting, so a kit that
                -- vanished after being claimed and reappeared hours later with
                -- no explanation would read as a bug (owner, 2026-08-24).
                -- `allowed`, not `ok`: that name belongs to the reply helper
                -- at the top of this file, and a local shadowing it here would
                -- turn the first success reply somebody adds to this handler
                -- into a call on a boolean.
                local allowed = DMKits.entitlement(user, def.id)
                local left = DMKits.cooldownLeft(user, def.id) or 0
                if allowed or left > 0 then
                    -- Only what they may claim, and only what they need to
                    -- decide: no requirement list, because sending one is a
                    -- readout of every gate on every kit they have not earned.
                    out[#out + 1] = {
                        id = def.id, kind = def.kind, label = def.label,
                        note = def.note,
                        -- The policy in words, built server-side so the two
                        -- surfaces cannot phrase the same wait differently.
                        claimText = DMKitDefs.claimText(def),
                        taken = DMKits.claimCount(user, def.id),
                        -- Milliseconds, and a DURATION rather than a deadline:
                        -- the client's wall clock is not this machine's, so it
                        -- anchors the countdown to its own on receipt. Same
                        -- reasoning as the vars mirror.
                        readyInMs = (left > 0) and left or nil,
                        -- WITHOUT ODDS, and the false is the whole rule
                        -- (owner, 2026-08-23). A player sees every outcome a
                        -- kit can produce; how the table is weighted is the
                        -- DM's dial and stays on the admin surface. Filtered
                        -- HERE, not on the client, so it is not a display
                        -- choice a client can decline to make.
                        contents = DMKitDefs.contents(def, false),
                    }
                end
            end
            reply(player, "KitMine", { kits = out })
        end)

    -- THE one submission a player makes. It carries an id. Everything else -
    -- may they have it, have they had it, what does it contain, what did it
    -- roll - is decided here, from the catalogue, every time.
    RDNet.register(TOKEN, "kitClaim", { public = true, rate = 1 },
        function(player, args)
            local user = RDShared.username(player)
            if not user then return end

            local id, why = wireId(args)
            if not id then return refuse(player, "kitClaim", why) end

            local def = DMKits.definition(id)
            -- An unknown id and an unearned kit get the SAME answer. Telling
            -- the difference apart tells a player which ids exist, which is the
            -- catalogue leaking one guess at a time.
            local allowed, detail, cooling = DMKits.entitlement(user, id)
            if not def or not allowed then
                forensic("DM.KIT_CLAIM_REFUSED", player,
                    { id = id, reason = detail or "no such kit" })
                -- A COOLDOWN IS THE ONE REFUSAL WORTH EXPLAINING. The flat
                -- answer above exists so a player cannot map the catalogue by
                -- guessing ids - but a cooling kit is already ON their list,
                -- so the wait is not a fact they could learn any other way,
                -- and hiding it makes a working feature look broken.
                if cooling and cooling > 0 then
                    return refuse(player, "kitClaim",
                        "Not ready yet - about " .. math.ceil(cooling / 60000)
                        .. " more minute(s).", { id = id, readyInMs = cooling })
                end
                return refuse(player, "kitClaim",
                    "That kit is not available to you.")
            end

            DMKits_Server.deliver(player, def, nil, player)
        end)

    print("[RFTDDungeonMaster] kits: 9 commands registered on " .. TOKEN)
end)

-- ---------------------------------------------------------------------------
-- Delivery, shared by the admin grant and the player claim
--
-- One path, because a kit handed over by an admin and one taken by a player
-- must land identically - two paths is two chances for the ledger and the
-- grants to disagree about what happened.
-- ---------------------------------------------------------------------------

function DMKits_Server.findOnline(username)
    local players = getOnlinePlayers()
    if not players then return nil end
    -- size/get, not ipairs: this is a Java collection and Kahlua cannot iterate
    -- one (CLAUDE.md sect. 3).
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        if p and RDShared.username(p) == username then return p end
    end
    return nil
end

-- `by` is the admin responsible, or nil for a self-claim. `tell` is who gets
-- the answer - the admin for a grant, the player for a claim.
function DMKits_Server.deliver(target, def, by, tell)
    local user = RDShared.username(target)
    -- Which command this answers, derived from the one thing that already
    -- distinguishes the two callers: `by` is the responsible admin on a staff
    -- grant and nil on a self-claim. The two answers land on different client
    -- surfaces - the authoring tab and the player's Kits window - so getting
    -- this wrong shows an admin's grant confirmation to the player as what
    -- they just claimed.
    local command = by and "kitGrantTo" or "kitClaim"

    local report, why = DMGrant.apply(target, def.grants, by)
    if not report then
        forensic("DM.KIT_GRANT_FAILED", tell, { id = def.id, user = user,
            reason = why })
        return refuse(tell, command, why)
    end

    -- Record only if something actually landed. Recording first would mark a
    -- one-time kit spent even when every grant failed; not recording a PARTIAL
    -- claim would let it be taken again for a second copy of the half that
    -- worked. Anything landing is the line between those two.
    if DMGrant.anyLanded(report) then
        DMKits.recordClaim(user, def.id, report.rolls, by)

        -- Flags that declared themselves spent by this kit. Declared on the
        -- VAR, never on the kit - see DMKits' header - so this is the only
        -- place that knows both halves, and it runs AFTER the claim is
        -- recorded: a revoke that fired first would remove the very flag the
        -- entitlement check just passed on, and a retry would then be refused
        -- for a reason that was true only because of the first attempt.
        for _, flagKey in ipairs(DMKits.consumedBy(def.id)) do
            RDVars.revoke(user, flagKey, "kit:" .. def.id)
        end
    end

    -- The log line was written when the claim was recorded; what landed is only
    -- known now. Kept as two steps on purpose - a delivery that faults must
    -- still leave the claim on the books, and it does.
    DMKits.attachDelivery(user, def.id, RDShared.textSafe(DMGrant.summary(report)))

    forensic("DM.KIT_CLAIMED", tell, {
        id      = def.id,
        kind    = def.kind,
        user    = user,
        by      = by,
        landed  = #report.landed,
        failed  = #report.failed,
        summary = RDShared.textSafe(DMGrant.summary(report)),
    })

    if #report.failed > 0 then
        -- Reported as a success that says what is missing, not as a failure:
        -- the player is holding what landed, and calling it a failure invites
        -- an admin to hand it over a second time.
        return ok(tell, command, DMGrant.summary(report),
                  { id = def.id, partial = true })
    end
    return ok(tell, command, DMGrant.summary(report), { id = def.id })
end

return DMKits_Server

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
