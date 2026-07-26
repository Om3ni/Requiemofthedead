-- DFConfirm - overrideable confirmation popup for MP-disruptive actions.
--
-- Per the refined MP-disruption rule: incidental disruption refuses, but
-- deliberate admin actions (mass cull, drop a horde, force reload) show a
-- single overrideable popup naming the affected players. Never refuse,
-- never silently force. DFConfirm.askIfOthersOnline() is the entry point.

if isServer() then return end

require "ISUI/ISModalDialog"

DFConfirm = DFConfirm or {}

local function otherUsernames()
    local out = {}
    local players = getOnlinePlayers()
    if not players then return out end
    local me = getPlayer()
    local myName = me and me.getUsername and me:getUsername() or nil
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        if p and p:getUsername() ~= myName then
            out[#out + 1] = p:getUsername()
        end
    end
    return out
end

-- Always-confirm variant for single-target irreversible actions (e.g. memoir
-- restore overwrites a character): plain yes/no modal regardless of who's
-- online - the online-count logic above is about SERVER-wide disruption, which
-- doesn't apply when the action rewrites one specific player.
function DFConfirm.ask(message, onConfirm)
    local modal = ISModalDialog:new(
        getCore():getScreenWidth() / 2 - 220,
        getCore():getScreenHeight() / 2 - 80,
        440, 180,
        message, true, nil,
        function(self_, button)
            if button.internal == "YES" then onConfirm() end
        end)
    modal:initialise()
    modal:addToUIManager()
end

-- Calls `onConfirm()` immediately if no other players are online (SP-style),
-- otherwise pops a modal naming the others and asks the admin to confirm.
function DFConfirm.askIfOthersOnline(actionLabel, onConfirm)
    local others = otherUsernames()
    if #others == 0 then
        onConfirm()
        return
    end

    local namelist = table.concat(others, ", ")
    local message = string.format(
        "%s\n\nOther players currently connected:\n%s\n\nProceed anyway?",
        actionLabel, namelist)

    local modal = ISModalDialog:new(
        getCore():getScreenWidth() / 2 - 220,
        getCore():getScreenHeight() / 2 - 80,
        440, 180,
        message, true, nil,
        function(self_, button)
            if button.internal == "YES" then onConfirm() end
        end)
    modal:initialise()
    modal:addToUIManager()
end
