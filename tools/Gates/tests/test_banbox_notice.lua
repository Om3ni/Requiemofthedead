-- test_banbox_notice.lua - client notification contract for BanBox removals.
--
-- BanBox sends plain text. Vanilla ISChat.addLineInChat instead requires a
-- ChatMessage and calls message:getTextWithPrefix() (ISChat.lua:707), so this
-- module must keep the supported HaloText notification and never feed that
-- incompatible text into chat.

local ROOT = arg[1] or "."
local SRC = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDBanBox"
             .. "/42/media/lua/client/DFBanBox_Notice.lua"

local pass, fail = 0, 0
local function eq(name, got, want)
    if got == want then pass = pass + 1
    else
        fail = fail + 1
        print("FAIL " .. name)
        print("  got:  " .. tostring(got))
        print("  want: " .. tostring(want))
    end
end

isServer = function() return false end

local handler
Events = {
    OnServerCommand = {
        Add = function(fn) handler = fn end,
    },
}

local player = {}
getPlayer = function() return player end

local halo = {}
HaloTextHelper = {
    addBadText = function(who, message)
        halo[#halo + 1] = { who = who, message = message }
    end,
}

local chatCalls = 0
ISChat = {
    instance = {
        addLineInChat = function() chatCalls = chatCalls + 1 end,
    },
}

dofile(SRC)
eq("registers one server-command listener", type(handler), "function")

handler("OtherMod", "removed", { message = "ignored" })
eq("ignores another module", #halo, 0)

handler("DFBanBox", "other", { message = "ignored" })
eq("ignores another command", #halo, 0)

handler("DFBanBox", "removed", {})
eq("ignores a missing message", #halo, 0)

handler("DFBanBox", "removed", { message = "" })
eq("ignores an empty message", #halo, 0)

handler("DFBanBox", "removed", { message = "Removed: Base.Yoyo" })
eq("shows one supported HaloText notice", #halo, 1)
eq("passes the local player to HaloText", halo[1] and halo[1].who, player)
eq("preserves the server-authored message", halo[1] and halo[1].message, "Removed: Base.Yoyo")
eq("never calls chat with incompatible text", chatCalls, 0)

player = nil
handler("DFBanBox", "removed", { message = "ignored" })
eq("does nothing before the local player exists", #halo, 1)

print(string.format("BanBox notice: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
