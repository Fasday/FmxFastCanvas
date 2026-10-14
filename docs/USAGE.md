# Using FastCanvas

## Requirements

- Delphi 13 (RAD Studio 37.0) or later, FireMonkey, Win64 or Win32. Win64 is faster on the CPU side (Delphi's 32-bit
  code: about 1.4 to 1.9 times the frame time on scenes with many shapes, strings or controls, measured 2026-10-13);
  the GPU work is the same.
- Windows 10 or 11.
- Direct3D 11 back end: a GPU with feature level 10_0 or higher (WARP when there is none).
- Direct3D 12 back end: a GPU with feature level 11_0 or higher.
- Ray-traced effects: a GPU with DirectX Raytracing tier 1.1 (NVIDIA RTX 20 and later, AMD RX 6000 and later,
  Intel Arc). Without it they are simply not drawn.

## Adding it to a project

Add two folders to the project's search path:

```
<FastCanvas>\src\Canvas
<FastCanvas>\third_party\delphidx12\src
```

and install the canvas (and, if the program uses 3D: `TViewport3D`, `TForm3D`, or the effects of `FMX.Effects`,
which run on a 3D context) **before** `Application.Initialize`:

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
  InstallFastCanvas;
  InstallFastContext3D12;
  Application.Initialize;
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;
end.
```

For Direct3D 11 leave `FastCanvasBackend` at its default and install `FastCanvas.Context3D11.InstallFastContext3D11`
instead. The 3D context must match the back end: it runs on the canvas's device and shares its bitmaps, its command
stream and its render thread.

Without a 3D context of its own, FMX keeps its stock DX11 3D context on a device of its own; the canvas works with it
too (bitmaps then cross between the devices through the CPU, which is slower).

Nothing else changes in the program: forms, controls, styles, `TBitmap`, `TTextLayout` and `Canvas` calls are the
standard FMX ones.

## Settings

All settings are global variables, set before `Application.Initialize` unless noted.

### `FastCanvas.Device`

| Variable | Default | Meaning |
|---|---|---|
| `FastCanvasBackend` | `D3D11` | The graphics API: `TFastCanvasBackend.D3D11` or `D3D12`. Read when the device is created (the first canvas, bitmap or text layout). |

### `FastCanvas.Canvas`

| Variable | Default | Meaning |
|---|---|---|
| `FastCanvasRenderThread` | `True` | Commands recorded in a scene run on a render thread while the main thread goes on. `False`: they run on the recording thread at `EndScene`. Can be switched between frames. |
| `FastCanvasFramesInFlight` | `1` | Window frames the main thread may run ahead of the render thread. |
| `FastCanvasPartialFrames` | `True` | Direct3D 12 only: report `TCanvasStyle.SupportClipRects`, so FMX repaints only the rectangles that changed. Faster when part of a form changes (scrolled lists), about 5 % slower when hundreds of controls move every frame (FMX then works out the update rectangle of each). |
| `FastCanvasPresentation` | `Composition` | How windows show their frames. `Composition`: a composition swap chain shown by DirectComposition, with the frame's alpha: where a form is drawn transparent, what is behind it shows, such as a DWM backdrop (Mica, Acrylic) with the frame extended into the client area, as with FMX's stock Direct2D canvas. `Flip`: a swap chain of the window, which DWM shows opaque. Same speed. Windows presenting with tearing (`AllowTearing`) take `Flip`, which tearing needs. Not for transparent forms (layered windows) and `TForm3D`; HDR output stays opaque. Read at every window frame; a form switching from `Flip` to `Composition` gets a new window (DWM would keep the last flip frame under the composition). |
| `FastCanvasTextAntialias` | `Grayscale` | How text is antialiased. `Grayscale`: as FMX's stock Direct2D canvas draws it. `ClearType`: subpixel antialiasing with the system's ClearType settings (the ClearType tuner's gamma, contrast and level; RGB or BGR subpixels), blended as Direct2D blends ClearType text, also when ClearType is turned off in Windows (as Direct2D's ClearType mode). Only where ClearType can be drawn: text in the frames of windows, unrotated and uniformly scaled, on a display whose subpixels are in a row; text drawn into bitmaps (effects, `TLayer3D`, the 2D controls of a `TForm3D`, caches), into transparent forms and rotated text stays grayscale, as with DirectWrite and Direct2D. Over parts of a `Composition` window that are transparent, ClearType edges show colors. From the first ClearType glyph of a window frame on, its draws blend with a second color output of the pixel shader (dual-source blending); frames without text blend as usual. `Aliased`: no antialiasing, every pixel of a glyph covered or not (DirectWrite's aliased rendering), everywhere, also text drawn as outlines (large or rotated); color emoji stay smooth. `System`: as Windows draws text (`FastCanvasSystemTextAntialias`, read once): `Aliased` when "Smooth edges of screen fonts" is off, `ClearType` when ClearType is on, else `Grayscale`. Read at every scene. |
| `FastCanvasKeepBitmapCopies` | `True` | Bitmaps the CPU wrote (loaded images, style bitmaps) keep a copy of their pixels and survive a device loss. |
| `FastCanvasNoHeapSleep` | `True` | `InstallFastCanvas` sets `System.NeverSleepOnMMThreadContention`: the RTL memory manager otherwise sleeps 10 ms when two threads contend for a block size, which showed as 10-25 ms frame spikes. |
| `FastCanvasOptions` | `[]` | `AllowTearing`: present with `DXGI_PRESENT_ALLOW_TEARING` when the system supports it (for throughput measurements; never waits for vertical blank; windows take `Flip` then). `D2DText`: text through Direct2D instead of the glyph atlas (Direct3D 11 only, a measurement aid). `HdrLinearBlend`: HDR windows blend in linear light (a measurement aid, see "HDR output"). Read at every scene. |

Functions: `FastCanvasSync` (wait until the render thread has executed everything recorded), `FastCanvasRenderBusyMs`,
`FastCanvasDrawCalls`, `FastCanvasDeviceResets` (diagnostics), `FastCanvasSystemTextAntialias` (what `System` text
antialiasing stands for), `FastCanvasSimulateDeviceLoss` (testing: the next scene
treats the device as lost and recreates everything).

### `FastCanvas.Context3D11`

| Variable | Default | Meaning |
|---|---|---|
| `FastContext3DFragile` | `True` | Report `TContextStyle.Fragile`: FMX keeps a copy of texture pixels and recreates textures and shaders after a device loss. Read by `InstallFastContext3D11` / `InstallFastContext3D12`. |

### `FastCanvas.Context3D12`: ray-traced effects

`FastContext3DRayTracing` holds the effects every new `TFastContext3D12` starts with; each context also has them as
properties, read at every scene:

```pascal
uses FastCanvas.Context3D12;

// Every 3D context of the program:
FastContext3DRayTracing.Shadows := True;

// One viewport:
if TFastContext3D12.RayTracingSupported then
  with Viewport3D1.Context as TFastContext3D12 do
  begin
    RayShadows := True;
    RayShadowSoftness := 0.05;      // soft shadows: the lights' angular radius as its tangent
    RayAmbientOcclusion := True;
    RayReflections := True;
  end;
```

| Field (`TFastRayTracing`) / property | Default | Meaning |
|---|---|---|
| `Shadows` / `RayShadows` | `False` | Shadows of the opaque 3D objects from the scene's `TLight`s (directional, point, spot). |
| `ShadowStrength` / `RayShadowStrength` | `0.7` | 0..1: the share of a light's contribution a shadow takes away. |
| `ShadowSoftness` / `RayShadowSoftness` | `0` | 0: hard shadows (one ray per light and pixel); above 0: soft shadows, traced at half resolution and smoothed. |
| `ShadowSamples` | `8` | Rays per light and pixel for soft shadows. |
| `AmbientOcclusion` / `RayAmbientOcclusion` | `False` | Surfaces darken where other surfaces are near (corners, contacts). Half resolution, smoothed. |
| `AORadius`, `AOStrength`, `AOSamples` | `1`, `0.6`, `8` | How far occluders count (scene units), how dark full occlusion gets, rays per pixel. |
| `Reflections` / `RayReflections` | `False` | Mirror reflections in `TLightMaterial` surfaces: as strong as the specular color times `Shininess / 128`, more at grazing angles. What they show is shaded as FMX shades it (colors, textures, lights, shadows). |
| `ReflectionStrength` / `RayReflectionStrength` | `1` | 0..1: scales every reflection. |

The effects are added after FMX has drawn a scene, from its depth buffer, so they work with any scene and any of
FMX's materials; they need a depth buffer (`TViewport3D` and `TForm3D` have one). Objects drawn without depth writes
(transparent ones) and 2D layers drawn in screen space (`TLayer3D` with `Projection = Screen`) cast no shadows.
With FMX's default `TLightMaterial` (`Specular = $FF606060`, `Shininess = 30`) every light material reflects about
9 % when reflections are on; give a material a dark `Specular` to keep it matte.

What they cost is in `BENCHMARKS.md`. Off, they cost nothing.

### `FastCanvas.Context3D12`: application ray passes

A program can run its own DXR shaders over the scene: compute passes and full-screen pixel passes, written in HLSL
(shader model 6.5, inline ray queries), compiled with `dxc` into signed DXIL. They see the top-level acceleration
structure FastCanvas builds from the scene's draws, the depth buffer, and the program's own buffers, images and FMX
textures. The Quake II port's path tracer is built on them.

```pascal
uses FastCanvas.Context3D12;

// Once: the shaders and the resources.
Trace := TFastRayShader.CreateCompute(TraceDxil);              // cs_6_5
Show := TFastRayShader.CreatePixel(ShowDxil, TFastRayBlend.Premultiplied);
Lighting := TFastRayImage.Create(TFastRayFormat.RGBA16F, Width, Height);
Materials := TFastRayBuffer.Create(SizeOf(MyMaterials));
Materials.Write(0, MyMaterials, SizeOf(MyMaterials));

// In a TControl3D's Render, every frame:
Ctx := Context as TFastContext3D12;
Ctx.RayScene := True;                     // the next opaque draws enter the acceleration structure
Ctx.RayInstanceUser := 7;                 // 24 bits the shaders read for the next draws
Context.DrawTriangles(...);               // FMX draws as usual
Ctx.RayDispatch(Trace, [Materials], [Lighting], Consts, SizeOf(Consts), (W + 7) div 8, (H + 7) div 8);
Ctx.RayDraw(Show, [Lighting], Consts, SizeOf(Consts));
Ctx.RayInclude := False;                  // e.g. a weapon model: drawn, but not in the scene
Context.DrawTriangles(...);
```

| Member | Meaning |
|---|---|
| `TFastRayBuffer.Create(Size)`, `Write(Offset, Data, Size)` | A raw GPU buffer (`ByteAddressBuffer` / `RWByteAddressBuffer`); `Write` is recorded into the command stream and runs in order on the render thread (inside or outside a scene). |
| `TFastRayImage.Create(Format, Width, Height)` | A 2D image kept between frames, read and written by passes (`TFastRayFormat`: `R8`, `RGBA8`, `R16F`, `RG16F`, `RGBA16F`, `R32F`, `RG32F`, `RGBA32F`, `R32UI`, `RG32UI`, `RGBA32UI`). |
| `Generation` (buffers, images) | 1 after `Create`; grows when a device loss gave the object new (zeroed) GPU memory: write its data again. |
| `TFastRayShader.CreateCompute(Dxil)`, `CreatePixel(Dxil, Blend)` | A pass shader; `TFastRayBlend`: `Replace`, `Premultiplied`, `Multiply`, `Add` into the 3D target. `Error`: why the pipeline could not be made (its passes are skipped). |
| `RayScene` | The next opaque draws (triangles, depth test and write, float3 positions) enter the scene's acceleration structure. Set it every frame (a `TViewport3D` makes a new context when resized). |
| `RayInclude` | Default `True`; `False` keeps the next draws out (also out of the built-in effects). |
| `RayInstanceMask`, `RayInstanceUser` | The instance mask and 24 bits of the next draws (`CommittedInstanceContributionToHitGroupIndex()` in HLSL). |
| `RayGeometryKey`, `RayGeometryVersion` | 0: geometries are recognized by their contents. A key: the program's geometry, rebuilt in place when the version changes (animated meshes); released 3 scenes after its last use. |
| `RayDispatch(Shader, Srvs, Uavs, Constants, Size, GroupsX, GroupsY[, GroupsZ])` | A compute pass at this point of the scene. The first pass of a scene builds the top-level structure from the objects drawn so far (again if more were added). |
| `RayDraw(Shader, Srvs[, Uavs], Constants, Size)` | A full-screen pixel pass blended into the 3D target at this point of the scene. |
| `RayPassesAvailable`, `RayTracingSupported` | Passes need DXR tier 1.1 and a depth buffer without multisampling: `RayPassesAvailable` is `False` while the target is multisampled, so decide whether to turn multisampling off with the class function `RayTracingSupported`. |
| `RayFrameIndex` | Grows with every scene that has application passes. |
| `RayTarget` | An SRV entry of `RayDispatch` meaning the 3D target as drawn so far in the scene (what the raster and earlier passes wrote: sRGB-encoded, premultiplied, above 1 only with `Hdr`). The context's own `Texture` as an SRV entry means the same: with `Hdr` the scene draws into an internal RGBA16F target and `Texture` gets the image only afterwards. `RayDraw` reads it as white (it draws into it); not a UAV entry. |

SRV entries may be buffers, images and FMX `TTexture`s, UAV entries buffers and images, numbered in the order given;
the registers, the frame constants (`InvViewProj`, `ViewProj`, `CameraPos`, `TargetSize`, `FrameIndex`) and helper
functions are declared in `src/Canvas/Shaders/FastRayApp.hlsli`. Triangle facing in the rays is the raster's
(`RAY_FLAG_CULL_BACK_FACING_TRIANGLES` culls what the raster culls with `csBackFace`). Call everything on the thread
that draws the scene; objects passed to a pass may be freed at once (the command keeps them alive). With `RayScene`
off nothing is recorded and nothing costs. Compile the passes with dxc from the Windows SDK, for example
`dxc -T cs_6_5 -E CSMain -I src\Canvas\Shaders -Fo pass.cso pass.hlsl` (`tools/compile-shaders.ps1` shows how the
canvas embeds its own DXIL as Pascal byte arrays).

## HDR output (Direct3D 12)

On a display in HDR mode (Windows HDR on, Win+Alt+B) a window can show more than SDR white: highlights of a path tracer,
of HDR photos. FastCanvas then gives the window an FP16 swap chain in the scRGB color space (linear light, BT.709
primaries, 1.0 = 80 nits); everything SDR in it (controls, text, bitmaps, 3D without HDR) looks exactly as before, at
Windows' "SDR content brightness".

```pascal
uses FastCanvas.Hdr;   // FastCanvasHdr, TFastHdrInfo

begin
  FastCanvasBackend := TFastCanvasBackend.D3D12;
  FastCanvasHdr := TFastCanvasHdr.Auto;   // can also change at run time
  InstallFastCanvas;
  InstallFastContext3D12;
  ...
```

| Setting (`FastCanvas.Hdr`) | Default | Meaning |
|---|---|---|
| `FastCanvasHdr` | `Off` | `Off`: 8-bit swap chains, as before (costs nothing). `Auto`: a window on a display in HDR mode gets an FP16 scRGB swap chain, on an SDR display an 8-bit one; it follows the window to another monitor and Windows HDR being switched on or off. `Force`: FP16 scRGB everywhere, also on SDR displays (testing: Windows composes it to SDR, values above SDR white clip). Read at every window frame. |
| `FastCanvasHdrTestWhite` | `0` | Testing: above 0, the SDR white level (nits) of every display, also in SDR mode (with `Force`, the scaling of SDR content can be checked on an SDR display). |

HDR output needs `FastCanvasBackend = D3D12`; on Direct3D 11 the setting is ignored. Transparent forms (layered windows
take 8-bit pixels) stay SDR. A `TForm3D` drawn by the Direct3D 12 3D context (`InstallFastContext3D12`) outputs HDR the
same way: its 3D context then draws into an RGBA16F target, so values above SDR white (`DrawIntensity`, application
passes) reach the display, and SDR content (FMX's materials, `TLayer3D`) looks as before.

**HDR content from 3D.** FMX's materials never go above SDR white. Brighter content comes from draws with
`DrawIntensity` (lamps, screens, the sky: no shader needed) or from application passes, on an HDR target: the 3D
context of a `TForm3D` whose window outputs HDR, or of a `TViewport3D` with `Hdr`:

```pascal
// Around the draw of a lamp (for example in the OnRender of a TDummy that holds it, and of the lamp itself):
Ctx := Context as TFastContext3D12;
Ctx.DrawIntensity := FastCanvasHdrInfo(Form).Headroom;   // at the display's peak; 1 on SDR output
Ctx.RayInclude := False;                                 // a lamp casts no shadow
// ... the lamp draws ...
Ctx.DrawIntensity := 1;
Ctx.RayInclude := True;
```

A `TViewport3D` needs `Hdr` on its 3D context for such values:

```pascal
uses FastCanvas.Canvas, FastCanvas.Context3D12, FastCanvas.Hdr;

// In a TControl3D's Render, every frame:
Info := FastCanvasHdrInfo(Form);                 // the form that shows the viewport
Ctx := Context as TFastContext3D12;
Ctx.Hdr := Info.Output;                          // applied at the next scene
Consts.Headroom := Info.Headroom;                // tone-map to it (1 on SDR output)
Ctx.RayDraw(Show, [Lighting], Consts, SizeOf(Consts));
```

```hlsl
#include "FastRayApp.hlsli"
// Lighting in linear light, 1.0 = SDR white. Tone-map to the headroom, then encode as the target expects.
float3 c = ToneMap(lighting * Exposure, Headroom);   // the program's own curve, reaching at most Headroom
return float4(FastSrgbEncode(c), 1);
```

| Member | Meaning |
|---|---|
| `FastCanvasHdrInfo(Form): TFastHdrInfo` (`FastCanvas.Canvas`) | Whether the form's window outputs HDR (`Output`, from its next frame on), and its display's levels: `DisplayHdr` (Windows HDR on), `SdrWhiteNits` (what SDR white is shown as: Windows' SDR content brightness in HDR mode, 80 in SDR mode), `SdrWhiteSettingNits` (that setting, read in either mode), `PeakNits`, `MaxFullFrameNits`, `MinNits` (as the display reports them, `IDXGIOutput6.GetDesc1`). `Headroom`: `PeakNits / SdrWhiteNits` with HDR output on an HDR display, else 1. `WhiteScale`: the scRGB value of SDR white. |
| `FastHdrDisplayOf(Wnd)`, `FastHdrRefresh` (`FastCanvas.Hdr`) | The same for any window handle (`Output` is False); `FastHdrRefresh` makes the next call read the displays again (FastCanvas notices changes itself, through `IDXGIFactory1.IsCurrent`; the SDR white level of displays in HDR mode is read again every second). |
| `TFastContext3D12.Hdr` | The context of a `TViewport3D` draws into an RGBA16F target: FMX's materials draw there as on an 8-bit one, application passes may write more than 1. The image goes into the viewport's bitmap as its HDR content: an HDR window shows it unclipped, an SDR window clipped at 1, `TBitmap.Map` reads it clipped. Ignored by `TForm3D`, whose target is RGBA16F exactly while its window outputs HDR. |
| `TFastContext3D12.DrawIntensity` | Default 1: the colors of the next draws times this, in linear light (exact for white, close for other colors: the factor applies to the sRGB-encoded color, through the blend factor). Above 1 on an HDR target: brighter than SDR white; on an 8-bit target they clip at 1. |
| `FastSrgbEncode`, `FastSrgbDecode` (`FastRayApp.hlsli`) | The encoding of 3D targets (the sRGB curve, continued above 1). |
| `FastCanvasCaptureWindow(Form, Capture)` | Diagnostics: the frame the window presented last, as floats (scRGB for HDR output, sRGB values for SDR). |
| `TFastCanvasOption.HdrLinearBlend` | Measurement aid: HDR windows draw and blend in linear light (see below). |

**How to tone-map.** Keep the scene's lighting in linear light with 1.0 = SDR white (what the program would show as white
in SDR). Apply exposure, then a curve that maps the scene's range to `[0, Headroom]` (on SDR output `Headroom` is 1: the
program's SDR curve; on a 455-nit display with SDR white at 240 nits it is about 1.9; with SDR white at 80 nits about
5.7). A curve that is linear up to about 0.6–0.8 of SDR white keeps midtones as in SDR and spends the headroom on
highlights. `MaxFullFrameNits / SdrWhiteNits` is a safe ceiling for large bright areas. Then `FastSrgbEncode` and write.
Values above `Headroom` reach the display and are clipped or tone-mapped by it.

**How SDR content stays the same.** The window's frame is drawn as on an 8-bit target (sRGB-encoded colors, blended and
antialiased in those values), only into an RGBA16F surface, where HDR content can exceed 1. At `Present` one pass
decodes it with the sRGB curve and scales it by `SdrWhiteNits / 80` into the swap chain buffer, as Windows composes the
8-bit windows of other programs. Measured on the benchmark scenes (forced HDR on an SDR display, screenshots after the
compositor): at most 0.05 % of pixels differ from SDR by more than 3 levels of 255, the rest by rounding (blending is no
longer rounded to 8 bits between draws). Blending in linear light instead (`HdrLinearBlend`) changes translucency, text
weight and antialiasing: up to 43 % of the pixels of a scene differ by more than 3 levels, up to 30 % by more than 23.

**Cost.** Off or on an SDR display with `Auto`: nothing measurable (a check of the window's monitor per frame,
0.05 µs). HDR output: the frame in an RGBA16F surface (twice the bytes of 8-bit) and one full-window pass per frame;
measured at 1920x1080, 4–13 µs per frame (3–7 % on scenes running at 6000–7000 FPS, nothing measurable at a few hundred).

## DLSS Super Resolution (Direct3D 12, NVIDIA RTX)

Experimental. The 3D scene of a `TForm3D` window is drawn at a lower resolution with a subpixel jitter and NVIDIA DLSS
reconstructs it at the window's resolution; the screen-projected 2D controls (a `TLayer3D` panel) are drawn after it,
at full resolution.

- Needs an NVIDIA RTX graphics card, a driver with NGX, a Win64 program and `nvngx_dlss.dll` of the
  [DLSS SDK](https://github.com/NVIDIA/DLSS) (`lib/Windows_x86_64/rel`) next to the EXE. The DLL is not part of
  FastCanvas: NVIDIA's RTX SDK license allows distributing it with an application, for systems with NVIDIA cards.
- `TFastContext3D12.DlssMode` (`Off`, `Quality`, `Balanced`, `Performance`, `UltraPerformance`, `DLAA`), or
  `FastContext3DDlssMode` for new contexts: a change takes effect at the next scene (new buffers).
- `DlssAvailable`: DLSS can be used; `DlssStatus`: the mode and sizes, or why it cannot be used; `DlssFrames`:
  evaluations so far. Asking `DlssAvailable` or switching DLSS on starts NGX for the device (once per process and
  device; nothing happens with DLSS off).
- `FastDlssProjectId` (`FastCanvas.Dlss`): the NGX project ID of the application, a GUID of its own. `FastDlssDataPath`:
  where NGX writes its logs (default `%LOCALAPPDATA%\FastCanvas\NGX`).
- `FastCanvasD3D12Breadcrumbs` (`FastCanvas.Device`): DRED breadcrumbs, `Off` by default; `Nvidia` turns them on for
  NVIDIA cards only (a ray tracing structure build hung on an RTX 5080 with driver 610.88 without them). They cost GPU
  time.

Limitations:

- `TForm3D` windows only, not `TViewport3D` or other texture contexts; no multisampling with DLSS.
- DLSS reconstructs what is drawn before the first screen-projected (2D) object of the scene; 3D drawn after it is
  drawn at the window's resolution without a depth buffer. FMX draws the children of a form sorted by material
  (`TControl3D.GetMaterialForSorting`), so a screen-projected layer may come before 3D objects: `HelloForm3D` gives its
  panel a sorting material that puts it last.
- Motion vectors come from FMX's `MVPMatrix` of each opaque object (depth test and write); vertices animated by the
  CPU move without them, transparent objects have none. Every other pixel (the background, objects without depth
  write) gets the camera's motion, reprojected from the depth buffer (the background as seen at infinity), as DLSS
  needs vectors for all pixels.
- Ray-traced shadows, ambient occlusion and reflections are part of the colors DLSS gets, and their pixels move with
  the surfaces they fall on: a shadow or a reflection that moves over a still floor has the floor's vectors, and DLSS
  may leave a short trail behind it. NVIDIA's mask for such pixels (`BiasCurrentColor`) is not to be used with
  NVIDIA's current models.
- Textures in the scene are sampled with a mip-map LOD bias of log2(render width / output width) - 1, as NVIDIA's
  guide recommends (textures as sharp as at the output size).
- Starting NGX for a device takes a moment: on an RTX 3090 the first DLSS frame came about 1.5 s after the window, the
  first after a device loss about 2 s after it (the session of the new device is made again).
- Settings, read when the feature is made: `FastDlssPreset` (NVIDIA's model of every mode: `Default` or `J`, `K`, `L`,
  `M`), `FastDlssAutoExposure` (default True; False gives DLSS a fixed exposure of 1).
- Diagnostics: `FastDlssJitterTest` turns the subpixel jitter off or negates what DLSS is told; `FastDlssView`
  shows the scene DLSS gets (`Input`) or its motion vectors (`Motion`: grey where still) instead of the result;
  `FastDlssCameraMotion := False` leaves the pixels without an object's vector still. `FastDlssEmulate` runs the
  whole DLSS phase on any Direct3D 12 card with a simple temporal shader instead of NGX (`Temporal`: as temporal
  antialiasing; `Accumulate`: unclamped, so that wrong motion vectors leave trails): with `FastDlssView` it shows the
  motion vectors on cards without DLSS. `HelloForm3D` takes these switches from environment variables (see
  `example/HelloForm3D.dpr`).

## Threads

- Draw with a canvas only between `BeginScene` and `EndScene`, as FMX requires. `TBitmap.Canvas` can be used on any
  thread; FMX's global canvas lock (`TCanvas.Lock`, held from `BeginScene` to `EndScene`) serializes the recording.
- `TBitmap.Map` waits until the render thread has executed everything that uses the bitmap.
- A device loss (driver update, TDR, adapter change) is detected on the render thread and handled at the next scene:
  everything is recreated on a new device, bitmaps the CPU wrote come back, forms repaint. FMX's
  `TContextLostMessage` and `TContextResetMessage` are sent as for the stock canvases.

## Debugging

- `FASTCANVAS_D3D12_DEBUG=<file>` (environment variable): the Direct3D 12 back end enables the debug layer and writes
  its messages to the file (the layer's exceptions are caught and logged, so a program without a debugger keeps
  running).
- `FastCanvasSimulateDeviceLoss`: the next scene treats the device as lost and recreates everything, as after a driver
  update or a GPU reset.
- `FastCanvasCaptureWindow`: the frame a window presented last, as floats (checks of HDR output).
- `ReportMemoryLeaksOnShutdown := True` in the program: FastCanvas frees everything it made at shutdown.

## Limitations

- Windows only (Win64 and Win32).
- Printing (`TPrinter` canvases) is not supported.
- Text is grayscale antialiased by default (as FMX's stock Direct2D canvas draws it); ClearType
  (`FastCanvasTextAntialias`) only in the frames of windows, not in bitmaps, transparent forms and `TForm3D`. No
  GDI-style text rendering (glyphs fitted to the pixel grid).
- Ray-traced effects need a depth buffer and DXR tier 1.1; they do not trace transparent objects.
- Partial frames are Direct3D 12 only.
- HDR output is Direct3D 12 only, and not for transparent forms.
