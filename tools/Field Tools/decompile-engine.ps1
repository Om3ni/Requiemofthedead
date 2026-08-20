# decompile-engine.ps1 - regenerate the Project Zomboid engine decompile.
#
# WHY THIS EXISTS: every engine fact in docs/ is cited by file:line against a
# decompile. When the game updates those citations silently become
# wrong-but-plausible - the file still exists, the line still has code on it,
# it's just different code now. So the decompile is a versioned artifact, not a
# one-off: keep the old tree, build a new one beside it, diff them.
#
# CFR 0.152 is pinned deliberately. It produced the 42.19.1 tree, so reusing it
# means a tree diff shows real engine changes instead of decompiler-formatting
# churn. Do NOT bump the decompiler in the same step as an engine bump - you
# lose the ability to tell which one moved. It reads Java 25 bytecode (class
# major 69, new in 42.20) without complaint.
#
# The CLIENT jar is the right source even for server-only questions: PZ ships
# zombie.network.* (GameServer, UdpConnection, ...) inside projectzomboid.jar.
# There is no separate server jar to decompile.
#
# WHY CHUNKED: one CFR pass over the whole 23.7k-class jar exhausts the heap -
# it accumulates per-class analysis state for the entire run and dies in
# zombie.scripting even at 4g (measured). Chunking per top-level package bounds
# peak memory to the largest single package, makes the run resumable, and stops
# one pathological class from taking the whole tree down with it.
#
# Chunk order is deliberate: PZ-authored and Lua-facing packages first, vendored
# libraries last. The tree becomes useful for engine questions long before the
# lwjgl/kotlin/netty bulk finishes.
#
# Output goes OUTSIDE any shipping mod dir and is gitignored
# (PZ_Engine_Decompiled_*/). Expect ~13.7k .java files and a few GB.
#
# Usage:
#   .\tools\decompile-engine.ps1 -Version 42.20.0-a2947723ca
# Take the version string from the server debug log line "version=42.20.0 <hash>"
# so the tree is named after the build it actually came from, not a guess.
# Re-running resumes: completed chunks are skipped.

[CmdletBinding()]
param(
    [string]$Jar = "D:\Steam\steamapps\common\ProjectZomboid\projectzomboid.jar",

    # Pinned decompiler - read the header before changing.
    [string]$Cfr = "C:\VSCodeProjects\PZMod\zz_Archived\tools\cfr-0.152.jar",

    [Parameter(Mandatory = $true)]
    [string]$Version,

    [string]$OutRoot = "C:\VSCodeProjects\RequiemoftheDead",

    # Per-chunk heap. The largest package (org, ~7.5k classes) is the binding
    # constraint, not zombie.
    [int]$HeapGb = 8,

    # Only decompile PZ-authored + Lua-facing packages, skipping vendored libs.
    # Much faster when you just need to check an engine fact.
    [switch]$PzOnly,

    # Re-decompile chunks already marked complete.
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

foreach ($p in @($Jar, $Cfr)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "Not found: $p" }
}

# PZ-authored, plus se.* (the Kahlua Lua VM - vendored but load-bearing for any
# modding question, so it counts as relevant).
$pzPackages = @('zombie', 'se', 'generation', 'astar', 'fmod', 'imgui', 'jassimp', 'N3D', 'de', 'pl')
# Vendored: lwjgl/joml (org), google/steamworks (com), trove (gnu), netty (io),
# kotlin stdlib, oshi, okhttp3, okio, javax.
$libPackages = @('org', 'com', 'gnu', 'io', 'kotlin', 'oshi', 'okhttp3', 'okio', 'javax')

$chunks = if ($PzOnly) { $pzPackages } else { $pzPackages + $libPackages }

$outDir = Join-Path $OutRoot "PZ_Engine_Decompiled_$Version"
$stateDir = Join-Path $outDir ".chunks"
$null = New-Item -ItemType Directory -Path $stateDir -Force

# Record what this tree actually is. Without this a decompile directory is an
# undated pile of Java with no way to tell which build produced it.
$jarInfo = Get-Item -LiteralPath $Jar
@(
    "engine_version : $Version"
    "source_jar     : $Jar"
    "jar_bytes      : $($jarInfo.Length)"
    "jar_mtime      : $($jarInfo.LastWriteTime.ToString('o'))"
    "jar_sha256     : $((Get-FileHash -LiteralPath $Jar -Algorithm SHA256).Hash)"
    "class_major    : 69 (Java 25)"
    "decompiler     : $(Split-Path -Leaf $Cfr)"
    "scope          : $(if ($PzOnly) { 'PZ-authored only' } else { 'full jar' })"
    "generated_utc  : $((Get-Date).ToUniversalTime().ToString('o'))"
) | Set-Content -LiteralPath (Join-Path $outDir "DECOMPILE-PROVENANCE.txt") -Encoding utf8

$total = [System.Diagnostics.Stopwatch]::StartNew()
$failed = @()

foreach ($pkg in $chunks) {
    $marker = Join-Path $stateDir "$pkg.done"
    if ((Test-Path -LiteralPath $marker) -and -not $Force) {
        Write-Host "[skip] $pkg (already complete)"
        continue
    }

    $log = Join-Path $stateDir "$pkg.log"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Host ("[run ] {0,-10} ..." -f $pkg) -NoNewline

    # Anchored on the DOTTED fqn: --jarfilter matches package.Class, not the
    # zip path, and is unanchored by default - bare "astar" also catches
    # anything with astar as a substring elsewhere in the jar.
    & java "-Xmx${HeapGb}g" -jar $Cfr $Jar --jarfilter "^$pkg\..*" --outputdir $outDir --silent true *> $log
    $sw.Stop()

    $oom = Select-String -LiteralPath $log -Pattern 'OutOfMemoryError' -Quiet -ErrorAction SilentlyContinue
    if ($oom) {
        # --lomem trades speed for a smaller working set. Only reached on a
        # chunk that already failed, so the cost is irrelevant.
        Write-Host " OOM, retrying with --lomem" -NoNewline
        & java "-Xmx${HeapGb}g" -jar $Cfr $Jar --jarfilter "^$pkg\..*" --outputdir $outDir --silent true --lomem true *> $log
        $oom = Select-String -LiteralPath $log -Pattern 'OutOfMemoryError' -Quiet -ErrorAction SilentlyContinue
    }

    $n = (Get-ChildItem -LiteralPath $outDir -Filter *.java -Recurse -ErrorAction SilentlyContinue |
          Measure-Object).Count

    if ($oom) {
        $failed += $pkg
        Write-Host (" FAILED (heap) after {0:n1}s" -f $sw.Elapsed.TotalSeconds)
    } else {
        Set-Content -LiteralPath $marker -Value $sw.Elapsed.ToString() -Encoding utf8
        Write-Host (" ok {0,6:n1}s  (tree now {1} .java)" -f $sw.Elapsed.TotalSeconds, $n)
    }
}

$total.Stop()
$count = (Get-ChildItem -LiteralPath $outDir -Filter *.java -Recurse -ErrorAction SilentlyContinue |
          Measure-Object).Count
Write-Host ""
Write-Host ("Done in {0:n1} min - {1} .java files -> {2}" -f $total.Elapsed.TotalMinutes, $count, $outDir)

if ($failed.Count -gt 0) {
    Write-Warning ("Chunks that ran out of heap: {0}. Re-run with a larger -HeapGb; completed chunks are skipped." -f ($failed -join ', '))
}
