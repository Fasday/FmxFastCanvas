unit Hello3DMain;

{ The form of HelloForm3D: a TForm3D, the whole window one 3D scene drawn by the 3D context of FastCanvas. Animated
  objects stand on a floor under a directional light, the camera swings around them, and a panel switches the
  ray-traced effects of Direct3D 12 (DirectX Raytracing 1.1). The panel is a TLayer3D in screen projection holding
  standard 2D controls. Every component is on the form in the designer; the code only applies the switches. }

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes, System.Math.Vectors,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.Forms3D, FMX.Types3D, FMX.Graphics, FMX.Controls3D, FMX.Objects3D,
  FMX.MaterialSources, FMX.Layers3D, FMX.Objects, FMX.StdCtrls, FMX.Controls.Presentation, FMX.Ani;

type
  THello3DForm = class(TForm3D)
    DummyCamera: TDummy;
    Camera1: TCamera;
    FloatAnimationCamera: TFloatAnimation;
    Light1: TLight;
    PlaneFloor: TPlane;
    CubeBlue: TCube;
    FloatAnimationCube: TFloatAnimation;
    SphereRed: TSphere;
    FloatAnimationSphere: TFloatAnimation;
    CylinderGreen: TCylinder;
    ConeYellow: TCone;
    MaterialFloor: TLightMaterialSource;
    MaterialBlue: TLightMaterialSource;
    MaterialRed: TLightMaterialSource;
    MaterialGreen: TLightMaterialSource;
    MaterialYellow: TLightMaterialSource;
    LayerPanel: TLayer3D;
    RectanglePanel: TRectangle;
    LabelTitle: TLabel;
    LabelStatus: TLabel;
    CheckBoxShadows: TCheckBox;
    CheckBoxSoft: TCheckBox;
    CheckBoxAO: TCheckBox;
    CheckBoxReflections: TCheckBox;
    CheckBoxFloor: TCheckBox;
    CheckBoxHdr: TCheckBox;
    LabelHdr: TLabel;
    procedure FormCreate(Sender: TObject);
    procedure RayTracingChange(Sender: TObject);
  private
    function Describe: string;
  end;

var
  Hello3DForm: THello3DForm;
  /// <summary>Set by the project when it installed FastCanvas (environment variable FC_STOCK=1: FMX's own 3D
  /// context).</summary>
  FastCanvasInstalled: Boolean;

implementation

uses
  FastCanvas.Device, FastCanvas.Context3D12;

{$R *.fmx}

procedure THello3DForm.FormCreate(Sender: TObject);
var
  Available: Boolean;
begin
  // The device is made on first use; what it is decides what the panel offers.
  if FastCanvasInstalled then
    TFastDevice.Ensure;
  Available := False;
  if not FastCanvasInstalled then
    LabelStatus.Text := 'FMX stock 3D context: no DXR'
  else if TFastDevice.Backend <> TFastCanvasBackend.D3D12 then
    LabelStatus.Text := 'Needs FastCanvas on Direct3D 12'
  else if not TFastContext3D12.RayTracingSupported then
    LabelStatus.Text := 'This GPU has no DXR tier 1.1'
  else
  begin
    Available := True;
    LabelStatus.Text := 'DirectX Raytracing 1.1';
  end;
  if not Available then
  begin
    CheckBoxShadows.IsChecked := False;
    CheckBoxSoft.IsChecked := False;
    CheckBoxAO.IsChecked := False;
    CheckBoxReflections.IsChecked := False;
  end;
  CheckBoxShadows.Enabled := Available;
  CheckBoxAO.Enabled := Available;
  CheckBoxReflections.Enabled := Available;
  Caption := 'Hello FastCanvas, TForm3D - ' + Describe;
  RayTracingChange(nil);
end;

function THello3DForm.Describe: string;
begin
  if not FastCanvasInstalled then
    Exit('FMX stock 3D context');
  if TFastDevice.Backend = TFastCanvasBackend.D3D12 then
    Result := 'FastCanvas, Direct3D 12'
  else
    Result := 'FastCanvas, Direct3D 11';
end;

procedure THello3DForm.RayTracingChange(Sender: TObject);
var
  Ray: TFastRayTracing;
begin
  if csLoading in ComponentState then
    Exit;
  CheckBoxSoft.Enabled := CheckBoxShadows.Enabled and CheckBoxShadows.IsChecked;
  PlaneFloor.Visible := CheckBoxFloor.IsChecked;
  Ray := FastContext3DRayTracing;
  Ray.Shadows := CheckBoxShadows.IsChecked;
  if CheckBoxSoft.IsChecked then
    Ray.ShadowSoftness := 0.05
  else
    Ray.ShadowSoftness := 0;
  Ray.AmbientOcclusion := CheckBoxAO.IsChecked;
  Ray.Reflections := CheckBoxReflections.IsChecked;
  // New 3D contexts start with it; the form's current one takes it at its next scene.
  FastContext3DRayTracing := Ray;
  if Context is TFastContext3D12 then
    TFastContext3D12(Context).RayTracing := Ray;
  Invalidate;
end;

end.
