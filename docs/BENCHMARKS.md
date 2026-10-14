# Benchmarks

`src/Bench/FmxCanvasBench.dpr` draws one scene in a 1920 x 1080 window with one canvas and measures it. The tables
below compare FastCanvas with the canvases that ship with FMX, on the same scenes and parameters, measured in one
session (absolute numbers of a machine drift by several percent between days; comparisons across sessions are not
meaningful).

## Method

- **Throughput mode**: frames are drawn back to back without waiting for vertical blank (the window is invalidated
  as soon as the previous frame is painted; FastCanvas presents with `AllowTearing`). The frame time is the time of
  one `PaintRects` of the form, median over 5 s after 2 s of warm-up.
- Every scene has three sizes (`light`, `medium`, `heavy`: the number N of shapes, strings, controls or objects);
  the tables use `medium` and `heavy`.
- Order: for each repeat and scene all canvases run back to back, so slow drift affects all of them equally; 3
  repeats, the tables show the median of the three medians.
- Win64 release build, no debugger, primary monitor, nothing else running.
- Each run records the environment (OS, CPU, GPU and driver, monitor, DPI, compiler, commit, every FMX global flag)
  in `runs.csv`; screenshots of every scene and canvas check that all canvases draw the same picture.

Machine: AMD Ryzen 5 7500F (6 cores), AMD Radeon RX 9070 XT (driver 32.0.31041.1004), Windows 11 Pro 25H2 (26200),
32 GB, monitor 2560 x 1440 at 240 Hz, 100 % scale; Delphi 13.2 (37.0.60952.8797).

### Canvases

| Name | Canvas |
|---|---|
| `d2d` | FMX default: Direct2D 1.0 on Direct3D 10.1 (`TCanvasD2D`) |
| `gpu` | FMX GPU canvas on the DX11 context (`GlobalUseGPUCanvas`) |
| `gdip` | GDI+ |
| `skia` | Skia4Delphi, CPU raster |
| `skiavk` | Skia4Delphi on Vulkan |
| `fc` | FastCanvas on Direct3D 11, with its 3D context |
| `fcdx12` | FastCanvas on Direct3D 12, with its 3D context |
| `fcdx12rt` / `ao` / `soft` / `refl` | `fcdx12` with ray-traced shadows / shadows and ambient occlusion / soft shadows / shadows and reflections |
| `fcvk` | FastCanvas on Vulkan, with its 3D context (see "Vulkan" below) |
| `fcvkrt` / `ao` / `soft` / `refl` | `fcvk` with the ray-traced effects of `fcdx12rt` / `ao` / `soft` / `refl` |
| `fcvksep` | `fcvk` with FMX's stock 3D context on a device of its own |
| `fcvkskia` | `fcvk` with the Skia geometry and text engines (those of Android and Linux) |

### Scenes

| Scene | What is drawn |
|---|---|
| `rects` | `FillRect` with a solid brush, N rectangles 8..96 px |
| `roundrects` | `FillRect` + `DrawRect` with radius 2..16, N shapes 16..96 px, stroke 1..3 |
| `ellipses` | `FillEllipse` + `DrawEllipse`, N ellipses 6..96 px, stroke 1..3 |
| `lines` | `DrawLine`, N rotating lines 20..300 px, width 0.5..6, 30 % dashed, flat/round caps |
| `strokes` | Dashed `DrawRect`/`DrawEllipse` outlines 16..160 px, width 1..4, and gradient lines |
| `gradients` | Rectangles, round rectangles, ellipses 16..128 px with 32 linear/radial gradient brushes |
| `paths` | Fill and stroke of 8 static `TPathData` icons, rotating, scale 0.5..3 |
| `bitmaps` | `DrawBitmap` 1:1, 8 icons 32/48 px with alpha, 30 % with opacity < 1 |
| `bitmapscaled` | The same icons scaled 0.5..4x (30 % non-uniform), filtered |
| `clip` | N panels, 3 nested `SaveState`/`IntersectClipRect` levels, 25 % rotated, 30 % with opacity < 1 |
| `text` | `FillText`, N short strings (2..5 words), 16 fonts; laid out on every call |
| `textcached` | The same strings, one persistent `TTextLayout` each (as `TText`/`TLabel` do) |
| `paragraph` | N wrapped paragraphs (80..140 words), persistent `TTextLayout`, moving |
| `reflow` | Like `paragraph`, the wrap width changes every frame: full layout per frame |
| `textedge` | Lines and paragraphs cut by the window edges |
| `aa` | Antialiasing test pattern (lines, small shapes, seams, bitmaps, small text) |
| `rare` | Bitmap brushes, rotated and large text, color emoji |
| `controls` | N standard styled controls in a grid; the container moves, progress bars change |
| `effects` | N moving `TRectangle` + `TText`: 6/8 `TShadowEffect`, 1/8 `TGlowEffect`, 1/8 `TBlurEffect` |
| `offscreen` | `rects` drawn into a client-size `TBitmap` every frame, then `DrawBitmap` |
| `offscreenmap` | `offscreen` + `Map(Read)` and pixel reads after `EndScene` (GPU to CPU synchronization) |
| `listbox` | `TListBox`, N items (text, detail, check box, accessories), scrolled |
| `listview` | `TListView` with images, N items, scrolled |
| `viewport3d` | `TViewport3D`, N rotating lit cubes and spheres |
| `shadows3d` | `TViewport3D`, a floor and N rotating objects above it, a directional and a point light |
| `mirror3d` | `shadows3d` with a shiny floor and shiny, textured objects |

## Results

Measured on 2026-10-09, 1920 x 1080 window, with FastCanvas as it was then (commit `efdbde4` of the development
repository; windows presented through swap chains of their own: the DirectComposition output that is the default now
measured the same speed on 2026-10-13). Full summaries with p95/p99, FPS, CPU time, memory and the screenshot
comparison: [results/2026-10-09_canvases.md](../results/2026-10-09_canvases.md) and
[results/2026-10-09_raytracing.md](../results/2026-10-09_raytracing.md), their tables as CSV next to them. Every run,
with its environment and command line, is in `results/raw/<name>/runs.csv` (paths in the command lines made relative
to the repository; the screenshots are not published).

- Against FMX's default Direct2D canvas (`d2d`), FastCanvas draws the same frames 5 to 60 times faster on shapes,
  text and bitmaps (`rects` 5.5x, `text` 23-26x, `ellipses` 57x, `clip` 84-97x, `gradients` 137-295x), 2 to 4 times
  faster with real controls (`listbox`, `listview`, `controls`), 11 to 24 times with effects and 14 to 24 times in 3D
  scenes.
- The best stock canvas depends on the scene (`gpu` for rectangles, `skiavk` for text and controls, `d2d` for
  reflowed text). FastCanvas is faster than the best of them in every scene but one: `offscreenmap` heavy, where every
  frame reads pixels of a bitmap back to the CPU and waits for the GPU (7.0 ms against 6.3 ms of `gpu`).
- Direct3D 12 is as fast as Direct3D 11 or faster: `effects` 2x, `shadows3d` 1.2-1.6x, `text` up to 1.4x.

Values are frame times in milliseconds (median of 3 repeats of the median frame). `*`: every repeat of this cell
was flagged as throughput-limited by the run script (frame intervals locked to the display's refresh); the value is
shown for reference.
### Frame time, ms, `medium` preset (lower is better)

| Scene | N | d2d | gpu | gdip | skia | skiavk | fc | fcdx12 | d2d / fc | d2d / fcdx12 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `rects` | 16000 | 8.43 | 2.02 | 106 | 14.4 | 11.2 | 1.54 | 1.43 | 5.5x | 5.9x |
| `text` | 250 | 7.84 | 5.19 | 27.6 | 7.17 | 6.19 | 0.335 | 0.296 | 23.4x | 26.5x |
| `textedge` | 16 | 0.385 | 0.544 | 3.21 | 0.631 | 0.254 | 0.221 | 0.166 | 1.7x | 2.3x |
| `textcached` | 250 | 3.55 | 1.27 | 5.04 | 1.70 | 1.09 | 0.320 | 0.242 | 11.1x | 14.7x |
| `paragraph` | 60 | 4.94 | 6.83 | 38.6 | 3.76 | 4.16 | 1.88 | 1.72 | 2.6x | 2.9x |
| `reflow` | 32 | 7.19 | 11.3 | 26.1 | 7.32 | 7.48 | 3.20 | 3.22 | 2.2x | 2.2x |
| `roundrects` | 800 | 7.60 | 31.7 | 26.9 | 8.37 | 5.17 | 0.359 | 0.294 | 21.2x | 25.9x |
| `ellipses` | 700 | 7.42 | 13.2 | 28.8 | 9.18 | 6.52 | 0.130 | 0.131 | 57.1x | 56.7x |
| `lines` | 1900 | 7.99 | 4.18 | 47.0 | 19.7 | 7.01 | 0.352 | 0.350 | 22.7x | 22.8x |
| `strokes` | 450 | 15.2 | 6.91 | 34.2 | 15.2 | 6.65 | 0.486 | 0.481 | 31.2x | 31.6x |
| `gradients` | 100 | 7.92 | 2.54 | 23.5 | 2.82 | 0.549 | 0.058 | 0.050 | 136.6x | 158.4x |
| `paths` | 330 | 7.40 | 28.3 | 46.7 | 19.9 | 5.03 | 0.518 | 0.520 | 14.3x | 14.2x |
| `bitmaps` | 11500 | 9.23 | 73.6 | 498 | 129 | 28.2 | 1.27 | 1.27 | 7.3x | 7.3x |
| `bitmapscaled` | 10800 | 9.20 | 69.9 | 994 | 1148 | 27.8 | 1.30 | 1.31 | 7.1x | 7.0x |
| `clip` | 75 | 8.92 | 5.70 | 5.70 | 3.53 | 0.950 | 0.106 | 0.093 | 84.1x | 95.9x |
| `aa` | 4 | 3.11 | 10.0 | 13.9 | 3.96 | 2.19 | 0.399 | 0.332 | 7.8x | 9.4x |
| `rare` | 3 | 4.23 | 1.52 | 11.9 | 14.5 | 0.815 | 0.092 | 0.072 | 45.9x | 58.7x |
| `controls` | 190 | 8.56 | 5.30 | 14.7 | 9.73 | 4.12 | 1.93 | 1.88 | 4.4x | 4.6x |
| `effects` | 112 | 7.70* | 6.43 | 10.5 | 12.4 | 5.85 | 0.678 | 0.349 | 11.4x | 22.1x |
| `offscreen` | 16000 | 8.40 | 2.05 | 112 | 15.3 | 14.6 | 1.45 | 1.45 | 5.8x | 5.8x |
| `offscreenmap` | 16000 | 8.77 | 3.85 | 111 | 15.3 | 14.6 | 3.48 | 3.51 | 2.5x | 2.5x |
| `listbox` | 4000 | 6.43 | 9.33 | 15.3 | 36.5 | 5.47 | 2.68 | 2.29 | 2.4x | 2.8x |
| `listview` | 10000 | 6.87 | 5.81 | 35.5 | 11.2 | 4.78 | 2.27 | 2.23 | 3.0x | 3.1x |
| `viewport3d` | 160 | 8.53 | 7.94 | 9.60 | 8.66 | 7.64 | 0.562 | 0.519 | 15.2x | 16.4x |
| `shadows3d` | 32 | 2.47 | 2.11 | 4.06 | 3.23 | 2.60 | 0.162 | 0.104 | 15.3x | 23.8x |
| `mirror3d` | 32 | 2.32 | 1.86 | 3.93 | 3.02 | 2.42 | 0.145 | 0.105 | 16.0x | 22.1x |

### Frame time, ms, `heavy` preset (lower is better)

| Scene | N | d2d | gpu | gdip | skia | skiavk | fc | fcdx12 | d2d / fc | d2d / fcdx12 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `rects` | 36000 | 17.9 | 4.33 | 238 | 32.0 | 24.8 | 3.21 | 3.21 | 5.6x | 5.6x |
| `text` | 500 | 14.9 | 9.97 | 55.7 | 24.1 | 12.7 | 0.818 | 0.579 | 18.2x | 25.7x |
| `textedge` | 16 | 0.385 | 0.539 | 3.20 | 0.632 | 0.254 | 0.224 | 0.168 | 1.7x | 2.3x |
| `textcached` | 500 | 6.46 | 2.30 | 9.91 | 9.18 | 1.88 | 0.582 | 0.486 | 11.1x | 13.3x |
| `paragraph` | 135 | 10.5 | 13.9 | 83.4 | 29.2 | 9.41 | 4.32 | 3.84 | 2.4x | 2.7x |
| `reflow` | 72 | 14.9 | 24.3 | 58.3 | 15.9 | 17.8 | 8.72 | 8.75 | 1.7x | 1.7x |
| `roundrects` | 1700 | 16.0 | 67.0 | 57.8 | 16.8 | 10.8 | 0.689 | 0.643 | 23.3x | 24.9x |
| `ellipses` | 1400 | 13.9 | 25.9 | 57.0 | 18.1 | 13.6 | 0.265 | 0.229 | 52.5x | 60.8x |
| `lines` | 4200 | 17.7 | 8.77 | 102 | 41.8 | 15.8 | 0.798 | 0.800 | 22.1x | 22.1x |
| `strokes` | 1000 | 30.7 | 14.7 | 77.2 | 33.3 | 15.0 | 0.999 | 1.02 | 30.7x | 30.2x |
| `gradients` | 250 | 19.5 | 6.26 | 64.9 | 6.35 | 1.23 | 0.092 | 0.066 | 211.5x | 294.9x |
| `paths` | 760 | 17.2 | 66.5 | 109 | 45.8 | 11.7 | 1.21 | 1.20 | 14.3x | 14.4x |
| `bitmaps` | 26500 | 20.7 | 169 | 1164 | 300 | 68.6 | 2.91 | 2.92 | 7.1x | 7.1x |
| `bitmapscaled` | 24000 | 20.0 | 152 | 2197 | 2513 | 64.1 | 2.87 | 2.88 | 7.0x | 6.9x |
| `clip` | 165 | 17.5 | 11.8 | 13.5 | 7.23 | 1.94 | 0.181 | 0.181 | 96.7x | 96.7x |
| `aa` | 9 | 6.91 | 21.7 | 28.3 | 8.11* | 4.64 | 0.784 | 0.714 | 8.8x | 9.7x |
| `rare` | 8 | 10.1 | 3.45 | 30.7 | 37.5 | 1.77 | 0.133 | 0.118 | 76.0x | 85.7x |
| `controls` | 460 | 19.1 | 12.5 | 36.3 | 20.0 | 9.83 | 4.67 | 4.61 | 4.1x | 4.2x |
| `effects` | 208 | 14.6* | 11.3 | 19.1 | 22.2 | 10.8 | 1.25 | 0.603 | 11.7x | 24.2x |
| `offscreen` | 36000 | 17.8 | 4.42 | 248 | 32.6 | 32.1 | 3.43 | 3.26 | 5.2x | 5.5x |
| `offscreenmap` | 36000 | 18.3 | 6.31 | 245 | 32.7 | 32.1 | 7.02* | 7.13* | 2.6x | 2.6x |
| `listbox` | 7000 | 12.9 | 15.0 | 31.0 | 44.7 | 9.23 | 4.72 | 4.05 | 2.7x | 3.2x |
| `listview` | 16000 | 9.66 | 7.74 | 47.9 | 16.7 | 7.08 | 3.62 | 3.62 | 2.7x | 2.7x |
| `viewport3d` | 480 | 22.4 | 20.5 | 24.6 | 22.9 | 21.8 | 1.64 | 1.59 | 13.6x | 14.1x |
| `shadows3d` | 120 | 6.08 | 6.20 | 7.71 | 6.94 | 6.08 | 0.417 | 0.358 | 14.6x | 17.0x |
| `mirror3d` | 120 | 5.14 | 5.20 | 6.91 | 6.06 | 5.31 | 0.418 | 0.360 | 12.3x | 14.3x |

Ray-traced effects on Direct3D 12 (`fcdx12rt` shadows, `fcdx12ao` shadows and ambient occlusion, `fcdx12soft` soft
shadows, `fcdx12refl` shadows and reflections) cost 0.09 to 0.25 ms per frame at 1920 x 1080 on the RX 9070 XT when the
GPU is the bottleneck (`light`); with more objects the main thread is the bottleneck and the GPU work of the effects
mostly disappears behind it. Off, they cost nothing (the `fcdx12` columns of both matrices agree).
### Ray-traced effects, frame time in ms (added time over `fcdx12`)

| Scene | Preset | N | fcdx12 | fcdx12rt | fcdx12ao | fcdx12soft | fcdx12refl |
|---|---|---:|---:|---:|---:|---:|---:|
| `shadows3d` | light | 8 | 0.049 | 0.140 (+0.091) | 0.216 (+0.167) | 0.273 (+0.224) | 0.289 (+0.240) |
| `shadows3d` | medium | 32 | 0.105 | 0.104 (+0.000) | 0.151 (+0.046) | 0.233 (+0.128) | 0.259 (+0.154) |
| `shadows3d` | heavy | 120 | 0.363 | 0.376 (+0.013) | 0.376 (+0.013) | 0.372 (+0.009) | 0.375 (+0.012) |
| `mirror3d` | light | 8 | 0.050 | 0.145 (+0.095) | 0.225 (+0.175) | 0.280 (+0.230) | 0.296 (+0.246) |
| `mirror3d` | medium | 32 | 0.105 | 0.105 (+0.000) | 0.149 (+0.044) | 0.234 (+0.129) | 0.254 (+0.149) |
| `mirror3d` | heavy | 120 | 0.363 | 0.374 (+0.011) | 0.371 (+0.008) | 0.372 (+0.009) | 0.379 (+0.016) |
| `viewport3d` | light | 20 | 0.070 | 0.072 (+0.002) | 0.138 (+0.068) | 0.164 (+0.094) | 0.161 (+0.091) |
| `viewport3d` | medium | 160 | 0.489 | 0.495 (+0.006) | 0.492 (+0.003) | 0.500 (+0.011) | 0.508 (+0.019) |
| `viewport3d` | heavy | 480 | 1.58 | 1.58 (+0.002) | 1.65 (+0.069) | 1.56 (+0.000) | 1.64 (+0.058) |

### Vulkan

`fcvk` against `fcdx12`, measured 2026-10-14 on the same machine but on a 3840 x 2160 monitor at 60 Hz and 150 %
scale (window 1920 x 1080 pixels), `medium`, throughput, frames per second (higher is better): for each of three
repeats every scene ran on both canvases back to back, the table shows the median (1 s warm-up and 3 s measured per
run). Other programs were running that day: repeated runs of a scene varied by up to 10–15 %. The screenshots of all
scenes are identical to `fcdx12` (strokes: 0.001 % of the pixels apart). Geometric mean of the ratios: 1.04.

| Scene | N | fcdx12 | fcvk | fcvk / fcdx12 |
|---|---:|---:|---:|---:|
| `rects` | 16000 | 564 | 581 | 1.03 |
| `text` | 250 | 1832 | 1504 | 0.82 |
| `textedge` | 16 | 2677 | 2437 | 0.91 |
| `textcached` | 250 | 2239 | 1727 | 0.77 |
| `paragraph` | 60 | 531 | 550 | 1.04 |
| `reflow` | 32 | 280 | 279 | 1.00 |
| `roundrects` | 800 | 1940 | 1883 | 0.97 |
| `ellipses` | 700 | 2820 | 3541 | 1.26 |
| `lines` | 1900 | 2138 | 1909 | 0.89 |
| `strokes` | 450 | 862 | 1181 | 1.37 |
| `gradients` | 100 | 3557 | 4540 | 1.28 |
| `paths` | 330 | 1097 | 1423 | 1.30 |
| `bitmaps` | 11500 | 695 | 683 | 0.98 |
| `bitmapscaled` | 10800 | 676 | 629 | 0.93 |
| `clip` | 75 | 3280 | 4204 | 1.28 |
| `aa` | 4 | 1670 | 1459 | 0.87 |
| `rare` | 3 | 3632 | 5210 | 1.43 |
| `controls` | 190 | 379 | 378 | 1.00 |
| `effects` | 112 | 1341 | 1493 | 1.11 |
| `offscreen` | 16000 | 565 | 609 | 1.08 |
| `offscreenmap` | 16000 | 198 | 237 | 1.20 |
| `listbox` | 4000 | 479 | 469 | 0.98 |
| `listview` | 10000 | 361 | 383 | 1.06 |
| `viewport3d` | 160 | 689 | 688 | 1.00 |
| `shadows3d` | 32 | 2557 | 2169 | 0.85 |
| `mirror3d` | 32 | 2563 | 2246 | 0.88 |

The text scenes are slower where the GPU limits them: at 960 x 540 `textcached` runs at the speed of `fcdx12`
(2810 against 2892 FPS), at 1920 x 1080 the render thread spends about a quarter of its time in `vkQueueSubmit2`.
Windows present from a thread of their own, which takes about a third of a CPU core at 2000+ FPS.

Ray-traced effects on Vulkan, `light` preset (the GPU is the bottleneck), one run each, frames per second:

| Scene | fcdx12 / fcvk | rt | ao | soft | refl |
|---|---:|---:|---:|---:|---:|
| `shadows3d` | 4040 / 5960 | 2900 / 6543 | 2258 / 4738 | 2185 / 4979 | 2430 / 5340 |
| `mirror3d` | 4018 / 6019 | 2841 / 6430 | 2638 / 5480 | 2214 / 5004 | 2018 / 5308 |
| `viewport3d` | 3671 / 4046 | 3020 / 4043 | 2329 / 3836 | 2289 / 3973 | 2429 / 3986 |

With `medium` the effects cost `fcvk` nothing measurable (`shadows3d` and `mirror3d` 2750–2880 FPS with every
variant, `viewport3d` 660–715). The images are those of `fcdx12rt` / `ao` / `soft` / `refl`: at most 0.04 % of the
pixels differ, all by 1 of 255 but two or three pixels per image (checked 2026-10-14 at 1920 x 1080, `light`).

`fcvkskia` against `fcvk`, measured 2026-10-13 at 1920 x 1080 (`medium`, throughput, two runs each; before windows
presented from a thread of their own): the same speed but for `strokes`, about 19 % slower (Skia widens the dashed
strokes of every frame more slowly than Direct2D): `strokes` 768 / 779 against 952 / 954 FPS, `paths` 1238 / 1157
against 1195 / 1137, `text` 1979 / 1962 against 1941 / 1939, `paragraph` 547 / 538 against 534 / 518. Screenshots:
`rects`, `ellipses`, `lines`, `gradients`, `bitmaps` and `clip` identical; `roundrects` 0.05 % of the pixels differ,
`strokes` 2.7 % (dash phase along ellipses), `paths` 2.2 % (curve flattening), `text` 3.8 %, `textedge` 5.5 %,
`paragraph` 25 % (Skia's line height is a fraction of a pixel larger, so lines drift and two lines break elsewhere),
`controls` and `aa` 0.5 %, `rare` 1.6 %.

`fcvkown` (the own geometry engine of Android and Linux, text by DirectWrite) against `fcvk` (Direct2D's geometry),
measured 2026-10-14 at 1920 x 1080 on the second monitor (3840 x 2160, 60 Hz; check-only numbers), `medium`,
throughput, median of three runs, frames per second: `strokes` 1226 / 1191, `paths` 1467 / 1395, `lines` 2077 / 1862,
`roundrects` 2391 / 1955, `ellipses` 4812 / 4429, `clip` 5585 / 5703, `rare` 6651 / 5123, `aa` 2491 / 1838: the same
or faster (paths that move are widened every frame, through Direct2D's COM calls on `fcvk`; repeated runs varied by
up to 15 %). Screenshots (`tools\compare-shots.ps1`, pixels whose summed RGB difference exceeds 24): `strokes`
0.35 %, `paths` 0.17 %, `rare` 0.026 %, `roundrects` 0.003 % (antialiasing at curves and dash ends), every other scene
0 % (but for the window's corner pixels).

### Android phone (Mali-G57)

The benchmark's scenes in PortProbe (`--scene=<name> --interval=1`; the APK of `tools\build-android.ps1`, options
in `options.txt`, see `USAGE.md`) on a TECNO KL7 (Mali-G57 MC2, Vulkan 1.1.177, 1080 x 2436 at 120 Hz),
FastCanvas (`FASTCANVAS_VK_GPUTIME=1`) against FMX's `TCanvasGpu` (`--fmx`), 2026-10-14. The counts are the presets'
for the benchmark's 1280 x 720 scaled to the area the scene got (about 0.27 of it); frames per second averaged over
about 9 s after a warm-up of 5 s. Main thread: the form's paint, recording (between `BeginScene` and `EndScene`) and
`EndScene`; `TCanvasGpu` draws and presents in `EndScene`, FastCanvas hands the frame to its render thread there
and waits for the frame before (the display's pace). GPU: the render passes of a frame from timestamps (FastCanvas
only), without the presenting thread's copy into the swap chain (0.7-1.3 ms). "Before": the merge of the Linux work;
"after": with the opaque interiors, the paths as pieces and the scissor of partial frames.

`light`: FPS, main thread ms, GPU ms

| Scene | N | TCanvasGpu FPS | rec / end | FastCanvas before FPS | GPU | after FPS | rec | GPU |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `rects` | 1094 | 119.0 | 2.5 / 5.4 | 29.9 | 32.7 | 119.2 | 1.1 | 4.1 |
| `roundrects` | 46 | 117.6 | 7.3 / 0.9 | 119.1 | 4.8 | 119.0 | 0.2 | 4.0 |
| `ellipses` | 36 | 102.4 | 7.0 / 2.6 | 119.0 | 6.5 | 119.1 | 0.1 | 4.7 |
| `lines` | 101 | 119.1 | 3.8 / 4.2 | 119.1 | 3.0 | 119.1 | 0.3 | 3.0 |
| `strokes` | 27 | 117.4 | 4.5 / 3.6 | 61.1 | 15.3 | 118.9 | 0.2 | 5.5 |
| `gradients` | 7 | 119.0 | 2.2 / 5.7 | 119.1 | 1.0 | 119.0 | 0.1 | 0.9 |
| `paths` | 19 | 99.9 | 9.0 / 0.7 | 55.3 | 17.3 | 119.1 | 0.6 | 5.8 |
| `bitmaps` | 656 | 118.1 | 6.5 / 1.7 | 118.9 | 3.9 | 119.1 | 0.8 | 4.0 |
| `bitmapscaled` | 602 | 119.1 | 6.3 / 1.8 | 119.1 | 6.7 | 119.2 | 0.8 | 6.7 |
| `clip` | 4 | 119.1 | 3.2 / 4.8 | 119.1 | 3.6 | 119.1 | 0.1 | 3.8 |
| `text` | 16 | 118.8 | 4.3 / 3.7 | 119.0 | 1.0 | 119.1 | 0.3 | 0.8 |
| `textcached` | 16 | 119.0 | 1.8 / 6.1 | 119.1 | 0.8 | 119.1 | 0.1 | 0.9 |
| `paragraph` | 4 | 119.1 | 3.4 / 4.6 | 119.1 | 2.0 | 119.1 | 0.1 | 2.1 |
| `controls` | 11 | 118.9 | 4.4 / 3.4 | 119.1 | 2.2 | 119.2 | 2.6 | 2.3 |
| `listbox` | 273 | 118.9 | 5.0 / 1.8 | 98.9 | 9.1 | 119.1 | 2.5 | 6.8 |
| `effects` | 7 | 119.2 | 3.6 / 4.3 | 119.1 | 2.9 | 119.0 | 0.2 | 2.4 |
| `viewport3d` | 5 | 119.1 | 2.6 / 5.1 | 35.2 | 19.8 | 35.7 | 0.3 | 19.8 |

`medium` (after): FPS, main thread ms, GPU ms

| Scene | N | TCanvasGpu FPS | rec / end | FastCanvas FPS | rec | GPU |
|---|---:|---:|---:|---:|---:|---:|
| `rects` | 4375 | 32.6 | 3.3 / 27.0 | 79.1 | 3.4 | 11.5 |
| `roundrects` | 219 | 28.1 | 32.5 / 2.3 | 111.7 | 0.6 | 7.7 |
| `ellipses` | 191 | 41.0 | 21.9 / 2.2 | 72.2 | 0.4 | 13.0 |
| `lines` | 520 | 117.3 | 7.3 / 0.9 | 113.2 | 1.2 | 7.6 |
| `strokes` | 123 | 65.7 | 12.9 / 2.0 | 37.5 | 0.5 | 24.9 |
| `paths` | 90 | 22.9 | 41.4 / 2.3 | 67.4 | 2.1 | 14.0 |
| `bitmaps` | 3145 | 36.0 | 25.4 / 2.2 | 89.1 | 3.1 | 10.4 |
| `text` | 68 | 96.7 | 9.2 / 0.8 | 119.1 | 1.1 | 1.7 |
| `textcached` | 68 | 119.1 | 3.4 / 4.6 | 119.1 | 0.2 | 1.8 |
| `controls` | 52 | 117.4 | 5.9 / 1.8 | 119.0 | 3.4 | 4.4 |
| `listbox` | 1094 | 92.8 | 7.7 / 0.8 | 113.9 | 5.3 | 7.2 |
| `gradients` | 27 | 118.9 | 4.1 / 3.9 | 119.0 | 0.1 | 5.2 |

Where many shapes are drawn, `TCanvasGpu`'s main thread is the limit (`roundrects` 32.5 ms, `paths` 41.4 ms,
`bitmaps` 25.4 ms a frame of recording and drawing) and FastCanvas records the same in 0.4-3.4 ms; where a few large
shapes are drawn the GPU decides. Still slower than `TCanvasGpu` on the phone: `strokes` medium (dashed outlines,
24.9 ms of GPU) and, until the change below, `viewport3d` (the 3D context's 4x multisampled target was stored and
resolved through memory: 19.8 ms of render passes and 7.6 ms of copies a frame; with one sample 6.7 ms and 0.9 ms).

The 3D context's multisampled scenes resolved in their rendering instance, their samples and depth not stored
(`ARCHITECTURE.md`, "The 3D contexts"), same phone and day, FPS and GPU ms a frame (render passes / command buffers,
which hold the copies too); `TCanvasGpu` draws its viewports without multisampling. "Before" is `ea546c1`. The
pictures are the same: PortProbe's scene with the cube at `--time=3.7` pixel for pixel, `viewport3d` antialiased as
before.

| Scene | N | TCanvasGpu FPS | before FPS | GPU | after FPS | GPU |
|---|---:|---:|---:|---:|---:|---:|
| `viewport3d` light | 5 | 117.8 | 35.1 | 19.9 / 27.6 | 115.5-119.0 | 5.9-6.5 / 6.8-7.4 |
| `viewport3d` medium | 44 | 118.5 | 26.1 | 29.8 / 37.6 | 116.6 | 5.8 / 6.7 |
| `effects` light | 7 | 119.2 | 119.1 | 1.8 / 1.8 | 119.1 | 1.8 / 1.8 |
| PortProbe's scene (cube) | | | 115.1 | 5.4 / 7.0 | 114.9-118.3 | 4.9 / 5.4-5.8 |

`viewport3d` medium needed the chunk held for the scene too: its vertices passed the canvas's 256 KB hand-over, the
chunk's end split the scene's rendering instance (stored and loaded again: 31.6 FPS, 30.3 ms of render passes).
`effects` has no multisampled scene (FMX's filters draw single-sampled quads).
## Running the benchmark

Everything that produced the tables is in the repository:

| Path | Contents |
|---|---|
| `src/Bench` | `FmxCanvasBench`: the scenes, the canvases, the measurement, the results row, the screenshots; `AaReference`, the reference renderer of the `aa` scene |
| `src/Common` | Timing, statistics, the environment record (OS, CPU, GPU and driver, monitor, compiler, FMX flags), CSV, a sampling profiler |
| `tools/run-bench.ps1` | Runs every canvas, scene, preset, mode and repeat in a process of its own, in the order described above, into `results/raw/<date>_<label>` (`runs.csv`, `log.txt`, screenshots) |
| `tools/summarize-bench.ps1` | The summary in `results` (`.md` and `.csv`): medians over the repeats, excluded runs, the screenshot comparison |
| `tools/compare-shots.ps1` | Compares every canvas's screenshot of a scene with `d2d`'s |
| `tools/run-aa.ps1`, `tools/compare-aa.ps1` | Antialiasing of the canvases against `AaReference` |
| `tools/profile-report.ps1` | Resolves the stacks sampled with `--profile` |
| `build.ps1`, `res` | Command-line build with dcc64 (Win64; `-Platform Win32`: dcc32), release, per-monitor DPI manifest; copies `sk4d.dll` for the Skia canvases |

Build and run (PowerShell, RAD Studio 37.0 at its default path, `build.ps1` has it in `$Bds`):

```powershell
.\build.ps1 -Project src\Bench\FmxCanvasBench.dpr -SearchPath src\Common,src\Canvas
.\tools\run-bench.ps1 -Label mine -Canvases d2d,fc,fcdx12 -Modes throughput -Presets medium -Repeats 3
.\tools\summarize-bench.ps1 -Raw (Get-ChildItem results\raw -Directory -Filter '*_mine' | Select-Object -Last 1).FullName
```

The published results were made by:

```powershell
.\tools\run-bench.ps1 -Label canvases -Canvases d2d,gpu,gdip,skia,skiavk,fc,fcdx12 -Modes throughput -Presets medium,heavy -Repeats 3
.\tools\run-bench.ps1 -Label raytracing -Canvases fcdx12,fcdx12rt,fcdx12ao,fcdx12soft,fcdx12refl -Scenes shadows3d,mirror3d,viewport3d -Modes throughput -Presets light,medium,heavy -Repeats 3
```

(all 26 scenes; 1092 runs in 2 h 30 min and 135 runs in 17 min; the summaries list the runs they excluded and why,
`log.txt` next to each `runs.csv` has the output of every run). `FmxCanvasBench.exe --help` lists the options
(scene, canvas, preset, mode, size, monitor, duration, screenshots, per-frame samples, simulated device loss). The
Skia canvases need `sk4d.dll` next to the executable (`build.ps1` copies it from the RAD Studio installation). Close
other programs, use the High performance power plan, and compare only runs of one session.
