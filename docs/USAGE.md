# Using FastCanvas

## Requirements

- Delphi 13 (RAD Studio 37.0) or later, FireMonkey, Win64 or Win32. Win64 is faster on the CPU side (Delphi's 32-bit
  code: about 1.4 to 1.9 times the frame time on scenes with many shapes, strings or controls, measured 2026-10-13);
  the GPU work is the same.
- Windows 10 or 11; Android 7.0 (API 24) or later on arm64 (Vulkan back end only, see "Android and Linux"); Linux
  x64 with glibc 2.35 or later (programs linked against the default SDK, Ubuntu 22.04's) and GTK 3 on X11 (Vulkan
  back end; tested on Ubuntu 26.04 in WSL2 with WSLg and on Ubuntu 22.04, Debian 12 and Fedora 44 in containers, on
  Mesa's lavapipe).
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
| `FastCanvasGeometryEngine` | `Native` (Windows), `Own` | Paths, their fill edges and stroke outlines: `Native` is Direct2D (Windows only; elsewhere it stands for `Own`), `Own` is FastCanvas's own engine (`FastCanvas.GeometryOwn`: no library; the default on Android and Linux), `Skia` is Skia (`FastCanvas.GeometrySkia`). Read when the first canvas is made. |
| `FastCanvasTextEngine` | `Native` (Windows, Linux), `Skia` (Android) | Text layout and glyphs: `Native` is DirectWrite on Windows and Pango with FreeType on Linux (`FastCanvas.TextPango`, see "Android and Linux"), `Skia` is Skia's paragraphs (`FastCanvas.TextSkia`: HarfBuzz shaping, the platform's font fallback; the only one on Android). `Own` is no text engine (on Linux it stands for `Native`). Read by `InstallFastCanvas`. |
| `FastPangoLightHinting` (`FastCanvas.TextPango`) | `False` | Linux: glyphs of the Pango engine hinted lightly (FreeType's light hinting, vertically only: the look of GTK's text with fontconfig's default `hintslight`); `False`: unhinted outlines, as Skia's. Set before the first text is drawn. |

On Windows and Linux the other engines are linked only when the program uses their units (`FastCanvas.GeometryOwn`,
`FastCanvas.GeometrySkia`, `FastCanvas.TextSkia`); the Skia ones then need `sk4d.dll` (`libsk4d.so`) next to the
executable. The own geometry engine strokes as Direct2D does (joins, the miter limit, caps, dash patterns and their
places, curves
flattened as densely): on the benchmark's scenes its screenshots differ from Direct2D's in 0.35 % of the pixels of
`strokes`, 0.17 % of `paths` (antialiasing at curves and dash ends) and nowhere else, at the same or a higher frame
rate (`BENCHMARKS.md`). Skia's geometry differs more (dash phase, curve flattening) and widens dashed strokes more
slowly. Skia's text differs from DirectWrite's by a fraction of a pixel in line height (paragraphs drift by a pixel
every few lines), its glyphs are unhinted outlines (DirectWrite's grayscale is about as soft), and FMX fonts added
through `TFontManager` are not known to it. On Linux Skia's paragraphs are slow: about 80 ms to lay out a paragraph of
190 characters, against 0.1 ms with Pango and 0.1 ms with Skia on Windows (`TextProbe --bench`, measured in WSL on the
same PC; apparently every paragraph builder of `sk4d` makes a font collection of its own, whose fonts fontconfig then
matches again).

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
  is ignored), each from a thread of its own: the render thread hands a finished frame to it and goes on (the surface
  of the frame shown before takes the next frame: nothing is copied), the window's thread acquires an image, copies
  the newest frame into it and presents. The present mode: `IMMEDIATE` with `AllowTearing`, else the first the driver
  has of `MAILBOX`, `FIFO_LATEST_READY` and `FIFO`. The GPU is at most three frames behind. A partial frame
  (`FastCanvasPartialFrames`) starts from a copy of the frame shown last, as on Direct3D 12.
- **Phones** (GPUs other than discrete ones): the canvas's pixel shader comes in variants that leave out what a draw
  does not have (shapes with gradients, glyphs, images, the three together, paths; with and without the clip test),
  and the renderer splits its runs of instances into draws of the cheapest variant where the pixels saved pay for a
  draw; large rectangle outlines are drawn around their inside. They draw the same pixels as the full shader
  (`FASTCANVAS_VK_VARIANTS=1` on a desktop GPU: the benchmark's scenes match pixel for pixel), several times faster
  on a Mali GPU. A discrete GPU keeps the full shader (the variants would only cost it draws). With the variants:
  **opaque interiors** (`FASTCANVAS_VK_INTERIORS`): targets of 256 x 256 pixels and more get a transient depth
  buffer; the inside of filled rectangles with an opaque solid color or an opaque two-stop linear gradient is drawn
  first, without blending, and nothing under it is shaded again (overlapping opaque shapes cost a phone their visible
  pixels, not their overdraw); **paths as pieces** (`FASTCANVAS_VK_PATHMESH`): a path, a widened stroke, a dashed
  outline is drawn as trapezoids around its edges and over its inside instead of a quad over its bounds, and the
  bands of many edges of a lasting path are cut into cells, so that a pixel goes through the edges near it only
  (`strokes` medium on the Mali-G57: 37.5 -> 72.5 FPS); partial frames are drawn within a scissor. Solid colors and paths match the full shader within a level or three of 255
  where a path's pixel is antialiased (0.04-1.2 % of the pixels of the benchmark's path scenes); gradient interiors,
  interpolated per vertex rather than read from the ramp, differ by one level (0.65 % of the gradients scene). Off
  on discrete GPUs (with the variants).
- **The 3D context** runs FMX's own shaders (materials, filters, effects, transitions) as SPIR-V made from the GLSL
  sources FMX ships, with the constants laid out as for Direct3D: `tools\compile-fmx-shaders-vk.ps1` writes
  `FastCanvas.VkFmxShaders.inc` (run it again, with the Vulkan SDK, when a Delphi update changes FMX's shaders). A
  shader FMX does not ship (an application's `TContextShader` or material) raises `EContext3DException`. The descriptors
  of a draw are pushed (`VK_KHR_push_descriptor`), or written into a set of the canvas's descriptor pools where the
  device lacks that extension (`FASTCANVAS_VK_NOPUSH=1` takes that path on any GPU). The constant layout of each
  shader (the variables of its Direct3D source: offsets, sizes, texture units) is kept in the generated include with
  its SPIR-V and attribute locations, so the context runs where FMX ships no Direct3D sources too (Android, Linux):
  there it finds a shader by its GLSL source alone. The SPIR-V is version 1.3, for Vulkan 1.1 devices.
- **Multisampling** (a `TViewport3D` has 4 samples by default, a `TForm3D` what its `Multisample` says): a scene is
  resolved by its own rendering instance (a resolve attachment of the render pass; with dynamic rendering the
  resolve mode of the color attachment), and the samples, the depth and the stencil are not written to memory at the
  scene's end; they are transient attachments, in lazily allocated memory where the device has it (the depth only
  where there are no ray queries: the ray-traced effects read it). On a tiler (phones) the samples then never leave
  tile memory: on the Mali-G57 the benchmark's `viewport3d` went from 35 to 115-119 FPS (`BENCHMARKS.md`). What
  interrupts a scene (a copy or a texture update recorded in it, canvas drawing into a bitmap during it, the ray-traced
  effects, a nested scene of another context) stores them as before and the scene's end resolves them in a rendering
  instance of its own; the pictures are the same either way. As with FMX's Metal context, the multisampled color, the
  depth and the stencil do not outlast a scene: one that draws before it clears them (or ends without clearing its
  color) makes the context keep them for the scenes after it, and finds them cleared (transparent, depth 1, stencil 0)
  itself. FMX's `TViewport3D` and `TForm3D` clear color and depth at every scene.
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

There the canvas runs on its Vulkan back end, with FastCanvas's own geometry engine, Skia's text engine on Android
(Skia is part of Delphi's RTL, linked into the library) and the Pango text engine on Linux (the system's Pango,
HarfBuzz, fontconfig and FreeType: no Skia), and the Vulkan 3D context (`InstallFastContext3DVk`) draws
`TViewport3D`, `TForm3D`, the effects and the ray-traced effects as on Windows. The search path needs `src\Canvas`
and `third_party\pasvulkan\src` only.

```pascal
begin
  FastCanvasBackend := TFastCanvasBackend.Vulkan; // the only back end there
  try
    TFastDevice.Ensure;   // EFastDevice when there is no Vulkan device the canvas can use, with the reason
    InstallFastCanvas;
    if TFastContext3DVk.Valid then
      InstallFastContext3DVk;
  except
    // No install: FMX's own canvas (TCanvasGpu on Android) draws the forms.
  end;
  Application.Initialize;
  ...
```

`src\Probe\PortProbe.dpr` does this, shows the device, its Vulkan version and limits and the engines, draws a cube in a
`TViewport3D` with the Vulkan 3D context (`--shadows=1 --ao=1 --reflect=1`: with the ray-traced effects, a floor and a
pole; `--effects=1`: FMX effects on two controls), and remembers a start with FastCanvas that crashed or raised (the
next start takes FMX's canvas and says why).

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
- Partial frames: FMX's Android platform forgets which rectangles a form invalidated and paints the whole form;
  `InstallFastCanvas` wraps its window service so that they are kept, and a window frame updates only their bounds
  (`FastCanvasPartialFrames`; FMX still paints every control, the canvas leaves out what is outside, the GPU starts
  from a copy of the frame shown last). Bounds of half the window or more take a whole frame.
- Without a phone: an Android 14 x86_64 emulator image (`system-images;android-34;google_apis;x86_64`) runs the
  arm64 library through its ARM translation, with the host GPU's Vulkan (`emulator -avd <name> -gpu host`); PortProbe
  was tested so (before the 3D context and the own geometry engine came to Android).
- On a phone (2026-10-14): a TECNO KL7 (Helio G99, Mali-G57 MC2, driver r32p1, Vulkan 1.1.177, Android 14, 1080x2436
  at 120 Hz) runs PortProbe on the Vulkan 1.1 core path (render passes, Vulkan 1.0 barriers, timeline semaphores; with
  fences too), through cold starts, the app in the background and back, and the screen off and on. With the shader
  variants ("Vulkan back end") it shows 115-118 FPS of the display's 120 with `--interval=1`, where FMX's `TCanvasGpu`
  shows 107-119 (its main thread paints the scene in 2.3-4.9 ms, FastCanvas's records it in 0.7-1.5 ms); with
  PortProbe's default 10 ms timer both show about 97. GPU time per frame (`FASTCANVAS_VK_GPUTIME=1`): one render pass
  of 7.2 ms and the presenting thread's blit into the swap chain of 0.7 ms. Before the variants it showed 55-59 FPS,
  GPU-bound: two render passes (the clear alone, then the draws) of 15.5 ms together (an almost empty frame about 10
  ms: the one pixel shader for everything is heavy for a two-core Mali), the frame's copy for the presenting thread
  0.85 ms, the blit 0.76 ms. Of the 7.2 ms, roughly: the controls and labels 2 ms, the scene's gradient background
  2 ms, the wave (a widened path) 1.6 ms, the dashed star 1.3 ms. The pictures are the same pixels as before (paused
  frames, `--time=3.7`, compared byte for byte). PortProbe reads `options.txt` in the app's files directory (`adb
  shell run-as <package>`): options as on its command line and `NAME=VALUE` environment variables such as
  `FASTCANVAS_VK_NOTIMELINE=1`; its status line (also in the log, `adb logcat`) gives the frame rate, the recording and
  render-thread times per frame. With the Vulkan 3D context and the own geometry engine (since the merge of the
  Linux work) the phone draws PortProbe's cube with that context on the Vulkan 1.1 core path: 84-100 FPS with the cube
  (three render passes, 9.1-9.2 ms of GPU time, 10.7-11.1 ms with the copies and resolves of the viewport), 116-120
  FPS without it (`--parts` without `cube`: 6.9-7.1 ms, as with Skia's geometry before); no Vulkan errors in the log.
  With the opaque interiors and paths as pieces (same day) the scene without the cube takes 3.7-4.3 ms of render
  passes a frame (before: 6.7-7.2 ms; see "Phones" under "Vulkan back end"): with the controls and labels alone
  1.4 ms either way, the gradient background added 2.5 ms before and 0.6 ms now, the wave 2.1 and 0.5 ms, the star
  with its dashed outline 1.8 and 0.3 ms; with the cube 7.0 ms; the scene paused with only
  a button changing (`--pause=1`) 1.0 ms of render pass plus 1.6 ms of copies (the last frame into the new one, the
  frame into the swap chain) against 4.4 ms for whole frames (`--partial=0`). With the cube's samples resolved in its
  rendering instance and not stored ("Multisampling" under "Vulkan back end", same day) the scene with the cube takes
  4.9 ms of render passes and 5.4-5.8 ms of command buffers a frame (before: 5.4 and 6.7-7.0 ms), 115-118 FPS either
  way; the picture is the same, pixel for pixel (`--time=3.7`). `--split=1` adds a plane to the cube's viewport that
  shows a bitmap the cube's `OnRender` draws into: canvas drawing in the middle of the scene, which then stores its
  samples and loads them again (5 render passes, 6.6 ms). PortProbe `--scene=<name>` runs a scene
  of the benchmark (`--preset`, `--count`): FastCanvas against `TCanvasGpu` on that phone is in `BENCHMARKS.md`.
  `FASTCANVAS_VK_DIRECT=1` stays slower there: a render pass into the swap chain's images costs about as much more as
  the copy it saves (`ARCHITECTURE.md`).

Linux:

- FMX's Linux platform (FMUX, a GTK 3 library embedded in the program, written to `~/.fmxlinux` at the first start)
  runs GTK on X11: `FMX.Platform.Linux` calls `FmuxInit(FMUX_INIT_NOWAYLAND)`, so in a Wayland session the program
  runs through XWayland without `GDK_BACKEND=x11`. The canvas makes the form's drawing area a native window and
  presents to its X11 window (`VK_KHR_xlib_surface`, the XID and the display through GDK, loaded at run time).
- Running it needs `libvulkan.so.1` and a Vulkan 1.1 driver with the extensions under "Requirements" (Mesa: radv,
  anv, nvk; lavapipe on the CPU) and GTK 3 (`libgtk-3.so.0`), which brings the libraries of the text engine:
  `libpango-1.0.so.0` and `libpangoft2-1.0.so.0` (Pango 1.44 or later), `libharfbuzz.so.0`, `libfontconfig.so.1`,
  `libfreetype.so.6`, `libgobject-2.0.so.0`, `libglib-2.0.so.0` (loaded with `dlopen` at the first text layout; the
  program does not link them, and an exception names what is missing). `libsk4d.so` (`Redist\linux64`, 26.7 MB)
  goes next to the program only when it uses the Skia engines (`FastCanvas.GeometrySkia`, `FastCanvas.TextSkia`).
- **Text on Linux** (`FastCanvas.TextPango`, the default; `FastCanvasTextEngine := TFastCanvasEngine.Skia` with the
  unit `FastCanvas.TextSkia` takes Skia's): a `PangoLayout` per text layout on a PangoFT2 font map at 96 dpi with
  pixel sizes (FMX's font sizes are pixels) and glyph positions in fractions of a pixel: HarfBuzz shaping (Arabic,
  Hebrew, Devanagari, Thai, ligatures), bidi, line breaking, fontconfig's font fallback (as GTK applications on the
  system show text; emoji in color from Noto Color Emoji's bitmaps). `WordWrap` wraps at words, inside words longer
  than a line; without it lines are as long as they are and move by the alignment. Leading and trailing alignment
  follow `RightToLeft`. Trimming: without `WordWrap` every line ellipsized at the box's width, with it the lines that
  fit the box and an ellipsis on the last; `Character` is Pango's ellipsizing, `Word` cuts at the last word boundary
  before it (a word longer than the line keeps its first character), as DirectWrite trims. Attributes (font and color
  ranges), underline and strikeout, `PositionAtPoint`, `RegionForRange` (carets, bidi ranges) and `ConvertToPath`
  work as with the other engines. Lines are as high as their fonts' ascent and descent, in fractions of a pixel
  (Skia's paragraphs round them to whole pixels: on DejaVu Sans 14 px a line is 16.30 px with Pango, 16 with Skia).
  Glyphs: FreeType (the engine's own `FT_Library`, a face per font file), unhinted outlines at quarter pixels as with
  Skia, or lightly hinted (`FastPangoLightHinting`); rotated and large text from FreeType's outlines. Variable fonts
  (Ubuntu's) at every weight and width. Fonts added through FMX's `TFontManager` are found (FMX's GTK library adds
  them to fontconfig's configuration; the engine looks at it again when their number changed), unlike with Skia.
- **Without Skia**: a Linux program that leaves the Skia units out runs without `libsk4d.so`
  (`tools\build-linux.ps1 -Define FASTCANVAS_NOSKIA` builds the probes so and does not copy it). PortProbe: 15.5 MB
  alone; with the Skia engines linked 16.0 MB and `libsk4d.so` (26.7 MB) next to it (MB of 2^20 bytes).
- Building without PAServer: Delphi links Linux programs against a copy of the target's libraries, the platform SDK.
  `tools\make-linux-sdk.ps1 [-Distro Ubuntu-22.04] [-Sdk D:\LinuxSDK\<distro>] [-Install] [-CreateDistro]` makes one
  from a WSL distribution (the top-level files of `/usr/lib/x86_64-linux-gnu` and `/usr/lib/gcc/x86_64-linux-gnu/<n>`,
  `/lib64/ld-linux-x86-64.so.2` and `/usr/include`, symbolic links dereferenced, `lib` a junction to `usr\lib`;
  `-Install` first installs `libc6-dev`, `libgcc-<n>-dev` and `zlib1g-dev`, which hold the startup objects, the
  linker scripts and `libz.so`; `-CreateDistro` installs the WSL distribution itself when it is missing, without the
  first-run prompt: `wsl --install -d <distro> --no-launch --web-download --location D:\WSL\<distro>`): 0.6 to
  0.9 GB. Programs linked against it need that distribution's glibc or a later one, so the default is the SDK of
  Ubuntu 22.04 (glibc 2.35, `D:\LinuxSDK\ubuntu-22.04`): PortProbe needs `GLIBC_2.34` at most, `libsk4d.so`
  `GLIBC_2.29`, the libfmux FMX writes out `GLIBC_2.2.5`. `-Sdk D:\LinuxSDK\ubuntu-26.04` (made with
  `-Distro Ubuntu-26.04`) links against Ubuntu 26.04 instead (glibc 2.43 or later needed at run time).
- `tools\build-linux.ps1 -Project <dpr> -SearchPath <dirs> [-Config Debug] [-Sdk <dir>] [-Define <names>]` builds
  with `dcclinux64` into `bin\Linux64\<Config>\<name>` and copies `libsk4d.so` next to it (not with
  `-Define FASTCANVAS_NOSKIA`); with a `.dproj` that has the Linux64 platform
  it runs msbuild instead (output where the project puts it). dcclinux64 links with LLVM's lld (`bin64\ld.lld.exe`, on
  the PATH) and is told about the SDK with `--syslibroot:<sdk>` (the linker's sysroot) and `--libpath:<dirs>`: Delphi's
  `lib\linux64\release` (`librtlhelper`), the SDK's `usr\lib\x86_64-linux-gnu` and `usr\lib\gcc\x86_64-linux-gnu\<n>`;
  msbuild takes the same as `/p:DCC_SysLibRoot=<sdk>` and `/p:DCC_LibraryPath=<dirs>` (what an IDE SDK profile sets
  as `Profile_sysroot` and `Profile_LibraryPath`). Delphi's `lib\linux64\release` must be on the resource path too,
  and `-GD` (a map file with a `.drc`) fails on `FMX.Filter.res`, which Delphi 13 does not ship for Linux64: the
  script makes the map with `-G`.
- Running in WSL2 with WSLg (its windows appear on the Windows desktop):
  `wsl -d Ubuntu-26.04 -- timeout 60 /mnt/d/<...>/bin/Linux64/Release/PortProbe`. In WSL only Mesa's lavapipe (Vulkan
  1.4 on the CPU, with ray queries) is a usable Vulkan device. `FASTCANVAS_VK_DEBUG=<file>` works with the
  distribution's `vulkan-validationlayers`. Screenshots: PortProbe `--shot=<png> --seconds=<s>` saves the frame
  FastCanvas presented (`FastCanvasCaptureWindow`), or `xwd -id <window> | magick xwd:- <png>` (the root window
  cannot be read under XWayland). WSLg's window manager does not close windows for `wmctrl`/`xdotool`; a
  `WM_DELETE_WINDOW` client message closes them as a title bar's close button does.
- Other distributions without a screen: `tools\linux-compat.ps1` checks the glibc versions the program and
  `libsk4d.so` (when it is next to it) need (`objdump -T`), then runs PortProbe on a private Xvfb for 8 seconds in the WSL distribution and in
  Docker containers of `ubuntu:22.04`, `debian:12` and `fedora:latest` (images with GTK 3, Mesa's Vulkan drivers,
  libGL, fontconfig, a font and Xvfb, built once as `fastcanvas-compat:<image>`), and keeps the frame FastCanvas
  presented (`D:\Work\FastCanvas-compat\<image>\frame.png`). Passed (2026-10-14, linked against the Ubuntu 22.04
  SDK): Ubuntu 26.04 (WSL, glibc 2.43, lavapipe of Mesa 26 with Vulkan 1.4), Ubuntu 22.04 (glibc 2.35, Vulkan 1.3
  on LLVM 15's lavapipe, no ray queries), Debian 12 (glibc 2.36, Vulkan 1.3), Fedora 44 (glibc 2.43, Vulkan 1.4):
  FastCanvas and its Vulkan 3D context draw the scene on all of them. On glibc 2.31 (Debian 11) the loader refuses
  the program (`GLIBC_2.34 not found`).
- Tested (2026-10-14, Ubuntu 26.04 in WSL2, lavapipe): PortProbe draws the scene, its text with Cyrillic and color
  emoji, the controls (clicks work), the cube by the Vulkan 3D context with ray-traced shadows, ambient occlusion and
  reflections, and FMX's effects, each pixel for pixel as Win64 on an RX 9070 XT outside the text (other fonts); with
  `GDK_SCALE=2`, with sizes changed from code, closed by the window manager and by itself, 2.5 minutes without memory
  growth after the caches fill; the validation layer (with synchronization validation, also with
  `FASTCANVAS_VK_API=1.1` and `FASTCANVAS_VK_NOPUSH=1`) reports nothing. The benchmark is Windows-only. With the
  Pango text engine (2026-10-14, Pango 1.57, FreeType 2.14): PortProbe built without Skia runs without `libsk4d.so`
  and draws the same frame as with Skia's engines but for the text (glyphs a quarter pixel apart in places, lines a
  fraction of a pixel taller); `src\Probe\TextProbe.dpr` (`tools\run-textprobe-linux.sh`) draws every case above with
  either engine (see "Debugging").

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
- `FASTCANVAS_VK_GPUTIME=1` (the platform's log: `adb logcat`, tag `FastCanvas`; `OutputDebugString` on Windows) or
  `=<file>`: every two seconds the GPU time per window frame of the render passes, of the command buffers and of the
  presented copies, from timestamps (a tile-based GPU cannot time its draws one by one: the render passes are the
  unit), and how the 3D context's scenes ended: in their rendering instance (resolved there), resolved apart, with
  rendering instances stored before their end, and instances that ended before the end they were planned to last to
  (0 but for a fault).
- `FASTCANVAS_VK_VARIANTS=1`: the shader variants of phones on any GPU (a test of their pixels on a desktop GPU), `0`:
  the full shader everywhere. `FASTCANVAS_VK_INTERIORS=0`: no opaque interiors (and no paths as pieces) where the
  variants are; `FASTCANVAS_VK_PATHMESH=0`: no paths as pieces. `FASTCANVAS_VK_DIRECT=1`: frames drawn straight into
  the images of a swap chain of the render thread (no copy, no presenting thread, no partial frames; on the Mali-G57
  slower than the copy it saves).
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
- `tools\map-address.ps1 -Map <map> -Address <hex>`: the function of an address in a crash message of a Linux program
  (the map file of LLVM's lld).
- The benchmark runs on Vulkan with `--canvas=fcvk` (also `fcvkrt`, `fcvkao`, `fcvksoft`, `fcvkrefl` with ray-traced
  effects, `fcvksep` with FMX's stock 3D context, `fcvkskia` with the Skia geometry and text engines, `fcvkown` with the
  own geometry engine of Android and Linux).

## Limitations

- Windows (Win64, Win32), Android (arm64) and Linux (x64, X11). On Android and Linux: the canvas and the 3D context on
  Vulkan only, no ClearType, no HDR output, no Direct2D fallbacks (`D2DText`).
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
