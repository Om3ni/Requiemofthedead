# sync-trees.ps1 - push the repo payload out to the two trees that actually run it.
#
# WHY THIS EXISTS (2026-08-02): the repo is the source of truth, but neither the
# server nor the client reads it. They read their own Steam workshop download
# caches, and those are DIFFERENT directories:
#
#   server  C:\Mosaic\pzdata\mods
#   client  %USERPROFILE%\Zomboid\mods
#
# STEAM NO LONGER OWNS THE SERVER TREE (2026-08-03). The server target used to
# be the Steam workshop cache, and that was the single biggest source of lost
# time on this project: Steam re-validates the workshop item on launch and
# rewrites that tree with the PUBLISHED build, silently reverting whatever this
# script pushed. It reverted mid-session, and later emptied the tree outright -
# fifteen mod folders, zero files. An hour went into debugging a "UI bug" that
# was a dedi running reverted code with no fleet handler.
#
# The fix is not to fight it. ZomboidFileSystem.getAllModFolders (:504) searches
# three sources - staged workshop, installed workshop, and <userdir>\mods - and
# only the last is added unconditionally; the other two are gated on Steam mode
# and are Steam's to rewrite. So the dev copy lives in C:\Mosaic\pzdata\mods and
# MDS.ini's WorkshopItems no longer lists 3772176444. Steam still manages every
# THIRD-PARTY item on that line (KI5, warthog, defender, damnlib) and still
# updates them normally; it simply has no record of ours to revert.
#
# CONSEQUENCE, deliberately accepted: WorkshopItems is also what tells joining
# clients which items to download, so players are no longer auto-prompted to
# install RotD on this server. Mosaic is a test surface - testers subscribe by
# hand. Put the id back for any run that takes public traffic (and upload first,
# so the clobber is harmless when it comes).
#
# The old Steam cache copy was DELETED rather than left in place: installed
# workshop items are searched BEFORE <userdir>\mods, so a stale copy there would
# shadow this one and nothing would say so.
#
# Both are laid out as <id>\mods\<ModId>\... - Steam strips the "Contents"
# wrapper on upload, so the repo's Contents\mods\ maps onto the target's mods\
# with a one-level offset. Getting that wrong lands everything in mods\mods\.
# This script owns that offset so nobody has to remember it.
#
# HOT RELOAD, and its limits (verified against the 42.20 decompile):
#   server lua  -> edit, sync, then "/reloadlua <file>" on the dedi. The command
#                  walks LuaManager.loaded (absolute paths recorded at load) and
#                  re-runs the file off disk. Needs Capability.ReloadLuaFiles.
#   client lua  -> edit, sync, then reloadLuaFile("media/lua/client/X.lua") in
#                  the client, or the debug-mode LuaFileBrowser window.
#   everything else - media\scripts\*.txt, sandbox-options.txt, AnimSets, models,
#                  sounds - is load-time only. ScriptManager.Load runs inside
#                  Core.ResetLua; no command re-runs it. Those need a restart.
#
#   Do NOT use "/reloadalllua". ReloadAllLuaCommand caches size up front then
#   removes an element per pass while incrementing the index, so it skips every
#   other file and runs off the end. Reload per-file.
#
# The targets are Steam download caches. Steam can overwrite or delete them on
# any item update or validate pass. That is exactly why authoring happens in the
# repo and this script pushes outward - never the reverse.
#
# Usage:
#   tools\sync-trees.ps1 -DryRun          # show what would change, write nothing
#   tools\sync-trees.ps1                  # push everything to both trees
#   tools\sync-trees.ps1 -Lua             # push only .lua - fast reload cycle
#   tools\sync-trees.ps1 -Server          # server tree only
#   tools\sync-trees.ps1 -Client          # client tree only
#   tools\sync-trees.ps1 -Mirror          # also DELETE target files not in repo
#
# Exit: 0 ok, 1 a copy failed, 2 a path is missing.

param(
    [switch]$DryRun,
    [switch]$Lua,
    [switch]$Server,
    [switch]$Client,
    [switch]$Mirror,
    [string]$Source = "C:\VSCodeProjects\RequiemoftheDead\RequiemOfTheDead\Contents\mods",
    # 2026-08-03: the server target is no longer a Steam workshop cache. See the
    # "STEAM NO LONGER OWNS THE SERVER TREE" note in the header.
    [string]$ServerTree = "C:\Mosaic\pzdata\mods",
    [string]$ClientTree = "$env:USERPROFILE\Zomboid\mods"
)

$ErrorActionPreference = "Stop"

function Fail([string]$m) { Write-Host "ABORT: $m" -ForegroundColor Red; exit 2 }

if (-not (Test-Path $Source)) { Fail "source not found: $Source" }

# Default to both trees when neither is named.
if (-not $Server -and -not $Client) { $Server = $true; $Client = $true }

$targets = @()
if ($Server) { $targets += @{ Name = "server"; Path = $ServerTree } }
if ($Client) { $targets += @{ Name = "client"; Path = $ClientTree } }

# robocopy flags. /E recurse incl. empty, /NJH no header, /NP no progress,
# /R:1 /W:1 fail fast rather than hang on a file the running server has open.
$flags = @("/E", "/NJH", "/NP", "/R:1", "/W:1", "/NDL")
if ($Lua)    { $flags += @("/IF", "*.lua") }
if ($Mirror) { $flags += "/PURGE" }
if ($DryRun) { $flags += "/L" }

$srcCount = (Get-ChildItem $Source -Recurse -File -Force | Measure-Object).Count
Write-Host ""
Write-Host "source: $Source ($srcCount files)"
if ($Lua)    { Write-Host "  filter : *.lua only" -ForegroundColor Cyan }
if ($Mirror) { Write-Host "  mirror : target files absent from repo will be DELETED" -ForegroundColor Yellow }
if ($DryRun) { Write-Host "  DRY RUN: nothing will be written" -ForegroundColor Yellow }
Write-Host ""

# CONTENT comparison, used for -DryRun.
#
# robocopy decides by size + timestamp, which is the right call when COPYING and
# actively misleading when ASKING "is this tree correct?". Any sync sets the
# destination's mtime to now, so every file it touched reads as "destination
# newer than repo" (robocopy prints it as `Older`) forever afterwards - and
# Mosaic's dev sync does exactly that on every server launch. That produced two
# separate false "Steam clobbered the tree" alarms on 2026-08-02/03, one of which
# cost a full test cycle.
#
# So a dry run now hashes. It is slower and it is the only answer worth trusting,
# because it reports what is actually DIFFERENT rather than what was recently
# written.
function Compare-Tree {
    param([string]$Src, [string]$Dst, [bool]$LuaOnly)

    $filter  = if ($LuaOnly) { "*.lua" } else { "*" }
    $files   = @(Get-ChildItem -LiteralPath $Src -Recurse -File -Force -Filter $filter)
    $differ  = New-Object System.Collections.Generic.List[string]
    $missing = New-Object System.Collections.Generic.List[string]

    foreach ($f in $files) {
        $rel = $f.FullName.Substring($Src.Length).TrimStart('\')
        $b   = Join-Path $Dst $rel
        if (-not (Test-Path -LiteralPath $b)) { $missing.Add($rel); continue }
        $ha = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
        $hb = (Get-FileHash -LiteralPath $b          -Algorithm SHA256).Hash
        if ($ha -ne $hb) { $differ.Add($rel) }
    }
    [pscustomobject]@{ Total = $files.Count; Differ = $differ; Missing = $missing }
}

$failed = 0
foreach ($t in $targets) {
    if (-not (Test-Path $t.Path)) {
        Write-Host ("{0,-7} SKIP - not found: {1}" -f $t.Name, $t.Path) -ForegroundColor Yellow
        continue
    }

    if ($DryRun) {
        $cmp   = Compare-Tree -Src $Source -Dst $t.Path -LuaOnly:$Lua
        $bad   = $cmp.Differ.Count + $cmp.Missing.Count
        $state = if ($bad -eq 0) { "matches ($($cmp.Total) checked)" } else { "$bad of $($cmp.Total) differ" }
        Write-Host ("{0,-7} {1,-24} {2}" -f $t.Name, $state, $t.Path) `
            -ForegroundColor $(if ($bad -eq 0) { "Green" } else { "Yellow" })
        foreach ($r in $cmp.Missing | Select-Object -First 12) { Write-Host "         MISSING  $r" -ForegroundColor DarkGray }
        foreach ($r in $cmp.Differ  | Select-Object -First 12) { Write-Host "         DIFFER   $r" -ForegroundColor DarkGray }
        if ($bad -gt 24) { Write-Host "         ... and $($bad - 24) more" -ForegroundColor DarkGray }
        continue
    }

    # REFUSE TO COPY THROUGH A LINK (2026-08-03). dev-link.ps1 replaces each mod
    # folder in this tree with a junction back into the repo. robocopy follows
    # junctions by default, so copying here would write INTO the repo through
    # them - and with -Mirror, /PURGE would be deleting inside the repo. The
    # source and destination would be the same files.
    #
    # There is no safe merge of the two modes, so this stops rather than guesses.
    $linked = @(Get-ChildItem -LiteralPath $t.Path -Directory -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
    if ($linked.Count -gt 0) {
        Write-Host ("{0,-7} REFUSED        {1}" -f $t.Name, $t.Path) -ForegroundColor Red
        Write-Host "        $($linked.Count) mod folder(s) here are junctions into the repo (dev-link is active)." -ForegroundColor Yellow
        Write-Host "        Copying would write through them into your working tree." -ForegroundColor Yellow
        Write-Host "        Nothing to sync - the tree already IS the repo. Use:" -ForegroundColor Yellow
        Write-Host "            tools\dev-link.ps1        re-link (also refreshes the Echoes copy)" -ForegroundColor DarkYellow
        Write-Host "            tools\dev-link.ps1 -Down  unlink, then this script works again" -ForegroundColor DarkYellow
        continue
    }

    $out = robocopy $Source $t.Path @flags
    $rc = $LASTEXITCODE

    # robocopy: 0 nothing to do, 1 copied, 2 extras present, 3 both, 8+ failure.
    $changed = @($out | Where-Object { $_ -match '^\s+(New File|Newer|Older|\*EXTRA File)' }).Count
    $status  = if ($rc -ge 8) { "FAILED" } elseif ($rc -eq 0) { "up to date" } else { "$changed file(s)" }
    $colour  = if ($rc -ge 8) { "Red" } elseif ($rc -eq 0) { "DarkGray" } else { "Green" }

    Write-Host ("{0,-7} {1,-14} {2}" -f $t.Name, $status, $t.Path) -ForegroundColor $colour

    if ($rc -ge 8) {
        $failed = 1
        $out | Where-Object { $_ -match 'ERROR' } | Select-Object -First 5 | ForEach-Object { Write-Host "         $_" -ForegroundColor Red }
    }
    elseif ($changed -gt 0) {
        $out | Where-Object { $_ -match '^\s+(New File|Newer|Older|\*EXTRA File)' } |
            Select-Object -First 20 |
            ForEach-Object { Write-Host ("         " + ($_.Trim() -replace '\s+', ' ')) -ForegroundColor DarkGray }
        if ($changed -gt 20) { Write-Host "         ... and $($changed - 20) more" -ForegroundColor DarkGray }
    }
}

Write-Host ""
if ($failed) {
    Write-Host "one or more copies FAILED - if the dedi is running it may hold a file open." -ForegroundColor Red
    exit 1
}
if ($DryRun) { Write-Host "dry run complete (content compared, not timestamps) - rerun without -DryRun to apply." -ForegroundColor Yellow }
else         { Write-Host "synced. server lua: /reloadlua <file>   client lua: reloadLuaFile(""media/lua/client/X.lua"")" -ForegroundColor Green }
exit 0
