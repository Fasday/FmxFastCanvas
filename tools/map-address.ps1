<#
.SYNOPSIS
  The symbol of an address in a program linked by LLVM's lld (Linux64: the .map file tools\build-linux.ps1 writes
  with -G), for addresses in crash messages ("Exception ... at 000000000047D1E3").

.EXAMPLE
  .\tools\map-address.ps1 -Map bin\Linux64\Release\TextProbe.map -Address 47D1E3
#>
param(
  [Parameter(Mandatory = $true)] [string] $Map,
  [Parameter(Mandatory = $true)] [string] $Address
)

$ErrorActionPreference = 'Stop'
$target = [Convert]::ToUInt64($Address.TrimStart('$').Replace('0x', ''), 16)
$best = $null
$bestVma = [UInt64]0
foreach ($line in [IO.File]::ReadLines((Resolve-Path $Map).Path)) {
  # VMA LMA Size Align then the symbol (an input section line has more columns before its name).
  if ($line -match '^\s*([0-9a-f]+)\s+[0-9a-f]+\s+([0-9a-f]+)\s+\d+\s+(.+)$') {
    $vma = [Convert]::ToUInt64($Matches[1], 16)
    $size = [Convert]::ToUInt64($Matches[2], 16)
    if ($vma -le $target -and $vma -ge $bestVma -and $Matches[3].Trim() -notmatch '^\.' -and
        ($size -eq 0 -or $target -lt $vma + $size)) {
      $best = $Matches[3].Trim()
      $bestVma = $vma
    }
  }
}
if ($best) { '{0} +0x{1:x}' -f $best, ($target - $bestVma) } else { 'not found' }
