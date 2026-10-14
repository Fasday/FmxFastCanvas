<#
.SYNOPSIS
  Screenshots of benchmark scenes for a list of canvases, for comparing builds or canvases (compare-shots.ps1).

.DESCRIPTION
  Runs FmxCanvasBench once per canvas and scene (short runs: the screenshot shows the animation frame --shot-frame,
  60 by default, whatever the timing) and writes <OutDir>\<scene>_<canvas>.png. The bench serializes its runs
  machine-wide; its windows must not be covered while it takes the screenshot.

.EXAMPLE
  .\tools\shots.ps1 -Exe bin-base\Win64\Release\FmxCanvasBench.exe -OutDir results\raw\shots-base -Canvases fc,fcvk
#>
param(
  [Parameter(Mandatory = $true)] [string] $Exe,
  [Parameter(Mandatory = $true)] [string] $OutDir,
  [string[]] $Canvases = @('fc', 'fcdx12', 'fcvk'),
  [string[]] $Scenes = @('rects', 'text', 'textedge', 'paragraph', 'roundrects', 'ellipses', 'lines', 'strokes',
    'gradients', 'paths', 'bitmaps', 'clip', 'aa', 'rare', 'controls'),
  [string] $Monitor = '1',
  # Physical pixels; at 150 % display scaling sizes that are not multiples of 3 never match exactly (the bench
  # waits for the size and stalls).
  [string] $Size = '1920x1080',
  [string] $Preset = 'light',
  [string[]] $Extra = @()
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$exePath = (Resolve-Path $Exe).Path
foreach ($canvas in $Canvases) {
  foreach ($scene in $Scenes) {
    $png = Join-Path (Resolve-Path $OutDir).Path "$($scene)_$($canvas).png"
    $args = @("--canvas=$canvas", "--scene=$scene", "--preset=$Preset", "--size=$Size", "--monitor=$Monitor",
      '--warmup=0.5', '--duration=0.5', "--screenshot=$png") + $Extra
    $out = & $exePath @args 2>&1
    if ($LASTEXITCODE -ne 0) {
      Write-Warning "$canvas $scene exit $LASTEXITCODE`n$($out | Out-String)"
    } elseif (-not (Test-Path $png)) {
      Write-Warning "$canvas $scene no screenshot"
    } else {
      Write-Host "$canvas $scene ok"
    }
  }
}
