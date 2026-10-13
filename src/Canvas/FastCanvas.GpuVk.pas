unit FastCanvas.GpuVk;

{ Vulkan backend of the FastCanvas renderer (FastCanvas.Gpu), on the device of FastCanvas.DeviceVk; the model is the
  Direct3D 12 backend (FastCanvas.Gpu12).

  One recording context per device (TGpuVkContext, used with the device lock held): a primary command buffer opened
  on first use and submitted before Present, at the end of every executed chunk of the canvas command stream, and
  when the CPU needs results (Map, transparent windows). Every submission signals the next value of one timeline
  semaphore; command pools, upload pages and descriptor pools are used again once the timeline has passed the
  submission that used them last, and objects released while the GPU may still use them wait for it too (Retire).

  Image layouts (and the stages and accesses that go with them, TGpuVkUse) are tracked per image and changed by
  batched synchronization2 barriers right before the next command that needs them; the table buffers take global
  memory barriers. Bitmap surfaces rest in SHADER_READ_ONLY_OPTIMAL. Draws run in dynamic rendering instances, which
  the context ends before every copy or barrier and begins again for the next draw (loading the target).

  The pipeline: one descriptor set layout (binding 0 the cbuffer Frame, 16..23 the textures of a draw, 24 atlas,
  25 ramps, 26..28 clips, paints and edges as uniform texel buffers, 32..34 the three immutable samplers) and three
  pipelines (blending, copy, dual-source blending) with the SPIR-V of FastCanvas.VkShaders.inc. A draw takes a
  descriptor set of the current pool (made again only when its textures or constants change); the instances and the
  frame constants go into the upload pages. The shaders do not flip clip space for Vulkan: the viewport does
  (negative height), so pixel coordinates are those of Direct3D.

  Windows: frames are drawn into a surface of the window (TGpuVkSurface), which keeps the frame (RestoreLast,
  Capture) and which transparent windows read back. Present copies it into a second surface and wakes the window's
  presenting thread (TGpuVkPresenter), which acquires a swap chain image, copies the newest frame into it (blit when
  the sizes or formats differ) and presents it: the render thread waits neither for the display nor for the driver's
  acquire and present (measured 2026-10-14 on the RX 9070 XT: text light without tearing 3800 FPS against 60 with
  FIFO on the render thread; with tearing 4900 against 3400 with IMMEDIATE on the render thread). The mode: IMMEDIATE
  when tearing is allowed, else MAILBOX, else FIFO_LATEST_READY (the AMD driver offers no MAILBOX), else FIFO, which
  wait for the refresh on the presenting thread only: frames come as fast as with Direct3D 12 presenting with sync
  interval 0. The swap chain is made again when the frame's size or the tearing changes, or when Vulkan reports it
  out of date or suboptimal. Vulkan windows present to the window itself (opaque, as Flip): no DirectComposition. No
  HDR yet (CreateHdrSurface returns nil, windows are 8-bit). }

interface

uses
  Winapi.Windows, System.SysUtils, System.Types, System.Math, System.Classes, System.SyncObjs,
  System.Generics.Collections, Vulkan, FastCanvas.Device, FastCanvas.DeviceVk, FastCanvas.Gpu;

const
  /// <summary>Window frames the GPU may have queued: Present waits for the frame this many before, as the presenting
  /// thread does for its copy.</summary>
  FramesInFlight = 3;

type
  TGpuVkSurface = class;
  TGpuVkWindow = class;

  {$SCOPEDENUMS ON}
  /// <summary>What an image (or a table buffer) is used for next: its layout, and the stages and accesses barriers
  /// wait for and make visible.</summary>
  TGpuVkUse = (Undefined, ShaderRead, ColorTarget, TransferSrc, TransferDst);

  /// <summary>Kinds of Vulkan objects that Retire keeps until the GPU is done with them (Memory: a TFastVkAllocation).
  /// </summary>
  TGpuVkObject = (Image, ImageView, Memory, Buffer, BufferView, Pipeline, PipelineLayout, SetLayout, Sampler,
    ShaderModule, Semaphore);
  {$SCOPEDENUMS OFF}

  /// <summary>Part of a host-visible buffer, mapped for writing.</summary>
  TGpuVkPage = class
  public
    Buffer: TVkBuffer;
    Memory: TFastVkAllocation;
    Cpu: PByte;
    Size, Used: NativeInt;
    /// <summary>The last submission that uses the page (InList: the open command buffer).</summary>
    Value: UInt64;
    /// <summary>Free page: the submission when it became free (released after FreePageLife more).</summary>
    FreeSince: UInt64;
  end;

  TGpuVkRetired = record
    Kind: TGpuVkObject;
    Handle: UInt64;
    Value: UInt64;
  end;

  /// <summary>A command pool with its one command buffer, and the submission that used it last.</summary>
  TGpuVkCommands = record
    Pool: TVkCommandPool;
    Buffer: TVkCommandBuffer;
    Value: UInt64;
  end;

  TGpuVkPool = record
    Pool: TVkDescriptorPool;
    Value: UInt64;
  end;

  /// <summary>Command recording on the queue of the device; with the device lock held.</summary>
  TGpuVkContext = class
  private
    FFast: TFastVulkan;
    FVk: TVulkan;
    FDevice: TVkDevice;
    FQueue: TVkQueue;
    FTimeline: TVkSemaphore;
    FSignaled: UInt64;
    FCmd: TGpuVkCommands;
    FOpen: Boolean;
    FListGen: Integer;
    FCommands: TQueue<TGpuVkCommands>;
    FBarriers: TArray<TVkImageMemoryBarrier2>;
    FBarrierCount: Integer;
    // The global memory barrier of the batch (table buffers, host reads).
    FMemSrcStage, FMemSrcAccess, FMemDstStage, FMemDstAccess: UInt64;
    FPage: TGpuVkPage;
    FBusyPages, FFreePages: TList<TGpuVkPage>;
    FRetired: TList<TGpuVkRetired>;
    FPool: TGpuVkPool;
    FPoolSets: Integer;
    FBusyPools: TList<TGpuVkPool>;
    FFreePools: TList<TVkDescriptorPool>;
    FRendering: TGpuVkSurface;
    FSurfaces: TList<TGpuVkSurface>;
    FWindows: TList<TGpuVkWindow>;
    FUniformAlign: Integer;
    FOwner: TObject;
    procedure Open;
    function Completed: UInt64;
    function TakePage(const ASize: NativeInt): TGpuVkPage;
    procedure FreePage(const APage: TGpuVkPage);
    procedure NextPool;
    procedure DestroyObject(const AKind: TGpuVkObject; const AHandle: UInt64);
  public
    constructor Create;
    destructor Destroy; override;
    /// <summary>Raises EFastDevice when ARes is an error (a lost device is noted first).</summary>
    procedure Check(const ARes: TVkResult; const AWhat: string);
    /// <summary>The open command buffer (opened if needed).</summary>
    function Cmd: TVkCommandBuffer;
    /// <summary>The open command buffer for a command outside rendering (a copy, a clear): rendering ended and the
    /// barriers recorded so far issued.</summary>
    function TransferCmd: TVkCommandBuffer;
    /// <summary>Executes the open command buffer on the queue (waiting for AWait at AWaitStage first, signaling
    /// ASignal, both binary semaphores of a swap chain) and signals the timeline. Returns the timeline value that
    /// marks its completion (0: nothing was submitted).</summary>
    function Submit(const AWait: TVkSemaphore = VK_NULL_HANDLE; const AWaitStage: UInt64 = 0;
      const ASignal: TVkSemaphore = VK_NULL_HANDLE): UInt64;
    procedure WaitFor(const AValue: UInt64);
    /// <summary>Submits and waits until the GPU has executed everything; releases what was retired.</summary>
    procedure WaitIdle;
    /// <summary>Releases retired objects and recycles pages, command pools and descriptor pools the GPU is done with.
    /// </summary>
    procedure Collect;
    /// <summary>Destroys AHandle once the GPU has executed everything recorded so far (VK_NULL_HANDLE: nothing).
    /// </summary>
    procedure Retire(const AKind: TGpuVkObject; const AHandle: UInt64);
    /// <summary>Records a layout change of an image (issued by FlushBarriers, before the next command). ADiscard:
    /// the content is not kept (the next command replaces all of it).</summary>
    procedure Transition(const AImage: TVkImage; var AUse: TGpuVkUse; const ANew: TGpuVkUse;
      const ADiscard: Boolean = False);
    /// <summary>An image barrier as given (swap chain images: the acquire semaphore's stage).</summary>
    procedure ImageBarrier(const AImage: TVkImage; const ASrcStage, ASrcAccess, ADstStage, ADstAccess: UInt64;
      const AOld, ANew: TVkImageLayout);
    /// <summary>Records a change of use of a buffer (a global memory barrier).</summary>
    procedure BufferUse(var AUse: TGpuVkUse; const ANew: TGpuVkUse);
    procedure MemoryBarrier(const ASrcStage, ASrcAccess, ADstStage, ADstAccess: UInt64);
    procedure FlushBarriers;
    /// <summary>ASize bytes of upload memory for the open command buffer: the CPU address; ABuffer and AOffset for
    /// the GPU.</summary>
    function Upload(const ASize: NativeInt; const AAlign: Integer; out ABuffer: TVkBuffer; out AOffset: UInt64): PByte;
    /// <summary>Copies rows of pixels into an image (records the copy; the image is left in TransferDst).</summary>
    procedure CopyToImage(const AImage: TVkImage; var AUse: TGpuVkUse; const ABytesPerPixel, X, Y, W, H: Integer;
      const AData: Pointer; const APitch: Integer);
    procedure CopyToBuffer(const ABuffer: TVkBuffer; var AUse: TGpuVkUse; const AOffset: UInt64; const AData: Pointer;
      const ASize: NativeInt);
    /// <summary>Fills a whole image with one color (the image is left in TransferDst).</summary>
    procedure ClearImage(const AImage: TVkImage; var AUse: TGpuVkUse; const AColor: TVkClearColorValue);
    /// <summary>A device-local image with a view of all of it (of AAspect).</summary>
    function NewImage(const AFormat: TVkFormat; const AWidth, AHeight: Integer; const AUsage: TVkImageUsageFlags;
      out AMemory: TFastVkAllocation; out AView: TVkImageView; const AMips: Integer = 1; const ASamples: Integer = 1;
      const AAspect: TVkImageAspectFlags = Ord(VK_IMAGE_ASPECT_COLOR_BIT)): TVkImage;
    /// <summary>A buffer and its memory (ARequired, APreferred: see TFastVulkan.MemoryType; host-visible memory is mapped:
    /// AMemory.Cpu).</summary>
    function NewBuffer(const ASize: UInt64; const AUsage: TVkBufferUsageFlags; const ARequired,
      APreferred: TVkMemoryPropertyFlags; out AMemory: TFastVkAllocation): TVkBuffer;
    /// <summary>A descriptor set of ALayout for the open command buffer.</summary>
    function AllocSet(const ALayout: TVkDescriptorSetLayout): TVkDescriptorSet;
    /// <summary>Rendering into ATarget (begun if it is not the current one, after the barriers so far); AClear: the
    /// whole target is filled with that color first.</summary>
    procedure BeginRendering(const ATarget: TGpuVkSurface; const AClear: PVkClearColorValue = nil);
    procedure EndRendering;
    property Fast: TFastVulkan read FFast;
    property Vk: TVulkan read FVk;
    property Device: TVkDevice read FDevice;
    property Queue: TVkQueue read FQueue;
    /// <summary>Changes whenever a new command buffer is opened (its state is empty).</summary>
    property ListGen: Integer read FListGen;
    /// <summary>Alignment of uniform buffer offsets.</summary>
    property UniformAlign: Integer read FUniformAlign;
    /// <summary>Who bound its pipeline and state on the open command buffer last (the canvas renderer, a 3D
    /// context): the other one binds its own again before it draws.</summary>
    property Owner: TObject read FOwner write FOwner;
  end;

  TGpuVkSurface = class(TGpuSurface)
  private
    FImage: TVkImage;
    FMemory: TFastVkAllocation;
    FView: TVkImageView;
    FUse: TGpuVkUse;
    FReadback: TVkBuffer;
    FReadbackMemory: TFastVkAllocation;
    FReadbackData: PByte;
    /// <summary>The read-back copy holds the current content (no GPU write since it was taken).</summary>
    FReadbackValid: Boolean;
    /// <summary>Destroys the Vulkan objects at once: the context shuts down (the GPU is idle) while the surface
    /// lives on (a bitmap freed after the canvas).</summary>
    procedure Drop(const AContext: TGpuVkContext);
  public
    constructor Create(const AWidth, AHeight: Integer; const AData: Pointer; const APitch: Integer);
    destructor Destroy; override;
    /// <summary>Records the change to AUse (device lock held).</summary>
    procedure Use(const AUse: TGpuVkUse);
    procedure Upload(const AData: Pointer; const APitch: Integer); override;
    function Map(out AData: Pointer; out APitch: Integer): Boolean; override;
    procedure Unmap(const AWritten: Boolean); override;
    procedure CopyFrom(const ASource: TGpuSurface); override;
    procedure GpuWritten; override;
    property Image: TVkImage read FImage;
    property View: TVkImageView read FView;
  end;

  TGpuVkPresenter = class;

  TGpuVkWindow = class(TGpuWindow)
  private
    /// <summary>The surface frames are drawn into; Present copies it into FShown. Whether it holds a frame.
    /// </summary>
    FSurface: TGpuVkSurface;
    FDrawn: Boolean;
    FVkSurface: TVkSurfaceKHR;
    /// <summary>The present modes the window's surface offers.</summary>
    FModes: TArray<TVkPresentModeKHR>;
    /// <summary>The thread that presents, and the copy of the newest frame it presents from (resting in
    /// TRANSFER_SRC_OPTIMAL).</summary>
    FPresenter: TGpuVkPresenter;
    FShown: TGpuVkSurface;
    /// <summary>The canvas asked for presenting without vertical sync.</summary>
    FTearingAsked: Boolean;
    /// <summary>The tearing changed: the presenter makes its swap chain again.</summary>
    FStale: Boolean;
    /// <summary>The timeline values of the last frames: the GPU is at most FramesInFlight frames behind (what DXGI's
    /// frame latency does for Direct3D 12).</summary>
    FFrameValues: array[0..FramesInFlight - 1] of UInt64;
    FFrameIndex: Cardinal;
    /// <summary>The window's Vulkan surface and the present modes it offers.</summary>
    procedure CreateVkSurface;
    function HasMode(const AMode: TVkPresentModeKHR): Boolean;
    procedure StopPresenter;
    /// <summary>Destroys the Vulkan objects at once (the context shuts down).</summary>
    procedure Drop(const AContext: TGpuVkContext);
  public
    constructor Create(const AWnd: HWND; const ALayered: Boolean); override;
    destructor Destroy; override;
    function Prepare(const AWidth, AHeight: Integer; const ATearing: Boolean; const AOutput: TGpuOutput): TGpuSurface;
      override;
    function Present: HResult; override;
    procedure ReadPixels(const ABits: Pointer; const AWidth, AHeight: Integer); override;
    function RestoreLast: Boolean; override;
    function Capture(out ACapture: TGpuCapture): Boolean; override;
  end;
  /// <summary>Presents the frames of a window, so that the render thread does not wait for the display or the
  /// driver's acquire and present: the render thread copies a finished frame into the window's FShown and wakes this
  /// thread, which acquires a swap chain image (where FIFO waits for the refresh), copies the newest frame into it and
  /// presents it; frames that come faster than it takes them are skipped. Its own swap chain, command buffers
  /// (recorded once per image and frame size) and timeline semaphore; it takes the queue lock to submit and present,
  /// never the device lock.</summary>
  TGpuVkPresenter = class(TThread)
  private
    FWindow: TGpuVkWindow;
    FFast: TFastVulkan;
    FVk: TVulkan;
    FDevice: TVkDevice;
    FWake: TEvent;
    /// <summary>Guards the hand-over: FShown (the window's), FShownGen, FPending, FStaleAsked.</summary>
    FLock: TRTLCriticalSection;
    FShownGen: Integer;
    FPending, FStaleAsked: Boolean;
    // This thread (and Release once it has ended).
    FSwapchain: TVkSwapchainKHR;
    FFormat: TVkSurfaceFormatKHR;
    FExtent: TVkExtent2D;
    FImages: TArray<TVkImage>;
    FPresentSems: TArray<TVkSemaphore>;
    /// <summary>Signaled when the acquired image is free: waited for on this thread, so that the copy into it does
    /// not wait on the queue (a semaphore waited for there held everything after it until the refresh).</summary>
    FAcquired: TVkFence;
    FPool: TVkCommandPool;
    FCmds: TArray<TVkCommandBuffer>;
    /// <summary>Per image: the FShownGen its command buffer was recorded for (-1: none), and the timeline value of
    /// its last submission.</summary>
    FCmdGens: TArray<Integer>;
    FCmdValues: TArray<UInt64>;
    FTimeline: TVkSemaphore;
    FValue: UInt64;
    FStale: Boolean;
    FCheckedW, FCheckedH: Integer;
    function Ok(const ARes: TVkResult): Boolean;
    procedure WaitValue(const AValue: UInt64);
    procedure ReleaseChain(const ADestroyOld: Boolean);
    function CreateChain(const AWidth, AHeight: Integer): Boolean;
    procedure Record_(const AIndex: Integer; const AShown: TGpuVkSurface);
    /// <summary>Presents the pending frame; False when there was none or it could not be presented.</summary>
    function PresentPending: Boolean;
    procedure Release;
  protected
    procedure Execute; override;
  public
    constructor Create(const AWindow: TGpuVkWindow);
    destructor Destroy; override;
    /// <summary>Render thread: FShown holds a new frame (submitted).</summary>
    procedure Post;
    /// <summary>The thread ends; its Vulkan objects go (the GPU is waited for).</summary>
    procedure Stop;
  end;

  /// <summary>A texture of the renderer (atlas, ramps, the empty slot texture).</summary>
  TGpuVkImage = record
    Image: TVkImage;
    Memory: TFastVkAllocation;
    View: TVkImageView;
    Use: TGpuVkUse;
  end;

  /// <summary>A table of the renderer: a buffer read as a uniform texel buffer of float4.</summary>
  TGpuVkTable = record
    Buffer: TVkBuffer;
    Memory: TFastVkAllocation;
    View: TVkBufferView;
    Use: TGpuVkUse;
  end;

  TGpuVkRenderer = class(TGpuRenderer)
  private
    FSamplers: array[0..2] of TVkSampler;
    FSetLayout: TVkDescriptorSetLayout;
    FLayout: TVkPipelineLayout;
    FVS, FPS, FPSDual: TVkShaderModule;
    FPipeBlend, FPipeCopy: TVkPipeline;
    /// <summary>Dual-source blending (ClearType text), made on first use; none without the feature.</summary>
    FPipeDual: TVkPipeline;
    FAtlas, FRamps, FEmpty: TGpuVkImage;
    FClips, FPaints, FEdges: TGpuVkTable;
    FCopy: Boolean;
    // What is bound on the open command buffer (ListGen).
    FBoundGen: Integer;
    FBoundPipe: TVkPipeline;
    FBoundW, FBoundH: Integer;
    // The frame constants in the upload memory of the open command buffer.
    FConstGen: Integer;
    FConstBuffer: TVkBuffer;
    FConstOffset: UInt64;
    // The descriptor set of the last draw (for the open command buffer) and what it holds.
    FSet: TVkDescriptorSet;
    FSetGen: Integer;
    FSetViews: array[0..GpuSlotCount - 1] of TVkImageView;
    FSetEdges: TVkBufferView;
    FSetConstBuffer: TVkBuffer;
    FSetConst: UInt64;
    procedure CreatePipeline;
    function NewModule(const ACode: Pointer; const AWords: Integer): TVkShaderModule;
    function NewPipeline(const AFormat: TVkFormat; const ABlend, ADual: Boolean): TVkPipeline;
    function TargetPipeline: TVkPipeline;
    function NewTexture(const AFormat: TVkFormat; const AWidth, AHeight: Integer): TGpuVkImage;
    function NewTable(const AFloat4s: Integer): TGpuVkTable;
    procedure ReleaseTable(var ATable: TGpuVkTable);
    procedure ReleaseTexture(var AImage: TGpuVkImage);
    procedure UploadTables;
    function DescriptorSet: TVkDescriptorSet;
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

  TGpuVkBackend = class(TGpuBackend)
  public
    class function CreateRenderer: TGpuRenderer; override;
    class function CreateSurface(const AWidth, AHeight: Integer; const AData: Pointer;
      const APitch: Integer): TGpuSurface; override;
    class function CreateWindow(const AWnd: HWND; const ALayered: Boolean): TGpuWindow; override;
    class procedure Submit; override;
    class procedure WaitIdle; override;
    class procedure Shutdown; override;
  end;

/// <summary>The recording context of the Vulkan device (made on first use); with the device lock held.</summary>
function GpuVk: TGpuVkContext;
/// <summary>The recording context, nil when there is none (not made here).</summary>
function GpuVkCurrent: TGpuVkContext;
/// <summary>The handle TGpuVkContext.Retire and DestroyObject take for memory (TGpuVkObject.Memory).</summary>
function MemoryHandle(const AMemory: TFastVkAllocation): UInt64; inline;

implementation

uses
  Winapi.DxgiType;

{$I FastCanvas.VkShaders.inc}

const
  InList = High(UInt64);
  // Upload memory is system memory: small pages, so that only what the frames in flight use stays allocated (as
  // FastCanvas.Gpu12).
  MaxFreePages = 8;
  FreePageLife = 120;
  PageSize = 2 * 1024 * 1024;

  SwapImages = 3;
  SetsPerPool = 256;
  MaxFreePools = 4;
  /// <summary>Waits on the timeline are cut into slices of this many nanoseconds (to notice a lost device).</summary>
  WaitSlice = 2000000000;

  // Stages and accesses of synchronization2 (64-bit masks; the header's enumerations hold only their low 32 bits).
  StageNone = UInt64(0);
  StageFragmentShader = UInt64($80);
  StageColorOutput = UInt64($400);
  StageTransfer = UInt64($1000);
  StageHost = UInt64($4000);
  StageAllCommands = UInt64($10000);
  AccessShaderRead = UInt64($20);
  AccessColorRead = UInt64($80);
  AccessColorWrite = UInt64($100);
  AccessTransferRead = UInt64($800);
  AccessTransferWrite = UInt64($1000);
  AccessHostRead = UInt64($2000);

  UseLayout: array[TGpuVkUse] of TVkImageLayout = (VK_IMAGE_LAYOUT_UNDEFINED,
    VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
    VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL);
  UseStage: array[TGpuVkUse] of UInt64 = (StageNone, StageFragmentShader, StageColorOutput, StageTransfer,
    StageTransfer);
  UseAccess: array[TGpuVkUse] of UInt64 = (0, AccessShaderRead, AccessColorRead or AccessColorWrite,
    AccessTransferRead, AccessTransferWrite);
  /// <summary>The writes of a use, which a barrier makes available.</summary>
  UseWrites: array[TGpuVkUse] of UInt64 = (0, 0, AccessColorWrite, 0, AccessTransferWrite);

var
  GCtx: TGpuVkContext;

function GpuVk: TGpuVkContext;
begin
  if GCtx = nil then
  begin
    TFastDevice.Lock;
    try
      if GCtx = nil then
        GCtx := TGpuVkContext.Create;
    finally
      TFastDevice.Unlock;
    end;
  end;
  Result := GCtx;
end;

function GpuVkCurrent: TGpuVkContext;
begin
  Result := GCtx;
end;

function AlignUp(const AValue: NativeInt; const AAlign: Integer): NativeInt; inline;
begin
  Result := (AValue + AAlign - 1) and not NativeInt(AAlign - 1);
end;

function MemoryHandle(const AMemory: TFastVkAllocation): UInt64;
begin
  Result := UInt64(NativeUInt(Pointer(AMemory)));
end;

function ColorRange: TVkImageSubresourceRange;
begin
  Result.aspectMask := Ord(VK_IMAGE_ASPECT_COLOR_BIT);
  Result.baseMipLevel := 0;
  Result.levelCount := 1;
  Result.baseArrayLayer := 0;
  Result.layerCount := 1;
end;

function ColorLayers: TVkImageSubresourceLayers;
begin
  Result.aspectMask := Ord(VK_IMAGE_ASPECT_COLOR_BIT);
  Result.mipLevel := 0;
  Result.baseArrayLayer := 0;
  Result.layerCount := 1;
end;

{ TGpuVkContext }

constructor TGpuVkContext.Create;
var
  TypeInfo: TVkSemaphoreTypeCreateInfo;
  Info: TVkSemaphoreCreateInfo;
begin
  inherited Create;
  FFast := TFastDevice.Vulkan;
  if FFast = nil then
    raise EFastDevice.Create('FastCanvas: no Vulkan device');
  FVk := FFast.Vk;
  FDevice := FFast.Device;
  FQueue := FFast.Queue;
  FUniformAlign := Max(16, Integer(FFast.Properties.limits.minUniformBufferOffsetAlignment));
  FCommands := TQueue<TGpuVkCommands>.Create;
  FBusyPages := TList<TGpuVkPage>.Create;
  FFreePages := TList<TGpuVkPage>.Create;
  FRetired := TList<TGpuVkRetired>.Create;
  FBusyPools := TList<TGpuVkPool>.Create;
  FFreePools := TList<TVkDescriptorPool>.Create;
  FSurfaces := TList<TGpuVkSurface>.Create;
  FWindows := TList<TGpuVkWindow>.Create;
  SetLength(FBarriers, 16);
  FillChar(TypeInfo, SizeOf(TypeInfo), 0);
  TypeInfo.sType := VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO;
  TypeInfo.semaphoreType := VK_SEMAPHORE_TYPE_TIMELINE;
  TypeInfo.initialValue := 0;
  FillChar(Info, SizeOf(Info), 0);
  Info.sType := VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
  Info.pNext := @TypeInfo;
  Check(FVk.CreateSemaphore(FDevice, @Info, nil, @FTimeline), 'vkCreateSemaphore (timeline)');
end;

destructor TGpuVkContext.Destroy;
var
  P: TGpuVkPage;
  R: TGpuVkRetired;
  Pool: TGpuVkPool;
  D: TVkDescriptorPool;
  W: TGpuVkWindow;
  S: TGpuVkSurface;
begin
  WaitIdle;
  // Presentation too: swap chains and their semaphores go now.
  FFast.LockQueue;
  try
    FVk.QueueWaitIdle(FQueue);
  finally
    FFast.UnlockQueue;
  end;
  // Windows and surfaces still alive (bitmaps freed after the canvas shut down) lose their Vulkan objects now.
  for W in FWindows.ToArray do
    W.Drop(Self);
  for S in FSurfaces.ToArray do
    S.Drop(Self);
  for R in FRetired do
    DestroyObject(R.Kind, R.Handle);
  FRetired.Clear;
  if FPage <> nil then
    FBusyPages.Add(FPage);
  FPage := nil;
  for P in FBusyPages do
    FreePage(P);
  for P in FFreePages do
    FreePage(P);
  if FPool.Pool <> VK_NULL_HANDLE then
    FBusyPools.Add(FPool);
  for Pool in FBusyPools do
    FVk.DestroyDescriptorPool(FDevice, Pool.Pool, nil);
  for D in FFreePools do
    FVk.DestroyDescriptorPool(FDevice, D, nil);
  if FCmd.Pool <> VK_NULL_HANDLE then
    FCommands.Enqueue(FCmd);
  while FCommands.Count > 0 do
    FVk.DestroyCommandPool(FDevice, FCommands.Dequeue.Pool, nil);
  if FTimeline <> VK_NULL_HANDLE then
    FVk.DestroySemaphore(FDevice, FTimeline, nil);
  FCommands.Free;
  FBusyPages.Free;
  FFreePages.Free;
  FRetired.Free;
  FBusyPools.Free;
  FFreePools.Free;
  FSurfaces.Free;
  FWindows.Free;
  inherited;
end;

procedure TGpuVkContext.Check(const ARes: TVkResult; const AWhat: string);
begin
  if Ord(FFast.Track(ARes)) < 0 then
    raise EFastDevice.CreateFmt('FastCanvas: %s failed (%d)', [AWhat, Ord(ARes)]);
end;

function TGpuVkContext.Completed: UInt64;
begin
  // A lost device never completes: everything counts as done.
  if Ord(FFast.Track(FVk.GetSemaphoreCounterValue(FDevice, FTimeline, @Result))) < 0 then
    Result := FSignaled;
end;

procedure TGpuVkContext.DestroyObject(const AKind: TGpuVkObject; const AHandle: UInt64);
begin
  if AHandle = VK_NULL_HANDLE then
    Exit;
  case AKind of
    TGpuVkObject.Image: FVk.DestroyImage(FDevice, AHandle, nil);
    TGpuVkObject.ImageView: FVk.DestroyImageView(FDevice, AHandle, nil);
    TGpuVkObject.Memory: FFast.Release(TFastVkAllocation(NativeUInt(AHandle)));
    TGpuVkObject.Buffer: FVk.DestroyBuffer(FDevice, AHandle, nil);
    TGpuVkObject.BufferView: FVk.DestroyBufferView(FDevice, AHandle, nil);
    TGpuVkObject.Pipeline: FVk.DestroyPipeline(FDevice, AHandle, nil);
    TGpuVkObject.PipelineLayout: FVk.DestroyPipelineLayout(FDevice, AHandle, nil);
    TGpuVkObject.SetLayout: FVk.DestroyDescriptorSetLayout(FDevice, AHandle, nil);
    TGpuVkObject.Sampler: FVk.DestroySampler(FDevice, AHandle, nil);
    TGpuVkObject.ShaderModule: FVk.DestroyShaderModule(FDevice, AHandle, nil);
    TGpuVkObject.Semaphore: FVk.DestroySemaphore(FDevice, AHandle, nil);
  end;
end;

procedure TGpuVkContext.Open;
var
  PoolInfo: TVkCommandPoolCreateInfo;
  AllocInfo: TVkCommandBufferAllocateInfo;
  Begin_: TVkCommandBufferBeginInfo;
begin
  Collect;
  if (FCommands.Count > 0) and (FCommands.Peek.Value <= Completed) then
  begin
    FCmd := FCommands.Dequeue;
    Check(FVk.ResetCommandPool(FDevice, FCmd.Pool, 0), 'vkResetCommandPool');
  end
  else
  begin
    FCmd := Default(TGpuVkCommands);
    FillChar(PoolInfo, SizeOf(PoolInfo), 0);
    PoolInfo.sType := VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    PoolInfo.flags := Ord(VK_COMMAND_POOL_CREATE_TRANSIENT_BIT);
    PoolInfo.queueFamilyIndex := FFast.QueueFamily;
    Check(FVk.CreateCommandPool(FDevice, @PoolInfo, nil, @FCmd.Pool), 'vkCreateCommandPool');
    FillChar(AllocInfo, SizeOf(AllocInfo), 0);
    AllocInfo.sType := VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    AllocInfo.commandPool := FCmd.Pool;
    AllocInfo.level := VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    AllocInfo.commandBufferCount := 1;
    Check(FVk.AllocateCommandBuffers(FDevice, @AllocInfo, @FCmd.Buffer), 'vkAllocateCommandBuffers');
  end;
  FillChar(Begin_, SizeOf(Begin_), 0);
  Begin_.sType := VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
  Begin_.flags := Ord(VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT);
  Check(FVk.BeginCommandBuffer(FCmd.Buffer, @Begin_), 'vkBeginCommandBuffer');
  FOpen := True;
  Inc(FListGen);
  // The current page and descriptor pool go on in this command buffer.
  if FPage <> nil then
    FPage.Value := InList;
  if FPool.Pool <> VK_NULL_HANDLE then
    FPool.Value := InList;
end;

function TGpuVkContext.Cmd: TVkCommandBuffer;
begin
  if not FOpen then
    Open;
  Result := FCmd.Buffer;
end;

function TGpuVkContext.TransferCmd: TVkCommandBuffer;
begin
  EndRendering;
  FlushBarriers;
  Result := Cmd;
end;

function TGpuVkContext.Submit(const AWait: TVkSemaphore; const AWaitStage: UInt64;
  const ASignal: TVkSemaphore): UInt64;
var
  Info: TVkSubmitInfo2;
  CmdInfo: TVkCommandBufferSubmitInfo;
  Wait: TVkSemaphoreSubmitInfo;
  Signals: array[0..1] of TVkSemaphoreSubmitInfo;
  Opened: Boolean;
  I: Integer;
  P: TGpuVkPage;
  R: TGpuVkRetired;
  Pool: TGpuVkPool;
  Res: TVkResult;
begin
  EndRendering;
  if (FBarrierCount > 0) or (FMemDstStage <> 0) or (FMemSrcStage <> 0) then
    FlushBarriers;
  Opened := FOpen;
  if not Opened and (AWait = VK_NULL_HANDLE) and (ASignal = VK_NULL_HANDLE) then
    Exit(0);
  if Opened then
  begin
    FOpen := False;
    Check(FVk.EndCommandBuffer(FCmd.Buffer), 'vkEndCommandBuffer');
  end;
  Inc(FSignaled);
  FillChar(Info, SizeOf(Info), 0);
  Info.sType := VK_STRUCTURE_TYPE_SUBMIT_INFO_2;
  if Opened then
  begin
    FillChar(CmdInfo, SizeOf(CmdInfo), 0);
    CmdInfo.sType := VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO;
    CmdInfo.commandBuffer := FCmd.Buffer;
    Info.commandBufferInfoCount := 1;
    Info.pCommandBufferInfos := @CmdInfo;
  end;
  if AWait <> VK_NULL_HANDLE then
  begin
    FillChar(Wait, SizeOf(Wait), 0);
    Wait.sType := VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO;
    Wait.semaphore := AWait;
    Wait.stageMask := AWaitStage;
    Info.waitSemaphoreInfoCount := 1;
    Info.pWaitSemaphoreInfos := @Wait;
  end;
  FillChar(Signals, SizeOf(Signals), 0);
  Signals[0].sType := VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO;
  Signals[0].semaphore := FTimeline;
  Signals[0].value := FSignaled;
  Signals[0].stageMask := StageAllCommands;
  Info.signalSemaphoreInfoCount := 1;
  if ASignal <> VK_NULL_HANDLE then
  begin
    Signals[1].sType := VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO;
    Signals[1].semaphore := ASignal;
    Signals[1].stageMask := StageAllCommands;
    Info.signalSemaphoreInfoCount := 2;
  end;
  Info.pSignalSemaphoreInfos := @Signals[0];
  FFast.LockQueue;
  try
    Res := FVk.QueueSubmit2(FQueue, 1, @Info, VK_NULL_HANDLE);
  finally
    FFast.UnlockQueue;
  end;
  // The work of a refused submission is gone (and the timeline never reaches its value): the device is made again.
  if Ord(Res) < 0 then
    FFast.Track(VK_ERROR_DEVICE_LOST);
  Result := FSignaled;
  if Opened then
  begin
    FCmd.Value := FSignaled;
    FCommands.Enqueue(FCmd);
    FCmd := Default(TGpuVkCommands);
    if FPage <> nil then
      FPage.Value := FSignaled;
    for P in FBusyPages do
      if P.Value = InList then
        P.Value := FSignaled;
    if FPool.Value = InList then
      FPool.Value := FSignaled;
    for I := 0 to FBusyPools.Count - 1 do
      if FBusyPools[I].Value = InList then
      begin
        Pool := FBusyPools[I];
        Pool.Value := FSignaled;
        FBusyPools[I] := Pool;
      end;
    for I := 0 to FRetired.Count - 1 do
      if FRetired[I].Value = InList then
      begin
        R := FRetired[I];
        R.Value := FSignaled;
        FRetired[I] := R;
      end;
  end;
  if Ord(Res) < 0 then
    raise EFastDevice.CreateFmt('FastCanvas: vkQueueSubmit2 failed (%d)', [Ord(Res)]);
end;

procedure TGpuVkContext.WaitFor(const AValue: UInt64);
var
  Info: TVkSemaphoreWaitInfo;
  Value: UInt64;
  Res: TVkResult;
begin
  if (AValue = 0) or (AValue > FSignaled) or (Completed >= AValue) then
    Exit;
  Value := AValue;
  FillChar(Info, SizeOf(Info), 0);
  Info.sType := VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO;
  Info.semaphoreCount := 1;
  Info.pSemaphores := @FTimeline;
  Info.pValues := @Value;
  repeat
    Res := FFast.Track(FVk.WaitSemaphores(FDevice, @Info, WaitSlice));
  until (Res <> VK_TIMEOUT) or FFast.Lost;
end;

procedure TGpuVkContext.WaitIdle;
begin
  Submit;
  WaitFor(FSignaled);
  Collect;
end;

procedure TGpuVkContext.FreePage(const APage: TGpuVkPage);
begin
  if APage.Buffer <> VK_NULL_HANDLE then
    FVk.DestroyBuffer(FDevice, APage.Buffer, nil);
  FFast.Release(APage.Memory);
  APage.Free;
end;

procedure TGpuVkContext.Collect;
var
  Done: UInt64;
  I: Integer;
  P: TGpuVkPage;
begin
  Done := Completed;
  I := 0;
  while I < FRetired.Count do
    if FRetired[I].Value <= Done then
    begin
      DestroyObject(FRetired[I].Kind, FRetired[I].Handle);
      FRetired.Delete(I);
    end
    else
      Inc(I);
  I := 0;
  while I < FBusyPages.Count do
  begin
    P := FBusyPages[I];
    if P.Value <= Done then
    begin
      FBusyPages.Delete(I);
      if FFreePages.Count < MaxFreePages then
      begin
        P.Used := 0;
        P.FreeSince := FSignaled;
        FFreePages.Add(P);
      end
      else
        FreePage(P);
    end
    else
      Inc(I);
  end;
  I := 0;
  while I < FFreePages.Count do
    if FSignaled - FFreePages[I].FreeSince > FreePageLife then
    begin
      FreePage(FFreePages[I]);
      FFreePages.Delete(I);
    end
    else
      Inc(I);
  I := 0;
  while I < FBusyPools.Count do
    if FBusyPools[I].Value <= Done then
    begin
      if FFreePools.Count < MaxFreePools then
      begin
        FVk.ResetDescriptorPool(FDevice, FBusyPools[I].Pool, 0);
        FFreePools.Add(FBusyPools[I].Pool);
      end
      else
        FVk.DestroyDescriptorPool(FDevice, FBusyPools[I].Pool, nil);
      FBusyPools.Delete(I);
    end
    else
      Inc(I);
end;

procedure TGpuVkContext.Retire(const AKind: TGpuVkObject; const AHandle: UInt64);
var
  R: TGpuVkRetired;
begin
  if AHandle = VK_NULL_HANDLE then
    Exit;
  R.Kind := AKind;
  R.Handle := AHandle;
  if FOpen then
    R.Value := InList
  else
    R.Value := FSignaled;
  FRetired.Add(R);
end;

procedure TGpuVkContext.ImageBarrier(const AImage: TVkImage; const ASrcStage, ASrcAccess, ADstStage,
  ADstAccess: UInt64; const AOld, ANew: TVkImageLayout);
var
  B: PVkImageMemoryBarrier2;
begin
  if FBarrierCount = Length(FBarriers) then
    SetLength(FBarriers, 2 * FBarrierCount);
  B := @FBarriers[FBarrierCount];
  FillChar(B^, SizeOf(B^), 0);
  B.sType := VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2;
  B.srcStageMask := ASrcStage;
  B.srcAccessMask := ASrcAccess;
  B.dstStageMask := ADstStage;
  B.dstAccessMask := ADstAccess;
  B.oldLayout := AOld;
  B.newLayout := ANew;
  B.srcQueueFamilyIndex := VK_QUEUE_FAMILY_IGNORED;
  B.dstQueueFamilyIndex := VK_QUEUE_FAMILY_IGNORED;
  B.image := AImage;
  B.subresourceRange := ColorRange;
  Inc(FBarrierCount);
end;

procedure TGpuVkContext.Transition(const AImage: TVkImage; var AUse: TGpuVkUse; const ANew: TGpuVkUse;
  const ADiscard: Boolean);
var
  I: Integer;
  Old: TVkImageLayout;
begin
  if (AUse = ANew) or (AImage = VK_NULL_HANDLE) then
    Exit;
  // A change of the same image waiting in the batch becomes one barrier (or none).
  for I := FBarrierCount - 1 downto 0 do
    if FBarriers[I].image = AImage then
    begin
      AUse := ANew;
      if ADiscard then
        FBarriers[I].oldLayout := VK_IMAGE_LAYOUT_UNDEFINED;
      if FBarriers[I].oldLayout = UseLayout[ANew] then
      begin
        Dec(FBarrierCount);
        if I < FBarrierCount then
          FBarriers[I] := FBarriers[FBarrierCount];
      end
      else
      begin
        FBarriers[I].newLayout := UseLayout[ANew];
        FBarriers[I].dstStageMask := UseStage[ANew];
        FBarriers[I].dstAccessMask := UseAccess[ANew];
      end;
      Exit;
    end;
  // A discarded content still waits for its last use (a clear after reads).
  Old := UseLayout[AUse];
  if ADiscard then
    Old := VK_IMAGE_LAYOUT_UNDEFINED;
  ImageBarrier(AImage, UseStage[AUse], UseWrites[AUse], UseStage[ANew], UseAccess[ANew], Old, UseLayout[ANew]);
  AUse := ANew;
end;

procedure TGpuVkContext.MemoryBarrier(const ASrcStage, ASrcAccess, ADstStage, ADstAccess: UInt64);
begin
  FMemSrcStage := FMemSrcStage or ASrcStage;
  FMemSrcAccess := FMemSrcAccess or ASrcAccess;
  FMemDstStage := FMemDstStage or ADstStage;
  FMemDstAccess := FMemDstAccess or ADstAccess;
end;

procedure TGpuVkContext.BufferUse(var AUse: TGpuVkUse; const ANew: TGpuVkUse);
begin
  if AUse = ANew then
  begin
    // Another copy into the buffer: after the ones before (their ranges may overlap: a fill, then a range).
    if ANew = TGpuVkUse.TransferDst then
      MemoryBarrier(StageTransfer, AccessTransferWrite, StageTransfer, AccessTransferWrite);
    Exit;
  end;
  MemoryBarrier(UseStage[AUse], UseWrites[AUse], UseStage[ANew], UseAccess[ANew]);
  AUse := ANew;
end;

procedure TGpuVkContext.FlushBarriers;
var
  Dep: TVkDependencyInfo;
  Mem: TVkMemoryBarrier2;
  C: TVkCommandBuffer;
begin
  if (FBarrierCount = 0) and (FMemSrcStage = 0) and (FMemDstStage = 0) then
    Exit;
  // Barriers inside rendering are for the attachments' own feedback only.
  EndRendering;
  C := Cmd;
  FillChar(Dep, SizeOf(Dep), 0);
  Dep.sType := VK_STRUCTURE_TYPE_DEPENDENCY_INFO;
  if (FMemSrcStage <> 0) or (FMemDstStage <> 0) then
  begin
    FillChar(Mem, SizeOf(Mem), 0);
    Mem.sType := VK_STRUCTURE_TYPE_MEMORY_BARRIER_2;
    Mem.srcStageMask := FMemSrcStage;
    Mem.srcAccessMask := FMemSrcAccess;
    Mem.dstStageMask := FMemDstStage;
    Mem.dstAccessMask := FMemDstAccess;
    Dep.memoryBarrierCount := 1;
    Dep.pMemoryBarriers := @Mem;
  end;
  if FBarrierCount > 0 then
  begin
    Dep.imageMemoryBarrierCount := FBarrierCount;
    Dep.pImageMemoryBarriers := @FBarriers[0];
  end;
  FVk.CmdPipelineBarrier2(C, @Dep);
  FBarrierCount := 0;
  FMemSrcStage := 0;
  FMemSrcAccess := 0;
  FMemDstStage := 0;
  FMemDstAccess := 0;
end;

function TGpuVkContext.TakePage(const ASize: NativeInt): TGpuVkPage;
var
  I, Best: Integer;
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
  Result := TGpuVkPage.Create;
  try
    Result.Size := Max(PageSize, AlignUp(ASize, 64 * 1024));
    Result.Buffer := NewBuffer(Result.Size, Ord(VK_BUFFER_USAGE_TRANSFER_SRC_BIT) or
      Ord(VK_BUFFER_USAGE_VERTEX_BUFFER_BIT) or Ord(VK_BUFFER_USAGE_INDEX_BUFFER_BIT) or
      Ord(VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT), Ord(VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) or
      Ord(VK_MEMORY_PROPERTY_HOST_COHERENT_BIT), 0, Result.Memory);
    Result.Cpu := Result.Memory.Cpu;
  except
    FreePage(Result);
    raise;
  end;
end;

function TGpuVkContext.Upload(const ASize: NativeInt; const AAlign: Integer; out ABuffer: TVkBuffer;
  out AOffset: UInt64): PByte;
var
  Pos: NativeInt;
  P: TGpuVkPage;
begin
  // The page is used by the open command buffer.
  Cmd;
  if FPage <> nil then
    Pos := AlignUp(FPage.Used, AAlign)
  else
    Pos := 0;
  if (FPage <> nil) and (Pos + ASize > FPage.Size) and (ASize > PageSize div 2) then
  begin
    // A large upload (the instances of a big frame) gets a page of its own; the current page stays open for the
    // small ones.
    P := TakePage(ASize);
    P.Value := InList;
    P.Used := ASize;
    FBusyPages.Add(P);
    ABuffer := P.Buffer;
    AOffset := 0;
    Exit(P.Cpu);
  end;
  if (FPage = nil) or (Pos + ASize > FPage.Size) then
  begin
    if FPage <> nil then
      FBusyPages.Add(FPage);
    FPage := nil;
    FPage := TakePage(ASize);
    FPage.Value := InList;
    Pos := 0;
  end;
  FPage.Used := Pos + ASize;
  ABuffer := FPage.Buffer;
  AOffset := Pos;
  Result := FPage.Cpu + Pos;
end;

procedure TGpuVkContext.CopyToImage(const AImage: TVkImage; var AUse: TGpuVkUse; const ABytesPerPixel, X, Y, W,
  H: Integer; const AData: Pointer; const APitch: Integer);
var
  Row, I: Integer;
  P: PByte;
  Buf: TVkBuffer;
  Off: UInt64;
  Region: TVkBufferImageCopy;
begin
  if (W <= 0) or (H <= 0) then
    Exit;
  Row := W * ABytesPerPixel;
  P := Upload(NativeInt(Row) * H, 16, Buf, Off);
  if APitch = Row then
    Move(AData^, P^, NativeInt(Row) * H)
  else
    for I := 0 to H - 1 do
      Move((PByte(AData) + NativeInt(I) * APitch)^, (P + NativeInt(I) * Row)^, Row);
  Transition(AImage, AUse, TGpuVkUse.TransferDst);
  FillChar(Region, SizeOf(Region), 0);
  Region.bufferOffset := Off;
  Region.imageSubresource := ColorLayers;
  Region.imageOffset.x := X;
  Region.imageOffset.y := Y;
  Region.imageExtent.width := W;
  Region.imageExtent.height := H;
  Region.imageExtent.depth := 1;
  FVk.CmdCopyBufferToImage(TransferCmd, Buf, AImage, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, @Region);
end;

procedure TGpuVkContext.CopyToBuffer(const ABuffer: TVkBuffer; var AUse: TGpuVkUse; const AOffset: UInt64;
  const AData: Pointer; const ASize: NativeInt);
var
  P: PByte;
  Src: TVkBuffer;
  Region: TVkBufferCopy;
begin
  if ASize <= 0 then
    Exit;
  P := Upload(ASize, 16, Src, Region.srcOffset);
  Move(AData^, P^, ASize);
  BufferUse(AUse, TGpuVkUse.TransferDst);
  Region.dstOffset := AOffset;
  Region.size := ASize;
  FVk.CmdCopyBuffer(TransferCmd, Src, ABuffer, 1, @Region);
end;

procedure TGpuVkContext.ClearImage(const AImage: TVkImage; var AUse: TGpuVkUse; const AColor: TVkClearColorValue);
var
  Range: TVkImageSubresourceRange;
begin
  // Whatever the image held goes.
  Transition(AImage, AUse, TGpuVkUse.TransferDst, True);
  Range := ColorRange;
  FVk.CmdClearColorImage(TransferCmd, AImage, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, @AColor, 1, @Range);
end;

function TGpuVkContext.NewImage(const AFormat: TVkFormat; const AWidth, AHeight: Integer;
  const AUsage: TVkImageUsageFlags; out AMemory: TFastVkAllocation; out AView: TVkImageView; const AMips: Integer;
  const ASamples: Integer; const AAspect: TVkImageAspectFlags): TVkImage;
var
  Info: TVkImageCreateInfo;
  ViewInfo: TVkImageViewCreateInfo;
  Req: TVkMemoryRequirements;
  Res: TVkResult;
begin
  AMemory := nil;
  AView := VK_NULL_HANDLE;
  Result := VK_NULL_HANDLE;
  FillChar(Info, SizeOf(Info), 0);
  Info.sType := VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
  Info.imageType := VK_IMAGE_TYPE_2D;
  Info.format := AFormat;
  Info.extent.width := Max(AWidth, 1);
  Info.extent.height := Max(AHeight, 1);
  Info.extent.depth := 1;
  Info.mipLevels := Max(AMips, 1);
  Info.arrayLayers := 1;
  Info.samples := TVkSampleCountFlagBits(Max(ASamples, 1));
  Info.tiling := VK_IMAGE_TILING_OPTIMAL;
  Info.usage := AUsage;
  Info.sharingMode := VK_SHARING_MODE_EXCLUSIVE;
  Info.initialLayout := VK_IMAGE_LAYOUT_UNDEFINED;
  Res := FFast.Track(FVk.CreateImage(FDevice, @Info, nil, @Result));
  if Res <> VK_SUCCESS then
    raise EFastDevice.CreateFmt('FastCanvas: cannot create a %dx%d image (%d)', [AWidth, AHeight, Ord(Res)]);
  try
    FVk.GetImageMemoryRequirements(FDevice, Result, @Req);
    try
      AMemory := FFast.Allocate(Req, Ord(VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT), 0, False);
    except
      on E: EFastVulkan do
        raise EFastDevice.Create(E.Message);
    end;
    Check(FVk.BindImageMemory(FDevice, Result, AMemory.Memory, AMemory.Offset), 'vkBindImageMemory');
    FillChar(ViewInfo, SizeOf(ViewInfo), 0);
    ViewInfo.sType := VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    ViewInfo.image := Result;
    ViewInfo.viewType := VK_IMAGE_VIEW_TYPE_2D;
    ViewInfo.format := AFormat;
    ViewInfo.components.r := VK_COMPONENT_SWIZZLE_IDENTITY;
    ViewInfo.components.g := VK_COMPONENT_SWIZZLE_IDENTITY;
    ViewInfo.components.b := VK_COMPONENT_SWIZZLE_IDENTITY;
    ViewInfo.components.a := VK_COMPONENT_SWIZZLE_IDENTITY;
    ViewInfo.subresourceRange := ColorRange;
    ViewInfo.subresourceRange.aspectMask := AAspect;
    ViewInfo.subresourceRange.levelCount := Max(AMips, 1);
    Check(FVk.CreateImageView(FDevice, @ViewInfo, nil, @AView), 'vkCreateImageView');
  except
    DestroyObject(TGpuVkObject.ImageView, AView);
    DestroyObject(TGpuVkObject.Image, Result);
    DestroyObject(TGpuVkObject.Memory, MemoryHandle(AMemory));
    AView := VK_NULL_HANDLE;
    AMemory := nil;
    Result := VK_NULL_HANDLE;
    raise;
  end;
end;

function TGpuVkContext.NewBuffer(const ASize: UInt64; const AUsage: TVkBufferUsageFlags; const ARequired,
  APreferred: TVkMemoryPropertyFlags; out AMemory: TFastVkAllocation): TVkBuffer;
var
  Info: TVkBufferCreateInfo;
  Req: TVkMemoryRequirements;
begin
  AMemory := nil;
  Result := VK_NULL_HANDLE;
  FillChar(Info, SizeOf(Info), 0);
  Info.sType := VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
  Info.size := ASize;
  Info.usage := AUsage;
  Info.sharingMode := VK_SHARING_MODE_EXCLUSIVE;
  Check(FVk.CreateBuffer(FDevice, @Info, nil, @Result), 'vkCreateBuffer');
  try
    FVk.GetBufferMemoryRequirements(FDevice, Result, @Req);
    try
      AMemory := FFast.Allocate(Req, ARequired, APreferred, True);
    except
      on E: EFastVulkan do
        raise EFastDevice.Create(E.Message);
    end;
    Check(FVk.BindBufferMemory(FDevice, Result, AMemory.Memory, AMemory.Offset), 'vkBindBufferMemory');
  except
    DestroyObject(TGpuVkObject.Buffer, Result);
    DestroyObject(TGpuVkObject.Memory, MemoryHandle(AMemory));
    AMemory := nil;
    Result := VK_NULL_HANDLE;
    raise;
  end;
end;

procedure TGpuVkContext.NextPool;
const
  Types: array[0..3] of TVkDescriptorType = (VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,
    VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER, VK_DESCRIPTOR_TYPE_SAMPLER);
  // Per set of the canvas layout (a 3D context of a later stage brings its own needs).
  PerSet: array[0..3] of Cardinal = (2, 16, 4, 4);
var
  Sizes: array[0..3] of TVkDescriptorPoolSize;
  Info: TVkDescriptorPoolCreateInfo;
  I: Integer;
begin
  if FPool.Pool <> VK_NULL_HANDLE then
    FBusyPools.Add(FPool);
  FPool := Default(TGpuVkPool);
  Collect;
  if FFreePools.Count > 0 then
  begin
    FPool.Pool := FFreePools.Last;
    FFreePools.Delete(FFreePools.Count - 1);
  end
  else
  begin
    for I := 0 to High(Sizes) do
    begin
      Sizes[I].type_ := Types[I];
      Sizes[I].descriptorCount := PerSet[I] * SetsPerPool;
    end;
    FillChar(Info, SizeOf(Info), 0);
    Info.sType := VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
    Info.maxSets := SetsPerPool;
    Info.poolSizeCount := Length(Sizes);
    Info.pPoolSizes := @Sizes[0];
    Check(FVk.CreateDescriptorPool(FDevice, @Info, nil, @FPool.Pool), 'vkCreateDescriptorPool');
  end;
  FPool.Value := InList;
  FPoolSets := 0;
end;

function TGpuVkContext.AllocSet(const ALayout: TVkDescriptorSetLayout): TVkDescriptorSet;
var
  Info: TVkDescriptorSetAllocateInfo;
  Layout: TVkDescriptorSetLayout;
  Res: TVkResult;
begin
  Cmd;
  if (FPool.Pool = VK_NULL_HANDLE) or (FPoolSets >= SetsPerPool) then
    NextPool;
  Layout := ALayout;
  FillChar(Info, SizeOf(Info), 0);
  Info.sType := VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
  Info.descriptorPool := FPool.Pool;
  Info.descriptorSetCount := 1;
  Info.pSetLayouts := @Layout;
  Res := FVk.AllocateDescriptorSets(FDevice, @Info, @Result);
  if (Res = VK_ERROR_OUT_OF_POOL_MEMORY) or (Res = VK_ERROR_FRAGMENTED_POOL) then
  begin
    NextPool;
    Info.descriptorPool := FPool.Pool;
    Res := FVk.AllocateDescriptorSets(FDevice, @Info, @Result);
  end;
  Check(Res, 'vkAllocateDescriptorSets');
  FPool.Value := InList;
  Inc(FPoolSets);
end;

procedure TGpuVkContext.BeginRendering(const ATarget: TGpuVkSurface; const AClear: PVkClearColorValue);
var
  Attachment: TVkRenderingAttachmentInfo;
  Info: TVkRenderingInfo;
  ClearAttachment: TVkClearAttachment;
  Rect: TVkClearRect;
begin
  if (FRendering = ATarget) and (FBarrierCount = 0) and (FMemSrcStage = 0) and (FMemDstStage = 0) then
  begin
    if AClear <> nil then
    begin
      FillChar(ClearAttachment, SizeOf(ClearAttachment), 0);
      ClearAttachment.aspectMask := Ord(VK_IMAGE_ASPECT_COLOR_BIT);
      ClearAttachment.colorAttachment := 0;
      ClearAttachment.clearValue.color := AClear^;
      FillChar(Rect, SizeOf(Rect), 0);
      Rect.rect.extent.width := Max(ATarget.Width, 1);
      Rect.rect.extent.height := Max(ATarget.Height, 1);
      Rect.layerCount := 1;
      FVk.CmdClearAttachments(FCmd.Buffer, 1, @ClearAttachment, 1, @Rect);
    end;
    Exit;
  end;
  EndRendering;
  if ATarget.FUse = TGpuVkUse.ColorTarget then
    // Drawn in an earlier rendering instance: its writes come before the next ones (blending reads them).
    MemoryBarrier(StageColorOutput, AccessColorWrite, StageColorOutput, AccessColorRead or AccessColorWrite)
  else
    // A clear replaces everything.
    Transition(ATarget.FImage, ATarget.FUse, TGpuVkUse.ColorTarget, AClear <> nil);
  FlushBarriers;
  FillChar(Attachment, SizeOf(Attachment), 0);
  Attachment.sType := VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO;
  Attachment.imageView := ATarget.FView;
  Attachment.imageLayout := VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
  Attachment.resolveMode := VK_RESOLVE_MODE_NONE;
  if AClear <> nil then
  begin
    Attachment.loadOp := VK_ATTACHMENT_LOAD_OP_CLEAR;
    Attachment.clearValue.color := AClear^;
  end
  else
    Attachment.loadOp := VK_ATTACHMENT_LOAD_OP_LOAD;
  Attachment.storeOp := VK_ATTACHMENT_STORE_OP_STORE;
  FillChar(Info, SizeOf(Info), 0);
  Info.sType := VK_STRUCTURE_TYPE_RENDERING_INFO;
  Info.renderArea.extent.width := Max(ATarget.Width, 1);
  Info.renderArea.extent.height := Max(ATarget.Height, 1);
  Info.layerCount := 1;
  Info.colorAttachmentCount := 1;
  Info.pColorAttachments := @Attachment;
  FVk.CmdBeginRendering(Cmd, @Info);
  FRendering := ATarget;
end;

procedure TGpuVkContext.EndRendering;
begin
  if FRendering = nil then
    Exit;
  FRendering := nil;
  FVk.CmdEndRendering(FCmd.Buffer);
end;

{ TGpuVkSurface }

constructor TGpuVkSurface.Create(const AWidth, AHeight: Integer; const AData: Pointer; const APitch: Integer);
var
  C: TGpuVkContext;
  Transparent: TVkClearColorValue;
begin
  inherited Create;
  FWidth := AWidth;
  FHeight := AHeight;
  TFastDevice.Lock;
  try
    C := GpuVk;
    FImage := C.NewImage(VK_FORMAT_B8G8R8A8_UNORM, AWidth, AHeight, Ord(VK_IMAGE_USAGE_SAMPLED_BIT) or
      Ord(VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT) or Ord(VK_IMAGE_USAGE_TRANSFER_SRC_BIT) or
      Ord(VK_IMAGE_USAGE_TRANSFER_DST_BIT), FMemory, FView);
    C.FSurfaces.Add(Self);
    if AData <> nil then
      C.CopyToImage(FImage, FUse, 4, 0, 0, AWidth, AHeight, AData, APitch)
    else
    begin
      // A new bitmap is transparent black.
      FillChar(Transparent, SizeOf(Transparent), 0);
      C.ClearImage(FImage, FUse, Transparent);
    end;
    C.Transition(FImage, FUse, TGpuVkUse.ShaderRead);
  finally
    TFastDevice.Unlock;
  end;
end;

destructor TGpuVkSurface.Destroy;
begin
  TFastDevice.Lock;
  try
    if GCtx <> nil then
    begin
      GCtx.FSurfaces.Remove(Self);
      if GCtx.FRendering = Self then
        GCtx.EndRendering;
      // Command buffers that are not executed yet may use them.
      GCtx.Retire(TGpuVkObject.ImageView, FView);
      GCtx.Retire(TGpuVkObject.Image, FImage);
      GCtx.Retire(TGpuVkObject.Memory, MemoryHandle(FMemory));
      GCtx.Retire(TGpuVkObject.Buffer, FReadback);
      GCtx.Retire(TGpuVkObject.Memory, MemoryHandle(FReadbackMemory));
    end;
    FView := VK_NULL_HANDLE;
    FImage := VK_NULL_HANDLE;
    FMemory := nil;
    FReadback := VK_NULL_HANDLE;
    FReadbackMemory := nil;
  finally
    TFastDevice.Unlock;
  end;
  inherited;
end;

procedure TGpuVkSurface.Drop(const AContext: TGpuVkContext);
var
  C: TGpuVkContext;
begin
  C := AContext;
  C.FSurfaces.Remove(Self);
  C.DestroyObject(TGpuVkObject.ImageView, FView);
  C.DestroyObject(TGpuVkObject.Image, FImage);
  C.DestroyObject(TGpuVkObject.Memory, MemoryHandle(FMemory));
  C.DestroyObject(TGpuVkObject.Buffer, FReadback);
  C.DestroyObject(TGpuVkObject.Memory, MemoryHandle(FReadbackMemory));
  FView := VK_NULL_HANDLE;
  FImage := VK_NULL_HANDLE;
  FMemory := nil;
  FReadback := VK_NULL_HANDLE;
  FReadbackMemory := nil;
  FReadbackData := nil;
  FReadbackValid := False;
end;

procedure TGpuVkSurface.Use(const AUse: TGpuVkUse);
begin
  GpuVk.Transition(FImage, FUse, AUse);
end;

procedure TGpuVkSurface.GpuWritten;
begin
  FReadbackValid := False;
end;

procedure TGpuVkSurface.Upload(const AData: Pointer; const APitch: Integer);
var
  C: TGpuVkContext;
begin
  if FImage = VK_NULL_HANDLE then
    Exit;
  C := GpuVk;
  C.CopyToImage(FImage, FUse, 4, 0, 0, FWidth, FHeight, AData, APitch);
  C.Transition(FImage, FUse, TGpuVkUse.ShaderRead);
  FReadbackValid := False;
end;

function TGpuVkSurface.Map(out AData: Pointer; out APitch: Integer): Boolean;
var
  C: TGpuVkContext;
  Region: TVkBufferImageCopy;
begin
  Result := False;
  AData := nil;
  APitch := 0;
  if (FImage = VK_NULL_HANDLE) or (FWidth <= 0) or (FHeight <= 0) then
    Exit;
  C := GpuVk;
  if FReadback = VK_NULL_HANDLE then
  begin
    // Cached memory: the CPU reads it (and FMX code may change pixels in place).
    FReadback := C.NewBuffer(UInt64(FWidth) * UInt64(FHeight) * 4, Ord(VK_BUFFER_USAGE_TRANSFER_DST_BIT),
      Ord(VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT), Ord(VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) or
      Ord(VK_MEMORY_PROPERTY_HOST_CACHED_BIT), FReadbackMemory);
    FReadbackData := FReadbackMemory.Cpu;
    FReadbackValid := False;
  end;
  if not FReadbackValid then
  begin
    C.Transition(FImage, FUse, TGpuVkUse.TransferSrc);
    FillChar(Region, SizeOf(Region), 0);
    Region.imageSubresource := ColorLayers;
    Region.imageExtent.width := FWidth;
    Region.imageExtent.height := FHeight;
    Region.imageExtent.depth := 1;
    C.Vk.CmdCopyImageToBuffer(C.TransferCmd, FImage, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, FReadback, 1, @Region);
    // The copy's writes are for the host to read.
    C.MemoryBarrier(StageTransfer, AccessTransferWrite, StageHost, AccessHostRead);
    C.Transition(FImage, FUse, TGpuVkUse.ShaderRead);
    C.WaitIdle;
    C.Fast.Invalidate(FReadbackMemory);
    FReadbackValid := True;
  end;
  AData := FReadbackData;
  APitch := FWidth * 4;
  Result := True;
end;

procedure TGpuVkSurface.Unmap(const AWritten: Boolean);
var
  C: TGpuVkContext;
begin
  if (FReadbackData = nil) or not AWritten or (FImage = VK_NULL_HANDLE) then
    Exit;
  // The pixels the CPU changed go back to the image (through upload memory: the read-back buffer is the CPU's
  // again at the next Map); the read-back copy stays current.
  C := GpuVk;
  C.CopyToImage(FImage, FUse, 4, 0, 0, FWidth, FHeight, FReadbackData, FWidth * 4);
  C.Transition(FImage, FUse, TGpuVkUse.ShaderRead);
end;

procedure TGpuVkSurface.CopyFrom(const ASource: TGpuSurface);
var
  C: TGpuVkContext;
  S: TGpuVkSurface;
  Region: TVkImageCopy;
begin
  S := TGpuVkSurface(ASource);
  if (S = Self) or (FImage = VK_NULL_HANDLE) or (S.FImage = VK_NULL_HANDLE) then
    Exit;
  C := GpuVk;
  C.Transition(S.FImage, S.FUse, TGpuVkUse.TransferSrc);
  C.Transition(FImage, FUse, TGpuVkUse.TransferDst);
  FillChar(Region, SizeOf(Region), 0);
  Region.srcSubresource := ColorLayers;
  Region.dstSubresource := ColorLayers;
  Region.extent.width := Min(FWidth, S.FWidth);
  Region.extent.height := Min(FHeight, S.FHeight);
  Region.extent.depth := 1;
  C.Vk.CmdCopyImage(C.TransferCmd, S.FImage, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, FImage,
    VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, @Region);
  C.Transition(S.FImage, S.FUse, TGpuVkUse.ShaderRead);
  C.Transition(FImage, FUse, TGpuVkUse.ShaderRead);
  FReadbackValid := False;
end;

{ TGpuVkWindow }

constructor TGpuVkWindow.Create(const AWnd: HWND; const ALayered: Boolean);
begin
  inherited;
  TFastDevice.Lock;
  try
    GpuVk.FWindows.Add(Self);
  finally
    TFastDevice.Unlock;
  end;
end;

destructor TGpuVkWindow.Destroy;
begin
  // The presenting thread never takes the device lock: stopped before it, or after it, alike.
  StopPresenter;
  TFastDevice.Lock;
  try
    if GCtx <> nil then
    begin
      GCtx.FWindows.Remove(Self);
      if FVkSurface <> VK_NULL_HANDLE then
        GCtx.Fast.InstanceVk.DestroySurfaceKHR(GCtx.Fast.Instance, FVkSurface, nil);
      FVkSurface := VK_NULL_HANDLE;
    end;
    FreeAndNil(FShown);
    FreeAndNil(FSurface);
  finally
    TFastDevice.Unlock;
  end;
  inherited;
end;

procedure TGpuVkWindow.StopPresenter;
begin
  if FPresenter = nil then
    Exit;
  FPresenter.Stop;
  FreeAndNil(FPresenter);
end;

procedure TGpuVkWindow.Drop(const AContext: TGpuVkContext);
begin
  StopPresenter;
  AContext.FWindows.Remove(Self);
  if FVkSurface <> VK_NULL_HANDLE then
    AContext.Fast.InstanceVk.DestroySurfaceKHR(AContext.Fast.Instance, FVkSurface, nil);
  FVkSurface := VK_NULL_HANDLE;
  FModes := nil;
end;

procedure TGpuVkWindow.CreateVkSurface;
var
  F: TFastVulkan;
  Info: TVkWin32SurfaceCreateInfoKHR;
  Supported: TVkBool32;
  Count: Cardinal;
begin
  F := GpuVk.Fast;
  FillChar(Info, SizeOf(Info), 0);
  Info.sType := VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR;
  Info.hinstance_ := TVkHINSTANCE(GetWindowLongPtr(FWnd, GWLP_HINSTANCE));
  Info.hwnd_ := FWnd;
  F.Check(F.InstanceVk.CreateWin32SurfaceKHR(F.Instance, @Info, nil, @FVkSurface), 'vkCreateWin32SurfaceKHR');
  Supported := VK_FALSE;
  F.InstanceVk.GetPhysicalDeviceSurfaceSupportKHR(F.Physical, F.QueueFamily, FVkSurface, @Supported);
  if Supported = VK_FALSE then
    raise EFastDevice.Create('FastCanvas: the Vulkan queue cannot present to the window');
  Count := 0;
  F.InstanceVk.GetPhysicalDeviceSurfacePresentModesKHR(F.Physical, FVkSurface, @Count, nil);
  SetLength(FModes, Count);
  if Count > 0 then
    F.InstanceVk.GetPhysicalDeviceSurfacePresentModesKHR(F.Physical, FVkSurface, @Count, @FModes[0]);
end;

function TGpuVkWindow.HasMode(const AMode: TVkPresentModeKHR): Boolean;
var
  M: TVkPresentModeKHR;
begin
  for M in FModes do
    if M = AMode then
      Exit(True);
  Result := False;
end;

/// <summary>A surface format for the frames: theirs (a copy), else an 8-bit UNORM one (a blit), else what there is.
/// </summary>
function ChooseFormat(const AFast: TFastVulkan; const ASurface: TVkSurfaceKHR): TVkSurfaceFormatKHR;

  function Rank(const AFormat: TVkSurfaceFormatKHR): Integer;
  begin
    Result := 0;
    if AFormat.colorSpace = VK_COLOR_SPACE_SRGB_NONLINEAR_KHR then
      if AFormat.format = VK_FORMAT_B8G8R8A8_UNORM then
        Result := 2
      else if AFormat.format = VK_FORMAT_R8G8B8A8_UNORM then
        Result := 1;
  end;

var
  Count, I: Cardinal;
  Formats: TArray<TVkSurfaceFormatKHR>;
begin
  Count := 0;
  AFast.InstanceVk.GetPhysicalDeviceSurfaceFormatsKHR(AFast.Physical, ASurface, @Count, nil);
  SetLength(Formats, Count);
  if Count > 0 then
    AFast.InstanceVk.GetPhysicalDeviceSurfaceFormatsKHR(AFast.Physical, ASurface, @Count, @Formats[0]);
  if Count = 0 then
    raise EFastDevice.Create('FastCanvas: the window has no Vulkan surface formats');
  Result := Formats[0];
  for I := Count - 1 downto 0 do
    if Rank(Formats[I]) >= Rank(Result) then
      Result := Formats[I];
end;

/// <summary>Records the copy (or the stretching blit) of a frame into a swap chain image, between the barriers that
/// take the image from the acquire to the present.</summary>
procedure RecordChainCopy(const AVk: TVulkan; const ACmd: TVkCommandBuffer; const ASource: TGpuVkSurface;
  const AImage: TVkImage; const AFormat: TVkFormat; const AExtent: TVkExtent2D);
var
  Barrier: TVkImageMemoryBarrier2;
  Dep: TVkDependencyInfo;
  Copy: TVkImageCopy;
  Blit: TVkImageBlit;
begin
  FillChar(Barrier, SizeOf(Barrier), 0);
  Barrier.sType := VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2;
  // After the acquire semaphore (waited for at the transfer stage); the image's old content goes.
  Barrier.srcStageMask := StageTransfer;
  Barrier.dstStageMask := StageTransfer;
  Barrier.dstAccessMask := AccessTransferWrite;
  Barrier.oldLayout := VK_IMAGE_LAYOUT_UNDEFINED;
  Barrier.newLayout := VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
  Barrier.srcQueueFamilyIndex := VK_QUEUE_FAMILY_IGNORED;
  Barrier.dstQueueFamilyIndex := VK_QUEUE_FAMILY_IGNORED;
  Barrier.image := AImage;
  Barrier.subresourceRange := ColorRange;
  FillChar(Dep, SizeOf(Dep), 0);
  Dep.sType := VK_STRUCTURE_TYPE_DEPENDENCY_INFO;
  Dep.imageMemoryBarrierCount := 1;
  Dep.pImageMemoryBarriers := @Barrier;
  AVk.CmdPipelineBarrier2(ACmd, @Dep);
  if (AFormat = VK_FORMAT_B8G8R8A8_UNORM) and (Cardinal(ASource.Width) = AExtent.width) and
    (Cardinal(ASource.Height) = AExtent.height) then
  begin
    FillChar(Copy, SizeOf(Copy), 0);
    Copy.srcSubresource := ColorLayers;
    Copy.dstSubresource := ColorLayers;
    Copy.extent.width := AExtent.width;
    Copy.extent.height := AExtent.height;
    Copy.extent.depth := 1;
    AVk.CmdCopyImage(ACmd, ASource.Image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, AImage,
      VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, @Copy);
  end
  else
  begin
    // Another size (the window was resized after the frame was recorded) or format: stretched and converted, as
    // DXGI_SCALING_STRETCH shows a swap chain of another size.
    FillChar(Blit, SizeOf(Blit), 0);
    Blit.srcSubresource := ColorLayers;
    Blit.srcOffsets[1].x := ASource.Width;
    Blit.srcOffsets[1].y := ASource.Height;
    Blit.srcOffsets[1].z := 1;
    Blit.dstSubresource := ColorLayers;
    Blit.dstOffsets[1].x := AExtent.width;
    Blit.dstOffsets[1].y := AExtent.height;
    Blit.dstOffsets[1].z := 1;
    AVk.CmdBlitImage(ACmd, ASource.Image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, AImage,
      VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, @Blit, VK_FILTER_LINEAR);
  end;
  Barrier.srcStageMask := StageTransfer;
  Barrier.srcAccessMask := AccessTransferWrite;
  Barrier.dstStageMask := StageNone;
  Barrier.dstAccessMask := 0;
  Barrier.oldLayout := VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
  Barrier.newLayout := VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
  AVk.CmdPipelineBarrier2(ACmd, @Dep);
end;

function TGpuVkWindow.Prepare(const AWidth, AHeight: Integer; const ATearing: Boolean;
  const AOutput: TGpuOutput): TGpuSurface;
begin
  // Frames are drawn into a surface of the window (8-bit: no HDR output yet), which Present copies on and
  // transparent windows read back.
  if (FSurface <> nil) and ((FSurface.Width <> AWidth) or (FSurface.Height <> AHeight)) then
    FreeAndNil(FSurface);
  if FSurface = nil then
  begin
    FSurface := TGpuVkSurface.Create(AWidth, AHeight, nil, 0);
    FDrawn := False;
  end;
  if ATearing <> FTearingAsked then
  begin
    FTearingAsked := ATearing;
    FStale := True;
  end;
  Result := FSurface;
end;

function TGpuVkWindow.Present: HResult;
var
  C: TGpuVkContext;
  S, Old: TGpuVkSurface;
  Region: TVkImageCopy;
begin
  Result := S_OK;
  if FLayered or (FSurface = nil) then
    Exit;
  C := GpuVk;
  if FVkSurface = VK_NULL_HANDLE then
    CreateVkSurface;
  if FPresenter = nil then
    FPresenter := TGpuVkPresenter.Create(Self);
  if FStale then
  begin
    FStale := False;
    EnterCriticalSection(FPresenter.FLock);
    FPresenter.FStaleAsked := True;
    LeaveCriticalSection(FPresenter.FLock);
  end;
  if (FShown = nil) or (FShown.Width <> FSurface.Width) or (FShown.Height <> FSurface.Height) then
  begin
    // A copy of the frame's size. The old one goes once the presenting thread has submitted what uses it (it does so
    // holding the lock) and the GPU is done with that: the context's next submission is later on the queue, and the
    // command buffer it retires with is open (the new surface was cleared in it).
    S := TGpuVkSurface.Create(FSurface.Width, FSurface.Height, nil, 0);
    EnterCriticalSection(FPresenter.FLock);
    Old := FShown;
    FShown := S;
    Inc(FPresenter.FShownGen);
    LeaveCriticalSection(FPresenter.FLock);
    Old.Free;
  end;
  // The newest frame into the copy, which rests in TRANSFER_SRC_OPTIMAL for the presenting thread (its reads of the
  // frame before are earlier on the queue).
  FSurface.Use(TGpuVkUse.TransferSrc);
  C.Transition(FShown.Image, FShown.FUse, TGpuVkUse.TransferDst, True);
  FillChar(Region, SizeOf(Region), 0);
  Region.srcSubresource := ColorLayers;
  Region.dstSubresource := ColorLayers;
  Region.extent.width := FSurface.Width;
  Region.extent.height := FSurface.Height;
  Region.extent.depth := 1;
  C.Vk.CmdCopyImage(C.TransferCmd, FSurface.Image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, FShown.Image,
    VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, @Region);
  FShown.Use(TGpuVkUse.TransferSrc);
  C.WaitFor(FFrameValues[FFrameIndex mod FramesInFlight]);
  FFrameValues[FFrameIndex mod FramesInFlight] := C.Submit;
  Inc(FFrameIndex);
  FDrawn := True;
  if C.Fast.Lost then
    Exit(DXGI_ERROR_DEVICE_REMOVED);
  FPresenter.Post;
end;

function TGpuVkWindow.RestoreLast: Boolean;
begin
  // The surface keeps the frame drawn last (also of a transparent window), unless it was made for this frame.
  Result := (FSurface <> nil) and FDrawn;
end;

function TGpuVkWindow.Capture(out ACapture: TGpuCapture): Boolean;
var
  P: Pointer;
  Pitch, X, Y, W, H: Integer;
  Src: PByte;
  D: PSingle;
begin
  ACapture := Default(TGpuCapture);
  Result := False;
  if (FSurface = nil) or not FDrawn then
    Exit;
  W := FSurface.Width;
  H := FSurface.Height;
  // A copy of what the GPU holds now.
  FSurface.GpuWritten;
  if not FSurface.Map(P, Pitch) then
    Exit;
  try
    ACapture.Width := W;
    ACapture.Height := H;
    SetLength(ACapture.Pixels, W * H * 4);
    D := @ACapture.Pixels[0];
    for Y := 0 to H - 1 do
    begin
      Src := PByte(P) + NativeInt(Y) * Pitch;
      for X := 0 to W - 1 do
      begin
        // BGRA.
        D^ := Src[2] / 255;
        PSingle(PByte(D) + 4)^ := Src[1] / 255;
        PSingle(PByte(D) + 8)^ := Src[0] / 255;
        PSingle(PByte(D) + 12)^ := Src[3] / 255;
        Inc(Src, 4);
        Inc(D, 4);
      end;
    end;
    Result := True;
  finally
    FSurface.Unmap(False);
  end;
end;

procedure TGpuVkWindow.ReadPixels(const ABits: Pointer; const AWidth, AHeight: Integer);
var
  P: Pointer;
  Pitch, I: Integer;
begin
  if FSurface = nil then
    Exit;
  FDrawn := True;
  FSurface.GpuWritten;
  if not FSurface.Map(P, Pitch) then
    Exit;
  try
    for I := 0 to Min(AHeight, FSurface.Height) - 1 do
      Move((PByte(P) + NativeInt(I) * Pitch)^, (PByte(ABits) + NativeInt(I) * AWidth * 4)^,
        Min(AWidth, FSurface.Width) * 4);
  finally
    FSurface.Unmap(False);
  end;
end;

/// <summary>The extent of a swap chain for frames of AWidth x AHeight; zero when the window has no size (minimized).
/// </summary>
function ChainExtent(const ACaps: TVkSurfaceCapabilitiesKHR; const AWidth, AHeight: Integer): TVkExtent2D;
begin
  Result := ACaps.currentExtent;
  if Result.width = High(Cardinal) then
  begin
    // The surface takes the swap chain's size: the frame's.
    Result.width := EnsureRange(Cardinal(AWidth), ACaps.minImageExtent.width, ACaps.maxImageExtent.width);
    Result.height := EnsureRange(Cardinal(AHeight), ACaps.minImageExtent.height, ACaps.maxImageExtent.height);
  end;
end;

/// <summary>The fields of a swap chain's creation that do not depend on the present mode and size.</summary>
procedure FillChainInfo(var AInfo: TVkSwapchainCreateInfoKHR; const ASurface: TVkSurfaceKHR;
  const ACaps: TVkSurfaceCapabilitiesKHR; const AFormat: TVkSurfaceFormatKHR);
begin
  if (ACaps.supportedUsageFlags and Ord(VK_IMAGE_USAGE_TRANSFER_DST_BIT)) = 0 then
    raise EFastDevice.Create('FastCanvas: the window''s swap chain cannot be copied into');
  FillChar(AInfo, SizeOf(AInfo), 0);
  AInfo.sType := VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR;
  AInfo.surface := ASurface;
  AInfo.minImageCount := Max(ACaps.minImageCount, SwapImages);
  if ACaps.maxImageCount > 0 then
    AInfo.minImageCount := Min(AInfo.minImageCount, ACaps.maxImageCount);
  AInfo.imageFormat := AFormat.format;
  AInfo.imageColorSpace := AFormat.colorSpace;
  AInfo.imageArrayLayers := 1;
  AInfo.imageUsage := Ord(VK_IMAGE_USAGE_TRANSFER_DST_BIT);
  AInfo.imageSharingMode := VK_SHARING_MODE_EXCLUSIVE;
  AInfo.preTransform := ACaps.currentTransform;
  if (ACaps.supportedCompositeAlpha and Ord(VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR)) <> 0 then
    AInfo.compositeAlpha := VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR
  else if (ACaps.supportedCompositeAlpha and Ord(VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR)) <> 0 then
    AInfo.compositeAlpha := VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR
  else
    AInfo.compositeAlpha := VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR;
  AInfo.clipped := VK_TRUE;
end;
{ TGpuVkPresenter }

constructor TGpuVkPresenter.Create(const AWindow: TGpuVkWindow);
var
  TypeInfo: TVkSemaphoreTypeCreateInfo;
  Info: TVkSemaphoreCreateInfo;
  PoolInfo: TVkCommandPoolCreateInfo;
  FenceInfo: TVkFenceCreateInfo;
begin
  FWindow := AWindow;
  FFast := GpuVk.Fast;
  FVk := FFast.Vk;
  FDevice := FFast.Device;
  InitializeCriticalSection(FLock);
  FWake := TEvent.Create(nil, False, False, '');
  FillChar(TypeInfo, SizeOf(TypeInfo), 0);
  TypeInfo.sType := VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO;
  TypeInfo.semaphoreType := VK_SEMAPHORE_TYPE_TIMELINE;
  FillChar(Info, SizeOf(Info), 0);
  Info.sType := VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
  Info.pNext := @TypeInfo;
  FFast.Check(FVk.CreateSemaphore(FDevice, @Info, nil, @FTimeline), 'vkCreateSemaphore (timeline)');
  FillChar(PoolInfo, SizeOf(PoolInfo), 0);
  PoolInfo.sType := VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
  PoolInfo.flags := Ord(VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT);
  PoolInfo.queueFamilyIndex := FFast.QueueFamily;
  FFast.Check(FVk.CreateCommandPool(FDevice, @PoolInfo, nil, @FPool), 'vkCreateCommandPool');
  FillChar(FenceInfo, SizeOf(FenceInfo), 0);
  FenceInfo.sType := VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
  FFast.Check(FVk.CreateFence(FDevice, @FenceInfo, nil, @FAcquired), 'vkCreateFence');
  inherited Create(False);
end;

destructor TGpuVkPresenter.Destroy;
begin
  // Stop has ended the thread and released its objects.
  inherited;
  FWake.Free;
  DeleteCriticalSection(FLock);
end;

procedure TGpuVkPresenter.Post;
begin
  EnterCriticalSection(FLock);
  FPending := True;
  LeaveCriticalSection(FLock);
  FWake.SetEvent;
end;

procedure TGpuVkPresenter.Stop;
begin
  Terminate;
  FWake.SetEvent;
  WaitFor;
  Release;
end;

function TGpuVkPresenter.Ok(const ARes: TVkResult): Boolean;
begin
  Result := Ord(FFast.Track(ARes)) >= 0;
end;

procedure TGpuVkPresenter.WaitValue(const AValue: UInt64);
var
  Info: TVkSemaphoreWaitInfo;
  Value: UInt64;
  Res: TVkResult;
begin
  if AValue = 0 then
    Exit;
  Value := AValue;
  FillChar(Info, SizeOf(Info), 0);
  Info.sType := VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO;
  Info.semaphoreCount := 1;
  Info.pSemaphores := @FTimeline;
  Info.pValues := @Value;
  repeat
    Res := FFast.Track(FVk.WaitSemaphores(FDevice, @Info, WaitSlice));
  until (Res <> VK_TIMEOUT) or FFast.Lost;
end;

/// <summary>The images, semaphores and command buffers of the swap chain go (and the swap chain when ADestroyOld),
/// once the queue and the presentation engine are done with them.</summary>
procedure TGpuVkPresenter.ReleaseChain(const ADestroyOld: Boolean);
var
  S: TVkSemaphore;
begin
  WaitValue(FValue);
  FFast.LockQueue;
  try
    FVk.QueueWaitIdle(FFast.Queue);
  finally
    FFast.UnlockQueue;
  end;
  for S in FPresentSems do
    FVk.DestroySemaphore(FDevice, S, nil);
  if FCmds <> nil then
    FVk.FreeCommandBuffers(FDevice, FPool, Length(FCmds), @FCmds[0]);
  FPresentSems := nil;
  FImages := nil;
  FCmds := nil;
  FCmdGens := nil;
  FCmdValues := nil;
  if ADestroyOld and (FSwapchain <> VK_NULL_HANDLE) then
  begin
    FVk.DestroySwapchainKHR(FDevice, FSwapchain, nil);
    FSwapchain := VK_NULL_HANDLE;
  end;
end;

procedure TGpuVkPresenter.Release;
begin
  if FTimeline = VK_NULL_HANDLE then
    Exit;
  ReleaseChain(True);
  FVk.DestroyCommandPool(FDevice, FPool, nil);
  FVk.DestroySemaphore(FDevice, FTimeline, nil);
  FVk.DestroyFence(FDevice, FAcquired, nil);
  FPool := VK_NULL_HANDLE;
  FTimeline := VK_NULL_HANDLE;
end;

function TGpuVkPresenter.CreateChain(const AWidth, AHeight: Integer): Boolean;
var
  Caps: TVkSurfaceCapabilitiesKHR;
  Extent: TVkExtent2D;
  Info: TVkSwapchainCreateInfoKHR;
  AllocInfo: TVkCommandBufferAllocateInfo;
  SemInfo: TVkSemaphoreCreateInfo;
  Old, Chain: TVkSwapchainKHR;
  Count: Cardinal;
  K: Integer;
begin
  Result := False;
  if not Ok(FFast.InstanceVk.GetPhysicalDeviceSurfaceCapabilitiesKHR(FFast.Physical, FWindow.FVkSurface, @Caps)) then
    Exit;
  Extent := ChainExtent(Caps, AWidth, AHeight);
  if (Extent.width = 0) or (Extent.height = 0) then
    Exit;
  if (FSwapchain <> VK_NULL_HANDLE) and not FStale and (Extent.width = FExtent.width) and
    (Extent.height = FExtent.height) then
    Exit(True);
  FFormat := ChooseFormat(FFast, FWindow.FVkSurface);
  Old := FSwapchain;
  ReleaseChain(False);
  FillChainInfo(Info, FWindow.FVkSurface, Caps, FFormat);
  Info.imageExtent := Extent;
  // FIFO_LATEST_READY shows the newest frame queued at a refresh and frees the ones before it.
  if FWindow.FTearingAsked and FWindow.HasMode(VK_PRESENT_MODE_IMMEDIATE_KHR) then
    Info.presentMode := VK_PRESENT_MODE_IMMEDIATE_KHR
  else if FWindow.HasMode(VK_PRESENT_MODE_MAILBOX_KHR) then
    Info.presentMode := VK_PRESENT_MODE_MAILBOX_KHR
  else if FFast.FifoLatestReady and FWindow.HasMode(VK_PRESENT_MODE_FIFO_LATEST_READY_KHR) then
    Info.presentMode := VK_PRESENT_MODE_FIFO_LATEST_READY_KHR
  else
    Info.presentMode := VK_PRESENT_MODE_FIFO_KHR;
  Info.oldSwapchain := Old;
  Chain := VK_NULL_HANDLE;
  FFast.Check(FVk.CreateSwapchainKHR(FDevice, @Info, nil, @Chain), 'vkCreateSwapchainKHR');
  if Old <> VK_NULL_HANDLE then
    FVk.DestroySwapchainKHR(FDevice, Old, nil);
  FSwapchain := Chain;
  Count := 0;
  FVk.GetSwapchainImagesKHR(FDevice, FSwapchain, @Count, nil);
  SetLength(FImages, Count);
  if Count > 0 then
    FVk.GetSwapchainImagesKHR(FDevice, FSwapchain, @Count, @FImages[0]);
  FillChar(SemInfo, SizeOf(SemInfo), 0);
  SemInfo.sType := VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
  SetLength(FPresentSems, Count);
  for K := 0 to High(FPresentSems) do
    FFast.Check(FVk.CreateSemaphore(FDevice, @SemInfo, nil, @FPresentSems[K]), 'vkCreateSemaphore');
  SetLength(FCmds, Count);
  SetLength(FCmdGens, Count);
  SetLength(FCmdValues, Count);
  FillChar(AllocInfo, SizeOf(AllocInfo), 0);
  AllocInfo.sType := VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
  AllocInfo.commandPool := FPool;
  AllocInfo.level := VK_COMMAND_BUFFER_LEVEL_PRIMARY;
  AllocInfo.commandBufferCount := Count;
  FFast.Check(FVk.AllocateCommandBuffers(FDevice, @AllocInfo, @FCmds[0]), 'vkAllocateCommandBuffers');
  for K := 0 to High(FCmdGens) do
  begin
    FCmdGens[K] := -1;
    FCmdValues[K] := 0;
  end;
  FExtent := Extent;
  FStale := False;
  Result := True;
end;

procedure TGpuVkPresenter.Record_(const AIndex: Integer; const AShown: TGpuVkSurface);
var
  Begin_: TVkCommandBufferBeginInfo;
begin
  // The command buffer's last execution is done before it is recorded again.
  WaitValue(FCmdValues[AIndex]);
  FFast.Check(FVk.ResetCommandBuffer(FCmds[AIndex], 0), 'vkResetCommandBuffer');
  FillChar(Begin_, SizeOf(Begin_), 0);
  Begin_.sType := VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
  FFast.Check(FVk.BeginCommandBuffer(FCmds[AIndex], @Begin_), 'vkBeginCommandBuffer');
  RecordChainCopy(FVk, FCmds[AIndex], AShown, FImages[AIndex], FFormat.format, FExtent);
  FFast.Check(FVk.EndCommandBuffer(FCmds[AIndex]), 'vkEndCommandBuffer');
  FCmdGens[AIndex] := FShownGen;
end;

function TGpuVkPresenter.PresentPending: Boolean;
var
  Shown: TGpuVkSurface;
  W, H, Attempt: Integer;
  Index: Cardinal;
  Res: TVkResult;
  Submit: TVkSubmitInfo2;
  CmdInfo: TVkCommandBufferSubmitInfo;
  Signals: array[0..1] of TVkSemaphoreSubmitInfo;
  Info: TVkPresentInfoKHR;
  Sem: TVkSemaphore;
begin
  Result := False;
  EnterCriticalSection(FLock);
  try
    Shown := FWindow.FShown;
    if not FPending or (Shown = nil) then
      Exit;
    W := Shown.Width;
    H := Shown.Height;
    if FStaleAsked then
    begin
      FStaleAsked := False;
      FStale := True;
    end;
  finally
    LeaveCriticalSection(FLock);
  end;
  if FFast.Lost then
    Exit;
  if FStale or (FSwapchain = VK_NULL_HANDLE) or (W <> FCheckedW) or (H <> FCheckedH) then
  begin
    FCheckedW := W;
    FCheckedH := H;
    if not CreateChain(W, H) then
    begin
      // No size (minimized): nothing to show.
      EnterCriticalSection(FLock);
      FPending := False;
      LeaveCriticalSection(FLock);
      Exit;
    end;
  end;
  // Where FIFO waits for the display. In slices, to notice the end of the thread.
  Index := 0;
  Attempt := 0;
  repeat
    Res := FFast.Track(FVk.AcquireNextImageKHR(FDevice, FSwapchain, 100000000, VK_NULL_HANDLE, FAcquired, @Index));
    if Res = VK_ERROR_OUT_OF_DATE_KHR then
    begin
      Inc(Attempt);
      FStale := True;
      if (Attempt > 1) or not CreateChain(W, H) then
        Exit;
      Continue;
    end;
    if (Res <> VK_TIMEOUT) and (Res <> VK_NOT_READY) then
      Break;
    if Terminated or FFast.Lost then
      Exit;
  until False;
  if (Res <> VK_SUCCESS) and (Res <> VK_SUBOPTIMAL_KHR) then
  begin
    FStale := True;
    Exit;
  end;
  if Res = VK_SUBOPTIMAL_KHR then
    FStale := True;
  repeat
    Res := FFast.Track(FVk.WaitForFences(FDevice, 1, @FAcquired, VK_TRUE, 100000000));
  until (Res <> VK_TIMEOUT) or FFast.Lost;
  FVk.ResetFences(FDevice, 1, @FAcquired);
  if FFast.Lost then
    Exit;
  // The newest frame: the render thread may have posted another meanwhile, or a copy of another size.
  EnterCriticalSection(FLock);
  try
    Shown := FWindow.FShown;
    FPending := False;
    if FCmdGens[Index] <> FShownGen then
      Record_(Index, Shown);
    Inc(FValue);
    FillChar(CmdInfo, SizeOf(CmdInfo), 0);
    CmdInfo.sType := VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO;
    CmdInfo.commandBuffer := FCmds[Index];
    Sem := FPresentSems[Index];
    FillChar(Signals, SizeOf(Signals), 0);
    Signals[0].sType := VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO;
    Signals[0].semaphore := FTimeline;
    Signals[0].value := FValue;
    Signals[0].stageMask := StageAllCommands;
    Signals[1].sType := VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO;
    Signals[1].semaphore := Sem;
    Signals[1].stageMask := StageAllCommands;
    FillChar(Submit, SizeOf(Submit), 0);
    Submit.sType := VK_STRUCTURE_TYPE_SUBMIT_INFO_2;
    Submit.commandBufferInfoCount := 1;
    Submit.pCommandBufferInfos := @CmdInfo;
    Submit.signalSemaphoreInfoCount := 2;
    Submit.pSignalSemaphoreInfos := @Signals[0];
    FillChar(Info, SizeOf(Info), 0);
    Info.sType := VK_STRUCTURE_TYPE_PRESENT_INFO_KHR;
    Info.waitSemaphoreCount := 1;
    Info.pWaitSemaphores := @Sem;
    Info.swapchainCount := 1;
    Info.pSwapchains := @FSwapchain;
    Info.pImageIndices := @Index;
    FFast.LockQueue;
    try
      Res := FFast.Track(FVk.QueueSubmit2(FFast.Queue, 1, @Submit, VK_NULL_HANDLE));
      if Ord(Res) >= 0 then
        Res := FFast.Track(FVk.QueuePresentKHR(FFast.Queue, @Info))
      else
        // The submission's work is gone and the timeline never gets its value: the device is made again.
        FFast.Track(VK_ERROR_DEVICE_LOST);
    finally
      FFast.UnlockQueue;
    end;
  finally
    LeaveCriticalSection(FLock);
  end;
  FCmdValues[Index] := FValue;
  if Res <> VK_SUCCESS then
    FStale := True;
  Result := not FFast.Lost;
end;

procedure TGpuVkPresenter.Execute;
begin
  NameThreadForDebugging('FastCanvas Vulkan present');
  while not Terminated do
  begin
    FWake.WaitFor(INFINITE);
    try
      while not Terminated and PresentPending do
        ;
    except
      // A failure here shows at the window's next frame (a lost device) or not at all (a frame not shown).
      FFast.Track(VK_ERROR_DEVICE_LOST);
    end;
  end;
end;

{ TGpuVkRenderer }

constructor TGpuVkRenderer.Create;
begin
  inherited Create;
  FBoundGen := -1;
  FConstGen := -1;
  FSetGen := -1;
  TFastDevice.Lock;
  try
    CreatePipeline;
  finally
    TFastDevice.Unlock;
  end;
end;

destructor TGpuVkRenderer.Destroy;
var
  C: TGpuVkContext;
  I: Integer;
begin
  C := GCtx;
  if C <> nil then
  begin
    // Submitted command buffers may still use them.
    C.Retire(TGpuVkObject.Pipeline, FPipeBlend);
    C.Retire(TGpuVkObject.Pipeline, FPipeCopy);
    C.Retire(TGpuVkObject.Pipeline, FPipeDual);
    C.Retire(TGpuVkObject.PipelineLayout, FLayout);
    C.Retire(TGpuVkObject.SetLayout, FSetLayout);
    for I := 0 to High(FSamplers) do
      C.Retire(TGpuVkObject.Sampler, FSamplers[I]);
    C.Retire(TGpuVkObject.ShaderModule, FVS);
    C.Retire(TGpuVkObject.ShaderModule, FPS);
    C.Retire(TGpuVkObject.ShaderModule, FPSDual);
    ReleaseTexture(FAtlas);
    ReleaseTexture(FRamps);
    ReleaseTexture(FEmpty);
    ReleaseTable(FClips);
    ReleaseTable(FPaints);
    ReleaseTable(FEdges);
  end;
  inherited;
end;

procedure TGpuVkRenderer.ReleaseTexture(var AImage: TGpuVkImage);
begin
  GCtx.Retire(TGpuVkObject.ImageView, AImage.View);
  GCtx.Retire(TGpuVkObject.Image, AImage.Image);
  GCtx.Retire(TGpuVkObject.Memory, MemoryHandle(AImage.Memory));
  AImage := Default(TGpuVkImage);
end;

procedure TGpuVkRenderer.ReleaseTable(var ATable: TGpuVkTable);
begin
  GCtx.Retire(TGpuVkObject.BufferView, ATable.View);
  GCtx.Retire(TGpuVkObject.Buffer, ATable.Buffer);
  GCtx.Retire(TGpuVkObject.Memory, MemoryHandle(ATable.Memory));
  ATable := Default(TGpuVkTable);
end;

function TGpuVkRenderer.NewTexture(const AFormat: TVkFormat; const AWidth, AHeight: Integer): TGpuVkImage;
var
  C: TGpuVkContext;
  Zero: TVkClearColorValue;
begin
  C := GpuVk;
  Result := Default(TGpuVkImage);
  Result.Image := C.NewImage(AFormat, AWidth, AHeight, Ord(VK_IMAGE_USAGE_SAMPLED_BIT) or
    Ord(VK_IMAGE_USAGE_TRANSFER_DST_BIT), Result.Memory, Result.View);
  // Defined content (Direct3D 12 leaves it undefined until uploaded; nothing reads it before).
  FillChar(Zero, SizeOf(Zero), 0);
  C.ClearImage(Result.Image, Result.Use, Zero);
  C.Transition(Result.Image, Result.Use, TGpuVkUse.ShaderRead);
end;

function TGpuVkRenderer.NewTable(const AFloat4s: Integer): TGpuVkTable;
var
  C: TGpuVkContext;
  Info: TVkBufferViewCreateInfo;
  Elements: UInt64;
begin
  C := GpuVk;
  Result := Default(TGpuVkTable);
  Result.Buffer := C.NewBuffer(UInt64(AFloat4s) * 16, Ord(VK_BUFFER_USAGE_UNIFORM_TEXEL_BUFFER_BIT) or
    Ord(VK_BUFFER_USAGE_TRANSFER_DST_BIT), Ord(VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT), 0, Result.Memory);
  // The view reaches as far as the device lets texel buffers reach.
  Elements := Min(UInt64(AFloat4s), UInt64(C.Fast.Properties.limits.maxTexelBufferElements));
  FillChar(Info, SizeOf(Info), 0);
  Info.sType := VK_STRUCTURE_TYPE_BUFFER_VIEW_CREATE_INFO;
  Info.buffer := Result.Buffer;
  Info.format := VK_FORMAT_R32G32B32A32_SFLOAT;
  Info.offset := 0;
  Info.range := Elements * 16;
  C.Check(C.Vk.CreateBufferView(C.Device, @Info, nil, @Result.View), 'vkCreateBufferView');
  C.BufferUse(Result.Use, TGpuVkUse.TransferDst);
  C.Vk.CmdFillBuffer(C.TransferCmd, Result.Buffer, 0, VK_WHOLE_SIZE, 0);
end;

function TGpuVkRenderer.NewPipeline(const AFormat: TVkFormat; const ABlend, ADual: Boolean): TVkPipeline;
const
  MainVS: PAnsiChar = 'VSMain';
  MainPS: PAnsiChar = 'PSMain';
  MainDual: PAnsiChar = 'PSMainDual';
var
  C: TGpuVkContext;
  Stages: array[0..1] of TVkPipelineShaderStageCreateInfo;
  Binding: TVkVertexInputBindingDescription;
  Attributes: array[0..5] of TVkVertexInputAttributeDescription;
  VertexInput: TVkPipelineVertexInputStateCreateInfo;
  Assembly: TVkPipelineInputAssemblyStateCreateInfo;
  ViewportState: TVkPipelineViewportStateCreateInfo;
  Raster: TVkPipelineRasterizationStateCreateInfo;
  Multisample: TVkPipelineMultisampleStateCreateInfo;
  Attachment: TVkPipelineColorBlendAttachmentState;
  Blend: TVkPipelineColorBlendStateCreateInfo;
  DynamicStates: array[0..1] of TVkDynamicState;
  Dynamic: TVkPipelineDynamicStateCreateInfo;
  Format: TVkFormat;
  Rendering: TVkPipelineRenderingCreateInfo;
  Info: TVkGraphicsPipelineCreateInfo;

  procedure Attribute(const AIndex: Integer; const AFormat: TVkFormat; const AOffset: Cardinal);
  begin
    Attributes[AIndex].location := AIndex;
    Attributes[AIndex].binding := 0;
    Attributes[AIndex].format := AFormat;
    Attributes[AIndex].offset := AOffset;
  end;

begin
  C := GpuVk;
  FillChar(Stages, SizeOf(Stages), 0);
  Stages[0].sType := VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
  Stages[0].stage := VK_SHADER_STAGE_VERTEX_BIT;
  Stages[0].module := FVS;
  Stages[0].pName := MainVS;
  Stages[1].sType := VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
  Stages[1].stage := VK_SHADER_STAGE_FRAGMENT_BIT;
  if ADual then
  begin
    Stages[1].module := FPSDual;
    Stages[1].pName := MainDual;
  end
  else
  begin
    Stages[1].module := FPS;
    Stages[1].pName := MainPS;
  end;
  // One instance per primitive (a strip of four vertices); the first 84 bytes of TGpuInstance.
  Binding.binding := 0;
  Binding.stride := GpuInstanceStride;
  Binding.inputRate := VK_VERTEX_INPUT_RATE_INSTANCE;
  Attribute(0, VK_FORMAT_R32G32B32A32_SFLOAT, 0);
  Attribute(1, VK_FORMAT_R32G32B32A32_SFLOAT, 16);
  Attribute(2, VK_FORMAT_R32G32B32A32_SFLOAT, 32);
  Attribute(3, VK_FORMAT_R32G32B32A32_SFLOAT, 48);
  Attribute(4, VK_FORMAT_R32G32B32A32_UINT, 64);
  Attribute(5, VK_FORMAT_R32_SFLOAT, 80);
  FillChar(VertexInput, SizeOf(VertexInput), 0);
  VertexInput.sType := VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
  VertexInput.vertexBindingDescriptionCount := 1;
  VertexInput.pVertexBindingDescriptions := @Binding;
  VertexInput.vertexAttributeDescriptionCount := Length(Attributes);
  VertexInput.pVertexAttributeDescriptions := @Attributes[0];
  FillChar(Assembly, SizeOf(Assembly), 0);
  Assembly.sType := VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
  Assembly.topology := VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP;
  FillChar(ViewportState, SizeOf(ViewportState), 0);
  ViewportState.sType := VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
  ViewportState.viewportCount := 1;
  ViewportState.scissorCount := 1;
  FillChar(Raster, SizeOf(Raster), 0);
  Raster.sType := VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
  Raster.polygonMode := VK_POLYGON_MODE_FILL;
  Raster.cullMode := Ord(VK_CULL_MODE_NONE);
  Raster.frontFace := VK_FRONT_FACE_CLOCKWISE;
  Raster.lineWidth := 1;
  FillChar(Multisample, SizeOf(Multisample), 0);
  Multisample.sType := VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
  Multisample.rasterizationSamples := VK_SAMPLE_COUNT_1_BIT;
  // Premultiplied alpha: result = source + destination * (1 - source alpha).
  FillChar(Attachment, SizeOf(Attachment), 0);
  Attachment.blendEnable := Ord(ABlend);
  Attachment.srcColorBlendFactor := VK_BLEND_FACTOR_ONE;
  Attachment.dstColorBlendFactor := VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
  Attachment.colorBlendOp := VK_BLEND_OP_ADD;
  Attachment.srcAlphaBlendFactor := VK_BLEND_FACTOR_ONE;
  Attachment.dstAlphaBlendFactor := VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
  Attachment.alphaBlendOp := VK_BLEND_OP_ADD;
  if ADual then
  begin
    // ClearType: result = color + destination * (1 - weights), the weights per channel (second output).
    Attachment.dstColorBlendFactor := VK_BLEND_FACTOR_ONE_MINUS_SRC1_COLOR;
    Attachment.dstAlphaBlendFactor := VK_BLEND_FACTOR_ONE_MINUS_SRC1_ALPHA;
  end;
  Attachment.colorWriteMask := Ord(VK_COLOR_COMPONENT_R_BIT) or Ord(VK_COLOR_COMPONENT_G_BIT) or
    Ord(VK_COLOR_COMPONENT_B_BIT) or Ord(VK_COLOR_COMPONENT_A_BIT);
  FillChar(Blend, SizeOf(Blend), 0);
  Blend.sType := VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
  Blend.attachmentCount := 1;
  Blend.pAttachments := @Attachment;
  DynamicStates[0] := VK_DYNAMIC_STATE_VIEWPORT;
  DynamicStates[1] := VK_DYNAMIC_STATE_SCISSOR;
  FillChar(Dynamic, SizeOf(Dynamic), 0);
  Dynamic.sType := VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
  Dynamic.dynamicStateCount := Length(DynamicStates);
  Dynamic.pDynamicStates := @DynamicStates[0];
  Format := AFormat;
  FillChar(Rendering, SizeOf(Rendering), 0);
  Rendering.sType := VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO;
  Rendering.colorAttachmentCount := 1;
  Rendering.pColorAttachmentFormats := @Format;
  FillChar(Info, SizeOf(Info), 0);
  Info.sType := VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
  Info.pNext := @Rendering;
  Info.stageCount := Length(Stages);
  Info.pStages := @Stages[0];
  Info.pVertexInputState := @VertexInput;
  Info.pInputAssemblyState := @Assembly;
  Info.pViewportState := @ViewportState;
  Info.pRasterizationState := @Raster;
  Info.pMultisampleState := @Multisample;
  Info.pColorBlendState := @Blend;
  Info.pDynamicState := @Dynamic;
  Info.layout := FLayout;
  Info.basePipelineIndex := -1;
  Result := VK_NULL_HANDLE;
  C.Check(C.Vk.CreateGraphicsPipelines(C.Device, VK_NULL_HANDLE, 1, @Info, nil, @Result), 'vkCreateGraphicsPipelines');
end;

function TGpuVkRenderer.NewModule(const ACode: Pointer; const AWords: Integer): TVkShaderModule;
var
  C: TGpuVkContext;
  Info: TVkShaderModuleCreateInfo;
begin
  C := GpuVk;
  FillChar(Info, SizeOf(Info), 0);
  Info.sType := VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
  Info.codeSize := AWords * 4;
  Info.pCode := ACode;
  Result := VK_NULL_HANDLE;
  C.Check(C.Vk.CreateShaderModule(C.Device, @Info, nil, @Result), 'vkCreateShaderModule');
end;

procedure TGpuVkRenderer.CreatePipeline;
var
  C: TGpuVkContext;
  Sampler: TVkSamplerCreateInfo;
  Bindings: array[0..16] of TVkDescriptorSetLayoutBinding;
  SetInfo: TVkDescriptorSetLayoutCreateInfo;
  LayoutInfo: TVkPipelineLayoutCreateInfo;
  I, N: Integer;

  procedure Bind(const ABinding: Cardinal; const AType: TVkDescriptorType; const ASampler: PVkSampler = nil);
  begin
    Bindings[N].binding := ABinding;
    Bindings[N].descriptorType := AType;
    Bindings[N].descriptorCount := 1;
    // The same stages everywhere: consecutive bindings of one type are written by one VkWriteDescriptorSet.
    Bindings[N].stageFlags := Ord(VK_SHADER_STAGE_VERTEX_BIT) or Ord(VK_SHADER_STAGE_FRAGMENT_BIT);
    Bindings[N].pImmutableSamplers := ASampler;
    Inc(N);
  end;

begin
  C := GpuVk;
  // s0 linear clamp, s1 point clamp, s2 linear wrap (bitmap brushes in tile mode).
  for I := 0 to High(FSamplers) do
  begin
    FillChar(Sampler, SizeOf(Sampler), 0);
    Sampler.sType := VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
    if I = 1 then
    begin
      Sampler.magFilter := VK_FILTER_NEAREST;
      Sampler.minFilter := VK_FILTER_NEAREST;
      Sampler.mipmapMode := VK_SAMPLER_MIPMAP_MODE_NEAREST;
    end
    else
    begin
      Sampler.magFilter := VK_FILTER_LINEAR;
      Sampler.minFilter := VK_FILTER_LINEAR;
      Sampler.mipmapMode := VK_SAMPLER_MIPMAP_MODE_LINEAR;
    end;
    if I = 2 then
    begin
      Sampler.addressModeU := VK_SAMPLER_ADDRESS_MODE_REPEAT;
      Sampler.addressModeV := VK_SAMPLER_ADDRESS_MODE_REPEAT;
    end
    else
    begin
      Sampler.addressModeU := VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
      Sampler.addressModeV := VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    end;
    Sampler.addressModeW := VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    Sampler.maxAnisotropy := 1;
    Sampler.compareOp := VK_COMPARE_OP_NEVER;
    Sampler.maxLod := VK_LOD_CLAMP_NONE;
    Sampler.borderColor := VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK;
    C.Check(C.Vk.CreateSampler(C.Device, @Sampler, nil, @FSamplers[I]), 'vkCreateSampler');
  end;
  // Binding 0 the cbuffer, 16..23 Tex0..Tex7, 24 atlas, 25 ramps, 26..28 clips, paints, edges, 32..34 samplers
  // (tools\compile-shaders.ps1: b at 0, t at 16, s at 32).
  FillChar(Bindings, SizeOf(Bindings), 0);
  N := 0;
  Bind(0, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER);
  for I := 0 to GpuSlotCount + 1 do
    Bind(16 + I, VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE);
  for I := 0 to 2 do
    Bind(26 + I, VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER);
  for I := 0 to 2 do
    Bind(32 + I, VK_DESCRIPTOR_TYPE_SAMPLER, @FSamplers[I]);
  FillChar(SetInfo, SizeOf(SetInfo), 0);
  SetInfo.sType := VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
  SetInfo.bindingCount := N;
  SetInfo.pBindings := @Bindings[0];
  C.Check(C.Vk.CreateDescriptorSetLayout(C.Device, @SetInfo, nil, @FSetLayout), 'vkCreateDescriptorSetLayout');
  FillChar(LayoutInfo, SizeOf(LayoutInfo), 0);
  LayoutInfo.sType := VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
  LayoutInfo.setLayoutCount := 1;
  LayoutInfo.pSetLayouts := @FSetLayout;
  C.Check(C.Vk.CreatePipelineLayout(C.Device, @LayoutInfo, nil, @FLayout), 'vkCreatePipelineLayout');
  FVS := NewModule(@FastCanvasVkVS[0], Length(FastCanvasVkVS));
  FPS := NewModule(@FastCanvasVkPS[0], Length(FastCanvasVkPS));
  FPipeBlend := NewPipeline(VK_FORMAT_B8G8R8A8_UNORM, True, False);
  FPipeCopy := NewPipeline(VK_FORMAT_B8G8R8A8_UNORM, False, False);

  FAtlas := NewTexture(VK_FORMAT_R8_UNORM, GpuAtlasSize, GpuAtlasSize);
  FRamps := NewTexture(VK_FORMAT_R8G8B8A8_UNORM, GpuRampWidth, GpuRampRows);
  // The texture of a slot without one (and of a slot whose texture is the target).
  FEmpty := NewTexture(VK_FORMAT_B8G8R8A8_UNORM, 1, 1);
  FClips := NewTable(GpuMaxClips * GpuClipFloat4s);
  FPaints := NewTable(GpuMaxPaints * GpuPaintFloat4s);
  CreateEdgeTable(GpuEdgesInitial);
end;

function TGpuVkRenderer.TargetPipeline: TVkPipeline;
begin
  if FDual and not FCopy and GpuVk.Fast.DualSource then
  begin
    // ClearType text in the frame: everything blends with the second output (the same result for the rest).
    if FPipeDual = VK_NULL_HANDLE then
    begin
      if FPSDual = VK_NULL_HANDLE then
        FPSDual := NewModule(@FastCanvasVkPSDual[0], Length(FastCanvasVkPSDual));
      FPipeDual := NewPipeline(VK_FORMAT_B8G8R8A8_UNORM, True, True);
    end;
    Exit(FPipeDual);
  end;
  if FCopy then
    Result := FPipeCopy
  else
    Result := FPipeBlend;
end;

procedure TGpuVkRenderer.CreateEdgeTable(const ACapacity: Integer);
begin
  if FEdges.Buffer <> VK_NULL_HANDLE then
    ReleaseTable(FEdges);
  FEdges := NewTable(ACapacity);
  FEdgeCapacity := ACapacity;
  FEdgeLo := 0;
  FEdgeHi := 0;
end;

procedure TGpuVkRenderer.Invalidate;
begin
  // Something else recorded into the open command buffer (its pipeline and state may differ).
  FBoundGen := -1;
end;

procedure TGpuVkRenderer.BeginTarget(const ATarget: TGpuSurface; const AWidth, AHeight: Integer;
  const AAliased: Boolean);
begin
  if (ATarget = FTarget) and (AWidth = FWidth) and (AHeight = FHeight) and (AAliased = FAliased) then
    Exit;
  inherited;
  // The scissor depends on the target's size.
  FBoundW := -1;
end;

procedure TGpuVkRenderer.UploadTables;
var
  C: TGpuVkContext;
  Data: PSingle;
  First, Count: Integer;
begin
  C := GpuVk;
  Data := TakeClips(First, Count);
  if Count > 0 then
    C.CopyToBuffer(FClips.Buffer, FClips.Use, UInt64(First) * GpuClipFloat4s * 16, Data,
      NativeInt(Count) * GpuClipFloat4s * 16);
  UploadEdgeRange;
  if TakePaints(First, Count) then
    C.CopyToBuffer(FPaints.Buffer, FPaints.Use, UInt64(First) * GpuPaintFloat4s * 16, @FPaintData[First],
      NativeInt(Count) * GpuPaintFloat4s * 16);
end;

procedure TGpuVkRenderer.UploadEdgeRange;
begin
  if FEdgeHi <= FEdgeLo then
    Exit;
  GpuVk.CopyToBuffer(FEdges.Buffer, FEdges.Use, UInt64(FEdgeLo) * 16, @FEdgeData[0],
    NativeInt(FEdgeHi - FEdgeLo) * 16);
  FEdgeLo := 0;
  FEdgeHi := 0;
end;

/// <summary>The descriptor set of the draw: the one of the last draw when it holds the same (in the same command
/// buffer), else a new one.</summary>
function TGpuVkRenderer.DescriptorSet: TVkDescriptorSet;
var
  C: TGpuVkContext;
  Views: array[0..GpuSlotCount - 1] of TVkImageView;
  Images: array[0..GpuSlotCount + 1] of TVkDescriptorImageInfo;
  Texels: array[0..2] of TVkBufferView;
  Constants: TVkDescriptorBufferInfo;
  Writes: array[0..2] of TVkWriteDescriptorSet;
  S: TGpuSurface;
  Same: Boolean;
  I: Integer;
begin
  C := GpuVk;
  Same := (FSet <> VK_NULL_HANDLE) and (FSetGen = C.ListGen) and (FSetEdges = FEdges.View) and
    (FSetConstBuffer = FConstBuffer) and (FSetConst = FConstOffset);
  for I := 0 to GpuSlotCount - 1 do
  begin
    Views[I] := FEmpty.View;
    if I < FSlotCount then
    begin
      S := IGpuTexture(FSlotTex[I]).Surface;
      if (S <> nil) and (S <> FTarget) and (TGpuVkSurface(S).View <> VK_NULL_HANDLE) then
        Views[I] := TGpuVkSurface(S).View;
    end;
    if Views[I] <> FSetViews[I] then
      Same := False;
  end;
  if Same then
    Exit(FSet);
  Result := C.AllocSet(FSetLayout);
  for I := 0 to GpuSlotCount - 1 do
  begin
    Images[I].sampler := VK_NULL_HANDLE;
    Images[I].imageView := Views[I];
    Images[I].imageLayout := VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
  end;
  Images[GpuSlotCount].sampler := VK_NULL_HANDLE;
  Images[GpuSlotCount].imageView := FAtlas.View;
  Images[GpuSlotCount].imageLayout := VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
  Images[GpuSlotCount + 1].sampler := VK_NULL_HANDLE;
  Images[GpuSlotCount + 1].imageView := FRamps.View;
  Images[GpuSlotCount + 1].imageLayout := VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
  Texels[0] := FClips.View;
  Texels[1] := FPaints.View;
  Texels[2] := FEdges.View;
  Constants.buffer := FConstBuffer;
  Constants.offset := FConstOffset;
  Constants.range := SizeOf(TGpuFrameConstants);
  FillChar(Writes, SizeOf(Writes), 0);
  for I := 0 to High(Writes) do
  begin
    Writes[I].sType := VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    Writes[I].dstSet := Result;
  end;
  Writes[0].dstBinding := 0;
  Writes[0].descriptorCount := 1;
  Writes[0].descriptorType := VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
  Writes[0].pBufferInfo := @Constants;
  // Bindings 16..25 (the slots, atlas, ramps) and 26..28 in one write each: consecutive bindings of one type.
  Writes[1].dstBinding := 16;
  Writes[1].descriptorCount := Length(Images);
  Writes[1].descriptorType := VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE;
  Writes[1].pImageInfo := @Images[0];
  Writes[2].dstBinding := 26;
  Writes[2].descriptorCount := Length(Texels);
  Writes[2].descriptorType := VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER;
  Writes[2].pTexelBufferView := @Texels[0];
  C.Vk.UpdateDescriptorSets(C.Device, Length(Writes), @Writes[0], 0, nil);
  FSet := Result;
  FSetGen := C.ListGen;
  FSetEdges := FEdges.View;
  FSetConstBuffer := FConstBuffer;
  FSetConst := FConstOffset;
  for I := 0 to GpuSlotCount - 1 do
    FSetViews[I] := Views[I];
end;

procedure TGpuVkRenderer.DrawPending;
var
  C: TGpuVkContext;
  Target: TGpuVkSurface;
  Bytes: NativeInt;
  P: PByte;
  Buffer: TVkBuffer;
  Offset: UInt64;
  K: TGpuFrameConstants;
  Set_: TVkDescriptorSet;
  Cmd: TVkCommandBuffer;
  Pipe: TVkPipeline;
  Viewport: TVkViewport;
  Scissor: TVkRect2D;
  S: TGpuSurface;
  I: Integer;
begin
  if (FPendingCount = 0) or (FTarget = nil) or (TGpuVkSurface(FTarget).Image = VK_NULL_HANDLE) then
  begin
    FPendingCount := 0;
    Exit;
  end;
  C := GpuVk;
  Target := TGpuVkSurface(FTarget);
  UploadTables;
  Bytes := NativeInt(FPendingCount) * GpuInstanceStride;
  P := C.Upload(Bytes, 16, Buffer, Offset);
  Move(FPending[0], P^, Bytes);
  // The constants once per command buffer, and when they change.
  if FFrameDirty or (FConstGen <> C.ListGen) then
  begin
    K := FrameConstants;
    P := C.Upload(SizeOf(K), C.UniformAlign, FConstBuffer, FConstOffset);
    Move(K, P^, SizeOf(K));
    FConstGen := C.ListGen;
    FFrameDirty := False;
  end;
  // Everything the draw reads in the state it needs (the barriers go before rendering begins).
  for I := 0 to FSlotCount - 1 do
  begin
    S := IGpuTexture(FSlotTex[I]).Surface;
    if (S <> nil) and (S <> FTarget) then
      TGpuVkSurface(S).Use(TGpuVkUse.ShaderRead);
  end;
  C.Transition(FAtlas.Image, FAtlas.Use, TGpuVkUse.ShaderRead);
  C.Transition(FRamps.Image, FRamps.Use, TGpuVkUse.ShaderRead);
  C.BufferUse(FClips.Use, TGpuVkUse.ShaderRead);
  C.BufferUse(FPaints.Use, TGpuVkUse.ShaderRead);
  C.BufferUse(FEdges.Use, TGpuVkUse.ShaderRead);
  Set_ := DescriptorSet;
  C.BeginRendering(Target);
  Cmd := C.Cmd;
  if (FBoundGen <> C.ListGen) or (C.Owner <> Self) then
  begin
    C.Owner := Self;
    FBoundGen := C.ListGen;
    FBoundPipe := VK_NULL_HANDLE;
    FBoundW := -1;
  end;
  // By the kind of draw (blend, copy, dual-source).
  Pipe := TargetPipeline;
  if Pipe <> FBoundPipe then
  begin
    C.Vk.CmdBindPipeline(Cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, Pipe);
    FBoundPipe := Pipe;
  end;
  if (FBoundW <> FWidth) or (FBoundH <> FHeight) then
  begin
    // Negative height: y down, as the shaders' clip space expects (Direct3D's).
    Viewport.x := 0;
    Viewport.y := FHeight;
    Viewport.width := FWidth;
    Viewport.height := -FHeight;
    Viewport.minDepth := 0;
    Viewport.maxDepth := 1;
    C.Vk.CmdSetViewport(Cmd, 0, 1, @Viewport);
    Scissor.offset.x := 0;
    Scissor.offset.y := 0;
    Scissor.extent.width := Max(0, Min(FWidth, Target.Width));
    Scissor.extent.height := Max(0, Min(FHeight, Target.Height));
    C.Vk.CmdSetScissor(Cmd, 0, 1, @Scissor);
    FBoundW := FWidth;
    FBoundH := FHeight;
  end;
  C.Vk.CmdBindDescriptorSets(Cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, FLayout, 0, 1, @Set_, 0, nil);
  C.Vk.CmdBindVertexBuffers(Cmd, 0, 1, @Buffer, @Offset);
  C.Vk.CmdDraw(Cmd, 4, FPendingCount, 0, 0);
  Inc(FDrawCalls);
  FPendingCount := 0;
end;

procedure TGpuVkRenderer.Clear(const AColor: Cardinal);
var
  K: TVkClearColorValue;
  I: Integer;
begin
  Flush;
  if (FTarget = nil) or (TGpuVkSurface(FTarget).Image = VK_NULL_HANDLE) then
    Exit;
  // The target holds premultiplied colors.
  K.float32[3] := (AColor shr 24) / 255;
  K.float32[0] := ((AColor shr 16) and $FF) / 255;
  K.float32[1] := ((AColor shr 8) and $FF) / 255;
  K.float32[2] := (AColor and $FF) / 255;
  if FTarget.Linear then
    for I := 0 to 2 do
      if K.float32[I] <= 0.04045 then
        K.float32[I] := K.float32[I] / 12.92
      else
        K.float32[I] := Power((K.float32[I] + 0.055) / 1.055, 2.4);
  for I := 0 to 2 do
    K.float32[I] := K.float32[I] * K.float32[3];
  GpuVk.BeginRendering(TGpuVkSurface(FTarget), @K);
end;

procedure TGpuVkRenderer.FillCopy(const ARect: TRectF; const AColor: Cardinal; const AClip: Cardinal);
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

procedure TGpuVkRenderer.UploadRamp(const ARow: Integer; const AData: Pointer);
begin
  GpuVk.CopyToImage(FRamps.Image, FRamps.Use, 4, 0, ARow, GpuRampWidth, 1, AData, GpuRampWidth * 4);
end;

procedure TGpuVkRenderer.UploadGlyph(const X, Y, W, H: Integer; const AData: Pointer; const APitch: Integer);
begin
  GpuVk.CopyToImage(FAtlas.Image, FAtlas.Use, 1, X, Y, W, H, AData, APitch);
end;

{ TGpuVkBackend }

class function TGpuVkBackend.CreateRenderer: TGpuRenderer;
begin
  Result := TGpuVkRenderer.Create;
end;

class function TGpuVkBackend.CreateSurface(const AWidth, AHeight: Integer; const AData: Pointer;
  const APitch: Integer): TGpuSurface;
begin
  Result := TGpuVkSurface.Create(AWidth, AHeight, AData, APitch);
end;

class function TGpuVkBackend.CreateWindow(const AWnd: HWND; const ALayered: Boolean): TGpuWindow;
begin
  Result := TGpuVkWindow.Create(AWnd, ALayered);
end;

class procedure TGpuVkBackend.Submit;
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

class procedure TGpuVkBackend.WaitIdle;
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

class procedure TGpuVkBackend.Shutdown;
begin
  TFastDevice.Lock;
  try
    FreeAndNil(GCtx);
  finally
    TFastDevice.Unlock;
  end;
end;

end.
