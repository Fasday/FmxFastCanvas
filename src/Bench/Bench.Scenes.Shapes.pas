unit Bench.Scenes.Shapes;

{ Shape scenes: filled and stroked primitives drawn directly in Paint of one full-client control.

  roundrects  FillRect + DrawRect with corner radii, as TRectangle paints. D2D, GPU and GDI+ do not
              override DoFillRoundRect/DoDrawRoundRect: TCanvas builds a TPathData and calls
              DoFillPath/DoDrawPath (FMX.Graphics.pas:7104, :7346). Skia draws a native round rect
              (FMX.Skia.Canvas.pas:2254, :2355). The GPU canvas fills a path through the stencil
              buffer and switches the drawing mode four times per fill, each switch flushes the
              batch (FMX.Canvas.GPU.pas:1185-1240, FMX.Canvas.GPU.Helpers.pas:179-187).
  ellipses    FillEllipse + DrawEllipse, as TEllipse paints; native on every canvas. The GPU canvas
              strokes an ellipse with 80..126 segments (three SinCos each) whenever the larger
              radius is up to 50 physical pixels (FMX.StrokeBuilder.pas:1008-1018, :1033-1053).
  lines       DrawLine, rotating lines with different thickness, caps and dash styles. D2D, GDI+ and
              Skia draw TStrokeCap.Flat as a square cap, extending the line by half the thickness
              (FMX.Canvas.D2D.pas:1962-1963, FMX.Canvas.GDIP.pas:769-770, FMX.Skia.Canvas.pas:1998);
              the GPU canvas ends the line exactly at the points and fits round caps inside it
              (FMX.StrokeBuilder.pas:362-374).
  strokes     Dashed outlines of rectangles, rounded rectangles and ellipses (dash, dot, dash-dot,
              dash-dot-dot, a custom array; width 1..4; flat or round caps), as selection and focus
              frames and dashed TShape strokes paint, and lines with a linear gradient stroke. Every
              stroke is a widened geometry with a stroke style on D2D (FMX.Canvas.D2D.pas); the GPU
              canvas builds the dashes on the CPU (FMX.StrokeBuilder.pas).

  Fill and stroke share one rect inset by half the stroke thickness, as TShape.GetShapeRect does
  (FMX.Objects.pas:1125-1130). Stroke colors are a darker shade of the fill color. }

interface

implementation

uses
  System.Types, System.UITypes, System.Math, FMX.Types, FMX.Graphics, Bench.Config, Bench.Scenes;

type
  TShapeStyle = record
    StrokeColor: TAlphaColor;
    Thickness: Single;
    Radius: Single;
    Corners: TCorners;
  end;

  TShapeSceneBase = class(TBenchPaintScene)
  protected
    FItems: TArray<TMovingItem>;
    FStyles: TArray<TShapeStyle>;
    procedure GenerateShapes(const ASeed: UInt64; const AMinSize, AMaxSize, AMinRadius, AMaxRadius: Single);
    function ShapeRect(const AIndex: Integer; const ABounds: TRectF): TRectF; inline;
    procedure ResetBrushes(const ACanvas: TCanvas);
  end;

  TRoundRectsScene = class(TShapeSceneBase)
  protected
    procedure Draw(const ACanvas: TCanvas; const ARect: TRectF); override;
  public
    class function Name: string; override;
    class function Description: string; override;
    class function DefaultN(const APreset: TBenchPreset): Integer; override;
    procedure Setup; override;
  end;

  TEllipsesScene = class(TShapeSceneBase)
  protected
    procedure Draw(const ACanvas: TCanvas; const ARect: TRectF); override;
  public
    class function Name: string; override;
    class function Description: string; override;
    class function DefaultN(const APreset: TBenchPreset): Integer; override;
    procedure Setup; override;
  end;

  TLineStyle = record
    Angle: Single;     // radians at Time = 0
    Speed: Single;     // radians per second
    Thickness: Single;
    Cap: TStrokeCap;
    Dash: TStrokeDash;
  end;

  TStrokeStyleItem = record
    Shape: Integer;    // 0 rect, 1 rounded rect, 2 ellipse, 3 gradient line
    Thickness: Single;
    Cap: TStrokeCap;
    Dash: TStrokeDash;
    Angle, Speed: Single;
  end;

  TStrokesScene = class(TBenchPaintScene)
  private
    FItems: TArray<TMovingItem>;
    FStyles: TArray<TStrokeStyleItem>;
  protected
    procedure Draw(const ACanvas: TCanvas; const ARect: TRectF); override;
  public
    class function Name: string; override;
    class function Description: string; override;
    class function DefaultN(const APreset: TBenchPreset): Integer; override;
    procedure Setup; override;
  end;

  TLinesScene = class(TBenchPaintScene)
  private
    FItems: TArray<TMovingItem>;
    FStyles: TArray<TLineStyle>;
  protected
    procedure Draw(const ACanvas: TCanvas; const ARect: TRectF); override;
  public
    class function Name: string; override;
    class function Description: string; override;
    class function DefaultN(const APreset: TBenchPreset): Integer; override;
    procedure Setup; override;
  end;

function DarkShade(const AColor: TAlphaColor): TAlphaColor; inline;
begin
  Result := TAlphaColor($FF000000) or ((AColor shr 1) and $7F7F7F);
end;

{ TShapeSceneBase }

procedure TShapeSceneBase.GenerateShapes(const ASeed: UInt64; const AMinSize, AMaxSize, AMinRadius,
  AMaxRadius: Single);
var
  Rnd: TBenchRandom;
  I: Integer;
  Corners: TCorners;
  C: TCorner;
begin
  GenerateMovingItems(FItems, N, ASeed, AMinSize, AMaxSize);
  // Styles come from their own stream, so the items stay those of GenerateMovingItems(ASeed).
  Rnd := TBenchRandom.Create(ASeed + 1000);
  SetLength(FStyles, N);
  for I := 0 to N - 1 do
  begin
    FStyles[I].StrokeColor := DarkShade(FItems[I].Color);
    FStyles[I].Thickness := Rnd.RangeInt(1, 3);
    // Keep the radius within half of the shape rect: larger radii send Skia to the path fallback
    // (FMX.Skia.Canvas.pas:2365-2368).
    FStyles[I].Radius := Min(Rnd.Range(AMinRadius, AMaxRadius),
      (Min(FItems[I].W, FItems[I].H) - FStyles[I].Thickness) * 0.5);
    if Rnd.NextFloat < 0.7 then
      FStyles[I].Corners := AllCorners
    else
    begin
      // A non-empty proper subset of the corners.
      repeat
        Corners := [];
        for C := Low(TCorner) to High(TCorner) do
          if Rnd.NextFloat < 0.5 then
            Include(Corners, C);
      until (Corners <> []) and (Corners <> AllCorners);
      FStyles[I].Corners := Corners;
    end;
  end;
end;

function TShapeSceneBase.ShapeRect(const AIndex: Integer; const ABounds: TRectF): TRectF;
var
  Half: Single;
begin
  Result := MovingItemRect(FItems[AIndex], ABounds, Time);
  Half := FStyles[AIndex].Thickness * 0.5;
  Result.Inflate(-Half, -Half);
end;

procedure TShapeSceneBase.ResetBrushes(const ACanvas: TCanvas);
begin
  ACanvas.Fill.Kind := TBrushKind.Solid;
  ACanvas.Stroke.Kind := TBrushKind.Solid;
  ACanvas.Stroke.Dash := TStrokeDash.Solid;
  ACanvas.Stroke.Cap := TStrokeCap.Flat;
  ACanvas.Stroke.Join := TStrokeJoin.Miter;
end;

{ TRoundRectsScene }

class function TRoundRectsScene.Name: string;
begin
  Result := 'roundrects';
end;

class function TRoundRectsScene.Description: string;
begin
  Result := 'FillRect + DrawRect with radius 2..16, N shapes 16..96 px, stroke 1..3';
end;

class function TRoundRectsScene.DefaultN(const APreset: TBenchPreset): Integer;
begin
  // D2D throughput frame: ~2 / ~9 / ~20 ms (~11 us per shape: two path geometries, measured
  // 2026-10-06).
  case APreset of
    TBenchPreset.Light: Result := 170;
    TBenchPreset.Heavy: Result := 1700;
  else
    Result := 800;
  end;
end;

procedure TRoundRectsScene.Setup;
begin
  inherited;
  GenerateShapes(21, 16, 96, 2, 16);
end;

procedure TRoundRectsScene.Draw(const ACanvas: TCanvas; const ARect: TRectF);
var
  I: Integer;
  R: TRectF;
begin
  ResetBrushes(ACanvas);
  for I := 0 to High(FItems) do
  begin
    R := ShapeRect(I, ARect);
    ACanvas.Fill.Color := FItems[I].Color;
    ACanvas.FillRect(R, FStyles[I].Radius, FStyles[I].Radius, FStyles[I].Corners, 1);
    ACanvas.Stroke.Color := FStyles[I].StrokeColor;
    ACanvas.Stroke.Thickness := FStyles[I].Thickness;
    ACanvas.DrawRect(R, FStyles[I].Radius, FStyles[I].Radius, FStyles[I].Corners, 1);
  end;
end;

{ TEllipsesScene }

class function TEllipsesScene.Name: string;
begin
  Result := 'ellipses';
end;

class function TEllipsesScene.Description: string;
begin
  Result := 'FillEllipse + DrawEllipse, N ellipses 6..96 px, stroke 1..3';
end;

class function TEllipsesScene.DefaultN(const APreset: TBenchPreset): Integer;
begin
  // D2D throughput frame: ~2 / ~9 / ~20 ms (~13 us per ellipse, fill and stroke about half each,
  // measured 2026-10-06).
  case APreset of
    TBenchPreset.Light: Result := 130;
    TBenchPreset.Heavy: Result := 1400;
  else
    Result := 700;
  end;
end;

procedure TEllipsesScene.Setup;
begin
  inherited;
  GenerateShapes(22, 6, 96, 0, 0);
end;

procedure TEllipsesScene.Draw(const ACanvas: TCanvas; const ARect: TRectF);
var
  I: Integer;
  R: TRectF;
begin
  ResetBrushes(ACanvas);
  for I := 0 to High(FItems) do
  begin
    R := ShapeRect(I, ARect);
    ACanvas.Fill.Color := FItems[I].Color;
    ACanvas.FillEllipse(R, 1);
    ACanvas.Stroke.Color := FStyles[I].StrokeColor;
    ACanvas.Stroke.Thickness := FStyles[I].Thickness;
    ACanvas.DrawEllipse(R, 1);
  end;
end;

{ TLinesScene }

class function TLinesScene.Name: string;
begin
  Result := 'lines';
end;

class function TLinesScene.Description: string;
begin
  Result := 'DrawLine, N rotating lines 20..300 px, width 0.5..6, 30% dashed, flat/round caps';
end;

class function TLinesScene.DefaultN(const APreset: TBenchPreset): Integer;
begin
  // D2D throughput frame: ~2 / ~9 / ~20 ms (~4.7 us per line on average, measured 2026-10-06):
  // a solid flat line ~0.5 us, a round cap adds ~1.4 us, a dashed line ~10 us.
  case APreset of
    TBenchPreset.Light: Result := 370;
    TBenchPreset.Heavy: Result := 4200;
  else
    Result := 1900;
  end;
end;

procedure TLinesScene.Setup;
const
  Dashes: array[0..2] of TStrokeDash = (TStrokeDash.Dash, TStrokeDash.Dot, TStrokeDash.DashDot);
var
  Rnd: TBenchRandom;
  I: Integer;
begin
  inherited;
  // W is the line length; H is not used.
  GenerateMovingItems(FItems, N, 23, 20, 300);
  Rnd := TBenchRandom.Create(1023);
  SetLength(FStyles, N);
  for I := 0 to N - 1 do
  begin
    FStyles[I].Angle := Rnd.Range(0, 2 * Pi);
    FStyles[I].Speed := Rnd.Range(-1.5, 1.5);
    FStyles[I].Thickness := Rnd.Range(0.5, 6);
    if Rnd.NextFloat < 0.5 then
      FStyles[I].Cap := TStrokeCap.Flat
    else
      FStyles[I].Cap := TStrokeCap.Round;
    if Rnd.NextFloat < 0.3 then
      FStyles[I].Dash := Dashes[Rnd.RangeInt(0, High(Dashes))]
    else
      FStyles[I].Dash := TStrokeDash.Solid;
  end;
end;

procedure TLinesScene.Draw(const ACanvas: TCanvas; const ARect: TRectF);
var
  I: Integer;
  Center, Half: TPointF;
  Angle, S, C: Single;
begin
  ACanvas.Stroke.Kind := TBrushKind.Solid;
  ACanvas.Stroke.Join := TStrokeJoin.Miter;
  for I := 0 to High(FItems) do
  begin
    Center := MovingItemRect(FItems[I], ARect, Time).CenterPoint;
    Angle := FStyles[I].Angle + Time * FStyles[I].Speed;
    SinCos(Angle, S, C);
    Half := TPointF.Create(C, S) * (FItems[I].W * 0.5);
    ACanvas.Stroke.Color := FItems[I].Color;
    ACanvas.Stroke.Thickness := FStyles[I].Thickness;
    ACanvas.Stroke.Cap := FStyles[I].Cap;
    ACanvas.Stroke.Dash := FStyles[I].Dash;
    ACanvas.DrawLine(Center - Half, Center + Half, 1);
  end;
end;

{ TStrokesScene }

class function TStrokesScene.Name: string;
begin
  Result := 'strokes';
end;

class function TStrokesScene.Description: string;
begin
  Result := 'Dashed DrawRect/DrawEllipse outlines 16..160 px, width 1..4, and gradient lines (N, 1 in 5 a line)';
end;

class function TStrokesScene.DefaultN(const APreset: TBenchPreset): Integer;
begin
  case APreset of
    TBenchPreset.Light: Result := 100;
    TBenchPreset.Heavy: Result := 1000;
  else
    Result := 450;
  end;
end;

procedure TStrokesScene.Setup;
const
  Dashes: array[0..4] of TStrokeDash = (TStrokeDash.Dash, TStrokeDash.Dot, TStrokeDash.DashDot,
    TStrokeDash.DashDotDot, TStrokeDash.Custom);
var
  Rnd: TBenchRandom;
  I: Integer;
begin
  inherited;
  GenerateMovingItems(FItems, N, 24, 16, 160);
  Rnd := TBenchRandom.Create(1024);
  SetLength(FStyles, N);
  for I := 0 to N - 1 do
  begin
    if I mod 5 = 4 then
      FStyles[I].Shape := 3
    else
      FStyles[I].Shape := Rnd.RangeInt(0, 2);
    FStyles[I].Thickness := Rnd.RangeInt(1, 4);
    if Rnd.NextFloat < 0.5 then
      FStyles[I].Cap := TStrokeCap.Flat
    else
      FStyles[I].Cap := TStrokeCap.Round;
    FStyles[I].Dash := Dashes[Rnd.RangeInt(0, High(Dashes))];
    FStyles[I].Angle := Rnd.Range(0, 2 * Pi);
    FStyles[I].Speed := Rnd.Range(-1.5, 1.5);
  end;
end;

procedure TStrokesScene.Draw(const ACanvas: TCanvas; const ARect: TRectF);
var
  I: Integer;
  R: TRectF;
  Center, Half: TPointF;
  Angle, S, C: Single;
begin
  ACanvas.Stroke.Join := TStrokeJoin.Miter;
  for I := 0 to High(FItems) do
  begin
    R := MovingItemRect(FItems[I], ARect, Time);
    ACanvas.Stroke.Thickness := FStyles[I].Thickness;
    ACanvas.Stroke.Cap := FStyles[I].Cap;
    if FStyles[I].Shape = 3 then
    begin
      ACanvas.Stroke.Kind := TBrushKind.Gradient;
      ACanvas.Stroke.Gradient.Style := TGradientStyle.Linear;
      ACanvas.Stroke.Gradient.Color := FItems[I].Color;
      ACanvas.Stroke.Gradient.Color1 := DarkShade(FItems[I].Color);
      ACanvas.Stroke.Dash := TStrokeDash.Solid;
      Center := R.CenterPoint;
      Angle := FStyles[I].Angle + Time * FStyles[I].Speed;
      SinCos(Angle, S, C);
      Half := TPointF.Create(C, S) * (FItems[I].W * 0.5);
      ACanvas.DrawLine(Center - Half, Center + Half, 1);
      Continue;
    end;
    ACanvas.Stroke.Kind := TBrushKind.Solid;
    ACanvas.Stroke.Color := DarkShade(FItems[I].Color);
    if FStyles[I].Dash = TStrokeDash.Custom then
      ACanvas.Stroke.SetCustomDash([3, 1, 1, 1, 1, 1], 0)
    else
      ACanvas.Stroke.Dash := FStyles[I].Dash;
    R.Inflate(-FStyles[I].Thickness * 0.5, -FStyles[I].Thickness * 0.5);
    case FStyles[I].Shape of
      0: ACanvas.DrawRect(R, 0, 0, [], 1);
      1: ACanvas.DrawRect(R, 8, 8, AllCorners, 1);
    else
      ACanvas.DrawEllipse(R, 1);
    end;
  end;
end;

initialization
  RegisterBenchScene(TRoundRectsScene);
  RegisterBenchScene(TEllipsesScene);
  RegisterBenchScene(TLinesScene);
  RegisterBenchScene(TStrokesScene);
end.
