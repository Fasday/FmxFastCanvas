<#
.SYNOPSIS
  Command-line build of an FMX project for Android64 into a signed APK (msbuild Build and Deploy).

.DESCRIPTION
  Sets the environment of rsvars.bat and runs msbuild with the targets Build and Deploy; the project needs its
  .deployproj (tools\make-deployproj.ps1). BT_BuildType Debug of the project makes an installable development APK in
  <project dir>\Android64\<Config>\<Name>\bin\<Name>.apk (APK Signature Scheme v2 and v3). It is signed with a debug
  keystore of the repository (dcu\android-debug.keystore, made by the build with the password "android" when
  missing), not with the IDE's: that one may have another password. The msbuild log goes to
  dcu\<Name>-android.log.

.EXAMPLE
  .\tools\build-android.ps1 -Project src\Probe\PortProbe.dproj
#>
param(
  [Parameter(Mandatory = $true)] [string] $Project,
  [ValidateSet('Release', 'Debug')] [string] $Config = 'Release',
  [string[]] $Property = @()
)

$ErrorActionPreference = 'Stop'

$Bds = 'C:\Program Files (x86)\Embarcadero\Studio\37.0'
$Root = Split-Path $PSScriptRoot
# Same environment as rsvars.bat
$env:BDS = $Bds
$env:BDSINCLUDE = Join-Path $Bds 'include'
$env:BDSCOMMONDIR = 'C:\Users\Public\Documents\Embarcadero\Studio\37.0'
$env:FrameworkDir = 'C:\WINDOWS\Microsoft.NET\Framework\v4.0.30319'
$env:FrameworkVersion = 'v4.5'
$env:PATH = "$env:FrameworkDir;$Bds\bin;$Bds\bin64;$Bds\cmake;$env:PATH"
$env:LANGDIR = 'EN'
$env:PLATFORM = ''

$ProjectPath = (Resolve-Path $Project).Path
$Name = [IO.Path]::GetFileNameWithoutExtension($ProjectPath)
$DcuDir = Join-Path $Root 'dcu'
New-Item -ItemType Directory -Force -Path $DcuDir | Out-Null
$Log = Join-Path $DcuDir "$Name-android.log"
$KeyStore = Join-Path $DcuDir 'android-debug.keystore'
$MsBuild = Join-Path $env:FrameworkDir 'MSBuild.exe'
$props = @("/p:Config=$Config", '/p:Platform=Android64', "/p:DebugKeyStoreFile=$KeyStore") +
  ($Property | ForEach-Object { "/p:$_" })
Write-Host "msbuild $Name [Android64 $Config], log $Log"
& $MsBuild $ProjectPath '/t:Build;Deploy' @props '/nologo' '/v:quiet' "/flp:LogFile=$Log;Verbosity=normal;Encoding=UTF-8" |
  Out-Null
$code = $LASTEXITCODE
Select-String -Path $Log -Pattern ': (error|warning|hint) ' | Select-Object -First 40 | ForEach-Object { $_.Line.Trim() }
if ($code -ne 0) { throw "msbuild failed ($code), see $Log" }
$Apk = Join-Path (Split-Path $ProjectPath) "Android64\$Config\$Name\bin\$Name.apk"
if (-not (Test-Path $Apk)) { throw "no APK at $Apk" }
Write-Host "OK -> $Apk ($([Math]::Round((Get-Item $Apk).Length / 1MB, 1)) MB)"
