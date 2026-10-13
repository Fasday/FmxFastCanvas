unit Hello3DMain;

{ The form of HelloForm3D: a TForm3D, the whole window one 3D scene drawn by the 3D context of FastCanvas. Animated
  objects stand on a floor under a directional light, a lamp floats above them, the camera swings around them, and a
  panel switches the ray-traced effects of Direct3D 12 (DirectX Raytracing 1.1) and HDR output. The panel is a
  TLayer3D in screen projection holding standard 2D controls.

  HDR: with HDR output on a display in HDR mode (Windows HDR on) the window gets an FP16 scRGB swap chain; the scene
  looks as in SDR, and the lamp, drawn with TFastContext3D12.DrawIntensity, shines brighter than SDR white, up to the
  display's peak. Every component is on the form in the designer; the code applies the switches and draws the lamp
  brighter. }

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes, System.Math, System.Math.Vectors,
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
    DummyLamp: TDummy;
    LightLamp: TLight;
    SphereLamp: TSphere;
    FloatAnimationLamp: TFloatAnimation;
    MaterialFloor: TLightMaterialSource;
    MaterialBlue: TLightMaterialSource;
    MaterialRed: TLightMaterialSource;
    MaterialGreen: TLightMaterialSource;
    MaterialYellow: TLightMaterialSource;
    MaterialLamp: TColorMaterialSource;
    TimerHdr: TTimer;
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
    procedure HdrChange(Sender: TObject);
    procedure TimerHdrTimer(Sender: TObject);
    procedure DummyLampRender(Sender: TObject; Context: TContext3D);
    procedure SphereLampRender(Sender: TObject; Context: TContext3D);
  private
    /// <summary>How bright the lamp is drawn, in SDR white: the display's headroom with HDR output, else 1.</summary>
    FLampIntensity: Single;
    function Describe: string;
    procedure UpdateHdr;
  end;

var
  Hello3DForm: THello3DForm;
  /// <summary>Set by the project when it installed FastCanvas (environment variable FC_STOCK=1: FMX's own 3D
  /// context).</summary>
  FastCanvasInstalled: Boolean;
  /// <summary>What the HDR switch turns on: Auto (HDR output on displays in HDR mode), or Force (environment variable
  /// FC_HDR=force: on every display, to try it on an SDR one, where values above SDR white clip).</summary>
  HdrOnMode: Integer;

implementation

uses
  FastCanvas.Device, FastCanvas.Canvas, FastCanvas.Context3D12, FastCanvas.Hdr;

{$R *.fmx}

procedure THello3DForm.FormCreate(Sender: TObject);
var
  Available: Boolean;
begin
  FLampIntensity := 1;
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
  // HDR output: FastCanvas on Direct3D 12.
  if not FastCanvasInstalled or (TFastDevice.Backend <> TFastCanvasBackend.D3D12) then
  begin
    CheckBoxHdr.IsChecked := False;
    CheckBoxHdr.Enabled := False;
  end;
  Caption := 'Hello FastCanvas, TForm3D - ' + Describe;
  RayTracingChange(nil);
  HdrChange(nil);
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

procedure THello3DForm.HdrChange(Sender: TObject);
begin
  if csLoading in ComponentState then
    Exit;
  // Read at every frame: the window's next frame gets the other swap chain.
  if CheckBoxHdr.IsChecked then
    FastCanvasHdr := TFastCanvasHdr(HdrOnMode)
  else
    FastCanvasHdr := TFastCanvasHdr.Off;
  UpdateHdr;
  Invalidate;
end;

procedure THello3DForm.TimerHdrTimer(Sender: TObject);
begin
  // The window may have moved to another display, Windows HDR or the SDR brightness may have changed.
  UpdateHdr;
end;

procedure THello3DForm.UpdateHdr;
var
  Info: TFastHdrInfo;
begin
  if not CheckBoxHdr.Enabled then
  begin
    LabelHdr.Text := 'Needs FastCanvas on Direct3D 12';
    FLampIntensity := 1;
    Exit;
  end;
  Info := FastCanvasHdrInfo(Self);
  if Info.Output then
  begin
    // The lamp at the display's peak (Headroom: peak / SDR white; 1 when the display does not say).
    FLampIntensity := Max(Info.Headroom, 1);
    LabelHdr.Text := Format('On: the lamp at %.1fx SDR white', [FLampIntensity]);
  end
  else
  begin
    FLampIntensity := 1;
    if not CheckBoxHdr.IsChecked then
      LabelHdr.Text := 'Off'
    else
      LabelHdr.Text := 'This display is SDR (Windows HDR off)';
  end;
end;

procedure THello3DForm.DummyLampRender(Sender: TObject; Context: TContext3D);
begin
  // Before the lamp (a child of this dummy) is drawn: brighter than white, and no shadows of its own.
  if Context is TFastContext3D12 then
  begin
    TFastContext3D12(Context).DrawIntensity := FLampIntensity;
    TFastContext3D12(Context).RayInclude := False;
  end;
end;

procedure THello3DForm.SphereLampRender(Sender: TObject; Context: TContext3D);
begin
  // After the lamp is drawn: the next objects as usual.
  if Context is TFastContext3D12 then
  begin
    TFastContext3D12(Context).DrawIntensity := 1;
    TFastContext3D12(Context).RayInclude := True;
  end;
end;

end.
