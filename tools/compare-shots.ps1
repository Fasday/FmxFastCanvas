<#
.SYNOPSIS
  Compares benchmark screenshots against a reference image.

.DESCRIPTION
  For every image prints the mean absolute difference per channel (0..255) and the share of
  pixels whose summed RGB difference exceeds -Threshold. Images must have the same size.

.EXAMPLE
  .\tools\compare-shots.ps1 -Reference results\raw\shots\rects_d2d.png -Images results\raw\shots\rects_*.png
#>
param(
  [Parameter(Mandatory = $true)] [string] $Reference,
  [Parameter(Mandatory = $true)] [string[]] $Images,
  [int] $Threshold = 24
)

$ErrorActionPreference = 'Stop'

if (-not ('ShotDiff' -as [type])) {
  Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public static class ShotDiff
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

    // Returns { meanAbs, shareAboveThreshold }.
    public static double[] Compare(string reference, string image, int threshold)
    {
        int w1, h1, w2, h2;
        var a = Load(reference, out w1, out h1);
        var b = Load(image, out w2, out h2);
        if (w1 != w2 || h1 != h2)
            throw new ArgumentException(string.Format("Size differs: {0}x{1} vs {2}x{3}", w1, h1, w2, h2));
        long sum = 0, above = 0;
        for (int i = 0; i < a.Length; i += 4)
        {
            int d = Math.Abs(a[i] - b[i]) + Math.Abs(a[i + 1] - b[i + 1]) + Math.Abs(a[i + 2] - b[i + 2]);
            sum += d;
            if (d > threshold) above++;
        }
        long pixels = a.Length / 4;
        return new double[] { (double)sum / (pixels * 3), (double)above / pixels };
    }
}
'@
}

$refPath = (Resolve-Path $Reference).Path
$files = $Images | ForEach-Object { Get-ChildItem $_ } | Sort-Object FullName -Unique
foreach ($f in $files) {
  if ($f.FullName -eq $refPath) { continue }
  $r = [ShotDiff]::Compare($refPath, $f.FullName, $Threshold)
  [pscustomobject]@{
    Image        = $f.Name
    MeanAbs      = [Math]::Round($r[0], 3)
    PixelsDiffPct = [Math]::Round($r[1] * 100, 3)
  }
}
