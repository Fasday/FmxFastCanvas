# FastCanvas for Delphi FireMonkey

FastCanvas replaces the canvas and the 3D context of FireMonkey (FMX) on Windows with its own GPU renderer on
Direct3D 11 or Direct3D 12. Programs stay standard FMX programs: forms, controls, styles, `TBitmap`, `TTextLayout`,
`TViewport3D`, `TForm3D` and effects work as before; a few lines before `Application.Initialize` switch them over.

[Русская версия](README.ru.md)

- **Fast.** Every shape, glyph and image is one instance of an instanced draw; antialiasing is analytic in the pixel
  shader; text comes from a glyph atlas; commands are recorded on the main thread and executed on a render thread.
  5 to 60 times faster than FMX's default canvas on shapes, text and bitmaps, 2 to 4 times on real forms.
- **Its own 3D contexts** on the same device: `TViewport3D` renders straight into the form on the GPU, effects
  (shadow, glow, blur) filter bitmaps without leaving the GPU, FMX's per-draw overhead is gone.
- **Ray-traced effects** (Direct3D 12, DXR 1.1): shadows, soft shadows, ambient occlusion and reflections added to any
  FMX 3D scene, with FMX's own materials and lights; application ray passes (compute and pixel shaders over the scene).
- **Looks like FMX.** Text is antialiased in grayscale with DirectWrite's contrast and gamma, as FMX's Direct2D canvas
  draws it (optionally ClearType, aliased or as Windows draws it: `FastCanvasTextAntialias`); windows are shown through
  DirectComposition, so forms drawn transparent over Mica or Acrylic look as with the stock canvas.
- **HDR output** (Direct3D 12) on HDR displays, for forms and `TForm3D`: SDR content unchanged, 3D content above SDR
  white (`DrawIntensity`: lamps, screens, the sky brighter than white without shaders; application passes).
- **DLSS Super Resolution** (experimental; Direct3D 12, NVIDIA RTX, Win64): the 3D scene of a `TForm3D` drawn at a
  lower resolution and reconstructed by NVIDIA DLSS, the 2D panel on top at full resolution. It pays off on heavy scenes;
  on light ones DLSS costs more than it saves (about 0.9 ms per frame at 2560 x 1400 on an RTX 3090).
- **Robust.** Device loss (driver update, GPU reset) is recovered and bitmaps keep their pixels; partial repaints on
  Direct3D 12; stress runs and the Direct3D 12 debug layer stay clean; nothing leaks at shutdown.

## Speed

Frame times of the same scenes at 1920 x 1080 (ms, lower is better; AMD Radeon RX 9070 XT, Ryzen 5 7500F).
`d2d` is FMX's default canvas; the best stock canvas is the fastest of FMX's Direct2D, GPU, GDI+, Skia and Skia
Vulkan canvases in that scene.

| Scene | FMX default (`d2d`) | Best stock canvas | FastCanvas D3D11 | FastCanvas D3D12 |
|---|---:|---:|---:|---:|
| 16000 rectangles | 8.43 | 2.02 (`gpu`) | 1.54 | 1.43 |
| 250 strings, `FillText` | 7.84 | 5.19 (`gpu`) | 0.335 | 0.296 |
| 700 ellipses | 7.42 | 6.52 (`skiavk`) | 0.130 | 0.131 |
| 330 paths | 7.40 | 5.03 (`skiavk`) | 0.518 | 0.520 |
| 11500 bitmaps | 9.23 | 9.23 (`d2d`) | 1.27 | 1.27 |
| 190 styled controls | 8.56 | 4.12 (`skiavk`) | 1.93 | 1.88 |
| 112 controls with shadow, glow and blur effects | 7.70 | 5.85 (`skiavk`) | 0.678 | 0.349 |
| `TListBox`, 4000 items, scrolled | 6.43 | 5.47 (`skiavk`) | 2.68 | 2.29 |
| `TViewport3D`, 160 lit objects | 8.53 | 7.64 (`skiavk`) | 0.562 | 0.519 |

All 26 scenes, two sizes, the method and the cost of the ray-traced effects: [docs/BENCHMARKS.md](docs/BENCHMARKS.md).
The benchmark program, its scripts, the summaries and every run (environment, command line, statistics) are in the
repository (`src/Bench`, `tools`, `results`): the numbers can be checked and measured again on another machine.

## Requirements

- Delphi 13 (RAD Studio 37.0) or later, FireMonkey, **Win64** or Win32 (Win64 is faster on the CPU side).
- Windows 10 or 11.
- A GPU with Direct3D feature level 10_0 for the Direct3D 11 back end (WARP without one), 11_0 for Direct3D 12.
- DirectX Raytracing tier 1.1 for the ray-traced effects (NVIDIA RTX 20 and later, AMD RX 6000 and later, Intel Arc);
  without it they are simply not drawn.

## Use

Add three folders to the project's search path:

```
src\Canvas
third_party\delphidx12\src
third_party\pasvulkan\src
```

and install FastCanvas before `Application.Initialize`:

```pascal
program MyApp;

uses
  System.StartUpCopy,
  FMX.Forms,
  FastCanvas.Device,       // FastCanvasBackend
  FastCanvas.Canvas,       // InstallFastCanvas and the canvas settings
  FastCanvas.Context3D12,  // the Direct3D 12 3D context
  Main in 'Main.pas' {MainForm};

{$R *.res}

begin
  FastCanvasBackend := TFastCanvasBackend.D3D12;
  // Optional: text antialiasing, Grayscale (default, as FMX), ClearType, Aliased or System (as Windows).
  FastCanvasTextAntialias := TFastTextAntialias.ClearType;
  InstallFastCanvas;
  InstallFastContext3D12;
  Application.Initialize;
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;
end.
```

For Direct3D 11 leave `FastCanvasBackend` at its default and use `FastCanvas.Context3D11` /
`InstallFastContext3D11`: the 3D context must match the back end. Nothing else changes in the program.

## Example

Two RAD Studio projects in `example`, both in the group `Examples.groupproj`. All their components are on the forms in
the designer; FastCanvas is installed in the `.dpr`. The window title tells what draws it.

- [HelloFastCanvas.dproj](example/HelloFastCanvas.dproj): a form with animated 2D drawing, a button with a shadow
  effect, a lit 3D cube over a floor in a `TViewport3D` and a switch for ray-traced shadows.
- [HelloForm3D.dproj](example/HelloForm3D.dproj): a `TForm3D`, the whole window one 3D scene: animated objects on a
  reflective floor, a lamp, a swinging camera, and a panel (a `TLayer3D` with standard controls) that switches the
  ray-traced shadows, soft shadows, ambient occlusion and reflections, the floor, and HDR output: on a display in HDR
  mode the lamp shines brighter than SDR white (`DrawIntensity`), the rest looks as in SDR; on NVIDIA RTX cards, DLSS
  Super Resolution (`nvngx_dlss.dll` of the [DLSS SDK](https://github.com/NVIDIA/DLSS) in
  `third_party\nvidia_dlss\bin\win64` is copied next to the program when it is built).

Open `Examples.groupproj` (or one of the projects) in RAD Studio and run: the projects target Win64 (Win32 too) and already have
the search path (`..\src\Canvas;..\third_party\delphidx12\src;..\third_party\pasvulkan\src`). From the command line:

```
cd example
"C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\rsvars.bat"
msbuild Examples.groupproj /p:Config=Release /p:Platform=Win64
```

(the programs are in `example\Win64\Release`). Environment variables of the examples: `FC_BACKEND=11` (Direct3D 11:
no ray tracing, no HDR), `FC_PRESENT=flip` (windows without DirectComposition), `FC_TEXT=cleartype|aliased|system`
(`HelloFastCanvas`: text antialiasing), `FC_STOCK=1` (FMX's own canvas and 3D context, to compare), `FC_HDR=force`
(`HelloForm3D`: HDR output also on an SDR display), `FC_DRED=0|1`, `FC_DLSS_JITTER`, `FC_DLSS_VIEW=input|motion`
(`HelloForm3D`: DRED breadcrumbs and DLSS diagnostics).

## Main settings

Global variables, set before `Application.Initialize`; all of them in [docs/USAGE.md](docs/USAGE.md).

| Variable | Default | Meaning |
|---|---|---|
| `FastCanvasBackend` | `D3D11` | The graphics API: `D3D11` or `D3D12` |
| `FastCanvasPresentation` | `Composition` | Windows shown by DirectComposition (transparent parts of a form show what is behind it, as with FMX's Direct2D canvas) or `Flip` (a swap chain of the window, shown opaque); the same speed |
| `FastCanvasPartialFrames` | `True` | Direct3D 12: repaint only the rectangles that changed |
| `FastCanvasRenderThread` | `True` | Execute the commands on a render thread |
| `FastCanvasTextAntialias` | `Grayscale` | Text antialiasing: `Grayscale` (as FMX's Direct2D canvas), `ClearType` (subpixel, with the system's ClearType settings), `Aliased` (none), `System` (as Windows draws text: ClearType when it is on, aliased when font smoothing is off); can be changed at run time |
| `FastCanvasHdr` (`FastCanvas.Hdr`) | `Off` | HDR output of windows on HDR displays (`Auto`) |
| `FastContext3DRayTracing` (`FastCanvas.Context3D12`) | all off | Shadows, soft shadows, ambient occlusion, reflections in 3D scenes |
| `FastContext3DDlssMode` (`FastCanvas.Context3D12`) | `Off` | DLSS Super Resolution of new `TForm3D` windows (NVIDIA RTX); `DlssMode` of a context at run time |

## Repository

| Path | Contents |
|---|---|
| `src/Canvas` | FastCanvas: canvas, renderer, Direct3D 11/12 and Vulkan (in progress) back ends, 3D contexts, shaders (HLSL and compiled) |
| `third_party/delphidx12` | Direct3D 12 / DXGI headers (DelphiDX12, Apache 2.0) |
| `third_party/pasvulkan` | Vulkan header (PasVulkan, zlib) |
| `example` | `HelloFastCanvas` and `HelloForm3D`, the smallest checks (RAD Studio projects) |
| `docs` | [USAGE.md](docs/USAGE.md) (settings, ray tracing, HDR, DLSS, threads), [ARCHITECTURE.md](docs/ARCHITECTURE.md) (how it works), [BENCHMARKS.md](docs/BENCHMARKS.md) |
| `src/Bench`, `src/Common` | The benchmark `FmxCanvasBench` (scenes, canvases, measurement) and its helpers |
| `results` | Benchmark summaries (`.md`, `.csv`) and, in `raw`, every run of them |
| `tools` | `run-bench.ps1`, `summarize-bench.ps1` and helpers: running and summarizing the benchmark; `compile-shaders.ps1`: the HLSL into the Pascal includes (only after changing the shaders) |
| `build.ps1`, `res` | Command-line build of the benchmark (dcc64) |

## Limitations

- Windows only (Win64 and Win32); no printing canvas (`TPrinter`).
- ClearType (`FastCanvasTextAntialias`) only in window frames: text in bitmaps (effects, `TLayer3D`, `TForm3D`), in
  transparent forms and rotated text stays grayscale.
- Partial repaints and HDR output on Direct3D 12 only; windows with HDR output are opaque.
- Windows presenting with tearing (`AllowTearing`) take `Flip`.
- The ray-traced effects do not trace transparent objects.
- DLSS: `TForm3D` windows only, no multisampling; motion vectors only for opaque objects moved by their matrices.

## Contributors

- [Hemul GM](https://github.com/HemulGM): NVIDIA DLSS Super Resolution in the Direct3D 12 3D context (`FastCanvas.Dlss`,
  `FastCanvas.Context3D12.Dlss.inc`, `Shaders\FastDlss.hlsl`, the DLSS panel of `HelloForm3D`), first tested by him on an
  RTX 5080.

## License

MIT, see [LICENSE](LICENSE). Third-party code and formulas: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
FastCanvas contains no code of Embarcadero's FireMonkey; building it requires a Delphi license.
