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
