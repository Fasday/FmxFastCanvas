unit Bench.Scenes.AA;

{ Scene "aa": a fixed anti-aliasing quality test pattern. The drawing is public so that the
  reference renderer (AaReference.dpr) draws exactly the same content; AaPatternRegions describes
  the bands and sections for tools\compare-aa.ps1.

  The pattern is made of tiles of AaTileWidth x AaTileHeight logical units. N tiles are laid out in
  Ceil(Sqrt(N)) columns and centred in the bounds: N = 4 fills 1280x720 units (1920x1080 at 150 %),
  N = 9 fills 1920x1080 at 100 %. Sizes are logical units and are never scaled with the client
  size, so a 1-unit line stays 1 unit wide. A tile has a geometry band (fans of lines 0.5..3 wide,
  small circles and round rects, abutting shapes over a contrasting background, a fan of thin
  triangles, a 1:1 and two rotated checkerboard bitmaps) and a text band (Segoe UI 8..14) below it.

  Everything sits at fractional coordinates. Each tile has its own sub-unit offset, and a slow drift
  from the time (period > 7 s) moves the content by less than one unit, so consecutive frames differ
  but a given frame is the same on every canvas. }

interface

uses
  System.Types, FMX.Graphics;

const
  AaTileWidth = 640;
  AaTileHeight = 360;
  /// <summary>The geometry band is the top of a tile, the text band the rest.</summary>
  AaGeometryBandHeight = 288;
  /// <summary>Side of the checkerboard bitmap, pixels. It is drawn 1:1 in device pixels.</summary>
  AaBitmapSize = 48;

type
  TAaRegionKind = (Geometry, Text, Section, Crop);

  TAaRegion = record
    Kind: TAaRegionKind;
    Name: string;
    Tile: Integer;
    Rect: TRectF;  // logical units, same space as ABounds
  end;

/// <summary>Draws ATiles pattern tiles into ABounds. ADeviceScale is the scale from logical units
/// to device pixels (TCanvas.Scale of the screen canvas); ABounds.TopLeft must map to a device
/// pixel corner. Bitmaps are drawn 1:1 in device pixels and one copy is snapped to them.</summary>
procedure DrawAaPattern(const ACanvas: TCanvas; const ABounds: TRectF; const ATime: Double;
  const ATiles: Integer; const ADeviceScale: Single);
/// <summary>Creates the checkerboard bitmap; DrawAaPattern calls it on first use.</summary>
procedure PrepareAaPatternResources;
procedure FreeAaPatternResources;
/// <summary>Per tile: the geometry and text bands and the named sections; for tile 0 also the
/// centres of the crops shown in the contact sheet (Kind = Crop).</summary>
function AaPatternRegions(const ABounds: TRectF; const ATiles: Integer): TArray<TAaRegion>;
function AaRegionKindName(const AKind: TAaRegionKind): string;

implementation

uses
  System.SysUtils, System.UITypes, System.Math, System.Math.Vectors, FMX.Types, Bench.Config,
  Bench.Scenes;

type
  TAaSection = record
    Name: string;
    Left, Top, Right, Bottom: Single;
  end;

const
  Sections: array[0..6] of TAaSection = (
    (Name: 'lines'; Left: 4; Top: 4; Right: 520; Bottom: 104),
    (Name: 'bitmap11'; Left: 524; Top: 4; Right: 636; Bottom: 104),
    (Name: 'circles'; Left: 4; Top: 108; Right: 108; Bottom: 284),
    (Name: 'rrects'; Left: 112; Top: 108; Right: 212; Bottom: 284),
    (Name: 'seams'; Left: 216; Top: 108; Right: 376; Bottom: 284),
    (Name: 'pie'; Left: 380; Top: 108; Right: 528; Bottom: 284),
    (Name: 'bitmaprot'; Left: 532; Top: 108; Right: 636; Bottom: 284));

  FanWidths: array[0..4] of Single = (0.5, 1, 1.5, 2, 3);
  FanPitch = 104;
  FanLines = 13;      // 0..90 degrees
  FanStep = 7.5;      // degrees
  FanInner = 18;
  FanOuter = 92;

  CircleRadii: array[0..7] of Single = (1.5, 2, 2.5, 3, 4, 5, 6, 8);
  CircleRows = 8;     // 6 filled, 2 stroked
  CircleRowPitch = 20;
  SubX: array[0..7] of Single = (0, 0.17, 0.33, 0.5, 0.67, 0.83, 0.25, 0.75);
  SubY: array[0..7] of Single = (0, 0.42, 0.83, 0.25, 0.67, 0.08, 0.6, 0.1);

  RRectW: array[0..5] of Single = (8, 10, 14, 18, 22, 28);
  RRectH: array[0..5] of Single = (5, 7, 9, 11, 14, 18);
  RRectRadius: array[0..5] of Single = (1.5, 2, 2.5, 3, 4, 6);

  PieWedges = 72;
  PieRadius = 68;
  HalfDiskSegments = 32;

  RotatedAngles: array[0..1] of Single = (15, 33);

  SeamX = 37.37;      // vertical seam, from the left of seam cell (0, 0)
  CornerX = 37.6;     // meeting point of four rectangles in seam cell (1, 1)
  CornerY = 26.3;

  TextColumnWidth = 206;
  TextLineFactor = 1.45;

var
  GChecker: TBitmap;

{ Layout }

function TileOrigin(const ABounds: TRectF; const ATiles, AIndex: Integer): TPointF;
var
  Cols, Rows: Integer;
begin
  Cols := Max(1, Ceil(Sqrt(Max(1, ATiles))));
  Rows := Max(1, Ceil(Max(1, ATiles) / Cols));
  Result.X := ABounds.Left + (ABounds.Width - Cols * AaTileWidth) / 2 + (AIndex mod Cols) * AaTileWidth;
  Result.Y := ABounds.Top + (ABounds.Height - Rows * AaTileHeight) / 2 + (AIndex div Cols) * AaTileHeight;
end;

function TileOffset(const AIndex: Integer; const ATime: Double): TPointF;
begin
  Result.X := 0.31 + 0.3 * Sin(ATime * 0.8 + AIndex * 2.4);
  Result.Y := 0.23 + 0.3 * Sin(ATime * 0.6 + AIndex * 1.7 + 1.0);
end;

function FanOrigin(const AIndex: Integer): TPointF;
begin
  Result := TPointF.Create(4 + AIndex * FanPitch + 6.3, 4 + 94.6);
end;

function PieCenter: TPointF;
begin
  Result := TPointF.Create(Sections[5].Left + 74.3, Sections[5].Top + 88.6);
end;

function SeamCell(const ACol, ARow: Integer): TPointF;
begin
  Result := TPointF.Create(Sections[4].Left + 4 + ACol * 78, Sections[4].Top + 4 + ARow * 57);
end;

function Bitmap11Pos: TPointF;
begin
  Result := TPointF.Create(Sections[1].Left + 4.37, Sections[1].Top + 6.71);
end;

function RotatedCenter(const AIndex: Integer): TPointF;
begin
  Result := TPointF.Create(Sections[6].Left + 52.31, Sections[6].Top + AIndex * 88 + 43.17);
end;

function TextOrigin(const AColumn: Integer): TPointF;
begin
  Result := TPointF.Create(6.3 + AColumn * 210, AaGeometryBandHeight + 2.4);
end;

function Dir(const ADegrees: Single): TPointF;
begin
  Result := TPointF.Create(Cos(DegToRad(ADegrees)), -Sin(DegToRad(ADegrees)));
end;

{ Resources }

function CheckerColor(const AX, AY: Integer): TAlphaColor;
const
  Half = AaBitmapSize div 2;
var
  Cell: Integer;
  Dark: Boolean;
begin
  // Four quadrants: 1, 2 and 4 pixel black/white checks, 8 pixel red/yellow checks.
  if AY < Half then
  begin
    if AX < Half then
      Cell := 1
    else
      Cell := 2;
  end
  else if AX < Half then
    Cell := 4
  else
    Cell := 8;
  Dark := ((AX div Cell) + (AY div Cell)) and 1 = 1;
  if Cell = 8 then
  begin
    if Dark then
      Result := $FFE53935
    else
      Result := $FFFDD835;
  end
  else if Dark then
    Result := TAlphaColors.Black
  else
    Result := TAlphaColors.White;
end;

procedure PrepareAaPatternResources;
var
  Data: TBitmapData;
  Line: TArray<TAlphaColor>;
  X, Y: Integer;
begin
  if GChecker <> nil then
    Exit;
  GChecker := TBitmap.Create(AaBitmapSize, AaBitmapSize);
  SetLength(Line, AaBitmapSize);
  if not GChecker.Map(TMapAccess.Write, Data) then
    raise Exception.Create('Cannot map the checkerboard bitmap');
  try
    for Y := 0 to AaBitmapSize - 1 do
    begin
      for X := 0 to AaBitmapSize - 1 do
        Line[X] := CheckerColor(X, Y);
      AlphaColorToScanline(@Line[0], Data.GetScanline(Y), AaBitmapSize, Data.PixelFormat);
    end;
  finally
    GChecker.Unmap(Data);
  end;
end;

procedure FreeAaPatternResources;
begin
  FreeAndNil(GChecker);
end;

{ Drawing }

procedure FillTriangle(const ACanvas: TCanvas; const APath: TPathData; const A, B, C: TPointF);
begin
  APath.Clear;
  APath.MoveTo(A);
  APath.LineTo(B);
  APath.LineTo(C);
  APath.ClosePath;
  ACanvas.FillPath(APath, 1);
end;

procedure DrawFans(const ACanvas: TCanvas; const AOrigin: TPointF);
var
  I, J: Integer;
  O, D: TPointF;
begin
  ACanvas.Stroke.Color := TAlphaColors.Black;
  for I := 0 to High(FanWidths) do
  begin
    ACanvas.Stroke.Thickness := FanWidths[I];
    O := AOrigin + FanOrigin(I);
    for J := 0 to FanLines - 1 do
    begin
      D := Dir(J * FanStep);
      ACanvas.DrawLine(O + D * FanInner, O + D * FanOuter, 1);
    end;
  end;
end;

procedure DrawCircles(const ACanvas: TCanvas; const AOrigin: TPointF);
var
  Row, I: Integer;
  X, R: Single;
  C: TPointF;
  Rect: TRectF;
begin
  ACanvas.Fill.Color := TAlphaColors.Black;
  ACanvas.Stroke.Color := TAlphaColors.Black;
  ACanvas.Stroke.Thickness := 1;
  for Row := 0 to CircleRows - 1 do
  begin
    X := 3;
    for I := 0 to High(CircleRadii) do
    begin
      R := CircleRadii[I];
      C := AOrigin + TPointF.Create(Sections[2].Left + X + R + SubX[Row],
        Sections[2].Top + 4 + Row * CircleRowPitch + CircleRowPitch / 2 + SubY[Row]);
      Rect := TRectF.Create(C.X - R, C.Y - R, C.X + R, C.Y + R);
      if Row < 6 then
        ACanvas.FillEllipse(Rect, 1)
      else
        ACanvas.DrawEllipse(Rect, 1);
      X := X + 2 * R + 3;
    end;
  end;
end;

procedure DrawRoundRects(const ACanvas: TCanvas; const AOrigin: TPointF);
var
  I, Col: Integer;
  Y: Single;
  P: TPointF;
  Rect: TRectF;
begin
  ACanvas.Fill.Color := TAlphaColors.Black;
  ACanvas.Stroke.Color := TAlphaColors.Black;
  ACanvas.Stroke.Thickness := 1;
  Y := 4;
  for I := 0 to High(RRectW) do
  begin
    for Col := 0 to 2 do
    begin
      P := AOrigin + TPointF.Create(Sections[3].Left + 4 + Col * 32 + SubX[Col * 2 + 1],
        Sections[3].Top + Y + SubY[Col * 2 + 1]);
      Rect := TRectF.Create(P.X, P.Y, P.X + RRectW[I], P.Y + RRectH[I]);
      if Col < 2 then
        ACanvas.FillRect(Rect, RRectRadius[I], RRectRadius[I], AllCorners, 1)
      else
        ACanvas.DrawRect(Rect, RRectRadius[I], RRectRadius[I], AllCorners, 1);
    end;
    Y := Y + RRectH[I] + 8;
  end;
  // Plain rectangles with fractional edges: 1-unit outlines and fills, the usual UI borders.
  for Col := 0 to 2 do
  begin
    P := AOrigin + TPointF.Create(Sections[3].Left + 4 + Col * 32 + SubX[Col + 5], Sections[3].Top + 120 + SubY[Col + 5]);
    ACanvas.DrawRect(TRectF.Create(P.X, P.Y, P.X + 26, P.Y + 18), 0, 0, [], 1);
    ACanvas.FillRect(TRectF.Create(P.X, P.Y + 26, P.X + 26, P.Y + 44), 0, 0, [], 1);
  end;
end;

procedure DrawHalfDisk(const ACanvas: TCanvas; const APath: TPathData; const AC: TPointF; const AR,
  AStart: Single);
var
  I: Integer;
begin
  APath.Clear;
  APath.MoveTo(AC + Dir(AStart) * AR);
  for I := 1 to HalfDiskSegments do
    APath.LineTo(AC + Dir(AStart + I * 180 / HalfDiskSegments) * AR);
  APath.ClosePath;
  ACanvas.FillPath(APath, 1);
end;

procedure DrawSeams(const ACanvas: TCanvas; const APath: TPathData; const AOrigin: TPointF);
var
  S, P, E0, E1: TPointF;
  L, T, R, B: Single;
begin
  S := AOrigin + TPointF.Create(Sections[4].Left, Sections[4].Top);
  ACanvas.Fill.Color := TAlphaColors.Black;
  ACanvas.FillRect(TRectF.Create(S.X + 0.4, S.Y + 0.3, S.X + 159.6, S.Y + 175.7), 0, 0, [], 1);
  ACanvas.Fill.Color := TAlphaColors.White;

  // Two rectangles sharing a vertical edge.
  S := AOrigin + SeamCell(0, 0);
  ACanvas.FillRect(TRectF.Create(S.X + 6.2, S.Y + 6.6, S.X + SeamX, S.Y + 47.4), 0, 0, [], 1);
  ACanvas.FillRect(TRectF.Create(S.X + SeamX, S.Y + 6.6, S.X + 68.5, S.Y + 47.4), 0, 0, [], 1);

  // Two rectangles sharing a horizontal edge.
  S := AOrigin + SeamCell(1, 0);
  ACanvas.FillRect(TRectF.Create(S.X + 6.6, S.Y + 4.2, S.X + 67.4, S.Y + 25.63), 0, 0, [], 1);
  ACanvas.FillRect(TRectF.Create(S.X + 6.6, S.Y + 25.63, S.X + 67.4, S.Y + 49.1), 0, 0, [], 1);

  // A rectangle split along its diagonal into two triangles.
  S := AOrigin + SeamCell(0, 1);
  L := S.X + 10.3;
  T := S.Y + 3.7;
  R := S.X + 59.3;
  B := S.Y + 49.2;
  FillTriangle(ACanvas, APath, TPointF.Create(L, T), TPointF.Create(R, T), TPointF.Create(R, B));
  FillTriangle(ACanvas, APath, TPointF.Create(L, T), TPointF.Create(R, B), TPointF.Create(L, B));

  // Four rectangles meeting at one fractional point.
  S := AOrigin + SeamCell(1, 1);
  P := S + TPointF.Create(CornerX, CornerY);
  L := S.X + 8.2;
  T := S.Y + 4.4;
  R := S.X + 66.9;
  B := S.Y + 48.7;
  ACanvas.FillRect(TRectF.Create(L, T, P.X, P.Y), 0, 0, [], 1);
  ACanvas.FillRect(TRectF.Create(P.X, T, R, P.Y), 0, 0, [], 1);
  ACanvas.FillRect(TRectF.Create(L, P.Y, P.X, B), 0, 0, [], 1);
  ACanvas.FillRect(TRectF.Create(P.X, P.Y, R, B), 0, 0, [], 1);

  // Two quads sharing a slanted edge.
  S := AOrigin + SeamCell(0, 2);
  E0 := S + TPointF.Create(31.4, 4.3);
  E1 := S + TPointF.Create(42.1, 48.8);
  APath.Clear;
  APath.MoveTo(TPointF.Create(S.X + 6.5, E0.Y));
  APath.LineTo(E0);
  APath.LineTo(E1);
  APath.LineTo(TPointF.Create(S.X + 6.5, E1.Y));
  APath.ClosePath;
  ACanvas.FillPath(APath, 1);
  APath.Clear;
  APath.MoveTo(E0);
  APath.LineTo(TPointF.Create(S.X + 67.5, E0.Y));
  APath.LineTo(TPointF.Create(S.X + 67.5, E1.Y));
  APath.LineTo(E1);
  APath.ClosePath;
  ACanvas.FillPath(APath, 1);

  // A disk made of two half disks.
  S := AOrigin + SeamCell(1, 2);
  P := S + TPointF.Create(37.2, 26.6);
  DrawHalfDisk(ACanvas, APath, P, 21.7, 0);
  DrawHalfDisk(ACanvas, APath, P, 21.7, 180);
end;

procedure DrawPie(const ACanvas: TCanvas; const APath: TPathData; const AOrigin: TPointF);
var
  S, C: TPointF;
  J: Integer;
begin
  S := AOrigin + TPointF.Create(Sections[5].Left, Sections[5].Top);
  ACanvas.Fill.Color := TAlphaColors.Black;
  ACanvas.FillRect(TRectF.Create(S.X + 0.6, S.Y + 0.2, S.X + 147.3, S.Y + 175.8), 0, 0, [], 1);
  // Thin triangles of one color meeting at the centre, each its own FillPath.
  ACanvas.Fill.Color := TAlphaColors.White;
  C := AOrigin + PieCenter;
  for J := 0 to PieWedges - 1 do
    FillTriangle(ACanvas, APath, C, C + Dir(J * 360 / PieWedges) * PieRadius,
      C + Dir((J + 1) * 360 / PieWedges) * PieRadius);
end;

procedure DrawBitmaps(const ACanvas: TCanvas; const AOrigin: TPointF; const ADeviceScale: Single;
  const ABase: TMatrix);
var
  Src: TRectF;
  Size: Single;
  P, C: TPointF;
  I: Integer;
begin
  Src := TRectF.Create(0, 0, AaBitmapSize, AaBitmapSize);
  Size := AaBitmapSize / ADeviceScale;
  P := AOrigin + Bitmap11Pos;
  ACanvas.DrawBitmap(GChecker, Src, TRectF.Create(P.X, P.Y, P.X + Size, P.Y + Size), 1, False);
  // The same bitmap snapped to device pixels: an exact copy is expected from every canvas.
  P := AOrigin + Bitmap11Pos + TPointF.Create(56, 0);
  P := TPointF.Create(Round(P.X * ADeviceScale) / ADeviceScale, Round(P.Y * ADeviceScale) / ADeviceScale);
  ACanvas.DrawBitmap(GChecker, Src, TRectF.Create(P.X, P.Y, P.X + Size, P.Y + Size), 1, False);
  for I := 0 to High(RotatedAngles) do
  begin
    C := AOrigin + RotatedCenter(I);
    ACanvas.SetMatrix(TMatrix.CreateTranslation(-C.X, -C.Y) * TMatrix.CreateRotation(DegToRad(RotatedAngles[I])) *
      TMatrix.CreateTranslation(C.X, C.Y) * ABase);
    ACanvas.DrawBitmap(GChecker, Src, TRectF.Create(C.X - Size / 2, C.Y - Size / 2, C.X + Size / 2, C.Y + Size / 2),
      1, False);
    ACanvas.SetMatrix(ABase);
  end;
end;

function SampleText: string;
begin
  // 'Sphinx 0123 il1 ' and a Cyrillic word.
  Result := 'Sphinx 0123 il1 ' + Char($0416) + Char($0451) + Char($043B) + Char($0442) + Char($044B) + Char($0439);
end;

procedure DrawText(const ACanvas: TCanvas; const AOrigin: TPointF);
const
  Sizes: array[0..2, 0..3] of Single = ((8, 9, 10, 11), (12, 13, 14, 0), (9, 11, 13, 0));
var
  Col, I: Integer;
  P: TPointF;
  S: string;
begin
  S := SampleText;
  ACanvas.Fill.Color := TAlphaColors.Black;
  ACanvas.Font.Family := 'Segoe UI';
  for Col := 0 to 2 do
  begin
    if Col = 2 then
      ACanvas.Font.Style := [TFontStyle.fsBold]
    else
      ACanvas.Font.Style := [];
    P := AOrigin + TextOrigin(Col);
    for I := 0 to 3 do
    begin
      if Sizes[Col, I] = 0 then
        Break;
      ACanvas.Font.Size := Sizes[Col, I];
      ACanvas.FillText(TRectF.Create(P.X, P.Y, P.X + TextColumnWidth, P.Y + Sizes[Col, I] * 1.6), S, False, 1, [],
        TTextAlign.Leading, TTextAlign.Leading);
      P.Y := P.Y + Sizes[Col, I] * TextLineFactor;
    end;
  end;
end;

procedure DrawAaPattern(const ACanvas: TCanvas; const ABounds: TRectF; const ATime: Double;
  const ATiles: Integer; const ADeviceScale: Single);
var
  State: TCanvasSaveState;
  Base: TMatrix;
  Path: TPathData;
  K: Integer;
  O: TPointF;
begin
  PrepareAaPatternResources;
  State := ACanvas.SaveState;
  Path := TPathData.Create;
  try
    Base := ACanvas.Matrix;
    ACanvas.Fill.Kind := TBrushKind.Solid;
    ACanvas.Stroke.Kind := TBrushKind.Solid;
    ACanvas.Stroke.Cap := TStrokeCap.Flat;
    ACanvas.Stroke.Join := TStrokeJoin.Miter;
    ACanvas.Stroke.Dash := TStrokeDash.Solid;
    ACanvas.Fill.Color := TAlphaColors.White;
    ACanvas.FillRect(ABounds, 0, 0, [], 1);
    for K := 0 to Max(1, ATiles) - 1 do
    begin
      O := TileOrigin(ABounds, ATiles, K) + TileOffset(K, ATime);
      DrawFans(ACanvas, O);
      DrawCircles(ACanvas, O);
      DrawRoundRects(ACanvas, O);
      DrawSeams(ACanvas, Path, O);
      DrawPie(ACanvas, Path, O);
      DrawBitmaps(ACanvas, O, ADeviceScale, Base);
      DrawText(ACanvas, O);
    end;
  finally
    Path.Free;
    ACanvas.RestoreState(State);
  end;
end;

{ Regions }

function AaRegionKindName(const AKind: TAaRegionKind): string;
begin
  case AKind of
    TAaRegionKind.Geometry: Result := 'geometry';
    TAaRegionKind.Text: Result := 'text';
    TAaRegionKind.Section: Result := 'section';
  else
    Result := 'crop';
  end;
end;

function AaPatternRegions(const ABounds: TRectF; const ATiles: Integer): TArray<TAaRegion>;
var
  List: TArray<TAaRegion>;
  Count: Integer;

  procedure Add(const AKind: TAaRegionKind; const AName: string; const ATile: Integer; const ARect: TRectF);
  begin
    if Count = Length(List) then
      SetLength(List, Count * 2 + 16);
    List[Count].Kind := AKind;
    List[Count].Name := AName;
    List[Count].Tile := ATile;
    List[Count].Rect := ARect;
    Inc(Count);
  end;

  procedure AddCrop(const AName: string; const AOrigin, ACenter: TPointF);
  const
    HalfW = 16;
    HalfH = 13;
  var
    C: TPointF;
  begin
    C := AOrigin + ACenter;
    Add(TAaRegionKind.Crop, AName, 0, TRectF.Create(C.X - HalfW, C.Y - HalfH, C.X + HalfW, C.Y + HalfH));
  end;

var
  K, I: Integer;
  O: TPointF;
begin
  Count := 0;
  for K := 0 to Max(1, ATiles) - 1 do
  begin
    O := TileOrigin(ABounds, ATiles, K);
    Add(TAaRegionKind.Geometry, 'geometry', K, TRectF.Create(O.X, O.Y, O.X + AaTileWidth, O.Y + AaGeometryBandHeight));
    Add(TAaRegionKind.Text, 'text', K, TRectF.Create(O.X, O.Y + AaGeometryBandHeight, O.X + AaTileWidth,
      O.Y + AaTileHeight));
    for I := 0 to High(Sections) do
      Add(TAaRegionKind.Section, Sections[I].Name, K, TRectF.Create(O.X + Sections[I].Left, O.Y + Sections[I].Top,
        O.X + Sections[I].Right, O.Y + Sections[I].Bottom));
  end;
  O := TileOrigin(ABounds, ATiles, 0);
  AddCrop('lines05', O, FanOrigin(0) + TPointF.Create(36, -8));
  AddCrop('lines1', O, FanOrigin(1) + TPointF.Create(36, -8));
  AddCrop('circles', O, TPointF.Create(Sections[2].Left + 16, Sections[2].Top + 24));
  AddCrop('seams', O, SeamCell(0, 0) + TPointF.Create(SeamX, 17));
  AddCrop('corner4', O, SeamCell(1, 1) + TPointF.Create(CornerX, CornerY));
  AddCrop('pie', O, PieCenter);
  AddCrop('bitmap11', O, Bitmap11Pos + TPointF.Create(16, 16));
  AddCrop('bitmaprot', O, RotatedCenter(1));
  AddCrop('text', O, TextOrigin(0) + TPointF.Create(16, 12));
  SetLength(List, Count);
  Result := List;
end;

{ Scene }

type
  TAaScene = class(TBenchPaintScene)
  protected
    procedure Draw(const ACanvas: TCanvas; const ARect: TRectF); override;
  public
    destructor Destroy; override;
    class function Name: string; override;
    class function Description: string; override;
    class function DefaultN(const APreset: TBenchPreset): Integer; override;
    procedure Setup; override;
  end;

class function TAaScene.Name: string;
begin
  Result := 'aa';
end;

class function TAaScene.Description: string;
begin
  Result := 'Anti-aliasing test pattern (lines, small shapes, seams, bitmaps, small text), N tiles 640x360';
end;

class function TAaScene.DefaultN(const APreset: TBenchPreset): Integer;
begin
  // Quality first: medium fills 1280x720 logical units (1920x1080 at 150 %).
  case APreset of
    TBenchPreset.Light: Result := 1;
    TBenchPreset.Heavy: Result := 9;
  else
    Result := 4;
  end;
end;

destructor TAaScene.Destroy;
begin
  FreeAaPatternResources;
  inherited;
end;

procedure TAaScene.Setup;
begin
  inherited;
  PrepareAaPatternResources;
end;

procedure TAaScene.Draw(const ACanvas: TCanvas; const ARect: TRectF);
begin
  DrawAaPattern(ACanvas, ARect, Time, N, ACanvas.Scale);
end;

initialization
  RegisterBenchScene(TAaScene);
end.
