-- SPDX-License-Identifier: GPL-3.0-or-later
-- MMTraitRepair.lua - undo a shadowed-trait swap on a live character.
--
-- WHY THIS EXISTS. Until 2026-08-09 the codec resolved snapshot traits by
-- getName(), which returns the ResourceLocation PATH with the namespace stripped
-- (CharacterTrait.java:118). base:Organized and SeinarExtendedProfessions
-- :Organized therefore share the key "organized", vanilla scripts always parse
-- before mod scripts, and the last writer won - so every memoir read handed the
-- player the MOD's trait in place of the vanilla one it shadowed. Seinar's is a
-- character-creation placeholder with no implementation (their own CreatePlayer
-- .lua swaps it to base at OnNewGame), so the real effect - for Organized, the
-- +30% container bonus that ItemContainer.getEffectiveCapacity reads off
-- CharacterTrait.ORGANIZED specifically - silently went away.
--
-- MMSvShared now keys on the full registry id, so no NEW character can be
-- corrupted this way. This file is for the ones already holding the impostor.
--
-- THE RULE IT APPLIES: a known trait is a repair candidate when its namespace is
-- not "base" AND the registry contains base:<same path>. That is the definition
-- of "a mod trait shadowing a vanilla one" and nothing more - it does not know
-- or care which mod, and it will not touch a mod trait that shadows nothing.
--
-- DRY RUN BY DEFAULT. This edits live characters, so `apply` must be passed
-- explicitly; without it the handler reports exactly what it would change and
-- touches nothing. Re-running after a repair finds nothing (the character now
-- holds the base trait), so it is safe to run repeatedly.
--
-- THE JUDGEMENT CALL IT CANNOT MAKE: a player who DELIBERATELY picked a mod
-- trait that shadows a vanilla one - because the mod meant them to have it - is
-- indistinguishable here from one who was handed it by a bad read. The report
-- flags the Seinar-style placeholder shape (cost 0 + IsProfessionTrait) to help,
-- but the admin decides. Read the dry run before passing apply.

if not isServer() then return end

require "MMSvShared"

MMTraitRepair = MMTraitRepair or {}

-- PF_Traits (SyncPlayerFieldsPacket.java:22). The packet writes the SERVER's
-- CharacterTraits and the client's parse does reset()+add for each - i.e. it
-- replaces the client list wholesale with ours. That is exactly the semantics a
-- repair wants, and it is why this file needs no client-side mirror-apply.
local PF_TRAITS = 2

local function findOnlineByUsername(name)
    local found
    pcall(function()
        local players = getOnlinePlayers()
        if not players then return end
        for i = 0, players:size() - 1 do
            local p = players:get(i)
            if p and p:getUsername() == name then found = p; break end
        end
    end)
    return found
end

-- Split "namespace:path" -> namespace, path. nil for anything that is not an id
-- (a stale registry object, whose getLocation() is gone).
local function splitId(id)
    if type(id) ~= "string" then return nil end
    local ns, path = id:match("^([^:]+):(.+)$")
    return ns, path
end

-- Candidates on ONE character. Pure inspection - never mutates.
-- Returns a list of { have, want, placeholder } sorted by `have`.
function MMTraitRepair.scan(player)
    local out = {}
    local known = player:getCharacterTraits():getKnownTraits()
    for i = 0, (known and known:size() or 0) - 1 do
        local t = known:get(i)
        local id = MMShared.fqid(t)
        local ns, path = splitId(id)
        if ns and ns ~= "base" then
            local baseId = "base:" .. path
            local baseTrait = MMShared.findTrait(baseId)
            -- findTrait on an explicit id hits the registry directly, so this is a
            -- real "does vanilla own this path" test, not a name-map guess.
            if baseTrait then
                -- Seinar's placeholders are Cost=0 + IsProfessionTrait=true. Reported,
                -- not enforced: it is a confidence hint for the admin, and a mod that
                -- shadows vanilla with a REAL trait would (rightly) not match it.
                local placeholder = false
                pcall(function()
                    local def = CharacterTraitDefinition.getCharacterTraitDefinition(t)
                    if def then placeholder = (def:getCost() == 0) and (def:isFree() == true) end
                end)
                out[#out + 1] = { have = id, want = baseId, placeholder = placeholder,
                                  modTrait = t, baseTrait = baseTrait }
            end
        end
    end
    table.sort(out, function(a, b) return a.have < b.have end)
    return out
end

-- Swap one character's shadowed traits for the vanilla originals.
-- Returns { ok, reason|message, found = n, repaired = n, items = {...} }.
function MMTraitRepair.runOne(admin, targetUsername, apply)
    targetUsername = tostring(targetUsername or "")
    if targetUsername == "" then return { ok = false, reason = "No target username." } end

    local target = findOnlineByUsername(targetUsername)
    if not target then
        return { ok = false, reason = targetUsername .. " must be online to repair." }
    end
    if target:isDead() then
        return { ok = false, reason = targetUsername .. " is dead - repair after they respawn." }
    end

    local okScan, found = pcall(MMTraitRepair.scan, target)
    if not okScan then
        MMwarn("REPAIR scan failed for " .. targetUsername .. ": " .. tostring(found))
        return { ok = false, reason = "Scan failed for " .. targetUsername .. " - check server console." }
    end

    local items = {}
    for _, c in ipairs(found) do
        items[#items + 1] = c.have .. " -> " .. c.want .. (c.placeholder and " (placeholder)" or "")
    end

    if #found == 0 then
        return { ok = true, found = 0, repaired = 0, items = items,
                 message = targetUsername .. ": no shadowed traits." }
    end
    if not apply then
        return { ok = true, found = #found, repaired = 0, items = items,
                 message = targetUsername .. ": " .. #found .. " shadowed trait(s) - "
                     .. table.concat(items, ", ") .. " (dry run, nothing changed)" }
    end

    -- Boost bookkeeping mirrors applyIdentity: modifyTraitXPBoost SUBTRACTS the
    -- outgoing trait's boosts from the live map and ADDS the incoming one's, and it
    -- null-guards a missing definition (IsoGameCharacter.java:10380), so a
    -- definitionless trait is safe to pass. Remove before add, so a shared perk
    -- entry nets out the way creation would have left it.
    local repaired = 0
    local okApply, err = pcall(function()
        local traits = target:getCharacterTraits()
        for _, c in ipairs(found) do
            traits:remove(c.modTrait)
            target:modifyTraitXPBoost(c.modTrait, true)
            traits:add(c.baseTrait)
            target:modifyTraitXPBoost(c.baseTrait, false)
            repaired = repaired + 1
        end
    end)
    if not okApply then
        MMwarn("REPAIR apply FAILED for " .. targetUsername .. ": " .. tostring(err))
        return { ok = false, found = #found, repaired = repaired, items = items,
                 reason = "Repair failed for " .. targetUsername .. " - check server console." }
    end

    -- VERIFY, same principle as applyIdentity: the engine's add() returns nothing
    -- and validates nothing, so read the character back before reporting success.
    local okVerify, still = pcall(MMTraitRepair.scan, target)
    if okVerify and #still > 0 then
        MMwarn("REPAIR incomplete for " .. targetUsername .. ": " .. tostring(#still)
            .. " shadowed trait(s) survived the swap")
        return { ok = false, found = #found, repaired = repaired, items = items,
                 reason = "Repair incomplete for " .. targetUsername .. " - check server console." }
    end

    -- Push the authoritative trait list to the owning client (see PF_TRAITS above).
    if sendSyncPlayerFields then pcall(function() sendSyncPlayerFields(target, PF_TRAITS) end) end

    if MMAudit then
        -- `admin` is an IsoPlayer for a manual repair and a plain string for an
        -- automatic one ("auto:login"). Recording which is which is the point:
        -- "who changed my traits" has a different answer in each case, and the
        -- audit trail is the only place that answer survives.
        local by = "?"
        if type(admin) == "string" then by = admin
        elseif admin and admin.getUsername then by = admin:getUsername() or "?" end
        MMAudit.log(target, "TRAIT_REPAIR", { admin = by, swaps = items })
    end
    MMwarn("REPAIR " .. targetUsername .. ": " .. table.concat(items, ", "))
    return { ok = true, found = #found, repaired = repaired, items = items,
             message = targetUsername .. ": repaired " .. repaired .. " trait(s) - "
                 .. table.concat(items, ", ") }
end

-- Same batch cap and per-target reporting contract as MMRestore.runMany: partial
-- failure is normal here (targets must be online and alive), so nothing is
-- summarised away without the Console tab getting the reason.
local MAX_BATCH = 10

function MMTraitRepair.run(admin, usernames, apply)
    if type(usernames) ~= "table" then
        if type(usernames) == "string" then usernames = { usernames }
        else return { ok = false, reason = "No targets selected." } end
    end

    local seen, targets = {}, {}
    for _, u in ipairs(usernames) do
        local name = tostring(u or "")
        if name ~= "" and not seen[name] then
            seen[name] = true
            targets[#targets + 1] = name
        end
    end
    if #targets == 0 then return { ok = false, reason = "No targets selected." } end
    if #targets == 1 then return MMTraitRepair.runOne(admin, targets[1], apply) end

    local overflow = {}
    while #targets > MAX_BATCH do table.insert(overflow, 1, table.remove(targets)) end

    local function report(name, ok, detail)
        if DFCore and DFCore.audit then
            DFCore.audit("memoirTraitRepair", admin, "target=" .. name .. " " .. tostring(detail))
        else
            MMwarn("REPAIR batch -> " .. name .. ": " .. tostring(detail))
        end
    end

    local okCount, failed, totalFound, totalRepaired = 0, 0, 0, 0
    for _, name in ipairs(targets) do
        local called, res = pcall(MMTraitRepair.runOne, admin, name, apply)
        if not called then
            failed = failed + 1
            report(name, false, "internal error: " .. tostring(res))
        elseif type(res) == "table" and res.ok then
            okCount = okCount + 1
            totalFound = totalFound + (res.found or 0)
            totalRepaired = totalRepaired + (res.repaired or 0)
            report(name, true, res.message or "ok")
        else
            failed = failed + 1
            report(name, false, (type(res) == "table" and (res.reason or res.message)) or "unknown failure")
        end
    end
    for _, name in ipairs(overflow) do
        report(name, false, "not attempted, batch cap " .. MAX_BATCH)
    end

    local parts = { string.format("%s %d of %d", apply and "Repaired" or "Scanned",
                                  okCount, #targets) }
    parts[#parts + 1] = string.format("%d shadowed trait(s) found", totalFound)
    if apply then parts[#parts + 1] = string.format("%d swapped", totalRepaired)
    else parts[#parts + 1] = "dry run" end
    if failed > 0 then parts[#parts + 1] = string.format("%d skipped", failed) end
    if #overflow > 0 then parts[#parts + 1] = string.format("%d over the %d cap", #overflow, MAX_BATCH) end
    if failed > 0 or #overflow > 0 or totalFound > 0 then parts[#parts + 1] = "see Console tab" end
    local summary = table.concat(parts, " - ") .. "."

    if okCount == 0 then return { ok = false, reason = summary } end
    return { ok = true, message = summary }
end

-- ─────────────────────────────────────────────────────────────────────────
-- Auto-repair on login (sandbox-gated, default off - see MMShared
-- .autoFixShadowedTraits for why the default is what it is)
-- ─────────────────────────────────────────────────────────────────────────
--
-- WHY THIS IS THE PRIMARY PATH and not a convenience on top of an admin button:
-- the bad swap was written into the PLAYER SAVE, so a corrupted character stays
-- corrupted through any number of relogs, and an admin can only repair someone
-- who happens to be online and alive at the moment they think to look. Anyone
-- who read a memoir and then stopped playing for a fortnight would simply never
-- be found. Hooking the connection inverts that: the fix itself ships with a
-- server restart, every player reconnects through this hook on their way back
-- in, and the population heals without anyone being chased.
--
-- RDLife.onPlayerReady fires once per connection, after square AND inventory are
-- both present, and pcalls each subscriber independently - so a fault here
-- cannot disturb the chronicle or any other subscriber.
Events.OnServerStarted.Add(function()
    if not RDLife or not RDLife.onPlayerReady then
        MMwarn("MMTraitRepair: RDLife.onPlayerReady missing - login auto-repair NOT armed")
        return
    end
    RDLife.onPlayerReady(function(p)
        -- Read the knob per connection, not once at boot: an admin who flips it
        -- mid-session for a migration should not have to restart again.
        if not MMShared.autoFixShadowedTraits() then return end
        local ok, res = pcall(MMTraitRepair.runOne, "auto:login", p:getUsername(), true)
        if not ok then
            MMwarn("auto-repair threw for " .. MMname(p) .. ": " .. tostring(res))
        elseif type(res) == "table" and res.ok and (res.repaired or 0) > 0 then
            -- Loud on purpose. This edits a character without anyone asking, so
            -- the console must carry a record of every one it touched.
            MMwarn("auto-repair on login: " .. MMname(p) .. " -> "
                .. table.concat(res.items or {}, ", "))
        end
    end)
    print("[Dragonfly] MMTraitRepair: login auto-repair armed (sandbox-gated)")
end)

-- Deferred registration: DFServer loads after Memoirs/ alphabetically, so the
-- handler table does not exist at file scope (same gate MMRestore uses).
--
-- NO UI BUTTON. There was one on the Players tab; it was removed once the login
-- hook above landed, because the hook catches the whole population on the first
-- reconnect after the deploy restart and the button would have been dead the day
-- after. The handler stays as the manual override - for a straggler while the
-- sandbox knob is off, or to re-check one character - reachable by an explicit
-- client command with the same capability gate every other Players-tab action
-- carries. Call MMTraitRepair.run(admin, {names}, true) directly server-side.
Events.OnServerStarted.Add(function()
    if not DFServer or not DFServer.registerHandler then
        print("[Dragonfly] MMTraitRepair: DFServer missing, repair handler not registered")
        return
    end
    DFServer.registerHandler{
        action     = "memoirTraitRepair",
        capability = Capability.CanModifyPlayerStatsInThePlayerStatsUI,
        -- args.apply must be literally true to mutate. Anything else - absent,
        -- nil, "true", 1 - is a dry run, because an accidental character edit is
        -- much worse than an accidental report.
        run = function(player, args)
            args = args or {}
            local targets = args.usernames or args.username
            return MMTraitRepair.run(player, targets, args.apply == true)
        end,
    }
    print("[Dragonfly] MMTraitRepair handler registered")
end)

return MMTraitRepair

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
