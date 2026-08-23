-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFLayout - the client's copy of the admin layout overlay.
--
-- DFOverlay (shared) owns the ordering rule. DFOverlay_Server owns the store
-- and the gates. This file owns the client's side of that conversation: what we
-- have asked for, what came back, and handing a view a page that has been
-- shaped by whatever the server holds.
--
-- ---------------------------------------------------------------------------
-- WHY THERE IS A CACHE AT ALL, given the panel could ask every time it draws:
-- because it draws sixty times a second and the answer changes when an admin
-- saves, which is roughly never. One request per page per session, plus a push
-- whenever anybody writes.
--
-- The push is what makes the cache safe to keep. DFOverlay_Server broadcasts to
-- every staff connection after a write - INCLUDING THE WRITER - so a stale copy
-- has a bounded life measured in the round trip, and the writer's own panel
-- refreshes by the same path a second admin's does. There is no confirmation
-- branch here that could disagree with the broadcast, because there is no
-- confirmation branch.
--
-- ---------------------------------------------------------------------------
-- A LOST REPLY MUST NOT BE PERMANENT. `asked` marks a request in flight so a
-- redraw does not re-send it sixty times a second, and that flag is exactly the
-- thing that would strand a page forever if the reply never arrived - a refused
-- read, a disconnect mid-request. So it is cleared by forget(), which the tab
-- calls when it is shown: reopening the tab is the retry, and it is the gesture
-- an admin already makes when a panel looks wrong.
--
-- ---------------------------------------------------------------------------
-- SHAPING IS NOT CACHED, deliberately. shape() runs DFOverlay.apply on every
-- rebuild rather than memoising the result, because the input it is applied to
-- is the reflected model, which is rebuilt when a mod loads or the panel is
-- reopened. A memo keyed on "the page" would have to know when the page changed
-- underneath it, and getting that wrong shows an admin an option list that no
-- longer matches the server. apply() over ~64 rows on a rebuild is nothing;
-- rebuilds happen on click, not per frame.

if isServer() then return end

require "DFKit"
require "DFOverlay"

DFLayout = DFLayout or {}
local L = DFLayout

L.cache    = {}   -- key -> { entries, by, atMs, held }
L.asked    = {}   -- key -> true while a request is in flight
L.listeners = {}

local function fire(key)
    for _, fn in ipairs(L.listeners) do fn(key) end
end

-- A view registers once, at attach, and is called when any page's layout
-- lands. Views filter on the key themselves - the two of them care about
-- different pages and neither should have to learn about the other's.
function DFLayout.onChanged(fn)
    L.listeners[#L.listeners + 1] = fn
end

-- ---------------------------------------------------------------------------
-- Reading
-- ---------------------------------------------------------------------------

function DFLayout.entriesFor(key)
    local rec = L.cache[key]
    return rec and rec.entries or nil
end

function DFLayout.recordFor(key) return L.cache[key] end

-- True while the server is holding a layout file it will not read and will not
-- overwrite - see RDConfigStore's THE HOLD. The panel is drawing reflected
-- order in that state and must say so, because the alternative is an admin
-- concluding their arrangement was lost.
function DFLayout.held(key)
    local rec = L.cache[key]
    return rec and rec.held or nil
end

-- The page a view should draw. Falls through to the reflected page untouched
-- when nothing is cached, which is also what happens for a page nobody has ever
-- arranged - the two are the same state and are not distinguished on purpose.
function DFLayout.shape(page)
    if not page then return page, { placed = 0, added = 0, stale = 0 } end
    return DFOverlay.apply(page, DFLayout.entriesFor(page.page))
end

-- The one line a view puts in front of an admin about the layout, or nil when
-- there is nothing to say. It lives HERE rather than in each view because both
-- views need it and a second copy is what check-helpers exists to catch - and
-- because the wording is the whole value: every state below is one in which the
-- panel is showing something other than what the admin arranged, and saying so
-- badly is the same as not saying it.
--
-- Ordered by what a reader can act on. A held file is a decision waiting; an
-- unplaced option is the only signal that the page grew since it was arranged;
-- a stale entry is already handled and merely worth knowing.
function DFLayout.noteFor(key, stats)
    local held = DFLayout.held(key)
    if held == "foreign" then
        return "A layout saved before this world is on disk and has NOT been "
            .. "loaded. Recover it or discard it."
    elseif held == "corrupt" then
        return "The saved layout file will not decode and is being kept for "
            .. "inspection. Nothing is being written until it is dealt with."
    end
    if not stats then return nil end
    if (stats.added or 0) > 0 and DFLayout.entriesFor(key) then
        return stats.added .. " option(s) are not placed in this layout - they "
            .. "are shown next to whichever option they follow."
    end
    if (stats.stale or 0) > 0 then
        return stats.stale .. " entr" .. (stats.stale == 1 and "y" or "ies")
            .. " in this layout name options that no longer exist."
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- The wire
-- ---------------------------------------------------------------------------

function DFLayout.request(key)
    if not key or L.cache[key] or L.asked[key] then return false end
    if not DFOverlay.validKey(key) then return false end
    L.asked[key] = true
    sendClientCommand(getPlayer(), DFCore.MODULE, "layoutGet", { key = key })
    return true
end

-- Save. The reply is the broadcast, not a return value: this client is on the
-- staff list too, so the same push that updates every other panel updates this
-- one. Nothing here writes the cache optimistically - a write the server
-- refused would otherwise leave this panel showing a layout that exists
-- nowhere else.
function DFLayout.save(key, entries)
    if not DFOverlay.validKey(key) then return false end
    sendClientCommand(getPlayer(), DFCore.MODULE, "layoutSet",
                      { key = key, entries = entries or {} })
    return true
end

function DFLayout.recover(take)
    sendClientCommand(getPlayer(), DFCore.MODULE, "layoutRecover",
                      { take = take and true or false })
end

-- Drop what we know so the next request re-asks. Called when the tab is shown
-- (the retry for a lost reply) and when the server says every copy is wrong.
function DFLayout.forget(key)
    if key then
        L.cache[key] = nil
        L.asked[key] = nil
    else
        L.cache, L.asked = {}, {}
    end
end

-- Exposed rather than local so a fixture can drive the receive path without a
-- fake Events table, and so the two commands stay one function - they differ
-- only in whether anything came with them.
function DFLayout.receive(command, args)
    if command == "AdminLayout" then
        local key = args and args.key
        if not key then return false end
        L.asked[key] = nil
        L.cache[key] = {
            entries = args.entries or {},
            by      = args.by,
            atMs    = args.atMs,
            held    = args.held,
        }
        fire(key)
        return true
    elseif command == "AdminLayoutStale" then
        -- Every page at once: a recover replaces the whole document, so there
        -- is no page-shaped correction to send.
        DFLayout.forget()
        fire(nil)
        return true
    end
    return false
end

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= DFCore.MODULE then return end
    DFLayout.receive(command, args)
end)

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
