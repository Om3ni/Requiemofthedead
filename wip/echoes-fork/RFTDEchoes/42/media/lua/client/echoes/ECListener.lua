-- Echoes: live music soothes anyone close enough to hear it. Runs on each
-- client, once a minute: if someone within earshot is mid-performance (the
-- play animation doubles as the network-visible signal - it syncs with the
-- character, so no extra traffic), the listener's mood ticks toward calm.
--
-- Extended from the fork source: stress and panic joined unhappiness and
-- boredom, the radius became a dial, and everything moved to the 42.20
-- CharacterStat API (the old BodyDamage getters are gone). All deltas scale
-- with day length so an in-game hour of music is worth the same at any
-- day-length setting. Every dial goes to zero to switch that effect off.

require "echoes/ECCore"

ECListener = ECListener or {}

function ECListener.IsPlayerPlayingMusic(player)
    if not player then return false end

    local animation = player:getVariableString("performingaction")
    return ECCore:isPlayingSongsAnimation(animation)
end

function ECListener.DoStats(me)
    local stats = me:getStats()
    local sandbox = SandboxVars.RFTDEchoes
    local dayLengthMultiplier = (getSandboxOptions():getDayLengthMinutes() / 60)

    -- add() clamps at the stat's bounds, so plain negative deltas are safe.
    if sandbox.HappinessModifier > 0 then
        stats:add(CharacterStat.UNHAPPINESS, -sandbox.HappinessModifier * dayLengthMultiplier)
    end
    if sandbox.BoredomModifier > 0 then
        stats:add(CharacterStat.BOREDOM, -sandbox.BoredomModifier * dayLengthMultiplier)
    end
    if sandbox.StressModifier > 0 then
        stats:add(CharacterStat.STRESS, -sandbox.StressModifier * dayLengthMultiplier)
    end
    if sandbox.PanicModifier > 0 then
        stats:add(CharacterStat.PANIC, -sandbox.PanicModifier * dayLengthMultiplier)
    end
end

function ECListener.Check()
    local me = getPlayer()
    if not me then return end

    if not isClient() then
        if ECListener.IsPlayerPlayingMusic(me) then
            ECListener.DoStats(me)
        end
        return
    end

    local players = getOnlinePlayers()
    if not players then return end

    local radius = SandboxVars.RFTDEchoes.ListenerRadius
    local radiusSq = radius * radius
    for i = 0, players:size() - 1 do
        local player = players:get(i)
        if player:getDistanceSq(me) < radiusSq then
            if ECListener.IsPlayerPlayingMusic(player) then
                ECListener.DoStats(me)
                return
            end
        end
    end
end

if not ECListener.initialized then
    ECListener.initialized = true

    Events.EveryOneMinute.Add(function()
        ECListener.Check()
    end)
end
