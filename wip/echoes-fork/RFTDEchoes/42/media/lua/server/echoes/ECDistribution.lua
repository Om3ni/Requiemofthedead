-- Echoes: loot distribution. Sheet music seeds wherever printed matter or
-- instruments live; the drum kit hides in music stores and the odd closet.
-- One category moved in 42: BedroomSideTable no longer exists, its slot went
-- to SideTableJunk at the same weight.

require 'Items/ProceduralDistributions'

local function addItemToDist(category, item, chance)
    if not ProceduralDistributions.list[category] then
        print("RFTDEchoes: Distribution category not found: " .. category)
        return
    end
    table.insert(ProceduralDistributions.list[category].items, item)
    table.insert(ProceduralDistributions.list[category].items, chance)
end

local function addJunkToDist(category, item, chance)
    if not ProceduralDistributions.list[category] then
        print("RFTDEchoes: Distribution category not found: " .. category)
        return
    end
    table.insert(ProceduralDistributions.list[category].junk.items, item)
    table.insert(ProceduralDistributions.list[category].junk.items, chance)
end

addItemToDist("BandPracticeClothing", "RFTDEchoes.SheetMusic", 1)
addItemToDist("BandPracticeInstruments", "RFTDEchoes.SheetMusic", 5)
addItemToDist("SideTableJunk", "RFTDEchoes.SheetMusic", 0.1)
addItemToDist("BookstoreBooks", "RFTDEchoes.SheetMusic", 1)
addItemToDist("BookstoreMisc", "RFTDEchoes.SheetMusic", 1)
addItemToDist("ClassroomDesk", "RFTDEchoes.SheetMusic", 0.2)
addItemToDist("ClassroomMisc", "RFTDEchoes.SheetMusic", 0.1)
addItemToDist("ClassroomShelves", "RFTDEchoes.SheetMusic", 0.1)
addItemToDist("ClosetInstruments", "RFTDEchoes.SheetMusic", 4)
addItemToDist("CrateInstruments", "RFTDEchoes.SheetMusic", 2)
addItemToDist("CrateRandomJunk", "RFTDEchoes.SheetMusic", 0.1)
addItemToDist("Hobbies", "RFTDEchoes.SheetMusic", 0.1)
addItemToDist("LibraryBooks", "RFTDEchoes.SheetMusic", 1)
addItemToDist("MagazineRackMixed", "RFTDEchoes.SheetMusic", 0.1)
addItemToDist("MusicStoreOthers", "RFTDEchoes.SheetMusic", 5)
addJunkToDist("MusicStoreOthers", "RFTDEchoes.SheetMusic", 5)
addItemToDist("OfficeDrawers", "RFTDEchoes.SheetMusic", 1)
addItemToDist("PostOfficeBooks", "RFTDEchoes.SheetMusic", 2)
addItemToDist("PostOfficeMagazines", "RFTDEchoes.SheetMusic", 2)
addItemToDist("PrisonCellRandom", "RFTDEchoes.SheetMusic", 2)
addItemToDist("RandomFiller", "RFTDEchoes.SheetMusic", 0.1)
addItemToDist("SchoolLockers", "RFTDEchoes.SheetMusic", 1)
addItemToDist("ShelfGeneric", "RFTDEchoes.SheetMusic", 0.2)

addItemToDist("ClosetInstruments", "RFTDEchoes.DrumKit", 2)
addItemToDist("CrateInstruments", "RFTDEchoes.DrumKit", 2)
addItemToDist("CrateRandomJunk", "RFTDEchoes.DrumKit", 0.2)
addItemToDist("MusicStoreOthers", "RFTDEchoes.DrumKit", 3)
addItemToDist("WardrobeChild", "RFTDEchoes.DrumKit", 0.01)
