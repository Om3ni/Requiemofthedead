<#
.SYNOPSIS
    Copy the server's mod list out of the Steam workshop tree into the cachedir mods folder,
    so the server can load them with Steam mode OFF.

.DESCRIPTION
    WHY THIS EXISTS: FakeClientManager bots hardcode ZNetNoSteam64 (FakeClientManager.java:348)
    and the server picks its transport at SteamUtils.java:64-72 - ZNetJNI64 with Steam on,
    ZNetNoSteam64 with it off. Mutually exclusive, so bots can only reach a server running
    -Dzomboid.steam=0.

    But both workshop mod sources are gated on the same switch:
        getInstalledItemModsFolders  ZomboidFileSystem.java:429   if (isSteamModeEnabled() && ...)
        getStagedItemModsFolders     ZomboidFileSystem.java:439   if (isSteamModeEnabled())
    so turning Steam off silently unloads every workshop mod and the server boots vanilla - which
    would make a capture worthless while still looking like it worked.

    The one ungated source is the plain mods folder under the cache dir
    (ZomboidFileSystem.java:520, Core.getMyDocumentFolder() -> getCacheDir()). Staging a real copy
    there gives a server that runs the full mod list with Steam disabled.

    A COPY, NOT A JUNCTION, ON PURPOSE: Steam re-validates and rewrites the workshop tree on every
    Mosaic launch - the same clobber launch-mosaic.ps1 exists to dodge. Junctions would inherit
    that churn mid-experiment; a copy is a stable snapshot that cannot move under a live capture.

    KEYED ON MOD ID, NOT FOLDER NAME. Mods= holds the id from mod.info, which is frequently NOT
    the folder name - on this box "RQD_DB" lives in a folder called "Deadband". Matching on folder
    names silently loses those mods, and a mod that quietly fails to load is the worst outcome
    here: the server boots, the capture runs, and the numbers describe a mod set you did not
    intend. Folder name is kept only as a fallback for mods whose mod.info has no id.

.PARAMETER Prefer
    Resolve an ambiguous id to a specific workshop item, e.g. -Prefer @{ RQD_DB = '3763118246' }.
    Ambiguity is never guessed: picking the wrong copy would mean measuring a mod that differs
    from the one the live server runs.

.PARAMETER Clean
    Also delete folders in Target that are not in Mods=. Off by default.

.EXAMPLE
    .\stage-mods.ps1
    .\stage-mods.ps1 -Clean
    .\stage-mods.ps1 -Prefer @{ RQD_DB = '3763118246' }
#>
[CmdletBinding()]
param(
    [string]    $Ini      = 'C:\Mosaic\pzdata\Server\MDS.ini',
    [string]    $Workshop = 'C:\Mosaic\ProjectZomboidDedicatedServer\steamapps\workshop\content\108600',
    [string]    $Target   = 'C:\Mosaic\pzdata\mods',
    [hashtable] $Prefer   = @{},
    [switch]    $Clean
)

$ErrorActionPreference = 'Stop'

function Say  ($m) { Write-Host $m }
function Step ($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Warn ($m) { Write-Host "!!  $m" -ForegroundColor Yellow }
function Good ($m) { Write-Host "OK  $m" -ForegroundColor Green }
function Bad  ($m) { Write-Host "XX  $m" -ForegroundColor Red }

foreach ($p in @($Ini, $Workshop)) {
    if (-not (Test-Path $p)) { Bad "not found: $p"; exit 1 }
}

# Staging into a tree the server has open mid-boot yields a half-copied mod and a baffling
# failure. Refuse rather than race it.
$running = Get-CimInstance Win32_Process -Filter "Name='java.exe'" -ErrorAction SilentlyContinue |
           Where-Object { $_.ExecutablePath -like 'C:\Mosaic\*' }
if ($running) {
    Bad "the Mosaic server is running (pid $($running.ProcessId))."
    Say "    Stop it first - copying mods under a live server gives a partial tree."
    exit 1
}

Step "Reading mod list from $Ini"
$line = (Select-String -Path $Ini -Pattern '^Mods=' | Select-Object -First 1).Line
if (-not $line) { Bad "no Mods= line in $Ini"; exit 1 }
$wanted = $line -replace '^Mods=','' -split ';' |
          ForEach-Object { $_.TrimStart('\').Trim() } |
          Where-Object { $_ }
Good "$($wanted.Count) mods listed"

Step "Indexing workshop tree by mod id"
$index = @{}          # id (or folder name fallback) -> @(mod folder paths)
$scanned = 0
foreach ($d in Get-ChildItem "$Workshop\*\mods\*" -Directory -ErrorAction SilentlyContinue) {
    $ids = @()
    # mod.info lives under common/ or a version dir like 42/ (ZomboidFileSystem.java:478).
    foreach ($v in Get-ChildItem $d.FullName -Directory -ErrorAction SilentlyContinue) {
        $mi = Join-Path $v.FullName 'mod.info'
        if (-not (Test-Path $mi)) { continue }
        $raw = Get-Content $mi -ErrorAction SilentlyContinue |
               Where-Object { $_ -match '^\s*id\s*=' } | Select-Object -First 1
        if ($raw) { $ids += ($raw -replace '^\s*id\s*=\s*','').Trim() }
    }
    if (-not $ids.Count) { continue }        # no mod.info anywhere: not a mod folder
    $scanned++
    $keys = @($ids | Where-Object { $_ } | Sort-Object -Unique)
    if (-not $keys.Count) { $keys = @($d.Name) }   # fallback: mod.info present but no id=
    foreach ($k in $keys) {
        if (-not $index.ContainsKey($k)) { $index[$k] = @() }
        if ($index[$k] -notcontains $d.FullName) { $index[$k] += $d.FullName }
    }
}
Good "$scanned mod folders, $($index.Count) distinct ids"

New-Item -ItemType Directory -Force $Target | Out-Null

$staged = @(); $missing = @(); $ambiguous = @(); $failed = @()

Step "Staging to $Target"
foreach ($name in $wanted) {
    if (-not $index.ContainsKey($name)) { $missing += $name; continue }

    $sources = @($index[$name])
    if ($sources.Count -gt 1) {
        if ($Prefer.ContainsKey($name)) {
            $want = [string]$Prefer[$name]
            $pick = @($sources | Where-Object { $_ -match "108600\\$want\\" })
            if ($pick.Count -ne 1) {
                $ambiguous += [pscustomobject]@{ Name = $name; Sources = $sources }
                continue
            }
            $sources = $pick
        } else {
            $ambiguous += [pscustomobject]@{ Name = $name; Sources = $sources }
            continue
        }
    }

    $dst = Join-Path $Target (Split-Path -Leaf $sources[0])
    robocopy $sources[0] $dst /MIR /NFL /NDL /NJH /NJS /NP /R:1 /W:1 | Out-Null
    if ($LASTEXITCODE -ge 8) { $failed += $name; Warn "robocopy failed ($LASTEXITCODE): $name" }
    else { $staged += $name; Write-Host ("  + {0,-28} <- {1}" -f $name, (Split-Path -Leaf $sources[0])) }
}

if ($Clean) {
    Step "Removing folders not backing any listed mod"
    $keep = @($staged | ForEach-Object { Split-Path -Leaf (@($index[$_])[0]) })
    foreach ($d in Get-ChildItem $Target -Directory -ErrorAction SilentlyContinue) {
        if ($keep -notcontains $d.Name) {
            Write-Host "  - $($d.Name)"
            Remove-Item $d.FullName -Recurse -Force
        }
    }
}

Write-Host ""
Write-Host "======================================================="
Good "staged    : $($staged.Count) / $($wanted.Count)"
if ($ambiguous.Count) {
    Bad "ambiguous : $($ambiguous.Count) - NOT staged"
    foreach ($a in $ambiguous) {
        Write-Host "    $($a.Name)"
        $a.Sources | ForEach-Object { Write-Host "      $_" }
    }
    Say "    Resolve with -Prefer @{ <id> = '<workshopItemId>' }"
}
if ($missing.Count) {
    Bad "missing   : $($missing.Count) - no mod with this id anywhere in the workshop tree"
    $missing | ForEach-Object { Write-Host "    $_" }
    Say "    These are absent from disk, so the LIVE Steam-mode server is not loading them"
    Say "    either. That is a pre-existing Mods= problem, not a staging failure."
}
if ($failed.Count) { Bad "failed    : $($failed.Count)"; $failed | ForEach-Object { Write-Host "    $_" } }
Write-Host "======================================================="

if ($ambiguous.Count -or $failed.Count) {
    Write-Host ""
    Warn "Resolve the above before capturing - the server would boot without those mods."
    exit 1
}

Write-Host ""
Good "Staging complete. Start the server with 1B-START-NOSTEAM.bat."
Say  "Re-run this after any sync-trees.ps1 push: the no-Steam server reads $Target,"
Say  "not the workshop tree, so a sync alone will not reach it."
exit 0
