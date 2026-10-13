unit FastCanvas.Geometry;

{ CPU geometry of FastCanvas: the polygons that the GPU renderer covers exactly (FastCanvas.Gpu, GpuKindPath). The
  canvas asks an engine for the geometry of a path or a shape, then for the polygon edges of its fill (curves
  flattened to a tolerance) or of the outline of a stroke (joins, caps, dashes) into a TFastEdgeSink, and whether a
  point is inside a fill (PtInPath).

  Engines: Direct2D (FastCanvas.GeometryD2D, Windows, the default there: ID2D1Geometry.Simplify and Widen) and Skia
  (FastCanvas.GeometrySkia, every platform, the only one on Android and Linux: SkPath, SkPaint.GetFillPath). An
  engine unit registers itself when it is linked; FastCanvasGeometryEngine chooses one. }

interface

uses
  System.Types, System.SysUtils, System.Math, FMX.Graphics;

type
  /// <summary>Where the canvas takes its CPU geometry (FastCanvasGeometryEngine) or its text (FastCanvasTextEngine)
  /// from.</summary>
  TFastCanvasEngine = (
    /// <summary>The platform's own: Direct2D and DirectWrite (Windows only).</summary>
    Native,
    /// <summary>Skia (System.Skia; sk4d.dll next to the program on Windows, libsk4d.so on Linux, linked into the
    /// program on Android). On Windows add the units FastCanvas.GeometrySkia and FastCanvas.TextSkia to the program.
    /// </summary>
    Skia);

  TFastEdge = record
    X0, Y0, X1, Y1: Single;
  end;

  PFastPathPoints = ^TFastPathPoints;
  TFastPathPoints = array[0..MaxInt div SizeOf(TPathPoint) - 1] of TPathPoint;

  /// <summary>Receives a flattened or widened geometry as polygon edges: every figure closed, curves flattened to the
  /// tolerance. Reused for every path (the render thread must not allocate per draw).</summary>
  TFastEdgeSink = class
  private
    FTolerance: Single;
    FStart, FCur: TPointF;
    FOpen: Boolean;
    procedure Edge(const A, B: TPointF);
  public
    Edges: TArray<TFastEdge>;
    Count: Integer;
    /// <summary>The fill rule of the polygon: even-odd, else non-zero.</summary>
    EvenOdd: Boolean;
    MinX, MinY, MaxX, MaxY: Single;
    constructor Create;
    /// <summary>Starts a new polygon (keeps the edge buffer).</summary>
    procedure Reset(const ATolerance: Single; const AEvenOdd: Boolean);
    /// <summary>Starts a figure (closes the open one).</summary>
    procedure BeginFigure(const P: TPointF);
    procedure LineTo(const P: TPointF);
    /// <summary>A cubic Bezier curve from the current point, flattened.</summary>
    procedure CubicTo(const P1, P2, P3: TPointF);
    /// <summary>A quadratic Bezier curve from the current point (as the cubic of the same curve).</summary>
    procedure QuadTo(const P1, P2: TPointF);
    /// <summary>A conic (rational quadratic) curve of weight W from the current point, flattened.</summary>
    procedure ConicTo(const P1, P2: TPointF; const W: Single);
    procedure CloseFigure;
    property Tolerance: Single read FTolerance;
  end;

  /// <summary>How a stroke is outlined, as the stock Direct2D canvas strokes: Cap 0 square (FMX's flat caps), 1 round;
  /// Join Ord(TStrokeJoin), miter limit 10; Dash Ord(TStrokeDash), the predefined patterns in stroke widths, Custom:
  /// DashCount lengths at Dashes (in stroke widths), DashOffset (in stroke widths).</summary>
  TFastStroke = record
    Width: Single;
    Cap, Join, Dash: Byte;
    DashOffset: Single;
    Dashes: PSingle;
    DashCount: Integer;
    /// <summary>Identifies cap, join and dashes (not the width): engines may keep what they make of them by it.
    /// </summary>
    Key: UInt64;
  end;

  /// <summary>A geometry of an engine (opaque to the canvas).</summary>
  IFastGeometry = interface
    ['{5A0C2B71-3E44-4C1D-9F28-6D7B1E0A9C35}']
  end;

  /// <summary>Makes and flattens geometries. The canvas's render thread holds one engine; PtInPath (the main
  /// thread) uses another.</summary>
  TFastGeometryEngine = class abstract
  public
    constructor Create; virtual;
    /// <summary>FMX path points: MoveTo starts a filled figure, CurveTo takes three points (two control points and
    /// the end), Close ends the figure closed; an unfinished figure ends open. AWinding: the non-zero fill rule (glyph
    /// outlines), else even-odd (FMX paths).</summary>
    function Path(const APoints: PFastPathPoints; const ACount: Integer;
      const AWinding: Boolean = False): IFastGeometry; virtual; abstract;
    function Rectangle(const R: TRectF): IFastGeometry; virtual; abstract;
    function RoundedRectangle(const R: TRectF; const ARx, ARy: Single): IFastGeometry; virtual; abstract;
    function Ellipse(const R: TRectF): IFastGeometry; virtual; abstract;
    /// <summary>An open figure from AP0 to AP1 (for strokes).</summary>
    function Line(const AP0, AP1: TPointF): IFastGeometry; virtual; abstract;
    /// <summary>The polygon of the fill into ASink, reset by the caller (its tolerance and the default rule, which
    /// the engine replaces by the geometry's). False when the engine fails.</summary>
    function Flatten(const AGeometry: IFastGeometry; const ASink: TFastEdgeSink): Boolean; virtual; abstract;
    /// <summary>The polygon of the outline of a stroke into ASink (as Flatten).</summary>
    function Widen(const AGeometry: IFastGeometry; const AStroke: TFastStroke; const ASink: TFastEdgeSink): Boolean;
      virtual; abstract;
    /// <summary>The point is inside the fill.</summary>
    function Contains(const AGeometry: IFastGeometry; const APoint: TPointF): Boolean; virtual; abstract;
  end;
  TFastGeometryEngineClass = class of TFastGeometryEngine;

var
  /// <summary>The engine of the CPU geometry; read when the canvas makes its renderer (the first scene) and by
  /// PtInPath. Android and Linux: Skia whatever it says.</summary>
  FastCanvasGeometryEngine: TFastCanvasEngine =
    {$IFDEF MSWINDOWS}TFastCanvasEngine.Native{$ELSE}TFastCanvasEngine.Skia{$ENDIF};

/// <summary>Called by the engine units (initialization).</summary>
procedure FastRegisterGeometryEngine(const AKind: TFastCanvasEngine; const AClass: TFastGeometryEngineClass);
/// <summary>The class of the engine FastCanvasGeometryEngine chooses (Skia on Android and Linux). Raises when the
/// unit of that engine is not in the program.</summary>
function FastGeometryEngineClass: TFastGeometryEngineClass;

implementation

var
  GEngines: array[TFastCanvasEngine] of TFastGeometryEngineClass;

procedure FastRegisterGeometryEngine(const AKind: TFastCanvasEngine; const AClass: TFastGeometryEngineClass);
begin
  GEngines[AKind] := AClass;
end;

function FastGeometryEngineClass: TFastGeometryEngineClass;
var
  Kind: TFastCanvasEngine;
begin
{$IFDEF MSWINDOWS}
  Kind := FastCanvasGeometryEngine;
{$ELSE}
  Kind := TFastCanvasEngine.Skia;
{$ENDIF}
  Result := GEngines[Kind];
  if Result = nil then
    raise Exception.Create('FastCanvas: the geometry engine is not in the program (add FastCanvas.GeometrySkia)');
end;

{ TFastGeometryEngine }

constructor TFastGeometryEngine.Create;
begin
  inherited Create;
end;

{ TFastEdgeSink }

constructor TFastEdgeSink.Create;
begin
  inherited Create;
  SetLength(Edges, 1024);
end;

procedure TFastEdgeSink.Reset(const ATolerance: Single; const AEvenOdd: Boolean);
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

procedure TFastEdgeSink.Edge(const A, B: TPointF);
begin
  if (A.X = B.X) and (A.Y = B.Y) then
    Exit;
  if Count = Length(Edges) then
    SetLength(Edges, 2 * Count);
  Edges[Count].X0 := A.X;
  Edges[Count].Y0 := A.Y;
  Edges[Count].X1 := B.X;
  Edges[Count].Y1 := B.Y;
  Inc(Count);
  // Every edge starts where the previous one ended: B is enough, except for the first point of a figure.
  if B.X < MinX then
    MinX := B.X;
  if B.X > MaxX then
    MaxX := B.X;
  if B.Y < MinY then
    MinY := B.Y;
  if B.Y > MaxY then
    MaxY := B.Y;
end;

procedure TFastEdgeSink.CloseFigure;
begin
  if FOpen then
    Edge(FCur, FStart);
  FOpen := False;
end;

procedure TFastEdgeSink.BeginFigure(const P: TPointF);
begin
  CloseFigure;
  if P.X < MinX then
    MinX := P.X;
  if P.X > MaxX then
    MaxX := P.X;
  if P.Y < MinY then
    MinY := P.Y;
  if P.Y > MaxY then
    MaxY := P.Y;
  FStart := P;
  FCur := P;
  FOpen := True;
end;

procedure TFastEdgeSink.LineTo(const P: TPointF);
begin
  Edge(FCur, P);
  FCur := P;
end;

procedure TFastEdgeSink.CubicTo(const P1, P2, P3: TPointF);
var
  K, N: Integer;
  P0, Q: TPointF;
  Dd, T, U: Single;
begin
  P0 := FCur;
  // Segments for a cubic from the size of its second differences.
  Dd := Max(Sqrt(Sqr(P0.X - 2 * P1.X + P2.X) + Sqr(P0.Y - 2 * P1.Y + P2.Y)),
    Sqrt(Sqr(P1.X - 2 * P2.X + P3.X) + Sqr(P1.Y - 2 * P2.Y + P3.Y)));
  N := EnsureRange(Ceil(Sqrt(0.75 * Dd / Max(FTolerance, 1E-4))), 1, 256);
  for K := 1 to N do
  begin
    T := K / N;
    U := 1 - T;
    Q.X := U * U * U * P0.X + 3 * U * U * T * P1.X + 3 * U * T * T * P2.X + T * T * T * P3.X;
    Q.Y := U * U * U * P0.Y + 3 * U * U * T * P1.Y + 3 * U * T * T * P2.Y + T * T * T * P3.Y;
    Edge(FCur, Q);
    FCur := Q;
  end;
end;

procedure TFastEdgeSink.QuadTo(const P1, P2: TPointF);
var
  P0, C1, C2: TPointF;
begin
  P0 := FCur;
  C1.X := P0.X + 2 / 3 * (P1.X - P0.X);
  C1.Y := P0.Y + 2 / 3 * (P1.Y - P0.Y);
  C2.X := P2.X + 2 / 3 * (P1.X - P2.X);
  C2.Y := P2.Y + 2 / 3 * (P1.Y - P2.Y);
  CubicTo(C1, C2, P2);
end;

procedure TFastEdgeSink.ConicTo(const P1, P2: TPointF; const W: Single);
var
  K, N: Integer;
  P0, Q: TPointF;
  Dd, T, U, A, B, C, D: Single;
begin
  P0 := FCur;
  // As many segments as the quadratic of the same points needs, more for heavy weights.
  Dd := Sqrt(Sqr(P0.X - 2 * P1.X + P2.X) + Sqr(P0.Y - 2 * P1.Y + P2.Y)) * Max(W, 1);
  N := EnsureRange(Ceil(Sqrt(0.75 * Dd / Max(FTolerance, 1E-4))), 1, 256);
  for K := 1 to N do
  begin
    T := K / N;
    U := 1 - T;
    A := U * U;
    B := 2 * W * U * T;
    C := T * T;
    D := A + B + C;
    Q.X := (A * P0.X + B * P1.X + C * P2.X) / D;
    Q.Y := (A * P0.Y + B * P1.Y + C * P2.Y) / D;
    Edge(FCur, Q);
    FCur := Q;
  end;
end;

end.
