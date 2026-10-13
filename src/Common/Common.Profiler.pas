unit Common.Profiler;

{ A sampling profiler for one thread of the process (no administrator rights needed, unlike WPR).

  A sampler thread wakes every IntervalUs microseconds (high-resolution waitable timer), suspends the target
  thread, reads its context and walks the stack with RtlLookupFunctionEntry / RtlVirtualUnwind (Win64 unwind
  data: Delphi emits .pdata for its code; Win32: the chain of frame pointers), resumes the thread and keeps the
  return addresses. Nothing is allocated while the target is suspended: it may hold the heap lock.

  ProfilerSave writes the loaded modules and the stacks; tools\profile-report.ps1 resolves the addresses of the
  executable with its detailed .map file and reports self and inclusive time per routine and per unit.

  DumpThreadStacks writes the stack of every other thread of the process once, in the same format with the thread
  ID before each stack (hang diagnostics; tools\profile-report.ps1 -Stacks prints them resolved). }

interface

/// <summary>Starts sampling a thread (by ID). Stops a running session first.</summary>
procedure ProfilerStart(const AThreadId: Cardinal; const AIntervalUs: Integer = 500);
procedure ProfilerStop;
/// <summary>Samples taken by the last session.</summary>
function ProfilerSamples: Integer;
procedure ProfilerSave(const AFileName: string);
/// <summary>Writes the current stack of every thread of the process except the calling one.</summary>
procedure DumpThreadStacks(const AFileName: string);

implementation

uses
  Winapi.Windows, Winapi.PsAPI, Winapi.TlHelp32, System.SysUtils, System.Classes;

const
  MaxFrames = 96;
  BufferWords = 4 * 1024 * 1024;
  CREATE_WAITABLE_TIMER_HIGH_RESOLUTION = $2;
  UNW_FLAG_NHANDLER = 0;
  THREAD_SUSPEND_RESUME = $0002;
  THREAD_GET_CONTEXT = $0008;
  THREAD_QUERY_INFORMATION = $0040;
  TIMER_ALL_ACCESS = $1F0003;

function OpenThread(dwDesiredAccess: DWORD; bInheritHandle: BOOL; dwThreadId: DWORD): THandle; stdcall;
  external kernel32 name 'OpenThread';

{$IFDEF CPUX64}
function RtlLookupFunctionEntry(ControlPc: UInt64; out ImageBase: UInt64; HistoryTable: Pointer): Pointer; stdcall;
  external kernel32 name 'RtlLookupFunctionEntry';
function RtlVirtualUnwind(HandlerType: Cardinal; ImageBase: UInt64; ControlPc: UInt64; FunctionEntry: Pointer;
  ContextRecord: PContext; out HandlerData: Pointer; out EstablisherFrame: UInt64;
  ContextPointers: Pointer): Pointer; stdcall; external kernel32 name 'RtlVirtualUnwind';
{$ENDIF}

type
  TSampler = class(TThread)
  private
    FTarget: THandle;
    FInterval: Integer;
    FStop: Boolean;
    FContextMem: Pointer;
    FContext: PContext;
  protected
    procedure Execute; override;
    procedure TakeSample;
  public
    constructor Create(const AThreadId: Cardinal; const AIntervalUs: Integer);
    destructor Destroy; override;
  end;

var
  // Sample i: GData[GStarts[i]] = frame count, then the frames (innermost first).
  GData: TArray<UInt64>;
  GUsed: Integer;
  GCount: Integer;
  GDropped: Integer;
  GSampler: TSampler;

{ TSampler }

constructor TSampler.Create(const AThreadId: Cardinal; const AIntervalUs: Integer);
begin
  FTarget := OpenThread(THREAD_SUSPEND_RESUME or THREAD_GET_CONTEXT or THREAD_QUERY_INFORMATION, False, AThreadId);
  FInterval := AIntervalUs;
  // GetThreadContext wants a 16-byte aligned CONTEXT.
  GetMem(FContextMem, SizeOf(TContext) + 16);
  FContext := Pointer((NativeUInt(FContextMem) + 15) and not NativeUInt(15));
  inherited Create(False);
  Priority := tpTimeCritical;
end;

destructor TSampler.Destroy;
begin
  inherited;
  if FTarget <> 0 then
    CloseHandle(FTarget);
  FreeMem(FContextMem);
end;

type
  TFrames = array[0..MaxFrames - 1] of UInt64;

/// <summary>Suspends a thread, walks its stack into AFrames (innermost first) and resumes it. AContext: a 16-byte
/// aligned CONTEXT. Allocates nothing while the thread is suspended.</summary>
function WalkThread(const AThread: THandle; const AContext: PContext; var AFrames: TFrames): Integer;
var
{$IFDEF CPUX64}
  ImageBase, Establisher: UInt64;
  Entry, Handler: Pointer;
  Rsp: UInt64;
{$ELSE}
  Ebp, Next, Ret: NativeUInt;
{$ENDIF}
begin
  Result := 0;
  if SuspendThread(AThread) = DWORD(-1) then
    Exit;
  try
    FillChar(AContext^, SizeOf(TContext), 0);
    AContext.ContextFlags := CONTEXT_FULL;
{$IFNDEF CPUX64}
    // Win32: the instruction pointer, then the chain of frame pointers (routines without a frame are left out).
    if GetThreadContext(AThread, AContext^) then
      try
        AFrames[0] := AContext.Eip;
        Result := 1;
        Ebp := AContext.Ebp;
        while (Result < MaxFrames) and (Ebp <> 0) and not IsBadReadPtr(Pointer(Ebp), 8) do
        begin
          Ret := PNativeUInt(Ebp + SizeOf(Pointer))^;
          if Ret = 0 then
            Break;
          AFrames[Result] := Ret;
          Inc(Result);
          Next := PNativeUInt(Ebp)^;
          if Next <= Ebp then
            Break;
          Ebp := Next;
        end;
      except
        // A frame pointing into nowhere: keep what was collected.
      end;
{$ELSE}
    if GetThreadContext(AThread, AContext^) then
      try
        while (Result < MaxFrames) and (AContext.Rip <> 0) do
        begin
          AFrames[Result] := AContext.Rip;
          Inc(Result);
          Entry := RtlLookupFunctionEntry(AContext.Rip, ImageBase, nil);
          if Entry = nil then
          begin
            // Leaf code without unwind data: the return address is on top of the stack.
            Rsp := AContext.Rsp;
            if Rsp = 0 then
              Break;
            AContext.Rip := PUInt64(Rsp)^;
            AContext.Rsp := Rsp + 8;
          end
          else
            RtlVirtualUnwind(UNW_FLAG_NHANDLER, ImageBase, AContext.Rip, Entry, AContext, Handler, Establisher, nil);
        end;
      except
        // A frame pointing into nowhere: keep what was collected.
      end;
{$ENDIF}
  finally
    ResumeThread(AThread);
  end;
end;

procedure TSampler.TakeSample;
var
  Frames: TFrames;
  N, I: Integer;
begin
  N := WalkThread(FTarget, FContext, Frames);
  if N = 0 then
    Exit;
  if GUsed + N + 1 > Length(GData) then
  begin
    Inc(GDropped);
    Exit;
  end;
  GData[GUsed] := N;
  for I := 0 to N - 1 do
    GData[GUsed + 1 + I] := Frames[I];
  Inc(GUsed, N + 1);
  Inc(GCount);
end;

procedure TSampler.Execute;
var
  Timer: THandle;
  Due: Int64;
begin
  NameThreadForDebugging('Profiler');
  Timer := CreateWaitableTimerEx(nil, nil, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS);
  if Timer = 0 then
    Timer := CreateWaitableTimer(nil, False, nil);
  try
    while not FStop do
    begin
      Due := -Int64(FInterval) * 10;
      SetWaitableTimer(Timer, Due, 0, nil, nil, False);
      WaitForSingleObject(Timer, 100);
      if FStop then
        Break;
      TakeSample;
    end;
  finally
    CloseHandle(Timer);
  end;
end;

procedure ProfilerStop;
begin
  if GSampler = nil then
    Exit;
  GSampler.FStop := True;
  GSampler.WaitFor;
  FreeAndNil(GSampler);
end;

procedure ProfilerStart(const AThreadId: Cardinal; const AIntervalUs: Integer);
begin
  ProfilerStop;
  if Length(GData) = 0 then
    SetLength(GData, BufferWords);
  GUsed := 0;
  GCount := 0;
  GDropped := 0;
  GSampler := TSampler.Create(AThreadId, AIntervalUs);
end;

function ProfilerSamples: Integer;
begin
  Result := GCount;
end;

procedure AddModules(const L: TStringList);
var
  Modules: array[0..1023] of HMODULE;
  Needed: DWORD;
  Info: TModuleInfo;
  Name: array[0..MAX_PATH] of Char;
  I: Integer;
begin
  if EnumProcessModules(GetCurrentProcess, @Modules[0], SizeOf(Modules), Needed) then
    for I := 0 to Integer(Needed div SizeOf(HMODULE)) - 1 do
      if GetModuleInformation(GetCurrentProcess, Modules[I], @Info, SizeOf(Info)) and
        (GetModuleFileNameEx(GetCurrentProcess, Modules[I], Name, Length(Name)) > 0) then
        L.Add(Format('module %x %x %s', [UInt64(Info.lpBaseOfDll), Info.SizeOfImage, string(Name)]));
end;

procedure DumpThreadStacks(const AFileName: string);
var
  Snap, H: THandle;
  E: TThreadEntry32;
  Ids: TArray<Cardinal>;
  Stacks: TArray<TFrames>;
  Counts: TArray<Integer>;
  Mem: Pointer;
  Ctx: PContext;
  I, K: Integer;
  L: TStringList;
  S: TStringBuilder;
begin
  // Thread IDs first: nothing is allocated while a thread is suspended.
  Snap := CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
  if Snap = INVALID_HANDLE_VALUE then
    Exit;
  try
    E.dwSize := SizeOf(E);
    if Thread32First(Snap, E) then
      repeat
        if (E.th32OwnerProcessID = GetCurrentProcessId) and (E.th32ThreadID <> GetCurrentThreadId) then
          Ids := Ids + [E.th32ThreadID];
        E.dwSize := SizeOf(E);
      until not Thread32Next(Snap, E);
  finally
    CloseHandle(Snap);
  end;
  SetLength(Stacks, Length(Ids));
  SetLength(Counts, Length(Ids));
  GetMem(Mem, SizeOf(TContext) + 16);
  try
    Ctx := Pointer((NativeUInt(Mem) + 15) and not NativeUInt(15));
    for I := 0 to High(Ids) do
    begin
      H := OpenThread(THREAD_SUSPEND_RESUME or THREAD_GET_CONTEXT or THREAD_QUERY_INFORMATION, False, Ids[I]);
      if H = 0 then
        Continue;
      try
        Counts[I] := WalkThread(H, Ctx, Stacks[I]);
      finally
        CloseHandle(H);
      end;
    end;
  finally
    FreeMem(Mem);
  end;
  L := TStringList.Create;
  S := TStringBuilder.Create;
  try
    L.Add(Format('samples %d dropped 0', [Length(Ids)]));
    AddModules(L);
    for I := 0 to High(Ids) do
    begin
      L.Add(Format('t %d', [Ids[I]]));
      S.Clear;
      S.Append('s');
      for K := 0 to Counts[I] - 1 do
        S.Append(' ').Append(IntToHex(Stacks[I][K], 1));
      L.Add(S.ToString);
    end;
    L.SaveToFile(AFileName, TEncoding.ASCII);
  finally
    S.Free;
    L.Free;
  end;
end;

procedure ProfilerSave(const AFileName: string);
var
  L: TStringList;
  P, N, K: Integer;
  S: TStringBuilder;
begin
  L := TStringList.Create;
  S := TStringBuilder.Create;
  try
    L.Add(Format('samples %d dropped %d', [GCount, GDropped]));
    AddModules(L);
    P := 0;
    while P < GUsed do
    begin
      N := GData[P];
      S.Clear;
      S.Append('s');
      for K := 1 to N do
        S.Append(' ').Append(IntToHex(GData[P + K], 1));
      L.Add(S.ToString);
      Inc(P, N + 1);
    end;
    L.SaveToFile(AFileName, TEncoding.ASCII);
  finally
    S.Free;
    L.Free;
  end;
end;

initialization
finalization
  ProfilerStop;
end.
