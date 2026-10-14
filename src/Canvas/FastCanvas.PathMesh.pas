unit FastCanvas.PathMesh;

{ Pieces of a path's polygon for drawing it without a quad over all of its bounds (the Vulkan back end on phones,
  TGpuVkRenderer with opaque interiors): the pixels the path's shader has to shade, and the pixels its fill covers
  entirely.

  In local units. A pixel is taken as the shader takes it (PathCoverage): a square around its center, here of half
  size AHalf at most. The bounds are cut into horizontal bands; in a band every edge has a fringe, a trapezoid that
  holds every pixel center of the band whose square reaches the edge (between the edge's line moved sideways by
  AHalf (1 + |dx/dy|), or within the edge's horizontal extent in the band widened by AHalf, whichever is narrower).
  Overlapping fringes merge into one trapezoid around both. No edge passes through a gap between two fringes, so a
  gap is inside or outside the fill as a whole (the winding number at its center): the squares of its pixels are
  covered entirely or not at all. Cover pieces: a run of fringes joined by inside gaps, from the first fringe's left
  side to the last one's right side, grown by AGrow on every side (pieces of neighboring bands overlap rather than
  leave cracks between them); solid pieces: the inside gaps. Pixels outside every cover piece are outside the fill
  and reach no edge (coverage 0). }

interface

uses
  System.Math, FastCanvas.Geometry;

type
  /// <summary>A trapezoid with a horizontal top (Y0) and bottom (Y1): the x of its left and right ends at the top (L0,
  /// R0) and at the bottom (L1, R1).</summary>
  TPathPiece = record
    Y0, Y1, L0, R0, L1, R1: Single;
  end;

/// <summary>The cover and solid pieces of the polygon of ACount edges (AEvenOdd: its fill rule, else non-zero) with
/// the bounds AMinY..AMaxY, bands ABand tall. False when it has too many pieces (draw the quad instead).</summary>
function BuildPathMesh(const AEdges: TArray<TFastEdge>; const ACount: Integer; const AEvenOdd: Boolean;
  const AMinY, AMaxY, AHalf, AGrow, ABand: Single; var ACover, ASolid: TArray<TPathPiece>;
  out ACoverCount, ASolidCount: Integer): Boolean;

implementation

const
  MaxBands = 1024;
  MaxPieces = 16384;

type
  /// <summary>A fringe: its left and right sides at the band's top and bottom.</summary>
  TFringe = record
    L0, L1, R0, R1: Single;
  end;

var
  // Work arrays of the render thread (one path at a time).
  GBandStart, GBandCount: array of Integer;
  GBandEdges: array of Integer;
  GFringes, GStack: array of TFringe;

function BuildPathMesh(const AEdges: TArray<TFastEdge>; const ACount: Integer; const AEvenOdd: Boolean;
  const AMinY, AMaxY, AHalf, AGrow, ABand: Single; var ACover, ASolid: TArray<TPathPiece>;
  out ACoverCount, ASolidCount: Integer): Boolean;
var
  Top, Bottom, H, Yt, Yb, Ya, Yz, Lo, Hi, K, Xa, Xz, Xmin, Xmax, Wide, Ym, Xm, X: Single;
  Bands, B, B0, B1, I, J, E, N, Total, Sp, First, Winding: Integer;
  F, Cur: TFringe;
  Ed: TFastEdge;
  Inside: Boolean;

  procedure AddCover(const AFirst, ALast: Integer);
  var
    P: ^TPathPiece;
  begin
    if ACoverCount = Length(ACover) then
      SetLength(ACover, Max(64, 2 * ACoverCount));
    P := @ACover[ACoverCount];
    Inc(ACoverCount);
    P.Y0 := Yt - AGrow;
    P.Y1 := Yb + AGrow;
    // The sides continued over the grown height (the lines through the band's ends), moved out by AGrow.
    P.L0 := GStack[AFirst].L0 - (GStack[AFirst].L1 - GStack[AFirst].L0) * AGrow / H - AGrow;
    P.L1 := GStack[AFirst].L1 + (GStack[AFirst].L1 - GStack[AFirst].L0) * AGrow / H - AGrow;
    P.R0 := GStack[ALast].R0 - (GStack[ALast].R1 - GStack[ALast].R0) * AGrow / H + AGrow;
    P.R1 := GStack[ALast].R1 + (GStack[ALast].R1 - GStack[ALast].R0) * AGrow / H + AGrow;
  end;

  procedure AddSolid(const ALeft, ARight: TFringe);
  var
    P: ^TPathPiece;
  begin
    if ASolidCount = Length(ASolid) then
      SetLength(ASolid, Max(64, 2 * ASolidCount));
    P := @ASolid[ASolidCount];
    Inc(ASolidCount);
    P.Y0 := Yt;
    P.Y1 := Yb;
    P.L0 := ALeft.R0;
    P.R0 := ARight.L0;
    P.L1 := ALeft.R1;
    P.R1 := ARight.L1;
  end;

begin
  Result := False;
  ACoverCount := 0;
  ASolidCount := 0;
  if (ACount <= 0) or not (AHalf > 0) or not (ABand > 0) or not (AMaxY >= AMinY) then
    Exit;
  Top := AMinY - AHalf;
  Bottom := AMaxY + AHalf;
  H := ABand;
  if (Bottom - Top) / H > MaxBands then
    H := (Bottom - Top) / MaxBands;
  Bands := Max(1, Ceil((Bottom - Top) / H));
  if Bands > MaxBands then
    Bands := MaxBands;
  // The edges of each band: those within AHalf of it.
  if Length(GBandStart) < Bands + 1 then
  begin
    SetLength(GBandStart, Bands + 1);
    SetLength(GBandCount, Bands + 1);
  end;
  FillChar(GBandCount[0], (Bands + 1) * SizeOf(Integer), 0);
  Total := 0;
  for I := 0 to ACount - 1 do
  begin
    Ed := AEdges[I];
    Lo := (Min(Ed.Y0, Ed.Y1) - AHalf - Top) / H;
    Hi := (Max(Ed.Y0, Ed.Y1) + AHalf - Top) / H;
    if not ((Lo < Bands) and (Hi >= 0)) then
      Continue;
    B0 := Max(0, Trunc(Lo));
    B1 := Min(Bands - 1, Trunc(Hi));
    for B := B0 to B1 do
      Inc(GBandCount[B]);
    Inc(Total, B1 - B0 + 1);
  end;
  if Total > 64 * MaxPieces then
    Exit;
  N := 0;
  for B := 0 to Bands - 1 do
  begin
    GBandStart[B] := N;
    Inc(N, GBandCount[B]);
    GBandCount[B] := 0;
  end;
  if Length(GBandEdges) < Total then
    SetLength(GBandEdges, Total);
  for I := 0 to ACount - 1 do
  begin
    Ed := AEdges[I];
    Lo := (Min(Ed.Y0, Ed.Y1) - AHalf - Top) / H;
    Hi := (Max(Ed.Y0, Ed.Y1) + AHalf - Top) / H;
    if not ((Lo < Bands) and (Hi >= 0)) then
      Continue;
    B0 := Max(0, Trunc(Lo));
    B1 := Min(Bands - 1, Trunc(Hi));
    for B := B0 to B1 do
    begin
      GBandEdges[GBandStart[B] + GBandCount[B]] := I;
      Inc(GBandCount[B]);
    end;
  end;

  for B := 0 to Bands - 1 do
  begin
    N := GBandCount[B];
    if N = 0 then
      Continue;
    Yt := Top + B * H;
    Yb := Min(Yt + H, Bottom);
    if not (Yb > Yt) then
      Continue;
    if Length(GFringes) < N then
    begin
      SetLength(GFringes, 2 * N);
      SetLength(GStack, 2 * N);
    end;
    // The fringe of every edge.
    for J := 0 to N - 1 do
    begin
      Ed := AEdges[GBandEdges[GBandStart[B] + J]];
      // The edge within the band's pixel squares' reach.
      Ya := Max(Min(Ed.Y0, Ed.Y1), Yt - AHalf);
      Yz := Min(Max(Ed.Y0, Ed.Y1), Yb + AHalf);
      if Abs(Ed.Y1 - Ed.Y0) > 1E-12 then
      begin
        K := (Ed.X1 - Ed.X0) / (Ed.Y1 - Ed.Y0);
        Xa := Ed.X0 + (Ya - Ed.Y0) * K;
        Xz := Ed.X0 + (Yz - Ed.Y0) * K;
        Xmin := Min(Xa, Xz);
        Xmax := Max(Xa, Xz);
        Wide := AHalf * (1 + Abs(K));
        if 2 * Wide < Xmax - Xmin + 2 * AHalf then
        begin
          F.L0 := Ed.X0 + (Yt - Ed.Y0) * K - Wide;
          F.L1 := Ed.X0 + (Yb - Ed.Y0) * K - Wide;
          F.R0 := F.L0 + 2 * Wide;
          F.R1 := F.L1 + 2 * Wide;
        end
        else
        begin
          F.L0 := Xmin - AHalf;
          F.L1 := F.L0;
          F.R0 := Xmax + AHalf;
          F.R1 := F.R0;
        end;
      end
      else
      begin
        F.L0 := Min(Ed.X0, Ed.X1) - AHalf;
        F.L1 := F.L0;
        F.R0 := Max(Ed.X0, Ed.X1) + AHalf;
        F.R1 := F.R0;
      end;
      if not ((Abs(F.L0) < 1E7) and (Abs(F.L1) < 1E7) and (Abs(F.R0) < 1E7) and (Abs(F.R1) < 1E7)) then
        Exit;
      // Insertion by the left side's middle (few edges a band).
      E := J;
      while (E > 0) and (GFringes[E - 1].L0 + GFringes[E - 1].L1 > F.L0 + F.L1) do
      begin
        GFringes[E] := GFringes[E - 1];
        Dec(E);
      end;
      GFringes[E] := F;
    end;
    // Merged left to right: a fringe that is not right of the top of the stack at both ends overlaps it (it cannot
    // be left of it at both ends, by the order), and they become the trapezoid around both.
    Sp := 0;
    for J := 0 to N - 1 do
    begin
      Cur := GFringes[J];
      while (Sp > 0) and not ((Cur.L0 > GStack[Sp - 1].R0) and (Cur.L1 > GStack[Sp - 1].R1)) do
      begin
        Dec(Sp);
        Cur.L0 := Min(Cur.L0, GStack[Sp].L0);
        Cur.L1 := Min(Cur.L1, GStack[Sp].L1);
        Cur.R0 := Max(Cur.R0, GStack[Sp].R0);
        Cur.R1 := Max(Cur.R1, GStack[Sp].R1);
      end;
      GStack[Sp] := Cur;
      Inc(Sp);
    end;
    // The gaps, and the runs of fringes joined by inside gaps.
    First := 0;
    Ym := (Yt + Yb) * 0.5;
    for J := 0 to Sp - 2 do
    begin
      Xm := ((GStack[J].R0 + GStack[J].R1) * 0.5 + (GStack[J + 1].L0 + GStack[J + 1].L1) * 0.5) * 0.5;
      Winding := 0;
      for I := 0 to N - 1 do
      begin
        Ed := AEdges[GBandEdges[GBandStart[B] + I]];
        if ((Ed.Y0 <= Ym) and (Ym < Ed.Y1)) or ((Ed.Y1 <= Ym) and (Ym < Ed.Y0)) then
        begin
          X := Ed.X0 + (Ym - Ed.Y0) * (Ed.X1 - Ed.X0) / (Ed.Y1 - Ed.Y0);
          if X > Xm then
            if Ed.Y1 > Ed.Y0 then
              Inc(Winding)
            else
              Dec(Winding);
        end;
      end;
      if AEvenOdd then
        Inside := Odd(Winding)
      else
        Inside := Winding <> 0;
      if Inside then
        AddSolid(GStack[J], GStack[J + 1])
      else
      begin
        AddCover(First, J);
        First := J + 1;
      end;
    end;
    AddCover(First, Sp - 1);
    if ACoverCount + ASolidCount > MaxPieces then
      Exit;
  end;
  Result := True;
end;

end.
