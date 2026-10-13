<#
.SYNOPSIS
  Runs the "aa" scene on every canvas and quality, renders the reference and compares.

.DESCRIPTION
  1. FmxCanvasBench --scene=aa for every canvas x quality, appending to <OutDir>\aa.csv and saving
     <OutDir>\aa_<canvas>_<quality>.png.
  2. AaReference with the size, scale and N of those runs (read from the CSV) -> <OutDir>\aa_ref.png.
  3. compare-aa.ps1 per quality -> <OutDir>\sheet_aa_<quality>.png; all rows -> <OutDir>\aa_summary.csv.
  Build both programs first (build.ps1). Runs are serialized by the benchmark's machine-wide mutex.

.EXAMPLE
  .\tools\run-aa.ps1 -Monitor secondary
#>
param(
  [string[]] $Canvases = @('d2d', 'gpu', 'gdip', 'skia', 'skiavk'),
  [string[]] $Qualities = @('default', 'perf', 'high'),
  [string] $Monitor = 'secondary',
  [string] $Size = '1920x1080',
  [double] $Warmup = 1,
  [double] $Duration = 3,
  [int] $K = 8,
  [string] $OutDir = 'results\raw\aa',
  [switch] $SkipRuns
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$bench = Join-Path $root 'bin\Win64\Release\FmxCanvasBench.exe'
$reference = Join-Path $root 'bin\Win64\Release\AaReference.exe'
foreach ($exe in @($bench, $reference)) {
  if (-not (Test-Path $exe)) { throw "Not built: $exe" }
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$csv = Join-Path $OutDir 'aa.csv'

if (-not $SkipRuns) {
  foreach ($q in $Qualities) {
    foreach ($c in $Canvases) {
      $shot = Join-Path $OutDir "aa_${c}_${q}.png"
      & $bench "--canvas=$c" '--scene=aa' "--quality=$q" "--monitor=$Monitor" "--size=$Size" `
        "--warmup=$Warmup" "--duration=$Duration" "--out=$csv" "--screenshot=$shot" | Out-Host
      if ($LASTEXITCODE -eq 2) { throw "FmxCanvasBench rejected the arguments (exit 2)" }
      if ($LASTEXITCODE -ne 0) { Write-Warning "$c / $q exit code $LASTEXITCODE" }
    }
  }
}

$runs = @(Import-Csv $csv | Where-Object scene -eq 'aa')
if ($runs.Count -eq 0) { throw "No aa runs in $csv" }
$last = $runs[-1]
$scales = @($runs | ForEach-Object scale | Select-Object -Unique)
$ns = @($runs | ForEach-Object n | Select-Object -Unique)
if ($scales.Count -ne 1 -or $ns.Count -ne 1) { Write-Warning "Runs differ in scale ($scales) or n ($ns); using the last one" }
$refPng = Join-Path $OutDir 'aa_ref.png'
& $reference "--size=$($last.client_w)x$($last.client_h)" "--scale=$($last.scale)" "--n=$($last.n)" "--k=$K" `
  "--out=$refPng" | Out-Host
if ($LASTEXITCODE -ne 0) { throw "AaReference failed ($LASTEXITCODE)" }

$all = @()
foreach ($q in $Qualities) {
  $images = @($Canvases | ForEach-Object { Join-Path $OutDir "aa_${_}_${q}.png" } | Where-Object { Test-Path $_ })
  if ($images.Count -eq 0) { continue }
  $all += & (Join-Path $PSScriptRoot 'compare-aa.ps1') -Reference $refPng -Images $images -Results $csv `
    -Sheet (Join-Path $OutDir "sheet_aa_$q.png")
}
$all | Export-Csv -NoTypeInformation -Path (Join-Path $OutDir 'aa_summary.csv')
$all | Format-Table Canvas, Quality, GeomAA, Status, FrameMs, MAE, EdgeMAE, P99, AbovePct, TextMAE -AutoSize
