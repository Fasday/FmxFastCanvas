unit FastCanvas.TextSkia;

{ The Skia text engine of FastCanvas (FastCanvas.Text), on every platform; the only one on Android and Linux,
  selectable on Windows (add this unit, FastCanvasTextEngine := Skia before InstallFastCanvas).

  TFastSkiaTextLayout lays text out with a Skia paragraph (SkParagraph: shaping with HarfBuzz, line breaking, bidi,
  font fallback of the platform's font manager). The paragraph's glyph runs (its visitor) become the layout's runs
  right away, with the ink bounds of their glyphs (the overhang) and the underlines and strikethroughs, which the
  canvas draws itself as rectangles. The paragraph is made again for hit testing and regions (a cached layout does
  not keep it: tens of kilobytes each, thousands of layouts). Glyph coverage is the unhinted
  outline (SkFont.getPath) filled by Skia, antialiased or aliased, at the subpixel position: plain coverage, which the
  canvas corrects for gamma and contrast as it does DirectWrite's. Layouts with color glyphs (emoji fonts) are painted
  by Skia into a raster surface.

  How FMX's layout parameters map: WordWrap off lays the paragraph out at its natural width and moves it by the
  alignment (overflowing text extends past the box as with DirectWrite); Trimming puts an ellipsis on the last line
  that fits (one line without WordWrap); the vertical alignment moves the paragraph in the box. Fonts added through
  FMX's TFontManager are not known to Skia's font manager. }

interface

uses
  System.Types, System.UITypes, System.SysUtils, System.Math, System.Generics.Collections, System.Skia, FMX.Types,
  FMX.Graphics, FMX.TextLayout, FastCanvas.Text;

type
  /// <summary>The style of a range of the text.</summary>
  TFastSkiaStyle = record
    Family: string;
    Size: Single;
    Style: TSkFontStyle;
    Underline, StrikeOut: Boolean;
    Color: TAlphaColor;
    HasColor: Boolean;
  end;

  /// <summary>Layout data of Skia: the paragraph and where it sits in the layout box.</summary>
  TFastSkiaLayoutData = class(TFastLayoutData)
  private
    FText: string;
    FStyles: TArray<TFastSkiaStyle>;
    /// <summary>The style of every UTF-16 code unit (index into FStyles).</summary>
    FCharStyles: TArray<Integer>;
    FAlign: TSkTextAlign;
    FDirection: TSkTextDirection;
    FEllipsis: Boolean;
    FMaxLines: NativeUInt;
    /// <summary>The width the paragraph is laid out at.</summary>
    FLayoutAt: Single;
    FParagraph: ISkParagraph;
    function MakeParagraph(const AColor: TAlphaColor; const APaintDecorations: Boolean): ISkParagraph;
    procedure Analyse;
  protected
    procedure CollectRuns; override;
  public
    /// <summary>The paragraph's origin in the layout box.</summary>
    Dx, Dy: Single;
    /// <summary>The text (its lines) in the layout box.</summary>
    TextRect: TRectF;
    /// <summary>The paragraph (hit testing, regions): made again when asked for, cached layouts do not keep theirs
    /// (tens of kilobytes each). Locked.</summary>
    function Paragraph: ISkParagraph;
    function RenderColor(const AScale, ADx, ADy: Single; const AColor: TAlphaColor; const AWidth, AHeight: Integer;
      out APixels: TBytes): Boolean; override;
  end;

  TFastSkiaTextLayout = class(TFastTextLayout)
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

  TFastSkiaEngine = class(TFastTextEngine)
  public
    class function LayoutClass: TTextLayoutClass; override;
    class function RasterizeGlyph(const AFace: IInterface; const AGlyph: Word; const AEmSize, ASubX: Single;
      const AKind: TFastGlyphKind; const AMaxSize: Integer; var AMode: Integer; var ABuffer: TBytes;
      out ABounds: TRect): Boolean; override;
    class function GlyphOutline(const AFace: IInterface; const AGlyph: Word; const AEmSize: Single;
      const ASideways: Boolean; out APoints: TArray<TPathPoint>): Boolean; override;
    class procedure Shutdown; override;
  end;

implementation

uses
  System.Skia.API, FastCanvas.Geometry, FastCanvas.GeometrySkia;

type
  /// <summary>A typeface as the font face of runs: one object per Skia typeface, so the glyph cache knows it again.
  /// </summary>
  ISkiaFace = interface
    ['{7E1C9A54-2B6F-4D83-9C0E-5A4F1D2B8E67}']
    function Typeface: ISkTypeface;
    /// <summary>A color font (emoji): its layouts are painted by Skia.</summary>
    function Color: Boolean;
    /// <summary>Tells color fonts that the name does not by a glyph with ink (AFont of this face): one without an
    /// outline is a color or bitmap glyph. Once per face.</summary>
    procedure CheckGlyph(const AFont: ISkFont; const AGlyph: Word);
  end;

  TSkiaFace = class(TInterfacedObject, ISkiaFace)
  private
    FTypeface: ISkTypeface;
    FColor, FChecked: Boolean;
  public
    constructor Create(const ATypeface: ISkTypeface);
    function Typeface: ISkTypeface;
    function Color: Boolean;
    procedure CheckGlyph(const AFont: ISkFont; const AGlyph: Word);
  end;

var
  GFaces: TDictionary<NativeUInt, ISkiaFace>;
  GFacesLock: TObject;

const
  FontWeights: array[TFontWeight] of Integer = (100, 200, 300, 350, 400, 500, 600, 700, 800, 900, 950);

{ TSkiaFace }

constructor TSkiaFace.Create(const ATypeface: ISkTypeface);
begin
  inherited Create;
  FTypeface := ATypeface;
  // Color fonts by name: Segoe UI Emoji, Noto Color Emoji, Apple Color Emoji (Skia does not tell). Android's fallback
  // fonts have names such as "91##fallback": CheckGlyph.
  FColor := ATypeface.FamilyName.ToLower.Contains('emoji');
  FChecked := FColor;
end;

procedure TSkiaFace.CheckGlyph(const AFont: ISkFont; const AGlyph: Word);
var
  Path: ISkPath;
begin
  if FChecked then
    Exit;
  Path := AFont.GetPath(AGlyph);
  FColor := (Path = nil) or Path.Bounds.IsEmpty;
  FChecked := True;
end;

function TSkiaFace.Typeface: ISkTypeface;
begin
  Result := FTypeface;
end;

function TSkiaFace.Color: Boolean;
begin
  Result := FColor;
end;

/// <summary>The face object of a typeface (the same for the same Skia typeface).</summary>
function FaceOf(const ATypeface: ISkTypeface): ISkiaFace;
var
  Key: NativeUInt;
begin
  if ATypeface = nil then
    Exit(nil);
  Key := ATypeface.Handle;
  TMonitor.Enter(GFacesLock);
  try
    if GFaces = nil then
      GFaces := TDictionary<NativeUInt, ISkiaFace>.Create;
    if not GFaces.TryGetValue(Key, Result) then
    begin
      Result := TSkiaFace.Create(ATypeface);
      GFaces.Add(Key, Result);
    end;
  finally
    TMonitor.Exit(GFacesLock);
  end;
end;

function SkiaStyleOf(const AFont: TFont): TFastSkiaStyle;
var
  Slant: TSkFontSlant;
begin
  Result := Default(TFastSkiaStyle);
  Result.Family := AFont.Family;
  Result.Size := AFont.Size;
  case AFont.StyleExt.Slant of
    TFontSlant.Italic: Slant := TSkFontSlant.Italic;
    TFontSlant.Oblique: Slant := TSkFontSlant.Oblique;
  else
    Slant := TSkFontSlant.Upright;
  end;
  Result.Style := TSkFontStyle.Create(FontWeights[AFont.StyleExt.Weight], Ord(AFont.StyleExt.Stretch) + 1, Slant);
  Result.Underline := TFontStyle.fsUnderline in AFont.StyleExt.SimpleStyle;
  Result.StrikeOut := TFontStyle.fsStrikeOut in AFont.StyleExt.SimpleStyle;
end;

function SameStyle(const A, B: TFastSkiaStyle): Boolean;
begin
  Result := (A.Family = B.Family) and (A.Size = B.Size) and (A.Style = B.Style) and (A.Underline = B.Underline) and
    (A.StrikeOut = B.StrikeOut) and (A.HasColor = B.HasColor) and (A.Color = B.Color);
end;

{ TFastSkiaLayoutData }

function TFastSkiaLayoutData.MakeParagraph(const AColor: TAlphaColor;
  const APaintDecorations: Boolean): ISkParagraph;
var
  ParagraphStyle: ISkParagraphStyle;
  Builder: ISkParagraphBuilder;
  TextStyle: ISkTextStyle;
  S: TFastSkiaStyle;
  I, Start: Integer;
  Decorations: TSkTextDecorations;
begin
  ParagraphStyle := TSkParagraphStyle.Create;
  ParagraphStyle.TextAlign := FAlign;
  ParagraphStyle.TextDirection := FDirection;
  if FEllipsis then
    ParagraphStyle.Ellipsis := #$2026;
  if FMaxLines > 0 then
    ParagraphStyle.MaxLines := FMaxLines;
  Builder := TSkParagraphBuilder.Create(ParagraphStyle);
  Start := 0;
  while Start < Length(FText) do
  begin
    I := Start + 1;
    while (I < Length(FText)) and (FCharStyles[I] = FCharStyles[Start]) do
      Inc(I);
    S := FStyles[FCharStyles[Start]];
    TextStyle := TSkTextStyle.Create;
    TextStyle.FontFamilies := [S.Family];
    TextStyle.FontSize := S.Size;
    TextStyle.FontStyle := S.Style;
    if S.HasColor then
      TextStyle.Color := S.Color
    else
      TextStyle.Color := AColor;
    Decorations := [];
    if APaintDecorations and S.Underline then
      Include(Decorations, TSkTextDecoration.Underline);
    if APaintDecorations and S.StrikeOut then
      Include(Decorations, TSkTextDecoration.LineThrough);
    TextStyle.Decorations := Decorations;
    Builder.PushStyle(TextStyle);
    Builder.AddText(FText.Substring(Start, I - Start));
    Builder.Pop;
    Start := I;
  end;
  Result := Builder.Build;
  Result.Layout(FLayoutAt);
end;

function TFastSkiaLayoutData.Paragraph: ISkParagraph;
begin
  if FParagraph = nil then
    FParagraph := MakeParagraph(TAlphaColors.Black, False);
  Result := FParagraph;
end;

procedure TFastSkiaLayoutData.CollectRuns;
begin
  // Collected when the layout is made (Analyse).
end;

/// <summary>Runs, decorations and ink of the paragraph (in the layout box).</summary>
procedure TFastSkiaLayoutData.Analyse;
var
  Utf8ToChar: TArray<Integer>;
  RunList: TList<TFastGlyphRun>;
  DecoList: TList<TFastTextDecoration>;
  Ink: TRectF;
  HasInk: Boolean;
  I, Bytes, Code: Integer;
  Lines: TArray<TSkMetrics>;
  L, R: Double;
begin
  // UTF-8 offsets of the paragraph's clusters to UTF-16 indices (the styles of the runs).
  SetLength(Utf8ToChar, Length(FText) * 3 + 4);
  Bytes := 0;
  I := 0;
  while I < Length(FText) do
  begin
    Code := Ord(FText.Chars[I]);
    if (Code >= $D800) and (Code <= $DBFF) and (I + 1 < Length(FText)) then
    begin
      Utf8ToChar[Bytes] := I;
      Utf8ToChar[Bytes + 1] := I;
      Utf8ToChar[Bytes + 2] := I;
      Utf8ToChar[Bytes + 3] := I;
      Inc(Bytes, 4);
      Inc(I, 2);
      Continue;
    end;
    Utf8ToChar[Bytes] := I;
    if Code < $80 then
      Inc(Bytes)
    else if Code < $800 then
    begin
      Utf8ToChar[Bytes + 1] := I;
      Inc(Bytes, 2);
    end
    else
    begin
      Utf8ToChar[Bytes + 1] := I;
      Utf8ToChar[Bytes + 2] := I;
      Inc(Bytes, 3);
    end;
    Inc(I);
  end;
  SetLength(Utf8ToChar, Bytes + 1);
  Utf8ToChar[Bytes] := Max(Length(FText) - 1, 0);

  RunList := TList<TFastGlyphRun>.Create;
  DecoList := TList<TFastTextDecoration>.Create;
  try
    HasInk := False;
    Ink := TRectF.Empty;
    Paragraph.Visit(
      procedure(const ALineNumber: Integer; const AInfo: TSkParagraphVisitorInfo)
      var
        Run: TFastGlyphRun;
        Face: ISkiaFace;
        Glyphs: TArray<Word>;
        Bounds: TArray<TRectF>;
        Widths: TArray<Single>;
        Metrics: TSkFontMetrics;
        Style: TFastSkiaStyle;
        K, Index: Integer;
        X0, X1, Pos, Thickness: Single;
        G: TRectF;
        D: TFastTextDecoration;
      begin
        if AInfo.Count <= 0 then
          Exit;
        Face := FaceOf(AInfo.Font.Typeface);
        if Face = nil then
          Exit;
        SetLength(Glyphs, AInfo.Count);
        for K := 0 to AInfo.Count - 1 do
          Glyphs[K] := AInfo.Glyphs[K];
        Run := Default(TFastGlyphRun);
        Run.FontFace := Face;
        Run.EmSize := AInfo.Font.Size;
        Run.OriginX := Dx + AInfo.Origin.X;
        Run.OriginY := Dy + AInfo.Origin.Y;
        Run.Glyphs := Glyphs;
        SetLength(Run.X, AInfo.Count);
        SetLength(Run.Y, AInfo.Count);
        for K := 0 to AInfo.Count - 1 do
        begin
          Run.X[K] := AInfo.Positions[K].X;
          Run.Y[K] := AInfo.Positions[K].Y;
        end;
        // The style of the run's first cluster: its own color, decorations.
        Index := 0;
        if (AInfo.Utf8Starts <> nil) and (Integer(AInfo.Utf8Starts[0]) < Length(Utf8ToChar)) then
          Index := Utf8ToChar[AInfo.Utf8Starts[0]];
        if (Index >= 0) and (Index < Length(FCharStyles)) then
          Style := FStyles[FCharStyles[Index]]
        else
          Style := FStyles[0];
        Run.HasColor := Style.HasColor;
        Run.Color := Style.Color;
        RunList.Add(Run);
        // Ink and extent of the run.
        AInfo.Font.GetWidthsAndBounds(Glyphs, Widths, Bounds);
        X0 := MaxSingle;
        X1 := -MaxSingle;
        for K := 0 to AInfo.Count - 1 do
        begin
          X0 := Min(X0, Run.X[K]);
          X1 := Max(X1, Run.X[K] + Widths[K]);
          G := Bounds[K];
          if G.IsEmpty then
            Continue;
          Face.CheckGlyph(AInfo.Font, Glyphs[K]);
          G.Offset(Run.OriginX + Run.X[K], Run.OriginY + Run.Y[K]);
          if HasInk then
            Ink := TRectF.Union(Ink, G)
          else
            Ink := G;
          HasInk := True;
        end;
        if Face.Color then
          ColorGlyphs := True;
        if (Style.Underline or Style.StrikeOut) and (X1 > X0) then
        begin
          AInfo.Font.GetMetrics(Metrics);
          D.Color := Style.Color;
          D.HasColor := Style.HasColor;
          if Style.Underline then
          begin
            Pos := Metrics.UnderlinePosition;
            Thickness := Metrics.UnderlineThickness;
            if not (TSkFontMetricsFlag.UnderlinePositionIsValid in Metrics.Flags) then
              Pos := Run.EmSize * 0.1;
            if not (TSkFontMetricsFlag.UnderlineThicknessIsValid in Metrics.Flags) or (Thickness <= 0) then
              Thickness := Max(Run.EmSize / 14, 1);
            D.Rect := TRectF.Create(Run.OriginX + X0, Run.OriginY + Pos, Run.OriginX + X1,
              Run.OriginY + Pos + Thickness);
            DecoList.Add(D);
          end;
          if Style.StrikeOut then
          begin
            Pos := Metrics.StrikeoutPosition;
            Thickness := Metrics.StrikeoutThickness;
            if not (TSkFontMetricsFlag.StrikeoutPositionIsValid in Metrics.Flags) then
              Pos := -Run.EmSize * 0.3;
            if not (TSkFontMetricsFlag.StrikeoutThicknessIsValid in Metrics.Flags) or (Thickness <= 0) then
              Thickness := Max(Run.EmSize / 14, 1);
            D.Rect := TRectF.Create(Run.OriginX + X0, Run.OriginY + Pos, Run.OriginX + X1,
              Run.OriginY + Pos + Thickness);
            DecoList.Add(D);
          end;
        end;
      end);
    Runs := RunList.ToArray;
    Decorations := DecoList.ToArray;
    for I := 0 to High(Decorations) do
      if HasInk then
        Ink := TRectF.Union(Ink, Decorations[I].Rect)
      else
      begin
        Ink := Decorations[I].Rect;
        HasInk := True;
      end;
  finally
    RunList.Free;
    DecoList.Free;
  end;

  // The text: the lines' extent (left to right), the paragraph's height.
  Lines := Paragraph.LineMetrics;
  L := MaxDouble;
  R := -MaxDouble;
  for I := 0 to High(Lines) do
  begin
    L := Min(L, Lines[I].Left);
    R := Max(R, Lines[I].Left + Lines[I].Width);
  end;
  if Length(Lines) = 0 then
  begin
    L := 0;
    R := 0;
  end;
  TextRect := TRectF.Create(Dx + L, Dy, Dx + R, Dy + Paragraph.Height);
  if not HasInk then
    Ink := TextRect;
  Overhang.Left := -Ink.Left;
  Overhang.Top := -Ink.Top;
  Overhang.Right := Ink.Right - LayoutWidth;
  Overhang.Bottom := Ink.Bottom - LayoutHeight;
  InkOutside := (Overhang.Left > 0.01) or (Overhang.Top > 0.01) or (Overhang.Right > 0.01) or
    (Overhang.Bottom > 0.01);
end;

function TFastSkiaLayoutData.RenderColor(const AScale, ADx, ADy: Single; const AColor: TAlphaColor; const AWidth,
  AHeight: Integer; out APixels: TBytes): Boolean;
var
  P: ISkParagraph;
  Surface: ISkSurface;
  Canvas: ISkCanvas;
  Pixmap: ISkPixmap;
  Y: Integer;
begin
  APixels := nil;
  Result := False;
  P := MakeParagraph(AColor or $FF000000, True);
  Surface := TSkSurface.MakeRaster(AWidth, AHeight, TSkColorType.BGRA8888, TSkAlphaType.Premul);
  if Surface = nil then
    Exit;
  Canvas := Surface.Canvas;
  Canvas.Clear(0);
  Canvas.Translate(ADx, ADy);
  Canvas.Scale(AScale, AScale);
  if InkOutside then
    Canvas.ClipRect(TRectF.Create(0, 0, LayoutWidth, LayoutHeight));
  P.Paint(Canvas, Dx, Dy);
  Pixmap := Surface.PeekPixels;
  if (Pixmap = nil) or (Pixmap.Pixels = nil) then
    Exit;
  SetLength(APixels, AWidth * 4 * AHeight);
  for Y := 0 to AHeight - 1 do
    Move((PByte(Pixmap.Pixels) + NativeUInt(Y) * Pixmap.RowBytes)^, APixels[Y * AWidth * 4], AWidth * 4);
  Result := True;
end;

{ TFastSkiaTextLayout }

procedure TFastSkiaTextLayout.DoRenderLayout;
var
  Key: string;
  Cached: Boolean;
  D: TFastSkiaLayoutData;
  W, H, Shift: Single;
  I, J, K: Integer;
  Attr: TTextAttributedRange;
  S: TFastSkiaStyle;
  Lines: TArray<TSkMetrics>;
  Fit: NativeUInt;
  HAlign: Single;

  function StyleIndex(const AStyle: TFastSkiaStyle): Integer;
  var
    N: Integer;
  begin
    for N := 0 to High(D.FStyles) do
      if SameStyle(D.FStyles[N], AStyle) then
        Exit(N);
    Result := Length(D.FStyles);
    D.FStyles := D.FStyles + [AStyle];
  end;

begin
  if Text.IsEmpty then
  begin
    SetData(nil);
    Exit;
  end;
  Cached := AttributesCount = 0;
  if Cached then
  begin
    Key := FastLayoutCacheKey(Self);
    if UseCached(Key) then
      Exit;
  end;

  D := TFastSkiaLayoutData.Create;
  try
    D.FText := Text;
    // The styles: the layout's font, then the attributes in their order.
    D.FStyles := [SkiaStyleOf(Font)];
    SetLength(D.FCharStyles, Length(Text));
    for I := 0 to AttributesCount - 1 do
    begin
      Attr := Attributes[I];
      for J := Max(Attr.Range.Pos, 0) to Min(Attr.Range.Pos + Attr.Range.Length, Length(Text)) - 1 do
      begin
        S := D.FStyles[D.FCharStyles[J]];
        if Attr.Attribute.Font <> nil then
        begin
          K := Ord(S.HasColor);
          S := SkiaStyleOf(Attr.Attribute.Font);
          S.HasColor := K <> 0;
          S.Color := D.FStyles[D.FCharStyles[J]].Color;
        end;
        if Attr.Attribute.Color <> TAlphaColorRec.Null then
        begin
          S.Color := Attr.Attribute.Color;
          S.HasColor := True;
        end;
        D.FCharStyles[J] := StyleIndex(S);
      end;
    end;
    if RightToLeft then
      D.FDirection := TSkTextDirection.RightToLeft
    else
      D.FDirection := TSkTextDirection.LeftToRight;
    case HorizontalAlign of
      TTextAlign.Center:
        begin
          D.FAlign := TSkTextAlign.Center;
          HAlign := 0.5;
        end;
      TTextAlign.Trailing:
        begin
          D.FAlign := TSkTextAlign.Terminate;
          HAlign := 1;
        end;
    else
      D.FAlign := TSkTextAlign.Start;
      HAlign := 0;
    end;
    if RightToLeft then
      HAlign := 1 - HAlign;
    W := Max(MaxSize.X - Padding.Left - Padding.Right, 0);
    H := Max(MaxSize.Y - Padding.Top - Padding.Bottom, 0);
    D.LayoutWidth := W;
    D.LayoutHeight := H;
    // Trimming: one line with an ellipsis without WordWrap; with it, an ellipsis only when the lines overflow the
    // box (below: Skia's ellipsis without a line limit ends the paragraph at the first line that wraps).
    D.FEllipsis := (Trimming <> TTextTrimming.None) and not WordWrap;
    if D.FEllipsis then
      D.FMaxLines := 1;
    if WordWrap then
      D.FLayoutAt := W
    else
      D.FLayoutAt := 1E7;
    D.FParagraph := D.MakeParagraph(TAlphaColors.Black, False);
    if not WordWrap then
    begin
      // Lines as long as they are: laid out again at the longest one, moved by the alignment within the box.
      D.FLayoutAt := Max(W, Ceil(D.Paragraph.MaxIntrinsicWidth) + 1);
      if D.FEllipsis then
        D.FLayoutAt := W;
      D.Paragraph.Layout(D.FLayoutAt);
    end
    else if (Trimming <> TTextTrimming.None) and (D.Paragraph.Height > H + 0.5) then
    begin
      // The lines that fit, the last one with the ellipsis.
      Lines := D.Paragraph.LineMetrics;
      Fit := 0;
      for I := 0 to High(Lines) do
        if Lines[I].Baseline + Lines[I].Descent <= H + 0.5 then
          Fit := I + 1;
      D.FMaxLines := Max(Fit, 1);
      D.FEllipsis := True;
      D.FParagraph := D.MakeParagraph(TAlphaColors.Black, False);
    end;
    Shift := (W - D.FLayoutAt) * HAlign;
    D.Dx := Shift;
    case VerticalAlign of
      TTextAlign.Center: D.Dy := (H - D.Paragraph.Height) / 2;
      TTextAlign.Trailing: D.Dy := H - D.Paragraph.Height;
    else
      D.Dy := 0;
    end;
    D.Analyse;
    D.FParagraph := nil;
  except
    D.Free;
    raise;
  end;
  SetData(D);
  if Cached then
    CacheData(Key);
end;

procedure UpdateRect(const ALayout: TFastSkiaTextLayout; out ARect: TRectF);
var
  R: TRectF;
  L, T: Single;
begin
  if ALayout.Data = nil then
  begin
    ARect := TRectF.Empty;
    Exit;
  end;
  // As the DirectWrite layout reports it: from the text's top-left (not before the box), at most the box's size.
  R := TFastSkiaLayoutData(ALayout.Data).TextRect;
  L := Max(R.Left, 0);
  T := Max(R.Top, 0);
  ARect := TRectF.Create(L, T, L + Min(R.Width, ALayout.MaxSize.X),
    T + Min(Min(R.Height, ALayout.Data.LayoutHeight), ALayout.MaxSize.Y));
end;

function TFastSkiaTextLayout.GetTextRect: TRectF;
begin
  UpdateRect(Self, Result);
  Result.Offset(LayoutOrigin);
end;

function TFastSkiaTextLayout.GetTextWidth: Single;
var
  R: TRectF;
begin
  UpdateRect(Self, R);
  Result := R.Width;
end;

function TFastSkiaTextLayout.GetTextHeight: Single;
var
  R: TRectF;
begin
  UpdateRect(Self, R);
  Result := R.Height;
end;

function TFastSkiaTextLayout.DoPositionAtPoint(const APoint: TPointF): Integer;
var
  D: TFastSkiaLayoutData;
  P: TPointF;
  A: TSkPositionAffinity;
begin
  D := TFastSkiaLayoutData(Data);
  if D = nil then
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
    A := D.Paragraph.GetGlyphPositionAtCoordinate(P.X - D.Dx, P.Y - D.Dy);
  finally
    D.Unlock;
  end;
  Result := EnsureRange(A.Position, 0, Text.Length);
end;

function TFastSkiaTextLayout.DoRegionForRange(const ARange: TTextRange): TRegion;
var
  D: TFastSkiaLayoutData;
  Boxes: TArray<TSkTextBox>;
  O: TPointF;
  Pos, I: Integer;
  X: Single;
begin
  Result := nil;
  D := TFastSkiaLayoutData(Data);
  if (D = nil) or Text.IsEmpty then
    Exit;
  O := LayoutOrigin + TPointF.Create(D.Dx, D.Dy);
  D.Lock;
  try
    if ARange.Length <= 0 then
    begin
      // A caret: a zero-width rectangle at the position (after the last character at the end of the text).
      Pos := EnsureRange(ARange.Pos, 0, Text.Length);
      if Pos = Text.Length then
      begin
        Boxes := D.Paragraph.GetRectsForRange(Pos - 1, Pos, TSkRectHeightStyle.Max, TSkRectWidthStyle.Tight);
        if Boxes = nil then
          Exit;
        if Boxes[High(Boxes)].Direction = TSkTextDirection.RightToLeft then
          X := Boxes[High(Boxes)].Rect.Left
        else
          X := Boxes[High(Boxes)].Rect.Right;
      end
      else
      begin
        Boxes := D.Paragraph.GetRectsForRange(Pos, Pos + 1, TSkRectHeightStyle.Max, TSkRectWidthStyle.Tight);
        if Boxes = nil then
          Exit;
        if Boxes[0].Direction = TSkTextDirection.RightToLeft then
          X := Boxes[0].Rect.Right
        else
          X := Boxes[0].Rect.Left;
      end;
      SetLength(Result, 1);
      Result[0] := TRectF.Create(O.X + X, O.Y + Boxes[0].Rect.Top, O.X + X, O.Y + Boxes[0].Rect.Bottom);
      Exit;
    end;
    Boxes := D.Paragraph.GetRectsForRange(ARange.Pos, ARange.Pos + ARange.Length, TSkRectHeightStyle.Max,
      TSkRectWidthStyle.Tight);
  finally
    D.Unlock;
  end;
  SetLength(Result, Length(Boxes));
  for I := 0 to High(Boxes) do
  begin
    Result[I] := Boxes[I].Rect;
    Result[I].Offset(O);
  end;
end;

procedure TFastSkiaTextLayout.ConvertToPath(const APath: TPathData);
var
  R: TFastGlyphRun;
  O: TPointF;
  Points: TArray<TPathPoint>;
  I, K: Integer;
begin
  if (APath = nil) or (Data = nil) then
    Exit;
  Data.EnsureRuns;
  for R in Data.Runs do
    for I := 0 to High(R.Glyphs) do
      if TFastSkiaEngine.GlyphOutline(R.FontFace, R.Glyphs[I], R.EmSize, False, Points) then
      begin
        O := LayoutOrigin + TPointF.Create(R.OriginX + R.X[I], R.OriginY + R.Y[I]);
        K := 0;
        while K < Length(Points) do
        begin
          case Points[K].Kind of
            TPathPointKind.MoveTo:
              APath.MoveTo(Points[K].Point + O);
            TPathPointKind.LineTo:
              APath.LineTo(Points[K].Point + O);
            TPathPointKind.CurveTo:
              if K + 2 < Length(Points) then
              begin
                APath.CurveTo(Points[K].Point + O, Points[K + 1].Point + O, Points[K + 2].Point + O);
                Inc(K, 2);
              end;
            TPathPointKind.Close:
              APath.ClosePath;
          end;
          Inc(K);
        end;
      end;
end;

{ TFastSkiaEngine }

class function TFastSkiaEngine.LayoutClass: TTextLayoutClass;
begin
  Result := TFastSkiaTextLayout;
end;

class function TFastSkiaEngine.RasterizeGlyph(const AFace: IInterface; const AGlyph: Word; const AEmSize,
  ASubX: Single; const AKind: TFastGlyphKind; const AMaxSize: Integer; var AMode: Integer; var ABuffer: TBytes;
  out ABounds: TRect): Boolean;
var
  Face: ISkiaFace;
  Font: ISkFont;
  Paint: ISkPaint;
  Path: ISkPath;
  Box: TRectF;
  L, T, R, B, W, H, Y: Integer;
  Surface: ISkSurface;
  Pixmap: ISkPixmap;
begin
  Result := False;
  ABounds := TRect.Empty;
  if not Supports(AFace, ISkiaFace, Face) then
    Exit;
  // The outline filled as a path: plain coverage, which the canvas corrects for gamma and contrast as DirectWrite's.
  // (Skia's glyph masks are preblended for the paint's luminance.)
  Font := TSkFont.Create(Face.Typeface, AEmSize);
  Font.Subpixel := True;
  Font.LinearMetrics := True;
  Font.Hinting := TSkFontHinting.None;
  Path := Font.GetPath(AGlyph);
  if Path = nil then
    Exit;
  Box := Path.Bounds;
  if (Box.Width <= 0) or (Box.Height <= 0) then
    Exit;
  // One pixel of margin for the antialiasing (and the hinting) around the bounds.
  L := Floor(Box.Left + ASubX) - 1;
  T := Floor(Box.Top) - 1;
  R := Ceil(Box.Right + ASubX) + 1;
  B := Ceil(Box.Bottom) + 1;
  W := R - L;
  H := B - T;
  if (W <= 0) or (H <= 0) or (W > AMaxSize) or (H > AMaxSize) then
    Exit;
  Surface := TSkSurface.MakeRaster(TSkImageInfo.Create(W, H, TSkColorType.Alpha8, TSkAlphaType.Premul));
  if Surface = nil then
    Exit;
  Surface.Canvas.Clear(0);
  Paint := TSkPaint.Create;
  Paint.AntiAlias := AKind <> TFastGlyphKind.Aliased;
  Surface.Canvas.Translate(ASubX - L, -T);
  Surface.Canvas.DrawPath(Path, Paint);
  Pixmap := Surface.PeekPixels;
  if (Pixmap = nil) or (Pixmap.Pixels = nil) then
    Exit;
  if Length(ABuffer) < W * H then
    SetLength(ABuffer, W * H);
  for Y := 0 to H - 1 do
    Move((PByte(Pixmap.Pixels) + NativeUInt(Y) * Pixmap.RowBytes)^, ABuffer[Y * W], W);
  ABounds := TRect.Create(L, T, R, B);
  Result := True;
end;

class function TFastSkiaEngine.GlyphOutline(const AFace: IInterface; const AGlyph: Word; const AEmSize: Single;
  const ASideways: Boolean; out APoints: TArray<TPathPoint>): Boolean;
var
  Face: ISkiaFace;
  Font: ISkFont;
  Path: ISkPath;
begin
  APoints := nil;
  if not Supports(AFace, ISkiaFace, Face) then
    Exit(False);
  Font := TSkFont.Create(Face.Typeface, AEmSize);
  Font.Subpixel := True;
  Font.LinearMetrics := True;
  Path := Font.GetPath(AGlyph);
  // A glyph without an outline (a space) has no path.
  if Path <> nil then
    APoints := FastSkiaPathPoints(Path);
  Result := True;
end;

class procedure TFastSkiaEngine.Shutdown;
begin
  if GFacesLock = nil then
    Exit;
  TMonitor.Enter(GFacesLock);
  try
    FreeAndNil(GFaces);
  finally
    TMonitor.Exit(GFacesLock);
  end;
  // As the layout cache's lock (FastTextShutdown): layouts made after this would need the device, which is gone.
  FreeAndNil(GFacesLock);
end;

initialization
  // Skia stays loaded until the process ends (not released): layouts, paths and typefaces are released with the
  // forms, after the finalization of System.Skia, which unloads the library otherwise.
  SkInitialize;
  // Freed by Shutdown (FastTextShutdown), not here: layouts are made and destroyed with the forms, after the unit
  // finalizations.
  GFacesLock := TObject.Create;
  FastRegisterTextEngine(TFastCanvasEngine.Skia, TFastSkiaEngine);
end.
