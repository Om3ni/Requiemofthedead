-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFSidebarBadge - plate resolution for Dragonfly's two sidebar badges.
--
-- The admin deck badge (DFDeckButton) and the player panel badge
-- (DFPlayerButton) are the same kind of thing: an ISButton appended to
-- vanilla's left column, wearing pre-rendered art plates that ship in one file
-- per sidebar size. Both had grown identical copies of the two mechanisms that
-- make that work, and a drifted copy here fails visibly - a badge one size
-- bucket off its neighbours reads as broken art. Promoted 2026-08-20.
--
-- What is here is MECHANISM only. Which plates a badge wears, how many states
-- it has, and what a missing plate degrades to are call-site policy and stay
-- with each badge - the admin badge tolerates a missing alert plate by
-- dropping to a two-frame cycle, the player badge has no alert at all, and
-- neither rule belongs to the other.

if isServer() then return end

DFSidebarBadge = DFSidebarBadge or {}

-- Vanilla's sidebar texture widths. These are the sizes the PLATE FILES ship
-- in (media/ui/DFSidebar/<bucket>/...), which is why they are a fixed list
-- rather than read from the engine: the question this answers is "which of
-- OUR files fits best", not "how big is the sidebar" - the live width comes
-- from adminBtn at the call sites, precisely so a sidebar-size option change
-- is followed (see DFDeckButton's header on why copying vanilla's numbers for
-- the LIVE size would drift).
local SIZE_BUCKETS = { 48, 64, 80, 96, 128 }

function DFSidebarBadge.tex(path)
    -- the getTexture GLOBAL is self-catching (LuaManager:6855 ->
    -- Texture.getSharedTexture:406, try/catch returning null), so a missing
    -- file is a nil here, never a throw
    return getTexture(path)
end

-- The bucket whose plate art best fits a live sidebar width.
function DFSidebarBadge.bucketFor(width)
    local best, bestDiff = SIZE_BUCKETS[#SIZE_BUCKETS], nil
    for _, b in ipairs(SIZE_BUCKETS) do
        local d = math.abs(b - (width or 0))
        if not bestDiff or d < bestDiff then best, bestDiff = b, d end
    end
    return best
end

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
