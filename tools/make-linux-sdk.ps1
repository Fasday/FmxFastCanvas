<#
.SYNOPSIS
  Makes the Linux64 platform SDK that dcclinux64 links against (tools\build-linux.ps1) from a WSL distribution,
  without PAServer.

.DESCRIPTION
  Copies out of the distribution what the linker reads: the top-level files of /usr/lib/x86_64-linux-gnu (shared
  libraries, linker scripts, crt1.o, crti.o, crtn.o, libc_nonshared.a), of /usr/lib/gcc/x86_64-linux-gnu/<gcc>
  (crtbegin.o, crtend.o, libgcc.a, libgcc_s.so), /lib64/ld-linux-x86-64.so.2 and /usr/include. Symbolic links are
  dereferenced (Windows tools do not follow them); "lib" becomes a junction to "usr\lib" (merged /usr, as the
  distribution has it). The distribution needs the packages libc6-dev, libgcc-<n>-dev and zlib1g-dev (libz.so:
  System.ZLib links -lz) (the script installs them with -Install).

  The SDK is a copy of one distribution's libraries: programs linked against it need that glibc version or a later
  one. The default is Ubuntu 22.04 (glibc 2.35): its programs run on Ubuntu 22.04 and later, Debian 12, Fedora, ...
  (D:\LinuxSDK\ubuntu-22.04, the default SDK of tools\build-linux.ps1); an SDK of Ubuntu 26.04 (glibc 2.43) stays
  selectable with -Sdk.

  -CreateDistro installs the WSL distribution first when it is missing, without the first-run user prompt
  (wsl --install --no-launch --web-download --location <DistroRoot>\<Distro>); "wsl -d <Distro> -u root" works
  then.

.EXAMPLE
  .\tools\make-linux-sdk.ps1 -CreateDistro -Install
  .\tools\make-linux-sdk.ps1 -Distro Ubuntu-26.04 -Install
#>
param(
  [string] $Distro = 'Ubuntu-22.04',
  # Default: D:\LinuxSDK\<distro in lower case>.
  [string] $Sdk = '',
  # apt-get install the packages with the startup objects and the linker scripts first.
  [switch] $Install,
  # Install the WSL distribution when it is not there (non-interactive, into <DistroRoot>\<Distro>).
  [switch] $CreateDistro,
  [string] $DistroRoot = 'D:\WSL'
)

$ErrorActionPreference = 'Stop'

if (-not $Sdk) { $Sdk = Join-Path 'D:\LinuxSDK' $Distro.ToLower() }
# (wsl -l writes UTF-16.)
$installed = (wsl -l -q | Out-String) -replace "`0", '' -split "`r?`n" | ForEach-Object { $_.Trim() }
if ($installed -notcontains $Distro) {
  if (-not $CreateDistro) { throw "No WSL distribution $Distro (-CreateDistro installs it)" }
  Write-Host "Installing the WSL distribution $Distro into $(Join-Path $DistroRoot $Distro)"
  wsl --install -d $Distro --no-launch --web-download --location (Join-Path $DistroRoot $Distro)
  if ($LASTEXITCODE -ne 0) { throw "wsl --install -d $Distro failed ($LASTEXITCODE)" }
}

New-Item -ItemType Directory -Force -Path $Sdk | Out-Null
$SdkFull = (Resolve-Path $Sdk).Path
$drive = $SdkFull.Substring(0, 1).ToLower()
$wslSdk = "/mnt/$drive" + $SdkFull.Substring(2).Replace('\', '/')

if ($Install) {
  # libgcc-s1's version names the matching libgcc-<n>-dev.
  # (--exec: no shell between, which would expand the format.)
  $gccMajor = (wsl -d $Distro -u root --exec dpkg-query -W -f '${Version}' libgcc-s1) -replace '^(\d+).*', '$1'
  wsl -d $Distro -u root --exec timeout 600 apt-get update -qq
  if ($LASTEXITCODE -ne 0) { throw "apt-get update failed ($LASTEXITCODE)" }
  wsl -d $Distro -u root --exec env DEBIAN_FRONTEND=noninteractive timeout 900 apt-get install -y -qq libc6-dev "libgcc-$gccMajor-dev" zlib1g-dev
  if ($LASTEXITCODE -ne 0) { throw "apt-get install failed ($LASTEXITCODE)" }
}

$script = @'
set -e
SDK="$1"
GCC=$(ls /usr/lib/gcc/x86_64-linux-gnu | sort -V | tail -1)
test -n "$GCC" || { echo "no /usr/lib/gcc/x86_64-linux-gnu/<version>: install libgcc-<n>-dev"; exit 1; }
test -f /usr/lib/x86_64-linux-gnu/crt1.o || { echo "no crt1.o: install libc6-dev"; exit 1; }
mkdir -p "$SDK/usr/lib/x86_64-linux-gnu" "$SDK/usr/lib/gcc/x86_64-linux-gnu/$GCC" "$SDK/lib64" "$SDK/usr/include"
# Top-level regular files and links to them, links dereferenced.
find -L /usr/lib/x86_64-linux-gnu -maxdepth 1 -type f -exec cp -L --preserve=timestamps -t "$SDK/usr/lib/x86_64-linux-gnu" {} +
find -L "/usr/lib/gcc/x86_64-linux-gnu/$GCC" -maxdepth 1 -type f -exec cp -L --preserve=timestamps -t "$SDK/usr/lib/gcc/x86_64-linux-gnu/$GCC" {} +
cp -L /lib64/ld-linux-x86-64.so.2 "$SDK/lib64/"
cp -rL /usr/include/. "$SDK/usr/include/" 2>/dev/null || true
. /etc/os-release
echo "$PRETTY_NAME, glibc $(ldd --version | head -1 | awk '{print $NF}'), gcc $GCC" > "$SDK/sdk-info.txt"
echo "gcc $GCC"
'@
Write-Host "Copying the libraries of $Distro into $SdkFull"
# The script goes through a file: Windows PowerShell mangles quotes in arguments of native programs.
$scriptFile = Join-Path $SdkFull 'make-sdk.sh'
[IO.File]::WriteAllText($scriptFile, ($script -replace "`r", ''), (New-Object Text.UTF8Encoding $false))
try {
  wsl -d $Distro -u root -- sh "$wslSdk/make-sdk.sh" $wslSdk
  if ($LASTEXITCODE -ne 0) { throw "copying from $Distro failed ($LASTEXITCODE)" }
} finally {
  Remove-Item $scriptFile -ErrorAction SilentlyContinue
}

# /lib is /usr/lib in the distribution (merged /usr); a junction instead of a second copy.
$lib = Join-Path $SdkFull 'lib'
if (-not (Test-Path $lib)) {
  New-Item -ItemType Junction -Path $lib -Target (Join-Path $SdkFull 'usr\lib') | Out-Null
}
$size = (Get-ChildItem -Recurse -File (Join-Path $SdkFull 'usr') | Measure-Object Length -Sum).Sum
Write-Host "OK -> $SdkFull ($([Math]::Round($size / 1MB)) MB): $(Get-Content (Join-Path $SdkFull 'sdk-info.txt'))"
