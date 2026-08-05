-- SPDX-License-Identifier: GPL-3.0-or-later
-- BMQuoteLoader.lua - Bookmark: assembles every quote chunk into one flat pool.
--
-- Each BMQuotes_<Work>.lua under this folder is a leaf data file: it only
-- appends its own entries to Bookmark.QuoteChunks.<Slug> and requires nothing.
-- This file is the one place that knows the full chunk list, and the one place
-- that flattens chunks into Bookmark.Quotes (the array BMClient draws from).
--
-- Requiring every chunk explicitly below - rather than trusting the filesystem
-- walk that auto-loads every .lua under lua/client/ - is deliberate: this
-- filename sorts alphabetically BEFORE "BMQuotes_*" (capital L 0x4C < lowercase
-- s 0x73), the same class of landmine OEShared.lua's header documents for the
-- shared/ tier. Off walk order, this merge would run before a single quote
-- chunk had loaded, and Bookmark.Quotes would come out empty.
--
-- PIPELINE NOTE: a new BMQuotes_<Work>.lua needs exactly one addition here (its
-- require line, alphabetised) to enter rotation. Nothing else in this file
-- changes shape as quotes are added.

if isServer() then return end

require "Bookmark/BMQuotes_Aesop"
require "Bookmark/BMQuotes_AliceInWonderland"
require "Bookmark/BMQuotes_AnneOfGreenGables"
require "Bookmark/BMQuotes_GulliversTravels"
require "Bookmark/BMQuotes_Odyssey"
require "Bookmark/BMQuotes_PeterPan"
require "Bookmark/BMQuotes_SherlockHolmes"
require "Bookmark/BMQuotes_ThreeMenInABoat"
require "Bookmark/BMQuotes_TreasureIsland"
require "Bookmark/BMQuotes_Twain"
require "Bookmark/BMQuotes_Verne"
require "Bookmark/BMQuotes_WindInTheWillows"
require "Bookmark/BMQuotes_WizardOfOz"
require "Bookmark/BMQuotes_Wodehouse"

Bookmark = Bookmark or {}
Bookmark.QuoteChunks = Bookmark.QuoteChunks or {}

if not Bookmark.Quotes then
    local flat = {}
    for _, chunk in pairs(Bookmark.QuoteChunks) do
        for _, entry in ipairs(chunk) do
            flat[#flat + 1] = entry
        end
    end
    Bookmark.Quotes = flat
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
