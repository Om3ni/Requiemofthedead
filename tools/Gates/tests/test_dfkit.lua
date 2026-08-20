-- test_dfkit.lua - focused engine-contract fixture for DFKit row heights.

local ROOT = arg[1] or "."
local SRC = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/client/DFKit.lua"

local pass, fail = 0, 0
local function eq(name, got, want)
    if got == want then pass = pass + 1
    else
        fail = fail + 1
        print("FAIL " .. name .. " (got " .. tostring(got) .. ", want " .. tostring(want) .. ")")
    end
end

UIFont = { Small = "small", Medium = "medium", Large = "large", Code = "code" }
isServer = function() return false end

local heights = { small = 15, large = 30, default = 11 }
getTextManager = function()
    return {
        -- Mirrors TextManager.getFontFromEnum: absent fonts use the default.
        getFontHeight = function(_, font) return heights[font] or heights.default end,
    }
end

DFKit = nil
dofile(SRC)

eq("small-font rows contain the glyph plus breathing room", DFKit.rowHeight(), 23)
DFKit.font.small = UIFont.Large
eq("large-font rows grow with the glyph", DFKit.rowHeight(), 38)
DFKit.font.small = nil
eq("absent font uses TextManager's default-font fallback", DFKit.rowHeight(), 22)

print(string.format("DFKit: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
