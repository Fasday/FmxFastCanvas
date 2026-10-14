unit FastCanvas.Gpu;

{ GPU renderer of FastCanvas (stages 4-5): the part that does not depend on the graphics API. The devices
  (FastCanvas.Gpu11 for Direct3D 11, FastCanvas.Gpu12 for Direct3D 12) derive from the classes here.

  Primitives arrive as TGpuInstance records (written by the recording side) and are drawn in instanced runs by
  the shaders of Shaders\FastCanvas.hlsl: one draw call per run of instances that share the render target and at
  most eight textures. Clips, paints (gradients, bitmap brushes, dash patterns) and path edges are looked up by
  index in three tables that the recording side fills (SetClip, SetPaint, UploadEdges); gradient ramps and glyph
  bitmaps live in two shared textures. The renderer keeps the CPU side of the tables and uploads the changed
  ranges before every draw.

  Surfaces (TGpuSurface) are the premultiplied BGRA textures of TBitmap handles and window buffers; windows
  (TGpuWindow) are swap chains (of the window, or shown by DirectComposition: TGpuComposition) or, for transparent
  windows, a texture read back after every frame. A window is known by a TGpuWindowHandle: a Win32 window, an
  Android native window, an X11 window or a Wayland surface (FastCanvas.Platform). }

interface

uses
{$IFDEF MSWINDOWS}
  Winapi.Windows, Winapi.D2D1, System.SysUtils, System.Types, System.Math, FastCanvas.DWriteExt, FastCanvas.DCompExt,
  FastCanvas.Device;
{$ELSE}
  System.SysUtils, System.Types, System.Math, FastCanvas.Device;
{$ENDIF}

const
  // TGpuInstance.Flags
  GpuKindFillRect = 0;
  GpuKindStrokeRect = 1;
  GpuKindFillEllipse = 2;
  GpuKindStrokeEllipse = 3;
  GpuKindLine = 4;
  GpuKindImage = 5;
  GpuKindGlyph = 6;
  GpuKindSolid = 7;
  /// <summary>Filled polygon: U0 = first band header, V0 = band count (as Cardinal bits), U1 = 1 for even-odd.</summary>
  GpuKindPath = 8;
  GpuSlotShift = 4;
  GpuNearest = $80;
  GpuJoinShift = 8;   // 0 miter, 1 round, 2 bevel
  GpuCapShift = 10;   // 0 flat, 1 square, 2 round
  GpuCornerShift = 12; // 1 top-left, 2 top-right, 4 bottom-left, 8 bottom-right
  GpuDashed = $10000;  // lines: Paint is a dash pattern
  /// <summary>Glyphs: ClearType, three coverage texels per pixel (R, G, B) in the atlas; drawn with dual-source
  /// blending (TGpuRenderer.SetDualBlend).</summary>
  GpuClearType = $20000;
  /// <summary>Paths: hard edges (aliased text drawn as outlines).</summary>
  GpuAliased = $40000;
  /// <summary>Paths with pieces (TGpuRenderer.AddMesh): the back end may draw them instead of the quad. Not read by the
  /// shaders.</summary>
  GpuMesh = $80000;

  GpuMaxClips = 16384;
  GpuMaxPaints = 4096;
  GpuRampWidth = 256;
  GpuRampRows = 256;
  GpuAtlasSize = 2048;
  /// <summary>Entries of the path edge table (16 bytes each): it starts small and grows while one frame's paths do
  /// not fit (TGpuRenderer.ResizeEdges), up to the limit.</summary>
  GpuEdgesInitial = 256 * 1024;
  GpuEdgesLimit = 4 * 1024 * 1024;

  /// <summary>What the pixel shader needs for an instance (TGpuRenderer.InstanceNeeds), as the WITH_ switches of
  /// Shaders\FastCanvas.hlsl: a variant of the shader without some of them draws the instances that need none.
  /// </summary>
  GpuNeedShapes = $1;
  GpuNeedDashes = $2;
  GpuNeedImages = $4;
  GpuNeedGlyphs = $8;
  GpuNeedClearType = $10;
  GpuNeedPaths = $20;
  GpuNeedGradients = $40;
  GpuNeedBrushes = $80;
  GpuNeedClips = $100;
  GpuNeedAll = $1FF;

  GpuSlotCount = 8;
  GpuClipFloat4s = 5;
  GpuPaintFloat4s = 3;
  /// <summary>Bytes of an instance in the vertex buffer: the first 84 bytes of TGpuInstance are the shader's
  /// struct Instance, the texture pointer travels along unused.</summary>
  GpuInstanceStride = 84 + SizeOf(Pointer);

type
  TGpuSurface = class;

  /// <summary>Texture that instances sample (images, bitmap brushes): a TBitmap handle of the canvas, kept alive by
  /// the command chunk that references it.</summary>
  IGpuTexture = interface
    ['{8E2B1B43-7E8C-4E0E-9B0D-4C2F7A9E51A1}']
    /// <summary>The surface that holds the content: the 8-bit one, or the RGBA16F one after HdrTarget (render thread).
    /// </summary>
    function Surface: TGpuSurface;
  end;

  /// <summary>A TBitmap handle that can hold HDR content (Direct3D 12): an RGBA16F surface beside its 8-bit one, which
  /// an HDR 3D context writes into (a TViewport3D's bitmap). Render thread, in stream order.</summary>
  IGpuHdrTexture = interface
    ['{4D7C0E51-2B8A-4F7E-A0C3-6B1E9D2F5A84}']
    /// <summary>The RGBA16F surface (made on first use) the next write goes to: the content is there from now on.
    /// nil without one (Direct3D 11).</summary>
    function HdrTarget: TGpuSurface;
    /// <summary>The next write goes to the 8-bit surface and replaces the whole content (no conversion of what the
    /// RGBA16F surface held).</summary>
    procedure SdrTarget;
    /// <summary>HDR content into the 8-bit surface (clipped at 1; waits for the GPU), which holds the content from now
    /// on: before something draws over it. Nothing to do without HDR content.</summary>
    procedure Demote;
  end;

  PGpuInstance = ^TGpuInstance;
  /// <summary>One primitive. The first 84 bytes are the vertex buffer record of the shaders (keep in sync with
  /// struct Instance); Texture is used on the CPU only.</summary>
  TGpuInstance = packed record
    X0, Y0, X1, Y1: Single;   // shape rectangle in local space; lines: the two points
    M11, M12, M21, M22: Single;
    Dx, Dy: Single;
    Rx, Ry: Single;           // corner radii (rectangles)
    U0, V0, U1, V1: Single;   // texture coordinates of the rectangle corners (images, glyphs)
    Color: Cardinal;          // TAlphaColor, alpha already multiplied by the opacity
    Flags: Cardinal;
    Clip: Cardinal;
    Paint: Cardinal;          // paint index + 1, 0 = solid color
    Stroke: Single;           // stroke width, 0 = fill
    Texture: Pointer;         // IGpuTexture (not counted), else nil
  end;

  TGpuAffine = record
    M11, M12, M21, M22, Dx, Dy: Single;
    function Apply(const X, Y: Single): TPointF; inline;
    function Inverse: TGpuAffine;
  end;

  TGpuOrientedRect = record
    /// <summary>Clip-local to pixels and back; the clip area is [0, Width) x [0, Height) in clip-local units.</summary>
    Fwd, Inv: TGpuAffine;
    Width, Height: Single;
    /// <summary>The clip area is outside the rectangle (ExcludeClipRect).</summary>
    Exclude: Boolean;
  end;

  /// <summary>Pixels inside Box (pixel centers, right and bottom exclusive) and inside every oriented rectangle.</summary>
  TGpuClip = record
    Box: TRectF;
    Count: Integer;
    Oriented: array[0..1] of TGpuOrientedRect;
  end;
  PGpuClip = ^TGpuClip;

  /// <summary>Rectangles of target pixels (right and bottom exclusive), see TGpuRenderer.HollowBands.</summary>
  TGpuBands = array[0..3] of TRect;

  /// <summary>A paint (shader PaintColor, ImagePaint, DashedLineDistance): 12 floats, see the shader.</summary>
  TGpuPaint = record
    Data: array[0..11] of Single;
  end;

  /// <summary>Constants of the shaders (cbuffer Frame).</summary>
  TGpuFrameConstants = record
    ScaleX, ScaleY, Aliased, TextContrast: Single;
    Gamma: array[0..3] of Single;
    /// <summary>A frame that updates part of a window: its rectangles are the boxes of the clip entries
    /// RegionFirst..RegionFirst + RegionCount - 1, and pixels outside all of them are left alone (0: no region).
    /// </summary>
    RegionFirst, RegionCount: Cardinal;
    /// <summary>ClearType text: the enhanced contrast and the ClearType level of the system rendering parameters.
    /// </summary>
    ClearTypeContrast, ClearTypeLevel: Single;
  end;

  /// <summary>A premultiplied BGRA texture of the device, image source and render target: the content of a TBitmap
  /// handle, or a buffer of a window. Hdr: RGBA16F instead (the same sRGB-encoded premultiplied values, which may go
  /// above 1).</summary>
  TGpuSurface = class
  protected
    FWidth, FHeight: Integer;
    FHdr, FLinear: Boolean;
  public
    /// <summary>Replaces the content (rows of Width * 4 bytes, APitch apart).</summary>
    procedure Upload(const AData: Pointer; const APitch: Integer); virtual; abstract;
    /// <summary>The current content for the CPU to read and change in place until Unmap. The caller holds the
    /// device lock, and the render thread has executed everything that uses the surface.</summary>
    function Map(out AData: Pointer; out APitch: Integer): Boolean; virtual; abstract;
    /// <summary>AWritten: the CPU changed the pixels, which go back to the texture.</summary>
    procedure Unmap(const AWritten: Boolean); virtual; abstract;
    /// <summary>The content of a surface of the same size (in the order of the device's work).</summary>
    procedure CopyFrom(const ASource: TGpuSurface); virtual; abstract;
    /// <summary>The GPU drew into the surface: CPU copies of the content are stale.</summary>
    procedure GpuWritten; virtual;
    property Width: Integer read FWidth;
    property Height: Integer read FHeight;
    property Hdr: Boolean read FHdr;
    /// <summary>Hdr surface of a window in the measurement mode HdrLinearBlend: drawn and blended in linear light.
    /// </summary>
    property Linear: Boolean read FLinear write FLinear;
  end;

  /// <summary>How a window shows its frames.</summary>
  TGpuOutput = record
    /// <summary>An FP16 scRGB swap chain (HDR) instead of an 8-bit one.</summary>
    Hdr: Boolean;
    /// <summary>HDR: the scRGB value of SDR white (the display's SDR white level / 80 nits).</summary>
    WhiteScale: Single;
    /// <summary>HDR, measurement aid: the frame is drawn and blended in linear light (TFastCanvasOption.HdrLinearBlend).
    /// </summary>
    Linear: Boolean;
    /// <summary>A composition swap chain shown by DirectComposition, whose premultiplied alpha lets what is behind
    /// show through (DWM backdrops such as Mica with the frame extended into the client area), instead of a swap
    /// chain of the window, which DWM shows opaque (TFastCanvasPresentation).</summary>
    Composition: Boolean;
  end;

  /// <summary>A window of the platform as the backends present to it (FastCanvas.Platform makes it).</summary>
  TGpuWindowHandle = record
    /// <summary>Windows: the HWND. Android: the ANativeWindow (a reference the canvas target holds). Linux: the X11
    /// window (XID), or the wl_surface when Wayland.</summary>
    Window: NativeUInt;
    /// <summary>Linux: the X11 Display, or the wl_display when Wayland; else nil.</summary>
    Display: Pointer;
    /// <summary>Linux on FMXWayland: Window and Display are Wayland's (VK_KHR_wayland_surface), and the platform
    /// stops showing frames of its own in the window while the handle is held (FastCanvas.Platform).</summary>
    Wayland: Boolean;
    /// <summary>Wayland: the FMX window handle (TWindowHandle) the surface belongs to, which outlives this handle.
    /// </summary>
    Owner: TObject;
  end;

{$IFDEF MSWINDOWS}
  /// <summary>DirectComposition binding of a window: a device, a target on the window and one visual that shows a
  /// composition swap chain, above the window's own (GDI) content and below its child windows. Render thread.
  /// </summary>
  TGpuComposition = class
  private
    FDevice: IDCompositionDevice;
    FTarget: IDCompositionTarget;
    FVisual: IDCompositionVisual;
  public
    /// <summary>Binds the window. False when DirectComposition cannot (the window then takes a swap chain of its
    /// own).</summary>
    function Bind(const AWnd: HWND): Boolean;
    /// <summary>What the visual shows (a composition swap chain; nil: nothing), applied at once.</summary>
    procedure SetContent(const AContent: IUnknown);
    /// <summary>Unbinds the window (it can be bound again right after).</summary>
    destructor Destroy; override;
    /// <summary>Fills the window's own (GDI) surface, which shows under the visual where the frame is transparent,
    /// with black through GDI: transparent where the frame is extended into the client area (GDI writes alpha 0),
    /// black elsewhere, as the stock Direct2D canvas leaves it. A new or resized window surface is white or
    /// undefined. Sends no messages (safe on the render thread).</summary>
    class procedure ClearWindow(const AWnd: HWND); static;
  end;
{$ENDIF}

  /// <summary>The pixels of the frame a window shows (FastCanvasCaptureWindow): four floats per pixel, R, G, B, A;
  /// scRGB (linear, 1.0 = 80 nits) for HDR output, sRGB-encoded 0..1 for SDR output.</summary>
  TGpuCapture = record
    Width, Height: Integer;
    Hdr: Boolean;
    Pixels: TArray<Single>;
  end;

  /// <summary>The output of a window: a flip-model swap chain (of the window, or a composition one shown by
  /// DirectComposition: TGpuOutput.Composition), or (transparent windows) a texture whose pixels go to the layered
  /// window buffer after every frame. Render thread only.</summary>
  TGpuWindow = class
  protected
    FHandle: TGpuWindowHandle;
{$IFDEF MSWINDOWS}
    FWnd: HWND;
{$ENDIF}
    FLayered: Boolean;
    FHdr: Boolean;
  public
    constructor Create(const AHandle: TGpuWindowHandle; const ALayered: Boolean); virtual;
    /// <summary>At the start of a frame: the surface to draw into, resized or recreated as needed (also when the
    /// output changes between SDR and HDR: the surface is Hdr then).</summary>
    function Prepare(const AWidth, AHeight: Integer; const ATearing: Boolean; const AOutput: TGpuOutput): TGpuSurface;
      virtual; abstract;
    /// <summary>Swap chains: shows the frame; the HResult of Present.</summary>
    function Present: HResult; virtual; abstract;
    /// <summary>Layered windows: the pixels of the frame into ABits (rows of AWidth * 4 bytes).</summary>
    procedure ReadPixels(const ABits: Pointer; const AWidth, AHeight: Integer); virtual; abstract;
    /// <summary>After Prepare: the frame presented last into the surface of this frame, which then updates part of
    /// the window. False when there is no such frame (a new or resized swap chain, a layered window, no support):
    /// the frame has to draw the whole window.</summary>
    function RestoreLast: Boolean; virtual;
    /// <summary>Diagnostics: the frame presented last. The device lock is held and the render thread is idle. False
    /// when there is none or the backend cannot.</summary>
    function Capture(out ACapture: TGpuCapture): Boolean; virtual;
    /// <summary>The platform is about to unmap the window (Wayland: a role object that must see no buffer until the
    /// compositor configures it again): nothing is presented to it from now until the next frame is prepared. The
    /// device lock is held and the render thread is idle (main thread).</summary>
    procedure Suspend; virtual;
    /// <summary>The window's handle.</summary>
    property Handle: TGpuWindowHandle read FHandle;
    /// <summary>The swap chain is FP16 scRGB now.</summary>
    property Hdr: Boolean read FHdr;
  end;

  TGpuRenderer = class
  protected
    FClipData: TArray<TGpuClip>;
    FClipLo, FClipHi: Integer;
    FPaintData: TArray<TGpuPaint>;
    FPaintLo, FPaintHi: Integer;
    // Edges uploaded since the last draw: entries FEdgeLo..FEdgeHi - 1 of the table, staged from FEdgeData[0].
    FEdgeData: TArray<Single>;
    FEdgeLo, FEdgeHi: Integer;
    FEdgeCapacity: Integer;
    FSlotTex: array[0..GpuSlotCount - 1] of Pointer;
    FSlotCount: Integer;
    FPending: TArray<TGpuInstance>;
    FPendingCount: Integer;
    FTarget: TGpuSurface;
    FWidth, FHeight: Integer;
    FAliased: Boolean;
    FFrameDirty: Boolean;
    FTextContrast, FClearTypeContrast, FClearTypeLevel: Single;
    FGammaRatios: array[0..3] of Single;
    /// <summary>The draws use dual-source blending (ClearType text in the frame of a window).</summary>
    FDual: Boolean;
    FDrawCalls: Integer;
    FRegionFirst, FRegionCount: Cardinal;
    // Shader data of the changed clip entries (reused: the render thread must not allocate per draw).
    FClipStage: TArray<Single>;
    FBandPixels: Single;
    FPathMeshes: Boolean;
    /// <summary>The pixels the draws may change (SetScissor); empty: the whole target.</summary>
    FScissor: TRect;
    procedure ReadTextParameters;
    function TextureSlot(const ATexture: Pointer): Integer;
    function FrameConstants: TGpuFrameConstants;
    /// <summary>The changed clip entries AFirst..AFirst + ACount - 1 as shader data (GpuClipFloat4s float4 each), nil
    /// when none changed. Valid until the next call; resets the changed range.</summary>
    function TakeClips(out AFirst, ACount: Integer): PSingle;
    /// <summary>The changed range of the paint table (AFirst..AFirst + ACount - 1); resets it.</summary>
    function TakePaints(out AFirst, ACount: Integer): Boolean;
    /// <summary>What the pixel shader needs to draw a pending instance (GpuNeed*), with the tables as the draw sees
    /// them; AArea: about how many pixels its quad covers. GpuNeedClips is left out when no pixel of the quad can be
    /// outside the clip (ClipFactor would be 1 everywhere).</summary>
    function InstanceNeeds(const AInstance: PGpuInstance; out AArea: Single): Cardinal;
    /// <summary>A rectangle outline (axis-aligned on the target) with an inside where the shader computes no coverage
    /// at all: up to four disjoint rectangles of the target around that inside (ACount), so that the draws of the
    /// instance in each (scissors: the same triangles, the same values at every pixel) leave out pixels that would
    /// not change; AArea: how many. False for other instances and outlines without such an inside.</summary>
    function HollowBands(const AInstance: PGpuInstance; out ABands: TGpuBands; out ACount: Integer;
      out AArea: Single): Boolean;
    /// <summary>Device: draws the pending instances with the bound slot textures (uploads the tables first).</summary>
    procedure DrawPending; virtual; abstract;
    /// <summary>Device: the staged edges (FEdgeLo..FEdgeHi from FEdgeData[0]) into the edge table; then resets the
    /// range.</summary>
    procedure UploadEdgeRange; virtual; abstract;
    /// <summary>Device: a new, empty edge table of ACapacity entries.</summary>
    procedure CreateEdgeTable(const ACapacity: Integer); virtual; abstract;
  public
    constructor Create;
    destructor Destroy; override;
    /// <summary>Sets the render target of the following instances (draws the previous target's first); nil
    /// unbinds.</summary>
    procedure BeginTarget(const ATarget: TGpuSurface; const AWidth, AHeight: Integer;
      const AAliased: Boolean); virtual;
    procedure EndTarget;
    /// <summary>The rectangles a partial window frame updates: the boxes of clip entries AFirst..AFirst + ACount - 1
    /// (set before); ACount = 0: the whole target. Draws what is pending first.</summary>
    procedure SetRegion(const AFirst, ACount: Cardinal);
    /// <summary>The following draws change no pixel outside ARect (target pixels; empty: the whole target): the
    /// partial frame of a window, whose rectangles are inside it. Back ends that can leave the pixels outside out of
    /// their draws (a scissor) do; the clip test of an instance is not needed then where its clip leaves out only
    /// pixels outside. Draws what is pending first when it changes.</summary>
    procedure SetScissor(const ARect: TRect);
    /// <summary>The following draws blend with a second color output of the pixel shader: per-channel weights,
    /// which ClearType glyphs (GpuClearType) need and which equal the alpha for everything else. Draws what is
    /// pending first when it changes.</summary>
    procedure SetDualBlend(const AValue: Boolean); virtual;
    procedure Add(AData: PGpuInstance; const ACount: Integer);
    /// <summary>One more pending instance without a texture, to be filled by the caller (valid until the next Add,
    /// Append or Flush).</summary>
    function Append: PGpuInstance; inline;
    /// <summary>Flags of an instance with the slot of a texture set (may draw what is pending first: call it before
    /// Append).</summary>
    function WithTexture(const AFlags: Cardinal; const ATexture: Pointer): Cardinal;
    /// <summary>Draws everything added so far and frees the texture slots.</summary>
    procedure Flush; virtual;
    /// <summary>Someone else used the device context: set the pipeline state again before the next draw.</summary>
    procedure Invalidate; virtual;
    /// <summary>Fills the whole target (no clip, no blending).</summary>
    procedure Clear(const AColor: Cardinal); virtual; abstract;
    /// <summary>Replaces the pixels of a device-space rectangle inside a clip (no blending).</summary>
    procedure FillCopy(const ARect: TRectF; const AColor: Cardinal; const AClip: Cardinal); virtual; abstract;
    procedure SetClip(const AIndex: Integer; const AClip: TGpuClip);
    function Clip(const AIndex: Integer): PGpuClip; inline;
    procedure SetPaint(const AIndex: Integer; const APaint: TGpuPaint);
    /// <summary>A row of the ramp texture (GpuRampWidth RGBA pixels).</summary>
    procedure UploadRamp(const ARow: Integer; const AData: Pointer); virtual; abstract;
    /// <summary>A rectangle of the glyph atlas (8-bit coverage).</summary>
    procedure UploadGlyph(const X, Y, W, H: Integer; const AData: Pointer; const APitch: Integer); virtual; abstract;
    /// <summary>Path edges (4 Singles each) at an index of the edge table.</summary>
    procedure UploadEdges(const AStart, ACount: Integer; const AData: Pointer);
    /// <summary>Replaces the edge table with an empty one of another size (draws what is pending first).</summary>
    procedure ResizeEdges(const ACapacity: Integer);
    property EdgeCapacity: Integer read FEdgeCapacity;
    /// <summary>Paths: bands of the edge table at most this many pixels tall (0: a band per six edges), where the
    /// back end shades a path's pixels slowly (phones): fewer edges per pixel, more entries in the table.</summary>
    property BandPixels: Single read FBandPixels;
    /// <summary>The instance appended last is a path, and these are its pieces (FastCanvas.PathMesh: ACover cover
    /// pieces, then ASolid solid ones, six floats each, in its local space): the back end may draw them instead of the
    /// quad (PathMeshes). Nothing by default.</summary>
    procedure AddMesh(const APieces: Pointer; const ACover, ASolid: Integer); virtual;
    /// <summary>The back end draws paths by their pieces where it can: the canvas makes them (AddMesh).</summary>
    property PathMeshes: Boolean read FPathMeshes;
    property Target: TGpuSurface read FTarget;
    property DrawCalls: Integer read FDrawCalls write FDrawCalls;
  end;

  /// <summary>The objects of one graphics API (TFastDevice.Backend). Surfaces are made on any thread; the renderer
  /// and windows are used on the render thread; everything else happens with the device lock held.</summary>
  TGpuBackend = class abstract
  public
    class function CreateRenderer: TGpuRenderer; virtual; abstract;
    /// <summary>AData: the initial pixels (rows of AWidth * 4 bytes, APitch apart), nil for transparent black.
    /// </summary>
    class function CreateSurface(const AWidth, AHeight: Integer; const AData: Pointer;
      const APitch: Integer): TGpuSurface; virtual; abstract;
    /// <summary>An RGBA16F surface (transparent black), nil when the backend has none (Direct3D 11).</summary>
    class function CreateHdrSurface(const AWidth, AHeight: Integer): TGpuSurface; virtual;
    class function CreateWindow(const AHandle: TGpuWindowHandle; const ALayered: Boolean): TGpuWindow; virtual;
      abstract;
    /// <summary>Hands the recorded work to the GPU (Direct3D 12: the open command list).</summary>
    class procedure Submit; virtual;
    /// <summary>Waits until the GPU has executed everything recorded so far.</summary>
    class procedure WaitIdle; virtual; abstract;
    /// <summary>Releases the backend's own objects, before the device is released or replaced. Surfaces, windows and
    /// the renderer are gone already.</summary>
    class procedure Shutdown; virtual;
  end;
  TGpuBackendClass = class of TGpuBackend;

procedure GpuCheck(const ARes: HResult; const AWhat: string);
/// <summary>An IEEE half-precision float (RGBA16F texels).</summary>
function GpuHalfToSingle(const AHalf: Word): Single;
/// <summary>A premultiplied RGBA16F texel (sRGB-encoded, may exceed 1) as premultiplied BGRA bytes, clipped at 1.
/// </summary>
function GpuHalfTexelToBgra(const ATexel: PWord): Cardinal;

implementation

procedure GpuCheck(const ARes: HResult; const AWhat: string);
begin
  if ARes < 0 then
    raise EFastDevice.CreateFmt('FastCanvas: %s failed (0x%.8x)', [AWhat, Cardinal(ARes)]);
end;

function GpuHalfToSingle(const AHalf: Word): Single;
var
  Sign, Exponent, Mantissa, Bits: Cardinal;
begin
  Sign := (AHalf shr 15) and 1;
  Exponent := (AHalf shr 10) and $1F;
  Mantissa := AHalf and $3FF;
  if Exponent = 0 then
  begin
    // Zero and subnormals: Mantissa * 2^-24.
    Result := Mantissa * (1 / 16777216);
    if Sign <> 0 then
      Result := -Result;
    Exit;
  end;
  if Exponent = 31 then
    Bits := (Sign shl 31) or $7F800000 or (Mantissa shl 13)
  else
    Bits := (Sign shl 31) or ((Exponent + 112) shl 23) or (Mantissa shl 13);
  Result := PSingle(@Bits)^;
end;

function GpuHalfTexelToBgra(const ATexel: PWord): Cardinal;

  function Byte8(const AHalf: Word): Cardinal; inline;
  var
    V: Single;
  begin
    V := GpuHalfToSingle(AHalf);
    if not (V > 0) then
      Result := 0
    else if V >= 1 then
      Result := 255
    else
      Result := Round(V * 255);
  end;

var
  P: PByte;
begin
  P := PByte(ATexel);
  Result := Byte8(PWord(P + 4)^) or (Byte8(PWord(P + 2)^) shl 8) or (Byte8(PWord(P)^) shl 16) or
    (Byte8(PWord(P + 6)^) shl 24);
end;

{ TGpuAffine }

function TGpuAffine.Apply(const X, Y: Single): TPointF;
begin
  Result.X := X * M11 + Y * M21 + Dx;
  Result.Y := X * M12 + Y * M22 + Dy;
end;

function TGpuAffine.Inverse: TGpuAffine;
var
  Det: Double;
begin
  Det := M11 * M22 - M12 * M21;
  if Abs(Det) < 1E-12 then
    Det := 1E-12;
  Result.M11 := M22 / Det;
  Result.M12 := -M12 / Det;
  Result.M21 := -M21 / Det;
  Result.M22 := M11 / Det;
  Result.Dx := -(Dx * Result.M11 + Dy * Result.M21);
  Result.Dy := -(Dx * Result.M12 + Dy * Result.M22);
end;

{ TGpuSurface }

procedure TGpuSurface.GpuWritten;
begin
end;

{ TGpuWindow }

constructor TGpuWindow.Create(const AHandle: TGpuWindowHandle; const ALayered: Boolean);
begin
  inherited Create;
  FHandle := AHandle;
{$IFDEF MSWINDOWS}
  FWnd := HWND(AHandle.Window);
{$ENDIF}
  FLayered := ALayered;
end;

function TGpuWindow.RestoreLast: Boolean;
begin
  Result := False;
end;

function TGpuWindow.Capture(out ACapture: TGpuCapture): Boolean;
begin
  ACapture := Default(TGpuCapture);
  Result := False;
end;

procedure TGpuWindow.Suspend;
begin
end;

{$IFDEF MSWINDOWS}
{ TGpuComposition }

function TGpuComposition.Bind(const AWnd: HWND): Boolean;
begin
  if FVisual <> nil then
    Exit(True);
  try
    // No rendering device: the content is a swap chain made by DXGI, not a DirectComposition surface.
    Result := Succeeded(DCompositionCreateDevice2(nil, IDCompositionDevice, FDevice)) and
      // Below the child windows (native controls such as a web browser stay visible).
      Succeeded(FDevice.CreateTargetForHwnd(AWnd, False, FTarget)) and
      Succeeded(FDevice.CreateVisual(FVisual)) and
      Succeeded(FTarget.SetRoot(FVisual));
  except
    // dcomp.dll missing (delay-loaded).
    Result := False;
  end;
  if not Result then
  begin
    FVisual := nil;
    FTarget := nil;
    FDevice := nil;
  end;
end;

procedure TGpuComposition.SetContent(const AContent: IUnknown);
begin
  if FVisual = nil then
    Exit;
  FVisual.SetContent(AContent);
  FDevice.Commit;
end;

class procedure TGpuComposition.ClearWindow(const AWnd: HWND);
var
  DC: HDC;
  R: TRect;
begin
  if not GetClientRect(AWnd, R) then
    Exit;
  DC := GetDC(AWnd);
  if DC = 0 then
    Exit;
  try
    FillRect(DC, R, GetStockObject(BLACK_BRUSH));
  finally
    ReleaseDC(AWnd, DC);
  end;
end;

destructor TGpuComposition.Destroy;
begin
  if FTarget <> nil then
  begin
    FVisual.SetContent(nil);
    FTarget.SetRoot(nil);
    FDevice.Commit;
    // The window is free for a new target only once DWM has processed this.
    FDevice.WaitForCommitCompletion;
  end;
  FVisual := nil;
  FTarget := nil;
  FDevice := nil;
  inherited;
end;
{$ENDIF}

{ TGpuBackend }

class function TGpuBackend.CreateHdrSurface(const AWidth, AHeight: Integer): TGpuSurface;
begin
  Result := nil;
end;

class procedure TGpuBackend.Submit;
begin
end;

class procedure TGpuBackend.Shutdown;
begin
end;

{ TGpuRenderer }

constructor TGpuRenderer.Create;
begin
  inherited Create;
  ReadTextParameters;
  FFrameDirty := True;
  SetLength(FPending, 4096);
  SetLength(FClipData, GpuMaxClips);
  SetLength(FPaintData, GpuMaxPaints);
  // Clip 0: no clip.
  FClipData[0].Box := TRectF.Create(-1E9, -1E9, 1E9, 1E9);
  FClipData[0].Count := 0;
  FClipLo := 0;
  FClipHi := 1;
  FPaintLo := MaxInt;
  FPaintHi := 0;
  FEdgeLo := 0;
  FEdgeHi := 0;
end;

destructor TGpuRenderer.Destroy;
begin
  FPending := nil;
  inherited;
end;

/// <summary>Text gamma and grayscale contrast of the system rendering parameters ("Adjust ClearType text"),
/// turned into the alpha correction ratios of the shader's TextAlpha. Table and normalization as in Microsoft
/// Terminal's DWrite_GetGammaRatios (src/renderer/atlas/dwrite_helpers.cpp, MIT license).</summary>
procedure TGpuRenderer.ReadTextParameters;
const
  Ratios: array[0..12, 0..3] of Single = (
    (0.0000, 0.0000, 0.0000, 0.0000), (0.0166, -0.0807, 0.2227, -0.0751), (0.0350, -0.1760, 0.4325, -0.1370),
    (0.0543, -0.2821, 0.6302, -0.1876), (0.0739, -0.3963, 0.8167, -0.2287), (0.0933, -0.5161, 0.9926, -0.2616),
    (0.1121, -0.6395, 1.1588, -0.2877), (0.1300, -0.7649, 1.3159, -0.3080), (0.1469, -0.8911, 1.4644, -0.3234),
    (0.1627, -1.0170, 1.6051, -0.3347), (0.1773, -1.1420, 1.7385, -0.3426), (0.1908, -1.2652, 1.8650, -0.3476),
    (0.2031, -1.3864, 1.9851, -0.3501));
  Norm13 = 65536 / (255 * 255) * 4;
  Norm24 = 256 / 255 * 4;
var
{$IFDEF MSWINDOWS}
  Params: IDWriteRenderingParams;
  Params1: IDWriteRenderingParams1;
{$ENDIF}
  Gamma: Single;
  Index: Integer;
begin
  Gamma := 1.8;
  FTextContrast := 1;
  FClearTypeContrast := 1;
  FClearTypeLevel := 1;
{$IFDEF MSWINDOWS}
  if (TFastDevice.DWrite <> nil) and Succeeded(TFastDevice.DWrite.CreateRenderingParams(Params)) and (Params <> nil) then
  begin
    Gamma := Params.GetGamma;
    FClearTypeContrast := Params.GetEnhancedContrast;
    FClearTypeLevel := EnsureRange(Params.GetClearTypeLevel, 0, 1);
    if Supports(Params, IDWriteRenderingParams1, Params1) then
      FTextContrast := Params1.GetGrayscaleEnhancedContrast
    else
      FTextContrast := Params.GetEnhancedContrast;
  end;
{$ENDIF}
  Index := EnsureRange(Trunc(Gamma * 10 + 0.5), 10, 22) - 10;
  FGammaRatios[0] := Norm13 * Ratios[Index, 0] / 4;
  FGammaRatios[1] := Norm24 * Ratios[Index, 1] / 4;
  FGammaRatios[2] := Norm13 * Ratios[Index, 2] / 4;
  FGammaRatios[3] := Norm24 * Ratios[Index, 3] / 4;
end;

function TGpuRenderer.FrameConstants: TGpuFrameConstants;
begin
  Result.ScaleX := 2 / Max(FWidth, 1);
  Result.ScaleY := -2 / Max(FHeight, 1);
  Result.Aliased := Ord(FAliased);
  Result.TextContrast := FTextContrast;
  Move(FGammaRatios, Result.Gamma, SizeOf(Result.Gamma));
  Result.RegionFirst := FRegionFirst;
  Result.RegionCount := FRegionCount;
  Result.ClearTypeContrast := FClearTypeContrast;
  Result.ClearTypeLevel := FClearTypeLevel;
end;

procedure TGpuRenderer.SetDualBlend(const AValue: Boolean);
begin
  if AValue = FDual then
    Exit;
  Flush;
  FDual := AValue;
end;

procedure TGpuRenderer.SetRegion(const AFirst, ACount: Cardinal);
begin
  if (AFirst = FRegionFirst) and (ACount = FRegionCount) then
    Exit;
  Flush;
  FRegionFirst := AFirst;
  FRegionCount := ACount;
  FFrameDirty := True;
end;

procedure TGpuRenderer.SetScissor(const ARect: TRect);
begin
  if ARect = FScissor then
    Exit;
  Flush;
  FScissor := ARect;
end;

procedure TGpuRenderer.Invalidate;
begin
end;

procedure TGpuRenderer.AddMesh(const APieces: Pointer; const ACover, ASolid: Integer);
begin
end;

procedure TGpuRenderer.BeginTarget(const ATarget: TGpuSurface; const AWidth, AHeight: Integer;
  const AAliased: Boolean);
begin
  if (ATarget = FTarget) and (AWidth = FWidth) and (AHeight = FHeight) and (AAliased = FAliased) then
    Exit;
  Flush;
  FTarget := ATarget;
  if (AWidth <> FWidth) or (AHeight <> FHeight) or (AAliased <> FAliased) then
    FFrameDirty := True;
  FWidth := AWidth;
  FHeight := AHeight;
  FAliased := AAliased;
end;

procedure TGpuRenderer.EndTarget;
begin
  Flush;
end;

function TGpuRenderer.TextureSlot(const ATexture: Pointer): Integer;
var
  I: Integer;
begin
  for I := 0 to FSlotCount - 1 do
    if FSlotTex[I] = ATexture then
      Exit(I);
  if FSlotCount = Length(FSlotTex) then
  begin
    DrawPending;
    FSlotCount := 0;
  end;
  Result := FSlotCount;
  FSlotTex[Result] := ATexture;
  Inc(FSlotCount);
end;

procedure TGpuRenderer.Add(AData: PGpuInstance; const ACount: Integer);
var
  I, Slot: Integer;
  P: PGpuInstance;
begin
  if FPendingCount + ACount > Length(FPending) then
    SetLength(FPending, Max(FPendingCount + ACount, 2 * Length(FPending)));
  for I := 0 to ACount - 1 do
  begin
    if AData.Texture <> nil then
    begin
      Slot := TextureSlot(AData.Texture);
      P := @FPending[FPendingCount];
      P^ := AData^;
      P.Flags := (P.Flags and not (7 shl GpuSlotShift)) or (Cardinal(Slot) shl GpuSlotShift);
    end
    else
      FPending[FPendingCount] := AData^;
    Inc(FPendingCount);
    Inc(AData);
  end;
end;

function TGpuRenderer.WithTexture(const AFlags: Cardinal; const ATexture: Pointer): Cardinal;
begin
  Result := (AFlags and not (7 shl GpuSlotShift)) or (Cardinal(TextureSlot(ATexture)) shl GpuSlotShift);
end;

function TGpuRenderer.Append: PGpuInstance;
begin
  if FPendingCount = Length(FPending) then
    SetLength(FPending, 2 * Length(FPending));
  Result := @FPending[FPendingCount];
  Inc(FPendingCount);
end;

procedure TGpuRenderer.Flush;
var
  I: Integer;
begin
  DrawPending;
  for I := 0 to FSlotCount - 1 do
    FSlotTex[I] := nil;
  FSlotCount := 0;
end;

procedure TGpuRenderer.SetClip(const AIndex: Integer; const AClip: TGpuClip);
begin
  FClipData[AIndex] := AClip;
  if AIndex < FClipLo then
    FClipLo := AIndex;
  if AIndex + 1 > FClipHi then
    FClipHi := AIndex + 1;
end;

function TGpuRenderer.Clip(const AIndex: Integer): PGpuClip;
begin
  Result := @FClipData[AIndex];
end;

procedure TGpuRenderer.SetPaint(const AIndex: Integer; const APaint: TGpuPaint);
begin
  FPaintData[AIndex] := APaint;
  if AIndex < FPaintLo then
    FPaintLo := AIndex;
  if AIndex + 1 > FPaintHi then
    FPaintHi := AIndex + 1;
end;

function TGpuRenderer.TakeClips(out AFirst, ACount: Integer): PSingle;
var
  I, J, K: Integer;
  C: PGpuClip;
  D: TArray<Single>;
begin
  AFirst := FClipLo;
  ACount := FClipHi - FClipLo;
  if ACount <= 0 then
  begin
    ACount := 0;
    Exit(nil);
  end;
  if Length(FClipStage) < ACount * GpuClipFloat4s * 4 then
    SetLength(FClipStage, Max(ACount * GpuClipFloat4s * 4, 2 * Length(FClipStage)));
  D := FClipStage;
  for I := 0 to ACount - 1 do
  begin
    C := @FClipData[FClipLo + I];
    K := I * GpuClipFloat4s * 4;
    D[K + 0] := C.Box.Left;
    D[K + 1] := C.Box.Top;
    D[K + 2] := C.Box.Right;
    D[K + 3] := C.Box.Bottom;
    Inc(K, 4);
    for J := 0 to 1 do
    begin
      if J < C.Count then
      begin
        D[K + 0] := C.Oriented[J].Inv.M11;
        D[K + 1] := C.Oriented[J].Inv.M12;
        D[K + 2] := C.Oriented[J].Inv.M21;
        D[K + 3] := C.Oriented[J].Inv.M22;
        D[K + 4] := C.Oriented[J].Inv.Dx;
        D[K + 5] := C.Oriented[J].Inv.Dy;
        D[K + 6] := C.Oriented[J].Width;
        if C.Oriented[J].Exclude then
          D[K + 7] := -1 - C.Oriented[J].Height
        else
          D[K + 7] := C.Oriented[J].Height;
      end
      else
      begin
        FillChar(D[K], 8 * SizeOf(Single), 0);
        D[K + 6] := -1;
      end;
      Inc(K, 8);
    end;
  end;
  FClipLo := MaxInt;
  FClipHi := 0;
  Result := @FClipStage[0];
end;

function TGpuRenderer.TakePaints(out AFirst, ACount: Integer): Boolean;
begin
  Result := FPaintHi > FPaintLo;
  AFirst := FPaintLo;
  ACount := FPaintHi - FPaintLo;
  FPaintLo := MaxInt;
  FPaintHi := 0;
end;

function TGpuRenderer.InstanceNeeds(const AInstance: PGpuInstance; out AArea: Single): Cardinal;
var
  P: PGpuInstance;
  Kind: Cardinal;
  C: PGpuClip;
  W, H, A11, A12, A21, A22, S, Det, Hx, Hy, E, X, Y, X0, X1, Y0, Y1: Single;
begin
  P := AInstance;
  Kind := P.Flags and 15;
  case Kind of
    GpuKindFillRect, GpuKindStrokeRect, GpuKindFillEllipse, GpuKindStrokeEllipse, GpuKindSolid:
      Result := GpuNeedShapes;
    GpuKindLine:
      if (P.Flags and GpuDashed) <> 0 then
        Result := GpuNeedShapes or GpuNeedDashes
      else
        Result := GpuNeedShapes;
    GpuKindImage:
      Result := GpuNeedImages;
    GpuKindGlyph:
      if (P.Flags and GpuClearType) <> 0 then
        Result := GpuNeedClearType
      else
        Result := GpuNeedGlyphs;
    GpuKindPath:
      Result := GpuNeedPaths;
  else
    Result := GpuNeedAll;
  end;
  // The paint of shapes and paths (of lines it is a dash pattern; images and glyphs have none), of the kind the
  // shader tells by its last float.
  if (P.Paint <> 0) and (Kind <> GpuKindLine) and (Kind <> GpuKindImage) and (Kind <> GpuKindGlyph) then
    if P.Paint > Cardinal(Length(FPaintData)) then
      Result := GpuNeedAll
    else if FPaintData[P.Paint - 1].Data[11] > 2.5 then
      Result := Result or GpuNeedBrushes
    else
      Result := Result or GpuNeedGradients;
  // Device bounds of the shape's rectangle (of a line: of its segment), and a margin beyond them that the quad does
  // not reach: the stroke, the antialiasing ring of a pixel in local units, a line's caps. S is at least the larger
  // scale of the matrix, S / Det at least one over the smaller one.
  A11 := Abs(P.M11);
  A12 := Abs(P.M12);
  A21 := Abs(P.M21);
  A22 := Abs(P.M22);
  W := Abs(P.X1 - P.X0);
  H := Abs(P.Y1 - P.Y0);
  Hx := (A11 * W + A21 * H) * 0.5;
  Hy := (A12 * W + A22 * H) * 0.5;
  S := Max(A11 + A12, A21 + A22);
  Det := Abs(P.M11 * P.M22 - P.M12 * P.M21);
  if Kind = GpuKindLine then
  begin
    E := 2 * S * (Abs(P.Stroke) + 2 * S / Max(Det, 1E-12)) + 2;
    AArea := 2 * (Hx + Hy) * (Abs(P.Stroke) * S + 2);
  end
  else
  begin
    E := Abs(P.Stroke) * S + 3;
    AArea := Det * W * H;
  end;
  // The clip test passes for every pixel of the quad: in its box, which has no rectangles in it, in a frame of the
  // whole target. (NaN bounds take the test.)
  if FRegionCount <> 0 then
    Exit(Result or GpuNeedClips);
  if P.Clip >= Cardinal(Length(FClipData)) then
    Exit(Result or GpuNeedClips);
  C := @FClipData[P.Clip];
  if C.Count <> 0 then
    Exit(Result or GpuNeedClips);
  X := (P.X0 + P.X1) * 0.5;
  Y := (P.Y0 + P.Y1) * 0.5;
  W := X * P.M11 + Y * P.M21 + P.Dx;
  H := X * P.M12 + Y * P.M22 + P.Dy;
  // The bounds of the pixels the quad can reach, within the scissor (the GPU leaves the others out).
  X0 := W - Hx - E;
  X1 := W + Hx + E;
  Y0 := H - Hy - E;
  Y1 := H + Hy + E;
  if not FScissor.IsEmpty then
  begin
    // Its first and last pixel centers.
    X0 := Max(X0, FScissor.Left + 0.5);
    X1 := Min(X1, FScissor.Right - 0.5);
    Y0 := Max(Y0, FScissor.Top + 0.5);
    Y1 := Min(Y1, FScissor.Bottom - 0.5);
  end;
  if not ((X0 >= C.Box.Left) and (X1 < C.Box.Right) and (Y0 >= C.Box.Top) and (Y1 < C.Box.Bottom)) then
    Result := Result or GpuNeedClips;
end;

function TGpuRenderer.HollowBands(const AInstance: PGpuInstance; out ABands: TGpuBands; out ACount: Integer;
  out AArea: Single): Boolean;
var
  P: PGpuInstance;
  Sx, Sy, G, Hs, Bx, By, Ox, Oy, X, Y: Single;
  Outer, Inner: TRect;

  procedure Band(const ALeft, ATop, ARight, ABottom: Integer);
  begin
    if (ARight > ALeft) and (ABottom > ATop) then
    begin
      ABands[ACount] := TRect.Create(ALeft, ATop, ARight, ABottom);
      Inc(ACount);
    end;
  end;

begin
  Result := False;
  ACount := 0;
  AArea := 0;
  P := AInstance;
  if ((P.Flags and 15) <> GpuKindStrokeRect) or (P.M12 <> 0) or (P.M21 <> 0) then
    Exit;
  Sx := Abs(P.M11);
  Sy := Abs(P.M22);
  if not ((Sx > 1E-3) and (Sy > 1E-3)) then
    Exit;
  // In local units: inside the outline's inner edge by the half stroke, the corner radii (no corner arcs there) and
  // more than half a pixel (the shader's antialiasing width: the size of a pixel), the shader's distance is more
  // than half a pixel: coverage 0, the target's pixel stays as it is.
  Hs := Abs(P.Stroke) * 0.5;
  G := Hs + Max(Abs(P.Rx), Abs(P.Ry)) + 2 / Min(Sx, Sy);
  Bx := (P.X1 - P.X0) * 0.5 - G;
  By := (P.Y1 - P.Y0) * 0.5 - G;
  Ox := ((P.X1 - P.X0) * 0.5 + Hs) * Sx + 1;
  Oy := ((P.Y1 - P.Y0) * 0.5 + Hs) * Sy + 1;
  X := (P.X0 + P.X1) * 0.5 * P.M11 + P.Dx;
  Y := (P.Y0 + P.Y1) * 0.5 * P.M22 + P.Dy;
  if not ((Bx > 0) and (By > 0) and (Abs(X) < 1E7) and (Abs(Y) < 1E7) and (Ox < 1E7) and (Oy < 1E7)) then
    Exit;
  // In pixels (whose centers are half a pixel in): the inner rectangle a pixel smaller on each side, and the quad's
  // bounds a pixel larger, within the target.
  Inner := TRect.Create(Ceil(X - Bx * Sx) + 1, Ceil(Y - By * Sy) + 1, Floor(X + Bx * Sx) - 1, Floor(Y + By * Sy) - 1);
  Outer := TRect.Create(Max(Floor(X - Ox) - 1, 0), Max(Floor(Y - Oy) - 1, 0), Min(Ceil(X + Ox) + 1, FWidth),
    Min(Ceil(Y + Oy) + 1, FHeight));
  Inner.Intersect(Outer);
  if (Inner.Right <= Inner.Left) or (Inner.Bottom <= Inner.Top) then
    Exit;
  Band(Outer.Left, Outer.Top, Outer.Right, Inner.Top);
  Band(Outer.Left, Inner.Bottom, Outer.Right, Outer.Bottom);
  Band(Outer.Left, Inner.Top, Inner.Left, Inner.Bottom);
  Band(Inner.Right, Inner.Top, Outer.Right, Inner.Bottom);
  AArea := Inner.Width * Inner.Height;
  Result := ACount > 0;
end;

procedure TGpuRenderer.UploadEdges(const AStart, ACount: Integer; const AData: Pointer);
begin
  if (ACount <= 0) or (AStart < 0) or (AStart + ACount > FEdgeCapacity) then
    Exit;
  // Collected and uploaded as one range before the next draw (many small uploads stall); the canvas appends edges
  // in order, so the range is contiguous.
  if (FEdgeHi > FEdgeLo) and (AStart <> FEdgeHi) then
    UploadEdgeRange;
  if FEdgeHi = FEdgeLo then
  begin
    FEdgeLo := AStart;
    FEdgeHi := AStart;
  end;
  if (FEdgeHi - FEdgeLo + ACount) * 4 > Length(FEdgeData) then
    SetLength(FEdgeData, Max((FEdgeHi - FEdgeLo + ACount) * 4, 2 * Length(FEdgeData)));
  Move(AData^, FEdgeData[(FEdgeHi - FEdgeLo) * 4], ACount * 16);
  Inc(FEdgeHi, ACount);
end;

procedure TGpuRenderer.ResizeEdges(const ACapacity: Integer);
begin
  DrawPending;
  CreateEdgeTable(ACapacity);
end;

end.
