# The Pango text engine on Linux (2026-10-14)

`src/Probe/TextProbe.dpr`, Linux64 in WSL2 (Ubuntu 26.04, Pango 1.57.0, FreeType 2.14.2, HarfBuzz 12.3.2, fonts
DejaVu, Noto core, Noto Color Emoji, Droid Sans Fallback; Vulkan on Mesa's lavapipe) and Win64 (Windows 11, Vulkan on
an RX 9070 XT), the same PC. `tools/run-textprobe-linux.sh`; Windows: `TextProbe --engine=native|skia --bench=<n>`.

## Layout and glyphs

Paragraphs of about 190 characters (31 words), DejaVu Sans (Linux) or Segoe UI (Windows) 12.5 px, wrapped at 260 px.
"Layout": new `TTextLayout`s and their `TextHeight`. "Glyph coverage": the engine's `RasterizeGlyph` of every
distinct glyph of those layouts at 4 subpixel positions (144 glyphs).

| | Pango (Linux) | Skia (Linux) | DirectWrite (Windows) | Skia (Windows) |
|---|---|---|---|---|
| first layout at a new font size | 2.5 ms | 84 ms | 0.6 ms | 0.8 ms |
| layout, per paragraph (300 paragraphs; Skia on Linux: 30) | 0.10 ms | 84 ms | 0.031 ms | 0.096 ms |
| glyph coverage, per glyph | 1.5 us | 7.6 us | 1.0 us | 4.9 us |

## Paragraph-heavy frames

The paragraphs drawn into a 1600 x 1600 bitmap at 11.5 px (a size not drawn before) until the bitmap has them
(`TBitmap.Map`): the first frame (layouts and glyphs made), the same frame again (layouts cached), a frame of new
paragraphs (glyphs cached, best of 3). Linux draws on lavapipe (the CPU), so compare the engines within a platform.

| | Pango, 30 | Skia, 30 | Pango, 300 | DirectWrite, 30 | Skia (Win), 30 | DirectWrite, 300 | Skia (Win), 300 |
|---|---|---|---|---|---|---|---|
| first frame | 27 ms | 2737 ms | 169 ms | 4.1 ms | 5.0 ms | 17.9 ms | 34.7 ms |
| same frame again | 9.1 ms | 11.1 ms | 82 ms | 5.2 ms | 4.6 ms | 8.6 ms | 9.0 ms |
| new paragraphs | 11.7 ms | 2638 ms | 105 ms | 2.5 ms | 3.0 ms | 13.0 ms | 25.4 ms |

Skia's layouts on Linux take about 80 ms each, on Windows 0.1 ms; Skia's own scene of TextProbe (about 60 layouts)
took 8.5 s on Linux, Pango's 0.34 s.

## Images and numbers

- Pango and Skia on Linux: the same text widths to 0.01 px for Latin, Cyrillic, Greek, Arabic, Hebrew, Thai and
  mixed lines; lines 16.30 px (Pango, DejaVu Sans 14) against 16 (Skia rounds line heights); identical glyph shapes
  (both unhinted coverage at quarter pixels).
- Pango draws what Skia's engine does not: underline and strikeout given as attributes of ranges, word trimming
  (Skia ellipsizes at characters), emoji presentation of U+2764 U+FE0F (Skia: the text heart), a font added through
  FMX's `TFontManager` (`--customfont`: Comic Sans MS from a file, also when added after the first layouts; Skia falls
  back to Noto Sans).
- A variable font (Ubuntu Sans, weight and width axes): every FMX weight and the condensed width as Skia draws them
  (the line 900.47 px wide with Pango, 899.98 with Skia).
- Arabic (joined, right to left), Hebrew, Devanagari conjuncts, Thai marks, the fi ligature, emoji with skin tones,
  ZWJ families and flags: drawn correctly. Korean shows missing glyphs (no Hangul font installed); U+3001 and U+3002
  come from Noto Sans Mongolian, as fontconfig orders the fallback fonts for the C locale (GTK shows the same).
- PortProbe built without the Skia units runs without `libsk4d.so` (61 FPS on lavapipe); its frame differs from the
  Skia build's only in the text (3.6 % of the pixels by more than 3 %: subpixel positions and the fractional line
  heights). Sizes: PortProbe 15.5 MB without Skia; 16.0 MB with the Skia engines plus `libsk4d.so` 26.7 MB.
