unit FastCanvas.GeometryD2D;

{ The Direct2D engine of the CPU geometry (FastCanvas.Geometry), Windows only, the default there: geometries of the
  device's Direct2D factory; fills through ID2D1Geometry.Simplify, stroke outlines through Widen, so joins, caps and
  dashes are exactly Direct2D's (the stock canvas strokes with Direct2D). }

interface

uses
  Winapi.Windows, Winapi.D2D1, System.Types, System.SysUtils, System.Math, System.Generics.Collections,
  FMX.Graphics, FastCanvas.Geometry;

type
  /// <summary>The Direct2D geometry behind an IFastGeometry of this engine.</summary>
  IFastD2DGeometry = interface(IFastGeometry)
    ['{9B4E2C10-7F3A-4D6B-8E15-2A9C0D7F4B63}']
    function Geometry: ID2D1Geometry;
  end;

  TFastGeometryD2D = class(TFastGeometryEngine)
  private
    FAdapter: ID2D1SimplifiedGeometrySink;
    FAdapterObject: TObject;
    FStrokes: TDictionary<UInt64, ID2D1StrokeStyle>;
    procedure Target(const ASink: TFastEdgeSink);
  public
    constructor Create; override;
    destructor Destroy; override;
    function Path(const APoints: PFastPathPoints; const ACount: Integer; const AWinding: Boolean = False): IFastGeometry;
      override;
    function Rectangle(const R: TRectF): IFastGeometry; override;
    function RoundedRectangle(const R: TRectF; const ARx, ARy: Single): IFastGeometry; override;
    function Ellipse(const R: TRectF): IFastGeometry; override;
    function Line(const AP0, AP1: TPointF): IFastGeometry; override;
    function Flatten(const AGeometry: IFastGeometry; const ASink: TFastEdgeSink): Boolean; override;
    function Widen(const AGeometry: IFastGeometry; const AStroke: TFastStroke; const ASink: TFastEdgeSink): Boolean;
      override;
    function Contains(const AGeometry: IFastGeometry; const APoint: TPointF): Boolean; override;
  end;

/// <summary>The Direct2D stroke style of a stroke (not cached).</summary>
function FastD2DStrokeStyle(const AStroke: TFastStroke): ID2D1StrokeStyle;
/// <summary>The Direct2D geometry of a geometry of this engine, else nil.</summary>
function FastD2DGeometry(const AGeometry: IFastGeometry): ID2D1Geometry;

implementation

uses
  FastCanvas.Device;

type
  TD2DGeometry = class(TInterfacedObject, IFastGeometry, IFastD2DGeometry)
  private
    FGeometry: ID2D1Geometry;
  public
    constructor Create(const AGeometry: ID2D1Geometry);
    function Geometry: ID2D1Geometry;
  end;

  /// <summary>Hands what Direct2D simplifies or widens to the edge sink.</summary>
  TSinkAdapter = class(TInterfacedObject, ID2D1SimplifiedGeometrySink)
  public
    Sink: TFastEdgeSink;
    procedure SetFillMode(fillMode: D2D1_FILL_MODE); stdcall;
    procedure SetSegmentFlags(vertexFlags: D2D1_PATH_SEGMENT); stdcall;
    procedure BeginFigure(startPoint: D2D1_POINT_2F; figureBegin: D2D1_FIGURE_BEGIN); stdcall;
    procedure AddLines(points: PD2D1Point2F; pointsCount: UINT); stdcall;
    procedure AddBeziers(beziers: PD2D1BezierSegment; beziersCount: UINT); stdcall;
    procedure EndFigure(figureEnd: D2D1_FIGURE_END); stdcall;
    function Close: HResult; stdcall;
  end;

function D2DPoint(const X, Y: Single): TD2D1Point2F; inline;
begin
  Result.x := X;
  Result.y := Y;
end;

function D2DRect(const R: TRectF): TD2D1RectF; inline;
begin
  Result.left := R.Left;
  Result.top := R.Top;
  Result.right := R.Right;
  Result.bottom := R.Bottom;
end;

function Identity: TD2D1Matrix3x2F; inline;
begin
  Result._11 := 1;
  Result._12 := 0;
  Result._21 := 0;
  Result._22 := 1;
  Result._31 := 0;
  Result._32 := 0;
end;

function Wrap(const AGeometry: ID2D1Geometry): IFastGeometry; inline;
begin
  if AGeometry = nil then
    Result := nil
  else
    Result := TD2DGeometry.Create(AGeometry);
end;

function FastD2DGeometry(const AGeometry: IFastGeometry): ID2D1Geometry;
var
  G: IFastD2DGeometry;
begin
  if Supports(AGeometry, IFastD2DGeometry, G) then
    Result := G.Geometry
  else
    Result := nil;
end;

/// <summary>Direct2D path geometry of FMX path points: MoveTo starts a filled figure, CurveTo takes three points
/// (two control points and the end), Close ends the figure closed; an unfinished figure ends open.</summary>
function BuildGeometry(const APoints: PFastPathPoints; const ACount: Integer;
  const AWinding: Boolean): ID2D1PathGeometry;
var
  Sink: ID2D1GeometrySink;
  I: Integer;
  Open: Boolean;
  B: TD2D1BezierSegment;
begin
  if Failed(TFastDevice.D2DFactory.CreatePathGeometry(Result)) or Failed(Result.Open(Sink)) then
    Exit(nil);
  if AWinding then
    Sink.SetFillMode(D2D1_FILL_MODE_WINDING);
  Open := False;
  I := 0;
  while I < ACount do
  begin
    case APoints[I].Kind of
      TPathPointKind.MoveTo:
        begin
          if Open then
            Sink.EndFigure(D2D1_FIGURE_END_OPEN);
          Sink.BeginFigure(D2DPoint(APoints[I].Point.X, APoints[I].Point.Y), D2D1_FIGURE_BEGIN_FILLED);
          Open := True;
        end;
      TPathPointKind.LineTo:
        if Open then
          Sink.AddLine(D2DPoint(APoints[I].Point.X, APoints[I].Point.Y));
      TPathPointKind.CurveTo:
        begin
          if Open and (I + 2 < ACount) then
          begin
            B.point1 := D2DPoint(APoints[I].Point.X, APoints[I].Point.Y);
            B.point2 := D2DPoint(APoints[I + 1].Point.X, APoints[I + 1].Point.Y);
            B.point3 := D2DPoint(APoints[I + 2].Point.X, APoints[I + 2].Point.Y);
            Sink.AddBezier(B);
          end;
          Inc(I, 2);
        end;
      TPathPointKind.Close:
        if Open then
        begin
          Sink.EndFigure(D2D1_FIGURE_END_CLOSED);
          Open := False;
        end;
    end;
    Inc(I);
  end;
  if Open then
    Sink.EndFigure(D2D1_FIGURE_END_OPEN);
  Sink.Close;
end;

function FastD2DStrokeStyle(const AStroke: TFastStroke): ID2D1StrokeStyle;
const
  Caps: array[0..1] of D2D1_CAP_STYLE = (D2D1_CAP_STYLE_SQUARE, D2D1_CAP_STYLE_ROUND);
  Joins: array[0..2] of D2D1_LINE_JOIN = (D2D1_LINE_JOIN_MITER, D2D1_LINE_JOIN_ROUND, D2D1_LINE_JOIN_BEVEL);
var
  Props: TD2D1StrokeStyleProperties;
  Dashes: PSingle;
begin
  // FMX flat caps are drawn square, as the stock Direct2D canvas does.
  Props.startCap := Caps[Min(AStroke.Cap, 1)];
  Props.endCap := Props.startCap;
  Props.dashCap := Props.startCap;
  Props.lineJoin := Joins[Min(AStroke.Join, 2)];
  Props.miterLimit := 10;
  Props.dashStyle := D2D1_DASH_STYLE(AStroke.Dash);
  Props.dashOffset := AStroke.DashOffset;
  Dashes := PSingle(AStroke.Dashes);
  if AStroke.DashCount = 0 then
    Dashes := nil;
  if Failed(TFastDevice.D2DFactory.CreateStrokeStyle(Props, Dashes, AStroke.DashCount, Result)) then
    Result := nil;
end;

{ TD2DGeometry }

constructor TD2DGeometry.Create(const AGeometry: ID2D1Geometry);
begin
  inherited Create;
  FGeometry := AGeometry;
end;

function TD2DGeometry.Geometry: ID2D1Geometry;
begin
  Result := FGeometry;
end;

{ TSinkAdapter }

procedure TSinkAdapter.SetFillMode(fillMode: D2D1_FILL_MODE);
begin
  Sink.EvenOdd := fillMode = D2D1_FILL_MODE_ALTERNATE;
end;

procedure TSinkAdapter.SetSegmentFlags(vertexFlags: D2D1_PATH_SEGMENT);
begin
end;

procedure TSinkAdapter.BeginFigure(startPoint: D2D1_POINT_2F; figureBegin: D2D1_FIGURE_BEGIN);
begin
  Sink.BeginFigure(TPointF(startPoint));
end;

procedure TSinkAdapter.AddLines(points: PD2D1Point2F; pointsCount: UINT);
var
  I: Integer;
begin
  for I := 0 to Integer(pointsCount) - 1 do
  begin
    Sink.LineTo(TPointF(points^));
    Inc(points);
  end;
end;

procedure TSinkAdapter.AddBeziers(beziers: PD2D1BezierSegment; beziersCount: UINT);
var
  I: Integer;
begin
  for I := 0 to Integer(beziersCount) - 1 do
  begin
    Sink.CubicTo(TPointF(beziers.point1), TPointF(beziers.point2), TPointF(beziers.point3));
    Inc(beziers);
  end;
end;

procedure TSinkAdapter.EndFigure(figureEnd: D2D1_FIGURE_END);
begin
  // Fills close every figure; widened outlines are closed already.
  Sink.CloseFigure;
end;

function TSinkAdapter.Close: HResult;
begin
  Sink.CloseFigure;
  Result := S_OK;
end;

{ TFastGeometryD2D }

constructor TFastGeometryD2D.Create;
begin
  inherited Create;
  FAdapterObject := TSinkAdapter.Create;
  FAdapter := TSinkAdapter(FAdapterObject);
  FStrokes := TDictionary<UInt64, ID2D1StrokeStyle>.Create;
end;

destructor TFastGeometryD2D.Destroy;
begin
  FStrokes.Free;
  FAdapter := nil;
  inherited;
end;

procedure TFastGeometryD2D.Target(const ASink: TFastEdgeSink);
begin
  TSinkAdapter(FAdapterObject).Sink := ASink;
end;

function TFastGeometryD2D.Path(const APoints: PFastPathPoints; const ACount: Integer;
  const AWinding: Boolean): IFastGeometry;
begin
  Result := Wrap(BuildGeometry(APoints, ACount, AWinding));
end;

function TFastGeometryD2D.Rectangle(const R: TRectF): IFastGeometry;
var
  G: ID2D1RectangleGeometry;
begin
  if Succeeded(TFastDevice.D2DFactory.CreateRectangleGeometry(D2DRect(R), G)) then
    Result := Wrap(G)
  else
    Result := nil;
end;

function TFastGeometryD2D.RoundedRectangle(const R: TRectF; const ARx, ARy: Single): IFastGeometry;
var
  G: ID2D1RoundedRectangleGeometry;
  RR: TD2D1RoundedRect;
begin
  RR.rect := D2DRect(R);
  RR.radiusX := ARx;
  RR.radiusY := ARy;
  if Succeeded(TFastDevice.D2DFactory.CreateRoundedRectangleGeometry(RR, G)) then
    Result := Wrap(G)
  else
    Result := nil;
end;

function TFastGeometryD2D.Ellipse(const R: TRectF): IFastGeometry;
var
  G: ID2D1EllipseGeometry;
  E: TD2D1Ellipse;
begin
  E.point := D2DPoint((R.Left + R.Right) / 2, (R.Top + R.Bottom) / 2);
  E.radiusX := R.Width / 2;
  E.radiusY := R.Height / 2;
  if Succeeded(TFastDevice.D2DFactory.CreateEllipseGeometry(E, G)) then
    Result := Wrap(G)
  else
    Result := nil;
end;

function TFastGeometryD2D.Line(const AP0, AP1: TPointF): IFastGeometry;
var
  Path: ID2D1PathGeometry;
  Sink: ID2D1GeometrySink;
begin
  Result := nil;
  if Succeeded(TFastDevice.D2DFactory.CreatePathGeometry(Path)) and Succeeded(Path.Open(Sink)) then
  begin
    Sink.BeginFigure(D2DPoint(AP0.X, AP0.Y), D2D1_FIGURE_BEGIN_HOLLOW);
    Sink.AddLine(D2DPoint(AP1.X, AP1.Y));
    Sink.EndFigure(D2D1_FIGURE_END_OPEN);
    if Succeeded(Sink.Close) then
      Result := Wrap(Path);
  end;
end;

function TFastGeometryD2D.Flatten(const AGeometry: IFastGeometry; const ASink: TFastEdgeSink): Boolean;
var
  G: ID2D1Geometry;
begin
  G := FastD2DGeometry(AGeometry);
  if G = nil then
    Exit(False);
  Target(ASink);
  Result := Succeeded(G.Simplify(D2D1_GEOMETRY_SIMPLIFICATION_OPTION_LINES, Identity, ASink.Tolerance, FAdapter));
end;

function TFastGeometryD2D.Widen(const AGeometry: IFastGeometry; const AStroke: TFastStroke;
  const ASink: TFastEdgeSink): Boolean;
var
  G: ID2D1Geometry;
  Style: ID2D1StrokeStyle;
begin
  G := FastD2DGeometry(AGeometry);
  if G = nil then
    Exit(False);
  if not FStrokes.TryGetValue(AStroke.Key, Style) then
  begin
    Style := FastD2DStrokeStyle(AStroke);
    FStrokes.AddOrSetValue(AStroke.Key, Style);
  end;
  Target(ASink);
  Result := Succeeded(G.Widen(AStroke.Width, Style, Identity, ASink.Tolerance, FAdapter));
end;

function TFastGeometryD2D.Contains(const AGeometry: IFastGeometry; const APoint: TPointF): Boolean;
var
  G: ID2D1Geometry;
  Inside: BOOL;
begin
  Result := False;
  G := FastD2DGeometry(AGeometry);
  if G = nil then
    Exit;
  Inside := False;
  if Succeeded(G.FillContainsPoint(D2DPoint(APoint.X, APoint.Y), Identity, D2D1_DEFAULT_FLATTENING_TOLERANCE,
    Inside)) then
    Result := Inside;
end;

initialization
  FastRegisterGeometryEngine(TFastCanvasEngine.Native, TFastGeometryD2D);
end.
