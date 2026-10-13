unit FastCanvas.Text;

{ Text of FastCanvas (stage 4).

  TFastTextLayout implements the FMX TTextLayout contract (FMX.TextLayout.pas:48-177) over a DirectWrite text
  layout. A layout is analysed once into glyph runs (TFastLayoutData, shared through a cache by all layouts with
  the same text and parameters); the canvas draws the runs as GPU quads that sample glyph bitmaps from an atlas
  texture. TFastGlyphCache owns the atlas: it rasterizes glyphs with DirectWrite (grayscale, ClearType or aliased
  coverage) on demand and hands the bitmaps to the canvas for upload.

  Written from the DirectWrite documentation; no code from the FMX canvases. }

interface

uses
  Winapi.Windows, Winapi.D2D1, System.Types, System.UITypes, System.SysUtils, System.Math, System.Math.Vectors,
  System.Generics.Collections, FMX.Types, FMX.Graphics, FMX.TextLayout, FastCanvas.DWriteExt;

type
  TFastGlyphRun = record
    FontFace: IDWriteFontFace;
    EmSize: Single;
    Sideways: Boolean;
    BidiLevel: Cardinal;
    /// <summary>Baseline origin in layout coordinates (relative to the layout box).</summary>
    OriginX, OriginY: Single;
    Glyphs: TArray<Word>;
    Advances: TArray<Single>;
    Offsets: TArray<TDwriteGlyphOffset>;
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

  /// <summary>Result of laying out a text; shared by layouts with the same key. Reference counted: the layout
  /// cache, every TFastTextLayout that uses it and the command chunks that draw it hold a reference.
  /// The glyph runs are collected on first use (EnsureRuns, usually on the render thread); Lock/Unlock guard
  /// the DirectWrite layout, which is not safe for concurrent use.</summary>
  TFastLayoutData = class(TInterfacedObject)
  private
    FRunsReady: Boolean;
  public
    Layout: IDWriteTextLayout;
    Metrics: TDwriteTextMetrics;
    Overhang: TDwriteOverhangMetrics;
    Runs: TArray<TFastGlyphRun>;
    Decorations: TArray<TFastTextDecoration>;
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
  end;

  TFastDrawLayoutProc = procedure(const ACanvas: TCanvas; const AData: TFastLayoutData; const AOrigin: TPointF;
    const AMaxSize: TPointF; const AColor: TAlphaColor; const AOpacity: Single);

  TFastTextLayout = class(TTextLayout)
  private
    FData: TFastLayoutData;
    FTextRect: TRectF;
    procedure SetData(const AData: TFastLayoutData);
    function LayoutOrigin: TPointF;
  protected
    procedure DoRenderLayout; override;
    procedure DoDrawLayout(const ACanvas: TCanvas); override;
    function GetTextHeight: Single; override;
    function GetTextWidth: Single; override;
    function GetTextRect: TRectF; override;
    function DoPositionAtPoint(const APoint: TPointF): Integer; override;
    function DoRegionForRange(const ARange: TTextRange): TRegion; override;
  public
    destructor Destroy; override;
    procedure ConvertToPath(const APath: TPathData); override;
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

  /// <summary>Glyphs of one font face at one size (pixels per em), by glyph index and subpixel position.</summary>
  TFastFaceGlyphs = class
  private
    FFace: IDWriteFontFace;
    FEmSize: Single;
    FMode: DWRITE_RENDERING_MODE;
    FGlyphs: TDictionary<Cardinal, TFastGlyph>;
  public
    constructor Create(const AFace: IDWriteFontFace; const AEmSize: Single);
    destructor Destroy; override;
  end;

  /// <summary>How a glyph is rasterized: grayscale coverage; ClearType coverage, three texels (R, G, B) per pixel;
  /// aliased, every pixel covered or not.</summary>
  TFastGlyphKind = (Gray, ClearType, Aliased);

  /// <summary>Glyph atlas: an GpuAtlasSize square of 8-bit coverage, shelf-packed. Used by the recording thread
  /// only (FMX holds the canvas lock between BeginScene and EndScene).</summary>
  TFastGlyphCache = class
  public const
    SubpixelSteps = 4;
  private
    FSize: Integer;
    FFaces: TObjectDictionary<UInt64, TFastFaceGlyphs>;
    FShelves: TArray<TPoint>;   // X = used width, Y = top; heights in FShelfHeights
    FShelfHeights: TArray<Integer>;
    FNextY: Integer;
    FParams: IDWriteRenderingParams;
    FBuffer: TBytes;
    FUpload: TFastGlyphUploadProc;
    FReset: TFastGlyphResetProc;
    FResets: Integer;
    function Allocate(const W, H: Integer; out X, Y: Integer): Boolean;
    function Rasterize(const AFaceGlyphs: TFastFaceGlyphs; const AGlyph: Word; const ASub: Integer;
      const AKind: TFastGlyphKind; out AResult: TFastGlyph): Boolean;
  public
    constructor Create(const ASize: Integer; const AUpload: TFastGlyphUploadProc; const AReset: TFastGlyphResetProc);
    destructor Destroy; override;
    /// <summary>The glyph set of a face at a pixel size. Valid until the next Clear (also implicit when the atlas
    /// is full).</summary>
    function Face(const AFace: IDWriteFontFace; const AEmSize: Single): TFastFaceGlyphs;
    /// <summary>The glyph at a subpixel position 0..SubpixelSteps - 1, rasterized as AKind; rasterized and uploaded on
    /// first use. AFaceGlyphs is replaced when the atlas was full and started over.</summary>
    function Glyph(var AFaceGlyphs: TFastFaceGlyphs; const AGlyph: Word; const ASub: Integer;
      const AKind: TFastGlyphKind = TFastGlyphKind.Gray): TFastGlyph;
    /// <summary>The display's subpixels are in a row (RGB or BGR): ClearType can be drawn.</summary>
    function ClearTypeGeometry: Boolean;
    procedure Clear;
    property Size: Integer read FSize;
    property Resets: Integer read FResets;
  end;

var
  /// <summary>Set by FastCanvas.Canvas: draws layout data on its canvas.</summary>
  FastDrawLayout: TFastDrawLayoutProc;

/// <summary>Releases the shared layout cache (shutdown).</summary>
procedure FastTextShutdown;

implementation

uses
  FMX.Helpers.Win, FMX.Platform, FMX.FontManager, FMX.FontManager.Win, FastCanvas.Device;

const
  /// <summary>Layouts per generation of the layout cache (it keeps two).</summary>
  CacheGeneration = 2048;
  /// <summary>Evicted layouts released per new layout: an evicted generation is gone long before the next one.</summary>
  ReleasesPerLayout = 4;
  IID_IFastTextColor: TGUID = '{0B4E7A2C-6C1F-4B83-9D61-3E5B9C0F1A27}';

type
  /// <summary>Drawing effect of a text range with its own color (TTextAttribute.Color).</summary>
  IFastTextColor = interface
    ['{0B4E7A2C-6C1F-4B83-9D61-3E5B9C0F1A27}']
    function Color: TAlphaColor;
  end;

  TFastTextColor = class(TInterfacedObject, IFastTextColor)
  private
    FColor: TAlphaColor;
  public
    constructor Create(const AColor: TAlphaColor);
    function Color: TAlphaColor;
  end;

  /// <summary>Collects the glyph runs and decorations of a layout (IDWriteTextLayout.Draw).</summary>
  TRunCollector = class(TInterfacedObject, IDWritePixelSnapping, IDWriteTextRenderer)
  private
    FData: TFastLayoutData;
    FRuns: TList<TFastGlyphRun>;
    FDecorations: TList<TFastTextDecoration>;
    procedure AddDecoration(const X, Y, W, H: Single; const AEffect: IUnknown);
  public
    constructor Create(const AData: TFastLayoutData);
    destructor Destroy; override;
    function IsPixelSnappingDisabled(clientDrawingContext: Pointer; var isDisabled: BOOL): HResult; stdcall;
    function GetCurrentTransform(clientDrawingContext: Pointer; var transform: TDwriteMatrix): HResult; stdcall;
    function GetPixelsPerDip(clientDrawingContext: Pointer; var pixelsPerDip: Single): HResult; stdcall;
    function DrawGlyphRun(clientDrawingContext: Pointer; baselineOriginX: Single; baselineOriginY: Single;
      measuringMode: TDWriteMeasuringMode; var glyphRun: TDwriteGlyphRun;
      var glyphRunDescription: TDwriteGlyphRunDescription; const clientDrawingEffect: IUnknown): HResult; stdcall;
    function DrawUnderline(clientDrawingContext: Pointer; baselineOriginX: Single; baselineOriginY: Single;
      var underline: TDwriteUnderline; const clientDrawingEffect: IUnknown): HResult; stdcall;
    function DrawStrikethrough(clientDrawingContext: Pointer; baselineOriginX: Single; baselineOriginY: Single;
      var strikethrough: TDwriteStrikethrough; const clientDrawingEffect: IUnknown): HResult; stdcall;
    function DrawInlineObject(clientDrawingContext: Pointer; originX: Single; originY: Single;
      const inlineObject: IDWriteInlineObject; isSideways: BOOL; isRightToLeft: BOOL;
      const clientDrawingEffect: IUnknown): HResult; stdcall;
  end;

  /// <summary>Glyph outlines into a TPathData (ConvertToPath).</summary>
  TPathSink = class(TInterfacedObject, ID2D1SimplifiedGeometrySink)
  private
    FPath: TPathData;
    FDx, FDy: Single;
  public
    constructor Create(const APath: TPathData; const ADx, ADy: Single);
    procedure SetFillMode(fillMode: D2D1_FILL_MODE); stdcall;
    procedure SetSegmentFlags(vertexFlags: D2D1_PATH_SEGMENT); stdcall;
    procedure BeginFigure(startPoint: D2D1_POINT_2F; figureBegin: D2D1_FIGURE_BEGIN); stdcall;
    procedure AddLines(points: PD2D1Point2F; pointsCount: UINT); stdcall;
    procedure AddBeziers(beziers: PD2D1BezierSegment; beziersCount: UINT); stdcall;
    procedure EndFigure(figureEnd: D2D1_FIGURE_END); stdcall;
    function Close: HResult; stdcall;
  end;

var
  // Layout cache in two generations: a hit in the old one moves the layout to the current one; when the current
  // one is full it becomes the old one, and the layouts of the old one are released a few per new layout (releasing
  // thousands of DirectWrite layouts at once stalled a frame for 60 ms).
  GCache, GCacheOld: TDictionary<string, TFastLayoutData>;
  GEvicted: TList<TFastLayoutData>;
  GCacheLock: TObject;
  GLocale: string;
  GSystemFonts: IDWriteFontCollection;
  GFamilies: TDictionary<string, IDWriteFontCollection>;

{ TFastTextColor }

constructor TFastTextColor.Create(const AColor: TAlphaColor);
begin
  inherited Create;
  FColor := AColor;
end;

function TFastTextColor.Color: TAlphaColor;
begin
  Result := FColor;
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

{ TRunCollector }

constructor TRunCollector.Create(const AData: TFastLayoutData);
begin
  inherited Create;
  FData := AData;
  FRuns := TList<TFastGlyphRun>.Create;
  FDecorations := TList<TFastTextDecoration>.Create;
end;

destructor TRunCollector.Destroy;
begin
  FData.Runs := FRuns.ToArray;
  FData.Decorations := FDecorations.ToArray;
  FRuns.Free;
  FDecorations.Free;
  inherited;
end;

function TRunCollector.IsPixelSnappingDisabled(clientDrawingContext: Pointer; var isDisabled: BOOL): HResult;
begin
  // Positions are collected once per layout; the canvas snaps them when it draws.
  isDisabled := True;
  Result := S_OK;
end;

function TRunCollector.GetCurrentTransform(clientDrawingContext: Pointer; var transform: TDwriteMatrix): HResult;
begin
  transform.m11 := 1;
  transform.m12 := 0;
  transform.m21 := 0;
  transform.m22 := 1;
  transform.dx := 0;
  transform.dy := 0;
  Result := S_OK;
end;

function TRunCollector.GetPixelsPerDip(clientDrawingContext: Pointer; var pixelsPerDip: Single): HResult;
begin
  pixelsPerDip := 1;
  Result := S_OK;
end;

function HasColorTables(const AFace: IDWriteFontFace): Boolean;
const
  Tags: array[0..3] of Cardinal = (DWRITE_TABLE_COLR, DWRITE_TABLE_CBDT, DWRITE_TABLE_SBIX, DWRITE_TABLE_SVG);
var
  Tag: Cardinal;
  Data, Context: Pointer;
  Size: Cardinal;
  Exists: BOOL;
begin
  for Tag in Tags do
  begin
    Exists := False;
    Context := nil;
    if Succeeded(AFace.TryGetFontTable(Tag, Data, Size, Context, Exists)) and Exists then
    begin
      AFace.ReleaseFontTable(Context);
      Exit(True);
    end;
  end;
  Result := False;
end;

function TRunCollector.DrawGlyphRun(clientDrawingContext: Pointer; baselineOriginX: Single; baselineOriginY: Single;
  measuringMode: TDWriteMeasuringMode; var glyphRun: TDwriteGlyphRun;
  var glyphRunDescription: TDwriteGlyphRunDescription; const clientDrawingEffect: IUnknown): HResult;
var
  R: TFastGlyphRun;
  I, N: Integer;
  Pen: Single;
  Rtl: Boolean;
  Effect: IFastTextColor;
begin
  N := glyphRun.glyphCount;
  if N = 0 then
    Exit(S_OK);
  R.FontFace := glyphRun.fontFace;
  R.EmSize := glyphRun.fontEmSize;
  R.Sideways := glyphRun.isSideways;
  R.BidiLevel := glyphRun.bidiLevel;
  R.OriginX := baselineOriginX;
  R.OriginY := baselineOriginY;
  SetLength(R.Glyphs, N);
  SetLength(R.Advances, N);
  SetLength(R.Offsets, N);
  SetLength(R.X, N);
  SetLength(R.Y, N);
  Move(glyphRun.glyphIndices^, R.Glyphs[0], N * SizeOf(Word));
  if glyphRun.glyphAdvances <> nil then
    Move(glyphRun.glyphAdvances^, R.Advances[0], N * SizeOf(Single));
  if glyphRun.glyphOffsets <> nil then
    Move(glyphRun.glyphOffsets^, R.Offsets[0], N * SizeOf(TDwriteGlyphOffset))
  else
    FillChar(R.Offsets[0], N * SizeOf(TDwriteGlyphOffset), 0);
  // Left-to-right runs advance to the right from the origin; right-to-left runs start at their right edge and
  // place every glyph to the left of the pen. Offsets point along the reading direction and upwards.
  Rtl := Odd(R.BidiLevel);
  Pen := 0;
  for I := 0 to N - 1 do
  begin
    if Rtl then
    begin
      Pen := Pen - R.Advances[I];
      R.X[I] := Pen - R.Offsets[I].advanceOffset;
    end
    else
    begin
      R.X[I] := Pen + R.Offsets[I].advanceOffset;
      Pen := Pen + R.Advances[I];
    end;
    R.Y[I] := -R.Offsets[I].ascenderOffset;
  end;
  R.HasColor := Supports(clientDrawingEffect, IFastTextColor, Effect);
  if R.HasColor then
    R.Color := Effect.Color
  else
    R.Color := 0;
  if not FData.ColorGlyphs and HasColorTables(R.FontFace) then
    FData.ColorGlyphs := True;
  FRuns.Add(R);
  Result := S_OK;
end;

procedure TRunCollector.AddDecoration(const X, Y, W, H: Single; const AEffect: IUnknown);
var
  D: TFastTextDecoration;
  Effect: IFastTextColor;
begin
  D.Rect := TRectF.Create(X, Y, X + W, Y + H);
  D.HasColor := Supports(AEffect, IFastTextColor, Effect);
  if D.HasColor then
    D.Color := Effect.Color
  else
    D.Color := 0;
  FDecorations.Add(D);
end;

function TRunCollector.DrawUnderline(clientDrawingContext: Pointer; baselineOriginX: Single; baselineOriginY: Single;
  var underline: TDwriteUnderline; const clientDrawingEffect: IUnknown): HResult;
var
  X: Single;
begin
  X := baselineOriginX;
  if underline.readingDirection = DWRITE_READING_DIRECTION_RIGHT_TO_LEFT then
    X := X - underline.width;
  AddDecoration(X, baselineOriginY + underline.offset, underline.width, underline.thickness, clientDrawingEffect);
  Result := S_OK;
end;

function TRunCollector.DrawStrikethrough(clientDrawingContext: Pointer; baselineOriginX: Single; baselineOriginY: Single;
  var strikethrough: TDwriteStrikethrough; const clientDrawingEffect: IUnknown): HResult;
var
  X: Single;
begin
  X := baselineOriginX;
  if strikethrough.readingDirection = DWRITE_READING_DIRECTION_RIGHT_TO_LEFT then
    X := X - strikethrough.width;
  AddDecoration(X, baselineOriginY + strikethrough.offset, strikethrough.width, strikethrough.thickness,
    clientDrawingEffect);
  Result := S_OK;
end;

function TRunCollector.DrawInlineObject(clientDrawingContext: Pointer; originX: Single; originY: Single;
  const inlineObject: IDWriteInlineObject; isSideways: BOOL; isRightToLeft: BOOL;
  const clientDrawingEffect: IUnknown): HResult;
begin
  // The trimming sign (ellipsis) draws itself as a glyph run through this renderer.
  if inlineObject <> nil then
    Result := inlineObject.Draw(clientDrawingContext, Self, originX, originY, isSideways, isRightToLeft,
      clientDrawingEffect)
  else
    Result := S_OK;
end;

procedure TFastLayoutData.EnsureRuns;
var
  Collector: IDWriteTextRenderer;
begin
  if FRunsReady then
    Exit;
  Lock;
  try
    if not FRunsReady then
    begin
      Collector := TRunCollector.Create(Self);
      Layout.Draw(nil, Collector, 0, 0);
      Collector := nil;
      FRunsReady := True;
    end;
  finally
    Unlock;
  end;
end;

{ TPathSink }

constructor TPathSink.Create(const APath: TPathData; const ADx, ADy: Single);
begin
  inherited Create;
  FPath := APath;
  FDx := ADx;
  FDy := ADy;
end;

procedure TPathSink.SetFillMode(fillMode: D2D1_FILL_MODE);
begin
end;

procedure TPathSink.SetSegmentFlags(vertexFlags: D2D1_PATH_SEGMENT);
begin
end;

procedure TPathSink.BeginFigure(startPoint: D2D1_POINT_2F; figureBegin: D2D1_FIGURE_BEGIN);
begin
  FPath.MoveTo(TPointF.Create(startPoint.x + FDx, startPoint.y + FDy));
end;

procedure TPathSink.AddLines(points: PD2D1Point2F; pointsCount: UINT);
var
  I: Integer;
begin
  for I := 0 to Integer(pointsCount) - 1 do
  begin
    FPath.LineTo(TPointF.Create(points.x + FDx, points.y + FDy));
    Inc(points);
  end;
end;

procedure TPathSink.AddBeziers(beziers: PD2D1BezierSegment; beziersCount: UINT);
var
  I: Integer;
begin
  for I := 0 to Integer(beziersCount) - 1 do
  begin
    FPath.CurveTo(TPointF.Create(beziers.point1.x + FDx, beziers.point1.y + FDy),
      TPointF.Create(beziers.point2.x + FDx, beziers.point2.y + FDy),
      TPointF.Create(beziers.point3.x + FDx, beziers.point3.y + FDy));
    Inc(beziers);
  end;
end;

procedure TPathSink.EndFigure(figureEnd: D2D1_FIGURE_END);
begin
  if figureEnd = D2D1_FIGURE_END_CLOSED then
    FPath.ClosePath;
end;

function TPathSink.Close: HResult;
begin
  Result := S_OK;
end;

{ Fonts }

function LocaleName: string;
var
  Buf: array[0..LOCALE_NAME_MAX_LENGTH - 1] of Char;
begin
  if GLocale = '' then
  begin
    if GetUserDefaultLocaleName(Buf, Length(Buf)) > 0 then
      GLocale := Buf
    else
      GLocale := 'en-us';
  end;
  Result := GLocale;
end;

/// <summary>The collection a family is in: nil = the system collection (also when the family is unknown: DirectWrite
/// then falls back to a default font), or the collection of fonts added through TFontManager.</summary>
function FamilyCollection(const AFamily: string): IDWriteFontCollection;
var
  Index: Cardinal;
  Exists: BOOL;
  Service: IFMXFontManagerService;
  Factory: IFontCollectionFactoryDW;
  Custom: IDWriteFontCollection;
begin
  TMonitor.Enter(GCacheLock);
  try
    if GFamilies = nil then
      GFamilies := TDictionary<string, IDWriteFontCollection>.Create;
    if GFamilies.TryGetValue(AFamily, Result) then
      Exit;
    Result := nil;
    if GSystemFonts = nil then
      TFastDevice.DWrite.GetSystemFontCollection(GSystemFonts);
    Exists := False;
    if (GSystemFonts <> nil) and Succeeded(GSystemFonts.FindFamilyName(PWideChar(AFamily), Index, Exists)) and Exists then
      Result := nil
    else if TPlatformServices.Current.SupportsPlatformService(IFMXFontManagerService, Service) and
      Supports(Service, IFontCollectionFactoryDW, Factory) then
    begin
      Custom := Factory.CreateCustomFontCollection;
      Exists := False;
      if (Custom <> nil) and Succeeded(Custom.FindFamilyName(PWideChar(AFamily), Index, Exists)) and Exists then
        Result := Custom;
    end;
    GFamilies.Add(AFamily, Result);
  finally
    TMonitor.Exit(GCacheLock);
  end;
end;

procedure ApplyFont(const ALayout: IDWriteTextLayout; const AFont: TFont; const ARange: TDwriteTextRange;
  const ABase: TFont);
var
  Collection: IDWriteFontCollection;
begin
  if (ABase = nil) or (AFont.Family <> ABase.Family) then
  begin
    Collection := FamilyCollection(AFont.Family);
    ALayout.SetFontFamilyName(PWideChar(AFont.Family), ARange);
    if Collection <> nil then
      ALayout.SetFontCollection(Collection, ARange);
  end;
  if (ABase = nil) or not SameValue(AFont.Size, ABase.Size, TEpsilon.FontSize) then
    ALayout.SetFontSize(AFont.Size, ARange);
  ALayout.SetFontWeight(FontWeightToDWrite(AFont.StyleExt.Weight), ARange);
  ALayout.SetFontStyle(FontSlantToDWrite(AFont.StyleExt.Slant), ARange);
  ALayout.SetFontStretch(FontStretchToDWrite(AFont.StyleExt.Stretch), ARange);
  ALayout.SetUnderline(TFontStyle.fsUnderline in AFont.StyleExt.SimpleStyle, ARange);
  ALayout.SetStrikethrough(TFontStyle.fsStrikeOut in AFont.StyleExt.SimpleStyle, ARange);
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

function CacheKey(const ALayout: TFastTextLayout): string;
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

procedure TFastTextLayout.DoRenderLayout;
const
  HAlign: array[TTextAlign] of DWRITE_TEXT_ALIGNMENT = (DWRITE_TEXT_ALIGNMENT_CENTER, DWRITE_TEXT_ALIGNMENT_LEADING,
    DWRITE_TEXT_ALIGNMENT_TRAILING);
  VAlign: array[TTextAlign] of DWRITE_PARAGRAPH_ALIGNMENT = (DWRITE_PARAGRAPH_ALIGNMENT_CENTER,
    DWRITE_PARAGRAPH_ALIGNMENT_NEAR, DWRITE_PARAGRAPH_ALIGNMENT_FAR);
var
  Key: string;
  Cached: Boolean;
  D: TFastLayoutData;
  Format: IDWriteTextFormat;
  Trim: TDwriteTrimming;
  Sign: IDWriteInlineObject;
  Range: TDwriteTextRange;
  Collection: IDWriteFontCollection;
  I: Integer;
  Attr: TTextAttributedRange;
  W, H: Single;
begin
  FTextRect := TRectF.Empty;
  if Text.IsEmpty then
  begin
    SetData(nil);
    Exit;
  end;
  TFastDevice.Ensure;
  Cached := AttributesCount = 0;
  if Cached then
  begin
    Key := CacheKey(Self);
    TMonitor.Enter(GCacheLock);
    try
      if CacheFind(Key, D) then
      begin
        SetData(D);
        Exit;
      end;
    finally
      TMonitor.Exit(GCacheLock);
    end;
  end;

  D := TFastLayoutData.Create;
  try
    Collection := FamilyCollection(Font.Family);
    if Failed(TFastDevice.DWrite.CreateTextFormat(PWideChar(Font.Family), Collection,
      FontWeightToDWrite(Font.StyleExt.Weight), FontSlantToDWrite(Font.StyleExt.Slant),
      FontStretchToDWrite(Font.StyleExt.Stretch), Font.Size, PWideChar(LocaleName), Format)) then
    begin
      D.Free;
      SetData(nil);
      Exit;
    end;
    if RightToLeft then
      Format.SetReadingDirection(DWRITE_READING_DIRECTION_RIGHT_TO_LEFT);
    if WordWrap then
      Format.SetWordWrapping(DWRITE_WORD_WRAPPING_WRAP)
    else
      Format.SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
    FillChar(Trim, SizeOf(Trim), 0);
    Sign := nil;
    case Trimming of
      TTextTrimming.Character:
        Trim.granularity := DWRITE_TRIMMING_GRANULARITY_CHARACTER;
      TTextTrimming.Word:
        Trim.granularity := DWRITE_TRIMMING_GRANULARITY_WORD;
    else
      Trim.granularity := DWRITE_TRIMMING_GRANULARITY_NONE;
    end;
    if Trimming <> TTextTrimming.None then
      TFastDevice.DWrite.CreateEllipsisTrimmingSign(Format, Sign);
    Format.SetTrimming(Trim, Sign);
    Format.SetTextAlignment(HAlign[HorizontalAlign]);
    Format.SetParagraphAlignment(VAlign[VerticalAlign]);

    W := Max(MaxSize.X - Padding.Left - Padding.Right, 0);
    H := Max(MaxSize.Y - Padding.Top - Padding.Bottom, 0);
    if Failed(TFastDevice.DWrite.CreateTextLayout(PWideChar(Text), Text.Length, Format, W, H, D.Layout)) then
    begin
      D.Free;
      SetData(nil);
      Exit;
    end;
    Range.startPosition := 0;
    Range.length := Text.Length;
    D.Layout.SetUnderline(TFontStyle.fsUnderline in Font.StyleExt.SimpleStyle, Range);
    D.Layout.SetStrikethrough(TFontStyle.fsStrikeOut in Font.StyleExt.SimpleStyle, Range);
    for I := 0 to AttributesCount - 1 do
    begin
      Attr := Attributes[I];
      Range.startPosition := Attr.Range.Pos;
      Range.length := Attr.Range.Length;
      if Attr.Attribute.Font <> nil then
        ApplyFont(D.Layout, Attr.Attribute.Font, Range, Font);
      if Attr.Attribute.Color <> TAlphaColorRec.Null then
        D.Layout.SetDrawingEffect(TFastTextColor.Create(Attr.Attribute.Color), Range);
    end;
    D.Layout.GetMetrics(D.Metrics);
    D.Layout.GetOverhangMetrics(D.Overhang);
    D.InkOutside := (D.Overhang.left > 0.01) or (D.Overhang.top > 0.01) or (D.Overhang.right > 0.01) or
      (D.Overhang.bottom > 0.01);
  except
    D.Free;
    raise;
  end;

  SetData(D);
  if Cached then
  begin
    TMonitor.Enter(GCacheLock);
    try
      CacheAdd(Key, FData);
    finally
      TMonitor.Exit(GCacheLock);
    end;
  end;
end;

procedure TFastTextLayout.DoDrawLayout(const ACanvas: TCanvas);
begin
  if (FData <> nil) and Assigned(FastDrawLayout) then
    FastDrawLayout(ACanvas, FData, LayoutOrigin,
      TPointF.Create(MaxSize.X - Padding.Left - Padding.Right, MaxSize.Y - Padding.Top - Padding.Bottom), Color, Opacity);
end;

procedure UpdateRect(const ALayout: TFastTextLayout; out ARect: TRectF);
var
  M: TDwriteTextMetrics;
  W, H, L, T: Single;
begin
  if ALayout.FData = nil then
  begin
    ARect := TRectF.Empty;
    Exit;
  end;
  M := ALayout.FData.Metrics;
  // Advance width including trailing spaces, widened to the ink when it overhangs on the right (italics).
  W := Max(M.left + M.widthIncludingTrailingWhitespace, M.layoutWidth + ALayout.FData.Overhang.right) - M.left;
  H := Min(M.height, M.layoutHeight);
  L := Max(M.left, 0);
  T := Max(M.top, 0);
  ARect := TRectF.Create(L, T, L + Min(W, ALayout.MaxSize.X), T + Min(H, ALayout.MaxSize.Y));
end;

function TFastTextLayout.GetTextRect: TRectF;
begin
  UpdateRect(Self, Result);
  Result.Offset(LayoutOrigin);
end;

function TFastTextLayout.GetTextWidth: Single;
var
  R: TRectF;
begin
  UpdateRect(Self, R);
  Result := R.Width;
end;

function TFastTextLayout.GetTextHeight: Single;
var
  R: TRectF;
begin
  UpdateRect(Self, R);
  Result := R.Height;
end;

function TFastTextLayout.DoPositionAtPoint(const APoint: TPointF): Integer;
var
  Trailing, Inside: BOOL;
  M: TDwriteHitTestMetrics;
  P: TPointF;
begin
  if (FData = nil) or (FData.Layout = nil) then
    Exit(-1);
  P := APoint - LayoutOrigin;
  FData.Lock;
  try
    if Failed(FData.Layout.HitTestPoint(P.X, P.Y, Trailing, Inside, M)) then
      Exit(-1);
  finally
    FData.Unlock;
  end;
  Result := M.textPosition;
  if Trailing then
    Inc(Result, M.length);
end;

function TFastTextLayout.DoRegionForRange(const ARange: TTextRange): TRegion;
var
  Count, I: Cardinal;
  Hits: TArray<TDwriteHitTestMetrics>;
  M: TDwriteHitTestMetrics;
  X, Y: Single;
  O: TPointF;
  Pos: Integer;
begin
  Result := nil;
  if (FData = nil) or (FData.Layout = nil) or Text.IsEmpty then
    Exit;
  O := LayoutOrigin;
  FData.Lock;
  try
  if ARange.Length <= 0 then
  begin
    // A caret: zero-width rectangle at the position (after the last character at the end of the text).
    Pos := EnsureRange(ARange.Pos, 0, Text.Length);
    if Pos = Text.Length then
      FData.Layout.HitTestTextPosition(Pos - 1, True, X, Y, M)
    else
      FData.Layout.HitTestTextPosition(Pos, False, X, Y, M);
    SetLength(Result, 1);
    Result[0] := TRectF.Create(O.X + X, O.Y + M.top, O.X + X, O.Y + M.top + M.height);
    Exit;
  end;
  Count := 0;
  FData.Layout.HitTestTextRange(ARange.Pos, ARange.Length, 0, 0, M, 0, Count);
  if Count = 0 then
    Exit;
  SetLength(Hits, Count);
  if Failed(FData.Layout.HitTestTextRange(ARange.Pos, ARange.Length, 0, 0, Hits[0], Count, Count)) then
    Exit;
  SetLength(Result, Count);
  for I := 0 to Count - 1 do
    Result[I] := TRectF.Create(O.X + Hits[I].left, O.Y + Hits[I].top, O.X + Hits[I].left + Hits[I].width,
      O.Y + Hits[I].top + Hits[I].height);
  finally
    FData.Unlock;
  end;
end;

procedure TFastTextLayout.ConvertToPath(const APath: TPathData);
var
  R: TFastGlyphRun;
  O: TPointF;
  Sink: ID2D1SimplifiedGeometrySink;
begin
  if (APath = nil) or (FData = nil) then
    Exit;
  FData.EnsureRuns;
  O := LayoutOrigin;
  for R in FData.Runs do
  begin
    Sink := TPathSink.Create(APath, O.X + R.OriginX, O.Y + R.OriginY);
    R.FontFace.GetGlyphRunOutline(R.EmSize, @R.Glyphs[0], @R.Advances[0], @R.Offsets[0], Length(R.Glyphs),
      R.Sideways, Odd(R.BidiLevel), Sink);
  end;
end;

{ TFastFaceGlyphs }

constructor TFastFaceGlyphs.Create(const AFace: IDWriteFontFace; const AEmSize: Single);
begin
  inherited Create;
  FFace := AFace;
  FEmSize := AEmSize;
  FMode := DWRITE_RENDERING_MODE_DEFAULT;
  FGlyphs := TDictionary<Cardinal, TFastGlyph>.Create;
end;

destructor TFastFaceGlyphs.Destroy;
begin
  FGlyphs.Free;
  inherited;
end;

{ TFastGlyphCache }

constructor TFastGlyphCache.Create(const ASize: Integer; const AUpload: TFastGlyphUploadProc;
  const AReset: TFastGlyphResetProc);
begin
  inherited Create;
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

function TFastGlyphCache.Face(const AFace: IDWriteFontFace; const AEmSize: Single): TFastFaceGlyphs;
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
var
  G: DWRITE_PIXEL_GEOMETRY;
begin
  if FParams = nil then
    TFastDevice.DWrite.CreateRenderingParams(FParams);
  if FParams = nil then
    Exit(False);
  G := FParams.GetPixelGeometry;
  Result := (G = DWRITE_PIXEL_GEOMETRY_RGB) or (G = DWRITE_PIXEL_GEOMETRY_BGR);
end;

function TFastGlyphCache.Rasterize(const AFaceGlyphs: TFastFaceGlyphs; const AGlyph: Word; const ASub: Integer;
  const AKind: TFastGlyphKind; out AResult: TFastGlyph): Boolean;
var
  Run: TDwriteGlyphRun;
  Glyph: Word;
  Advance: Single;
  Analysis: IDWriteGlyphRunAnalysis;
  Bounds: TRect;
  TexType: DWRITE_TEXTURE_TYPE;
  W, H, X, Y, I, N, Texels: Integer;
  Identity: TDwriteMatrix;
  Mode: DWRITE_RENDERING_MODE;
  T: Byte;
begin
  FillChar(AResult, SizeOf(AResult), 0);
  Result := True;
  if FParams = nil then
    TFastDevice.DWrite.CreateRenderingParams(FParams);
  if AFaceGlyphs.FMode = DWRITE_RENDERING_MODE_DEFAULT then
  begin
    Mode := DWRITE_RENDERING_MODE_DEFAULT;
    AFaceGlyphs.FFace.GetRecommendedRenderingMode(AFaceGlyphs.FEmSize, 1, DWRITE_MEASURING_MODE_NATURAL, FParams, Mode);
    // Coverage bitmaps: outlines and the default go through the symmetric natural mode, as Direct2D does for
    // antialiased (non-ClearType) text below the outline threshold.
    if (Mode = DWRITE_RENDERING_MODE_DEFAULT) or (Mode = DWRITE_RENDERING_MODE_OUTLINE) or
      (Mode = DWRITE_RENDERING_MODE_ALIASED) then
      Mode := DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC;
    AFaceGlyphs.FMode := Mode;
  end;
  Glyph := AGlyph;
  Advance := 0;
  FillChar(Run, SizeOf(Run), 0);
  Run.fontFace := AFaceGlyphs.FFace;
  Run.fontEmSize := AFaceGlyphs.FEmSize;
  Run.glyphCount := 1;
  Run.glyphIndices := @Glyph;
  Run.glyphAdvances := @Advance;
  // Aliased glyphs: DirectWrite's aliased rendering, one byte per pixel, 0 or 255.
  Mode := AFaceGlyphs.FMode;
  if AKind = TFastGlyphKind.Aliased then
    Mode := DWRITE_RENDERING_MODE_ALIASED;
  if (TFastDevice.DWrite2 <> nil) and (AKind = TFastGlyphKind.ClearType) then
  begin
    TexType := DWRITE_TEXTURE_CLEARTYPE_3x1;
    if Failed(TFastDevice.DWrite2.CreateGlyphRunAnalysis2(@Run, nil, Mode, DWRITE_MEASURING_MODE_NATURAL,
      DWRITE_GRID_FIT_MODE_DEFAULT, DWRITE_TEXT_ANTIALIAS_MODE_CLEARTYPE, ASub / SubpixelSteps, 0, Analysis)) then
      Exit;
  end
  else if TFastDevice.DWrite2 <> nil then
  begin
    TexType := DWRITE_TEXTURE_ALIASED_1x1;
    if Failed(TFastDevice.DWrite2.CreateGlyphRunAnalysis2(@Run, nil, Mode, DWRITE_MEASURING_MODE_NATURAL,
      DWRITE_GRID_FIT_MODE_DEFAULT, DWRITE_TEXT_ANTIALIAS_MODE_GRAYSCALE, ASub / SubpixelSteps, 0, Analysis)) then
      Exit;
  end
  else
  begin
    // IDWriteFactory only: antialiased modes give ClearType coverage (averaged below for grayscale).
    if AKind = TFastGlyphKind.Aliased then
      TexType := DWRITE_TEXTURE_ALIASED_1x1
    else
      TexType := DWRITE_TEXTURE_CLEARTYPE_3x1;
    Identity.m11 := 1;
    Identity.m12 := 0;
    Identity.m21 := 0;
    Identity.m22 := 1;
    Identity.dx := 0;
    Identity.dy := 0;
    if Failed(TFastDevice.DWrite.CreateGlyphRunAnalysis(Run, 1, Identity, Mode, DWRITE_MEASURING_MODE_NATURAL,
      ASub / SubpixelSteps, 0, Analysis)) then
      Exit;
  end;
  Run.fontFace := nil;
  if Failed(Analysis.GetAlphaTextureBounds(TexType, Bounds)) or (Bounds.Width <= 0) or (Bounds.Height <= 0) then
    Exit;
  W := Bounds.Width;
  H := Bounds.Height;
  // Larger glyphs are drawn by Direct2D (the canvas never asks for them); keep them out of the atlas.
  if (W > FSize div 4) or (H > FSize div 4) then
    Exit;
  N := W * H;
  if TexType = DWRITE_TEXTURE_CLEARTYPE_3x1 then
    N := N * 3;
  if Length(FBuffer) < N then
    SetLength(FBuffer, N);
  if Failed(Analysis.CreateAlphaTexture(TexType, Bounds, FBuffer[0], N)) then
    Exit;
  Texels := W;
  if AKind = TFastGlyphKind.ClearType then
  begin
    // Three texels per pixel, red first: on a BGR display the subpixel on the left is blue.
    Texels := 3 * W;
    if FParams.GetPixelGeometry = DWRITE_PIXEL_GEOMETRY_BGR then
      for I := 0 to W * H - 1 do
      begin
        T := FBuffer[3 * I];
        FBuffer[3 * I] := FBuffer[3 * I + 2];
        FBuffer[3 * I + 2] := T;
      end;
  end
  else if TexType = DWRITE_TEXTURE_CLEARTYPE_3x1 then
    for I := 0 to W * H - 1 do
      FBuffer[I] := (Integer(FBuffer[3 * I]) + FBuffer[3 * I + 1] + FBuffer[3 * I + 2]) div 3;
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
  Face: IDWriteFontFace;
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
    FreeAndNil(GFamilies);
    GSystemFonts := nil;
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
