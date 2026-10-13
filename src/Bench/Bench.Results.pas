unit Bench.Results;

{ Per-frame samples, run summary and the CSV result row. Times are stored as QPC ticks and
  converted to milliseconds only here. }

interface

uses
  FMX.Graphics, Common.Stats, Common.Env, Common.Csv, Bench.Config, Bench.Canvases;

type
  TFrameSample = record
    Start: Int64;           // QPC at PaintRects entry
    Interval: Int64;        // ticks since the previous PaintRects entry
    BeginTicks: Int64;      // outer Canvas.BeginScene (split mode)
    RecordTicks: Int64;     // inherited PaintRects: tree walk and canvas calls
    EndTicks: Int64;        // outer Canvas.EndScene: flush, EndDraw, Present
    TotalTicks: Int64;      // whole PaintRects
    PaintCycles: UInt64;    // main thread cycles inside PaintRects
    FrameCycles: UInt64;    // main thread cycles since the previous PaintRects entry
  end;

  TRunInfo = record
    Config: TBenchConfig;
    Canvas: TBenchCanvasInfo;
    StartedUtc: TDateTime;
    SceneName: string;
    N: Integer;
    CanvasClass: string;
    TextLayoutClass: string;
    CanvasQuality: TCanvasQuality;
    ClientWidth, ClientHeight: Integer;  // physical pixels, measured on the window
    Scale: Single;
    Display: TDisplayInfo;
    WarmupFrames: Integer;
    WarmupMs: Double;
    MemStart, MemEnd: TMemoryInfo;
    ThreadCpuMs: Double;    // GetThreadTimes delta over the measurement (main thread)
    ProcessCpuMs: Double;   // GetProcessTimes delta over the measurement
    CpuFrames: Integer;     // number of frames the two CPU time deltas cover
    RenderMs: Double;       // render thread busy time over the same frames; -1 = the canvas has none
    ExtraPaints: Integer;   // unrequested PaintRects merged into the measured frames
    CycleHz: Double;
    DisplayLinkDeltasMs: TArray<Double>;
    Status: string;
  end;

  TRunSummary = record
    Frames: Integer;
    SpanMs: Double;         // first to last frame start
    Fps: Double;
    Total, BeginScene, RecordScene, EndScene, Interval, CpuPaint, CpuFrame: TSampleStats;
    BudgetMs: Double;
    InBudgetShare: Double;  // share of frames with Total <= BudgetMs
    MissedIntervals: Integer; // intervals longer than 1.5 refresh periods
    DisplayLink: TSampleStats;
  end;

function Summarize(const AInfo: TRunInfo; const ASamples: TArray<TFrameSample>;
  const ACount: Integer): TRunSummary;
function BuildResultRow(const AInfo: TRunInfo; const ASummary: TRunSummary): TCsvRow;
procedure WriteFramesCsv(const AFileName: string; const ASamples: TArray<TFrameSample>;
  const ACount: Integer);
function SummaryText(const AInfo: TRunInfo; const ASummary: TRunSummary): string;

implementation

uses
  System.SysUtils, System.DateUtils, Common.Timing;

function TicksToMsArray(const ASamples: TArray<TFrameSample>; const ACount: Integer;
  const AField: Integer): TArray<Double>;
var
  I: Integer;
  T: Int64;
begin
  SetLength(Result, ACount);
  for I := 0 to ACount - 1 do
  begin
    case AField of
      0: T := ASamples[I].TotalTicks;
      1: T := ASamples[I].BeginTicks;
      2: T := ASamples[I].RecordTicks;
      3: T := ASamples[I].EndTicks;
    else
      T := ASamples[I].Interval;
    end;
    Result[I] := QpcToMs(T);
  end;
end;

function CyclesToMsArray(const ASamples: TArray<TFrameSample>; const ACount: Integer;
  const APaint: Boolean): TArray<Double>;
var
  I: Integer;
begin
  SetLength(Result, ACount);
  for I := 0 to ACount - 1 do
    if APaint then
      Result[I] := CyclesToMs(ASamples[I].PaintCycles)
    else
      Result[I] := CyclesToMs(ASamples[I].FrameCycles);
end;

function Summarize(const AInfo: TRunInfo; const ASamples: TArray<TFrameSample>;
  const ACount: Integer): TRunSummary;
var
  Totals, Intervals: TArray<Double>;
  RefreshMs: Double;
begin
  Result := Default(TRunSummary);
  Result.Frames := ACount;
  if ACount = 0 then
    Exit;
  Result.SpanMs := QpcToMs(ASamples[ACount - 1].Start - ASamples[0].Start);
  if Result.SpanMs > 0 then
    Result.Fps := (ACount - 1) / (Result.SpanMs / 1000);
  Totals := TicksToMsArray(ASamples, ACount, 0);
  Intervals := TicksToMsArray(ASamples, ACount, 4);
  Result.Total := ComputeStats(Totals);
  Result.BeginScene := ComputeStats(TicksToMsArray(ASamples, ACount, 1));
  Result.RecordScene := ComputeStats(TicksToMsArray(ASamples, ACount, 2));
  Result.EndScene := ComputeStats(TicksToMsArray(ASamples, ACount, 3));
  Result.Interval := ComputeStats(Intervals);
  Result.CpuPaint := ComputeStats(CyclesToMsArray(ASamples, ACount, True));
  Result.CpuFrame := ComputeStats(CyclesToMsArray(ASamples, ACount, False));
  // The budget is the refresh period of the window's monitor. DwmGetCompositionTimingInfo(0) reports
  // the compositor rate shared by all monitors (on a 60 Hz secondary next to a 240 Hz primary it says
  // 240), so it is only a fallback.
  if AInfo.Display.ModeHz > 0 then
    RefreshMs := 1000 / AInfo.Display.ModeHz
  else if AInfo.Display.DwmHz > 0 then
    RefreshMs := 1000 / AInfo.Display.DwmHz
  else
    RefreshMs := 1000 / 60;
  Result.BudgetMs := RefreshMs;
  Result.InBudgetShare := ShareAtMost(Totals, RefreshMs);
  Result.MissedIntervals := CountAbove(Intervals, RefreshMs * 1.5);
  Result.DisplayLink := ComputeStats(AInfo.DisplayLinkDeltasMs);
end;

function Mb(const ABytes: UInt64): Double;
begin
  Result := ABytes / (1024 * 1024);
end;

procedure AddStats(const ARow: TCsvRow; const APrefix: string; const AStats: TSampleStats;
  const AFull: Boolean; const AValid: Boolean = True);
  function V(const AValue: Double): string;
  begin
    if AValid and (AStats.Count > 0) then
      Result := CsvFloat(AValue)
    else
      Result := '';
  end;
begin
  ARow.Add(APrefix + '_median', V(AStats.Median));
  ARow.Add(APrefix + '_p95', V(AStats.P95));
  if AFull then
  begin
    ARow.Add(APrefix + '_p99', V(AStats.P99));
    ARow.Add(APrefix + '_max', V(AStats.Max));
    ARow.Add(APrefix + '_mean', V(AStats.Mean));
    ARow.Add(APrefix + '_stddev', V(AStats.StdDev));
  end;
end;

function BuildResultRow(const AInfo: TRunInfo; const ASummary: TRunSummary): TCsvRow;
var
  Geometry, Text: string;
  C: TBenchConfig;
  Paced: Boolean;
begin
  C := AInfo.Config;
  Paced := C.Mode = TBenchMode.Paced;
  Result := TCsvRow.Create;
  Result.Add('schema', 4);
  Result.Add('started_utc', DateToISO8601(AInfo.StartedUtc, True));
  Result.Add('tag', C.Tag);
  Result.Add('status', AInfo.Status);
  // Environment
  AddEnvironmentColumns(Result);
  Result.Add('monitor', AInfo.Display.Device);
  Result.AddBool('monitor_primary', AInfo.Display.Primary);
  Result.Add('monitor_hz', AInfo.Display.ModeHz);
  Result.Add('monitor_hz_dwm', AInfo.Display.DwmHz, 3);
  Result.Add('monitor_res', Format('%dx%d', [AInfo.Display.Width, AInfo.Display.Height]));
  Result.Add('dpi', AInfo.Display.Dpi);
  Result.Add('scale', AInfo.Scale, 2);
  Result.Add('cycle_mhz', AInfo.CycleHz / 1E6, 1);
  // Canvas
  Result.Add('canvas', C.CanvasName);
  Result.Add('canvas_class', AInfo.CanvasClass);
  Result.Add('canvas_expected', AInfo.Canvas.ExpectedClass);
  Result.AddBool('canvas_ok', SameText(AInfo.CanvasClass, AInfo.Canvas.ExpectedClass));
  Result.Add('text_layout_class', AInfo.TextLayoutClass);
  Result.Add('quality', QualityName(C.Quality));
  Result.Add('canvas_quality', QualityName(AInfo.CanvasQuality));
  AInfo.Canvas.AntiAliasing(C, Geometry, Text);
  Result.Add('geom_aa', Geometry);
  Result.Add('text_aa', Text);
  if Assigned(AInfo.Canvas.Options) then
    Result.Add('canvas_opts', AInfo.Canvas.Options())
  else
    Result.Add('canvas_opts', '');
  Result.AddBool('transparency', C.Transparency);
  AddGlobalFlagColumns(Result);
  // Scene and run parameters
  Result.Add('scene', AInfo.SceneName);
  Result.Add('n', AInfo.N);
  Result.Add('preset', PresetName(C.Preset));
  Result.Add('size', Format('%dx%d', [C.Width, C.Height]));
  Result.Add('client_w', AInfo.ClientWidth);
  Result.Add('client_h', AInfo.ClientHeight);
  Result.Add('mode', ModeName(C.Mode));
  Result.AddBool('split', C.Split);
  Result.Add('warmup_s', C.WarmupSec, 2);
  Result.Add('warmup_frames', AInfo.WarmupFrames);
  Result.Add('warmup_ms', AInfo.WarmupMs, 1);
  Result.Add('duration_s', C.DurationSec, 2);
  // Results
  Result.Add('frames', ASummary.Frames);
  Result.Add('extra_paints', AInfo.ExtraPaints);
  Result.Add('span_ms', ASummary.SpanMs, 1);
  Result.Add('fps', ASummary.Fps, 2);
  AddStats(Result, 'frame_ms', ASummary.Total, True);
  AddStats(Result, 'begin_ms', ASummary.BeginScene, False, C.Split);
  AddStats(Result, 'record_ms', ASummary.RecordScene, True, C.Split);
  AddStats(Result, 'end_ms', ASummary.EndScene, True, C.Split);
  AddStats(Result, 'interval_ms', ASummary.Interval, True);
  Result.Add('budget_ms', ASummary.BudgetMs, 3);
  if ASummary.Frames > 0 then
    Result.Add('in_budget_pct', ASummary.InBudgetShare * 100, 2)
  else
    Result.Add('in_budget_pct', '');
  Result.Add('missed_intervals', ASummary.MissedIntervals);
  AddStats(Result, 'cpu_paint_ms', ASummary.CpuPaint, False);
  AddStats(Result, 'cpu_frame_ms', ASummary.CpuFrame, False);
  if AInfo.CpuFrames > 0 then
  begin
    Result.Add('cpu_main_ms_per_frame', AInfo.ThreadCpuMs / AInfo.CpuFrames);
    Result.Add('cpu_process_ms_per_frame', AInfo.ProcessCpuMs / AInfo.CpuFrames);
  end
  else
  begin
    Result.Add('cpu_main_ms_per_frame', '');
    Result.Add('cpu_process_ms_per_frame', '');
  end;
  if ASummary.SpanMs > 0 then
    Result.Add('cpu_main_util_pct', AInfo.ThreadCpuMs / ASummary.SpanMs * 100, 1)
  else
    Result.Add('cpu_main_util_pct', '');
  if (AInfo.RenderMs >= 0) and (AInfo.CpuFrames > 0) then
    Result.Add('render_ms_per_frame', AInfo.RenderMs / AInfo.CpuFrames)
  else
    Result.Add('render_ms_per_frame', '');
  AddStats(Result, 'displaylink_ms', ASummary.DisplayLink, False, Paced);
  Result.Add('displaylink_ticks', ASummary.DisplayLink.Count);
  Result.Add('ws_start_mb', Mb(AInfo.MemStart.WorkingSet), 1);
  Result.Add('ws_end_mb', Mb(AInfo.MemEnd.WorkingSet), 1);
  Result.Add('ws_peak_mb', Mb(AInfo.MemEnd.PeakWorkingSet), 1);
  Result.Add('private_start_mb', Mb(AInfo.MemStart.PrivateBytes), 1);
  Result.Add('private_end_mb', Mb(AInfo.MemEnd.PrivateBytes), 1);
  Result.Add('command_line', C.CommandLine);
end;

procedure WriteFramesCsv(const AFileName: string; const ASamples: TArray<TFrameSample>;
  const ACount: Integer);
var
  Lines: TArray<string>;
  I: Integer;
  S: TFrameSample;
begin
  SetLength(Lines, ACount);
  for I := 0 to ACount - 1 do
  begin
    S := ASamples[I];
    Lines[I] := Format('%d,%s,%s,%s,%s,%s,%s,%s,%s,%s', [I,
      CsvFloat(QpcToMs(S.Start - ASamples[0].Start)),
      CsvFloat(QpcToMs(S.Interval)),
      CsvFloat(QpcToMs(S.TotalTicks)),
      CsvFloat(QpcToMs(S.BeginTicks)),
      CsvFloat(QpcToMs(S.RecordTicks)),
      CsvFloat(QpcToMs(S.EndTicks)),
      CsvFloat(CyclesToMs(S.PaintCycles)),
      CsvFloat(CyclesToMs(S.FrameCycles)),
      CsvFloat(QpcToMs(S.TotalTicks) - CyclesToMs(S.PaintCycles))]);
  end;
  WriteCsvTable(AFileName,
    'frame,start_ms,interval_ms,frame_ms,begin_ms,record_ms,end_ms,cpu_paint_ms,cpu_frame_ms,wait_ms',
    Lines);
end;

function SummaryText(const AInfo: TRunInfo; const ASummary: TRunSummary): string;
var
  F: TFormatSettings;
begin
  F := TFormatSettings.Invariant;
  Result := Format('%s/%s n=%d %s q=%s: status=%s class=%s', [AInfo.Config.CanvasName, AInfo.SceneName,
    AInfo.N, ModeName(AInfo.Config.Mode), QualityName(AInfo.Config.Quality), AInfo.Status,
    AInfo.CanvasClass], F) + sLineBreak;
  Result := Result + Format('  frames=%d fps=%.1f frame median=%.3f p95=%.3f p99=%.3f max=%.3f ms',
    [ASummary.Frames, ASummary.Fps, ASummary.Total.Median, ASummary.Total.P95, ASummary.Total.P99,
    ASummary.Total.Max], F) + sLineBreak;
  if AInfo.Config.Split then
    Result := Result + Format('  begin=%.3f record=%.3f end=%.3f ms (medians)',
      [ASummary.BeginScene.Median, ASummary.RecordScene.Median, ASummary.EndScene.Median], F) + sLineBreak;
  Result := Result + Format('  interval median=%.3f p99=%.3f max=%.3f ms, in budget %.1f%%, missed %d, ' +
    'cpu paint=%.3f frame=%.3f ms',
    [ASummary.Interval.Median, ASummary.Interval.P99, ASummary.Interval.Max, ASummary.InBudgetShare * 100,
    ASummary.MissedIntervals, ASummary.CpuPaint.Median, ASummary.CpuFrame.Median], F);
  if (AInfo.RenderMs >= 0) and (AInfo.CpuFrames > 0) then
    Result := Result + Format(', render thread=%.3f ms', [AInfo.RenderMs / AInfo.CpuFrames], F);
end;

end.
