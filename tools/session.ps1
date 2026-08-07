# session.ps1 - one button up, one button down. The repo is the only thing that
# survives a session.
#
# WHY THIS EXISTS (2026-08-06): a client crash-to-desktop on join was traced to
# item->mod attribution collapsing in the engine. WorldDictionary refused to load
# because the server said Base.Memoir belonged to RFTDOddsAndEnds while the
# client's parse said otherwise, and GameEntityScript.setModID throws on any
# mismatch when Core.debug is on. Neither mod ever defined the other's items.
#
# The engine was guessing, and here is the exact mechanism, because it decides
# everything this script does:
#
#   ScriptManager.Load (:1476) builds  tempFileToModMap[absPath] = modId
#   using ZomboidFileSystem.getAbsolutePath (:365), which returns NULL on a miss.
#   HashMap accepts a null key. So every script file whose path fails to resolve
#   writes into ONE shared null slot, last write wins, and at :1527
#   currentLoadFileMod = get(null) hands that arbitrary mod id to every item
#   parsed from those files. Four items across three mods all came out stamped
#   RFTDDirge in one save; the same item was Dragonfly, RFTDMemoir and
#   RFTDOddsAndEnds on three other days. It is a collision, not stale data.
#
#   The lookup misses because getRelativeFile (:848) returns the FULL path when
#   relativize fails, and it fails on a prefix mismatch. ScriptManager builds its
#   root with File.getCanonicalFile(), which FOLLOWS junctions, while walking
#   children through the getCanonicalFile(parent,child) helper (:125), which does
#   not. Link the tree and root and children stop sharing a prefix.
#
# So: NO JUNCTIONS IN THE MOD TREES, EVER. Real copies only. That is the whole
# reason this script exists and why dev-link.ps1 is retired for these two trees.
#
# THE SECOND HALF IS SHADOWING. getAllModFolders (:504) searches in the order
# "workshop,steam,mods":
#
#     1. staged workshop   %USERPROFILE%\Zomboid\Workshop\<item>\Contents\mods
#     2. installed steam   <steam>\workshop\content\108600\<id>\mods
#     3. user mods         %USERPROFILE%\Zomboid\mods          <- ours, and LAST
#
# ChooseGameInfo.readModInfo (:164) breaks duplicate-id ties by lowest index, so
# a copy in 1 or 2 silently outranks everything this script deploys. That is not
# theoretical: on 2026-08-05 the client loaded a staged upload snapshot instead
# of the working tree, and every resolved mod path in console.txt proved it while
# the tree in 3 looked perfectly correct. UP parks tiers 1 and 2 before it pushes
# tier 3, or the push means nothing.
#
# WHAT UP DOES        push repo -> server + client, park every shadow, verify.
# WHAT DOWN DOES      remove everything this script deployed. Repo is untouched
#                     and is all that is left. Shadows stay parked - see below.
#
# THREE RULES THAT MUST NOT BE RELAXED:
#   1. A reparse point is removed with `cmd /c rmdir`, never Remove-Item
#      -Recurse, which FOLLOWS the link and deletes the target - your repo. This
#      is how 286 files were lost on 2026-08-02.
#   2. /MIR runs per mod folder, NEVER at a tree root. The roots hold files this
#      script does not own - default.txt, reset-mods-42_00.txt - and mirroring
#      the root would delete them.
#   3. The source is counted before anything is deleted. A missing or truncated
#      repo must abort, not mirror emptiness over two working trees.
#
# DOWN LEAVES SHADOWS PARKED ON PURPOSE. Restoring the staged upload folder would
# re-arm the exact trap that cost a session. Unpark deliberately with
# -RestoreShadows when you are actually uploading.
#
# Usage:
#   tools\deploy.bat                   deploy and verify (double-click)
#   tools\cleanup.bat                  tear down to bare repo (double-click)
#   tools\deploy.bat -DryRun           plan only, writes nothing
#   tools\cleanup.bat -DryRun          plan the teardown
#   tools\deploy.bat -NoServer         one tree only
#   tools\session.ps1 -RestoreShadows  unpark staged upload folders, then stop
#
# Exit: 0 ok, 1 something failed, 2 refused (bad path, or PZ still running).

[CmdletBinding()]
param(
    [switch] $Down,
    [switch] $DryRun,
    [switch] $NoServer,
    [switch] $NoClient,
    [switch] $RestoreShadows
)

$ErrorActionPreference = 'Stop'

$RepoMods   = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\RequiemOfTheDead\Contents\mods'))
$EchoesSrc  = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\wip\echoes-fork\RFTDEchoes'))
$Manifest   = '.rotd-session'      # written at each tree root; DOWN reads it back
$MinFiles   = 100                  # rule 3: sanity floor for the source tree

# Hashing goes through .NET, NOT Get-FileHash. The bat launches whichever
# powershell.exe the box has, and on this one the cmdlet does not resolve
# (CommandNotFoundException) - it is a Utility-module cmdlet and its autoload
# is not guaranteed, while [Security.Cryptography] always is. check-deploy.ps1
# reached the same conclusion independently; this is that call, kept.
# Returns $null when a file cannot be read, and callers must treat $null as
# drift rather than as "equal" - two unreadable files are not a match.
$script:md5 = [Security.Cryptography.MD5]::Create()
function Get-FileMD5 {
    param([string] $Path)
    try {
        $fs = [IO.File]::OpenRead($Path)
        try { return [BitConverter]::ToString($script:md5.ComputeHash($fs)) }
        finally { $fs.Dispose() }
    } catch { return $null }
}

function Say  { param($m, $c = 'Gray') Write-Host $m -ForegroundColor $c }
function Step { param($m) Write-Host ''; Write-Host $m -ForegroundColor White }
function Fail { param($m) Write-Host "ABORT: $m" -ForegroundColor Red; exit 2 }

$Trees = @()
if (-not $NoServer) { $Trees += [pscustomobject]@{ Name = 'SERVER'; Path = 'C:\Mosaic\pzdata\mods' } }
if (-not $NoClient) { $Trees += [pscustomobject]@{ Name = 'CLIENT'; Path = "$env:USERPROFILE\Zomboid\mods" } }
if (-not $Trees)    { Fail 'both trees disabled - nothing to do' }

# --- rule 1 -----------------------------------------------------------------
# The only removal path in this file. A reparse point is DETACHED with rmdir,
# which never follows it. Anything else is a real folder we own a copy of.
function Remove-Entry {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $i = Get-Item -LiteralPath $Path -Force
    if ($i.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        cmd /c rmdir "$Path" | Out-Null
    } else {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
    return $true
}

# Refuse to swap mods under a live process: the dedi holds script files open and
# a client mid-load would read half of each tree.
#
# Matched by EXE name for the client and by main class for the dedi, never by a
# loose command-line grep - a substring match on "ProjectZomboid" also matches
# the shell that is running this script, which would make the tool refuse itself.
# $PID is excluded for the same reason.
function Assert-NotRunning {
    param([switch] $WarnOnly)
    $live = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
              Where-Object {
                  $_.ProcessId -ne $PID -and (
                      ($_.Name -like 'ProjectZomboid*.exe') -or
                      ($_.Name -eq 'java.exe' -and $_.CommandLine -match 'zombie\.network\.GameServer')
                  )
              })
    if (-not $live.Count) { Say '  no PZ process running' 'DarkGray'; return }

    foreach ($p in $live) {
        $what = if ($p.Name -eq 'java.exe') { 'dedicated server' } else { 'client' }
        Say ("  PID {0,-6} {1}  ({2})" -f $p.ProcessId, $what, $p.Name) $(if ($WarnOnly) { 'Yellow' } else { 'Red' })
    }
    # A dry run writes nothing, so it stays available while the game is up -
    # that is exactly when you want to ask what a deploy would change.
    if ($WarnOnly) { Say '  (dry run - reporting only, nothing would be written yet)' 'Yellow'; return }
    Fail 'Project Zomboid is running - stop it first'
}

# Every place the engine looks BEFORE <userdir>\mods.
#
# A location is only a shadow when it registers one of OUR mod ids - that is what
# creates the duplicate-id tie that ChooseGameInfo.readModInfo resolves in its
# favour. Somebody else's staged item sitting alongside ours is not our business
# and is left strictly alone, which is why this matches against the live id list
# rather than a name pattern.
# WHAT GETS RENAMED, AND WHY IT IS THE INNER FOLDER (corrected 2026-08-06).
#
# The first cut of this renamed the staged ITEM folder and claimed that hid it.
# It does not. SteamWorkshop.getStageFolders (:100) enumerates EVERY directory
# under Zomboid\Workshop with a plain directory stream - the name is never
# examined - and getStagedItemModsFolders then registers each one that has a
# Contents\mods inside it:
#
#     File file = new File(folder + "\Contents\mods");
#     if (!file.exists()) continue;
#
# So `RequiemOfTheDead.parked` was still fully registered, and re-running just
# parked it again into `.parked.parked`. The ONLY thing that deregisters a
# staged item is that inner path not existing, so that is what moves:
# <item>\Contents\mods -> <item>\Contents\mods.parked. The item folder keeps
# its name, which is also what stage-upload expects to find.
#
# Installed Steam items take the same treatment one level shallower (<id>\mods),
# per getInstalledItemModsFolders. Steam owns those and may restore them on any
# validate pass, so a re-park is expected rather than a failure.
$SteamRoots = @('C:\Program Files (x86)\Steam', 'D:\Steam', 'C:\Steam')

function Get-ShadowSources {
    param([string[]] $Ids)
    $out = @()

    function Test-HoldsOurs {
        param([string] $ModsDir)
        if (-not (Test-Path -LiteralPath $ModsDir)) { return @() }
        return @(Get-ChildItem -LiteralPath $ModsDir -Directory -Force -ErrorAction SilentlyContinue |
                 Where-Object { $_.Name -in $Ids } | ForEach-Object Name)
    }

    $staged = Join-Path $env:USERPROFILE 'Zomboid\Workshop'
    if (Test-Path -LiteralPath $staged) {
        foreach ($d in Get-ChildItem -LiteralPath $staged -Directory -Force -ErrorAction SilentlyContinue) {
            $modsDir = Join-Path $d.FullName 'Contents\mods'
            $hit = Test-HoldsOurs $modsDir
            if ($hit.Count) {
                $out += [pscustomobject]@{ Tier = 'staged workshop'; Item = $d.Name; ModsDir = $modsDir; Mods = $hit }
            }
        }
    }
    foreach ($root in $SteamRoots) {
        $content = Join-Path $root 'steamapps\workshop\content\108600'
        if (-not (Test-Path -LiteralPath $content)) { continue }
        foreach ($d in Get-ChildItem -LiteralPath $content -Directory -Force -ErrorAction SilentlyContinue) {
            $modsDir = Join-Path $d.FullName 'mods'
            $hit = Test-HoldsOurs $modsDir
            if ($hit.Count) {
                $out += [pscustomobject]@{ Tier = 'installed steam'; Item = $d.Name; ModsDir = $modsDir; Mods = $hit }
            }
        }
    }
    return $out
}

# Every parked mods folder, both tiers. Used by -RestoreShadows and by the
# teardown's "still parked" note.
function Get-ParkedShadows {
    $out = @()
    $staged = Join-Path $env:USERPROFILE 'Zomboid\Workshop'
    foreach ($d in Get-ChildItem -LiteralPath $staged -Directory -Force -ErrorAction SilentlyContinue) {
        $p = Join-Path $d.FullName 'Contents\mods.parked'
        if (Test-Path -LiteralPath $p) { $out += $p }
    }
    foreach ($root in $SteamRoots) {
        $content = Join-Path $root 'steamapps\workshop\content\108600'
        if (-not (Test-Path -LiteralPath $content)) { continue }
        foreach ($d in Get-ChildItem -LiteralPath $content -Directory -Force -ErrorAction SilentlyContinue) {
            $p = Join-Path $d.FullName 'mods.parked'
            if (Test-Path -LiteralPath $p) { $out += $p }
        }
    }
    return $out
}

# ---------------------------------------------------------------------------
if ($RestoreShadows) {
    Step 'UNPARK'
    $n = 0
    foreach ($p in Get-ParkedShadows) {
        $to = $p -replace '\.parked$', ''
        if (Test-Path -LiteralPath $to) { Say "  SKIP  $p - $to already exists" 'Yellow'; continue }
        if ($DryRun) { Say "  would restore $p" 'DarkGray'; $n++; continue }
        Rename-Item -LiteralPath $p -NewName (Split-Path $to -Leaf)
        Say "  restored $to" 'Green'; $n++
    }
    if (-not $n) { Say '  nothing parked' 'DarkGray' }
    Say ''
    Say 'Shadows are LIVE again - they outrank the deployed trees. Re-run' 'Yellow'
    Say 'tools\deploy.bat before testing anything.' 'Yellow'
    exit 0
}

if (-not (Test-Path -LiteralPath $RepoMods)) { Fail "repo payload not found: $RepoMods" }

$mods = @(Get-ChildItem -LiteralPath $RepoMods -Directory | Sort-Object Name)

# RFTDEchoes is a fork living in wip\, not in the shipped payload, but it IS
# loaded by both trees. Deploy it from its own source so it cannot drift.
$sources = @()
foreach ($m in $mods) { $sources += [pscustomobject]@{ Id = $m.Name; Path = $m.FullName } }
if (Test-Path -LiteralPath $EchoesSrc) {
    $sources += [pscustomobject]@{ Id = 'RFTDEchoes'; Path = $EchoesSrc }
}
$sources = $sources | Sort-Object Id

Write-Host ''
Say ("repo   {0}" -f $RepoMods) 'DarkGray'
if ($DryRun) { Say '  DRY RUN - nothing will be written' 'Yellow' }

# ===========================================================================
#  DOWN
# ===========================================================================
if ($Down) {
    Step 'CHECK'
    Assert-NotRunning -WarnOnly:$DryRun

    $failed = 0
    foreach ($t in $Trees) {
        Step ("{0}  {1}" -f $t.Name, $t.Path)
        if (-not (Test-Path -LiteralPath $t.Path)) { Say '  not present' 'DarkGray'; continue }

        # Prefer the manifest: it records exactly what we put here, so we never
        # guess about a folder somebody else owns.
        $mf = Join-Path $t.Path $Manifest
        if (Test-Path -LiteralPath $mf) {
            $owned = @(Get-Content -LiteralPath $mf | Where-Object { $_ -and $_ -notmatch '^#' })
        } else {
            $owned = @($sources.Id)
            Say '  no manifest - falling back to the known mod list' 'DarkYellow'
        }

        foreach ($id in ($owned | Sort-Object)) {
            $dest = Join-Path $t.Path $id
            if (-not (Test-Path -LiteralPath $dest)) { continue }
            if ($DryRun) { Say ('  would remove {0}' -f $id) 'DarkGray'; continue }
            try { [void](Remove-Entry $dest); Say ('  gone   {0}' -f $id) 'DarkGray' }
            catch { Say ('  FAILED {0} - {1}' -f $id, $_) 'Red'; $failed = 1 }
        }

        # The .zip artefacts robocopy /E used to drag in from the payload root.
        foreach ($z in Get-ChildItem -LiteralPath $t.Path -Filter '*.zip' -File -Force -ErrorAction SilentlyContinue) {
            if ($DryRun) { Say ('  would remove {0}' -f $z.Name) 'DarkGray'; continue }
            Remove-Item -LiteralPath $z.FullName -Force; Say ('  gone   {0}' -f $z.Name) 'DarkGray'
        }

        if (-not $DryRun -and (Test-Path -LiteralPath $mf)) { Remove-Item -LiteralPath $mf -Force }

        # Excluded by name rather than re-scanned, so the answer is the same in a
        # dry run (where nothing was actually removed) as in a real one.
        $left = @(Get-ChildItem -LiteralPath $t.Path -Directory -Force -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -notin $owned })
        if ($left.Count) {
            Say ('  left alone ({0} not ours): {1}' -f $left.Count, ($left.Name -join ', ')) 'DarkYellow'
        }
    }

    Step 'VERIFY'
    $n = (Get-ChildItem -LiteralPath $RepoMods -Recurse -File -Force).Count
    Say ("  repo intact: {0} files" -f $n) 'Green'
    $parked = @(Get-ParkedShadows)
    if ($parked.Count) {
        Say ("  {0} shadow(s) still parked (deliberate):" -f $parked.Count) 'DarkGray'
        foreach ($p in $parked) { Say "    $p" 'DarkGray' }
        Say '  tools\session.ps1 -RestoreShadows  before an upload' 'DarkGray'
    }
    Write-Host ''
    if ($failed) { Say 'teardown had errors - see above' 'Red'; exit 1 }
    Say 'Down. The repo is all that is left.' 'Green'
    exit 0
}

# ===========================================================================
#  UP
# ===========================================================================
Step 'CHECK'
Assert-NotRunning -WarnOnly:$DryRun

# Rule 3: never mirror a broken source over two working trees.
$srcCount = (Get-ChildItem -LiteralPath $RepoMods -Recurse -File -Force).Count
if ($srcCount -lt $MinFiles) {
    Fail "source has only $srcCount files (floor is $MinFiles) - refusing to mirror over the trees"
}
Say ("  source: {0} files, {1} mods" -f $srcCount, $sources.Count) 'DarkGray'

Step 'PARK SHADOWS'
$shadows = @(Get-ShadowSources -Ids $sources.Id)
if (-not $shadows.Count) { Say '  none - nothing outranks the deploy' 'DarkGray' }
foreach ($s in $shadows) {
    $to = "$($s.ModsDir).parked"
    Say ("  [{0}] {1}  registers {2} of ours" -f $s.Tier, $s.Item, $s.Mods.Count) 'DarkGray'

    # An upload link is not a snapshot to park. Renaming it would leave a
    # junction called mods.parked - and where a real parked snapshot already
    # exists, the rename collides and this loop would skip with a message about
    # the wrong problem. Name the actual situation and the one command that ends
    # it; upload-link.ps1 owns that teardown because it points into the repo.
    $isLink = $false
    if (Test-Path -LiteralPath $s.ModsDir) {
        $isLink = ((Get-Item -LiteralPath $s.ModsDir -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
    }
    if ($isLink) {
        Say '  UPLOAD LINK ACTIVE here - not parking it.' 'Red'
        Say '  It outranks everything this script deploys. Run: tools\upload-unlink.bat' 'Red'
        continue
    }

    if (Test-Path -LiteralPath $to) {
        Say ("  SKIP    {0} already exists - resolve by hand" -f $to) 'Yellow'
        continue
    }
    if ($DryRun) { Say ("  would park {0}" -f $s.ModsDir) 'DarkGray'; continue }
    Rename-Item -LiteralPath $s.ModsDir -NewName ((Split-Path $s.ModsDir -Leaf) + '.parked')
    Say ("  parked  {0}\{1} -> mods.parked" -f $s.Tier, $s.Item) 'Yellow'
}

$failed = 0
foreach ($t in $Trees) {
    Step ("{0}  {1}" -f $t.Name, $t.Path)

    if (-not (Test-Path -LiteralPath $t.Path)) {
        if ($DryRun) { Say '  would create tree' 'DarkGray' }
        else { New-Item -ItemType Directory -Force -Path $t.Path | Out-Null }
    }

    # Rule 1. Any link here is the attribution bug waiting to happen, so it goes
    # before anything is copied - including links left by the retired dev-link.
    $links = @(Get-ChildItem -LiteralPath $t.Path -Directory -Force -ErrorAction SilentlyContinue |
               Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
    foreach ($l in $links) {
        if ($DryRun) { Say ('  would unlink {0}' -f $l.Name) 'DarkGray'; continue }
        [void](Remove-Entry $l.FullName)
        Say ('  unlink {0}' -f $l.Name) 'Yellow'
    }

    foreach ($s in $sources) {
        $dest = Join-Path $t.Path $s.Id
        if ($DryRun) { Say ('  would push {0}' -f $s.Id) 'DarkGray'; continue }

        # Rule 2: /MIR is scoped to ONE mod folder. It purges files deleted from
        # the repo without ever seeing the tree root.
        & robocopy $s.Path $dest /MIR /NFL /NDL /NJH /NJS /NP /R:2 /W:2 | Out-Null
        if ($LASTEXITCODE -ge 8) { Say ('  FAILED {0} (robocopy {1})' -f $s.Id, $LASTEXITCODE) 'Red'; $failed = 1; continue }
        Say ('  push   {0}' -f $s.Id) 'Green'
    }

    # Stale mods: ours last time, gone from the repo now. The manifest is what
    # makes this safe - a folder we never deployed is never a candidate.
    $mf = Join-Path $t.Path $Manifest
    if (Test-Path -LiteralPath $mf) {
        $prev = @(Get-Content -LiteralPath $mf | Where-Object { $_ -and $_ -notmatch '^#' })
        foreach ($id in ($prev | Where-Object { $_ -notin $sources.Id })) {
            $dest = Join-Path $t.Path $id
            if (-not (Test-Path -LiteralPath $dest)) { continue }
            if ($DryRun) { Say ('  would drop {0} (no longer in repo)' -f $id) 'DarkGray'; continue }
            [void](Remove-Entry $dest)
            Say ('  drop   {0} (no longer in repo)' -f $id) 'Yellow'
        }
    }

    # Payload-root artefacts that are not mods and must not sit in a mod tree.
    foreach ($z in Get-ChildItem -LiteralPath $t.Path -Filter '*.zip' -File -Force -ErrorAction SilentlyContinue) {
        if ($DryRun) { Say ('  would remove {0}' -f $z.Name) 'DarkGray'; continue }
        Remove-Item -LiteralPath $z.FullName -Force
        Say ('  remove {0}' -f $z.Name) 'Yellow'
    }

    if (-not $DryRun) {
        @("# written by tools\session.ps1 - do not edit", "# $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')") + $sources.Id |
            Set-Content -LiteralPath $mf -Encoding UTF8
    }
}

# ---------------------------------------------------------------------------
Step 'VERIFY'
if ($DryRun) { Say '  skipped (dry run)' 'DarkGray'; Write-Host ''; Say 'Plan only - nothing changed.' 'Yellow'; exit 0 }

foreach ($t in $Trees) {
    $rp = @(Get-ChildItem -LiteralPath $t.Path -Directory -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
    $ok = $true

    # Prove content, not timestamps: a fresh copy always looks "newer", which is
    # what produced two false clobber alarms on 2026-08-02/03.
    $drift = 0
    foreach ($s in $sources) {
        $dest = Join-Path $t.Path $s.Id
        if (-not (Test-Path -LiteralPath $dest)) { $ok = $false; continue }
        foreach ($f in Get-ChildItem -LiteralPath $s.Path -Recurse -File -Force -Filter '*.lua') {
            $rel = $f.FullName.Substring($s.Path.Length).TrimStart('\')
            $b   = Join-Path $dest $rel
            if (-not (Test-Path -LiteralPath $b)) { $drift++; continue }
            $ha = Get-FileMD5 $f.FullName
            $hb = Get-FileMD5 $b
            if ($null -eq $ha -or $null -eq $hb -or $ha -ne $hb) { $drift++ }
        }
    }

    $colour = if ($rp.Count -eq 0 -and $ok -and $drift -eq 0) { 'Green' } else { 'Red' }
    if ($rp.Count -or -not $ok -or $drift) { $failed = 1 }
    Say ("  {0,-7} links:{1}  mods:{2}  lua drift:{3}" -f $t.Name, $rp.Count, $sources.Count, $drift) $colour
    if ($rp.Count) { Say ('           STILL LINKED: ' + ($rp.Name -join ', ')) 'Red' }
}

$stillShadowed = @(Get-ShadowSources -Ids $sources.Id)
if ($stillShadowed.Count) {
    Say ("  {0} shadow(s) STILL ACTIVE - the deploy is being outranked:" -f $stillShadowed.Count) 'Red'
    foreach ($s in $stillShadowed) { Say ("    [{0}] {1}  ({2})" -f $s.Tier, $s.Path, ($s.Mods -join ', ')) 'Red' }
    $failed = 1
} else {
    Say '  no shadows - the deployed trees are what will load' 'Green'
}

Write-Host ''
if ($failed) { Say 'UP finished with problems - read the red lines above.' 'Red'; exit 1 }
Say 'Up. Server and client are running your working tree.' 'Green'
Say 'When you are done:  tools\cleanup.bat' 'DarkGray'
exit 0
