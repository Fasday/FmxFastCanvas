unit FastCanvas.TextDWrite;

{ The DirectWrite text engine of FastCanvas (FastCanvas.Text), Windows only, the default there: TFastDWriteTextLayout
  lays text out with an IDWriteTextLayout, whose glyph runs and decorations a text renderer collects
  (IDWriteTextLayout.Draw); glyphs are rasterized by IDWriteGlyphRunAnalysis (grayscale, ClearType or aliased, at the
  system's rendering mode), outlines come from IDWriteFontFace.GetGlyphRunOutline, color fonts (emoji) are drawn by
  a software Direct2D target over a WIC bitmap.

  Written from the DirectWrite documentation; no code from the FMX canvases. }

interface

uses
  Winapi.Windows, Winapi.D2D1, System.Types, System.UITypes, System.SysUtils, System.Math, System.Math.Vectors,
  System.Generics.Collections, FMX.Types, FMX.Graphics, FMX.TextLayout, FastCanvas.DWriteExt, FastCanvas.Text;

type
  /// <summary>Layout data of DirectWrite: the layout itself and its metrics.</summary>
  TFastDWriteLayoutData = class(TFastLayoutData)
  protected
    procedure CollectRuns; override;
  public
    Layout: IDWriteTextLayout;
    Metrics: TDwriteTextMetrics;
    function RenderColor(const AScale, ADx, ADy: Single; const AColor: TAlphaColor; const AWidth, AHeight: Integer;
      out APixels: TBytes): Boolean; override;
  end;

  TFastDWriteTextLayout = class(TFastTextLayout)
  private
    FTextRect: TRectF;
  protected
    procedure DoRenderLayout; override;
    function GetTextHeight: Single; override;
    function GetTextWidth: Single; override;
    function GetTextRect: TRectF; override;
    function DoPositionAtPoint(const APoint: TPointF): Integer; override;
    function DoRegionForRange(const ARange: TTextRange): TRegion; override;
  public
    procedure ConvertToPath(const APath: TPathData); override;
  end;

  TFastDWriteEngine = class(TFastTextEngine)
  public
    class function LayoutClass: TTextLayoutClass; override;
    class function RasterizeGlyph(const AFace: IInterface; const AGlyph: Word; const AEmSize, ASubX: Single;
      const AKind: TFastGlyphKind; const AMaxSize: Integer; var AMode: Integer; var ABuffer: TBytes;
      out ABounds: TRect): Boolean; override;
    class function GlyphOutline(const AFace: IInterface; const AGlyph: Word; const AEmSize: Single;
      const ASideways: Boolean; out APoints: TArray<TPathPoint>): Boolean; override;
    class function ClearTypeGeometry: Boolean; override;
    class procedure Shutdown; override;
  end;

implementation

uses
  Winapi.ActiveX, Winapi.Wincodec, Winapi.DxgiFormat, FMX.Helpers.Win, FMX.Platform, FMX.FontManager,
  FMX.FontManager.Win, FastCanvas.Geometry, FastCanvas.Device;

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

  /// <summary>A glyph outline as FMX path points (GlyphOutline).</summary>
  TPointSink = class(TInterfacedObject, ID2D1SimplifiedGeometrySink)
  private
    FPoints: TArray<TPathPoint>;
    FCount: Integer;
    procedure Add(const AKind: TPathPointKind; const X, Y: Single);
  public
    procedure SetFillMode(fillMode: D2D1_FILL_MODE); stdcall;
    procedure SetSegmentFlags(vertexFlags: D2D1_PATH_SEGMENT); stdcall;
    procedure BeginFigure(startPoint: D2D1_POINT_2F; figureBegin: D2D1_FIGURE_BEGIN); stdcall;
    procedure AddLines(points: PD2D1Point2F; pointsCount: UINT); stdcall;
    procedure AddBeziers(beziers: PD2D1BezierSegment; beziersCount: UINT); stdcall;
    procedure EndFigure(figureEnd: D2D1_FIGURE_END); stdcall;
    function Close: HResult; stdcall;
    function Points: TArray<TPathPoint>;
  end;

var
  GLocale: string;
  GSystemFonts: IDWriteFontCollection;
  GFamilies: TDictionary<string, IDWriteFontCollection>;
  /// <summary>Guards GFamilies and GSystemFonts.</summary>
  GFontsLock: TObject;
  /// <summary>Render thread: the rendering parameters of the system (glyph rasterization) and the WIC factory (color
  /// layouts).</summary>
  GParams: IDWriteRenderingParams;
  GWic: IWICImagingFactory;

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
  // DWRITE_GLYPH_OFFSET is two Singles, as TPointF: advanceOffset (X), ascenderOffset (Y).
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
      R.X[I] := Pen - R.Offsets[I].X;
    end
    else
    begin
      R.X[I] := Pen + R.Offsets[I].X;
      Pen := Pen + R.Advances[I];
    end;
    R.Y[I] := -R.Offsets[I].Y;
  end;
  R.HasColor := Supports(clientDrawingEffect, IFastTextColor, Effect);
  if R.HasColor then
    R.Color := Effect.Color
  else
    R.Color := 0;
  if not FData.ColorGlyphs and HasColorTables(glyphRun.fontFace) then
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

{ TFastDWriteLayoutData }

procedure TFastDWriteLayoutData.CollectRuns;
var
  Collector: IDWriteTextRenderer;
begin
  Collector := TRunCollector.Create(Self);
  Layout.Draw(nil, Collector, 0, 0);
  Collector := nil;
end;

function D2DColor(const AColor: Cardinal): TD2D1ColorF; inline;
begin
  Result.r := ((AColor shr 16) and $FF) / 255;
  Result.g := ((AColor shr 8) and $FF) / 255;
  Result.b := (AColor and $FF) / 255;
  Result.a := (AColor shr 24) / 255;
end;

function TFastDWriteLayoutData.RenderColor(const AScale, ADx, ADy: Single; const AColor: TAlphaColor; const AWidth,
  AHeight: Integer; out APixels: TBytes): Boolean;
var
  Wic: IWICBitmap;
  Target: ID2D1RenderTarget;
  Props: TD2D1RenderTargetProperties;
  Brush: ID2D1SolidColorBrush;
  Options: Cardinal;
  BitmapLock: IWICBitmapLock;
  Size, Stride: Cardinal;
  Bits: PByte;
  Rect: WICRect;
  T: TD2D1Matrix3x2F;
  P: TD2D1Point2F;
  Y: Integer;
begin
  Result := False;
  APixels := nil;
  if GWic = nil then
    CoCreateInstance(CLSID_WICImagingFactory, nil, CLSCTX_INPROC_SERVER, IWICImagingFactory, GWic);
  if (GWic = nil) or Failed(GWic.CreateBitmap(AWidth, AHeight, @GUID_WICPixelFormat32bppPBGRA, WICBitmapCacheOnLoad,
    Wic)) then
    Exit;
  Props := D2D1RenderTargetProperties(D2D1_RENDER_TARGET_TYPE_SOFTWARE,
    D2D1PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), 96, 96);
  if Failed(TFastDevice.D2DFactory.CreateWicBitmapRenderTarget(Wic, Props, Target)) then
    Exit;
  Target.CreateSolidColorBrush(D2DColor(AColor or $FF000000), nil, Brush);
  Target.SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
  Target.BeginDraw;
  Target.Clear(D2DColor(0));
  T._11 := AScale;
  T._12 := 0;
  T._21 := 0;
  T._22 := AScale;
  T._31 := ADx;
  T._32 := ADy;
  Target.SetTransform(T);
  Options := D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT;
  if InkOutside then
    Options := Options or D2D1_DRAW_TEXT_OPTIONS_CLIP;
  P.x := 0;
  P.y := 0;
  Lock;
  try
    Target.DrawTextLayout(P, Layout, Brush, Options);
  finally
    Unlock;
  end;
  if Failed(Target.EndDraw) then
    Exit;
  Target := nil;
  Rect.X := 0;
  Rect.Y := 0;
  Rect.Width := AWidth;
  Rect.Height := AHeight;
  if Failed(Wic.Lock(Rect, WICBitmapLockRead, BitmapLock)) then
    Exit;
  BitmapLock.GetStride(Stride);
  BitmapLock.GetDataPointer(Size, WICInProcPointer(Bits));
  SetLength(APixels, AWidth * 4 * AHeight);
  for Y := 0 to AHeight - 1 do
    Move((Bits + Cardinal(Y) * Stride)^, APixels[Y * AWidth * 4], AWidth * 4);
  BitmapLock := nil;
  Result := True;
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

{ TPointSink }

procedure TPointSink.Add(const AKind: TPathPointKind; const X, Y: Single);
begin
  if FCount = Length(FPoints) then
    SetLength(FPoints, Max(64, 2 * FCount));
  FPoints[FCount].Kind := AKind;
  FPoints[FCount].Point := TPointF.Create(X, Y);
  Inc(FCount);
end;

procedure TPointSink.SetFillMode(fillMode: D2D1_FILL_MODE);
begin
end;

procedure TPointSink.SetSegmentFlags(vertexFlags: D2D1_PATH_SEGMENT);
begin
end;

procedure TPointSink.BeginFigure(startPoint: D2D1_POINT_2F; figureBegin: D2D1_FIGURE_BEGIN);
begin
  Add(TPathPointKind.MoveTo, startPoint.x, startPoint.y);
end;

procedure TPointSink.AddLines(points: PD2D1Point2F; pointsCount: UINT);
var
  I: Integer;
begin
  for I := 0 to Integer(pointsCount) - 1 do
  begin
    Add(TPathPointKind.LineTo, points.x, points.y);
    Inc(points);
  end;
end;

procedure TPointSink.AddBeziers(beziers: PD2D1BezierSegment; beziersCount: UINT);
var
  I: Integer;
begin
  for I := 0 to Integer(beziersCount) - 1 do
  begin
    Add(TPathPointKind.CurveTo, beziers.point1.x, beziers.point1.y);
    Add(TPathPointKind.CurveTo, beziers.point2.x, beziers.point2.y);
    Add(TPathPointKind.CurveTo, beziers.point3.x, beziers.point3.y);
    Inc(beziers);
  end;
end;

procedure TPointSink.EndFigure(figureEnd: D2D1_FIGURE_END);
begin
  if figureEnd = D2D1_FIGURE_END_CLOSED then
    Add(TPathPointKind.Close, 0, 0);
end;

function TPointSink.Close: HResult;
begin
  Result := S_OK;
end;

function TPointSink.Points: TArray<TPathPoint>;
begin
  Result := Copy(FPoints, 0, FCount);
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
  TMonitor.Enter(GFontsLock);
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
    TMonitor.Exit(GFontsLock);
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

{ TFastDWriteTextLayout }

procedure TFastDWriteTextLayout.DoRenderLayout;
const
  HAlign: array[TTextAlign] of DWRITE_TEXT_ALIGNMENT = (DWRITE_TEXT_ALIGNMENT_CENTER, DWRITE_TEXT_ALIGNMENT_LEADING,
    DWRITE_TEXT_ALIGNMENT_TRAILING);
  VAlign: array[TTextAlign] of DWRITE_PARAGRAPH_ALIGNMENT = (DWRITE_PARAGRAPH_ALIGNMENT_CENTER,
    DWRITE_PARAGRAPH_ALIGNMENT_NEAR, DWRITE_PARAGRAPH_ALIGNMENT_FAR);
var
  Key: string;
  Cached: Boolean;
  D: TFastDWriteLayoutData;
  Format: IDWriteTextFormat;
  Trim: TDwriteTrimming;
  Sign: IDWriteInlineObject;
  Range: TDwriteTextRange;
  Collection: IDWriteFontCollection;
  I: Integer;
  Attr: TTextAttributedRange;
  W, H: Single;
  Overhang: TDwriteOverhangMetrics;
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
    Key := FastLayoutCacheKey(Self);
    if UseCached(Key) then
      Exit;
  end;

  D := TFastDWriteLayoutData.Create;
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
    D.Layout.GetOverhangMetrics(Overhang);
    D.LayoutWidth := D.Metrics.layoutWidth;
    D.LayoutHeight := D.Metrics.layoutHeight;
    D.Overhang.Left := Overhang.left;
    D.Overhang.Top := Overhang.top;
    D.Overhang.Right := Overhang.right;
    D.Overhang.Bottom := Overhang.bottom;
    D.InkOutside := (Overhang.left > 0.01) or (Overhang.top > 0.01) or (Overhang.right > 0.01) or
      (Overhang.bottom > 0.01);
  except
    D.Free;
    raise;
  end;

  SetData(D);
  if Cached then
    CacheData(Key);
end;

procedure UpdateRect(const ALayout: TFastDWriteTextLayout; out ARect: TRectF);
var
  M: TDwriteTextMetrics;
  W, H, L, T: Single;
begin
  if ALayout.Data = nil then
  begin
    ARect := TRectF.Empty;
    Exit;
  end;
  M := TFastDWriteLayoutData(ALayout.Data).Metrics;
  // Advance width including trailing spaces, widened to the ink when it overhangs on the right (italics).
  W := Max(M.left + M.widthIncludingTrailingWhitespace, M.layoutWidth + ALayout.Data.Overhang.Right) - M.left;
  H := Min(M.height, M.layoutHeight);
  L := Max(M.left, 0);
  T := Max(M.top, 0);
  ARect := TRectF.Create(L, T, L + Min(W, ALayout.MaxSize.X), T + Min(H, ALayout.MaxSize.Y));
end;

function TFastDWriteTextLayout.GetTextRect: TRectF;
begin
  UpdateRect(Self, Result);
  Result.Offset(LayoutOrigin);
end;

function TFastDWriteTextLayout.GetTextWidth: Single;
var
  R: TRectF;
begin
  UpdateRect(Self, R);
  Result := R.Width;
end;

function TFastDWriteTextLayout.GetTextHeight: Single;
var
  R: TRectF;
begin
  UpdateRect(Self, R);
  Result := R.Height;
end;

function TFastDWriteTextLayout.DoPositionAtPoint(const APoint: TPointF): Integer;
var
  Trailing, Inside: BOOL;
  M: TDwriteHitTestMetrics;
  P: TPointF;
  D: TFastDWriteLayoutData;
begin
  D := TFastDWriteLayoutData(Data);
  if (D = nil) or (D.Layout = nil) then
  begin
    // No text, no layout: the caret's only place. FMX's text controls ask where a click into an empty edit goes,
    // and raise ETextLayoutException for -1 (FMX's own layouts give 0).
    if Text.IsEmpty then
      Exit(0);
    Exit(-1);
  end;
  P := APoint - LayoutOrigin;
  D.Lock;
  try
    if Failed(D.Layout.HitTestPoint(P.X, P.Y, Trailing, Inside, M)) then
      Exit(-1);
  finally
    D.Unlock;
  end;
  Result := M.textPosition;
  if Trailing then
    Inc(Result, M.length);
end;

function TFastDWriteTextLayout.DoRegionForRange(const ARange: TTextRange): TRegion;
var
  Count, I: Cardinal;
  Hits: TArray<TDwriteHitTestMetrics>;
  M: TDwriteHitTestMetrics;
  X, Y: Single;
  O: TPointF;
  Pos: Integer;
  D: TFastDWriteLayoutData;
begin
  Result := nil;
  D := TFastDWriteLayoutData(Data);
  if (D = nil) or (D.Layout = nil) or Text.IsEmpty then
    Exit;
  O := LayoutOrigin;
  D.Lock;
  try
  if ARange.Length <= 0 then
  begin
    // A caret: zero-width rectangle at the position (after the last character at the end of the text).
    Pos := EnsureRange(ARange.Pos, 0, Text.Length);
    if Pos = Text.Length then
      D.Layout.HitTestTextPosition(Pos - 1, True, X, Y, M)
    else
      D.Layout.HitTestTextPosition(Pos, False, X, Y, M);
    SetLength(Result, 1);
    Result[0] := TRectF.Create(O.X + X, O.Y + M.top, O.X + X, O.Y + M.top + M.height);
    Exit;
  end;
  Count := 0;
  D.Layout.HitTestTextRange(ARange.Pos, ARange.Length, 0, 0, M, 0, Count);
  if Count = 0 then
    Exit;
  SetLength(Hits, Count);
  if Failed(D.Layout.HitTestTextRange(ARange.Pos, ARange.Length, 0, 0, Hits[0], Count, Count)) then
    Exit;
  SetLength(Result, Count);
  for I := 0 to Count - 1 do
    Result[I] := TRectF.Create(O.X + Hits[I].left, O.Y + Hits[I].top, O.X + Hits[I].left + Hits[I].width,
      O.Y + Hits[I].top + Hits[I].height);
  finally
    D.Unlock;
  end;
end;

procedure TFastDWriteTextLayout.ConvertToPath(const APath: TPathData);
var
  R: TFastGlyphRun;
  O: TPointF;
  Sink: ID2D1SimplifiedGeometrySink;
begin
  if (APath = nil) or (Data = nil) then
    Exit;
  Data.EnsureRuns;
  O := LayoutOrigin;
  for R in Data.Runs do
  begin
    Sink := TPathSink.Create(APath, O.X + R.OriginX, O.Y + R.OriginY);
    IDWriteFontFace(R.FontFace).GetGlyphRunOutline(R.EmSize, @R.Glyphs[0], @R.Advances[0],
      PDwriteGlyphOffset(@R.Offsets[0]), Length(R.Glyphs), R.Sideways, Odd(R.BidiLevel), Sink);
  end;
end;

{ TFastDWriteEngine }

class function TFastDWriteEngine.LayoutClass: TTextLayoutClass;
begin
  Result := TFastDWriteTextLayout;
end;

class function TFastDWriteEngine.ClearTypeGeometry: Boolean;
var
  G: DWRITE_PIXEL_GEOMETRY;
begin
  if GParams = nil then
    TFastDevice.DWrite.CreateRenderingParams(GParams);
  if GParams = nil then
    Exit(False);
  G := GParams.GetPixelGeometry;
  Result := (G = DWRITE_PIXEL_GEOMETRY_RGB) or (G = DWRITE_PIXEL_GEOMETRY_BGR);
end;

class function TFastDWriteEngine.RasterizeGlyph(const AFace: IInterface; const AGlyph: Word; const AEmSize,
  ASubX: Single; const AKind: TFastGlyphKind; const AMaxSize: Integer; var AMode: Integer; var ABuffer: TBytes;
  out ABounds: TRect): Boolean;
var
  Face: IDWriteFontFace;
  Run: TDwriteGlyphRun;
  Glyph: Word;
  Advance: Single;
  Analysis: IDWriteGlyphRunAnalysis;
  TexType: DWRITE_TEXTURE_TYPE;
  W, H, I, N: Integer;
  Identity: TDwriteMatrix;
  Mode: DWRITE_RENDERING_MODE;
  T: Byte;
begin
  Result := False;
  ABounds := TRect.Empty;
  Face := IDWriteFontFace(AFace);
  if GParams = nil then
    TFastDevice.DWrite.CreateRenderingParams(GParams);
  if AMode = Ord(DWRITE_RENDERING_MODE_DEFAULT) then
  begin
    Mode := DWRITE_RENDERING_MODE_DEFAULT;
    Face.GetRecommendedRenderingMode(AEmSize, 1, DWRITE_MEASURING_MODE_NATURAL, GParams, Mode);
    // Coverage bitmaps: outlines and the default go through the symmetric natural mode, as Direct2D does for
    // antialiased (non-ClearType) text below the outline threshold.
    if (Mode = DWRITE_RENDERING_MODE_DEFAULT) or (Mode = DWRITE_RENDERING_MODE_OUTLINE) or
      (Mode = DWRITE_RENDERING_MODE_ALIASED) then
      Mode := DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC;
    AMode := Ord(Mode);
  end;
  Glyph := AGlyph;
  Advance := 0;
  FillChar(Run, SizeOf(Run), 0);
  Run.fontFace := Face;
  Run.fontEmSize := AEmSize;
  Run.glyphCount := 1;
  Run.glyphIndices := @Glyph;
  Run.glyphAdvances := @Advance;
  // Aliased glyphs: DirectWrite's aliased rendering, one byte per pixel, 0 or 255.
  Mode := DWRITE_RENDERING_MODE(AMode);
  if AKind = TFastGlyphKind.Aliased then
    Mode := DWRITE_RENDERING_MODE_ALIASED;
  if (TFastDevice.DWrite2 <> nil) and (AKind = TFastGlyphKind.ClearType) then
  begin
    TexType := DWRITE_TEXTURE_CLEARTYPE_3x1;
    if Failed(TFastDevice.DWrite2.CreateGlyphRunAnalysis2(@Run, nil, Mode, DWRITE_MEASURING_MODE_NATURAL,
      DWRITE_GRID_FIT_MODE_DEFAULT, DWRITE_TEXT_ANTIALIAS_MODE_CLEARTYPE, ASubX, 0, Analysis)) then
      Exit;
  end
  else if TFastDevice.DWrite2 <> nil then
  begin
    TexType := DWRITE_TEXTURE_ALIASED_1x1;
    if Failed(TFastDevice.DWrite2.CreateGlyphRunAnalysis2(@Run, nil, Mode, DWRITE_MEASURING_MODE_NATURAL,
      DWRITE_GRID_FIT_MODE_DEFAULT, DWRITE_TEXT_ANTIALIAS_MODE_GRAYSCALE, ASubX, 0, Analysis)) then
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
      ASubX, 0, Analysis)) then
      Exit;
  end;
  Run.fontFace := nil;
  if Failed(Analysis.GetAlphaTextureBounds(TexType, ABounds)) or (ABounds.Width <= 0) or (ABounds.Height <= 0) then
    Exit;
  W := ABounds.Width;
  H := ABounds.Height;
  if (W > AMaxSize) or (H > AMaxSize) then
    Exit;
  N := W * H;
  if TexType = DWRITE_TEXTURE_CLEARTYPE_3x1 then
    N := N * 3;
  if Length(ABuffer) < N then
    SetLength(ABuffer, N);
  if Failed(Analysis.CreateAlphaTexture(TexType, ABounds, ABuffer[0], N)) then
    Exit;
  if AKind = TFastGlyphKind.ClearType then
  begin
    // Three texels per pixel, red first: on a BGR display the subpixel on the left is blue.
    if GParams.GetPixelGeometry = DWRITE_PIXEL_GEOMETRY_BGR then
      for I := 0 to W * H - 1 do
      begin
        T := ABuffer[3 * I];
        ABuffer[3 * I] := ABuffer[3 * I + 2];
        ABuffer[3 * I + 2] := T;
      end;
  end
  else if TexType = DWRITE_TEXTURE_CLEARTYPE_3x1 then
    for I := 0 to W * H - 1 do
      ABuffer[I] := (Integer(ABuffer[3 * I]) + ABuffer[3 * I + 1] + ABuffer[3 * I + 2]) div 3;
  Result := True;
end;

class function TFastDWriteEngine.GlyphOutline(const AFace: IInterface; const AGlyph: Word; const AEmSize: Single;
  const ASideways: Boolean; out APoints: TArray<TPathPoint>): Boolean;
var
  Glyph: Word;
  Sink: TPointSink;
  Ref: ID2D1SimplifiedGeometrySink;
begin
  APoints := nil;
  Glyph := AGlyph;
  Sink := TPointSink.Create;
  Ref := Sink;
  Result := Succeeded(IDWriteFontFace(AFace).GetGlyphRunOutline(AEmSize, @Glyph, nil, nil, 1, ASideways, False,
    Ref));
  if Result then
    APoints := Sink.Points;
end;

class procedure TFastDWriteEngine.Shutdown;
begin
  if GFontsLock = nil then
    Exit;
  TMonitor.Enter(GFontsLock);
  try
    FreeAndNil(GFamilies);
    GSystemFonts := nil;
  finally
    TMonitor.Exit(GFontsLock);
  end;
  GParams := nil;
  GWic := nil;
  // As the layout cache's lock (FastTextShutdown): layouts made after this would need the device, which is gone.
  FreeAndNil(GFontsLock);
end;

initialization
  // Freed by Shutdown (FastTextShutdown), not here: layouts are made and destroyed with the forms, after the unit
  // finalizations.
  GFontsLock := TObject.Create;
  FastRegisterTextEngine(TFastCanvasEngine.Native, TFastDWriteEngine);
end.
