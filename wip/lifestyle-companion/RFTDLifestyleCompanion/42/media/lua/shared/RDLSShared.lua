-- ============================================================================
-- CREDIT: this mod patches "Lifestyle: Hobbies" by [Angry]
--   https://steamcommunity.com/sharedfiles/filedetails/?id=3403870858
-- The patch code here is Requiem of the Dead's own work; the mod it patches is
-- theirs. All original Lifestyle content, code and design belong to its author.
-- ============================================================================

-- RDLSShared.lua - identity + constants for the Lifestyle Companion (both sides).
--
-- The Companion does not own a fresh wire token: Lifestyle's client already
-- sends everything on the literal "LS" module string (237 call sites), and we
-- do NOT rewrite those. Instead the server adopts "LS" into RDNet's single
-- dispatcher, so those unchanged client sends land on a locked door. WIRE is
-- therefore "LS" (Lifestyle's token we adopt), while MODULE is our own id, kept
-- only for the family's mod registry / any Companion-owned S2C traffic.
--
-- Constants only - no RDNet/RDShared calls at file scope. PZ loads shared/
-- alphabetically and "RDLSShared" sorts before "RDNet"/"RDShared", so those
-- tables may not exist yet when this file runs. registerMod happens from the
-- server file, which loads after every shared/ file.

RDLSShared = RDLSShared or {}

RDLSShared.MODULE  = "RFTDLifestyleCompanion"  -- our own id
RDLSShared.WIRE    = "LS"                       -- Lifestyle's token we adopt
RDLSShared.VERSION = "0.1.0"

-- The upstream mod this Companion tracks, for the staleness guard (RDSelfTest).
RDLSShared.UPSTREAM_ID         = "LifestyleHobbies"
RDLSShared.UPSTREAM_MODVERSION = "0.4.0"        -- last version whose LSservercommands.lua we ported

return RDLSShared
