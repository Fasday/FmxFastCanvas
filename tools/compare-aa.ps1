<#
.SYNOPSIS
  Compares screenshots of the "aa" scene with the reference image and builds a contact sheet.

.DESCRIPTION
  The reference and <reference>.regions.csv come from AaReference.exe (same size, scale and N as
  the benchmark run). For every image the per-pixel error is the mean absolute RGB difference
  (0..255). Reported over the geometry bands only (text bands excluded):
    MAE       mean error over all geometry pixels
    EdgeMAE   mean error over edge pixels: where the reference is not flat (differs from a
              neighbour), dilated by one pixel; the same mask for every image
    P99       99th percentile of the error over the geometry pixels
    AbovePct  share of geometry pixels with error > -Threshold
    <section> MAE per section of the pattern (all tiles), and TextMAE over the text bands
  With -Results (the benchmark CSV) every image is matched to its run by the --screenshot path in
  command_line, adding canvas, quality, status and frame_ms_median.

  -Sheet writes a PNG: rows are the crop regions from the regions file, columns the reference and
  the images, each crop zoomed -Zoom times with nearest-neighbour sampling.

.EXAMPLE
  .\tools\compare-aa.ps1 -Reference results\raw\shots\aa_ref.png -Images results\raw\shots\aa_*_default.png `
    -Results results\raw\aa.csv -Sheet results\raw\shots\sheet_aa_default.png
#>
param(
  [Parameter(Mandatory = $true)] [string] $Reference,
  [Parameter(Mandatory = $true)] [string[]] $Images,
  [string] $Regions = '',
  [string] $Results = '',
  [string] $Sheet = '',
  [string] $OutCsv = '',
  [int] $Threshold = 16,
  [int] $CropWidth = 48,
  [int] $CropHeight = 40,
  [int] $Zoom = 8
)

$ErrorActionPreference = 'Stop'

if (-not ('AaCompare' -as [type])) {
  Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.Runtime.InteropServices;

public static class AaCompare
{
    public static int[] Load(string path, out int width, out int height)
    {
        using (var bmp = new Bitmap(path))
        {
            width = bmp.Width;
            height = bmp.Height;
            var data = bmp.LockBits(new Rectangle(0, 0, width, height), ImageLockMode.ReadOnly,
                PixelFormat.Format32bppArgb);
            try
            {
                var px = new int[width * height];
                for (int y = 0; y < height; y++)
                    Marshal.Copy(IntPtr.Add(data.Scan0, y * data.Stride), px, y * width, width);
                return px;
            }
            finally { bmp.UnlockBits(data); }
        }
    }

    public static void FillRect(byte[] mask, int w, int h, double x, double y, double rw, double rh, byte value)
    {
        int x0 = Math.Max(0, (int)Math.Round(x)), y0 = Math.Max(0, (int)Math.Round(y));
        int x1 = Math.Min(w, (int)Math.Round(x + rw)), y1 = Math.Min(h, (int)Math.Round(y + rh));
        for (int yy = y0; yy < y1; yy++)
            for (int xx = x0; xx < x1; xx++)
                mask[yy * w + xx] = value;
    }

    static int Diff(int a, int b)
    {
        return Math.Abs(((a >> 16) & 255) - ((b >> 16) & 255)) + Math.Abs(((a >> 8) & 255) - ((b >> 8) & 255)) +
            Math.Abs((a & 255) - (b & 255));
    }

    // 1 where the reference differs from one of its 8 neighbours by more than 3 (sum of channels),
    // dilated by one pixel.
    public static byte[] EdgeMask(int[] px, int w, int h)
    {
        var edge = new byte[w * h];
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++)
            {
                int c = px[y * w + x];
                bool e = false;
                for (int dy = -1; dy <= 1 && !e; dy++)
                    for (int dx = -1; dx <= 1 && !e; dx++)
                    {
                        int nx = x + dx, ny = y + dy;
                        if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
                        if (Diff(c, px[ny * w + nx]) > 3) e = true;
                    }
                if (e) edge[y * w + x] = 1;
            }
        var result = new byte[w * h];
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++)
            {
                if (edge[y * w + x] == 0) continue;
                for (int dy = -1; dy <= 1; dy++)
                    for (int dx = -1; dx <= 1; dx++)
                    {
                        int nx = x + dx, ny = y + dy;
                        if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
                        result[ny * w + nx] = 1;
                    }
            }
        return result;
    }

    // { count, mae, p95, p99, sharePct above threshold, edgeCount, edgeMae } over pixels with mask == value.
    public static double[] Stats(int[] a, int[] b, byte[] mask, byte value, byte[] edge, int threshold)
    {
        var hist = new long[766];
        long count = 0, sum = 0, above = 0, edgeCount = 0, edgeSum = 0;
        for (int i = 0; i < a.Length; i++)
        {
            if (mask[i] != value) continue;
            int d = Diff(a[i], b[i]);
            hist[d]++;
            count++;
            sum += d;
            if (d > threshold * 3) above++;
            if (edge != null && edge[i] != 0) { edgeCount++; edgeSum += d; }
        }
        return new double[] {
            count,
            count > 0 ? sum / 3.0 / count : 0,
            Percentile(hist, count, 0.95) / 3.0,
            Percentile(hist, count, 0.99) / 3.0,
            count > 0 ? 100.0 * above / count : 0,
            edgeCount,
            edgeCount > 0 ? edgeSum / 3.0 / edgeCount : 0 };
    }

    static int Percentile(long[] hist, long count, double q)
    {
        if (count == 0) return 0;
        long target = (long)Math.Ceiling(q * count), acc = 0;
        for (int i = 0; i < hist.Length; i++)
        {
            acc += hist[i];
            if (acc >= target) return i;
        }
        return hist.Length - 1;
    }

    // Mean error per id 1..ids over pixels with sections[i] == id.
    public static double[] SectionMae(int[] a, int[] b, byte[] sections, int ids)
    {
        var sum = new long[ids + 1];
        var count = new long[ids + 1];
        for (int i = 0; i < a.Length; i++)
        {
            int s = sections[i];
            if (s == 0) continue;
            sum[s] += Diff(a[i], b[i]);
            count[s]++;
        }
        var result = new double[ids];
        for (int s = 1; s <= ids; s++)
            result[s - 1] = count[s] > 0 ? sum[s] / 3.0 / count[s] : 0;
        return result;
    }

    public static void ContactSheet(string outPath, string[] paths, string[] labels, string[] cropNames,
        int[] cropX, int[] cropY, int cw, int ch, int zoom)
    {
        const int gap = 6, header = 24, rowLabel = 90;
        int cellW = cw * zoom, cellH = ch * zoom;
        int width = rowLabel + paths.Length * (cellW + gap);
        int height = header + cropNames.Length * (cellH + gap);
        using (var sheet = new Bitmap(width, height, PixelFormat.Format24bppRgb))
        using (var g = Graphics.FromImage(sheet))
        using (var font = new Font("Arial", 12f, FontStyle.Bold, GraphicsUnit.Pixel))
        {
            g.Clear(Color.FromArgb(64, 64, 64));
            g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
            g.InterpolationMode = InterpolationMode.NearestNeighbor;
            g.PixelOffsetMode = PixelOffsetMode.Half;
            for (int c = 0; c < paths.Length; c++)
            {
                int x0 = rowLabel + c * (cellW + gap);
                g.DrawString(labels[c], font, Brushes.White, x0 + 2, 5);
                using (var img = new Bitmap(paths[c]))
                {
                    for (int r = 0; r < cropNames.Length; r++)
                    {
                        int y0 = header + r * (cellH + gap);
                        var src = new Rectangle(cropX[r], cropY[r], cw, ch);
                        g.DrawImage(img, new Rectangle(x0, y0, cellW, cellH), src, GraphicsUnit.Pixel);
                    }
                }
            }
            for (int r = 0; r < cropNames.Length; r++)
                g.DrawString(cropNames[r], font, Brushes.White, 4, header + r * (cellH + gap) + 4);
            sheet.Save(outPath, ImageFormat.Png);
        }
    }
}
'@
}

$refPath = (Resolve-Path $Reference).Path
if ($Regions -eq '') { $Regions = [IO.Path]::ChangeExtension($refPath, '.regions.csv') }
$regionRows = Import-Csv $Regions
$inv = [Globalization.CultureInfo]::InvariantCulture

$w = 0; $h = 0
$refPx = [AaCompare]::Load($refPath, [ref]$w, [ref]$h)

# Band mask: 1 = geometry, 2 = text (text drawn last, so it wins where bands touch).
$bands = New-Object byte[] ($w * $h)
foreach ($kind in @('geometry', 'text')) {
  $value = if ($kind -eq 'geometry') { 1 } else { 2 }
  foreach ($r in ($regionRows | Where-Object kind -eq $kind)) {
    [AaCompare]::FillRect($bands, $w, $h, [double]::Parse($r.x, $inv), [double]::Parse($r.y, $inv),
      [double]::Parse($r.w, $inv), [double]::Parse($r.h, $inv), [byte]$value)
  }
}
$sectionNames = @($regionRows | Where-Object kind -eq 'section' | ForEach-Object name | Select-Object -Unique)
$sections = New-Object byte[] ($w * $h)
foreach ($r in ($regionRows | Where-Object kind -eq 'section')) {
  $id = [Array]::IndexOf($sectionNames, $r.name) + 1
  [AaCompare]::FillRect($sections, $w, $h, [double]::Parse($r.x, $inv), [double]::Parse($r.y, $inv),
    [double]::Parse($r.w, $inv), [double]::Parse($r.h, $inv), [byte]$id)
}
$edge = [AaCompare]::EdgeMask($refPx, $w, $h)

$runs = @()
if ($Results -ne '') { $runs = @(Import-Csv $Results) }

$files = $Images | ForEach-Object { Get-ChildItem $_ } | Sort-Object FullName -Unique |
  Where-Object { $_.FullName -ne $refPath }
$rows = @()
foreach ($f in $files) {
  $iw = 0; $ih = 0
  $px = [AaCompare]::Load($f.FullName, [ref]$iw, [ref]$ih)
  if ($iw -ne $w -or $ih -ne $h) { throw "Size differs: $($f.Name) ${iw}x${ih}, reference ${w}x${h}" }
  $g = [AaCompare]::Stats($refPx, $px, $bands, 1, $edge, $Threshold)
  $t = [AaCompare]::Stats($refPx, $px, $bands, 2, $null, $Threshold)
  $s = [AaCompare]::SectionMae($refPx, $px, $sections, $sectionNames.Count)
  $run = $runs | Where-Object { $_.command_line -like "*$($f.Name)*" } | Select-Object -Last 1
  $row = [ordered]@{
    Image    = $f.Name
    Canvas   = if ($run) { $run.canvas } else { '' }
    Quality  = if ($run) { $run.quality } else { '' }
    GeomAA   = if ($run) { $run.geom_aa } else { '' }
    Status   = if ($run) { $run.status } else { '' }
    FrameMs  = if ($run) { [Math]::Round([double]::Parse($run.frame_ms_median, $inv), 3) } else { $null }
    MAE      = [Math]::Round($g[1], 3)
    EdgeMAE  = [Math]::Round($g[6], 2)
    P99      = [Math]::Round($g[3], 1)
    AbovePct = [Math]::Round($g[4], 3)
  }
  for ($i = 0; $i -lt $sectionNames.Count; $i++) { $row[$sectionNames[$i]] = [Math]::Round($s[$i], 3) }
  $row['TextMAE'] = [Math]::Round($t[1], 3)
  $rows += [pscustomobject]$row
}

if ($OutCsv -ne '') { $rows | Export-Csv -NoTypeInformation -Path $OutCsv }

if ($Sheet -ne '') {
  $crops = @($regionRows | Where-Object kind -eq 'crop')
  $cropNames = [string[]]@($crops | ForEach-Object name)
  $cropX = [int[]]@($crops | ForEach-Object {
    $cx = [double]::Parse($_.x, $inv) + [double]::Parse($_.w, $inv) / 2
    [Math]::Min([Math]::Max(0, [int][Math]::Round($cx - $CropWidth / 2)), $w - $CropWidth) })
  $cropY = [int[]]@($crops | ForEach-Object {
    $cy = [double]::Parse($_.y, $inv) + [double]::Parse($_.h, $inv) / 2
    [Math]::Min([Math]::Max(0, [int][Math]::Round($cy - $CropHeight / 2)), $h - $CropHeight) })
  $paths = [string[]](@($refPath) + @($files | ForEach-Object FullName))
  $labels = [string[]](@('reference') + @($rows | ForEach-Object {
    if ($_.Canvas -ne '') { "$($_.Canvas) / $($_.Quality)  MAE $($_.MAE)" } else { $_.Image } }))
  $sheetPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Sheet)
  [AaCompare]::ContactSheet($sheetPath, $paths, $labels, $cropNames, $cropX, $cropY, $CropWidth, $CropHeight, $Zoom)
  Write-Host "Contact sheet: $sheetPath"
}

$rows
