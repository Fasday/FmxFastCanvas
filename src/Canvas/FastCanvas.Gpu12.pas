unit FastCanvas.Gpu12;

{ Direct3D 12 backend of the FastCanvas renderer (FastCanvas.Gpu), with no Direct3D 11 layer in between.

  One recording context per device (TGpu12Context, used with the device lock held): a direct command list opened on
  first use and submitted before Present, at the end of every executed chunk of the canvas command stream, and when
  the CPU needs results (Map, transparent windows). Command allocators, upload pages and blocks of the shader-visible
  descriptor heap are used again once the fence of the submission that used them has passed; resources released
  while the GPU may still use them wait for that fence too (Retire).

  Resource states are tracked per resource and changed by batched barriers right before the next command that needs
  them. Surfaces rest in PIXEL_SHADER_RESOURCE, swap chain buffers in PRESENT.

  The pipeline: one root signature (b0 as 8 root constants; t0..t7 the textures of a draw; t8..t12 atlas, ramps,
  clips, paints, edges; three static samplers) and two pipeline states (blending, copy) with the shaders of the
  Direct3D 11 backend (DXBC vs_4_0 / ps_4_0). }

interface

uses
  DX12.D3D12, DX12.D3DCommon, DX12.DXGI, DX12.DXGI1_2, DX12.DXGI1_4,
  Winapi.Windows, System.SysUtils, System.Types, System.Math, System.Generics.Collections,
  FastCanvas.Device, FastCanvas.Gpu;

type
  TGpu12Surface = class;

  /// <summary>CPU-only descriptors (views of surfaces), handed out and taken back one by one.</summary>
  TGpu12DescriptorPool = class
  private
    FType: TD3D12_DESCRIPTOR_HEAP_TYPE;
    FIncrement: Cardinal;
    FHeaps: TList<ID3D12DescriptorHeap>;
    FFree: TList<SIZE_T>;
  public
    constructor Create(const AType: TD3D12_DESCRIPTOR_HEAP_TYPE);
    destructor Destroy; override;
    function Alloc: TD3D12_CPU_DESCRIPTOR_HANDLE;
    procedure Release(const AHandle: TD3D12_CPU_DESCRIPTOR_HANDLE);
  end;

  /// <summary>Part of an upload heap buffer, mapped for writing.</summary>
  TGpu12Page = class
  public
    Resource: ID3D12Resource;
    Cpu: PByte;
    Gpu: UInt64;
    Size, Used: NativeInt;
    /// <summary>The last submission that uses the page (InList: the open list).</summary>
    Fence: UInt64;
    /// <summary>Free page: the submission when it became free (released after FreePageLife more).</summary>
    FreeSince: UInt64;
  end;

  TGpu12Retired = record
    Obj: IInterface;
    Fence: UInt64;
  end;

  TGpu12Allocator = record
    Allocator: ID3D12CommandAllocator;
    Fence: UInt64;
  end;

  /// <summary>Command recording on the queue of the device; with the device lock held.</summary>
  TGpu12Context = class
  private
    FDevice: ID3D12Device;
    FQueue: ID3D12CommandQueue;
    FFence: ID3D12Fence;
    FEvent: THandle;
    FSignaled: UInt64;
    FList: ID3D12GraphicsCommandList;
    FOpen: Boolean;
    FListGen: Integer;
    FAllocator: ID3D12CommandAllocator;
    FAllocators: TQueue<TGpu12Allocator>;
    FBarriers: TArray<TD3D12_RESOURCE_BARRIER>;
    FBarrierCount: Integer;
    FPage: TGpu12Page;
    FBusyPages, FFreePages: TList<TGpu12Page>;
    FRetired: TList<TGpu12Retired>;
    FHeap: ID3D12DescriptorHeap;
    FHeapCpu: TD3D12_CPU_DESCRIPTOR_HANDLE;
    FHeapGpu: TD3D12_GPU_DESCRIPTOR_HANDLE;
    FSrvIncrement: Cardinal;
    FBlockFence: TArray<UInt64>;
    FBlock, FBlockPos: Integer;
    FListBlocks: TList<Integer>;
    FSrvPool, FRtvPool, FDsvPool: TGpu12DescriptorPool;
    FOwner: TObject;
    FInfo: IInterface;
    FMessages: Integer;
    // HDR window output (OutputHdr), made on first use.
    FOutRoot: ID3D12RootSignature;
    FOutPso: ID3D12PipelineState;
    procedure Open;
    function TakePage(const ASize: NativeInt): TGpu12Page;
    procedure NextBlock;
    procedure CreateOutputPipeline;
  public
    constructor Create;
    destructor Destroy; override;
    /// <summary>Debug layer: its messages so far into the log file.</summary>
    procedure DrainMessages;
    /// <summary>The open command list (opened if needed).</summary>
    function List: ID3D12GraphicsCommandList;
    /// <summary>Executes the open list on the queue, then AExtra (a list recorded elsewhere: the 3D context), and
    /// signals the fence. Returns the fence value that marks their completion (0: nothing was executed).</summary>
    function Submit(const AExtra: ID3D12CommandList = nil): UInt64;
    procedure WaitFor(const AValue: UInt64);
    /// <summary>Submits and waits until the GPU has executed everything; releases what was retired.</summary>
    procedure WaitIdle;
    /// <summary>Releases retired objects and recycles pages the GPU is done with.</summary>
    procedure Collect;
    /// <summary>Keeps AObject alive until the GPU has executed everything recorded so far.</summary>
    procedure Retire(const AObject: IInterface);
    /// <summary>Records a state change (issued by FlushBarriers, before the next command).</summary>
    procedure Transition(const AResource: ID3D12Resource; var AState: TD3D12_RESOURCE_STATES;
      const ANew: TD3D12_RESOURCE_STATES);
    procedure FlushBarriers;
    /// <summary>ASize bytes of upload memory for the open list: the CPU address; AResource and AOffset, AGpu for the GPU.
    /// </summary>
    function Upload(const ASize: NativeInt; const AAlign: Integer; out AResource: ID3D12Resource; out AOffset: UInt64;
      out AGpu: UInt64): PByte;
    /// <summary>Copies rows of pixels into a texture (records the copy; the texture is left in COPY_DEST).</summary>
    procedure CopyToTexture(const ADest: ID3D12Resource; var AState: TD3D12_RESOURCE_STATES; const AFormat: TDXGI_FORMAT;
      const ABytesPerPixel, X, Y, W, H: Integer; const AData: Pointer; const APitch: Integer;
      const ASubresource: Integer = 0);
    procedure CopyToBuffer(const ADest: ID3D12Resource; var AState: TD3D12_RESOURCE_STATES; const AOffset: UInt64;
      const AData: Pointer; const ASize: NativeInt);
    /// <summary>ACount consecutive descriptors of the shader-visible heap for the open list. May submit the list (when
    /// the heap is full): ListGen tells.</summary>
    function AllocTable(const ACount: Integer; out AGpu: TD3D12_GPU_DESCRIPTOR_HANDLE): TD3D12_CPU_DESCRIPTOR_HANDLE;
    /// <summary>HDR window output: ASource (the RGBA16F surface of a window: sRGB-encoded, SDR white at 1) into
    /// ATarget (its FP16 scRGB swap chain buffer) in linear light, SDR white at AScale (ALinear: the source is linear
    /// already).</summary>
    procedure OutputHdr(const ASource, ATarget: TGpu12Surface; const AScale: Single; const ALinear: Boolean);
    /// <summary>The same between any RGBA16F texture and FP16 render target of AWidth x AHeight, given by their views
    /// (the 3D context of a TForm3D window). The caller has put them in the pixel shader resource and render target
    /// states.</summary>
    procedure OutputHdrViews(const ASrv, ARtv: TD3D12_CPU_DESCRIPTOR_HANDLE; const AWidth, AHeight: Integer;
      const AScale: Single; const ALinear: Boolean);
    property Device: ID3D12Device read FDevice;
    property Queue: ID3D12CommandQueue read FQueue;
    /// <summary>Signaled by the queue after every submission (free-threaded: other threads wait on it with their own
    /// event).</summary>
    property Fence: ID3D12Fence read FFence;
    /// <summary>Changes whenever a new command list is opened (its state is empty).</summary>
    property ListGen: Integer read FListGen;
    property SrvPool: TGpu12DescriptorPool read FSrvPool;
    property RtvPool: TGpu12DescriptorPool read FRtvPool;
    property DsvPool: TGpu12DescriptorPool read FDsvPool;
    /// <summary>The shader-visible descriptor heap of the open list.</summary>
    property Heap: ID3D12DescriptorHeap read FHeap;
    /// <summary>Who set the root signature and pipeline of the open list last (the canvas renderer, the 3D context):
    /// the other one sets its own again before it draws.</summary>
    property Owner: TObject read FOwner write FOwner;
    property SrvIncrement: Cardinal read FSrvIncrement;
  end;

  TGpu12Surface = class(TGpuSurface)
  private
    FResource: ID3D12Resource;
    FState: TD3D12_RESOURCE_STATES;
    FSrv, FRtv: TD3D12_CPU_DESCRIPTOR_HANDLE;
    FReadback: ID3D12Resource;
    FFootprint: TD3D12_PLACED_SUBRESOURCE_FOOTPRINT;
    FReadbackData: PByte;
    FReadbackSize: UInt64;
    /// <summary>The read-back copy holds the current content (no GPU write since it was taken).</summary>
    FReadbackValid: Boolean;
    procedure Init(const AFormat: TDXGI_FORMAT; const AData: Pointer; const APitch: Integer);
  public
    constructor Create(const AWidth, AHeight: Integer; const AData: Pointer; const APitch: Integer);
    /// <summary>RGBA16F, transparent black (Hdr).</summary>
    constructor CreateHdr(const AWidth, AHeight: Integer);
    /// <summary>A resource made elsewhere (a swap chain buffer): render target only. AHdr: FP16.</summary>
    constructor CreateOver(const AResource: ID3D12Resource; const AWidth, AHeight: Integer;
      const AState: TD3D12_RESOURCE_STATES; const AHdr: Boolean = False);
    destructor Destroy; override;
    function Rtv: TD3D12_CPU_DESCRIPTOR_HANDLE;
    /// <summary>Records the change to AState (device lock held).</summary>
    procedure Use(const AState: TD3D12_RESOURCE_STATES);
    procedure Upload(const AData: Pointer; const APitch: Integer); override;
    function Map(out AData: Pointer; out APitch: Integer): Boolean; override;
    procedure Unmap(const AWritten: Boolean); override;
    procedure CopyFrom(const ASource: TGpuSurface); override;
    procedure GpuWritten; override;
    property Resource: ID3D12Resource read FResource;
    property Srv: TD3D12_CPU_DESCRIPTOR_HANDLE read FSrv;
  end;

  TGpu12Window = class(TGpuWindow)
  private
    FSwapChain: IDXGISwapChain3;
    /// <summary>The swap chain presents with tearing allowed; what the canvas asked for (the swap chain is made again
    /// when that changes).</summary>
    FTearing, FTearingAsked: Boolean;
    /// <summary>The swap chain is a composition one, shown by FComposition.</summary>
    FComposed: Boolean;
    FComposition: TGpuComposition;
    FWidth, FHeight: Integer;
    FBuffers: TArray<TGpu12Surface>;
    FCurrent: TGpu12Surface;
    /// <summary>The buffer presented last (its pixels stay: flip sequential), nil when there is none.</summary>
    FShown: TGpu12Surface;
    /// <summary>Layered windows: the texture drawn into, and whether a frame was drawn into it.</summary>
    FTexture: TGpu12Surface;
    FTextureDrawn: Boolean;
    /// <summary>HDR output: the RGBA16F surface frames are drawn into (it keeps the frame for the next partial one),
    /// whether it holds a whole frame, and how it goes to the swap chain.</summary>
    FHdrSurface: TGpu12Surface;
    FHdrDrawn: Boolean;
    FOutput: TGpuOutput;
    procedure ReleaseBuffers;
    /// <summary>The color space of the swap chain's buffers: scRGB for HDR, sRGB else. False when scRGB cannot be
    /// presented.</summary>
    function SetColorSpace(const AHdr: Boolean): Boolean;
  public
    destructor Destroy; override;
    function Prepare(const AWidth, AHeight: Integer; const ATearing: Boolean; const AOutput: TGpuOutput): TGpuSurface;
      override;
    function Present: HResult; override;
    procedure ReadPixels(const ABits: Pointer; const AWidth, AHeight: Integer); override;
    function RestoreLast: Boolean; override;
    function Capture(out ACapture: TGpuCapture): Boolean; override;
  end;

  TGpu12Table = record
    Resource: ID3D12Resource;
    State: TD3D12_RESOURCE_STATES;
  end;

  TGpu12Renderer = class(TGpuRenderer)
  private
    FRoot: ID3D12RootSignature;
    FPsoBlend, FPsoCopy: ID3D12PipelineState;
    /// <summary>RGBA16F targets (HDR windows), made on first use: blend, copy; the same in linear light.</summary>
    FPso16: array[0..3] of ID3D12PipelineState;
    /// <summary>Dual-source blending (ClearType text), made on first use: 8-bit and RGBA16F targets.</summary>
    FPsoDual, FPso16Dual: ID3D12PipelineState;
    FBoundPso: Pointer;
    FClips, FPaints, FEdges, FAtlas, FRamps: TGpu12Table;
    // CPU descriptors: 0 atlas, 1 ramps, 2 clips, 3 paints, 4 edges (t8..t12, copied together), 5 empty texture.
    FStaticHeap: ID3D12DescriptorHeap;
    FStaticCpu: TD3D12_CPU_DESCRIPTOR_HANDLE;
    // Tables in the shader-visible heap for the open list (ListGen): t8..t12 and t0..t7 all empty.
    FTablesGen: Integer;
    FStaticTable, FEmptyTable: TD3D12_GPU_DESCRIPTOR_HANDLE;
    // What is set on the open list (ListGen).
    FBoundGen: Integer;
    FTargetBound: Boolean;
    FCopy: Boolean;
    procedure CreatePipeline;
    function NewPso(const AFormat: TDXGI_FORMAT; const ABlend, ALinear: Boolean;
      const ADual: Boolean = False): ID3D12PipelineState;
    /// <summary>The pipeline state for the target and the kind of draw.</summary>
    function TargetPso: ID3D12PipelineState;
    function NewBuffer(const ABytes: Integer): TGpu12Table;
    procedure TableView(const ABuffer: ID3D12Resource; const AFloat4s, ASlot: Integer);
    function Bind: ID3D12GraphicsCommandList;
    procedure UploadTables;
  protected
    procedure DrawPending; override;
    procedure UploadEdgeRange; override;
    procedure CreateEdgeTable(const ACapacity: Integer); override;
  public
    constructor Create;
    destructor Destroy; override;
    procedure BeginTarget(const ATarget: TGpuSurface; const AWidth, AHeight: Integer;
      const AAliased: Boolean); override;
    procedure Invalidate; override;
    procedure Clear(const AColor: Cardinal); override;
    procedure FillCopy(const ARect: TRectF; const AColor: Cardinal; const AClip: Cardinal); override;
    procedure UploadRamp(const ARow: Integer; const AData: Pointer); override;
    procedure UploadGlyph(const X, Y, W, H: Integer; const AData: Pointer; const APitch: Integer); override;
  end;

  TGpu12Backend = class(TGpuBackend)
  public
    class function CreateRenderer: TGpuRenderer; override;
    class function CreateSurface(const AWidth, AHeight: Integer; const AData: Pointer;
      const APitch: Integer): TGpuSurface; override;
    class function CreateHdrSurface(const AWidth, AHeight: Integer): TGpuSurface; override;
    class function CreateWindow(const AHandle: TGpuWindowHandle; const ALayered: Boolean): TGpuWindow; override;
    class procedure Submit; override;
    class procedure WaitIdle; override;
    class procedure Shutdown; override;
  end;

/// <summary>The recording context of the Direct3D 12 device (made on first use); with the device lock held.</summary>
function Gpu12: TGpu12Context;
/// <summary>The recording context, nil when there is none (not made here).</summary>
function Gpu12Current: TGpu12Context;

implementation

uses
  DX12.D3D12SDKLayers;

{$I FastCanvas.Shaders.inc}

const
  InList = High(UInt64);
  // Upload memory is system memory (in the working set): small pages, so that only what the frames in flight use
  // stays allocated.
  MaxFreePages = 8;
  /// <summary>Submissions a free page waits to be taken again before it is released: the glyphs of a first frame
  /// fill pages that the frames after it do not need (measured 2026-10-08: paragraph heavy kept 12 MB of them).
  /// </summary>
  FreePageLife = 120;
  /// <summary>Swap chain buffers. Two let the render thread wait in Present for the buffer the display still shows
  /// (Direct3D 11 does not: its runtime queues the frame); three keep it drawing (measured 2026-10-08: clip, gradients,
  /// rare +12..+23 % over two).</summary>
  SwapBuffers = 3;
  BlockSize = 1024;
  BlockCount = 64;
  StateRead = D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE;

type
  // D3D12_MESSAGE and D3D12_INFO_QUEUE_FILTER with the C layout: DX12.D3D12SDKLayers is compiled with {$A4}, which
  // packs their pointers at 4-byte offsets.
  TMessage12 = record
    Category, Severity, ID: Integer;
    Description: PAnsiChar;
    DescriptionLength: NativeUInt;
  end;
  PMessage12 = ^TMessage12;

  TFilterDesc12 = record
    NumCategories: Cardinal;
    Categories: Pointer;
    NumSeverities: Cardinal;
    Severities: Pointer;
    NumIDs: Cardinal;
    IDs: Pointer;
  end;

  TFilter12 = record
    AllowList, DenyList: TFilterDesc12;
  end;

var
  GCtx: TGpu12Context;
  PageSize: NativeInt = 2 * 1024 * 1024;  // measured 2026-10-08: 256 KB to 8 MB run as fast; 8 MB keeps 6-12 MB more

function Gpu12: TGpu12Context;
begin
  if GCtx = nil then
  begin
    TFastDevice.Lock;
    try
      if GCtx = nil then
        GCtx := TGpu12Context.Create;
    finally
      TFastDevice.Unlock;
    end;
  end;
  Result := GCtx;
end;

function Gpu12Current: TGpu12Context;
begin
  Result := GCtx;
end;

function AlignUp(const AValue: NativeInt; const AAlign: Integer): NativeInt; inline;
begin
  Result := (AValue + AAlign - 1) and not NativeInt(AAlign - 1);
end;

function Offset(const AHandle: TD3D12_CPU_DESCRIPTOR_HANDLE; const AIndex: Integer;
  const AIncrement: Cardinal): TD3D12_CPU_DESCRIPTOR_HANDLE; inline;
begin
  Result.ptr := AHandle.ptr + SIZE_T(AIndex) * AIncrement;
end;

{ TGpu12DescriptorPool }

constructor TGpu12DescriptorPool.Create(const AType: TD3D12_DESCRIPTOR_HEAP_TYPE);
begin
  inherited Create;
  FType := AType;
  FIncrement := TFastDevice.D3D12.GetDescriptorHandleIncrementSize(AType);
  FHeaps := TList<ID3D12DescriptorHeap>.Create;
  FFree := TList<SIZE_T>.Create;
end;

destructor TGpu12DescriptorPool.Destroy;
begin
  FFree.Free;
  FHeaps.Free;
  inherited;
end;

function TGpu12DescriptorPool.Alloc: TD3D12_CPU_DESCRIPTOR_HANDLE;
const
  Count = 256;
var
  Desc: TD3D12_DESCRIPTOR_HEAP_DESC;
  Heap: ID3D12DescriptorHeap;
  Start: TD3D12_CPU_DESCRIPTOR_HANDLE;
  I: Integer;
begin
  if FFree.Count = 0 then
  begin
    FillChar(Desc, SizeOf(Desc), 0);
    Desc._Type := FType;
    Desc.NumDescriptors := Count;
    Desc.Flags := D3D12_DESCRIPTOR_HEAP_FLAG_NONE;
    GpuCheck(TFastDevice.D3D12.CreateDescriptorHeap(@Desc, IID_ID3D12DescriptorHeap, @Heap), 'CreateDescriptorHeap');
    FHeaps.Add(Heap);
    Heap.GetCPUDescriptorHandleForHeapStart(Start);
    for I := Count - 1 downto 0 do
      FFree.Add(Start.ptr + SIZE_T(I) * FIncrement);
  end;
  Result.ptr := FFree.Last;
  FFree.Delete(FFree.Count - 1);
end;

procedure TGpu12DescriptorPool.Release(const AHandle: TD3D12_CPU_DESCRIPTOR_HANDLE);
begin
  if AHandle.ptr <> 0 then
    FFree.Add(AHandle.ptr);
end;

const
  /// <summary>Raised by the debug layer for a corruption or an error (to break into a debugger).</summary>
  DebugLayerException = $87D;

function AddVectoredExceptionHandler(First: Cardinal; Handler: Pointer): Pointer; stdcall;
  external 'kernel32.dll';

/// <summary>Debug layer only: the message behind DebugLayerException goes to the log, and the program goes on (as
/// it would under a debugger).</summary>
function DebugLayerHandler(P: PExceptionPointers): Integer; stdcall;
begin
  Result := 0;
  if P.ExceptionRecord.ExceptionCode = DebugLayerException then
  begin
    if GCtx <> nil then
      GCtx.DrainMessages;
    Result := -1;
  end;
end;

{ TGpu12Context }

constructor TGpu12Context.Create;
var
  Desc: TD3D12_DESCRIPTOR_HEAP_DESC;
  Info: ID3D12InfoQueue;
  Filter: TFilter12;
  Ids: array[0..0] of Integer;
begin
  inherited Create;
  FDevice := TFastDevice.D3D12;
  FQueue := TFastDevice.Queue;
  if (FDevice = nil) or (FQueue = nil) then
    raise EFastDevice.Create('FastCanvas: no Direct3D 12 device');
  GpuCheck(FDevice.CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_ID3D12Fence, FFence), 'CreateFence');
  FEvent := CreateEvent(nil, False, False, nil);
  FAllocators := TQueue<TGpu12Allocator>.Create;
  FBusyPages := TList<TGpu12Page>.Create;
  FFreePages := TList<TGpu12Page>.Create;
  FRetired := TList<TGpu12Retired>.Create;
  FListBlocks := TList<Integer>.Create;
  SetLength(FBarriers, 16);
  FillChar(Desc, SizeOf(Desc), 0);
  Desc._Type := D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;
  Desc.NumDescriptors := BlockSize * BlockCount;
  Desc.Flags := D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
  GpuCheck(FDevice.CreateDescriptorHeap(@Desc, IID_ID3D12DescriptorHeap, @FHeap), 'CreateDescriptorHeap (shader)');
  FHeap.GetCPUDescriptorHandleForHeapStart(FHeapCpu);
  FHeap.GetGPUDescriptorHandleForHeapStart(FHeapGpu);
  FSrvIncrement := FDevice.GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
  SetLength(FBlockFence, BlockCount);
  FSrvPool := TGpu12DescriptorPool.Create(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
  FRtvPool := TGpu12DescriptorPool.Create(D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
  FDsvPool := TGpu12DescriptorPool.Create(D3D12_DESCRIPTOR_HEAP_TYPE_DSV);
  if TFastDevice.Debug12 and Supports(FDevice, IID_ID3D12InfoQueue, Info) then
  begin
    FInfo := Info;
    // The layer reports to a debugger by raising exceptions, which end a process that runs without one: logged and
    // continued here.
    Info.SetMuteDebugOutput(True);
    AddVectoredExceptionHandler(1, @DebugLayerHandler);
    // Windows are cleared to their fill color, bitmaps to transparent black (their optimized clear value).
    FillChar(Filter, SizeOf(Filter), 0);
    Ids[0] := Ord(D3D12_MESSAGE_ID_CLEARRENDERTARGETVIEW_MISMATCHINGCLEARVALUE);
    Filter.DenyList.NumIDs := Length(Ids);
    Filter.DenyList.IDs := @Ids[0];
    Info.AddStorageFilterEntries(PD3D12_INFO_QUEUE_FILTER(@Filter));
  end;
end;

destructor TGpu12Context.Destroy;
var
  P: TGpu12Page;
begin
  WaitIdle;
  FRetired.Clear;
  Collect;
  if FPage <> nil then
    FBusyPages.Add(FPage);
  for P in FBusyPages do
    P.Free;
  for P in FFreePages do
    P.Free;
  FBusyPages.Free;
  FFreePages.Free;
  FRetired.Free;
  FAllocators.Free;
  FListBlocks.Free;
  FSrvPool.Free;
  FRtvPool.Free;
  FDsvPool.Free;
  FList := nil;
  FAllocator := nil;
  FHeap := nil;
  FFence := nil;
  FInfo := nil;
  if FEvent <> 0 then
    CloseHandle(FEvent);
  inherited;
end;

procedure TGpu12Context.Open;
var
  A: TGpu12Allocator;
begin
  Collect;
  if (FAllocators.Count > 0) and (FAllocators.Peek.Fence <= FFence.GetCompletedValue) then
  begin
    A := FAllocators.Dequeue;
    FAllocator := A.Allocator;
    GpuCheck(FAllocator.Reset, 'ID3D12CommandAllocator.Reset');
  end
  else
    GpuCheck(FDevice.CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, IID_ID3D12CommandAllocator, FAllocator),
      'CreateCommandAllocator');
  if FList = nil then
    GpuCheck(FDevice.CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, FAllocator, nil,
      IID_ID3D12GraphicsCommandList, FList), 'CreateCommandList')
  else
    GpuCheck(FList.Reset(FAllocator, nil), 'ID3D12GraphicsCommandList.Reset');
  FOpen := True;
  Inc(FListGen);
  FList.SetDescriptorHeaps(1, @FHeap);
  // The current block of the descriptor ring goes on in this list.
  FListBlocks.Clear;
  FListBlocks.Add(FBlock);
  FBlockFence[FBlock] := InList;
  if FPage <> nil then
    FPage.Fence := InList;
end;

function TGpu12Context.List: ID3D12GraphicsCommandList;
begin
  if not FOpen then
    Open;
  Result := FList;
end;

function TGpu12Context.Submit(const AExtra: ID3D12CommandList): UInt64;
var
  L: array[0..1] of ID3D12CommandList;
  N: Integer;
  A: TGpu12Allocator;
  B, I: Integer;
  P: TGpu12Page;
  R: TGpu12Retired;
  Opened: Boolean;
begin
  if FBarrierCount > 0 then
    FlushBarriers;
  Opened := FOpen;
  if not Opened and (AExtra = nil) then
    Exit(0);
  N := 0;
  if Opened then
  begin
    FOpen := False;
    FList.Close;
    L[N] := FList;
    Inc(N);
  end;
  if AExtra <> nil then
  begin
    L[N] := AExtra;
    Inc(N);
  end;
  // One call for both: ExecuteCommandLists costs more than its lists when they are short.
  FQueue.ExecuteCommandLists(N, @L[0]);
  Inc(FSignaled);
  FQueue.Signal(FFence, FSignaled);
  Result := FSignaled;
  if not Opened then
    Exit;
  A.Allocator := FAllocator;
  A.Fence := FSignaled;
  FAllocators.Enqueue(A);
  FAllocator := nil;
  for B in FListBlocks do
    FBlockFence[B] := FSignaled;
  FListBlocks.Clear;
  if FPage <> nil then
    FPage.Fence := FSignaled;
  for P in FBusyPages do
    if P.Fence = InList then
      P.Fence := FSignaled;
  for I := 0 to FRetired.Count - 1 do
    if FRetired[I].Fence = InList then
    begin
      R := FRetired[I];
      R.Fence := FSignaled;
      FRetired[I] := R;
    end;
  if FInfo <> nil then
    DrainMessages;
end;

procedure TGpu12Context.WaitFor(const AValue: UInt64);
begin
  if (AValue = 0) or (AValue > FSignaled) or (FFence.GetCompletedValue >= AValue) then
    Exit;
  if Succeeded(FFence.SetEventOnCompletion(AValue, FEvent)) then
    // A removed device never completes: give up when the device is gone.
    while WaitForSingleObject(FEvent, 2000) = WAIT_TIMEOUT do
      if Failed(FDevice.GetDeviceRemovedReason) then
        Break;
end;

procedure TGpu12Context.WaitIdle;
begin
  Submit;
  // A signal of its own: the queue may have work after the last submission (Present).
  Inc(FSignaled);
  FQueue.Signal(FFence, FSignaled);
  WaitFor(FSignaled);
  Collect;
end;

procedure TGpu12Context.Collect;
var
  Done: UInt64;
  I: Integer;
  P: TGpu12Page;
begin
  Done := FFence.GetCompletedValue;
  I := 0;
  while I < FRetired.Count do
    if FRetired[I].Fence <= Done then
      FRetired.Delete(I)
    else
      Inc(I);
  I := 0;
  while I < FBusyPages.Count do
  begin
    P := FBusyPages[I];
    if P.Fence <= Done then
    begin
      FBusyPages.Delete(I);
      if FFreePages.Count < MaxFreePages then
      begin
        P.Used := 0;
        P.FreeSince := FSignaled;
        FFreePages.Add(P);
      end
      else
        P.Free;
    end
    else
      Inc(I);
  end;
  I := 0;
  while I < FFreePages.Count do
    if FSignaled - FFreePages[I].FreeSince > FreePageLife then
    begin
      FFreePages[I].Free;
      FFreePages.Delete(I);
    end
    else
      Inc(I);
end;

procedure TGpu12Context.Retire(const AObject: IInterface);
var
  R: TGpu12Retired;
begin
  if AObject = nil then
    Exit;
  R.Obj := AObject;
  if FOpen then
    R.Fence := InList
  else
    R.Fence := FSignaled;
  FRetired.Add(R);
end;

procedure TGpu12Context.Transition(const AResource: ID3D12Resource; var AState: TD3D12_RESOURCE_STATES;
  const ANew: TD3D12_RESOURCE_STATES);
var
  I: Integer;
begin
  if (AState = ANew) or (AResource = nil) then
    Exit;
  // A change of the same resource waiting in the batch becomes one barrier (or none).
  for I := FBarrierCount - 1 downto 0 do
    if FBarriers[I].Transition.pResource = Pointer(AResource) then
    begin
      AState := ANew;
      if FBarriers[I].Transition.StateBefore = ANew then
      begin
        Dec(FBarrierCount);
        if I < FBarrierCount then
          FBarriers[I] := FBarriers[FBarrierCount];
      end
      else
        FBarriers[I].Transition.StateAfter := ANew;
      Exit;
    end;
  if FBarrierCount = Length(FBarriers) then
    SetLength(FBarriers, 2 * FBarrierCount);
  FBarriers[FBarrierCount] := TD3D12_RESOURCE_BARRIER.CreateTransition(Pointer(AResource), AState, ANew);
  Inc(FBarrierCount);
  AState := ANew;
end;

procedure TGpu12Context.FlushBarriers;
begin
  if FBarrierCount = 0 then
    Exit;
  List.ResourceBarrier(FBarrierCount, @FBarriers[0]);
  FBarrierCount := 0;
end;

function TGpu12Context.TakePage(const ASize: NativeInt): TGpu12Page;
var
  I, Best: Integer;
  Props: TD3D12_HEAP_PROPERTIES;
  Desc: TD3D12_RESOURCE_DESC;
  Range: TD3D12_RANGE;
  P: Pointer;
begin
  Collect;
  // The smallest free page that fits: a small request does not take the page a large one needs next.
  Best := -1;
  for I := 0 to FFreePages.Count - 1 do
    if (FFreePages[I].Size >= ASize) and ((Best < 0) or (FFreePages[I].Size < FFreePages[Best].Size)) then
      Best := I;
  if Best >= 0 then
  begin
    Result := FFreePages[Best];
    FFreePages.Delete(Best);
    Exit;
  end;
  Result := TGpu12Page.Create;
  try
    Result.Size := Max(PageSize, AlignUp(ASize, 64 * 1024));
    Props := TD3D12_HEAP_PROPERTIES.Create(D3D12_HEAP_TYPE_UPLOAD);
    Desc := TD3D12_RESOURCE_DESC.CreateBuffer(Result.Size);
    GpuCheck(FDevice.CreateCommittedResource(@Props, D3D12_HEAP_FLAG_NONE, @Desc, D3D12_RESOURCE_STATE_GENERIC_READ,
      nil, IID_ID3D12Resource, Result.Resource), 'CreateCommittedResource (upload)');
    Range._Begin := 0;
    Range._End := 0;
    GpuCheck(Result.Resource.Map(0, @Range, P), 'Map (upload)');
    Result.Cpu := P;
    Result.Gpu := Result.Resource.GetGPUVirtualAddress;
  except
    Result.Free;
    raise;
  end;
end;

function TGpu12Context.Upload(const ASize: NativeInt; const AAlign: Integer; out AResource: ID3D12Resource;
  out AOffset: UInt64; out AGpu: UInt64): PByte;
var
  Pos: NativeInt;
  P: TGpu12Page;
begin
  // The page is used by the open list.
  List;
  if FPage <> nil then
    Pos := AlignUp(FPage.Used, AAlign)
  else
    Pos := 0;
  if (FPage <> nil) and (Pos + ASize > FPage.Size) and (ASize > PageSize div 2) then
  begin
    // A large upload (the instances of a big frame) gets a page of its own; the current page stays open for the
    // small ones, which would otherwise start a new page after it each time.
    P := TakePage(ASize);
    P.Fence := InList;
    P.Used := ASize;
    FBusyPages.Add(P);
    AResource := P.Resource;
    AOffset := 0;
    AGpu := P.Gpu;
    Exit(P.Cpu);
  end;
  if (FPage = nil) or (Pos + ASize > FPage.Size) then
  begin
    if FPage <> nil then
      FBusyPages.Add(FPage);
    FPage := TakePage(ASize);
    FPage.Fence := InList;
    Pos := 0;
  end;
  FPage.Used := Pos + ASize;
  AResource := FPage.Resource;
  AOffset := Pos;
  AGpu := FPage.Gpu + UInt64(Pos);
  Result := FPage.Cpu + Pos;
end;

procedure TGpu12Context.CopyToTexture(const ADest: ID3D12Resource; var AState: TD3D12_RESOURCE_STATES;
  const AFormat: TDXGI_FORMAT; const ABytesPerPixel, X, Y, W, H: Integer; const AData: Pointer; const APitch: Integer;
  const ASubresource: Integer);
var
  Row, Pitch, I: Integer;
  P: PByte;
  Src: ID3D12Resource;
  Off, Gpu: UInt64;
  DstLoc, SrcLoc: TD3D12_TEXTURE_COPY_LOCATION;
begin
  if (W <= 0) or (H <= 0) then
    Exit;
  Row := W * ABytesPerPixel;
  Pitch := AlignUp(Row, D3D12_TEXTURE_DATA_PITCH_ALIGNMENT);
  P := Upload(NativeInt(Pitch) * H, D3D12_TEXTURE_DATA_PLACEMENT_ALIGNMENT, Src, Off, Gpu);
  for I := 0 to H - 1 do
    Move((PByte(AData) + NativeInt(I) * APitch)^, (P + NativeInt(I) * Pitch)^, Row);
  Transition(ADest, AState, D3D12_RESOURCE_STATE_COPY_DEST);
  FlushBarriers;
  DstLoc := TD3D12_TEXTURE_COPY_LOCATION.Create(ADest, ASubresource);
  SrcLoc.pResource := Src;
  SrcLoc._Type := D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
  SrcLoc.PlacedFootprint.Offset := Off;
  SrcLoc.PlacedFootprint.Footprint.Format := AFormat;
  SrcLoc.PlacedFootprint.Footprint.Width := W;
  SrcLoc.PlacedFootprint.Footprint.Height := H;
  SrcLoc.PlacedFootprint.Footprint.Depth := 1;
  SrcLoc.PlacedFootprint.Footprint.RowPitch := Pitch;
  FList.CopyTextureRegion(@DstLoc, X, Y, 0, @SrcLoc, nil);
end;

procedure TGpu12Context.CopyToBuffer(const ADest: ID3D12Resource; var AState: TD3D12_RESOURCE_STATES;
  const AOffset: UInt64; const AData: Pointer; const ASize: NativeInt);
var
  P: PByte;
  Src: ID3D12Resource;
  Off, Gpu: UInt64;
begin
  if ASize <= 0 then
    Exit;
  P := Upload(ASize, 16, Src, Off, Gpu);
  Move(AData^, P^, ASize);
  Transition(ADest, AState, D3D12_RESOURCE_STATE_COPY_DEST);
  FlushBarriers;
  FList.CopyBufferRegion(ADest, AOffset, Src, Off, ASize);
end;

procedure TGpu12Context.NextBlock;
var
  I: Integer;
begin
  I := (FBlock + 1) mod BlockCount;
  if FBlockFence[I] = InList then
  begin
    // The open list has used the whole ring: hand it over, then the block is free once the GPU is done with it.
    Submit;
    List;
  end;
  WaitFor(FBlockFence[I]);
  FBlock := I;
  FBlockPos := 0;
  FBlockFence[I] := InList;
  FListBlocks.Add(I);
end;

function TGpu12Context.AllocTable(const ACount: Integer;
  out AGpu: TD3D12_GPU_DESCRIPTOR_HANDLE): TD3D12_CPU_DESCRIPTOR_HANDLE;
var
  Index: Integer;
begin
  List;
  if FBlockPos + ACount > BlockSize then
    NextBlock;
  Index := FBlock * BlockSize + FBlockPos;
  Inc(FBlockPos, ACount);
  Result.ptr := FHeapCpu.ptr + SIZE_T(Index) * FSrvIncrement;
  AGpu.ptr := FHeapGpu.ptr + UInt64(Index) * FSrvIncrement;
end;

procedure TGpu12Context.CreateOutputPipeline;
var
  Range: TD3D12_DESCRIPTOR_RANGE;
  Params: array[0..1] of TD3D12_ROOT_PARAMETER;
  RootDesc: TD3D12_ROOT_SIGNATURE_DESC;
  Blob, Errors: ID3DBlob;
  Res: HResult;
  Pso: TD3D12_GRAPHICS_PIPELINE_STATE_DESC;
begin
  // b0: scale and mode; t0: the window's surface (read with Load, no sampler).
  Range.Init(D3D12_DESCRIPTOR_RANGE_TYPE_SRV, 1, 0);
  Params[0].InitAsConstants(4, 0, 0, D3D12_SHADER_VISIBILITY_PIXEL);
  Params[1].InitAsDescriptorTable(1, @Range, D3D12_SHADER_VISIBILITY_PIXEL);
  RootDesc.Init(Length(Params), @Params[0], 0, nil, D3D12_ROOT_SIGNATURE_FLAG_NONE);
  Res := D3D12SerializeRootSignature(RootDesc, D3D_ROOT_SIGNATURE_VERSION_1, @Blob, @Errors);
  if Failed(Res) and (Errors <> nil) then
    raise EFastDevice.CreateFmt('FastCanvas: output root signature: %s', [string(PAnsiChar(Errors.GetBufferPointer))]);
  GpuCheck(Res, 'D3D12SerializeRootSignature (output)');
  GpuCheck(FDevice.CreateRootSignature(0, Blob.GetBufferPointer, Blob.GetBufferSize, IID_ID3D12RootSignature,
    FOutRoot), 'CreateRootSignature (output)');
  Pso := Default(TD3D12_GRAPHICS_PIPELINE_STATE_DESC);
  Pso.pRootSignature := FOutRoot;
  Pso.VS := TD3D12_SHADER_BYTECODE.Create(@FastOutputVS[0], Length(FastOutputVS));
  Pso.PS := TD3D12_SHADER_BYTECODE.Create(@FastOutputPS[0], Length(FastOutputPS));
  Pso.BlendState.RenderTarget[0].SrcBlend := D3D12_BLEND_ONE;
  Pso.BlendState.RenderTarget[0].DestBlend := D3D12_BLEND_ZERO;
  Pso.BlendState.RenderTarget[0].BlendOp := D3D12_BLEND_OP_ADD;
  Pso.BlendState.RenderTarget[0].SrcBlendAlpha := D3D12_BLEND_ONE;
  Pso.BlendState.RenderTarget[0].DestBlendAlpha := D3D12_BLEND_ZERO;
  Pso.BlendState.RenderTarget[0].BlendOpAlpha := D3D12_BLEND_OP_ADD;
  Pso.BlendState.RenderTarget[0].LogicOp := D3D12_LOGIC_OP_NOOP;
  Pso.BlendState.RenderTarget[0].RenderTargetWriteMask := Ord(D3D12_COLOR_WRITE_ENABLE_ALL);
  Pso.SampleMask := $FFFFFFFF;
  Pso.RasterizerState := TD3D12_RASTERIZER_DESC.Create(D3D12_DEFAULT);
  Pso.RasterizerState.CullMode := D3D12_CULL_MODE_NONE;
  Pso.DepthStencilState := TD3D12_DEPTH_STENCIL_DESC.Create(D3D12_DEFAULT);
  Pso.DepthStencilState.DepthEnable := False;
  Pso.DepthStencilState.DepthWriteMask := D3D12_DEPTH_WRITE_MASK_ZERO;
  Pso.PrimitiveTopologyType := D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
  Pso.NumRenderTargets := 1;
  Pso.RTVFormats[0] := DXGI_FORMAT_R16G16B16A16_FLOAT;
  Pso.DSVFormat := DXGI_FORMAT_UNKNOWN;
  Pso.SampleDesc.Count := 1;
  GpuCheck(FDevice.CreateGraphicsPipelineState(@Pso, IID_ID3D12PipelineState, FOutPso),
    'CreateGraphicsPipelineState (output)');
end;

procedure TGpu12Context.OutputHdr(const ASource, ATarget: TGpu12Surface; const AScale: Single;
  const ALinear: Boolean);
begin
  ASource.Use(StateRead);
  ATarget.Use(D3D12_RESOURCE_STATE_RENDER_TARGET);
  OutputHdrViews(ASource.Srv, ATarget.Rtv, ATarget.Width, ATarget.Height, AScale, ALinear);
end;

procedure TGpu12Context.OutputHdrViews(const ASrv, ARtv: TD3D12_CPU_DESCRIPTOR_HANDLE; const AWidth,
  AHeight: Integer; const AScale: Single; const ALinear: Boolean);
var
  L: ID3D12GraphicsCommandList;
  Table, Rtv: TD3D12_CPU_DESCRIPTOR_HANDLE;
  TableGpu: TD3D12_GPU_DESCRIPTOR_HANDLE;
  K: array[0..3] of Single;
  Viewport: TD3D12_VIEWPORT;
  Scissor: TD3D12_RECT;
begin
  if FOutPso = nil then
    CreateOutputPipeline;
  // It may hand the list to the GPU when the descriptor ring is full (with the barriers so far).
  Table := AllocTable(1, TableGpu);
  FDevice.CopyDescriptorsSimple(1, Table, ASrv, D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
  FlushBarriers;
  L := List;
  L.SetGraphicsRootSignature(FOutRoot);
  L.SetPipelineState(FOutPso);
  K[0] := AScale;
  K[1] := Ord(ALinear);
  K[2] := 0;
  K[3] := 0;
  L.SetGraphicsRoot32BitConstants(0, 4, @K[0], 0);
  L.SetGraphicsRootDescriptorTable(1, TableGpu);
  Rtv := ARtv;
  L.OMSetRenderTargets(1, @Rtv, False, nil);
  Viewport.TopLeftX := 0;
  Viewport.TopLeftY := 0;
  Viewport.Width := AWidth;
  Viewport.Height := AHeight;
  Viewport.MinDepth := 0;
  Viewport.MaxDepth := 1;
  L.RSSetViewports(1, @Viewport);
  Scissor := TRect.Create(0, 0, AWidth, AHeight);
  L.RSSetScissorRects(1, @Scissor);
  L.IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
  L.DrawInstanced(3, 1, 0, 0);
  // The canvas and the 3D context set their root signature, pipeline and target again.
  FOwner := nil;
end;

/// <summary>Debug layer messages (FASTCANVAS_D3D12_DEBUG names the file) after every submission.</summary>
procedure TGpu12Context.DrainMessages;
var
  Info: ID3D12InfoQueue;
  N, I: UInt64;
  Size: SIZE_T;
  Buf: PMessage12;
  F: TextFile;
  Name: string;
begin
  Info := ID3D12InfoQueue(FInfo);
  N := Info.GetNumStoredMessages;
  if N = 0 then
    Exit;
  Name := GetEnvironmentVariable('FASTCANVAS_D3D12_DEBUG');
  AssignFile(F, Name);
  try
    if FileExists(Name) then
      Append(F)
    else
      Rewrite(F);
    try
      I := 0;
      while (I < N) and (FMessages < 2000) do
      begin
        Size := 0;
        Info.GetMessage(I, PD3D12_MESSAGE(nil)^, Size);
        if Size > 0 then
        begin
          GetMem(Buf, Size);
          try
            if Succeeded(Info.GetMessage(I, PD3D12_MESSAGE(Buf)^, Size)) then
            begin
              Writeln(F, Format('[%d] %s', [Buf.Severity, string(Buf.Description)]));
              Inc(FMessages);
            end;
          finally
            FreeMem(Buf);
          end;
        end;
        Inc(I);
      end;
    finally
      CloseFile(F);
    end;
  except
    // The log is a development aid only.
  end;
  Info.ClearStoredMessages;
end;

{ TGpu12Surface }

constructor TGpu12Surface.Create(const AWidth, AHeight: Integer; const AData: Pointer; const APitch: Integer);
begin
  inherited Create;
  FWidth := AWidth;
  FHeight := AHeight;
  Init(DXGI_FORMAT_B8G8R8A8_UNORM, AData, APitch);
end;

constructor TGpu12Surface.CreateHdr(const AWidth, AHeight: Integer);
begin
  inherited Create;
  FWidth := AWidth;
  FHeight := AHeight;
  FHdr := True;
  Init(DXGI_FORMAT_R16G16B16A16_FLOAT, nil, 0);
end;

procedure TGpu12Surface.Init(const AFormat: TDXGI_FORMAT; const AData: Pointer; const APitch: Integer);
const
  Transparent: TSingleArray4 = (0, 0, 0, 0);
var
  C: TGpu12Context;
  Props: TD3D12_HEAP_PROPERTIES;
  Desc: TD3D12_RESOURCE_DESC;
  Res: HResult;
  ClearValue: TD3D12_CLEAR_VALUE;
begin
  // Bitmaps are cleared to transparent black (TCanvas.Clear(0), new bitmaps) more than to anything else.
  FillChar(ClearValue, SizeOf(ClearValue), 0);
  ClearValue.Format := AFormat;
  TFastDevice.Lock;
  try
    C := Gpu12;
    Props := TD3D12_HEAP_PROPERTIES.Create(D3D12_HEAP_TYPE_DEFAULT);
    Desc := TD3D12_RESOURCE_DESC.CreateTex2D(AFormat, FWidth, FHeight, 1, 1, 1, 0,
      D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET);
    if AData <> nil then
      FState := D3D12_RESOURCE_STATE_COPY_DEST
    else
      FState := D3D12_RESOURCE_STATE_RENDER_TARGET;
    Res := C.Device.CreateCommittedResource(@Props, D3D12_HEAP_FLAG_NONE, @Desc, FState, @ClearValue, IID_ID3D12Resource,
      FResource);
    if Failed(Res) then
      raise EFastDevice.CreateFmt('FastCanvas: cannot create a %dx%d bitmap (0x%.8x)', [FWidth, FHeight, Cardinal(Res)]);
    FSrv := C.SrvPool.Alloc;
    C.Device.CreateShaderResourceView(FResource, nil, FSrv);
    if AData <> nil then
      C.CopyToTexture(FResource, FState, AFormat, 4, 0, 0, FWidth, FHeight, AData, APitch)
    else
    begin
      // A new bitmap is transparent black (a render target is cleared before its first use).
      C.FlushBarriers;
      C.List.ClearRenderTargetView(Rtv, Transparent, 0, nil);
    end;
    C.Transition(FResource, FState, StateRead);
  finally
    TFastDevice.Unlock;
  end;
end;

constructor TGpu12Surface.CreateOver(const AResource: ID3D12Resource; const AWidth, AHeight: Integer;
  const AState: TD3D12_RESOURCE_STATES; const AHdr: Boolean);
begin
  inherited Create;
  FWidth := AWidth;
  FHeight := AHeight;
  FResource := AResource;
  FState := AState;
  FHdr := AHdr;
end;

destructor TGpu12Surface.Destroy;
begin
  TFastDevice.Lock;
  try
    if GCtx <> nil then
    begin
      GCtx.SrvPool.Release(FSrv);
      GCtx.RtvPool.Release(FRtv);
      // Command lists that are not executed yet may use the resources.
      GCtx.Retire(FResource);
      GCtx.Retire(FReadback);
    end;
    FResource := nil;
    FReadback := nil;
  finally
    TFastDevice.Unlock;
  end;
  inherited;
end;

function TGpu12Surface.Rtv: TD3D12_CPU_DESCRIPTOR_HANDLE;
begin
  if FRtv.ptr = 0 then
  begin
    FRtv := Gpu12.RtvPool.Alloc;
    Gpu12.Device.CreateRenderTargetView(FResource, nil, FRtv);
  end;
  Result := FRtv;
end;

procedure TGpu12Surface.Use(const AState: TD3D12_RESOURCE_STATES);
begin
  Gpu12.Transition(FResource, FState, AState);
end;

procedure TGpu12Surface.GpuWritten;
begin
  FReadbackValid := False;
end;

procedure TGpu12Surface.Upload(const AData: Pointer; const APitch: Integer);
var
  C: TGpu12Context;
begin
  C := Gpu12;
  C.CopyToTexture(FResource, FState, DXGI_FORMAT_B8G8R8A8_UNORM, 4, 0, 0, FWidth, FHeight, AData, APitch);
  C.Transition(FResource, FState, StateRead);
  FReadbackValid := False;
end;

function TGpu12Surface.Map(out AData: Pointer; out APitch: Integer): Boolean;
var
  C: TGpu12Context;
  Desc: TD3D12_RESOURCE_DESC;
  Props: TD3D12_HEAP_PROPERTIES;
  Buf: TD3D12_RESOURCE_DESC;
  Total: UInt64;
  DstLoc, SrcLoc: TD3D12_TEXTURE_COPY_LOCATION;
  Range: TD3D12_RANGE;
  P: Pointer;
begin
  Result := False;
  AData := nil;
  APitch := 0;
  C := Gpu12;
  if FReadback = nil then
  begin
    FResource.GetDesc(Desc);
    C.Device.GetCopyableFootprints(@Desc, 0, 1, 0, @FFootprint, nil, nil, Total);
    // The last row with its whole pitch too: FMX code may copy Pitch * Height bytes at once (the stock 3D context's
    // CopyToBits does when the pitches match).
    FReadbackSize := Max(Total, UInt64(FFootprint.Footprint.RowPitch) * Cardinal(FHeight));
    Props := TD3D12_HEAP_PROPERTIES.Create(D3D12_HEAP_TYPE_READBACK);
    Buf := TD3D12_RESOURCE_DESC.CreateBuffer(FReadbackSize);
    if Failed(C.Device.CreateCommittedResource(@Props, D3D12_HEAP_FLAG_NONE, @Buf, D3D12_RESOURCE_STATE_COPY_DEST, nil,
      IID_ID3D12Resource, FReadback)) then
      Exit;
    FReadbackValid := False;
  end;
  if not FReadbackValid then
  begin
    C.Transition(FResource, FState, D3D12_RESOURCE_STATE_COPY_SOURCE);
    C.FlushBarriers;
    DstLoc := TD3D12_TEXTURE_COPY_LOCATION.Create(FReadback, FFootprint);
    SrcLoc := TD3D12_TEXTURE_COPY_LOCATION.Create(FResource, 0);
    C.List.CopyTextureRegion(@DstLoc, 0, 0, 0, @SrcLoc, nil);
    C.Transition(FResource, FState, StateRead);
    C.WaitIdle;
    FReadbackValid := True;
  end;
  Range._Begin := 0;
  Range._End := FReadbackSize;
  if Failed(FReadback.Map(0, @Range, P)) then
    Exit;
  FReadbackData := P;
  AData := P;
  APitch := FFootprint.Footprint.RowPitch;
  Result := True;
end;

procedure TGpu12Surface.Unmap(const AWritten: Boolean);
var
  C: TGpu12Context;
  Range: TD3D12_RANGE;
begin
  if FReadbackData = nil then
    Exit;
  if AWritten then
  begin
    // The pixels the CPU changed go back to the texture; the read-back copy stays current.
    C := Gpu12;
    C.CopyToTexture(FResource, FState, DXGI_FORMAT_B8G8R8A8_UNORM, 4, 0, 0, FWidth, FHeight, FReadbackData,
      FFootprint.Footprint.RowPitch);
    C.Transition(FResource, FState, StateRead);
  end;
  Range._Begin := 0;
  Range._End := 0;
  FReadback.Unmap(0, @Range);
  FReadbackData := nil;
end;

procedure TGpu12Surface.CopyFrom(const ASource: TGpuSurface);
var
  C: TGpu12Context;
  S: TGpu12Surface;
begin
  C := Gpu12;
  S := TGpu12Surface(ASource);
  C.Transition(S.FResource, S.FState, D3D12_RESOURCE_STATE_COPY_SOURCE);
  C.Transition(FResource, FState, D3D12_RESOURCE_STATE_COPY_DEST);
  C.FlushBarriers;
  C.List.CopyResource(FResource, S.FResource);
  C.Transition(S.FResource, S.FState, StateRead);
  C.Transition(FResource, FState, StateRead);
  FReadbackValid := False;
end;

{ TGpu12Window }

destructor TGpu12Window.Destroy;
begin
  ReleaseBuffers;
  FreeAndNil(FTexture);
  FreeAndNil(FHdrSurface);
  // The visual lets go of the swap chain and the window of the target.
  FreeAndNil(FComposition);
  FSwapChain := nil;
  inherited;
end;

function TGpu12Window.SetColorSpace(const AHdr: Boolean): Boolean;
var
  Space: TDXGI_COLOR_SPACE_TYPE;
  Support: UINT;
begin
  if AHdr then
    Space := DXGI_COLOR_SPACE_RGB_FULL_G10_NONE_P709
  else
    Space := DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709;
  Support := 0;
  Result := Succeeded(FSwapChain.CheckColorSpaceSupport(Space, Support)) and
    ((Support and Ord(DXGI_SWAP_CHAIN_COLOR_SPACE_SUPPORT_FLAG_PRESENT)) <> 0) and
    Succeeded(FSwapChain.SetColorSpace1(Space));
end;

procedure TGpu12Window.ReleaseBuffers;
var
  S: TGpu12Surface;
begin
  if FBuffers = nil then
    Exit;
  // ResizeBuffers and a new swap chain need every reference to the buffers gone, the GPU's included.
  Gpu12.WaitIdle;
  for S in FBuffers do
    S.Free;
  FBuffers := nil;
  FCurrent := nil;
  FShown := nil;
  Gpu12.Collect;
end;

function TGpu12Window.Prepare(const AWidth, AHeight: Integer; const ATearing: Boolean;
  const AOutput: TGpuOutput): TGpuSurface;
const
  Formats: array[Boolean] of TDXGI_FORMAT = (DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_FORMAT_R16G16B16A16_FLOAT);
var
  Desc: TDXGI_SWAP_CHAIN_DESC1;
  Factory: IDXGIFactory2;
  Chain: IDXGISwapChain1;
  Flags: Cardinal;
  Res: HResult;
  I: Integer;
  Buffer: ID3D12Resource;
  Hdr, Fresh: Boolean;
begin
  if FLayered then
  begin
    // A layered window shows 8-bit pixels: SDR only.
    if (FTexture <> nil) and ((AWidth <> FWidth) or (AHeight <> FHeight)) then
      FreeAndNil(FTexture);
    if FTexture = nil then
    begin
      FTexture := TGpu12Surface.Create(AWidth, AHeight, nil, 0);
      FTextureDrawn := False;
    end;
    FWidth := AWidth;
    FHeight := AHeight;
    Exit(FTexture);
  end;
  Hdr := AOutput.Hdr;
  if (FSwapChain <> nil) and ((ATearing <> FTearingAsked) or (AOutput.Composition <> FComposed)) then
  begin
    ReleaseBuffers;
    if FComposition <> nil then
      FComposition.SetContent(nil);
    FSwapChain := nil;
  end;
  Fresh := False;
  if (FSwapChain <> nil) and ((AWidth <> FWidth) or (AHeight <> FHeight) or (Hdr <> FHdr)) then
  begin
    ReleaseBuffers;
    Fresh := True;
    if FTearing then
      Flags := Ord(DXGI_SWAP_CHAIN_FLAG_ALLOW_TEARING)
    else
      Flags := 0;
    // Also from 8-bit to FP16 and back (FastCanvasHdr, another display, Windows HDR switched).
    if Failed(FSwapChain.ResizeBuffers(0, AWidth, AHeight, Formats[Hdr], Flags)) then
      FSwapChain := nil
    else if Hdr <> FHdr then
    begin
      if not SetColorSpace(Hdr) and Hdr then
      begin
        // No scRGB on this swap chain: SDR.
        Hdr := False;
        if Failed(FSwapChain.ResizeBuffers(0, AWidth, AHeight, Formats[False], Flags)) then
          FSwapChain := nil
        else
          SetColorSpace(False);
      end;
      FHdr := Hdr;
    end;
  end;
  if FSwapChain = nil then
  begin
    if not Supports(TFastDevice.DXGIFactory, IDXGIFactory2, Factory) then
      raise EFastDevice.Create('FastCanvas: DXGI 1.2 is required');
    FillChar(Desc, SizeOf(Desc), 0);
    Desc.Width := AWidth;
    Desc.Height := AHeight;
    Desc.Format := Formats[Hdr];
    Desc.SampleDesc.Count := 1;
    Desc.BufferUsage := DXGI_USAGE_RENDER_TARGET_OUTPUT;
    Desc.BufferCount := SwapBuffers;
    Desc.Scaling := DXGI_SCALING_STRETCH;
    // Sequential: the buffers keep their pixels, so a frame that updates part of the window starts from the one
    // presented last (RestoreLast). Measured 2026-10-08: as fast as discard (+-0.8 %, ellipses, text, lines, listbox).
    Desc.SwapEffect := DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
    FTearingAsked := ATearing;
    FComposed := AOutput.Composition;
    Fresh := True;
    if FComposed then
    begin
      if FComposition = nil then
        FComposition := TGpuComposition.Create;
      if not FComposition.Bind(FWnd) then
      begin
        FreeAndNil(FComposition);
        FComposed := False;
      end;
    end
    else
      FreeAndNil(FComposition);
    if FComposed then
    begin
      // The frame's alpha (premultiplied, as the canvas draws) decides what shows through. Tearing is for swap
      // chains of a window only.
      Desc.AlphaMode := DXGI_ALPHA_MODE_PREMULTIPLIED;
      FTearing := False;
      Res := Factory.CreateSwapChainForComposition(TFastDevice.Queue, @Desc, nil, Chain);
    end
    else
    begin
      Desc.AlphaMode := DXGI_ALPHA_MODE_IGNORE;
      FTearing := ATearing and TFastDevice.TearingSupported;
      if FTearing then
        Desc.Flags := Ord(DXGI_SWAP_CHAIN_FLAG_ALLOW_TEARING);
      Res := Factory.CreateSwapChainForHwnd(TFastDevice.Queue, FWnd, @Desc, nil, nil, Chain);
    end;
    if Failed(Res) or not Supports(Chain, IDXGISwapChain3, FSwapChain) then
      raise EFastDevice.CreateFmt('FastCanvas: cannot create the swap chain (0x%.8x)', [Cardinal(Res)]);
    if FComposed then
      FComposition.SetContent(FSwapChain)
    else
      Factory.MakeWindowAssociation(FWnd, DXGI_MWA_NO_WINDOW_CHANGES);
    if Hdr and not SetColorSpace(True) then
    begin
      // No scRGB on this swap chain: SDR.
      Hdr := False;
      GpuCheck(FSwapChain.ResizeBuffers(0, AWidth, AHeight, Formats[False], Desc.Flags), 'ResizeBuffers');
      SetColorSpace(False);
    end;
    FHdr := Hdr;
  end;
  if FBuffers = nil then
  begin
    SetLength(FBuffers, SwapBuffers);
    for I := 0 to High(FBuffers) do
    begin
      GpuCheck(FSwapChain.GetBuffer(I, IID_ID3D12Resource, Buffer), 'GetBuffer');
      FBuffers[I] := TGpu12Surface.CreateOver(Buffer, AWidth, AHeight, D3D12_RESOURCE_STATE_PRESENT, FHdr);
      Buffer := nil;
    end;
  end;
  FWidth := AWidth;
  FHeight := AHeight;
  if FComposed and Fresh then
    // A new or resized window: its own surface under the visual is white or undefined.
    TGpuComposition.ClearWindow(FWnd);
  FCurrent := FBuffers[FSwapChain.GetCurrentBackBufferIndex mod Cardinal(Length(FBuffers))];
  if not FHdr then
  begin
    FreeAndNil(FHdrSurface);
    Exit(FCurrent);
  end;
  // HDR: frames are drawn into an RGBA16F surface that keeps them (for partial frames) and go to the buffer at
  // Present, in linear light.
  if (FHdrSurface <> nil) and ((FHdrSurface.Width <> AWidth) or (FHdrSurface.Height <> AHeight) or
    (AOutput.Linear <> FOutput.Linear)) then
    FreeAndNil(FHdrSurface);
  if FHdrSurface = nil then
  begin
    FHdrSurface := TGpu12Surface.CreateHdr(AWidth, AHeight);
    FHdrSurface.Linear := AOutput.Linear;
    FHdrDrawn := False;
  end;
  FOutput := AOutput;
  Result := FHdrSurface;
end;

function TGpu12Window.Present: HResult;
var
  Flags: Cardinal;
begin
  if (FSwapChain = nil) or (FCurrent = nil) then
    Exit(S_OK);
  if FHdr and (FHdrSurface <> nil) then
  begin
    Gpu12.OutputHdr(FHdrSurface, FCurrent, FOutput.WhiteScale, FOutput.Linear);
    // A presented frame is whole: the next partial frame starts from it.
    FHdrDrawn := True;
  end;
  FCurrent.Use(D3D12_RESOURCE_STATE_PRESENT);
  // The frame runs before the flip.
  Gpu12.Submit;
  Flags := 0;
  if FTearing then
    Flags := DXGI_PRESENT_ALLOW_TEARING;
  Result := FSwapChain.Present(0, Flags);
  if Succeeded(Result) then
    FShown := FCurrent
  else
    FShown := nil;
end;

function TGpu12Window.RestoreLast: Boolean;
begin
  if FLayered then
    // One texture for every frame: it holds the last one, unless it was made for this frame (a new size).
    Exit((FTexture <> nil) and FTextureDrawn);
  if FHdr then
    // The same with the surface of HDR output.
    Exit((FHdrSurface <> nil) and FHdrDrawn);
  Result := (FCurrent <> nil) and (FShown <> nil) and (FShown <> FCurrent);
  if Result then
    FCurrent.CopyFrom(FShown);
end;

function TGpu12Window.Capture(out ACapture: TGpuCapture): Boolean;
var
  S: TGpu12Surface;
  P: Pointer;
  Pitch, X, Y, W, H: Integer;
  Src: PByte;
  D: PSingle;
begin
  ACapture := Default(TGpuCapture);
  Result := False;
  if FLayered then
    S := FTexture
  else
    S := FShown;
  if S = nil then
    Exit;
  W := S.Width;
  H := S.Height;
  // A copy of what the GPU holds now.
  S.GpuWritten;
  if not S.Map(P, Pitch) then
    Exit;
  try
    ACapture.Width := W;
    ACapture.Height := H;
    ACapture.Hdr := S.Hdr;
    SetLength(ACapture.Pixels, W * H * 4);
    D := @ACapture.Pixels[0];
    for Y := 0 to H - 1 do
    begin
      Src := PByte(P) + NativeInt(Y) * Pitch;
      for X := 0 to W - 1 do
      begin
        if S.Hdr then
        begin
          D^ := GpuHalfToSingle(PWord(Src)^);
          PSingle(PByte(D) + 4)^ := GpuHalfToSingle(PWord(Src + 2)^);
          PSingle(PByte(D) + 8)^ := GpuHalfToSingle(PWord(Src + 4)^);
          PSingle(PByte(D) + 12)^ := GpuHalfToSingle(PWord(Src + 6)^);
          Inc(Src, 8);
        end
        else
        begin
          // BGRA.
          D^ := Src[2] / 255;
          PSingle(PByte(D) + 4)^ := Src[1] / 255;
          PSingle(PByte(D) + 8)^ := Src[0] / 255;
          PSingle(PByte(D) + 12)^ := Src[3] / 255;
          Inc(Src, 4);
        end;
        Inc(D, 4);
      end;
    end;
    Result := True;
  finally
    S.Unmap(False);
    if not FLayered then
      S.Use(D3D12_RESOURCE_STATE_PRESENT);
  end;
end;

procedure TGpu12Window.ReadPixels(const ABits: Pointer; const AWidth, AHeight: Integer);
var
  P: Pointer;
  Pitch, I: Integer;
begin
  if FTexture = nil then
    Exit;
  FTextureDrawn := True;
  FTexture.GpuWritten;
  if not FTexture.Map(P, Pitch) then
    Exit;
  try
    for I := 0 to Min(AHeight, FHeight) - 1 do
      Move((PByte(P) + NativeInt(I) * Pitch)^, (PByte(ABits) + NativeInt(I) * AWidth * 4)^, Min(AWidth, FWidth) * 4);
  finally
    FTexture.Unmap(False);
  end;
end;

{ TGpu12Renderer }

constructor TGpu12Renderer.Create;
begin
  inherited Create;
  FTablesGen := -1;
  FBoundGen := -1;
  CreatePipeline;
end;

destructor TGpu12Renderer.Destroy;
var
  C: TGpu12Context;
  I: Integer;
begin
  C := GCtx;
  if C <> nil then
  begin
    // Submitted lists may still use them.
    C.Retire(FRoot);
    C.Retire(FPsoBlend);
    C.Retire(FPsoCopy);
    for I := 0 to High(FPso16) do
      C.Retire(FPso16[I]);
    C.Retire(FPsoDual);
    C.Retire(FPso16Dual);
    C.Retire(FClips.Resource);
    C.Retire(FPaints.Resource);
    C.Retire(FEdges.Resource);
    C.Retire(FAtlas.Resource);
    C.Retire(FRamps.Resource);
  end;
  inherited;
end;

function TGpu12Renderer.NewBuffer(const ABytes: Integer): TGpu12Table;
var
  Props: TD3D12_HEAP_PROPERTIES;
  Desc: TD3D12_RESOURCE_DESC;
begin
  Props := TD3D12_HEAP_PROPERTIES.Create(D3D12_HEAP_TYPE_DEFAULT);
  Desc := TD3D12_RESOURCE_DESC.CreateBuffer(ABytes);
  // Buffers start in COMMON whatever the initial state says.
  Result.State := D3D12_RESOURCE_STATE_COMMON;
  GpuCheck(Gpu12.Device.CreateCommittedResource(@Props, D3D12_HEAP_FLAG_NONE, @Desc, Result.State, nil,
    IID_ID3D12Resource, Result.Resource), 'CreateCommittedResource (table)');
end;

function TGpu12Renderer.NewPso(const AFormat: TDXGI_FORMAT; const ABlend, ALinear,
  ADual: Boolean): ID3D12PipelineState;
var
  Elements: array[0..5] of TD3D12_INPUT_ELEMENT_DESC;
  Pso: TD3D12_GRAPHICS_PIPELINE_STATE_DESC;

  procedure Element(const AIndex: Integer; const AName: PAnsiChar; const AFormat: TDXGI_FORMAT; const AOffset: Cardinal);
  begin
    Elements[AIndex].SemanticName := AName;
    Elements[AIndex].SemanticIndex := 0;
    Elements[AIndex].Format := AFormat;
    Elements[AIndex].InputSlot := 0;
    Elements[AIndex].AlignedByteOffset := AOffset;
    Elements[AIndex].InputSlotClass := D3D12_INPUT_CLASSIFICATION_PER_INSTANCE_DATA;
    Elements[AIndex].InstanceDataStepRate := 1;
  end;

begin
  Element(0, 'RECT', DXGI_FORMAT_R32G32B32A32_FLOAT, 0);
  Element(1, 'XFORM', DXGI_FORMAT_R32G32B32A32_FLOAT, 16);
  Element(2, 'XLATE', DXGI_FORMAT_R32G32B32A32_FLOAT, 32);
  Element(3, 'UVRECT', DXGI_FORMAT_R32G32B32A32_FLOAT, 48);
  Element(4, 'DATA', DXGI_FORMAT_R32G32B32A32_UINT, 64);
  Element(5, 'STROKE', DXGI_FORMAT_R32_FLOAT, 80);
  Pso := Default(TD3D12_GRAPHICS_PIPELINE_STATE_DESC);
  Pso.pRootSignature := FRoot;
  Pso.VS := TD3D12_SHADER_BYTECODE.Create(@FastCanvasVS[0], Length(FastCanvasVS));
  if ADual then
    Pso.PS := TD3D12_SHADER_BYTECODE.Create(@FastCanvasPSDual[0], Length(FastCanvasPSDual))
  else if ALinear then
    Pso.PS := TD3D12_SHADER_BYTECODE.Create(@FastCanvasPSLinear[0], Length(FastCanvasPSLinear))
  else
    Pso.PS := TD3D12_SHADER_BYTECODE.Create(@FastCanvasPS[0], Length(FastCanvasPS));
  // Premultiplied alpha: result = source + destination * (1 - source alpha).
  Pso.BlendState.RenderTarget[0].BlendEnable := ABlend;
  Pso.BlendState.RenderTarget[0].SrcBlend := D3D12_BLEND_ONE;
  Pso.BlendState.RenderTarget[0].DestBlend := D3D12_BLEND_INV_SRC_ALPHA;
  Pso.BlendState.RenderTarget[0].BlendOp := D3D12_BLEND_OP_ADD;
  Pso.BlendState.RenderTarget[0].SrcBlendAlpha := D3D12_BLEND_ONE;
  Pso.BlendState.RenderTarget[0].DestBlendAlpha := D3D12_BLEND_INV_SRC_ALPHA;
  Pso.BlendState.RenderTarget[0].BlendOpAlpha := D3D12_BLEND_OP_ADD;
  Pso.BlendState.RenderTarget[0].LogicOp := D3D12_LOGIC_OP_NOOP;
  Pso.BlendState.RenderTarget[0].RenderTargetWriteMask := Ord(D3D12_COLOR_WRITE_ENABLE_ALL);
  if ADual then
  begin
    // ClearType: result = color + destination * (1 - weights), the weights per channel (second output).
    Pso.BlendState.RenderTarget[0].DestBlend := D3D12_BLEND_INV_SRC1_COLOR;
    Pso.BlendState.RenderTarget[0].DestBlendAlpha := D3D12_BLEND_INV_SRC1_ALPHA;
  end;
  Pso.SampleMask := $FFFFFFFF;
  Pso.RasterizerState := TD3D12_RASTERIZER_DESC.Create(D3D12_DEFAULT);
  Pso.RasterizerState.CullMode := D3D12_CULL_MODE_NONE;
  Pso.DepthStencilState := TD3D12_DEPTH_STENCIL_DESC.Create(D3D12_DEFAULT);
  Pso.DepthStencilState.DepthEnable := False;
  Pso.DepthStencilState.DepthWriteMask := D3D12_DEPTH_WRITE_MASK_ZERO;
  Pso.InputLayout.pInputElementDescs := @Elements[0];
  Pso.InputLayout.NumElements := Length(Elements);
  Pso.PrimitiveTopologyType := D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
  Pso.NumRenderTargets := 1;
  Pso.RTVFormats[0] := AFormat;
  Pso.DSVFormat := DXGI_FORMAT_UNKNOWN;
  Pso.SampleDesc.Count := 1;
  GpuCheck(Gpu12.Device.CreateGraphicsPipelineState(@Pso, IID_ID3D12PipelineState, Result),
    'CreateGraphicsPipelineState');
end;

function TGpu12Renderer.TargetPso: ID3D12PipelineState;
var
  I: Integer;
begin
  if FDual and not FCopy and not FTarget.Linear then
  begin
    // ClearType text in the frame: everything blends with the second output (the same result for the rest).
    if FTarget.Hdr then
    begin
      if FPso16Dual = nil then
        FPso16Dual := NewPso(DXGI_FORMAT_R16G16B16A16_FLOAT, True, False, True);
      Exit(FPso16Dual);
    end;
    if FPsoDual = nil then
      FPsoDual := NewPso(DXGI_FORMAT_B8G8R8A8_UNORM, True, False, True);
    Exit(FPsoDual);
  end;
  if not FTarget.Hdr then
  begin
    if FCopy then
      Exit(FPsoCopy);
    Exit(FPsoBlend);
  end;
  I := Ord(FCopy) + 2 * Ord(FTarget.Linear);
  if FPso16[I] = nil then
    FPso16[I] := NewPso(DXGI_FORMAT_R16G16B16A16_FLOAT, not FCopy, FTarget.Linear);
  Result := FPso16[I];
end;

procedure TGpu12Renderer.CreatePipeline;
var
  C: TGpu12Context;
  D: ID3D12Device;
  Ranges: array[0..1] of TD3D12_DESCRIPTOR_RANGE;
  Params: array[0..2] of TD3D12_ROOT_PARAMETER;
  Samplers: array[0..2] of TD3D12_STATIC_SAMPLER_DESC;
  RootDesc: TD3D12_ROOT_SIGNATURE_DESC;
  Blob, Errors: ID3DBlob;
  Res: HResult;
  HeapDesc: TD3D12_DESCRIPTOR_HEAP_DESC;
  Props: TD3D12_HEAP_PROPERTIES;
  Tex: TD3D12_RESOURCE_DESC;
  View: TD3D12_SHADER_RESOURCE_VIEW_DESC;

  function Sampler(const ARegister: Cardinal; const AFilter: TD3D12_FILTER;
    const AAddress: TD3D12_TEXTURE_ADDRESS_MODE): TD3D12_STATIC_SAMPLER_DESC;
  begin
    Result := TD3D12_STATIC_SAMPLER_DESC.Create(ARegister, AFilter, AAddress, AAddress,
      D3D12_TEXTURE_ADDRESS_MODE_CLAMP, 0, 1, D3D12_COMPARISON_FUNC_NEVER, D3D12_STATIC_BORDER_COLOR_TRANSPARENT_BLACK,
      0, D3D12_FLOAT32_MAX, D3D12_SHADER_VISIBILITY_PIXEL);
  end;

  function Texture(const AWidth, AHeight: Integer; const AFormat: TDXGI_FORMAT): TGpu12Table;
  begin
    Props := TD3D12_HEAP_PROPERTIES.Create(D3D12_HEAP_TYPE_DEFAULT);
    Tex := TD3D12_RESOURCE_DESC.CreateTex2D(AFormat, AWidth, AHeight, 1, 1);
    Result.State := D3D12_RESOURCE_STATE_COPY_DEST;
    GpuCheck(D.CreateCommittedResource(@Props, D3D12_HEAP_FLAG_NONE, @Tex, Result.State, nil, IID_ID3D12Resource,
      Result.Resource), 'CreateCommittedResource (texture)');
  end;

begin
  C := Gpu12;
  D := C.Device;
  Ranges[0].Init(D3D12_DESCRIPTOR_RANGE_TYPE_SRV, GpuSlotCount, 0);
  Ranges[1].Init(D3D12_DESCRIPTOR_RANGE_TYPE_SRV, 5, GpuSlotCount);
  Params[0].InitAsConstants(SizeOf(TGpuFrameConstants) div 4, 0, 0, D3D12_SHADER_VISIBILITY_ALL);
  Params[1].InitAsDescriptorTable(1, @Ranges[0], D3D12_SHADER_VISIBILITY_PIXEL);
  Params[2].InitAsDescriptorTable(1, @Ranges[1], D3D12_SHADER_VISIBILITY_PIXEL);
  // s0 linear clamp, s1 point clamp, s2 linear wrap (bitmap brushes in tile mode).
  Samplers[0] := Sampler(0, D3D12_FILTER_MIN_MAG_MIP_LINEAR, D3D12_TEXTURE_ADDRESS_MODE_CLAMP);
  Samplers[1] := Sampler(1, D3D12_FILTER_MIN_MAG_MIP_POINT, D3D12_TEXTURE_ADDRESS_MODE_CLAMP);
  Samplers[2] := Sampler(2, D3D12_FILTER_MIN_MAG_MIP_LINEAR, D3D12_TEXTURE_ADDRESS_MODE_WRAP);
  RootDesc.Init(Length(Params), @Params[0], Length(Samplers), @Samplers[0],
    D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT);
  Res := D3D12SerializeRootSignature(RootDesc, D3D_ROOT_SIGNATURE_VERSION_1, @Blob, @Errors);
  if Failed(Res) and (Errors <> nil) then
    raise EFastDevice.CreateFmt('FastCanvas: root signature: %s', [string(PAnsiChar(Errors.GetBufferPointer))]);
  GpuCheck(Res, 'D3D12SerializeRootSignature');
  GpuCheck(D.CreateRootSignature(0, Blob.GetBufferPointer, Blob.GetBufferSize, IID_ID3D12RootSignature, FRoot),
    'CreateRootSignature');
  FPsoBlend := NewPso(DXGI_FORMAT_B8G8R8A8_UNORM, True, False);
  FPsoCopy := NewPso(DXGI_FORMAT_B8G8R8A8_UNORM, False, False);

  FillChar(HeapDesc, SizeOf(HeapDesc), 0);
  HeapDesc._Type := D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;
  HeapDesc.NumDescriptors := 6;
  HeapDesc.Flags := D3D12_DESCRIPTOR_HEAP_FLAG_NONE;
  GpuCheck(D.CreateDescriptorHeap(@HeapDesc, IID_ID3D12DescriptorHeap, @FStaticHeap), 'CreateDescriptorHeap (tables)');
  FStaticHeap.GetCPUDescriptorHandleForHeapStart(FStaticCpu);

  FAtlas := Texture(GpuAtlasSize, GpuAtlasSize, DXGI_FORMAT_R8_UNORM);
  D.CreateShaderResourceView(FAtlas.Resource, nil, Offset(FStaticCpu, 0, C.SrvIncrement));
  FRamps := Texture(GpuRampWidth, GpuRampRows, DXGI_FORMAT_R8G8B8A8_UNORM);
  D.CreateShaderResourceView(FRamps.Resource, nil, Offset(FStaticCpu, 1, C.SrvIncrement));
  FClips := NewBuffer(GpuMaxClips * GpuClipFloat4s * 16);
  TableView(FClips.Resource, GpuMaxClips * GpuClipFloat4s, 2);
  FPaints := NewBuffer(GpuMaxPaints * GpuPaintFloat4s * 16);
  TableView(FPaints.Resource, GpuMaxPaints * GpuPaintFloat4s, 3);
  CreateEdgeTable(GpuEdgesInitial);
  // The view of a texture unit without a texture.
  FillChar(View, SizeOf(View), 0);
  View.Format := DXGI_FORMAT_B8G8R8A8_UNORM;
  View.ViewDimension := D3D12_SRV_DIMENSION_TEXTURE2D;
  View.Shader4ComponentMapping := D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
  View.Texture2D.MipLevels := 1;
  D.CreateShaderResourceView(nil, @View, Offset(FStaticCpu, 5, C.SrvIncrement));
end;

procedure TGpu12Renderer.TableView(const ABuffer: ID3D12Resource; const AFloat4s, ASlot: Integer);
var
  View: TD3D12_SHADER_RESOURCE_VIEW_DESC;
begin
  FillChar(View, SizeOf(View), 0);
  View.Format := DXGI_FORMAT_R32G32B32A32_FLOAT;
  View.ViewDimension := D3D12_SRV_DIMENSION_BUFFER;
  View.Shader4ComponentMapping := D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
  View.Buffer.FirstElement := 0;
  View.Buffer.NumElements := AFloat4s;
  View.Buffer.StructureByteStride := 0;
  View.Buffer.Flags := D3D12_BUFFER_SRV_FLAG_NONE;
  Gpu12.Device.CreateShaderResourceView(ABuffer, @View, Offset(FStaticCpu, ASlot, Gpu12.SrvIncrement));
end;

procedure TGpu12Renderer.CreateEdgeTable(const ACapacity: Integer);
begin
  if FEdges.Resource <> nil then
    Gpu12.Retire(FEdges.Resource);
  FEdges := NewBuffer(ACapacity * 16);
  TableView(FEdges.Resource, ACapacity, 4);
  FEdgeCapacity := ACapacity;
  FEdgeLo := 0;
  FEdgeHi := 0;
  // The table of the open list holds the old view.
  FTablesGen := -1;
end;

procedure TGpu12Renderer.Invalidate;
begin
  // Something else recorded into the open list (its root signature and pipeline state may differ).
  FBoundGen := -1;
end;

procedure TGpu12Renderer.BeginTarget(const ATarget: TGpuSurface; const AWidth, AHeight: Integer;
  const AAliased: Boolean);
begin
  if (ATarget = FTarget) and (AWidth = FWidth) and (AHeight = FHeight) and (AAliased = FAliased) then
    Exit;
  inherited;
  FTargetBound := False;
end;

/// <summary>The open list with the pipeline of the renderer, the tables (made by DrawPending for this list) and the
/// target set, and the resources in the states the draw needs.</summary>
function TGpu12Renderer.Bind: ID3D12GraphicsCommandList;
var
  C: TGpu12Context;
  L: ID3D12GraphicsCommandList;
  Rtv: TD3D12_CPU_DESCRIPTOR_HANDLE;
  Viewport: TD3D12_VIEWPORT;
  Scissor: TD3D12_RECT;
  K: TGpuFrameConstants;
  Pso: ID3D12PipelineState;
begin
  C := Gpu12;
  L := C.List;
  if (FBoundGen <> C.ListGen) or (C.Owner <> Self) then
  begin
    C.Owner := Self;
    L.SetGraphicsRootSignature(FRoot);
    FBoundPso := nil;
    L.IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP);
    L.SetGraphicsRootDescriptorTable(2, FStaticTable);
    FBoundGen := C.ListGen;
    FTargetBound := False;
    FFrameDirty := True;
  end;
  // By the kind of draw (blend or copy) and the target (8-bit, or RGBA16F of an HDR window).
  Pso := TargetPso;
  if Pointer(Pso) <> FBoundPso then
  begin
    L.SetPipelineState(Pso);
    FBoundPso := Pointer(Pso);
  end;
  if not FTargetBound then
  begin
    Rtv := TGpu12Surface(FTarget).Rtv;
    L.OMSetRenderTargets(1, @Rtv, False, nil);
    Viewport.TopLeftX := 0;
    Viewport.TopLeftY := 0;
    Viewport.Width := FWidth;
    Viewport.Height := FHeight;
    Viewport.MinDepth := 0;
    Viewport.MaxDepth := 1;
    L.RSSetViewports(1, @Viewport);
    Scissor := TRect.Create(0, 0, FWidth, FHeight);
    L.RSSetScissorRects(1, @Scissor);
    FTargetBound := True;
  end;
  if FFrameDirty then
  begin
    K := FrameConstants;
    L.SetGraphicsRoot32BitConstants(0, SizeOf(K) div 4, @K, 0);
    FFrameDirty := False;
  end;
  TGpu12Surface(FTarget).Use(D3D12_RESOURCE_STATE_RENDER_TARGET);
  C.Transition(FAtlas.Resource, FAtlas.State, StateRead);
  C.Transition(FRamps.Resource, FRamps.State, StateRead);
  C.Transition(FClips.Resource, FClips.State, StateRead);
  C.Transition(FPaints.Resource, FPaints.State, StateRead);
  C.Transition(FEdges.Resource, FEdges.State, StateRead);
  C.FlushBarriers;
  Result := L;
end;

procedure TGpu12Renderer.UploadTables;
var
  Data: PSingle;
  First, Count: Integer;
begin
  Data := TakeClips(First, Count);
  if Count > 0 then
    Gpu12.CopyToBuffer(FClips.Resource, FClips.State, UInt64(First) * GpuClipFloat4s * 16, Data,
      NativeInt(Count) * GpuClipFloat4s * 16);
  UploadEdgeRange;
  if TakePaints(First, Count) then
    Gpu12.CopyToBuffer(FPaints.Resource, FPaints.State, UInt64(First) * GpuPaintFloat4s * 16, @FPaintData[First],
      NativeInt(Count) * GpuPaintFloat4s * 16);
end;

procedure TGpu12Renderer.UploadEdgeRange;
begin
  if FEdgeHi <= FEdgeLo then
    Exit;
  Gpu12.CopyToBuffer(FEdges.Resource, FEdges.State, UInt64(FEdgeLo) * 16, @FEdgeData[0],
    NativeInt(FEdgeHi - FEdgeLo) * 16);
  FEdgeLo := 0;
  FEdgeHi := 0;
end;

procedure TGpu12Renderer.DrawPending;
var
  C: TGpu12Context;
  L: ID3D12GraphicsCommandList;
  Bytes: NativeInt;
  P: PByte;
  Res: ID3D12Resource;
  Off, Gpu: UInt64;
  Gen, I: Integer;
  Table: TD3D12_CPU_DESCRIPTOR_HANDLE;
  TableGpu: TD3D12_GPU_DESCRIPTOR_HANDLE;
  Src: TD3D12_CPU_DESCRIPTOR_HANDLE;
  S: TGpuSurface;
  View: TD3D12_VERTEX_BUFFER_VIEW;
begin
  if (FPendingCount = 0) or (FTarget = nil) then
  begin
    FPendingCount := 0;
    Exit;
  end;
  C := Gpu12;
  UploadTables;
  Bytes := NativeInt(FPendingCount) * GpuInstanceStride;
  P := C.Upload(Bytes, 16, Res, Off, Gpu);
  Move(FPending[0], P^, Bytes);
  // Descriptor tables in the heap of the open list: when the heap is full, the list is submitted and the tables are
  // made again in the next one.
  repeat
    Gen := C.ListGen;
    if FTablesGen <> Gen then
    begin
      Table := C.AllocTable(5, FStaticTable);
      C.Device.CopyDescriptorsSimple(5, Table, FStaticCpu, D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
      Table := C.AllocTable(GpuSlotCount, FEmptyTable);
      for I := 0 to GpuSlotCount - 1 do
        C.Device.CopyDescriptorsSimple(1, Offset(Table, I, C.SrvIncrement), Offset(FStaticCpu, 5, C.SrvIncrement),
          D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
      FTablesGen := Gen;
      // A new static table (a new edge table in the same list) is set again.
      if FBoundGen = Gen then
        FBoundGen := -1;
    end;
    TableGpu := FEmptyTable;
    if FSlotCount > 0 then
    begin
      Table := C.AllocTable(GpuSlotCount, TableGpu);
      for I := 0 to GpuSlotCount - 1 do
      begin
        Src := Offset(FStaticCpu, 5, C.SrvIncrement);
        if I < FSlotCount then
        begin
          S := IGpuTexture(FSlotTex[I]).Surface;
          if (S <> nil) and (S <> FTarget) and (TGpu12Surface(S).Srv.ptr <> 0) then
          begin
            TGpu12Surface(S).Use(StateRead);
            Src := TGpu12Surface(S).Srv;
          end;
        end;
        C.Device.CopyDescriptorsSimple(1, Offset(Table, I, C.SrvIncrement), Src, D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
      end;
    end;
  until C.ListGen = Gen;
  L := Bind;
  L.SetGraphicsRootDescriptorTable(1, TableGpu);
  View.BufferLocation := Gpu;
  View.SizeInBytes := Bytes;
  View.StrideInBytes := GpuInstanceStride;
  L.IASetVertexBuffers(0, 1, @View);
  L.DrawInstanced(4, FPendingCount, 0, 0);
  Inc(FDrawCalls);
  FPendingCount := 0;
end;

procedure TGpu12Renderer.Clear(const AColor: Cardinal);
var
  C: TGpu12Context;
  K: TSingleArray4;
  I: Integer;
begin
  Flush;
  if FTarget = nil then
    Exit;
  // The target holds premultiplied colors.
  K[3] := (AColor shr 24) / 255;
  K[0] := ((AColor shr 16) and $FF) / 255;
  K[1] := ((AColor shr 8) and $FF) / 255;
  K[2] := (AColor and $FF) / 255;
  if FTarget.Linear then
    for I := 0 to 2 do
      if K[I] <= 0.04045 then
        K[I] := K[I] / 12.92
      else
        K[I] := Power((K[I] + 0.055) / 1.055, 2.4);
  K[0] := K[0] * K[3];
  K[1] := K[1] * K[3];
  K[2] := K[2] * K[3];
  C := Gpu12;
  TGpu12Surface(FTarget).Use(D3D12_RESOURCE_STATE_RENDER_TARGET);
  C.FlushBarriers;
  C.List.ClearRenderTargetView(TGpu12Surface(FTarget).Rtv, K, 0, nil);
end;

procedure TGpu12Renderer.FillCopy(const ARect: TRectF; const AColor: Cardinal; const AClip: Cardinal);
var
  I: TGpuInstance;
begin
  Flush;
  if FTarget = nil then
    Exit;
  FillChar(I, SizeOf(I), 0);
  I.X0 := ARect.Left;
  I.Y0 := ARect.Top;
  I.X1 := ARect.Right;
  I.Y1 := ARect.Bottom;
  I.M11 := 1;
  I.M22 := 1;
  I.Color := AColor;
  I.Flags := GpuKindSolid;
  I.Clip := AClip;
  Add(@I, 1);
  FCopy := True;
  try
    DrawPending;
  finally
    FCopy := False;
  end;
end;

procedure TGpu12Renderer.UploadRamp(const ARow: Integer; const AData: Pointer);
begin
  Gpu12.CopyToTexture(FRamps.Resource, FRamps.State, DXGI_FORMAT_R8G8B8A8_UNORM, 4, 0, ARow, GpuRampWidth, 1, AData,
    GpuRampWidth * 4);
end;

procedure TGpu12Renderer.UploadGlyph(const X, Y, W, H: Integer; const AData: Pointer; const APitch: Integer);
begin
  Gpu12.CopyToTexture(FAtlas.Resource, FAtlas.State, DXGI_FORMAT_R8_UNORM, 1, X, Y, W, H, AData, APitch);
end;

{ TGpu12Backend }

class function TGpu12Backend.CreateRenderer: TGpuRenderer;
begin
  Result := TGpu12Renderer.Create;
end;

class function TGpu12Backend.CreateSurface(const AWidth, AHeight: Integer; const AData: Pointer;
  const APitch: Integer): TGpuSurface;
begin
  Result := TGpu12Surface.Create(AWidth, AHeight, AData, APitch);
end;

class function TGpu12Backend.CreateHdrSurface(const AWidth, AHeight: Integer): TGpuSurface;
begin
  Result := TGpu12Surface.CreateHdr(AWidth, AHeight);
end;

class function TGpu12Backend.CreateWindow(const AHandle: TGpuWindowHandle;
  const ALayered: Boolean): TGpuWindow;
begin
  Result := TGpu12Window.Create(AHandle, ALayered);
end;

class procedure TGpu12Backend.Submit;
begin
  if GCtx = nil then
    Exit;
  TFastDevice.Lock;
  try
    GCtx.Submit;
  finally
    TFastDevice.Unlock;
  end;
end;

class procedure TGpu12Backend.WaitIdle;
begin
  if GCtx = nil then
    Exit;
  TFastDevice.Lock;
  try
    GCtx.WaitIdle;
  finally
    TFastDevice.Unlock;
  end;
end;

class procedure TGpu12Backend.Shutdown;
begin
  TFastDevice.Lock;
  try
    FreeAndNil(GCtx);
  finally
    TFastDevice.Unlock;
  end;
end;

end.
