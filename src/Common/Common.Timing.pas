unit Common.Timing;

{ High-resolution timing helpers: QPC wall clock and per-thread CPU cycles.

  QueryThreadCycleTime counts TSC ticks while the thread runs. The TSC rate is calibrated once
  against QPC so that cycle counts can be reported as CPU milliseconds. }

interface

function QpcNow: Int64;
function QpcFrequency: Int64;
function QpcToMs(const ATicks: Int64): Double;

function ThreadCycles: UInt64;
/// <summary>TSC rate in Hz used to convert thread cycles to time. Calibrated on first use.</summary>
function CycleFrequency: Double;
function CyclesToMs(const ACycles: UInt64): Double;

/// <summary>Kernel + user CPU time of the current thread in milliseconds (coarse, ~1 ms).</summary>
function ThreadCpuTimeMs: Double;
/// <summary>Kernel + user CPU time of the whole process in milliseconds.</summary>
function ProcessCpuTimeMs: Double;

procedure CalibrateCycleFrequency;

implementation

uses
  Winapi.Windows;

function QueryThreadCycleTimeApi(ThreadHandle: THandle; out CycleTime: UInt64): BOOL; stdcall;
  external kernel32 name 'QueryThreadCycleTime';

var
  GQpcFrequency: Int64;
  GQpcToMs: Double;
  GCycleFrequency: Double;
  GCyclesToMs: Double;

function QpcNow: Int64;
begin
  QueryPerformanceCounter(Result);
end;

function QpcFrequency: Int64;
begin
  Result := GQpcFrequency;
end;

function QpcToMs(const ATicks: Int64): Double;
begin
  Result := ATicks * GQpcToMs;
end;

function ThreadCycles: UInt64;
begin
  // GetCurrentThread returns a pseudo handle, no need to close it.
  if not QueryThreadCycleTimeApi(GetCurrentThread, Result) then
    Result := 0;
end;

procedure CalibrateCycleFrequency;
const
  TrialMs = 25;
  Trials = 4;
var
  I: Integer;
  Q0, Q1, QEnd: Int64;
  C0, C1: UInt64;
  Rate, Best: Double;
begin
  // Spin on this thread so that thread cycles advance at the TSC rate. Preemption can only lower
  // the measured rate, so the maximum over several trials is the best estimate.
  Best := 0;
  for I := 1 to Trials do
  begin
    Q0 := QpcNow;
    C0 := ThreadCycles;
    QEnd := Q0 + (GQpcFrequency * TrialMs) div 1000;
    repeat
      Q1 := QpcNow;
    until Q1 >= QEnd;
    C1 := ThreadCycles;
    Rate := (C1 - C0) / ((Q1 - Q0) / GQpcFrequency);
    if Rate > Best then
      Best := Rate;
  end;
  if Best <= 0 then
    Best := 1;
  GCycleFrequency := Best;
  GCyclesToMs := 1000 / Best;
end;

function CycleFrequency: Double;
begin
  if GCycleFrequency = 0 then
    CalibrateCycleFrequency;
  Result := GCycleFrequency;
end;

function CyclesToMs(const ACycles: UInt64): Double;
begin
  Result := ACycles * GCyclesToMs;
end;

function FileTimeToMs(const AFileTime: TFileTime): Double;
begin
  Result := (Int64(AFileTime.dwHighDateTime) shl 32 or AFileTime.dwLowDateTime) / 10000;
end;

function ThreadCpuTimeMs: Double;
var
  CreationTime, ExitTime, KernelTime, UserTime: TFileTime;
begin
  if GetThreadTimes(GetCurrentThread, CreationTime, ExitTime, KernelTime, UserTime) then
    Result := FileTimeToMs(KernelTime) + FileTimeToMs(UserTime)
  else
    Result := 0;
end;

function ProcessCpuTimeMs: Double;
var
  CreationTime, ExitTime, KernelTime, UserTime: TFileTime;
begin
  if GetProcessTimes(GetCurrentProcess, CreationTime, ExitTime, KernelTime, UserTime) then
    Result := FileTimeToMs(KernelTime) + FileTimeToMs(UserTime)
  else
    Result := 0;
end;

initialization
  QueryPerformanceFrequency(GQpcFrequency);
  GQpcToMs := 1000 / GQpcFrequency;
end.
