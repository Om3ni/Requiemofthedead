# LZI bridge — live server install brief

**Audience:** Claude Code running on the PRODUCTION Project Zomboid dedicated server.
**Task:** install three sidecar class files so the LZI population governor (shipping in
the RFTDReaper mod update) can push zombie-config changes into the native popman at
runtime. This folder (`tools/lzi/`) travels with this brief and contains everything.

Do the steps in order. Every step has a verification — do not proceed past a failed one.

## What this is (30 seconds of context)

LZI (LuaZombieInjection) is an experimental governor in RFTDReaper that watches real
tick health and trims `ZombieConfig.PopulationPeakMultiplier` when the server is
overloaded, restoring it on recovery. The Lua arrives with the normal Workshop mod
update and is **default-off** (`RFTDReaper.LZIEnabled = false`). The Lua half works
without this install, but its changes would only reach the engine at a restart. These
three class files patch one method (`ZombiePopulationManager.setZombiesMaxPerChunk`
gains a config push, gated on `GameServer.server`, try/catch-wrapped) so the change
lands live. Tested end to end on the Mosaic test dedi 2026-08-11.

The install is additive and trivially reversible: three loose files the game's
classpath (`java/.` before `java/projectzomboid.jar`) picks up in preference to the
jar. Steam updates and `validate` never touch them.

## Step 1 — locate the server root and confirm the version

The server root is the directory containing `java/projectzomboid.jar` and
`ProjectZomboid64.json` (steamcmd installs it as `ProjectZomboidDedicatedServer`).

Confirm the game build is **42.20.2**. The classes were compiled against the
42.20.2-ffe7a8a4b1 jar. If the live server is on any other build, **STOP — do not
install** — report back instead; the patch must be re-diffed and rebuilt on the dev box.

Optional stronger check (needs any JDK ≥25 on PATH; skip if none):

    javap -p -cp <serverRoot>/java/projectzomboid.jar zombie.popman.ZombiePopulationManager | sort > jar.sig
    javap -p -cp classes zombie.popman.ZombiePopulationManager | sort > our.sig
    diff jar.sig our.sig        # must be empty (the patch changes a method body, not the API)

## Step 2 — verify the payload survived the transfer

From this folder, the three files under `classes/zombie/popman/` must hash exactly:

| SHA-256 | file | bytes |
|---|---|---|
| `2f84d941d8979070176dd26b5306e0442e62b260f48e324868de844b9509faaf` | `ZombiePopulationManager.class` | 27347 |
| `6b0599bc2f9a8cbf482ec090c14a6aa9ae1153a77c95b0de6c68a19573445ab5` | `ZombiePopulationManager$PendingCellSave.class` | 802 |
| `88af1385cd2888230a0040f02eebeaa08950b8474ed7b95f88ae544e3cc59b7d` | `ZombiePopulationManager$ZombieSaveData.class` | 978 |

PowerShell: `Get-FileHash -Algorithm SHA256 classes\zombie\popman\*.class`
Any mismatch → STOP, report back.

## Step 3 — install (server stopped)

1. Stop the dedicated server by the site's normal procedure. Confirm no server java
   process remains before copying.
2. Copy the tree, preserving paths — **all three files together, never a subset**
   (javac emits the inner classes separately; mixing patched and jar halves is
   undefined behavior):

       <serverRoot>/java/zombie/popman/ZombiePopulationManager.class
       <serverRoot>/java/zombie/popman/ZombiePopulationManager$PendingCellSave.class
       <serverRoot>/java/zombie/popman/ZombiePopulationManager$ZombieSaveData.class

   (`java/zombie/popman/` will not exist yet — create it.)
3. Verify: list the directory and re-hash the three copied files against the table.

## Step 4 — boot and verify (governor still off)

Start the server normally. This boot proves only that the patched class loads:

- **PASS:** server reaches `*** SERVER STARTED ***` with no
  `NoSuchMethodError` / `ClassNotFoundException` / `NoClassDefFoundError` mentioning
  `ZombiePopulationManager` in the console.
- **FAIL:** any such error → delete the three files, start the server (it will run
  the jar's own class, fully vanilla), report back.

No `[LZI]` lines are expected yet — the governor is off and the bridge is silent
until something calls it.

## Step 5 — enable the governor (only after the Reaper mod update is live)

Ordering matters: the server must have loaded the updated RFTDReaper at least once
before the sandbox file is edited. The engine **rewrites `<servername>_SandboxVars.lua`
at every boot and silently drops entries for options it doesn't know** — an edit made
before the updated mod has registered its options evaporates without a trace.

1. Confirm the update is loaded: the mod tree the server actually reads contains
   `RFTDReaper/42/media/lua/server/RPGovernor.lua`.
2. Stop the server. In `<cachedir>/Server/<servername>_SandboxVars.lua`, inside the
   `RFTDReaper = { ... }` block, set (adding any that are absent):

       LZIEnabled = true,

   Leave the other LZI values at their defaults (LowWater 5.0 Hz, HighWater 9.0 Hz,
   HoldDown 120 s, HoldUp 900 s, Step 0.25, Floor 1.0, Cooldown 600 s) unless told
   otherwise.
3. Start the server and watch the console:
   - Within seconds of the first tick: `[LZI] governor live: ...` — the Lua is armed.
   - On its first window: `[LZI] armed; ceiling captured at <current Peak>`.
   - **Bridge proof appears only when a step actually fires** (a genuinely overloaded
     tick rate sustained past the hold time): the pair
     `[LZI] popman config pushed to native (peak=...)` (from this patch) followed by
     `[LZI] peak -> ... ` (from the governor). On a healthy server it is normal to
     see no step for days. Setting `LZILowWaterHz` above 10 (max 12) is a deliberate
     force-overload test mode if an immediate live-fire proof is wanted — revert it
     to 5.0 afterwards.

## Behavior notes for whoever operates this

- Trimming the peak removes NO zombies. It stops the population ramp from adding more
  and shrinks respawn targets; relief arrives by attrition over hours. Reaper's cull
  remains the fast path.
- A restart resets the peak to the sandbox file's value (the file is authoritative on
  dedis, re-read every boot); the governor re-trims if the overload is real.
- Disabling later (`LZIEnabled = false`) is safe: on the next boot the governor
  notices it had governed, restores the original ceiling once, and goes quiet.
- Full rollback of everything = set `LZIEnabled = false` AND delete the three class
  files. Order doesn't matter; each half is independently safe.
- After any PZ engine update: the loose classes survive and keep winning against the
  new jar. If the boot then fails with a `ZombiePopulationManager` class error, delete
  the three files and report back for a rebuild. Even on a clean boot, report the
  update so the dev box can re-diff the class against the new jar.

## Report back

When done, report: game build seen, hash check result, boot result, whether LZI was
enabled, and the exact `[LZI]` console lines observed (or their absence).
