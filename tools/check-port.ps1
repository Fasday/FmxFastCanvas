<#
.SYNOPSIS
  Compiles the canvas units (FastCanvas.Canvas and every unit it uses) and the Vulkan 3D context
  (FastCanvas.Context3DVk) for Android64 (dccaarm64) and Linux64 (dcclinux64) without linking: the check that the
  non-Windows code builds, also without the Android or Linux SDK.

.DESCRIPTION
  DCUs go to dcu\check\<Platform>. Exit code 1 when a compiler reports an error; warnings and hints are listed.
  Linking a program needs the platform SDK: tools\build-android.ps1 builds the Android APK.

.EXAMPLE
  .\tools\check-port.ps1
  .\tools\check-port.ps1 -Platform Linux64 -Unit src\Canvas\FastCanvas.GpuVk.pas
#>
param(
  [ValidateSet('Android64', 'Linux64')] [string[]] $Platform = @('Android64', 'Linux64'),
  [string[]] $Unit = @('src\Canvas\FastCanvas.Canvas.pas', 'src\Canvas\FastCanvas.Context3DVk.pas'),
  [ValidateSet('Release', 'Debug')] [string] $Config = 'Release'
)

$ErrorActionPreference = 'Stop'
$Bds = 'C:\Program Files (x86)\Embarcadero\Studio\37.0'
$Root = Split-Path $PSScriptRoot -Parent
$env:BDS = $Bds
$env:BDSINCLUDE = Join-Path $Bds 'include'
$env:BDSCOMMONDIR = 'C:\Users\Public\Documents\Embarcadero\Studio\37.0'

$paths = @((Join-Path $Root 'src\Canvas'), (Join-Path $Root 'third_party\pasvulkan\src'), (Join-Path $Root 'dcu'))
$pathArg = $paths -join ';'
$failed = $false
foreach ($p in $Platform) {
  if ($p -eq 'Android64') {
    $dcc = Join-Path $Bds 'bin\dccaarm64.exe'
    $ns = 'System;Xml;Data;Datasnap;Web;Soap;FMX;Androidapi;Posix'
  } else {
    $dcc = Join-Path $Bds 'bin\dcclinux64.exe'
    $ns = 'System;Xml;Data;Datasnap;Web;Soap;FMX;Posix;Linuxapi'
  }
  $dcuDir = Join-Path $Root "dcu\check\$p\$Config"
  New-Item -ItemType Directory -Force -Path $dcuDir | Out-Null
  $flags = @('-B', '-Q', "-NS$ns", "-NU$dcuDir", "-N0$dcuDir", "-U$pathArg", "-I$pathArg", "-R$pathArg")
  if ($Config -eq 'Release') {
    $flags += '-$O+', '-$C-', '-DRELEASE'
  } else {
    $flags += '-$O-', '-$C+', '-DDEBUG'
  }
  foreach ($u in $Unit) {
    Write-Host "$p ($([IO.Path]::GetFileName($dcc))) $u"
    $out = & $dcc @flags (Join-Path $Root $u) 2>&1
    $out | Where-Object { "$_" -match '(Error|Warning|Hint|Fatal)' -or "$_" -match 'lines,' } | ForEach-Object { "  $_" }
    if ($LASTEXITCODE -ne 0) { $failed = $true }
  }
}
if ($failed) { exit 1 }
