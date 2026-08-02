-- Echoes: registry and skill core.
-- Forked from Musicians of the Wasteland (workshop 3301008514, open-use license),
-- reworked for 42.20 and the RFTD family. Instruments, skills and songs are all
-- plain data registered here; the machinery never needs to know a new entry was
-- added. Skills are 3-level and live in player modData ("EC_Skill<type>") on
-- purpose - nine vanilla perks would flood the skill panel for what is a flavor
-- system.
--
-- 42.20 note: TraitFactory is gone. Traits register through the script registry
-- (CharacterTrait.register + CharacterTraitDefinition.addCharacterTraitDefinition),
-- which throws on duplicates and never resets during a session, hence the
-- one-shot guard around boot registration.

ECCore = ECCore or {}
ECCore.allSongsByName = {}
ECCore.allSongsArray = {}
ECCore.findableSongsArray = {}
ECCore.songsByInstrument = {}
ECCore.groupSongsByInstrument = {}
ECCore.instrumentLookup = {}
ECCore.instrumentSkill = {}
ECCore.instrumentAnimation = {}
ECCore.instrumentIsWorldItem = {}
ECCore.instrumentWorldOffset = {}
ECCore.instrumentLoudness = {}
ECCore.skillLookup = {}
ECCore.playingSongsAnimations = {}

ECCore.MAX_SKILL_LEVEL = 3
ECCore.XP_PER_LEVEL = {
    [1] = 400,
    [2] = 1000,
}

-- Set once registerTrait has run; the CharacterTrait object is what
-- hasTrait() wants in 42.20 - strings no longer work.
ECCore.SavantTrait = nil
local traitRegistered = false

function ECCore.registerTrait()
    if traitRegistered then return end
    traitRegistered = true
    ECCore.SavantTrait = CharacterTrait.register("echoes:musicalsavant")
    -- Constructor getText()s the keys eagerly and derives the icon from the
    -- registry path: media/ui/Traits/trait_musicalsavant.png.
    CharacterTraitDefinition.addCharacterTraitDefinition(
        ECCore.SavantTrait, "UI_trait_ECMusicalSavant", 3,
        "UI_trait_ECMusicalSavantDesc", false, false)
end

Events.OnGameBoot.Add(ECCore.registerTrait)

function ECCore:isSavant(playerObj)
    return self.SavantTrait ~= nil and playerObj:hasTrait(self.SavantTrait)
end

function ECCore:registerSkill(skillDef)
    self.skillLookup[skillDef.skillType] = skillDef.skillName
    for _, instrumentType in ipairs(skillDef.instrumentTypes) do
        self.instrumentSkill[instrumentType] = skillDef.skillType
    end
end

function ECCore:registerInstrument(instrumentDef)
    self.instrumentLookup[instrumentDef.fullType] = instrumentDef.instrumentType
    self.instrumentAnimation[instrumentDef.fullType] = instrumentDef.animation
    self.instrumentIsWorldItem[instrumentDef.fullType] = instrumentDef.isWorldInstrument or false
    self.instrumentWorldOffset[instrumentDef.fullType] = instrumentDef.worldOffset or {x=0, y=0, z=0, r=0}
    -- Loudness scales the zombie lure radius; 1.0 is "acoustic guitar".
    self.instrumentLoudness[instrumentDef.fullType] = instrumentDef.loudness or 1.0
    self.playingSongsAnimations[instrumentDef.animation] = true
end

function ECCore:registerSong(songInput)
    local song = songInput
    song.type = "single"
    song.difficulty = song.difficulty or 1
    song.notFindable = song.notFindable or false
    self.allSongsByName[song.name] = song
    table.insert(self.allSongsArray, song)
    if not song.notFindable then
        table.insert(self.findableSongsArray, song)
    end
    self.songsByInstrument[song.instrumentType] = self.songsByInstrument[song.instrumentType] or {}
    table.insert(self.songsByInstrument[song.instrumentType], song)
end

function ECCore:registerGroupSong(songInput)
    local song = songInput
    song.type = "group"
    song.difficulty = song.difficulty or 1
    song.notFindable = song.notFindable or false
    self.allSongsByName[song.name] = song
    table.insert(self.allSongsArray, song)
    if not song.notFindable then
        table.insert(self.findableSongsArray, song)
    end
    local uniqueInstruments = {}
    for _, instrumentType in ipairs(song.instrumentTypes) do
        uniqueInstruments[instrumentType] = true
    end
    for instrumentType, _ in pairs(uniqueInstruments) do
        self.groupSongsByInstrument[instrumentType] = self.groupSongsByInstrument[instrumentType] or {}
        table.insert(self.groupSongsByInstrument[instrumentType], song)
    end
end

function ECCore:isPlayingSongsAnimation(animation)
    return self.playingSongsAnimations[animation]
end

function ECCore:getInstrumentType(fullType)
    return self.instrumentLookup[fullType]
end

function ECCore:isWorldInstrument(fullType)
    return self.instrumentIsWorldItem[fullType]
end

function ECCore:getWorldOffset(fullType)
    return self.instrumentWorldOffset[fullType]
end

function ECCore:getInstrumentLoudness(fullType)
    return self.instrumentLoudness[fullType] or 1.0
end

function ECCore:getInstrumentSkill(instrumentType)
    return self.instrumentSkill[instrumentType]
end

function ECCore:getInstrumentAnimation(fullType)
    return self.instrumentAnimation[fullType]
end

function ECCore:getSkillName(skillType)
    return self.skillLookup[skillType]
end

function ECCore:getAllSkillTypes()
    local skillTypes = {}
    for skillType, _ in pairs(self.skillLookup) do
        table.insert(skillTypes, skillType)
    end
    return skillTypes
end

function ECCore:getSong(songName)
    return self.allSongsByName[songName]
end

function ECCore:getRandomSong()
    local idx = ZombRand(#self.allSongsArray) + 1
    return self.allSongsArray[idx] or self.allSongsArray[1]
end

function ECCore:getRandomFindableSong()
    if #self.findableSongsArray > 0 then
        local idx = ZombRand(#self.findableSongsArray) + 1
        return self.findableSongsArray[idx] or self.findableSongsArray[1]
    else
        return self:getRandomSong()
    end
end

function ECCore:getSongsForInstrument(instrumentType)
    local bySkill = {
        [1] = {},
        [2] = {},
        [3] = {},
    }
    if self.songsByInstrument[instrumentType] then
        for _, song in ipairs(self.songsByInstrument[instrumentType]) do
            table.insert(bySkill[song.difficulty], song)
        end
    end
    return bySkill
end

function ECCore:getGroupSongsForInstrument(instrumentType)
    local bySkill = {
        [1] = {},
        [2] = {},
        [3] = {},
    }
    if self.groupSongsByInstrument[instrumentType] then
        for _, song in ipairs(self.groupSongsByInstrument[instrumentType]) do
            table.insert(bySkill[song.difficulty], song)
        end
    end
    return bySkill
end

function ECCore:isSongKnown(playerObj, song)
    return song.isKnown or playerObj:getModData()["EC_Learned:" .. song.name] == true
end

function ECCore:getAllKnownSongs(playerObj)
    local knownSongs = {}
    for _, song in ipairs(self.allSongsArray) do
        if self:isSongKnown(playerObj, song) then
            if song.type == "single" then
                knownSongs[song.instrumentType] = knownSongs[song.instrumentType] or {}
                knownSongs[song.instrumentType][song.difficulty] = knownSongs[song.instrumentType][song.difficulty] or {}
                table.insert(knownSongs[song.instrumentType][song.difficulty], song)
            else
                knownSongs["Group"] = knownSongs["Group"] or {}
                knownSongs["Group"][song.difficulty] = knownSongs["Group"][song.difficulty] or {}
                table.insert(knownSongs["Group"][song.difficulty], song)
            end
        end
    end
    return knownSongs
end

function ECCore:getAllSongs()
    local copy = {}
    for _, song in ipairs(self.allSongsArray) do
        table.insert(copy, song)
    end
    return copy
end

function ECCore:getPlayerSkill(playerObj, skillType)
    return playerObj:getModData()["EC_Skill" .. skillType] or 1
end

function ECCore:setPlayerSkill(playerObj, skillType, skillLevel)
    playerObj:getModData()["EC_Skill" .. skillType] = skillLevel
end

function ECCore:getPlayerXp(playerObj, skillType)
    return playerObj:getModData()["EC_SkillXp" .. skillType] or 0
end

function ECCore:givePlayerXp(playerObj, skillType, xp)
    local currentLevel = self:getPlayerSkill(playerObj, skillType)
    if currentLevel >= self.MAX_SKILL_LEVEL then
        return
    end
    xp = SandboxVars.RFTDEchoes.XpModifier * xp
    if self:isSavant(playerObj) then
        xp = xp * 2
    end
    local currentXp = playerObj:getModData()["EC_SkillXp" .. skillType] or 0
    local newXp = currentXp + xp
    if newXp >= self.XP_PER_LEVEL[currentLevel] then
        self:setPlayerSkill(playerObj, skillType, currentLevel + 1)
        newXp = newXp - self.XP_PER_LEVEL[currentLevel]
        if currentLevel + 1 >= self.MAX_SKILL_LEVEL then
            newXp = 0
        end
    end
    playerObj:getModData()["EC_SkillXp" .. skillType] = newXp
end

function ECCore:learnSong(playerObj, song)
    playerObj:getModData()["EC_Learned:" .. song.name] = true
end

function ECCore:getLearnSongIssue(playerObj, songName, instrumentType)
    if not songName then
        return "ERROR"
    end

    local song = self.allSongsByName[songName]
    if not song then
        return "ERROR"
    end

    if self:isSongKnown(playerObj, song) then
        return "IGUI_EC_AlreadyKnown"
    end

    local skillType = self:getInstrumentSkill(instrumentType)
    local skillLevel = self:getPlayerSkill(playerObj, skillType)
    if skillLevel < song.difficulty then
        return "IGUI_EC_SkillTooLow"
    end

    return nil
end

function ECCore:getPlaySongIssue(playerObj, song, instrumentType)
    if playerObj:getAccessLevel() ~= "None" then
        return nil
    end
    if not self:isSongKnown(playerObj, song) then
        return "IGUI_EC_UnknownSong"
    end
    local skillType = self:getInstrumentSkill(instrumentType)
    local skillLevel = self:getPlayerSkill(playerObj, skillType)
    if skillLevel < song.difficulty then
        return "IGUI_EC_SkillTooLow"
    end
    return nil
end
