-- SPDX-License-Identifier: GPL-3.0-or-later
-- LRPrefs.lua  (client)
--
-- Last Rites' client-side cosmetic preferences - the LRHub toggles and the
-- overhead Y offset. Outcome-affecting config is sandbox options and never
-- lives here.
--
-- The store itself moved to Core 2026-08-19. This file was 97 lines and
-- RFTDOddsAndEnds/OEPrefs.lua was the same 97 lines with two names changed, so
-- the serializer, the reader, the writer and the startup load now live once in
-- RDClientPrefs and this is the binding. Nothing about the call surface
-- changed: LRPrefs.get / LRPrefs.set behave exactly as before, and so does the
-- file on disk - same name, same format, same location, so a player's existing
-- preferences load untouched.
--
-- Per-install, not per-save and not synced: the file lands in the user's
-- Zomboid dir, which is exactly right for something that is about one person's
-- screen rather than one world's rules.

require "RDClientPrefs"

-- The filename is carried here rather than derived from the mod id because it
-- already exists on players' machines. Deriving it would rename the file and
-- quietly discard every setting anyone has made.
LRPrefs = RDClientPrefs.store("RFTDLastRites_clientprefs.txt")

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
