program HelloForm3D;

{ FastCanvas in a TForm3D: open HelloForm3D.dproj in RAD Studio (Win64) and run it. The title of the window tells
  which 3D context draws it; the panel switches the ray-traced effects (Direct3D 12, DXR 1.1) and HDR output.

  Environment variables: FC_BACKEND=11 (Direct3D 11 instead of 12: no ray tracing, no HDR), FC_STOCK=1 (FMX's own 3D
  context, to compare), FC_HDR=force (the HDR switch gives HDR output on any display, also an SDR one). }

uses
  System.StartUpCopy,
  System.SysUtils,
  FMX.Forms,
  FastCanvas.Device,
  FastCanvas.Canvas,
  FastCanvas.Hdr,
  FastCanvas.Context3D11,
  FastCanvas.Context3D12,
  Hello3DMain in 'Hello3DMain.pas' {Hello3DForm};

{$R *.res}

begin
  ReportMemoryLeaksOnShutdown := True;
  // Before Application.Initialize: the graphics API, then the canvas (it draws the 2D controls of the panel) and the
  // 3D context of the same API.
  if GetEnvironmentVariable('FC_STOCK') <> '1' then
  begin
    if GetEnvironmentVariable('FC_BACKEND') = '11' then
      FastCanvasBackend := TFastCanvasBackend.D3D11
    else
      FastCanvasBackend := TFastCanvasBackend.D3D12;
    InstallFastCanvas;
    if FastCanvasBackend = TFastCanvasBackend.D3D12 then
      InstallFastContext3D12
    else
      InstallFastContext3D11;
    FastCanvasInstalled := True;
  end;
  // HDR output (the form's HDR switch sets FastCanvasHdr at run time): on displays in HDR mode, or everywhere.
  if SameText(GetEnvironmentVariable('FC_HDR'), 'force') then
    HdrOnMode := Ord(TFastCanvasHdr.Force)
  else
    HdrOnMode := Ord(TFastCanvasHdr.Auto);
  Application.Initialize;
  Application.CreateForm(THello3DForm, Hello3DForm);
  Application.Run;
end.
