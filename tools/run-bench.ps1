<#
.SYNOPSIS
  Runs the benchmark matrix canvases x scenes x modes x presets x repeats.

.DESCRIPTION
  - Monitors, canvases and scenes are discovered from "FmxCanvasBench.exe --list"; by default all
    canvases and scenes are run.
  - Order: for each repeat, for each scene, preset and mode, all canvases run back to back
    (interleaved), so that slow drift (heat, background load) affects every canvas equally.
  - Output in results\raw\<yyyy-MM-dd>_<Label>\:
      runs.csv                      one row per run (the exe's --out)
      shots\<scene>_<canvas>.png    one screenshot per canvas x scene: medium preset, throughput,
                                    first repeat (the first given preset/mode if medium/throughput
                                    are not in the matrix)
      frames\<scene>_<preset>_<mode>_<canvas>_r<k>.csv   per-frame samples (-Frames)
      log.txt                       every command line, exit code, duration and the exe's output
  - The run tag (CSV column "tag") is <Label>/r<k>; -Resume uses it to skip runs already present
    in runs.csv (with -Resume the newest results\raw\*_<Label> directory is continued).
  - A failing run (exit code <> 0, no result row, status <> ok or canvas_ok = 0) is logged and the
    matrix continues; failures are listed at the end and the script exits with code 1.
  - Refuses to start without -Force if "git status --porcelain src" is not empty or the exe is
    older than the newest file under src\.
  - Runs are serialized machine-wide by a mutex inside the exe, so a run may wait for another one.
  - -Timeout (seconds, default 300, 0 = none): a run whose window stays open longer (or that shows
    no window that long while no other bench process exists) is killed and counted as failed. A
    hung run holds the mutex and blocks every other benchmark on the machine. Waiting for the
    mutex does not count: the window appears only after it is acquired. After two consecutive
    timeouts the matrix stops.
  - Summarize with: .\tools\summarize-bench.ps1 -Raw results\raw\<yyyy-MM-dd>_<Label>

.EXAMPLE
  .\tools\run-bench.ps1 -Label baseline
  .\tools\run-bench.ps1 -Label check -Canvases d2d,gpu,skiavk -Scenes rects,text -Presets light -Repeats 2 -Duration 1 -Warmup 0.5 -Monitor secondary
  .\tools\run-bench.ps1 -Label baseline -Resume
  .\tools\run-bench.ps1 -Label baseline -DryRun
#>
param(
  [Parameter(Mandatory = $true)] [string] $Label,
  [string[]] $Canvases = @(),
  [string[]] $Scenes = @(),
  [string[]] $Modes = @('throughput', 'paced'),
  [string[]] $Presets = @('light', 'medium', 'heavy'),
  [ValidateRange(1, 1000)] [int] $Repeats = 3,
  [ValidateRange(0.0, 3600.0)] [double] $Warmup = 2,
  [ValidateRange(0.01, 3600.0)] [double] $Duration = 5,
  [ValidateSet('default', 'perf', 'high')] [string] $Quality = 'default',
  [string] $Monitor = 'primary',
  [string] $Size = '1920x1080',
  [switch] $NoScreenshots,
  [switch] $Frames,
  [string] $Exe = '',
  [ValidateRange(0.0, 86400.0)] [double] $Timeout = 300,
  [switch] $DryRun,
  [switch] $Resume,
  [switch] $Force
)

$ErrorActionPreference = 'Stop'

$Inv = [Globalization.CultureInfo]::InvariantCulture
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $Exe) { $Exe = Join-Path $Root 'bin\Win64\Release\FmxCanvasBench.exe' }
$script:RunLimit = if ($Timeout -gt 0) { $Timeout } else { [double]::MaxValue }

function Split-List([string[]] $Values) {
  # Accepts both "a,b" (powershell -File) and @('a','b').
  @($Values | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Format-Num([double] $Value) {
  $Value.ToString('0.###', $Inv)
}

function Format-Time([double] $Seconds) {
  [TimeSpan]::FromSeconds([Math]::Max(0, [Math]::Round($Seconds))).ToString('hh\:mm\:ss', $Inv)
}

function Invoke-Native([string] $File, [string[]] $Arguments) {
  # Windows PowerShell turns stderr of native commands into terminating errors under 'Stop'.
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $lines = @(& $File @Arguments 2>$null)
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Lines = $lines }
  } finally {
    $ErrorActionPreference = $prev
  }
}

function Get-BenchList([string] $ExePath) {
  $r = Invoke-Native $ExePath @('--list')
  if ($r.ExitCode -ne 0) { throw "$ExePath --list failed ($($r.ExitCode))" }
  $monitors = New-Object System.Collections.Generic.List[object]
  $canvases = New-Object System.Collections.Generic.List[object]
  $scenes = New-Object System.Collections.Generic.List[object]
  $section = ''
  foreach ($line in $r.Lines) {
    $line = [string]$line
    if ($line -match '^Monitors') { $section = 'monitors'; continue }
    if ($line -match '^Canvases') { $section = 'canvases'; continue }
    if ($line -match '^Scenes') { $section = 'scenes'; continue }
    if ($line -notmatch '^\s+\S') { continue }
    $t = $line.Trim() -split '\s+'
    if ($section -eq 'monitors' -and $t.Count -ge 2 -and $t[0] -match '^\d+$') {
      $monitors.Add([pscustomobject]@{ Index = [int]$t[0]; Device = $t[1]; Primary = ($line -match '\sprimary\s*$') })
    } elseif ($section -eq 'canvases') {
      $canvases.Add([pscustomobject]@{ Name = $t[0]; Class = $(if ($t.Count -ge 2) { $t[1] } else { '' }) })
    } elseif ($section -eq 'scenes') {
      $scenes.Add([pscustomobject]@{ Name = $t[0] })
    }
  }
  if ($canvases.Count -eq 0 -or $scenes.Count -eq 0) {
    throw "Could not parse '$ExePath --list' output:`n$($r.Lines -join "`n")"
  }
  [pscustomobject]@{ Monitors = $monitors.ToArray(); Canvases = $canvases.ToArray(); Scenes = $scenes.ToArray() }
}

function Resolve-Monitor([string] $Spec, [object[]] $Monitors) {
  # Same rules as FindMonitor in src\Common\Common.Env.pas.
  $s = $Spec.Trim()
  $index = 0
  if ($s -eq '' -or $s -eq 'primary') { $index = 1 }
  elseif ($s -eq 'secondary') { $index = 2 }
  elseif ($s -match '^\d+$') { $index = [int]$s }
  else {
    foreach ($m in $Monitors) {
      if ($m.Device -eq $s -or $m.Device -eq "\\.\$s") { return $m }
    }
    return $null
  }
  foreach ($m in $Monitors) { if ($m.Index -eq $index) { return $m } }
  $null
}

function Select-Names([string[]] $Requested, [object[]] $Available, [string] $Kind) {
  if ($Requested.Count -eq 0) { return @($Available | ForEach-Object { $_.Name }) }
  $result = @()
  foreach ($name in $Requested) {
    $match = @($Available | Where-Object { $_.Name -eq $name })
    if ($match.Count -eq 0) {
      throw "Unknown $Kind '$name'. Available: $(($Available | ForEach-Object { $_.Name }) -join ', ')"
    }
    if ($result -notcontains $match[0].Name) { $result += $match[0].Name }
  }
  $result
}

function Read-Runs([string] $Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return @() }
  @(Import-Csv -LiteralPath $Path -Encoding UTF8)
}

function Get-RunKey($Canvas, $Scene, $Preset, $Mode, $Tag) {
  "$Canvas|$Scene|$Preset|$Mode|$Tag".ToLowerInvariant()
}

function Format-Arg([string] $Arg) {
  # Delphi's ParamStr drops double quotes and treats the text between them as one argument.
  if ($Arg -match '\s') { '"' + $Arg + '"' } else { $Arg }
}

function Invoke-Bench([string] $ExePath, [string[]] $Arguments) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $ExePath
  $psi.Arguments = (@($Arguments | ForEach-Object { Format-Arg $_ }) -join ' ')
  $psi.WorkingDirectory = $Root
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $launchUtc = [DateTime]::UtcNow
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $p = [Diagnostics.Process]::Start($psi)
  try {
    $stdout = $p.StandardOutput.ReadToEndAsync()
    $stderr = $p.StandardError.ReadToEndAsync()
    # The bench window appears only after the run mutex is acquired, so waiting for other runs
    # does not count against the timeout. Without a window, only the time when no other bench
    # process exists (nobody else can hold the mutex) counts. Only this process is ever killed.
    $windowAt = $null
    $alone = 0.0
    $last = 0.0
    $timedOut = $false
    while (-not $p.WaitForExit(500)) {
      $now = $sw.Elapsed.TotalSeconds
      if ($null -eq $windowAt) {
        $p.Refresh()
        if ($p.MainWindowHandle -ne [IntPtr]::Zero) {
          $windowAt = $now
        } else {
          $others = @(Get-Process -Name 'FmxCanvasBench' -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $p.Id })
          if ($others.Count -eq 0) { $alone += $now - $last }
          $timedOut = $alone -gt $script:RunLimit
        }
      } else {
        $timedOut = $now - $windowAt -gt $script:RunLimit
      }
      $last = $now
      if ($timedOut) {
        try { $p.Kill() } catch { }
        [void]$p.WaitForExit(10000)
        break
      }
    }
    $p.WaitForExit()
    $sw.Stop()
    # After a kill, a child process could keep the pipes open; do not wait for it.
    $pipeWait = if ($timedOut) { 5000 } else { -1 }
    [void][Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdout, $stderr), $pipeWait)
    $text = ''
    foreach ($task in @($stdout, $stderr)) {
      if ($task.IsCompleted) { $text += $task.Result }
    }
    $text = $text.TrimEnd()
    if ($timedOut) {
      $text = ($text + "`nrun-bench: killed after $($script:RunLimit.ToString('F0', $Inv)) s " +
        $(if ($null -ne $windowAt) { 'with the window open' } else { 'without a window and without other bench processes' })).Trim()
    }
    [pscustomobject]@{
      ExitCode  = $p.ExitCode
      TimedOut  = $timedOut
      LaunchUtc = $launchUtc
      Seconds   = $sw.Elapsed.TotalSeconds
      Output    = $text
    }
  } finally {
    $p.Dispose()
  }
}

$script:LogPath = $null
function Write-Log([string] $Text) {
  if ($script:LogPath) {
    [IO.File]::AppendAllText($script:LogPath, ($Text -replace "`r`n", "`n") + "`n", $Utf8)
  }
}

# --- Parameters ----------------------------------------------------------------------------------

if ($Label -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
  throw "Invalid -Label '$Label': use letters, digits, '.', '_' and '-'"
}
if ($Size -notmatch '^\d+x\d+$') { throw "Invalid -Size '$Size', expected WxH" }
$modeList = Split-List $Modes
$presetList = Split-List $Presets
foreach ($m in $modeList) {
  if (@('throughput', 'paced') -notcontains $m) { throw "Invalid mode '$m' (throughput, paced)" }
}
foreach ($p in $presetList) {
  if (@('light', 'medium', 'heavy') -notcontains $p) { throw "Invalid preset '$p' (light, medium, heavy)" }
}
$modeList = @($modeList | ForEach-Object { $_.ToLowerInvariant() } | Select-Object -Unique)
$presetList = @($presetList | ForEach-Object { $_.ToLowerInvariant() } | Select-Object -Unique)
if ($modeList.Count -eq 0 -or $presetList.Count -eq 0) { throw 'No modes or presets given' }

if (-not (Test-Path -LiteralPath $Exe -PathType Leaf)) { throw "Exe not found: $Exe (build it with build.ps1)" }
$Exe = (Resolve-Path -LiteralPath $Exe).Path
$list = Get-BenchList $Exe
$canvasList = @(Select-Names (Split-List $Canvases) $list.Canvases 'canvas')
$sceneList = @(Select-Names (Split-List $Scenes) $list.Scenes 'scene')
$mon = Resolve-Monitor $Monitor $list.Monitors
if (-not $mon) {
  throw "Unknown monitor '$Monitor'. Monitors: $(($list.Monitors | ForEach-Object { "$($_.Index)=$($_.Device)" }) -join ', ')"
}

# --- Safety checks -------------------------------------------------------------------------------

$problems = @()
$git = Invoke-Native 'git' @('-C', $Root, 'status', '--porcelain', '--', 'src')
if ($git.ExitCode -ne 0) {
  $problems += 'git status failed: cannot verify that src\ is clean'
} elseif ($git.Lines.Count -gt 0) {
  $problems += "src\ has uncommitted changes:`n    " + ($git.Lines -join "`n    ")
}
$head = Invoke-Native 'git' @('-C', $Root, 'rev-parse', '--short=12', 'HEAD')
$headCommit = if ($head.ExitCode -eq 0 -and $head.Lines.Count -gt 0) { ([string]$head.Lines[0]).Trim() } else { '' }
$exeTime = (Get-Item -LiteralPath $Exe).LastWriteTimeUtc
$newest = Get-ChildItem -LiteralPath (Join-Path $Root 'src') -Recurse -File |
  Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
if ($newest -and $newest.LastWriteTimeUtc -gt $exeTime) {
  $problems += "exe is older than $($newest.FullName.Substring($Root.Length + 1)) " +
    "($($exeTime.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss', $Inv)) < " +
    "$($newest.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss', $Inv))); rebuild with build.ps1"
}
foreach ($p in $problems) { Write-Warning $p }
if ($problems.Count -gt 0 -and -not $Force -and -not $DryRun) {
  throw 'Refusing to start (see warnings above); use -Force to run anyway'
}
if (-not $mon.Primary) {
  Write-Warning "Monitor $($mon.Device) is not the primary one: check-only numbers (AGENTS.md, rule 1)"
}

# --- Output directory ----------------------------------------------------------------------------

$rawRoot = Join-Path $Root 'results\raw'
$outDir = $null
if ($Resume -and (Test-Path -LiteralPath $rawRoot)) {
  $prev = Get-ChildItem -LiteralPath $rawRoot -Directory |
    Where-Object { $_.Name -match ('^\d{4}-\d{2}-\d{2}_' + [regex]::Escape($Label) + '$') } |
    Sort-Object Name -Descending | Select-Object -First 1
  if ($prev) { $outDir = $prev.FullName }
}
if (-not $outDir) {
  $outDir = Join-Path $rawRoot ([DateTime]::Now.ToString('yyyy-MM-dd', $Inv) + '_' + $Label)
}
$runsCsv = Join-Path $outDir 'runs.csv'
$shotDir = Join-Path $outDir 'shots'
$framesDir = Join-Path $outDir 'frames'
$script:LogPath = if ($DryRun) { $null } else { Join-Path $outDir 'log.txt' }

$existing = @(Read-Runs $runsCsv)
if ($existing.Count -gt 0 -and -not $Resume) {
  throw "$runsCsv already has $($existing.Count) rows; use -Resume to continue it or another -Label"
}
$done = @{}
foreach ($row in $existing) { $done[(Get-RunKey $row.canvas $row.scene $row.preset $row.mode $row.tag)] = $true }
if ($existing.Count -gt 0) {
  # Rows of a resumed matrix must have been measured with the same parameters.
  $mismatch = @()
  $want = @{
    size       = $Size
    quality    = $Quality
    monitor    = $mon.Device
    warmup_s   = $Warmup.ToString('F2', $Inv)
    duration_s = $Duration.ToString('F2', $Inv)
  }
  foreach ($col in $want.Keys) {
    $vals = @($existing | ForEach-Object { $_.$col } | Select-Object -Unique)
    foreach ($v in $vals) {
      if ($v -ne $want[$col]) { $mismatch += "$col='$v' in runs.csv, now '$($want[$col])'" }
    }
  }
  foreach ($m in $mismatch) { Write-Warning "Resume: $m" }
  if ($mismatch.Count -gt 0 -and -not $Force -and -not $DryRun) {
    throw 'Refusing to resume with different parameters; use -Force to mix them anyway'
  }
}

# --- Plan ----------------------------------------------------------------------------------------

$shotPreset = if ($presetList -contains 'medium') { 'medium' } else { $presetList[0] }
$shotMode = if ($modeList -contains 'throughput') { 'throughput' } else { $modeList[0] }
$plan = New-Object System.Collections.Generic.List[object]
$skipped = 0
for ($r = 1; $r -le $Repeats; $r++) {
  foreach ($scene in $sceneList) {
    foreach ($preset in $presetList) {
      foreach ($mode in $modeList) {
        foreach ($canvas in $canvasList) {
          $tag = "$Label/r$r"
          if ($done.ContainsKey((Get-RunKey $canvas $scene $preset $mode $tag))) { $skipped++; continue }
          $plan.Add([pscustomobject]@{
            Repeat = $r; Scene = $scene; Preset = $preset; Mode = $mode; Canvas = $canvas; Tag = $tag
            Shot   = (-not $NoScreenshots) -and $r -eq 1 -and $preset -eq $shotPreset -and $mode -eq $shotMode
          })
        }
      }
    }
  }
}

function Get-RunArgs($Run) {
  $a = @(
    "--canvas=$($Run.Canvas)", "--scene=$($Run.Scene)", "--preset=$($Run.Preset)", "--mode=$($Run.Mode)",
    "--size=$Size", "--monitor=$Monitor", "--quality=$Quality",
    "--warmup=$(Format-Num $Warmup)", "--duration=$(Format-Num $Duration)",
    "--tag=$($Run.Tag)", "--out=$runsCsv"
  )
  if ($Run.Shot) { $a += "--screenshot=$(Join-Path $shotDir "$($Run.Scene)_$($Run.Canvas).png")" }
  if ($Frames) {
    $a += "--frames=$(Join-Path $framesDir "$($Run.Scene)_$($Run.Preset)_$($Run.Mode)_$($Run.Canvas)_r$($Run.Repeat).csv")"
  }
  $a
}

function Get-CommandText([string[]] $Arguments) {
  (@("`"$Exe`"") + @($Arguments | ForEach-Object { Format-Arg $_ })) -join ' '
}

# Rough estimate until real durations are known: process start, warmup (at least 120 frames),
# measurement, screenshot.
$estimate = 0.0
foreach ($run in $plan) {
  $estimate += 2.5 + [Math]::Max($Warmup, 0.5) + $Duration
  if ($run.Shot) { $estimate += 1 }
}

Write-Host "Exe:      $Exe"
Write-Host "Output:   $outDir"
Write-Host "Monitor:  $($mon.Device)$(if ($mon.Primary) { ' (primary)' })"
Write-Host "Canvases: $($canvasList -join ', ')"
Write-Host "Scenes:   $($sceneList -join ', ')"
Write-Host "Presets:  $($presetList -join ', ');  modes: $($modeList -join ', ');  repeats: $Repeats"
Write-Host "Warmup $(Format-Num $Warmup) s, duration $(Format-Num $Duration) s, size $Size, quality $Quality"
Write-Host ("Runs:     $($plan.Count)" + $(if ($skipped) { " ($skipped already in runs.csv)" }) +
  ", estimate ~$(Format-Time $estimate)")

if ($DryRun) {
  foreach ($run in $plan) { Write-Host (Get-CommandText (Get-RunArgs $run)) }
  Write-Host 'Dry run: nothing executed.'
  return
}
if ($plan.Count -eq 0) {
  Write-Host 'Nothing to do.'
  return
}

# --- Run -----------------------------------------------------------------------------------------

New-Item -ItemType Directory -Force -Path $outDir | Out-Null
if (-not $NoScreenshots) { New-Item -ItemType Directory -Force -Path $shotDir | Out-Null }
if ($Frames) { New-Item -ItemType Directory -Force -Path $framesDir | Out-Null }

$started = Get-Date
Write-Log ("=== $($started.ToString('yyyy-MM-dd HH:mm:ss', $Inv)) run-bench.ps1 " +
  "label=$Label resume=$([bool]$Resume) force=$([bool]$Force)")
Write-Log "exe: $Exe ($($exeTime.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss', $Inv))), git HEAD $headCommit"
Write-Log ("canvases=$($canvasList -join ',') scenes=$($sceneList -join ',') presets=$($presetList -join ',') " +
  "modes=$($modeList -join ',') repeats=$Repeats warmup=$(Format-Num $Warmup) duration=$(Format-Num $Duration) " +
  "size=$Size quality=$Quality monitor=$Monitor ($($mon.Device)) runs=$($plan.Count) skipped=$skipped")
foreach ($p in $problems) { Write-Log "WARNING: $p" }

function Test-ExeCommit([string] $Commit) {
  # The exe stores the commit it was built from (build.ps1); compare the build inputs with HEAD.
  $c = $Commit -replace '-dirty$', ''
  if (-not $c -or $c -eq 'unknown') { return "exe has no commit info ($Commit)" }
  if ($Commit -like '*-dirty') { return "exe was built from a dirty tree ($Commit)" }
  $d = Invoke-Native 'git' @('-C', $Root, 'diff', '--quiet', $c, 'HEAD', '--', 'src', 'res', 'third_party', 'build.ps1')
  if ($d.ExitCode -eq 1) { return "exe was built from commit $c; src differs from HEAD $headCommit, rebuild" }
  if ($d.ExitCode -ne 0) { return "exe commit $c is unknown to git (git diff exit $($d.ExitCode))" }
  $null
}

$failures = New-Object System.Collections.Generic.List[string]
$commitChecked = $false
$timeouts = 0
$rowCount = $existing.Count
$spent = 0.0
$index = 0
$completed = $false
try {
  foreach ($run in $plan) {
    $index++
    $runArgs = Get-RunArgs $run
    $name = "r$($run.Repeat) $($run.Scene)/$($run.Preset)/$($run.Mode)/$($run.Canvas)"
    $width = "$($plan.Count)".Length
    Write-Host -NoNewline ("[{0}/{1}] {2} ... " -f "$index".PadLeft($width), $plan.Count, $name)
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss', $Inv)
    Write-Log "[$stamp] [$index/$($plan.Count)] $(Get-CommandText $runArgs)"

    $res = Invoke-Bench $Exe $runArgs
    $spent += $res.Seconds

    $rows = @(Read-Runs $runsCsv)
    $row = if ($rows.Count -gt $rowCount) { $rows[$rows.Count - 1] } else { $null }
    $rowCount = $rows.Count
    $why = @()
    if ($res.TimedOut) { $why += "timeout: killed after $(Format-Num $Timeout) s" }
    elseif ($res.ExitCode -ne 0) { $why += "exit code $($res.ExitCode)" }
    if (-not $row) {
      $why += 'no result row'
    } else {
      if ($row.status -ne 'ok') { $why += "status $($row.status)" }
      if ($row.canvas_ok -ne '1') { $why += "canvas class $($row.canvas_class), expected $($row.canvas_expected)" }
      if (-not $commitChecked) {
        $commitChecked = $true
        $note = Test-ExeCommit $row.commit
        if ($note) {
          Write-Host ''
          Write-Warning $note
          Write-Log "WARNING: $note"
        }
      }
    }
    if ($run.Shot) {
      $shotPath = Join-Path $shotDir "$($run.Scene)_$($run.Canvas).png"
      if (-not (Test-Path -LiteralPath $shotPath)) { $why += 'no screenshot' }
    }
    $status = if ($why.Count -eq 0) { 'ok' } else { 'FAILED: ' + ($why -join '; ') }
    if ($why.Count -gt 0) { $failures.Add("$name [$($run.Tag)]: $($why -join '; ')") }

    $fps = if ($row) { " fps=$($row.fps) frame=$($row.frame_ms_median) ms" } else { '' }
    # started_utc is taken after the run mutex is acquired: the delay is mostly the wait for runs
    # of other processes.
    $delay = ''
    $startedUtc = [DateTimeOffset]::MinValue
    if ($row -and [DateTimeOffset]::TryParse($row.started_utc, $Inv, [Globalization.DateTimeStyles]::AssumeUniversal,
        [ref]$startedUtc)) {
      $delay = ($startedUtc.UtcDateTime - $res.LaunchUtc).TotalSeconds.ToString('F1', $Inv)
    }
    Write-Log ("  exit=$($res.ExitCode) duration=$($res.Seconds.ToString('F1', $Inv)) s" +
      $(if ($delay) { " (start delay $delay s: mutex wait + startup)" }) + " status=$status$fps")
    if ($res.Output) { Write-Log (($res.Output -split "`r?`n" | ForEach-Object { "  | $_" }) -join "`n") }

    $left = $plan.Count - $index
    $eta = $spent / $index * $left
    $elapsed = ((Get-Date) - $started).TotalSeconds
    $waited = if ($delay -and [double]::Parse($delay, $Inv) -ge 2) { ", waited $delay s" } else { '' }
    $msg = "$status$fps ($($res.Seconds.ToString('F1', $Inv)) s$waited; elapsed $(Format-Time $elapsed), ETA $(Format-Time $eta))"
    if ($why.Count -eq 0) { Write-Host $msg } else { Write-Host $msg -ForegroundColor Red }

    # A hung run holds the machine-wide mutex; do not keep blocking other benchmarks.
    $timeouts = if ($res.TimedOut) { $timeouts + 1 } else { 0 }
    if ($timeouts -ge 2) {
      $stopNote = "stopped after $timeouts consecutive timeouts (systematic hang?); fix it and continue with -Resume"
      Write-Host $stopNote -ForegroundColor Red
      Write-Log "=== $stopNote"
      $failures.Add("matrix $stopNote")
      break
    }
  }
  $completed = $true
} finally {
  $total = ((Get-Date) - $started).TotalSeconds
  if (-not $completed) {
    Write-Log "=== interrupted after $index of $($plan.Count) runs ($(Format-Time $total)); continue with -Resume"
  } else {
    Write-Log "=== done: $index of $($plan.Count) runs in $(Format-Time $total), $($failures.Count) failed"
    foreach ($f in $failures) { Write-Log "FAILED: $f" }
  }
}

Write-Host ''
Write-Host "Done: $index of $($plan.Count) runs in $(Format-Time $total), $($failures.Count) failed. Raw data: $outDir"
if ($failures.Count -gt 0) {
  Write-Host 'Failed runs:' -ForegroundColor Red
  foreach ($f in $failures) { Write-Host "  $f" -ForegroundColor Red }
}
Write-Host "Summary: .\tools\summarize-bench.ps1 -Raw $($outDir.Substring($Root.Length + 1))"
if ($failures.Count -gt 0) { exit 1 }
