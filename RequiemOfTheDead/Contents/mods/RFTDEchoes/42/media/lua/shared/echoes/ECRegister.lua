require "echoes/ECCore"

ECCore:registerSkill({
    skillType = "Guitar",
    skillName = "IGUI_EC_SkillGuitar",
    instrumentTypes = {"GuitarAcoustic", "GuitarElectric"},
})

ECCore:registerSkill({
    skillType = "Banjo",
    skillName = "IGUI_EC_SkillBanjo",
    instrumentTypes = {"Banjo"},
})

ECCore:registerSkill({
    skillType = "GuitarBass",
    skillName = "IGUI_EC_SkillGuitarBass",
    instrumentTypes = {"GuitarElectricBass"},
})

ECCore:registerSkill({
    skillType = "Synthesizer",
    skillName = "IGUI_EC_SkillSynthesizer",
    instrumentTypes = {"Synthesizer"},
})

ECCore:registerSkill({
    skillType = "Flute",
    skillName = "IGUI_EC_SkillFlute",
    instrumentTypes = {"Flute"},
})

ECCore:registerSkill({
    skillType = "Saxophone",
    skillName = "IGUI_EC_SkillSaxophone",
    instrumentTypes = {"Saxophone"},
})

ECCore:registerSkill({
    skillType = "Trumpet",
    skillName = "IGUI_EC_SkillTrumpet",
    instrumentTypes = {"Trumpet"},
})

ECCore:registerSkill({
    skillType = "Violin",
    skillName = "IGUI_EC_SkillViolin",
    instrumentTypes = {"Violin"},
})

ECCore:registerSkill({
    skillType = "Drums",
    skillName = "IGUI_EC_SkillDrums",
    instrumentTypes = {"DrumKit"},
})

ECCore:registerInstrument({
    fullType = "Base.GuitarAcoustic",
    instrumentType = "GuitarAcoustic",
    animation = "ECPlayGuitarAcoustic",
})

ECCore:registerInstrument({
    fullType = "Base.Banjo",
    instrumentType = "Banjo",
    animation = "ECPlayGuitarAcoustic",
})

ECCore:registerInstrument({
    fullType = "Base.GuitarElectricBlack",
    instrumentType = "GuitarElectric",
    animation = "ECPlayGuitarElectric",
    loudness = 1.6,
})

ECCore:registerInstrument({
    fullType = "Base.GuitarElectricBlue",
    instrumentType = "GuitarElectric",
    animation = "ECPlayGuitarElectric",
    loudness = 1.6,
})

ECCore:registerInstrument({
    fullType = "Base.GuitarElectricRed",
    instrumentType = "GuitarElectric",
    animation = "ECPlayGuitarElectric",
    loudness = 1.6,
})

ECCore:registerInstrument({
    fullType = "Base.GuitarElectricBassBlack",
    instrumentType = "GuitarElectricBass",
    animation = "ECPlayGuitarBass",
    loudness = 1.5,
})

ECCore:registerInstrument({
    fullType = "Base.GuitarElectricBassBlue",
    instrumentType = "GuitarElectricBass",
    animation = "ECPlayGuitarBass",
    loudness = 1.5,
})

ECCore:registerInstrument({
    fullType = "Base.GuitarElectricBassRed",
    instrumentType = "GuitarElectricBass",
    animation = "ECPlayGuitarBass",
    loudness = 1.5,
})

ECCore:registerInstrument({
    fullType = "Base.Keytar",
    instrumentType = "Synthesizer",
    animation = "ECPlaySynthesizer",
    loudness = 1.3,
})

ECCore:registerInstrument({
    fullType = "Base.Flute",
    instrumentType = "Flute",
    animation = "ECPlayFlute",
    loudness = 0.7,
})

ECCore:registerInstrument({
    fullType = "Base.Saxophone",
    instrumentType = "Saxophone",
    animation = "ECPlaySaxophone",
    loudness = 1.4,
})

ECCore:registerInstrument({
    fullType = "Base.Trumpet",
    instrumentType = "Trumpet",
    animation = "ECPlayTrumpet",
    loudness = 1.5,
})

ECCore:registerInstrument({
    fullType = "Base.Violin",
    instrumentType = "Violin",
    animation = "ECPlayViolin",
    loudness = 0.9,
})

ECCore:registerInstrument({
    fullType = "RFTDEchoes.DrumKit",
    instrumentType = "DrumKit",
    animation = "ECPlayDrumKit",
    loudness = 2.0,
    isWorldInstrument = true,
    worldOffset = {
        x = 0,
        y = 0,
        z = 0,
        r = 30,
    }
})

ECCore:registerSong({
    name = "IGUI_EC_GuitarAcoustic_Dreamland",
    instrumentType = "GuitarAcoustic",
    soundFile = "EC_GuitarAcoustic_Dreamland",
    duration = 191,
    difficulty = 2,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_GuitarAcoustic_HappyTimes",
    instrumentType = "GuitarAcoustic",
    soundFile = "EC_GuitarAcoustic_HappyTimes",
    duration = 115,
    difficulty = 1,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_GuitarAcoustic_ConiferousForest",
    instrumentType = "GuitarAcoustic",
    soundFile = "EC_GuitarAcoustic_ConiferousForest",
    duration = 129,
    difficulty = 1,
    isKnown = true,
})

ECCore:registerSong({
    name = "IGUI_EC_GuitarAcoustic_Diabelli",
    instrumentType = "GuitarAcoustic",
    soundFile = "EC_GuitarAcoustic_Diabelli",
    duration = 40,
    difficulty = 2,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_GuitarAcoustic_FoliaByVivaldi",
    instrumentType = "GuitarAcoustic",
    soundFile = "EC_GuitarAcoustic_FoliaByVivaldi",
    duration = 522,
    difficulty = 3,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_GuitarAcoustic_FurEliseByBeethoven",
    instrumentType = "GuitarAcoustic",
    soundFile = "EC_GuitarAcoustic_FurEliseByBeethoven",
    duration = 67,
    difficulty = 1,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_GuitarAcoustic_Opus4No8ByVivaldi",
    instrumentType = "GuitarAcoustic",
    soundFile = "EC_GuitarAcoustic_Opus4No8ByVivaldi",
    duration = 215,
    difficulty = 3,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_GuitarAcoustic_SipOfCoffee",
    instrumentType = "GuitarAcoustic",
    soundFile = "EC_GuitarAcoustic_SipOfCoffee",
    duration = 38,
    difficulty = 1,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_GuitarAcoustic_SmoothClassical",
    instrumentType = "GuitarAcoustic",
    soundFile = "EC_GuitarAcoustic_SmoothClassical",
    duration = 100,
    difficulty = 3,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_GuitarAcoustic_Springtime",
    instrumentType = "GuitarAcoustic",
    soundFile = "EC_GuitarAcoustic_Springtime",
    duration = 141,
    difficulty = 1,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_GuitarAcoustic_TangoByTerrega",
    instrumentType = "GuitarAcoustic",
    soundFile = "EC_GuitarAcoustic_TangoByTerrega",
    duration = 104,
    difficulty = 2,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_GuitarAcoustic_ThinkingOfHome",
    instrumentType = "GuitarAcoustic",
    soundFile = "EC_GuitarAcoustic_ThinkingOfHome",
    duration = 82,
    difficulty = 3,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_GuitarAcoustic_TripToHome",
    instrumentType = "GuitarAcoustic",
    soundFile = "EC_GuitarAcoustic_TripToHome",
    duration = 148,
    difficulty = 2,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_GuitarAcoustic_WhereThePathsGo",
    instrumentType = "GuitarElectric",
    soundFile = "EC_GuitarAcoustic_WhereThePathsGo",
    duration = 375,
    difficulty = 1,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_GuitarElectric_AVilliansRedemption",
    instrumentType = "GuitarElectric",
    soundFile = "EC_GuitarElectric_AVilliansRedemption",
    duration = 116,
    difficulty = 1,
    isKnown = true,
})

ECCore:registerSong({
    name = "IGUI_EC_GuitarElectric_ChristmasMedley",
    instrumentType = "GuitarElectric",
    soundFile = "EC_GuitarElectric_ChristmasMedley",
    duration = 331,
    difficulty = 3,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_GuitarElectric_Echos",
    instrumentType = "GuitarElectric",
    soundFile = "EC_GuitarElectric_Echos",
    duration = 113,
    difficulty = 2,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_GuitarElectric_JungleRumble",
    instrumentType = "GuitarElectric",
    soundFile = "EC_GuitarElectric_JungleRumble",
    duration = 34,
    difficulty = 2,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_GuitarElectric_SlowBlues",
    instrumentType = "GuitarElectric",
    soundFile = "EC_GuitarElectric_SlowBlues",
    duration = 84,
    difficulty = 2,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_GuitarElectric_StonedHippy",
    instrumentType = "GuitarElectric",
    soundFile = "EC_GuitarElectric_StonedHippy",
    duration = 25,
    difficulty = 1,
    isKnown = false,
})


ECCore:registerSong({
    name = "IGUI_EC_GuitarElectricBass_CowboyBassLine",
    instrumentType = "GuitarElectricBass",
    soundFile = "EC_GuitarElectricBass_CowboyBassLine",
    duration = 75,
    difficulty = 1,
    isKnown = true,
})

ECCore:registerSong({
    name = "IGUI_EC_GuitarElectricBass_RockBassLine",
    instrumentType = "GuitarElectricBass",
    soundFile = "EC_GuitarElectricBass_RockBassLine",
    duration = 68,
    difficulty = 2,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_GuitarElectricBass_UptownFunk",
    instrumentType = "GuitarElectricBass",
    soundFile = "EC_GuitarElectricBass_UptownFunk",
    duration = 148,
    difficulty = 3,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_GuitarElectricBass_TheDeepSorrow",
    instrumentType = "GuitarElectricBass",
    soundFile = "EC_GuitarElectricBass_TheDeepSorrow",
    duration = 168,
    difficulty = 3,
    isKnown = false,
})


ECCore:registerSong({
    name = "IGUI_EC_Trumpet_JazzyPractice",
    instrumentType = "Trumpet",
    soundFile = "EC_Trumpet_JazzyPractice",
    duration = 39,
    difficulty = 1,
    isKnown = true,
})

ECCore:registerSong({
    name = "IGUI_EC_Trumpet_ILiveForNothing",
    instrumentType = "Trumpet",
    soundFile = "EC_Trumpet_ILiveForNothing",
    duration = 180,
    difficulty = 1,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_Trumpet_Taps",
    instrumentType = "Trumpet",
    soundFile = "EC_Trumpet_Taps",
    duration = 74,
    difficulty = 2,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_Trumpet_Reveille",
    instrumentType = "Trumpet",
    soundFile = "EC_Trumpet_Reveille",
    duration = 24,
    difficulty = 1,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_Trumpet_Fanfare13",
    instrumentType = "Trumpet",
    soundFile = "EC_Trumpet_Fanfare13",
    duration = 55,
    difficulty = 3,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_Trumpet_FanfareInWasteland",
    instrumentType = "Trumpet",
    soundFile = "EC_Trumpet_FanfareInWasteland",
    duration = 222,
    difficulty = 3,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_Violin_TearsAtNight",
    instrumentType = "Violin",
    soundFile = "EC_Violin_TearsAtNight",
    duration = 134,
    difficulty = 1,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_Violin_TheStreetsOfCairo",
    instrumentType = "Violin",
    soundFile = "EC_Violin_TheStreetsOfCairo",
    duration = 122,
    difficulty = 2,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_Violin_Greensleeves",
    instrumentType = "Violin",
    soundFile = "EC_Violin_Greensleeves",
    duration = 73,
    difficulty = 3,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_Violin_LaCucaracha",
    instrumentType = "Violin",
    soundFile = "EC_Violin_LaCucaracha",
    duration = 66,
    difficulty = 1,
    isKnown = true,
})

ECCore:registerSong({
    name = "IGUI_EC_Violin_Sleepy",
    instrumentType = "Violin",
    soundFile = "EC_Violin_Sleepy",
    duration = 123,
    difficulty = 2,
    isKnown = false,
})


ECCore:registerSong({
    name = "IGUI_EC_Saxophone_WalkingDirty",
    instrumentType = "Saxophone",
    soundFile = "EC_Saxophone_WalkingDirty",
    duration = 125,
    difficulty = 1,
    isKnown = true,
})

ECCore:registerSong({
    name = "IGUI_EC_Saxophone_FeelinLoving",
    instrumentType = "Saxophone",
    soundFile = "EC_Saxophone_FeelinLoving",
    duration = 49,
    difficulty = 2,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_Saxophone_InTheSheets",
    instrumentType = "Saxophone",
    soundFile = "EC_Saxophone_InTheSheets",
    duration = 84,
    difficulty = 3,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_Saxophone_Smooth",
    instrumentType = "Saxophone",
    soundFile = "EC_Saxophone_Smooth",
    duration = 65,
    difficulty = 2,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_Saxophone_HangingLose",
    instrumentType = "Saxophone",
    soundFile = "EC_Saxophone_HangingLose",
    duration = 131,
    difficulty = 1,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_Saxophone_StandByMe",
    instrumentType = "Saxophone",
    soundFile = "EC_Saxophone_StandByMe",
    duration = 122,
    difficulty = 1,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_Saxophone_AllIAsk",
    instrumentType = "Saxophone",
    soundFile = "EC_Saxophone_AllIAsk",
    duration = 270,
    difficulty = 2,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_Saxophone_CarelessWhisper",
    instrumentType = "Saxophone",
    soundFile = "EC_Saxophone_CarelessWhisper",
    duration = 79,
    difficulty = 3,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_Synthesizer_Celestial",
    instrumentType = "Synthesizer",
    soundFile = "EC_Synthesizer_Celestial",
    duration = 31,
    difficulty = 1,
    isKnown = true,
})

ECCore:registerSong({
    name = "IGUI_EC_Synthesizer_Rebel",
    instrumentType = "Synthesizer",
    soundFile = "EC_Synthesizer_Rebel",
    duration = 125,
    difficulty = 2,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_Synthesizer_NeonBass",
    instrumentType = "Synthesizer",
    soundFile = "EC_Synthesizer_NeonBass",
    duration = 176,
    difficulty = 3,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_Synthesizer_Ominous",
    instrumentType = "Synthesizer",
    soundFile = "EC_Synthesizer_Ominous",
    duration = 63,
    difficulty = 1,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_Synthesizer_OnTheEdge",
    instrumentType = "Synthesizer",
    soundFile = "EC_Synthesizer_OnTheEdge",
    duration = 77,
    difficulty = 2,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_Banjo_FingerPickinGood",
    instrumentType = "Banjo",
    soundFile = "EC_Banjo_FingerPickinGood",
    duration = 95,
    difficulty = 2,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_Banjo_DurangsHornpipe",
    instrumentType = "Banjo",
    soundFile = "EC_Banjo_DurangsHornpipe",
    duration = 167,
    difficulty = 1,
    isKnown = true,
})

ECCore:registerSong({
    name = "IGUI_EC_Banjo_TombigbeeWaltz",
    instrumentType = "Banjo",
    soundFile = "EC_Banjo_TombigbeeWaltz",
    duration = 149,
    difficulty = 1,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_Banjo_AmazingGrace",
    instrumentType = "Banjo",
    soundFile = "EC_Banjo_AmazingGrace",
    duration = 38,
    difficulty = 3,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_Banjo_GOhG",
    instrumentType = "Banjo",
    soundFile = "EC_Banjo_GOhG",
    duration = 203,
    difficulty = 3,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_Banjo_CountryPickin",
    instrumentType = "Banjo",
    soundFile = "EC_Banjo_CountryPickin",
    duration = 179,
    difficulty = 2,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_Flute_Practicing",
    instrumentType = "Flute",
    soundFile = "EC_Flute_Practicing",
    duration = 180,
    difficulty = 1,
    isKnown = true,
})

ECCore:registerSong({
    name = "IGUI_EC_Flute_HagridsFriendlyBird",
    instrumentType = "Flute",
    soundFile = "EC_Flute_HagridsFriendlyBird",
    duration = 35,
    difficulty = 3,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_Flute_WindsWhisper",
    instrumentType = "Flute",
    soundFile = "EC_Flute_WindsWhisper",
    duration = 39,
    difficulty = 2,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_Flute_MelodyOfSolitude",
    instrumentType = "Flute",
    soundFile = "EC_Flute_MelodyOfSolitude",
    duration = 101,
    difficulty = 2,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_Flute_Despacito",
    instrumentType = "Flute",
    soundFile = "EC_Flute_Despacito",
    duration = 166,
    difficulty = 2,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_Flute_BohemianRhapsody",
    instrumentType = "Flute",
    soundFile = "EC_Flute_BohemianRhapsody",
    duration = 104,
    difficulty = 3,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_Flute_HedwigsTheme",
    instrumentType = "Flute",
    soundFile = "EC_Flute_HedwigsTheme",
    duration = 40,
    difficulty = 1,
    isKnown = false,
})


ECCore:registerSong({
    name = "IGUI_EC_DrumKit_TubbersSnareSolo",
    instrumentType = "DrumKit",
    soundFile = "EC_DrumKit_TubbersSnareSolo",
    duration = 156,
    difficulty = 1,
    isKnown = true,
})

ECCore:registerSong({
    name = "IGUI_EC_DrumKit_BaDumTss",
    instrumentType = "DrumKit",
    soundFile = "EC_DrumKit_BaDumTss",
    duration = 5,
    difficulty = 1,
    isKnown = true,
})


-- group songs

ECCore:registerGroupSong({
    name = "IGUI_EC_Group_RockSong",
    instrumentTypes = {"GuitarElectric", "GuitarElectricBass", "DrumKit"},
    soundFile = "EC_Group_RockSong",
    duration = 43,
    difficulty = 1,
    isKnown = true,
})

ECCore:registerGroupSong({
    name = "IGUI_EC_Group_AllegroSonataNo5",
    instrumentTypes = {"Trumpet", "Flute"},
    soundFile = "EC_Group_AllegroSonataNo5",
    duration = 115,
    difficulty = 2,
    isKnown = true,
})

ECCore:registerGroupSong({
    name = "IGUI_EC_Group_ToTheSea",
    instrumentTypes = {"Banjo", "GuitarAcoustic"},
    soundFile = "EC_Group_ToTheSea",
    duration = 97,
    difficulty = 3,
    isKnown = false,
})

ECCore:registerGroupSong({
    name = "IGUI_EC_Group_TrumpetBeBlue",
    instrumentTypes = {"Trumpet", "GuitarElectric", "GuitarElectricBass", "DrumKit"},
    soundFile = "EC_Group_TrumpetBeBlue",
    duration = 108,
    difficulty = 2,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_GuitarAcoustic_NothingForMeHere",
    instrumentType = "GuitarAcoustic",
    soundFile = "EC_GuitarAcoustic_NothingForMeHere",
    duration = 173,
    difficulty = 1,
    isKnown = true,
})

ECCore:registerSong({
    name = "IGUI_EC_GuitarAcoustic_WhereIAm",
    instrumentType = "GuitarAcoustic",
    soundFile = "EC_GuitarAcoustic_WhereIAm",
    duration = 161,
    difficulty = 3,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_GuitarElectric_WillISeeHerAgain",
    instrumentType = "GuitarElectric",
    soundFile = "EC_GuitarElectric_WillISeeHerAgain",
    duration = 184,
    difficulty = 2,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_GuitarAcoustic_OurEncounter",
    instrumentType = "GuitarAcoustic",
    soundFile = "EC_GuitarAcoustic_OurEncounter",
    duration = 129,
    difficulty = 2,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_GuitarElectric_ComeforaRide",
    instrumentType = "GuitarElectric",
    soundFile = "EC_GuitarElectric_ComeforaRide",
    duration = 94,
    difficulty = 2,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_GuitarElectric_PickingDaisies",
    instrumentType = "GuitarElectric",
    soundFile = "EC_GuitarElectric_PickingDaisies",
    duration = 154,
    difficulty = 3,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_GuitarElectric_RunToMe",
    instrumentType = "GuitarElectric",
    soundFile = "EC_GuitarElectric_RunToMe",
    duration = 139,
    difficulty = 3,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_GuitarElectric_CantKeepUp",
    instrumentType = "GuitarElectric",
    soundFile = "EC_GuitarElectric_CantKeepUp",
    duration = 108,
    difficulty = 3,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_GuitarElectric_StrollinginKnox",
    instrumentType = "GuitarElectric",
    soundFile = "EC_GuitarElectric_StrollinginKnox",
    duration = 86,
    difficulty = 1,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_GuitarElectricBass_KeepWithMe",
    instrumentType = "GuitarElectricBass",
    soundFile = "EC_GuitarElectricBass_KeepWithMe",
    duration = 198,
    difficulty = 1,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_Violin_FindingTheLight",
    instrumentType = "Violin",
    soundFile = "EC_Violin_FindingTheLight",
    duration = 139,
    difficulty = 3,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_Violin_RestTomorrow",
    instrumentType = "Violin",
    soundFile = "EC_Violin_RestTomorrow",
    duration = 105,
    difficulty = 3,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_Trumpet_LetitHop",
    instrumentType = "Trumpet",
    soundFile = "EC_Trumpet_LetitHop",
    duration = 146,
    difficulty = 2,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_GuitarAcoustic_SpringTimeRaindrops",
    instrumentType = "GuitarAcoustic",
    soundFile = "EC_GuitarAcoustic_SpringTimeRaindrops",
    duration = 110,
    difficulty = 2,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_GuitarAcoustic_ComeSitWithMe",
    instrumentType = "GuitarAcoustic",
    soundFile = "EC_GuitarAcoustic_ComeSitWithMe",
    duration = 139,
    difficulty = 2,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_GuitarAcoustic_TippyToe-In",
    instrumentType = "GuitarAcoustic",
    soundFile = "EC_GuitarAcoustic_TippyToe-In",
    duration = 124,
    difficulty = 1,
    isKnown = false,
})

ECCore:registerSong({
    name = "IGUI_EC_GuitarElectric_RiffnAround",
    instrumentType = "GuitarElectric",
    soundFile = "EC_GuitarElectric_RiffnAround",
    duration = 159,
    difficulty = 1,
    isKnown = true,
})

ECCore:registerGroupSong({
    name = "IGUI_EC_Group_WheretheWindCame",
    instrumentTypes = {"GuitarAcoustic", "Violin"},
    soundFile = "EC_Group_WheretheWindCame",
    duration = 228,
    difficulty = 1,
    isKnown = false,
})

ECCore:registerGroupSong({
    name = "IGUI_EC_Group_SoIFlutter",
    instrumentTypes = {"GuitarAcoustic", "Flute"},
    soundFile = "EC_Group_SoIFlutter",
    duration = 173,
    difficulty = 1,
    isKnown = false,
})

ECCore:registerGroupSong({
    name = "IGUI_EC_Group_NowYouKnowLove",
    instrumentTypes = {"GuitarAcoustic", "Saxophone"},
    soundFile = "EC_Group_NowYouKnowLove",
    duration = 229,
    difficulty = 1,
    isKnown = false,
})

ECCore:registerGroupSong({
    name = "IGUI_EC_Group_LoveintheHills",
    instrumentTypes = {"GuitarAcoustic", "Banjo"},
    soundFile = "EC_Group_LoveintheHills",
    duration = 131,
    difficulty = 1,
    isKnown = false,
})

-- Shipped by the fork source but never wired to a sound or song entry;
-- restored as a playable track in Echoes.
ECCore:registerSong({
    name = "IGUI_EC_GuitarElectric_Electrique",
    instrumentType = "GuitarElectric",
    soundFile = "EC_GuitarElectric_Electrique",
    duration = 42,
    difficulty = 2,
    isKnown = false,
})
