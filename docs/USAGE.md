# Using FastCanvas

## Requirements

- Delphi 13 (RAD Studio 37.0) or later, FireMonkey, Win64 or Win32. Win64 is faster on the CPU side (Delphi's 32-bit
  code: about 1.4 to 1.9 times the frame time on scenes with many shapes, strings or controls, measured 2026-10-13);
  the GPU work is the same.
- Windows 10 or 11; Android 7.0 (API 24) or later on arm64 (Vulkan back end only, see "Android and Linux"); Linux
  x64 under X11 (Vulkan back end; it compiles, it has not run yet).
- Direct3D 11 back end: a GPU with feature level 10_0 or higher (WARP when there is none).
- Direct3D 12 back end: a GPU with feature level 11_0 or higher.
- Vulkan back end: Vulkan 1.1 with `VK_KHR_swapchain` and a queue that draws and presents. Dynamic rendering,
  synchronization2 and timeline semaphores are used where the device has them (Vulkan 1.3 core, or
  `VK_KHR_dynamic_rendering`, `VK_KHR_synchronization2`, `VK_KHR_timeline_semaphore`), else render passes, Vulkan 1.0
  barriers and fences stand in for them (many 2021-2024 phones: Mali, older Adreno and PowerVR). What it does not
  have is listed under "Vulkan back end". Without a device that qualifies, `TFastDevice.Ensure` raises `EFastDevice`
  with what each device lacks.
- Ray-traced effects: a GPU with DirectX Raytracing tier 1.1 (NVIDIA RTX 20 and later, AMD RX 6000 and later,
  Intel Arc); on Vulkan, a Vulkan 1.3 device with ray queries (`VK_KHR_ray_query` with acceleration structures, buffer
  device addresses and descriptor indexing; AMD's 32-bit driver has none). Without it they are simply not drawn.

## Adding it to a project

Add three folders to the project's search path:

```
<FastCanvas>\src\Canvas
<FastCanvas>\third_party\delphidx12\src
<FastCanvas>\third_party\pasvulkan\src
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
instead; for Vulkan set `TFastCanvasBackend.Vulkan` and install `FastCanvas.Context3DVk.InstallFastContext3DVk`. The
3D context must match the back end: it runs on the canvas's device and shares its bitmaps, its command stream and its
render thread.

Without a 3D context of its own, FMX keeps its stock DX11 3D context on a device of its own; the canvas works with it
too (bitmaps then cross between the devices through the CPU, which is slower).

Nothing else changes in the program: forms, controls, styles, `TBitmap`, `TTextLayout` and `Canvas` calls are the
standard FMX ones.

## Settings

All settings are global variables, set before `Application.Initialize` unless noted.

### `FastCanvas.Device`

| Variable | Default | Meaning |
|---|---|---|
| `FastCanvasBackend` | `D3D11` | The graphics API: `TFastCanvasBackend.D3D11`, `D3D12` or `Vulkan`. Read when the device is created (the first canvas, bitmap or text layout). On Vulkan see "Vulkan back end". |

### `FastCanvas.Canvas`

| Variable | Default | Meaning |
|---|---|---|
| `FastCanvasRenderThread` | `True` | Commands recorded in a scene run on a render thread while the main thread goes on. `False`: they run on the recording thread at `EndScene`. Can be switched between frames. |
| `FastCanvasFramesInFlight` | `1` | Window frames the main thread may run ahead of the render thread. |
| `FastCanvasPartialFrames` | `True` | Direct3D 12 and Vulkan: report `TCanvasStyle.SupportClipRects`, so FMX repaints only the rectangles that changed. Faster when part of a form changes (scrolled lists), about 5 % slower when hundreds of controls move every frame (FMX then works out the update rectangle of each). |
| `FastCanvasPresentation` | `Composition` | How windows show their frames. `Composition`: a composition swap chain shown by DirectComposition, with the frame's alpha: where a form is drawn transparent, what is behind it shows, such as a DWM backdrop (Mica, Acrylic) with the frame extended into the client area, as with FMX's stock Direct2D canvas. `Flip`: a swap chain of the window, which DWM shows opaque. Same speed. Windows presenting with tearing (`AllowTearing`) take `Flip`, which tearing needs. Not for transparent forms (layered windows) and `TForm3D`; HDR output stays opaque. Read at every window frame; a form switching from `Flip` to `Composition` gets a new window (DWM would keep the last flip frame under the composition). |
| `FastCanvasTextAntialias` | `Grayscale` | How text is antialiased. `Grayscale`: as FMX's stock Direct2D canvas draws it. `ClearType`: subpixel antialiasing with the system's ClearType settings (the ClearType tuner's gamma, contrast and level; RGB or BGR subpixels), blended as Direct2D blends ClearType text, also when ClearType is turned off in Windows (as Direct2D's ClearType mode). Only where ClearType can be drawn: text in the frames of windows, unrotated and uniformly scaled, on a display whose subpixels are in a row; text drawn into bitmaps (effects, `TLayer3D`, the 2D controls of a `TForm3D`, caches), into transparent forms and rotated text stays grayscale, as with DirectWrite and Direct2D. Over parts of a `Composition` window that are transparent, ClearType edges show colors. From the first ClearType glyph of a window frame on, its draws blend with a second color output of the pixel shader (dual-source blending); frames without text blend as usual. `Aliased`: no antialiasing, every pixel of a glyph covered or not (DirectWrite's aliased rendering), everywhere, also text drawn as outlines (large or rotated); color emoji stay smooth. `System`: as Windows draws text (`FastCanvasSystemTextAntialias`, read once): `Aliased` when "Smooth edges of screen fonts" is off, `ClearType` when ClearType is on, else `Grayscale`. Read at every scene. |
| `FastCanvasKeepBitmapCopies` | `True` | Bitmaps the CPU wrote (loaded images, style bitmaps) keep a copy of their pixels and survive a device loss. |
| `FastCanvasNoHeapSleep` | `True` | `InstallFastCanvas` sets `System.NeverSleepOnMMThreadContention`: the RTL memory manager otherwise sleeps 10 ms when two threads contend for a block size, which showed as 10-25 ms frame spikes. |
| `FastCanvasOptions` | `[]` | `AllowTearing`: present with `DXGI_PRESENT_ALLOW_TEARING` when the system supports it (for throughput measurements; never waits for vertical blank; windows take `Flip` then). `D2DText`: text through Direct2D instead of the glyph atlas (Direct3D 11 only, a measurement aid). `HdrLinearBlend`: HDR windows blend in linear light (a measurement aid, see "HDR output"). Read at every scene. |

### `FastCanvas.Geometry`, `FastCanvas.Text`: the CPU engines

| Variable | Default | Meaning |
|---|---|---|
| `FastCanvasGeometryEngine` | `Native` (Windows), `Skia` | Paths, their fill edges and stroke outlines: `Native` is Direct2D, `Skia` is Skia (`FastCanvas.GeometrySkia`; the only one on Android and Linux). Read when the first canvas is made. |
| `FastCanvasTextEngine` | `Native` (Windows), `Skia` | Text layout and glyphs: `Native` is DirectWrite, `Skia` is Skia's paragraphs (`FastCanvas.TextSkia`: HarfBuzz shaping, the platform's font fallback; the only one on Android and Linux). Read by `InstallFastCanvas`. |

On Windows the Skia engines are linked only when the program uses their units (`FastCanvas.GeometrySkia`,
`FastCanvas.TextSkia`), and then need `sk4d.dll` next to the executable. Skia's text differs from DirectWrite's by
a fraction of a pixel in line height (paragraphs drift by a pixel every few lines), its glyphs are unhinted outlines
(DirectWrite's grayscale is about as soft), and FMX fonts added through `TFontManager` are not known to it.

Functions: `FastCanvasSync` (wait until the render thread has executed everything recorded), `FastCanvasRenderBusyMs`,
`FastCanvasDrawCalls`, `FastCanvasDeviceResets` (diagnostics), `FastCanvasSystemTextAntialias` (what `System` text
antialiasing stands for), `FastCanvasSimulateDeviceLoss` (testing: the next scene
treats the device as lost and recreates everything).

### `FastCanvas.Context3D`

| Variable | Default | Meaning |
|---|---|---|
| `FastContext3DFragile` | `True` | Report `TContextStyle.Fragile`: FMX keeps a copy of texture pixels and recreates textures and shaders after a device loss. Read by `InstallFastContext3D11` / `InstallFastContext3D12` / `InstallFastContext3DVk`. Declared in `FastCanvas.Context3D` (every platform); `FastCanvas.Context3D11` keeps an alias. |

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

On Vulkan the Vulkan 3D context (`TFastContext3DVk`) draws the same effects with the same shaders, compiled to SPIR-V,
and the images match those of Direct3D 12. `TFastRayTracing` and `FastContext3DRayTracing` are declared in
`FastCanvas.Context3D` (`FastCanvas.Context3D12` keeps aliases); a Vulkan context has them as its `RayTracing`
property, and `TFastContext3DVk.RayTracingSupported` says whether the device has ray queries.

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
- Settings, read when the feature is made: `FastDlssPreset` (NVIDIA's model: `Default` = model M for Quality and
  Balanced, NVIDIA's choice for the other modes — NVIDIA's default K left a speckled halo around a bright object moving
  over a dark background on an RTX 3090, M did not; `Nvidia` = NVIDIA's choice everywhere; or `J`, `K`, `L`, `M` for
  every mode), `FastDlssAutoExposure` (default True; False gives DLSS a fixed exposure of 1),
  `FastDlssConservativeMotion` (default True: the motion pass rasterizes conservatively where the device can, so thin
  features such as a cone's tip at the render size of Performance and Ultra Performance get their vectors, as NVIDIA's
  guide recommends).
- Diagnostics: `FastDlssJitterTest` turns the subpixel jitter off or negates what DLSS is told; `FastDlssView`
  shows the scene DLSS gets (`Input`) or its motion vectors (`Motion`: grey where still) instead of the result;
  `FastDlssCameraMotion := False` leaves the pixels without an object's vector still. `FastDlssEmulate` runs the
  whole DLSS phase on any Direct3D 12 card with a simple temporal shader instead of NGX (`Temporal`: as temporal
  antialiasing; `Accumulate`: unclamped, so that wrong motion vectors leave trails): with `FastDlssView` it shows the
  motion vectors on cards without DLSS. `HelloForm3D` takes these switches from environment variables (see
  `example/HelloForm3D.dpr`).

## Raw draws (3D contexts)

FMX's `TContext3D` has one blend mode, `LESS_EQUAL` depth, single-sided stencil, all-or-nothing color writes and
`DrawPrimitives` with FMX's vertex formats. Programs that bring their own renderer (a game engine's back end) draw
through `TFastContext3D` (`FastCanvas.Context3D`) instead, on the context of a `TForm3D`, a `TViewport3D` or a texture
target (`TContextManager.CreateFromTexture`), between its `BeginScene` and `EndScene`:

- `DrawRaw(const TFastRawDraw)`: one indexed draw (triangles, lines or points) with
  - the program's shaders: `TContextShader`s with `DX11` / `DX10` bytecode (shader model 4 or 5, e.g. from `fxc`),
    their constants in `cbuffer` register `b0` (`VSConstants` / `PSConstants`, `VSConstantSize` / `PSConstantSize`
    bytes, multiples of 16), textures at `t0`–`t7` with their samplers at `s0`–`s7`;
  - its vertex layout (`TFastVertexLayout.Create` of `TFastVertexElement`s: semantic, index, `DXGI_FORMAT`, byte
    offset) and `Stride`;
  - geometry from memory (`Vertices` / `VertexCount`, `Indices`: copied when recorded) or from `TFastBuffer`s
    (`VertexBuffer` / `VertexOffset`, `IndexBuffer` / `IndexOffset` in bytes, `BaseVertex`), 16- or 32-bit indices;
  - `TFastTexture`s with `TFastSampler`s (D3D filter value, address modes, border color, anisotropy, LOD range);
  - `TFastRawState`: blend factors and ops for color and alpha, write mask per channel, depth enable / write / compare
    function, two-sided stencil (separate front and back operations and functions, read / write masks) with
    `StencilRef`, cull mode, front face winding, wireframe, depth bias and slope-scaled depth bias. Start from
    `TFastRawState.Default`;
  - `Scissor` and `Viewport` in pixels of the target (top-left origin; empty: none / the whole target).
- `CopyToTexture`: what the scene has drawn so far (a rectangle of the color target, or the whole depth buffer into a
  `Depth24` texture) into a `TFastTexture`, recorded in order with the draws (render-to-texture effects that sample
  the screen: `_currentRender`, `_currentDepth`).
- `ReadTarget`: waits for the recorded work and reads a rectangle of the target's color (BGRA), depth (`Single`) or
  stencil (bytes), rows from the top (tests, screenshots).
- `TFastTexture`: 2D or cube, `RGBA8`, `BGRA8`, `R8`, `RG8`, `R16`, `RG16`, `RGBA16F`, `RGBA32F`, `BC1`–`BC5` or
  `Depth24`, with explicit mip levels; `Upload` of a rectangle of a mip level of a face (compressed formats in 4 x 4
  blocks). `TFastBuffer`: a vertex or index buffer; `Write` of a byte range. Uploads and writes are recorded in
  program order with the draws: a write after a draw does not change what that draw reads.

Raw draws need an installed context class (`InstallFastContext3D11` / `InstallFastContext3D12`); textures and
buffers belong to its device. FMX's own state (`SetContextState`, the material of the next `DrawPrimitives`) is not
changed by them, so FMX objects and raw draws can be mixed in one scene. After a device loss textures and buffers get
new, zeroed GPU memory and a higher `Generation`: upload them again. Pipeline states are made once per combination of
shaders, layout, state, topology and target format and kept.

A program without FMX forms (a console test) shuts FastCanvas down as FMX's `FinalizeForms` does:
`TContextManager.UnInitialize` and `TCanvasManager.UnInitialize` after its last context is freed.

## Vulkan back end

With `FastCanvasBackend := TFastCanvasBackend.Vulkan` and `InstallFastContext3DVk` everything is drawn with Vulkan
(1.1 and up, see "Requirements"; headers from `third_party\pasvulkan`): the canvas,
text (ClearType included), bitmaps, transparent forms, the effects, `TViewport3D`, `TForm3D` and the ray-traced
effects, with device loss handled as on Direct3D. The benchmark's scenes draw as on Direct3D 12 (identical screenshots
but for a few pixels of strokes), at about its speed (`BENCHMARKS.md`). It is the back end of Android and Linux too
(see "Android and Linux").

- **Windows** show their frames through a swap chain of the window itself (opaque, as `Flip`; `FastCanvasPresentation`
  is ignored), each from a thread of its own: the render thread copies a finished frame and goes on, the window's
  thread acquires an image, copies the newest frame into it and presents. The present mode: `IMMEDIATE` with
  `AllowTearing`, else the first the driver has of `MAILBOX`, `FIFO_LATEST_READY` and `FIFO`. The GPU is at most
  three frames behind. Frames are drawn into a surface of the window that keeps them, so partial frames
  (`FastCanvasPartialFrames`) work as on Direct3D 12.
- **The 3D context** runs FMX's own shaders (materials, filters, effects, transitions) as SPIR-V made from the GLSL
  sources FMX ships, with the constants laid out as for Direct3D: `tools\compile-fmx-shaders-vk.ps1` writes
  `FastCanvas.VkFmxShaders.inc` (run it again, with the Vulkan SDK, when a Delphi update changes FMX's shaders). A
  shader FMX does not ship (an application's `TContextShader` or material) raises `EContext3DException`. The descriptors
  of a draw are pushed (`VK_KHR_push_descriptor`), or written into a set of the canvas's descriptor pools where the
  device lacks that extension (`FASTCANVAS_VK_NOPUSH=1` takes that path on any GPU). It runs on Windows only: FMX
  ships the Direct3D sources of its shaders, whose variables give the context the constant layout and the key of the
  SPIR-V, there only (`TFastContext3DVk.Valid` is `False` elsewhere).
- **Memory**: textures and buffers share blocks of device memory (32 MB device-local, 8 MB host-visible; larger
  resources get memory of their own), so thousands of bitmaps take a few memory objects. `FASTCANVAS_VK_STATS=<file>`
  appends the peak numbers of memory objects and allocations when the device goes.
- **Devices below Vulkan 1.3** (most phones): dynamic rendering, synchronization2 and timeline semaphores come from
  their extensions where they have them; push descriptors and `FIFO_LATEST_READY` likewise; no ray-traced effects
  (their shaders are built for Vulkan 1.2 with buffer device addresses). `FASTCANVAS_VK_API=1.1` takes any GPU this
  way.
- **The Vulkan 1.1 core path** (devices without some or all of the three features; the Mali-G57 of a TECNO KL7,
  Vulkan 1.1.177, has only timeline semaphores): draws run in render passes (made once per set of attachments and
  operations, framebuffers per target view), barriers are `vkCmdPipelineBarrier`, submissions `vkQueueSubmit`, and
  without timeline semaphores every submission signals a fence. It draws the same pixels: on a desktop GPU with
  `FASTCANVAS_VK_LEGACY=1` and `FASTCANVAS_VK_NOTIMELINE=1` the benchmark's scenes, the 3D context and its ray-traced
  effects match the default path pixel for pixel, with no message of the validation layer. What such a device lacks
  otherwise: without `VK_KHR_push_descriptor` the 3D context binds descriptor sets (no visible difference), without
  dual-source blending (`dualSrcBlend`, which that Mali lacks) ClearType text is drawn grayscale.

Not on Vulkan: HDR output (`FastCanvasHdr`, `Hdr`, `DrawIntensity`), DirectComposition, DLSS, the application ray
passes (`RayScene`, `RayDispatch`, `RayDraw` and their types are Direct3D 12 only), application shaders in the 3D
context, `D2DText`. Win32 programs run on Vulkan too, but AMD's 32-bit driver has no ray queries: their 3D scenes are
drawn without the ray-traced effects.

## Android and Linux

There the canvas runs on its Vulkan back end, with Skia's geometry and text engines (Skia is part of Delphi's RTL:
linked into the library on Android; on Linux `libsk4d.so` of `Redist\linux64` goes next to the program). The Vulkan 3D
context builds there but does not run yet: FMX's shaders have no Direct3D sources off Windows, and the context takes
their variables (`TFastContext3DVk.Valid` is `False`, `InstallFastContext3DVk` does nothing). The search path needs
`src\Canvas` and `third_party\pasvulkan\src` only.

```pascal
begin
  FastCanvasBackend := TFastCanvasBackend.Vulkan; // the only back end there
  try
    TFastDevice.Ensure;   // EFastDevice when there is no Vulkan device the canvas can use, with the reason
    InstallFastCanvas;
  except
    // No install: FMX's own canvas (TCanvasGpu on Android) draws the forms.
  end;
  Application.Initialize;
  ...
```

`src\Probe\PortProbe.dpr` does this, shows the device, its Vulkan version and limits, and remembers a start with
FastCanvas that crashed or raised (the next start takes FMX's canvas and says why); on Windows it also draws a cube
in a `TViewport3D` with the Vulkan 3D context. With FastCanvas off Windows, FMX's own 3D context would draw 3D
controls; that has not been tried.

Android:

- The window is the `ANativeWindow` of the form's surface. FMX makes the form's canvas again when the surface is made
  or changed; while the app is in the background there is no surface and nothing is drawn (a surface lost meanwhile
  ends the window's presenting thread, and the frame that finds it lost is not presented). The swap chain has the
  frame's size and is not rotated by the canvas (the compositor turns it), and frames are copied into it (blitted into
  the `R8G8B8A8` images phones offer) by the window's own thread, as on Windows.
- `InstallFastCanvas` enables FMX's software canvases (`TCanvasManager.EnableSoftwareCanvas`), which makes FMX take
  `TFastCanvas` rather than `TCanvasGpu` (it prefers canvases that need a GPU surface otherwise; FMX.Skia does the
  same).
- Building the APK from the command line: `tools\make-deployproj.ps1 -Project <dproj>` writes the `.deployproj` the
  IDE would write, `tools\build-android.ps1 -Project <dproj>` runs msbuild (Build, Deploy) into
  `<project dir>\Android64\Release\<name>\bin\<name>.apk`, signed with a debug key of its own
  (`dcu\android-debug.keystore`). The `.dproj` needs the Android64 platform with `BT_BuildType` `Debug` (an installable
  development APK), `minSdkVersion` 24 or more, and the `EnabledSysJars` of a project the IDE made
  (`src\Probe\PortProbe.dproj` has them). Installing: `adb install -r <apk>` with USB debugging on.
- Without a phone: an Android 14 x86_64 emulator image (`system-images;android-34;google_apis;x86_64`) runs the
  arm64 library through its ARM translation, with the host GPU's Vulkan (`emulator -avd <name> -gpu host`); PortProbe
  was tested so.
- On a phone (2026-10-14): a TECNO KL7 (Helio G99, Mali-G57 MC2, driver r32p1, Vulkan 1.1.177, Android 14, 1080x2436
  at 120 Hz) runs PortProbe on the Vulkan 1.1 core path (render passes, Vulkan 1.0 barriers, timeline semaphores; with
  fences too), through cold starts, the app in the background and back, and the screen off and on. It shows 55-59 FPS
  where FMX's `TCanvasGpu` shows 97: it is GPU-bound, the canvas's render passes take about 16 ms of GPU time per
  frame (an almost empty frame about 10 ms: the instanced shader is heavy for a two-core Mali), the copy into the
  presented surface 0.85 ms, the blit into the swap chain 0.76 ms (GPU timestamps); the main thread records the scene
  in 0.8 ms. PortProbe reads `options.txt` in the app's files directory (`adb shell run-as <package>`): options as on
  its command line and `NAME=VALUE` environment variables such as `FASTCANVAS_VK_NOTIMELINE=1`; its status line (also
  in the log, `adb logcat`) gives the frame rate, the recording and render-thread times per frame.

Linux (compiles with `tools\check-port.ps1`, has not run yet):

- X11 only: FMX's Linux platform (FMUX) runs GTK 3; the canvas makes the form's drawing area a native window and
  presents to its X11 window (`VK_KHR_xlib_surface`, the XID and the display through GDK, loaded at run time). In a
  Wayland session the program has to run through XWayland (`GDK_BACKEND=x11`); Wayland surfaces are not supported.
- Running it needs `libvulkan.so.1` and a Vulkan 1.1 driver (Mesa: radv, anv, nvk; lavapipe
  on the CPU), GTK 3, and `libsk4d.so` next to the program.
- Building a Linux program needs the Linux SDK in the IDE (Tools > Options > Deployment > SDK Manager, a Linux 64-bit
  profile pulled from a Linux machine running PAServer: `LinuxPAServer37.0.tar.gz`, a download of Embarcadero's, not
  part of this installation), and PAServer there to deploy and run. WSL2 with WSLg can be that machine (X11 through
  XWayland; Vulkan through Mesa's `dzn` driver over Direct3D 12, or lavapipe).

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
- `FASTCANVAS_VK_DEBUG=<file>` (environment variable): the Vulkan back end enables `VK_LAYER_KHRONOS_validation` (of
  the Vulkan SDK) and appends its warnings and errors to the file. `VK_KHRONOS_VALIDATION_VALIDATE_SYNC=1` adds the
  layer's synchronization validation. `FASTCANVAS_VK_STATS=<file>`: the peak numbers of Vulkan memory objects and
  allocations, appended when the device goes.
- `FASTCANVAS_VK_API=1.1` or `1.2` (environment variable): the Vulkan instance of that version, so any device is used
  the way of devices below Vulkan 1.3 (a test of that path on a desktop GPU; no ray-traced effects then); `1.0`: no
  device qualifies (a test of the fallback). `FASTCANVAS_VK_NOPUSH=1`: `VK_KHR_push_descriptor` stays off, so the
  Vulkan 3D context binds descriptor sets (the path of devices without it). `FASTCANVAS_VK_LEGACY=1`: no dynamic
  rendering, synchronization2 or push descriptors on any device, `FASTCANVAS_VK_NOTIMELINE=1`: no timeline semaphores
  (fences): the Vulkan 1.1 core path of phones on a desktop GPU, ray-traced effects included; with
  `FASTCANVAS_VK_API=1.1` as well it is the path of such a phone. `FASTCANVAS_VK_STATS` also notes the features in
  use and the number of render passes.
- `FastCanvasSimulateDeviceLoss`: the next scene treats the device as lost and recreates everything, as after a driver
  update or a GPU reset.
- `FastCanvasCaptureWindow`: the frame a window presented last, as floats (checks of HDR output).
- `ReportMemoryLeaksOnShutdown := True` in the program: FastCanvas frees everything it made at shutdown.
- The benchmark runs on Vulkan with `--canvas=fcvk` (also `fcvkrt`, `fcvkao`, `fcvksoft`, `fcvkrefl` with ray-traced
  effects, `fcvksep` with FMX's stock 3D context, `fcvkskia` with the Skia geometry and text engines of Android and
  Linux).

## Limitations

- Windows (Win64, Win32) and Android (arm64); Linux x64 compiles but has not run. On Android and Linux: the canvas on
  Vulkan only, no 3D context of its own (see "Android and Linux"), no ClearType, no HDR output, no Direct2D
  fallbacks (`D2DText`).
- Printing (`TPrinter` canvases) is not supported.
- Text is grayscale antialiased by default (as FMX's stock Direct2D canvas draws it); ClearType
  (`FastCanvasTextAntialias`) only in the frames of windows, not in bitmaps, transparent forms and `TForm3D`. No
  GDI-style text rendering (glyphs fitted to the pixel grid).
- Ray-traced effects need a depth buffer and DXR tier 1.1 or Vulkan ray queries; they do not trace transparent
  objects.
- Partial frames are Direct3D 12 and Vulkan only.
- HDR output is Direct3D 12 only, and not for transparent forms.
- On Vulkan the 3D context runs only FMX's own shaders, and there are no application ray passes and no DLSS (see
  "Vulkan back end").
