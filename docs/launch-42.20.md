# 42.20 stable launch runbook — Wednesday, July 29, 2026

The first B42 stable. Fresh world, new season, RFTDCore's first deployment.
Work through this top to bottom; nothing here is optional except where marked.

## Monday / Tuesday (before stable)

1. **Read the 42.20 notes the moment they land** (expected Jul 27–29):
   theindiestone.com blog + the Steam news hub. Diff against what Core touches:
   `getFileWriter`/`getFileReader`, `OnClientCommand`, `OnCharacterDeath`,
   `OnTick`, `SafeHouse`, sandbox option loading, the version-folder rules.
   Also watch for the promised post-stable modding guide.
2. **Local smoke test on 42.19** (closest public build to 42.20):
   - `RFTDCore` is junctioned into `%USERPROFILE%\Zomboid\mods\` (remove with
     `Remove-Item` on the junction — it only removes the link).
   - Launch PZ, Mods menu → confirm "Requiem of the Dead" (RFTDCore 0.1.0)
     appears and enables. Host a local game; check `%USERPROFILE%\Zomboid\console.txt`
     for `[RFTDCore] season '...' active` and no Lua stack traces.
   - On a local **dedicated** server if time allows: connect, then from a
     `-debug` client's Lua console run
     `RDNet.send("RFTDCore", "selftest", {})`
     and validate off-box:
     `python tools/validate_jsonl.py "<server cachedir>/Lua/RFTD"`
     Exit criterion: **zero failures**. Record the printed ms/KB numbers in the
     RDLog.lua header.
3. **Publish the Workshop item** (from this repo — in-game Workshop tool →
   select `C:\VSCodeProjects\RequiemoftheDead\RFTDCore`). It needs a real
   `preview.png` first (256x256+; steal the family style). Visibility:
   **unlisted** until proven on the dedi. Record the new Workshop id in
   `RFTDCore/workshop.txt` (`id=`) and in README.md — commit that.

## Wednesday (stable day)

0. **Mosaic branch flip:** the PZ server install tracks `beta_branch: "unstable"`
   in Mosaic's launcher config. 42.20 ships to the DEFAULT branch; switch the
   branch to default/stable in Mosaic before updating, or the server may sit on
   a stale 42.19 unstable. Also remember `mod_check_auto_restart` is ON with a
   5-minute interval - every bundle upload bounces the server automatically.

4. **Server config** (the dedi pulls published builds only):
   - `WorkshopItems=` + the new RFTDCore item id (plus existing items).
   - `Mods=` + `RFTDCore` (load position does not matter to the engine, but
     listing it first reads well).
   - Sandbox: set **`RFTDCore.SeasonId`** for the new season (e.g. `S1-2026-STABLE`).
     Bump this at every wipe — if it is forgotten after a future wipe, Core
     auto-rolls to `auto-<date>` when it notices world age went backwards.
   - Leave `DeathCaptureEnabled` ON; it is the kill switch if horde-night
     performance ever points at the death hook.
5. **Verify all published mods load on 42.20.** Watch server console for
   `[RFTDCore] season ... active` and the absence of stack traces from any
   RFTD mod. 42.19 saves are incompatible with 42.20 — the fresh world is
   expected, not optional.
6. **Run the selftest on the real dedi** (step 2's command) and validate.
7. **First real records:** after the first players load in, confirm
   `Lua/RFTD/season/<id>/chronicle/p/` is populating (RD.SPAWN with plausible
   x/y and a house bbox; RD.HELLO). A death should produce RD.DEATH with
   `killer.kind`, `hours > 0`, and a matching lifeId; the respawn mints a NEW
   lifeId.
8. **Reaper evaluation** — 42.20's headline fix is MP zombie culling, the
   thing Reaper exists to work around (`zombie.popman.ZombieCountOptimiser`
   since 42.19; changed again in 42.20). Run a horde area with Reaper's own
   logging visible: if vanilla culling now behaves, Reaper retires and only
   the Necro tab survives (folded into Dirge at its migration turn).
9. **Anti-cheat check** — 42.19 enabled XP/Permission/Player anti-cheats.
   Exercise Dragonfly's admin flows (grants, role edits, teleports, item
   spawns) with a non-owner admin account and watch for kicks/false
   positives. Any hit: note the exact action; Dragonfly fixes happen in PZMod
   until its migration turn.

## Not on Wednesday

- Nothing player-visible ships. No announcements about Core; it is
  infrastructure.
- Satellite migrations start after the launch settles, in order:
  Dirge + Reclaimation → Dragonfly (+shakeout) → Reaper decision →
  Husbandry, Last Rites.
