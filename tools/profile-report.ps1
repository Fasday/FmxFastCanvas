<#
.SYNOPSIS
  Report of a sampling profile written by FmxCanvasBench --profile=<txt> (src\Common\Common.Profiler.pas).

.DESCRIPTION
  Resolves the addresses of the executable with its detailed .map file (publics by value and the unit of every
  code range), addresses in other modules by module name. Prints self time (innermost frame) and inclusive time
  (routine anywhere on the stack, counted once per sample) per routine and per unit, in percent of the samples.

.EXAMPLE
  .\tools\profile-report.ps1 -Profile results\raw\prof_listbox_fc.txt -Top 40
#>
param(
  [Parameter(Mandatory = $true)] [string] $Profile,
  [string] $Map = '',
  [int] $Top = 30,
  [string] $Filter = '',
  # Print every stack resolved (thread dumps of Common.Profiler.DumpThreadStacks) instead of the statistics.
  [switch] $Stacks
)
$ErrorActionPreference = 'Stop'

$lines = [IO.File]::ReadAllLines((Resolve-Path $Profile))
$modules = @()
$samples = New-Object System.Collections.Generic.List[UInt64[]]
$threads = New-Object System.Collections.Generic.List[string]
$thread = ''
foreach ($l in $lines) {
  if ($l.StartsWith('t ')) {
    $thread = $l.Substring(2).Trim()
  } elseif ($l.StartsWith('s ') -or $l -eq 's') {
    $threads.Add($thread)
    $parts = $l.Substring(1).Trim().Split(' ', [StringSplitOptions]::RemoveEmptyEntries)
    $samples.Add([UInt64[]]($parts | ForEach-Object { [Convert]::ToUInt64($_, 16) }))
  } elseif ($l.StartsWith('module ')) {
    $p = $l.Split(' ', 4)
    $modules += [pscustomobject]@{ Base = [Convert]::ToUInt64($p[1], 16); Size = [Convert]::ToUInt64($p[2], 16); Path = $p[3] }
  } elseif ($l.StartsWith('samples ')) {
    Write-Host $l
  }
}
$exe = $modules | Where-Object { $_.Path -like '*.exe' } | Select-Object -First 1
if (-not $Map) {
  $Map = [IO.Path]::ChangeExtension($exe.Path, '.map')
}

# Map: .text starts at RVA 0x1000 (segment 0001); publics and unit ranges are offsets in it.
$publics = New-Object System.Collections.Generic.List[object]
$units = New-Object System.Collections.Generic.List[object]
$mode = ''
foreach ($l in [IO.File]::ReadLines($Map)) {
  if ($l -match 'Detailed map of segments') { $mode = 'seg'; continue }
  if ($l -match 'Publics by Value') { $mode = 'pub'; continue }
  if ($l -match '^Line numbers for') { break }
  if ($mode -eq 'seg' -and $l -match '^\s*0001:([0-9A-F]+)\s+([0-9A-F]+)\s+C=CODE.*M=(\S+)') {
    $units.Add([pscustomobject]@{ Start = [Convert]::ToUInt64($Matches[1], 16); End = [Convert]::ToUInt64($Matches[1], 16) + [Convert]::ToUInt64($Matches[2], 16); Name = $Matches[3] })
  } elseif ($mode -eq 'pub' -and $l -match '^\s*0001:([0-9A-F]+)\s+(\S.*)$') {
    $publics.Add([pscustomobject]@{ Off = [Convert]::ToUInt64($Matches[1], 16); Name = $Matches[2].Trim() })
  }
}
$pubOff = [UInt64[]]($publics | ForEach-Object Off)
$pubName = [string[]]($publics | ForEach-Object Name)
[Array]::Sort($pubOff, $pubName)
$unitStart = [UInt64[]]($units | ForEach-Object Start)
$unitName = [string[]]($units | ForEach-Object Name)
[Array]::Sort($unitStart, $unitName)

$cache = @{}
function Resolve-Address([UInt64] $a) {
  if ($cache.ContainsKey($a)) { return $cache[$a] }
  $r = $null
  if ($a -ge $exe.Base -and $a -lt $exe.Base + $exe.Size) {
    $off = $a - $exe.Base - 0x1000
    $i = [Array]::BinarySearch($pubOff, $off); if ($i -lt 0) { $i = (-bnot $i) - 1 }
    $j = [Array]::BinarySearch($unitStart, $off); if ($j -lt 0) { $j = (-bnot $j) - 1 }
    $name = if ($i -ge 0) { $pubName[$i] } else { '?' }
    $unit = if ($j -ge 0) { $unitName[$j] } else { '?' }
    $r = [pscustomobject]@{ Routine = $name; Unit = $unit }
  } else {
    $m = $modules | Where-Object { $a -ge $_.Base -and $a -lt $_.Base + $_.Size } | Select-Object -First 1
    $n = if ($m) { [IO.Path]::GetFileName($m.Path) } else { '?' }
    $r = [pscustomobject]@{ Routine = "[$n]"; Unit = "[$n]" }
  }
  $cache[$a] = $r
  return $r
}

if ($Stacks) {
  for ($i = 0; $i -lt $samples.Count; $i++) {
    "== thread {0}" -f $threads[$i]
    $prev = ''
    foreach ($a in $samples[$i]) {
      $x = Resolve-Address $a
      if ($x.Routine -ne $prev) { '   {0}' -f $x.Routine }
      $prev = $x.Routine
    }
    ''
  }
  return
}

$total = $samples.Count
$selfR = @{}; $inclR = @{}; $selfU = @{}; $inclU = @{}
foreach ($s in $samples) {
  if ($Filter) {
    $hit = $false
    foreach ($a in $s) { if ((Resolve-Address $a).Routine -like $Filter) { $hit = $true; break } }
    if (-not $hit) { continue }
  }
  $leaf = Resolve-Address $s[0]
  $selfR[$leaf.Routine] = 1 + [int]$selfR[$leaf.Routine]
  $selfU[$leaf.Unit] = 1 + [int]$selfU[$leaf.Unit]
  $seenR = @{}; $seenU = @{}
  foreach ($a in $s) {
    $x = Resolve-Address $a
    if (-not $seenR.ContainsKey($x.Routine)) { $seenR[$x.Routine] = 1; $inclR[$x.Routine] = 1 + [int]$inclR[$x.Routine] }
    if (-not $seenU.ContainsKey($x.Unit)) { $seenU[$x.Unit] = 1; $inclU[$x.Unit] = 1 + [int]$inclU[$x.Unit] }
  }
}
function Show($h, $title) {
  "== $title (of $total samples)"
  $h.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First $Top |
    ForEach-Object { '{0,6:N1}%  {1}' -f (100.0 * $_.Value / $total), $_.Key }
  ''
}
Show $selfU 'self by unit'
Show $inclU 'inclusive by unit'
Show $selfR 'self by routine'
Show $inclR 'inclusive by routine'
