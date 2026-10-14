<#
.SYNOPSIS
  Makes the Linux64 platform SDK that dcclinux64 links against (tools\build-linux.ps1) from a WSL distribution,
  without PAServer.

.DESCRIPTION
  Copies out of the distribution what the linker reads: the top-level files of /usr/lib/x86_64-linux-gnu (shared
  libraries, linker scripts, crt1.o, crti.o, crtn.o, libc_nonshared.a), of /usr/lib/gcc/x86_64-linux-gnu/<gcc>
  (crtbegin.o, crtend.o, libgcc.a, libgcc_s.so), /lib64/ld-linux-x86-64.so.2 and /usr/include. Symbolic links are
  dereferenced (Windows tools do not follow them); "lib" becomes a junction to "usr\lib" (merged /usr, as the
  distribution has it). The distribution needs the packages libc6-dev and libgcc-<n>-dev (the script installs them
  with -Install).

  The SDK is a copy of one distribution's libraries: programs linked against it need that glibc version or a later
  one (an SDK from an older distribution makes programs that run on more systems).

.EXAMPLE
  .\tools\make-linux-sdk.ps1
  .\tools\make-linux-sdk.ps1 -Distro Ubuntu-26.04 -Sdk D:\LinuxSDK\ubuntu-26.04 -Install
#>
param(
  [string] $Distro = 'Ubuntu-26.04',
  [string] $Sdk = 'D:\LinuxSDK\ubuntu-26.04',
  # apt-get install the packages with the startup objects and the linker scripts first.
  [switch] $Install
)

$ErrorActionPreference = 'Stop'

New-Item -ItemType Directory -Force -Path $Sdk | Out-Null
$SdkFull = (Resolve-Path $Sdk).Path
$drive = $SdkFull.Substring(0, 1).ToLower()
$wslSdk = "/mnt/$drive" + $SdkFull.Substring(2).Replace('\', '/')

if ($Install) {
  # libgcc-s1's version names the matching libgcc-<n>-dev.
  # (--exec: no shell between, which would expand the format.)
  $gccMajor = (wsl -d $Distro -u root --exec dpkg-query -W -f '${Version}' libgcc-s1) -replace '^(\d+).*', '$1'
  wsl -d $Distro -u root --exec env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq libc6-dev "libgcc-$gccMajor-dev"
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
