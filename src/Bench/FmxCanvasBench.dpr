program FmxCanvasBench;

{$APPTYPE CONSOLE}
{$R WinApp.res}

uses
  Winapi.Windows,
  System.SysUtils,
  System.StrUtils,
  System.StartUpCopy,
  FMX.Forms,
  Common.Timing in '..\Common\Common.Timing.pas',
  Common.Stats in '..\Common\Common.Stats.pas',
  Common.Csv in '..\Common\Common.Csv.pas',
  Common.Env in '..\Common\Common.Env.pas',
  Common.Profiler in '..\Common\Common.Profiler.pas',
  FastCanvas.D2D1Ext in '..\Canvas\FastCanvas.D2D1Ext.pas',
  FastCanvas.Service in '..\Canvas\FastCanvas.Service.pas',
  FastCanvas.RenderQueue in '..\Canvas\FastCanvas.RenderQueue.pas',
  FastCanvas.Bridge in '..\Canvas\FastCanvas.Bridge.pas',
  FastCanvas.DWriteExt in '..\Canvas\FastCanvas.DWriteExt.pas',
  FastCanvas.DCompExt in '..\Canvas\FastCanvas.DCompExt.pas',
  FastCanvas.DeviceVk in '..\Canvas\FastCanvas.DeviceVk.pas',
  FastCanvas.Device in '..\Canvas\FastCanvas.Device.pas',
  FastCanvas.Hdr in '..\Canvas\FastCanvas.Hdr.pas',
  FastCanvas.Gpu in '..\Canvas\FastCanvas.Gpu.pas',
  FastCanvas.Gpu11 in '..\Canvas\FastCanvas.Gpu11.pas',
  FastCanvas.Gpu12 in '..\Canvas\FastCanvas.Gpu12.pas',
  FastCanvas.GpuVk in '..\Canvas\FastCanvas.GpuVk.pas',
  FastCanvas.Text in '..\Canvas\FastCanvas.Text.pas',
  FastCanvas.Canvas in '..\Canvas\FastCanvas.Canvas.pas',
  FastCanvas.Context3D in '..\Canvas\FastCanvas.Context3D.pas',
  FastCanvas.Context3D11 in '..\Canvas\FastCanvas.Context3D11.pas',
  FastCanvas.Context3D12 in '..\Canvas\FastCanvas.Context3D12.pas',
  FastCanvas.Context3DVk in '..\Canvas\FastCanvas.Context3DVk.pas',
  Bench.Config in 'Bench.Config.pas',
  Bench.Canvases in 'Bench.Canvases.pas',
  Bench.Canvases.Builtin in 'Bench.Canvases.Builtin.pas',
  Bench.Canvases.Fast in 'Bench.Canvases.Fast.pas',
  Bench.Scenes in 'Bench.Scenes.pas',
  Bench.Scenes.Synthetic in 'Bench.Scenes.Synthetic.pas',
  Bench.Scenes.Text in 'Bench.Scenes.Text.pas',
  Bench.Scenes.Shapes in 'Bench.Scenes.Shapes.pas',
  Bench.Scenes.Paths in 'Bench.Scenes.Paths.pas',
  Bench.Scenes.Bitmaps in 'Bench.Scenes.Bitmaps.pas',
  Bench.Scenes.AA in 'Bench.Scenes.AA.pas',
  Bench.Scenes.Rare in 'Bench.Scenes.Rare.pas',
  Bench.Scenes.Controls in 'Bench.Scenes.Controls.pas',
  Bench.Scenes.Lists in 'Bench.Scenes.Lists.pas',
  Bench.Scenes.View3D in 'Bench.Scenes.View3D.pas',
  Bench.Results in 'Bench.Results.pas',
  Bench.Screenshot in 'Bench.Screenshot.pas',
  Bench.Form in 'Bench.Form.pas';

procedure PrintList;
var
  C: TBenchCanvasInfo;
  S: TBenchSceneClass;
  M: TMonitorDesc;
  I: Integer;
begin
  Writeln('Monitors (--monitor=<index>):');
  I := 0;
  for M in EnumMonitors do
  begin
    Inc(I);
    Writeln(Format('  %d  %-14s %dx%d at (%d,%d)%s', [I, M.Device, M.Bounds.Width, M.Bounds.Height,
      M.Bounds.Left, M.Bounds.Top, IfThen(M.Primary, ' primary', '')]));
  end;
  Writeln('Canvases:');
  for C in BenchCanvases do
    Writeln(Format('  %-10s %-16s %s', [C.Name, C.ExpectedClass, C.Description]));
  Writeln('Scenes (N for light/medium/heavy):');
  for S in BenchScenes do
    Writeln(Format('  %-14s %6d %6d %6d  %s', [S.Name, S.DefaultN(TBenchPreset.Light),
      S.DefaultN(TBenchPreset.Medium), S.DefaultN(TBenchPreset.Heavy), S.Description]));
end;

const
  // Runs are serialized machine-wide: parallel runs would overlap on screen (screenshots read the
  // screen) and disturb each other's timings.
  RunMutexName = 'Local\FmxCanvasBench.Run';

var
  Canvas: TBenchCanvasInfo;
  Monitor: TMonitorDesc;
  BenchForm: TBenchForm;
  RunMutex: THandle;
begin
  {$IFDEF LEAKCHECK}
  // A build with -Define LEAKCHECK reports leaked memory when the process ends.
  ReportMemoryLeaksOnShutdown := True;
  {$ENDIF}
  try
    BenchConfig := ParseCommandLine;
  except
    on E: EBenchConfig do
    begin
      Writeln(ErrOutput, 'ERROR: ' + E.Message);
      Writeln(ErrOutput, UsageText);
      ExitCode := 2;
      Exit;
    end;
  end;
  if BenchConfig.HelpOnly then
  begin
    Writeln(UsageText);
    Exit;
  end;
  if BenchConfig.ListOnly then
  begin
    PrintList;
    Exit;
  end;
  Canvas := FindBenchCanvas(BenchConfig.CanvasName);
  if Canvas = nil then
  begin
    Writeln(ErrOutput, 'ERROR: unknown canvas "' + BenchConfig.CanvasName + '" (see --list)');
    ExitCode := 2;
    Exit;
  end;
  if FindBenchScene(BenchConfig.SceneName) = nil then
  begin
    Writeln(ErrOutput, 'ERROR: unknown scene "' + BenchConfig.SceneName + '" (see --list)');
    ExitCode := 2;
    Exit;
  end;
  if not FindMonitor(BenchConfig.Monitor, Monitor) then
  begin
    Writeln(ErrOutput, 'ERROR: unknown monitor "' + BenchConfig.Monitor + '" (see --list)');
    ExitCode := 2;
    Exit;
  end;

  RunMutex := CreateMutex(nil, False, RunMutexName);
  if RunMutex = 0 then
    RaiseLastOSError;
  // WAIT_ABANDONED means a previous run died holding the mutex; the mutex is ours anyway.
  WaitForSingleObject(RunMutex, INFINITE);
  try
    CalibrateCycleFrequency;
    // The canvas must be chosen before Application.Initialize (FMX.Graphics.TCanvasManager).
    ResetGlobals(BenchConfig);
    Canvas.Setup(BenchConfig);

    Application.Initialize;
    Application.CreateForm(TBenchForm, BenchForm);
    Application.Run;
    ExitCode := BenchExitCode;
  finally
    ReleaseMutex(RunMutex);
    CloseHandle(RunMutex);
  end;
end.
