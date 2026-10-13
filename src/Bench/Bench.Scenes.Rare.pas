unit Bench.Scenes.Rare;

{ Scene "rare": the drawing a canvas meets seldom, which FastCanvas used to hand to Direct2D (docs/BENCHMARKS.md
  section 14a): bitmap brushes (fills and strokes of rectangles, rounded rectangles, ellipses and paths, in the
  three wrap modes), rotated and very large text, color emoji. A correctness check against the stock canvases:
  everything stands still (N copies of the board, slightly offset, so the scene has a measurable cost). }

interface

implementation

uses
  System.Types, System.UITypes, System.Math, System.Math.Vectors, System.SysUtils, FMX.Types, FMX.Graphics,
  FMX.TextLayout,
  Bench.Config, Bench.Scenes;

type
  TRareScene = class(TBenchPaintScene)
  private
    FTile: TBitmap;
    FStar: TPathData;
    FLayouts: TArray<TTextLayout>;
    procedure DrawBoard(const ACanvas: TCanvas; const AOrigin: TPointF; const AWidth: Single);
  protected
    procedure Draw(const ACanvas: TCanvas; const ARect: TRectF); override;
  public
    class function Name: string; override;
    class function Description: string; override;
    class function DefaultN(const APreset: TBenchPreset): Integer; override;
    procedure Setup; override;
    destructor Destroy; override;
  end;

const
  // Emoji as UTF-16 surrogate pairs (the sources stay ASCII): grinning face, rocket, red heart with variation
  // selector, thumbs up, globe.
  Emoji = #$D83D#$DE00' '#$D83D#$DE80' '#$2764#$FE0F' '#$D83D#$DC4D' '#$D83C#$DF0D;

{ TRareScene }

class function TRareScene.Name: string;
begin
  Result := 'rare';
end;

class function TRareScene.Description: string;
begin
  Result := 'Bitmap brushes, rotated and large text, color emoji (correctness check; N boards)';
end;

class function TRareScene.DefaultN(const APreset: TBenchPreset): Integer;
begin
  case APreset of
    TBenchPreset.Light: Result := 1;
    TBenchPreset.Heavy: Result := 8;
  else
    Result := 3;
  end;
end;

procedure TRareScene.Setup;
var
  I: Integer;
  L: TTextLayout;
begin
  inherited;
  // A 32x32 tile: checker squares and a circle, so wrap seams and scaling show.
  FTile := TBitmap.Create(32, 32);
  if FTile.Canvas.BeginScene then
    try
      FTile.Canvas.Clear(TAlphaColors.Gold);
      FTile.Canvas.Fill.Kind := TBrushKind.Solid;
      FTile.Canvas.Fill.Color := TAlphaColors.Navy;
      FTile.Canvas.FillRect(TRectF.Create(0, 0, 16, 16), 1);
      FTile.Canvas.FillRect(TRectF.Create(16, 16, 32, 32), 1);
      FTile.Canvas.Fill.Color := TAlphaColors.Crimson;
      FTile.Canvas.FillEllipse(TRectF.Create(8, 8, 24, 24), 1);
    finally
      FTile.Canvas.EndScene;
    end;
  FStar := TPathData.Create;
  FStar.Data := 'M 50,0 L 61,35 L 98,35 L 68,57 L 79,91 L 50,70 L 21,91 L 32,57 L 2,35 L 39,35 Z';
  SetLength(FLayouts, 2);
  for I := 0 to 1 do
  begin
    L := TTextLayoutManager.DefaultTextLayout.Create;
    L.BeginUpdate;
    try
      L.Font.Family := 'Segoe UI Emoji';
      L.Font.Size := 28 + I * 20;
      L.Color := TAlphaColors.Black;
      L.WordWrap := False;
      L.Text := 'Emoji ' + Emoji;
      L.MaxSize := TPointF.Create(10000, 10000);
    finally
      L.EndUpdate;
    end;
    FLayouts[I] := L;
  end;
end;

destructor TRareScene.Destroy;
var
  L: TTextLayout;
begin
  for L in FLayouts do
    L.Free;
  FStar.Free;
  FTile.Free;
  inherited;
end;

procedure TRareScene.DrawBoard(const ACanvas: TCanvas; const AOrigin: TPointF; const AWidth: Single);
const
  Modes: array[0..2] of TWrapMode = (TWrapMode.Tile, TWrapMode.TileOriginal, TWrapMode.TileStretch);
var
  I: Integer;
  X, Y: Single;
  M: TMatrix;
  Saved: TCanvasSaveState;
begin
  // Row 1: bitmap brush fills in the three wrap modes: rectangle, rounded rectangle, ellipse, path.
  for I := 0 to 2 do
  begin
    ACanvas.Fill.Kind := TBrushKind.Bitmap;
    ACanvas.Fill.Bitmap.Bitmap := FTile;
    ACanvas.Fill.Bitmap.WrapMode := Modes[I];
    X := AOrigin.X + I * 330;
    Y := AOrigin.Y;
    ACanvas.FillRect(TRectF.Create(X, Y, X + 90, Y + 70), 0, 0, [], 1);
    ACanvas.FillRect(TRectF.Create(X + 100, Y, X + 190, Y + 70), 14, 14, AllCorners, 0.8);
    ACanvas.FillEllipse(TRectF.Create(X + 200, Y, X + 300, Y + 70), 1);
    Saved := ACanvas.SaveState;
    try
      ACanvas.SetMatrix(TMatrix.CreateTranslation(X, Y + 80) * ACanvas.Matrix);
      ACanvas.FillPath(FStar, 1);
    finally
      ACanvas.RestoreState(Saved);
    end;
  end;
  // Row 2: bitmap brush strokes (rectangle, ellipse, line, path outline).
  ACanvas.Stroke.Kind := TBrushKind.Bitmap;
  ACanvas.Stroke.Bitmap.Bitmap := FTile;
  ACanvas.Stroke.Bitmap.WrapMode := TWrapMode.Tile;
  ACanvas.Stroke.Thickness := 10;
  ACanvas.Stroke.Dash := TStrokeDash.Solid;
  ACanvas.Stroke.Cap := TStrokeCap.Round;
  ACanvas.Stroke.Join := TStrokeJoin.Round;
  X := AOrigin.X + 110;
  Y := AOrigin.Y + 90;
  ACanvas.DrawRect(TRectF.Create(X, Y, X + 100, Y + 80), 0, 0, [], 1);
  ACanvas.DrawEllipse(TRectF.Create(X + 120, Y, X + 240, Y + 80), 1);
  ACanvas.DrawLine(TPointF.Create(X + 260, Y + 10), TPointF.Create(X + 420, Y + 70), 1);
  Saved := ACanvas.SaveState;
  try
    ACanvas.SetMatrix(TMatrix.CreateTranslation(X + 440, Y - 10) * ACanvas.Matrix);
    ACanvas.DrawPath(FStar, 1);
  finally
    ACanvas.RestoreState(Saved);
  end;
  // Row 3: rotated text at several angles, and very large text.
  ACanvas.Fill.Kind := TBrushKind.Solid;
  ACanvas.Fill.Color := TAlphaColors.Darkslategray;
  ACanvas.Font.Family := 'Segoe UI';
  ACanvas.Font.Size := 18;
  for I := 0 to 3 do
  begin
    Saved := ACanvas.SaveState;
    try
      M := TMatrix.CreateRotation(DegToRad(-30 + I * 25)) *
        TMatrix.CreateTranslation(AOrigin.X + 60 + I * 150, AOrigin.Y + 260);
      ACanvas.SetMatrix(M * ACanvas.Matrix);
      ACanvas.FillText(TRectF.Create(0, -12, 200, 12), 'Rotated text ' + IntToStr(I), False, 1, [],
        TTextAlign.Leading, TTextAlign.Center);
    finally
      ACanvas.RestoreState(Saved);
    end;
  end;
  ACanvas.Font.Size := 180;
  ACanvas.Fill.Color := TAlphaColors.Teal;
  ACanvas.FillText(TRectF.Create(AOrigin.X + 620, AOrigin.Y + 170, AOrigin.X + AWidth, AOrigin.Y + 400), 'Ag',
    False, 1, [], TTextAlign.Leading, TTextAlign.Leading);
  // Row 4: color emoji.
  for I := 0 to High(FLayouts) do
  begin
    FLayouts[I].TopLeft := TPointF.Create(AOrigin.X + 20, AOrigin.Y + 330 + I * 50);
    FLayouts[I].RenderLayout(ACanvas);
  end;
end;

procedure TRareScene.Draw(const ACanvas: TCanvas; const ARect: TRectF);
var
  I: Integer;
begin
  for I := 0 to N - 1 do
    DrawBoard(ACanvas, TPointF.Create(ARect.Left + 20 + I * 3, ARect.Top + 20 + I * 3), Min(ARect.Width - 40, 1000));
end;

initialization
  RegisterBenchScene(TRareScene);
end.
