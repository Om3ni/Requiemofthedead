# stage-upload.ps1 - copy the repo payload into the Workshop staging folder.
#
# Run this before every upload. The PZ uploader reads
# %USERPROFILE%\Zomboid\Workshop\<Name>\ expecting workshop.txt beside a
# Contents\ folder - which is exactly the shape of RequiemOfTheDead\ in the repo,
# so this is a straight mirror.
#
# REAL FILES, NOT A LINK, and that is the whole point. A junction here works for
# most mods and breaks this one: RFTDEchoes ships AnimSets, and
# AdvancedAnimator.buildChecksum canonicalizes the folder but looks files up by
# the link path, which fails at dedi boot and again on the client at server-join.
# A copy has no such problem. It also keeps the staging folder from being a live
# mod source pointing at whatever the repo happens to contain mid-edit - staging
# is a snapshot you chose to publish, not a window onto your working tree.
#
# /MIR, so a file deleted from the repo is deleted from staging. That is only
# safe because the target is a folder this script owns; the reparse-point guard
# below is what stops /MIR ever being pointed at something it would gut.
#
# Usage:
#   tools\stage-upload.ps1            mirror, then report
#   tools\stage-upload.ps1 -DryRun    show what would change, write nothing

[CmdletBinding()]
param(
    # Resolved in the body, not here: $PSScriptRoot is not populated while a
    # param() default is being evaluated under -File.
    [string] $Source,
    [string] $StageRoot = "$env:USERPROFILE\Zomboid\Workshop",
    [string] $Name = 'RequiemOfTheDead',
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
if (-not $Source) { $Source = Join-Path $PSScriptRoot '..\RequiemOfTheDead' }
$Source = [IO.Path]::GetFullPath($Source)
$Dest   = Join-Path $StageRoot $Name

# --- sanity: is the source actually a workshop item? ------------------------
if (-not (Test-Path -LiteralPath $Source)) { throw "source not found: $Source" }
foreach ($need in 'workshop.txt', 'Contents') {
    if (-not (Test-Path -LiteralPath (Join-Path $Source $need))) {
        throw "source is not a Workshop item - missing $need in $Source"
    }
}

# --- safety: never /MIR through a link --------------------------------------
# If the destination is a junction or symlink, /MIR would mirror into whatever
# it points at and delete anything there that is not in the source. Today that
# would have been the repo itself.
if (Test-Path -LiteralPath $Dest) {
    $d = Get-Item -LiteralPath $Dest -Force
    if ($d.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw @"
$Dest is a link (-> $($d.Target)), not a folder.
Refusing to /MIR through it. Remove it first, link-only:
    cmd /c rmdir "$Dest"
(never Remove-Item -Recurse on a junction - that follows into the target)
"@
    }
}

$srcFiles = (Get-ChildItem -LiteralPath $Source -Recurse -File -Force).Count
Write-Host "source: $Source  ($srcFiles files)"
Write-Host "stage:  $Dest"

# Not $args - that is an automatic variable and splatting it is asking for
# trouble.
$rcArgs = @($Source, $Dest, '/MIR', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/R:2', '/W:2')
if ($DryRun) { $rcArgs += '/L' }

& robocopy @rcArgs | Out-Null
$rc = $LASTEXITCODE

# robocopy: 0-7 success (bit 0 copied, 1 extra, 2 mismatched, 3 = 1+2), 8+ fail.
if ($rc -ge 8) { throw "robocopy failed with exit $rc" }

if ($DryRun) {
    Write-Host "DRY RUN - nothing written (robocopy $rc)" -ForegroundColor Yellow
    return
}

# --- verify ------------------------------------------------------------------
$dstFiles = (Get-ChildItem -LiteralPath $Dest -Recurse -File -Force).Count
$idLine   = (Get-Content -LiteralPath (Join-Path $Dest 'workshop.txt') |
             Select-String '^id=').Line
$mods     = (Get-ChildItem -LiteralPath (Join-Path $Dest 'Contents\mods') -Directory).Count

Write-Host ''
if ($dstFiles -eq $srcFiles) {
    Write-Host "staged $dstFiles files, $mods mods - $idLine" -ForegroundColor Green
    Write-Host 'ready to upload from the in-game Workshop tool.'
} else {
    Write-Host "MISMATCH: source $srcFiles files, stage $dstFiles" -ForegroundColor Red
    exit 1
}
