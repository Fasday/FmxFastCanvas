unit FastCanvas.Canvas;

{ FastCanvas (stage 4): an FMX canvas with its own GPU renderer, written from scratch (docs/ARCHITECTURE.md
  section 13; no code from the FMX canvases).

  Drawing on the main thread records commands into the stream of FastCanvas.RenderQueue and returns; a render
  thread executes them. Rectangles, rounded rectangles, ellipses, lines, bitmaps and glyphs become TGpuInstance
  records that the recording side writes straight into the stream, and the render thread draws them in instanced
  runs (FastCanvas.Gpu, on Direct3D 11 or 12: FastCanvasBackend). Paths and stroke outlines are polygons with exact
  area coverage on the GPU (their geometry comes from the Direct2D factory on the CPU); rotated and very large text
  is drawn from glyph outlines, color fonts from an image rasterized once. Clips are a table of pixel boxes plus up
  to two oriented rectangles per entry, tested per pixel, so clip changes do not split draw calls.

  Contract: TCanvas (FMX.Graphics.pas:980-1229), TTextLayout (FMX.TextLayout.pas:48-177). On Direct3D 12 the canvas
  reports TCanvasStyle.SupportClipRects (FastCanvasPartialFrames): FMX then repaints only the rectangles that changed
  (FMX.Forms.pas:6387-6464); such a frame starts from the swap chain buffer shown last (flip sequential) and draws
  only inside them (a clip box around them, the rectangles tested per pixel when there are several). A frame that
  finds nothing to start from (a new or resized swap chain) is not presented, and the forms repaint in full. On
  Direct3D 11 FMX repaints the whole form every time. }

interface

{$SCOPEDENUMS ON}

uses
  System.Types, System.UITypes, System.SysUtils, System.Classes, System.Math, FMX.Types, FMX.Graphics, FMX.Forms,
  FastCanvas.Gpu, FastCanvas.Hdr;

type
  TFastCanvasOption = (
    /// <summary>Present with DXGI_PRESENT_ALLOW_TEARING when supported: Present never waits for vertical
    /// blank, even when DWM runs the window in independent flip (throughput measurements).</summary>
    AllowTearing,
    /// <summary>Text through Direct2D DrawTextLayout instead of the glyph atlas (measurement aid).</summary>
    D2DText,
    /// <summary>HDR windows draw and blend in linear light instead of in sRGB-encoded values as SDR targets do
    /// (measurement aid: what linear blending changes in antialiasing, text and transparency).</summary>
    HdrLinearBlend);
  TFastCanvasOptions = set of TFastCanvasOption;

  /// <summary>How the windows of the canvas show their frames.</summary>
  TFastCanvasPresentation = (
    /// <summary>A flip-model swap chain of the window. DWM shows it opaque: the alpha of the frame is ignored, so a
    /// form drawn transparent over a DWM backdrop (Mica, Acrylic, a frame extended into the client area) shows
    /// black there.</summary>
    Flip,
    /// <summary>A composition swap chain shown in the window by DirectComposition, with premultiplied alpha: where
    /// the frame is transparent, what is behind it shows (the backdrop, as with the stock Direct2D canvas). Windows
    /// presenting with tearing (TFastCanvasOption.AllowTearing) take Flip: tearing needs a swap chain of the window.
    /// Falls back to Flip when DirectComposition is not available. HDR output stays opaque.</summary>
    Composition);

  /// <summary>The frame a window shows (FastCanvasCaptureWindow): Width x Height pixels of four floats, R, G, B, A;
  /// scRGB (linear light, 1.0 = 80 nits) when Hdr, else sRGB-encoded 0..1.</summary>
  TFastWindowCapture = TGpuCapture;

var
  /// <summary>Read at BeginScene.</summary>
  FastCanvasOptions: TFastCanvasOptions = [];
  /// <summary>Window frames recorded but not presented yet when EndScene returns: the main thread records frame
  /// N + 1 while the render thread draws frame N, and runs at most this many frames ahead.</summary>
  FastCanvasFramesInFlight: Integer = 1;
  /// <summary>True: the commands recorded in a scene are executed on the render thread while the thread that
  /// records goes on (the main thread records frame N + 1 while frame N is drawn). False: they are executed on the
  /// recording thread at EndScene (and when a chunk fills up), with no second thread. Read at every scene that is
  /// not nested in another; switching waits for the render thread.</summary>
  FastCanvasRenderThread: Boolean = True;
  /// <summary>Read by InstallFastCanvas: set System.NeverSleepOnMMThreadContention. On contention for a block lock the
  /// Delphi memory manager sleeps 10 ms (getmem.inc, AdditionalSleepTime); the main thread (FMX) and the render
  /// thread both allocate, so that showed as 10-25 ms frame spikes. Spinning is what FastMM advises when there are
  /// fewer busy threads than cores.</summary>
  FastCanvasNoHeapSleep: Boolean = True;
  /// <summary>Bitmaps written by the CPU (Map for writing: loaded images, style bitmaps) keep a copy of their pixels,
  /// so that a new device after a device removal gets them back (the stock Direct2D canvas loses them). Bitmaps the
  /// GPU draws into do not keep one: FMX draws them again.</summary>
  FastCanvasKeepBitmapCopies: Boolean = True;
  /// <summary>Direct3D 12: the canvas reports TCanvasStyle.SupportClipRects, so FMX paints only the controls in the
  /// rectangles that changed (FMX.Forms.pas:6434-6464, :6509-6560); a window frame then starts from the one shown
  /// last and draws only inside those rectangles. As the stock Direct2D canvas. Measured 2026-10-08: listbox (lists
  /// scrolled in part of a form) 327 -> 357 and 181 -> 207 FPS; controls (hundreds of moving controls, every frame
  /// the whole window) -5 %: FMX then works out the update rectangle of every control that moves
  /// (FMX.Controls.pas:3637). Direct3D 11 has no access to the buffer shown last (flip model: buffer 0 only), so it
  /// keeps full repaints. Read by GetCanvasStyle, which FMX asks at every paint and invalidation: change it before
  /// forms are shown.</summary>
  FastCanvasPartialFrames: Boolean = True;
  /// <summary>How windows show their frames (not transparent forms, which are layered windows, nor TForm3D). Read at
  /// every window frame: a change makes the window's swap chain again, and the form repaints in full. A form whose
  /// window showed frames of its own swap chain (Flip) gets a new window when it switches to Composition (DWM would
  /// go on showing the last of those frames under the composition). Composition by default: forms look as with the
  /// stock Direct2D canvas where they are transparent, at the same speed (measured 2026-10-13).</summary>
  FastCanvasPresentation: TFastCanvasPresentation = TFastCanvasPresentation.Composition;

/// <summary>Makes TFastCanvas the default canvas. Call before Application.Initialize.</summary>
procedure InstallFastCanvas;
/// <summary>Waits until the render thread has executed everything recorded so far.</summary>
procedure FastCanvasSync;
/// <summary>Time the render thread has spent executing commands, ms.</summary>
function FastCanvasRenderBusyMs: Double;
/// <summary>GPU draw calls issued so far (diagnostics).</summary>
function FastCanvasDrawCalls: Integer;
/// <summary>ID of the render thread, 0 before the first scene.</summary>
function FastCanvasRenderThreadId: Cardinal;
/// <summary>Testing aid: the next scene that is not nested in another treats the graphics device as lost and
/// recreates everything on a new one, as after a real device removal.</summary>
procedure FastCanvasSimulateDeviceLoss;
/// <summary>Devices recreated so far (removed or simulated).</summary>
function FastCanvasDeviceResets: Integer;
/// <summary>HDR output of a form's window (FastCanvas.Hdr.FastCanvasHdr) and the levels of its display: Output says
/// whether its frames go out as FP16 scRGB (from the next frame on); tone-map HDR content to Headroom. Main thread.
/// </summary>
function FastCanvasHdrInfo(const AForm: TCommonCustomForm): TFastHdrInfo;
/// <summary>Diagnostics: the frame a form's window presented last, as the GPU holds it (Direct3D 12). Waits for the
/// render thread and the GPU. False when there is none.</summary>
function FastCanvasCaptureWindow(const AForm: TCommonCustomForm; out ACapture: TFastWindowCapture): Boolean;

implementation

uses
  Winapi.Windows, Winapi.DXGI, Winapi.D3D11, Winapi.D3DCommon, Winapi.DxgiFormat, Winapi.DxgiType,
  Winapi.D2D1, Winapi.Wincodec, Winapi.ActiveX, System.Generics.Collections, System.Math.Vectors, System.Messaging,
  FMX.Platform.Win, FMX.TextLayout,
  FMX.Types3D, FMX.Controls,
  FastCanvas.D2D1Ext, FastCanvas.DWriteExt, FastCanvas.Device, FastCanvas.Gpu11, FastCanvas.Gpu12,
  FastCanvas.Text, FastCanvas.RenderQueue, FastCanvas.Service, FastCanvas.Bridge;

type
  // Winapi.Windows declares a TBitmap too.
  TBitmap = FMX.Graphics.TBitmap;

const
  /// <summary>A chunk this large goes to the render thread before the frame is recorded to the end.</summary>
  SubmitBytes = 256 * 1024;
  /// <summary>Pixels per em up to which text is drawn from the glyph atlas.</summary>
  MaxAtlasEm = 160;
  MaxRecordedPaths = 1024;
  /// <summary>Paths kept in the GPU edge table (render thread).</summary>
  MaxEdgePaths = 4096;
  /// <summary>Horizontal bands of a path in the edge table (shader PathCoverage).</summary>
  MaxPathBands = 256;
  // TCmdBegin.Hdr.
  HdrModeMask = 3;
  HdrLinear = 4;

type
  TFastCanvas = class;

  /// <summary>TBitmap handle: a premultiplied BGRA texture of the backend (TGpuSurface), usable as image source and
  /// render target. On Direct3D 12 it can hold HDR content instead (an HDR 3D context copied its image into it): an
  /// RGBA16F surface beside the 8-bit one, which canvases draw from; converted into the 8-bit surface (clipped at 1)
  /// when the CPU maps the bitmap or a canvas draws into it.</summary>
  TFastBitmap = class(TInterfacedObject, IGpuTexture, IGpuHdrTexture)
  private
    FWidth, FHeight: Integer;
    /// <summary>nil while the device is lost.</summary>
    FSurface: TGpuSurface;
    FD2D: ID2D1Bitmap1;
    FAccess: TMapAccess;
    /// <summary>Pixels last written by the CPU (FastCanvasKeepBitmapCopies), nil when the GPU wrote it since.</summary>
    FCopy: TBytes;
    /// <summary>HDR content (made on first use) and whether the content is there (render thread, in stream order).
    /// </summary>
    FHdr: TGpuSurface;
    FHdrValid: Boolean;
    procedure CreateTexture(const AData: Pointer; const APitch: Integer);
    procedure ReleaseTexture;
    procedure GpuWritten; inline;
  public
    /// <summary>Device lock held, render thread idle or on it: HDR content into the 8-bit surface (clipped at 1).
    /// </summary>
    procedure Demote;
    /// <summary>AData: the initial pixels (rows APitch apart), nil for transparent black.</summary>
    constructor Create(const AWidth, AHeight: Integer; const AData: Pointer = nil; const APitch: Integer = 0);
    destructor Destroy; override;
    function Surface: TGpuSurface;
    function HdrTarget: TGpuSurface;
    procedure SdrTarget;
    /// <summary>Render thread, Direct3D 11: the Direct2D bitmap over the texture (source and target).</summary>
    function D2DBitmap(const AContext: ID2D1DeviceContext): ID2D1Bitmap1;
  end;

  TTargetKind = (Window, Layered, Bitmap);

  /// <summary>Render-thread resources of a canvas: the output of a window (TGpuWindow), or the bitmap.</summary>
  TFastTarget = class
  public
    Kind: TTargetKind;
    Wnd: HWND;
    Width, Height: Integer;
    Aliased, Tearing: Boolean;
    Window: TGpuWindow;
    /// <summary>The surface the frame in progress draws into.</summary>
    Surface: TGpuSurface;
    D2D: ID2D1Bitmap1;
    Bitmap: IGpuTexture;
    /// <summary>Device generation the window and the surfaces belong to.</summary>
    Gen: Integer;
    /// <summary>Render thread: the rectangles of the partial frame in progress (TCmdRegion), applied whenever this
    /// target is selected; RegionCount = 0: none.</summary>
    RegionFirst, RegionCount: Cardinal;
    procedure ReleaseViews;
    /// <summary>AHdr, AComposition: TCmdBegin.Hdr, TCmdBegin.Composition.</summary>
    procedure Prepare(const AWidth, AHeight: Integer; const ATearing: Boolean; const ABitmap: TFastBitmap;
      const AHdr: Byte; const AComposition: Boolean);
    function D2DTarget(const AContext: ID2D1DeviceContext): ID2D1Bitmap1;
    constructor Create;
    destructor Destroy; override;
  end;

  TClipState = record
    Clip: TGpuClip;
    /// <summary>Index in the clip table, -1 = not recorded yet; valid while Epoch = GEpoch.</summary>
    Index: Integer;
    Epoch: Integer;
  end;

  TFastCanvasState = class(TCanvasSaveState)
  private
    FClip: TClipState;
  protected
    procedure AssignTo(Dest: TPersistent); override;
  public
    procedure Assign(Source: TPersistent); override;
  end;

  TPaintResult = (None, Gpu, D2D);
  TD2DShape = (Rect, RoundRect, Ellipse, Line, Path);

  TFastCanvas = class(TCanvas)
  private
    FTarget: TFastTarget;
    FDev: TGpuAffine;
    FAxis: Boolean;
    /// <summary>Largest scale of FDev (Visible grows rectangles by it).</summary>
    FDevScale: Single;
    FClip: TClipState;
    FPixelW, FPixelH: Integer;
    /// <summary>Window: the size and device generation of the last frame recorded for presenting, which a partial
    /// frame starts from; FKeptW = 0: none.</summary>
    FKeptW, FKeptH, FKeptGen: Integer;
    /// <summary>The scene in progress updates part of its target (only these rectangles, in pixels): a partial window
    /// frame, or a bitmap scene FMX gave clip rectangles (TLayer3D).</summary>
    FRegion: TArray<TRectF>;
    /// <summary>The canvas whose region was in force when this one's began (a bitmap scene in a partial window
    /// frame), in force again after this scene.</summary>
    FOuterRegion: TFastCanvas;
    /// <summary>The bitmap of the paint PaintOf made last (bitmap brushes), taken by the next AddInstance.</summary>
    FPaintTexture: TFastBitmap;
    /// <summary>Window: a frame was recorded for its own swap chain (FastCanvasPresentation = Flip); a new window
    /// for the form was asked for.</summary>
    FFlipShown, FRecreateQueued: Boolean;
    procedure QueueRecreateWindow;
    procedure RecRegion;
    procedure PartialRegion(const ARects: TClipRects);
    procedure RegionOf(const ARects: TClipRects);
    function DeviceBox(const R: TRectF): TRectF;
    function Visible(const R: TRectF; const AGrow: Single): Boolean;
    function ClipIndex: Cardinal;
    function AddInstance(const AFlags: Cardinal; const R: TRectF): PGpuInstance;
    function PaintOf(const ABrush: TBrush; const R: TRectF; const AOpacity: Single; out AColor, APaint: Cardinal): TPaintResult;
    function DashPattern(const AStroke: TStrokeBrush): Cardinal;
    function StrokeOf(const ABrush: TStrokeBrush; const R: TRectF; const AOpacity: Single; const ALine: Boolean;
      out AColor, APaint, AFlags: Cardinal; out AWidth: Single): TPaintResult;
    procedure RecD2D(const AShape: TD2DShape; const AFill: Boolean; const R: TRectF; const Rx, Ry: Single;
      const APath: TPathData; const ABrush: TBrush; const AOpacity: Single);
    procedure IntersectDeviceClip(const R: TRectF; const AExclude: Boolean);
    procedure DrawText(const AData: TFastLayoutData; const AOrigin, AMaxSize: TPointF; const AColor: TAlphaColor;
      const AOpacity: Single);

  protected
    function CreateSaveState: TCanvasSaveState; override;
    function DoBeginScene(AClipRects: PClipRects = nil; AContextHandle: THandle = 0): Boolean; override;
    procedure DoEndScene; override;
    procedure DoFlush; override;
    constructor CreateFromWindow(const AParent: TWindowHandle; const AWidth, AHeight: Single;
      const AQuality: TCanvasQuality = TCanvasQuality.SystemDefault); override;
    constructor CreateFromBitmap(const ABitmap: TBitmap; const AQuality: TCanvasQuality = TCanvasQuality.SystemDefault); override;
    constructor CreateFromPrinter(const APrinter: TAbstractPrinter); override;
    class function DoInitializeBitmap(const Width, Height: Integer; const Scale: Single; var PixelFormat: TPixelFormat): THandle; override;
    class procedure DoFinalizeBitmap(var Bitmap: THandle); override;
    class function DoMapBitmap(const Bitmap: THandle; const Access: TMapAccess; var Data: TBitmapData): Boolean; override;
    class procedure DoUnmapBitmap(const Bitmap: THandle; var Data: TBitmapData); override;
    class function DoCopyImageToBitmap(const Source: THandle; const Dest: TBitmap): Boolean; override;
    procedure DoSetMatrix(const M: TMatrix); override;
    procedure DoFillRect(const ARect: TRectF; const AOpacity: Single; const ABrush: TBrush); override;
    procedure DoFillRoundRect(const ARect: TRectF; const XRadius, YRadius: Single; const ACorners: TCorners;
      const AOpacity: Single; const ABrush: TBrush; const ACornerType: TCornerType = TCornerType.Round); override;
    procedure DoDrawRoundRect(const ARect: TRectF; const XRadius, YRadius: Single; const ACorners: TCorners;
      const AOpacity: Single; const ABrush: TStrokeBrush; const ACornerType: TCornerType = TCornerType.Round); override;
    procedure DoFillPath(const APath: TPathData; const AOpacity: Single; const ABrush: TBrush); override;
    procedure DoFillEllipse(const ARect: TRectF; const AOpacity: Single; const ABrush: TBrush); override;
    procedure DoDrawBitmap(const ABitmap: TBitmap; const SrcRect, DstRect: TRectF; const AOpacity: Single;
      const HighSpeed: Boolean); override;
    procedure DoDrawLine(const APt1, APt2: TPointF; const AOpacity: Single; const ABrush: TStrokeBrush); override;
    procedure DoDrawRect(const ARect: TRectF; const AOpacity: Single; const ABrush: TStrokeBrush); override;
    procedure DoDrawPath(const APath: TPathData; const AOpacity: Single; const ABrush: TStrokeBrush); override;
    procedure DoDrawEllipse(const ARect: TRectF; const AOpacity: Single; const ABrush: TStrokeBrush); override;
    procedure DoClear(const Color: TAlphaColor); override;
    procedure DoClearRect(const ARect: TRectF; const AColor: TAlphaColor = 0); override;
    procedure DoIntersectClipRect(const ARect: TRectF); override;
    procedure DoExcludeClipRect(const ARect: TRectF); override;
  public
    destructor Destroy; override;
    class function GetCanvasStyle: TCanvasStyles; override;
    class function GetAttribute(const Value: TCanvasAttribute): Integer; override;
    function PtInPath(const APoint: TPointF; const APath: TPathData): Boolean; override;
  end;

  { Command stream }

  TCmd = (Target, BeginFrame, EndFrame, Instances, Clip, Paint, Ramp, Flush, Clear, FillCopy, PathDef,
    ResetPaths, D2DShape, Text, ExecuteList, Callback, Native, Region);

  PCmdHeader = ^TCmdHeader;
  TCmdHeader = packed record
    Op: TCmd;
    Pad: array[0..2] of Byte;
    Size: Cardinal;
  end;

  PCmdTarget = ^TCmdTarget;
  TCmdTarget = packed record
    Canvas: Pointer;
  end;

  PCmdBegin = ^TCmdBegin;
  TCmdBegin = packed record
    Width, Height: Integer;
    Aliased, Tearing: Boolean;
    /// <summary>Window: the frame updates part of it, starting from the frame presented last.</summary>
    Partial: Boolean;
    /// <summary>Window on Direct3D 12: Ord(FastCanvasHdr) (HdrModeMask), HdrLinear (HdrLinearBlend).</summary>
    Hdr: Byte;
    /// <summary>Window: FastCanvasPresentation = Composition.</summary>
    Composition: Boolean;
    Bitmap: Pointer;   // TFastBitmap of a bitmap canvas, kept alive by the chunk
  end;

  PCmdRegion = ^TCmdRegion;
  /// <summary>The rectangles of a partial frame of a window canvas: the boxes of clip entries First..First + Count - 1;
  /// Count = 0: the whole target. They hold only while that canvas is the target (scenes of bitmap canvases may run
  /// in the middle of the frame).</summary>
  TCmdRegion = packed record
    First, Count: Cardinal;
    Canvas: Pointer;
  end;

  PCmdEnd = ^TCmdEnd;
  TCmdEnd = packed record
    Present, Window: Boolean;
    Pad: Word;
    BitsWidth, BitsHeight: Integer;
    Bits: Pointer;     // transparent window: the buffer of the layered window
  end;

  PCmdInstances = ^TCmdInstances;
  TCmdInstances = packed record
    Count: Integer;
    Pad: Integer;
  end;

  PCmdClip = ^TCmdClip;
  TCmdClip = packed record
    Index: Integer;
    Clip: TGpuClip;
  end;

  PCmdPaint = ^TCmdPaint;
  TCmdPaint = packed record
    Index: Integer;
    Paint: TGpuPaint;
  end;

  PCmdRamp = ^TCmdRamp;
  TCmdRamp = packed record
    Row: Integer;
    Texels: array[0..GpuRampWidth - 1] of Cardinal;
  end;

  PCmdColor = ^TCmdColor;
  TCmdColor = packed record
    Color: Cardinal;
  end;

  PCmdFillCopy = ^TCmdFillCopy;
  TCmdFillCopy = packed record
    Rect: TRectF;
    Color: Cardinal;
    Clip: Cardinal;
  end;

  PCmdPathDef = ^TCmdPathDef;
  TCmdPathDef = packed record
    Key: UInt64;
    Count: Integer;   // followed by Count TPathPoint
  end;

  TD2DBrushKind = (Solid, Linear, Radial, Bitmap);

  PCmdD2D = ^TCmdD2D;
  /// <summary>A shape drawn by Direct2D; followed by DashCount Singles and StopCount TD2D1GradientStop.</summary>
  TCmdD2D = packed record
    Shape: TD2DShape;
    Brush: TD2DBrushKind;
    Fill: Boolean;
    Cap, Join, Dash: Byte;
    Pad: Word;
    Clip: Integer;
    Matrix: TGpuAffine;
    R: TRectF;
    Rx, Ry: Single;
    PathKey: UInt64;
    Color: Cardinal;
    Opacity: Single;
    StrokeWidth: Single;
    DashOffset: Single;
    DashCount: Integer;
    StopCount: Integer;
    GradKey: UInt64;
    G0, G1: TPointF;
    GMatrix: TGpuAffine;
    Bitmap: Pointer;
    BitmapExtend: Integer;
    BitmapMatrix: TGpuAffine;
    /// <summary>Paths: the GPU renderer can draw it (solid or gradient paint); Inst carries matrix, paint and clip.</summary>
    GpuOk: Boolean;
    Inst: TGpuInstance;
  end;

  PCmdCallback = ^TCmdCallback;
  /// <summary>A TProc of FastBridge.RunOnRender (kept alive by the chunk).</summary>
  TCmdCallback = packed record
    Proc: Pointer;
  end;

  PCmdText = ^TCmdText;
  /// <summary>A text layout; the render thread turns it into glyph instances, or draws it with Direct2D.</summary>
  TCmdText = packed record
    Data: Pointer;     // TFastLayoutData, kept alive by the chunk
    Origin: TPointF;
    Matrix: TGpuAffine;
    Color: Cardinal;
    Opacity: Single;
    Clip: Integer;
    ForceD2D: Boolean;
    Pad: array[0..2] of Byte;
  end;
  PCmdList = ^TCmdList;
  TCmdList = packed record
    List: Pointer;   // ID3D11CommandList, kept alive by the chunk
  end;

  PPathPoints = ^TPathPoints;
  TPathPoints = array[0..MaxInt div SizeOf(TPathPoint) - 1] of TPathPoint;

  { Render thread }

  /// <summary>A path in the edge table: Header = first band header, Bands band lists (shader PathCoverage), Count
  /// polygon edges before banding.</summary>
  TPathEdges = record
    Header, Bands, Count: Integer;
    /// <summary>-1: in the lasting part of the table; else in the per-frame part, valid while its generation
    /// (TransGen) is current.</summary>
    Frame, TransGen: Integer;
    Bounds: TRectF;
    EvenOdd: Boolean;
  end;

  TEdge = record
    X0, Y0, X1, Y1: Single;
  end;

  /// <summary>Receives a flattened or widened Direct2D geometry as polygon edges (every figure closed, curves
  /// flattened to the tolerance).</summary>
  TEdgeSink = class(TInterfacedObject, ID2D1SimplifiedGeometrySink)
  private
    FTolerance: Single;
    FStart, FCur: TD2D1Point2F;
    FOpen: Boolean;
    procedure Edge(const A, B: TD2D1Point2F);
    procedure CloseFigure;
  public
    Edges: TArray<TEdge>;
    Count: Integer;
    EvenOdd: Boolean;
    MinX, MinY, MaxX, MaxY: Single;
    constructor Create;
    /// <summary>Starts a new polygon (keeps the edge buffer).</summary>
    procedure Reset(const ATolerance: Single; const AEvenOdd: Boolean);
    procedure SetFillMode(fillMode: D2D1_FILL_MODE); stdcall;
    procedure SetSegmentFlags(vertexFlags: D2D1_PATH_SEGMENT); stdcall;
    procedure BeginFigure(startPoint: D2D1_POINT_2F; figureBegin: D2D1_FIGURE_BEGIN); stdcall;
    procedure AddLines(points: PD2D1Point2F; pointsCount: UINT); stdcall;
    procedure AddBeziers(beziers: PD2D1BezierSegment; beziersCount: UINT); stdcall;
    procedure EndFigure(figureEnd: D2D1_FIGURE_END); stdcall;
    function Close: HResult; stdcall;
  end;

  TPlayer = class
  private
    FGpu: TGpuRenderer;
    FD2D: ID2D1DeviceContext;
    FCanvas: TFastCanvas;
    FInD2D: Boolean;
    FD2DClip: Integer;
    FD2DPushed: TArray<Boolean>;  // True = layer, False = axis-aligned clip
    FD2DPushCount: Integer;
    FSolid: ID2D1SolidColorBrush;
    FGlyphs: TFastGlyphCache;
    /// <summary>Glyph outlines (rotated, sideways and very large text) by face, glyph and size.</summary>
    FGlyphPaths: TDictionary<UInt64, ID2D1PathGeometry>;
    FWic: IWICImagingFactory;
    FPaths: TDictionary<UInt64, ID2D1PathGeometry>;
    FStrokes: TDictionary<UInt64, ID2D1StrokeStyle>;
    FStops: TDictionary<UInt64, ID2D1GradientStopCollection>;
    FEdges: TDictionary<UInt64, TPathEdges>;
    FEdgeCount: Integer;
    // Reused for every path: the render thread must not allocate per draw (the Delphi memory manager sleeps 10 ms
    // when the main thread holds the same block lock).
    FSink: TEdgeSink;
    FSinkRef: ID2D1SimplifiedGeometrySink;
    FBanded: TArray<TEdge>;
    FFrame, FEdgeResetFrame: Integer;
    /// <summary>The frame in progress is partial but found no frame to start from: it is not presented.</summary>
    FNoPresent: Boolean;
    // Per-frame part of the edge table: next free entry, and the keys added in the last two frames.
    FTransPos, FTransFrame, FTransCur, FTransGen: Integer;
    FPersistCount: Integer;
    FTransKeys: array[0..1] of TArray<UInt64>;
    FTransCount: array[0..1] of Integer;
    /// <summary>Gradient brushes by stop collection: points, opacity and transform are set before every use.</summary>
    FLinear: TDictionary<UInt64, ID2D1LinearGradientBrush>;
    FRadial: TDictionary<UInt64, ID2D1RadialGradientBrush>;
    procedure Run(const H: PCmdHeader);
    procedure SelectTarget(const ACanvas: TFastCanvas);
    procedure SetRegion(const C: PCmdRegion);
    procedure BeginFrame(const C: PCmdBegin);
    procedure EndFrame(const C: PCmdEnd);
    function AllocEdges(const N: Integer; const APersistent: Boolean): Integer;
    procedure AddTransient(const AKey: UInt64);
    procedure DropTransient(const AList: Integer);
    procedure NewFrame;
    procedure EnterD2D;
    procedure LeaveD2D;
    procedure UseD2DClip(const AIndex: Integer);
    procedure PopD2DClips;
    procedure DefinePath(const C: PCmdPathDef);
    procedure DrawShape(const C: PCmdD2D);
    function StrokeKey(const C: PCmdD2D): UInt64;
    function PathEdges(const C: PCmdD2D; const AScaleMax, AScaleMin: Single; out AEdges: TPathEdges): Boolean;
    function ShapeGeometry(const C: PCmdD2D; const R: TRectF): ID2D1Geometry;
    function DrawShapeGpu(const C: PCmdD2D): Boolean;
    procedure DrawText(const C: PCmdText);
    procedure DrawRunOutlines(const C: PCmdText; const ARun: TFastGlyphRun; const AColor: Cardinal);
    procedure DrawColorLayout(const C: PCmdText; const AData: TFastLayoutData);
    procedure DrawTextD2D(const C: PCmdText; const AData: TFastLayoutData);
    function Brush(const C: PCmdD2D): ID2D1Brush;
    function StrokeStyle(const C: PCmdD2D): ID2D1StrokeStyle;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Execute(const AData: PByte; const ASize: Integer);
  end;

var
  GQueue: TRenderQueue;
  GPlayer: TPlayer;
  GRecTarget: TFastCanvas;
  GRunOffset: Integer = -1;
  GRunChunk: TRenderChunk;
  GClipCount: Integer = 1;
  GPaintCount: Integer;
  GEpoch: Integer = 1;
  GRamps: TDictionary<UInt64, Integer>;
  GKnownPaths: TDictionary<UInt64, Boolean>;
  GInstalled: Boolean;
  // Device removal: the generation of the current device, set when the render thread saw the device go (or a
  // simulated loss), resets so far, and the depth of the scenes in progress (only an outer scene recovers).
  GDeviceGen: Integer = 1;
  GDeviceLost: Integer;
  GDeviceResets: Integer;
  GSceneDepth: Integer;
  // Live bitmaps and canvas targets, recreated on a new device.
  GBitmaps: TDictionary<Pointer, Boolean>;
  GTargets: TDictionary<Pointer, Boolean>;
  GBitmapsLock: TObject;
  /// <summary>The canvas service shut down (ShutdownFastCanvas).</summary>
  GFinished: Boolean;
  // The canvas whose region is in force (a partial window frame, a bitmap scene with clip rectangles); with its
  // FOuterRegion chain, the regions recorded again after ResetTables.
  GRegionCanvas: TFastCanvas;
  // Set by the render thread: a partial frame found no frame to start from and was not presented; the main thread
  // repaints the windows in full (CheckPartialFrames).
  GPartialMissed: Integer;

{ Helpers }

function Fnv(const AData: Pointer; const ASize: Integer; const ASeed: UInt64 = UInt64($CBF29CE484222325)): UInt64;
var
  P: PByte;
  I: Integer;
begin
  Result := ASeed;
  P := AData;
  for I := 0 to ASize - 1 do
  begin
    Result := (Result xor P^) * UInt64($100000001B3);
    Inc(P);
  end;
end;

function MulAlpha(const AColor: TAlphaColor; const AOpacity: Single): Cardinal; inline;
var
  A: Integer;
begin
  A := Round((AColor shr 24) * EnsureRange(AOpacity, 0, 1));
  Result := (AColor and $00FFFFFF) or (Cardinal(A) shl 24);
end;

function OpacityColor(const AOpacity: Single): Cardinal; inline;
begin
  Result := $00FFFFFF or (Cardinal(Round(255 * EnsureRange(AOpacity, 0, 1))) shl 24);
end;

function NormRect(const R: TRectF): TRectF; inline;
begin
  Result := TRectF.Create(Min(R.Left, R.Right), Min(R.Top, R.Bottom), Max(R.Left, R.Right), Max(R.Top, R.Bottom));
end;

function Affine(const M: TMatrix): TGpuAffine; inline;
begin
  Result.M11 := M.m11;
  Result.M12 := M.m12;
  Result.M21 := M.m21;
  Result.M22 := M.m22;
  Result.Dx := M.m31;
  Result.Dy := M.m32;
end;

function D2DMatrix(const A: TGpuAffine): TD2D1Matrix3x2F; inline;
begin
  Result._11 := A.M11;
  Result._12 := A.M12;
  Result._21 := A.M21;
  Result._22 := A.M22;
  Result._31 := A.Dx;
  Result._32 := A.Dy;
end;

function D2DColor(const AColor: Cardinal): TD2D1ColorF; inline;
begin
  Result.r := ((AColor shr 16) and $FF) / 255;
  Result.g := ((AColor shr 8) and $FF) / 255;
  Result.b := (AColor and $FF) / 255;
  Result.a := (AColor shr 24) / 255;
end;

function D2DRect(const R: TRectF): TD2D1RectF; inline;
begin
  Result.left := R.Left;
  Result.top := R.Top;
  Result.right := R.Right;
  Result.bottom := R.Bottom;
end;

function D2DPoint(const X, Y: Single): TD2D1Point2F; inline;
begin
  Result.x := X;
  Result.y := Y;
end;

function ResolveBrush(const ABrush: TBrush): TBrush;
begin
  Result := ABrush;
  while (Result <> nil) and (Result.Kind = TBrushKind.Resource) do
    if Result.Resource <> nil then
      Result := Result.Resource.Brush
    else
      Result := nil;
end;

function CornerMask(const ACorners: TCorners): Cardinal;
begin
  Result := 0;
  if TCorner.TopLeft in ACorners then
    Result := Result or 1;
  if TCorner.TopRight in ACorners then
    Result := Result or 2;
  if TCorner.BottomLeft in ACorners then
    Result := Result or 4;
  if TCorner.BottomRight in ACorners then
    Result := Result or 8;
end;

function PathHash(const APath: TPathData): UInt64;
var
  I: Integer;
  P: TPathPoint;
begin
  Result := Fnv(@I, 0);
  for I := 0 to APath.Count - 1 do
  begin
    P := APath[I];
    Result := Fnv(@P, SizeOf(P), Result);
  end;
end;

function GradientHash(const AGradient: TGradient): UInt64;
var
  I: Integer;
  C: TAlphaColor;
  O: Single;
  S: Byte;
begin
  S := Ord(AGradient.Style);
  Result := Fnv(@S, 1);
  for I := 0 to AGradient.Points.Count - 1 do
  begin
    C := AGradient.Points[I].IntColor;
    O := AGradient.Points[I].Offset;
    Result := Fnv(@C, SizeOf(C), Result);
    Result := Fnv(@O, SizeOf(O), Result);
  end;
end;

/// <summary>Stops of a gradient sorted by offset (FMX keeps them in collection order).</summary>
procedure SortedStops(const AGradient: TGradient; out AOffsets: TArray<Single>; out AColors: TArray<TAlphaColor>);
var
  I, J, N: Integer;
  O: Single;
  C: TAlphaColor;
begin
  N := AGradient.Points.Count;
  SetLength(AOffsets, N);
  SetLength(AColors, N);
  for I := 0 to N - 1 do
  begin
    AOffsets[I] := EnsureRange(AGradient.Points[I].Offset, 0, 1);
    AColors[I] := AGradient.Points[I].IntColor;
  end;
  for I := 1 to N - 1 do
  begin
    O := AOffsets[I];
    C := AColors[I];
    J := I - 1;
    while (J >= 0) and (AOffsets[J] > O) do
    begin
      AOffsets[J + 1] := AOffsets[J];
      AColors[J + 1] := AColors[J];
      Dec(J);
    end;
    AOffsets[J + 1] := O;
    AColors[J + 1] := C;
  end;
end;

/// <summary>Direct2D path geometry of FMX path points: MoveTo starts a filled figure, CurveTo takes three points
/// (two control points and the end), Close ends the figure closed; an unfinished figure ends open.</summary>
function BuildGeometry(const APoints: PPathPoints; const ACount: Integer): ID2D1PathGeometry;
var
  Sink: ID2D1GeometrySink;
  I: Integer;
  Open: Boolean;
  B: TD2D1BezierSegment;
begin
  if Failed(TFastDevice.D2DFactory.CreatePathGeometry(Result)) or Failed(Result.Open(Sink)) then
    Exit(nil);
  Open := False;
  I := 0;
  while I < ACount do
  begin
    case APoints[I].Kind of
      TPathPointKind.MoveTo:
        begin
          if Open then
            Sink.EndFigure(D2D1_FIGURE_END_OPEN);
          Sink.BeginFigure(D2DPoint(APoints[I].Point.X, APoints[I].Point.Y), D2D1_FIGURE_BEGIN_FILLED);
          Open := True;
        end;
      TPathPointKind.LineTo:
        if Open then
          Sink.AddLine(D2DPoint(APoints[I].Point.X, APoints[I].Point.Y));
      TPathPointKind.CurveTo:
        begin
          if Open and (I + 2 < ACount) then
          begin
            B.point1 := D2DPoint(APoints[I].Point.X, APoints[I].Point.Y);
            B.point2 := D2DPoint(APoints[I + 1].Point.X, APoints[I + 1].Point.Y);
            B.point3 := D2DPoint(APoints[I + 2].Point.X, APoints[I + 2].Point.Y);
            Sink.AddBezier(B);
          end;
          Inc(I, 2);
        end;
      TPathPointKind.Close:
        if Open then
        begin
          Sink.EndFigure(D2D1_FIGURE_END_CLOSED);
          Open := False;
        end;
    end;
    Inc(I);
  end;
  if Open then
    Sink.EndFigure(D2D1_FIGURE_END_OPEN);
  Sink.Close;
end;

function PathPoints(const APath: TPathData): TArray<TPathPoint>;
var
  I: Integer;
begin
  SetLength(Result, APath.Count);
  for I := 0 to APath.Count - 1 do
    Result[I] := APath[I];
end;

{ Recording (the thread that holds the canvas lock of FMX) }

procedure PlayStream(const AData: PByte; const ASize: Integer); forward;

function Queue: TRenderQueue;
begin
  if GQueue = nil then
    GQueue := TRenderQueue.Create(PlayStream, FastCanvasRenderThread);
  Result := GQueue;
end;

/// <summary>Appends a command and returns its payload (valid until the next allocation). Any command ends the open
/// run of instances.</summary>
function RecAlloc(const AOp: TCmd; const APayload: Integer; const ARef: IInterface = nil): Pointer;
var
  Q: TRenderQueue;
  H: PCmdHeader;
begin
  // 3D work recorded on a deferred context before this command goes first.
  if FastDeferredPending and (AOp <> TCmd.ExecuteList) then
    FastFlushDeferred;
  Q := Queue;
  GRunOffset := -1;
  if Q.Chunk.Size >= SubmitBytes then
    Q.Submit;
  H := Q.Chunk.Alloc(SizeOf(TCmdHeader) + APayload);
  H.Op := AOp;
  H.Pad[0] := 0;
  H.Pad[1] := 0;
  H.Pad[2] := 0;
  H.Size := SizeOf(TCmdHeader) + APayload;
  if ARef <> nil then
    Q.Chunk.KeepAlive(ARef);
  Result := PByte(H) + SizeOf(TCmdHeader);
end;

procedure RecTarget(const ACanvas: TFastCanvas);
begin
  if GRecTarget = ACanvas then
    Exit;
  PCmdTarget(RecAlloc(TCmd.Target, SizeOf(TCmdTarget))).Canvas := ACanvas;
  GRecTarget := ACanvas;
end;

/// <summary>Space for one instance at the end of the open run (a new run when needed).</summary>
function RecInstance(const ACanvas: TFastCanvas): PGpuInstance;
var
  Q: TRenderQueue;
  H: PCmdHeader;
begin
  if FastDeferredPending then
    FastFlushDeferred;
  RecTarget(ACanvas);
  Q := GQueue;
  if (GRunOffset < 0) or (GRunChunk <> Q.Chunk) or (Q.Chunk.Size >= SubmitBytes) then
  begin
    PCmdInstances(RecAlloc(TCmd.Instances, SizeOf(TCmdInstances))).Count := 0;
    GRunChunk := Q.Chunk;
    GRunOffset := Q.Chunk.Size - SizeOf(TCmdHeader) - SizeOf(TCmdInstances);
  end;
  Result := Q.Chunk.Alloc(SizeOf(TGpuInstance));
  H := Q.Chunk.At(GRunOffset);
  Inc(H.Size, SizeOf(TGpuInstance));
  Inc(PCmdInstances(PByte(H) + SizeOf(TCmdHeader)).Count);
end;

procedure RecFlush;
begin
  RecAlloc(TCmd.Flush, 0);
end;

procedure ResetTables;
var
  C: TFastCanvas;
begin
  // The render thread draws what refers to the old entries before they are overwritten.
  RecFlush;
  GClipCount := 1;
  GPaintCount := 0;
  Inc(GEpoch);
  // The regions in force: of the scene in progress and of the scenes it is drawn in.
  C := GRegionCanvas;
  while C <> nil do
  begin
    C.RecRegion;
    C := C.FOuterRegion;
  end;
end;

function RecPaint(const APaint: TGpuPaint): Cardinal;
var
  C: PCmdPaint;
begin
  if GPaintCount >= GpuMaxPaints then
    ResetTables;
  Result := GPaintCount;
  Inc(GPaintCount);
  C := RecAlloc(TCmd.Paint, SizeOf(TCmdPaint));
  C.Index := Result;
  C.Paint := APaint;
end;

/// <summary>Ramp row of a gradient (uploaded on first use): 256 straight colors over the offsets 0..1.</summary>
function RampRow(const AGradient: TGradient): Integer;
var
  Key: UInt64;
  C: PCmdRamp;
  Offsets: TArray<Single>;
  Colors: TArray<TAlphaColor>;
  I, K, N: Integer;
  T, F: Single;
  A, B: TAlphaColorRec;

  function Lerp(const X, Y: Byte; const AF: Single): Cardinal; inline;
  begin
    Result := Round(X + (Y - X) * AF);
  end;

begin
  Key := GradientHash(AGradient);
  if GRamps = nil then
    GRamps := TDictionary<UInt64, Integer>.Create;
  if GRamps.TryGetValue(Key, Result) then
    Exit;
  if GRamps.Count >= GpuRampRows then
  begin
    RecFlush;
    GRamps.Clear;
  end;
  Result := GRamps.Count;
  GRamps.Add(Key, Result);
  SortedStops(AGradient, Offsets, Colors);
  N := Length(Offsets);
  C := RecAlloc(TCmd.Ramp, SizeOf(TCmdRamp));
  C.Row := Result;
  K := 0;
  for I := 0 to GpuRampWidth - 1 do
  begin
    T := I / (GpuRampWidth - 1);
    while (K < N - 1) and (Offsets[K + 1] < T) do
      Inc(K);
    if (N = 1) or (T <= Offsets[0]) then
      A.Color := Colors[0]
    else if T >= Offsets[N - 1] then
      A.Color := Colors[N - 1]
    else
    begin
      A.Color := Colors[K];
      B.Color := Colors[K + 1];
      if Offsets[K + 1] > Offsets[K] then
        F := (T - Offsets[K]) / (Offsets[K + 1] - Offsets[K])
      else
        F := 0;
      A.R := Lerp(A.R, B.R, F);
      A.G := Lerp(A.G, B.G, F);
      A.B := Lerp(A.B, B.B, F);
      A.A := Lerp(A.A, B.A, F);
    end;
    // R8G8B8A8_UNORM: bytes R, G, B, A.
    C.Texels[I] := A.R or (Cardinal(A.G) shl 8) or (Cardinal(A.B) shl 16) or (Cardinal(A.A) shl 24);
  end;
end;

/// <summary>Paint table entry of a gradient over the rectangle R (local space).</summary>
function RecGradientPaint(const AGradient: TGradient; const R: TRectF): Cardinal;
var
  P: TGpuPaint;
  V: Single;
  Inv: TGpuAffine;
begin
  V := (RampRow(AGradient) + 0.5) / GpuRampRows;
  FillChar(P, SizeOf(P), 0);
  if AGradient.Style = TGradientStyle.Radial then
  begin
    // Center and radii in brush space, as Direct2D defines a radial brush; RadialTransform maps brush space
    // to the local space, the shader goes the other way.
    Inv := Affine(AGradient.RadialTransform.Matrix).Inverse;
    P.Data[0] := Inv.M11;
    P.Data[1] := Inv.M12;
    P.Data[2] := Inv.M21;
    P.Data[3] := Inv.M22;
    P.Data[4] := Inv.Dx;
    P.Data[5] := Inv.Dy;
    P.Data[6] := R.Left + R.Width * AGradient.RadialTransform.RotationCenter.X;
    P.Data[7] := R.Top + R.Height * AGradient.RadialTransform.RotationCenter.Y;
    P.Data[8] := R.Width / 2;
    P.Data[9] := R.Height / 2;
    P.Data[11] := 2;
  end
  else
  begin
    P.Data[0] := R.Left + AGradient.StartPosition.X * R.Width;
    P.Data[1] := R.Top + AGradient.StartPosition.Y * R.Height;
    P.Data[2] := R.Left + AGradient.StopPosition.X * R.Width;
    P.Data[3] := R.Top + AGradient.StopPosition.Y * R.Height;
    P.Data[11] := 1;
  end;
  P.Data[10] := V;
  Result := RecPaint(P);
end;

/// <summary>Paint of a bitmap brush (shader ImagePaint): local position to texture coordinates. Tile and
/// TileOriginal: one bitmap pixel per local unit from the local origin (repeating, or the edge pixels beyond);
/// TileStretch: the bitmap over the rectangle of the shape.</summary>
function RecImagePaint(const ABitmap: TFastBitmap; const AWrap: TWrapMode; const R: TRectF): Cardinal;
var
  P: TGpuPaint;
begin
  FillChar(P, SizeOf(P), 0);
  if (AWrap = TWrapMode.TileStretch) and (R.Width > 0) and (R.Height > 0) then
  begin
    P.Data[0] := 1 / R.Width;
    P.Data[3] := 1 / R.Height;
    P.Data[4] := -R.Left / R.Width;
    P.Data[5] := -R.Top / R.Height;
  end
  else
  begin
    P.Data[0] := 1 / Max(ABitmap.FWidth, 1);
    P.Data[3] := 1 / Max(ABitmap.FHeight, 1);
  end;
  if AWrap = TWrapMode.Tile then
    P.Data[6] := 1;
  P.Data[11] := 3;
  Result := RecPaint(P);
end;

function RecPathKey(const APath: TPathData): UInt64;
var
  C: PCmdPathDef;
  Points: PPathPoints;
  I: Integer;
begin
  Result := PathHash(APath);
  if GKnownPaths = nil then
    GKnownPaths := TDictionary<UInt64, Boolean>.Create;
  if GKnownPaths.ContainsKey(Result) then
    Exit;
  if GKnownPaths.Count >= MaxRecordedPaths then
  begin
    RecAlloc(TCmd.ResetPaths, 0);
    GKnownPaths.Clear;
  end;
  GKnownPaths.Add(Result, True);
  C := RecAlloc(TCmd.PathDef, SizeOf(TCmdPathDef) + APath.Count * SizeOf(TPathPoint));
  C.Key := Result;
  C.Count := APath.Count;
  Points := PPathPoints(PByte(C) + SizeOf(TCmdPathDef));
  for I := 0 to APath.Count - 1 do
    Points[I] := APath[I];
end;

procedure FastCanvasSync;
begin
  // The deferred context of the 3D context belongs to the main thread.
  if GetCurrentThreadId = MainThreadID then
    FastFlushDeferred;
  if GQueue = nil then
    Exit;
  TCanvas.Lock;
  try
    GQueue.Sync;
  finally
    TCanvas.Unlock;
  end;
  GQueue.CheckError;
end;

function FastCanvasRenderBusyMs: Double;
var
  Freq: Int64;
begin
  if (GQueue = nil) or not QueryPerformanceFrequency(Freq) then
    Exit(0);
  Result := GQueue.BusyTicks * 1000 / Freq;
end;

function FastCanvasRenderThreadId: Cardinal;
begin
  if GQueue = nil then
    Result := 0
  else
    Result := GQueue.ThreadId;
end;

function FastCanvasDrawCalls: Integer;
begin
  if (GPlayer = nil) or (GPlayer.FGpu = nil) then
    Result := 0
  else
    Result := GPlayer.FGpu.DrawCalls;
end;

{ TFastBitmap }

function DeviceGone: Boolean;
begin
  Result := (GDeviceLost <> 0) or (TFastDevice.Ready and (TFastDevice.RemovedReason <> S_OK));
end;

procedure MarkDeviceLost;
begin
  AtomicExchange(GDeviceLost, 1);
end;

/// <summary>The classes of the graphics API of the device.</summary>
function Backend: TGpuBackendClass; inline;
begin
  if TFastDevice.Backend = TFastCanvasBackend.D3D12 then
    Result := TGpu12Backend
  else
    Result := TGpu11Backend;
end;

/// <summary>Removes AItem from a registry of live bitmaps or targets (GBitmaps, GTargets). After the shutdown a
/// registry goes with its last entry, and the lock with both: bitmaps may be freed after the canvas service shut
/// down (by FMX units finalized later).</summary>
procedure Unregister(var ARegistry: TDictionary<Pointer, Boolean>; const AItem: Pointer);
begin
  if GBitmapsLock = nil then
    Exit;
  TMonitor.Enter(GBitmapsLock);
  try
    if ARegistry <> nil then
    begin
      ARegistry.Remove(AItem);
      if GFinished and (ARegistry.Count = 0) then
        FreeAndNil(ARegistry);
    end;
  finally
    TMonitor.Exit(GBitmapsLock);
  end;
  if GFinished and (GBitmaps = nil) and (GTargets = nil) then
    FreeAndNil(GBitmapsLock);
end;

constructor TFastBitmap.Create(const AWidth, AHeight: Integer; const AData: Pointer; const APitch: Integer);
begin
  inherited Create;
  FWidth := AWidth;
  FHeight := AHeight;
  CreateTexture(AData, APitch);
  TMonitor.Enter(GBitmapsLock);
  try
    if GBitmaps = nil then
      GBitmaps := TDictionary<Pointer, Boolean>.Create;
    GBitmaps.Add(Self, True);
  finally
    TMonitor.Exit(GBitmapsLock);
  end;
end;

destructor TFastBitmap.Destroy;
begin
  Unregister(GBitmaps, Self);
  ReleaseTexture;
  inherited;
end;

/// <summary>The texture, from AData, the CPU copy or transparent black. On a removed device it stays nil until the
/// device is recreated (CheckDevice).</summary>
procedure TFastBitmap.CreateTexture(const AData: Pointer; const APitch: Integer);
var
  Data: Pointer;
  Pitch: Integer;
begin
  if not TFastDevice.Ready then
  begin
    MarkDeviceLost;
    Exit;
  end;
  Data := AData;
  Pitch := APitch;
  if (Data = nil) and (Length(FCopy) = FWidth * 4 * FHeight) then
  begin
    Data := @FCopy[0];
    Pitch := FWidth * 4;
  end;
  try
    FSurface := Backend.CreateSurface(FWidth, FHeight, Data, Pitch);
  except
    FSurface := nil;
    if DeviceGone then
    begin
      MarkDeviceLost;
      Exit;
    end;
    raise;
  end;
end;

procedure TFastBitmap.ReleaseTexture;
begin
  FD2D := nil;
  FreeAndNil(FSurface);
  FreeAndNil(FHdr);
  FHdrValid := False;
end;

procedure TFastBitmap.GpuWritten;
begin
  if FSurface <> nil then
    FSurface.GpuWritten;
  FCopy := nil;
end;

function TFastBitmap.Surface: TGpuSurface;
begin
  if FHdrValid then
    Result := FHdr
  else
    Result := FSurface;
end;

function TFastBitmap.HdrTarget: TGpuSurface;
begin
  if (FHdr = nil) and (FSurface <> nil) then
    FHdr := Backend.CreateHdrSurface(FWidth, FHeight);
  FHdrValid := FHdr <> nil;
  if FHdrValid then
    FCopy := nil;
  Result := FHdr;
end;

procedure TFastBitmap.SdrTarget;
begin
  FHdrValid := False;
end;

procedure TFastBitmap.Demote;
var
  P: Pointer;
  Pitch, X, Y: Integer;
  Pixels: TArray<Cardinal>;
  Src: PByte;
begin
  if not FHdrValid then
    Exit;
  FHdrValid := False;
  if (FHdr = nil) or (FSurface = nil) then
    Exit;
  FHdr.GpuWritten;
  if not FHdr.Map(P, Pitch) then
    Exit;
  try
    SetLength(Pixels, FWidth * FHeight);
    for Y := 0 to FHeight - 1 do
    begin
      Src := PByte(P) + NativeInt(Y) * Pitch;
      for X := 0 to FWidth - 1 do
        Pixels[Y * FWidth + X] := GpuHalfTexelToBgra(PWord(Src + X * 8));
    end;
  finally
    FHdr.Unmap(False);
  end;
  FSurface.Upload(@Pixels[0], FWidth * 4);
end;

function TFastBitmap.D2DBitmap(const AContext: ID2D1DeviceContext): ID2D1Bitmap1;
var
  Props: TD2D1BitmapProperties1;
begin
  if (FD2D = nil) and (FSurface is TGpu11Surface) then
  begin
    Props := D2D1BitmapProperties1(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED, D2D1_BITMAP_OPTIONS_TARGET);
    if Failed(AContext.CreateBitmapFromDxgiSurface(TGpu11Surface(FSurface).Texture as IDXGISurface, @Props, FD2D)) then
      FD2D := nil;
  end;
  Result := FD2D;
end;

/// <summary>After a new device: FMX keeps some drawings in bitmaps the GPU drew (results of effects), which are
/// transparent now. Marks every effect for an update and repaints every form.</summary>
procedure RedrawForms;

  procedure Walk(const AObject: TFmxObject);
  var
    I: Integer;
  begin
    if AObject is TControl then
      TControl(AObject).UpdateEffects;
    for I := 0 to AObject.ChildrenCount - 1 do
      Walk(AObject.Children[I]);
  end;

var
  I: Integer;
begin
  for I := 0 to Screen.FormCount - 1 do
  begin
    Walk(Screen.Forms[I]);
    Screen.Forms[I].Invalidate;
  end;
end;

/// <summary>Before a scene or a bitmap access: True when the device works. When it was removed (or a loss is
/// simulated), recreates it with everything on it, unless a scene is in progress: that one goes on recording for
/// the old device, the render thread drops the failures, and the next outer scene recovers.</summary>
function CheckDevice: Boolean;
var
  P: TPair<Pointer, Boolean>;
begin
  if not DeviceGone then
    Exit(True);
  if GSceneDepth > 0 then
    Exit(False);
  TCanvas.Lock;
  try
    // What was recorded runs on the old device (failing quietly); after that nothing refers to it.
    FastCanvasSync;
    if GQueue <> nil then
      GQueue.ClearError;
    // As the stock Direct2D canvas does: FMX textures and shaders of fragile 3D contexts let go of the device.
    TMessageManager.DefaultManager.SendMessage(nil, TContextLostMessage.Create, False);
    if Assigned(FastBridge.DeviceLost) then
      FastBridge.DeviceLost();
    TFastDevice.Lock;
    TMonitor.Enter(GBitmapsLock);
    try
      // Everything made on the old device goes before it (a window takes a new flip-model swap chain only when
      // the old one is destroyed: ResetDevice flushes the old context for that). Direct3D 12 does not keep what the
      // GPU still uses alive: wait for it first (on a removed device the wait ends at once).
      Backend.WaitIdle;
      FreeAndNil(GPlayer);
      if GTargets <> nil then
        for P in GTargets do
        begin
          TFastTarget(P.Key).ReleaseViews;
          TFastTarget(P.Key).Bitmap := nil;
        end;
      if GBitmaps <> nil then
        for P in GBitmaps do
          TFastBitmap(P.Key).ReleaseTexture;
      Backend.Shutdown;
      try
        TFastDevice.ResetDevice;
      except
        // No device yet (a driver being installed): try again at the next scene.
        Exit(False);
      end;
      Inc(GDeviceGen);
      if GBitmaps <> nil then
        for P in GBitmaps do
          TFastBitmap(P.Key).CreateTexture(nil, 0);
    finally
      TMonitor.Exit(GBitmapsLock);
      TFastDevice.Unlock;
    end;
    // The recording side mirrors render-thread state (ramp rows, known paths, table entries): send it all again.
    if GRamps <> nil then
      GRamps.Clear;
    if GKnownPaths <> nil then
      GKnownPaths.Clear;
    GClipCount := 1;
    GPaintCount := 0;
    Inc(GEpoch);
    GRecTarget := nil;
    GRunOffset := -1;
    AtomicExchange(GDeviceLost, 0);
    Inc(GDeviceResets);
  finally
    TCanvas.Unlock;
  end;
  // Textures of 3D contexts come back, then the contexts make their buffers.
  TMessageManager.DefaultManager.SendMessage(nil, TContextResetMessage.Create, False);
  if Assigned(FastBridge.DeviceReset) then
    FastBridge.DeviceReset();
  if TThread.CurrentThread.ThreadID = MainThreadID then
    RedrawForms
  else
    TThread.ForceQueue(nil, RedrawForms);
  Result := not DeviceGone;
end;

procedure FastCanvasSimulateDeviceLoss;
begin
  MarkDeviceLost;
end;

function FastCanvasDeviceResets: Integer;
begin
  Result := GDeviceResets;
end;

function FastCanvasHdrInfo(const AForm: TCommonCustomForm): TFastHdrInfo;
var
  H: TWinWindowHandle;
begin
  Result := Default(TFastHdrInfo);
  Result.SdrWhiteNits := 80;
  if (AForm = nil) or (AForm.Handle = nil) then
    Exit;
  H := WindowHandleToPlatform(AForm.Handle);
  Result := FastHdrDisplayOf(H.Wnd);
  // As TFastTarget.Prepare decides for the next frame: windows of 2D forms drawn by FastCanvas on Direct3D 12, not
  // transparent ones (layered windows take 8-bit pixels), not TForm3D (its 3D context draws the window).
  Result.Output := (FastCanvasHdr <> TFastCanvasHdr.Off) and (AForm is TCustomForm) and not H.Transparency and
    (TCustomForm(AForm).Canvas is TFastCanvas) and (TFastDevice.Backend = TFastCanvasBackend.D3D12) and
    ((FastCanvasHdr = TFastCanvasHdr.Force) or Result.DisplayHdr);
end;

function FastCanvasCaptureWindow(const AForm: TCommonCustomForm; out ACapture: TFastWindowCapture): Boolean;
var
  C: TCanvas;
  T: TFastTarget;
begin
  ACapture := Default(TFastWindowCapture);
  Result := False;
  if not (AForm is TCustomForm) then
    Exit;
  C := TCustomForm(AForm).Canvas;
  if not (C is TFastCanvas) then
    Exit;
  FastCanvasSync;
  TFastDevice.Lock;
  try
    T := TFastCanvas(C).FTarget;
    if (T <> nil) and (T.Window <> nil) and (T.Gen = GDeviceGen) then
      Result := T.Window.Capture(ACapture);
  finally
    TFastDevice.Unlock;
  end;
end;

{ TFastTarget }

constructor TFastTarget.Create;
begin
  inherited;
  Gen := GDeviceGen;
  TMonitor.Enter(GBitmapsLock);
  try
    if GTargets = nil then
      GTargets := TDictionary<Pointer, Boolean>.Create;
    GTargets.Add(Self, True);
  finally
    TMonitor.Exit(GBitmapsLock);
  end;
end;

destructor TFastTarget.Destroy;
begin
  Unregister(GTargets, Self);
  ReleaseViews;
  Bitmap := nil;
  inherited;
end;

procedure TFastTarget.ReleaseViews;
begin
  D2D := nil;
  Surface := nil;
  FreeAndNil(Window);
end;

procedure TFastTarget.Prepare(const AWidth, AHeight: Integer; const ATearing: Boolean; const ABitmap: TFastBitmap;
  const AHdr: Byte; const AComposition: Boolean);
var
  Output: TGpuOutput;
  Info: TFastHdrInfo;
  Mode: TFastCanvasHdr;
begin
  if Gen <> GDeviceGen then
  begin
    // The window output and the surfaces of a removed device.
    ReleaseViews;
    Gen := GDeviceGen;
  end;
  if Kind = TTargetKind.Bitmap then
  begin
    Bitmap := ABitmap;
    D2D := nil;
    if ABitmap <> nil then
    begin
      // The canvas draws over the content: HDR content of a 3D context first into the 8-bit surface.
      ABitmap.Demote;
      Surface := ABitmap.FSurface;
    end
    else
      Surface := nil;
  end
  else
  begin
    // Direct2D's bitmap over a buffer must go before the buffers are resized or the swap chain is replaced.
    if (AWidth <> Width) or (AHeight <> Height) or (ATearing <> Tearing) then
      D2D := nil;
    if Window = nil then
      Window := Backend.CreateWindow(Wnd, Kind = TTargetKind.Layered);
    Output := Default(TGpuOutput);
    Mode := TFastCanvasHdr(AHdr and HdrModeMask);
    if (Mode <> TFastCanvasHdr.Off) and (Kind = TTargetKind.Window) then
    begin
      // HDR output: the display of the window now (it may have moved, Windows HDR may have been switched).
      Info := FastHdrDisplayOf(Wnd);
      Output.Hdr := (Mode = TFastCanvasHdr.Force) or Info.DisplayHdr;
      Output.WhiteScale := Info.WhiteScale;
      Output.Linear := AHdr and HdrLinear <> 0;
    end;
    Output.Composition := AComposition and (Kind = TTargetKind.Window);
    Surface := Window.Prepare(AWidth, AHeight, ATearing, Output);
    Tearing := ATearing;
  end;
  Width := AWidth;
  Height := AHeight;
end;

/// <summary>The Direct2D bitmap over the target, made on first use (only Direct2D drawing needs it: the
/// D2DText measurement aid, Direct3D 11 only).</summary>
function TFastTarget.D2DTarget(const AContext: ID2D1DeviceContext): ID2D1Bitmap1;
var
  Props: TD2D1BitmapProperties1;
begin
  if (D2D = nil) and (AContext <> nil) then
    case Kind of
      TTargetKind.Bitmap:
        if Bitmap <> nil then
          D2D := TFastBitmap(Bitmap as TObject).D2DBitmap(AContext);
      TTargetKind.Window, TTargetKind.Layered:
        if Surface is TGpu11Surface then
        begin
          if Kind = TTargetKind.Window then
            Props := D2D1BitmapProperties1(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED,
              D2D1_BITMAP_OPTIONS_TARGET or D2D1_BITMAP_OPTIONS_CANNOT_DRAW)
          else
            Props := D2D1BitmapProperties1(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED,
              D2D1_BITMAP_OPTIONS_TARGET);
          if Failed(AContext.CreateBitmapFromDxgiSurface(TGpu11Surface(Surface).Texture as IDXGISurface, @Props,
            D2D)) then
            D2D := nil;
        end;
    end;
  Result := D2D;
end;

{ TFastCanvasState }

procedure TFastCanvasState.Assign(Source: TPersistent);
begin
  inherited Assign(Source);
  if Source is TFastCanvas then
    FClip := TFastCanvas(Source).FClip;
end;

procedure TFastCanvasState.AssignTo(Dest: TPersistent);
begin
  if Dest is TFastCanvas then
    TFastCanvas(Dest).FClip := FClip;
  inherited AssignTo(Dest);
end;

{ TFastCanvas }

/// <summary>A partial frame the render thread could not start from the frame shown last was not presented: repaint
/// every form in full.</summary>
procedure CheckPartialFrames;
var
  I: Integer;
begin
  if (GPartialMissed = 0) or (GetCurrentThreadId <> MainThreadID) then
    Exit;
  AtomicExchange(GPartialMissed, 0);
  for I := 0 to Screen.FormCount - 1 do
    Screen.Forms[I].Invalidate;
end;

constructor TFastCanvas.CreateFromWindow(const AParent: TWindowHandle; const AWidth, AHeight: Single;
  const AQuality: TCanvasQuality);
var
  H: TWinWindowHandle;
begin
  inherited;
  TFastDevice.Ensure;
  FTarget := TFastTarget.Create;
  H := WindowHandleToPlatform(AParent);
  FTarget.Wnd := H.Wnd;
  if H.Transparency then
  begin
    FTarget.Kind := TTargetKind.Layered;
    H.CreateBuffer(H.WndClientSize.Width, H.WndClientSize.Height);
  end
  else
    FTarget.Kind := TTargetKind.Window;
end;

constructor TFastCanvas.CreateFromBitmap(const ABitmap: TBitmap; const AQuality: TCanvasQuality);
begin
  inherited;
  TFastDevice.Ensure;
  FTarget := TFastTarget.Create;
  FTarget.Kind := TTargetKind.Bitmap;
end;

constructor TFastCanvas.CreateFromPrinter(const APrinter: TAbstractPrinter);
begin
  raise ENotSupportedException.Create('FastCanvas does not print');
end;

destructor TFastCanvas.Destroy;
begin
  // The render thread may still use the target.
  FastCanvasSync;
  if GRecTarget = Self then
    GRecTarget := nil;
  if (GPlayer <> nil) and (GPlayer.FCanvas = Self) then
    GPlayer.FCanvas := nil;
  TFastDevice.Lock;
  try
    FreeAndNil(FTarget);
  finally
    TFastDevice.Unlock;
  end;
  inherited;
end;

class function TFastCanvas.GetCanvasStyle: TCanvasStyles;
begin
  // The global canvas lock stays on: recording into the shared command stream relies on it.
  if FastCanvasPartialFrames and (TFastDevice.Backend = TFastCanvasBackend.D3D12) then
    Result := [TCanvasStyle.SupportClipRects]
  else
    Result := [];
end;

/// <summary>The rectangles of the partial frame in progress into the clip table and the stream (again after
/// ResetTables).</summary>
procedure TFastCanvas.RecRegion;
var
  C: PCmdRegion;
  Clip: PCmdClip;
  First, I: Integer;
begin
  if Length(FRegion) < 2 then
    Exit;
  if GClipCount + Length(FRegion) > GpuMaxClips then
  begin
    // Never twice in a row: a reset leaves room for any region (at most 20 rectangles each). It records the regions
    // this one is drawn in; this one follows.
    GRegionCanvas := FOuterRegion;
    ResetTables;
    GRegionCanvas := Self;
  end;
  First := GClipCount;
  for I := 0 to High(FRegion) do
  begin
    Clip := RecAlloc(TCmd.Clip, SizeOf(TCmdClip));
    Clip.Index := GClipCount;
    FillChar(Clip.Clip, SizeOf(Clip.Clip), 0);
    Clip.Clip.Box := FRegion[I];
    Inc(GClipCount);
  end;
  C := RecAlloc(TCmd.Region, SizeOf(TCmdRegion));
  C.First := First;
  C.Count := Length(FRegion);
  C.Canvas := Self;
end;

class function TFastCanvas.GetAttribute(const Value: TCanvasAttribute): Integer;
begin
  if Value = TCanvasAttribute.MaxBitmapSize then
  begin
    TFastDevice.Ensure;
    Result := TFastDevice.MaxTextureSize;
  end
  else
    Result := inherited;
end;

function TFastCanvas.CreateSaveState: TCanvasSaveState;
begin
  Result := TFastCanvasState.Create;
end;

function TFastCanvas.DoBeginScene(AClipRects: PClipRects; AContextHandle: THandle): Boolean;
var
  H: TWinWindowHandle;
  B: TFastBitmap;
  C: PCmdBegin;
  I: Integer;
begin
  CheckPartialFrames;
  if not CheckDevice then
    Exit(False);
  B := nil;
  if FTarget.Kind = TTargetKind.Bitmap then
  begin
    if (Bitmap = nil) or not Bitmap.HandleAllocated then
      Exit(False);
    B := TFastBitmap(Bitmap.Handle);
    if B.FSurface = nil then
      Exit(False);
    FPixelW := B.FWidth;
    FPixelH := B.FHeight;
    // The scene writes the texture: a later Map copies it again.
    B.GpuWritten;
  end
  else
  begin
    H := WindowHandleToPlatform(Parent);
    FPixelW := H.WndClientSize.Width;
    FPixelH := H.WndClientSize.Height;
    if (FTarget.Kind = TTargetKind.Layered) and ((H.BufferSize.Width <> FPixelW) or (H.BufferSize.Height <> FPixelH)) then
      H.ResizeBuffer(FPixelW, FPixelH);
  end;
  if (FPixelW <= 0) or (FPixelH <= 0) then
    Exit(False);
  Result := inherited DoBeginScene(AClipRects, AContextHandle);
  if not Result then
    Exit;
  if (GSceneDepth = 0) and (Queue.Threaded <> FastCanvasRenderThread) then
  begin
    // 3D work recorded for the render thread goes first.
    if GetCurrentThreadId = MainThreadID then
      FastFlushDeferred;
    Queue.SetThreaded(FastCanvasRenderThread);
  end;
  Inc(GSceneDepth);
  FClip.Clip.Box := TRectF.Create(0, 0, FPixelW, FPixelH);
  FClip.Clip.Count := 0;
  FClip.Index := 0;
  FClip.Epoch := GEpoch;
  FRegion := nil;
  if AClipRects <> nil then
    if FTarget.Kind <> TTargetKind.Bitmap then
      PartialRegion(AClipRects^)
    else if TCanvasStyle.SupportClipRects in GetCanvasStyle then
      // FMX clears only these rectangles and paints only the controls in them (TLayer3D): the rest of the bitmap
      // must stay as it is.
      RegionOf(AClipRects^);
  RecTarget(Self);
  C := RecAlloc(TCmd.BeginFrame, SizeOf(TCmdBegin), B);
  C.Width := FPixelW;
  C.Height := FPixelH;
  C.Aliased := Quality = TCanvasQuality.HighPerformance;
  C.Tearing := TFastCanvasOption.AllowTearing in FastCanvasOptions;
  // A partial window frame starts from the last one; a bitmap keeps its pixels anyway.
  C.Partial := (FRegion <> nil) and (FTarget.Kind <> TTargetKind.Bitmap);
  // Tearing needs a swap chain of the window.
  C.Composition := (FTarget.Kind = TTargetKind.Window) and
    (FastCanvasPresentation = TFastCanvasPresentation.Composition) and not C.Tearing;
  if FTarget.Kind = TTargetKind.Window then
    if not C.Composition then
      FFlipShown := True
    else if FFlipShown and not FRecreateQueued then
      QueueRecreateWindow;
  C.Hdr := 0;
  if (FastCanvasHdr <> TFastCanvasHdr.Off) and (FTarget.Kind = TTargetKind.Window) and
    (TFastDevice.Backend = TFastCanvasBackend.D3D12) then
  begin
    C.Hdr := Ord(FastCanvasHdr);
    if TFastCanvasOption.HdrLinearBlend in FastCanvasOptions then
      C.Hdr := C.Hdr or HdrLinear;
  end;
  C.Bitmap := B;
  if FRegion <> nil then
  begin
    // The union bounds what is drawn (also on the CPU: Visible); several rectangles are tested per pixel.
    FClip.Clip.Box := FRegion[0];
    for I := 1 to High(FRegion) do
      FClip.Clip.Box := TRectF.Union(FClip.Clip.Box, FRegion[I]);
    FClip.Index := -1;
    FOuterRegion := GRegionCanvas;
    GRegionCanvas := Self;
    RecRegion;
  end;
end;

type
  TFormAccess = class(TCommonCustomForm);

/// <summary>The window switched from its own swap chain to a composition one. DWM goes on showing the last frame of
/// the window's swap chain under the composition visual, through its transparent pixels (neither GDI drawing into
/// the window, nor resizing, hiding or making it layered for a moment clears it; measured 2026-10-13): the form gets a
/// new window (as FMX does when BorderStyle changes), whose frames are composition ones from the start.</summary>
procedure TFastCanvas.QueueRecreateWindow;
var
  Wnd: HWND;
begin
  FRecreateQueued := True;
  Wnd := FTarget.Wnd;
  // Not from inside a paint: on the main thread, once it is idle; the form may be gone by then.
  TThread.ForceQueue(nil,
    procedure
    var
      Form: TCommonCustomForm;
    begin
      Form := FMX.Platform.Win.FindWindow(Wnd);
      if Form <> nil then
        TFormAccess(Form).Recreate;
    end);
end;

/// <summary>Window scene: FRegion := the rectangles FMX updates, in pixels (whole pixels around them), when they
/// leave part of the window as it was and the last frame recorded for presenting has the same size on the same
/// device; else nil (the frame draws the whole window).</summary>
procedure TFastCanvas.PartialRegion(const ARects: TClipRects);
begin
  if (FKeptW <> FPixelW) or (FKeptH <> FPixelH) or (FKeptGen <> GDeviceGen) or
    (TFastDevice.Backend <> TFastCanvasBackend.D3D12) then
    Exit;
  RegionOf(ARects);
end;

/// <summary>FRegion := the rectangles, in pixels (whole pixels around them, inside the target); nil when there are
/// none or one of them is the whole target.</summary>
procedure TFastCanvas.RegionOf(const ARects: TClipRects);
var
  I, N: Integer;
  R: TRectF;
begin
  N := Length(ARects);
  if N = 0 then
    Exit;
  SetLength(FRegion, N);
  for I := 0 to N - 1 do
  begin
    // FMX gives them in logical units.
    R := TRectF.Create(ARects[I].Left * Scale, ARects[I].Top * Scale, ARects[I].Right * Scale,
      ARects[I].Bottom * Scale);
    R := TRectF.Create(Floor(R.Left), Floor(R.Top), Ceil(R.Right), Ceil(R.Bottom));
    R.Intersect(TRectF.Create(0, 0, FPixelW, FPixelH));
    if R.IsEmpty then
      R := TRectF.Empty;
    FRegion[I] := R;
    if (R.Left <= 0) and (R.Top <= 0) and (R.Right >= FPixelW) and (R.Bottom >= FPixelH) then
    begin
      FRegion := nil;
      Exit;
    end;
  end;
end;

procedure TFastCanvas.DoEndScene;
var
  C: PCmdEnd;
  H: TWinWindowHandle;
  Q: TRenderQueue;
  R: PCmdRegion;
begin
  if GRegionCanvas = Self then
  begin
    GRegionCanvas := FOuterRegion;
    FOuterRegion := nil;
    R := RecAlloc(TCmd.Region, SizeOf(TCmdRegion));
    R.First := 0;
    R.Count := 0;
    R.Canvas := Self;
  end;
  FRegion := nil;
  if FTarget.Kind <> TTargetKind.Bitmap then
  begin
    // A partial frame of the same size can start from this one.
    FKeptW := FPixelW;
    FKeptH := FPixelH;
    FKeptGen := GDeviceGen;
  end;
  RecTarget(Self);
  C := RecAlloc(TCmd.EndFrame, SizeOf(TCmdEnd));
  C.Present := FTarget.Kind = TTargetKind.Window;
  C.Window := FTarget.Kind <> TTargetKind.Bitmap;
  C.Pad := 0;
  C.Bits := nil;
  C.BitsWidth := 0;
  C.BitsHeight := 0;
  if FTarget.Kind = TTargetKind.Layered then
  begin
    H := WindowHandleToPlatform(Parent);
    C.Bits := H.BufferBits;
    C.BitsWidth := H.BufferSize.Width;
    C.BitsHeight := H.BufferSize.Height;
  end;
  inherited;
  Dec(GSceneDepth);
  Q := GQueue;
  if FTarget.Kind <> TTargetKind.Bitmap then
  begin
    Q.FrameSubmitted;
    Q.Submit;
    // FMX copies the buffer of a transparent window right after EndScene.
    if (FTarget.Kind = TTargetKind.Layered) or (GetCurrentThreadId <> MainThreadID) then
      Q.WaitSubmitted
    else
      Q.WaitFrames(FastCanvasFramesInFlight);
    Q.CheckError;
  end
  else if GetCurrentThreadId <> MainThreadID then
    Q.Sync;
end;

procedure TFastCanvas.DoFlush;
begin
  // Commands run in stream order; nothing to do.
end;

procedure TFastCanvas.DoSetMatrix(const M: TMatrix);
var
  S: Single;
begin
  S := Scale;
  FDev.M11 := M.m11 * S;
  FDev.M12 := M.m12 * S;
  FDev.M21 := M.m21 * S;
  FDev.M22 := M.m22 * S;
  FDev.Dx := M.m31 * S;
  FDev.Dy := M.m32 * S;
  FAxis := (Abs(FDev.M12) < 1E-5) and (Abs(FDev.M21) < 1E-5);
  if FAxis then
    FDevScale := Max(Abs(FDev.M11), Abs(FDev.M22))
  else
    FDevScale := Max(Sqrt(Sqr(FDev.M11) + Sqr(FDev.M12)), Sqrt(Sqr(FDev.M21) + Sqr(FDev.M22)));
end;

function TFastCanvas.DeviceBox(const R: TRectF): TRectF;
var
  P: array[0..3] of TPointF;
  I: Integer;
begin
  P[0] := FDev.Apply(R.Left, R.Top);
  P[1] := FDev.Apply(R.Right, R.Bottom);
  if FAxis then
    Exit(NormRect(TRectF.Create(P[0], P[1])));
  P[2] := FDev.Apply(R.Right, R.Top);
  P[3] := FDev.Apply(R.Left, R.Bottom);
  Result := TRectF.Create(P[0], P[0]);
  for I := 1 to 3 do
  begin
    Result.Left := Min(Result.Left, P[I].X);
    Result.Top := Min(Result.Top, P[I].Y);
    Result.Right := Max(Result.Right, P[I].X);
    Result.Bottom := Max(Result.Bottom, P[I].Y);
  end;
end;

function TFastCanvas.Visible(const R: TRectF; const AGrow: Single): Boolean;
var
  B, C: TRectF;
  G: Single;
begin
  B := DeviceBox(R);
  G := AGrow * FDevScale + 1;
  C := FClip.Clip.Box;
  Result := (B.Right + G > C.Left) and (B.Left - G < C.Right) and (B.Bottom + G > C.Top) and (B.Top - G < C.Bottom);
end;

function TFastCanvas.ClipIndex: Cardinal;
var
  C: PCmdClip;
begin
  if (FClip.Index >= 0) and (FClip.Epoch = GEpoch) then
    Exit(FClip.Index);
  if GClipCount >= GpuMaxClips then
    ResetTables;
  FClip.Index := GClipCount;
  FClip.Epoch := GEpoch;
  Inc(GClipCount);
  C := RecAlloc(TCmd.Clip, SizeOf(TCmdClip));
  C.Index := FClip.Index;
  C.Clip := FClip.Clip;
  Result := FClip.Index;
end;

/// <summary>An instance of the current matrix and clip; call after everything else that records commands (paints,
/// clips): the result is valid until the next allocation in the stream.</summary>
function TFastCanvas.AddInstance(const AFlags: Cardinal; const R: TRectF): PGpuInstance;
var
  Clip: Cardinal;
begin
  Clip := ClipIndex;
  Result := RecInstance(Self);
  Result.X0 := R.Left;
  Result.Y0 := R.Top;
  Result.X1 := R.Right;
  Result.Y1 := R.Bottom;
  Result.M11 := FDev.M11;
  Result.M12 := FDev.M12;
  Result.M21 := FDev.M21;
  Result.M22 := FDev.M22;
  Result.Dx := FDev.Dx;
  Result.Dy := FDev.Dy;
  Result.Rx := 0;
  Result.Ry := 0;
  Result.U0 := 0;
  Result.V0 := 0;
  Result.U1 := 0;
  Result.V1 := 0;
  Result.Color := 0;
  Result.Flags := AFlags;
  Result.Clip := Clip;
  Result.Paint := 0;
  Result.Stroke := 0;
  Result.Texture := nil;
  if FPaintTexture <> nil then
  begin
    // A bitmap brush: the renderer binds the bitmap and puts its slot into the flags.
    Result.Texture := Pointer(IGpuTexture(FPaintTexture));
    GQueue.Chunk.KeepAlive(IGpuTexture(FPaintTexture));
    FPaintTexture := nil;
  end;
end;

function TFastCanvas.PaintOf(const ABrush: TBrush; const R: TRectF; const AOpacity: Single;
  out AColor, APaint: Cardinal): TPaintResult;
begin
  AColor := 0;
  APaint := 0;
  FPaintTexture := nil;
  if ABrush = nil then
    Exit(TPaintResult.None);
  case ABrush.Kind of
    TBrushKind.Solid:
      begin
        AColor := MulAlpha(ABrush.Color, AOpacity);
        if AColor shr 24 = 0 then
          Exit(TPaintResult.None);
        Result := TPaintResult.Gpu;
      end;
    TBrushKind.Gradient:
      begin
        AColor := OpacityColor(AOpacity);
        if (ABrush.Gradient.Points.Count < 2) or (AColor shr 24 = 0) then
          Exit(TPaintResult.None);
        APaint := RecGradientPaint(ABrush.Gradient, R) + 1;
        Result := TPaintResult.Gpu;
      end;
    TBrushKind.Bitmap:
      if (ABrush.Bitmap.Bitmap = nil) or not ABrush.Bitmap.Bitmap.HandleAllocated then
        Result := TPaintResult.None
      else if not ABrush.Bitmap.Bitmap.CanvasClass.InheritsFrom(TFastCanvas) or
        (TFastBitmap(ABrush.Bitmap.Bitmap.Handle).FSurface = nil) then
        Result := TPaintResult.D2D
      else
      begin
        AColor := OpacityColor(AOpacity);
        if AColor shr 24 = 0 then
          Exit(TPaintResult.None);
        FPaintTexture := TFastBitmap(ABrush.Bitmap.Bitmap.Handle);
        APaint := RecImagePaint(FPaintTexture, ABrush.Bitmap.WrapMode, R) + 1;
        Result := TPaintResult.Gpu;
      end;
  else
    Result := TPaintResult.None;
  end;
end;

function TFastCanvas.StrokeOf(const ABrush: TStrokeBrush; const R: TRectF; const AOpacity: Single;
  const ALine: Boolean; out AColor, APaint, AFlags: Cardinal; out AWidth: Single): TPaintResult;
var
  B: TBrush;
  S: TStrokeBrush;
begin
  AColor := 0;
  APaint := 0;
  AFlags := 0;
  AWidth := 0;
  B := ResolveBrush(ABrush);
  if B = nil then
    Exit(TPaintResult.None);
  if B is TStrokeBrush then
    S := TStrokeBrush(B)
  else
    S := ABrush;
  AWidth := S.Thickness;
  if (AWidth <= 0) or (B.Kind = TBrushKind.None) then
    Exit(TPaintResult.None);
  if (B.Kind = TBrushKind.Bitmap) or (ALine and (B.Kind = TBrushKind.Gradient)) or
    ((S.Dash <> TStrokeDash.Solid) and not ALine) then
    Exit(TPaintResult.D2D);
  // The stock Direct2D canvas draws FMX flat caps as square caps; do the same.
  if S.Cap = TStrokeCap.Round then
    AFlags := 2 shl GpuCapShift
  else
    AFlags := 1 shl GpuCapShift;
  case S.Join of
    TStrokeJoin.Round:
      AFlags := AFlags or (1 shl GpuJoinShift);
    TStrokeJoin.Bevel:
      AFlags := AFlags or (2 shl GpuJoinShift);
  end;
  Result := PaintOf(B, R, AOpacity, AColor, APaint);
  if (Result = TPaintResult.Gpu) and (S.Dash <> TStrokeDash.Solid) then
  begin
    // Lines only (see above): the paint index is the dash pattern.
    APaint := DashPattern(S);
    if APaint = 0 then
      Exit(TPaintResult.D2D);
    AFlags := AFlags or GpuDashed;
  end;
end;

/// <summary>Paint table entry of a dash pattern + 1, 0 when the pattern is not supported by the shader. Lengths in
/// stroke widths: the predefined styles as Direct2D defines them (D2D1_DASH_STYLE), Custom from DashArray.</summary>
function TFastCanvas.DashPattern(const AStroke: TStrokeBrush): Cardinal;
var
  P: TGpuPaint;
  Dashes: TArray<Single>;
  I: Integer;
  Period: Single;
begin
  case AStroke.Dash of
    TStrokeDash.Dash:
      Dashes := [2, 2];
    TStrokeDash.Dot:
      Dashes := [0, 2];
    TStrokeDash.DashDot:
      Dashes := [2, 2, 0, 2];
    TStrokeDash.DashDotDot:
      Dashes := [2, 2, 0, 2, 0, 2];
  else
    Dashes := AStroke.DashArray;
  end;
  if (Length(Dashes) = 0) or Odd(Length(Dashes)) or (Length(Dashes) > 6) then
    Exit(0);
  FillChar(P, SizeOf(P), 0);
  Period := 0;
  for I := 0 to High(Dashes) do
  begin
    if Dashes[I] < 0 then
      Exit(0);
    P.Data[I] := Dashes[I];
    Period := Period + Dashes[I];
  end;
  if Period <= 0 then
    Exit(0);
  P.Data[6] := Length(Dashes);
  P.Data[7] := AStroke.DashOffset;
  P.Data[8] := Period;
  Result := RecPaint(P) + 1;
end;

procedure TFastCanvas.DoFillRect(const ARect: TRectF; const AOpacity: Single; const ABrush: TBrush);
var
  R: TRectF;
  Color, Paint: Cardinal;
  I: PGpuInstance;
begin
  R := NormRect(ARect);
  if not Visible(R, 0) then
    Exit;
  case PaintOf(ResolveBrush(ABrush), R, AOpacity, Color, Paint) of
    TPaintResult.Gpu:
      begin
        I := AddInstance(GpuKindFillRect, R);
        I.Color := Color;
        I.Paint := Paint;
      end;
    TPaintResult.D2D:
      RecD2D(TD2DShape.Rect, True, R, 0, 0, nil, ABrush, AOpacity);
  end;
end;

procedure TFastCanvas.DoFillRoundRect(const ARect: TRectF; const XRadius, YRadius: Single; const ACorners: TCorners;
  const AOpacity: Single; const ABrush: TBrush; const ACornerType: TCornerType);
var
  R: TRectF;
  Color, Paint, Mask: Cardinal;
  I: PGpuInstance;
begin
  R := NormRect(ARect);
  Mask := CornerMask(ACorners);
  if (XRadius <= 0) or (YRadius <= 0) or (Mask = 0) then
  begin
    DoFillRect(R, AOpacity, ABrush);
    Exit;
  end;
  // Other corner types, and radii that FMX clamps (its path then distorts the corners,
  // FMX.Graphics.pas:7104-7120): the generic path.
  if (ACornerType <> TCornerType.Round) or (XRadius * 2 > R.Width) or (YRadius * 2 > R.Height) then
  begin
    inherited;
    Exit;
  end;
  if not Visible(R, 0) then
    Exit;
  case PaintOf(ResolveBrush(ABrush), R, AOpacity, Color, Paint) of
    TPaintResult.Gpu:
      begin
        I := AddInstance(GpuKindFillRect or (Mask shl GpuCornerShift), R);
        I.Rx := XRadius;
        I.Ry := YRadius;
        I.Color := Color;
        I.Paint := Paint;
      end;
    TPaintResult.D2D:
      if Mask = 15 then
        RecD2D(TD2DShape.RoundRect, True, R, XRadius, YRadius, nil, ABrush, AOpacity)
      else
        inherited;
  end;
end;

procedure TFastCanvas.DoDrawRoundRect(const ARect: TRectF; const XRadius, YRadius: Single; const ACorners: TCorners;
  const AOpacity: Single; const ABrush: TStrokeBrush; const ACornerType: TCornerType);
var
  R: TRectF;
  Color, Paint, Flags, Mask: Cardinal;
  W: Single;
  I: PGpuInstance;
begin
  R := NormRect(ARect);
  Mask := CornerMask(ACorners);
  if (XRadius <= 0) or (YRadius <= 0) or (Mask = 0) then
  begin
    DoDrawRect(R, AOpacity, ABrush);
    Exit;
  end;
  if (ACornerType <> TCornerType.Round) or (XRadius * 2 > R.Width) or (YRadius * 2 > R.Height) then
  begin
    inherited;
    Exit;
  end;
  case StrokeOf(ABrush, R, AOpacity, False, Color, Paint, Flags, W) of
    TPaintResult.Gpu:
      if Visible(R, W / 2) then
      begin
        I := AddInstance(GpuKindStrokeRect or Flags or (Mask shl GpuCornerShift), R);
        I.Rx := XRadius;
        I.Ry := YRadius;
        I.Stroke := W;
        I.Color := Color;
        I.Paint := Paint;
      end;
    TPaintResult.D2D:
      RecD2D(TD2DShape.RoundRect, False, R, XRadius, YRadius, nil, ABrush, AOpacity);
  end;
end;

procedure TFastCanvas.DoDrawRect(const ARect: TRectF; const AOpacity: Single; const ABrush: TStrokeBrush);
var
  R: TRectF;
  Color, Paint, Flags: Cardinal;
  W: Single;
  I: PGpuInstance;
begin
  R := NormRect(ARect);
  case StrokeOf(ABrush, R, AOpacity, False, Color, Paint, Flags, W) of
    TPaintResult.Gpu:
      if Visible(R, W / 2) then
      begin
        I := AddInstance(GpuKindStrokeRect or Flags, R);
        I.Stroke := W;
        I.Color := Color;
        I.Paint := Paint;
      end;
    TPaintResult.D2D:
      RecD2D(TD2DShape.Rect, False, R, 0, 0, nil, ABrush, AOpacity);
  end;
end;

procedure TFastCanvas.DoFillEllipse(const ARect: TRectF; const AOpacity: Single; const ABrush: TBrush);
var
  R: TRectF;
  Color, Paint: Cardinal;
  I: PGpuInstance;
begin
  R := NormRect(ARect);
  if not Visible(R, 0) then
    Exit;
  case PaintOf(ResolveBrush(ABrush), R, AOpacity, Color, Paint) of
    TPaintResult.Gpu:
      begin
        I := AddInstance(GpuKindFillEllipse, R);
        I.Color := Color;
        I.Paint := Paint;
      end;
    TPaintResult.D2D:
      RecD2D(TD2DShape.Ellipse, True, R, 0, 0, nil, ABrush, AOpacity);
  end;
end;

procedure TFastCanvas.DoDrawEllipse(const ARect: TRectF; const AOpacity: Single; const ABrush: TStrokeBrush);
var
  R: TRectF;
  Color, Paint, Flags: Cardinal;
  W: Single;
  I: PGpuInstance;
begin
  R := NormRect(ARect);
  case StrokeOf(ABrush, R, AOpacity, False, Color, Paint, Flags, W) of
    TPaintResult.Gpu:
      if Visible(R, W / 2) then
      begin
        I := AddInstance(GpuKindStrokeEllipse or Flags, R);
        I.Stroke := W;
        I.Color := Color;
        I.Paint := Paint;
      end;
    TPaintResult.D2D:
      RecD2D(TD2DShape.Ellipse, False, R, 0, 0, nil, ABrush, AOpacity);
  end;
end;

procedure TFastCanvas.DoDrawLine(const APt1, APt2: TPointF; const AOpacity: Single; const ABrush: TStrokeBrush);
var
  R: TRectF;
  Color, Paint, Flags: Cardinal;
  W: Single;
  I: PGpuInstance;
begin
  R := TRectF.Create(APt1, APt2);
  case StrokeOf(ABrush, NormRect(R), AOpacity, True, Color, Paint, Flags, W) of
    TPaintResult.Gpu:
      if Visible(NormRect(R), W / 2) then
      begin
        I := AddInstance(GpuKindLine or Flags, R);
        I.Stroke := W;
        I.Color := Color;
        I.Paint := Paint;
      end;
    TPaintResult.D2D:
      RecD2D(TD2DShape.Line, False, R, 0, 0, nil, ABrush, AOpacity);
  end;
end;

procedure TFastCanvas.DoFillPath(const APath: TPathData; const AOpacity: Single; const ABrush: TBrush);
begin
  if (APath = nil) or APath.IsEmpty or not Visible(APath.GetBounds, 0) then
    Exit;
  RecD2D(TD2DShape.Path, True, APath.GetBounds, 0, 0, APath, ABrush, AOpacity);
end;

procedure TFastCanvas.DoDrawPath(const APath: TPathData; const AOpacity: Single; const ABrush: TStrokeBrush);
begin
  if (APath = nil) or APath.IsEmpty or not Visible(APath.GetBounds, ABrush.Thickness / 2) then
    Exit;
  RecD2D(TD2DShape.Path, False, APath.GetBounds, 0, 0, APath, ABrush, AOpacity);
end;

procedure TFastCanvas.DoDrawBitmap(const ABitmap: TBitmap; const SrcRect, DstRect: TRectF; const AOpacity: Single;
  const HighSpeed: Boolean);
var
  B: TFastBitmap;
  D, S: TRectF;
  I: PGpuInstance;
  Flags, Color: Cardinal;
  Tex: IGpuTexture;
begin
  if (ABitmap = nil) or not ABitmap.HandleAllocated or not ABitmap.CanvasClass.InheritsFrom(TFastCanvas) then
    Exit;
  B := TFastBitmap(ABitmap.Handle);
  D := DstRect;
  S := SrcRect;
  if D.Left > D.Right then
  begin
    D := TRectF.Create(D.Right, D.Top, D.Left, D.Bottom);
    S := TRectF.Create(S.Right, S.Top, S.Left, S.Bottom);
  end;
  if D.Top > D.Bottom then
  begin
    D := TRectF.Create(D.Left, D.Bottom, D.Right, D.Top);
    S := TRectF.Create(S.Left, S.Bottom, S.Right, S.Top);
  end;
  Color := OpacityColor(AOpacity);
  if (Color shr 24 = 0) or not Visible(D, 0) then
    Exit;
  Flags := GpuKindImage;
  if HighSpeed then
    Flags := Flags or GpuNearest;
  Tex := B;
  FPaintTexture := nil;
  I := AddInstance(Flags, D);
  I.U0 := S.Left / B.FWidth;
  I.V0 := S.Top / B.FHeight;
  I.U1 := S.Right / B.FWidth;
  I.V1 := S.Bottom / B.FHeight;
  I.Color := Color;
  I.Texture := Pointer(Tex);
  GQueue.Chunk.KeepAlive(Tex);
end;

procedure TFastCanvas.DoClear(const Color: TAlphaColor);
var
  C: PCmdFillCopy;
  Clip: Cardinal;
begin
  if (FClip.Clip.Count = 0) and (FClip.Clip.Box.Left <= 0) and (FClip.Clip.Box.Top <= 0) and
    (FClip.Clip.Box.Right >= FPixelW) and (FClip.Clip.Box.Bottom >= FPixelH) then
  begin
    RecTarget(Self);
    PCmdColor(RecAlloc(TCmd.Clear, SizeOf(TCmdColor))).Color := Color;
    Exit;
  end;
  Clip := ClipIndex;
  RecTarget(Self);
  C := RecAlloc(TCmd.FillCopy, SizeOf(TCmdFillCopy));
  C.Rect := TRectF.Create(0, 0, FPixelW, FPixelH);
  C.Color := Color;
  C.Clip := Clip;
end;

procedure TFastCanvas.DoClearRect(const ARect: TRectF; const AColor: TAlphaColor);
var
  C: PCmdFillCopy;
  Clip: Cardinal;
  R: TRectF;
begin
  R := DeviceBox(NormRect(ARect));
  if (R.Left <= 0) and (R.Top <= 0) and (R.Right >= FPixelW) and (R.Bottom >= FPixelH) then
  begin
    // The whole target (FMX clears the update rectangle of a full repaint this way with SupportClipRects): a clear
    // of the view instead of a full-screen draw (ellipses light 5460 -> 7470 FPS, measured 2026-10-08).
    DoClear(AColor);
    Exit;
  end;
  Clip := ClipIndex;
  RecTarget(Self);
  C := RecAlloc(TCmd.FillCopy, SizeOf(TCmdFillCopy));
  C.Rect := R;
  C.Color := AColor;
  C.Clip := Clip;
end;

procedure TFastCanvas.IntersectDeviceClip(const R: TRectF; const AExclude: Boolean);
var
  O: TGpuOrientedRect;
  T: TGpuAffine;
begin
  FClippingChangeCount := FClippingChangeCount + 1;
  FClip.Index := -1;
  if FAxis and not AExclude then
  begin
    FClip.Clip.Box.Intersect(DeviceBox(R));
    if FClip.Clip.Box.IsEmpty then
      FClip.Clip.Box := TRectF.Empty;
    Exit;
  end;
  if not AExclude then
  begin
    FClip.Clip.Box.Intersect(DeviceBox(R));
    if FClip.Clip.Box.IsEmpty then
      FClip.Clip.Box := TRectF.Empty;
  end;
  if FClip.Clip.Count = Length(FClip.Clip.Oriented) then
    // Deeper rotated clips are approximated by their bounding boxes (above).
    Exit;
  // Clip-local coordinates start at the rectangle's top-left corner.
  T := FDev;
  T.Dx := FDev.Dx + R.Left * FDev.M11 + R.Top * FDev.M21;
  T.Dy := FDev.Dy + R.Left * FDev.M12 + R.Top * FDev.M22;
  O.Fwd := T;
  O.Inv := T.Inverse;
  O.Width := R.Width;
  O.Height := R.Height;
  O.Exclude := AExclude;
  FClip.Clip.Oriented[FClip.Clip.Count] := O;
  Inc(FClip.Clip.Count);
end;

procedure TFastCanvas.DoIntersectClipRect(const ARect: TRectF);
begin
  IntersectDeviceClip(NormRect(ARect), False);
end;

procedure TFastCanvas.DoExcludeClipRect(const ARect: TRectF);
begin
  IntersectDeviceClip(NormRect(ARect), True);
end;

procedure TFastCanvas.RecD2D(const AShape: TD2DShape; const AFill: Boolean; const R: TRectF; const Rx, Ry: Single;
  const APath: TPathData; const ABrush: TBrush; const AOpacity: Single);
var
  B: TBrush;
  S: TStrokeBrush;
  Kind: TD2DBrushKind;
  PathKey, GradKey: UInt64;
  Clip: Cardinal;
  Dashes: TArray<Single>;
  Offsets: TArray<Single>;
  Colors: TArray<TAlphaColor>;
  Stops: TArray<TD2D1GradientStop>;
  C: PCmdD2D;
  Bmp: TFastBitmap;
  Ref: IInterface;
  I, N: Integer;
  G: TGradient;
  Tail: PByte;
  GpuOk: Boolean;
  GpuColor, GpuPaint: Cardinal;
begin
  B := ResolveBrush(ABrush);
  if (B = nil) or (B.Kind = TBrushKind.None) then
    Exit;
  S := nil;
  if not AFill then
  begin
    if B is TStrokeBrush then
      S := TStrokeBrush(B)
    else if ABrush is TStrokeBrush then
      S := TStrokeBrush(ABrush)
    else
      Exit;
    if S.Thickness <= 0 then
      Exit;
  end;
  Bmp := nil;
  case B.Kind of
    TBrushKind.Gradient:
      begin
        if B.Gradient.Points.Count < 2 then
          Exit;
        if B.Gradient.Style = TGradientStyle.Radial then
          Kind := TD2DBrushKind.Radial
        else
          Kind := TD2DBrushKind.Linear;
      end;
    TBrushKind.Bitmap:
      begin
        if (B.Bitmap.Bitmap = nil) or not B.Bitmap.Bitmap.HandleAllocated or
          not B.Bitmap.Bitmap.CanvasClass.InheritsFrom(TFastCanvas) then
          Exit;
        Kind := TD2DBrushKind.Bitmap;
        Bmp := TFastBitmap(B.Bitmap.Bitmap.Handle);
        Ref := Bmp;
      end;
  else
    Kind := TD2DBrushKind.Solid;
  end;
  G := nil;
  PathKey := 0;
  if AShape = TD2DShape.Path then
    PathKey := RecPathKey(APath);
  // Shapes with a solid or gradient paint (paths, dashed outlines, gradient lines) go to the GPU renderer as
  // polygons; the paint is recorded here, before the command is allocated.
  GpuOk := PaintOf(B, R, AOpacity, GpuColor, GpuPaint) = TPaintResult.Gpu;
  if (S <> nil) and (S.Dash = TStrokeDash.Custom) then
    Dashes := S.DashArray;
  GradKey := 0;
  if Kind in [TD2DBrushKind.Linear, TD2DBrushKind.Radial] then
  begin
    G := B.Gradient;
    SortedStops(G, Offsets, Colors);
    N := Length(Offsets);
    SetLength(Stops, N);
    for I := 0 to N - 1 do
    begin
      // Direct2D runs a radial ramp from the center outwards, FMX from the edge inwards.
      if Kind = TD2DBrushKind.Radial then
        Stops[N - 1 - I].position := 1 - Offsets[I]
      else
        Stops[I].position := Offsets[I];
      if Kind = TD2DBrushKind.Radial then
        Stops[N - 1 - I].color := D2DColor(Colors[I])
      else
        Stops[I].color := D2DColor(Colors[I]);
    end;
    GradKey := GradientHash(G);
  end;
  Clip := ClipIndex;
  RecTarget(Self);
  C := RecAlloc(TCmd.D2DShape, SizeOf(TCmdD2D) + Length(Dashes) * SizeOf(Single) +
    Length(Stops) * SizeOf(TD2D1GradientStop), Ref);
  FillChar(C^, SizeOf(TCmdD2D), 0);
  C.Shape := AShape;
  C.Brush := Kind;
  C.Fill := AFill;
  C.Clip := Clip;
  C.Matrix := FDev;
  C.R := R;
  C.Rx := Rx;
  C.Ry := Ry;
  C.PathKey := PathKey;
  C.Opacity := EnsureRange(AOpacity, 0, 1);
  if Kind = TD2DBrushKind.Solid then
    C.Color := MulAlpha(B.Color, AOpacity);
  if S <> nil then
  begin
    C.StrokeWidth := S.Thickness;
    C.Cap := Ord(S.Cap);
    C.Join := Ord(S.Join);
    C.Dash := Ord(S.Dash);
    C.DashOffset := S.DashOffset;
  end;
  C.DashCount := Length(Dashes);
  C.StopCount := Length(Stops);
  C.GradKey := GradKey;
  if Kind = TD2DBrushKind.Linear then
  begin
    C.G0 := TPointF.Create(R.Left + G.StartPosition.X * R.Width, R.Top + G.StartPosition.Y * R.Height);
    C.G1 := TPointF.Create(R.Left + G.StopPosition.X * R.Width, R.Top + G.StopPosition.Y * R.Height);
  end
  else if Kind = TD2DBrushKind.Radial then
  begin
    C.G0 := TPointF.Create(R.Left + R.Width * G.RadialTransform.RotationCenter.X,
      R.Top + R.Height * G.RadialTransform.RotationCenter.Y);
    C.G1 := TPointF.Create(R.Width / 2, R.Height / 2);
    C.GMatrix := Affine(G.RadialTransform.Matrix);
  end
  else if Kind = TD2DBrushKind.Bitmap then
  begin
    C.Bitmap := Bmp;
    C.BitmapExtend := Ord(B.Bitmap.WrapMode);
    C.BitmapMatrix.M11 := 1;
    C.BitmapMatrix.M22 := 1;
    if B.Bitmap.WrapMode = TWrapMode.TileStretch then
    begin
      C.BitmapMatrix.M11 := R.Width / Bmp.FWidth;
      C.BitmapMatrix.M22 := R.Height / Bmp.FHeight;
      C.BitmapMatrix.Dx := R.Left;
      C.BitmapMatrix.Dy := R.Top;
    end;
  end;
  C.GpuOk := GpuOk;
  C.Inst.Texture := nil;
  if GpuOk and (FPaintTexture <> nil) then
  begin
    // A bitmap brush (kept alive by the command: RecAlloc with Ref).
    C.Inst.Texture := Pointer(IGpuTexture(FPaintTexture));
    FPaintTexture := nil;
  end;
  if GpuOk then
  begin
    C.Inst.M11 := FDev.M11;
    C.Inst.M12 := FDev.M12;
    C.Inst.M21 := FDev.M21;
    C.Inst.M22 := FDev.M22;
    C.Inst.Dx := FDev.Dx;
    C.Inst.Dy := FDev.Dy;
    C.Inst.Color := GpuColor;
    C.Inst.Paint := GpuPaint;
    C.Inst.Clip := Clip;
    C.Inst.Flags := GpuKindPath;
  end;
  Tail := PByte(C) + SizeOf(TCmdD2D);
  if Length(Dashes) > 0 then
  begin
    Move(Dashes[0], Tail^, Length(Dashes) * SizeOf(Single));
    Inc(Tail, Length(Dashes) * SizeOf(Single));
  end;
  if Length(Stops) > 0 then
    Move(Stops[0], Tail^, Length(Stops) * SizeOf(TD2D1GradientStop));
end;

procedure TFastCanvas.DrawText(const AData: TFastLayoutData; const AOrigin, AMaxSize: TPointF;
  const AColor: TAlphaColor; const AOpacity: Single);
var
  Saved: TClipState;
  Clip: Cardinal;
  Box: TRectF;
  C: PCmdText;
begin
  if AOpacity <= 0 then
    Exit;
  // The ink: overhang metrics are distances from the edges of the layout box (0, 0, layout width, layout height),
  // not from the text. (Until 2026-10-07 they widened the text box: with a tall layout box, e.g. a paragraph of
  // MaxSize.Y = 10000, the bottom overhang is about -10000, the box ended above the text, and the text vanished
  // as soon as it came near the top edge.)
  Box := TRectF.Create(AOrigin.X - AData.Overhang.left, AOrigin.Y - AData.Overhang.top,
    AOrigin.X + AData.Metrics.layoutWidth + AData.Overhang.right,
    AOrigin.Y + AData.Metrics.layoutHeight + AData.Overhang.bottom);
  if not Visible(NormRect(Box), 2) then
    Exit;
  Saved := FClip;
  try
    // Ink outside the layout box is clipped to it, as Direct2D does with D2D1_DRAW_TEXT_OPTIONS_CLIP.
    if AData.InkOutside then
      IntersectDeviceClip(TRectF.Create(AOrigin.X, AOrigin.Y, AOrigin.X + AData.Metrics.layoutWidth,
        AOrigin.Y + AData.Metrics.layoutHeight), False);
    Clip := ClipIndex;
  finally
    FClip := Saved;
  end;
  RecTarget(Self);
  C := RecAlloc(TCmd.Text, SizeOf(TCmdText), AData);
  C.Data := AData;
  C.Origin := AOrigin;
  C.Matrix := FDev;
  C.Color := AColor;
  C.Opacity := EnsureRange(AOpacity, 0, 1);
  C.Clip := Clip;
  C.ForceD2D := TFastCanvasOption.D2DText in FastCanvasOptions;
  C.Pad[0] := 0;
  C.Pad[1] := 0;
  C.Pad[2] := 0;
end;
procedure DrawLayoutOnCanvas(const ACanvas: TCanvas; const AData: TFastLayoutData; const AOrigin: TPointF;
  const AMaxSize: TPointF; const AColor: TAlphaColor; const AOpacity: Single);
begin
  if ACanvas is TFastCanvas then
    TFastCanvas(ACanvas).DrawText(AData, AOrigin, AMaxSize, AColor, AOpacity);
end;

function TFastCanvas.PtInPath(const APoint: TPointF; const APath: TPathData): Boolean;
var
  Geometry: ID2D1PathGeometry;
  Points: TArray<TPathPoint>;
  Contains: BOOL;
  Identity: TD2D1Matrix3x2F;
begin
  Result := False;
  if (APath = nil) or APath.IsEmpty or not APath.GetBounds.Contains(APoint) then
    Exit;
  TFastDevice.Ensure;
  Points := PathPoints(APath);
  Geometry := BuildGeometry(@Points[0], Length(Points));
  if Geometry = nil then
    Exit;
  Identity._11 := 1;
  Identity._12 := 0;
  Identity._21 := 0;
  Identity._22 := 1;
  Identity._31 := 0;
  Identity._32 := 0;
  Contains := False;
  if Succeeded(Geometry.FillContainsPoint(D2DPoint(APoint.X, APoint.Y), Identity, D2D1_DEFAULT_FLATTENING_TOLERANCE,
    Contains)) then
    Result := Contains;
end;

{ Bitmaps }

class function TFastCanvas.DoInitializeBitmap(const Width, Height: Integer; const Scale: Single;
  var PixelFormat: TPixelFormat): THandle;
var
  B: TFastBitmap;
begin
  TFastDevice.Ensure;
  CheckDevice;
  PixelFormat := TPixelFormat.BGRA;
  B := TFastBitmap.Create(Width, Height);
  // The handle owns one reference; command chunks that use the bitmap hold their own.
  IInterface(B)._AddRef;
  Result := THandle(B);
end;

class procedure TFastCanvas.DoFinalizeBitmap(var Bitmap: THandle);
var
  B: TFastBitmap;
begin
  B := TFastBitmap(Bitmap);
  Bitmap := 0;
  if B <> nil then
    IInterface(B)._Release;
end;

class function TFastCanvas.DoMapBitmap(const Bitmap: THandle; const Access: TMapAccess; var Data: TBitmapData): Boolean;
var
  B: TFastBitmap;
  P: Pointer;
  Pitch: Integer;
begin
  Result := False;
  B := TFastBitmap(Bitmap);
  if not CheckDevice or (B.FSurface = nil) then
    Exit;
  // The render thread may still draw into or from the bitmap.
  FastCanvasSync;
  TFastDevice.Lock;
  try
    // HDR content (of a 3D context) as the CPU reads bitmaps: 8-bit, clipped.
    B.Demote;
    if B.FSurface.Map(P, Pitch) then
    begin
      B.FAccess := Access;
      Data.Data := P;
      Data.Pitch := Pitch;
      Result := True;
    end;
  finally
    TFastDevice.Unlock;
  end;
end;

class procedure TFastCanvas.DoUnmapBitmap(const Bitmap: THandle; var Data: TBitmapData);
var
  B: TFastBitmap;
  I: Integer;
begin
  B := TFastBitmap(Bitmap);
  if (B.FAccess <> TMapAccess.Read) and FastCanvasKeepBitmapCopies then
  begin
    // The pixels the CPU wrote, for a new device (FastCanvasKeepBitmapCopies).
    if Length(B.FCopy) <> B.FWidth * 4 * B.FHeight then
      SetLength(B.FCopy, B.FWidth * 4 * B.FHeight);
    for I := 0 to B.FHeight - 1 do
      Move((PByte(Data.Data) + I * Data.Pitch)^, B.FCopy[I * B.FWidth * 4], B.FWidth * 4);
  end;
  if B.FSurface = nil then
    Exit;
  TFastDevice.Lock;
  try
    B.FSurface.Unmap(B.FAccess <> TMapAccess.Read);
  finally
    TFastDevice.Unlock;
  end;
end;

class function TFastCanvas.DoCopyImageToBitmap(const Source: THandle; const Dest: TBitmap): Boolean;
var
  S, D: TFastBitmap;
begin
  Result := False;
  if (Source = 0) or (Dest = nil) or not Dest.HandleAllocated or not Dest.CanvasClass.InheritsFrom(TFastCanvas) then
    Exit;
  S := TFastBitmap(Source);
  D := TFastBitmap(Dest.Handle);
  if (S.FWidth <> D.FWidth) or (S.FHeight <> D.FHeight) or not CheckDevice or (S.FSurface = nil) or
    (D.FSurface = nil) then
    Exit;
  FastCanvasSync;
  TFastDevice.Lock;
  try
    S.Demote;
    D.SdrTarget;
    D.FSurface.CopyFrom(S.FSurface);
    D.GpuWritten;
    D.FCopy := Copy(S.FCopy);
  finally
    TFastDevice.Unlock;
  end;
  Result := True;
end;

{ TEdgeSink }

constructor TEdgeSink.Create;
begin
  inherited Create;
  SetLength(Edges, 1024);
end;

procedure TEdgeSink.Reset(const ATolerance: Single; const AEvenOdd: Boolean);
begin
  FTolerance := ATolerance;
  FOpen := False;
  EvenOdd := AEvenOdd;
  Count := 0;
  MinX := MaxSingle;
  MinY := MaxSingle;
  MaxX := -MaxSingle;
  MaxY := -MaxSingle;
end;

procedure TEdgeSink.Edge(const A, B: TD2D1Point2F);
begin
  if (A.x = B.x) and (A.y = B.y) then
    Exit;
  if Count = Length(Edges) then
    SetLength(Edges, 2 * Count);
  Edges[Count].X0 := A.x;
  Edges[Count].Y0 := A.y;
  Edges[Count].X1 := B.x;
  Edges[Count].Y1 := B.y;
  Inc(Count);
  // Every edge starts where the previous one ended: B is enough, except for the first point of a figure.
  if B.x < MinX then
    MinX := B.x;
  if B.x > MaxX then
    MaxX := B.x;
  if B.y < MinY then
    MinY := B.y;
  if B.y > MaxY then
    MaxY := B.y;
end;

procedure TEdgeSink.CloseFigure;
begin
  if FOpen then
    Edge(FCur, FStart);
  FOpen := False;
end;

procedure TEdgeSink.SetFillMode(fillMode: D2D1_FILL_MODE);
begin
  EvenOdd := fillMode = D2D1_FILL_MODE_ALTERNATE;
end;

procedure TEdgeSink.SetSegmentFlags(vertexFlags: D2D1_PATH_SEGMENT);
begin
end;

procedure TEdgeSink.BeginFigure(startPoint: D2D1_POINT_2F; figureBegin: D2D1_FIGURE_BEGIN);
begin
  CloseFigure;
  if startPoint.x < MinX then
    MinX := startPoint.x;
  if startPoint.x > MaxX then
    MaxX := startPoint.x;
  if startPoint.y < MinY then
    MinY := startPoint.y;
  if startPoint.y > MaxY then
    MaxY := startPoint.y;
  FStart := startPoint;
  FCur := startPoint;
  FOpen := True;
end;

procedure TEdgeSink.AddLines(points: PD2D1Point2F; pointsCount: UINT);
var
  I: Integer;
begin
  for I := 0 to Integer(pointsCount) - 1 do
  begin
    Edge(FCur, points^);
    FCur := points^;
    Inc(points);
  end;
end;

procedure TEdgeSink.AddBeziers(beziers: PD2D1BezierSegment; beziersCount: UINT);
var
  I, K, N: Integer;
  P0, P1, P2, P3, Q: TD2D1Point2F;
  Dd, T, U: Single;
begin
  for I := 0 to Integer(beziersCount) - 1 do
  begin
    P0 := FCur;
    P1 := beziers.point1;
    P2 := beziers.point2;
    P3 := beziers.point3;
    // Segments for a cubic from the size of its second differences.
    Dd := Max(Sqrt(Sqr(P0.x - 2 * P1.x + P2.x) + Sqr(P0.y - 2 * P1.y + P2.y)),
      Sqrt(Sqr(P1.x - 2 * P2.x + P3.x) + Sqr(P1.y - 2 * P2.y + P3.y)));
    N := EnsureRange(Ceil(Sqrt(0.75 * Dd / Max(FTolerance, 1E-4))), 1, 256);
    for K := 1 to N do
    begin
      T := K / N;
      U := 1 - T;
      Q.x := U * U * U * P0.x + 3 * U * U * T * P1.x + 3 * U * T * T * P2.x + T * T * T * P3.x;
      Q.y := U * U * U * P0.y + 3 * U * U * T * P1.y + 3 * U * T * T * P2.y + T * T * T * P3.y;
      Edge(FCur, Q);
      FCur := Q;
    end;
    Inc(beziers);
  end;
end;

procedure TEdgeSink.EndFigure(figureEnd: D2D1_FIGURE_END);
begin
  // Fills close every figure; widened outlines are closed already.
  CloseFigure;
end;

function TEdgeSink.Close: HResult;
begin
  CloseFigure;
  Result := S_OK;
end;

{ TPlayer (render thread) }

constructor TPlayer.Create;
begin
  inherited Create;
  FGpu := Backend.CreateRenderer;

  FPaths := TDictionary<UInt64, ID2D1PathGeometry>.Create;
  FStrokes := TDictionary<UInt64, ID2D1StrokeStyle>.Create;
  FStops := TDictionary<UInt64, ID2D1GradientStopCollection>.Create;
  FLinear := TDictionary<UInt64, ID2D1LinearGradientBrush>.Create;
  FEdges := TDictionary<UInt64, TPathEdges>.Create;
  FGlyphPaths := TDictionary<UInt64, ID2D1PathGeometry>.Create;
  FSink := TEdgeSink.Create;
  FSinkRef := FSink;
  FEdgeResetFrame := -100;
  FTransFrame := -1;
  FRadial := TDictionary<UInt64, ID2D1RadialGradientBrush>.Create;
  FD2DClip := -1;
end;

destructor TPlayer.Destroy;
begin
  LeaveD2D;
  FGlyphs.Free;
  FPaths.Free;
  FStrokes.Free;
  FStops.Free;
  FLinear.Free;
  FEdges.Free;
  FGlyphPaths.Free;
  FSinkRef := nil;
  FRadial.Free;
  FSolid := nil;
  FD2D := nil;
  FGpu.Free;
  inherited;
end;

procedure TPlayer.SelectTarget(const ACanvas: TFastCanvas);
var
  T: TFastTarget;
begin
  LeaveD2D;
  FCanvas := ACanvas;
  if (ACanvas <> nil) and (ACanvas.FTarget <> nil) and (ACanvas.FTarget.Surface <> nil) then
  begin
    T := ACanvas.FTarget;
    FGpu.BeginTarget(T.Surface, T.Width, T.Height, T.Aliased);
    // The rectangles of a partial window frame hold for that window only: back to it after a bitmap scene drawn in
    // the middle of its frame, they hold again.
    FGpu.SetRegion(T.RegionFirst, T.RegionCount);
  end
  else
    FGpu.Flush;
end;

procedure TPlayer.SetRegion(const C: PCmdRegion);
var
  Canvas: TFastCanvas;
begin
  Canvas := TFastCanvas(C.Canvas);
  if (Canvas <> nil) and (Canvas.FTarget <> nil) then
  begin
    Canvas.FTarget.RegionFirst := C.First;
    Canvas.FTarget.RegionCount := C.Count;
  end;
  // Recorded again after the tables were reset, maybe while a bitmap canvas is the target.
  if Canvas = FCanvas then
    FGpu.SetRegion(C.First, C.Count);
end;

procedure TPlayer.BeginFrame(const C: PCmdBegin);
var
  T: TFastTarget;
begin
  if FCanvas = nil then
    Exit;
  LeaveD2D;
  T := FCanvas.FTarget;
  // The renderer must not keep a view of buffers that are about to be resized.
  FGpu.BeginTarget(nil, 0, 0, False);
  T.Aliased := C.Aliased;
  T.Prepare(C.Width, C.Height, C.Tearing, TFastBitmap(C.Bitmap), C.Hdr, C.Composition);
  FNoPresent := False;
  if C.Partial and ((T.Window = nil) or not T.Window.RestoreLast) then
  begin
    // Nothing to start from (a new or resized swap chain): the frame would show what FMX did not paint.
    FNoPresent := True;
    AtomicExchange(GPartialMissed, 1);
  end;
  FGpu.BeginTarget(T.Surface, T.Width, T.Height, T.Aliased);
  // A frame starts on the whole target; a partial window frame sets its rectangles next (TCmd.Region). A bitmap
  // scene in the middle of a window frame draws everywhere.
  T.RegionFirst := 0;
  T.RegionCount := 0;
  FGpu.SetRegion(0, 0);
end;

procedure TPlayer.EndFrame(const C: PCmdEnd);
var
  T: TFastTarget;
  Res: HResult;
begin
  try
    LeaveD2D;
    FGpu.EndTarget;
    FGpu.SetRegion(0, 0);
    Inc(FFrame);
    if FCanvas = nil then
      Exit;
    T := FCanvas.FTarget;
    T.RegionFirst := 0;
    T.RegionCount := 0;
    if T.Window = nil then
      Exit;
    if C.Present and not FNoPresent then
    begin
      Res := T.Window.Present;
      if (Res = DXGI_ERROR_DEVICE_REMOVED) or (Res = DXGI_ERROR_DEVICE_RESET) then
        MarkDeviceLost;
    end;
    if (C.Bits <> nil) and not FNoPresent then
      T.Window.ReadPixels(C.Bits, C.BitsWidth, C.BitsHeight);
  finally
    if C.Window then
      GQueue.FrameCompleted;
  end;
end;

procedure TPlayer.EnterD2D;
var
  Target: ID2D1Bitmap1;
begin
  if FInD2D then
    Exit;
  // Direct2D draws only with a Direct3D 11 device.
  if (FCanvas = nil) or (FCanvas.FTarget = nil) or (TFastDevice.D2DDevice = nil) then
    Abort;
  if FD2D = nil then
  begin
    // Made on first use: only the D2DText measurement aid draws with Direct2D.
    if Failed(TFastDevice.D2DDevice.CreateDeviceContext(D2D1_DEVICE_CONTEXT_OPTIONS_NONE, FD2D)) then
      raise EFastDevice.Create('FastCanvas: cannot create a Direct2D device context');
    FD2D.SetDpi(96, 96);
  end;
  Target := FCanvas.FTarget.D2DTarget(FD2D);
  if Target = nil then
    Abort;
  FGpu.Flush;
  FD2D.SetTarget(Target);
  FD2D.BeginDraw;
  if FCanvas.FTarget.Aliased then
    FD2D.SetAntialiasMode(D2D1_ANTIALIAS_MODE_ALIASED)
  else
    FD2D.SetAntialiasMode(D2D1_ANTIALIAS_MODE_PER_PRIMITIVE);
  FD2D.SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
  FInD2D := True;
  FD2DClip := -1;
  FD2DPushCount := 0;
end;

procedure TPlayer.PopD2DClips;
begin
  while FD2DPushCount > 0 do
  begin
    Dec(FD2DPushCount);
    if FD2DPushed[FD2DPushCount] then
      FD2D.PopLayer
    else
      FD2D.PopAxisAlignedClip;
  end;
  FD2DClip := -1;
end;

procedure TPlayer.LeaveD2D;
var
  Res: HResult;
begin
  if not FInD2D then
    Exit;
  PopD2DClips;
  Res := FD2D.EndDraw;
  FD2D.SetTarget(nil);
  FInD2D := False;
  // Direct2D changed the pipeline state of the immediate context.
  FGpu.Invalidate;
  if (Res = D2DERR_RECREATE_TARGET) or DeviceGone then
    MarkDeviceLost
  else if Failed(Res) then
    GQueue.ReportError(Format('Direct2D EndDraw failed (0x%.8x)', [Cardinal(Res)]));
end;

procedure TPlayer.UseD2DClip(const AIndex: Integer);
var
  C: PGpuClip;
  I: Integer;
  Identity: TD2D1Matrix3x2F;
  Geometry: ID2D1RectangleGeometry;
  Params: TD2D1LayerParameters;
  Outer: array[0..3] of ID2D1Geometry;
  Group: ID2D1GeometryGroup;
  O: TGpuOrientedRect;
begin
  if AIndex = FD2DClip then
    Exit;
  PopD2DClips;
  if AIndex > 0 then
  begin
    C := FGpu.Clip(AIndex);
    if Length(FD2DPushed) < 1 + Length(C.Oriented) then
      SetLength(FD2DPushed, 1 + Length(C.Oriented));
    Identity._11 := 1;
    Identity._12 := 0;
    Identity._21 := 0;
    Identity._22 := 1;
    Identity._31 := 0;
    Identity._32 := 0;
    FD2D.SetTransform(Identity);
    FD2D.PushAxisAlignedClip(D2DRect(C.Box), D2D1_ANTIALIAS_MODE_ALIASED);
    FD2DPushed[FD2DPushCount] := False;
    Inc(FD2DPushCount);
    for I := 0 to C.Count - 1 do
    begin
      O := C.Oriented[I];
      if O.Exclude then
      begin
        // Everything around the rectangle: four rectangles of a group.
        TFastDevice.D2DFactory.CreateRectangleGeometry(D2DRect(TRectF.Create(-1E6, -1E6, 0, 1E6)), ID2D1RectangleGeometry(Outer[0]));
        TFastDevice.D2DFactory.CreateRectangleGeometry(D2DRect(TRectF.Create(O.Width, -1E6, 1E6, 1E6)), ID2D1RectangleGeometry(Outer[1]));
        TFastDevice.D2DFactory.CreateRectangleGeometry(D2DRect(TRectF.Create(0, -1E6, O.Width, 0)), ID2D1RectangleGeometry(Outer[2]));
        TFastDevice.D2DFactory.CreateRectangleGeometry(D2DRect(TRectF.Create(0, O.Height, O.Width, 1E6)), ID2D1RectangleGeometry(Outer[3]));
        TFastDevice.D2DFactory.CreateGeometryGroup(D2D1_FILL_MODE_WINDING, @Outer[0], 4, Group);
        Params.geometricMask := Group;
      end
      else
      begin
        TFastDevice.D2DFactory.CreateRectangleGeometry(D2DRect(TRectF.Create(0, 0, O.Width, O.Height)), Geometry);
        Params.geometricMask := Geometry;
      end;
      Params.contentBounds := D2DRect(TRectF.Create(-1E9, -1E9, 1E9, 1E9));
      Params.maskAntialiasMode := D2D1_ANTIALIAS_MODE_ALIASED;
      Params.maskTransform := D2DMatrix(O.Fwd);
      Params.opacity := 1;
      Params.opacityBrush := nil;
      Params.layerOptions := D2D1_LAYER_OPTIONS_NONE;
      FD2D.PushLayer(Params, nil);
      FD2DPushed[FD2DPushCount] := True;
      Inc(FD2DPushCount);
    end;
  end;
  FD2DClip := AIndex;
end;

procedure TPlayer.DefinePath(const C: PCmdPathDef);
var
  G: ID2D1PathGeometry;
begin
  G := BuildGeometry(PPathPoints(PByte(C) + SizeOf(TCmdPathDef)), C.Count);
  if G <> nil then
    FPaths.AddOrSetValue(C.Key, G);
end;

function TPlayer.StrokeStyle(const C: PCmdD2D): ID2D1StrokeStyle;
const
  Caps: array[0..1] of D2D1_CAP_STYLE = (D2D1_CAP_STYLE_SQUARE, D2D1_CAP_STYLE_ROUND);
  Joins: array[0..2] of D2D1_LINE_JOIN = (D2D1_LINE_JOIN_MITER, D2D1_LINE_JOIN_ROUND, D2D1_LINE_JOIN_BEVEL);
var
  Key: UInt64;
  Props: TD2D1StrokeStyleProperties;
  Dashes: PSingle;
begin
  Key := StrokeKey(C);
  Dashes := PSingle(PByte(C) + SizeOf(TCmdD2D));
  if FStrokes.TryGetValue(Key, Result) then
    Exit;
  // FMX flat caps are drawn square, as the stock Direct2D canvas does.
  Props.startCap := Caps[Min(C.Cap, 1)];
  Props.endCap := Props.startCap;
  Props.dashCap := Props.startCap;
  Props.lineJoin := Joins[Min(C.Join, 2)];
  Props.miterLimit := 10;
  Props.dashStyle := D2D1_DASH_STYLE(C.Dash);
  Props.dashOffset := C.DashOffset;
  if C.DashCount = 0 then
    Dashes := nil;
  if Failed(TFastDevice.D2DFactory.CreateStrokeStyle(Props, Dashes, C.DashCount, Result)) then
    Result := nil;
  FStrokes.AddOrSetValue(Key, Result);
end;

function TPlayer.Brush(const C: PCmdD2D): ID2D1Brush;
var
  Stops: ID2D1GradientStopCollection;
  Lin: TD2D1LinearGradientBrushProperties;
  Rad: TD2D1RadialGradientBrushProperties;
  BmpProps: TD2D1BitmapBrushProperties;
  Props: TD2D1BrushProperties;
  LinBrush: ID2D1LinearGradientBrush;
  RadBrush: ID2D1RadialGradientBrush;
  BmpBrush: ID2D1BitmapBrush;
  Bmp: ID2D1Bitmap1;
  StopData: PD2D1GradientStop;
begin
  Result := nil;
  case C.Brush of
    TD2DBrushKind.Solid:
      begin
        if FSolid = nil then
          FD2D.CreateSolidColorBrush(D2DColor(C.Color), nil, FSolid)
        else
          FSolid.SetColor(D2DColor(C.Color));
        Result := FSolid;
      end;
    TD2DBrushKind.Linear, TD2DBrushKind.Radial:
      begin
        if not FStops.TryGetValue(C.GradKey, Stops) then
        begin
          StopData := PD2D1GradientStop(PByte(C) + SizeOf(TCmdD2D) + C.DashCount * SizeOf(Single));
          if Failed(FD2D.CreateGradientStopCollection(StopData, C.StopCount, D2D1_GAMMA_2_2, D2D1_EXTEND_MODE_CLAMP,
            Stops)) then
            Exit;
          if FStops.Count > 256 then
          begin
            FStops.Clear;
            FLinear.Clear;
            FRadial.Clear;
          end;
          FStops.Add(C.GradKey, Stops);
        end;
        if C.Brush = TD2DBrushKind.Linear then
        begin
          if FLinear.TryGetValue(C.GradKey, LinBrush) then
          begin
            LinBrush.SetStartPoint(D2DPoint(C.G0.X, C.G0.Y));
            LinBrush.SetEndPoint(D2DPoint(C.G1.X, C.G1.Y));
          end
          else
          begin
            Lin.startPoint := D2DPoint(C.G0.X, C.G0.Y);
            Lin.endPoint := D2DPoint(C.G1.X, C.G1.Y);
            if Failed(FD2D.CreateLinearGradientBrush(Lin, nil, Stops, LinBrush)) then
              Exit;
            FLinear.Add(C.GradKey, LinBrush);
          end;
          Result := LinBrush;
        end
        else
        begin
          if FRadial.TryGetValue(C.GradKey, RadBrush) then
          begin
            RadBrush.SetCenter(D2DPoint(C.G0.X, C.G0.Y));
            RadBrush.SetRadiusX(C.G1.X);
            RadBrush.SetRadiusY(C.G1.Y);
          end
          else
          begin
            Rad.center := D2DPoint(C.G0.X, C.G0.Y);
            Rad.gradientOriginOffset := D2DPoint(0, 0);
            Rad.radiusX := C.G1.X;
            Rad.radiusY := C.G1.Y;
            if Failed(FD2D.CreateRadialGradientBrush(Rad, nil, Stops, RadBrush)) then
              Exit;
            FRadial.Add(C.GradKey, RadBrush);
          end;
          RadBrush.SetTransform(D2DMatrix(C.GMatrix));
          Result := RadBrush;
        end;
        if Result <> nil then
          Result.SetOpacity(C.Opacity);
      end;
    TD2DBrushKind.Bitmap:
      begin
        Bmp := TFastBitmap(C.Bitmap).D2DBitmap(FD2D);
        if Bmp = nil then
          Exit;
        if TWrapMode(C.BitmapExtend) = TWrapMode.TileOriginal then
        begin
          BmpProps.extendModeX := D2D1_EXTEND_MODE_CLAMP;
          BmpProps.extendModeY := D2D1_EXTEND_MODE_CLAMP;
        end
        else
        begin
          BmpProps.extendModeX := D2D1_EXTEND_MODE_WRAP;
          BmpProps.extendModeY := D2D1_EXTEND_MODE_WRAP;
        end;
        BmpProps.interpolationMode := D2D1_BITMAP_INTERPOLATION_MODE_LINEAR;
        Props.opacity := C.Opacity;
        Props.transform := D2DMatrix(C.BitmapMatrix);
        if Succeeded(FD2D.CreateBitmapBrush(Bmp, @BmpProps, @Props, BmpBrush)) then
          Result := BmpBrush;
      end;
  end;
end;

/// <summary>Cap, join and dashes of a stroke (not the width).</summary>
function TPlayer.StrokeKey(const C: PCmdD2D): UInt64;
begin
  Result := Fnv(@C.Cap, 3);
  Result := Fnv(@C.DashOffset, SizeOf(Single), Result);
  Result := Fnv(PByte(C) + SizeOf(TCmdD2D), C.DashCount * SizeOf(Single), Result);
end;

/// <summary>Band layout of polygon edges for the shader (PathCoverage), written to AOut (grown when needed, reused):
/// (Bands + 1) div 2 headers of two (start, count) pairs each (relative to AOut, as Cardinal bits), then the edges
/// of every band. A band lists the edges overlapping it widened by 0.75 pixel at the lowest scale of the bucket, so
/// the pixel square around any point of the band finds all the edges it needs in that band. Returns the number of
/// entries used.</summary>
function BandEdges(const ASink: TEdgeSink; const AMinScale: Single; var AOut: TArray<TEdge>;
  out ABands: Integer): Integer;
var
  H, InvH, Margin: Single;
  B, I, Headers, First, Last: Integer;
  Counts, Next: array[0..MaxPathBands - 1] of Integer;

  procedure Span(const E: TEdge; out AFirst, ALast: Integer);
  var
    Lo, Hi: Single;
  begin
    if H <= 0 then
    begin
      AFirst := 0;
      ALast := 0;
      Exit;
    end;
    if E.Y0 < E.Y1 then
    begin
      Lo := E.Y0;
      Hi := E.Y1;
    end
    else
    begin
      Lo := E.Y1;
      Hi := E.Y0;
    end;
    Lo := (Lo - Margin - ASink.MinY) * InvH;
    Hi := (Hi + Margin - ASink.MinY) * InvH;
    if Lo <= 0 then
      AFirst := 0
    else if Lo >= ABands - 1 then
      AFirst := ABands - 1
    else
      AFirst := Trunc(Lo);
    if Hi <= 0 then
      ALast := 0
    else if Hi >= ABands - 1 then
      ALast := ABands - 1
    else
      ALast := Trunc(Hi);
  end;

begin
  ABands := EnsureRange(ASink.Count div 6, 1, MaxPathBands);
  H := (ASink.MaxY - ASink.MinY) / ABands;
  if H <= 1E-6 then
  begin
    ABands := 1;
    H := 0;
  end;
  InvH := 0;
  if H > 0 then
    InvH := 1 / H;
  Margin := 0.75 / Max(AMinScale, 1E-3);
  FillChar(Counts, SizeOf(Counts), 0);
  for I := 0 to ASink.Count - 1 do
  begin
    Span(ASink.Edges[I], First, Last);
    for B := First to Last do
      Inc(Counts[B]);
  end;
  Headers := (ABands + 1) div 2;
  Result := Headers;
  for B := 0 to ABands - 1 do
  begin
    Next[B] := Result;
    Inc(Result, Counts[B]);
  end;
  if Length(AOut) < Result then
    SetLength(AOut, Max(Result, 2 * Length(AOut)));
  FillChar(AOut[0], Headers * SizeOf(TEdge), 0);
  for B := 0 to ABands - 1 do
    if Odd(B) then
    begin
      PCardinal(@AOut[B div 2].X1)^ := Next[B];
      PCardinal(@AOut[B div 2].Y1)^ := Counts[B];
    end
    else
    begin
      PCardinal(@AOut[B div 2].X0)^ := Next[B];
      PCardinal(@AOut[B div 2].Y0)^ := Counts[B];
    end;
  for I := 0 to ASink.Count - 1 do
  begin
    Span(ASink.Edges[I], First, Last);
    for B := First to Last do
    begin
      AOut[Next[B]] := ASink.Edges[I];
      Inc(Next[B]);
    end;
  end;
end;

/// <summary>Origin of the polygon of a shape command in local space. Solid shapes other than paths are built at the
/// origin and moved by the instance matrix, so moving shapes of one size share their edges (a gradient paint is
/// evaluated in local space: those stay where they are).</summary>
function ShapeOrigin(const C: PCmdD2D): TPointF; inline;
begin
  if (C.Shape <> TD2DShape.Path) and (C.Inst.Paint = 0) then
    Result := C.R.TopLeft
  else
    Result := TPointF.Zero;
end;

/// <summary>Direct2D geometry of a shape command: the recorded path, or a rectangle, rounded rectangle, ellipse or
/// line (an open figure) with the rectangle R (the command's, relative to ShapeOrigin).</summary>
function TPlayer.ShapeGeometry(const C: PCmdD2D; const R: TRectF): ID2D1Geometry;
var
  Path: ID2D1PathGeometry;
  Rect: ID2D1RectangleGeometry;
  Round: ID2D1RoundedRectangleGeometry;
  Ellipse: ID2D1EllipseGeometry;
  RR: TD2D1RoundedRect;
  E: TD2D1Ellipse;
  Sink: ID2D1GeometrySink;
begin
  Result := nil;
  case C.Shape of
    TD2DShape.Path:
      if FPaths.TryGetValue(C.PathKey, Path) or FGlyphPaths.TryGetValue(C.PathKey, Path) then
        Result := Path;
    TD2DShape.Rect:
      if Succeeded(TFastDevice.D2DFactory.CreateRectangleGeometry(D2DRect(R), Rect)) then
        Result := Rect;
    TD2DShape.RoundRect:
      begin
        RR.rect := D2DRect(R);
        RR.radiusX := C.Rx;
        RR.radiusY := C.Ry;
        if Succeeded(TFastDevice.D2DFactory.CreateRoundedRectangleGeometry(RR, Round)) then
          Result := Round;
      end;
    TD2DShape.Ellipse:
      begin
        E.point := D2DPoint((R.Left + R.Right) / 2, (R.Top + R.Bottom) / 2);
        E.radiusX := R.Width / 2;
        E.radiusY := R.Height / 2;
        if Succeeded(TFastDevice.D2DFactory.CreateEllipseGeometry(E, Ellipse)) then
          Result := Ellipse;
      end;
    TD2DShape.Line:
      if Succeeded(TFastDevice.D2DFactory.CreatePathGeometry(Path)) and Succeeded(Path.Open(Sink)) then
      begin
        Sink.BeginFigure(D2DPoint(R.Left, R.Top), D2D1_FIGURE_BEGIN_HOLLOW);
        Sink.AddLine(D2DPoint(R.Right, R.Bottom));
        Sink.EndFigure(D2D1_FIGURE_END_OPEN);
        if Succeeded(Sink.Close) then
          Result := Path;
      end;
  end;
end;

/// <summary>Polygon edges of a shape fill, or of the outline of a stroke (ID2D1Geometry.Widen: joins, caps and
/// dashes exactly as Direct2D strokes), in local space. Cached per scale bucket (quarter octaves): the largest scale
/// of the matrix sets the flattening tolerance, the smallest the band margin.</summary>
function TPlayer.PathEdges(const C: PCmdD2D; const AScaleMax, AScaleMin: Single; out AEdges: TPathEdges): Boolean;
var
  Bucket, BucketMin: Integer;
  Tolerance: Single;
  Key: UInt64;
  Geometry: ID2D1Geometry;
  Identity: TD2D1Matrix3x2F;
  Res: HResult;
  Fill, Shape: Byte;
  Bands, N, I, Start: Integer;
  R: TRectF;
  Q: Single;
  Persistent: Boolean;
begin
  Bucket := Round(Log2(Max(AScaleMax, 1E-3)) * 4);
  BucketMin := Round(Log2(Max(AScaleMin, 1E-3)) * 4);
  Tolerance := 0.2 / Power(2, Bucket / 4);
  Fill := Ord(C.Fill);
  R := C.R;
  if C.Shape = TD2DShape.Path then
    Key := Fnv(@C.PathKey, SizeOf(UInt64))
  else
  begin
    Shape := Ord(C.Shape);
    Key := Fnv(@Shape, 1);
    // Relative to the origin and on a 1/64 pixel grid: the size of a moving shape is computed from its corners
    // and differs in the last bits from frame to frame.
    R.Offset(-ShapeOrigin(C));
    Q := 64 * Power(2, Bucket / 4);
    R := TRectF.Create(Round(R.Left * Q) / Q, Round(R.Top * Q) / Q, Round(R.Right * Q) / Q, Round(R.Bottom * Q) / Q);
    Key := Fnv(@R, SizeOf(TRectF), Key);
    Key := Fnv(@C.Rx, 2 * SizeOf(Single), Key);
  end;
  Key := Fnv(@Fill, 1, Key);
  Key := Fnv(@Bucket, SizeOf(Integer), Key);
  Key := Fnv(@BucketMin, SizeOf(Integer), Key);
  if not C.Fill then
  begin
    Key := Fnv(@C.StrokeWidth, SizeOf(Single), Key);
    Key := Fnv(@Key, SizeOf(UInt64), StrokeKey(C));
  end;
  NewFrame;
  // A path seen for the first time goes to the per-frame part of the table; seen again after that part has been
  // reused (a later frame), it is built once more into the lasting part. Geometry that changes every frame
  // (animated arcs, rotating gradient lines) then never pushes out the paths that stay.
  Persistent := False;
  if FEdges.TryGetValue(Key, AEdges) then
  begin
    if (AEdges.Frame < 0) or (AEdges.TransGen = FTransGen) then
      Exit(AEdges.Count > 0);
    Persistent := True;
  end;
  Geometry := ShapeGeometry(C, R);
  if Geometry = nil then
    Exit(False);
  Identity._11 := 1;
  Identity._12 := 0;
  Identity._21 := 0;
  Identity._22 := 1;
  Identity._31 := 0;
  Identity._32 := 0;
  // The fill rule is the one the geometry reports (SetFillMode): FMX paths are ALTERNATE (even-odd), glyph outlines
  // WINDING; Widen reports WINDING for most outlines, but not for the outline of a plain rectangle, whose inner
  // contour runs the same way as the outer one (even-odd, the default here). Found 2026-10-07: a bitmap-brush
  // rectangle stroke filled with non-zero came out solid.
  FSink.Reset(Tolerance, True);
  if C.Fill then
    Res := Geometry.Simplify(D2D1_GEOMETRY_SIMPLIFICATION_OPTION_LINES, Identity, Tolerance, FSinkRef)
  else
    Res := Geometry.Widen(C.StrokeWidth, StrokeStyle(C), Identity, Tolerance, FSinkRef);
  if Failed(Res) then
    Exit(False);
  AEdges := Default(TPathEdges);
  AEdges.Frame := -1;
  if FSink.Count > 0 then
  begin
    N := BandEdges(FSink, Power(2, (BucketMin - 0.5) / 4), FBanded, Bands);
    if N > GpuEdgesLimit div 4 then
      Exit(False);
    if not Persistent and (N > FGpu.EdgeCapacity div 4) then
      Persistent := True;
    Start := AllocEdges(N, Persistent);
    // Band headers hold absolute indices.
    for I := 0 to (Bands + 1) div 2 - 1 do
    begin
      Inc(PCardinal(@FBanded[I].X0)^, Start);
      Inc(PCardinal(@FBanded[I].X1)^, Start);
    end;
    FGpu.UploadEdges(Start, N, @FBanded[0]);
    AEdges.Header := Start;
    AEdges.Bands := Bands;
    AEdges.Count := FSink.Count;
    AEdges.Bounds := TRectF.Create(FSink.MinX, FSink.MinY, FSink.MaxX, FSink.MaxY);
    AEdges.EvenOdd := FSink.EvenOdd;
    if not Persistent then
    begin
      AEdges.Frame := FFrame;
      AEdges.TransGen := FTransGen;
      AddTransient(Key);
    end;
  end;
  if AEdges.Frame < 0 then
    Inc(FPersistCount);
  FEdges.AddOrSetValue(Key, AEdges);
  Result := AEdges.Count > 0;
end;

/// <summary>Space for N edge table entries: in the lasting part (the lower three quarters, filled upwards and started
/// over when full, growing the table when one frame needs more), or in the per-frame part (the upper quarter, reused
/// every frame).</summary>
function TPlayer.AllocEdges(const N: Integer; const APersistent: Boolean): Integer;
var
  Base, Need, Cap: Integer;
begin
  Base := FGpu.EdgeCapacity - FGpu.EdgeCapacity div 4;
  if APersistent then
  begin
    // Also when the table holds many paths: the dictionary must not grow without bound.
    if (FEdgeCount + N > Base) or (FPersistCount >= MaxEdgePaths) then
    begin
      // Draw what uses the current edges, then start over.
      FGpu.Flush;
      if FEdgeCount + N > Base then
      begin
        // A larger table when the paths of a frame do not fit (started over in this frame or the previous one:
        // otherwise every frame would rebuild all its paths), or when this path alone does not.
        Need := N + N div 3;
        if FFrame - FEdgeResetFrame <= 1 then
          Need := Max(Need, 2 * FGpu.EdgeCapacity);
        Cap := FGpu.EdgeCapacity;
        while (Cap < Need) and (Cap < GpuEdgesLimit) do
          Cap := 2 * Cap;
        if Cap <> FGpu.EdgeCapacity then
          FGpu.ResizeEdges(Cap);
        FEdgeResetFrame := FFrame;
      end;
      FEdges.Clear;
      FEdgeCount := 0;
      FPersistCount := 0;
      FTransCount[0] := 0;
      FTransCount[1] := 0;
      FTransPos := FGpu.EdgeCapacity - FGpu.EdgeCapacity div 4;
      Inc(FTransGen);
    end;
    Result := FEdgeCount;
    Inc(FEdgeCount, N);
  end
  else
  begin
    if FTransPos < Base then
      FTransPos := Base;
    if FTransPos + N > FGpu.EdgeCapacity then
    begin
      // The per-frame part is full: draw what uses it and start it over (its entries stay known as seen).
      FGpu.Flush;
      Inc(FTransGen);
      FTransPos := Base;
    end;
    Result := FTransPos;
    Inc(FTransPos, N);
  end;
end;

procedure TPlayer.AddTransient(const AKey: UInt64);
begin
  if FTransCount[FTransCur] = Length(FTransKeys[FTransCur]) then
    SetLength(FTransKeys[FTransCur], Max(256, 2 * FTransCount[FTransCur]));
  FTransKeys[FTransCur][FTransCount[FTransCur]] := AKey;
  Inc(FTransCount[FTransCur]);
end;

/// <summary>Removes the per-frame entries of a key list from the dictionary (keys rebuilt as lasting stay).</summary>
procedure TPlayer.DropTransient(const AList: Integer);
var
  I: Integer;
  E: TPathEdges;
begin
  for I := 0 to FTransCount[AList] - 1 do
    if FEdges.TryGetValue(FTransKeys[AList][I], E) and (E.Frame >= 0) then
      FEdges.Remove(FTransKeys[AList][I]);
  FTransCount[AList] := 0;
end;

/// <summary>At the first path of a frame: forgets the per-frame entries of the frame before the last one, and
/// reuses the per-frame part of the table (the entries of the last frame are kept only to recognize paths seen
/// again).</summary>
procedure TPlayer.NewFrame;
begin
  if FTransFrame = FFrame then
    Exit;
  FTransFrame := FFrame;
  FTransCur := 1 - FTransCur;
  DropTransient(FTransCur);
  FTransPos := FGpu.EdgeCapacity - FGpu.EdgeCapacity div 4;
  Inc(FTransGen);
end;

function TPlayer.DrawShapeGpu(const C: PCmdD2D): Boolean;
var
  M: TGpuAffine;
  A, B2, C2, Root: Single;
  O: TPointF;
  E: TPathEdges;
  Flags: Cardinal;
  Inst: PGpuInstance;
begin
  M := C.Matrix;
  O := ShapeOrigin(C);
  M.Dx := M.Dx + O.X * M.M11 + O.Y * M.M21;
  M.Dy := M.Dy + O.X * M.M12 + O.Y * M.M22;
  // Singular values of the linear part: the largest and the smallest scale of the matrix.
  A := Sqr(M.M11) + Sqr(M.M12);
  C2 := Sqr(M.M21) + Sqr(M.M22);
  B2 := M.M11 * M.M21 + M.M12 * M.M22;
  Root := Sqrt(Sqr(0.5 * (A - C2)) + Sqr(B2));
  if not PathEdges(C, Sqrt(0.5 * (A + C2) + Root), Sqrt(Max(0.5 * (A + C2) - Root, 0)), E) then
    Exit(E.Count = 0);
  LeaveD2D;
  Flags := C.Inst.Flags;
  if C.Inst.Texture <> nil then
    Flags := FGpu.WithTexture(Flags, C.Inst.Texture);
  Inst := FGpu.Append;
  Inst^ := C.Inst;
  Inst.Flags := Flags;
  Inst.Dx := M.Dx;
  Inst.Dy := M.Dy;
  Inst.X0 := E.Bounds.Left;
  Inst.Y0 := E.Bounds.Top;
  Inst.X1 := E.Bounds.Right;
  Inst.Y1 := E.Bounds.Bottom;
  PCardinal(@Inst.U0)^ := E.Header;
  PCardinal(@Inst.V0)^ := E.Bands;
  PCardinal(@Inst.U1)^ := Ord(E.EvenOdd);
  PCardinal(@Inst.V1)^ := 0;
  Inst.Texture := nil;
  Result := True;
end;

procedure TPlayer.DrawShape(const C: PCmdD2D);
var
  B: ID2D1Brush;
  S: ID2D1StrokeStyle;
  Geometry: ID2D1PathGeometry;
  RR: TD2D1RoundedRect;
  E: TD2D1Ellipse;
begin
  if C.GpuOk and DrawShapeGpu(C) then
    Exit;
  EnterD2D;
  UseD2DClip(C.Clip);
  FD2D.SetTransform(D2DMatrix(C.Matrix));
  B := Brush(C);
  if B = nil then
    Exit;
  Geometry := nil;
  if (C.Shape = TD2DShape.Path) and not FPaths.TryGetValue(C.PathKey, Geometry) then
    Exit;
  RR.rect := D2DRect(C.R);
  RR.radiusX := C.Rx;
  RR.radiusY := C.Ry;
  E.point := D2DPoint((C.R.Left + C.R.Right) / 2, (C.R.Top + C.R.Bottom) / 2);
  E.radiusX := C.R.Width / 2;
  E.radiusY := C.R.Height / 2;
  if C.Fill then
    case C.Shape of
      TD2DShape.Rect:
        FD2D.FillRectangle(D2DRect(C.R), B);
      TD2DShape.RoundRect:
        FD2D.FillRoundedRectangle(RR, B);
      TD2DShape.Ellipse:
        FD2D.FillEllipse(E, B);
      TD2DShape.Path:
        FD2D.FillGeometry(Geometry, B, nil);
    end
  else
  begin
    S := StrokeStyle(C);
    case C.Shape of
      TD2DShape.Rect:
        FD2D.DrawRectangle(D2DRect(C.R), B, C.StrokeWidth, S);
      TD2DShape.RoundRect:
        FD2D.DrawRoundedRectangle(RR, B, C.StrokeWidth, S);
      TD2DShape.Ellipse:
        FD2D.DrawEllipse(E, B, C.StrokeWidth, S);
      TD2DShape.Line:
        FD2D.DrawLine(D2DPoint(C.R.Left, C.R.Top), D2DPoint(C.R.Right, C.R.Bottom), B, C.StrokeWidth, S);
      TD2DShape.Path:
        FD2D.DrawGeometry(Geometry, B, C.StrokeWidth, S);
    end;
  end;
end;

procedure TPlayer.DrawTextD2D(const C: PCmdText; const AData: TFastLayoutData);
var
  Options: Cardinal;
begin
  EnterD2D;
  UseD2DClip(C.Clip);
  FD2D.SetTransform(D2DMatrix(C.Matrix));
  if FSolid = nil then
    FD2D.CreateSolidColorBrush(D2DColor(MulAlpha(C.Color, C.Opacity)), nil, FSolid)
  else
    FSolid.SetColor(D2DColor(MulAlpha(C.Color, C.Opacity)));
  Options := 0;
  if AData.InkOutside then
    Options := Options or D2D1_DRAW_TEXT_OPTIONS_CLIP;
  if AData.ColorGlyphs then
    Options := Options or D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT;
  AData.Lock;
  try
    FD2D.DrawTextLayout(D2DPoint(C.Origin.X, C.Origin.Y), AData.Layout, FSolid, Options);
  finally
    AData.Unlock;
  end;
end;

procedure GlyphUploadNow(const X, Y, W, H: Integer; const AData: PByte; const APitch: Integer);
begin
  GPlayer.FGpu.UploadGlyph(X, Y, W, H, AData, APitch);
end;

procedure GlyphResetNow;
begin
  // Draw what samples the old atlas content before it is overwritten.
  GPlayer.FGpu.Flush;
end;

/// <summary>Glyphs as filled outlines (GPU path coverage), for runs the atlas cannot take: rotated or skewed text,
/// sideways runs, glyphs larger than MaxAtlasEm pixels. Outlines come from DirectWrite once per face, glyph and size.
/// </summary>
procedure TPlayer.DrawRunOutlines(const C: PCmdText; const ARun: TFastGlyphRun; const AColor: Cardinal);
var
  I: Integer;
  Key: UInt64;
  Face: Pointer;
  Glyph: Word;
  Geometry: ID2D1PathGeometry;
  Sink: ID2D1GeometrySink;
  Cmd: TCmdD2D;
  Lx, Ly: Single;
  M: TGpuAffine;
begin
  M := C.Matrix;
  Face := Pointer(ARun.FontFace);
  for I := 0 to High(ARun.Glyphs) do
  begin
    Glyph := ARun.Glyphs[I];
    Key := Fnv(@Face, SizeOf(Pointer), UInt64($9E3779B97F4A7C15));
    Key := Fnv(@Glyph, SizeOf(Word), Key);
    Key := Fnv(@ARun.EmSize, SizeOf(Single), Key);
    Key := Fnv(@ARun.Sideways, SizeOf(Boolean), Key);
    if not FGlyphPaths.TryGetValue(Key, Geometry) then
    begin
      if FGlyphPaths.Count >= 4096 then
        FGlyphPaths.Clear;
      Geometry := nil;
      if Succeeded(TFastDevice.D2DFactory.CreatePathGeometry(Geometry)) and Succeeded(Geometry.Open(Sink)) then
      begin
        if Failed(ARun.FontFace.GetGlyphRunOutline(ARun.EmSize, @Glyph, nil, nil, 1, ARun.Sideways, False,
          IDWriteGeometrySink(Sink))) then
          Geometry := nil;
        Sink.Close;
        Sink := nil;
      end;
      FGlyphPaths.Add(Key, Geometry);
    end;
    if Geometry = nil then
      Continue;
    // Glyph origin in local space, then the canvas matrix.
    Lx := C.Origin.X + ARun.OriginX + ARun.X[I];
    Ly := C.Origin.Y + ARun.OriginY + ARun.Y[I];
    FillChar(Cmd, SizeOf(Cmd), 0);
    Cmd.Shape := TD2DShape.Path;
    Cmd.Brush := TD2DBrushKind.Solid;
    Cmd.Fill := True;
    Cmd.Clip := C.Clip;
    Cmd.PathKey := Key;
    Cmd.Color := AColor;
    Cmd.Opacity := 1;
    Cmd.Matrix := M;
    Cmd.Matrix.Dx := M.Dx + Lx * M.M11 + Ly * M.M21;
    Cmd.Matrix.Dy := M.Dy + Lx * M.M12 + Ly * M.M22;
    Cmd.GpuOk := True;
    Cmd.Inst.M11 := Cmd.Matrix.M11;
    Cmd.Inst.M12 := Cmd.Matrix.M12;
    Cmd.Inst.M21 := Cmd.Matrix.M21;
    Cmd.Inst.M22 := Cmd.Matrix.M22;
    Cmd.Inst.Dx := Cmd.Matrix.Dx;
    Cmd.Inst.Dy := Cmd.Matrix.Dy;
    Cmd.Inst.Color := AColor;
    Cmd.Inst.Clip := C.Clip;
    Cmd.Inst.Flags := GpuKindPath;
    DrawShapeGpu(@Cmd);
  end;
end;

/// <summary>A layout with color glyphs (emoji): rasterized once on the CPU (a software Direct2D target over a WIC
/// bitmap, which renders color fonts as Direct2D does), kept with the layout data for this scale and color, and
/// drawn as an image.</summary>
procedure TPlayer.DrawColorLayout(const C: PCmdText; const AData: TFastLayoutData);
var
  M: TGpuAffine;
  Scale: Single;
  Ink: TRectF;
  W, H, Y: Integer;
  Key: UInt64;
  Wic: IWICBitmap;
  Target: ID2D1RenderTarget;
  Props: TD2D1RenderTargetProperties;
  Brush: ID2D1SolidColorBrush;
  Options: Cardinal;
  Lock: IWICBitmapLock;
  Size, Stride: Cardinal;
  Bits: PByte;
  Pixels: TBytes;
  B: TFastBitmap;
  Inst: PGpuInstance;
  Flags: Cardinal;
  Rect: WICRect;
  Gen: Integer;
  T: TGpuAffine;
begin
  M := C.Matrix;
  Scale := Max(Sqrt(Sqr(M.M11) + Sqr(M.M12)), Sqrt(Sqr(M.M21) + Sqr(M.M22)));
  if Scale <= 0 then
    Exit;
  // The ink: the layout box widened by the overhangs (distances from its edges).
  Ink := TRectF.Create(-AData.Overhang.left, -AData.Overhang.top, AData.Metrics.layoutWidth + AData.Overhang.right,
    AData.Metrics.layoutHeight + AData.Overhang.bottom);
  if AData.InkOutside then
    Ink.Intersect(TRectF.Create(0, 0, AData.Metrics.layoutWidth, AData.Metrics.layoutHeight));
  W := Min(Ceil(Ink.Width * Scale) + 2, 4096);
  H := Min(Ceil(Ink.Height * Scale) + 2, 4096);
  if (W <= 2) or (H <= 2) then
    Exit;
  Gen := GDeviceGen;
  Key := Fnv(@Scale, SizeOf(Single), Fnv(@C.Color, SizeOf(Cardinal)));
  Key := Fnv(@Gen, SizeOf(Integer), Key);
  if (AData.ColorImage <> nil) and (AData.ColorKey = Key) then
    B := TFastBitmap(AData.ColorImage as TObject)
  else
  begin
    if FWic = nil then
      CoCreateInstance(CLSID_WICImagingFactory, nil, CLSCTX_INPROC_SERVER, IWICImagingFactory, FWic);
    if (FWic = nil) or Failed(FWic.CreateBitmap(W, H, @GUID_WICPixelFormat32bppPBGRA, WICBitmapCacheOnLoad, Wic)) then
      Exit;
    Props := D2D1RenderTargetProperties(D2D1_RENDER_TARGET_TYPE_SOFTWARE,
      D2D1PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), 96, 96);
    if Failed(TFastDevice.D2DFactory.CreateWicBitmapRenderTarget(Wic, Props, Target)) then
      Exit;
    Target.CreateSolidColorBrush(D2DColor(C.Color or $FF000000), nil, Brush);
    Target.SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
    Target.BeginDraw;
    Target.Clear(D2DColor(0));
    T.M11 := Scale;
    T.M12 := 0;
    T.M21 := 0;
    T.M22 := Scale;
    T.Dx := 1 - Ink.Left * Scale;
    T.Dy := 1 - Ink.Top * Scale;
    Target.SetTransform(D2DMatrix(T));
    Options := D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT;
    if AData.InkOutside then
      Options := Options or D2D1_DRAW_TEXT_OPTIONS_CLIP;
    AData.Lock;
    try
      Target.DrawTextLayout(D2DPoint(0, 0), AData.Layout, Brush, Options);
    finally
      AData.Unlock;
    end;
    if Failed(Target.EndDraw) then
      Exit;
    Target := nil;
    Rect.X := 0;
    Rect.Y := 0;
    Rect.Width := W;
    Rect.Height := H;
    if Failed(Wic.Lock(Rect, WICBitmapLockRead, Lock)) then
      Exit;
    Lock.GetStride(Stride);
    Lock.GetDataPointer(Size, WICInProcPointer(Bits));
    SetLength(Pixels, W * 4 * H);
    for Y := 0 to H - 1 do
      Move((Bits + Cardinal(Y) * Stride)^, Pixels[Y * W * 4], W * 4);
    Lock := nil;
    B := TFastBitmap.Create(W, H, @Pixels[0], W * 4);
    if B.FSurface = nil then
    begin
      B.Free;
      Exit;
    end;
    AData.ColorImage := B;
    AData.ColorKey := Key;
  end;
  LeaveD2D;
  // The image covers Ink widened by one pixel on every side, in local space at the text origin.
  Flags := FGpu.WithTexture(GpuKindImage, Pointer(IGpuTexture(B)));
  Inst := FGpu.Append;
  FillChar(Inst^, SizeOf(TGpuInstance), 0);
  Inst.X0 := C.Origin.X + Ink.Left - 1 / Scale;
  Inst.Y0 := C.Origin.Y + Ink.Top - 1 / Scale;
  Inst.X1 := Inst.X0 + B.FWidth / Scale;
  Inst.Y1 := Inst.Y0 + B.FHeight / Scale;
  Inst.M11 := M.M11;
  Inst.M12 := M.M12;
  Inst.M21 := M.M21;
  Inst.M22 := M.M22;
  Inst.Dx := M.Dx;
  Inst.Dy := M.Dy;
  Inst.U0 := 0;
  Inst.V0 := 0;
  Inst.U1 := 1;
  Inst.V1 := 1;
  Inst.Color := OpacityColor(C.Opacity);
  Inst.Flags := Flags;
  Inst.Clip := C.Clip;
end;

/// <summary>Glyph quads of a layout: positions on quarter pixels horizontally, the baseline on whole pixels
/// (Direct2D snaps text vertically), bitmaps from the atlas, rasterized here on first use.</summary>
procedure TPlayer.DrawText(const C: PCmdText);
var
  Data: TFastLayoutData;
  S, X0, Y0, Gx, Atlas: Single;
  Run: TFastGlyphRun;
  Face: TFastFaceGlyphs;
  G: TFastGlyph;
  I, Q, Ix, Sub, Iy: Integer;
  Color: Cardinal;
  Inst: PGpuInstance;
  Box, R: TRectF;
  D: TFastTextDecoration;
  M: TGpuAffine;
  Axis: Boolean;
begin
  Data := TFastLayoutData(C.Data);
  Data.EnsureRuns;
  M := C.Matrix;
  if C.ForceD2D and (TFastDevice.D2DDevice <> nil) then
  begin
    DrawTextD2D(C, Data);
    Exit;
  end;
  if Data.ColorGlyphs then
  begin
    DrawColorLayout(C, Data);
    Exit;
  end;
  S := M.M11;
  // Glyphs from the atlas need an unrotated, uniformly scaled matrix; other runs are drawn as outlines.
  Axis := (Abs(M.M12) <= 1E-5) and (Abs(M.M21) <= 1E-5) and (S > 0) and (Abs(M.M22 - S) <= 1E-4 * S);
  LeaveD2D;
  if FGlyphs = nil then
    FGlyphs := TFastGlyphCache.Create(GpuAtlasSize, GlyphUploadNow, GlyphResetNow);
  Atlas := 1 / FGlyphs.Size;
  Box := FGpu.Clip(C.Clip).Box;
  for Run in Data.Runs do
  begin
    if Run.HasColor then
      Color := MulAlpha(Run.Color, C.Opacity)
    else
      Color := MulAlpha(C.Color, C.Opacity);
    if Color shr 24 = 0 then
      Continue;
    if not Axis or Run.Sideways or (Run.EmSize * S > MaxAtlasEm) then
    begin
      DrawRunOutlines(C, Run, Color);
      Continue;
    end;
    Face := FGlyphs.Face(Run.FontFace, Run.EmSize * S);
    X0 := M.Dx + (C.Origin.X + Run.OriginX) * S;
    Y0 := M.Dy + (C.Origin.Y + Run.OriginY) * S;
    for I := 0 to High(Run.Glyphs) do
    begin
      Gx := X0 + Run.X[I] * S;
      Q := Floor(Gx * TFastGlyphCache.SubpixelSteps + 0.5);
      Ix := Floor(Q / TFastGlyphCache.SubpixelSteps);
      Sub := Q - Ix * TFastGlyphCache.SubpixelSteps;
      Iy := Floor(Y0 + Run.Y[I] * S + 0.5);
      if (Ix - 64 >= Box.Right) or (Iy + 64 <= Box.Top) or (Iy - 256 >= Box.Bottom) then
        Continue;
      G := FGlyphs.Glyph(Face, Run.Glyphs[I], Sub);
      if G.W = 0 then
        Continue;
      if (Ix + G.Left + G.W <= Box.Left) or (Ix + G.Left >= Box.Right) or (Iy + G.Top + G.H <= Box.Top) or
        (Iy + G.Top >= Box.Bottom) then
        Continue;
      Inst := FGpu.Append;
      Inst.X0 := Ix + G.Left;
      Inst.Y0 := Iy + G.Top;
      Inst.X1 := Inst.X0 + G.W;
      Inst.Y1 := Inst.Y0 + G.H;
      Inst.M11 := 1;
      Inst.M12 := 0;
      Inst.M21 := 0;
      Inst.M22 := 1;
      Inst.Dx := 0;
      Inst.Dy := 0;
      Inst.Rx := 0;
      Inst.Ry := 0;
      Inst.U0 := G.X * Atlas;
      Inst.V0 := G.Y * Atlas;
      Inst.U1 := (G.X + G.W) * Atlas;
      Inst.V1 := (G.Y + G.H) * Atlas;
      Inst.Color := Color;
      Inst.Flags := GpuKindGlyph;
      Inst.Clip := C.Clip;
      Inst.Paint := 0;
      Inst.Stroke := 0;
      Inst.Texture := nil;
    end;
  end;
  // Underlines and strikethroughs.
  for D in Data.Decorations do
  begin
    if D.HasColor then
      Color := MulAlpha(D.Color, C.Opacity)
    else
      Color := MulAlpha(C.Color, C.Opacity);
    if Color shr 24 = 0 then
      Continue;
    R := D.Rect;
    R.Offset(C.Origin);
    Inst := FGpu.Append;
    FillChar(Inst^, SizeOf(TGpuInstance), 0);
    Inst.X0 := R.Left;
    Inst.Y0 := R.Top;
    Inst.X1 := R.Right;
    Inst.Y1 := R.Bottom;
    Inst.M11 := M.M11;
    Inst.M12 := M.M12;
    Inst.M21 := M.M21;
    Inst.M22 := M.M22;
    Inst.Dx := M.Dx;
    Inst.Dy := M.Dy;
    Inst.Color := Color;
    Inst.Flags := GpuKindFillRect;
    Inst.Clip := C.Clip;
  end;
end;
procedure TPlayer.Run(const H: PCmdHeader);
var
  D: PByte;
  Proc: TProc;
begin
  D := PByte(H) + SizeOf(TCmdHeader);
  case H.Op of
    TCmd.Target:
      SelectTarget(TFastCanvas(PCmdTarget(D).Canvas));
    TCmd.BeginFrame:
      BeginFrame(PCmdBegin(D));
    TCmd.EndFrame:
      EndFrame(PCmdEnd(D));
    TCmd.Region:
      SetRegion(PCmdRegion(D));
    TCmd.Instances:
      begin
        LeaveD2D;
        FGpu.Add(PGpuInstance(D + SizeOf(TCmdInstances)), PCmdInstances(D).Count);
      end;
    TCmd.Clip:
      FGpu.SetClip(PCmdClip(D).Index, PCmdClip(D).Clip);
    TCmd.Paint:
      FGpu.SetPaint(PCmdPaint(D).Index, PCmdPaint(D).Paint);
    TCmd.Ramp:
      FGpu.UploadRamp(PCmdRamp(D).Row, @PCmdRamp(D).Texels[0]);

    TCmd.Flush:
      begin
        LeaveD2D;
        FGpu.Flush;
      end;
    TCmd.Clear:
      begin
        LeaveD2D;
        FGpu.Clear(PCmdColor(D).Color);
      end;
    TCmd.FillCopy:
      begin
        LeaveD2D;
        FGpu.FillCopy(PCmdFillCopy(D).Rect, PCmdFillCopy(D).Color, PCmdFillCopy(D).Clip);
      end;
    TCmd.PathDef:
      DefinePath(PCmdPathDef(D));
    TCmd.ResetPaths:
      FPaths.Clear;
    TCmd.D2DShape:
      DrawShape(PCmdD2D(D));
    TCmd.Text:
      DrawText(PCmdText(D));
    TCmd.Callback:
      begin
        // The canvas's drawing so far goes to the immediate context first: the callback may read its targets.
        LeaveD2D;
        FGpu.Flush;
        Proc := nil;
        PPointer(@Proc)^ := PCmdCallback(D).Proc;
        try
          Proc();
        finally
          PPointer(@Proc)^ := nil;
        end;
        FGpu.Invalidate;
      end;
    TCmd.Native:
      begin
        // The canvas's drawing so far goes into the command list first.
        LeaveD2D;
        FGpu.Flush;
        TFastNativeHandler(PPointer(D)^)(D + SizeOf(Pointer));
      end;
    TCmd.ExecuteList:
      begin
        LeaveD2D;
        FGpu.Flush;
        // Keeps the state of the immediate context, which Direct2D shares.
        if TFastDevice.Context <> nil then
          TFastDevice.Context.ExecuteCommandList(ID3D11CommandList(PCmdList(D).List), True);
        FGpu.Invalidate;
      end;
  end;
end;

procedure TPlayer.Execute(const AData: PByte; const ASize: Integer);
var
  P, PEnd: PByte;
  H: PCmdHeader;
begin
  P := AData;
  PEnd := AData + ASize;
  while P < PEnd do
  begin
    H := PCmdHeader(P);
    try
      Run(H);
    except
      on E: EAbort do
        ;
      on E: Exception do
        // On a removed device everything fails until the next outer scene recreates it.
        if DeviceGone then
          MarkDeviceLost
        else
          GQueue.ReportError(Format('%s: %s (command %d)', [E.ClassName, E.Message, Ord(H.Op)]));
    end;
    Inc(P, H.Size);
  end;
end;

procedure PlayStream(const AData: PByte; const ASize: Integer);
begin
  TFastDevice.Lock;
  try
    if GPlayer = nil then
      GPlayer := TPlayer.Create;
    GPlayer.Execute(AData, ASize);
    // Direct3D 12: the chunk's work goes to the GPU while the next one is recorded.
    Backend.Submit;
  finally
    TFastDevice.Unlock;
  end;
end;

{ Bridge (FastCanvas.Bridge): the 3D context on the canvas device }

function BridgeDevice: ID3D11Device;
begin
  TFastDevice.Ensure;
  Result := TFastDevice.D3D;
end;

function BridgeContext: ID3D11DeviceContext;
begin
  TFastDevice.Ensure;
  Result := TFastDevice.Context;
end;

function BridgeLevel: D3D_FEATURE_LEVEL;
begin
  TFastDevice.Ensure;
  Result := TFastDevice.FeatureLevel;
end;

function BridgeHardware: Boolean;
begin
  TFastDevice.Ensure;
  Result := TFastDevice.Hardware;
end;

procedure BridgeLock;
begin
  TFastDevice.Lock;
end;

procedure BridgeUnlock;
begin
  TFastDevice.Unlock;
end;

function BridgeRecording: Boolean;
begin
  // Other threads record too, but wait for the render thread at their EndScene; the deferred 3D path is for the
  // main thread, and only with a render thread (else the 3D context draws on the immediate context after a Sync,
  // which executes the recorded commands first).
  Result := (GetCurrentThreadId = MainThreadID) and ((GQueue = nil) or GQueue.Threaded);
end;

procedure BridgeExecute(const AList: ID3D11CommandList);
begin
  if AList <> nil then
    PCmdList(RecAlloc(TCmd.ExecuteList, SizeOf(TCmdList), AList)).List := Pointer(AList);
end;

function BridgeTexture(const ABitmap: TBitmap): ID3D11Texture2D;
begin
  if (ABitmap <> nil) and ABitmap.HandleAllocated and ABitmap.CanvasClass.InheritsFrom(TFastCanvas) and
    (TFastBitmap(ABitmap.Handle).FSurface is TGpu11Surface) then
    Result := TGpu11Surface(TFastBitmap(ABitmap.Handle).FSurface).Texture
  else
    Result := nil;
end;

function BridgeSurface(const ABitmap: TBitmap): IInterface;
begin
  if (ABitmap <> nil) and ABitmap.HandleAllocated and ABitmap.CanvasClass.InheritsFrom(TFastCanvas) then
    Result := IGpuTexture(TFastBitmap(ABitmap.Handle))
  else
    Result := nil;
end;

procedure BridgeRunOnRender(const AProc: TProc);
var
  C: PCmdCallback;
  Ref: IInterface;
begin
  if not Assigned(AProc) then
    Exit;
  TCanvas.Lock;
  try
    Ref := IInterface(PPointer(@AProc)^);
    C := RecAlloc(TCmd.Callback, SizeOf(TCmdCallback), Ref);
    C.Proc := PPointer(@AProc)^;
  finally
    TCanvas.Unlock;
  end;
end;

function BridgeRecordNative(const AHandler: TFastNativeHandler; const ASize: Integer; const ARef: IInterface): Pointer;
var
  P: PPointer;
begin
  P := RecAlloc(TCmd.Native, SizeOf(Pointer) + ASize, ARef);
  P^ := @AHandler;
  Result := PByte(P) + SizeOf(Pointer);
end;

procedure BridgeKeepAlive(const ARef: IInterface);
begin
  if ARef <> nil then
    Queue.Chunk.KeepAlive(ARef);
end;

procedure BridgeWritten(const ABitmap: TBitmap);
begin
  if (ABitmap <> nil) and ABitmap.HandleAllocated and ABitmap.CanvasClass.InheritsFrom(TFastCanvas) then
    TFastBitmap(ABitmap.Handle).GpuWritten;
end;

{ Installation }

procedure ShutdownFastCanvas;
begin
  // Executes what is left and stops the render thread before the device goes.
  FreeAndNil(GQueue);
  if TFastDevice.Ready then
    Backend.WaitIdle;
  FreeAndNil(GPlayer);
  GRecTarget := nil;
  FreeAndNil(GRamps);
  FreeAndNil(GKnownPaths);
  FastTextShutdown;
  if TFastDevice.Ready then
    Backend.Shutdown;
  TFastDevice.Finish;
  // The registries go now when empty, else with their last entry (Unregister).
  GFinished := True;
  if GBitmapsLock <> nil then
  begin
    TMonitor.Enter(GBitmapsLock);
    try
      if (GBitmaps <> nil) and (GBitmaps.Count = 0) then
        FreeAndNil(GBitmaps);
      if (GTargets <> nil) and (GTargets.Count = 0) then
        FreeAndNil(GTargets);
    finally
      TMonitor.Exit(GBitmapsLock);
    end;
    if (GBitmaps = nil) and (GTargets = nil) then
      FreeAndNil(GBitmapsLock);
  end;
end;

procedure InstallFastCanvas;
begin
  if FastCanvasNoHeapSleep then
    NeverSleepOnMMThreadContention := True;
  InstallCanvasService(TFastCanvas, ShutdownFastCanvas);
  GInstalled := True;
  FastBridge.Device := BridgeDevice;
  FastBridge.ImmediateContext := BridgeContext;
  FastBridge.FeatureLevel := BridgeLevel;
  FastBridge.Hardware := BridgeHardware;
  FastBridge.Lock := BridgeLock;
  FastBridge.Unlock := BridgeUnlock;
  FastBridge.Sync := FastCanvasSync;
  FastBridge.Recording := BridgeRecording;
  FastBridge.ExecuteCommandList := BridgeExecute;
  FastBridge.BitmapTexture := BridgeTexture;
  FastBridge.BitmapSurface := BridgeSurface;
  FastBridge.BitmapWritten := BridgeWritten;
  FastBridge.RunOnRender := BridgeRunOnRender;
  FastBridge.RecordNative := BridgeRecordNative;
  FastBridge.KeepAlive := BridgeKeepAlive;
end;

initialization
  // Freed by ShutdownFastCanvas (or with the last bitmap after it), not here: bitmaps are freed by FMX after the
  // unit finalizations.
  GBitmapsLock := TObject.Create;
  FastDrawLayout := DrawLayoutOnCanvas;
  TTextLayoutManager.RegisterTextLayout(TFastTextLayout, TFastCanvas);
finalization
  // When installed, the canvas service shuts down after the forms are freed (FastCanvas.Service).
  if not GInstalled then
    ShutdownFastCanvas;
end.
