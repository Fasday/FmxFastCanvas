unit Bench.Scenes;

{ Scene base classes and registry.

  A scene is created once per run, builds its content in Setup and is advanced once per frame.
  Advance must derive the whole animation state from the frame number alone, so that a given
  frame looks the same on every canvas (screenshots are compared across canvases). }

interface

uses
  System.Types, System.UITypes, System.Classes, System.Generics.Collections,
  FMX.Types, FMX.Controls, FMX.Graphics, FMX.Forms, Bench.Config;

type
  /// <summary>Deterministic xorshift64* generator, independent of System.Random.</summary>
  TBenchRandom = record
  private
    FState: UInt64;
  public
    constructor Create(const ASeed: UInt64);
    function NextU32: Cardinal;
    function NextFloat: Single;  // [0, 1)
    function Range(const AMin, AMax: Single): Single;
    function RangeInt(const AMin, AMax: Integer): Integer; // inclusive
    function Color(const AAlpha: Byte = $FF): TAlphaColor;
  end;

  /// <summary>Item that drifts on a small Lissajous path; shared by the synthetic scenes so that
  /// all of them animate the same way.</summary>
  TMovingItem = record
    X, Y: Single;      // normalized centre, 0..1
    W, H: Single;      // logical pixels
    Phase: Single;
    Color: TAlphaColor;
  end;

  TBenchScene = class
  private
    FForm: TCustomForm;
    FN: Integer;
    FFrame: Int64;
    FTime: Double;
  protected
    /// <summary>Called after FFrame/FTime are updated.</summary>
    procedure DoAdvance; virtual;
  public
    constructor Create(const AForm: TCustomForm; const AN: Integer); virtual;
    class function Name: string; virtual; abstract;
    class function Description: string; virtual; abstract;
    class function DefaultN(const APreset: TBenchPreset): Integer; virtual; abstract;
    /// <summary>Creates controls and precomputes content. The form already has its final size.</summary>
    procedure Setup; virtual; abstract;
    /// <summary>Sets the animation state for AFrame; ATime = AFrame / nominal fps, seconds.</summary>
    procedure Advance(const AFrame: Int64; const ATime: Double);
    property Form: TCustomForm read FForm;
    property N: Integer read FN;
    property Frame: Int64 read FFrame;
    property Time: Double read FTime;
  end;

  TBenchSceneClass = class of TBenchScene;

  TBenchPaintScene = class;

  /// <summary>Full-client control that forwards Paint to its scene.</summary>
  TBenchPaintControl = class(TControl)
  private
    FScene: TBenchPaintScene;
  protected
    procedure Paint; override;
  end;

  /// <summary>Synthetic scene that draws directly on the canvas of one control.</summary>
  TBenchPaintScene = class(TBenchScene)
  private
    FControl: TBenchPaintControl;
  protected
    procedure Draw(const ACanvas: TCanvas; const ARect: TRectF); virtual; abstract;
  public
    procedure Setup; override;
    property Control: TBenchPaintControl read FControl;
  end;

const
  SceneMotionAmplitude = 24; // logical pixels

/// <summary>Fills AItems with ACount items: centre uniform in 0..1, size AMinSize..AMaxSize,
/// random phase and opaque random color.</summary>
procedure GenerateMovingItems(var AItems: TArray<TMovingItem>; const ACount: Integer; const ASeed: UInt64;
  const AMinSize, AMaxSize: Single);
/// <summary>Rectangle of the item at ATime inside ABounds.</summary>
function MovingItemRect(const AItem: TMovingItem; const ABounds: TRectF; const ATime: Double): TRectF;

procedure RegisterBenchScene(const AClass: TBenchSceneClass);
function FindBenchScene(const AName: string): TBenchSceneClass;
function BenchScenes: TArray<TBenchSceneClass>;

implementation

uses
  System.SysUtils;

procedure GenerateMovingItems(var AItems: TArray<TMovingItem>; const ACount: Integer; const ASeed: UInt64;
  const AMinSize, AMaxSize: Single);
var
  Rnd: TBenchRandom;
  I: Integer;
begin
  Rnd := TBenchRandom.Create(ASeed);
  SetLength(AItems, ACount);
  for I := 0 to ACount - 1 do
  begin
    AItems[I].X := Rnd.NextFloat;
    AItems[I].Y := Rnd.NextFloat;
    AItems[I].W := Rnd.Range(AMinSize, AMaxSize);
    AItems[I].H := Rnd.Range(AMinSize, AMaxSize);
    AItems[I].Phase := Rnd.Range(0, 2 * Pi);
    AItems[I].Color := Rnd.Color;
  end;
end;

function MovingItemRect(const AItem: TMovingItem; const ABounds: TRectF; const ATime: Double): TRectF;
var
  CX, CY: Single;
begin
  CX := ABounds.Left + AItem.X * ABounds.Width + Sin(ATime * 2.0 + AItem.Phase) * SceneMotionAmplitude;
  CY := ABounds.Top + AItem.Y * ABounds.Height + Cos(ATime * 1.5 + AItem.Phase) * SceneMotionAmplitude;
  Result := TRectF.Create(CX - AItem.W * 0.5, CY - AItem.H * 0.5, CX + AItem.W * 0.5, CY + AItem.H * 0.5);
end;

var
  GScenes: TList<TBenchSceneClass>;

{ TBenchRandom }

constructor TBenchRandom.Create(const ASeed: UInt64);
begin
  FState := ASeed;
  if FState = 0 then
    FState := $9E3779B97F4A7C15;
end;

function TBenchRandom.NextU32: Cardinal;
var
  X: UInt64;
begin
  X := FState;
  X := X xor (X shr 12);
  X := X xor (X shl 25);
  X := X xor (X shr 27);
  FState := X;
  Result := Cardinal((X * UInt64($2545F4914F6CDD1D)) shr 32);
end;

function TBenchRandom.NextFloat: Single;
begin
  Result := (NextU32 shr 8) / 16777216.0;
end;

function TBenchRandom.Range(const AMin, AMax: Single): Single;
begin
  Result := AMin + (AMax - AMin) * NextFloat;
end;

function TBenchRandom.RangeInt(const AMin, AMax: Integer): Integer;
begin
  Result := AMin + Integer(NextU32 mod Cardinal(AMax - AMin + 1));
end;

function TBenchRandom.Color(const AAlpha: Byte): TAlphaColor;
begin
  Result := (TAlphaColor(AAlpha) shl 24) or (NextU32 and $FFFFFF);
end;

{ TBenchScene }

constructor TBenchScene.Create(const AForm: TCustomForm; const AN: Integer);
begin
  inherited Create;
  FForm := AForm;
  FN := AN;
end;

procedure TBenchScene.Advance(const AFrame: Int64; const ATime: Double);
begin
  FFrame := AFrame;
  FTime := ATime;
  DoAdvance;
end;

procedure TBenchScene.DoAdvance;
begin
end;

{ TBenchPaintControl }

procedure TBenchPaintControl.Paint;
begin
  if FScene <> nil then
    FScene.Draw(Canvas, LocalRect);
end;

{ TBenchPaintScene }

procedure TBenchPaintScene.Setup;
begin
  FControl := TBenchPaintControl.Create(Form);
  FControl.FScene := Self;
  FControl.HitTest := False;
  FControl.Align := TAlignLayout.Client;
  FControl.Parent := Form;
end;

{ Registry }

procedure RegisterBenchScene(const AClass: TBenchSceneClass);
begin
  if FindBenchScene(AClass.Name) <> nil then
    raise EArgumentException.CreateFmt('Scene "%s" is already registered', [AClass.Name]);
  GScenes.Add(AClass);
end;

function FindBenchScene(const AName: string): TBenchSceneClass;
var
  C: TBenchSceneClass;
begin
  for C in GScenes do
    if SameText(C.Name, AName) then
      Exit(C);
  Result := nil;
end;

function BenchScenes: TArray<TBenchSceneClass>;
begin
  Result := GScenes.ToArray;
end;

initialization
  GScenes := TList<TBenchSceneClass>.Create;
finalization
  GScenes.Free;
end.
