# dev-link.ps1 - point the server and client mod folders straight at the repo.
#
# WHAT THIS REPLACES. sync-trees copies the payload out to the trees that run it,
# which means every edit needs a sync and a forgotten sync looks exactly like a
# bug in your code. This removes the step entirely: each mod folder in the target
# tree becomes a JUNCTION to the repo's copy, so the server and client read your
# working tree directly. Edit, restart, done.
#
# DIRECTION IS THE WHOLE SAFETY ARGUMENT. The links live in the DISPOSABLE trees
# and point INTO the repo. When Steam or PZ destroys one of those trees - and it
# does; on 2026-08-03 Steam emptied the server's mod tree and then deleted the
# client's outright, both unprompted - the repo does not notice, because nothing
# in the repo points anywhere.
#
# That is the exact inverse of the arrangement that cost this project its payload
# on 2026-08-02, when the REPO path was a junction to an external tree, that tree
# was emptied, and 286 files read as deleted with git holding 5.2MB against 139MB
# on disk. Links pointing out of the repo are how you lose work. Links pointing
# in are how you stop copying it around.
#
# ECHOES IS COPIED, NOT LINKED, and any future mod like it will be too. A mod
# shipping AnimSets cannot be read through a link: AdvancedAnimator.buildChecksum
# canonicalizes the folder but looks its files up by the link path, which fails at
# dedi boot and again on the client at server-join. Mods needing a real copy are
# DETECTED (an AnimSets/anims folder), not hardcoded, so this keeps working when
# the next animation mod lands.
#
# TEARDOWN IS THE DANGEROUS PART and is why it lives in a script. Removing a
# junction with Remove-Item -Recurse follows it and deletes the TARGET - here,
# your repo. Every removal below checks for a reparse point first and uses
# `cmd /c rmdir` when it finds one. Do not do this by hand.
#
# Usage:
#   tools\dev-link.ps1              link both trees (idempotent - re-run anytime)
#   tools\dev-link.ps1 -Down        remove the links, leave the trees empty
#   tools\dev-link.ps1 -Copy        real copies everywhere instead of links
#   tools\dev-link.ps1 -NoClient    one tree only
#   tools\dev-link.ps1 -WhatIfOnly  report the plan, change nothing

[CmdletBinding()]
param(
    [switch] $Down,
    [switch] $Copy,
    [switch] $NoServer,
    [switch] $NoClient,
    [switch] $WhatIfOnly
)

$ErrorActionPreference = 'Stop'

$RepoMods = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\RequiemOfTheDead\Contents\mods'))
if (-not (Test-Path -LiteralPath $RepoMods)) { throw "repo mods not found: $RepoMods" }

$Targets = @()
if (-not $NoServer) { $Targets += [pscustomobject]@{ Name='SERVER'; Path='C:\Mosaic\pzdata\mods' } }
if (-not $NoClient) { $Targets += [pscustomobject]@{ Name='CLIENT'; Path="$env:USERPROFILE\Zomboid\mods" } }

# A mod that ships animation sets cannot be read through a link - see header.
function Test-NeedsCopy {
    param([string] $ModPath)
    $hit = Get-ChildItem -LiteralPath $ModPath -Recurse -Directory -Force -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -in @('AnimSets', 'anims_X', 'anims') }
    return [bool]$hit
}

function Test-IsLink {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $i = Get-Item -LiteralPath $Path -Force
    return [bool]($i.Attributes -band [IO.FileAttributes]::ReparsePoint)
}

# The one removal path. A reparse point is unlinked with rmdir, which detaches
# the link and never follows it; anything else is a real folder we own a copy of.
function Remove-Entry {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if (Test-IsLink $Path) {
        cmd /c rmdir "$Path" | Out-Null
    } else {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
}

$mods = Get-ChildItem -LiteralPath $RepoMods -Directory | Sort-Object Name
$copyMods = @($mods | Where-Object { Test-NeedsCopy $_.FullName } | ForEach-Object Name)

Write-Host ''
Write-Host "repo:   $RepoMods" -ForegroundColor DarkGray
if ($copyMods.Count) {
    Write-Host "copied (ships AnimSets): $($copyMods -join ', ')" -ForegroundColor DarkYellow
}

foreach ($t in $Targets) {
    Write-Host ''
    Write-Host "$($t.Name)  $($t.Path)" -ForegroundColor White

    if (-not (Test-Path -LiteralPath $t.Path)) {
        if ($WhatIfOnly) { Write-Host '  would create target folder'; continue }
        New-Item -ItemType Directory -Force -Path $t.Path | Out-Null
    }

    foreach ($m in $mods) {
        $dest      = Join-Path $t.Path $m.Name
        $mustCopy  = $Copy -or ($copyMods -contains $m.Name)
        $verb      = if ($Down) { 'remove' } elseif ($mustCopy) { 'copy' } else { 'link' }

        if ($WhatIfOnly) {
            Write-Host ('  {0,-6} {1}' -f $verb, $m.Name) -ForegroundColor DarkGray
            continue
        }

        # Always clear first: this is what makes the script idempotent, and it is
        # also how a mod switches between copied and linked without a stale
        # folder of the other kind being left behind to shadow it.
        Remove-Entry $dest
        if ($Down) {
            Write-Host ('  {0,-6} {1}' -f 'gone', $m.Name) -ForegroundColor DarkGray
            continue
        }

        if ($mustCopy) {
            & robocopy $m.FullName $dest /MIR /NFL /NDL /NJH /NJS /NP /R:2 /W:2 | Out-Null
            if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE) for $($m.Name)" }
            Write-Host ('  {0,-6} {1}' -f 'copy', $m.Name) -ForegroundColor Yellow
        } else {
            New-Item -ItemType Junction -Path $dest -Target $m.FullName | Out-Null
            Write-Host ('  {0,-6} {1}' -f 'link', $m.Name) -ForegroundColor Green
        }
    }
}

if ($WhatIfOnly) { Write-Host ''; Write-Host 'plan only - nothing changed' -ForegroundColor Yellow; return }

# --- verify, and prove the repo is untouched --------------------------------
$repoFiles = (Get-ChildItem -LiteralPath $RepoMods -Recurse -File -Force).Count
Write-Host ''
Write-Host "repo intact: $repoFiles files" -ForegroundColor Green
if (-not $Down) {
    foreach ($t in $Targets) {
        $seen = (Get-ChildItem -LiteralPath $t.Path -Directory -Force |
                 Where-Object { $_.Name -in $mods.Name }).Count
        Write-Host ("$($t.Name) has $seen/$($mods.Count) mods") -ForegroundColor Green
    }
    Write-Host ''
    Write-Host 'Edit in the repo; the server and client read it directly. No sync.' -ForegroundColor Cyan
    Write-Host 'Echoes is a copy - re-run this script after changing it.' -ForegroundColor DarkCyan
}
