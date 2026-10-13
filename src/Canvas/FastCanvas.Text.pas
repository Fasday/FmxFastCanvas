unit FastCanvas.Text;

{ Text of FastCanvas: what the canvas needs of a text layout, whatever lays it out.

  TFastTextLayout implements the FMX TTextLayout contract (FMX.TextLayout.pas:48-177) for the canvas; a text engine
  lays the text out and makes its glyphs: DirectWrite (FastCanvas.TextDWrite, Windows, the default there) or Skia
  (FastCanvas.TextSkia, every platform, the only one on Android and Linux); FastCanvasTextEngine chooses one. A layout
  is analysed once into glyph runs (TFastLayoutData, shared through a cache by all layouts with the same text and
  parameters); the canvas draws the runs as GPU quads that sample glyph bitmaps from an atlas texture.
  TFastGlyphCache owns the atlas: the engine rasterizes glyphs (grayscale, ClearType or aliased coverage) on demand,
  and the cache hands the bitmaps to the canvas for upload.

  Written from the DirectWrite and Skia documentation; no code from the FMX canvases. }

interface

uses
  System.Types, System.UITypes, System.SysUtils, System.Math, System.Generics.Collections, FMX.Types, FMX.Graphics,
  FMX.TextLayout, FastCanvas.Geometry;

type
  TFastGlyphRun = record
    /// <summary>The engine's font face (DirectWrite: IDWriteFontFace), the same object for the same face: glyphs are
    /// cached by it.</summary>
    FontFace: IInterface;
    EmSize: Single;
    Sideways: Boolean;
    BidiLevel: Cardinal;
    /// <summary>Baseline origin in layout coordinates (relative to the layout box).</summary>
    OriginX, OriginY: Single;
    Glyphs: TArray<Word>;
    Advances: TArray<Single>;
    /// <summary>Glyph offsets along the reading direction (X) and upwards (Y), as DirectWrite gives them.</summary>
    Offsets: TArray<TPointF>;
    /// <summary>Origin of every glyph relative to the run origin.</summary>
    X, Y: TArray<Single>;
    Color: TAlphaColor;
    /// <summary>The run has its own color (a text attribute); otherwise it takes the layout color.</summary>
    HasColor: Boolean;
  end;

  TFastTextDecoration = record
    Rect: TRectF;
    Color: TAlphaColor;
    HasColor: Boolean;
  end;

  /// <summary>Ink beyond the layout box: distances from its left, top, right and bottom edges, positive outside (as
  /// DirectWrite's overhang metrics).</summary>
  TFastOverhang = record
    Left, Top, Right, Bottom: Single;
  end;

  /// <summary>Result of laying out a text; shared by layouts with the same key. Reference counted: the layout
  /// cache, every TFastTextLayout that uses it and the command chunks that draw it hold a reference.
  /// The glyph runs are collected on first use (EnsureRuns, usually on the render thread); Lock/Unlock guard
  /// the engine's layout, which is not safe for concurrent use.</summary>
  TFastLayoutData = class(TInterfacedObject)
  private
    FRunsReady: Boolean;
  protected
    /// <summary>Engine: fills Runs, Decorations and ColorGlyphs (once, locked).</summary>
    procedure CollectRuns; virtual; abstract;
  public
    Runs: TArray<TFastGlyphRun>;
    Decorations: TArray<TFastTextDecoration>;
    /// <summary>The size of the layout box the text was laid out in.</summary>
    LayoutWidth, LayoutHeight: Single;
    Overhang: TFastOverhang;
    /// <summary>A run uses a color font (emoji). Valid after EnsureRuns.</summary>
    ColorGlyphs: Boolean;
    /// <summary>Layouts with color glyphs: the canvas's rasterized image of the layout and what it was made for
    /// (render thread only).</summary>
    ColorImage: IInterface;
    ColorKey: UInt64;
    /// <summary>Ink outside the layout box: the canvas clips to the box, as Direct2D does with
    /// D2D1_DRAW_TEXT_OPTIONS_CLIP.</summary>
    InkOutside: Boolean;
    procedure AddRef; inline;
    procedure Release; inline;
    procedure Lock; inline;
    procedure Unlock; inline;
    /// <summary>Collects the glyph runs and decorations (once).</summary>
    procedure EnsureRuns;
    /// <summary>Layouts with color glyphs: the layout drawn on the CPU into premultiplied BGRA pixels, AWidth x
    /// AHeight (rows of AWidth * 4 bytes), layout coordinates scaled by AScale and moved by ADx, ADy, the text in
    /// AColor (opaque; color glyphs in their own colors), clipped to the layout box when InkOutside. False when the
    /// engine cannot.</summary>
    function RenderColor(const AScale, ADx, ADy: Single; const AColor: TAlphaColor; const AWidth, AHeight: Integer;
      out APixels: TBytes): Boolean; virtual;
  end;

  TFastDrawLayoutProc = procedure(const ACanvas: TCanvas; const AData: TFastLayoutData; const AOrigin: TPointF;
    const AMaxSize: TPointF; const AColor: TAlphaColor; const AOpacity: Single);

  /// <summary>The text layout of the canvas; the engines derive from it.</summary>
  TFastTextLayout = class(TTextLayout)
  private
    FData: TFastLayoutData;
  protected
    procedure SetData(const AData: TFastLayoutData);
    function LayoutOrigin: TPointF;
    /// <summary>The cached data of AKey becomes the layout's: True; False when there is none.</summary>
    function UseCached(const AKey: string): Boolean;
    /// <summary>The layout's data into the cache under AKey.</summary>
    procedure CacheData(const AKey: string);
    procedure DoDrawLayout(const ACanvas: TCanvas); override;
  public
    destructor Destroy; override;
    property Data: TFastLayoutData read FData;
  end;

  TFastGlyph = record
    /// <summary>Atlas position and size in pixels; W = 0 for glyphs without ink (spaces). A ClearType glyph takes 3 * W
    /// texels of the atlas in width: R, G and B coverage of every pixel.</summary>
    X, Y, W, H: SmallInt;
    /// <summary>Top-left of the glyph bitmap relative to the (integer) baseline origin, pixels.</summary>
    Left, Top: SmallInt;
  end;
  PFastGlyph = ^TFastGlyph;

  TFastGlyphUploadProc = procedure(const X, Y, W, H: Integer; const AData: PByte; const APitch: Integer);
  TFastGlyphResetProc = procedure;

  /// <summary>How a glyph is rasterized: grayscale coverage; ClearType coverage, three texels (R, G, B) per pixel;
  /// aliased, every pixel covered or not.</summary>
  TFastGlyphKind = (Gray, ClearType, Aliased);

  /// <summary>A text engine: its layout class, and the glyphs of the font faces of its runs. Glyphs are made on the
  /// render thread.</summary>
  TFastTextEngine = class abstract
  public
    /// <summary>The TTextLayout class of the engine (a TFastTextLayout).</summary>
    class function LayoutClass: TTextLayoutClass; virtual; abstract;
    /// <summary>Coverage of a glyph at AEmSize pixels per em, its origin ASubX pixels (0 <= ASubX < 1) right of a
    /// whole pixel, as AKind: rows of W bytes (ClearType: 3 * W, red first) into ABuffer (grown as needed);
    /// ABounds: the pixels relative to the origin. AMode: the engine's state for the face at this size, 0 at first.
    /// False: no ink, or larger than AMaxSize in either direction.</summary>
    class function RasterizeGlyph(const AFace: IInterface; const AGlyph: Word; const AEmSize, ASubX: Single;
      const AKind: TFastGlyphKind; const AMaxSize: Integer; var AMode: Integer; var ABuffer: TBytes;
      out ABounds: TRect): Boolean; virtual; abstract;
    /// <summary>The outline of a glyph at AEmSize, its origin at (0, 0) on the baseline, as FMX path points (filled
    /// with the non-zero rule). False when the engine cannot.</summary>
    class function GlyphOutline(const AFace: IInterface; const AGlyph: Word; const AEmSize: Single;
      const ASideways: Boolean; out APoints: TArray<TPathPoint>): Boolean; virtual; abstract;
    /// <summary>The display's subpixels are in a row (RGB or BGR): ClearType can be drawn.</summary>
    class function ClearTypeGeometry: Boolean; virtual;
    /// <summary>Releases the engine's shared objects (shutdown).</summary>
    class procedure Shutdown; virtual;
  end;
  TFastTextEngineClass = class of TFastTextEngine;

  /// <summary>Glyphs of one font face at one size (pixels per em), by glyph index and subpixel position.</summary>
  TFastFaceGlyphs = class
  private
    FFace: IInterface;
    FEmSize: Single;
    FMode: Integer;
    FGlyphs: TDictionary<Cardinal, TFastGlyph>;
  public
    constructor Create(const AFace: IInterface; const AEmSize: Single);
    destructor Destroy; override;
  end;

  /// <summary>Glyph atlas: an GpuAtlasSize square of 8-bit coverage, shelf-packed. Used by the recording thread
  /// only (FMX holds the canvas lock between BeginScene and EndScene).</summary>
  TFastGlyphCache = class
  public const
    SubpixelSteps = 4;
  private
    FEngine: TFastTextEngineClass;
    FSize: Integer;
    FFaces: TObjectDictionary<UInt64, TFastFaceGlyphs>;
    FShelves: TArray<TPoint>;   // X = used width, Y = top; heights in FShelfHeights
    FShelfHeights: TArray<Integer>;
    FNextY: Integer;
    FBuffer: TBytes;
    FUpload: TFastGlyphUploadProc;
    FReset: TFastGlyphResetProc;
    FResets: Integer;
    function Allocate(const W, H: Integer; out X, Y: Integer): Boolean;
    function Rasterize(const AFaceGlyphs: TFastFaceGlyphs; const AGlyph: Word; const ASub: Integer;
      const AKind: TFastGlyphKind; out AResult: TFastGlyph): Boolean;
  public
    constructor Create(const AEngine: TFastTextEngineClass; const ASize: Integer; const AUpload: TFastGlyphUploadProc;
      const AReset: TFastGlyphResetProc);
    destructor Destroy; override;
    /// <summary>The glyph set of a face at a pixel size. Valid until the next Clear (also implicit when the atlas
    /// is full).</summary>
    function Face(const AFace: IInterface; const AEmSize: Single): TFastFaceGlyphs;
    /// <summary>The glyph at a subpixel position 0..SubpixelSteps - 1, rasterized as AKind; rasterized and uploaded on
    /// first use. AFaceGlyphs is replaced when the atlas was full and started over.</summary>
    function Glyph(var AFaceGlyphs: TFastFaceGlyphs; const AGlyph: Word; const ASub: Integer;
      const AKind: TFastGlyphKind = TFastGlyphKind.Gray): TFastGlyph;
    /// <summary>The display's subpixels are in a row (RGB or BGR): ClearType can be drawn.</summary>
    function ClearTypeGeometry: Boolean;
    procedure Clear;
    property Engine: TFastTextEngineClass read FEngine;
    property Size: Integer read FSize;
    property Resets: Integer read FResets;
  end;

var
  /// <summary>Set by FastCanvas.Canvas: draws layout data on its canvas.</summary>
  FastDrawLayout: TFastDrawLayoutProc;
  /// <summary>The engine of the text: read by InstallFastCanvas, which registers its layout class for the canvas.
  /// Android and Linux: Skia whatever it says.</summary>
  FastCanvasTextEngine: TFastCanvasEngine =
    {$IFDEF MSWINDOWS}TFastCanvasEngine.Native{$ELSE}TFastCanvasEngine.Skia{$ENDIF};

/// <summary>Called by the engine units (initialization).</summary>
procedure FastRegisterTextEngine(const AKind: TFastCanvasEngine; const AClass: TFastTextEngineClass);
/// <summary>The class of the engine FastCanvasTextEngine chooses (Skia on Android and Linux). Raises when the unit of
/// that engine is not in the program.</summary>
function FastTextEngineClass: TFastTextEngineClass;
/// <summary>The key of a layout's parameters and text in the layout cache.</summary>
function FastLayoutCacheKey(const ALayout: TTextLayout): string;
/// <summary>Releases the shared layout cache and the engines' objects (shutdown).</summary>
procedure FastTextShutdown;

implementation

const
  /// <summary>Layouts per generation of the layout cache (it keeps two).</summary>
  CacheGeneration = 2048;
  /// <summary>Evicted layouts released per new layout: an evicted generation is gone long before the next one.</summary>
  ReleasesPerLayout = 4;

var
  // Layout cache in two generations: a hit in the old one moves the layout to the current one; when the current
  // one is full it becomes the old one, and the layouts of the old one are released a few per new layout (releasing
  // thousands of DirectWrite layouts at once stalled a frame for 60 ms).
  GCache, GCacheOld: TDictionary<string, TFastLayoutData>;
  GEvicted: TList<TFastLayoutData>;
  GCacheLock: TObject;
  GEngines: array[TFastCanvasEngine] of TFastTextEngineClass;

procedure FastRegisterTextEngine(const AKind: TFastCanvasEngine; const AClass: TFastTextEngineClass);
begin
  GEngines[AKind] := AClass;
end;

function FastTextEngineClass: TFastTextEngineClass;
var
  Kind: TFastCanvasEngine;
begin
  Kind := FastCanvasTextEngine;
{$IFNDEF MSWINDOWS}
  Kind := TFastCanvasEngine.Skia;
{$ENDIF}
  Result := GEngines[Kind];
  if Result = nil then
    raise Exception.Create('FastCanvas: the text engine is not in the program (add FastCanvas.TextSkia)');
end;

{ TFastTextEngine }

class function TFastTextEngine.ClearTypeGeometry: Boolean;
begin
  Result := False;
end;

class procedure TFastTextEngine.Shutdown;
begin
end;

{ TFastLayoutData }

procedure TFastLayoutData.AddRef;
begin
  _AddRef;
end;

procedure TFastLayoutData.Release;
begin
  _Release;
end;

procedure TFastLayoutData.Lock;
begin
  TMonitor.Enter(Self);
end;

procedure TFastLayoutData.Unlock;
begin
  TMonitor.Exit(Self);
end;

procedure TFastLayoutData.EnsureRuns;
begin
  if FRunsReady then
    Exit;
  Lock;
  try
    if not FRunsReady then
    begin
      CollectRuns;
      FRunsReady := True;
    end;
  finally
    Unlock;
  end;
end;

function TFastLayoutData.RenderColor(const AScale, ADx, ADy: Single; const AColor: TAlphaColor; const AWidth,
  AHeight: Integer; out APixels: TBytes): Boolean;
begin
  APixels := nil;
  Result := False;
end;

{ TFastTextLayout }

destructor TFastTextLayout.Destroy;
begin
  SetData(nil);
  inherited;
end;

procedure TFastTextLayout.SetData(const AData: TFastLayoutData);
begin
  if AData <> nil then
    AData.AddRef;
  if FData <> nil then
    FData.Release;
  FData := AData;
end;

function TFastTextLayout.LayoutOrigin: TPointF;
begin
  Result := TPointF.Create(TopLeft.X + Padding.Left, TopLeft.Y + Padding.Top);
end;

function FastLayoutCacheKey(const ALayout: TTextLayout): string;
var
  H: packed record
    Size, MaxX, MaxY, PadL, PadT, PadR, PadB: Single;
    Weight, Slant, Stretch: Byte;
    Simple: Byte;
    Flags: Word;
  end;
  S: string;
begin
  H.Size := ALayout.Font.Size;
  H.MaxX := ALayout.MaxSize.X;
  H.MaxY := ALayout.MaxSize.Y;
  H.PadL := ALayout.Padding.Left;
  H.PadT := ALayout.Padding.Top;
  H.PadR := ALayout.Padding.Right;
  H.PadB := ALayout.Padding.Bottom;
  H.Weight := Ord(ALayout.Font.StyleExt.Weight);
  H.Slant := Ord(ALayout.Font.StyleExt.Slant);
  H.Stretch := Ord(ALayout.Font.StyleExt.Stretch);
  H.Simple := Byte(ALayout.Font.StyleExt.SimpleStyle);
  H.Flags := Ord(ALayout.WordWrap) or (Ord(ALayout.RightToLeft) shl 1) or (Ord(ALayout.Trimming) shl 2) or
    (Ord(ALayout.HorizontalAlign) shl 4) or (Ord(ALayout.VerticalAlign) shl 6);
  SetString(S, PChar(@H), SizeOf(H) div SizeOf(Char));
  Result := S + ALayout.Font.Family + #0 + ALayout.Text;
end;

/// <summary>Cached layout data (under GCacheLock); not referenced for the caller.</summary>
function CacheFind(const AKey: string; out AData: TFastLayoutData): Boolean;
begin
  if GCache = nil then
    Exit(False);
  Result := GCache.TryGetValue(AKey, AData);
  if not Result and GCacheOld.TryGetValue(AKey, AData) then
  begin
    // The cache reference moves with it.
    GCacheOld.Remove(AKey);
    GCache.Add(AKey, AData);
    Result := True;
  end;
end;

/// <summary>Adds layout data to the cache (under GCacheLock), which takes a reference.</summary>
procedure CacheAdd(const AKey: string; const AData: TFastLayoutData);
var
  I: Integer;
  D: TFastLayoutData;
  T: TDictionary<string, TFastLayoutData>;
begin
  if GCache = nil then
  begin
    GCache := TDictionary<string, TFastLayoutData>.Create;
    GCacheOld := TDictionary<string, TFastLayoutData>.Create;
    GEvicted := TList<TFastLayoutData>.Create;
  end;
  for I := 1 to Min(ReleasesPerLayout, GEvicted.Count) do
  begin
    GEvicted.Last.Release;
    GEvicted.Delete(GEvicted.Count - 1);
  end;
  if GCache.ContainsKey(AKey) or GCacheOld.ContainsKey(AKey) then
    Exit;
  if GCache.Count >= CacheGeneration then
  begin
    for D in GEvicted do
      D.Release;
    GEvicted.Clear;
    GEvicted.AddRange(GCacheOld.Values);
    GCacheOld.Clear;
    T := GCacheOld;
    GCacheOld := GCache;
    GCache := T;
  end;
  AData.AddRef;
  GCache.Add(AKey, AData);
end;

function TFastTextLayout.UseCached(const AKey: string): Boolean;
var
  D: TFastLayoutData;
begin
  TMonitor.Enter(GCacheLock);
  try
    Result := CacheFind(AKey, D);
    if Result then
      SetData(D);
  finally
    TMonitor.Exit(GCacheLock);
  end;
end;

procedure TFastTextLayout.CacheData(const AKey: string);
begin
  TMonitor.Enter(GCacheLock);
  try
    CacheAdd(AKey, FData);
  finally
    TMonitor.Exit(GCacheLock);
  end;
end;

procedure TFastTextLayout.DoDrawLayout(const ACanvas: TCanvas);
begin
  if (FData <> nil) and Assigned(FastDrawLayout) then
    FastDrawLayout(ACanvas, FData, LayoutOrigin,
      TPointF.Create(MaxSize.X - Padding.Left - Padding.Right, MaxSize.Y - Padding.Top - Padding.Bottom), Color, Opacity);
end;

{ TFastFaceGlyphs }

constructor TFastFaceGlyphs.Create(const AFace: IInterface; const AEmSize: Single);
begin
  inherited Create;
  FFace := AFace;
  FEmSize := AEmSize;
  FMode := 0;
  FGlyphs := TDictionary<Cardinal, TFastGlyph>.Create;
end;

destructor TFastFaceGlyphs.Destroy;
begin
  FGlyphs.Free;
  inherited;
end;

{ TFastGlyphCache }

constructor TFastGlyphCache.Create(const AEngine: TFastTextEngineClass; const ASize: Integer;
  const AUpload: TFastGlyphUploadProc; const AReset: TFastGlyphResetProc);
begin
  inherited Create;
  FEngine := AEngine;
  FSize := ASize;
  FUpload := AUpload;
  FReset := AReset;
  FFaces := TObjectDictionary<UInt64, TFastFaceGlyphs>.Create([doOwnsValues]);
end;

destructor TFastGlyphCache.Destroy;
begin
  FFaces.Free;
  inherited;
end;

procedure TFastGlyphCache.Clear;
begin
  FFaces.Clear;
  FShelves := nil;
  FShelfHeights := nil;
  FNextY := 0;
  Inc(FResets);
  if Assigned(FReset) then
    FReset;
end;

function TFastGlyphCache.Face(const AFace: IInterface; const AEmSize: Single): TFastFaceGlyphs;
var
  Key: UInt64;
  Size: Single;
begin
  Size := AEmSize;
  Key := UInt64(NativeUInt(Pointer(AFace))) xor (UInt64(PCardinal(@Size)^) shl 17) * UInt64($9E3779B97F4A7C15);
  if FFaces.TryGetValue(Key, Result) and (Pointer(Result.FFace) = Pointer(AFace)) and (Result.FEmSize = AEmSize) then
    Exit;
  Result := TFastFaceGlyphs.Create(AFace, AEmSize);
  FFaces.AddOrSetValue(Key, Result);
end;

function TFastGlyphCache.Allocate(const W, H: Integer; out X, Y: Integer): Boolean;
var
  I, Best: Integer;
begin
  Best := -1;
  for I := 0 to High(FShelves) do
    if (FShelfHeights[I] >= H) and (FShelfHeights[I] <= H + H div 4 + 2) and (FShelves[I].X + W <= FSize) and
      ((Best < 0) or (FShelfHeights[I] < FShelfHeights[Best])) then
      Best := I;
  if Best < 0 then
  begin
    if (FNextY + H > FSize) or (W > FSize) then
      Exit(False);
    Best := Length(FShelves);
    SetLength(FShelves, Best + 1);
    SetLength(FShelfHeights, Best + 1);
    FShelves[Best] := TPoint.Create(0, FNextY);
    FShelfHeights[Best] := H;
    Inc(FNextY, H);
  end;
  X := FShelves[Best].X;
  Y := FShelves[Best].Y;
  Inc(FShelves[Best].X, W);
  Result := True;
end;

function TFastGlyphCache.ClearTypeGeometry: Boolean;
begin
  Result := FEngine.ClearTypeGeometry;
end;

function TFastGlyphCache.Rasterize(const AFaceGlyphs: TFastFaceGlyphs; const AGlyph: Word; const ASub: Integer;
  const AKind: TFastGlyphKind; out AResult: TFastGlyph): Boolean;
var
  Bounds: TRect;
  W, H, X, Y, Texels: Integer;
begin
  FillChar(AResult, SizeOf(AResult), 0);
  Result := True;
  // Glyphs without ink, and larger ones (drawn as outlines: the canvas never asks for them), stay out of the atlas.
  if not FEngine.RasterizeGlyph(AFaceGlyphs.FFace, AGlyph, AFaceGlyphs.FEmSize, ASub / SubpixelSteps, AKind,
    FSize div 4, AFaceGlyphs.FMode, FBuffer, Bounds) then
    Exit;
  W := Bounds.Width;
  H := Bounds.Height;
  Texels := W;
  if AKind = TFastGlyphKind.ClearType then
    Texels := 3 * W;
  // One pixel of padding: bilinear taps never reach a neighbour (glyphs are point-sampled anyway).
  if not Allocate(Texels + 1, H + 1, X, Y) then
    Exit(False);
  FUpload(X, Y, Texels, H, @FBuffer[0], Texels);
  AResult.X := X;
  AResult.Y := Y;
  AResult.W := W;
  AResult.H := H;
  AResult.Left := Bounds.Left;
  AResult.Top := Bounds.Top;
end;

function TFastGlyphCache.Glyph(var AFaceGlyphs: TFastFaceGlyphs; const AGlyph: Word; const ASub: Integer;
  const AKind: TFastGlyphKind): TFastGlyph;
var
  Key: Cardinal;
  Face: IInterface;
  EmSize: Single;
begin
  Key := AGlyph or (Cardinal(ASub) shl 16) or (Cardinal(Ord(AKind)) shl 24);
  if AFaceGlyphs.FGlyphs.TryGetValue(Key, Result) then
    Exit;
  if not Rasterize(AFaceGlyphs, AGlyph, ASub, AKind, Result) then
  begin
    // The atlas is full: start over (the canvas flushes what was drawn with the old content).
    Face := AFaceGlyphs.FFace;
    EmSize := AFaceGlyphs.FEmSize;
    Clear;
    AFaceGlyphs := Self.Face(Face, EmSize);
    if not Rasterize(AFaceGlyphs, AGlyph, ASub, AKind, Result) then
      FillChar(Result, SizeOf(Result), 0);
  end;
  AFaceGlyphs.FGlyphs.Add(Key, Result);
end;

procedure FastTextShutdown;
var
  D: TFastLayoutData;
  E: TFastCanvasEngine;
begin
  if GCacheLock = nil then
    Exit;
  TMonitor.Enter(GCacheLock);
  try
    if GCache <> nil then
    begin
      for D in GCache.Values do
        D.Release;
      for D in GCacheOld.Values do
        D.Release;
      for D in GEvicted do
        D.Release;
      FreeAndNil(GCache);
      FreeAndNil(GCacheOld);
      FreeAndNil(GEvicted);
    end;
    for E := Low(TFastCanvasEngine) to High(TFastCanvasEngine) do
      if GEngines[E] <> nil then
        GEngines[E].Shutdown;
  finally
    TMonitor.Exit(GCacheLock);
  end;
  // Layouts made after this would need the device, which is gone (TFastDevice.Ensure raises).
  FreeAndNil(GCacheLock);
end;

initialization
  // Freed by FastTextShutdown, not here: layouts are destroyed with the forms, after the unit finalizations (the
  // canvas service shuts down then).
  GCacheLock := TObject.Create;
end.
