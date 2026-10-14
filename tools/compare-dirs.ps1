<#
.SYNOPSIS
  Compares the screenshots of two directories pair by pair (same file names): identical or not, how many pixels
  differ, by how much.

.DESCRIPTION
  For every PNG of -Reference that -Other has too: Identical (every pixel equal), DiffPixelsPct (any channel differs),
  Above24Pct (the summed RGB difference exceeds 24, as compare-shots.ps1), MaxDiff (largest channel difference) and
  MeanAbs (mean absolute difference per channel). -Map renames: "fcvk=fcvkskia" compares <scene>_fcvk.png of the
  reference with <scene>_fcvkskia.png of the other directory.

.EXAMPLE
  .\tools\compare-dirs.ps1 -Reference results\raw\shots-base -Other results\raw\shots-new
#>
param(
  [Parameter(Mandatory = $true)] [string] $Reference,
  [Parameter(Mandatory = $true)] [string] $Other,
  [string] $Map = ''
)

$ErrorActionPreference = 'Stop'

if (-not ('DirDiff' -as [type])) {
  Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public static class DirDiff
{
    static byte[] Load(string path, out int width, out int height)
    {
        using (var bmp = new Bitmap(path))
        {
            width = bmp.Width;
            height = bmp.Height;
            var data = bmp.LockBits(new Rectangle(0, 0, width, height), ImageLockMode.ReadOnly,
                PixelFormat.Format32bppArgb);
            try
            {
                var bytes = new byte[data.Stride * height];
                Marshal.Copy(data.Scan0, bytes, 0, bytes.Length);
                return bytes;
            }
            finally { bmp.UnlockBits(data); }
        }
    }

    // { diffShare, above24Share, maxDiff, meanAbs }
    public static double[] Compare(string a, string b)
    {
        int w1, h1, w2, h2;
        var x = Load(a, out w1, out h1);
        var y = Load(b, out w2, out h2);
        if (w1 != w2 || h1 != h2)
            throw new ArgumentException(string.Format("Size differs: {0}x{1} vs {2}x{3}", w1, h1, w2, h2));
        long diff = 0, above = 0, sum = 0;
        int max = 0;
        for (int i = 0; i < x.Length; i += 4)
        {
            int r = Math.Abs(x[i] - y[i]), g = Math.Abs(x[i + 1] - y[i + 1]), bl = Math.Abs(x[i + 2] - y[i + 2]);
            int d = r + g + bl;
            if (d > 0) diff++;
            if (d > 24) above++;
            sum += d;
            max = Math.Max(max, Math.Max(r, Math.Max(g, bl)));
        }
        long pixels = x.Length / 4;
        return new double[] { (double)diff / pixels, (double)above / pixels, max, (double)sum / (pixels * 3) };
    }
}
'@
}

$from = ''
$to = ''
if ($Map) { $from, $to = $Map.Split('=') }
foreach ($f in Get-ChildItem (Join-Path $Reference '*.png') | Sort-Object Name) {
  $name = $f.Name
  if ($from) {
    if (-not $name.EndsWith("_$from.png")) { continue }
    $name = $name.Substring(0, $name.Length - "_$from.png".Length) + "_$to.png"
  }
  $o = Join-Path $Other $name
  if (-not (Test-Path $o)) { continue }
  $r = [DirDiff]::Compare($f.FullName, $o)
  [pscustomobject]@{
    Image         = $f.Name
    Identical     = ($r[0] -eq 0)
    DiffPixelsPct = [Math]::Round($r[0] * 100, 4)
    Above24Pct    = [Math]::Round($r[1] * 100, 4)
    MaxDiff       = $r[2]
    MeanAbs       = [Math]::Round($r[3], 4)
  }
}
