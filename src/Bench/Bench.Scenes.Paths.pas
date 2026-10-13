unit Bench.Scenes.Paths;

{ Gradient and path scenes.

  gradients  N moving rectangles, rounded rectangles and ellipses (16..128 px) filled from a pool of
             32 gradient brushes created once in Setup (linear and radial, 2..4 stops), as styles keep
             their brushes. Every item is drawn in local coordinates under its own translation, as a
             control is: TCanvasD2D puts the radial centre at Rect.Width/2 without Rect.Left
             (FMX.Canvas.D2D.pas:1424), so radial fills are only right when the rect starts at the
             origin. D2D creates a new stop collection and brush whenever the rect or the gradient
             differs from the previous fill (FMX.Canvas.D2D.pas:1866-1869, :1407-1427): every item here.
  paths      N icons from 8 static TPathData parsed once from SVG path data (star, gear, heart, cloud,
             arrow, speech bubble, lightning, target: lines, cubic and quadratic curves, arcs, several
             subpaths, holes). Each item fills and strokes its icon under its own matrix: translation
             (moving), rotation (from Time) and scale 0.5..3. D2D builds a new ID2D1PathGeometry for
             every FillPath and DrawPath (FMX.Canvas.D2D.pas:2369, :2381, :1123).

  All canvases fill paths with the even-odd rule; holes are also wound opposite to their outlines so
  that they stay holes under the non-zero rule.

  Screenshots match across canvases except on GPU: no anti-aliasing at the default quality, and linear
  gradients are interpolated in the normalized 0..1 space of the shape (texture coordinates,
  FMX.Canvas.GPU.Helpers.pas:825-828), so diagonal gradients on non-square shapes tilt differently. }

interface

implementation

uses
  System.Types, System.UITypes, System.Math, System.Math.Vectors, FMX.Types, FMX.Graphics, Bench.Config,
  Bench.Scenes;

const
  GradientBrushCount = 32;
  // Normalized start and stop points whose gradient line spans the whole shape. GDI+ mirrors a linear
  // gradient outside start..stop (WrapModeTileFlipX, FMX.Canvas.GDIP.pas:442), the other canvases clamp.
  LinearDirections: array[0..7, 0..3] of Single = (
    (0, 0.5, 1, 0.5), (1, 0.5, 0, 0.5), (0.5, 0, 0.5, 1), (0.5, 1, 0.5, 0),
    (0, 0, 1, 1), (1, 1, 0, 0), (1, 0, 0, 1), (0, 1, 1, 0));

  IconSize = 64;
  IconCount = 8;
  // Icons in a 64 x 64 box. Outlines run clockwise (on screen), holes counter-clockwise.
  IconPaths: array[0..IconCount - 1] of string = (
    // Star with a round hole.
    'M 32,4 L 39.35,23.89 60.53,24.73 43.89,37.86 49.63,58.27 32,46.5 14.37,58.27 20.11,37.86 3.47,24.73 ' +
    '24.65,23.89 Z' +
    ' M 38,34 A 6,6 0 1,0 26,34 A 6,6 0 1,0 38,34 Z',
    // Gear: 16 teeth with arcs between them, an axle hole and six lightening holes.
    'M 56,32 L 62.44,33.86 62.04,37.3 55.34,37.6 A 24,24 0 0,1 54.17,41.18' +
    ' L 59.41,45.37 57.72,48.39 51.42,46.11 A 24,24 0 0,1 48.97,48.97' +
    ' L 52.21,54.84 49.49,56.98 44.54,52.46 A 24,24 0 0,1 41.18,54.17' +
    ' L 41.93,60.84 38.6,61.78 35.75,55.7 A 24,24 0 0,1 32,56' +
    ' L 30.14,62.44 26.7,62.04 26.4,55.34 A 24,24 0 0,1 22.82,54.17' +
    ' L 18.63,59.41 15.61,57.72 17.89,51.42 A 24,24 0 0,1 15.03,48.97' +
    ' L 9.16,52.21 7.02,49.49 11.54,44.54 A 24,24 0 0,1 9.83,41.18' +
    ' L 3.16,41.93 2.22,38.6 8.3,35.75 A 24,24 0 0,1 8,32' +
    ' L 1.56,30.14 1.96,26.7 8.66,26.4 A 24,24 0 0,1 9.83,22.82' +
    ' L 4.59,18.63 6.28,15.61 12.58,17.89 A 24,24 0 0,1 15.03,15.03' +
    ' L 11.79,9.16 14.51,7.02 19.46,11.54 A 24,24 0 0,1 22.82,9.83' +
    ' L 22.07,3.16 25.4,2.22 28.25,8.3 A 24,24 0 0,1 32,8' +
    ' L 33.86,1.56 37.3,1.96 37.6,8.66 A 24,24 0 0,1 41.18,9.83' +
    ' L 45.37,4.59 48.39,6.28 46.11,12.58 A 24,24 0 0,1 48.97,15.03' +
    ' L 54.84,11.79 56.98,14.51 52.46,19.46 A 24,24 0 0,1 54.17,22.82' +
    ' L 60.84,22.07 61.78,25.4 55.7,28.25 A 24,24 0 0,1 56,32 Z' +
    ' M 41,32 A 9,9 0 1,0 23,32 A 9,9 0 1,0 41,32 Z' +
    ' M 48.86,40 A 3,3 0 1,0 42.86,40 A 3,3 0 1,0 48.86,40 Z' +
    ' M 35,48 A 3,3 0 1,0 29,48 A 3,3 0 1,0 35,48 Z' +
    ' M 21.14,40 A 3,3 0 1,0 15.14,40 A 3,3 0 1,0 21.14,40 Z' +
    ' M 21.14,24 A 3,3 0 1,0 15.14,24 A 3,3 0 1,0 21.14,24 Z' +
    ' M 35,16 A 3,3 0 1,0 29,16 A 3,3 0 1,0 35,16 Z' +
    ' M 48.86,24 A 3,3 0 1,0 42.86,24 A 3,3 0 1,0 48.86,24 Z',
    // Heart.
    'M 32,58 C 12,44 2,32 2,20 C 2,10 10,4 18,4 C 24,4 29,8 32,13 C 35,8 40,4 46,4 C 54,4 62,10 62,20' +
    ' C 62,32 52,44 32,58 Z',
    // Cloud with three rain drops.
    'M 16,44 C 8,44 2,39 2,32 C 2,25 8,20 15,20 C 17,11 24,4 34,4 C 43,4 50,10 52,18 C 59,18 63,24 63,31' +
    ' C 63,38 57,44 50,44 Z' +
    ' M 20,49 Q 24,55 24,58 A 4,4 0 0,1 16,58 Q 16,55 20,49 Z' +
    ' M 32,49 Q 36,55 36,58 A 4,4 0 0,1 28,58 Q 28,55 32,49 Z' +
    ' M 44,49 Q 48,55 48,58 A 4,4 0 0,1 40,58 Q 40,55 44,49 Z',
    // Circular arrow: 270 degree band with an arrow head.
    'M 19,54.52 A 26,26 0 1,1 54.52,45 L 60.58,48.5 45.05,53.39 41.53,37.5 47.59,41 A 18,18 0 1,0 23,47.59 Z',
    // Speech bubble with three dots cut out.
    'M 12,6 L 52,6 Q 60,6 60,14 L 60,36 Q 60,44 52,44 L 28,44 14,58 17,44 12,44 Q 4,44 4,36 L 4,14' +
    ' Q 4,6 12,6 Z' +
    ' M 23.5,25 A 3.5,3.5 0 1,0 16.5,25 A 3.5,3.5 0 1,0 23.5,25 Z' +
    ' M 35.5,25 A 3.5,3.5 0 1,0 28.5,25 A 3.5,3.5 0 1,0 35.5,25 Z' +
    ' M 47.5,25 A 3.5,3.5 0 1,0 40.5,25 A 3.5,3.5 0 1,0 47.5,25 Z',
    // Lightning bolt, lines only.
    'M 38,2 L 44,2 34,24 52,24 22,62 29,36 12,36 Z',
    // Target: concentric rings and a centre dot.
    'M 62,32 A 30,30 0 1,1 2,32 A 30,30 0 1,1 62,32 Z' +
    ' M 54,32 A 22,22 0 1,0 10,32 A 22,22 0 1,0 54,32 Z' +
    ' M 46,32 A 14,14 0 1,1 18,32 A 14,14 0 1,1 46,32 Z' +
    ' M 39,32 A 7,7 0 1,0 25,32 A 7,7 0 1,0 39,32 Z' +
    ' M 35,32 A 3,3 0 1,1 29,32 A 3,3 0 1,1 35,32 Z');
  IconStrokeThickness = 1.5; // icon units, scaled with the icon

type
  TGradientShape = (Plain, Rounded, Oval);

  TGradientItem = record
    Move: TMovingItem;
    Shape: TGradientShape;
    Brush: Integer;
  end;

  TGradientsScene = class(TBenchPaintScene)
  private
    FBrushes: TArray<TBrush>;
    FItems: TArray<TGradientItem>;
  protected
    procedure Draw(const ACanvas: TCanvas; const ARect: TRectF); override;
  public
    destructor Destroy; override;
    class function Name: string; override;
    class function Description: string; override;
    class function DefaultN(const APreset: TBenchPreset): Integer; override;
    procedure Setup; override;
  end;

  TPathItem = record
    Move: TMovingItem;
    Icon: Integer;
    Scale: Single;
    Angle: Single;   // radians at Time = 0
    Spin: Single;    // radians per second
    StrokeColor: TAlphaColor;
  end;

  TPathsScene = class(TBenchPaintScene)
  private
    FPaths: TArray<TPathData>;
    FItems: TArray<TPathItem>;
  protected
    procedure Draw(const ACanvas: TCanvas; const ARect: TRectF); override;
  public
    destructor Destroy; override;
    class function Name: string; override;
    class function Description: string; override;
    class function DefaultN(const APreset: TBenchPreset): Integer; override;
    procedure Setup; override;
  end;

function CreateGradientBrush(var ARnd: TBenchRandom): TBrush;
var
  Stops, I, Dir: Integer;
  Offsets: array[0..3] of Single;
  P: TGradientPoint;
begin
  Result := TBrush.Create(TBrushKind.Gradient, TAlphaColors.Black);
  Stops := ARnd.RangeInt(2, 4);
  // The outer stops sit exactly at 0 and 1: D2D and GDI+ would add boundary stops otherwise.
  Offsets[0] := 0;
  if Stops = 3 then
    Offsets[1] := ARnd.Range(0.25, 0.75)
  else if Stops = 4 then
  begin
    Offsets[1] := ARnd.Range(0.15, 0.45);
    Offsets[2] := ARnd.Range(0.55, 0.85);
  end;
  Offsets[Stops - 1] := 1;
  Result.Gradient.Points.Clear;
  for I := 0 to Stops - 1 do
  begin
    P := TGradientPoint(Result.Gradient.Points.Add);
    P.Color := ARnd.Color;
    P.Offset := Offsets[I];
  end;
  // Radial gradients keep the default RadialTransform: GDI+ ignores RotationCenter
  // (FMX.Canvas.GDIP.pas:468) and the GPU canvas ignores its scale (FMX.Materials.Canvas.pas:1966).
  if ARnd.NextFloat < 0.6 then
  begin
    Result.Gradient.Style := TGradientStyle.Linear;
    Dir := ARnd.RangeInt(0, High(LinearDirections));
    Result.Gradient.StartPosition.Point := TPointF.Create(LinearDirections[Dir, 0], LinearDirections[Dir, 1]);
    Result.Gradient.StopPosition.Point := TPointF.Create(LinearDirections[Dir, 2], LinearDirections[Dir, 3]);
  end
  else
    Result.Gradient.Style := TGradientStyle.Radial;
end;

{ TGradientsScene }

destructor TGradientsScene.Destroy;
var
  B: TBrush;
begin
  for B in FBrushes do
    B.Free;
  inherited;
end;

class function TGradientsScene.Name: string;
begin
  Result := 'gradients';
end;

class function TGradientsScene.Description: string;
begin
  Result := 'Rects, round rects, ellipses 16..128 px, 32 linear/radial gradient brushes';
end;

class function TGradientsScene.DefaultN(const APreset: TBenchPreset): Integer;
begin
  // D2D throughput frame: ~2 / ~9 / ~20 ms (~75 us per gradient fill, measured 2026-10-06).
  case APreset of
    TBenchPreset.Light: Result := 25;
    TBenchPreset.Heavy: Result := 250;
  else
    Result := 100;
  end;
end;

procedure TGradientsScene.Setup;
var
  Rnd: TBenchRandom;
  Moves: TArray<TMovingItem>;
  I: Integer;
begin
  inherited;
  Rnd := TBenchRandom.Create(21);
  SetLength(FBrushes, GradientBrushCount);
  for I := 0 to GradientBrushCount - 1 do
    FBrushes[I] := CreateGradientBrush(Rnd);
  GenerateMovingItems(Moves, N, 20, 16, 128);
  SetLength(FItems, N);
  for I := 0 to N - 1 do
  begin
    FItems[I].Move := Moves[I];
    FItems[I].Shape := TGradientShape(Rnd.RangeInt(0, Ord(High(TGradientShape))));
    FItems[I].Brush := Rnd.RangeInt(0, GradientBrushCount - 1);
  end;
end;

procedure TGradientsScene.Draw(const ACanvas: TCanvas; const ARect: TRectF);
var
  Base: TMatrix;
  I: Integer;
  R, Local: TRectF;
  Radius: Single;
  Brush: TBrush;
begin
  Base := ACanvas.Matrix;
  try
    for I := 0 to High(FItems) do
    begin
      R := MovingItemRect(FItems[I].Move, ARect, Time);
      ACanvas.SetMatrix(TMatrix.CreateTranslation(R.Left, R.Top) * Base);
      Local := TRectF.Create(0, 0, R.Width, R.Height);
      Brush := FBrushes[FItems[I].Brush];
      case FItems[I].Shape of
        TGradientShape.Plain:
          ACanvas.FillRect(Local, 1, Brush);
        TGradientShape.Rounded:
          begin
            Radius := Min(R.Width, R.Height) * 0.25;
            ACanvas.FillRect(Local, Radius, Radius, AllCorners, 1, Brush);
          end;
      else
        ACanvas.FillEllipse(Local, 1, Brush);
      end;
    end;
  finally
    ACanvas.SetMatrix(Base);
  end;
end;

{ TPathsScene }

destructor TPathsScene.Destroy;
var
  P: TPathData;
begin
  for P in FPaths do
    P.Free;
  inherited;
end;

class function TPathsScene.Name: string;
begin
  Result := 'paths';
end;

class function TPathsScene.Description: string;
begin
  Result := 'Fill + stroke of 8 static TPathData icons, rotating, scale 0.5..3';
end;

class function TPathsScene.DefaultN(const APreset: TBenchPreset): Integer;
begin
  // D2D throughput frame: ~2 / ~9 / ~20 ms (~25 us per icon, fill + stroke, measured 2026-10-06).
  case APreset of
    TBenchPreset.Light: Result := 70;
    TBenchPreset.Heavy: Result := 760;
  else
    Result := 330;
  end;
end;

procedure TPathsScene.Setup;
var
  Rnd: TBenchRandom;
  Moves: TArray<TMovingItem>;
  I: Integer;
begin
  inherited;
  SetLength(FPaths, IconCount);
  for I := 0 to IconCount - 1 do
  begin
    FPaths[I] := TPathData.Create;
    FPaths[I].Data := IconPaths[I];
    FPaths[I].Translate(-IconSize / 2, -IconSize / 2);
  end;
  GenerateMovingItems(Moves, N, 30, 0, 0);
  Rnd := TBenchRandom.Create(31);
  SetLength(FItems, N);
  for I := 0 to N - 1 do
  begin
    FItems[I].Move := Moves[I];
    FItems[I].Icon := Rnd.RangeInt(0, IconCount - 1);
    // Mostly small icons, a few large ones: 0.5..3, mean ~1.3 (85 px).
    FItems[I].Scale := 0.5 + 2.5 * Sqr(Rnd.NextFloat);
    FItems[I].Angle := Rnd.Range(0, 2 * Pi);
    FItems[I].Spin := Rnd.Range(-1.5, 1.5);
    FItems[I].StrokeColor := TAlphaColor($FF000000) or ((Moves[I].Color and $FEFEFE) shr 1);
  end;
end;

procedure TPathsScene.Draw(const ACanvas: TCanvas; const ARect: TRectF);
var
  Base, M: TMatrix;
  I: Integer;
  C: TPointF;
begin
  Base := ACanvas.Matrix;
  ACanvas.Fill.Kind := TBrushKind.Solid;
  ACanvas.Stroke.Kind := TBrushKind.Solid;
  ACanvas.Stroke.Thickness := IconStrokeThickness;
  ACanvas.Stroke.Join := TStrokeJoin.Round;
  try
    for I := 0 to High(FItems) do
    begin
      C := MovingItemRect(FItems[I].Move, ARect, Time).CenterPoint;
      M := TMatrix.CreateScaling(FItems[I].Scale, FItems[I].Scale) *
        TMatrix.CreateRotation(FItems[I].Angle + Time * FItems[I].Spin) * TMatrix.CreateTranslation(C.X, C.Y);
      ACanvas.SetMatrix(M * Base);
      ACanvas.Fill.Color := FItems[I].Move.Color;
      ACanvas.FillPath(FPaths[FItems[I].Icon], 1);
      ACanvas.Stroke.Color := FItems[I].StrokeColor;
      ACanvas.DrawPath(FPaths[FItems[I].Icon], 1);
    end;
  finally
    ACanvas.SetMatrix(Base);
  end;
end;

initialization
  RegisterBenchScene(TGradientsScene);
  RegisterBenchScene(TPathsScene);
end.
