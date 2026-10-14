# How FastCanvas works

FastCanvas replaces the canvas and the 3D context of FireMonkey on Windows, Android and Linux. It is written from scratch on Direct3D 11, Direct3D 12 or Vulkan (the only back end on Android and Linux);
FMX itself (forms, controls, styles, layout, animations) is unchanged.

## Units

| Unit | What it does |
|---|---|
| `FastCanvas.Canvas` | `TFastCanvas`: records canvas calls as commands, owns bitmaps (`TFastBitmap`), window targets, the player that executes the commands on the render thread, device loss, partial frames. |
| `FastCanvas.RenderQueue` | The command stream (chunks) and the render thread. |
| `FastCanvas.Gpu` | The renderer that does not depend on the graphics API: instanced runs of primitives, clip/paint/edge tables, gradient ramps, glyph atlas. |
| `FastCanvas.Gpu11`, `FastCanvas.Gpu12` | The Direct3D 11 and Direct3D 12 back ends of the renderer: surfaces, swap chains, pipelines. |
| `Shaders/FastCanvas.hlsl` → `FastCanvas.Shaders.inc` | The canvas shaders (vs_4_0 / ps_4_0, DXBC, used by both back ends; for Vulkan also variants of the pixel shader, see "The Vulkan back end"). |
| `FastCanvas.Text` | The text that does not depend on the engine: `TFastTextLayout` and its data (glyph runs, overhang, decorations), the layout cache, the glyph atlas, the engine registry (`FastCanvasTextEngine`). |
| `FastCanvas.TextDWrite`, `FastCanvas.TextSkia` | The text engines: DirectWrite (Windows) and Skia paragraphs (every platform; the only one on Android and Linux): layouts, glyph coverage, glyph outlines, layouts with color glyphs rasterized on the CPU. |
| `FastCanvas.Geometry`, `FastCanvas.GeometryD2D`, `FastCanvas.GeometryOwn`, `FastCanvas.GeometrySkia` | The CPU geometry (paths, their fill edges and stroke outlines, hit tests) and its engines: Direct2D (Windows), FastCanvas's own (Android, Linux) and Skia (`FastCanvasGeometryEngine`). |
| `FastCanvas.Platform` | The window of a form for the back end on Windows (HWND), Android (`ANativeWindow`) and Linux (X11 window of the GTK drawing area), and its size in pixels. |
| `FastCanvas.Device` | The device of the process (Direct3D 11 or 12), DXGI, Direct2D factory (CPU geometry), DirectWrite. |
| `FastCanvas.Hdr`, `Shaders/FastOutput.hlsl` | HDR output: the setting, what the display of a window can show (DXGI outputs, SDR white level), the pass that turns a window's frame into scRGB. |
| `FastCanvas.Service` | Installs the canvas class and the 3D context class into FMX (`IFMXCanvasService`, `IFMXContextService`). |
| `FastCanvas.Bridge` | What a 3D context needs from the canvas: device, lock, bitmap textures, a way into the command stream. |
| `FastCanvas.Context3D` | The part of the 3D contexts that does not depend on the API: shaders and their variables, pipeline state, vertex layouts, the settings of the ray-traced effects. |
| `FastCanvas.Context3D11`, `FastCanvas.Context3D12`, `FastCanvas.Context3DVk` | The 3D contexts (`TContext3D`) for `TViewport3D`, `TForm3D` and the effects. |
| `FastCanvas.Context3D12.Ray.inc`, `Shaders/FastRay.hlsl` → `FastCanvas.RayShaders.inc` | Ray-traced effects (DXR 1.1, shader model 6.5). |
| `FastCanvas.DeviceVk` | The Vulkan device (1.1 and up; dynamic rendering, synchronization2 and timeline semaphores where it has them, core or extension): the loader and surface extension of the platform, instance, physical and logical device and their optional features, the render passes of devices without dynamic rendering, the memory suballocator, the queue lock. |
| `FastCanvas.GpuVk` | The Vulkan back end of the renderer: the recording context, surfaces, windows (Win32, Android and Xlib surfaces) and the threads that present them, pipelines. |
| `FastCanvas.VkShaders.inc`, `FastCanvas.VkRayShaders.inc`, `FastCanvas.VkFmxShaders.inc` | SPIR-V: `FastCanvas.hlsl`, `FastOutput.hlsl` and `FastRay.hlsl` (dxc), FMX's own shaders (from their GLSL, `tools/compile-fmx-shaders-vk.ps1`). |
| `FastCanvas.Context3DVk.Ray.inc` | Ray-traced effects on Vulkan (ray queries). |
| `FastCanvas.D2D1Ext`, `FastCanvas.DWriteExt`, `FastCanvas.DCompExt` | Headers of Direct2D 1.1+, DirectWrite 2 and DirectComposition that Delphi's RTL lacks. |

The shaders are compiled offline by `tools/compile-shaders.ps1` (fxc and dxc from the Windows SDK; SPIR-V with dxc
and glslangValidator from the Vulkan SDK) into Pascal byte arrays; building FastCanvas needs none of the compilers.

## Platforms

The canvas does not call Windows APIs outside `{$IFDEF MSWINDOWS}`: what it needs of a platform goes through three
seams, so the same recording, player and renderer run on Android and Linux on the Vulkan back end.

- **Geometry** (`TFastGeometryEngine`): paths from FMX points, rectangles, rounded rectangles, ellipses, lines;
  `Flatten` and `Widen` (with a `TFastStroke`: width, caps, joins, dashes) into the canvas's edge sink, which flattens
  curves to its tolerance; `Contains`. Direct2D on Windows by default, FastCanvas's own engine on Android and Linux (see
  "The own geometry engine"), Skia (`SkPath`, `SkPaint.getFillPath`) where chosen. Glyph outlines come from the text
  engine as FMX path points and are filled through it too.
- **Text** (`TFastTextEngine`): the layout class (`TFastTextLayout` descendants fill `TFastLayoutData`: glyph runs
  with an engine font face that keys the glyph cache, ink overhang, underline and strikethrough rectangles), glyph
  coverage for the atlas (DirectWrite's alpha textures; Skia: the unhinted outline filled, plain coverage that the
  shader corrects for gamma and contrast alike), glyph outlines, and the CPU image of layouts with color glyphs. Skia
  lays text out with SkParagraph (HarfBuzz, line breaking, bidi, the platform's font fallback); color fonts are told
  by name or by a glyph without an outline (Android names its fallback fonts "91##fallback").
- **Windows** (`FastCanvas.Platform`, `TGpuWindowHandle`): the native window and display a form presents to, whether
  it can be drawn now, its pixel size. Android: the `ANativeWindow` of the form's surface holder, held while the
  canvas lives (FMX makes the canvas again on `surfaceCreated`/`surfaceChanged`). Linux: the X11 window of the GTK
  drawing area through GDK, loaded at run time.

Off Windows the render queue waits on `TEvent`s, the device lock, the queue lock and the locks of the memory
allocator, of the presenting threads and of the 3D context are monitors, thread ids come from `pthread_self`. The
Vulkan back end takes devices below 1.3 through `VK_KHR_dynamic_rendering`, `VK_KHR_synchronization2` (and
`VK_KHR_timeline_semaphore` below 1.2) where they have them, with the KHR commands under the core names
(`FASTCANVAS_VK_API=1.1` tests that path on any GPU), and through the Vulkan 1.1 core path where they lack them (see
"The Vulkan back end"); such a device gets push descriptors (the 3D context) and `FIFO_LATEST_READY` where it has
them, but no ray tracing features (the ray-tracing shaders are built for Vulkan 1.2). Windows present from a thread of
their own there too. On Android the swap chain is not rotated by the canvas and a suboptimal swap chain is kept (it stays
suboptimal while the display is turned); the frame is blitted into the `R8G8B8A8` images. A lost surface (the app went
to the background) ends the window's presenting thread, which drops its swap chain; the next frame of the window
drops the surface and is not presented, and FMX makes the canvas again for the next native window. On Android the
render thread waits until the presenting thread has taken the frame before (it presents with `FIFO`), so the frames
keep the display's pace as when the render thread presented itself. The Vulkan 3D context runs there too (a
`TForm3D` window gets its native window through `FastCanvas.Platform`): FMX ships the Direct3D sources of its
shaders, whose variables lay the constants out, on Windows only, so the generated include keeps those variables with
each shader's SPIR-V, and off Windows `FastCanvas.Context3D` asks the device context for them (`ShaderLayout`), which
finds the shader by its GLSL source.

Linux programs are linked on Windows against a copy of a distribution's libraries (`tools\make-linux-sdk.ps1`, from
WSL) with dcclinux64 and LLVM's lld (`tools\build-linux.ps1`); no PAServer is needed (`USAGE.md`, "Android and
Linux").

The PasVulkan header is patched for Delphi's 64-bit POSIX platforms, where `LongInt` and `LongWord` are 64-bit
(`third_party\pasvulkan\PROVENANCE.md`).

## Recording and the render thread

Every canvas call of the main thread appends a compact command to the current chunk of the command stream and returns:
nothing is drawn on the main thread, and no driver is called there. `EndScene` of a window hands the chunk to the render
thread, which executes chunks in submission order, so the stream order is the program order: a bitmap drawn into and
then drawn onto a form needs no synchronization. The main thread records frame N + 1 while the render thread draws
frame N (`FastCanvasFramesInFlight`). Objects that commands refer to (bitmaps, text layouts) are kept alive by the
chunk until it has run.

Waits of the main thread (a frame in flight, `TBitmap.Map`) dispatch messages sent to its windows and nothing else,
so a wait inside a paint does not re-enter FMX. Without a render thread (`FastCanvasRenderThread := False`) the same
stream is executed on the recording thread at `EndScene`.

## The renderer

- **One instance per shape.** A rectangle (with rounded corners per corner), a rectangle outline (miter, round or bevel
  joins), an ellipse and its outline, a line (flat, square or round caps, dashes), an image and a glyph are each one
  84-byte instance record: the shape rectangle in local space, a 2x3 matrix, radii, texture coordinates, color, flags,
  clip index, paint index, stroke width. The main thread writes the records straight into the stream; the render
  thread copies runs of them into a vertex buffer and draws each run with one instanced draw call. A new run starts
  only for a new render target or a ninth texture (on Vulkan phones also for another variant of the pixel shader).
- **Coverage is analytic.** The pixel shader computes the signed distance to the shape's edge in local space; the
  antialiasing width is the size of a pixel taken from the derivatives of the local position. Shapes are smooth at any
  rotation and scale, with no MSAA and no tessellation.
- **Clips do not split draws.** A clip is an entry of a table (a pixel box and up to two rotated rectangles, the
  inverse kind for `ExcludeClipRect`); instances carry its index and the shader tests the pixel center.
- **Paints** (a table too): linear and radial gradients (256-texel ramps in a shared texture), bitmap brushes (sampled
  in the shader, tile modes included), dash patterns.
- **Paths** are polygons: the render thread flattens a path once with the geometry engine (on Windows the Direct2D
  factory: `Simplify` for fills, `Widen` for strokes, so joins, caps and dashes are exactly Direct2D's; on Android and
  Linux the own engine, which strokes as Direct2D does), splits the edges into horizontal bands and
  stores them in an edge table; the shader computes the exact area of the pixel square inside the polygon from the
  edges of its band (even-odd for FMX fills, non-zero for strokes). Results are cached by path and scale; shapes that
  move keep their edges (the offset goes into the instance matrix). The table keeps a persistent part and a per-frame
  part, so geometry that changes every frame does not evict the geometry that stays.
- **Text.** `TFastTextLayout` builds a DirectWrite text layout, analyses it once into glyph runs (cached by text and
  parameters), and the canvas draws glyph quads that sample an R8 glyph atlas (2048 x 2048, shelf-packed; glyphs
  rasterized by DirectWrite at 4 horizontal subpixel positions, in grayscale by default; ClearType glyphs take three
  texels per pixel, aliased ones are 0 or 255). The blending follows DirectWrite's own contrast and gamma correction
  (formulas of Microsoft Terminal, `THIRD_PARTY_NOTICES.md`); ClearType blends per channel with a second pixel shader
  output (dual-source blending), switched on at the first ClearType glyph of a window frame. Color fonts
  (emoji) are rasterized once into images; rotated and very large text is drawn from glyph outlines.
- **No Direct2D drawing.** Direct2D only serves the CPU geometry; everything is drawn by the shaders above.

## The own geometry engine

`FastCanvas.GeometryOwn` makes the polygons of fills and stroke outlines without a library, as Direct2D makes them, so
that Android and Linux draw what the stock Direct2D canvas draws on Windows:

- **Geometries** are FMX path points; rectangles, rounded rectangles (corners as cubic quarter arcs) and ellipses
  start where Direct2D's start and run the same way round (clockwise on screen from the top left corner, the top of
  the left side, the leftmost point), so dash patterns start in the same places. Fills go into the edge sink with the
  path's rule, curves flattened with the edge sink's formula at 0.6 of the tolerance: as densely as Direct2D
  flattens (measured), which matches its fills best.
- **Strokes**: every figure is flattened (curves also finer where the stroke is wide: a turn of `a` per segment puts
  the outer side `w/2 * a^2 / 8` inside the true offset), points of curves remembered as such. Dashes (Direct2D's
  patterns in stroke widths, an odd custom pattern taken twice, the offset moving the pattern towards the start) are
  cut along the flattened figure, started again at every figure; on a closed figure the last dash goes on into the
  first, as Direct2D does. Each dash or open figure becomes one polygon, a ribbon: side A forward, the end cap, side B
  backwards, the start cap; a closed figure two loops (side A forward, side B backwards). At a vertex of the path
  the outer side gets the join (miter up to 10 half widths from the vertex, clipped there; round; bevel; within the
  tolerance of each other the miter point) and the inner side goes through the vertex itself, so the ribbon overlaps
  itself there, as Direct2D's outlines do. At a point of a flattened curve, and where one curve goes on into another,
  both sides take the offset points along the normal (the bisector of the segments), unless the stroke is wider than
  the segments allow (the inner offset lines would cross before the next point: then round outside, through the
  point inside). Round caps and joins are cubic quarter arcs flattened with the sink's formula at the tolerance, as
  Direct2D's are; caps are square to the curve's tangent at the end (the segment's direction turned by half the
  curve's turn per segment), not to the last segment. A figure of no length draws a dot (a square along the path or
  a circle), a lone MoveTo nothing; the corners of a rectangle are outlined exactly (Direct2D outlines rectangles
  without overlaps).
- **Why it is correct at any width**: every polygon runs the same way round (negative area in y-down coordinates),
  and each is the boundary of an orientation-keeping map of the stroke's pieces (segments as quadrilaterals, joins as
  sectors), so its winding number at a point is the number of pieces covering the point: never 0 inside the stroke,
  never negative. The canvas fills outlines with the non-zero rule, which covers the union; where pieces overlap near
  the inner side of a sharp vertex the coverage of a pixel saturates, as with Direct2D's outlines.
- **Contains** flattens the figures at 0.25 (Direct2D's default flattening tolerance) and counts crossings (even-odd)
  or the winding number (non-zero).
- `src\Probe\GeometryProbe.dpr` compares it with Direct2D on the CPU, with the shader's exact coverage per pixel: 245
  cases (joins, caps, dash styles and offsets, curves with cusps and loops, widths from 0.3 to 90, degenerate figures)
  differ by 1910 pixels of area in total (Skia's engine: 17561); a pixel more than 0.3 apart in 17 cases, most of
  them Direct2D's bevels next to segments of no length (it joins there as if the segment had a direction) and dash
  ends on curves. Its `Widen` takes 1.15 times Direct2D's CPU time over the cases (Skia's 4.4 times).

## Windows and present

- Direct3D 11: a flip-model swap chain with two buffers (`FLIP_DISCARD`). FMX repaints the whole form every frame.
- Direct3D 12: three buffers (`FLIP_SEQUENTIAL`; two cost 10 % on light scenes, sequential costs nothing over discard).
  The canvas reports `TCanvasStyle.SupportClipRects` (`FastCanvasPartialFrames`): FMX repaints only the rectangles
  that changed, the frame starts from a copy of the buffer shown last and draws inside a clip around the rectangles,
  testing each pixel against them when there are several. The rectangles hold only while the window is the target:
  scenes of bitmap canvases that run in the middle of the window's frame (image lists, effects) draw everywhere, and
  the window's draws after them are tested again. A frame with nothing to start from (a new or resized swap chain) is
  not presented, and the forms repaint in full. The style is global, so FMX also gives bitmap scenes the rectangles
  it repaints (`TLayer3D` clears and paints only the controls in them): a bitmap scene draws inside them the same
  way, and the region of the window frame it runs in holds again after it.
- `FastCanvasPresentation`: `Flip` gives every window a swap chain of its own (`CreateSwapChainForHwnd`,
  alpha ignored: DWM shows it opaque). `Composition` (default) makes a composition swap chain (`CreateSwapChainForComposition`,
  premultiplied alpha, same buffers and partial frames) that one DirectComposition visual shows in the window
  (`FastCanvas.DCompExt`: a device made with `DCompositionCreateDevice2` without a rendering device, a target on the
  window below its child windows). Transparent pixels show what is under the frame: a DWM backdrop (Mica, Acrylic)
  with the frame extended into the client area, as with the stock Direct2D canvas, whose blt-model swap chain DWM
  composes with alpha. The window's own GDI surface under the visual is filled with black when the swap chain is made
  or resized (a new surface is white; GDI black has alpha 0, transparent over the backdrop). DWM keeps showing the last
  frame of a window's own swap chain after it is gone (GDI drawing, resizing, hiding the window or making it layered
  do not clear it), so a form that switches from `Flip` to `Composition` at run time gets a new window
  (`TCommonCustomForm.Recreate`). Same speed as `Flip` (listbox, controls, effects, rects, text on both back ends,
  measured 2026-10-13).
- Transparent forms draw into a texture that is read back into the layered window after every frame.
- `AllowTearing` presents with `DXGI_PRESENT_ALLOW_TEARING` (throughput measurements); only a swap chain of the window
  can, so such windows take `Flip` also when `Composition` is set.

### HDR output (Direct3D 12)

With `FastCanvasHdr` on, every window frame starts by asking which display the window is on (`MonitorFromWindow`) and
what that display shows, from a cache of the DXGI outputs (`IDXGIOutput6.GetDesc1`: color space, luminances) and the
display configuration (`DisplayConfigGetDeviceInfo`: the SDR white level). The cache is read again when
`IDXGIFactory1.IsCurrent` turns false (a display added or removed, a mode change, Windows HDR switched), for a monitor it
does not know, and on `FastHdrRefresh`; SDR white levels of displays in HDR mode once a second. A window whose display is
in HDR mode (or every window with `Force`) gets its swap chain buffers as `R16G16B16A16_FLOAT` with the color space
`RGB_FULL_G10_NONE_P709` (scRGB; `ResizeBuffers` and `SetColorSpace1` when it changes, a new swap chain when DXGI refuses).

The frame is drawn as before, only into an RGBA16F surface of the window instead of the buffer: the same sRGB-encoded,
premultiplied colors, blended the same way (pipeline states for RGBA16F targets are made on first use), with room above
1.0. At `Present` one full-window pass (`FastOutput.hlsl`) decodes it with the sRGB curve and multiplies by the SDR white
level / 80 nits into the swap chain buffer, which is what Windows does with the 8-bit buffers of other programs: SDR
content keeps its look, and blending, text and antialiasing are unchanged (blending in linear light would change them,
see `USAGE.md`). The surface keeps the frame, so a partial frame starts from it, as from the shown buffer in SDR.

HDR content comes from 3D: a context with `Hdr` draws into an RGBA16F target (same encoding, values above 1), and its
`CopyToBitmap` puts the image into the bitmap's second, RGBA16F surface, which canvases then draw from. The bitmap goes
back to its 8-bit surface (values clipped at 1) when the CPU maps it, a canvas draws into it, or a 3D context renders into
it. On an 8-bit target such values clip; on an HDR window's surface they pass through to the display. Values above 1
come from application passes and from `DrawIntensity`, which draws with a pipeline state that multiplies the color by the
blend factor (`OMSetBlendFactor`: the sRGB encoding of the intensity, exact for white).

A `TForm3D` window belongs to its 3D context, which makes its swap chain: at every scene it asks the same question as
the canvas (`FastCanvasHdr`, the display of the window) and, when the answer changes, makes the swap chain again in the
other format (FP16 with scRGB, or 8-bit). With HDR output the scene draws into an RGBA16F target (and its multisampled
buffer, resolved into it), and before `Present` the same output pass writes it into the swap chain buffer with the SDR
white level of the display.

## The Direct3D 12 back end

One recording context per device: a direct command list per executed chunk of the stream (2D and 3D work share it),
submitted before `Present` and whenever the CPU needs results. Command allocators, upload pages and blocks of the
shader-visible descriptor heap are reused once the fence of the submission that used them has passed; released
resources wait for that fence too. Resource states are tracked per resource and changed by batched barriers. The
canvas pipeline has one root signature (8 root constants, a table of eight textures, a table of the shared resources,
three static samplers) and two pipeline states.

## The Vulkan back end

Modelled on the Direct3D 12 back end. One recording context per device: a primary command buffer per executed chunk,
submitted before `Present` and whenever the CPU needs results; every submission signals the next value of a timeline
semaphore, and command pools, upload pages, descriptor pools and released objects are reused or destroyed once the
timeline has passed the submission that used them. Image layouts are tracked per image and changed by batched
synchronization2 barriers; draws run in dynamic rendering instances, and a clear of a whole target is the load
operation of the target's next instance (a frame's clear and draws take one render pass: on a tiler the frame is
written once, not cleared, stored, loaded and stored again). The canvas pipeline has one descriptor set layout (the
frame constants, eight textures, atlas, ramps, the tables as uniform texel buffers, immutable samplers) and three
pipelines; the viewport flips y (negative height), so the shaders keep Direct3D's coordinates.

**Shader variants** (GPUs other than discrete ones, `FASTCANVAS_VK_VARIANTS`). The one pixel shader that draws every
kind of primitive, clip and paint is too heavy for a phone GPU: on a Mali-G57 it takes 45 work registers (half the
threads), and its loads from the clip and paint tables bound it (Mali Offline Compiler); every pixel of a frame pays
for all of that. `FastCanvas.hlsl` has `WITH_` switches (shapes, dashes, images, glyphs, ClearType, paths, gradients,
bitmap brushes, clips); a variant compiled with some of them off drops branches that its draws never take and computes
the rest as the full shader, so it draws the same pixels. Ten variants (shapes with gradients, glyphs, images, the
three together, shapes and paths; each with and without the clip test) are compiled with `FLAT_TABLES`: the vertex
shader loads the instance's paint and clip entries and hands them on as flat varyings, the same values the pixels
loaded. For a run of instances `TGpuRenderer.InstanceNeeds` tells what each needs (the clip test only where a pixel of
its quad can be outside the clip's box); `TGpuVkRenderer.NextRun` cuts the run greedily into draws of the cheapest
variant that fits, where the pixels saved (instance areas times the variants' cycles) pay for another draw, keeping the
order. A large axis-aligned rectangle outline is drawn as the same instance in up to four scissors around its inside,
whose pixels it leaves as they are; and path bands are at most two pixels tall (`BandPixels`), so a pixel goes through
fewer edges (the ones it skips add nothing to its coverage). A discrete GPU keeps the full shader: its vertex shader
and the splits only cost it (paragraph light on the RX 9070 XT: 1370 FPS with the variants, 1950 without). On the
RX 9070 XT with `FASTCANVAS_VK_VARIANTS=1` the benchmark's scenes draw the same pixels as with the full shader.

Each of the three features is optional (Vulkan 1.1 core path, as on many 2021-2024 phones):

- **No dynamic rendering**: a rendering instance (`TVkRenderingInfo`, the canvas's and the 3D context's alike) begins
  a render pass of the same attachments, load and store operations and layouts (one subpass, no layout changes: the
  barriers before it make them, as with dynamic rendering). Render passes are made once per such set and kept with the
  device; framebuffers are made per target view and size and destroyed with the view. Pipelines are made for a
  compatible render pass (same formats and samples), so the pipeline caches keep their keys.
- **No synchronization2**: a batch of barriers becomes one `vkCmdPipelineBarrier` with the union of the batch's stages
  (TOP/BOTTOM_OF_PIPE where there are none) and each barrier's accesses and layouts (the stage and access bits used
  have the same values in both); submissions go through `vkQueueSubmit`, the timeline value in
  `VkTimelineSemaphoreSubmitInfo`.
- **No timeline semaphores**: every submission signals a fence of its own; the fences of one queue signal in
  submission order, so the last signaled one gives the timeline's value (`TGpuVkTimeline`, also of the presenting
  threads).

`FASTCANVAS_VK_LEGACY=1` turns off dynamic rendering, synchronization2 and push descriptors on any device,
`FASTCANVAS_VK_NOTIMELINE=1` timeline semaphores: on the RX 9070 XT the benchmark's scenes, the 3D scenes with every
ray-traced effect and `Form3DProbe` draw the same pixels that way, with no message of the validation layer
(synchronization validation included).

- **Memory** (`FastCanvas.DeviceVk`): blocks of device memory per memory type (32 MB device-local, 8 MB host-visible,
  host-visible ones mapped), buffers and images in blocks of their own, suballocated first fit; resources larger than
  half a block get memory of their own. Thread-safe: the 3D context makes textures on the main thread while the render
  thread draws.
- **Windows**: frames are drawn into a surface of the window. `Present` hands it to the window's presenting thread
  and takes the surface it showed before for the next frame (a partial frame starts from a copy of the shown one, as
  from the shown buffer on Direct3D 12); the thread acquires a swap chain image (waiting for a fence on the CPU: a
  semaphore wait held up the whole queue), copies the newest frame into it with a recorded command buffer and
  presents; it takes the queue lock only, never the device lock. The render thread waits for neither the display nor
  the driver's acquire, and waits for the GPU only to stay three frames ahead. The present mode is `IMMEDIATE` when
  tearing is allowed, else `MAILBOX`, `FIFO_LATEST_READY` (the AMD driver has no `MAILBOX`) or `FIFO`: frames come as
  fast as with Direct3D 12 presenting with sync interval 0. **Direct** (`FASTCANVAS_VK_DIRECT=1`, a measurement aid):
  the render thread draws the frame into an image of a swap chain of its own (pipelines for `R8G8B8A8` too), acquired
  when the frame begins (the acquire's semaphore goes with the next submission; the image's old content is discarded
  after that wait) and presented when it ends; no partial frames. It saves the copy but did not pay on the Mali-G57:
  its render passes into the swap chain's images took 0.9 ms more per frame than the copy (0.7 ms) costs.

## The 3D contexts

FMX's 3D context (`TContext3D`) renders `TViewport3D`, `TForm3D` and the filters of `FMX.Effects`. FastCanvas has its
own for each back end, on the canvas's device:

- **Shared part** (`FastCanvas.Context3D`): FMX passes a shader's bytecode with its variables by name on every
  draw; variables are found by comparing the string pointer first (FMX passes the same string constants every time;
  the stock context searches with `SameText` on every variable of every draw, a third of the frame of a simple 3D
  scene). Constant buffers are kept with dirty flags; the pipeline state FMX sets is a small record that serves as a
  cache key.
- **Direct3D 11**: every 3D command goes into a deferred context; its command list enters the canvas's command stream
  before the canvas's next command, so 3D work runs in program order with the 2D work, on the render thread.
- **Direct3D 12**: the main thread records compact commands (target, clear, draw with its vertices, indices and
  changed constants, copy, resolve, texture upload, present) into the canvas's command stream; the render thread
  replays them into the canvas's command list. Pipeline state objects are cached by shaders, vertex layout, state and
  target format. With `Hdr` the target of a viewport is RGBA16F (see "HDR output").
- **Vulkan**: as Direct3D 12, replayed into the canvas's command buffer, with push descriptors (one set layout: the
  constants of both stages, eight texture units; without `VK_KHR_push_descriptor` a set of the recording context's
  descriptor pools per change, bound). FMX ships its shaders as Direct3D bytecode and GLSL ES sources;
  `tools/compile-fmx-shaders-vk.ps1` rewrites the GLSL into Vulkan GLSL with the uniforms of a stage in one block at
  the byte offsets of the Direct3D variables (matrices transposed; the few shaders whose GLSL computes otherwise than
  their bytecode patched), so the constants `FastCanvas.Context3D` lays out are the same bytes on every back end. The
  context finds a shader's SPIR-V by a hash of its GLSL and of its Direct3D variables; the include keeps those
  variables too, for the platforms without Direct3D sources (found by the GLSL alone there; the script checks that a
  source and stage has one layout). The SPIR-V targets Vulkan 1.1. A `TForm3D` draws into the frame surface of a
  canvas window, presented as the canvas's windows are.
- Bitmaps of the canvas are used in place as textures and render targets: a `TViewport3D` renders and copies its image
  into the form's bitmap on the GPU (the stock contexts read it back through the CPU), and the effects filter canvas
  bitmaps without leaving the GPU.
- **Raw draws** (`DrawRaw`, `CopyToTexture`, `ReadTarget`; USAGE.md): the program's shaders, vertex layout and full
  pipeline state. A raw draw is one more command of the stream (Direct3D 12) or of the deferred context (Direct3D 11):
  the pipeline state object (or the D3D11 state objects) cached by a hash of shaders, layout, state, topology, sample
  count and target format; geometry from memory is copied into the command and uploaded by the render thread
  (Direct3D 11: into a dynamic ring buffer of the deferred context), from a `TFastBuffer` it is bound in place; the
  constants are copied and bound as `b0`; textures and samplers as tables of eight. `TFastTexture` and `TFastBuffer` are objects of the installed context class; their
  uploads and writes are commands too, so they run in program order with the draws. FMX's cached state is marked dirty
  after a raw draw, so the next `DrawPrimitives` sets it again.

### Ray-traced effects (Direct3D 12 with DXR 1.1, Vulkan with ray queries)

While a scene with effects is recorded, every opaque object (triangles, depth test and write, float3 positions, drawn
in world space) is announced to the render thread with its matrix and, for reflections, its vertex layout and material
(read from the constants FMX's standard materials set: `MaterialDiffuse`, `MaterialSpecular`, `MaterialOpts`, ...).
The render thread builds a bottom-level acceleration structure once per geometry (identified by its vertex arrays and
a sample of positions; released after 300 passes unused) and, at the end of the scene, the top-level structure of
its instances. Full-screen passes then work from the depth buffer, with inline ray queries (shader model 6.5):

- **Shadows**: rays from each pixel's surface to every light (`TLightDescription`: directional, point, spot); hard
  shadows in one full-resolution pass, soft shadows with several rays per light over the light's disc.
- **Ambient occlusion**: rays over the hemisphere of the surface, up to a radius. Soft shadows and occlusion are traced
  at half resolution and smoothed and upsampled within surfaces (the depth buffer tells them apart).
- **Reflections**: a ray from the camera finds the object of the pixel, its material says how much it reflects, and a
  mirrored ray finds what it reflects, shaded as FMX shades its material (lights, shadows, textures; the scene's clear
  color where the ray leaves the scene). Each geometry keeps a copy of its vertices and indices for the normals and
  texture coordinates of the surfaces the rays hit.

The results multiply (shadows, occlusion) or blend (reflections) into the color FMX has drawn, so FMX's materials and
shaders are untouched. Off, the effects cost nothing: nothing is recorded or built.

On Vulkan (`FastCanvas.Context3DVk.Ray.inc`) the passes are the same HLSL, compiled to SPIR-V with ray queries. The
bottom-level structures are built from the vertices and indices the draw uploaded (device addresses in the upload
pages, which ray tracing gives the usages it needs), the geometry copies and material textures of reflections are
arrays of storage buffers and sampled images (descriptor indexing), and the descriptor sets of a scene's passes come
from a pool of their own that is retired with them.

**Application ray passes** use the same machinery: with `RayScene` on, the draws are announced to the render thread
with the program's attributes (mask, 24-bit user value in `InstanceContributionToHitGroupIndex`, optional geometry
key and version). `RayDispatch` and `RayDraw` record a command at their point of the stream; the render thread
builds the top-level structure if instances were added since the last pass, puts a UAV barrier, binds a fixed root
signature (frame constants, the program's constants, the structure, the depth buffer, the program's SRV and UAV
tables, four static samplers) and runs the program's compute or pixel shader, whose pipeline it made once and keeps.
Program buffers and images are GPU resources of the render thread; their writes are commands too, and after a device
loss they get new zeroed memory and a new `Generation`. Instances get `TRIANGLE_FRONT_COUNTERCLOCKWISE` when their
transform keeps orientation, so that a ray sees the same front face as the raster.

## Device loss

The render thread only records that the device is gone (`DXGI_ERROR_DEVICE_REMOVED` or `RESET` from `Present`,
`VK_ERROR_DEVICE_LOST`, or an exception on a removed device). The next scene that is not nested in another waits for
the render thread, sends `TContextLostMessage`, releases everything made on the old device, creates a new device,
recreates the bitmap textures (bitmaps the CPU wrote get their pixels back), sends `TContextResetMessage`, and repaints
the forms. The 3D contexts make their buffers again on the main thread before their next scene.
`FastCanvasSimulateDeviceLoss` exercises this path.

## Shutdown

FMX frees the forms, and with them canvases, bitmaps, text layouts and 3D contexts, after the unit finalizations
(`FinalizeForms` in the finalization of `FMX.Platform`), then unregisters the canvas classes, finalizes the shaders
and unregisters the context classes. The canvas service shuts the canvas down then (render thread, renderer, text
cache, the back end's recording context, the device), the context service the 3D contexts' shared objects; the
registries of live bitmaps go with their last entry when something outlives the service. The device and the
factories live on the heap, not in class variables: the finalization of `FastCanvas.Device` would release those
before the forms that still use them. With `ReportMemoryLeaksOnShutdown` nothing is reported (Direct3D 11 and 12, flip
and DirectComposition, 3D with ray-traced effects, a window recreated at run time). On Vulkan every object of the 3D
context is destroyed when the canvas's recording context shuts down (textures FMX frees later have nothing left to
release), before the device goes.

## Locks

- FMX's global canvas lock (`TCanvas.Lock`, from `BeginScene` to `EndScene`) serializes recording; the command
  stream relies on it.
- The device lock (the Direct2D multithread lock) guards the immediate context (Direct3D 11), the open command list
  (Direct3D 12) or command buffer (Vulkan) against other threads that need them (`TBitmap.Map`, texture uploads).
- Vulkan: submissions and presents take the queue lock (`TFastVulkan.LockQueue`); the threads presenting windows take
  it alone, never the device lock.
- `TContextResetMessage` is sent from whichever thread found the device loss; paths taken in its handlers (texture
  uploads) take the device lock only, never `TCanvas.Lock` (that deadlocked with a main thread holding it while
  waiting for FMX's message manager).
