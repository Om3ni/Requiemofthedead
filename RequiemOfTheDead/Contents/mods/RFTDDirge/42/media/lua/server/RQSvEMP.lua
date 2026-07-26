-- RQSvEMP.lua
-- EMP zombie has no alive behavior tick -- it doesnt do anything while it's alive
-- the actual detonation happens in the zombieKilled command handler in RQServer.lua
-- when the EMP dies it fires svApplyEMPBlast at its position, thats the whole mechanic
-- this file just holds the state table so other modules can reference or clean it up consistently
if not isServer() then return end

RQSvEMP = RQSvEMP or {}
RQSvEMP.state = {}  -- empID -> { activated, castDue } -- currently unused, reserved for future use

-- Copyright Project_Omen
