program HelloForm3D;

{ FastCanvas in a TForm3D: open HelloForm3D.dproj in RAD Studio (Win64) and run it. The title of the window tells
  which 3D context draws it; the panel switches the ray-traced effects (Direct3D 12, DXR 1.1) and HDR output.

  Environment variables: FC_BACKEND=11 (Direct3D 11 instead of 12: no ray tracing, no HDR), FC_STOCK=1 (FMX's own 3D
  context, to compare), FC_HDR=force (the HDR switch gives HDR output on any display, also an SDR one), FC_DRED=0|1
  (DRED breadcrumbs off, or on every card; default: NVIDIA cards), FC_DLSS=quality|balanced|performance|ultra|dlaa
  (DLSS on at the start, in that mode).
  DLSS diagnostics and variants (FastCanvas.Dlss): FC_DLSS_JITTER=off|-x|-y|-xy, FC_DLSS_VIEW=input|motion,
  FC_DLSS_EMULATE=1|accumulate (a simple shader instead of NVIDIA's DLSS, on any Direct3D 12 card: with
  FC_DLSS_VIEW=motion it shows the motion vectors), FC_DLSS_CAMERA_MOTION=0 (no camera motion for the background),
  FC_DLSS_PRESET=j|k|l|m (NVIDIA's model), FC_DLSS_EXPOSURE=fixed (no auto exposure).
  DLSS (NVIDIA RTX): nvngx_dlss.dll of the DLSS SDK next to the program. }

uses
  System.StartUpCopy,
  System.SysUtils,
  FMX.Forms,
  FastCanvas.Device,
  FastCanvas.Canvas,
  FastCanvas.Hdr,
  FastCanvas.Context3D11,
  FastCanvas.Context3D12,
  FastCanvas.Dlss,
  Hello3DMain in 'Hello3DMain.pas' {Hello3DForm};

{$R *.res}

var
  Emulate: string;

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
    // DRED breadcrumbs on NVIDIA cards (a ray tracing structure build hung on an RTX 5080 with driver 610.88 without
    // them); FC_DRED=0: off, FC_DRED=1: on every card.
    if GetEnvironmentVariable('FC_DRED') = '0' then
      FastCanvasD3D12Breadcrumbs := TFastCanvasBreadcrumbs.Off
    else if GetEnvironmentVariable('FC_DRED') = '1' then
      FastCanvasD3D12Breadcrumbs := TFastCanvasBreadcrumbs.On
    else
      FastCanvasD3D12Breadcrumbs := TFastCanvasBreadcrumbs.Nvidia;
    // DLSS on at the start: FC_DLSS=quality|balanced|performance|ultra|dlaa (the panel shows it).
    if SameText(GetEnvironmentVariable('FC_DLSS'), 'quality') then
      FastContext3DDlssMode := TFastDlssMode.Quality
    else if SameText(GetEnvironmentVariable('FC_DLSS'), 'balanced') then
      FastContext3DDlssMode := TFastDlssMode.Balanced
    else if SameText(GetEnvironmentVariable('FC_DLSS'), 'performance') then
      FastContext3DDlssMode := TFastDlssMode.Performance
    else if SameText(GetEnvironmentVariable('FC_DLSS'), 'ultra') then
      FastContext3DDlssMode := TFastDlssMode.UltraPerformance
    else if SameText(GetEnvironmentVariable('FC_DLSS'), 'dlaa') then
      FastContext3DDlssMode := TFastDlssMode.DLAA;
    // Diagnostics of DLSS: FC_DLSS_JITTER=off|-x|-y|-xy, FC_DLSS_VIEW=input|motion, FC_DLSS_EMULATE=1|accumulate
    // (any card), FC_DLSS_CAMERA_MOTION=0; variants: FC_DLSS_PRESET=j|k|l|m, FC_DLSS_EXPOSURE=fixed.
    if SameText(GetEnvironmentVariable('FC_DLSS_JITTER'), 'off') then
      FastDlssJitterTest := TFastDlssJitterTest.Off
    else if SameText(GetEnvironmentVariable('FC_DLSS_JITTER'), '-x') then
      FastDlssJitterTest := TFastDlssJitterTest.NegateX
    else if SameText(GetEnvironmentVariable('FC_DLSS_JITTER'), '-y') then
      FastDlssJitterTest := TFastDlssJitterTest.NegateY
    else if SameText(GetEnvironmentVariable('FC_DLSS_JITTER'), '-xy') then
      FastDlssJitterTest := TFastDlssJitterTest.NegateXY;
    if SameText(GetEnvironmentVariable('FC_DLSS_VIEW'), 'input') then
      FastDlssView := TFastDlssView.Input
    else if SameText(GetEnvironmentVariable('FC_DLSS_VIEW'), 'motion') then
      FastDlssView := TFastDlssView.Motion;
    Emulate := GetEnvironmentVariable('FC_DLSS_EMULATE');
    if SameText(Emulate, 'accumulate') then
      FastDlssEmulate := TFastDlssEmulation.Accumulate
    else if (Emulate <> '') and (Emulate <> '0') then
      FastDlssEmulate := TFastDlssEmulation.Temporal;
    if GetEnvironmentVariable('FC_DLSS_CAMERA_MOTION') = '0' then
      FastDlssCameraMotion := False;
    if SameText(GetEnvironmentVariable('FC_DLSS_PRESET'), 'j') then
      FastDlssPreset := TFastDlssPreset.J
    else if SameText(GetEnvironmentVariable('FC_DLSS_PRESET'), 'k') then
      FastDlssPreset := TFastDlssPreset.K
    else if SameText(GetEnvironmentVariable('FC_DLSS_PRESET'), 'l') then
      FastDlssPreset := TFastDlssPreset.L
    else if SameText(GetEnvironmentVariable('FC_DLSS_PRESET'), 'm') then
      FastDlssPreset := TFastDlssPreset.M;
    if SameText(GetEnvironmentVariable('FC_DLSS_EXPOSURE'), 'fixed') then
      FastDlssAutoExposure := False;
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
