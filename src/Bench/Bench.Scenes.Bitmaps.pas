unit Bench.Scenes.Bitmaps;

{ Bitmap and clipping scenes.

  bitmaps       N icons drawn with DrawBitmap at 1:1 physical pixels (destination = source size / canvas
                scale), moving, so positions are fractional. 30% of them with opacity < 1.
  bitmapscaled  The same icons scaled 0.5..4x (30% non-uniform), slowly pulsing, so every draw
                goes through the canvas' filtering path.
  clip          N panels, each with three nested SaveState/IntersectClipRect levels and shapes that
                overflow every clip. 25% of the panels are rotated (non-axis-aligned clip), 30% are
                drawn with opacity < 1.

  What the scenes stress:
  - D2D wraps the cached shared bitmap for the window target on every DrawBitmap
    (FMX.Canvas.D2D.pas:2353 -> :1068) and pushes a layer, not an axis-aligned clip, for every
    IntersectClipRect, rotated or not (:1785-1796).
  - The GPU canvas flushes its batch on every texture change (FMX.Canvas.GPU.Helpers.pas:321-327),
    so interleaved icons cost one draw call each, and on every clip change (:198-206). Its scissor
    clip is built from two transformed corners (FMX.Canvas.GPU.pas:606-612), so rotated panels are
    clipped wrongly.

  The 8 source icons (32x32 and 48x48) are computed per pixel in Setup from signed distance
  functions with 1 px analytic anti-aliasing, so no asset files are needed. FMX bitmaps hold
  premultiplied alpha (D2D: D2D1_ALPHA_MODE_PREMULTIPLIED, FMX.Canvas.D2D.pas:1064; GDI+:
  PixelFormat32bppPARGB, FMX.Canvas.GDIP.pas:1091; Skia: TSkImageInfo defaults to Premul,
  System.Skia.pas:4932) and TBitmapData.SetPixel stores the color as is (FMX.Types.pas:2886-2890),
  so the pixels are premultiplied here. }

interface

implementation

uses
  System.SysUtils, System.Types, System.UITypes, System.Math, System.Math.Vectors, FMX.Types, FMX.Graphics,
  Bench.Config, Bench.Scenes;

const
  IconCount = 8;
  IconSizes: array[0..IconCount - 1] of Integer = (32, 48, 32, 48, 32, 48, 32, 48);
  MinScale = 0.5;
  MaxScale = 4.0;

type
  /// <summary>Premultiplied color accumulator, components 0..1.</summary>
  TPremulColor = record
    R, G, B, A: Single;
    /// <summary>Composites a straight-alpha color with the given alpha (coverage included) over Self.</summary>
    procedure Over(const AR, AG, AB, AAlpha: Single);
    function ToAlphaColor: TAlphaColor;
  end;

  TBitmapItem = record
    Icon: Integer;
    Opacity: Single;
    ScaleX, ScaleY: Single;
  end;

  TBitmapsScene = class(TBenchPaintScene)
  private
    FIcons: array[0..IconCount - 1] of TBitmap;
    FMoves: TArray<TMovingItem>;
    FItems: TArray<TBitmapItem>;
    procedure CreateIcons;
    procedure GenerateItems(const ASeed: UInt64);
  protected
    class function Scaled: Boolean; virtual;
    procedure Draw(const ACanvas: TCanvas; const ARect: TRectF); override;
  public
    destructor Destroy; override;
    class function Name: string; override;
    class function Description: string; override;
    class function DefaultN(const APreset: TBenchPreset): Integer; override;
    procedure Setup; override;
  end;

  TBitmapScaledScene = class(TBitmapsScene)
  protected
    class function Scaled: Boolean; override;
  public
    class function Name: string; override;
    class function Description: string; override;
    class function DefaultN(const APreset: TBenchPreset): Integer; override;
  end;

  TClipPanel = record
    Opacity: Single;
    Angle: Single;  // radians, 0 = axis-aligned
    Colors: array[0..5] of TAlphaColor;
  end;

  TClipScene = class(TBenchPaintScene)
  private
    FMoves: TArray<TMovingItem>;
    FPanels: TArray<TClipPanel>;
    procedure DrawPanel(const ACanvas: TCanvas; const APanel: TClipPanel; const APhase: Single; const R: TRectF);
  protected
    procedure Draw(const ACanvas: TCanvas; const ARect: TRectF); override;
  public
    class function Name: string; override;
    class function Description: string; override;
    class function DefaultN(const APreset: TBenchPreset): Integer; override;
    procedure Setup; override;
  end;

{ Icon rendering }

procedure TPremulColor.Over(const AR, AG, AB, AAlpha: Single);
var
  K: Single;
begin
  if AAlpha <= 0 then
    Exit;
  K := 1 - AAlpha;
  R := AR * AAlpha + R * K;
  G := AG * AAlpha + G * K;
  B := AB * AAlpha + B * K;
  A := AAlpha + A * K;
end;

function TPremulColor.ToAlphaColor: TAlphaColor;
var
  A8: Integer;

  function Channel(const AValue: Single): Cardinal;
  begin
    // Premultiplied: a color channel never exceeds alpha.
    Result := Min(EnsureRange(Round(AValue * 255), 0, 255), A8);
  end;

begin
  A8 := EnsureRange(Round(A * 255), 0, 255);
  Result := (Cardinal(A8) shl 24) or (Channel(R) shl 16) or (Channel(G) shl 8) or Channel(B);
end;

/// <summary>Coverage of a pixel by a shape with signed distance ADist (negative inside), 1 px ramp.</summary>
function Coverage(const ADist: Single): Single;
begin
  Result := EnsureRange(0.5 - ADist, 0, 1);
end;

function CircleDist(const PX, PY, CX, CY, R: Single): Single;
begin
  Result := Sqrt(Sqr(PX - CX) + Sqr(PY - CY)) - R;
end;

function RoundBoxDist(const PX, PY, CX, CY, HalfW, HalfH, R: Single): Single;
var
  QX, QY: Single;
begin
  QX := Abs(PX - CX) - (HalfW - R);
  QY := Abs(PY - CY) - (HalfH - R);
  Result := Sqrt(Sqr(Max(QX, 0)) + Sqr(Max(QY, 0))) + Min(Max(QX, QY), 0) - R;
end;

function Lerp(const A, B, T: Single): Single; inline;
begin
  Result := A + (B - A) * T;
end;

/// <summary>Premultiplied color of the pixel centred at (PX, PY) of icon AKind with side ASize.</summary>
function ShadeIcon(const AKind, ASize: Integer; const PX, PY: Single): TAlphaColor;
const
  InvSqrt2 = 0.70710678;
  Third = 2.0943951; // 2 * Pi / 3
var
  P: TPremulColor;
  C, S, D, T, Angle, Len: Single;
begin
  P := Default(TPremulColor);
  S := ASize;
  C := S * 0.5;
  case AKind of
    0: // Orb: radial gradient disc with a soft highlight.
      begin
        T := EnsureRange(Sqrt(Sqr(PX - C * 0.7) + Sqr(PY - C * 0.7)) / S * 1.4, 0, 1);
        P.Over(Lerp(1.0, 0.65, T), Lerp(0.55, 0.10, T), Lerp(0.25, 0.05, T), Coverage(CircleDist(PX, PY, C, C, C - 1.5)));
        P.Over(1, 1, 1, 0.55 * Coverage(CircleDist(PX, PY, C * 0.7, C * 0.62, S * 0.14)));
      end;
    1: // Tile: rounded square, vertical gradient, inner light border.
      begin
        D := RoundBoxDist(PX, PY, C, C, C - 2, C - 2, 9);
        T := PY / S;
        P.Over(Lerp(0.20, 0.05, T), Lerp(0.55, 0.25, T), Lerp(0.95, 0.60, T), Coverage(D));
        P.Over(1, 1, 1, 0.6 * Coverage(Abs(D + 3.5) - 0.75));
      end;
    2: // Ring with the hue running around it.
      begin
        Angle := ArcTan2(PY - C, PX - C);
        D := Abs(Sqrt(Sqr(PX - C) + Sqr(PY - C)) - (C - 5)) - 3;
        P.Over(0.5 + 0.5 * Cos(Angle), 0.5 + 0.5 * Cos(Angle - Third), 0.5 + 0.5 * Cos(Angle + Third), Coverage(D));
      end;
    3: // Diamond with a gradient and a dark outline.
      begin
        D := (Abs(PX - C) + Abs(PY - C) - (C - 3)) * InvSqrt2;
        T := PY / S;
        P.Over(Lerp(1.0, 0.95, T), Lerp(0.85, 0.45, T), Lerp(0.20, 0.05, T), Coverage(D));
        P.Over(0.35, 0.20, 0.0, Coverage(Abs(D + 0.75) - 0.75));
      end;
    4: // Button with a soft drop shadow: wide semi-transparent alpha ramp.
      begin
        Len := Sqrt(Sqr(PX - C - 2) + Sqr(PY - C - 3));
        P.Over(0, 0, 0, 0.6 * Exp(-Sqr(Len) / (2 * Sqr(S * 0.22))) * EnsureRange(1 - Len / C, 0, 1));
        P.Over(0.30, 0.80, 0.45, Coverage(CircleDist(PX, PY, C - 1, C - 1.5, S * 0.3)));
      end;
    5: // Play button: disc and a white triangle (max of three half-plane distances).
      begin
        P.Over(0.15, 0.65, 0.30, Coverage(CircleDist(PX, PY, C, C, C - 2)));
        Len := Sqrt(Sqr(11) + Sqr(19));
        D := Max((C - 7) - PX, Max(((PX - (C - 7)) * 11 - (PY - (C - 11)) * 19) / Len,
          ((PX - (C + 12)) * 11 + (PY - C) * 19) / Len));
        P.Over(1, 1, 1, Coverage(D));
      end;
    6: // Two overlapping translucent circles.
      begin
        P.Over(0.90, 0.15, 0.20, 0.75 * Coverage(CircleDist(PX, PY, C - 5, C - 2, C * 0.58)));
        P.Over(0.15, 0.35, 0.95, 0.75 * Coverage(CircleDist(PX, PY, C + 5, C + 3, C * 0.58)));
      end;
  else // Badge: outlined rounded square with a gradient and a plus sign.
    begin
      D := RoundBoxDist(PX, PY, C, C, C - 3, C - 3, 6);
      T := PY / S;
      P.Over(0.15, 0.05, 0.25, Coverage(D));
      P.Over(Lerp(0.70, 0.40, T), Lerp(0.35, 0.10, T), Lerp(0.95, 0.60, T), Coverage(D + 1.25));
      D := Min(RoundBoxDist(PX, PY, C, C, 10, 3, 1), RoundBoxDist(PX, PY, C, C, 3, 10, 1));
      P.Over(1, 1, 1, Coverage(D));
    end;
  end;
  Result := P.ToAlphaColor;
end;

procedure RenderIcon(const ABitmap: TBitmap; const AKind: Integer);
var
  Data: TBitmapData;
  X, Y: Integer;
begin
  if not ABitmap.Map(TMapAccess.Write, Data) then
    raise Exception.CreateFmt('Cannot map icon %d for writing', [AKind]);
  try
    for Y := 0 to Data.Height - 1 do
      for X := 0 to Data.Width - 1 do
        Data.SetPixel(X, Y, ShadeIcon(AKind, Data.Width, X + 0.5, Y + 0.5));
  finally
    ABitmap.Unmap(Data);
  end;
end;

{ TBitmapsScene }

destructor TBitmapsScene.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(FIcons) do
    FIcons[I].Free;
  inherited;
end;

class function TBitmapsScene.Name: string;
begin
  Result := 'bitmaps';
end;

class function TBitmapsScene.Description: string;
begin
  Result := 'DrawBitmap 1:1 physical px, 8 procedural 32/48 px icons with alpha, 30% opacity < 1';
end;

class function TBitmapsScene.DefaultN(const APreset: TBenchPreset): Integer;
begin
  // D2D throughput frame: ~2 / ~9 / ~20 ms (0.73 us per bitmap, measured 2026-10-06).
  case APreset of
    TBenchPreset.Light: Result := 2400;
    TBenchPreset.Heavy: Result := 26500;
  else
    Result := 11500;
  end;
end;

class function TBitmapsScene.Scaled: Boolean;
begin
  Result := False;
end;

procedure TBitmapsScene.Setup;
begin
  inherited;
  CreateIcons;
  if Scaled then
    GenerateItems(21)
  else
    GenerateItems(20);
end;

procedure TBitmapsScene.CreateIcons;
var
  I: Integer;
begin
  for I := 0 to IconCount - 1 do
  begin
    FIcons[I] := TBitmap.Create(IconSizes[I], IconSizes[I]);
    RenderIcon(FIcons[I], I);
  end;
end;

procedure TBitmapsScene.GenerateItems(const ASeed: UInt64);
var
  Rnd: TBenchRandom;
  I: Integer;
begin
  // Only the motion (X, Y, Phase) of the moving items is used; size comes from the icon.
  GenerateMovingItems(FMoves, N, ASeed, 0, 0);
  Rnd := TBenchRandom.Create(ASeed + 1000);
  SetLength(FItems, N);
  for I := 0 to N - 1 do
  begin
    FItems[I].Icon := Rnd.RangeInt(0, IconCount - 1);
    if Rnd.NextFloat < 0.3 then
      FItems[I].Opacity := Rnd.Range(0.35, 0.85)
    else
      FItems[I].Opacity := 1;
    if Scaled then
    begin
      // Log-uniform, so that downscaling and upscaling are equally common.
      FItems[I].ScaleX := MinScale * Power(MaxScale / MinScale, Rnd.NextFloat);
      if Rnd.NextFloat < 0.3 then
        FItems[I].ScaleY := MinScale * Power(MaxScale / MinScale, Rnd.NextFloat)
      else
        FItems[I].ScaleY := FItems[I].ScaleX;
    end
    else
    begin
      FItems[I].ScaleX := 1;
      FItems[I].ScaleY := 1;
    end;
  end;
end;

procedure TBitmapsScene.Draw(const ACanvas: TCanvas; const ARect: TRectF);
var
  I: Integer;
  Bmp: TBitmap;
  Center: TPointF;
  InvScale, Pulse, HalfW, HalfH: Single;
begin
  // Source size / canvas scale = 1:1 in physical pixels, as TImage draws a MultiResBitmap item.
  InvScale := 1 / ACanvas.Scale;
  for I := 0 to High(FItems) do
  begin
    Bmp := FIcons[FItems[I].Icon];
    Center := MovingItemRect(FMoves[I], ARect, Time).CenterPoint;
    if Scaled then
      Pulse := 1 + 0.08 * Sin(Time * 1.3 + FMoves[I].Phase)
    else
      Pulse := 1;
    HalfW := 0.5 * Bmp.Width * InvScale * FItems[I].ScaleX * Pulse;
    HalfH := 0.5 * Bmp.Height * InvScale * FItems[I].ScaleY * Pulse;
    ACanvas.DrawBitmap(Bmp, TRectF.Create(0, 0, Bmp.Width, Bmp.Height),
      TRectF.Create(Center.X - HalfW, Center.Y - HalfH, Center.X + HalfW, Center.Y + HalfH), FItems[I].Opacity, False);
  end;
end;

{ TBitmapScaledScene }

class function TBitmapScaledScene.Name: string;
begin
  Result := 'bitmapscaled';
end;

class function TBitmapScaledScene.Description: string;
begin
  Result := 'Same icons as bitmaps, scaled 0.5..4x (30% non-uniform), pulsing 8%: filtered draws';
end;

class function TBitmapScaledScene.DefaultN(const APreset: TBenchPreset): Integer;
begin
  // D2D throughput frame: ~2 / ~9 / ~20 ms (0.8 us per bitmap, measured 2026-10-06).
  case APreset of
    TBenchPreset.Light: Result := 2200;
    TBenchPreset.Heavy: Result := 24000;
  else
    Result := 10800;
  end;
end;

class function TBitmapScaledScene.Scaled: Boolean;
begin
  Result := True;
end;

{ TClipScene }

class function TClipScene.Name: string;
begin
  Result := 'clip';
end;

class function TClipScene.Description: string;
begin
  Result := 'N panels, 3 nested SaveState/IntersectClipRect levels, 25% rotated, 30% opacity < 1';
end;

class function TClipScene.DefaultN(const APreset: TBenchPreset): Integer;
begin
  // D2D throughput frame: ~2 / ~9 / ~20 ms (~120 us per panel, measured 2026-10-06).
  case APreset of
    TBenchPreset.Light: Result := 15;
    TBenchPreset.Heavy: Result := 165;
  else
    Result := 75;
  end;
end;

procedure TClipScene.Setup;
var
  Rnd: TBenchRandom;
  I, J: Integer;
  Angle: Single;
begin
  inherited;
  GenerateMovingItems(FMoves, N, 30, 70, 170);
  Rnd := TBenchRandom.Create(31);
  SetLength(FPanels, N);
  for I := 0 to N - 1 do
  begin
    if Rnd.NextFloat < 0.3 then
      FPanels[I].Opacity := Rnd.Range(0.4, 0.85)
    else
      FPanels[I].Opacity := 1;
    if Rnd.NextFloat < 0.25 then
    begin
      // Two statements: the compilers order the calls of one expression differently (Win32 and Win64 drew other
      // angles).
      Angle := Rnd.Range(0.1, 0.5);
      FPanels[I].Angle := Angle * (2 * Rnd.RangeInt(0, 1) - 1);
    end
    else
      FPanels[I].Angle := 0;
    // Light background, darker header, saturated content.
    FPanels[I].Colors[0] := TAlphaColor($FFC0C0C0) or (Rnd.NextU32 and $3F3F3F);
    FPanels[I].Colors[1] := TAlphaColor($FF000000) or (Rnd.NextU32 and $7F7F7F);
    for J := 2 to High(FPanels[I].Colors) do
      FPanels[I].Colors[J] := Rnd.Color;
  end;
end;

procedure TClipScene.DrawPanel(const ACanvas: TCanvas; const APanel: TClipPanel; const APhase: Single;
  const R: TRectF);
var
  State1, State2, State3: TCanvasSaveState;
  Center: TPointF;
  Inner, Cell: TRectF;
  Op, Slide, HeaderH, X: Single;
begin
  Center := R.CenterPoint;
  Op := APanel.Opacity;
  Slide := Sin(Time * 2.5 + APhase) * R.Width * 0.25;
  HeaderH := R.Height * 0.18;
  State1 := ACanvas.SaveState;
  try
    if APanel.Angle <> 0 then
      ACanvas.MultiplyMatrix(TMatrix.CreateTranslation(-Center.X, -Center.Y) *
        TMatrix.CreateRotation(APanel.Angle + 0.2 * Sin(Time + APhase)) * TMatrix.CreateTranslation(Center.X, Center.Y));
    // Level 1: the panel; the header overflows it on both sides.
    ACanvas.IntersectClipRect(R);
    ACanvas.Fill.Color := APanel.Colors[0];
    ACanvas.FillRect(R, 0, 0, [], Op);
    ACanvas.Fill.Color := APanel.Colors[1];
    ACanvas.FillRect(TRectF.Create(R.Left - 10, R.Top, R.Right + 10, R.Top + HeaderH), 0, 0, [], Op);

    // Level 2: content area; a sliding bar and a round rect overflow it.
    Inner := TRectF.Create(R.Left + 6, R.Top + HeaderH + 4, R.Right - 6, R.Bottom - 6);
    State2 := ACanvas.SaveState;
    try
      ACanvas.IntersectClipRect(Inner);
      ACanvas.Fill.Color := APanel.Colors[2];
      ACanvas.FillRect(TRectF.Create(Inner.Left - 20 + Slide, Inner.Top + 4, Inner.Right + 20 + Slide,
        Inner.Top + Inner.Height * 0.3), 0, 0, [], Op);
      ACanvas.Fill.Color := APanel.Colors[3];
      ACanvas.FillRect(TRectF.Create(Inner.CenterPoint.X - Slide * 0.5, Inner.CenterPoint.Y, Inner.Right + 25,
        Inner.Bottom + 25), 10, 10, AllCorners, Op);

      // Level 3: bottom-left cell; a round rect and a sliding vertical bar overflow it.
      Cell := TRectF.Create(Inner.Left + 4, Inner.CenterPoint.Y + 2, Inner.CenterPoint.X - 2, Inner.Bottom - 4);
      State3 := ACanvas.SaveState;
      try
        ACanvas.IntersectClipRect(Cell);
        ACanvas.Fill.Color := APanel.Colors[4];
        ACanvas.FillRect(TRectF.Create(Cell.Left - 15, Cell.Top + Cell.Height * 0.4 + Slide * 0.2, Cell.Right + 15,
          Cell.Bottom + 30), 8, 8, AllCorners, Op);
        X := Cell.CenterPoint.X + Slide * 0.4;
        ACanvas.Fill.Color := APanel.Colors[5];
        ACanvas.FillRect(TRectF.Create(X - 5, Cell.Top - 20, X + 5, Cell.Bottom + 20), 0, 0, [], Op);
      finally
        ACanvas.RestoreState(State3);
      end;
    finally
      ACanvas.RestoreState(State2);
    end;
  finally
    ACanvas.RestoreState(State1);
  end;
end;

procedure TClipScene.Draw(const ACanvas: TCanvas; const ARect: TRectF);
var
  I: Integer;
begin
  ACanvas.Fill.Kind := TBrushKind.Solid;
  for I := 0 to High(FPanels) do
    DrawPanel(ACanvas, FPanels[I], FMoves[I].Phase, MovingItemRect(FMoves[I], ARect, Time));
end;

initialization
  RegisterBenchScene(TBitmapsScene);
  RegisterBenchScene(TBitmapScaledScene);
  RegisterBenchScene(TClipScene);
end.
