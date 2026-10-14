<#
.SYNOPSIS
  Does a Linux program of FastCanvas (PortProbe), linked against the default SDK (Ubuntu 22.04, glibc 2.35), run on
  other distributions? Without a screen and without touching the desktop:
  1. The glibc symbol versions the program and libsk4d.so (when it is next to the program: built with the Skia
     engines) need (objdump -T in WSL) must be at most -MaxGlibc.
  2. In a Docker container of each image, and in the WSL distribution -Distro: a private Xvfb, PortProbe on it for a
     few seconds (FMX's Linux platform: libfmux, GTK 3, X11; FastCanvas on Vulkan, Mesa's lavapipe), the frame
     FastCanvas presented last saved as a PNG (look at it: the top says what the canvas runs on).

.DESCRIPTION
  Checks: FastCanvas ran (the frame PNG exists, no "failed" state, the start was confirmed after 60 frames), the
  program ended by itself (exit 0). Needs Docker with Linux containers (Docker Desktop, WSL 2 engine). The images get
  what a user of the program installs (GTK 3, the Vulkan loader and Mesa's Vulkan drivers, libGL and fontconfig for
  libsk4d.so, a font) plus Xvfb; they are built once as fastcanvas-compat:<image> (-Rebuild makes them again). The
  distribution -Distro needs xvfb, libgtk-3-0, mesa-vulkan-drivers. Output: <OutRoot>\<image>\.

.EXAMPLE
  .\tools\build-linux.ps1 -Project src\Probe\PortProbe.dpr -SearchPath src\Common,src\Canvas,src\Bench
  .\tools\linux-compat.ps1
#>
param(
  [string[]] $Images = @('ubuntu:22.04', 'debian:12', 'fedora:latest'),
  [string] $Program = 'bin\Linux64\Release\PortProbe',
  [string[]] $Arguments = @('--seconds=8', '--time=2'),
  # Also run in this WSL distribution ('' for none); it runs objdump too.
  [string] $Distro = 'Ubuntu-26.04',
  [string] $MaxGlibc = '2.35',
  [string] $OutRoot = 'D:\Work\FastCanvas-compat',
  [switch] $Rebuild
)

$ErrorActionPreference = 'Stop'
function WslPath([string] $p) { '/mnt/' + $p.Substring(0, 1).ToLower() + $p.Substring(2).Replace('\', '/') }

$Root = Split-Path $PSScriptRoot -Parent
$exe = (Resolve-Path (Join-Path $Root $Program)).Path
$binDir = Split-Path $exe
$name = Split-Path $exe -Leaf
$results = New-Object System.Collections.Generic.List[string]
function Check([string] $Name, [bool] $Ok) {
  $s = if ($Ok) { 'PASS' } else { 'FAIL' }
  $results.Add("$s  $Name")
  Write-Host "$s  $Name"
}

# 1. The newest GLIBC_x.y symbol version each file needs.
foreach ($f in @($exe, (Join-Path $binDir 'libsk4d.so')) | Where-Object { Test-Path $_ }) {
  $newest = wsl -d $Distro -u root --exec objdump -T (WslPath $f) |
    Select-String -Pattern 'GLIBC_([0-9.]+)' -AllMatches | ForEach-Object { $_.Matches } |
    ForEach-Object { [version]($_.Groups[1].Value + '.0') } | Sort-Object -Unique | Select-Object -Last 1
  Check "$(Split-Path $f -Leaf): needs GLIBC_$($newest.Major).$($newest.Minor) <= $MaxGlibc" `
    (($null -ne $newest) -and ($newest -le [version]($MaxGlibc + '.0')))
}

# Checks of one run (its output folder).
function CheckRun([string] $Label, [string] $Out) {
  $system = Get-Content (Join-Path $Out 'system.txt') -ErrorAction SilentlyContinue
  $log = Get-Content (Join-Path $Out 'program.log') -Raw -ErrorAction SilentlyContinue
  Write-Host "$($Label): $system"
  Check "$($Label): exit 0 (closed itself)" ("$log" -match 'exit=0')
  Check "$($Label): FastCanvas ran (no failed start)" ("$log" -notmatch 'state: fastcanvas-failed')
  Check "$($Label): FastCanvas confirmed (60 frames)" ("$log" -notmatch 'state: fastcanvas-pending')
  Check "$($Label): frame of FastCanvas saved" (Test-Path (Join-Path $Out 'frame.png'))
}

$probeArgs = @($Arguments) + '--shot=/out/frame.png'
# Native programs' stderr redirected: error records that must not stop the script.
$ErrorActionPreference = 'Continue'

# 2a. The WSL distribution.
if ($Distro) {
  $out = Join-Path $OutRoot ($Distro.ToLower())
  if (Test-Path $out) { Remove-Item -Recurse -Force $out }
  New-Item -ItemType Directory -Force -Path $out | Out-Null
  $wslArgs = @($Arguments) + "--shot=$(WslPath $out)/frame.png"
  wsl -d $Distro -u root --exec sh (WslPath (Join-Path $PSScriptRoot 'linux-compat.sh')) (WslPath $out) (WslPath $exe) `
    @wslArgs 2>&1 | ForEach-Object { "$_" } | Out-Null
  CheckRun "WSL $Distro" $out
}

# 2b. The containers.
docker info --format '{{.OSType}}' 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Docker does not answer (Docker Desktop: docker desktop start)' }
foreach ($image in $Images) {
  $tagName = $image -replace '[:/]', '-'
  $tag = "fastcanvas-compat:$tagName"
  if ($image -match '^(fedora|rockylinux|almalinux|centos)') {
    $install = 'dnf install -y -q --setopt=install_weak_deps=False xorg-x11-server-Xvfb gtk3 vulkan-loader ' +
      'mesa-vulkan-drivers mesa-libGL fontconfig dejavu-sans-fonts zlib && dnf clean all'
  } else {
    # (Ubuntu 24.04 and later: libgtk-3-0t64.)
    $install = 'apt-get update -qq && GTK=$(apt-cache show libgtk-3-0t64 >/dev/null 2>&1 && echo libgtk-3-0t64 || ' +
      'echo libgtk-3-0) && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends xvfb $GTK ' +
      'libvulkan1 mesa-vulkan-drivers libgl1 libfontconfig1 fonts-dejavu-core zlib1g && rm -rf /var/lib/apt/lists/*'
  }
  $out = Join-Path $OutRoot $tagName
  if (Test-Path $out) { Remove-Item -Recurse -Force $out }
  New-Item -ItemType Directory -Force -Path $out | Out-Null
  docker image inspect $tag 2>&1 | Out-Null
  if ($Rebuild -or $LASTEXITCODE -ne 0) {
    Write-Host "Building the image $tag"
    "FROM $image`nRUN $install`n" | docker build -t $tag - 2>&1 | ForEach-Object { "$_" } |
      Set-Content (Join-Path $out 'docker-build.log')
    if ($LASTEXITCODE -ne 0) { throw "docker build of $tag failed, see $out\docker-build.log" }
  }
  # --init: GNU timeout 9.10 (Fedora 44) runs nothing as the container's PID 1.
  docker run --rm --init -v "${binDir}:/app:ro" -v "${PSScriptRoot}:/tools:ro" -v "${out}:/out" $tag `
    timeout 150 sh /tools/linux-compat.sh /out "/app/$name" @probeArgs 2>&1 | ForEach-Object { "$_" } |
    Set-Content (Join-Path $out 'docker-run.log')
  CheckRun $image $out
}
$results | Set-Content (Join-Path $OutRoot 'results.txt')
$failed = @($results | Where-Object { $_ -like 'FAIL*' }).Count
if ($failed -gt 0) { Write-Host "$failed check(s) failed"; exit 1 }
Write-Host "All checks passed (frames: $OutRoot\<name>\frame.png)"
