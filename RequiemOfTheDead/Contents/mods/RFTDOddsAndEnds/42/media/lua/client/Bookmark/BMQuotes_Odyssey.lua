-- SPDX-License-Identifier: GPL-3.0-or-later
-- BMQuotes_Odyssey.lua - Bookmark quote chunk: Homer (public domain).
-- These eight came from RFTDCore's RDOdysseySmoke.lua, the throwaway popup that
-- proved the Mosaic junction loop worked; Bookmark superseded it, so they moved
-- here and the smoke test was deleted. Their quips are the smoke test's own,
-- verbatim - they set the voice every other chunk now follows.
--
-- Wording varies by translator more than most entries here (Butler 1900 and
-- Pope's verse are the usual public-domain English renderings); these are the
-- most commonly quoted forms, with Pope's flagged where it is distinctly his.

Bookmark = Bookmark or {}
Bookmark.QuoteChunks = Bookmark.QuoteChunks or {}

Bookmark.QuoteChunks.Odyssey = {
    { text = "There is a time for many words, and there is also a time for sleep.", author = "Homer", work = "The Odyssey", quip = "four books into telling his own story" },
    { text = "My name is Nobody.", author = "Homer", work = "The Odyssey", quip = "the original fake ID" },
    { text = "Endure, my heart; you have endured worse than this.", author = "Homer", work = "The Odyssey", quip = "solid advice for Knox County" },
    { text = "Few sons are like their fathers; most are worse.", author = "Homer", work = "The Odyssey", quip = "Athena, roasting an entire generation" },
    { text = "The blade itself incites to deeds of violence.", author = "Homer", work = "The Odyssey", quip = "why the good axe stays home" },
    { text = "Wine can of their wits the wise beguile.", author = "Homer", work = "The Odyssey (Pope's translation)", quip = "leading cause of death after zombies" },
    { text = "A man who has seen much and travelled far enjoys even his sufferings after a time.", author = "Homer", work = "The Odyssey", quip = "every survivor, around day 100" },
    { text = "It is tedious to tell again tales already plainly told.", author = "Homer", work = "The Odyssey", quip = "Odysseus, declining the recap" },
}

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
