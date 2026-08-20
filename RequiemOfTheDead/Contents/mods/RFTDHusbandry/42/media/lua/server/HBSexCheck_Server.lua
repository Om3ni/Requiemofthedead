-- SPDX-License-Identifier: GPL-3.0-or-later
-- HBSexCheck_Server - server side of the sex-check diagnostic.
--
-- Dumps the definition table to the server log, reports the server-authoritative
-- sex for the requested OID, and replies to the requesting admin via the
-- existing hbDebugProbeResult channel so the result also surfaces in the panel
-- log.
--
-- NO LISTENER HERE, since 2026-08-19. This file used to add its own
-- OnClientCommand listener for "hbSexCheck", which made RFTDHusbandry a token
-- with TWO executable intakes - so no single file stated the token's trust
-- boundary and check-network failed on it. Intake and the staff gate now belong
-- to the one dispatcher in HBCommands.lua, which routes here; this file is back
-- to owning only the diagnostic. The gate is unchanged in effect - HBCommands
-- applies the same isAdminLike, which is now defined once instead of twice.

if not isServer() then return end

HBSexCheck_Server = HBSexCheck_Server or {}

-- Called by HBCommands' dispatcher AFTER the staff gate. Do not add a gate
-- here: one boundary, stated in one place.
function HBSexCheck_Server.handle(player, args)
    if HBSexCheck and HBSexCheck.dumpDefs then HBSexCheck.dumpDefs("server") end

    local oid = tonumber(args and args.id)
    if not oid then return end

    local line
    local a = getAnimal(oid)
    if a then
        -- isFemale delegates to getCharacterGender (IsoGameCharacter.java:9312-9313),
        -- which returns FEMALE when an early-constructed animal has no descriptor
        -- (:9328-9333). The valid receiver therefore has no exceptional path.
        local sex = a:isFemale() and "FEMALE" or "MALE"
        line = string.format("[HBSexCheck] server view: oid=%d sex=%s", oid, sex)
    else
        line = "[HBSexCheck] server: animal " .. tostring(oid) .. " not resolvable"
    end
    print(line)
    -- GameServer.sendServerCommand:3256 returns early for an unmapped player and
    -- for a closed connection, so a disconnect mid-probe needs no guard.
    sendServerCommand(player, "RFTDHusbandry", "hbDebugProbeResult", { line = line })
end

print("[HB] HBSexCheck_Server loaded")

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
