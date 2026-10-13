unit HelloMain;

{ The form of HelloFastCanvas: animated 2D drawing on the left (a paint box repainted by a timer), a 3D viewport on the
  right (a lit, rotating cube over a floor) and, on top, a button with a shadow effect and a switch for ray-traced
  shadows. Every component is on the form in the designer; the code only draws and animates. }

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes, System.Math, System.Math.Vectors,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.Graphics, FMX.StdCtrls, FMX.Controls.Presentation, FMX.Objects,
  FMX.Layouts, FMX.Effects, FMX.Types3D, FMX.Controls3D, FMX.Objects3D, FMX.Viewport3D, FMX.MaterialSources;

type
  THelloForm = class(TForm)
    LayoutTop: TLayout;
    ButtonHello: TButton;
    ShadowEffectButton: TShadowEffect;
    CheckBoxShadows: TCheckBox;
    PaintBoxDrawing: TPaintBox;
    Viewport3D1: TViewport3D;
    Light1: TLight;
    Cube1: TCube;
    PlaneFloor: TPlane;
    LightMaterialSourceCube: TLightMaterialSource;
    LightMaterialSourceFloor: TLightMaterialSource;
    TimerAnimate: TTimer;
    procedure FormCreate(Sender: TObject);
    procedure PaintBoxDrawingPaint(Sender: TObject; Canvas: TCanvas);
    procedure TimerAnimateTimer(Sender: TObject);
    procedure CheckBoxShadowsChange(Sender: TObject);
  private
    FAngle: Single;
    function Describe: string;
  end;

var
  HelloForm: THelloForm;
  /// <summary>Set by the project when it installed FastCanvas (environment variable FC_STOCK=1: FMX's own canvas).
  /// </summary>
  FastCanvasInstalled: Boolean;

implementation

uses
  FastCanvas.Device, FastCanvas.Canvas, FastCanvas.Context3D12;

{$R *.fmx}

procedure THelloForm.FormCreate(Sender: TObject);
begin
  // The device is made on first use (the first canvas); what it is decides what the form offers.
  if FastCanvasInstalled then
    TFastDevice.Ensure;
  CheckBoxShadows.Enabled := FastCanvasInstalled and (TFastDevice.Backend = TFastCanvasBackend.D3D12) and
    TFastContext3D12.RayTracingSupported;
  Caption := 'Hello FastCanvas - ' + Describe;
end;

function THelloForm.Describe: string;
begin
  if not FastCanvasInstalled then
    Exit('FMX stock canvas');
  if TFastDevice.Backend = TFastCanvasBackend.D3D12 then
    Result := 'FastCanvas, Direct3D 12'
  else
    Result := 'FastCanvas, Direct3D 11';
  if FastCanvasPresentation = TFastCanvasPresentation.Composition then
    Result := Result + ', DirectComposition'
  else
    Result := Result + ', flip';
  case FastCanvasTextAntialias of
    TFastTextAntialias.ClearType: Result := Result + ', ClearType';
    TFastTextAntialias.Aliased: Result := Result + ', aliased text';
    TFastTextAntialias.System: Result := Result + ', system text antialiasing';
  end;
end;

procedure THelloForm.PaintBoxDrawingPaint(Sender: TObject; Canvas: TCanvas);
var
  R: TRectF;
  I: Integer;
  M: TMatrix;
  C: TPointF;
begin
  R := PaintBoxDrawing.LocalRect;
  R.Inflate(-12, -12);
  Canvas.Fill.Kind := TBrushKind.Gradient;
  Canvas.Fill.Gradient.Color := $FF2B5876;
  Canvas.Fill.Gradient.Color1 := $FF4E4376;
  Canvas.FillRect(R, 16, 16, AllCorners, 1);

  // A wave of translucent circles.
  Canvas.Fill.Kind := TBrushKind.Solid;
  C := R.CenterPoint;
  for I := 0 to 11 do
  begin
    Canvas.Fill.Color := TAlphaColorF.Create(0.5 + 0.5 * Sin(I + FAngle), 0.6, 1 - I / 12, 0.6).ToAlphaColor;
    Canvas.FillEllipse(TRectF.Create(C.X - 140 + I * 22, C.Y - 20 + 60 * Sin(FAngle + I / 2),
      C.X - 110 + I * 22, C.Y + 10 + 60 * Sin(FAngle + I / 2)), 1);
  end;

  // Rotating lines.
  M := Canvas.Matrix;
  Canvas.SetMatrix(TMatrix.CreateTranslation(-C.X, -C.Y) * TMatrix.CreateRotation(FAngle / 3) *
    TMatrix.CreateTranslation(C.X, C.Y) * M);
  Canvas.Stroke.Kind := TBrushKind.Solid;
  Canvas.Stroke.Color := $C0FFFFFF;
  Canvas.Stroke.Thickness := 2;
  for I := 0 to 7 do
    Canvas.DrawLine(PointF(C.X, C.Y), PointF(C.X + 180 * Cos(I * Pi / 4), C.Y + 180 * Sin(I * Pi / 4)), 0.5);
  Canvas.SetMatrix(M);

  Canvas.Fill.Color := TAlphaColors.White;
  Canvas.Font.Size := 22;
  Canvas.FillText(TRectF.Create(R.Left, R.Bottom - 70, R.Right, R.Bottom - 10), Describe, False, 1, [],
    TTextAlign.Center, TTextAlign.Center);
end;

procedure THelloForm.TimerAnimateTimer(Sender: TObject);
begin
  FAngle := FAngle + 0.03;
  Cube1.RotationAngle.Y := FAngle * 40;
  Cube1.RotationAngle.X := FAngle * 15;
  PaintBoxDrawing.Repaint;
end;

procedure THelloForm.CheckBoxShadowsChange(Sender: TObject);
begin
  // Every new 3D context starts with this; the viewport's current one takes it at its next scene.
  FastContext3DRayTracing.Shadows := CheckBoxShadows.IsChecked;
  if Viewport3D1.Context is TFastContext3D12 then
    TFastContext3D12(Viewport3D1.Context).RayShadows := CheckBoxShadows.IsChecked;
  Viewport3D1.Repaint;
end;

end.
