<#
.SYNOPSIS
  Summarizes a raw benchmark run (tools\run-bench.ps1) into <Out>.csv and <Out>.md.

.DESCRIPTION
  Reads <Raw>\runs.csv (one row per run; -Raw may also point to a CSV file with the same schema)
  and writes:
  - <Out>.csv: one row per canvas x scene x preset (x N) x mode with the median over the repeats
    of fps, frame_ms_median/p95/p99/max, record_ms_median, end_ms_median, interval_ms_p99,
    in_budget_pct, missed_intervals, cpu_paint_ms_median, ws_end_mb; frame_ms_median_spread =
    max - min of frame_ms_median over the repeats (spread_pct relative to the median); the frame
    time ratio vs the baseline canvas. N is part of the key so that --n sweeps are not merged.
  - <Out>.md: environment, warnings, throughput and paced tables (never mixed) with ratios vs the
    baseline canvas, record/EndScene split, screenshot comparison (if <Raw>\shots exists, via
    compare-shots.ps1) and repeat spread notes.
  Only rows with status = ok and canvas_ok = 1 enter the statistics, unless -IncludeFailed.
  Numbers are parsed and written with the invariant culture ('.' as decimal separator).
  Outputs are UTF-8 without BOM with LF line endings. Default -Out: results\<name of the raw dir>.

.EXAMPLE
  .\tools\summarize-bench.ps1 -Raw results\raw\2026-10-06_baseline
  .\tools\summarize-bench.ps1 -Raw results\raw\2026-10-06_check -Out $env:TEMP\check
#>
param(
  [Parameter(Mandatory = $true)] [string] $Raw,
  [string] $Out = '',
  [string] $Baseline = 'd2d',
  [double] $SpreadPct = 10,
  [double] $ShotDiffPct = 1,
  [switch] $IncludeFailed
)

$ErrorActionPreference = 'Stop'

$Inv = [Globalization.CultureInfo]::InvariantCulture
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

$PresetOrder = @('light', 'medium', 'heavy')
$ModeOrder = @('throughput', 'paced')
# Medians over the repeats; Dec = decimals in the summary CSV.
$Metrics = @(
  @{ Name = 'fps'; Dec = 2 },
  @{ Name = 'frame_ms_median'; Dec = 3 },
  @{ Name = 'frame_ms_p95'; Dec = 3 },
  @{ Name = 'frame_ms_p99'; Dec = 3 },
  @{ Name = 'frame_ms_max'; Dec = 3 },
  @{ Name = 'record_ms_median'; Dec = 3 },
  @{ Name = 'end_ms_median'; Dec = 3 },
  @{ Name = 'interval_ms_p99'; Dec = 3 },
  @{ Name = 'in_budget_pct'; Dec = 2 },
  @{ Name = 'missed_intervals'; Dec = 1 },
  @{ Name = 'cpu_paint_ms_median'; Dec = 3 },
  @{ Name = 'ws_end_mb'; Dec = 1 }
)

function ConvertTo-Num([string] $Text) {
  $v = 0.0
  if ($Text -and [double]::TryParse($Text, [Globalization.NumberStyles]::Float, $Inv, [ref]$v)) { return $v }
  $null
}

function Get-Median([double[]] $Values) {
  $s = [double[]]@($Values | Sort-Object)
  $n = $s.Count
  if ($n -eq 0) { return $null }
  if ($n % 2 -eq 1) { return $s[[int](($n - 1) / 2)] }
  ($s[[int]($n / 2) - 1] + $s[[int]($n / 2)]) / 2
}

function Format-Fixed($Value, [int] $Dec) {
  if ($null -eq $Value) { return '' }
  ([double]$Value).ToString("F$Dec", $Inv)
}

function Format-Ms($Value) {
  # About three significant digits.
  if ($null -eq $Value) { return '-' }
  $v = [double]$Value
  $dec = if ($v -ge 100) { 0 } elseif ($v -ge 10) { 1 } elseif ($v -ge 1) { 2 } else { 3 }
  $v.ToString("F$dec", $Inv)
}

function Format-CsvValue([string] $Value) {
  if ($Value -match '[",\r\n]') { '"' + $Value.Replace('"', '""') + '"' } else { $Value }
}

function Format-Md([string] $Value) {
  $Value.Replace('|', '\|')
}

function Get-RelPath([string] $Path) {
  $full = [IO.Path]::GetFullPath($Path)
  if ($full.StartsWith($Root + '\', [StringComparison]::OrdinalIgnoreCase)) {
    return $full.Substring($Root.Length + 1).Replace('\', '/')
  }
  $full
}

function Get-Distinct([object[]] $Rows, [string] $Column) {
  @($Rows | ForEach-Object { [string]$_.$Column } | Where-Object { $_ -ne '' } | Select-Object -Unique)
}

function Get-Order([string[]] $Values, [string[]] $Preferred) {
  $known = @($Preferred | Where-Object { $Values -contains $_ })
  $other = @($Values | Where-Object { $Preferred -notcontains $_ })
  @($known) + @($other)
}

function New-MdTable([string[]] $Header, [string[]] $Align, [object[]] $Rows) {
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('| ' + (($Header | ForEach-Object { Format-Md $_ }) -join ' | ') + ' |')
  $lines.Add('|' + (($Align | ForEach-Object { if ($_ -eq 'r') { '---:' } else { '---' } }) -join '|') + '|')
  foreach ($r in $Rows) { $lines.Add('| ' + (($r | ForEach-Object { Format-Md ([string]$_) }) -join ' | ') + ' |') }
  $lines.ToArray()
}

# --- Input ---------------------------------------------------------------------------------------

$rawItem = Get-Item -LiteralPath (Resolve-Path $Raw).Path
if ($rawItem.PSIsContainer) {
  $csvPath = Join-Path $rawItem.FullName 'runs.csv'
  $name = $rawItem.Name
  $shotDir = Join-Path $rawItem.FullName 'shots'
} else {
  $csvPath = $rawItem.FullName
  $name = [IO.Path]::GetFileNameWithoutExtension($rawItem.Name)
  $shotDir = $null
}
if (-not (Test-Path -LiteralPath $csvPath -PathType Leaf)) { throw "Not found: $csvPath" }
if (-not $Out) { $Out = Join-Path $Root "results\$name" }
$Out = [IO.Path]::GetFullPath($(if ([IO.Path]::IsPathRooted($Out)) { $Out } else { Join-Path (Get-Location).Path $Out }))
New-Item -ItemType Directory -Force -Path (Split-Path $Out -Parent) | Out-Null

$all = @(Import-Csv -LiteralPath $csvPath -Encoding UTF8)
if ($all.Count -eq 0) { throw "$csvPath has no rows" }
$columns = @($all[0].PSObject.Properties | ForEach-Object { $_.Name })
foreach ($c in @('canvas', 'scene', 'preset', 'n', 'mode', 'status', 'canvas_ok', 'commit') + @($Metrics | ForEach-Object { $_.Name })) {
  if ($columns -notcontains $c) { throw "$csvPath has no column '$c' (not a FmxCanvasBench result CSV?)" }
}

$bad = @($all | Where-Object { $_.status -ne 'ok' -or $_.canvas_ok -ne '1' })
$used = if ($IncludeFailed) { $all } else { @($all | Where-Object { $_.status -eq 'ok' -and $_.canvas_ok -eq '1' }) }

$canvases = @(Get-Order (Get-Distinct $all 'canvas') @($Baseline))
$scenes = @(Get-Distinct $all 'scene')
$presets = @(Get-Order (Get-Distinct $all 'preset') $PresetOrder)
$modes = @(Get-Order (Get-Distinct $all 'mode') $ModeOrder)
$hasBaseline = $canvases -contains $Baseline

function Get-RowKey($Row) { "$($Row.scene)|$($Row.preset)|$($Row.n)" }

# Distinct scene/preset/N combinations of the rows, in matrix order (N ascending).
function Get-RowKeys([object[]] $Rows) {
  $seen = @{}
  $list = @()
  foreach ($r in $Rows) {
    $k = Get-RowKey $r
    if ($seen.ContainsKey($k)) { continue }
    $seen[$k] = $true
    $n = ConvertTo-Num $r.n
    $list += [pscustomobject]@{
      Key = $k; Scene = $r.scene; Preset = $r.preset; N = $r.n
      SceneIdx = [array]::IndexOf($scenes, $r.scene); PresetIdx = [array]::IndexOf($presets, $r.preset)
      NNum = $(if ($null -ne $n) { $n } else { 0 })
    }
  }
  @($list | Sort-Object SceneIdx, PresetIdx, NNum)
}

function Get-ModeRowKeys([string] $Mode) { Get-RowKeys @($all | Where-Object { $_.mode -eq $Mode }) }

# --- Cells ---------------------------------------------------------------------------------------

$cells = @{}
foreach ($g in ($used | Group-Object { "$($_.canvas)|$(Get-RowKey $_)|$($_.mode)" })) {
  $rows = @($g.Group)
  $first = $rows[0]
  $values = @{}
  foreach ($m in $Metrics) {
    $nums = New-Object System.Collections.Generic.List[double]
    foreach ($r in $rows) {
      $v = ConvertTo-Num $r.($m.Name)
      if ($null -ne $v) { $nums.Add($v) }
    }
    $values[$m.Name] = Get-Median $nums.ToArray()
  }
  $medians = New-Object System.Collections.Generic.List[double]
  foreach ($r in $rows) {
    $v = ConvertTo-Num $r.frame_ms_median
    if ($null -ne $v) { $medians.Add($v) }
  }
  $spread = $null
  $spreadRel = $null
  $min = $null
  $max = $null
  if ($medians.Count -gt 0) {
    $min = ($medians | Measure-Object -Minimum).Minimum
    $max = ($medians | Measure-Object -Maximum).Maximum
    $spread = $max - $min
    if ($values['frame_ms_median'] -gt 0) { $spreadRel = $spread / $values['frame_ms_median'] * 100 }
  }
  $excluded = 0
  if (-not $IncludeFailed) {
    $excluded = @($bad | Where-Object { "$($_.canvas)|$(Get-RowKey $_)|$($_.mode)" -eq $g.Name }).Count
  }
  $cells[$g.Name] = [pscustomobject]@{
    Canvas = $first.canvas; Scene = $first.scene; Preset = $first.preset; N = $first.n; Mode = $first.mode
    RowKey = (Get-RowKey $first)
    Runs = $rows.Count; Excluded = $excluded
    Commit = ((Get-Distinct $rows 'commit') -join ';')
    Values = $values; Spread = $spread; SpreadPct = $spreadRel; Min = $min; Max = $max
    Ratio = $null
  }
}
foreach ($cell in $cells.Values) {
  $base = $cells["$Baseline|$($cell.RowKey)|$($cell.Mode)"]
  if ($base -and $base.Values['frame_ms_median'] -gt 0 -and $null -ne $cell.Values['frame_ms_median']) {
    $cell.Ratio = $cell.Values['frame_ms_median'] / $base.Values['frame_ms_median']
  }
}

function Get-Cell([string] $Canvas, $Key, [string] $Mode) { $cells["$Canvas|$($Key.Key)|$Mode"] }

# --- Summary CSV ---------------------------------------------------------------------------------

$header = @('canvas', 'scene', 'preset', 'n', 'mode', 'runs', 'runs_excluded') + @($Metrics | ForEach-Object { $_.Name }) +
  @('frame_ms_median_spread', 'spread_pct', "ratio_vs_$Baseline", 'commit')
$csvLines = New-Object System.Collections.Generic.List[string]
$csvLines.Add($header -join ',')
foreach ($k in (Get-RowKeys $all)) {
  foreach ($m in $modes) {
    foreach ($c in $canvases) {
      $cell = Get-Cell $c $k $m
      if (-not $cell) { continue }
      $f = @($cell.Canvas, $cell.Scene, $cell.Preset, $cell.N, $cell.Mode, "$($cell.Runs)", "$($cell.Excluded)")
      foreach ($mt in $Metrics) { $f += Format-Fixed $cell.Values[$mt.Name] $mt.Dec }
      $f += Format-Fixed $cell.Spread 3
      $f += Format-Fixed $cell.SpreadPct 1
      $f += Format-Fixed $cell.Ratio 3
      $f += $cell.Commit
      $csvLines.Add((($f | ForEach-Object { Format-CsvValue ([string]$_) }) -join ','))
    }
  }
}
[IO.File]::WriteAllText("$Out.csv", (($csvLines.ToArray() -join "`n") + "`n"), $Utf8)

# --- Markdown ------------------------------------------------------------------------------------

$md = New-Object System.Collections.Generic.List[string]
function Add-Md([string[]] $Lines) { foreach ($l in $Lines) { $md.Add($l) } }

Add-Md "# Benchmark summary: $name"
Add-Md ''
Add-Md ("Raw data: ``$(Get-RelPath $csvPath)`` ($($all.Count) runs, $($all.Count - $bad.Count) ok). " +
  "Generated by ``tools/summarize-bench.ps1``. Values are medians over the repeats of per-run statistics.")
Add-Md ''

# Environment
function Join-Distinct([string] $Column, [string] $Suffix = '') {
  $v = Get-Distinct $all $Column
  if ($v.Count -eq 0) { return '?' }
  (($v | ForEach-Object { "$_$Suffix" }) -join ' / ')
}
$monitors = @()
foreach ($dev in (Get-Distinct $all 'monitor')) {
  $r = @($all | Where-Object { $_.monitor -eq $dev })[0]
  $role = if ($r.monitor_primary -eq '1') { 'primary' } else { 'not primary' }
  $monitors += "``$dev`` ($role), $($r.monitor_res) @ $($r.monitor_hz) Hz (DWM $($r.monitor_hz_dwm) Hz), " +
    "$($r.dpi) DPI, scale $($r.scale)"
}
$repeatCounts = @($cells.Values | ForEach-Object { $_.Runs + $_.Excluded } | Sort-Object -Unique)
$repeatText = if ($repeatCounts.Count -eq 1) { "$($repeatCounts[0])" } else { "$($repeatCounts[0])..$($repeatCounts[-1])" }
$times = @($all | ForEach-Object { $_.started_utc } | Where-Object { $_ } | Sort-Object)
$envRows = @(
  , @('OS', "$(Join-Distinct 'os') $(Join-Distinct 'os_version') (build $(Join-Distinct 'os_build'))")
  , @('CPU', "$(Join-Distinct 'cpu') ($(Join-Distinct 'cpu_threads') threads)")
  , @('GPU', "$(Join-Distinct 'gpu'), driver $(Join-Distinct 'gpu_driver')")
  , @('Monitor', ($monitors -join '; '))
  , @('Delphi', "$(Join-Distinct 'delphi') $(Join-Distinct 'build_config')")
  , @('Commit', (Join-Distinct 'commit'))
  , @('Power plan', (Join-Distinct 'power_plan'))
  , @('Quality', "$(Join-Distinct 'quality') (canvas: $(Join-Distinct 'canvas_quality'))")
  , @('Size', (Join-Distinct 'size'))
  , @('Warmup / duration / repeats', "$(Join-Distinct 'warmup_s' ' s') / $(Join-Distinct 'duration_s' ' s') / $repeatText")
  , @('Preferred FPS', (Join-Distinct 'g_preferred_fps'))
  , @('Split record/EndScene', (Join-Distinct 'split'))
  , @('Started (UTC)', $(if ($times.Count) { "$($times[0]) .. $($times[-1])" } else { '?' }))
)
Add-Md '## Environment'
Add-Md ''
Add-Md (New-MdTable @('Item', 'Value') @('l', 'l') $envRows)
Add-Md ''

# Warnings
$warn = New-Object System.Collections.Generic.List[string]
$commits = Get-Distinct $all 'commit'
if ($commits.Count -gt 1) { $warn.Add("Rows come from different commits: $($commits -join ', ').") }
if (@($commits | Where-Object { $_ -like '*-dirty' }).Count -gt 0) {
  $warn.Add('The exe was built from a dirty tree (commit ends with -dirty).')
}
if (@($all | Where-Object { $_.monitor_primary -ne '1' }).Count -gt 0) {
  $warn.Add('Runs on a non-primary monitor: check-only numbers, do not compare them with primary-monitor results (AGENTS.md, rule 1).')
}
foreach ($dev in (Get-Distinct $all 'monitor')) {
  $rowsOfDev = @($all | Where-Object { $_.monitor -eq $dev })
  $hz = ConvertTo-Num $rowsOfDev[0].monitor_hz
  $dwm = @($rowsOfDev | ForEach-Object { ConvertTo-Num $_.monitor_hz_dwm } | Where-Object { $null -ne $_ })
  $off = @($dwm | Where-Object { $hz -gt 0 -and [Math]::Abs($_ - $hz) / $hz -gt 0.05 })
  if ($off.Count -gt 0) {
    $range = "$(Format-Fixed ($dwm | Measure-Object -Minimum).Minimum 1)..$(Format-Fixed ($dwm | Measure-Object -Maximum).Maximum 1)"
    $warn.Add("DWM reports $range Hz on $dev (display mode $hz Hz) in $($off.Count) of $($rowsOfDev.Count) runs: " +
      'budget_ms, in_budget_pct and missed_intervals use the DWM rate.')
  }
}
foreach ($col in @('size', 'quality', 'warmup_s', 'duration_s', 'monitor', 'gpu_driver', 'power_plan',
    'g_preferred_fps', 'split', 'transparency')) {
  if ($columns -contains $col) {
    $v = Get-Distinct $all $col
    if ($v.Count -gt 1) { $warn.Add("Column $col differs between rows: $($v -join ', ').") }
  }
}
foreach ($r in $bad) {
  $what = @()
  if ($r.status -ne 'ok') { $what += "status $($r.status)" }
  if ($r.canvas_ok -ne '1') { $what += "canvas_ok = 0 (class $($r.canvas_class), expected $($r.canvas_expected))" }
  $warn.Add("Run $($r.canvas) $($r.scene)/$($r.preset)/n=$($r.n)/$($r.mode) [$($r.tag)]: $($what -join ', ')" +
    $(if ($IncludeFailed) { ' (included)' } else { ' (excluded)' }))
}
foreach ($m in $modes) {
  foreach ($k in (Get-ModeRowKeys $m)) {
    $missing = @($canvases | Where-Object { -not (Get-Cell $_ $k $m) })
    if ($missing.Count -gt 0) {
      $warn.Add("No valid runs for $($missing -join ', ') in $($k.Scene)/$($k.Preset)/n=$($k.N)/$m.")
    }
  }
}
$runCounts = @($cells.Values | ForEach-Object { $_.Runs } | Sort-Object -Unique)
if ($runCounts.Count -gt 1) { $warn.Add("Cells have different numbers of valid runs: $($runCounts -join ', ').") }
if (-not $hasBaseline) { $warn.Add("Baseline canvas '$Baseline' has no rows: no ratios.") }
Add-Md '## Warnings'
Add-Md ''
if ($warn.Count -eq 0) { Add-Md 'None.' } else { foreach ($w in $warn) { Add-Md "- $w" } }
Add-Md ''

Add-Md ("Frame = whole ``PaintRects`` (record + ``EndScene``), ms. Ratio in parentheses = canvas / $Baseline " +
  'frame time for the same scene, preset and N (below 1.00 is faster).')
Add-Md ''

function Add-MetricTable([string] $Title, [string] $Mode, [scriptblock] $Format) {
  $keys = @(Get-ModeRowKeys $Mode)
  if ($keys.Count -eq 0) { return }
  $rows = @()
  foreach ($k in $keys) {
    $r = @($k.Scene, $k.Preset, $k.N)
    foreach ($c in $canvases) {
      $cell = Get-Cell $c $k $Mode
      $r += $(if ($cell) { & $Format $cell } else { '-' })
    }
    $rows += , $r
  }
  Add-Md "### $Title"
  Add-Md ''
  Add-Md (New-MdTable (@('Scene', 'Preset', 'N') + $canvases) (@('l', 'l', 'r') + @($canvases | ForEach-Object { 'r' })) $rows)
  Add-Md ''
}

$fmtFrame = {
  param($c)
  $t = Format-Ms $c.Values['frame_ms_median']
  if ($null -ne $c.Ratio) { $t += ' (' + $c.Ratio.ToString('F2', $Inv) + ')' }
  $t
}

if ($modes -contains 'throughput') {
  Add-Md '## Throughput (no vsync, frames back to back)'
  Add-Md ''
  Add-MetricTable 'Frame time median, ms (ratio)' 'throughput' $fmtFrame
  Add-MetricTable 'Frame time p99, ms' 'throughput' { param($c) Format-Ms $c.Values['frame_ms_p99'] }
  Add-MetricTable 'FPS' 'throughput' { param($c) Format-Fixed $c.Values['fps'] 0 }
}
if ($modes -contains 'paced') {
  Add-Md '## Paced (FMX animation clock, vsync)'
  Add-Md ''
  Add-MetricTable 'Frame time median, ms (ratio)' 'paced' $fmtFrame
  Add-MetricTable 'Frame interval p99, ms' 'paced' { param($c) Format-Ms $c.Values['interval_ms_p99'] }
  Add-MetricTable 'Frames within budget (1/Hz), %; missed intervals (> 1.5 periods) in parentheses' 'paced' {
    param($c)
    $t = Format-Fixed $c.Values['in_budget_pct'] 1
    if ($null -ne $c.Values['missed_intervals']) { $t += ' (' + (Format-Fixed $c.Values['missed_intervals'] 0) + ')' }
    $t
  }
}

# Record vs EndScene split
$splitPreset = if ($presets -contains 'medium') { 'medium' } else { $presets[0] }
$fmtSplit = {
  param($c)
  $rec = $c.Values['record_ms_median']
  $end = $c.Values['end_ms_median']
  if ($null -eq $rec -or $null -eq $end) { return '-' }
  $t = "$(Format-Ms $rec) / $(Format-Ms $end)"
  if ($rec + $end -gt 0) { $t += ' (' + ($end / ($rec + $end) * 100).ToString('F0', $Inv) + '%)' }
  $t
}
$splitHeader = $false
foreach ($m in $modes) {
  $rows = @()
  foreach ($k in (Get-ModeRowKeys $m)) {
    if ($k.Preset -ne $splitPreset) { continue }
    $r = @($k.Scene, $k.N)
    foreach ($c in $canvases) {
      $cell = Get-Cell $c $k $m
      $r += $(if ($cell) { & $fmtSplit $cell } else { '-' })
    }
    $rows += , $r
  }
  if ($rows.Count -eq 0) { continue }
  if (-not $splitHeader) {
    $splitHeader = $true
    Add-Md "## Record vs EndScene, $splitPreset preset"
    Add-Md ''
    Add-Md ('Record = scene walk and canvas calls (inherited `PaintRects`), EndScene = flush, EndDraw, Present. ' +
      'Medians in ms: record / EndScene (EndScene share of record + EndScene).')
    Add-Md ''
  }
  Add-Md "### $m"
  Add-Md ''
  Add-Md (New-MdTable (@('Scene', 'N') + $canvases) (@('l', 'r') + @($canvases | ForEach-Object { 'r' })) $rows)
  Add-Md ''
}

# Screenshots
if ($shotDir -and (Test-Path -LiteralPath $shotDir -PathType Container)) {
  $compare = Join-Path $PSScriptRoot 'compare-shots.ps1'
  $others = @($canvases | Where-Object { $_ -ne $Baseline })
  $rows = @()
  $flagged = @()
  foreach ($s in $scenes) {
    $ref = Join-Path $shotDir "${s}_$Baseline.png"
    $r = @($s)
    $anyShot = $false
    foreach ($c in $others) {
      $img = Join-Path $shotDir "${s}_$c.png"
      if (-not (Test-Path -LiteralPath $img)) { $r += '-'; continue }
      $anyShot = $true
      if (-not (Test-Path -LiteralPath $ref)) { $r += 'no reference'; continue }
      try {
        $d = @(& $compare -Reference $ref -Images $img)[0]
        $t = "$(([double]$d.MeanAbs).ToString('F2', $Inv)) / $(([double]$d.PixelsDiffPct).ToString('F2', $Inv))%"
        if ([double]$d.PixelsDiffPct -gt $ShotDiffPct) { $t = "**$t !**"; $flagged += "$s/$c" }
        $r += $t
      } catch {
        $r += "error: $($_.Exception.Message)"
      }
    }
    if ($anyShot -or (Test-Path -LiteralPath $ref)) { $rows += , $r }
  }
  if ($rows.Count -gt 0 -and $others.Count -gt 0) {
    Add-Md "## Screenshots vs $Baseline"
    Add-Md ''
    Add-Md ("Mean absolute difference per channel (0..255) / share of pixels whose summed RGB difference " +
      "exceeds 24 (``tools/compare-shots.ps1``). Shots in ``$(Get-RelPath $shotDir)``. " +
      "**!** = more than $(Format-Fixed $ShotDiffPct 0)% of pixels differ: the picture is noticeably different.")
    Add-Md ''
    Add-Md (New-MdTable (@('Scene') + $others) (@('l') + @($others | ForEach-Object { 'r' })) $rows)
    Add-Md ''
    if ($flagged.Count -gt 0) {
      Add-Md "Noticeable differences: $($flagged -join ', '). Check the images before comparing these timings."
      Add-Md ''
    }
  }
}

# Repeat spread
$spreadRows = @()
foreach ($m in $modes) {
  foreach ($k in (Get-ModeRowKeys $m)) {
    foreach ($c in $canvases) {
      $cell = Get-Cell $c $k $m
      if ($cell -and $null -ne $cell.SpreadPct -and $cell.SpreadPct -gt $SpreadPct) {
        $spreadRows += , @($m, $k.Scene, $k.Preset, $k.N, $c, "$($cell.Runs)",
          "$(Format-Ms $cell.Min) .. $(Format-Ms $cell.Max)", $cell.SpreadPct.ToString('F1', $Inv))
      }
    }
  }
}
Add-Md '## Repeat spread'
Add-Md ''
if ($spreadRows.Count -eq 0) {
  Add-Md ("Spread (max - min of the frame time median over the repeats) is within " +
    "$(Format-Fixed $SpreadPct 0)% of the median everywhere.")
} else {
  Add-Md ("Cells where the spread (max - min of the frame time median over the repeats) exceeds " +
    "$(Format-Fixed $SpreadPct 0)% of the median: these numbers are noisy.")
  Add-Md ''
  Add-Md (New-MdTable @('Mode', 'Scene', 'Preset', 'N', 'Canvas', 'Runs', 'Frame median range, ms', 'Spread, %') `
    @('l', 'l', 'l', 'r', 'l', 'r', 'r', 'r') $spreadRows)
}

[IO.File]::WriteAllText("$Out.md", (($md.ToArray() -join "`n").TrimEnd() + "`n"), $Utf8)
Write-Host "Wrote $Out.csv"
Write-Host "Wrote $Out.md"
