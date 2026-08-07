# upload-link.ps1 - point the Workshop staging folder straight at the repo for
# an upload, and take it away again afterwards.
#
# WHAT THIS IS FOR. The PZ uploader reads
# %USERPROFILE%\Zomboid\Workshop\<Name>\, expecting workshop.txt and preview.png
# beside a Contents\mods\ tree. stage-upload.ps1 fills that with a real COPY;
# this links it to the repo instead, so what you publish is what you have right
# now with no mirror step to forget.
#
# THE LINK IS A LOADED GUN AND THAT IS WHY THERE ARE TWO SCRIPTS.
#
# While Contents\mods exists, the game registers it as a STAGED WORKSHOP ITEM,
# and staged items are searched FIRST - ahead of installed workshop items and
# ahead of <userdir>\mods, where deploy.bat puts your code
# (ZomboidFileSystem.getAllModFolders, order "workshop,steam,mods";
# ChooseGameInfo.readModInfo breaks the duplicate-id tie by lowest index). So
# for as long as this link is up, every mod id in the repo is registered twice
# and the staged copy WINS. That is the exact failure that cost a session on
# 2026-08-05: a client quietly ran an upload snapshot while a correct-looking
# deployed tree sat underneath it, and nothing anywhere said so.
#
# A LINKED STAGING FOLDER IS ALSO NOT SAFE TO PLAY ON, for a second and
# unrelated reason: RFTDEchoes ships AnimSets, and AdvancedAnimator's checksum
# pass canonicalizes the folder but looks its files up by the LINK path, which
# fails at dedi boot and again on the client at server-join
# (see stage-upload.ps1's header, where that is why staging is a copy).
#
# Both problems have the same cure and it is one command: unlink when the upload
# finishes. Link, upload, unlink. Do not leave it up, do not play with it up.
#
# DIRECTION, and why this is still the safe kind of link. It lives in the
# disposable staging tree and points INTO the repo, which is the same direction
# dev-link.ps1 argued for: when Steam or PZ destroys the staging folder - and it
# has - the repo does not notice, because nothing in the repo points anywhere.
# The inverse arrangement is what lost 286 files on 2026-08-02.
#
# TEARDOWN USES rmdir, ALWAYS. Remove-Item -Recurse follows a junction and
# deletes what it points at, which here is the payload itself. That single line
# is the whole reason the unlink is a script and not a hand gesture.
#
# Usage:
#   tools\upload-link.bat            link staging -> repo, ready to upload
#   tools\upload-unlink.bat          remove the link (run this straight after)
#   tools\upload-link.ps1 -Status    report what staging currently is
#
# Exit: 0 ok, 1 failed, 2 refused.

[CmdletBinding()]
param(
    [switch] $Down,
    [switch] $Status,
    [string] $StageRoot = "$env:USERPROFILE\Zomboid\Workshop",
    [string] $Name      = 'RequiemOfTheDead'
)

$ErrorActionPreference = 'Stop'

$RepoMods = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\RequiemOfTheDead\Contents\mods'))
$Item     = Join-Path $StageRoot $Name
$Contents = Join-Path $Item 'Contents'
$Mods     = Join-Path $Contents 'mods'

function Say  { param($m, $c = 'Gray') Write-Host $m -ForegroundColor $c }
function Fail { param($m) Write-Host "ABORT: $m" -ForegroundColor Red; exit 2 }

function Get-ModsState {
    if (-not (Test-Path -LiteralPath $Mods)) { return 'absent' }
    $i = Get-Item -LiteralPath $Mods -Force
    if ($i.Attributes -band [IO.FileAttributes]::ReparsePoint) { return 'link' }
    return 'copy'
}

# Same guard as deploy.bat, same reason: swapping what the staging folder means
# under a running game gives it a half-registered mod set.
function Assert-NotRunning {
    $live = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
              Where-Object {
                  $_.ProcessId -ne $PID -and (
                      ($_.Name -like 'ProjectZomboid*.exe') -or
                      ($_.Name -eq 'java.exe' -and $_.CommandLine -match 'zombie\.network\.GameServer')
                  )
              })
    if (-not $live.Count) { return }
    foreach ($p in $live) {
        $what = if ($p.Name -eq 'java.exe') { 'dedicated server' } else { 'client' }
        Say ("  PID {0,-6} {1}" -f $p.ProcessId, $what) 'Red'
    }
    Fail 'Project Zomboid is running - stop it first'
}

Write-Host ''
Say "repo     $RepoMods" 'DarkGray'
Say "staging  $Item" 'DarkGray'

# ---------------------------------------------------------------------------
if ($Status) {
    $state = Get-ModsState
    switch ($state) {
        'link' {
            $t = (Get-Item -LiteralPath $Mods -Force).Target
            Say "  Contents\mods is a LINK -> $t" 'Yellow'
            Say '  The staged item is LIVE and outranks your deployed trees.' 'Yellow'
            Say '  Run tools\upload-unlink.bat before playing or testing.' 'Yellow'
        }
        'copy'   { Say '  Contents\mods is a real folder (a staged snapshot, also live)' 'Yellow' }
        'absent' { Say '  Contents\mods is absent - staging is deregistered, nothing shadows' 'Green' }
    }
    $parked = Join-Path $Contents 'mods.parked'
    if (Test-Path -LiteralPath $parked) { Say "  (a parked snapshot is present: $parked)" 'DarkGray' }
    exit 0
}

# ---------------------------------------------------------------------------
if ($Down) {
    $state = Get-ModsState
    if ($state -eq 'absent') { Say '  already unlinked - nothing registered' 'Green'; Write-Host ''; exit 0 }

    if ($state -eq 'copy') {
        Say '  Contents\mods is a REAL FOLDER, not a link.' 'Red'
        Say '  This script only removes links it made - a real folder is either a' 'Yellow'
        Say '  stage-upload snapshot or hand-made, and deleting it is not its call.' 'Yellow'
        Say '  Park it instead:  tools\deploy.bat  (renames it to mods.parked)' 'Yellow'
        exit 2
    }

    Assert-NotRunning

    # rmdir, never Remove-Item -Recurse: this junction points at the payload.
    $before = (Get-ChildItem -LiteralPath $RepoMods -Recurse -File -Force).Count
    cmd /c rmdir "$Mods" | Out-Null
    if (Test-Path -LiteralPath $Mods) { Say '  FAILED - the link is still there' 'Red'; exit 1 }

    # Prove the teardown did not reach through into the repo. Cheap, and the one
    # thing worth being certain of after removing a link that points at it.
    $after = (Get-ChildItem -LiteralPath $RepoMods -Recurse -File -Force).Count
    Say "  unlinked - staging is deregistered" 'Green'
    if ($after -ne $before) {
        Say "  REPO CHANGED during unlink: $before -> $after files. STOP AND CHECK." 'Red'
        exit 1
    }
    Say "  repo intact: $after files" 'Green'
    Write-Host ''
    Say 'Deployed trees are authoritative again. tools\deploy.bat if in doubt.' 'DarkGray'
    exit 0
}

# ---------------------------------------------------------------------------
# Link
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $RepoMods)) { Fail "repo payload not found: $RepoMods" }

# The uploader needs these BESIDE Contents, and they are not ours to invent -
# a missing workshop.txt is how an upload becomes a new item instead of an
# update to the existing one.
foreach ($need in 'workshop.txt') {
    if (-not (Test-Path -LiteralPath (Join-Path $Item $need))) {
        Fail "$Item is missing $need - that file identifies the Workshop item, refusing to stage without it"
    }
}

Assert-NotRunning

$state = Get-ModsState
if ($state -eq 'link') {
    $t = (Get-Item -LiteralPath $Mods -Force).Target
    if ($t -eq $RepoMods) { Say '  already linked to the repo' 'Green' }
    else { Fail "Contents\mods is already a link, but to $t - remove it first (tools\upload-unlink.bat)" }
} elseif ($state -eq 'copy') {
    Fail "Contents\mods is a real folder (a stage-upload snapshot). Move or park it first - this script will not delete a folder it did not create."
} else {
    if (-not (Test-Path -LiteralPath $Contents)) { New-Item -ItemType Directory -Force -Path $Contents | Out-Null }
    New-Item -ItemType Junction -Path $Mods -Target $RepoMods | Out-Null
    Say '  linked  Contents\mods -> repo' 'Green'
}

$n = (Get-ChildItem -LiteralPath $Mods -Recurse -File -Force).Count
Say "  $n files visible through the link" 'DarkGray'

Write-Host ''
Say 'READY TO UPLOAD.' 'Green'
Say ''
Say 'While this link is up:' 'Yellow'
Say '  * the staged item OUTRANKS your deployed trees - the game will load THIS,' 'Yellow'
Say '    not %USERPROFILE%\Zomboid\mods, for every mod id in the repo' 'Yellow'
Say '  * RFTDEchoes ships AnimSets, which do not survive being read through a' 'Yellow'
Say '    link - expect failures at dedi boot and at server-join' 'Yellow'
Say ''
Say 'Upload, then run:  tools\upload-unlink.bat' 'Cyan'
exit 0
