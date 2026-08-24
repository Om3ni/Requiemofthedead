-- SPDX-License-Identifier: GPL-3.0-or-later
-- DMGrant - turning a validated kit into effects on a live character (server).
--
-- Five kinds, five engine surfaces, no two of which fail the same way. This
-- file is where a kit stops being data. It knows nothing about entitlement, the
-- ledger, or who asked - DMKits owns those - and it never decides WHETHER a kit
-- should be handed over, only what happens when it is.
--
-- ---------------------------------------------------------------------------
-- IT REPORTS, IT DOES NOT ROLL BACK.
--
-- There is no transaction here and pretending otherwise would be worse than
-- admitting it. XP cannot be un-added cleanly once the player has gained more;
-- an item cannot be un-given once they have moved or dropped it; a trait
-- removed to "undo" a partial claim is indistinguishable from a bug. So every
-- grant is attempted, every outcome is recorded, and the caller gets a report
-- naming exactly what landed and what did not.
--
-- The caller's rule, which is DMKits' to enforce: record the claim if ANYTHING
-- landed. Not recording a partial claim lets a one-time kit be taken again for
-- a second copy of the half that worked, which is a worse failure than a player
-- who got most of a reward and an admin who can see precisely which piece was
-- missing.
--
-- Everything failing here is supposed to be impossible: DMKits refuses a kit at
-- SAVE time whose items, traits or skills do not resolve. A failure at claim
-- time therefore means the world changed underneath the catalogue - a mod that
-- shipped an item was removed, a trait was renamed - and that is exactly the
-- event an admin needs told about rather than smoothed over.
--
-- ---------------------------------------------------------------------------
-- THE ENGINE SURFACES, each read this session
--
-- ITEM. inv:AddItem(fullType) returns nil rather than throwing for an
-- unfindable type, an obsolete script, or a factory failure
-- (ItemContainer.java:511-520) - so the nil test IS the contract and there is
-- nothing here for a pcall to catch. The new item must then be replicated with
-- sendAddItemToContainer or the owning client never sees it; both that and
-- transmitModData null-guard every branch and route through INetworkPacket.send
-- (GameServer.java:2220), so no guard is needed on non-nil arguments. Dragonfly
-- reached the same two conclusions independently at DFInventory_Server.lua:193.
--
-- TRAIT. chr:getCharacterTraits():add(trait) - CharacterTraits.java:82-84, the
-- class exposed at LuaManager.java:1783. NOT applyTraits(): that one rebuilds
-- the entire XP-boost map and re-runs LevelPerk in a loop from only the traits
-- handed to it (IsoGameCharacter.java:10399-10446), which is right for
-- character creation and would wreck a live character's progression.
--
-- XP. p:getXp():AddXP(perk, amount, false, false, false, false) followed by
-- p:getNetworkCharacterAI():updateXpChecker(), which is the replication
-- trigger. Fitness and Strength additionally need their CharacterStat pushed,
-- because a perk level and the stat that mirrors it are stored separately. All
-- three steps are lifted from the engine's own /addxp command
-- (AddXPCommand.java:66-71) rather than guessed at.
--
-- THE PLAYER MUST BE ONLINE, and that is the engine's rule, not a convenience.
-- AddXPCommand does its work only inside `if c != nil` where c is the player's
-- UdpConnection (:65) - there is no server-side path that gives XP to someone
-- who is not connected. An absent player also has no inventory to add to. So a
-- grant to an offline player is REFUSED whole, with a reason, rather than
-- half-applied and silently short.
--
-- ---------------------------------------------------------------------------
-- THE ROLL IS SERVER-SIDE AND RECORDED.
--
-- ZombRand is the source (LuaManager.java:5780-5789, forwarding to
-- RandLua.Next), passed into DMRoll rather than called from inside it so every
-- outcome stays pinnable in a fixture. The drawn branch indices go back to the
-- caller to be stored, because "what did I actually get" must be answerable
-- afterwards - and because a client that decides where the wheel stops is a
-- client that decided its own reward.

if not isServer() then return end

require "RDShared"
require "RDVars"
require "DMKitDefs"
require "DMRoll"
require "DMRegistry"

DMGrant = DMGrant or {}

-- The random source, injectable for fixtures. Production is ZombRand, whose
-- contract - an integer in [0, n) - is what DMRoll validates against.
DMGrant.rand = function(n) return ZombRand(n) end

-- ---------------------------------------------------------------------------
-- One grant at a time. Each returns (true, description) or (nil, reason); the
-- description is what an admin log and a player's "you received" line read.
-- ---------------------------------------------------------------------------

local appliers = {}

appliers[DMKitDefs.ITEM] = function(player, g)
    local inv = player:getInventory()
    if not inv then return nil, "the player has no inventory" end

    local added = 0
    for _ = 1, (g.count or 1) do
        local item = inv:AddItem(g.type)
        -- The nil test is the contract - see the header. There is no throw
        -- path here to guard, and a guard would only hide which unit failed.
        if item then
            added = added + 1
            sendAddItemToContainer(inv, item)
        end
    end

    if added == 0 then
        return nil, "could not create '" .. g.type .. "' - the item script is "
            .. "gone since this kit was saved"
    end
    -- A partial add is reported as a success that says how short it fell, not
    -- as a failure: the player is holding the ones that worked.
    if added < (g.count or 1) then
        return true, added .. " x " .. g.type .. " (of " .. g.count .. " - the "
            .. "rest could not be created)"
    end
    return true, added .. " x " .. g.type
end

appliers[DMKitDefs.FLAG] = function(player, g, by)
    local ok, why = RDVars.grant(player, g.name, by)
    if not ok then return nil, why end
    return true, "flag '" .. g.name .. "'"
end

appliers[DMKitDefs.COUNTER] = function(player, g)
    if g.add ~= nil then
        local value, why = RDVars.add(player, g.name, g.add)
        if not value then return nil, why end
        return true, g.name .. " " .. (g.add >= 0 and "+" or "") .. g.add
            .. " (now " .. tostring(value) .. ")"
    end
    local ok, why = RDVars.set(player, g.name, g.set)
    if not ok then return nil, why end
    return true, g.name .. " set to " .. tostring(g.set)
end

appliers[DMKitDefs.TRAIT] = function(player, g)
    local trait, why = DMRegistry.trait(g.id)
    if not trait then return nil, why end

    local traits = player:getCharacterTraits()
    if not traits then return nil, "the player has no trait list" end

    -- Already holding it is not a failure - a repeatable kit granting the same
    -- trait twice is a no-op, and reporting it as an error would send an admin
    -- looking for a fault that is not there.
    if traits:get(trait) then
        return true, "trait '" .. g.id .. "' (already held)"
    end

    -- add(), never applyTraits(). See the header.
    traits:add(trait)
    return true, "trait '" .. g.id .. "'"
end

appliers[DMKitDefs.XP] = function(player, g)
    local perk, why = DMRegistry.perk(g.perk)
    if not perk then return nil, why end

    local xp = player:getXp()
    if not xp then return nil, "the player has no XP record" end

    -- The six-argument overload is
    -- AddXP(perk, amount, callLua, doXPBoost, remote, haloText)
    -- (IsoGameCharacter.java:15482), and all four flags are the engine's own
    -- choice at AddXPCommand.java:66 rather than a guess:
    --
    --   callLua   false - the kit is already announcing itself through its own
    --                     report; firing the XP hooks as well would have other
    --                     mods react to a reward as though it were earned play.
    --   doXPBoost false - THE ONE THAT MATTERS. True applies the character's
    --                     trait XP boosts, so an authored "200" would silently
    --                     become 200 x whatever that player happens to carry,
    --                     and two players claiming one kit would get different
    --                     amounts. An authored number means that number.
    --                     /addxp only sets it when an admin passes -true.
    --   remote    false - this IS the authoritative side.
    --   haloText  false - the floating number is for XP the player earned.
    xp:AddXP(perk, g.amount, false, false, false, false)

    -- A perk level and the stat mirroring it are stored apart, so Fitness and
    -- Strength need the stat pushed or the character sheet and the perk
    -- disagree until something else recalculates. The engine's command does
    -- exactly this for Fitness (:67-69).
    if perk == Perks.Fitness or perk == Perks.Strength then
        local stat = (perk == Perks.Fitness) and CharacterStat.FITNESS
            or CharacterStat.STRENGTH
        local stats = player:getStats()
        if stats then
            stats:set(stat, player:getPerkLevel(perk) / 5.0 - 1.0)
        end
    end

    -- The replication trigger. Without it the client's copy is stale until
    -- something else forces a sync, which reads as "the kit gave me nothing".
    local ai = player:getNetworkCharacterAI()
    if ai then ai:updateXpChecker() end

    return true, g.perk .. " " .. (g.amount >= 0 and "+" or "") .. g.amount
        .. " xp"
end

-- ---------------------------------------------------------------------------
-- A whole grant list
-- ---------------------------------------------------------------------------

local applyList

-- Roulette is not an applier: it DRAWS and then recurses, and the draw has to
-- reach the report so the caller can store it.
local function applyRoulette(player, g, by, index, report)
    local drawn, why = DMRoll.roll(g.from, g.pick, DMGrant.rand)
    if not drawn then
        report.failed[#report.failed + 1] = "roulette " .. index .. ": " .. why
        return
    end

    report.rolls[index] = drawn

    for _, branch in ipairs(drawn) do
        applyList(player, g.from[branch].grants, by, report)
    end
end

applyList = function(player, grants, by, report)
    for i, g in ipairs(grants) do
        if g.kind == DMKitDefs.ROULETTE then
            applyRoulette(player, g, by, i, report)
        else
            local applier = appliers[g.kind]
            if not applier then
                -- Unreachable while DMKitDefs and this table agree, and kept
                -- because the day they stop agreeing the symptom is a grant
                -- that vanishes without a word.
                report.failed[#report.failed + 1] =
                    "grant " .. i .. ": no applier for kind '"
                    .. tostring(g.kind) .. "'"
            else
                local ok, detail = applier(player, g, by)
                if ok then
                    report.landed[#report.landed + 1] = detail
                else
                    report.failed[#report.failed + 1] =
                        "grant " .. i .. ": " .. tostring(detail)
                end
            end
        end
    end
end

-- Hand a kit's grants to a live player.
--
-- Returns a report: { landed = { text, ... }, failed = { text, ... },
-- rolls = { [grantIndex] = { branchIndex, ... } } }, or (nil, reason) when the
-- whole thing could not be attempted.
--
-- `by` is the admin who caused it, or nil for a self-claim; it reaches RDVars
-- so a granted flag records who is responsible for it.
function DMGrant.apply(player, grants, by)
    -- An offline or absent player is refused WHOLE. See the header: the engine
    -- has no server-side path that gives XP to a player with no connection, and
    -- an absent one has no inventory either, so a partial application here
    -- would be silently short in a way nobody could see afterwards.
    if type(player) ~= "table" and type(player) ~= "userdata" then
        return nil, "a kit can only be handed to a player who is online"
    end
    if not player.getInventory then
        return nil, "a kit can only be handed to a player who is online"
    end
    if type(grants) ~= "table" then
        return nil, "grants must be a list"
    end

    local report = { landed = {}, failed = {}, rolls = {} }
    applyList(player, grants, by, report)
    return report
end

-- Did anything at all land? The caller's rule for whether to record a claim -
-- see the header on partial failure.
function DMGrant.anyLanded(report)
    return type(report) == "table" and #report.landed > 0
end

-- One line for an admin log or a player's confirmation. Deliberately says what
-- FAILED as well: a reward that silently came up short is the failure this
-- whole file is shaped around.
function DMGrant.summary(report)
    if type(report) ~= "table" then return "nothing" end
    local got = #report.landed > 0 and table.concat(report.landed, ", ")
        or "nothing"
    if #report.failed > 0 then
        return got .. " (failed: " .. table.concat(report.failed, "; ") .. ")"
    end
    return got
end

return DMGrant

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
