unit Bench.Scenes.View3D;

{ 3D inside a 2D form.

  viewport3d  TViewport3D (Align Client) with N rotating cubes and spheres, lit by one directional light.
              Every frame the viewport renders its scene with the default TContext3D into a texture,
              copies it into a TBitmap (Context.CopyToBitmap, FMX.Viewport3D.pas:258) and draws the bitmap
              with the form canvas (FMX.Viewport3D.pas:264). With the stock D2D canvas the copy goes
              through the CPU; FastCanvas copies on the GPU.
  shadows3d   TViewport3D with a floor, N rotating cubes, spheres and cones above it, a directional and a point
              light: the scene of the ray-traced shadows (FastCanvas.Context3D12, variant fcdx12rt); without them
              it is a plain lit scene.
  mirror3d    shadows3d with shiny materials: a floor with a white specular color (Shininess 96), half of the
              objects shiny (white specular, Shininess 64), a quarter textured (checkerboard): the scene of the
              ray-traced reflections (variant fcdx12refl). }

interface

implementation

uses
  System.Types, System.UITypes, System.Math, System.Math.Vectors, FMX.Types, FMX.Controls, FMX.Controls3D,
  FMX.Objects3D, FMX.Viewport3D, FMX.MaterialSources, FMX.Types3D, FMX.Graphics, Bench.Config, Bench.Scenes;

const
  MaterialCount = 8;

type
  TItem3D = record
    Obj: TControl3D;
    Phase: Single;
    Speed: Single;
  end;

  TViewport3DScene = class(TBenchScene)
  private
    FViewport: TViewport3D;
    FLight: TLight;
    FMaterials: array[0..MaterialCount - 1] of TLightMaterialSource;
    FItems: TArray<TItem3D>;
  protected
    procedure DoAdvance; override;
  public
    class function Name: string; override;
    class function Description: string; override;
    class function DefaultN(const APreset: TBenchPreset): Integer; override;
    procedure Setup; override;
  end;

  TShadows3DScene = class(TBenchScene)
  private
    FViewport: TViewport3D;
    FMaterials: array[0..MaterialCount - 1] of TLightMaterialSource;
    FItems: TArray<TItem3D>;
  protected
    procedure DoAdvance; override;
    class function Shiny: Boolean; virtual;
  public
    class function Name: string; override;
    class function Description: string; override;
    class function DefaultN(const APreset: TBenchPreset): Integer; override;
    procedure Setup; override;
  end;

  TMirror3DScene = class(TShadows3DScene)
  protected
    class function Shiny: Boolean; override;
  public
    class function Name: string; override;
    class function Description: string; override;
  end;

{ TViewport3DScene }

class function TViewport3DScene.Name: string;
begin
  Result := 'viewport3d';
end;

class function TViewport3DScene.Description: string;
begin
  Result := 'TViewport3D, N rotating lit cubes and spheres (3D rendered and copied into the 2D form)';
end;

class function TViewport3DScene.DefaultN(const APreset: TBenchPreset): Integer;
begin
  // D2D throughput frame: ~4 / ~9 / ~20 ms (copy of the 1920x1080 viewport through the CPU ~3.5 ms plus
  // ~35 us per object, measured 2026-10-06).
  case APreset of
    TBenchPreset.Light: Result := 20;
    TBenchPreset.Heavy: Result := 480;
  else
    Result := 160;
  end;
end;

procedure TViewport3DScene.Setup;
var
  Rnd: TBenchRandom;
  I, Cols, Rows: Integer;
  Obj: TControl3D;
begin
  Rnd := TBenchRandom.Create(31);
  FViewport := TViewport3D.Create(Form);
  FViewport.Align := TAlignLayout.Client;
  FViewport.Color := TAlphaColors.White;
  FViewport.HitTest := False;
  FViewport.Parent := Form;

  FLight := TLight.Create(FViewport);
  FLight.LightType := TLightType.Directional;
  FLight.RotationAngle.X := -40;
  FLight.RotationAngle.Y := 30;
  FLight.Parent := FViewport;

  for I := 0 to MaterialCount - 1 do
  begin
    FMaterials[I] := TLightMaterialSource.Create(FViewport);
    FMaterials[I].Diffuse := TAlphaColor($FF000000) or (Rnd.NextU32 and $FFFFFF);
    FMaterials[I].Ambient := $FF202020;
  end;

  // A grid that fills the default design camera view (camera at z = -20 looking at the origin).
  Cols := Max(1, Ceil(Sqrt(N * 16 / 9)));
  Rows := Max(1, Ceil(N / Cols));
  SetLength(FItems, N);
  for I := 0 to N - 1 do
  begin
    if Odd(I) then
      Obj := TSphere.Create(FViewport)
    else
      Obj := TCube.Create(FViewport);
    Obj.Width := 22 / Cols * 0.6;
    Obj.Height := Obj.Width;
    Obj.Depth := Obj.Width;
    Obj.Position.X := -11 + 22 * ((I mod Cols) + 0.5) / Cols;
    Obj.Position.Y := -6.2 + 12.4 * ((I div Cols) + 0.5) / Rows;
    Obj.Position.Z := Rnd.Range(-1, 1);
    Obj.HitTest := False;
    if Obj is TCube then
      TCube(Obj).MaterialSource := FMaterials[I mod MaterialCount]
    else
      TSphere(Obj).MaterialSource := FMaterials[I mod MaterialCount];
    Obj.Parent := FViewport;
    FItems[I].Obj := Obj;
    FItems[I].Phase := Rnd.Range(0, 360);
    FItems[I].Speed := Rnd.Range(30, 90);
  end;
end;

procedure TViewport3DScene.DoAdvance;
var
  I: Integer;
begin
  // TControl3D applies a change of RotationAngle as an incremental rotation of its quaternion
  // (FMX.Controls3D.pas:758-793), so the orientation would depend on the frame history. Reset it and set
  // both angles at once: the orientation is then a function of Time only.
  for I := 0 to High(FItems) do
  begin
    FItems[I].Obj.ResetRotationAngle;
    FItems[I].Obj.RotationAngle.Point := TPoint3D.Create(FItems[I].Phase * 0.5 + Time * FItems[I].Speed * 0.5,
      FItems[I].Phase + Time * FItems[I].Speed, 0);
  end;
end;

{ TShadows3DScene }

/// <summary>A 64 x 64 checkerboard of 8-pixel squares into ABitmap.</summary>
procedure Checker(const ABitmap: TBitmap; const A, B: TAlphaColor);
var
  D: TBitmapData;
  X, Y: Integer;
begin
  ABitmap.SetSize(64, 64);
  if ABitmap.Map(TMapAccess.Write, D) then
  try
    for Y := 0 to 63 do
      for X := 0 to 63 do
        if Odd(X div 8 + Y div 8) then
          D.SetPixel(X, Y, A)
        else
          D.SetPixel(X, Y, B);
  finally
    ABitmap.Unmap(D);
  end;
end;

class function TShadows3DScene.Shiny: Boolean;
begin
  Result := False;
end;

class function TShadows3DScene.Name: string;
begin
  Result := 'shadows3d';
end;

class function TShadows3DScene.Description: string;
begin
  Result := 'TViewport3D, a floor and N rotating objects above it, a directional and a point light';
end;

class function TShadows3DScene.DefaultN(const APreset: TBenchPreset): Integer;
begin
  case APreset of
    TBenchPreset.Light: Result := 8;
    TBenchPreset.Heavy: Result := 120;
  else
    Result := 32;
  end;
end;

procedure TShadows3DScene.Setup;
var
  Rnd: TBenchRandom;
  I, Cols, Rows: Integer;
  Obj: TControl3D;
  Floor: TPlane;
  FloorMat: TLightMaterialSource;
  Sun, Lamp: TLight;
  Size: Single;
begin
  Rnd := TBenchRandom.Create(47);
  FViewport := TViewport3D.Create(Form);
  FViewport.Align := TAlignLayout.Client;
  FViewport.Color := TAlphaColors.Lightsteelblue;
  FViewport.HitTest := False;
  FViewport.Multisample := TMultisample.FourSamples;
  FViewport.Parent := Form;

  // Y grows downward in FMX 3D: the floor lies below the objects, tilted toward the camera (at z = -20).
  Sun := TLight.Create(FViewport);
  Sun.LightType := TLightType.Directional;
  Sun.RotationAngle.X := -55;
  Sun.RotationAngle.Y := 35;
  Sun.Parent := FViewport;
  Lamp := TLight.Create(FViewport);
  Lamp.LightType := TLightType.Point;
  Lamp.Color := $FFFFE0C0;
  Lamp.Position.Point := TPoint3D.Create(-6, -5, -3);
  Lamp.Parent := FViewport;

  FloorMat := TLightMaterialSource.Create(FViewport);
  FloorMat.Diffuse := $FFE8E8E8;
  FloorMat.Ambient := $FF303030;
  if Shiny then
  begin
    FloorMat.Diffuse := $FFB0B8C0;
    FloorMat.Specular := TAlphaColors.White;
    FloorMat.Shininess := 96;
  end;
  Floor := TPlane.Create(FViewport);
  Floor.Width := 40;
  Floor.Height := 40;
  Floor.Position.Point := TPoint3D.Create(0, 3, 0);
  Floor.RotationAngle.X := 70;
  Floor.MaterialSource := FloorMat;
  Floor.HitTest := False;
  Floor.Parent := FViewport;

  for I := 0 to MaterialCount - 1 do
  begin
    FMaterials[I] := TLightMaterialSource.Create(FViewport);
    FMaterials[I].Diffuse := TAlphaColor($FF000000) or (Rnd.NextU32 and $FFFFFF);
    FMaterials[I].Ambient := $FF202020;
    if Shiny and Odd(I) then
    begin
      FMaterials[I].Specular := TAlphaColors.White;
      FMaterials[I].Shininess := 64;
    end;
    if Shiny and (I mod 4 = 0) then
      Checker(FMaterials[I].Texture, TAlphaColors.White, FMaterials[I].Diffuse);
  end;
  Cols := Max(1, Ceil(Sqrt(N * 2)));
  Rows := Max(1, Ceil(N / Cols));
  Size := Min(2.4, 18 / Cols * 0.6);
  SetLength(FItems, N);
  for I := 0 to N - 1 do
  begin
    case I mod 3 of
      0: Obj := TCube.Create(FViewport);
      1: Obj := TSphere.Create(FViewport);
    else
      Obj := TCone.Create(FViewport);
    end;
    Obj.Width := Size;
    Obj.Height := Size;
    Obj.Depth := Size;
    Obj.Position.X := -9 + 18 * ((I mod Cols) + 0.5) / Cols;
    Obj.Position.Y := 0.5 - 2.5 * ((I div Cols) + 0.5) / Rows;
    Obj.Position.Z := -4 + 8 * ((I div Cols) + 0.5) / Rows;
    Obj.HitTest := False;
    TCustomMesh(Obj).MaterialSource := FMaterials[I mod MaterialCount];
    Obj.Parent := FViewport;
    FItems[I].Obj := Obj;
    FItems[I].Phase := Rnd.Range(0, 360);
    FItems[I].Speed := Rnd.Range(20, 60);
  end;
end;

procedure TShadows3DScene.DoAdvance;
var
  I: Integer;
begin
  for I := 0 to High(FItems) do
  begin
    FItems[I].Obj.ResetRotationAngle;
    FItems[I].Obj.RotationAngle.Point := TPoint3D.Create(FItems[I].Phase * 0.5 + Time * FItems[I].Speed * 0.5,
      FItems[I].Phase + Time * FItems[I].Speed, 0);
  end;
end;

{ TMirror3DScene }

class function TMirror3DScene.Shiny: Boolean;
begin
  Result := True;
end;

class function TMirror3DScene.Name: string;
begin
  Result := 'mirror3d';
end;

class function TMirror3DScene.Description: string;
begin
  Result := 'shadows3d with a shiny floor, shiny and textured objects (ray-traced reflections)';
end;

initialization
  RegisterBenchScene(TViewport3DScene);
  RegisterBenchScene(TShadows3DScene);
  RegisterBenchScene(TMirror3DScene);
end.
