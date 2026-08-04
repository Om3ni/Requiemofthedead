# check-deploy.ps1 - "am I actually running my own code?"
#
# WHY THIS EXISTS (2026-08-03): the repo is the source of truth and NOTHING runs
# from it. The server reads its own Steam workshop cache, the client reads a
# different one, and Steam owns both - it re-validates the workshop item on
# launch and rewrites those trees with the PUBLISHED build, silently reverting
# whatever sync-trees last pushed. Nothing anywhere reports this. The trees just
# quietly stop being your code.
#
# What that cost, in one day: an hour reading UI internals for a "bug" where the
# Vehicles tab sat on "Requesting fleet..." forever. The panel was fine. The
# dedi was running a reverted RCServer.lua with no fleet handler, so the request
# matched nothing and was dropped in silence. Later the same tree was found
# EMPTY - fifteen mod folders, zero files - after another Steam pass.
#
# So: one glanceable answer, before any debugging starts. Leave it running in
# the corner of a screen. Green means the thing you are testing is the thing you
# wrote. Red means stop and re-deploy, and do not spend another minute reading
# code that is not the code that is running.
#
# WHAT IT COMPARES. Repo Contents\mods\<Mod>\... against each tree's
# mods\<Mod>\... - Steam strips the "Contents" wrapper on upload, which is the
# one-level offset sync-trees.ps1 also owns. A file counts as current when its
# byte length matches AND (for anything under -HashUnder) its MD5 matches.
# Large binaries - RFTDEchoes' .ogg and .fbx - are compared by length only:
# hashing 130MB every few seconds to detect a change to audio that is never
# hand-edited is the wrong trade.
#
# Usage:
#   tools\check-deploy.bat              watch, refresh every 10s (double-click)
#   tools\check-deploy.bat -Once        one pass, exit 1 if anything is stale
#   tools\check-deploy.bat -Interval 30 watch, slower
#   tools\check-deploy.ps1 -NoServer    skip a tree you are not using

[CmdletBinding()]
param(
    [switch] $Once,
    [int]    $Interval = 10,
    [switch] $NoServer,
    [switch] $NoClient,
    [int]    $HashUnder = 524288
)

$ErrorActionPreference = 'Stop'

$RepoMods = Join-Path $PSScriptRoot '..\RequiemOfTheDead\Contents\mods'
$RepoMods = [IO.Path]::GetFullPath($RepoMods)

$Trees = @()
if (-not $NoServer) {
    $Trees += [pscustomobject]@{
        Name = 'SERVER'
        # NOT the Steam workshop cache any more - see sync-trees.ps1's header.
        # The dedi loads RotD from <userdir>\mods, which Steam never touches.
        Path = 'C:\Mosaic\pzdata\mods'
    }
}
if (-not $NoClient) {
    $Trees += [pscustomobject]@{
        Name = 'CLIENT'
        # Also off Steam's leash: Steam deleted its own cached copy of the item
        # unprompted on 2026-08-03. <userdir>\mods is the one source it does not
        # manage. Stay UNSUBSCRIBED on this client while iterating - an installed
        # workshop item is searched first and would shadow this silently.
        Path = "$env:USERPROFILE\Zomboid\mods"
    }
}

# Index one mod folder as relativePath -> FileInfo. Returns $null when the
# folder does not exist at all, which is a different answer from "empty".
function Get-ModIndex {
    param([string] $Root)
    if (-not (Test-Path -LiteralPath $Root)) { return $null }
    $idx = @{}
    foreach ($f in Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue) {
        $rel = $f.FullName.Substring($Root.Length).TrimStart('\')
        $idx[$rel] = $f
    }
    return $idx
}

$md5 = [Security.Cryptography.MD5]::Create()
function Get-Hash {
    param([string] $Path)
    try {
        $fs = [IO.File]::OpenRead($Path)
        try { return [BitConverter]::ToString($md5.ComputeHash($fs)) }
        finally { $fs.Dispose() }
    } catch { return $null }
}

# Compare one mod. Returns @{ Missing; Behind; Extra } where Behind counts files
# that exist in both but differ.
function Compare-Mod {
    param($RepoIdx, $TreeIdx)
    if ($null -eq $TreeIdx) { return $null }   # folder absent entirely
    $missing = 0; $behind = 0
    foreach ($rel in $RepoIdx.Keys) {
        $a = $RepoIdx[$rel]
        $b = $TreeIdx[$rel]
        if ($null -eq $b) { $missing++; continue }
        if ($a.Length -ne $b.Length) { $behind++; continue }
        if ($a.Length -le $HashUnder) {
            if ((Get-Hash $a.FullName) -ne (Get-Hash $b.FullName)) { $behind++ }
        }
    }
    $extra = 0
    foreach ($rel in $TreeIdx.Keys) { if (-not $RepoIdx.ContainsKey($rel)) { $extra++ } }
    return @{ Missing = $missing; Behind = $behind; Extra = $extra }
}

function Invoke-Pass {
    $mods = Get-ChildItem -LiteralPath $RepoMods -Directory | Sort-Object Name
    $repoIdx = @{}
    foreach ($m in $mods) { $repoIdx[$m.Name] = Get-ModIndex $m.FullName }

    $stamp = (Get-Date).ToString('HH:mm:ss')
    Write-Host ''
    Write-Host "  RotD deploy check              $stamp" -ForegroundColor White
    Write-Host ('  ' + ('-' * 44)) -ForegroundColor DarkGray

    $header = '  {0,-18}' -f 'MOD'
    foreach ($t in $Trees) { $header += ('{0,-13}' -f $t.Name) }
    Write-Host $header -ForegroundColor DarkGray

    $totals = @{}
    foreach ($t in $Trees) { $totals[$t.Name] = @{ Mods = 0; Files = 0; Gone = 0 } }

    foreach ($m in $mods) {
        $short = $m.Name -replace '^RFTD', ''
        if ($short.Length -gt 17) { $short = $short.Substring(0, 16) + '.' }
        Write-Host ('  {0,-18}' -f $short) -NoNewline

        foreach ($t in $Trees) {
            $dest = Join-Path $t.Path $m.Name

            # A junction IS the repo - there is nothing to compare and nothing
            # that can go stale. Say so rather than reporting a hollow "ok",
            # because "linked" and "copied and currently matching" are different
            # promises about tomorrow.
            if (Test-Path -LiteralPath $dest) {
                $di = Get-Item -LiteralPath $dest -Force
                if ($di.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                    Write-Host ('{0,-13}' -f 'link') -ForegroundColor Cyan -NoNewline
                    continue
                }
            }

            $treeIdx = Get-ModIndex $dest
            $r = Compare-Mod $repoIdx[$m.Name] $treeIdx

            if ($null -eq $r) {
                Write-Host ('{0,-13}' -f 'ABSENT') -ForegroundColor Magenta -NoNewline
                $totals[$t.Name].Gone++
                $totals[$t.Name].Mods++
            }
            elseif ($r.Missing -eq 0 -and $r.Behind -eq 0) {
                Write-Host ('{0,-13}' -f 'ok') -ForegroundColor Green -NoNewline
            }
            else {
                $n = $r.Missing + $r.Behind
                $lbl = if ($r.Missing -gt 0 -and $r.Behind -eq 0) { "MISSING $n" } else { "STALE $n" }
                Write-Host ('{0,-13}' -f $lbl) -ForegroundColor Red -NoNewline
                $totals[$t.Name].Mods++
                $totals[$t.Name].Files += $n
            }
        }
        Write-Host ''
    }

    Write-Host ('  ' + ('-' * 44)) -ForegroundColor DarkGray
    $bad = 0
    foreach ($t in $Trees) {
        $s = $totals[$t.Name]
        if ($s.Mods -eq 0) {
            Write-Host ('  {0,-8} up to date' -f $t.Name) -ForegroundColor Green
        } else {
            $bad++
            $msg = '  {0,-8} {1} mod(s) behind' -f $t.Name, $s.Mods
            if ($s.Files -gt 0) { $msg += ", $($s.Files) file(s)" }
            if ($s.Gone -gt 0)  { $msg += ", $($s.Gone) ABSENT" }
            Write-Host $msg -ForegroundColor Red
        }
    }
    if ($bad -gt 0) {
        Write-Host ''
        Write-Host '  -> tools\launch-mosaic.ps1 -Restart' -ForegroundColor Yellow
        Write-Host '     (sync alone will not hold; Steam reverts on launch)' -ForegroundColor DarkYellow
    }
    return $bad
}

if ($Once) {
    $bad = Invoke-Pass
    exit ([int]($bad -gt 0))
}

while ($true) {
    Clear-Host
    try { [void](Invoke-Pass) }
    catch { Write-Host "  check failed: $_" -ForegroundColor Red }
    Write-Host ''
    Write-Host "  refreshing every ${Interval}s - Ctrl+C to stop" -ForegroundColor DarkGray
    Start-Sleep -Seconds $Interval
}
