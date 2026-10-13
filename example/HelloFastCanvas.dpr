program HelloFastCanvas;

{ The smallest check of FastCanvas: a form with animated 2D drawing, standard controls and a 3D viewport with a lit,
  rotating cube over a floor. The title tells which canvas and graphics API draw the window.

  Environment variables: FC_BACKEND=11 (Direct3D 11 instead of 12), FC_PRESENT=flip (windows without
  DirectComposition), FC_STOCK=1 (FMX's own canvas, to compare). }

uses
  System.StartUpCopy,
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
  System.Types,
  System.UITypes,
  System.Math,
  System.Math.Vectors,
  FMX.Types,
  FMX.Forms,
  FMX.Graphics,
  FMX.Controls,
  FMX.StdCtrls,
  FMX.Objects,
  FMX.Layouts,
  FMX.Types3D,
  FMX.Controls3D,
  FMX.Objects3D,
  FMX.Viewport3D,
  FMX.MaterialSources,
  FMX.Effects,
  FastCanvas.Device,
  FastCanvas.Canvas,
  FastCanvas.Context3D11,
  FastCanvas.Context3D12;

type
  THelloForm = class(TForm)
  private
    FDrawing: TPaintBox;
    FViewport: TViewport3D;
    FCube: TCube;
    FShadows: TCheckBox;
    FTimer: TTimer;
    FAngle: Single;
    procedure DrawingPaint(Sender: TObject; Canvas: TCanvas);
    procedure Tick(Sender: TObject);
    procedure ShadowsChange(Sender: TObject);
    function Describe: string;
  public
    constructor Create(AOwner: TComponent); override;
  end;

var
  HelloForm: THelloForm;
  UseFastCanvas: Boolean;

constructor THelloForm.Create(AOwner: TComponent);
var
  Top: TLayout;
  Button: TButton;
  Material, FloorMaterial: TLightMaterialSource;
  Light: TLight;
  Floor: TPlane;
  Shadow: TShadowEffect;
begin
  // No form resource: the controls are made here.
  inherited CreateNew(AOwner);
  // The device is made on first use (the first canvas); what it is decides what the form offers.
  if UseFastCanvas then
    TFastDevice.Ensure;
  SetBounds(100, 100, 960, 600);
  Fill.Kind := TBrushKind.Solid;
  Fill.Color := $FF1E1F24;

  Top := TLayout.Create(Self);
  Top.Parent := Self;
  Top.Align := TAlignLayout.Top;
  Top.Height := 48;
  Top.Padding.Rect := TRectF.Create(12, 8, 12, 8);

  // Left-aligned controls line up by their position.
  Button := TButton.Create(Self);
  Button.Parent := Top;
  Button.Position.X := 0;
  Button.Align := TAlignLayout.Left;
  Button.Width := 140;
  Button.Text := 'A button';
  Shadow := TShadowEffect.Create(Self);
  Shadow.Parent := Button;

  FShadows := TCheckBox.Create(Self);
  FShadows.Parent := Top;
  FShadows.Position.X := 200;
  FShadows.Align := TAlignLayout.Left;
  FShadows.Margins.Left := 16;
  FShadows.Width := 300;
  FShadows.StyledSettings := FShadows.StyledSettings - [TStyledSetting.FontColor];
  FShadows.TextSettings.FontColor := TAlphaColors.White;
  FShadows.Text := 'Ray-traced shadows (DXR, Direct3D 12)';
  FShadows.Enabled := UseFastCanvas and (TFastDevice.Backend = TFastCanvasBackend.D3D12) and
    TFastContext3D12.RayTracingSupported;
  FShadows.OnChange := ShadowsChange;

  // Left: 2D drawing, repainted every frame.
  FDrawing := TPaintBox.Create(Self);
  FDrawing.Parent := Self;
  FDrawing.Align := TAlignLayout.Left;
  FDrawing.Width := 480;
  FDrawing.OnPaint := DrawingPaint;

  // Right: 3D.
  FViewport := TViewport3D.Create(Self);
  FViewport.Parent := Self;
  FViewport.Align := TAlignLayout.Client;
  FViewport.Color := TAlphaColors.Null;

  Material := TLightMaterialSource.Create(Self);
  Material.Diffuse := $FF3C8DDE;
  Material.Ambient := $FF203040;
  FloorMaterial := TLightMaterialSource.Create(Self);
  FloorMaterial.Diffuse := $FF808080;
  FloorMaterial.Ambient := $FF303030;
  FloorMaterial.Specular := $FF202020;

  Light := TLight.Create(Self);
  Light.Parent := FViewport;
  Light.LightType := TLightType.Point;
  Light.Position.Point := TPoint3D.Create(-4, -6, -6);

  FCube := TCube.Create(Self);
  FCube.Parent := FViewport;
  FCube.SetSize(2.5, 2.5, 2.5);
  FCube.Position.Point := TPoint3D.Create(0, -0.5, 0);
  FCube.MaterialSource := Material;

  Floor := TPlane.Create(Self);
  Floor.Parent := FViewport;
  Floor.SetSize(14, 14, 0.01);
  Floor.RotationAngle.X := 90;
  Floor.Position.Point := TPoint3D.Create(0, 1.5, 0);
  Floor.MaterialSource := FloorMaterial;

  FTimer := TTimer.Create(Self);
  FTimer.Interval := 15;
  FTimer.OnTimer := Tick;

  Caption := 'Hello FastCanvas - ' + Describe;
end;

function THelloForm.Describe: string;
begin
  if not UseFastCanvas then
    Exit('FMX stock canvas');
  if TFastDevice.Backend = TFastCanvasBackend.D3D12 then
    Result := 'FastCanvas, Direct3D 12'
  else
    Result := 'FastCanvas, Direct3D 11';
  if FastCanvasPresentation = TFastCanvasPresentation.Composition then
    Result := Result + ', DirectComposition'
  else
    Result := Result + ', flip';
end;

procedure THelloForm.DrawingPaint(Sender: TObject; Canvas: TCanvas);
var
  R: TRectF;
  I: Integer;
  M: TMatrix;
  C: TPointF;
begin
  R := FDrawing.LocalRect;
  R.Inflate(-12, -12);
  Canvas.Fill.Kind := TBrushKind.Gradient;
  Canvas.Fill.Gradient.Color := $FF2B5876;
  Canvas.Fill.Gradient.Color1 := $FF4E4376;
  Canvas.FillRect(R, 16, 16, AllCorners, 1);

  Canvas.Fill.Kind := TBrushKind.Solid;
  Canvas.Stroke.Kind := TBrushKind.Solid;
  C := R.CenterPoint;
  for I := 0 to 11 do
  begin
    Canvas.Fill.Color := TAlphaColorF.Create(0.5 + 0.5 * Sin(I + FAngle), 0.6, 1 - I / 12, 0.6).ToAlphaColor;
    Canvas.FillEllipse(TRectF.Create(C.X - 140 + I * 22, C.Y - 20 + 60 * Sin(FAngle + I / 2),
      C.X - 110 + I * 22, C.Y + 10 + 60 * Sin(FAngle + I / 2)), 1);
  end;

  // Rotating text and lines.
  M := Canvas.Matrix;
  Canvas.SetMatrix(TMatrix.CreateTranslation(-C.X, -C.Y) * TMatrix.CreateRotation(FAngle / 3) *
    TMatrix.CreateTranslation(C.X, C.Y) * M);
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

procedure THelloForm.Tick(Sender: TObject);
begin
  FAngle := FAngle + 0.03;
  FCube.RotationAngle.Y := FAngle * 40;
  FCube.RotationAngle.X := FAngle * 15;
  FDrawing.Repaint;
end;

procedure THelloForm.ShadowsChange(Sender: TObject);
begin
  // Every new 3D context starts with this; the viewport's current one takes it at its next scene.
  FastContext3DRayTracing.Shadows := FShadows.IsChecked;
  if FViewport.Context is TFastContext3D12 then
    TFastContext3D12(FViewport.Context).RayShadows := FShadows.IsChecked;
  FViewport.Repaint;
end;

begin
  // Per-monitor DPI awareness, which a project made in the IDE gets from its manifest (built from the command line,
  // this program has none, and Windows would scale its window as a bitmap).
  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  ReportMemoryLeaksOnShutdown := True;
  UseFastCanvas := GetEnvironmentVariable('FC_STOCK') <> '1';
  if UseFastCanvas then
  begin
    // Before Application.Initialize: the backend, then the canvas and the 3D context of the same backend.
    if GetEnvironmentVariable('FC_BACKEND') = '11' then
      FastCanvasBackend := TFastCanvasBackend.D3D11
    else
      FastCanvasBackend := TFastCanvasBackend.D3D12;
    if SameText(GetEnvironmentVariable('FC_PRESENT'), 'flip') then
      FastCanvasPresentation := TFastCanvasPresentation.Flip;
    InstallFastCanvas;
    if FastCanvasBackend = TFastCanvasBackend.D3D12 then
      InstallFastContext3D12
    else
      InstallFastContext3D11;
  end;
  Application.Initialize;
  Application.CreateForm(THelloForm, HelloForm);
  Application.Run;
end.
