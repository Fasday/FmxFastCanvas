program HelloFastCanvas;

{ The smallest check of FastCanvas: open HelloFastCanvas.dproj in RAD Studio (Win64) and run it. The title of the
  window tells which canvas and graphics API draw it.

  Environment variables: FC_BACKEND=11 (Direct3D 11 instead of 12), FC_PRESENT=flip (windows without
  DirectComposition), FC_TEXT=cleartype|aliased|system (text antialiasing instead of grayscale), FC_STOCK=1 (FMX's
  own canvas, to compare). }

uses
  System.StartUpCopy,
  System.SysUtils,
  FMX.Forms,
  FastCanvas.Device,
  FastCanvas.Canvas,
  FastCanvas.Context3D11,
  FastCanvas.Context3D12,
  HelloMain in 'HelloMain.pas' {HelloForm};

{$R *.res}

begin
  ReportMemoryLeaksOnShutdown := True;
  // Before Application.Initialize: the graphics API, then the canvas and the 3D context of the same API.
  if GetEnvironmentVariable('FC_STOCK') <> '1' then
  begin
    if GetEnvironmentVariable('FC_BACKEND') = '11' then
      FastCanvasBackend := TFastCanvasBackend.D3D11
    else
      FastCanvasBackend := TFastCanvasBackend.D3D12;
    if SameText(GetEnvironmentVariable('FC_PRESENT'), 'flip') then
      FastCanvasPresentation := TFastCanvasPresentation.Flip;
    if SameText(GetEnvironmentVariable('FC_TEXT'), 'cleartype') then
      FastCanvasTextAntialias := TFastTextAntialias.ClearType
    else if SameText(GetEnvironmentVariable('FC_TEXT'), 'aliased') then
      FastCanvasTextAntialias := TFastTextAntialias.Aliased
    else if SameText(GetEnvironmentVariable('FC_TEXT'), 'system') then
      FastCanvasTextAntialias := TFastTextAntialias.System;
    InstallFastCanvas;
    if FastCanvasBackend = TFastCanvasBackend.D3D12 then
      InstallFastContext3D12
    else
      InstallFastContext3D11;
    FastCanvasInstalled := True;
  end;
  Application.Initialize;
  Application.CreateForm(THelloForm, HelloForm);
  Application.Run;
end.
