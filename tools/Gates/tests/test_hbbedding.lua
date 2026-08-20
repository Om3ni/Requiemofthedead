-- HBBedding fixture - server-owned bedding writes cap their state and transmit
-- the matching ModData update exactly once.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDHusbandry/42/media/lua/shared/HBBedding.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL HBBedding: " .. message)
    end
end

function isServer() return true end
SandboxVars = { RFTDHusbandry = { HayTuftsPerBedding = 4 } }
HBData = { NS_HUTCH = "RFTDHusbandry.Bedding" }

local ok, err = pcall(dofile, SOURCE)
check(ok, "module loads: " .. tostring(err))

local modData, transmissions = {}, 0
local hutch = {
    getModData = function() return modData end,
    transmitModData = function() transmissions = transmissions + 1 end,
}

local first = HBBedding.addBedding(hutch)
check(first == 25 and modData[HBData.NS_HUTCH].bedding == 25 and transmissions == 1,
    "a default HayTuft grant writes and transmits one capped charge")

local second = HBBedding.addBedding(hutch, 100)
check(second == HBBedding.MAX and modData[HBData.NS_HUTCH].bedding == HBBedding.MAX and transmissions == 2,
    "an oversized grant caps at MAX and still transmits the authoritative state")

check(HBBedding.addBedding(nil) == 0 and transmissions == 2,
    "a missing hutch remains a no-op")

-- A dirty live hutch absorbs the capped five units in deterministic engine
-- field writes, mirrors its current values for dedicated clients, and sends
-- exactly one mod-data update.
local cleanData, cleanTransmissions = { [HBData.NS_HUTCH] = { bedding = 10 } }, 0
local cleanHutch = {
    dirt = 4, nest = 2,
    getModData = function() return cleanData end,
    getHutchDirt = function(self) return self.dirt end,
    setHutchDirt = function(self, value) self.dirt = value end,
    getNestBoxDirt = function(self) return self.nest end,
    setNestBoxDirt = function(self, value) self.nest = value end,
    transmitModData = function() cleanTransmissions = cleanTransmissions + 1 end,
}
HBBedding.applyBedding(cleanHutch)
local cleanState = cleanData[HBData.NS_HUTCH]
check(cleanHutch.dirt == 0 and cleanHutch.nest == 1
    and cleanState.dirt == 0 and cleanState.nbDirt == 1
    and cleanState.bedding == (10 - 5 / HBBedding.DEFAULT_RATIO)
    and cleanTransmissions == 1,
    "a pass cleans in order, mirrors the result, spends bedding, and transmits once")

-- Spending the last charge on the last dirt auto-prunes the idle ModData
-- record; a clean hutch does no write or transmission at all.
local emptyData, emptyTransmissions = { [HBData.NS_HUTCH] = { bedding = 1 } }, 0
local emptyHutch = {
    dirt = 3, nest = 0,
    getModData = function() return emptyData end,
    getHutchDirt = function(self) return self.dirt end,
    setHutchDirt = function(self, value) self.dirt = value end,
    getNestBoxDirt = function(self) return self.nest end,
    setNestBoxDirt = function(self, value) self.nest = value end,
    transmitModData = function() emptyTransmissions = emptyTransmissions + 1 end,
}
HBBedding.applyBedding(emptyHutch)
check(emptyHutch.dirt == 0 and emptyHutch.nest == 0
    and emptyData[HBData.NS_HUTCH] == nil and emptyTransmissions == 1,
    "a fully spent clean pass prunes idle bedding state")
HBBedding.applyBedding(emptyHutch)
check(emptyTransmissions == 1,
    "an already clean and unbedded hutch does not transmit")

local master = { getHutch = function(self) return self end }
local coldCalls = 0
function getCell()
    return {
        getGridSquare = function(_, x)
            coldCalls = coldCalls + 1
            if x == 1 then return nil end
            return { getObjects = function()
                return { size = function() return 1 end, get = function() return master end }
            end }
        end,
    }
end
function instanceof(object, name) return object == master and name == "IsoHutch" end
check(HBBedding.resolveHutchAt(1, 2, 0) == nil,
    "an unloaded server square is a direct no-hutch result")
check(HBBedding.resolveHutchAt(3, 2, 0) == master and coldCalls == 2,
    "a loaded hutch square resolves its authoritative master")

print(string.format("HBBedding: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
