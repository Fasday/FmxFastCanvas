unit Bench.Form;

{ Benchmark form: drives frames, times PaintRects and collects samples.

  Frame time split (BenchConfig.Split = True): PaintRects calls Canvas.BeginScene before inherited
  and Canvas.EndScene after it. The inner pair in TCustomForm.PaintRects then only changes the
  scene counter, so DoBeginScene/DoEndScene (BeginDraw, flush, EndDraw, Present) run in our calls
  (FMX.Graphics.pas:6432-6464). The clip rects passed to our BeginScene are computed exactly as
  TCustomForm.AddUpdateRects would (FMX.Forms.pas:6434-6464).

  Frame loop:
  - throughput: after each PaintRects a message is posted to a private window; its handler
    advances the scene and invalidates the form. Invalidating inside PaintRects would trigger a
    second PaintRects in the same WM_PAINT (FMX.Platform.Win.pas:1803-1811).
  - paced: the FMX animation clock (IFMXDisplayLinkService) advances the scene and invalidates. }

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Classes, System.Types, System.UITypes,
  System.Generics.Collections, FMX.Types, FMX.Forms, FMX.Graphics, FMX.DisplayLink,
  Common.Env, Bench.Config, Bench.Canvases, Bench.Scenes, Bench.Results;

type
  TBenchState = (Starting, Warmup, Measure, Screenshot, Done);

  TBenchForm = class(TForm)
  private const
    WM_BENCH_NEXT = WM_APP + 1;
    WM_BENCH_SHOTFRAME = WM_APP + 2;
    WM_BENCH_SHOT = WM_APP + 3;
    WM_BENCH_FINISH = WM_APP + 4;
    StallTimeoutMs = 15000;
    MaxSizeAttempts = 3;
  private
    FConfig: TBenchConfig;
    FMonitor: TMonitorDesc;
    FInfo: TRunInfo;
    FSceneClass: TBenchSceneClass;
    FScene: TBenchScene;
    FState: TBenchState;
    FFinished: Boolean;
    FMsgWnd: HWND;
    FWatchdog: TTimer;
    FDisplayLink: IFMXDisplayLinkService;
    FSubscribed: Boolean;
    FFrame: Int64;
    FSizeAttempts: Integer;
    FShotFrameRequested: Boolean;
    FShotPosted: Boolean;
    FFrameRequested: Boolean;
    FExtraPaints: Integer;
    FSamples: TArray<TFrameSample>;
    FSampleCount: Integer;
    FDisplayLinkDeltas: TList<Double>;
    FPrevStart: Int64;
    FPrevCycles: UInt64;
    FLastActivity: Int64;
    FWarmupStart: Int64;
    FWarmupFrames: Integer;
    FMeasureStart: Int64;
    FLastDeviceLoss: Int64;
    FDurationTicks: Int64;
    FThreadCpuStart: Double;
    FProcessCpuStart: Double;
    FRenderStart: Double;
    function Wnd: HWND;
    function ClientSizePx: TSize;
    procedure ApplyClientSize;
    procedure PlaceWindow;
    function WindowPlaced: Boolean;
    function SceneClipRects(const AUpdateRects: array of TRectF): TClipRects;
    procedure FramePainted(const AStart, ABegin, ARecord, AEnd, ATotal: Int64;
      const AStartCycles, APaintCycles: UInt64);
    procedure BeginWarmup(const AStart: Int64);
    procedure BeginMeasure(const AStart: Int64);
    procedure EndMeasure;
    procedure RequestFrame;
    procedure SetDisplayLink(const AOn: Boolean);
    procedure DisplayLinkTick(const ATime, ADeltaTime: Double);
    procedure TakeScreenshot;
    procedure Finish;
    procedure Fail(const AMessage: string);
    procedure WndMethod(var AMsg: TMessage);
    procedure WatchdogTimer(Sender: TObject);
    procedure FormClosing(Sender: TObject; var Action: TCloseAction);
    procedure StartProfile;
    procedure AppException(Sender: TObject; E: Exception);
  protected
    procedure PaintRects(const UpdateRects: array of TRectF); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  end;

var
  /// <summary>Set by the program before Application.CreateForm.</summary>
  BenchConfig: TBenchConfig;
  /// <summary>Process exit code chosen by the form.</summary>
  BenchExitCode: Integer = 0;

implementation

uses
  System.Math, System.DateUtils, Winapi.Dwmapi, Winapi.MultiMon, FMX.Platform, FMX.Platform.Win, FMX.Controls,
  FMX.TextLayout, Common.Timing, Common.Csv, Common.Profiler, Bench.Screenshot;

{ TBenchForm }

constructor TBenchForm.Create(AOwner: TComponent);
var
  N: Integer;
begin
  inherited CreateNew(AOwner);
  FConfig := BenchConfig;
  FInfo.Config := FConfig;
  FInfo.StartedUtc := TTimeZone.Local.ToUniversalTime(Now);
  FInfo.Canvas := FindBenchCanvas(FConfig.CanvasName);
  FInfo.RenderMs := -1;
  FSceneClass := FindBenchScene(FConfig.SceneName);
  FInfo.SceneName := FSceneClass.Name;
  FInfo.CycleHz := CycleFrequency;
  FDisplayLinkDeltas := TList<Double>.Create;
  FDurationTicks := Round(FConfig.DurationSec * QpcFrequency);
  SetLength(FSamples, Ceil(FConfig.DurationSec * 4000) + 1024);

  Caption := Format('FmxCanvasBench - %s / %s / %s', [FConfig.CanvasName, FInfo.SceneName,
    ModeName(FConfig.Mode)]);
  BorderIcons := [TBorderIcon.biSystemMenu];
  if FConfig.Transparency then
    BorderStyle := TFmxFormBorderStyle.None
  else
    BorderStyle := TFmxFormBorderStyle.Single;
  FormStyle := TFormStyle.StayOnTop;
  Position := TFormPosition.Designed;
  Quality := FConfig.Quality;
  Transparency := FConfig.Transparency;
  Fill.Kind := TBrushKind.Solid;
  Fill.Color := TAlphaColors.White;
  if not FindMonitor(FConfig.Monitor, FMonitor) then
    raise EBenchConfig.CreateFmt('Monitor "%s" not found', [FConfig.Monitor]);
  // Apply the properties above to the native window now, so that the size set next is final.
  // Move to the target monitor first: its DPI defines the logical client size.
  HandleNeeded;
  PlaceWindow;
  ApplyClientSize;
  PlaceWindow;

  if FConfig.N > 0 then
    N := FConfig.N
  else
    N := FSceneClass.DefaultN(FConfig.Preset);
  FInfo.N := N;
  FScene := FSceneClass.Create(Self, N);
  FScene.Setup;
  FScene.Advance(0, 0);

  FMsgWnd := AllocateHWnd(WndMethod);
  Application.OnException := AppException;
  FLastActivity := QpcNow;
  FWatchdog := TTimer.Create(Self);
  FWatchdog.Interval := 1000;
  FWatchdog.OnTimer := WatchdogTimer;
  FWatchdog.Enabled := True;
  OnClose := FormClosing;
end;

destructor TBenchForm.Destroy;
begin
  SetDisplayLink(False);
  if FMsgWnd <> 0 then
    DeallocateHWnd(FMsgWnd);
  FScene.Free;
  FDisplayLinkDeltas.Free;
  inherited;
end;

function TBenchForm.Wnd: HWND;
begin
  Result := WindowHandleToPlatform(Handle).Wnd;
end;

function TBenchForm.ClientSizePx: TSize;
var
  R: TRect;
begin
  if GetClientRect(Wnd, R) then
    Result := TSize.Create(R.Width, R.Height)
  else
    Result := TSize.Create(0, 0);
end;

procedure TBenchForm.ApplyClientSize;
var
  S: Single;
begin
  S := Handle.Scale;
  FInfo.Scale := S;
  ClientWidth := Round(FConfig.Width / S);
  ClientHeight := Round(FConfig.Height / S);
end;

procedure TBenchForm.PlaceWindow;
var
  WR, CR, Work: TRect;
  Origin: TPoint;
  X, Y: Integer;
begin
  // Centre the client area in the work area of the target monitor (physical pixels).
  if not GetWindowRect(Wnd, WR) or not GetClientRect(Wnd, CR) then
    Exit;
  Origin := TPoint.Create(0, 0);
  Winapi.Windows.ClientToScreen(Wnd, Origin);
  Work := FMonitor.WorkArea;
  X := Work.Left + (Work.Width - CR.Width) div 2 - (Origin.X - WR.Left);
  Y := Work.Top + (Work.Height - CR.Height) div 2 - (Origin.Y - WR.Top);
  if Y < Work.Top then
    Y := Work.Top;
  SetWindowPos(Wnd, 0, X, Y, 0, 0, SWP_NOSIZE or SWP_NOZORDER or SWP_NOACTIVATE);
end;

function TBenchForm.WindowPlaced: Boolean;
var
  Size: TSize;
begin
  Size := ClientSizePx;
  Result := (Size.cx = FConfig.Width) and (Size.cy = FConfig.Height) and
    (MonitorFromWindow(Wnd, MONITOR_DEFAULTTONEAREST) = FMonitor.Handle);
end;

function TBenchForm.SceneClipRects(const AUpdateRects: array of TRectF): TClipRects;
const
  MaxSeparatedRects = 20; // FMX.Forms.pas:6436
var
  Scene: IScene;
  I, Count: Integer;
begin
  if TCanvasStyle.SupportClipRects in TCanvasManager.DefaultCanvas.GetCanvasStyle then
  begin
    Scene := Self as IScene;
    Count := Scene.GetUpdateRectsCount;
    SetLength(Result, Count + Length(AUpdateRects));
    for I := 0 to Count - 1 do
      Result[I] := Scene.GetUpdateRect(I);
    for I := 0 to High(AUpdateRects) do
      Result[Count + I] := AUpdateRects[I];
    if Length(Result) > MaxSeparatedRects then
    begin
      for I := 1 to High(Result) do
        Result[0] := UnionRect(Result[0], Result[I]);
      SetLength(Result, 1);
    end;
  end
  else
    Result := [TRectF.Create(0, 0, Canvas.Width, Canvas.Height)];
end;

procedure TBenchForm.PaintRects(const UpdateRects: array of TRectF);
var
  T0, T1, T2, T3: Int64;
  C0, C1: UInt64;
  Clip: TClipRects;
  Began: Boolean;
begin
  C0 := ThreadCycles;
  T0 := QpcNow;
  if FConfig.Split and (Canvas <> nil) then
  begin
    Clip := SceneClipRects(UpdateRects);
    Began := Canvas.BeginScene(@Clip, ContextHandle);
    T1 := QpcNow;
    try
      inherited;
    finally
      T2 := QpcNow;
      if Began then
        Canvas.EndScene;
    end;
  end
  else
  begin
    T1 := T0;
    inherited;
    T2 := QpcNow;
  end;
  T3 := QpcNow;
  C1 := ThreadCycles;
  FramePainted(T0, T1 - T0, T2 - T1, T3 - T2, T3 - T0, C0, C1 - C0);
end;

procedure TBenchForm.FramePainted(const AStart, ABegin, ARecord, AEnd, ATotal: Int64;
  const AStartCycles, APaintCycles: UInt64);
var
  S: TFrameSample;
begin
  if (FState in [TBenchState.Warmup, TBenchState.Measure]) and not FFrameRequested then
  begin
    // A paint we did not ask for: the second PaintRects that FMX runs in the same WM_PAINT for rects
    // invalidated while painting (FMX.Platform.Win.pas:1803-1811), or a system repaint. It is part of
    // the current frame: add its cost to the last sample, do not advance the scene again.
    if (FState = TBenchState.Measure) and (FSampleCount > 0) then
    begin
      Inc(FSamples[FSampleCount - 1].BeginTicks, ABegin);
      Inc(FSamples[FSampleCount - 1].RecordTicks, ARecord);
      Inc(FSamples[FSampleCount - 1].EndTicks, AEnd);
      Inc(FSamples[FSampleCount - 1].TotalTicks, ATotal);
      Inc(FSamples[FSampleCount - 1].PaintCycles, APaintCycles);
      Inc(FExtraPaints);
    end;
    FLastActivity := QpcNow;
    Exit;
  end;
  FFrameRequested := False;

  S.Start := AStart;
  S.BeginTicks := ABegin;
  S.RecordTicks := ARecord;
  S.EndTicks := AEnd;
  S.TotalTicks := ATotal;
  S.PaintCycles := APaintCycles;
  if FPrevStart <> 0 then
  begin
    S.Interval := AStart - FPrevStart;
    S.FrameCycles := AStartCycles - FPrevCycles;
  end
  else
  begin
    S.Interval := 0;
    S.FrameCycles := 0;
  end;
  FPrevStart := AStart;
  FPrevCycles := AStartCycles;
  FLastActivity := QpcNow;
  if (FConfig.DeviceLossSec > 0) and Assigned(FInfo.Canvas.SimulateDeviceLoss) and
    (FState in [TBenchState.Warmup, TBenchState.Measure]) then
  begin
    if FLastDeviceLoss = 0 then
      FLastDeviceLoss := AStart
    else if QpcToMs(AStart - FLastDeviceLoss) >= FConfig.DeviceLossSec * 1000 then
    begin
      FLastDeviceLoss := AStart;
      FInfo.Canvas.SimulateDeviceLoss();
    end;
  end;

  case FState of
    TBenchState.Starting:
      begin
        BeginWarmup(AStart);
        if FState = TBenchState.Starting then
          Exit;
      end;
    TBenchState.Warmup:
      begin
        Inc(FWarmupFrames);
        // At least WarmupSec and WarmupMinFrames; slow cells (about a second per frame) stop waiting for
        // the frame count after 3 x WarmupSec.
        if (QpcToMs(AStart - FWarmupStart) >= FConfig.WarmupSec * 1000) and
          ((FWarmupFrames >= FConfig.WarmupMinFrames) or
           (QpcToMs(AStart - FWarmupStart) >= 3 * FConfig.WarmupSec * 1000)) then
          BeginMeasure(AStart);
      end;
    TBenchState.Measure:
      begin
        if FSampleCount = 0 then
          FMeasureStart := AStart;
        if AStart - FMeasureStart >= FDurationTicks then
        begin
          EndMeasure;
          Exit;
        end;
        if FSampleCount = Length(FSamples) then
          SetLength(FSamples, 2 * Length(FSamples));
        FSamples[FSampleCount] := S;
        Inc(FSampleCount);
      end;
    TBenchState.Screenshot:
      begin
        // FMX calls PaintRects a second time in the same WM_PAINT for rects invalidated while
        // painting (FMX.Platform.Win.pas:1803-1811); that repaint of the last measured frame must
        // not trigger the capture.
        if FShotFrameRequested and not FShotPosted then
        begin
          FShotPosted := True;
          PostMessage(FMsgWnd, WM_BENCH_SHOT, 0, 0);
        end;
        Exit;
      end;
  else
    Exit;
  end;

  if FConfig.Mode = TBenchMode.Throughput then
    PostMessage(FMsgWnd, WM_BENCH_NEXT, 0, 0);
end;

procedure TBenchForm.BeginWarmup(const AStart: Int64);
var
  Size: TSize;
begin
  if not WindowPlaced and (FSizeAttempts < MaxSizeAttempts) then
  begin
    // The window was moved, recreated or rescaled (WM_DPICHANGED) on show; place it again and
    // wait for the next paint.
    Inc(FSizeAttempts);
    PlaceWindow;
    ApplyClientSize;
    PlaceWindow;
    Invalidate;
    Exit;
  end;
  Size := ClientSizePx;
  FInfo.ClientWidth := Size.cx;
  FInfo.ClientHeight := Size.cy;
  FInfo.Scale := Handle.Scale;
  FInfo.CanvasClass := Canvas.ClassName;
  FInfo.CanvasQuality := Canvas.Quality;
  FInfo.TextLayoutClass := TTextLayoutManager.TextLayoutByCanvas(Canvas.ClassType).ClassName;
  FInfo.Display := GetDisplayInfo(Wnd);
  FWarmupStart := AStart;
  FWarmupFrames := 0;
  FState := TBenchState.Warmup;
  if FConfig.Mode = TBenchMode.Paced then
    SetDisplayLink(True);
end;

procedure TBenchForm.BeginMeasure(const AStart: Int64);
begin
  FInfo.WarmupFrames := FWarmupFrames;
  FInfo.WarmupMs := QpcToMs(AStart - FWarmupStart);
  FInfo.MemStart := GetMemoryInfo;
  FThreadCpuStart := ThreadCpuTimeMs;
  FProcessCpuStart := ProcessCpuTimeMs;
  if FConfig.Profile <> '' then
    StartProfile;
  if Assigned(FInfo.Canvas.RenderBusyMs) then
    FRenderStart := FInfo.Canvas.RenderBusyMs();
  FSampleCount := 0;
  FDisplayLinkDeltas.Clear;
  FState := TBenchState.Measure;
end;

procedure TBenchForm.StartProfile;
var
  Id: Cardinal;
begin
  Id := MainThreadID;
  if SameText(FConfig.ProfileThread, 'render') then
    if Assigned(FInfo.Canvas.RenderThreadId) then
      Id := FInfo.Canvas.RenderThreadId()
    else
      Id := 0;
  if Id <> 0 then
    ProfilerStart(Id, FConfig.ProfileIntervalUs);
end;

procedure TBenchForm.EndMeasure;
begin
  SetDisplayLink(False);
  if FConfig.Profile <> '' then
  begin
    ProfilerStop;
    ProfilerSave(FConfig.Profile);
  end;
  // CPU snapshots are taken at the end of PaintRects, so they cover the measured frames plus the
  // one that ended the measurement.
  FInfo.ThreadCpuMs := ThreadCpuTimeMs - FThreadCpuStart;
  FInfo.ProcessCpuMs := ProcessCpuTimeMs - FProcessCpuStart;
  if Assigned(FInfo.Canvas.RenderBusyMs) then
    FInfo.RenderMs := FInfo.Canvas.RenderBusyMs() - FRenderStart;
  FInfo.CpuFrames := FSampleCount + 1;
  FInfo.ExtraPaints := FExtraPaints;
  FInfo.MemEnd := GetMemoryInfo;
  FInfo.DisplayLinkDeltasMs := FDisplayLinkDeltas.ToArray;
  if FConfig.Screenshot <> '' then
  begin
    FState := TBenchState.Screenshot;
    PostMessage(FMsgWnd, WM_BENCH_SHOTFRAME, 0, 0);
  end
  else
  begin
    FState := TBenchState.Done;
    PostMessage(FMsgWnd, WM_BENCH_FINISH, 0, 0);
  end;
end;

procedure TBenchForm.RequestFrame;
begin
  FFrameRequested := True;
  Inc(FFrame);
  FScene.Advance(FFrame, FFrame / FConfig.Fps);
  Invalidate;
end;

procedure TBenchForm.SetDisplayLink(const AOn: Boolean);
begin
  if AOn = FSubscribed then
    Exit;
  if AOn then
  begin
    if FDisplayLink = nil then
      if not TPlatformServices.Current.SupportsPlatformService(IFMXDisplayLinkService, FDisplayLink) then
        raise Exception.Create('IFMXDisplayLinkService is not available');
    FDisplayLink.Subscribe(DisplayLinkTick);
  end
  else if FDisplayLink <> nil then
    FDisplayLink.Unsubscribe(DisplayLinkTick);
  FSubscribed := AOn;
end;

procedure TBenchForm.DisplayLinkTick(const ATime, ADeltaTime: Double);
begin
  if FState = TBenchState.Measure then
    FDisplayLinkDeltas.Add(ADeltaTime * 1000);
  if FState in [TBenchState.Warmup, TBenchState.Measure] then
    RequestFrame;
end;

procedure TBenchForm.TakeScreenshot;
var
  I: Integer;
begin
  if Assigned(FInfo.Canvas.BeforeCapture) then
    FInfo.Canvas.BeforeCapture();
  // Let DWM compose the presented frame before reading the screen.
  for I := 1 to 3 do
    DwmFlush;
  CaptureClientToPng(Wnd, FConfig.Screenshot);
  FState := TBenchState.Done;
  Finish;
end;

procedure TBenchForm.Finish;
var
  Summary: TRunSummary;
  Row: TCsvRow;
  Status: TStringList;
  RefreshLocked, Idle: Boolean;
  K: Integer;
begin
  if FFinished then
    Exit;
  FFinished := True;
  FWatchdog.Enabled := False;
  FState := TBenchState.Done;
  // Whatever happens below (e.g. a CSV schema mismatch), the process must end: a hanging run keeps
  // the run mutex and blocks every other run.
  try
    try
      Summary := Summarize(FInfo, FSamples, FSampleCount);
      Status := TStringList.Create;
      try
        Status.Delimiter := ';';
        Status.StrictDelimiter := True;
        if not SameText(FInfo.CanvasClass, FInfo.Canvas.ExpectedClass) then
        begin
          Status.Add('canvas-mismatch');
          BenchExitCode := 3;
        end;
        if (FInfo.ClientWidth <> FConfig.Width) or (FInfo.ClientHeight <> FConfig.Height) then
          Status.Add('size-mismatch');
        if not SameText(FInfo.Display.Device, FMonitor.Device) then
          Status.Add('monitor-mismatch');
        if FInfo.CanvasQuality <> FConfig.Quality then
          Status.Add('quality-mismatch');
        // The DWM compositor clock follows one rate for all monitors; a different rate than the
        // window's monitor (another monitor, or a game forcing 60 Hz) changes paced results.
        if (FInfo.Display.DwmHz > 0) and (FInfo.Display.ModeHz > 0) and
          (Abs(FInfo.Display.DwmHz - FInfo.Display.ModeHz) > FInfo.Display.ModeHz * 0.05) then
          Status.Add('dwm-rate-differs');
        // Throughput is suspect when it sits on the refresh rate or an integer fraction of it (presents held
        // to vsync, seen 2026-10-06 with independent flip: exactly 240 or 120 FPS), or when it does not exceed
        // the refresh rate although both the main thread and the render thread (if any) are idle most of the
        // time. CPU time of the main thread, not the PaintRects share: FMX work outside PaintRects (layout,
        // scrolling) is part of the frame too.
        if (FConfig.Mode = TBenchMode.Throughput) and (Summary.BudgetMs > 0) and (Summary.SpanMs > 0) then
        begin
          RefreshLocked := False;
          for K := 1 to 4 do
            if Abs(Summary.Fps - 1000 / Summary.BudgetMs / K) <= 1000 / Summary.BudgetMs / K * 0.01 then
              RefreshLocked := True;
          Idle := (FInfo.ThreadCpuMs / Summary.SpanMs < 0.8) and
            ((FInfo.RenderMs < 0) or (FInfo.RenderMs / Summary.SpanMs < 0.8));
          if RefreshLocked or ((Summary.Fps <= 1000 / Summary.BudgetMs * 1.05) and Idle) then
            Status.Add('throughput-limited');
        end;
        if Status.Count = 0 then
          FInfo.Status := 'ok'
        else
          FInfo.Status := Status.DelimitedText;
      finally
        Status.Free;
      end;

      if FConfig.OutCsv <> '' then
      begin
        Row := BuildResultRow(FInfo, Summary);
        try
          AppendCsvRow(FConfig.OutCsv, Row);
        finally
          Row.Free;
        end;
      end;
      if FConfig.FramesCsv <> '' then
        WriteFramesCsv(FConfig.FramesCsv, FSamples, FSampleCount);
      if IsConsole then
      begin
        Writeln(SummaryText(FInfo, Summary));
        if Assigned(FInfo.Canvas.DeviceResets) and (FInfo.Canvas.DeviceResets() > 0) then
          Writeln(Format('  device resets: %d', [FInfo.Canvas.DeviceResets()]));
      end;
    except
      on E: Exception do
      begin
        BenchExitCode := 1;
        if IsConsole then
          Writeln(ErrOutput, 'ERROR: ' + E.ClassName + ': ' + E.Message);
      end;
    end;
  finally
    Application.Terminate;
  end;
end;

procedure TBenchForm.Fail(const AMessage: string);
begin
  // Always terminate, also when called after Finish has started.
  BenchExitCode := 1;
  if IsConsole then
    Writeln(ErrOutput, 'ERROR: ' + AMessage);
  if not FFinished then
  begin
    FFinished := True;
    FWatchdog.Enabled := False;
    FState := TBenchState.Done;
  end;
  try
    SetDisplayLink(False);
  finally
    Application.Terminate;
  end;
end;

procedure TBenchForm.WndMethod(var AMsg: TMessage);
begin
  try
    case AMsg.Msg of
      WM_BENCH_NEXT:
        if FState in [TBenchState.Warmup, TBenchState.Measure] then
          RequestFrame;
      WM_BENCH_SHOTFRAME:
        begin
          FScene.Advance(FConfig.ScreenshotFrame, FConfig.ScreenshotFrame / FConfig.Fps);
          FShotFrameRequested := True;
          Invalidate;
        end;
      WM_BENCH_SHOT:
        TakeScreenshot;
      WM_BENCH_FINISH:
        Finish;
    else
      AMsg.Result := DefWindowProc(FMsgWnd, AMsg.Msg, AMsg.WParam, AMsg.LParam);
    end;
  except
    on E: Exception do
      Fail(E.ClassName + ': ' + E.Message);
  end;
end;

procedure TBenchForm.WatchdogTimer(Sender: TObject);
begin
  if not FFinished and (QpcToMs(QpcNow - FLastActivity) > StallTimeoutMs) then
    Fail(Format('No frame for %d ms (state %d, frames %d)', [StallTimeoutMs, Ord(FState), FSampleCount]));
end;

procedure TBenchForm.FormClosing(Sender: TObject; var Action: TCloseAction);
begin
  // Closed from outside (Alt+F4, close button, session end) before the run finished: report it instead
  // of exiting with code 0 and no result row.
  if not FFinished then
  begin
    FFinished := True;
    FWatchdog.Enabled := False;
    SetDisplayLink(False);
    FState := TBenchState.Done;
    BenchExitCode := 4;
    if IsConsole then
      Writeln(ErrOutput, 'ERROR: window closed before the run finished');
  end;
end;

procedure TBenchForm.AppException(Sender: TObject; E: Exception);
begin
  Fail(E.ClassName + ': ' + E.Message);
end;

end.
