unit FastCanvas.GeometrySkia;

{ The Skia engine of the CPU geometry (FastCanvas.Geometry), on every platform; the only one on Android and Linux,
  selectable on Windows (add this unit, FastCanvasGeometryEngine := Skia). Paths are SkPaths; fills are flattened
  from their verbs (the edge sink flattens the curves to the tolerance), stroke outlines come from
  SkPaint.getFillPath with the stroke of the stock canvas: FMX's flat caps square, miter limit 10, the dash patterns
  of Direct2D in stroke widths. }

interface

uses
  System.Types, System.SysUtils, System.Math, System.Skia, FMX.Graphics, FastCanvas.Geometry;

type
  /// <summary>The Skia path behind an IFastGeometry of this engine.</summary>
  IFastSkiaGeometry = interface(IFastGeometry)
    ['{3D6A1E92-58C4-4F0B-A1D7-9E2C6B47F0D8}']
    function Path: ISkPath;
  end;

  TFastGeometrySkia = class(TFastGeometryEngine)
  private
    FPaint: ISkPaint;
  public
    constructor Create; override;
    function Path(const APoints: PFastPathPoints; const ACount: Integer;
      const AWinding: Boolean = False): IFastGeometry; override;
    function Rectangle(const R: TRectF): IFastGeometry; override;
    function RoundedRectangle(const R: TRectF; const ARx, ARy: Single): IFastGeometry; override;
    function Ellipse(const R: TRectF): IFastGeometry; override;
    function Line(const AP0, AP1: TPointF): IFastGeometry; override;
    function Flatten(const AGeometry: IFastGeometry; const ASink: TFastEdgeSink): Boolean; override;
    function Widen(const AGeometry: IFastGeometry; const AStroke: TFastStroke; const ASink: TFastEdgeSink): Boolean;
      override;
    function Contains(const AGeometry: IFastGeometry; const APoint: TPointF): Boolean; override;
  end;

/// <summary>The edges of a Skia path into ASink (its fill rule too).</summary>
procedure FastSkiaPathEdges(const APath: ISkPath; const ASink: TFastEdgeSink);
/// <summary>A Skia path as FMX path points (conics as quadratics, quadratics as cubics).</summary>
function FastSkiaPathPoints(const APath: ISkPath; const ADx: Single = 0; const ADy: Single = 0): TArray<TPathPoint>;

implementation

uses
  System.Skia.API;

type
  TSkiaGeometry = class(TInterfacedObject, IFastGeometry, IFastSkiaGeometry)
  private
    FPath: ISkPath;
  public
    constructor Create(const APath: ISkPath);
    function Path: ISkPath;
  end;

constructor TSkiaGeometry.Create(const APath: ISkPath);
begin
  inherited Create;
  FPath := APath;
end;

function TSkiaGeometry.Path: ISkPath;
begin
  Result := FPath;
end;

function SkiaPath(const AGeometry: IFastGeometry): ISkPath;
var
  G: IFastSkiaGeometry;
begin
  if Supports(AGeometry, IFastSkiaGeometry, G) then
    Result := G.Path
  else
    Result := nil;
end;

function Wrap(const APath: ISkPath): IFastGeometry; inline;
begin
  if APath = nil then
    Result := nil
  else
    Result := TSkiaGeometry.Create(APath);
end;

procedure FastSkiaPathEdges(const APath: ISkPath; const ASink: TFastEdgeSink);
var
  E: TSkPathIteratorElem;
  Quads: TArray<TPointF>;
  I: Integer;
begin
  ASink.EvenOdd := APath.FillType in [TSkPathFillType.EvenOdd, TSkPathFillType.InverseEvenOdd];
  for E in APath.GetIterator(False) do
    case E.Verb of
      TSkPathVerb.Move:
        ASink.BeginFigure(E.Points[0]);
      TSkPathVerb.Line:
        ASink.LineTo(E.Points[1]);
      TSkPathVerb.Quad:
        ASink.QuadTo(E.Points[1], E.Points[2]);
      TSkPathVerb.Conic:
        if Abs(E.ConicWeight - 1) < 1E-4 then
          ASink.QuadTo(E.Points[1], E.Points[2])
        else
        begin
          // Quadratics within Skia's tolerance (2^2 per conic), each flattened by the sink.
          Quads := TSkPath.ConvertConicToQuads(E.Points[0], E.Points[1], E.Points[2], E.ConicWeight, 2);
          I := 1;
          while I + 1 < Length(Quads) do
          begin
            ASink.QuadTo(Quads[I], Quads[I + 1]);
            Inc(I, 2);
          end;
        end;
      TSkPathVerb.Cubic:
        ASink.CubicTo(E.Points[1], E.Points[2], E.Points[3]);
      TSkPathVerb.Close:
        ASink.CloseFigure;
    end;
  // Fills close every figure.
  ASink.CloseFigure;
end;

function FastSkiaPathPoints(const APath: ISkPath; const ADx, ADy: Single): TArray<TPathPoint>;
var
  E: TSkPathIteratorElem;
  Count, I: Integer;
  Quads: TArray<TPointF>;
  P0: TPointF;

  procedure Add(const AKind: TPathPointKind; const P: TPointF);
  begin
    if Count = Length(Result) then
      SetLength(Result, Max(64, 2 * Count));
    Result[Count].Kind := AKind;
    Result[Count].Point := TPointF.Create(P.X + ADx, P.Y + ADy);
    Inc(Count);
  end;

  procedure Quad(const A, B, C: TPointF);
  begin
    // The cubic of the same curve.
    Add(TPathPointKind.CurveTo, A + (B - A) * (2 / 3));
    Add(TPathPointKind.CurveTo, C + (B - C) * (2 / 3));
    Add(TPathPointKind.CurveTo, C);
  end;

begin
  Count := 0;
  Result := nil;
  for E in APath.GetIterator(False) do
    case E.Verb of
      TSkPathVerb.Move:
        Add(TPathPointKind.MoveTo, E.Points[0]);
      TSkPathVerb.Line:
        Add(TPathPointKind.LineTo, E.Points[1]);
      TSkPathVerb.Quad:
        Quad(E.Points[0], E.Points[1], E.Points[2]);
      TSkPathVerb.Conic:
        begin
          Quads := TSkPath.ConvertConicToQuads(E.Points[0], E.Points[1], E.Points[2], E.ConicWeight, 2);
          P0 := E.Points[0];
          I := 1;
          while I + 1 < Length(Quads) do
          begin
            Quad(P0, Quads[I], Quads[I + 1]);
            P0 := Quads[I + 1];
            Inc(I, 2);
          end;
        end;
      TSkPathVerb.Cubic:
        begin
          Add(TPathPointKind.CurveTo, E.Points[1]);
          Add(TPathPointKind.CurveTo, E.Points[2]);
          Add(TPathPointKind.CurveTo, E.Points[3]);
        end;
      TSkPathVerb.Close:
        Add(TPathPointKind.Close, TPointF.Zero);
    end;
  SetLength(Result, Count);
end;

{ TFastGeometrySkia }

constructor TFastGeometrySkia.Create;
begin
  inherited Create;
  FPaint := TSkPaint.Create(TSkPaintStyle.Stroke);
end;

function TFastGeometrySkia.Path(const APoints: PFastPathPoints; const ACount: Integer;
  const AWinding: Boolean): IFastGeometry;
var
  B: ISkPathBuilder;
  I: Integer;
  Open: Boolean;
begin
  if AWinding then
    B := TSkPathBuilder.Create(TSkPathFillType.Winding)
  else
    B := TSkPathBuilder.Create(TSkPathFillType.EvenOdd);
  Open := False;
  I := 0;
  while I < ACount do
  begin
    case APoints[I].Kind of
      TPathPointKind.MoveTo:
        begin
          B.MoveTo(APoints[I].Point);
          Open := True;
        end;
      TPathPointKind.LineTo:
        if Open then
          B.LineTo(APoints[I].Point);
      TPathPointKind.CurveTo:
        begin
          if Open and (I + 2 < ACount) then
            B.CubicTo(APoints[I].Point, APoints[I + 1].Point, APoints[I + 2].Point);
          Inc(I, 2);
        end;
      TPathPointKind.Close:
        if Open then
        begin
          B.Close;
          Open := False;
        end;
    end;
    Inc(I);
  end;
  Result := Wrap(B.Detach);
end;

function TFastGeometrySkia.Rectangle(const R: TRectF): IFastGeometry;
var
  B: ISkPathBuilder;
begin
  B := TSkPathBuilder.Create;
  B.AddRect(R);
  Result := Wrap(B.Detach);
end;

function TFastGeometrySkia.RoundedRectangle(const R: TRectF; const ARx, ARy: Single): IFastGeometry;
var
  B: ISkPathBuilder;
begin
  B := TSkPathBuilder.Create;
  // Clockwise from the top of the left side, as Direct2D: dash patterns start where its rounded rectangles do.
  B.AddRoundRect(TSkRoundRect.Create(R, ARx, ARy), TSkPathDirection.CW, 7);
  Result := Wrap(B.Detach);
end;

function TFastGeometrySkia.Ellipse(const R: TRectF): IFastGeometry;
var
  B: ISkPathBuilder;
begin
  B := TSkPathBuilder.Create;
  // Clockwise from the leftmost point, as Direct2D's ellipses.
  B.AddOval(R, TSkPathDirection.CW, 3);
  Result := Wrap(B.Detach);
end;

function TFastGeometrySkia.Line(const AP0, AP1: TPointF): IFastGeometry;
var
  B: ISkPathBuilder;
begin
  B := TSkPathBuilder.Create;
  B.MoveTo(AP0);
  B.LineTo(AP1);
  Result := Wrap(B.Detach);
end;

function TFastGeometrySkia.Flatten(const AGeometry: IFastGeometry; const ASink: TFastEdgeSink): Boolean;
var
  P: ISkPath;
begin
  P := SkiaPath(AGeometry);
  if P = nil then
    Exit(False);
  FastSkiaPathEdges(P, ASink);
  Result := True;
end;

function TFastGeometrySkia.Widen(const AGeometry: IFastGeometry; const AStroke: TFastStroke;
  const ASink: TFastEdgeSink): Boolean;
const
  Joins: array[0..2] of TSkStrokeJoin = (TSkStrokeJoin.Miter, TSkStrokeJoin.Round, TSkStrokeJoin.Bevel);
  Huge = 1E9;
var
  P, Outline: ISkPath;
  Pattern: TArray<Single>;
  Dashes: PSingle;
  I: Integer;
begin
  P := SkiaPath(AGeometry);
  if (P = nil) or (AStroke.Width <= 0) then
    Exit(False);
  // FMX's flat caps square, as the stock Direct2D canvas strokes.
  if AStroke.Cap = 1 then
    FPaint.StrokeCap := TSkStrokeCap.Round
  else
    FPaint.StrokeCap := TSkStrokeCap.Square;
  FPaint.StrokeJoin := Joins[Min(AStroke.Join, 2)];
  FPaint.StrokeMiter := 10;
  FPaint.StrokeWidth := AStroke.Width;
  // Dash patterns in stroke widths (Direct2D's D2D1_DASH_STYLE; Custom: the brush's array).
  case AStroke.Dash of
    1: Pattern := [2, 2];
    2: Pattern := [0, 2];
    3: Pattern := [2, 2, 0, 2];
    4: Pattern := [2, 2, 0, 2, 0, 2];
    5:
      begin
        SetLength(Pattern, AStroke.DashCount);
        Dashes := AStroke.Dashes;
        for I := 0 to AStroke.DashCount - 1 do
        begin
          Pattern[I] := Dashes^;
          Inc(Dashes);
        end;
        if Odd(Length(Pattern)) then
          Pattern := Pattern + Pattern;
      end;
  else
    Pattern := nil;
  end;
  if Pattern <> nil then
  begin
    for I := 0 to High(Pattern) do
      Pattern[I] := Pattern[I] * AStroke.Width;
    FPaint.PathEffect := TSkPathEffect.MakeDash(Pattern, AStroke.DashOffset * AStroke.Width);
  end
  else
    FPaint.PathEffect := nil;
  // The resolution scale: curves of the outline as fine as the tolerance needs.
  Outline := FPaint.GetFillPath(P, TRectF.Create(-Huge, -Huge, Huge, Huge), Max(1, 0.2 / Max(ASink.Tolerance, 1E-4)));
  if Outline = nil then
    Exit(False);
  FastSkiaPathEdges(Outline, ASink);
  Result := True;
end;

function TFastGeometrySkia.Contains(const AGeometry: IFastGeometry; const APoint: TPointF): Boolean;
var
  P: ISkPath;
begin
  P := SkiaPath(AGeometry);
  Result := (P <> nil) and P.Contains(APoint.X, APoint.Y);
end;

initialization
  // Skia stays loaded until the process ends (not released): paths are released with the forms' canvases, after the
  // finalization of System.Skia, which unloads the library otherwise.
  SkInitialize;
  FastRegisterGeometryEngine(TFastCanvasEngine.Skia, TFastGeometrySkia);
end.
