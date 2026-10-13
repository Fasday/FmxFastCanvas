unit Bench.Scenes.Text;

{ Text scenes.

  text        N short strings through TCanvas.FillText. FillText creates and frees a TTextLayout per
              call (FMX.Graphics.pas:7271-7287), so every string is shaped every frame.
  textcached  The same strings, one persistent TTextLayout each, as TText/TLabel do. Only TopLeft
              changes per frame, which does not relayout (FMX.TextLayout.pas:169): drawing cost only.
  paragraph   N wrapped paragraphs (80..140 words), persistent layouts, moving.
  reflow      Like paragraph, but the wrap width changes every frame, so every layout is rebuilt.

  Text is generated from a fixed seed: Latin and Cyrillic words, five common Windows fonts,
  sizes 9..24, some bold and italic. }

interface

implementation

uses
  System.SysUtils, System.Types, System.UITypes, System.Math, FMX.Types, FMX.Graphics, FMX.TextLayout,
  Bench.Config, Bench.Scenes;

const
  FontFamilies: array[0..4] of string = ('Segoe UI', 'Arial', 'Tahoma', 'Consolas', 'Times New Roman');
  FontSizes: array[0..7] of Single = (9, 10, 11, 12, 14, 16, 20, 24);
  FontCount = 16;
  MotionAmplitude = 24;
  LineBoxWidth = 600;
  LineBoxHeight = 60;

type
  TTextItem = record
    X, Y: Single;       // normalized origin, 0..1
    Phase: Single;
    FontIndex: Integer;
    Color: TAlphaColor;
    Text: string;
    Width: Single;      // wrap width for paragraphs
  end;

  TTextSceneBase = class(TBenchPaintScene)
  protected
    FFonts: TArray<TFont>;
    FItems: TArray<TTextItem>;
    procedure GenerateItems(const ASeed: UInt64; const AMinWords, AMaxWords: Integer;
      const AMinWidth, AMaxWidth: Single);
    function ItemOrigin(const AItem: TTextItem; const ABounds: TRectF): TPointF;
  public
    destructor Destroy; override;
  end;

  TFillTextScene = class(TTextSceneBase)
  protected
    procedure Draw(const ACanvas: TCanvas; const ARect: TRectF); override;
  public
    class function Name: string; override;
    class function Description: string; override;
    class function DefaultN(const APreset: TBenchPreset): Integer; override;
    procedure Setup; override;
  end;

  TLayoutSceneBase = class(TTextSceneBase)
  private
    FLayouts: TArray<TTextLayout>;
    FLayoutCanvas: TCanvas;
    procedure FreeLayouts;
    procedure BuildLayouts(const ACanvas: TCanvas);
  protected
    function WordWrap: Boolean; virtual; abstract;
    function MaxSizeFor(const AItem: TTextItem): TPointF; virtual; abstract;
    procedure UpdateLayout(const ALayout: TTextLayout; const AItem: TTextItem); virtual;
    procedure Draw(const ACanvas: TCanvas; const ARect: TRectF); override;
  public
    destructor Destroy; override;
  end;

  TCachedTextScene = class(TLayoutSceneBase)
  protected
    function WordWrap: Boolean; override;
    function MaxSizeFor(const AItem: TTextItem): TPointF; override;
  public
    class function Name: string; override;
    class function Description: string; override;
    class function DefaultN(const APreset: TBenchPreset): Integer; override;
    procedure Setup; override;
  end;

  TParagraphScene = class(TLayoutSceneBase)
  protected
    function WordWrap: Boolean; override;
    function MaxSizeFor(const AItem: TTextItem): TPointF; override;
  public
    class function Name: string; override;
    class function Description: string; override;
    class function DefaultN(const APreset: TBenchPreset): Integer; override;
    procedure Setup; override;
  end;

  /// <summary>Text cut by the edges of the window: lines and paragraphs (layout height 10000, as the paragraph scenes)
  /// crossing every edge and corner, at fixed positions. A correctness check: text must be cut, not dropped.</summary>
  TTextEdgeScene = class(TBenchPaintScene)
  private
    FLayouts: TArray<TTextLayout>;
    FOrigins: TArray<TPointF>;
  protected
    procedure Draw(const ACanvas: TCanvas; const ARect: TRectF); override;
  public
    class function Name: string; override;
    class function Description: string; override;
    class function DefaultN(const APreset: TBenchPreset): Integer; override;
    destructor Destroy; override;
  end;

  TReflowScene = class(TParagraphScene)
  protected
    procedure UpdateLayout(const ALayout: TTextLayout; const AItem: TTextItem); override;
  public
    class function Name: string; override;
    class function Description: string; override;
    class function DefaultN(const APreset: TBenchPreset): Integer; override;
  end;

function RandomWord(var ARnd: TBenchRandom): string;
var
  Len, I, Base: Integer;
begin
  Len := ARnd.RangeInt(2, 9);
  if ARnd.NextFloat < 0.25 then
    Base := $0430  // Cyrillic small a
  else
    Base := Ord('a');
  SetLength(Result, Len);
  for I := 1 to Len do
    Result[I] := Char(Base + ARnd.RangeInt(0, 25));
end;

function Capitalize(const AWord: string): string;
begin
  Result := AWord;
  // Both 'a'..'z' and U+0430..U+044F have their capitals 32 code points lower.
  Result[1] := Char(Ord(Result[1]) - 32);
end;

function RandomText(var ARnd: TBenchRandom; const AWords: Integer): string;
var
  I: Integer;
  SB: TStringBuilder;
  W: string;
  NewSentence: Boolean;
begin
  SB := TStringBuilder.Create;
  try
    NewSentence := True;
    for I := 1 to AWords do
    begin
      W := RandomWord(ARnd);
      if NewSentence then
        W := Capitalize(W);
      if I > 1 then
        SB.Append(' ');
      SB.Append(W);
      NewSentence := False;
      if I < AWords then
      begin
        if ARnd.NextFloat < 0.08 then
        begin
          SB.Append('.');
          NewSentence := True;
        end
        else if ARnd.NextFloat < 0.08 then
          SB.Append(',');
      end;
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

{ TTextSceneBase }

destructor TTextSceneBase.Destroy;
var
  F: TFont;
begin
  for F in FFonts do
    F.Free;
  inherited;
end;

procedure TTextSceneBase.GenerateItems(const ASeed: UInt64; const AMinWords, AMaxWords: Integer;
  const AMinWidth, AMaxWidth: Single);
var
  Rnd: TBenchRandom;
  I: Integer;
  F: TFont;
  Style: TFontStyles;
begin
  Rnd := TBenchRandom.Create(ASeed);
  SetLength(FFonts, FontCount);
  for I := 0 to FontCount - 1 do
  begin
    F := TFont.Create;
    F.Family := FontFamilies[I mod Length(FontFamilies)];
    F.Size := FontSizes[Rnd.RangeInt(0, High(FontSizes))];
    Style := [];
    if Rnd.NextFloat < 0.25 then
      Include(Style, TFontStyle.fsBold);
    if Rnd.NextFloat < 0.15 then
      Include(Style, TFontStyle.fsItalic);
    F.Style := Style;
    FFonts[I] := F;
  end;
  SetLength(FItems, N);
  for I := 0 to N - 1 do
  begin
    FItems[I].X := Rnd.NextFloat * 0.9;
    FItems[I].Y := Rnd.NextFloat * 0.95;
    FItems[I].Phase := Rnd.Range(0, 2 * Pi);
    FItems[I].FontIndex := Rnd.RangeInt(0, FontCount - 1);
    // Dark opaque colors keep the text readable on the white form.
    FItems[I].Color := TAlphaColor($FF000000) or (Rnd.NextU32 and $7F7F7F);
    FItems[I].Text := RandomText(Rnd, Rnd.RangeInt(AMinWords, AMaxWords));
    FItems[I].Width := Rnd.Range(AMinWidth, AMaxWidth);
  end;
end;

function TTextSceneBase.ItemOrigin(const AItem: TTextItem; const ABounds: TRectF): TPointF;
begin
  Result.X := ABounds.Left + AItem.X * ABounds.Width + Sin(Time * 2.0 + AItem.Phase) * MotionAmplitude;
  Result.Y := ABounds.Top + AItem.Y * ABounds.Height + Cos(Time * 1.5 + AItem.Phase) * MotionAmplitude;
end;

{ TFillTextScene }

class function TFillTextScene.Name: string;
begin
  Result := 'text';
end;

class function TFillTextScene.Description: string;
begin
  Result := 'FillText, N short strings (2..5 words), 16 fonts; shaped every call';
end;

class function TFillTextScene.DefaultN(const APreset: TBenchPreset): Integer;
begin
  // D2D throughput frame: ~2 / ~10 / ~20 ms (~40 us per string, measured 2026-10-06).
  case APreset of
    TBenchPreset.Light: Result := 60;
    TBenchPreset.Heavy: Result := 500;
  else
    Result := 250;
  end;
end;

procedure TFillTextScene.Setup;
begin
  inherited;
  GenerateItems(8, 2, 5, 0, 0);
end;

procedure TFillTextScene.Draw(const ACanvas: TCanvas; const ARect: TRectF);
var
  I, LastFont: Integer;
  P: TPointF;
begin
  ACanvas.Fill.Kind := TBrushKind.Solid;
  LastFont := -1;
  for I := 0 to High(FItems) do
  begin
    if FItems[I].FontIndex <> LastFont then
    begin
      LastFont := FItems[I].FontIndex;
      ACanvas.Font.Assign(FFonts[LastFont]);
    end;
    ACanvas.Fill.Color := FItems[I].Color;
    P := ItemOrigin(FItems[I], ARect);
    ACanvas.FillText(TRectF.Create(P.X, P.Y, P.X + LineBoxWidth, P.Y + LineBoxHeight), FItems[I].Text,
      False, 1, [], TTextAlign.Leading, TTextAlign.Leading);
  end;
end;

{ TLayoutSceneBase }

destructor TLayoutSceneBase.Destroy;
begin
  FreeLayouts;
  inherited;
end;

procedure TLayoutSceneBase.FreeLayouts;
var
  L: TTextLayout;
begin
  for L in FLayouts do
    L.Free;
  FLayouts := nil;
  FLayoutCanvas := nil;
end;

procedure TLayoutSceneBase.BuildLayouts(const ACanvas: TCanvas);
var
  LayoutClass: TTextLayoutClass;
  I: Integer;
  L: TTextLayout;
begin
  FreeLayouts;
  LayoutClass := TTextLayoutManager.TextLayoutByCanvas(ACanvas.ClassType);
  SetLength(FLayouts, Length(FItems));
  for I := 0 to High(FItems) do
  begin
    L := LayoutClass.Create(ACanvas);
    L.BeginUpdate;
    try
      L.Font := FFonts[FItems[I].FontIndex];
      L.Color := FItems[I].Color;
      L.Text := FItems[I].Text;
      L.WordWrap := WordWrap;
      L.HorizontalAlign := TTextAlign.Leading;
      L.VerticalAlign := TTextAlign.Leading;
      L.MaxSize := MaxSizeFor(FItems[I]);
    finally
      L.EndUpdate;
    end;
    FLayouts[I] := L;
  end;
  FLayoutCanvas := ACanvas;
end;

procedure TLayoutSceneBase.UpdateLayout(const ALayout: TTextLayout; const AItem: TTextItem);
begin
end;

procedure TLayoutSceneBase.Draw(const ACanvas: TCanvas; const ARect: TRectF);
var
  I: Integer;
begin
  if FLayoutCanvas <> ACanvas then
    BuildLayouts(ACanvas);
  for I := 0 to High(FLayouts) do
  begin
    UpdateLayout(FLayouts[I], FItems[I]);
    FLayouts[I].TopLeft := ItemOrigin(FItems[I], ARect);
    FLayouts[I].RenderLayout(ACanvas);
  end;
end;

{ TCachedTextScene }

class function TCachedTextScene.Name: string;
begin
  Result := 'textcached';
end;

class function TCachedTextScene.Description: string;
begin
  Result := 'Same strings as text, one persistent TTextLayout each (as TText/TLabel)';
end;

class function TCachedTextScene.DefaultN(const APreset: TBenchPreset): Integer;
begin
  Result := TFillTextScene.DefaultN(APreset);
end;

procedure TCachedTextScene.Setup;
begin
  inherited;
  // Same seed and parameters as the text scene: identical strings, fonts and positions.
  GenerateItems(8, 2, 5, 0, 0);
end;

function TCachedTextScene.WordWrap: Boolean;
begin
  Result := False;
end;

function TCachedTextScene.MaxSizeFor(const AItem: TTextItem): TPointF;
begin
  Result := TPointF.Create(LineBoxWidth, LineBoxHeight);
end;

{ TParagraphScene }

class function TParagraphScene.Name: string;
begin
  Result := 'paragraph';
end;

class function TParagraphScene.Description: string;
begin
  Result := 'N wrapped paragraphs (80..140 words), persistent TTextLayout, moving';
end;

class function TParagraphScene.DefaultN(const APreset: TBenchPreset): Integer;
begin
  // D2D throughput frame: ~2 / ~9 / ~20 ms (~0.15 ms per paragraph, measured 2026-10-06).
  case APreset of
    TBenchPreset.Light: Result := 15;
    TBenchPreset.Heavy: Result := 135;
  else
    Result := 60;
  end;
end;

procedure TParagraphScene.Setup;
begin
  inherited;
  GenerateItems(9, 80, 140, 280, 520);
end;

function TParagraphScene.WordWrap: Boolean;
begin
  Result := True;
end;

function TParagraphScene.MaxSizeFor(const AItem: TTextItem): TPointF;
begin
  Result := TPointF.Create(AItem.Width, 10000);
end;

{ TReflowScene }

class function TReflowScene.Name: string;
begin
  Result := 'reflow';
end;

class function TReflowScene.Description: string;
begin
  Result := 'Like paragraph, wrap width changes every frame: full relayout per frame';
end;

class function TReflowScene.DefaultN(const APreset: TBenchPreset): Integer;
begin
  // D2D throughput frame: ~2 / ~9 / ~20 ms (~0.28 ms per paragraph, measured 2026-10-06).
  case APreset of
    TBenchPreset.Light: Result := 8;
    TBenchPreset.Heavy: Result := 72;
  else
    Result := 32;
  end;
end;

procedure TReflowScene.UpdateLayout(const ALayout: TTextLayout; const AItem: TTextItem);
begin
  // Round to whole pixels so that the width differs between consecutive frames but stays
  // identical for a given frame number on every canvas.
  ALayout.MaxSize := TPointF.Create(Round(AItem.Width * (0.8 + 0.2 * Sin(Time * 3.0 + AItem.Phase))), 10000);
end;

{ TTextEdgeScene }

class function TTextEdgeScene.Name: string;
begin
  Result := 'textedge';
end;

class function TTextEdgeScene.Description: string;
begin
  Result := 'Lines and paragraphs cut by the window edges (correctness check)';
end;

class function TTextEdgeScene.DefaultN(const APreset: TBenchPreset): Integer;
begin
  Result := 16;
end;

destructor TTextEdgeScene.Destroy;
var
  L: TTextLayout;
begin
  for L in FLayouts do
    L.Free;
  inherited;
end;

procedure TTextEdgeScene.Draw(const ACanvas: TCanvas; const ARect: TRectF);
const
  Words = 'The quick brown fox jumps over the lazy dog. ';
var
  I: Integer;
  L: TTextLayout;
  W, H, X, Y: Single;
  Text: string;
begin
  if FLayouts = nil then
  begin
    W := ARect.Width;
    H := ARect.Height;
    SetLength(FLayouts, 16);
    SetLength(FOrigins, 16);
    for I := 0 to 15 do
    begin
      L := TTextLayoutManager.DefaultTextLayout.Create(ACanvas);
      L.BeginUpdate;
      try
        L.Font.Family := 'Segoe UI';
        L.Font.Size := 12 + (I mod 4) * 6;
        L.Color := TAlphaColorRec.Black;
        L.WordWrap := I >= 8;
        Text := Words + Words + Words;
        if I >= 8 then
          Text := Text + Text + Text;
        L.Text := Text;
        if I >= 8 then
          L.MaxSize := TPointF.Create(260, 10000)
        else
          L.MaxSize := TPointF.Create(10000, 10000);
      finally
        L.EndUpdate;
      end;
      FLayouts[I] := L;
      // Across the four edges and the corners.
      case I mod 8 of
        0: begin X := -40; Y := H * 0.3; end;
        1: begin X := W - 120; Y := H * 0.4; end;
        2: begin X := W * 0.3; Y := -8; end;
        3: begin X := W * 0.5; Y := H - 10; end;
        4: begin X := -60; Y := -10; end;
        5: begin X := W - 90; Y := -12; end;
        6: begin X := -50; Y := H - 14; end;
      else
        begin X := W - 100; Y := H - 16; end;
      end;
      if I >= 8 then
        Y := Y - 30;
      FOrigins[I] := TPointF.Create(ARect.Left + X, ARect.Top + Y);
    end;
  end;
  for I := 0 to High(FLayouts) do
  begin
    FLayouts[I].TopLeft := FOrigins[I];
    FLayouts[I].RenderLayout(ACanvas);
  end;
end;

initialization
  RegisterBenchScene(TFillTextScene);
  RegisterBenchScene(TTextEdgeScene);
  RegisterBenchScene(TCachedTextScene);
  RegisterBenchScene(TParagraphScene);
  RegisterBenchScene(TReflowScene);
end.
