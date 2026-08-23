-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFOverlay_Server - the admin layout overlay, stored and served.
--
-- DFOverlay (shared) owns what a layout IS and what it may do to a page. This
-- file owns where it lives, who may write one, and how it reaches the other
-- admins' panels. Nothing here knows what an option means.
--
-- ---------------------------------------------------------------------------
-- WHY THE SERVER HOLDS IT AT ALL. A layout could have been a client preference
-- - DFPrefs already stores those - and that was rejected for one reason: admin
-- state only one admin can see is a sticky note. Four people share this panel.
-- If the person who arranged Dirge's sixty-four options into something usable
-- is the only one who ever sees that arrangement, the work is done four times
-- or not at all, and the second admin's screenshot in chat does not match what
-- the first admin is looking at.
--
-- ---------------------------------------------------------------------------
-- ONE PAGE PER MESSAGE, in both directions, and that is the bound.
--
-- The obvious shape - ship the whole document - has no ceiling worth relying
-- on: ten pages at DFOverlay.MAX_ENTRIES is six figures of string, which is not
-- a ClientCommand. Per page it is at most one page's entries, and the panel
-- draws one page at a time anyway, so the request follows what the admin is
-- actually looking at. Nothing needs chunking and nothing needs a budget.
--
-- The broadcast after a write goes to ALL staff INCLUDING THE SENDER, which is
-- deliberate: the writer's own panel updates by the same path a second admin's
-- does, so there is one receive path and no confirmation branch that could
-- disagree with it.
--
-- ---------------------------------------------------------------------------
-- AUTHORITY. Registered with NO dispatcher capability and gated inside the
-- handler, following auditOnly's precedent in DFServer - because the right gate
-- is not one capability, it is per page:
--
--   __server page     Capability.ChangeAndReloadServerOptions
--   a sandbox page    Capability.SandboxOptions
--
-- Those are the engine's own gates for the two screens this panel mirrors, they
-- are what the two sub-tabs are shown for, and a role can hold either without
-- the other. A single dispatcher capability would have to pick one and would
-- then either lock a sandbox-only moderator out of arranging sandbox pages or
-- let them rearrange the server page. DFServer's `handler.capability` takes one
-- name, so the check moves inside; it is not weaker for that - the dispatcher
-- would run the same RDAccess call.
--
-- Reading is staff-only rather than per page. A layout is an ordering of option
-- names every client already holds a copy of, so there is nothing to leak; the
-- gate exists so a non-staff client cannot make the server do work.

if not isServer() then return end

require "RDShared"
require "RDConfigStore"
require "DFOverlay"

DFOverlay_Server = DFOverlay_Server or {}

-- ---------------------------------------------------------------------------
-- The store
--
-- DEFS-ONLY. A layout is authored configuration end to end: an order and some
-- headings, written rarely, and exactly the half an admin wants back after a
-- wipe. There is no per-player anything in a column of settings, so there is no
-- hot document, and RDConfigStore takes the absence rather than being handed an
-- empty file that would trip its foreign hold after a wipe and ask an admin to
-- decide about nothing.
-- ---------------------------------------------------------------------------

local store

local function ensure()
    if not store then
        store = RDConfigStore.new{
            modKey   = "RFTDAdminLayout",
            defsFile = RDShared.DIR .. "admin-layout" .. RDShared.EXT_DOC,
            label    = "Dragonfly",
        }
    end
    store:boot()   -- idempotent
    return store
end

local function pages()
    local defs = ensure():defs()
    defs.pages = defs.pages or {}
    return defs.pages
end

-- ---------------------------------------------------------------------------
-- Read and write, split from the wire so a fixture can drive them.
-- ---------------------------------------------------------------------------

-- One page's record, or nil. Shape: { entries, by, atMs }.
function DFOverlay_Server.get(key)
    if not DFOverlay.validKey(key) then return nil end
    return pages()[key]
end

-- Store one page. Returns (true, kept, dropped) or (false, reason).
--
-- An EMPTY layout removes the page rather than storing an empty list, and that
-- is the reset: with no record the panel falls back to the reflected order,
-- which is the same state a page has before anyone ever arranges it. Storing
-- `{}` instead would leave a second way to express "no layout" and a document
-- that grows a key every time someone opens the editor and changes their mind.
function DFOverlay_Server.set(key, entries, who)
    if not DFOverlay.validKey(key) then
        return false, "bad page key"
    end
    local clean, dropped = DFOverlay.sanitize(entries)
    local p = pages()
    if #clean == 0 then
        p[key] = nil
    else
        p[key] = { entries = clean, by = who, atMs = RDShared.nowMs() }
    end
    ensure():touchDefs()
    return true, #clean, dropped
end

-- ---------------------------------------------------------------------------
-- Wire
-- ---------------------------------------------------------------------------

local function capabilityFor(key)
    if key == DFOverlay.SERVER_KEY then
        return "ChangeAndReloadServerOptions"
    end
    return "SandboxOptions"
end

-- What a client is sent for one page. `held` travels with it because a held
-- store is the one state in which the panel is showing reflected order while a
-- perfectly good layout sits on disk - and without this the admin's only clue
-- would be a line in a server console they may not have.
local function payloadFor(key)
    local rec = DFOverlay_Server.get(key)
    -- report(), not the store's own `held` table: a satellite reading Core's
    -- internals is the coupling sect. 12 forbids, and report() is the surface
    -- that exists for exactly this question.
    local held = ensure():report().heldDefs
    return {
        key     = key,
        entries = rec and rec.entries or {},
        by      = rec and rec.by,
        atMs    = rec and rec.atMs,
        held    = held,
    }
end

local function pushTo(player, key)
    sendServerCommand(player, DFCore.MODULE, "AdminLayout", payloadFor(key))
end

-- DFServer.lua loads AFTER this file - the server walks its lua tier in name
-- order and "DFOverlay_Server" sorts before "DFServer" - so DFServer is nil at
-- top-of-file execution. Same trap DFPlayersTab_Server and DFInventory_Server
-- already carry, same gate: OnServerStarted is after the whole script set and
-- before any client can send a command.
Events.OnServerStarted.Add(function()
    if not DFServer or not DFServer.registerHandler then
        print("[Dragonfly] DFOverlay_Server: DFServer missing, handlers not registered")
        return
    end

    -- Boot the store HERE rather than at the first request, so a held or
    -- unwritable store says so in the console at the time an operator is
    -- reading it, not the first time an admin opens a tab days later.
    ensure()

    DFServer.registerHandler{
        action = "layoutGet",
        -- No dispatcher capability ON PURPOSE - see AUTHORITY in the header. Staff
        -- is the gate for a read, and it is checked here rather than being left to
        -- the absence of a caller.
        run = function(player, args)
            if not DFCore.hasAnyCapability(player) then
                return { ok = false, reason = "not permitted" }
            end
            local key = tostring(args.key or "")
            if not DFOverlay.validKey(key) then
                return { ok = false, reason = "bad page key" }
            end
            pushTo(player, key)
            return { ok = true }
        end,
    }

    DFServer.registerHandler{
        action = "layoutSet",
        run = function(player, args)
            local key = tostring(args.key or "")
            if not DFOverlay.validKey(key) then
                return { ok = false, reason = "bad page key" }
            end
            -- The gate that matters, and it is per page. Domain validation inside
            -- the handler is not a fallback for a missing dispatcher capability
            -- here; it IS the correct gate, because the answer depends on the
            -- payload (CLAUDE.md sect. 13).
            if not RDAccess.roleHas(player, capabilityFor(key)) then
                return { ok = false, reason = "missing capability for " .. key }
            end

            local ok, kept, dropped = DFOverlay_Server.set(
                key, args.entries, player:getUsername())
            if not ok then return { ok = false, reason = kept } end

            -- Counted, not silently accepted. A payload three quarters of which was
            -- refused leaves the client and the server holding different layouts,
            -- and the broadcast below is what resolves that - but only if somebody
            -- can see it happened.
            DFCore.audit("layoutSet", player, string.format(
                "page=%s entries=%d%s", key, kept,
                dropped > 0 and (" dropped=" .. dropped) or ""))

            RDNet.sendStaff(DFCore.MODULE, "AdminLayout", payloadFor(key))
            return { ok = true, message = kept == 0
                and ("Layout cleared for " .. key)
                or  (kept .. " entries saved for " .. key) }
        end,
    }

    -- The way out of a hold, in the panel rather than only in a server console.
    --
    -- After a wipe the file outlives the world that wrote it, so RDConfigStore
    -- refuses to load it and refuses to overwrite it (its THE HOLD section says
    -- why, and the rule is uniform across consumers on purpose). For a layout that
    -- resolves to a genuine choice - last season's arrangement is either still
    -- wanted or it is not - and the person who can answer it is looking at this
    -- panel, not at the console. Both exits are explicit and neither is reachable
    -- by accident.
    DFServer.registerHandler{
        action = "layoutRecover",
        run = function(player, args)
            -- Recovering replaces every page's layout at once, so this is gated on
            -- the stricter of the two capabilities rather than on either.
            if not RDAccess.roleHas(player, "ChangeAndReloadServerOptions") then
                return { ok = false, reason = "not permitted" }
            end
            local s = ensure()
            if not s:report().heldDefs then
                return { ok = false, reason = "nothing is held" }
            end
            local ok, why
            if args.take then ok, why = s:import("defs") else ok, why = s:discard("defs") end
            if not ok then return { ok = false, reason = tostring(why) } end
            DFCore.audit("layoutRecover", player, args.take and "imported" or "discarded")
            -- Everyone's copy of whatever page they are on is now wrong. There is
            -- no per-page broadcast that fixes that, so tell the panels to re-ask.
            RDNet.sendStaff(DFCore.MODULE, "AdminLayoutStale", {})
            return { ok = true, message = args.take
                and "Saved layouts recovered."
                or  "Saved layouts discarded." }
        end,
    }

    print("[Dragonfly] DFOverlay_Server handlers registered")
end)

print("[Dragonfly] DFOverlay_Server loaded (registration deferred to OnServerStarted)")

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
