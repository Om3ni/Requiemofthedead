-- MMServer.lua - Memoir authority (RFTD convention: <Px>Server single dispatcher).
-- The server is the ONLY place mutation happens. The client proposes; the server
-- validates and disposes. Snapshot lives in the JOURNAL ITEM's modData, so the book
-- physically carries the save (and can be lost/stolen - hence the identity gate).
--
-- Flow:
--   WRITE_REQUEST -> stamp the character's life-id, capture live char into item modData,
--                    stamp owner.
--   READ_REQUEST  -> stale wipe-epoch: REFUSE, not consumed (voided books "fade";
--                    the owner writes over the book for a fresh snapshot).
--                    same life that wrote it: REFUSE, not consumed (nothing to recall -
--                    and the additive XP model would double-count its own history).
--                    already recalled this life: REFUSE, not consumed (one recall per
--                    life; a second book from the same dead life would double-count).
--                    otherwise: OVERWRITE the character from the memoir (source of
--                    truth; this life's earnings add on top), then CONSUME (-> notebook)
--                    and stamp the life as recalled.
--                    Legacy pre-v4 books (no life-id) bridge via the old identity
--                    compare: match = non-additive top-up, mismatch = overwrite.
--   DUMP          -> debug dump of authoritative state.

if not isServer() then return end

require "MMSvShared"
require "MMSnapshotCodec"

MMServer = MMServer or {}

-- ========================
-- Journal modData helpers (the book carries the snapshot)
-- ========================
local function getSnap(item) return item and item:getModData()["MM"] or nil end
local function setSnap(item, snap) item:getModData()["MM"] = snap end

local function findItem(player, itemID)
    return player:getInventory():getItemWithIDRecursiv(itemID)
end

-- A memoir is SINGLE-USE: on read we consume it and hand back a plain notebook (the recipe's
-- primary input), so the player crafts a fresh one to save again - clearer than the old
-- empty-and-rename reuse, which players found confusing. Uses the canonical DFInventory
-- add/remove sync (Remove + sendRemoveItemFromContainer, AddItem + sendAddItemToContainer)
-- against the item's OWN container, so the swap lands where the book was and reaches the
-- owning client. Returns the new notebook (or nil).
local function consumeAndReplace(player, item)
    local inv = player:getInventory()
    local container = inv
    pcall(function() container = item:getContainer() or inv end)
    pcall(function() container:Remove(item) end)
    pcall(function() sendRemoveItemFromContainer(container, item) end)
    local nb
    pcall(function() nb = container:AddItem("Base.Notebook") end)
    if nb then pcall(function() sendAddItemToContainer(container, nb) end) end
    MMlog("consumed memoir -> Base.Notebook for " .. MMname(player) .. " (notebook=" .. tostring(nb ~= nil) .. ")")
    return nb
end

-- applyData (optional) = { snap, chosen } so the owning client can MIRROR-apply the
-- same change locally (dual-apply: no reliable Lua server->client XP push).
local function reply(player, ok, reason, say, applyData)
    sendServerCommand(player, MMShared.MODULE, MMShared.CMD.RESULT,
        { ok = ok, reason = reason, say = say, applyData = applyData })
end

-- ========================
-- Identity ownership gate (steamID/username) - kept; matters more now (read rebuilds you)
-- ========================
local function ownerMatches(player, snap)
    if not snap.owner then return true end
    local uname = player:getUsername()
    if snap.owner.username and uname and snap.owner.username ~= uname then return false end
    local sid = player.getSteamID and player:getSteamID() or 0
    if snap.owner.steamID and snap.owner.steamID ~= 0 and sid ~= 0 and snap.owner.steamID ~= sid then return false end
    return true
end

-- ========================
-- WRITE
-- ========================
function MMServer.onWrite(player, args)
    local item = findItem(player, args.itemID)
    if not item then
        -- Not silent: the server only searches the PLAYER's inventory, so a memoir
        -- lying in a crate/car "writes" as a no-op - without this message the player
        -- walks away believing the save landed (the faded-ink ticket generator).
        if MMAudit then MMAudit.log(player, "WRITE_NOITEM", { itemId = args.itemID }) end
        return reply(player, false, "noitem",
            "I need to be carrying the memoir to write in it.")
    end

    local existing = getSnap(item)
    if existing and not ownerMatches(player, existing) then
        MMlog("WRITE denied - owner mismatch for " .. MMname(player))
        if MMAudit then MMAudit.log(player, "WRITE_OWNER", { itemId = args.itemID }) end
        return reply(player, false, "owner", "This memoir is bound to another character.")
    end

    -- LIFE-ID: stamp this character's life once (death wipes player modData, so a
    -- respawn never carries it) and let capture() bake it into the snapshot. On read,
    -- a matching id = the life that wrote the book is reading it -> refused there.
    local md = player:getModData()
    if md and not md.MMLifeId then
        md.MMLifeId = tostring(getTimestamp and getTimestamp() or 0) .. "-" .. tostring(ZombRand(100000000))
        if player.transmitModData then pcall(function() player:transmitModData() end) end
    end

    local snap = MMSnapshotCodec.capture(player)
    snap.owner = {
        username = player:getUsername(),
        steamID = (player.getSteamID and player:getSteamID()) or 0,
    }
    -- WRITE TIMESTAMPS (optional fields, no schema bump - readers treat nil as
    -- "pre-audit book"): writtenAt = this write; firstWrittenAt carries over from the
    -- previous snapshot, because a re-write is the same physical book.
    snap.writtenAt = (getTimestamp and getTimestamp()) or 0
    snap.firstWrittenAt = (existing and existing.firstWrittenAt) or snap.writtenAt
    setSnap(item, snap)
    item:setName("Memoirs of " .. tostring(player:getDisplayName()))
    if sendItemStats then sendItemStats(item) end
    syncItemModData(player, item)
    MMlog("WRITE stored snapshot into item#" .. tostring(args.itemID) .. " for " .. MMname(player))
    if MMAudit then MMAudit.log(player, "WRITE", {
        itemId = args.itemID,
        first  = (snap.firstWrittenAt == snap.writtenAt),
        lifeId = snap.lifeId,
        snap   = snap,
    }) end
    reply(player, true, nil, "Recorded in the memoir.")
end

-- ========================
-- READ
-- ========================
function MMServer.onRead(player, args)
    local item = findItem(player, args.itemID)
    if not item then
        -- Same visibility rule as the write path: never a silent no-op.
        if MMAudit then MMAudit.log(player, "READ_NOITEM", { itemId = args.itemID }) end
        return reply(player, false, "noitem",
            "I need to be carrying the memoir to read it.")
    end
    local snap = getSnap(item)
    if not snap then
        if MMAudit then MMAudit.log(player, "READ_EMPTY", { itemId = args.itemID }) end
        return reply(player, false, "empty", "Nothing has been recorded in this memoir yet.")
    end
    if not ownerMatches(player, snap) then
        MMlog("READ denied - owner mismatch for " .. MMname(player))
        if MMAudit then MMAudit.log(player, "READ_OWNER", { itemId = args.itemID,
            bookOwner = snap.owner and snap.owner.username }) end
        return reply(player, false, "owner", "This memoir is bound to another character.")
    end

    -- WIPE-EPOCH GATE: a book stamped with an older epoch (or none - every pre-epoch
    -- book) is void. Refuse WITHOUT consuming: the owner writes over the same book
    -- for a fresh snapshot. Bump MMShared.WIPE_EPOCH to retire all outstanding books.
    if (snap.epoch or 0) < MMShared.WIPE_EPOCH then
        MMlog("READ refused - stale epoch " .. tostring(snap.epoch or 0) .. " < "
            .. tostring(MMShared.WIPE_EPOCH) .. " for " .. MMname(player))
        -- writtenAt tells amnesty-wave fades (nil: pre-audit book) apart from a
        -- post-update book that somehow lost its epoch - the open "faded" question.
        if MMAudit then MMAudit.log(player, "READ_FADED", { itemId = args.itemID,
            bookEpoch = snap.epoch or 0, serverEpoch = MMShared.WIPE_EPOCH,
            writtenAt = snap.writtenAt }) end
        return reply(player, false, "faded",
            "The ink has faded beyond reading... I should write these memoirs anew.")
    end

    -- SAME-LIFE GUARD: the life that wrote the book gets refused (and keeps the book) -
    -- there is nothing to recall, and the additive XP model would double-count the
    -- book's own history. Death wipes player modData, so a respawn never matches.
    local md = player:getModData()
    if snap.lifeId and md and md.MMLifeId == snap.lifeId then
        MMlog("READ refused - same life for " .. MMname(player))
        if MMAudit then MMAudit.log(player, "READ_SAMELIFE", { itemId = args.itemID,
            lifeId = snap.lifeId }) end
        return reply(player, false, "samelife",
            "I remember writing this... there is nothing here to recall.")
    end

    -- ONE RECALL PER LIFE: each life gets a single read; death re-arms it. The
    -- "eligible" flag is the death-wipe itself - player modData dies with the
    -- character, so a fresh spawn has no MMRecalled and may read; a successful read
    -- stamps it (below) and every later read this life is refused, book kept.
    -- Without this gate, two memoirs written by the same DEAD life pass the
    -- same-life guard back-to-back, and the second read classifies everything the
    -- first read restored as "this life's earnings" - doubling every kill and XP
    -- point the books share (the additive model; see the codec header).
    if md and md.MMRecalled then
        MMlog("READ refused - already recalled this life for " .. MMname(player))
        if MMAudit then MMAudit.log(player, "READ_RECALLED", { itemId = args.itemID }) end
        return reply(player, false, "recalled",
            "My mind is still settling from the last recall... I cannot take in another in this life.")
    end

    -- Decide the apply shape. v4+ books: OVERWRITE, always - the memoir is the source
    -- of truth. Legacy books (no life-id) can't prove which life is reading them, so
    -- they bridge on the old identity compare: match -> non-additive top-up (could be
    -- the same life); mismatch -> overwrite, with the diff warned for forensics.
    local chosen, xpMode
    if snap.lifeId then
        chosen, xpMode = { profession = snap.profession, traits = snap.traits }, "overwrite"
    else
        local matches, reason, detail = MMSnapshotCodec.identityMatches(player, snap)
        if matches then
            chosen, xpMode = nil, "max"
        else
            chosen, xpMode = { profession = snap.profession, traits = snap.traits }, "overwrite"
            local function joinList(t) return (t and #t > 0) and table.concat(t, ", ") or "(none)" end
            MMwarn("READ legacy-bridge overwrite (" .. tostring(reason) .. ") for " .. MMname(player)
                .. " | profession snap=" .. tostring(snap.profession) .. " cur=" .. tostring(detail.curProfession)
                .. " | snapshot-only traits: " .. joinList(detail.snapOnly)
                .. " | current-only traits: " .. joinList(detail.curOnly))
        end
    end

    -- pcall-armored: a server-side failure must deny loudly and keep the memoir -
    -- never a silent no-op. The codec apply is idempotent, so retrying is safe.
    local preLevels = MMAudit and MMAudit.perkLevels(player) or nil
    local okApply, err = pcall(function() MMSnapshotCodec.applyToCharacter(player, snap, chosen, xpMode) end)
    if not okApply then
        MMwarn("READ apply FAILED (xpMode=" .. tostring(xpMode) .. ") for " .. MMname(player) .. ": " .. tostring(err))
        if MMAudit then MMAudit.log(player, "READ_APPLYFAIL", { itemId = args.itemID,
            xpMode = xpMode, err = tostring(err) }) end
        return reply(player, false, "applyfail",
            "The pages blur... (recall failed, the memoir was not consumed - please tell an admin)")
    end
    -- Spend this life's single recall (see the gate above). Stamped only after a
    -- successful apply - a failed apply must leave the player eligible to retry.
    -- pushFields' transmitModData carries it to the client with the rest.
    if md then md.MMRecalled = true end
    consumeAndReplace(player, item)
    MMServer.pushFields(player)
    MMlog("READ applied (xpMode=" .. tostring(xpMode) .. ") + consumed item#" .. tostring(args.itemID))
    if MMAudit then
        local now = (getTimestamp and getTimestamp()) or 0
        MMAudit.log(player, "READ_OK", {
            itemId  = args.itemID,
            xpMode  = xpMode,
            legacy  = (snap.lifeId == nil),
            -- bookAge only for books that carry writtenAt (post-audit writes)
            bookAgeS = snap.writtenAt and (now - snap.writtenAt) or nil,
            -- before/after proof: levels for the pipe timeline's compact diff,
            -- full per-perk XP for the schema - the OUTCOME of the recall is on
            -- record, not just the book (progression sheet + hand-fix material)
            lvlsBefore = preLevels,
            lvlsAfter  = MMAudit.perkLevels(player),
            postXP     = MMAudit.perkXP(player),
            -- the exact snapshot that was applied - pre-audit books never logged a
            -- WRITE, so the read is the only place their contents get on record
            snap = snap,
        })
        -- ~2 min later a READ_RECHECK record reports per-perk XP drift vs this
        -- moment - the only server-side window into the client mirror-apply
        -- (big positive drift = double-add, big negative = mirror failed).
        MMAudit.scheduleRecheck(player, args.itemID)
    end
    reply(player, true, nil, "Character recalled.", { snap = snap, chosen = chosen, xpMode = xpMode })
end

-- ========================
-- Sync helper: XP/traits reach the client via its mirror-apply (no Lua server->client
-- XP push); recipes need the field sync. Mirror-apply is driven by the client on the
-- RESULT it gets. Here we nudge recipe fields.
-- ========================
function MMServer.pushFields(player)
    if sendSyncPlayerFields then sendSyncPlayerFields(player, 0x00000001) end
    -- Faith lives in player modData (ParanormalZ exorcistFaith), so a restored value must be
    -- pushed to the client the same way ParanormalZ itself does. No-op when modData is unchanged.
    if player.transmitModData then pcall(function() player:transmitModData() end) end
end

-- ========================
-- DUMP (debug)
-- ========================
function MMServer.onDump(player, args)
    local item = findItem(player, args.itemID)
    MMlog("==== SERVER DUMP item#" .. tostring(args.itemID) .. " player=" .. MMname(player) .. " ====")
    if item then
        local snap = getSnap(item)
        if snap then
            MMlog("  profession=" .. tostring(snap.profession) .. " owner=" .. tostring(snap.owner and snap.owner.username)
                .. " faith=" .. tostring(snap.faith) .. " lifeId=" .. tostring(snap.lifeId)
                .. " epoch=" .. tostring(snap.epoch or 0) .. "/" .. tostring(MMShared.WIPE_EPOCH)
                .. " (reader lifeId=" .. tostring(player:getModData() and player:getModData().MMLifeId) .. ")")
            MMlogTable("  perks", snap.perks)
            MMlogTable("  traits", snap.traits)
            MMlogTable("  kills", snap.kills)
            MMlogTable("  nutrition", snap.nutrition)
        else
            MMlog("  item has no snapshot (empty)")
        end
    else
        MMlog("  item not found")
    end
end

-- ========================
-- Dispatcher
-- ========================
local function onClientCommand(module, command, player, args)
    if module ~= MMShared.MODULE then return end
    if command == MMShared.CMD.WRITE_REQUEST then MMServer.onWrite(player, args)
    elseif command == MMShared.CMD.READ_REQUEST then MMServer.onRead(player, args)
    elseif command == MMShared.CMD.DUMP then MMServer.onDump(player, args)
    end
end
Events.OnClientCommand.Add(onClientCommand)

MMlog("MMServer dispatcher registered")
