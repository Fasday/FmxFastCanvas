unit FastCanvas.GeometryOwn;

{ FastCanvas's own engine of the CPU geometry (FastCanvas.Geometry): no library, every platform, the default on
  Android and Linux (elsewhere add this unit and set FastCanvasGeometryEngine := Own).

  Geometries are FMX path points (rectangles, rounded rectangles and ellipses as Direct2D builds them: from the same
  corner, the same way round, so that dash patterns start where they start there). Fills: the figures into the edge
  sink, curves flattened as densely as Direct2D flattens them. Stroke outlines are made here as the stock Direct2D
  canvas strokes (ID2D1Geometry.Widen): curves flattened so, and finer where the stroke is wide (the outer side of a
  curve is longer); dashes cut along the flattened figure (the patterns of Direct2D in stroke widths, the offset,
  started again with every figure; on a closed figure the last dash goes on into the first); then every dash or
  figure is outlined as one polygon, a ribbon along it (a closed figure: two loops, one per side). At the vertices of
  the path the outer side gets the join (miter, clipped at 10 half widths from the vertex as Direct2D's miter join;
  round; bevel), the inner side goes through the vertex itself, as Direct2D's outlines do: the ribbon then overlaps
  itself there, and the non-zero rule covers the union, so that a stroke of any width is outlined correctly. At the
  points of a flattened curve (and where one curve goes on into another) the sides take the offset points of the
  normal there, unless the stroke is wider than the curve's segments allow (then round on the outer side and through
  the point on the inner one). Open figures get their caps (square for FMX's flat ones, round) square to the curve's
  tangent, a figure of no length a dot; the corners of a rectangle are outlined exactly, as Direct2D does. Contains
  tests a point against the flattened figures with the path's fill rule. Compared with Direct2D on the CPU by
  src\Probe\GeometryProbe.dpr. }

interface

uses
  System.Types, System.SysUtils, System.Math, FMX.Graphics, FastCanvas.Geometry;

type
  TFastGeometryOwn = class(TFastGeometryEngine)
  private
    { The stroke of the outline being made. }
    FSink: TFastEdgeSink;
    FHalf, FTol: Single;
    FCap, FJoin: Byte;
    { The outline of a rectangle without dashes: corners outlined exactly (no overlap), as Direct2D does. }
    FExact: Boolean;
    { The flattened figure; Smooth: a point inside a flattened curve (not a vertex of the path). }
    FPts: TArray<TPointF>;
    FSmooth: TArray<Boolean>;
    FCount: Integer;
    { The piece being outlined (a figure or a dash): its points, their segments' directions and lengths; per vertex
      the inner side (+1: A, -1: B, 0: straight on), how far back from the vertex the inner offset lines meet, and
      whether the inner side takes that point (else it goes through the vertex). }
    FPiece: TArray<TPointF>;
    FPieceSmooth: TArray<Boolean>;
    FPieceCount: Integer;
    FDir: TArray<TPointF>;
    FLen: TArray<Single>;
    FTrim: TArray<Single>;
    FSide: TArray<ShortInt>;
    FMeet: TArray<Boolean>;
    { The two sides of the piece: A on the side of the normal (-dy, dx) of the direction, B on the other. }
    FA, FB: TArray<TPointF>;
    FACount, FBCount: Integer;
    FPoly: TArray<TPointF>;
    FPolyCount: Integer;
    { The dash pattern in path units, and dashes made of the figure so far. The first dash of a closed figure, held
      for the last one, and its direction at its end. }
    FPattern: TArray<Single>;
    FDashes: Integer;
    FFirst: TArray<TPointF>;
    FFirstSmooth: TArray<Boolean>;
    FFirstEndTan: TPointF;
    { The segments of the figure being dashed: directions, lengths, turns (and how many turns were added up). }
    FSegDir: TArray<TPointF>;
    FSegLen, FSegTurn: TArray<Single>;
    FSegTurns: TArray<Integer>;
    FSegReady: Boolean;
    { Flattening for Contains. }
    FHitSink: TFastEdgeSink;
    procedure AddPoint(const P: TPointF; const ASmooth: Boolean);
    procedure AddCubic(const P0, P1, P2, P3: TPointF);
    procedure AddPiecePoint(const P: TPointF; const ASmooth: Boolean);
    procedure AddA(const P: TPointF); inline;
    procedure AddB(const P: TPointF); inline;
    procedure AddPoly(const P: TPointF); inline;
    procedure Put(const P: TPointF; const ASide: ShortInt); inline;
    procedure AddArc(const C: TPointF; const AFrom: TPointF; const AAngle: Single; const ASide: ShortInt);
    procedure OuterJoin(const P: TPointF; const D0, D1: TPointF; const ASide: ShortInt; const AJoin: Byte);
    procedure Vertex(const V, APrev, ANext: Integer);
    procedure Dot(const P, D: TPointF);
    procedure EmitPoly;
    procedure EmitOpen(const AStart, AEnd, AStartDir, AEndDir: TPointF);
    procedure PrepareSegments(const AClosed: Boolean);
    function FigureDir(const ASeg: Integer): TPointF;
    function SegmentTurn(const ASeg: Integer; const AClosed: Boolean): Single;
    function FigureTangent(const ASeg: Integer; const AAt: Single; const AClosed: Boolean): TPointF;
    procedure StrokePiece(const AClosed, ADot: Boolean; const AStartTan, AEndTan: TPointF);
    procedure DashFigure(const AClosed: Boolean; const AStartIndex: Integer; const AStartRemain: Single);
  public
    constructor Create; override;
    destructor Destroy; override;
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

implementation

const
  /// <summary>The arc of a quarter circle as a cubic: control points at this share of the radius.</summary>
  Kappa = 0.5522847498;
  /// <summary>Direct2D's miter limit of the stock canvas: the miter tip at most this many half widths from the
  /// vertex.</summary>
  MiterLimit = 10;
  /// <summary>Curves of paths are flattened to this share of the tolerance (with the edge sink's formula: about 1.3
  /// times its segments): as densely as Direct2D flattens them, whose fills, outlines and dash positions are matched
  /// best so (src\Probe\GeometryProbe.dpr). Round joins and caps take the tolerance as it is, as Direct2D's.
  /// </summary>
  Flatness = 0.6;
  /// <summary>Dashes of one stroke at most (a dash pattern far finer than the path): about 500 000 edges, within what
  /// the canvas draws of one path (GpuEdgesLimit).</summary>
  MaxDashes = 50000;

type
  /// <summary>The figures of a geometry as FMX path points, and its fill rule.</summary>
  TOwnGeometry = class(TInterfacedObject, IFastGeometry)
  public
    Points: TArray<TPathPoint>;
    Count: Integer;
    Winding: Boolean;
    /// <summary>A rectangle (Rectangle).</summary>
    Rect: Boolean;
    procedure Add(const AKind: TPathPointKind; const X, Y: Single);
  end;

procedure TOwnGeometry.Add(const AKind: TPathPointKind; const X, Y: Single);
begin
  if Count = Length(Points) then
    SetLength(Points, Max(16, 2 * Count));
  Points[Count].Kind := AKind;
  Points[Count].Point := TPointF.Create(X, Y);
  Inc(Count);
end;

function Own(const AGeometry: IFastGeometry): TOwnGeometry;
var
  O: TObject;
begin
  Result := nil;
  if AGeometry <> nil then
  begin
    O := AGeometry as TObject;
    if O is TOwnGeometry then
      Result := TOwnGeometry(O);
  end;
end;

function Cross(const A, B: TPointF): Single; inline;
begin
  Result := A.X * B.Y - A.Y * B.X;
end;

function Dot2(const A, B: TPointF): Single; inline;
begin
  Result := A.X * B.X + A.Y * B.Y;
end;

/// <summary>The normal of side A of a direction: the direction turned by +90 degrees ((x, y) to (-y, x)).</summary>
function Normal(const D: TPointF): TPointF; inline;
begin
  Result.X := -D.Y;
  Result.Y := D.X;
end;

/// <summary>P + N * H.</summary>
function Offset(const P, N: TPointF; const H: Single): TPointF; inline;
begin
  Result.X := P.X + N.X * H;
  Result.Y := P.Y + N.Y * H;
end;

{ TFastGeometryOwn: geometries }

constructor TFastGeometryOwn.Create;
begin
  inherited Create;
  FHitSink := TFastEdgeSink.Create;
end;

destructor TFastGeometryOwn.Destroy;
begin
  FHitSink.Free;
  inherited;
end;

function TFastGeometryOwn.Path(const APoints: PFastPathPoints; const ACount: Integer;
  const AWinding: Boolean): IFastGeometry;
var
  G: TOwnGeometry;
begin
  G := TOwnGeometry.Create;
  SetLength(G.Points, ACount);
  if ACount > 0 then
    Move(APoints[0], G.Points[0], ACount * SizeOf(TPathPoint));
  G.Count := ACount;
  G.Winding := AWinding;
  Result := G;
end;

function TFastGeometryOwn.Rectangle(const R: TRectF): IFastGeometry;
var
  G: TOwnGeometry;
begin
  // From the top left corner, clockwise on screen, as Direct2D's rectangles.
  G := TOwnGeometry.Create;
  SetLength(G.Points, 5);
  G.Add(TPathPointKind.MoveTo, R.Left, R.Top);
  G.Add(TPathPointKind.LineTo, R.Right, R.Top);
  G.Add(TPathPointKind.LineTo, R.Right, R.Bottom);
  G.Add(TPathPointKind.LineTo, R.Left, R.Bottom);
  G.Add(TPathPointKind.Close, 0, 0);
  G.Rect := True;
  Result := G;
end;

function TFastGeometryOwn.RoundedRectangle(const R: TRectF; const ARx, ARy: Single): IFastGeometry;
var
  G: TOwnGeometry;
  Rx, Ry, X0, Y0, X1, Y1, Kx, Ky: Single;
begin
  Rx := Min(Abs(ARx), Abs(R.Width) / 2);
  Ry := Min(Abs(ARy), Abs(R.Height) / 2);
  if (Rx <= 0) or (Ry <= 0) then
    Exit(Rectangle(R));
  X0 := Min(R.Left, R.Right);
  X1 := Max(R.Left, R.Right);
  Y0 := Min(R.Top, R.Bottom);
  Y1 := Max(R.Top, R.Bottom);
  Kx := Rx * (1 - Kappa);
  Ky := Ry * (1 - Kappa);
  // Clockwise on screen from the top of the left side, as Direct2D's rounded rectangles.
  G := TOwnGeometry.Create;
  SetLength(G.Points, 17);
  G.Add(TPathPointKind.MoveTo, X0, Y0 + Ry);
  G.Add(TPathPointKind.CurveTo, X0, Y0 + Ky);
  G.Add(TPathPointKind.CurveTo, X0 + Kx, Y0);
  G.Add(TPathPointKind.CurveTo, X0 + Rx, Y0);
  G.Add(TPathPointKind.LineTo, X1 - Rx, Y0);
  G.Add(TPathPointKind.CurveTo, X1 - Kx, Y0);
  G.Add(TPathPointKind.CurveTo, X1, Y0 + Ky);
  G.Add(TPathPointKind.CurveTo, X1, Y0 + Ry);
  G.Add(TPathPointKind.LineTo, X1, Y1 - Ry);
  G.Add(TPathPointKind.CurveTo, X1, Y1 - Ky);
  G.Add(TPathPointKind.CurveTo, X1 - Kx, Y1);
  G.Add(TPathPointKind.CurveTo, X1 - Rx, Y1);
  G.Add(TPathPointKind.LineTo, X0 + Rx, Y1);
  G.Add(TPathPointKind.CurveTo, X0 + Kx, Y1);
  G.Add(TPathPointKind.CurveTo, X0, Y1 - Ky);
  G.Add(TPathPointKind.CurveTo, X0, Y1 - Ry);
  G.Add(TPathPointKind.Close, 0, 0);
  Result := G;
end;

function TFastGeometryOwn.Ellipse(const R: TRectF): IFastGeometry;
var
  G: TOwnGeometry;
  Cx, Cy, Rx, Ry, Kx, Ky: Single;
begin
  Cx := (R.Left + R.Right) / 2;
  Cy := (R.Top + R.Bottom) / 2;
  Rx := Abs(R.Width) / 2;
  Ry := Abs(R.Height) / 2;
  Kx := Rx * Kappa;
  Ky := Ry * Kappa;
  // Clockwise on screen from the leftmost point, as Direct2D's ellipses.
  G := TOwnGeometry.Create;
  SetLength(G.Points, 14);
  G.Add(TPathPointKind.MoveTo, Cx - Rx, Cy);
  G.Add(TPathPointKind.CurveTo, Cx - Rx, Cy - Ky);
  G.Add(TPathPointKind.CurveTo, Cx - Kx, Cy - Ry);
  G.Add(TPathPointKind.CurveTo, Cx, Cy - Ry);
  G.Add(TPathPointKind.CurveTo, Cx + Kx, Cy - Ry);
  G.Add(TPathPointKind.CurveTo, Cx + Rx, Cy - Ky);
  G.Add(TPathPointKind.CurveTo, Cx + Rx, Cy);
  G.Add(TPathPointKind.CurveTo, Cx + Rx, Cy + Ky);
  G.Add(TPathPointKind.CurveTo, Cx + Kx, Cy + Ry);
  G.Add(TPathPointKind.CurveTo, Cx, Cy + Ry);
  G.Add(TPathPointKind.CurveTo, Cx - Kx, Cy + Ry);
  G.Add(TPathPointKind.CurveTo, Cx - Rx, Cy + Ky);
  G.Add(TPathPointKind.CurveTo, Cx - Rx, Cy);
  G.Add(TPathPointKind.Close, 0, 0);
  Result := G;
end;

function TFastGeometryOwn.Line(const AP0, AP1: TPointF): IFastGeometry;
var
  G: TOwnGeometry;
begin
  G := TOwnGeometry.Create;
  SetLength(G.Points, 2);
  G.Add(TPathPointKind.MoveTo, AP0.X, AP0.Y);
  G.Add(TPathPointKind.LineTo, AP1.X, AP1.Y);
  Result := G;
end;

/// <summary>The figures of a geometry into a sink, as Direct2D builds paths: MoveTo starts a figure, LineTo and
/// CurveTo (three points) outside a figure are left out, Close and the end close it (fills close every figure).
/// </summary>
procedure FigureEdges(const G: TOwnGeometry; const ASink: TFastEdgeSink);
var
  I, K, N: Integer;
  Open: Boolean;
  P0, P1, P2, P3, Q: TPointF;
  Dd, T, U: Single;
begin
  Open := False;
  P0 := TPointF.Zero;
  I := 0;
  while I < G.Count do
  begin
    case G.Points[I].Kind of
      TPathPointKind.MoveTo:
        begin
          P0 := G.Points[I].Point;
          ASink.BeginFigure(P0);
          Open := True;
        end;
      TPathPointKind.LineTo:
        if Open then
        begin
          P0 := G.Points[I].Point;
          ASink.LineTo(P0);
        end;
      TPathPointKind.CurveTo:
        begin
          if Open and (I + 2 < G.Count) then
          begin
            P1 := G.Points[I].Point;
            P2 := G.Points[I + 1].Point;
            P3 := G.Points[I + 2].Point;
            Dd := Max(Sqrt(Sqr(P0.X - 2 * P1.X + P2.X) + Sqr(P0.Y - 2 * P1.Y + P2.Y)),
              Sqrt(Sqr(P1.X - 2 * P2.X + P3.X) + Sqr(P1.Y - 2 * P2.Y + P3.Y)));
            N := EnsureRange(Ceil(Sqrt(0.75 * Dd / Max(ASink.Tolerance * Flatness, 1E-4))), 1, 1024);
            for K := 1 to N do
            begin
              T := K / N;
              U := 1 - T;
              Q.X := U * U * U * P0.X + 3 * U * U * T * P1.X + 3 * U * T * T * P2.X + T * T * T * P3.X;
              Q.Y := U * U * U * P0.Y + 3 * U * U * T * P1.Y + 3 * U * T * T * P2.Y + T * T * T * P3.Y;
              ASink.LineTo(Q);
            end;
            P0 := P3;
          end;
          Inc(I, 2);
        end;
      TPathPointKind.Close:
        begin
          ASink.CloseFigure;
          Open := False;
        end;
    end;
    Inc(I);
  end;
  ASink.CloseFigure;
end;

function TFastGeometryOwn.Flatten(const AGeometry: IFastGeometry; const ASink: TFastEdgeSink): Boolean;
var
  G: TOwnGeometry;
begin
  G := Own(AGeometry);
  if G = nil then
    Exit(False);
  ASink.EvenOdd := not G.Winding;
  FigureEdges(G, ASink);
  Result := True;
end;

function TFastGeometryOwn.Contains(const AGeometry: IFastGeometry; const APoint: TPointF): Boolean;
var
  G: TOwnGeometry;
  I, Winding, Crossings: Integer;
  E: TFastEdge;
  X: Single;
begin
  G := Own(AGeometry);
  if G = nil then
    Exit(False);
  // Flattened as Direct2D's FillContainsPoint flattens by default (D2D1_DEFAULT_FLATTENING_TOLERANCE).
  FHitSink.Reset(0.25, True);
  FigureEdges(G, FHitSink);
  Winding := 0;
  Crossings := 0;
  for I := 0 to FHitSink.Count - 1 do
  begin
    E := FHitSink.Edges[I];
    if (E.Y0 <= APoint.Y) <> (E.Y1 <= APoint.Y) then
    begin
      X := E.X0 + (APoint.Y - E.Y0) * (E.X1 - E.X0) / (E.Y1 - E.Y0);
      if X > APoint.X then
      begin
        Inc(Crossings);
        if E.Y1 > E.Y0 then
          Inc(Winding)
        else
          Dec(Winding);
      end;
    end;
  end;
  if G.Winding then
    Result := Winding <> 0
  else
    Result := Odd(Crossings);
end;

{ TFastGeometryOwn: stroke outlines }

procedure TFastGeometryOwn.AddPoint(const P: TPointF; const ASmooth: Boolean);
var
  Q: TPointF;
  Eps: Single;
begin
  if FCount > 0 then
  begin
    // Coincident points (segments of no length) have no direction: one point, a vertex if either is one.
    Q := FPts[FCount - 1];
    Eps := FTol * 1E-3;
    if (Abs(P.X - Q.X) <= Eps) and (Abs(P.Y - Q.Y) <= Eps) then
    begin
      if not ASmooth then
        FSmooth[FCount - 1] := False;
      Exit;
    end;
  end;
  if FCount = Length(FPts) then
  begin
    SetLength(FPts, Max(64, 2 * FCount));
    SetLength(FSmooth, Length(FPts));
  end;
  FPts[FCount] := P;
  FSmooth[FCount] := ASmooth;
  Inc(FCount);
end;

procedure TFastGeometryOwn.AddCubic(const P0, P1, P2, P3: TPointF);
var
  K, N, NA: Integer;
  Dd, T, U, Turning, A, Step: Single;
  Q, D, Prev: TPointF;
  HasPrev: Boolean;
begin
  // Segments for the tolerance (from the second differences, as the edge sink flattens), and for the outer side
  // of a wide stroke: a turn of Phi per segment puts the outline Half * Phi^2 / 8 inside the curve's offset.
  Dd := Max(Sqrt(Sqr(P0.X - 2 * P1.X + P2.X) + Sqr(P0.Y - 2 * P1.Y + P2.Y)),
    Sqrt(Sqr(P1.X - 2 * P2.X + P3.X) + Sqr(P1.Y - 2 * P2.Y + P3.Y)));
  N := Ceil(Sqrt(0.75 * Dd / (FTol * Flatness)));
  Step := Sqrt(8 * FTol / Max(FHalf, 1E-6));
  // (A cubic turns by less than two full turns.)
  if (FHalf > FTol) and (N * Step < 2 * Pi) then
  begin
    // The tangent's turning, from four samples of the derivative.
    Turning := 0;
    HasPrev := False;
    Prev := TPointF.Zero;
    for K := 0 to 3 do
    begin
      T := K / 3;
      U := 1 - T;
      D.X := U * U * (P1.X - P0.X) + 2 * U * T * (P2.X - P1.X) + T * T * (P3.X - P2.X);
      D.Y := U * U * (P1.Y - P0.Y) + 2 * U * T * (P2.Y - P1.Y) + T * T * (P3.Y - P2.Y);
      if (D.X = 0) and (D.Y = 0) then
        Continue;
      if HasPrev then
        Turning := Turning + Abs(ArcTan2(Cross(Prev, D), Dot2(Prev, D)));
      Prev := D;
      HasPrev := True;
    end;
    A := Turning / Step;
    if A > 1024 then
      NA := 1024
    else
      NA := Ceil(A);
    N := Max(N, NA);
  end;
  N := EnsureRange(N, 1, 1024);
  for K := 1 to N do
  begin
    T := K / N;
    U := 1 - T;
    Q.X := U * U * U * P0.X + 3 * U * U * T * P1.X + 3 * U * T * T * P2.X + T * T * T * P3.X;
    Q.Y := U * U * U * P0.Y + 3 * U * U * T * P1.Y + 3 * U * T * T * P2.Y + T * T * T * P3.Y;
    // The curve's end is a vertex of the path.
    AddPoint(Q, K < N);
  end;
end;

procedure TFastGeometryOwn.AddPiecePoint(const P: TPointF; const ASmooth: Boolean);
var
  Q: TPointF;
  Eps: Single;
begin
  if FPieceCount > 0 then
  begin
    Q := FPiece[FPieceCount - 1];
    Eps := FTol * 1E-3;
    if (Abs(P.X - Q.X) <= Eps) and (Abs(P.Y - Q.Y) <= Eps) then
    begin
      if not ASmooth then
        FPieceSmooth[FPieceCount - 1] := False;
      Exit;
    end;
  end;
  if FPieceCount = Length(FPiece) then
  begin
    SetLength(FPiece, Max(64, 2 * FPieceCount));
    SetLength(FPieceSmooth, Length(FPiece));
  end;
  FPiece[FPieceCount] := P;
  FPieceSmooth[FPieceCount] := ASmooth;
  Inc(FPieceCount);
end;

procedure TFastGeometryOwn.AddA(const P: TPointF);
begin
  if FACount = Length(FA) then
    SetLength(FA, Max(64, 2 * FACount));
  FA[FACount] := P;
  Inc(FACount);
end;

procedure TFastGeometryOwn.AddB(const P: TPointF);
begin
  if FBCount = Length(FB) then
    SetLength(FB, Max(64, 2 * FBCount));
  FB[FBCount] := P;
  Inc(FBCount);
end;

procedure TFastGeometryOwn.AddPoly(const P: TPointF);
begin
  if FPolyCount = Length(FPoly) then
    SetLength(FPoly, Max(64, 2 * FPolyCount));
  FPoly[FPolyCount] := P;
  Inc(FPolyCount);
end;

/// <summary>A point to side A (ASide > 0), side B (< 0) or the polygon FPoly (0).</summary>
procedure TFastGeometryOwn.Put(const P: TPointF; const ASide: ShortInt);
begin
  if ASide > 0 then
    AddA(P)
  else if ASide < 0 then
    AddB(P)
  else
    AddPoly(P);
end;

/// <summary>The points of an arc of radius FHalf around C, from the direction AFrom (a unit vector) turned by AAngle
/// (signed, radians; as from x towards y), its ends left out, to ASide (as Put). As Direct2D makes round caps and
/// joins: cubic arcs of at most a quarter circle, each flattened to the tolerance as the edge sink flattens curves.
/// </summary>
procedure TFastGeometryOwn.AddArc(const C: TPointF; const AFrom: TPointF; const AAngle: Single;
  const ASide: ShortInt);
var
  M, J, N, K: Integer;
  Beta, Co, Si, Handle, Dd, T, U: Single;
  U0, U1, P0, P1, P2, P3: TPointF;
begin
  M := Max(1, Ceil(Abs(AAngle) / (Pi / 2) - 1E-4));
  Beta := AAngle / M;
  Co := Cos(Beta);
  Si := Sin(Beta);
  Handle := 4 / 3 * Tan(Beta / 4) * FHalf;
  U0 := AFrom;
  for J := 0 to M - 1 do
  begin
    U1 := TPointF.Create(U0.X * Co - U0.Y * Si, U0.X * Si + U0.Y * Co);
    P0 := Offset(C, U0, FHalf);
    P3 := Offset(C, U1, FHalf);
    // The tangents of the arc as the angle grows: the radii turned by +90 degrees.
    P1 := Offset(P0, Normal(U0), Handle);
    P2 := Offset(P3, Normal(U1), -Handle);
    Dd := Max(Sqrt(Sqr(P0.X - 2 * P1.X + P2.X) + Sqr(P0.Y - 2 * P1.Y + P2.Y)),
      Sqrt(Sqr(P1.X - 2 * P2.X + P3.X) + Sqr(P1.Y - 2 * P2.Y + P3.Y)));
    N := EnsureRange(Ceil(Sqrt(0.75 * Dd / FTol)), 1, 256);
    for K := 1 to N do
    begin
      if (J = M - 1) and (K = N) then
        Break;
      T := K / N;
      U := 1 - T;
      Put(TPointF.Create(U * U * U * P0.X + 3 * U * U * T * P1.X + 3 * U * T * T * P2.X + T * T * T * P3.X,
        U * U * U * P0.Y + 3 * U * U * T * P1.Y + 3 * U * T * T * P2.Y + T * T * T * P3.Y), ASide);
    end;
    U0 := U1;
  end;
end;

/// <summary>The join AJoin at the vertex P (from the direction D0 to D1) on its outer side ASide: the points between
/// the end of the previous segment's offset and the start of the next one's.</summary>
procedure TFastGeometryOwn.OuterJoin(const P: TPointF; const D0, D1: TPointF; const ASide: ShortInt;
  const AJoin: Byte);
var
  N0, N1, E0, S1: TPointF;
  C, Dt, CosHalf, SinHalf, T, U, Angle: Single;
begin
  N0 := Normal(D0) * ASide;
  N1 := Normal(D1) * ASide;
  E0 := Offset(P, N0, FHalf);
  S1 := Offset(P, N1, FHalf);
  C := Cross(D0, D1);
  Dt := EnsureRange(Dot2(D0, D1), -1, 1);
  CosHalf := Sqrt((1 + Dt) / 2);
  SinHalf := Sqrt((1 - Dt) / 2);
  // A turn whose join styles differ by less than the tolerance: the miter point.
  if (CosHalf > 1E-6) and (FHalf * (1 / CosHalf - 1) <= FTol) then
  begin
    T := FHalf * SinHalf / CosHalf;
    Put(TPointF.Create(E0.X + D0.X * T, E0.Y + D0.Y * T), ASide);
    Exit;
  end;
  case AJoin of
    1:
      begin
        // Round: the arc from N0 to N1 round the outside; a full reversal round the front.
        if (C = 0) and (Dt < 0) then
        begin
          Angle := Pi;
          if Cross(N0, D0) < 0 then
            Angle := -Pi;
        end
        else
        begin
          Angle := ArcTan2(Abs(C), Dt);
          if Cross(N0, N1) < 0 then
            Angle := -Angle;
        end;
        Put(E0, ASide);
        AddArc(P, N0, Angle, ASide);
        Put(S1, ASide);
      end;
    2:
      begin
        Put(E0, ASide);
        Put(S1, ASide);
      end;
  else
    if (CosHalf > 1E-6) and (1 / CosHalf <= MiterLimit) then
    begin
      T := FHalf * SinHalf / CosHalf;
      Put(TPointF.Create(E0.X + D0.X * T, E0.Y + D0.Y * T), ASide);
    end
    else
    begin
      // Clipped MiterLimit half widths from the vertex, as Direct2D's miter join.
      U := FHalf * (MiterLimit - CosHalf) / Max(SinHalf, 1E-6);
      Put(E0, ASide);
      Put(TPointF.Create(E0.X + D0.X * U, E0.Y + D0.Y * U), ASide);
      Put(TPointF.Create(S1.X - D1.X * U, S1.Y - D1.Y * U), ASide);
      Put(S1, ASide);
    end;
  end;
end;

/// <summary>The points of the vertex V of the piece (segments APrev before it, ANext after it). A vertex of the path:
/// the join on the outer side, the inner side through the vertex. A point of a flattened curve: the offset points of
/// the curve's normal there (the bisector of the segments) where the inner side does not fold back, else round on
/// the outer side and through the point on the inner one.</summary>
procedure TFastGeometryOwn.Vertex(const V, APrev, ANext: Integer);
var
  P, D0, D1: TPointF;
  Inner: ShortInt;
  TX, TY, L, H: Single;
begin
  Inner := FSide[V];
  if Inner = 0 then
    Exit;
  P := FPiece[V];
  D0 := FDir[APrev];
  D1 := FDir[ANext];
  if FMeet[V] then
  begin
    // The normal of the bisector, Half long.
    TX := D0.X + D1.X;
    TY := D0.Y + D1.Y;
    L := TX * TX + TY * TY;
    if FExact and not FPieceSmooth[V] then
    begin
      // A corner of a rectangle: the inner offset lines' meeting point and the join, as Direct2D outlines them.
      H := FHalf * Inner;
      Put(TPointF.Create(P.X - D0.Y * H - D0.X * FTrim[V], P.Y + D0.X * H - D0.Y * FTrim[V]), Inner);
      OuterJoin(P, D0, D1, -Inner, FJoin);
      Exit;
    end;
    if L > 1E-12 then
    begin
      L := FHalf / Sqrt(L);
      AddA(TPointF.Create(P.X - TY * L, P.Y + TX * L));
      AddB(TPointF.Create(P.X + TY * L, P.Y - TX * L));
      Exit;
    end;
  end;
  // Through the vertex: the ribbon overlaps itself on the inner side (the non-zero rule covers it).
  H := FHalf * Inner;
  Put(TPointF.Create(P.X - D0.Y * H, P.Y + D0.X * H), Inner);
  Put(P, Inner);
  Put(TPointF.Create(P.X - D1.Y * H, P.Y + D1.X * H), Inner);
  if FPieceSmooth[V] then
    OuterJoin(P, D0, D1, -Inner, 1)
  else
    OuterJoin(P, D0, D1, -Inner, FJoin);
end;

/// <summary>A dash or figure of no length at P (direction D): a square (square caps, along D) or a circle.</summary>
procedure TFastGeometryOwn.Dot(const P, D: TPointF);
var
  N, Dd: TPointF;
begin
  if FCap > 1 then
    Exit;
  Dd := D;
  if (Dd.X = 0) and (Dd.Y = 0) then
    Dd := TPointF.Create(1, 0);
  N := Normal(Dd);
  FPolyCount := 0;
  if FCap = 1 then
  begin
    AddPoly(Offset(P, N, FHalf));
    AddArc(P, N, Pi, 0);
    AddPoly(Offset(P, N, -FHalf));
    AddArc(P, -N, Pi, 0);
  end
  else
  begin
    AddPoly(TPointF.Create(P.X + (N.X - Dd.X) * FHalf, P.Y + (N.Y - Dd.Y) * FHalf));
    AddPoly(TPointF.Create(P.X + (N.X + Dd.X) * FHalf, P.Y + (N.Y + Dd.Y) * FHalf));
    AddPoly(TPointF.Create(P.X + (-N.X + Dd.X) * FHalf, P.Y + (-N.Y + Dd.Y) * FHalf));
    AddPoly(TPointF.Create(P.X + (-N.X - Dd.X) * FHalf, P.Y + (-N.Y - Dd.Y) * FHalf));
  end;
  EmitPoly;
end;

/// <summary>FPoly into the sink, turned the way the ribbons run (a negative area in y-down coordinates).</summary>
procedure TFastGeometryOwn.EmitPoly;
var
  I, J: Integer;
  A: Double;
begin
  if FPolyCount < 3 then
    Exit;
  A := 0;
  J := FPolyCount - 1;
  for I := 0 to FPolyCount - 1 do
  begin
    A := A + (Double(FPoly[J].X) * FPoly[I].Y - Double(FPoly[I].X) * FPoly[J].Y);
    J := I;
  end;
  if A = 0 then
    Exit;
  if A < 0 then
  begin
    FSink.BeginFigure(FPoly[0]);
    for I := 1 to FPolyCount - 1 do
      FSink.LineTo(FPoly[I]);
  end
  else
  begin
    FSink.BeginFigure(FPoly[FPolyCount - 1]);
    for I := FPolyCount - 2 downto 0 do
      FSink.LineTo(FPoly[I]);
  end;
  FSink.CloseFigure;
end;

/// <summary>The ribbon of an open piece: side A, the end cap, side B backwards, the start cap.</summary>
procedure TFastGeometryOwn.EmitOpen(const AStart, AEnd, AStartDir, AEndDir: TPointF);
var
  I: Integer;
  N: TPointF;
begin
  FSink.BeginFigure(FA[0]);
  for I := 1 to FACount - 1 do
    FSink.LineTo(FA[I]);
  N := Normal(AEndDir);
  FPolyCount := 0;
  if FCap = 1 then
    AddArc(AEnd, N, -Pi, 0)
  else if FCap = 0 then
  begin
    AddPoly(TPointF.Create(AEnd.X + (N.X + AEndDir.X) * FHalf, AEnd.Y + (N.Y + AEndDir.Y) * FHalf));
    AddPoly(TPointF.Create(AEnd.X + (-N.X + AEndDir.X) * FHalf, AEnd.Y + (-N.Y + AEndDir.Y) * FHalf));
  end;
  for I := 0 to FPolyCount - 1 do
    FSink.LineTo(FPoly[I]);
  for I := FBCount - 1 downto 0 do
    FSink.LineTo(FB[I]);
  N := Normal(AStartDir);
  FPolyCount := 0;
  if FCap = 1 then
    AddArc(AStart, -N, -Pi, 0)
  else if FCap = 0 then
  begin
    AddPoly(TPointF.Create(AStart.X + (-N.X - AStartDir.X) * FHalf, AStart.Y + (-N.Y - AStartDir.Y) * FHalf));
    AddPoly(TPointF.Create(AStart.X + (N.X - AStartDir.X) * FHalf, AStart.Y + (N.Y - AStartDir.Y) * FHalf));
  end;
  for I := 0 to FPolyCount - 1 do
    FSink.LineTo(FPoly[I]);
  FSink.CloseFigure;
end;

/// <summary>The direction of the figure in FPts at AAt (0..1) of its segment ASeg: the segment's, turned as a curve
/// turns where the segment is part of a flattened one (by its share of the turns at the curve's points next to it).
/// </summary>
function TFastGeometryOwn.FigureTangent(const ASeg: Integer; const AAt: Single; const AClosed: Boolean): TPointF;
var
  D: TPointF;
  A, Co, Si: Single;
begin
  if FCount < 2 then
    Exit(TPointF.Create(1, 0));
  if FSegReady then
  begin
    D := FSegDir[ASeg mod FCount];
    A := FSegTurn[ASeg mod FCount] * (AAt - 0.5);
  end
  else
  begin
    D := FigureDir(ASeg);
    A := SegmentTurn(ASeg, AClosed) * (AAt - 0.5);
  end;
  if A = 0 then
    Exit(D);
  if Abs(A) < 0.5 then
  begin
    // (Within 3E-4 of the cosine and sine there.)
    Co := 1 - A * A * (0.5 - A * A / 24);
    Si := A * (1 - A * A / 6);
  end
  else
  begin
    Co := Cos(A);
    Si := Sin(A);
  end;
  Result := TPointF.Create(D.X * Co - D.Y * Si, D.X * Si + D.Y * Co);
end;

/// <summary>The directions, lengths and turns (SegmentTurn) of every segment of the figure in FPts, for the dashes
/// (FigureTangent takes them while FSegReady).</summary>
procedure TFastGeometryOwn.PrepareSegments(const AClosed: Boolean);
var
  N, I, J, V, P: Integer;
  E, D0, D1: TPointF;
  L, Turn: Single;
begin
  N := FCount;
  if Length(FSegDir) < N then
  begin
    SetLength(FSegDir, Max(N, 2 * Length(FSegDir)));
    SetLength(FSegLen, Length(FSegDir));
    SetLength(FSegTurn, Length(FSegDir));
    SetLength(FSegTurns, Length(FSegDir));
  end;
  for I := 0 to N - 1 do
  begin
    J := I + 1;
    if J = N then
      J := 0;
    E.X := FPts[J].X - FPts[I].X;
    E.Y := FPts[J].Y - FPts[I].Y;
    L := Sqrt(E.X * E.X + E.Y * E.Y);
    FSegLen[I] := L;
    if L > 0 then
      FSegDir[I] := TPointF.Create(E.X / L, E.Y / L)
    else
      FSegDir[I] := TPointF.Create(1, 0);
    FSegTurn[I] := 0;
    FSegTurns[I] := 0;
  end;
  if N >= 3 then
    for V := 0 to N - 1 do
      if FSmooth[V] and (AClosed or ((V > 0) and (V < N - 1))) then
      begin
        if V = 0 then
          P := N - 1
        else
          P := V - 1;
        D0 := FSegDir[P];
        D1 := FSegDir[V];
        Turn := ArcTan2(D0.X * D1.Y - D0.Y * D1.X, D0.X * D1.X + D0.Y * D1.Y);
        FSegTurn[P] := FSegTurn[P] + Turn;
        Inc(FSegTurns[P]);
        FSegTurn[V] := FSegTurn[V] + Turn;
        Inc(FSegTurns[V]);
      end;
  for I := 0 to N - 1 do
    if FSegTurns[I] > 1 then
      FSegTurn[I] := FSegTurn[I] / FSegTurns[I];
  FSegReady := True;
end;

/// <summary>The direction of the segment ASeg of the figure in FPts.</summary>
function TFastGeometryOwn.FigureDir(const ASeg: Integer): TPointF;
var
  E: TPointF;
  L: Single;
begin
  E := FPts[(ASeg + 1) mod FCount] - FPts[ASeg mod FCount];
  L := Sqrt(E.X * E.X + E.Y * E.Y);
  if L > 0 then
    Result := TPointF.Create(E.X / L, E.Y / L)
  else
    Result := TPointF.Create(1, 0);
end;

/// <summary>How far the curve that the segment ASeg of the figure in FPts stands for turns along it (signed,
/// radians): the mean of the turns at its ends that are points of a flattened curve; 0 for a line.</summary>
function TFastGeometryOwn.SegmentTurn(const ASeg: Integer; const AClosed: Boolean): Single;
var
  N, Turns: Integer;
  D, E: TPointF;
begin
  N := FCount;
  Result := 0;
  if N < 3 then
    Exit;
  D := FigureDir(ASeg);
  Turns := 0;
  if FSmooth[ASeg mod N] and (AClosed or (ASeg > 0)) then
  begin
    E := FigureDir((ASeg + N - 1) mod N);
    Result := Result + ArcTan2(Cross(E, D), Dot2(E, D));
    Inc(Turns);
  end;
  if FSmooth[(ASeg + 1) mod N] and (AClosed or (ASeg + 2 < N)) then
  begin
    E := FigureDir(ASeg + 1);
    Result := Result + ArcTan2(Cross(D, E), Dot2(D, E));
    Inc(Turns);
  end;
  if Turns > 0 then
    Result := Result / Turns;
end;

/// <summary>Outlines the piece in FPiece, an open one with its ends in the directions AStartTan and AEndTan. ADot: a
/// piece of no length gets a dot (direction AStartTan).</summary>
procedure TFastGeometryOwn.StrokePiece(const AClosed, ADot: Boolean; const AStartTan, AEndTan: TPointF);
var
  N, Segs, I, J, V, Prev, K: Integer;
  D, Nn, StartTan, EndTan, D0, D1: TPointF;
  L, C, Dt, Other: Single;
  Closed: Boolean;
begin
  N := FPieceCount;
  Closed := AClosed;
  if Closed and (N > 1) then
  begin
    // The closing segment is there already when the last point is the first.
    D := FPiece[N - 1] - FPiece[0];
    if (Abs(D.X) <= FTol * 1E-3) and (Abs(D.Y) <= FTol * 1E-3) then
      Dec(N);
  end;
  if N = 0 then
    Exit;
  if N = 1 then
  begin
    if ADot then
      Dot(FPiece[0], AStartTan);
    Exit;
  end;
  if Closed then
    Segs := N
  else
    Segs := N - 1;
  if Length(FDir) < Segs then
  begin
    SetLength(FDir, Max(Segs, 2 * Length(FDir)));
    SetLength(FLen, Length(FDir));
  end;
  if Length(FTrim) < N then
  begin
    SetLength(FTrim, Max(N, 2 * Length(FTrim)));
    SetLength(FSide, Length(FTrim));
    SetLength(FMeet, Length(FTrim));
  end;
  for I := 0 to Segs - 1 do
  begin
    J := I + 1;
    if J = N then
      J := 0;
    D.X := FPiece[J].X - FPiece[I].X;
    D.Y := FPiece[J].Y - FPiece[I].Y;
    L := Sqrt(D.X * D.X + D.Y * D.Y);
    FLen[I] := L;
    if L > 0 then
      FDir[I] := TPointF.Create(D.X / L, D.Y / L)
    else
      FDir[I] := TPointF.Create(1, 0);
  end;
  // The vertices: their inner side, and how far back from them the inner offset lines meet (Half * tan(Phi / 2) for
  // a turn by Phi).
  for V := 0 to N - 1 do
  begin
    FTrim[V] := 0;
    FSide[V] := 0;
    FMeet[V] := False;
    if not Closed and ((V = 0) or (V = N - 1)) then
      Continue;
    // The segment before the vertex (its other end: vertex Prev) and the one after it (V).
    if V = 0 then
      Prev := Segs - 1
    else
      Prev := V - 1;
    J := V + 1;
    if J = N then
      J := 0;
    D0 := FDir[Prev];
    D1 := FDir[V];
    C := D0.X * D1.Y - D0.Y * D1.X;
    Dt := D0.X * D1.X + D0.Y * D1.Y;
    if C > 0 then
      FSide[V] := 1
    else if (C < 0) or (Dt < 0) then
      // (A full reversal: either side; the join goes round the front.)
      FSide[V] := -1;
    if 1 + Dt > 1E-6 then
      FTrim[V] := FHalf * Abs(C) / (1 + Dt)
    else
      FTrim[V] := MaxSingle;
    // Points of curves, and vertices next to a curve whose join styles differ by less than the tolerance (a curve
    // going on into another: Half * (1 / cos(Phi / 2) - 1) <= Tolerance). Polylines keep their joins, as Direct2D's.
    FMeet[V] := (FSide[V] <> 0) and (FPieceSmooth[V] or FExact or ((FPieceSmooth[Prev] or FPieceSmooth[J]) and
      (1 + Dt > 1E-6) and (FHalf * (Sqrt(2 / (1 + Dt)) - 1) <= FTol)));
  end;
  // A point of a curve takes the meeting point where the trims of its segments' ends on the same side fit into them
  // (else the inner side would fold back: through the point then).
  for V := 0 to N - 1 do
    if FMeet[V] then
    begin
      if V = 0 then
        Prev := Segs - 1
      else
        Prev := V - 1;
      Other := 0;
      if FMeet[Prev] and (FSide[Prev] = FSide[V]) then
        Other := FTrim[Prev];
      if FTrim[V] + Other > FLen[Prev] then
        FMeet[V] := False;
      Other := 0;
      K := V + 1;
      if K = N then
        K := 0;
      if FMeet[K] and (FSide[K] = FSide[V]) then
        Other := FTrim[K];
      if FTrim[V] + Other > FLen[V] then
        FMeet[V] := False;
    end;
  FACount := 0;
  FBCount := 0;
  if not Closed then
  begin
    // The ends square to the given directions (a curve's tangent there, not its first or last segment's), unless a
    // dash ends at a vertex (within the tolerance of points): the direction of its segment there.
    StartTan := AStartTan;
    if Dot2(StartTan, FDir[0]) < 0.7 then
      StartTan := FDir[0];
    EndTan := AEndTan;
    if Dot2(EndTan, FDir[N - 2]) < 0.7 then
      EndTan := FDir[N - 2];
    Nn := Normal(StartTan);
    AddA(Offset(FPiece[0], Nn, FHalf));
    AddB(Offset(FPiece[0], Nn, -FHalf));
    for V := 1 to N - 2 do
      Vertex(V, V - 1, V);
    Nn := Normal(EndTan);
    AddA(Offset(FPiece[N - 1], Nn, FHalf));
    AddB(Offset(FPiece[N - 1], Nn, -FHalf));
    EmitOpen(FPiece[0], FPiece[N - 1], StartTan, EndTan);
    Exit;
  end;
  // Closed: two loops, side A forward and side B backwards.
  Vertex(0, Segs - 1, 0);
  for V := 1 to N - 1 do
    Vertex(V, V - 1, V);
  if FACount > 2 then
  begin
    FSink.BeginFigure(FA[0]);
    for I := 1 to FACount - 1 do
      FSink.LineTo(FA[I]);
    FSink.CloseFigure;
  end;
  if FBCount > 2 then
  begin
    FSink.BeginFigure(FB[FBCount - 1]);
    for I := FBCount - 2 downto 0 do
      FSink.LineTo(FB[I]);
    FSink.CloseFigure;
  end;
end;

/// <summary>The dashes of the figure in FPts: the pattern starts in its element AStartIndex with AStartRemain of it
/// left; each dash is outlined as an open piece with its caps.</summary>
procedure TFastGeometryOwn.DashFigure(const AClosed: Boolean; const AStartIndex: Integer; const AStartRemain: Single);
var
  K, Segs, I: Integer;
  Remain, L, Pos: Single;
  A, B, D, X, StartTan: TPointF;
  IsOn, Held: Boolean;
begin
  PrepareSegments(AClosed);
  K := AStartIndex;
  Remain := AStartRemain;
  IsOn := not Odd(K);
  FPieceCount := 0;
  StartTan := FigureTangent(0, 0, AClosed);
  FFirst := nil;
  // A closed figure that starts with a dash: that dash waits for the last one.
  Held := AClosed and IsOn;
  if IsOn then
    AddPiecePoint(FPts[0], False);
  if FCount = 1 then
  begin
    if IsOn then
      StrokePiece(False, True, StartTan, StartTan);
    Exit;
  end;
  if AClosed then
    Segs := FCount
  else
    Segs := FCount - 1;
  for I := 0 to Segs - 1 do
  begin
    A := FPts[I];
    B := FPts[(I + 1) mod FCount];
    L := FSegLen[I];
    if L <= 0 then
      Continue;
    D := FSegDir[I];
    Pos := 0;
    // The pattern's elements that end in this segment (lengths along the flattened figure, as Direct2D dashes).
    while L - Pos > Remain do
    begin
      Pos := Pos + Remain;
      X := TPointF.Create(A.X + D.X * Pos, A.Y + D.Y * Pos);
      if IsOn then
      begin
        AddPiecePoint(X, False);
        if Held then
        begin
          // The first dash of a closed figure, kept for the last one, which goes on into it as Direct2D strokes it.
          Held := False;
          FFirst := Copy(FPiece, 0, FPieceCount);
          FFirstSmooth := Copy(FPieceSmooth, 0, FPieceCount);
          FFirstEndTan := FigureTangent(I, Pos / L, AClosed);
        end
        else
          StrokePiece(False, True, StartTan, FigureTangent(I, Pos / L, AClosed));
        Inc(FDashes);
        if FDashes > MaxDashes then
          Exit;
      end
      else
        StartTan := FigureTangent(I, Pos / L, AClosed);
      FPieceCount := 0;
      if not IsOn then
        AddPiecePoint(X, False);
      K := (K + 1) mod Length(FPattern);
      Remain := FPattern[K];
      IsOn := not IsOn;
    end;
    Remain := Remain - (L - Pos);
    if IsOn then
      AddPiecePoint(B, FSmooth[(I + 1) mod FCount]);
  end;
  if IsOn and (FPieceCount > 0) then
  begin
    if Held then
      // One dash all round: the figure closed.
      StrokePiece(True, False, StartTan, StartTan)
    else if FFirst <> nil then
    begin
      // The last dash reaches the start: the first one goes on from it.
      for I := 1 to High(FFirst) do
        AddPiecePoint(FFirst[I], FFirstSmooth[I]);
      StrokePiece(False, True, StartTan, FFirstEndTan);
    end
    else
      StrokePiece(False, True, StartTan, FigureTangent(Segs - 1, 1, AClosed));
  end
  else if FFirst <> nil then
  begin
    FPieceCount := 0;
    for I := 0 to High(FFirst) do
      AddPiecePoint(FFirst[I], FFirstSmooth[I]);
    StrokePiece(False, True, FigureTangent(0, 0, AClosed), FFirstEndTan);
  end;
end;

function TFastGeometryOwn.Widen(const AGeometry: IFastGeometry; const AStroke: TFastStroke;
  const ASink: TFastEdgeSink): Boolean;
var
  G: TOwnGeometry;
  I, K, StartIndex: Integer;
  Open, Closed, Segment: Boolean;
  Cur: TPointF;
  Dashes: PSingle;
  Period, Phase, StartRemain: Single;

  procedure EndFigure;
  begin
    if FCount > 0 then
    begin
      // A closed figure that comes back to its start (a curve ending there) has its closing segment already.
      if Closed and (FCount > 1) and (Abs(FPts[FCount - 1].X - FPts[0].X) <= FTol * 1E-3) and
        (Abs(FPts[FCount - 1].Y - FPts[0].Y) <= FTol * 1E-3) then
        Dec(FCount);
      if Length(FPattern) > 0 then
      begin
        // A figure of no length is a dot where the pattern starts with a dash.
        if (FCount > 1) or Segment then
          DashFigure(Closed, StartIndex, StartRemain);
        FSegReady := False;
      end
      else
      begin
        // The figure's points are apart already.
        if Length(FPiece) < FCount then
        begin
          SetLength(FPiece, Length(FPts));
          SetLength(FPieceSmooth, Length(FPts));
        end;
        Move(FPts[0], FPiece[0], FCount * SizeOf(TPointF));
        Move(FSmooth[0], FPieceSmooth[0], FCount * SizeOf(Boolean));
        FPieceCount := FCount;
        StrokePiece(Closed, Segment, FigureTangent(0, 0, Closed), FigureTangent(Max(FCount - 2, 0), 1, Closed));
      end;
    end;
    FCount := 0;
    Segment := False;
  end;

begin
  G := Own(AGeometry);
  if (G = nil) or not (AStroke.Width > 0) then
    Exit(False);
  FSink := ASink;
  FSink.EvenOdd := False;
  FHalf := AStroke.Width / 2;
  FTol := Max(ASink.Tolerance, 1E-4);
  FCap := Min(AStroke.Cap, 1);
  FJoin := Min(AStroke.Join, 2);
  FDashes := 0;
  // The dash patterns of Direct2D's dash styles in stroke widths (Custom: the brush's lengths; an odd count taken
  // twice, as dashes and gaps alternate).
  case AStroke.Dash of
    1: FPattern := [2, 2];
    2: FPattern := [0, 2];
    3: FPattern := [2, 2, 0, 2];
    4: FPattern := [2, 2, 0, 2, 0, 2];
    5:
      begin
        SetLength(FPattern, AStroke.DashCount);
        Dashes := AStroke.Dashes;
        for I := 0 to AStroke.DashCount - 1 do
        begin
          FPattern[I] := Max(Dashes^, 0);
          Inc(Dashes);
        end;
        if Odd(Length(FPattern)) then
          FPattern := FPattern + FPattern;
        // Direct2D strokes a custom style without lengths solid, with flat caps.
        if Length(FPattern) = 0 then
          FCap := 2;
      end;
  else
    FPattern := nil;
  end;
  FExact := G.Rect and (FPattern = nil);
  StartIndex := 0;
  StartRemain := 0;
  if Length(FPattern) > 0 then
  begin
    Period := 0;
    for I := 0 to High(FPattern) do
    begin
      FPattern[I] := FPattern[I] * AStroke.Width;
      Period := Period + FPattern[I];
    end;
    if not (Period > 0) then
      FPattern := nil
    else
    begin
      // A positive offset moves the pattern towards the start of the figure.
      Phase := AStroke.DashOffset * AStroke.Width;
      Phase := Phase - Floor(Phase / Period) * Period;
      K := 0;
      while (Phase > 0) and (Phase >= FPattern[K]) do
      begin
        Phase := Phase - FPattern[K];
        K := (K + 1) mod Length(FPattern);
      end;
      StartIndex := K;
      StartRemain := FPattern[K] - Max(Phase, 0);
    end;
  end;
  FCount := 0;
  Open := False;
  Closed := False;
  Segment := False;
  Cur := TPointF.Zero;
  I := 0;
  while I < G.Count do
  begin
    case G.Points[I].Kind of
      TPathPointKind.MoveTo:
        begin
          Closed := False;
          EndFigure;
          Cur := G.Points[I].Point;
          AddPoint(Cur, False);
          Open := True;
        end;
      TPathPointKind.LineTo:
        if Open then
        begin
          Cur := G.Points[I].Point;
          AddPoint(Cur, False);
          Segment := True;
        end;
      TPathPointKind.CurveTo:
        begin
          if Open and (I + 2 < G.Count) then
          begin
            AddCubic(Cur, G.Points[I].Point, G.Points[I + 1].Point, G.Points[I + 2].Point);
            Cur := G.Points[I + 2].Point;
            Segment := True;
          end;
          Inc(I, 2);
        end;
      TPathPointKind.Close:
        if Open then
        begin
          Closed := True;
          Segment := True;
          EndFigure;
          Closed := False;
          Open := False;
        end;
    end;
    if FDashes > MaxDashes then
      Break;
    Inc(I);
  end;
  EndFigure;
  FSink := nil;
  Result := True;
end;

initialization
  FastRegisterGeometryEngine(TFastCanvasEngine.Own, TFastGeometryOwn);
end.
