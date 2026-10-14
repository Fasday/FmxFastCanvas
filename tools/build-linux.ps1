<#
.SYNOPSIS
  Command-line build of a Delphi (FMX) program for Linux64 (dcclinux64) against a platform SDK on this machine,
  without PAServer.

.DESCRIPTION
  - The SDK: a copy of a Linux system's libraries (tools\make-linux-sdk.ps1 makes one from a WSL distribution).
    dcclinux64 links with LLVM's lld (bin64\dcc-ld.lld.exe, found through bin64\ld.lld.exe on the PATH) and is told
    about the SDK with --syslibroot:<sdk> (the linker's --sysroot) and --libpath:<dirs> (its -L: Delphi's
    lib\linux64\<config> for librtlhelper, the SDK's usr\lib\x86_64-linux-gnu and usr\lib\gcc\x86_64-linux-gnu\<n>).
    msbuild takes the same as the properties DCC_SysLibRoot and DCC_LibraryPath (an IDE SDK profile sets them through
    Profile_sysroot and Profile_LibraryPath).
  - A .dpr: dcclinux64 as build.ps1 runs dcc64. Output: bin\Linux64\<Config>\<Name> (with -OutRoot another folder),
    libsk4d.so (Skia, Redist\linux64) copied next to it, not with -Define FASTCANVAS_NOSKIA (the probes then leave the
    Skia engines out: Pango text, the own geometry). DCUs: dcu\<OutRoot>\Linux64\<Config>\<Name>\.
  - A .dproj with the Linux64 platform: msbuild (-SearchPath, -Define and -OutRoot do not apply), output where the
    project puts it (<project dir>\Linux64\<Config>\), libsk4d.so next to it; log dcu\<Name>-linux.log.
  - Always a full build (-B); a .map file (-G) for addresses in crash reports; dcu\BuildInfo.inc as build.ps1 writes
    it.

  Running: in WSL, wsl -d <distro> -- /mnt/d/.../<Name> (see docs\USAGE.md, "Linux").

.EXAMPLE
  .\tools\build-linux.ps1 -Project src\Probe\PortProbe.dpr -SearchPath src\Common,src\Canvas,src\Bench
  .\tools\build-linux.ps1 -Project src\Probe\PortProbe.dproj
#>
param(
  [Parameter(Mandatory = $true)] [string] $Project,
  [ValidateSet('Release', 'Debug')] [string] $Config = 'Release',
  [string[]] $SearchPath = @(),
  [string[]] $Define = @(),
  [string] $OutRoot = 'bin',
  [string] $Sdk = 'D:\LinuxSDK\ubuntu-26.04'
)

$ErrorActionPreference = 'Stop'

$Bds = 'C:\Program Files (x86)\Embarcadero\Studio\37.0'
$Dcc = Join-Path $Bds 'bin\dcclinux64.exe'
$Root = Split-Path $PSScriptRoot -Parent

if (-not (Test-Path (Join-Path $Sdk 'usr\lib\x86_64-linux-gnu\libc.so.6'))) {
  throw "No Linux SDK at $Sdk (tools\make-linux-sdk.ps1 makes one)"
}
$Sdk = (Resolve-Path $Sdk).Path
$gccDir = Get-ChildItem (Join-Path $Sdk 'usr\lib\gcc\x86_64-linux-gnu') -Directory |
  Sort-Object { [int]($_.Name -replace '\D.*', '') } | Select-Object -Last 1
if (-not $gccDir) { throw "No usr\lib\gcc\x86_64-linux-gnu\<version> in $Sdk" }

$ProjectPath = (Resolve-Path $Project).Path
$Name = [IO.Path]::GetFileNameWithoutExtension($ProjectPath)
$OutDir = Join-Path $Root "$OutRoot\Linux64\$Config"
$DcuDir = Join-Path $Root "dcu\$OutRoot\Linux64\$Config\$Name"
$ResDir = Join-Path $Root 'dcu'

# Same environment as rsvars.bat; bin64 holds the linker.
$env:BDS = $Bds
$env:BDSINCLUDE = Join-Path $Bds 'include'
$env:BDSCOMMONDIR = 'C:\Users\Public\Documents\Embarcadero\Studio\37.0'
$env:PATH = "$Bds\bin;$Bds\bin64;$env:PATH"

if ([IO.Path]::GetExtension($ProjectPath) -eq '.dproj') {
  # An IDE project (with the Linux64 platform): msbuild, output where the project says.
  $env:BDSLIB = Join-Path $Bds 'lib'
  $env:FrameworkDir = 'C:\WINDOWS\Microsoft.NET\Framework\v4.0.30319'
  $env:FrameworkVersion = 'v4.5'
  $env:PATH = "$env:FrameworkDir;$env:PATH"
  $env:LANGDIR = 'EN'
  $env:PLATFORM = ''
  $Log = Join-Path $Root "dcu\$Name-linux.log"
  New-Item -ItemType Directory -Force -Path (Split-Path $Log) | Out-Null
  # (%3B: a semicolon inside a property value.)
  $libArg = (@((Join-Path $Sdk 'usr\lib\x86_64-linux-gnu'), $gccDir.FullName) -join '%3B')
  Write-Host "msbuild $Name [Linux64 $Config], SDK $Sdk, log $Log"
  & (Join-Path $env:FrameworkDir 'MSBuild.exe') $ProjectPath '/t:Build' "/p:Config=$Config" '/p:Platform=Linux64' `
    "/p:DCC_SysLibRoot=$Sdk" "/p:DCC_LibraryPath=$libArg" '/nologo' '/v:quiet' `
    "/flp:LogFile=$Log;Verbosity=normal;Encoding=UTF-8" | Out-Null
  $code = $LASTEXITCODE
  Select-String -Path $Log -Pattern ': (error|warning|hint) |Error: |Fatal: ' | Select-Object -First 40 |
    ForEach-Object { $_.Line.Trim() }
  if ($code -ne 0) { throw "msbuild failed ($code), see $Log" }
  $Exe = Join-Path (Split-Path $ProjectPath) "Linux64\$Config\$Name"
  if (-not (Test-Path $Exe)) { throw "no program at $Exe" }
  Copy-Item (Join-Path $Bds 'Redist\linux64\libsk4d.so') (Split-Path $Exe) -Force
  Write-Host "OK -> $Exe"
  exit 0
}
New-Item -ItemType Directory -Force -Path $OutDir, $DcuDir | Out-Null

# Build info (commit, dirty flag over the inputs of the binary, compiler version), as build.ps1 writes it.
$commit = 'unknown'
$dirty = 'True'
Push-Location $Root
$eap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
  $c = & git rev-parse --short=12 HEAD 2>$null
  if ($LASTEXITCODE -eq 0 -and $c) {
    $commit = "$c".Trim()
    $changes = & git status --porcelain -- src res third_party build.ps1 2>$null
    $dirty = if ($changes) { 'True' } else { 'False' }
  }
} catch {
} finally {
  $ErrorActionPreference = $eap
  Pop-Location
}
$dccVersion = (Get-Item $Dcc).VersionInfo.FileVersion
$buildInfo = @(
  '// Generated by build.ps1. Do not edit.',
  'const',
  "  BuildCommit = '$commit';",
  "  BuildDirty = $dirty;",
  "  BuildCompilerVersion = '$dccVersion';",
  "  BuildConfig = '$Config';"
)
Set-Content -Path (Join-Path $ResDir 'BuildInfo.inc') -Value $buildInfo -Encoding ascii

$paths = @($ResDir) + ($SearchPath | ForEach-Object { (Resolve-Path $_).Path })
$paths += Join-Path $Root 'third_party\pasvulkan\src'
# Delphi's own: units (dcclinux64.cfg has them too), the .res files of FMX's units, the archives the linker takes.
$delphiLib = Join-Path $Bds "lib\linux64\$($Config.ToLower())"
$paths += $delphiLib
$pathArg = ($paths -join ';')
$libPaths = @($delphiLib, (Join-Path $Sdk 'usr\lib\x86_64-linux-gnu'), $gccDir.FullName)
$defines = @($Define)
$flags = @(
  '-B', '-Q',
  '-NSSystem;Xml;Data;Datasnap;Web;Soap;FMX;Posix;Linuxapi',
  "-E$OutDir", "-NU$DcuDir",
  "-U$pathArg", "-I$pathArg", "-R$pathArg",
  "--syslibroot:$Sdk", "--libpath:$($libPaths -join ';')",
  # A map file for addresses; not -GD: the .drc file it adds wants FMX.Filter.res, which Delphi 13 does not ship for
  # Linux64.
  '-G'
)
if ($Config -eq 'Release') {
  $flags += '-$O+', '-$C-', '-$D+', '-$L+', '-$W-'
  $defines += 'RELEASE'
} else {
  $flags += '-$O-', '-$C+', '-$D+', '-$L+', '-$W+', '-V'
  $defines += 'DEBUG'
}
$flags += '-D' + ($defines -join ';')

Write-Host "dcclinux64 $Name [$Config] commit $commit dirty=$dirty, SDK $Sdk"
$out = & $Dcc @flags $ProjectPath 2>&1
$code = $LASTEXITCODE
$out | Where-Object { "$_" -notmatch '^(Linker command line:|Embarcadero|Copyright)' } | ForEach-Object { Write-Host "$_" }
if ($code -ne 0) { throw "dcclinux64 failed ($code)" }

if ($Define -contains 'FASTCANVAS_NOSKIA') {
  # Built without the Skia engines: no libsk4d.so (an older copy in the folder would hide that it is not needed).
  Remove-Item (Join-Path $OutDir 'libsk4d.so') -ErrorAction SilentlyContinue
} else {
  Copy-Item (Join-Path $Bds 'Redist\linux64\libsk4d.so') $OutDir -Force
}
Write-Host "OK -> $(Join-Path $OutDir $Name)"
