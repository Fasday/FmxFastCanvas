unit FastCanvas.RenderQueue;

{ Command stream and render thread (docs/ARCHITECTURE.md).

  The main thread appends commands to the current chunk. Submit hands the chunk to the render thread,
  which executes chunks one by one in submission order: the stream order is the program order, so a
  bitmap drawn into and then drawn onto a form needs no extra synchronization. Objects referenced by
  commands (bitmaps, text layouts) are kept alive by the chunk until it has been executed.

  Waits of the main thread dispatch messages sent to its windows (MsgWaitForMultipleObjects with
  QS_SENDMESSAGE) and nothing else: posted messages, timers and paints stay in the queue, so a wait
  inside a paint does not re-enter FMX.

  Without a render thread (Threaded = False) Submit executes the chunk at once on the calling thread: the same
  command stream, the same player, nothing to wait for. The mode can change between frames (SetThreaded waits for
  the render thread first); the thread is started on first threaded use and then kept.

  Several threads may wait at once (the main thread for a frame, another thread in a bitmap Map). Every waiter
  checks its condition and registers its own event under the lock; the render thread updates the counters and
  takes the list of registered events under the same lock and signals them after leaving it (a waiter woken
  inside the lock would block on it at once), so no wakeup is lost. A late signal of a reused event only causes
  one more check. (Until 2026-10-07 all waiters shared one auto-reset event: a waiter could take the wakeup of
  another, which then slept forever.)

  Android and Linux: the waiters' events are TEvent objects, and a wait dispatches nothing (no window messages are
  sent between threads there); the render thread does not initialize COM. }

interface

uses
  {$IFDEF MSWINDOWS}Winapi.Windows, {$ELSE}Posix.Pthread, {$ENDIF}System.SysUtils, System.Classes, System.SyncObjs,
  System.Generics.Collections;

type
  TRenderChunk = class
  private const
    RecentSize = 64;
  private
    FData: TBytes;
    FSize: Integer;
    FRefs: TArray<IInterface>;
    FRefCount: Integer;
    /// <summary>Recently kept pointers: most commands of a frame reference a few objects again and again.</summary>
    FRecent: array[0..RecentSize - 1] of Pointer;
    FSeq: Int64;
    procedure Grow(const ANeed: Integer);
    procedure Reset;
  public
    /// <summary>ASize bytes at the end of the chunk. The pointer is valid until the next Alloc.</summary>
    function Alloc(const ASize: Integer): Pointer; inline;
    /// <summary>Keeps AObj alive until the chunk has been executed.</summary>
    procedure KeepAlive(const AObj: IInterface);
    /// <summary>Address of a byte offset; valid until the next Alloc.</summary>
    function At(const AOffset: Integer): Pointer; inline;
    property Size: Integer read FSize;
  end;

  TRenderExecute = procedure(const AData: PByte; const ASize: Integer);
  /// <summary>The event a waiting thread sleeps on: an auto-reset event.</summary>
  TWaiterEvent = {$IFDEF MSWINDOWS}THandle{$ELSE}TEvent{$ENDIF};
  TWaiterEvents = array[0..15] of TWaiterEvent;

  TRenderQueue = class
  private
    FThread: TThread;
    FLock: TCriticalSection;
    FPending: TQueue<TRenderChunk>;
    FFree: TStack<TRenderChunk>;
    FWork: TEvent;
    FCurrent: TRenderChunk;
    // Events of the threads waiting now, and unused ones.
    FWaiters: TList<TWaiterEvent>;
    FSpareEvents: TStack<TWaiterEvent>;
    FExecute: TRenderExecute;
    FSubmitted: Int64;
    FCompleted: Int64;
    FFramesSubmitted: Int64;
    FFramesCompleted: Int64;
    FBusyTicks: Int64;
    FError: string;
    FTerminated: Boolean;
    FThreaded: Boolean;
    /// <summary>Thread executing a chunk inline (Threaded = False), else 0.</summary>
    FInlineThread: TThreadID;
    procedure StartThread;
    procedure ExecuteInline;
    procedure ThreadProc;
    /// <summary>Under FLock: the events of the waiting threads, for WakeWaiters after leaving the lock.</summary>
    procedure TakeWaiters(var AEvents: TWaiterEvents; out ACount: Integer);
    class procedure WakeWaiters(const AEvents: TWaiterEvents; const ACount: Integer); static;
    /// <summary>Waits until FCompleted >= ATarget (AFrames = False) or until at most ATarget frames are not presented
    /// yet (AFrames = True).</summary>
    procedure WaitUntil(const AFrames: Boolean; const ATarget: Int64);
  public
    constructor Create(const AExecute: TRenderExecute; const AThreaded: Boolean = True);
    /// <summary>Calling thread (the one that records): switches between executing on the render thread and executing
    /// at Submit on the calling thread. Waits for the render thread when leaving it.</summary>
    procedure SetThreaded(const AValue: Boolean);
    property Threaded: Boolean read FThreaded;
    destructor Destroy; override;
    /// <summary>Main thread: the chunk commands are appended to.</summary>
    property Chunk: TRenderChunk read FCurrent;
    /// <summary>Main thread: hands the current chunk to the render thread.</summary>
    procedure Submit;
    /// <summary>Main thread: Submit, then wait until the render thread has executed everything.</summary>
    procedure Sync;
    /// <summary>Any thread: wait until the chunks submitted so far have been executed.</summary>
    procedure WaitSubmitted;
    /// <summary>Main thread: a frame (a window present) has been recorded.</summary>
    procedure FrameSubmitted;
    /// <summary>Render thread: a frame has been presented.</summary>
    procedure FrameCompleted;
    /// <summary>Main thread: wait until at most AInFlight recorded frames are not presented yet.</summary>
    procedure WaitFrames(const AInFlight: Integer);
    /// <summary>Main thread: raises the first error of the render thread, if any.</summary>
    procedure CheckError;
    /// <summary>Render thread: remembers the first error; the main thread raises it in CheckError.</summary>
    procedure ReportError(const AMessage: string);
    /// <summary>Main thread: forgets a reported error (the device was recreated).</summary>
    procedure ClearError;
    /// <summary>True on the thread that executes commands now (the render thread, or the thread executing inline).</summary>
    function IsRenderThread: Boolean;
    function ThreadId: TThreadID;
    /// <summary>Time the render thread spent executing chunks, TStopwatch ticks (QueryPerformanceCounter on
    /// Windows; TStopwatch.Frequency per second).</summary>
    property BusyTicks: Int64 read FBusyTicks;
  end;

{$IFNDEF MSWINDOWS}
/// <summary>The calling thread, as Winapi.Windows.GetCurrentThreadId (TThread.ThreadID is its pthread_t here).
/// </summary>
function GetCurrentThreadId: TThreadID;
{$ENDIF}

implementation

uses
{$IFDEF MSWINDOWS}
  Winapi.ActiveX, System.Math;
{$ELSE}
  System.Math, System.Diagnostics;
{$ENDIF}

{$IFNDEF MSWINDOWS}
function GetCurrentThreadId: TThreadID;
begin
  Result := TThreadID(pthread_self);
end;
{$ENDIF}

const
{$IFDEF MSWINDOWS}
  // winuser.h: PM_QS_SENDMESSAGE = QS_SENDMESSAGE shl 16 (not in Winapi.Windows).
  PM_QS_SENDMESSAGE = QS_SENDMESSAGE shl 16;
{$ENDIF}
  NoWaiter = {$IFDEF MSWINDOWS}0{$ELSE}nil{$ENDIF};

/// <summary>Now, in the ticks of BusyTicks.</summary>
function Ticks: Int64; inline;
begin
{$IFDEF MSWINDOWS}
  QueryPerformanceCounter(Result);
{$ELSE}
  Result := TStopwatch.GetTimeStamp;
{$ENDIF}
end;

function NewWaiterEvent: TWaiterEvent; inline;
begin
{$IFDEF MSWINDOWS}
  Result := CreateEvent(nil, False, False, nil);
{$ELSE}
  Result := TEvent.Create(nil, False, False, '');
{$ENDIF}
end;

procedure SignalWaiter(const AEvent: TWaiterEvent); inline;
begin
{$IFDEF MSWINDOWS}
  SetEvent(AEvent);
{$ELSE}
  AEvent.SetEvent;
{$ENDIF}
end;

procedure FreeWaiterEvent(const AEvent: TWaiterEvent); inline;
begin
{$IFDEF MSWINDOWS}
  CloseHandle(AEvent);
{$ELSE}
  AEvent.Free;
{$ENDIF}
end;

type
  TRenderThread = class(TThread)
  private
    FQueue: TRenderQueue;
  protected
    procedure Execute; override;
  end;

{ TRenderChunk }

function TRenderChunk.Alloc(const ASize: Integer): Pointer;
begin
  if FSize + ASize > Length(FData) then
    Grow(FSize + ASize);
  Result := @FData[FSize];
  Inc(FSize, ASize);
end;

function TRenderChunk.At(const AOffset: Integer): Pointer;
begin
  Result := @FData[AOffset];
end;

procedure TRenderChunk.Grow(const ANeed: Integer);
begin
  SetLength(FData, Max(Max(ANeed, 2 * Length(FData)), 64 * 1024));
end;

procedure TRenderChunk.KeepAlive(const AObj: IInterface);
var
  Slot: Integer;
begin
  if AObj = nil then
    Exit;
  Slot := (NativeUInt(Pointer(AObj)) shr 4) and (RecentSize - 1);
  if FRecent[Slot] = Pointer(AObj) then
    Exit;
  FRecent[Slot] := Pointer(AObj);
  if FRefCount = Length(FRefs) then
    SetLength(FRefs, Max(64, 2 * FRefCount));
  FRefs[FRefCount] := AObj;
  Inc(FRefCount);
end;

procedure TRenderChunk.Reset;
var
  I: Integer;
begin
  for I := 0 to FRefCount - 1 do
    FRefs[I] := nil;
  FRefCount := 0;
  FillChar(FRecent, SizeOf(FRecent), 0);
  FSize := 0;
end;

{ TRenderThread }

procedure TRenderThread.Execute;
begin
  NameThreadForDebugging('FastCanvas render');
  FQueue.ThreadProc;
end;

{ TRenderQueue }

constructor TRenderQueue.Create(const AExecute: TRenderExecute; const AThreaded: Boolean);
begin
  inherited Create;
  FExecute := AExecute;
  FLock := TCriticalSection.Create;
  FPending := TQueue<TRenderChunk>.Create;
  FFree := TStack<TRenderChunk>.Create;
  FWork := TEvent.Create(nil, False, False, '');
  FWaiters := TList<TWaiterEvent>.Create;
  FSpareEvents := TStack<TWaiterEvent>.Create;
  FCurrent := TRenderChunk.Create;
  FThreaded := AThreaded;
  if FThreaded then
    StartThread;
end;

procedure TRenderQueue.StartThread;
begin
  FThread := TRenderThread.Create(True);
  TRenderThread(FThread).FQueue := Self;
  FThread.FreeOnTerminate := False;
  FThread.Start;
end;

procedure TRenderQueue.SetThreaded(const AValue: Boolean);
begin
  if AValue = FThreaded then
    Exit;
  if FThreaded then
    Sync;
  FThreaded := AValue;
  if FThreaded and (FThread = nil) then
    StartThread;
end;

procedure TRenderQueue.ExecuteInline;
var
  C: TRenderChunk;
  T0, T1: Int64;
begin
  // The chunk leaves FCurrent first: what the execution records (if anything) goes to a new one.
  C := FCurrent;
  FLock.Enter;
  try
    Inc(FSubmitted);
    C.FSeq := FSubmitted;
    if FFree.Count > 0 then
      FCurrent := FFree.Pop
    else
      FCurrent := nil;
  finally
    FLock.Leave;
  end;
  if FCurrent = nil then
    FCurrent := TRenderChunk.Create;
  T0 := Ticks;
  FInlineThread := GetCurrentThreadId;
  try
    try
      FExecute(PByte(C.FData), C.FSize);
    except
      on E: Exception do
        ReportError(E.ClassName + ': ' + E.Message);
    end;
  finally
    FInlineThread := 0;
  end;
  C.Reset;
  T1 := Ticks;
  FLock.Enter;
  try
    Inc(FBusyTicks, T1 - T0);
    FCompleted := C.FSeq;
    FFree.Push(C);
  finally
    FLock.Leave;
  end;
end;

destructor TRenderQueue.Destroy;
var
  C: TRenderChunk;
begin
  // What is left runs first (on the render thread, or here).
  Sync;
  if FThread <> nil then
  begin
    FLock.Enter;
    try
      FTerminated := True;
    finally
      FLock.Leave;
    end;
    FWork.SetEvent;
    FThread.WaitFor;
    FreeAndNil(FThread);
  end;
  for C in FPending do
    C.Free;
  for C in FFree do
    C.Free;
  FCurrent.Free;
  FPending.Free;
  FFree.Free;
  FWork.Free;
  while FSpareEvents.Count > 0 do
    FreeWaiterEvent(FSpareEvents.Pop);
  FSpareEvents.Free;
  FWaiters.Free;
  FLock.Free;
  inherited;
end;

procedure TRenderQueue.ThreadProc;
var
  C: TRenderChunk;
  Stop: Boolean;
  T0, T1: Int64;
  Events: TWaiterEvents;
  N: Integer;
begin
{$IFDEF MSWINDOWS}
  CoInitializeEx(nil, COINIT_MULTITHREADED);
{$ENDIF}
  try
    // Direct2D and Direct3D expect the arithmetic exceptions masked (FMX masks them around its calls).
    SetExceptionMask(exAllArithmeticExceptions);
    repeat
      FWork.WaitFor(INFINITE);
      repeat
        FLock.Enter;
        try
          if FPending.Count > 0 then
            C := FPending.Dequeue
          else
            C := nil;
          Stop := FTerminated and (C = nil);
        finally
          FLock.Leave;
        end;
        if C = nil then
          Break;
        T0 := Ticks;
        try
          FExecute(PByte(C.FData), C.FSize);
        except
          on E: Exception do
            ReportError(E.ClassName + ': ' + E.Message);
        end;
        // Last references of bitmaps and layouts may be released here, on the render thread.
        C.Reset;
        T1 := Ticks;
        FLock.Enter;
        try
          Inc(FBusyTicks, T1 - T0);
          FCompleted := C.FSeq;
          FFree.Push(C);
          TakeWaiters(Events, N);
        finally
          FLock.Leave;
        end;
        WakeWaiters(Events, N);
      until False;
    until Stop;
  finally
{$IFDEF MSWINDOWS}
    CoUninitialize;
{$ENDIF}
  end;
end;

procedure TRenderQueue.TakeWaiters(var AEvents: TWaiterEvents; out ACount: Integer);
var
  I: Integer;
begin
  ACount := 0;
  if FWaiters.Count > Length(AEvents) then
  begin
    // More waiters than the buffer holds (never seen): signal them here.
    for I := 0 to FWaiters.Count - 1 do
      SignalWaiter(FWaiters[I]);
    Exit;
  end;
  for I := 0 to FWaiters.Count - 1 do
    AEvents[I] := FWaiters[I];
  ACount := FWaiters.Count;
end;

class procedure TRenderQueue.WakeWaiters(const AEvents: TWaiterEvents; const ACount: Integer);
var
  I: Integer;
begin
  for I := 0 to ACount - 1 do
    SignalWaiter(AEvents[I]);
end;

procedure TRenderQueue.WaitUntil(const AFrames: Boolean; const ATarget: Int64);
var
  H: TWaiterEvent;
{$IFDEF MSWINDOWS}
  Msg: TMsg;
{$ENDIF}
  Done, Registered: Boolean;
begin
  H := NoWaiter;
  Registered := False;
  try
    repeat
      FLock.Enter;
      try
        if Registered then
        begin
          FWaiters.Remove(H);
          Registered := False;
        end;
        if AFrames then
          Done := FFramesSubmitted - FFramesCompleted <= ATarget
        else
          Done := FCompleted >= ATarget;
        if not Done then
        begin
          if H = NoWaiter then
            if FSpareEvents.Count > 0 then
              H := FSpareEvents.Pop
            else
              H := NewWaiterEvent;
          FWaiters.Add(H);
          Registered := True;
        end
        else if H <> NoWaiter then
        begin
          FSpareEvents.Push(H);
          H := NoWaiter;
        end;
      finally
        FLock.Leave;
      end;
      if Done then
        Break;
{$IFDEF MSWINDOWS}
      if MsgWaitForMultipleObjects(1, H, False, INFINITE, QS_SENDMESSAGE) = WAIT_OBJECT_0 + 1 then
        // Dispatches the messages sent by other threads (DXGI may send to the window); leaves posted ones.
        PeekMessage(Msg, 0, 0, 0, PM_NOREMOVE or PM_QS_SENDMESSAGE);
{$ELSE}
      H.WaitFor(INFINITE);
{$ENDIF}
    until False;
  except
    // A sent message raised: unregister before passing it on.
    if H <> NoWaiter then
    begin
      FLock.Enter;
      try
        if Registered then
          FWaiters.Remove(H);
        FSpareEvents.Push(H);
      finally
        FLock.Leave;
      end;
    end;
    raise;
  end;
end;

procedure TRenderQueue.Submit;
var
  Next: TRenderChunk;
begin
  if FCurrent.FSize = 0 then
    Exit;
  if not FThreaded then
  begin
    ExecuteInline;
    Exit;
  end;
  FLock.Enter;
  try
    Inc(FSubmitted);
    FCurrent.FSeq := FSubmitted;
    FPending.Enqueue(FCurrent);
    if FFree.Count > 0 then
      Next := FFree.Pop
    else
      Next := nil;
  finally
    FLock.Leave;
  end;
  if Next = nil then
    Next := TRenderChunk.Create;
  FCurrent := Next;
  FWork.SetEvent;
end;

procedure TRenderQueue.Sync;
begin
  Submit;
  WaitSubmitted;
end;

procedure TRenderQueue.WaitSubmitted;
var
  Target: Int64;
begin
  FLock.Enter;
  try
    Target := FSubmitted;
  finally
    FLock.Leave;
  end;
  WaitUntil(False, Target);
end;

procedure TRenderQueue.FrameSubmitted;
begin
  FLock.Enter;
  try
    Inc(FFramesSubmitted);
  finally
    FLock.Leave;
  end;
end;

procedure TRenderQueue.FrameCompleted;
var
  Events: TWaiterEvents;
  N: Integer;
begin
  FLock.Enter;
  try
    Inc(FFramesCompleted);
    TakeWaiters(Events, N);
  finally
    FLock.Leave;
  end;
  WakeWaiters(Events, N);
end;

procedure TRenderQueue.WaitFrames(const AInFlight: Integer);
begin
  WaitUntil(True, AInFlight);
end;

procedure TRenderQueue.CheckError;
var
  E: string;
begin
  if FError = '' then
    Exit;
  FLock.Enter;
  try
    E := FError;
    FError := '';
  finally
    FLock.Leave;
  end;
  raise Exception.Create('Render thread: ' + E);
end;

procedure TRenderQueue.ClearError;
begin
  FLock.Enter;
  try
    FError := '';
  finally
    FLock.Leave;
  end;
end;

procedure TRenderQueue.ReportError(const AMessage: string);
begin
  FLock.Enter;
  try
    if FError = '' then
      FError := AMessage;
  finally
    FLock.Leave;
  end;
end;

function TRenderQueue.ThreadId: TThreadID;
begin
  if FThreaded and (FThread <> nil) then
    Result := FThread.ThreadID
  else
    Result := 0;
end;

function TRenderQueue.IsRenderThread: Boolean;
begin
  Result := ((FThread <> nil) and (GetCurrentThreadId = FThread.ThreadID)) or
    ((FInlineThread <> 0) and (GetCurrentThreadId = FInlineThread));
end;

end.
