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
  the context ends before every copy or barrier and begins again for the next draw (loading the target); a clear of
  a whole target waits to be the load operation of its next instance (a frame's clear and draws in one render pass).

  Devices without these features (Vulkan 1.1 phones; FASTCANVAS_VK_LEGACY=1, FASTCANVAS_VK_NOTIMELINE=1 on others):
  without synchronization2 a batch of barriers becomes one vkCmdPipelineBarrier (the union of the batch's stages, the
  same access masks and layouts: the bits used here have the same values in both) and submissions go through
  vkQueueSubmit (timeline values in VkTimelineSemaphoreSubmitInfo); without dynamic rendering a rendering instance is
  a render pass of the same attachments, load and store operations and layouts (TFastVulkan.RenderPass) with a
  framebuffer of the target's views (made once, destroyed with the views); without timeline semaphores every
  submission signals a fence of its own (TGpuVkTimeline), whose order on the queue gives the values.

  The pipeline: one descriptor set layout (binding 0 the cbuffer Frame, 16..23 the textures of a draw, 24 atlas,
  25 ramps, 26..28 clips, paints and edges as uniform texel buffers, 32..34 the three immutable samplers) and three
  pipelines (blending, copy, dual-source blending) with the SPIR-V of FastCanvas.VkShaders.inc. On GPUs other than
  discrete ones (phones) blending draws are split into runs of variants of the pixel shader that leave out what the
  run's instances do not need (TGpuVkVariant), and large rectangle outlines are drawn around their inside (scissors).
  A draw takes a descriptor set of the current pool (made again only when its textures or constants change); the
  instances and the frame constants go into the upload pages. The shaders do not flip clip space for Vulkan: the
  viewport does (negative height), so pixel coordinates are those of Direct3D. FASTCANVAS_VK_GPUTIME reports the GPU
  time of the render passes and presented copies per frame (timestamps).

  Windows: frames are drawn into a surface of the window (TGpuVkSurface), which keeps the frame (RestoreLast,
  Capture) and which transparent windows read back. Present hands the surface to the window's presenting thread
  (TGpuVkPresenter) and takes the one it showed before for the next frame (a partial frame starts from a copy of the
  shown one); the thread acquires a swap chain image, copies the newest frame into it (blit when the sizes or formats
  differ) and presents it: the render thread waits neither for the display nor for the driver's
  acquire and present (measured 2026-10-14 on the RX 9070 XT: text light without tearing 3800 FPS against 60 with
  FIFO on the render thread; with tearing 4900 against 3400 with IMMEDIATE on the render thread). The mode: IMMEDIATE
  when tearing is allowed, else MAILBOX, else FIFO_LATEST_READY (the AMD driver offers no MAILBOX), else FIFO, which
  wait for the refresh on the presenting thread only: frames come as fast as with Direct3D 12 presenting with sync
  interval 0. The swap chain is made again when the frame's size or the tearing changes, or when Vulkan reports it
  out of date or suboptimal. Vulkan windows present to the window itself (opaque, as Flip): no DirectComposition. No
  HDR yet (CreateHdrSurface returns nil, windows are 8-bit).

  Android and Linux: the surface is made from the native window (ANativeWindow) or the X11 window of the handle, and
  presented to by the window's thread as on Windows. A surface that is lost (Android takes the native window away
  when the app goes to the background) ends the presenting thread and is dropped at the next frame, which is not
  presented; FMX makes the canvas again for the next native window. On Android the swap chain takes the frame's size
  unrotated (the compositor rotates it) and is not made again for being suboptimal, presents with FIFO unless tearing
  is asked for, and Present waits until the thread has taken the frame before: the frames keep the display's pace, as
  when the render thread presented (FMX paints as often as its timers ask). }

interface

uses
  {$IFDEF MSWINDOWS}Winapi.Windows, {$ENDIF}System.SysUtils, System.Types, System.Math, System.Classes,
  System.SyncObjs, System.Generics.Collections, Vulkan, FastCanvas.Device, FastCanvas.DeviceVk, FastCanvas.Gpu;

const
  /// <summary>Window frames the GPU may have queued: Present waits for the frame this many before, as the presenting
  /// thread does for its copy.</summary>
  FramesInFlight = 3;

  // Stages and accesses of synchronization2 (64-bit masks; the header's enumerations hold only their low 32 bits).
  StageNone = UInt64(0);
  StageVertexInput = UInt64($4);
  StageVertexShader = UInt64($8);
  StageFragmentShader = UInt64($80);
  StageEarlyTests = UInt64($100);
  StageLateTests = UInt64($200);
  StageColorOutput = UInt64($400);
  StageComputeShader = UInt64($800);
  StageTransfer = UInt64($1000);
  StageHost = UInt64($4000);
  StageAllCommands = UInt64($10000);
  StageAccelerationBuild = UInt64($02000000);
  AccessShaderRead = UInt64($20);
  AccessShaderWrite = UInt64($40);
  AccessColorRead = UInt64($80);
  AccessColorWrite = UInt64($100);
  AccessDepthRead = UInt64($200);
  AccessDepthWrite = UInt64($400);
  AccessTransferRead = UInt64($800);
  AccessTransferWrite = UInt64($1000);
  AccessHostRead = UInt64($2000);
  AccessAccelerationRead = UInt64($00200000);
  AccessAccelerationWrite = UInt64($00400000);

type
  TGpuVkSurface = class;
  TGpuVkWindow = class;

  {$SCOPEDENUMS ON}
  /// <summary>What an image (or a table buffer) is used for next: its layout, and the stages and accesses barriers
  /// wait for and make visible. DepthTarget and DepthRead: depth and stencil images (the 3D context). Present: a swap
  /// chain image a frame was drawn into (TGpuVkWindow with Direct), for the presentation engine.</summary>
  TGpuVkUse = (Undefined, ShaderRead, ColorTarget, TransferSrc, TransferDst, DepthTarget, DepthRead, Present);

  /// <summary>Kinds of Vulkan objects that Retire keeps until the GPU is done with them (Memory: a TFastVkAllocation).
  /// </summary>
  TGpuVkObject = (Image, ImageView, Memory, Buffer, BufferView, Pipeline, PipelineLayout, SetLayout, Sampler,
    ShaderModule, Semaphore, AccelerationStructure, DescriptorPool);
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

  TGpuVkFenceValue = record
    Fence: TVkFence;
    Value: UInt64;
  end;

  /// <summary>Values the submissions of a queue signal one after the other, and how far the GPU has come: a timeline
  /// semaphore, or where the device has none (TFastVulkan.TimelineSemaphore) a fence per submission (the fences of
  /// one queue are signaled in submission order). Used by one thread at a time.</summary>
  TGpuVkTimeline = class
  private
    FFast: TFastVulkan;
    FSemaphore: TVkSemaphore;
    FSignaled, FDone: UInt64;
    /// <summary>Fences: of submissions not known to be done (by value), and free ones.</summary>
    FPending: TList<TGpuVkFenceValue>;
    FFree: TList<TVkFence>;
  public
    constructor Create(const AFast: TFastVulkan);
    /// <summary>The GPU has to be done with the submissions.</summary>
    destructor Destroy; override;
    /// <summary>The value of the next submission (Signaled from now on) and the fence it signals (VK_NULL_HANDLE with
    /// a semaphore: it signals the value of Semaphore).</summary>
    function Next(out AFence: TVkFence): UInt64;
    /// <summary>The last value the GPU has reached (all of them on a lost device).</summary>
    function Completed: UInt64;
    /// <summary>Waits until the GPU has reached AValue (or the device is lost).</summary>
    procedure Wait(const AValue: UInt64);
    /// <summary>The timeline semaphore; VK_NULL_HANDLE with fences.</summary>
    property Semaphore: TVkSemaphore read FSemaphore;
    property Signaled: UInt64 read FSignaled;
  end;

  /// <summary>GPU timing (FASTCANVAS_VK_GPUTIME): the timestamps of a command buffer of the recording context, at its
  /// start, around each rendering instance and at its end; Value: its submission (0: free).</summary>
  TGpuVkTimeSlot = record
    Value: UInt64;
    Count: Integer;
  end;

  /// <summary>A depth buffer of the canvas's targets of one size (opaque interiors, TGpuVkSurface.WantDepth): cleared
  /// when a rendering instance begins and never stored, so targets of the same size share it.</summary>
  TGpuVkDepth = record
    Width, Height: Integer;
    Image: TVkImage;
    Memory: TFastVkAllocation;
    View: TVkImageView;
    Use: TGpuVkUse;
    /// <summary>The command buffer that used it last (ListGen), for dropping the oldest of several sizes.</summary>
    Gen: Integer;
  end;

  /// <summary>The views and size a framebuffer is made for (devices without dynamic rendering).</summary>
  TGpuVkFramebufferKey = packed record
    Pass: TVkRenderPass;
    Color, Depth: TVkImageView;
    Width, Height: Cardinal;
  end;

  /// <summary>Command recording on the queue of the device; with the device lock held.</summary>
  TGpuVkContext = class
  private
    FFast: TFastVulkan;
    FVk: TVulkan;
    FDevice: TVkDevice;
    FQueue: TVkQueue;
    FTimeline: TGpuVkTimeline;
    FSignaled: UInt64;
    FCmd: TGpuVkCommands;
    FOpen: Boolean;
    FListGen: Integer;
    FCommands: TQueue<TGpuVkCommands>;
    FBarriers: TArray<TVkImageMemoryBarrier2>;
    FBarrierCount: Integer;
    /// <summary>Without synchronization2: the batch as Vulkan 1.0 barriers.</summary>
    FLegacyBarriers: TArray<TVkImageMemoryBarrier>;
    /// <summary>Without dynamic rendering: framebuffers by views and size, and how many there are of each view (they
    /// go when it goes).</summary>
    FFramebuffers: TDictionary<TGpuVkFramebufferKey, TVkFramebuffer>;
    FFramebufferViews: TDictionary<TVkImageView, Integer>;
    // The global memory barrier of the batch (table buffers, host reads).
    FMemSrcStage, FMemSrcAccess, FMemDstStage, FMemDstAccess: UInt64;
    FPage: TGpuVkPage;
    FBusyPages, FFreePages: TList<TGpuVkPage>;
    FRetired: TList<TGpuVkRetired>;
    FPool: TGpuVkPool;
    FPoolSets: Integer;
    FBusyPools: TList<TGpuVkPool>;
    FFreePools: TList<TVkDescriptorPool>;
    /// <summary>What the active rendering instance draws into: a surface of the canvas, or the object another
    /// renderer began it for (BeginRenderingInfo); nil: none.</summary>
    FRendering: TObject;
    /// <summary>A clear of a whole surface not recorded yet (BeginRendering): it becomes the load operation of the
    /// surface's next rendering instance, so that a frame's clear and draws take one render pass (a tiler writes
    /// and reads the frame once less), or is recorded before anything else uses the surface (FlushClear).</summary>
    FClearSurface: TGpuVkSurface;
    FClearColor: TVkClearColorValue;
    /// <summary>A swap chain image acquired for the frame (TGpuVkWindow with Direct) signals this binary semaphore:
    /// the next submission waits for it before its color output (the commands that use the image are in it or
    /// later).</summary>
    FAcquireWait: TVkSemaphore;
    /// <summary>GPU timing (FASTCANVAS_VK_GPUTIME): the query pool, the slot of the open command buffer (-1: not
    /// timed), the next slot, whether a rendering instance's start was stamped.</summary>
    FTimePool: TVkQueryPool;
    FTimeSlots: array of TGpuVkTimeSlot;
    FTimeSlot, FTimeNext: Integer;
    FTimePass: Boolean;
    FSurfaces: TList<TGpuVkSurface>;
    FWindows: TList<TGpuVkWindow>;
    FUniformAlign: Integer;
    FOwner: TObject;
    /// <summary>Opaque interiors: the depth buffers by size; the active rendering instance has one (its draws number
    /// their instances from DepthCount on).</summary>
    FDepths: TArray<TGpuVkDepth>;
    FRenderingDepth: Boolean;
    FDepthCount: Cardinal;
    /// <summary>The depth buffer of a target of this size (made on first use; at most a few sizes are kept).</summary>
    function TargetDepth(const AWidth, AHeight: Integer): Integer;
    procedure Open;
    function Completed: UInt64;
    function TakePage(const ASize: NativeInt): TGpuVkPage;
    procedure FreePage(const APage: TGpuVkPage);
    procedure NextPool;
    /// <summary>Begins rendering as AInfo describes: dynamic rendering, else the render pass and framebuffer of the
    /// same (AColorFormat, ASamples: of the color attachment).</summary>
    procedure StartRendering(const AInfo: TVkRenderingInfo; const AColorFormat: TVkFormat; const ASamples: Integer);
    /// <summary>Begins rendering into ATarget (AClear: cleared first), after the barriers so far.</summary>
    procedure StartTarget(const ATarget: TGpuVkSurface; const AClear: PVkClearColorValue);
    /// <summary>Records the deferred clear (FClearSurface), if any.</summary>
    procedure FlushClear;
    /// <summary>GPU timing: on with FASTCANVAS_VK_GPUTIME where the queue has timestamps.</summary>
    procedure StartTiming;
    /// <summary>GPU timing: a timestamp into the slot of the open command buffer.</summary>
    procedure TimeStamp(const AStage: TVkPipelineStageFlagBits);
    /// <summary>GPU timing: the results of the slots whose submissions are done into the sums.</summary>
    procedure CollectTimes(const ADone: UInt64);
    /// <summary>The framebuffer of AColor (and ADepth) for render passes compatible with APass.</summary>
    function Framebuffer(const APass: TVkRenderPass; const AColor, ADepth: TVkImageView;
      const AExtent: TVkExtent2D): TVkFramebuffer;
    /// <summary>The framebuffers of an image view go (the view is destroyed now).</summary>
    procedure DropFramebuffers(const AView: TVkImageView);
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
    /// <summary>Destroys AHandle now (the GPU does not use it).</summary>
    procedure DestroyObject(const AKind: TGpuVkObject; const AHandle: UInt64);
    /// <summary>Records a layout change of an image (issued by FlushBarriers, before the next command). ADiscard:
    /// the content is not kept (the next command replaces all of it).</summary>
    procedure Transition(const AImage: TVkImage; var AUse: TGpuVkUse; const ANew: TGpuVkUse;
      const ADiscard: Boolean = False; const ARange: PVkImageSubresourceRange = nil);
    /// <summary>An image barrier as given (swap chain images: the acquire semaphore's stage). ARange: nil for the
    /// color of the first mip level.</summary>
    procedure ImageBarrier(const AImage: TVkImage; const ASrcStage, ASrcAccess, ADstStage, ADstAccess: UInt64;
      const AOld, ANew: TVkImageLayout; const ARange: PVkImageSubresourceRange = nil);
    /// <summary>Barriers are recorded but not issued yet.</summary>
    function HasBarriers: Boolean; inline;
    /// <summary>Records a change of use of a buffer (a global memory barrier).</summary>
    procedure BufferUse(var AUse: TGpuVkUse; const ANew: TGpuVkUse);
    procedure MemoryBarrier(const ASrcStage, ASrcAccess, ADstStage, ADstAccess: UInt64);
    procedure FlushBarriers;
    /// <summary>ASize bytes of upload memory for the open command buffer: the CPU address; ABuffer and AOffset for
    /// the GPU.</summary>
    function Upload(const ASize: NativeInt; const AAlign: Integer; out ABuffer: TVkBuffer; out AOffset: UInt64): PByte;
    /// <summary>Copies rows of pixels into a mip level of an image (records the copy; the image is left in
    /// TransferDst: an image with mip levels is moved there by the caller, with all of them).</summary>
    procedure CopyToImage(const AImage: TVkImage; var AUse: TGpuVkUse; const ABytesPerPixel, X, Y, W, H: Integer;
      const AData: Pointer; const APitch: Integer; const ALevel: Integer = 0);
    procedure CopyToBuffer(const ABuffer: TVkBuffer; var AUse: TGpuVkUse; const AOffset: UInt64; const AData: Pointer;
      const ASize: NativeInt);
    /// <summary>Fills a whole image with one color (the image is left in TransferDst).</summary>
    procedure ClearImage(const AImage: TVkImage; var AUse: TGpuVkUse; const AColor: TVkClearColorValue);
    /// <summary>A device-local image with a view of all of it (of AAspect).</summary>
    function NewImage(const AFormat: TVkFormat; const AWidth, AHeight: Integer; const AUsage: TVkImageUsageFlags;
      out AMemory: TFastVkAllocation; out AView: TVkImageView; const AMips: Integer = 1; const ASamples: Integer = 1;
      const AAspect: TVkImageAspectFlags = Ord(VK_IMAGE_ASPECT_COLOR_BIT); const ALazy: Boolean = False): TVkImage;
    /// <summary>A buffer and its memory (ARequired, APreferred: see TFastVulkan.MemoryType; host-visible memory is
    /// mapped: AMemory.Cpu).</summary>
    function NewBuffer(const ASize: UInt64; const AUsage: TVkBufferUsageFlags; const ARequired,
      APreferred: TVkMemoryPropertyFlags; out AMemory: TFastVkAllocation): TVkBuffer;
    /// <summary>The device address of a buffer (buffer device address).</summary>
    function BufferAddress(const ABuffer: TVkBuffer): UInt64;
    /// <summary>A descriptor set of ALayout for the open command buffer.</summary>
    function AllocSet(const ALayout: TVkDescriptorSetLayout): TVkDescriptorSet;
    /// <summary>Rendering into ATarget (begun if it is not the current one, after the barriers so far); AClear: the
    /// whole target is filled with that color first (deferred to the next rendering into ATarget, see FClearSurface:
    /// no rendering instance is begun then).</summary>
    procedure BeginRendering(const ATarget: TGpuVkSurface; const AClear: PVkClearColorValue = nil);
    /// <summary>Rendering of another renderer (the 3D context), identified by AOwner (Rendering): the active one ends
    /// and the barriers so far are issued first. AColorFormat, ASamples: of the color attachment (render passes);
    /// depth and stencil are in the device's DepthFormat.</summary>
    procedure BeginRenderingInfo(const AOwner: TObject; const AInfo: TVkRenderingInfo; const AColorFormat: TVkFormat;
      const ASamples: Integer);
    procedure EndRendering;
    /// <summary>What the active rendering instance draws into (a canvas surface, another renderer's object), nil
    /// outside rendering.</summary>
    property Rendering: TObject read FRendering;
    /// <summary>The active rendering instance of a canvas surface has a depth buffer (cleared to 1 at its start).
    /// </summary>
    property RenderingDepth: Boolean read FRenderingDepth;
    /// <summary>Instances numbered for their depth in the active rendering instance so far (the renderer counts on).
    /// </summary>
    property DepthCount: Cardinal read FDepthCount write FDepthCount;
    /// <summary>Clears the depth buffer of the active rendering instance (when the instance numbers run out).
    /// </summary>
    procedure ClearDepth;
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
    FFormat: TVkFormat;
    /// <summary>A swap chain image (CreateChain): the surface owns its view only.</summary>
    FBorrowed: Boolean;
    FReadback: TVkBuffer;
    FReadbackMemory: TFastVkAllocation;
    FReadbackData: PByte;
    /// <summary>The read-back copy holds the current content (no GPU write since it was taken).</summary>
    FReadbackValid: Boolean;
    /// <summary>Its rendering instances have a depth buffer (opaque interiors; set by the renderer before the first).
    /// </summary>
    FWantDepth: Boolean;
    /// <summary>Destroys the Vulkan objects at once: the context shuts down (the GPU is idle) while the surface
    /// lives on (a bitmap freed after the canvas).</summary>
    procedure Drop(const AContext: TGpuVkContext);
  public
    constructor Create(const AWidth, AHeight: Integer; const AData: Pointer; const APitch: Integer);
    /// <summary>A surface of a swap chain image of AFormat (8-bit UNORM, BGRA or RGBA), in no layout yet.</summary>
    constructor CreateChain(const AImage: TVkImage; const AFormat: TVkFormat; const AWidth, AHeight: Integer);
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
    /// <summary>B8G8R8A8_UNORM, or a swap chain's format.</summary>
    property Format: TVkFormat read FFormat;
    /// <summary>The use the image is in (render thread).</summary>
    property State: TGpuVkUse read FUse;
    property WantDepth: Boolean read FWantDepth write FWantDepth;
  end;

  TGpuVkPresenter = class;

  TGpuVkWindow = class(TGpuWindow)
  private
    /// <summary>The surface frames are drawn into; Present makes it FShown and takes the one FShown was for the next
    /// frame. FDrawn: it holds the frame drawn last; FLastShown: FShown holds it (RestoreLast copies it from there).
    /// </summary>
    FSurface: TGpuVkSurface;
    FDrawn, FLastShown: Boolean;
    FVkSurface: TVkSurfaceKHR;
    /// <summary>The present modes the window's surface offers.</summary>
    FModes: TArray<TVkPresentModeKHR>;
    /// <summary>The thread that presents, and the surface of the newest frame it presents from (resting in
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
    /// <summary>Direct (FASTCANVAS_VK_DIRECT=1): frames are drawn into the images of a swap chain of the render
    /// thread: Prepare acquires one, Present presents it; no presenting thread, no copy of the frame, no partial frames
    /// (FMX repaints the whole form on Android anyway). Not the default: on a Mali-G57 the render passes into the swap
    /// chain's images took 0.9 ms more per frame than the presenting thread's copy (0.7 ms, 2026-10-14). Decided at the
    /// first frame; a frame without a swap chain image (no native window, a timeout) is drawn into the window's surface
    /// and not shown.</summary>
    FDirect, FDirectChecked: Boolean;
    FChain: TVkSwapchainKHR;
    FChainExtent: TVkExtent2D;
    /// <summary>Surfaces of the images, and per image the semaphore its frame's submission signals for the present.
    /// </summary>
    FChainImages: TArray<TGpuVkSurface>;
    FChainPresent: TArray<TVkSemaphore>;
    /// <summary>Per frame in flight: the semaphore the acquire signals (its last wait is done once the frame's
    /// submission FramesInFlight frames before is).</summary>
    FChainAcquire: array[0..FramesInFlight - 1] of TVkSemaphore;
    /// <summary>The image acquired for the frame; held: acquired and not presented yet (a frame that was not
    /// presented leaves it to the next one).</summary>
    FChainIndex: Cardinal;
    FChainHeld, FChainStale: Boolean;
    /// <summary>The Vulkan surface of the platform's window and the present modes it offers; False when the window
    /// cannot have one now (Android: no native window).</summary>
    function CreateVkSurface: Boolean;
    /// <summary>The present mode for the tearing asked for (the presenting thread's swap chains and direct ones).
    /// </summary>
    function PresentMode: TVkPresentModeKHR;
    /// <summary>Direct: the swap chain for frames of this size (made again when it changed or is stale); False when
    /// there is none (no size, the surface lost, a format the pipelines do not draw into: Direct goes off).</summary>
    function DirectChain(const AWidth, AHeight: Integer): Boolean;
    /// <summary>Direct: the swap chain and its images, semaphores go (the GPU is waited for).</summary>
    procedure ReleaseDirectChain;
    /// <summary>Direct: the surface of an acquired image for the frame; nil when there is none.</summary>
    function DirectPrepare(const AWidth, AHeight: Integer): TGpuSurface;
    function DirectPresent: HResult;
    /// <summary>The surface is lost: the presenting thread ends and the surface goes (made again at the next frame).
    /// </summary>
    procedure DropSurface;
    function HasMode(const AMode: TVkPresentModeKHR): Boolean;
    procedure StopPresenter;
    /// <summary>Destroys the Vulkan objects at once (the context shuts down).</summary>
    procedure Drop(const AContext: TGpuVkContext);
  public
    constructor Create(const AHandle: TGpuWindowHandle; const ALayered: Boolean); override;
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
  /// (recorded once per image and frame size) and timeline (TGpuVkTimeline); it takes the queue lock to submit and
  /// present, never the device lock.</summary>
  TGpuVkPresenter = class(TThread)
  private
    FWindow: TGpuVkWindow;
    FFast: TFastVulkan;
    FVk: TVulkan;
    FDevice: TVkDevice;
    FWake: TEvent;
    /// <summary>Guards the hand-over: FShown (the window's), FShownGen, FPending, FStaleAsked, FSurfaceLost.
    /// </summary>
{$IFDEF MSWINDOWS}
    FLock: TRTLCriticalSection;
{$ELSE}
    FLock: TObject;
{$ENDIF}
    FShownGen: Integer;
    FPending, FStaleAsked: Boolean;
    /// <summary>Set when FPending goes from True to False (the frame was taken: its swap chain image acquired, or it
    /// was dropped); reset under FLock by WaitTaken.</summary>
    FTaken: TEvent;
    /// <summary>The window's surface was lost (Android took the native window away): the swap chain is gone and
    /// nothing is presented any more; the window drops the surface at its next frame.</summary>
    FSurfaceLost: Boolean;
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
    /// <summary>GPU timing (FASTCANVAS_VK_GPUTIME): two timestamps around the copy of each image's command buffer,
    /// and whether they were recorded.</summary>
    FTimePool: TVkQueryPool;
    FTimed: TArray<Boolean>;
    FTimeline: TGpuVkTimeline;
    FValue: UInt64;
    FStale: Boolean;
    FCheckedW, FCheckedH: Integer;
    procedure WaitValue(const AValue: UInt64);
    procedure ReleaseChain(const ADestroyOld: Boolean);
    function CreateChain(const AWidth, AHeight: Integer): Boolean;
    /// <summary>The surface is lost: the swap chain goes, FSurfaceLost is set.</summary>
    procedure LoseSurface;
    procedure Record_(const AIndex: Integer; const AShown: TGpuVkSurface);
    /// <summary>Presents the pending frame; False when there was none or it could not be presented.</summary>
    function PresentPending: Boolean;
    procedure Release;
  protected
    procedure Execute; override;
  public
    constructor Create(const AWindow: TGpuVkWindow);
    destructor Destroy; override;
    /// <summary>The lock of the hand-over (FLock).</summary>
    procedure Lock;
    procedure Unlock;
    /// <summary>Render thread: FShown holds a new frame (submitted).</summary>
    procedure Post;
    /// <summary>Render thread: waits at most ATimeoutMs until the frame posted last has been taken (with FIFO the
    /// acquire waits for the display, so the frames keep its pace).</summary>
    procedure WaitTaken(const ATimeoutMs: Cardinal);
    /// <summary>The window's surface was lost (see FSurfaceLost).</summary>
    function SurfaceLost: Boolean;
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

  {$SCOPEDENUMS ON}
  /// <summary>The variants of the pixel shader for blending draws (Shaders\FastCanvas.hlsl, the WITH_ switches):
  /// shapes with gradients, glyphs, images, all three (controls), shapes and paths with gradients, each with and
  /// without the clip test, and the full shader.</summary>
  TGpuVkVariant = (Shapes, ShapesClip, Glyphs, GlyphsClip, Images, ImagesClip, Ui, UiClip, Paths, PathsClip, Full);
  /// <summary>What a pipeline draws: a quad per instance (the canvas's draws), opaque interiors (triangles in pixels
  /// with a color per vertex), paths as triangles of local positions with their instance.</summary>
  TGpuVkGeometry = (Quads, Interiors, Meshes);
  {$SCOPEDENUMS OFF}

  /// <summary>A vertex of an opaque interior (shader VSInterior): target pixels and depth, a premultiplied color.
  /// </summary>
  TGpuVkInteriorVertex = packed record
    X, Y, Z: Single;
    R, G, B, A: Single;
  end;
  PGpuVkInteriorVertex = ^TGpuVkInteriorVertex;

  /// <summary>A piece of a path (FastCanvas.PathMesh.TPathPiece): a trapezoid in local units.</summary>
  TGpuVkPiece = record
    Y0, Y1, L0, R0, L1, R1: Single;
  end;

  /// <summary>The pieces of a pending path instance (Index): Cover cover pieces from First in the renderer's pieces,
  /// then Solid solid ones; Vertex: the first of its triangles in the draw's upload (UploadMeshes).</summary>
  TGpuVkMeshRef = record
    Index, First, Cover, Solid, Vertex: Integer;
  end;

  TGpuVkRenderer = class(TGpuRenderer)
  private
    FSamplers: array[0..2] of TVkSampler;
    FSetLayout: TVkDescriptorSetLayout;
    FLayout: TVkPipelineLayout;
    FVS, FPS, FPSDual: TVkShaderModule;
    /// <summary>The pipelines by the format of the target (TargetSlot: 0 B8G8R8A8, the canvas's surfaces; 1 R8G8B8A8,
    /// swap chain images frames are drawn into, TGpuVkWindow with Direct; 2 and 3 the same with a depth buffer, for
    /// opaque interiors), made on first use but slot 0's blend and copy. Dual: dual-source blending (ClearType text),
    /// none without the feature.</summary>
    FPipeBlend, FPipeCopy, FPipeDual: array[0..3] of TVkPipeline;
    /// <summary>Opaque interiors (FASTCANVAS_VK_INTERIORS, on where the variants are): large targets get a depth buffer
    /// (TGpuVkSurface.WantDepth); the opaque interiors of filled rectangles with a solid color or a linear gradient
    /// are drawn first, front to back without blending (FInteriorPipes, per format), and every instance after them
    /// with the depth test (the variants' pipelines of slots 2 and 3, vertex shader FVSFlatZ), so that a pixel under
    /// an opaque interior of its own instance or a later one is not shaded.</summary>
    FInteriors: Boolean;
    FVSFlatZ, FVSInterior, FPSInterior: TVkShaderModule;
    FInteriorPipes: array[0..1] of TVkPipeline;
    FInteriorData: TArray<TGpuVkInteriorVertex>;
    /// <summary>Ramp rows as uploaded (straight RGBA), and whether a row is opaque and linear over its length within
    /// a level (a linear gradient of it is interpolated per vertex in an interior).</summary>
    FRampTexels: array of array[0..GpuRampWidth - 1] of Cardinal;
    FRampLinear: array of Boolean;
    /// <summary>Paths as pieces (FASTCANVAS_VK_PATHMESH, with the opaque interiors): the pending paths' pieces
    /// (AddMesh). On a target with the depth buffer such a path is drawn as its cover pieces (FMeshPipes: the
    /// instance with the triangles' local positions, FVSMeshZ, the depth test and writes) instead of the quad, which
    /// leaves out the pixels of its bounds that no edge comes near and that it does not cover; an opaque one's solid
    /// pieces are drawn with the interiors.</summary>
    FMeshRefs: TArray<TGpuVkMeshRef>;
    FMeshRefCount: Integer;
    FMeshPieces: TArray<TGpuVkPiece>;
    FMeshPieceCount: Integer;
    FVSMeshZ: TVkShaderModule;
    FMeshPipes: array[0..1, TGpuVkVariant] of TVkPipeline;
    /// <summary>DrawPending: the paths with pieces are drawn by them (runs end before them).</summary>
    FRunStopMesh: Boolean;
    /// <summary>Blending draws in runs of the cheapest variant that fits, with the vertex shader that hands the table
    /// entries to the pixel shader (FVSFlat; the full shader of these runs is FastCanvasVkPSFlat): on GPUs other than
    /// discrete ones, with FASTCANVAS_VK_VARIANTS=1 on any, with 0 on none (the full shader, FPipeBlend). Modules and
    /// pipelines are made on first use.</summary>
    FVariants: Boolean;
    FVSFlat: TVkShaderModule;
    FVariantPS: array[TGpuVkVariant] of TVkShaderModule;
    FVariantPipes: array[0..3, TGpuVkVariant] of TVkPipeline;
    /// <summary>A run is split when that saves more than this of pixels times variant cost (see DrawPending).
    /// </summary>
    FSplitCost: Single;
    FAtlas, FRamps, FEmpty: TGpuVkImage;
    FClips, FPaints, FEdges: TGpuVkTable;
    FCopy: Boolean;
    // What is bound on the open command buffer (ListGen).
    FBoundGen: Integer;
    FBoundPipe: TVkPipeline;
    FBoundW, FBoundH: Integer;
    FBoundScissor: TRect;
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
    /// <summary>APixel: the pixel shader module (entry PSMain, PSInterior for interiors); VK_NULL_HANDLE: FPS, or FPSDual
    /// when ADual. AVertex: the vertex shader module; VK_NULL_HANDLE: FVS. ADepth: 0 no depth buffer, 1 one without the
    /// test, 2 the test (less), 3 the test and writes.</summary>
    function NewPipeline(const AFormat: TVkFormat; const ABlend, ADual: Boolean;
      const APixel: TVkShaderModule = VK_NULL_HANDLE; const AVertex: TVkShaderModule = VK_NULL_HANDLE;
      const ADepth: Integer = 0; const AGeometry: TGpuVkGeometry = TGpuVkGeometry.Quads): TVkPipeline;
    function TargetSlot: Integer;
    /// <summary>The instance has an opaque solid color or a linear gradient whose ramp is opaque and linear (ARow; -1
    /// for a solid color), and no clip test: its interior can be drawn without blending.</summary>
    function InteriorPaint(const AInstance: PGpuInstance; out ARow: Integer): Boolean;
    /// <summary>A vertex of an interior at the local position (X, Y): False where a gradient clamps.</summary>
    function InteriorVertex(const AInstance: PGpuInstance; const ARow: Integer; const X, Y, AZ: Single;
      var AOut: PGpuVkInteriorVertex): Boolean;
    /// <summary>The opaque interior of a pending instance as two triangles (6 vertices at AOut) with the depth AZ:
    /// filled rectangles (rounded ones inside their corners) with an opaque solid color or a linear gradient whose ramp
    /// is linear and that covers the interior without clamping, and no clip test. False for others.</summary>
    function InteriorOf(const AInstance: PGpuInstance; const AZ: Single; const AOut: PGpuVkInteriorVertex): Boolean;
    /// <summary>The solid pieces of a path (mesh reference ARef) as triangles at AOut: their vertex count (0 for a
    /// path that is not opaque).</summary>
    function MeshInterior(const AInstance: PGpuInstance; const ARef: Integer; const AZ: Single;
      const AOut: PGpuVkInteriorVertex): Integer;
    /// <summary>The cover pieces of the draw's paths into upload memory; False when there are none.</summary>
    function UploadMeshes(out ABuffer: TVkBuffer; out AOffset: UInt64): Boolean;
    function MeshPipeline(const AVariant: TGpuVkVariant): TVkPipeline;
    /// <summary>Pass one of a draw on a depth target: the opaque interiors of the pending instances, front to back.
    /// </summary>
    procedure DrawInteriors(const ABase: Cardinal);
    function TargetPipeline: TVkPipeline;
    function VariantPipeline(const AVariant: TGpuVkVariant): TVkPipeline;
    /// <summary>The pending instance is a rectangle outline with an inside large enough to leave out of its draw
    /// (TGpuRenderer.HollowBands): the rectangles around it.</summary>
    function Hollow(const AIndex: Integer; out ABands: TGpuBands; out ACount: Integer): Boolean;
    /// <summary>The pending instances from AFirst on that one draw takes (at least one), and its variant.</summary>
    function NextRun(const AFirst: Integer; out AVariant: TGpuVkVariant): Integer;
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
    procedure AddMesh(const APieces: Pointer; const ACover, ASolid: Integer); override;
  end;

  TGpuVkBackend = class(TGpuBackend)
  public
    class function CreateRenderer: TGpuRenderer; override;
    class function CreateSurface(const AWidth, AHeight: Integer; const AData: Pointer;
      const APitch: Integer): TGpuSurface; override;
    class function CreateWindow(const AHandle: TGpuWindowHandle; const ALayered: Boolean): TGpuWindow; override;
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
/// <summary>The subresources of the first mip level's color.</summary>
function ColorRange: TVkImageSubresourceRange;
function ColorLayers: TVkImageSubresourceLayers;

var
  /// <summary>Set by the 3D context: the recording context shuts down (the GPU is idle; device lock held): every
  /// Vulkan object made outside it goes now.</summary>
  GpuVkShutdownHook: procedure(const AContext: TGpuVkContext);

implementation

uses
{$IFDEF MSWINDOWS}
  Winapi.DxgiType,
{$ENDIF}
{$IFDEF ANDROID}
  Androidapi.Log,
{$ENDIF}
  System.Diagnostics;

{$IFNDEF MSWINDOWS}
const
  DXGI_ERROR_DEVICE_REMOVED = FastDeviceRemoved;
{$ENDIF}

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

  UseLayout: array[TGpuVkUse] of TVkImageLayout = (VK_IMAGE_LAYOUT_UNDEFINED,
    VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
    VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
    VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL, VK_IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL,
    VK_IMAGE_LAYOUT_PRESENT_SRC_KHR);
  UseStage: array[TGpuVkUse] of UInt64 = (StageNone, StageFragmentShader, StageColorOutput, StageTransfer,
    StageTransfer, StageEarlyTests or StageLateTests, StageFragmentShader or StageEarlyTests or StageLateTests,
    StageNone);
  UseAccess: array[TGpuVkUse] of UInt64 = (0, AccessShaderRead, AccessColorRead or AccessColorWrite,
    AccessTransferRead, AccessTransferWrite, AccessDepthRead or AccessDepthWrite, AccessShaderRead or AccessDepthRead,
    0);
  /// <summary>The writes of a use, which a barrier makes available.</summary>
  UseWrites: array[TGpuVkUse] of UInt64 = (0, 0, AccessColorWrite, 0, AccessTransferWrite, AccessDepthWrite, 0, 0);

  /// <summary>What each variant of the pixel shader draws (GpuNeed*), and what a pixel of it costs, relatively: the
  /// cycles of its longest path on a Mali-G57 (Mali Offline Compiler), the full shader's doubled for its registers
  /// (half the threads).</summary>
  VariantNeeds: array[TGpuVkVariant] of Cardinal = (GpuNeedShapes or GpuNeedGradients,
    GpuNeedShapes or GpuNeedGradients or GpuNeedClips, GpuNeedGlyphs, GpuNeedGlyphs or GpuNeedClips, GpuNeedImages,
    GpuNeedImages or GpuNeedClips, GpuNeedShapes or GpuNeedGradients or GpuNeedGlyphs or GpuNeedImages,
    GpuNeedShapes or GpuNeedGradients or GpuNeedGlyphs or GpuNeedImages or GpuNeedClips,
    GpuNeedShapes or GpuNeedGradients or GpuNeedPaths,
    GpuNeedShapes or GpuNeedGradients or GpuNeedPaths or GpuNeedClips, GpuNeedAll);
  VariantCost: array[TGpuVkVariant] of Single = (3, 4.5, 1, 2.5, 2.5, 4, 4, 6, 4.5, 6, 12);
  VariantVariable = 'FASTCANVAS_VK_VARIANTS';
  DirectVariable = 'FASTCANVAS_VK_DIRECT';
  /// <summary>The formats of TGpuVkRenderer.TargetSlot (slots 2 and 3 with a depth buffer).</summary>
  SlotFormats: array[0..3] of TVkFormat = (VK_FORMAT_B8G8R8A8_UNORM, VK_FORMAT_R8G8B8A8_UNORM,
    VK_FORMAT_B8G8R8A8_UNORM, VK_FORMAT_R8G8B8A8_UNORM);
  InteriorVariable = 'FASTCANVAS_VK_INTERIORS';
  PathMeshVariable = 'FASTCANVAS_VK_PATHMESH';
  /// <summary>Depth numbers of a rendering instance (shader InstanceDepth: 1 - n / 2^22).</summary>
  DepthNumbers = 4194304;
  /// <summary>Targets with at least this many pixels get a depth buffer for opaque interiors.</summary>
  DepthMinPixels = 256 * 256;

  /// <summary>GPU timing: 1 for the platform's log (Android: logcat, tag FastCanvas; Windows: OutputDebugString), else
  /// a file the report lines are appended to.</summary>
  GpuTimeVariable = 'FASTCANVAS_VK_GPUTIME';
  /// <summary>GPU timing: command buffers in flight that are timed, and timestamps each (its start and end, and 15
  /// rendering instances; the ones after those are not timed).</summary>
  TimeSlots = 64;
  TimeSlotQueries = 32;

var
  GCtx: TGpuVkContext;
  /// <summary>The cheapest variant that draws instances of these needs (TGpuVkRenderer.Create fills it).</summary>
  GVariantOf: array[0..GpuNeedAll] of TGpuVkVariant;
  /// <summary>GPU timing: where it goes ('' off), nanoseconds per tick and the mask of the valid bits of timestamps;
  /// since the last report: window frames, timed rendering instances and command buffers and their nanoseconds,
  /// rendering instances not timed (render thread, device lock); presented copies and their nanoseconds (presenting
  /// threads, atomic).</summary>
  GTimeTarget: string;
  GTimePeriod: Double;
  GTimeMask: UInt64;
  GTimeFrames, GTimePasses, GTimeUntimed, GTimeCmds: Integer;
  GTimePassNs, GTimeCmdNs: Double;
  GTimeCopies, GTimeCopyNs: Int64;
  GTimeLast: Int64;

/// <summary>GPU timing: a report line.</summary>
procedure TimingOutput(const AText: string);
var
  F: TextFile;
begin
  if GTimeTarget = '1' then
  begin
{$IF Defined(ANDROID)}
    __android_log_write(android_LogPriority.ANDROID_LOG_INFO, 'FastCanvas', MarshaledAString(UTF8String(AText)));
{$ELSEIF Defined(MSWINDOWS)}
    OutputDebugString(PChar(AText));
{$ELSE}
    Writeln(ErrOutput, AText);
{$ENDIF}
    Exit;
  end;
  AssignFile(F, GTimeTarget);
  try
    if FileExists(GTimeTarget) then
      Append(F)
    else
      Rewrite(F);
    try
      Writeln(F, AText);
    finally
      CloseFile(F);
    end;
  except
    // A development aid only.
  end;
end;

/// <summary>GPU timing: one more window frame; every two seconds the GPU time per frame since the last report.
/// </summary>
procedure TimingFrame;
var
  Now, Copies: Int64;
  N: Integer;
  CopyNs: Double;
begin
  Inc(GTimeFrames);
  Now := TStopwatch.GetTimeStamp;
  if GTimeLast = 0 then
    GTimeLast := Now;
  if Now - GTimeLast < 2 * TStopwatch.Frequency then
    Exit;
  N := Max(GTimeFrames, 1);
  Copies := TInterlocked.Exchange(GTimeCopies, 0);
  CopyNs := TInterlocked.Exchange(GTimeCopyNs, 0);
  TimingOutput(Format('FastCanvas GPU time per frame (%d frames in %.1f s): rendering %.2f ms (%.1f render passes, ' +
    '%d not timed), command buffers %.2f ms (%.1f), presented copies %.2f ms (%.1f)', [GTimeFrames,
    (Now - GTimeLast) / TStopwatch.Frequency, GTimePassNs / 1E6 / N, GTimePasses / N, GTimeUntimed,
    GTimeCmdNs / 1E6 / N, GTimeCmds / N, CopyNs / 1E6 / N, Copies / N], TFormatSettings.Invariant));
  GTimeLast := Now;
  GTimeFrames := 0;
  GTimePasses := 0;
  GTimeUntimed := 0;
  GTimeCmds := 0;
  GTimePassNs := 0;
  GTimeCmdNs := 0;
end;

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

/// <summary>Stages of synchronization2 as those of Vulkan 1.0 (the stages used here have the same bits in both);
/// ANone where there are none (TOP_OF_PIPE for a source, BOTTOM_OF_PIPE for a destination).</summary>
function LegacyStages(const AStages: UInt64; const ANone: TVkPipelineStageFlagBits): TVkPipelineStageFlags; inline;
begin
  Result := TVkPipelineStageFlags(AStages and $FFFFFFFF);
  if Result = 0 then
    Result := Ord(ANone);
end;

/// <summary>Records one image barrier: synchronization2, or vkCmdPipelineBarrier with the same masks and layouts.
/// </summary>
procedure CmdImageBarrier(const AFast: TFastVulkan; const ACmd: TVkCommandBuffer;
  const ABarrier: TVkImageMemoryBarrier2);
var
  Dep: TVkDependencyInfo;
  B: TVkImageMemoryBarrier;
begin
  if AFast.Synchronization2 then
  begin
    FillChar(Dep, SizeOf(Dep), 0);
    Dep.sType := VK_STRUCTURE_TYPE_DEPENDENCY_INFO;
    Dep.imageMemoryBarrierCount := 1;
    Dep.pImageMemoryBarriers := @ABarrier;
    AFast.Vk.CmdPipelineBarrier2(ACmd, @Dep);
    Exit;
  end;
  FillChar(B, SizeOf(B), 0);
  B.sType := VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
  B.srcAccessMask := TVkAccessFlags(ABarrier.srcAccessMask and $FFFFFFFF);
  B.dstAccessMask := TVkAccessFlags(ABarrier.dstAccessMask and $FFFFFFFF);
  B.oldLayout := ABarrier.oldLayout;
  B.newLayout := ABarrier.newLayout;
  B.srcQueueFamilyIndex := ABarrier.srcQueueFamilyIndex;
  B.dstQueueFamilyIndex := ABarrier.dstQueueFamilyIndex;
  B.image := ABarrier.image;
  B.subresourceRange := ABarrier.subresourceRange;
  AFast.Vk.CmdPipelineBarrier(ACmd, LegacyStages(ABarrier.srcStageMask, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT),
    LegacyStages(ABarrier.dstStageMask, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT), 0, 0, nil, 0, nil, 1, @B);
end;

/// <summary>Submits ACmd (VK_NULL_HANDLE: no command buffer) to the queue; the caller holds the queue lock. Waits for
/// AWait (a binary semaphore, VK_NULL_HANDLE: none) at AWaitStage, signals ASignal (binary, or none) and AValue of
/// ATimeline: its semaphore, or AFence. vkQueueSubmit2 with synchronization2, else vkQueueSubmit (the value in
/// VkTimelineSemaphoreSubmitInfo).</summary>
function QueueSubmit(const AFast: TFastVulkan; const ACmd: TVkCommandBuffer; const AWait: TVkSemaphore;
  const AWaitStage: UInt64; const ASignal: TVkSemaphore; const ATimeline: TGpuVkTimeline; const AValue: UInt64;
  const AFence: TVkFence): TVkResult;
var
  Info2: TVkSubmitInfo2;
  CmdInfo: TVkCommandBufferSubmitInfo;
  Wait2: TVkSemaphoreSubmitInfo;
  Signals2: array[0..1] of TVkSemaphoreSubmitInfo;
  Info: TVkSubmitInfo;
  TimelineInfo: TVkTimelineSemaphoreSubmitInfo;
  Signals, Waits: array[0..1] of TVkSemaphore;
  Values: array[0..1] of UInt64;
  WaitStage: TVkPipelineStageFlags;
  Cmd: TVkCommandBuffer;
  I, N: Integer;
begin
  N := 0;
  if ATimeline.Semaphore <> VK_NULL_HANDLE then
  begin
    Signals[N] := ATimeline.Semaphore;
    Values[N] := AValue;
    Inc(N);
  end;
  if ASignal <> VK_NULL_HANDLE then
  begin
    Signals[N] := ASignal;
    Values[N] := 0;
    Inc(N);
  end;
  Cmd := ACmd;
  if AFast.Synchronization2 then
  begin
    FillChar(Info2, SizeOf(Info2), 0);
    Info2.sType := VK_STRUCTURE_TYPE_SUBMIT_INFO_2;
    if Cmd <> VK_NULL_HANDLE then
    begin
      FillChar(CmdInfo, SizeOf(CmdInfo), 0);
      CmdInfo.sType := VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO;
      CmdInfo.commandBuffer := Cmd;
      Info2.commandBufferInfoCount := 1;
      Info2.pCommandBufferInfos := @CmdInfo;
    end;
    if AWait <> VK_NULL_HANDLE then
    begin
      FillChar(Wait2, SizeOf(Wait2), 0);
      Wait2.sType := VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO;
      Wait2.semaphore := AWait;
      Wait2.stageMask := AWaitStage;
      Info2.waitSemaphoreInfoCount := 1;
      Info2.pWaitSemaphoreInfos := @Wait2;
    end;
    FillChar(Signals2, SizeOf(Signals2), 0);
    for I := 0 to N - 1 do
    begin
      Signals2[I].sType := VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO;
      Signals2[I].semaphore := Signals[I];
      Signals2[I].value := Values[I];
      Signals2[I].stageMask := StageAllCommands;
    end;
    Info2.signalSemaphoreInfoCount := N;
    if N > 0 then
      Info2.pSignalSemaphoreInfos := @Signals2[0];
    Exit(AFast.Vk.QueueSubmit2(AFast.Queue, 1, @Info2, AFence));
  end;
  FillChar(Info, SizeOf(Info), 0);
  Info.sType := VK_STRUCTURE_TYPE_SUBMIT_INFO;
  if Cmd <> VK_NULL_HANDLE then
  begin
    Info.commandBufferCount := 1;
    Info.pCommandBuffers := @Cmd;
  end;
  if AWait <> VK_NULL_HANDLE then
  begin
    Waits[0] := AWait;
    WaitStage := LegacyStages(AWaitStage, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT);
    Info.waitSemaphoreCount := 1;
    Info.pWaitSemaphores := @Waits[0];
    Info.pWaitDstStageMask := @WaitStage;
  end;
  Info.signalSemaphoreCount := N;
  if N > 0 then
    Info.pSignalSemaphores := @Signals[0];
  if ATimeline.Semaphore <> VK_NULL_HANDLE then
  begin
    // A value per signaled semaphore (the binary one's is ignored); the wait is on a binary semaphore.
    FillChar(TimelineInfo, SizeOf(TimelineInfo), 0);
    TimelineInfo.sType := VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO;
    TimelineInfo.signalSemaphoreValueCount := N;
    TimelineInfo.pSignalSemaphoreValues := @Values[0];
    Info.pNext := @TimelineInfo;
  end;
  Result := AFast.Vk.QueueSubmit(AFast.Queue, 1, @Info, AFence);
end;

{ TGpuVkTimeline }

constructor TGpuVkTimeline.Create(const AFast: TFastVulkan);
var
  TypeInfo: TVkSemaphoreTypeCreateInfo;
  Info: TVkSemaphoreCreateInfo;
begin
  inherited Create;
  FFast := AFast;
  FPending := TList<TGpuVkFenceValue>.Create;
  FFree := TList<TVkFence>.Create;
  if not FFast.TimelineSemaphore then
    Exit;
  FillChar(TypeInfo, SizeOf(TypeInfo), 0);
  TypeInfo.sType := VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO;
  TypeInfo.semaphoreType := VK_SEMAPHORE_TYPE_TIMELINE;
  TypeInfo.initialValue := 0;
  FillChar(Info, SizeOf(Info), 0);
  Info.sType := VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
  Info.pNext := @TypeInfo;
  FFast.Check(FFast.Vk.CreateSemaphore(FFast.Device, @Info, nil, @FSemaphore), 'vkCreateSemaphore (timeline)');
end;

destructor TGpuVkTimeline.Destroy;
var
  F: TGpuVkFenceValue;
  Fence: TVkFence;
begin
  if FFast <> nil then
  begin
    if FSemaphore <> VK_NULL_HANDLE then
      FFast.Vk.DestroySemaphore(FFast.Device, FSemaphore, nil);
    if FPending <> nil then
      for F in FPending do
        FFast.Vk.DestroyFence(FFast.Device, F.Fence, nil);
    if FFree <> nil then
      for Fence in FFree do
        FFast.Vk.DestroyFence(FFast.Device, Fence, nil);
  end;
  FPending.Free;
  FFree.Free;
  inherited;
end;

function TGpuVkTimeline.Next(out AFence: TVkFence): UInt64;
var
  Info: TVkFenceCreateInfo;
  F: TGpuVkFenceValue;
begin
  AFence := VK_NULL_HANDLE;
  if FSemaphore = VK_NULL_HANDLE then
  begin
    // Fences of submissions done are free again.
    Completed;
    if FFree.Count > 0 then
    begin
      AFence := FFree.Last;
      FFree.Delete(FFree.Count - 1);
    end
    else
    begin
      FillChar(Info, SizeOf(Info), 0);
      Info.sType := VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
      FFast.Check(FFast.Vk.CreateFence(FFast.Device, @Info, nil, @AFence), 'vkCreateFence');
    end;
    F.Fence := AFence;
    F.Value := FSignaled + 1;
    FPending.Add(F);
  end;
  Inc(FSignaled);
  Result := FSignaled;
end;

function TGpuVkTimeline.Completed: UInt64;
var
  Res: TVkResult;
  Fence: TVkFence;
begin
  // A lost device never completes: everything counts as done.
  if FSemaphore <> VK_NULL_HANDLE then
  begin
    if Ord(FFast.Track(FFast.Vk.GetSemaphoreCounterValue(FFast.Device, FSemaphore, @Result))) < 0 then
      Result := FSignaled;
    Exit;
  end;
  if FFast.Lost then
    Exit(FSignaled);
  while FPending.Count > 0 do
  begin
    Fence := FPending[0].Fence;
    Res := FFast.Track(FFast.Vk.GetFenceStatus(FFast.Device, Fence));
    if Res = VK_NOT_READY then
      Break;
    if Res <> VK_SUCCESS then
      Exit(FSignaled);
    FDone := FPending[0].Value;
    FPending.Delete(0);
    FFast.Vk.ResetFences(FFast.Device, 1, @Fence);
    FFree.Add(Fence);
  end;
  Result := FDone;
end;

procedure TGpuVkTimeline.Wait(const AValue: UInt64);
var
  Info: TVkSemaphoreWaitInfo;
  Value: UInt64;
  Fence: TVkFence;
  Res: TVkResult;
  I: Integer;
begin
  if (AValue = 0) or (AValue > FSignaled) or (Completed >= AValue) then
    Exit;
  if FSemaphore <> VK_NULL_HANDLE then
  begin
    Value := AValue;
    FillChar(Info, SizeOf(Info), 0);
    Info.sType := VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO;
    Info.semaphoreCount := 1;
    Info.pSemaphores := @FSemaphore;
    Info.pValues := @Value;
    // In slices, to notice a lost device.
    repeat
      Res := FFast.Track(FFast.Vk.WaitSemaphores(FFast.Device, @Info, WaitSlice));
    until (Res <> VK_TIMEOUT) or FFast.Lost;
    Exit;
  end;
  // The fence of the first submission with that value or a later one.
  Fence := VK_NULL_HANDLE;
  for I := 0 to FPending.Count - 1 do
    if FPending[I].Value >= AValue then
    begin
      Fence := FPending[I].Fence;
      Break;
    end;
  if Fence = VK_NULL_HANDLE then
    Exit;
  repeat
    Res := FFast.Track(FFast.Vk.WaitForFences(FFast.Device, 1, @Fence, VK_TRUE, WaitSlice));
  until (Res <> VK_TIMEOUT) or FFast.Lost;
  Completed;
end;

{ TGpuVkContext }

constructor TGpuVkContext.Create;
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
  FFramebuffers := TDictionary<TGpuVkFramebufferKey, TVkFramebuffer>.Create;
  FFramebufferViews := TDictionary<TVkImageView, Integer>.Create;
  SetLength(FBarriers, 16);
  FTimeSlot := -1;
  StartTiming;
  try
    FTimeline := TGpuVkTimeline.Create(FFast);
  except
    on E: EFastVulkan do
      raise EFastDevice.Create(E.Message);
  end;
end;

destructor TGpuVkContext.Destroy;
var
  P: TGpuVkPage;
  R: TGpuVkRetired;
  Pool: TGpuVkPool;
  D: TVkDescriptorPool;
  W: TGpuVkWindow;
  S: TGpuVkSurface;
  Fb: TVkFramebuffer;
  I: Integer;
begin
  WaitIdle;
  // The 3D context lets go of what it made on the device (textures FMX still holds, pipelines).
  if Assigned(GpuVkShutdownHook) then
    GpuVkShutdownHook(Self);
  // Presentation too: swap chains and their semaphores go now.
  if FTimePool <> VK_NULL_HANDLE then
    FVk.DestroyQueryPool(FDevice, FTimePool, nil);
  FTimePool := VK_NULL_HANDLE;
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
  FreeAndNil(FTimeline);
  for I := 0 to High(FDepths) do
  begin
    DestroyObject(TGpuVkObject.ImageView, FDepths[I].View);
    DestroyObject(TGpuVkObject.Image, FDepths[I].Image);
    DestroyObject(TGpuVkObject.Memory, MemoryHandle(FDepths[I].Memory));
  end;
  FDepths := nil;
  for Fb in FFramebuffers.Values do
    FVk.DestroyFramebuffer(FDevice, Fb, nil);
  FFramebuffers.Free;
  FFramebufferViews.Free;
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

procedure TGpuVkContext.StartTiming;
var
  Count: Cardinal;
  Families: TArray<TVkQueueFamilyProperties>;
  Bits: Cardinal;
  Info: TVkQueryPoolCreateInfo;
begin
  GTimeTarget := GetEnvironmentVariable(GpuTimeVariable);
  if GTimeTarget = '' then
    Exit;
  Count := 0;
  FFast.InstanceVk.GetPhysicalDeviceQueueFamilyProperties(FFast.Physical, @Count, nil);
  SetLength(Families, Count);
  if Count > 0 then
    FFast.InstanceVk.GetPhysicalDeviceQueueFamilyProperties(FFast.Physical, @Count, @Families[0]);
  Bits := 0;
  if FFast.QueueFamily < Count then
    Bits := Families[FFast.QueueFamily].timestampValidBits;
  if Bits = 0 then
  begin
    TimingOutput('FastCanvas GPU time: the queue has no timestamps');
    GTimeTarget := '';
    Exit;
  end;
  if Bits >= 64 then
    GTimeMask := High(UInt64)
  else
    GTimeMask := (UInt64(1) shl Bits) - 1;
  GTimePeriod := FFast.Properties.limits.timestampPeriod;
  FillChar(Info, SizeOf(Info), 0);
  Info.sType := VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO;
  Info.queryType := VK_QUERY_TYPE_TIMESTAMP;
  Info.queryCount := TimeSlots * TimeSlotQueries;
  Check(FVk.CreateQueryPool(FDevice, @Info, nil, @FTimePool), 'vkCreateQueryPool');
  SetLength(FTimeSlots, TimeSlots);
end;

procedure TGpuVkContext.TimeStamp(const AStage: TVkPipelineStageFlagBits);
begin
  FVk.CmdWriteTimestamp(FCmd.Buffer, AStage, FTimePool, FTimeSlot * TimeSlotQueries + FTimeSlots[FTimeSlot].Count);
  Inc(FTimeSlots[FTimeSlot].Count);
end;

procedure TGpuVkContext.CollectTimes(const ADone: UInt64);
var
  Q: array[0..TimeSlotQueries - 1] of UInt64;
  I, K, N: Integer;
begin
  for I := 0 to High(FTimeSlots) do
    if (FTimeSlots[I].Value <> 0) and (FTimeSlots[I].Value <= ADone) then
    begin
      N := FTimeSlots[I].Count;
      FTimeSlots[I].Value := 0;
      if (N < 2) or (FVk.GetQueryPoolResults(FDevice, FTimePool, I * TimeSlotQueries, N, SizeOf(Q), @Q[0],
        SizeOf(UInt64), Ord(VK_QUERY_RESULT_64_BIT)) <> VK_SUCCESS) then
        Continue;
      // The start, pairs around rendering instances, the end.
      GTimeCmdNs := GTimeCmdNs + ((Q[N - 1] - Q[0]) and GTimeMask) * GTimePeriod;
      Inc(GTimeCmds);
      K := 1;
      while K + 1 <= N - 2 do
      begin
        GTimePassNs := GTimePassNs + ((Q[K + 1] - Q[K]) and GTimeMask) * GTimePeriod;
        Inc(GTimePasses);
        Inc(K, 2);
      end;
    end;
end;

procedure TGpuVkContext.Check(const ARes: TVkResult; const AWhat: string);
begin
  if Ord(FFast.Track(ARes)) < 0 then
    raise EFastDevice.CreateFmt('FastCanvas: %s failed (%d)', [AWhat, Ord(ARes)]);
end;

function TGpuVkContext.Completed: UInt64;
begin
  if FTimeline = nil then
    Exit(FSignaled);
  Result := FTimeline.Completed;
end;

procedure TGpuVkContext.DestroyObject(const AKind: TGpuVkObject; const AHandle: UInt64);
begin
  if AHandle = VK_NULL_HANDLE then
    Exit;
  case AKind of
    TGpuVkObject.Image: FVk.DestroyImage(FDevice, AHandle, nil);
    TGpuVkObject.ImageView:
      begin
        if (FFramebufferViews <> nil) and FFramebufferViews.ContainsKey(AHandle) then
          DropFramebuffers(AHandle);
        FVk.DestroyImageView(FDevice, AHandle, nil);
      end;
    TGpuVkObject.Memory: FFast.Release(TFastVkAllocation(NativeUInt(AHandle)));
    TGpuVkObject.Buffer: FVk.DestroyBuffer(FDevice, AHandle, nil);
    TGpuVkObject.BufferView: FVk.DestroyBufferView(FDevice, AHandle, nil);
    TGpuVkObject.Pipeline: FVk.DestroyPipeline(FDevice, AHandle, nil);
    TGpuVkObject.PipelineLayout: FVk.DestroyPipelineLayout(FDevice, AHandle, nil);
    TGpuVkObject.SetLayout: FVk.DestroyDescriptorSetLayout(FDevice, AHandle, nil);
    TGpuVkObject.Sampler: FVk.DestroySampler(FDevice, AHandle, nil);
    TGpuVkObject.ShaderModule: FVk.DestroyShaderModule(FDevice, AHandle, nil);
    TGpuVkObject.Semaphore: FVk.DestroySemaphore(FDevice, AHandle, nil);
    TGpuVkObject.AccelerationStructure: FVk.DestroyAccelerationStructureKHR(FDevice, AHandle, nil);
    TGpuVkObject.DescriptorPool: FVk.DestroyDescriptorPool(FDevice, AHandle, nil);
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
  if FTimePool <> VK_NULL_HANDLE then
  begin
    // A slot whose last command buffer is not done (many in flight) leaves this one untimed.
    FTimeSlot := FTimeNext;
    FTimeNext := (FTimeNext + 1) mod TimeSlots;
    if FTimeSlots[FTimeSlot].Value <> 0 then
      FTimeSlot := -1
    else
    begin
      FTimeSlots[FTimeSlot].Count := 0;
      FVk.CmdResetQueryPool(FCmd.Buffer, FTimePool, FTimeSlot * TimeSlotQueries, TimeSlotQueries);
      TimeStamp(VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT);
    end;
  end;
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
  Wait: TVkSemaphore;
  WaitStage: UInt64;
  Opened: Boolean;
  I: Integer;
  P: TGpuVkPage;
  R: TGpuVkRetired;
  Pool: TGpuVkPool;
  Res: TVkResult;
  Fence: TVkFence;
  Buffer: TVkCommandBuffer;
begin
  EndRendering;
  if (FBarrierCount > 0) or (FMemDstStage <> 0) or (FMemSrcStage <> 0) then
    FlushBarriers;
  Opened := FOpen;
  if not Opened and (AWait = VK_NULL_HANDLE) and (ASignal = VK_NULL_HANDLE) then
    Exit(0);
  Wait := AWait;
  WaitStage := AWaitStage;
  if (Wait = VK_NULL_HANDLE) and (FAcquireWait <> VK_NULL_HANDLE) then
  begin
    Wait := FAcquireWait;
    WaitStage := StageColorOutput;
    FAcquireWait := VK_NULL_HANDLE;
  end;
  Buffer := VK_NULL_HANDLE;
  if Opened then
  begin
    FOpen := False;
    if FTimeSlot >= 0 then
      TimeStamp(VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT);
    Check(FVk.EndCommandBuffer(FCmd.Buffer), 'vkEndCommandBuffer');
    Buffer := FCmd.Buffer;
  end;
  try
    FSignaled := FTimeline.Next(Fence);
  except
    on E: EFastVulkan do
      raise EFastDevice.Create(E.Message);
  end;
  FFast.LockQueue;
  try
    Res := QueueSubmit(FFast, Buffer, Wait, WaitStage, ASignal, FTimeline, FSignaled, Fence);
  finally
    FFast.UnlockQueue;
  end;
  // The work of a refused submission is gone (and the timeline never reaches its value): the device is made again.
  if Ord(Res) < 0 then
    FFast.Track(VK_ERROR_DEVICE_LOST);
  Result := FSignaled;
  if Opened then
  begin
    if FTimeSlot >= 0 then
      FTimeSlots[FTimeSlot].Value := FSignaled;
    FTimeSlot := -1;
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
    raise EFastDevice.CreateFmt('FastCanvas: the submission to the Vulkan queue failed (%d)', [Ord(Res)]);
end;

procedure TGpuVkContext.WaitFor(const AValue: UInt64);
begin
  if (AValue = 0) or (AValue > FSignaled) or (FTimeline = nil) then
    Exit;
  FTimeline.Wait(AValue);
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
  if FTimePool <> VK_NULL_HANDLE then
    CollectTimes(Done);
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

function TGpuVkContext.HasBarriers: Boolean;
begin
  Result := (FBarrierCount > 0) or (FMemSrcStage <> 0) or (FMemDstStage <> 0);
end;

procedure TGpuVkContext.ImageBarrier(const AImage: TVkImage; const ASrcStage, ASrcAccess, ADstStage,
  ADstAccess: UInt64; const AOld, ANew: TVkImageLayout; const ARange: PVkImageSubresourceRange);
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
  if ARange <> nil then
    B.subresourceRange := ARange^
  else
    B.subresourceRange := ColorRange;
  Inc(FBarrierCount);
end;

procedure TGpuVkContext.Transition(const AImage: TVkImage; var AUse: TGpuVkUse; const ANew: TGpuVkUse;
  const ADiscard: Boolean; const ARange: PVkImageSubresourceRange);
var
  I: Integer;
  Old: TVkImageLayout;
begin
  // A deferred clear goes before any other use of its surface.
  if (FClearSurface <> nil) and (AImage = FClearSurface.FImage) then
    FlushClear;
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
  ImageBarrier(AImage, UseStage[AUse], UseWrites[AUse], UseStage[ANew], UseAccess[ANew], Old, UseLayout[ANew],
    ARange);
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
  Mem1: TVkMemoryBarrier;
  C: TVkCommandBuffer;
  Src, Dst: UInt64;
  I, MemCount: Integer;
  B: PVkImageMemoryBarrier2;
  L: PVkImageMemoryBarrier;
begin
  if (FBarrierCount = 0) and (FMemSrcStage = 0) and (FMemDstStage = 0) then
    Exit;
  // Barriers inside rendering are for the attachments' own feedback only.
  EndRendering;
  C := Cmd;
  if not FFast.Synchronization2 then
  begin
    // One barrier of Vulkan 1.0 for the batch: the union of its stages, each barrier's accesses and layouts.
    Src := FMemSrcStage;
    Dst := FMemDstStage;
    if Length(FLegacyBarriers) < FBarrierCount then
      SetLength(FLegacyBarriers, Length(FBarriers));
    for I := 0 to FBarrierCount - 1 do
    begin
      B := @FBarriers[I];
      L := @FLegacyBarriers[I];
      FillChar(L^, SizeOf(L^), 0);
      L.sType := VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
      L.srcAccessMask := TVkAccessFlags(B.srcAccessMask and $FFFFFFFF);
      L.dstAccessMask := TVkAccessFlags(B.dstAccessMask and $FFFFFFFF);
      L.oldLayout := B.oldLayout;
      L.newLayout := B.newLayout;
      L.srcQueueFamilyIndex := B.srcQueueFamilyIndex;
      L.dstQueueFamilyIndex := B.dstQueueFamilyIndex;
      L.image := B.image;
      L.subresourceRange := B.subresourceRange;
      Src := Src or B.srcStageMask;
      Dst := Dst or B.dstStageMask;
    end;
    MemCount := 0;
    FillChar(Mem1, SizeOf(Mem1), 0);
    if (FMemSrcStage <> 0) or (FMemDstStage <> 0) then
    begin
      Mem1.sType := VK_STRUCTURE_TYPE_MEMORY_BARRIER;
      Mem1.srcAccessMask := TVkAccessFlags(FMemSrcAccess and $FFFFFFFF);
      Mem1.dstAccessMask := TVkAccessFlags(FMemDstAccess and $FFFFFFFF);
      MemCount := 1;
    end;
    L := nil;
    if FBarrierCount > 0 then
      L := @FLegacyBarriers[0];
    FVk.CmdPipelineBarrier(C, LegacyStages(Src, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT),
      LegacyStages(Dst, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT), 0, MemCount, @Mem1, 0, nil, FBarrierCount, L);
    FBarrierCount := 0;
    FMemSrcStage := 0;
    FMemSrcAccess := 0;
    FMemDstStage := 0;
    FMemDstAccess := 0;
    Exit;
  end;
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
  Usage: TVkBufferUsageFlags;
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
    Usage := Ord(VK_BUFFER_USAGE_TRANSFER_SRC_BIT) or Ord(VK_BUFFER_USAGE_VERTEX_BUFFER_BIT) or
      Ord(VK_BUFFER_USAGE_INDEX_BUFFER_BIT) or Ord(VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT);
    // Ray tracing builds its structures from the vertices and indices draws upload, and reads instance records.
    if FFast.RayQuery then
      Usage := Usage or Ord(VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT) or Ord(VK_BUFFER_USAGE_STORAGE_BUFFER_BIT) or
        Ord(VK_BUFFER_USAGE_ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_BIT_KHR);
    Result.Buffer := NewBuffer(Result.Size, Usage, Ord(VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) or
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
  H: Integer; const AData: Pointer; const APitch: Integer; const ALevel: Integer);
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
  Region.imageSubresource.mipLevel := ALevel;
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
  const ASamples: Integer; const AAspect: TVkImageAspectFlags; const ALazy: Boolean): TVkImage;
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
      // ALazy: transient attachments, in lazily allocated memory where the device has it.
      AMemory := FFast.Allocate(Req, Ord(VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT),
        IfThen(ALazy, Ord(VK_MEMORY_PROPERTY_LAZILY_ALLOCATED_BIT), 0), False);
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

function TGpuVkContext.BufferAddress(const ABuffer: TVkBuffer): UInt64;
var
  Info: TVkBufferDeviceAddressInfo;
begin
  FillChar(Info, SizeOf(Info), 0);
  Info.sType := VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO;
  Info.buffer := ABuffer;
  Result := FVk.GetBufferDeviceAddress(FDevice, @Info);
end;

procedure TGpuVkContext.NextPool;
const
  Types: array[0..4] of TVkDescriptorType = (VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,
    VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER, VK_DESCRIPTOR_TYPE_SAMPLER, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER);
  // Per set of the canvas layout; the 3D context's sets (two uniform buffers, eight combined image samplers) come
  // from these pools too where it cannot push them (no VK_KHR_push_descriptor).
  PerSet: array[0..4] of Cardinal = (2, 16, 4, 4, 8);
var
  Sizes: array[0..4] of TVkDescriptorPoolSize;
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
    if FFast.PushDescriptor then
      Info.poolSizeCount := Length(Sizes) - 1;
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
  ClearAttachment: TVkClearAttachment;
  Rect: TVkClearRect;
  Color: TVkClearColorValue;
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
  if AClear <> nil then
  begin
    // Deferred: the load operation of the target's next rendering instance (one render pass for the clear and the
    // draws after it), unless something else uses the target first (FlushClear).
    if FRendering = ATarget then
      EndRendering;
    if (FClearSurface <> nil) and (FClearSurface <> ATarget) then
      FlushClear;
    FClearSurface := ATarget;
    FClearColor := AClear^;
    Exit;
  end;
  if FClearSurface = ATarget then
  begin
    FClearSurface := nil;
    Color := FClearColor;
    StartTarget(ATarget, @Color);
  end
  else
    StartTarget(ATarget, nil);
end;

procedure TGpuVkContext.FlushClear;
var
  S: TGpuVkSurface;
  Color: TVkClearColorValue;
begin
  S := FClearSurface;
  if S = nil then
    Exit;
  FClearSurface := nil;
  Color := FClearColor;
  StartTarget(S, @Color);
  EndRendering;
  // The clear's writes come before the next ones (a use without a change of layout takes no barrier of its own).
  MemoryBarrier(StageColorOutput, AccessColorWrite, StageColorOutput, AccessColorRead or AccessColorWrite);
end;

function TGpuVkContext.TargetDepth(const AWidth, AHeight: Integer): Integer;
var
  I, Oldest: Integer;
  D: TGpuVkDepth;
begin
  for I := 0 to High(FDepths) do
    if (FDepths[I].Width = AWidth) and (FDepths[I].Height = AHeight) then
    begin
      FDepths[I].Gen := FListGen;
      Exit(I);
    end;
  // A few sizes (a window, its client-sized bitmaps); the one used longest ago goes for another.
  if Length(FDepths) >= 4 then
  begin
    Oldest := 0;
    for I := 1 to High(FDepths) do
      if FDepths[I].Gen < FDepths[Oldest].Gen then
        Oldest := I;
    Retire(TGpuVkObject.ImageView, FDepths[Oldest].View);
    Retire(TGpuVkObject.Image, FDepths[Oldest].Image);
    Retire(TGpuVkObject.Memory, MemoryHandle(FDepths[Oldest].Memory));
    Delete(FDepths, Oldest, 1);
  end;
  D := Default(TGpuVkDepth);
  D.Width := AWidth;
  D.Height := AHeight;
  // Transient: a tiler keeps it in tile memory (cleared at the start, never stored), lazily allocated memory where
  // the device has it.
  D.Image := NewImage(FFast.DepthFormat, AWidth, AHeight, Ord(VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT) or
    Ord(VK_IMAGE_USAGE_TRANSIENT_ATTACHMENT_BIT), D.Memory, D.View, 1, 1, Ord(VK_IMAGE_ASPECT_DEPTH_BIT) or
    Ord(VK_IMAGE_ASPECT_STENCIL_BIT), True);
  D.Gen := FListGen;
  FDepths := FDepths + [D];
  Result := High(FDepths);
end;

procedure TGpuVkContext.ClearDepth;
var
  Attachment: TVkClearAttachment;
  Rect: TVkClearRect;
  S: TGpuVkSurface;
begin
  if not FRenderingDepth or not (FRendering is TGpuVkSurface) then
    Exit;
  S := TGpuVkSurface(FRendering);
  FillChar(Attachment, SizeOf(Attachment), 0);
  Attachment.aspectMask := Ord(VK_IMAGE_ASPECT_DEPTH_BIT);
  Attachment.clearValue.depthStencil.depth := 1;
  FillChar(Rect, SizeOf(Rect), 0);
  Rect.rect.extent.width := Max(S.Width, 1);
  Rect.rect.extent.height := Max(S.Height, 1);
  Rect.layerCount := 1;
  FVk.CmdClearAttachments(FCmd.Buffer, 1, @Attachment, 1, @Rect);
  FDepthCount := 0;
end;

procedure TGpuVkContext.StartTarget(const ATarget: TGpuVkSurface; const AClear: PVkClearColorValue);
var
  Attachment, Depth, Stencil: TVkRenderingAttachmentInfo;
  Info: TVkRenderingInfo;
  D: Integer;
  Range: TVkImageSubresourceRange;
begin
  EndRendering;
  if ATarget.FUse = TGpuVkUse.ColorTarget then
    // Drawn in an earlier rendering instance: its writes come before the next ones (blending reads them).
    MemoryBarrier(StageColorOutput, AccessColorWrite, StageColorOutput, AccessColorRead or AccessColorWrite)
  else
    // A clear replaces everything.
    Transition(ATarget.FImage, ATarget.FUse, TGpuVkUse.ColorTarget, AClear <> nil);
  D := -1;
  if ATarget.FWantDepth and (FFast.DepthFormat <> VK_FORMAT_UNDEFINED) then
  begin
    D := TargetDepth(Max(ATarget.Width, 1), Max(ATarget.Height, 1));
    if FDepths[D].Use = TGpuVkUse.DepthTarget then
      // The tests and writes of its last rendering instance come before this one's clear.
      MemoryBarrier(StageLateTests, AccessDepthWrite, StageEarlyTests or StageLateTests,
        AccessDepthRead or AccessDepthWrite)
    else
    begin
      Range := ColorRange;
      Range.aspectMask := Ord(VK_IMAGE_ASPECT_DEPTH_BIT) or Ord(VK_IMAGE_ASPECT_STENCIL_BIT);
      Transition(FDepths[D].Image, FDepths[D].Use, TGpuVkUse.DepthTarget, True, @Range);
    end;
  end;
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
  if D >= 0 then
  begin
    FillChar(Depth, SizeOf(Depth), 0);
    Depth.sType := VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO;
    Depth.imageView := FDepths[D].View;
    Depth.imageLayout := VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;
    Depth.resolveMode := VK_RESOLVE_MODE_NONE;
    Depth.loadOp := VK_ATTACHMENT_LOAD_OP_CLEAR;
    Depth.storeOp := VK_ATTACHMENT_STORE_OP_DONT_CARE;
    Depth.clearValue.depthStencil.depth := 1;
    Stencil := Depth;
    Stencil.loadOp := VK_ATTACHMENT_LOAD_OP_DONT_CARE;
    Info.pDepthAttachment := @Depth;
    Info.pStencilAttachment := @Stencil;
  end;
  StartRendering(Info, ATarget.FFormat, 1);
  FRendering := ATarget;
  FRenderingDepth := D >= 0;
  FDepthCount := 0;
end;

procedure TGpuVkContext.BeginRenderingInfo(const AOwner: TObject; const AInfo: TVkRenderingInfo;
  const AColorFormat: TVkFormat; const ASamples: Integer);
begin
  EndRendering;
  FlushBarriers;
  StartRendering(AInfo, AColorFormat, ASamples);
  FRendering := AOwner;
end;

procedure TGpuVkContext.StartRendering(const AInfo: TVkRenderingInfo; const AColorFormat: TVkFormat;
  const ASamples: Integer);
var
  Key: TFastVkPassKey;
  Color, Depth, Stencil: PVkRenderingAttachmentInfo;
  DepthView: TVkImageView;
  Clears: array[0..1] of TVkClearValue;
  Info: TVkRenderPassBeginInfo;
begin
  if FTimeSlot >= 0 then
    // Room for its end and the command buffer's.
    if FTimeSlots[FTimeSlot].Count <= TimeSlotQueries - 3 then
    begin
      TimeStamp(VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT);
      FTimePass := True;
    end
    else
      Inc(GTimeUntimed);
  if FFast.DynamicRendering then
  begin
    FVk.CmdBeginRendering(Cmd, @AInfo);
    Exit;
  end;
  // A render pass of the same attachments, operations and layouts, with a framebuffer of the views.
  Color := AInfo.pColorAttachments;
  Depth := AInfo.pDepthAttachment;
  Stencil := AInfo.pStencilAttachment;
  FillChar(Key, SizeOf(Key), 0);
  FillChar(Clears, SizeOf(Clears), 0);
  Key.ColorFormat := AColorFormat;
  Key.DepthFormat := VK_FORMAT_UNDEFINED;
  Key.Samples := Max(ASamples, 1);
  Key.ColorLayout := Color.imageLayout;
  Key.ColorLoad := Color.loadOp;
  Key.ColorStore := Color.storeOp;
  Clears[0] := Color.clearValue;
  DepthView := VK_NULL_HANDLE;
  if Depth <> nil then
  begin
    DepthView := Depth.imageView;
    Key.DepthFormat := FFast.DepthFormat;
    Key.DepthLayout := Depth.imageLayout;
    Key.DepthLoad := Depth.loadOp;
    Key.DepthStore := Depth.storeOp;
    Key.StencilLoad := VK_ATTACHMENT_LOAD_OP_DONT_CARE;
    Key.StencilStore := VK_ATTACHMENT_STORE_OP_DONT_CARE;
    Clears[1].depthStencil.depth := Depth.clearValue.depthStencil.depth;
    if Stencil <> nil then
    begin
      Key.StencilLoad := Stencil.loadOp;
      Key.StencilStore := Stencil.storeOp;
      Clears[1].depthStencil.stencil := Stencil.clearValue.depthStencil.stencil;
    end;
  end;
  FillChar(Info, SizeOf(Info), 0);
  Info.sType := VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
  try
    Info.renderPass := FFast.RenderPass(Key);
    Info.framebuffer := Framebuffer(FFast.CompatiblePass(AColorFormat, ASamples, Key.DepthFormat), Color.imageView,
      DepthView, AInfo.renderArea.extent);
  except
    on E: EFastVulkan do
      raise EFastDevice.Create(E.Message);
  end;
  Info.renderArea := AInfo.renderArea;
  Info.clearValueCount := 1;
  if Depth <> nil then
    Info.clearValueCount := 2;
  Info.pClearValues := @Clears[0];
  FVk.CmdBeginRenderPass(Cmd, @Info, VK_SUBPASS_CONTENTS_INLINE);
end;

function TGpuVkContext.Framebuffer(const APass: TVkRenderPass; const AColor, ADepth: TVkImageView;
  const AExtent: TVkExtent2D): TVkFramebuffer;
var
  Key: TGpuVkFramebufferKey;
  Views: array[0..1] of TVkImageView;
  Info: TVkFramebufferCreateInfo;
  View: TVkImageView;
  N: Integer;
begin
  FillChar(Key, SizeOf(Key), 0);
  Key.Pass := APass;
  Key.Color := AColor;
  Key.Depth := ADepth;
  Key.Width := Max(AExtent.width, 1);
  Key.Height := Max(AExtent.height, 1);
  if FFramebuffers.TryGetValue(Key, Result) then
    Exit;
  Views[0] := AColor;
  Views[1] := ADepth;
  FillChar(Info, SizeOf(Info), 0);
  Info.sType := VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
  Info.renderPass := APass;
  Info.attachmentCount := 1;
  if ADepth <> VK_NULL_HANDLE then
    Info.attachmentCount := 2;
  Info.pAttachments := @Views[0];
  Info.width := Key.Width;
  Info.height := Key.Height;
  Info.layers := 1;
  Result := VK_NULL_HANDLE;
  Check(FVk.CreateFramebuffer(FDevice, @Info, nil, @Result), 'vkCreateFramebuffer');
  FFramebuffers.Add(Key, Result);
  for View in Views do
    if View <> VK_NULL_HANDLE then
    begin
      if not FFramebufferViews.TryGetValue(View, N) then
        N := 0;
      FFramebufferViews.AddOrSetValue(View, N + 1);
    end;
end;

procedure TGpuVkContext.DropFramebuffers(const AView: TVkImageView);
var
  Pair: TPair<TGpuVkFramebufferKey, TVkFramebuffer>;
  Other: TVkImageView;
  N: Integer;
begin
  // The command buffers that used them are done (the view is destroyed now).
  for Pair in FFramebuffers.ToArray do
    if (Pair.Key.Color = AView) or (Pair.Key.Depth = AView) then
    begin
      FVk.DestroyFramebuffer(FDevice, Pair.Value, nil);
      FFramebuffers.Remove(Pair.Key);
      if Pair.Key.Color = AView then
        Other := Pair.Key.Depth
      else
        Other := Pair.Key.Color;
      if (Other <> VK_NULL_HANDLE) and FFramebufferViews.TryGetValue(Other, N) then
        if N > 1 then
          FFramebufferViews[Other] := N - 1
        else
          FFramebufferViews.Remove(Other);
    end;
  FFramebufferViews.Remove(AView);
end;

procedure TGpuVkContext.EndRendering;
begin
  if FRendering = nil then
    Exit;
  FRendering := nil;
  FRenderingDepth := False;
  if FFast.DynamicRendering then
    FVk.CmdEndRendering(FCmd.Buffer)
  else
    FVk.CmdEndRenderPass(FCmd.Buffer);
  if FTimePass then
  begin
    FTimePass := False;
    TimeStamp(VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT);
  end;
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
  FFormat := VK_FORMAT_B8G8R8A8_UNORM;
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

constructor TGpuVkSurface.CreateChain(const AImage: TVkImage; const AFormat: TVkFormat; const AWidth,
  AHeight: Integer);
var
  C: TGpuVkContext;
  Info: TVkImageViewCreateInfo;
begin
  inherited Create;
  FWidth := AWidth;
  FHeight := AHeight;
  FFormat := AFormat;
  FImage := AImage;
  FBorrowed := True;
  C := GpuVk;
  FillChar(Info, SizeOf(Info), 0);
  Info.sType := VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
  Info.image := AImage;
  Info.viewType := VK_IMAGE_VIEW_TYPE_2D;
  Info.format := AFormat;
  Info.subresourceRange := ColorRange;
  C.Check(C.Vk.CreateImageView(C.Device, @Info, nil, @FView), 'vkCreateImageView');
  C.FSurfaces.Add(Self);
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
      if GCtx.FClearSurface = Self then
        GCtx.FClearSurface := nil;
      // Command buffers that are not executed yet may use them.
      GCtx.Retire(TGpuVkObject.ImageView, FView);
      if not FBorrowed then
      begin
        GCtx.Retire(TGpuVkObject.Image, FImage);
        GCtx.Retire(TGpuVkObject.Memory, MemoryHandle(FMemory));
      end;
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
  if C.FClearSurface = Self then
    C.FClearSurface := nil;
  C.DestroyObject(TGpuVkObject.ImageView, FView);
  if not FBorrowed then
  begin
    C.DestroyObject(TGpuVkObject.Image, FImage);
    C.DestroyObject(TGpuVkObject.Memory, MemoryHandle(FMemory));
  end;
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

constructor TGpuVkWindow.Create(const AHandle: TGpuWindowHandle; const ALayered: Boolean);
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
      ReleaseDirectChain;
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
var
  S: TGpuVkSurface;
  I: Integer;
begin
  StopPresenter;
  // The GPU is idle: the direct swap chain's objects go at once.
  for S in FChainImages do
  begin
    S.Drop(AContext);
    S.Free;
  end;
  FChainImages := nil;
  for I := 0 to High(FChainPresent) do
    AContext.Vk.DestroySemaphore(AContext.Device, FChainPresent[I], nil);
  FChainPresent := nil;
  for I := 0 to High(FChainAcquire) do
  begin
    if FChainAcquire[I] <> VK_NULL_HANDLE then
      AContext.Vk.DestroySemaphore(AContext.Device, FChainAcquire[I], nil);
    FChainAcquire[I] := VK_NULL_HANDLE;
  end;
  if FChain <> VK_NULL_HANDLE then
    AContext.Vk.DestroySwapchainKHR(AContext.Device, FChain, nil);
  FChain := VK_NULL_HANDLE;
  FChainHeld := False;
  AContext.FWindows.Remove(Self);
  if FVkSurface <> VK_NULL_HANDLE then
    AContext.Fast.InstanceVk.DestroySurfaceKHR(AContext.Fast.Instance, FVkSurface, nil);
  FVkSurface := VK_NULL_HANDLE;
  FModes := nil;
end;

function TGpuVkWindow.CreateVkSurface: Boolean;
var
  F: TFastVulkan;
{$IF Defined(MSWINDOWS)}
  Info: TVkWin32SurfaceCreateInfoKHR;
{$ELSEIF Defined(ANDROID)}
  Info: TVkAndroidSurfaceCreateInfoKHR;
{$ELSE}
  Info: TVkXlibSurfaceCreateInfoKHR;
{$ENDIF}
  Supported: TVkBool32;
  Count: Cardinal;
begin
  F := GpuVk.Fast;
{$IF Defined(MSWINDOWS)}
  FillChar(Info, SizeOf(Info), 0);
  Info.sType := VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR;
  Info.hinstance_ := TVkHINSTANCE(GetWindowLongPtr(FWnd, GWLP_HINSTANCE));
  Info.hwnd_ := FWnd;
  F.Check(F.InstanceVk.CreateWin32SurfaceKHR(F.Instance, @Info, nil, @FVkSurface), 'vkCreateWin32SurfaceKHR');
{$ELSEIF Defined(ANDROID)}
  // No native window: the app has no surface now (FMX makes the canvas again when it gets one).
  if FHandle.Window = 0 then
    Exit(False);
  FillChar(Info, SizeOf(Info), 0);
  Info.sType := VK_STRUCTURE_TYPE_ANDROID_SURFACE_CREATE_INFO_KHR;
  Info.window := Pointer(FHandle.Window);
  if F.Track(F.InstanceVk.CreateAndroidSurfaceKHR(F.Instance, @Info, nil, @FVkSurface)) <> VK_SUCCESS then
  begin
    FVkSurface := VK_NULL_HANDLE;
    Exit(False);
  end;
{$ELSE}
  if (FHandle.Window = 0) or (FHandle.Display = nil) then
    Exit(False);
  FillChar(Info, SizeOf(Info), 0);
  Info.sType := VK_STRUCTURE_TYPE_XLIB_SURFACE_CREATE_INFO_KHR;
  Info.dpy := FHandle.Display;
  Info.window := FHandle.Window;
  F.Check(F.InstanceVk.CreateXlibSurfaceKHR(F.Instance, @Info, nil, @FVkSurface), 'vkCreateXlibSurfaceKHR');
{$ENDIF}
  Supported := VK_FALSE;
  F.InstanceVk.GetPhysicalDeviceSurfaceSupportKHR(F.Physical, F.QueueFamily, FVkSurface, @Supported);
  if Supported = VK_FALSE then
    raise EFastDevice.Create('FastCanvas: the Vulkan queue cannot present to the window');
  Count := 0;
  F.InstanceVk.GetPhysicalDeviceSurfacePresentModesKHR(F.Physical, FVkSurface, @Count, nil);
  SetLength(FModes, Count);
  if Count > 0 then
    F.InstanceVk.GetPhysicalDeviceSurfacePresentModesKHR(F.Physical, FVkSurface, @Count, @FModes[0]);
  Result := True;
end;

procedure TGpuVkWindow.DropSurface;
begin
  // The thread presenting to it ends first (its swap chain is gone already), the direct swap chain too.
  StopPresenter;
  ReleaseDirectChain;
  if FVkSurface <> VK_NULL_HANDLE then
    GCtx.Fast.InstanceVk.DestroySurfaceKHR(GCtx.Fast.Instance, FVkSurface, nil);
  FVkSurface := VK_NULL_HANDLE;
  FModes := nil;
end;

function TGpuVkWindow.PresentMode: TVkPresentModeKHR;
begin
  // FIFO_LATEST_READY shows the newest frame queued at a refresh and frees the ones before it. Android: vertical sync
  // unless tearing is asked for (the window's frames keep the display's pace there, TGpuVkWindow.Present).
  if FTearingAsked and HasMode(VK_PRESENT_MODE_IMMEDIATE_KHR) then
    Result := VK_PRESENT_MODE_IMMEDIATE_KHR
  else if {$IFDEF ANDROID}FTearingAsked and {$ENDIF}HasMode(VK_PRESENT_MODE_MAILBOX_KHR) then
    Result := VK_PRESENT_MODE_MAILBOX_KHR
  else if GpuVk.Fast.FifoLatestReady and HasMode(VK_PRESENT_MODE_FIFO_LATEST_READY_KHR) then
    Result := VK_PRESENT_MODE_FIFO_LATEST_READY_KHR
  else
    Result := VK_PRESENT_MODE_FIFO_KHR;
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
procedure RecordChainCopy(const AFast: TFastVulkan; const ACmd: TVkCommandBuffer; const ASource: TGpuVkSurface;
  const AImage: TVkImage; const AFormat: TVkFormat; const AExtent: TVkExtent2D);
var
  AVk: TVulkan;
  Barrier: TVkImageMemoryBarrier2;
  Copy: TVkImageCopy;
  Blit: TVkImageBlit;
begin
  AVk := AFast.Vk;
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
  CmdImageBarrier(AFast, ACmd, Barrier);
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
  CmdImageBarrier(AFast, ACmd, Barrier);
end;

/// <summary>The extent of a swap chain for frames of AWidth x AHeight; zero when the window has no size (minimized).
/// </summary>
function ChainExtent(const ACaps: TVkSurfaceCapabilitiesKHR; const AWidth, AHeight: Integer): TVkExtent2D;
begin
  Result := ACaps.currentExtent;
{$IFDEF ANDROID}
  // The extent there is the one of the display's natural orientation: the frame's size instead (the compositor
  // rotates the images, preTransform in FillChainInfo).
  Result.width := High(Cardinal);
{$ENDIF}
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
{$IFDEF ANDROID}
  // Unrotated images of the frame's size (ChainExtent): the compositor rotates them.
  if (ACaps.supportedTransforms and Ord(VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR)) <> 0 then
    AInfo.preTransform := VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR;
{$ENDIF}
  if (ACaps.supportedCompositeAlpha and Ord(VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR)) <> 0 then
    AInfo.compositeAlpha := VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR
  else if (ACaps.supportedCompositeAlpha and Ord(VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR)) <> 0 then
    AInfo.compositeAlpha := VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR
  else
    AInfo.compositeAlpha := VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR;
  AInfo.clipped := VK_TRUE;
end;

function TGpuVkWindow.Prepare(const AWidth, AHeight: Integer; const ATearing: Boolean;
  const AOutput: TGpuOutput): TGpuSurface;
begin
  if ATearing <> FTearingAsked then
  begin
    FTearingAsked := ATearing;
    FStale := True;
    FChainStale := True;
  end;
  if not FDirectChecked then
  begin
    FDirectChecked := True;
    FDirect := not FLayered and (GetEnvironmentVariable(DirectVariable) = '1');
  end;
  if FDirect then
  begin
    Result := DirectPrepare(AWidth, AHeight);
    if Result <> nil then
      Exit;
  end;
  // Frames are drawn into a surface of the window (8-bit: no HDR output yet), which Present hands to the presenting
  // thread and transparent windows read back.
  if (FSurface <> nil) and ((FSurface.Width <> AWidth) or (FSurface.Height <> AHeight)) then
  begin
    // It may have been the one shown: it goes once a submission after the presenting thread's copies of it is done
    // (one of the next command buffer, opened for it).
    GpuVk.Cmd;
    FreeAndNil(FSurface);
  end;
  if FSurface = nil then
  begin
    FSurface := TGpuVkSurface.Create(AWidth, AHeight, nil, 0);
    FDrawn := False;
  end;
  Result := FSurface;
end;

function TGpuVkWindow.DirectChain(const AWidth, AHeight: Integer): Boolean;
var
  C: TGpuVkContext;
  F: TFastVulkan;
  Caps: TVkSurfaceCapabilitiesKHR;
  Extent: TVkExtent2D;
  Format: TVkSurfaceFormatKHR;
  Info: TVkSwapchainCreateInfoKHR;
  SemInfo: TVkSemaphoreCreateInfo;
  Chain: TVkSwapchainKHR;
  Images: TArray<TVkImage>;
  Count: Cardinal;
  Res: TVkResult;
  I: Integer;
begin
  Result := False;
  C := GpuVk;
  F := C.Fast;
  Res := F.Track(F.InstanceVk.GetPhysicalDeviceSurfaceCapabilitiesKHR(F.Physical, FVkSurface, @Caps));
  if Res = VK_ERROR_SURFACE_LOST_KHR then
  begin
    DropSurface;
    Exit;
  end;
  if Ord(Res) < 0 then
    Exit;
  Extent := ChainExtent(Caps, AWidth, AHeight);
  if (Extent.width = 0) or (Extent.height = 0) then
    Exit;
  if (FChain <> VK_NULL_HANDLE) and not FChainStale and (Extent.width = FChainExtent.width) and
    (Extent.height = FChainExtent.height) then
    Exit(True);
  // Made again (a new size, tearing): rare, the GPU is waited for.
  ReleaseDirectChain;
  Format := ChooseFormat(F, FVkSurface);
  if ((Format.format <> VK_FORMAT_B8G8R8A8_UNORM) and (Format.format <> VK_FORMAT_R8G8B8A8_UNORM)) or
    ((Caps.supportedUsageFlags and Ord(VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT)) = 0) then
  begin
    // Not a format the pipelines draw into: the presenting thread copies the frames.
    FDirect := False;
    Exit;
  end;
  FillChainInfo(Info, FVkSurface, Caps, Format);
  Info.imageUsage := Ord(VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT);
  Info.imageExtent := Extent;
  Info.presentMode := PresentMode;
  Chain := VK_NULL_HANDLE;
  Res := F.Track(C.Vk.CreateSwapchainKHR(C.Device, @Info, nil, @Chain));
  if (Res = VK_ERROR_SURFACE_LOST_KHR) or (Res = VK_ERROR_NATIVE_WINDOW_IN_USE_KHR) then
  begin
    DropSurface;
    Exit;
  end;
  F.Check(Res, 'vkCreateSwapchainKHR');
  FChain := Chain;
  Count := 0;
  C.Vk.GetSwapchainImagesKHR(C.Device, FChain, @Count, nil);
  SetLength(Images, Count);
  if Count > 0 then
    C.Vk.GetSwapchainImagesKHR(C.Device, FChain, @Count, @Images[0]);
  FillChar(SemInfo, SizeOf(SemInfo), 0);
  SemInfo.sType := VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
  SetLength(FChainImages, Count);
  SetLength(FChainPresent, Count);
  for I := 0 to Integer(Count) - 1 do
  begin
    FChainImages[I] := TGpuVkSurface.CreateChain(Images[I], Format.format, Extent.width, Extent.height);
    F.Check(C.Vk.CreateSemaphore(C.Device, @SemInfo, nil, @FChainPresent[I]), 'vkCreateSemaphore');
  end;
  for I := 0 to High(FChainAcquire) do
    F.Check(C.Vk.CreateSemaphore(C.Device, @SemInfo, nil, @FChainAcquire[I]), 'vkCreateSemaphore');
  FChainExtent := Extent;
  FChainStale := False;
  FChainHeld := False;
  Result := True;
end;

procedure TGpuVkWindow.ReleaseDirectChain;
var
  C: TGpuVkContext;
  S: TGpuVkSurface;
  I: Integer;
begin
  C := GCtx;
  if (C = nil) or ((FChain = VK_NULL_HANDLE) and (FChainImages = nil) and (FChainAcquire[0] = VK_NULL_HANDLE)) then
    Exit;
  // An acquire no submission waited for yet is waited for now; then presents and waits on the semaphores are done.
  for I := 0 to High(FChainAcquire) do
    if (FChainAcquire[I] <> VK_NULL_HANDLE) and (C.FAcquireWait = FChainAcquire[I]) then
    begin
      C.FAcquireWait := VK_NULL_HANDLE;
      C.Submit(FChainAcquire[I], StageColorOutput);
    end;
  C.WaitIdle;
  C.Fast.LockQueue;
  try
    C.Vk.QueueWaitIdle(C.Queue);
  finally
    C.Fast.UnlockQueue;
  end;
  for I := 0 to High(FChainAcquire) do
  begin
    C.DestroyObject(TGpuVkObject.Semaphore, FChainAcquire[I]);
    FChainAcquire[I] := VK_NULL_HANDLE;
  end;
  for S in FChainImages do
    S.Free;
  FChainImages := nil;
  for I := 0 to High(FChainPresent) do
    C.DestroyObject(TGpuVkObject.Semaphore, FChainPresent[I]);
  FChainPresent := nil;
  // The surfaces' views were retired: they go with the next collection, after the swap chain is gone.
  C.Collect;
  if FChain <> VK_NULL_HANDLE then
    C.Vk.DestroySwapchainKHR(C.Device, FChain, nil);
  FChain := VK_NULL_HANDLE;
  FChainHeld := False;
end;

function TGpuVkWindow.DirectPrepare(const AWidth, AHeight: Integer): TGpuSurface;
var
  C: TGpuVkContext;
  S: TGpuVkSurface;
  Sem: TVkSemaphore;
  Res: TVkResult;
  Attempt, Waits: Integer;
begin
  Result := nil;
  C := GpuVk;
  if FChainHeld then
  begin
    // The frame before was not presented: this one takes its image.
    if not FChainStale and (FChainExtent.width = Cardinal(AWidth)) and (FChainExtent.height = Cardinal(AHeight)) then
      Exit(FChainImages[FChainIndex]);
    ReleaseDirectChain;
  end;
  if FPresenter <> nil then
    StopPresenter;
  if (FVkSurface = VK_NULL_HANDLE) and not CreateVkSurface then
    Exit;
  if not DirectChain(AWidth, AHeight) then
    Exit;
  // The acquire semaphore of this frame in flight: its last wait (FramesInFlight frames before) is done.
  C.WaitFor(FFrameValues[FFrameIndex mod FramesInFlight]);
  Sem := FChainAcquire[FFrameIndex mod FramesInFlight];
  // Where FIFO waits for the display (the frames keep its pace); in slices, at most a second.
  Attempt := 0;
  Waits := 0;
  repeat
    Res := C.Fast.Track(C.Vk.AcquireNextImageKHR(C.Device, FChain, 100000000, Sem, VK_NULL_HANDLE, @FChainIndex));
    if Res = VK_ERROR_OUT_OF_DATE_KHR then
    begin
      Inc(Attempt);
      FChainStale := True;
      if (Attempt > 1) or not DirectChain(AWidth, AHeight) then
        Exit;
      Sem := FChainAcquire[FFrameIndex mod FramesInFlight];
      Continue;
    end;
    if (Res <> VK_TIMEOUT) and (Res <> VK_NOT_READY) then
      Break;
    Inc(Waits);
    if (Waits >= 10) or C.Fast.Lost then
      Exit;
  until False;
  if Res = VK_ERROR_SURFACE_LOST_KHR then
  begin
    DropSurface;
    Exit;
  end;
  if (Res <> VK_SUCCESS) and (Res <> VK_SUBOPTIMAL_KHR) then
  begin
    FChainStale := True;
    Exit;
  end;
  // Suboptimal: made again for the next frame; not on Android (see TGpuVkPresenter.PresentPending).
{$IFNDEF ANDROID}
  if Res = VK_SUBOPTIMAL_KHR then
    FChainStale := True;
{$ENDIF}
  FChainHeld := True;
  // The next submission waits for the image; the old content goes, after that wait (its stage).
  C.FAcquireWait := Sem;
  S := FChainImages[FChainIndex];
  C.ImageBarrier(S.FImage, StageColorOutput, 0, StageColorOutput, AccessColorRead or AccessColorWrite,
    VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL);
  S.FUse := TGpuVkUse.ColorTarget;
  Result := S;
end;

function TGpuVkWindow.DirectPresent: HResult;
var
  C: TGpuVkContext;
  Info: TVkPresentInfoKHR;
  Sem: TVkSemaphore;
  Index: Cardinal;
  Res: TVkResult;
begin
  Result := S_OK;
  C := GpuVk;
  Index := FChainIndex;
  FChainImages[Index].Use(TGpuVkUse.Present);
  Sem := FChainPresent[Index];
  C.WaitFor(FFrameValues[FFrameIndex mod FramesInFlight]);
  FFrameValues[FFrameIndex mod FramesInFlight] := C.Submit(VK_NULL_HANDLE, 0, Sem);
  Inc(FFrameIndex);
  FChainHeld := False;
  if C.Fast.Lost then
    Exit(DXGI_ERROR_DEVICE_REMOVED);
  if GTimeTarget <> '' then
    TimingFrame;
  FillChar(Info, SizeOf(Info), 0);
  Info.sType := VK_STRUCTURE_TYPE_PRESENT_INFO_KHR;
  Info.waitSemaphoreCount := 1;
  Info.pWaitSemaphores := @Sem;
  Info.swapchainCount := 1;
  Info.pSwapchains := @FChain;
  Info.pImageIndices := @Index;
  C.Fast.LockQueue;
  try
    Res := C.Fast.Track(C.Vk.QueuePresentKHR(C.Queue, @Info));
  finally
    C.Fast.UnlockQueue;
  end;
  if Res = VK_ERROR_SURFACE_LOST_KHR then
    DropSurface
  else if (Res <> VK_SUCCESS) {$IFDEF ANDROID}and (Res <> VK_SUBOPTIMAL_KHR){$ENDIF} then
    FChainStale := True;
  if C.Fast.Lost then
    Result := DXGI_ERROR_DEVICE_REMOVED;
end;

function TGpuVkWindow.Present: HResult;
var
  C: TGpuVkContext;
  Old: TGpuVkSurface;
begin
  Result := S_OK;
  if FDirect and FChainHeld then
    Exit(DirectPresent);
  if FLayered or (FSurface = nil) then
    Exit;
  C := GpuVk;
  if FDirect then
  begin
    // The frame went into the window's surface (no swap chain image now): not shown.
    C.Submit;
    FDrawn := True;
    FLastShown := False;
    if C.Fast.Lost then
      Exit(DXGI_ERROR_DEVICE_REMOVED);
    Exit;
  end;
  if (FPresenter <> nil) and FPresenter.SurfaceLost then
    DropSurface;
  if (FVkSurface = VK_NULL_HANDLE) and not CreateVkSurface then
  begin
    // No surface now (Android: no native window): the frame stays in the window's surface, not shown.
    C.Submit;
    FDrawn := True;
    FLastShown := False;
    if C.Fast.Lost then
      Exit(DXGI_ERROR_DEVICE_REMOVED);
    Exit;
  end;
  if FPresenter = nil then
    FPresenter := TGpuVkPresenter.Create(Self);
  if FStale then
  begin
    FStale := False;
    FPresenter.Lock;
    FPresenter.FStaleAsked := True;
    FPresenter.Unlock;
  end;
  // The frame rests in TRANSFER_SRC_OPTIMAL for the presenting thread, which shows it from now on (Post): it is not
  // copied. The surface it showed before takes the next frame.
  FSurface.Use(TGpuVkUse.TransferSrc);
  C.WaitFor(FFrameValues[FFrameIndex mod FramesInFlight]);
  FFrameValues[FFrameIndex mod FramesInFlight] := C.Submit;
  Inc(FFrameIndex);
  if C.Fast.Lost then
  begin
    FDrawn := True;
    Exit(DXGI_ERROR_DEVICE_REMOVED);
  end;
  if GTimeTarget <> '' then
    TimingFrame;
{$IFDEF ANDROID}
  // Phones: the frames keep the display's pace (FIFO), as when the render thread presented itself; the frame before
  // has to be taken first (bounded: a frame that cannot be shown does not hold the render thread).
  FPresenter.WaitTaken(100);
{$ENDIF}
  // The frame is shown from now on, and the surface shown before takes the next frame: the presenting thread takes
  // the frame to show holding the lock and submits its copy before it lets go, so its copies of the old one are
  // earlier on the queue than the next frame's draws into it.
  FPresenter.Lock;
  Old := FShown;
  FShown := FSurface;
  Inc(FPresenter.FShownGen);
  FPresenter.Unlock;
  FPresenter.Post;
  FDrawn := False;
  FLastShown := True;
  if (Old <> nil) and (Old.Width = FShown.Width) and (Old.Height = FShown.Height) then
    FSurface := Old
  else
  begin
    // Of another size: it goes once a submission after the presenting thread's last copy of it is done (one of the
    // next command buffer, opened for it).
    FSurface := nil;
    C.Cmd;
    Old.Free;
  end;
end;

function TGpuVkWindow.RestoreLast: Boolean;
var
  C: TGpuVkContext;
  Region: TVkImageCopy;
begin
  // The frame shown last into the surface (FShown stays in TRANSFER_SRC_OPTIMAL for the presenting thread, which
  // only reads it too). The surface holds the frame drawn last itself when it was not shown (no swap chain now,
  // transparent windows). Direct: the swap chain's images keep nothing.
  if FDirect and FChainHeld then
    Exit(False);
  if (FSurface <> nil) and not FDrawn and FLastShown and (FShown <> nil) and (FShown.Width = FSurface.Width) and
    (FShown.Height = FSurface.Height) then
  begin
    C := GpuVk;
    C.Transition(FSurface.Image, FSurface.FUse, TGpuVkUse.TransferDst, True);
    FillChar(Region, SizeOf(Region), 0);
    Region.srcSubresource := ColorLayers;
    Region.dstSubresource := ColorLayers;
    Region.extent.width := FSurface.Width;
    Region.extent.height := FSurface.Height;
    Region.extent.depth := 1;
    C.Vk.CmdCopyImage(C.TransferCmd, FShown.Image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, FSurface.Image,
      VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, @Region);
    FSurface.GpuWritten;
    FDrawn := True;
  end;
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
  // The frame shown last, into the surface (whose content goes: the next frame draws all of it, or starts from the
  // last one as well).
  if not RestoreLast then
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

{ TGpuVkPresenter }

constructor TGpuVkPresenter.Create(const AWindow: TGpuVkWindow);
var
  PoolInfo: TVkCommandPoolCreateInfo;
  FenceInfo: TVkFenceCreateInfo;
begin
  FWindow := AWindow;
  FFast := GpuVk.Fast;
  FVk := FFast.Vk;
  FDevice := FFast.Device;
{$IFDEF MSWINDOWS}
  InitializeCriticalSection(FLock);
{$ELSE}
  FLock := TObject.Create;
{$ENDIF}
  FWake := TEvent.Create(nil, False, False, '');
  FTaken := TEvent.Create(nil, True, False, '');
  FTimeline := TGpuVkTimeline.Create(FFast);
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
  FTaken.Free;
{$IFDEF MSWINDOWS}
  DeleteCriticalSection(FLock);
{$ELSE}
  FLock.Free;
{$ENDIF}
end;

procedure TGpuVkPresenter.Lock;
begin
{$IFDEF MSWINDOWS}
  EnterCriticalSection(FLock);
{$ELSE}
  TMonitor.Enter(FLock);
{$ENDIF}
end;

procedure TGpuVkPresenter.Unlock;
begin
{$IFDEF MSWINDOWS}
  LeaveCriticalSection(FLock);
{$ELSE}
  TMonitor.Exit(FLock);
{$ENDIF}
end;

procedure TGpuVkPresenter.Post;
begin
  Lock;
  FPending := True;
  Unlock;
  FWake.SetEvent;
end;

procedure TGpuVkPresenter.WaitTaken(const ATimeoutMs: Cardinal);
var
  Pending: Boolean;
begin
  // Reset under the lock that clears FPending and sets the event: no wakeup is lost.
  Lock;
  Pending := FPending;
  if Pending then
    FTaken.ResetEvent;
  Unlock;
  if Pending then
    FTaken.WaitFor(ATimeoutMs);
end;

function TGpuVkPresenter.SurfaceLost: Boolean;
begin
  Lock;
  Result := FSurfaceLost;
  Unlock;
end;

procedure TGpuVkPresenter.LoseSurface;
begin
  ReleaseChain(True);
  Lock;
  FSurfaceLost := True;
  FPending := False;
  FTaken.SetEvent;
  Unlock;
end;

procedure TGpuVkPresenter.Stop;
begin
  Terminate;
  FWake.SetEvent;
  WaitFor;
  Release;
end;

procedure TGpuVkPresenter.WaitValue(const AValue: UInt64);
begin
  if (AValue = 0) or (FTimeline = nil) then
    Exit;
  FTimeline.Wait(AValue);
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
  if FTimePool <> VK_NULL_HANDLE then
    FVk.DestroyQueryPool(FDevice, FTimePool, nil);
  FTimePool := VK_NULL_HANDLE;
  FTimed := nil;
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
  if FTimeline = nil then
    Exit;
  ReleaseChain(True);
  FVk.DestroyCommandPool(FDevice, FPool, nil);
  FreeAndNil(FTimeline);
  FVk.DestroyFence(FDevice, FAcquired, nil);
  FPool := VK_NULL_HANDLE;
end;

function TGpuVkPresenter.CreateChain(const AWidth, AHeight: Integer): Boolean;
var
  Caps: TVkSurfaceCapabilitiesKHR;
  Extent: TVkExtent2D;
  Info: TVkSwapchainCreateInfoKHR;
  AllocInfo: TVkCommandBufferAllocateInfo;
  SemInfo: TVkSemaphoreCreateInfo;
  PoolInfo: TVkQueryPoolCreateInfo;
  Old, Chain: TVkSwapchainKHR;
  Count: Cardinal;
  K: Integer;
  Res: TVkResult;
begin
  Result := False;
  Res := FFast.Track(FFast.InstanceVk.GetPhysicalDeviceSurfaceCapabilitiesKHR(FFast.Physical, FWindow.FVkSurface,
    @Caps));
  if Res = VK_ERROR_SURFACE_LOST_KHR then
  begin
    LoseSurface;
    Exit;
  end;
  if Ord(Res) < 0 then
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
  Info.presentMode := FWindow.PresentMode;
  Info.oldSwapchain := Old;
  Chain := VK_NULL_HANDLE;
  Res := FFast.Track(FVk.CreateSwapchainKHR(FDevice, @Info, nil, @Chain));
  if (Res = VK_ERROR_SURFACE_LOST_KHR) or (Res = VK_ERROR_NATIVE_WINDOW_IN_USE_KHR) then
  begin
    // The old swap chain is retired all the same: it goes with the surface.
    LoseSurface;
    Exit;
  end;
  FFast.Check(Res, 'vkCreateSwapchainKHR');
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
  if GTimeTarget <> '' then
  begin
    FillChar(PoolInfo, SizeOf(PoolInfo), 0);
    PoolInfo.sType := VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO;
    PoolInfo.queryType := VK_QUERY_TYPE_TIMESTAMP;
    PoolInfo.queryCount := 2 * Count;
    FFast.Check(FVk.CreateQueryPool(FDevice, @PoolInfo, nil, @FTimePool), 'vkCreateQueryPool');
    SetLength(FTimed, Count);
  end;
  FExtent := Extent;
  FStale := False;
  Result := True;
end;

procedure TGpuVkPresenter.Record_(const AIndex: Integer; const AShown: TGpuVkSurface);
var
  Begin_: TVkCommandBufferBeginInfo;
  Q: array[0..1] of UInt64;
begin
  // The command buffer's last execution is done before it is recorded again.
  WaitValue(FCmdValues[AIndex]);
  if (FTimePool <> VK_NULL_HANDLE) and FTimed[AIndex] and (FCmdValues[AIndex] <> 0) then
  begin
    FTimed[AIndex] := False;
    if FVk.GetQueryPoolResults(FDevice, FTimePool, 2 * AIndex, 2, SizeOf(Q), @Q[0], SizeOf(UInt64),
      Ord(VK_QUERY_RESULT_64_BIT)) = VK_SUCCESS then
    begin
      TInterlocked.Add(GTimeCopyNs, Round(((Q[1] - Q[0]) and GTimeMask) * GTimePeriod));
      TInterlocked.Increment(GTimeCopies);
    end;
  end;
  FFast.Check(FVk.ResetCommandBuffer(FCmds[AIndex], 0), 'vkResetCommandBuffer');
  FillChar(Begin_, SizeOf(Begin_), 0);
  Begin_.sType := VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
  FFast.Check(FVk.BeginCommandBuffer(FCmds[AIndex], @Begin_), 'vkBeginCommandBuffer');
  if FTimePool <> VK_NULL_HANDLE then
  begin
    FVk.CmdResetQueryPool(FCmds[AIndex], FTimePool, 2 * AIndex, 2);
    FVk.CmdWriteTimestamp(FCmds[AIndex], VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, FTimePool, 2 * AIndex);
  end;
  RecordChainCopy(FFast, FCmds[AIndex], AShown, FImages[AIndex], FFormat.format, FExtent);
  if FTimePool <> VK_NULL_HANDLE then
  begin
    FVk.CmdWriteTimestamp(FCmds[AIndex], VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, FTimePool, 2 * AIndex + 1);
    FTimed[AIndex] := True;
  end;
  FFast.Check(FVk.EndCommandBuffer(FCmds[AIndex]), 'vkEndCommandBuffer');
  FCmdGens[AIndex] := FShownGen;
end;

function TGpuVkPresenter.PresentPending: Boolean;
var
  Shown: TGpuVkSurface;
  W, H, Attempt: Integer;
  Index: Cardinal;
  Res: TVkResult;
  Info: TVkPresentInfoKHR;
  Sem: TVkSemaphore;
  Fence: TVkFence;
begin
  Result := False;
  Lock;
  try
    Shown := FWindow.FShown;
    if not FPending or (Shown = nil) then
      Exit;
    if FSurfaceLost then
    begin
      FPending := False;
      FTaken.SetEvent;
      Exit;
    end;
    W := Shown.Width;
    H := Shown.Height;
    if FStaleAsked then
    begin
      FStaleAsked := False;
      FStale := True;
    end;
  finally
    Unlock;
  end;
  if FFast.Lost then
    Exit;
  if FStale or (FSwapchain = VK_NULL_HANDLE) or (W <> FCheckedW) or (H <> FCheckedH) then
  begin
    FCheckedW := W;
    FCheckedH := H;
    if not CreateChain(W, H) then
    begin
      // No size (minimized) or no surface: nothing to show.
      Lock;
      FPending := False;
      FTaken.SetEvent;
      Unlock;
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
  if Res = VK_ERROR_SURFACE_LOST_KHR then
  begin
    LoseSurface;
    Exit;
  end;
  if (Res <> VK_SUCCESS) and (Res <> VK_SUBOPTIMAL_KHR) then
  begin
    FStale := True;
    Exit;
  end;
  // Suboptimal: made again for the next frame. Not on Android, where it stays suboptimal while the display is turned
  // from its natural orientation (the images are unrotated, FillChainInfo).
{$IFNDEF ANDROID}
  if Res = VK_SUBOPTIMAL_KHR then
    FStale := True;
{$ENDIF}
  repeat
    Res := FFast.Track(FVk.WaitForFences(FDevice, 1, @FAcquired, VK_TRUE, 100000000));
  until (Res <> VK_TIMEOUT) or FFast.Lost;
  FVk.ResetFences(FDevice, 1, @FAcquired);
  if FFast.Lost then
    Exit;
  // The newest frame: the render thread may have posted another meanwhile, or a copy of another size.
  Lock;
  try
    Shown := FWindow.FShown;
    FPending := False;
    FTaken.SetEvent;
    if FCmdGens[Index] <> FShownGen then
      Record_(Index, Shown);
    FValue := FTimeline.Next(Fence);
    Sem := FPresentSems[Index];
    FillChar(Info, SizeOf(Info), 0);
    Info.sType := VK_STRUCTURE_TYPE_PRESENT_INFO_KHR;
    Info.waitSemaphoreCount := 1;
    Info.pWaitSemaphores := @Sem;
    Info.swapchainCount := 1;
    Info.pSwapchains := @FSwapchain;
    Info.pImageIndices := @Index;
    FFast.LockQueue;
    try
      Res := FFast.Track(QueueSubmit(FFast, FCmds[Index], VK_NULL_HANDLE, 0, Sem, FTimeline, FValue, Fence));
      if Ord(Res) >= 0 then
        Res := FFast.Track(FVk.QueuePresentKHR(FFast.Queue, @Info))
      else
        // The submission's work is gone and the timeline never gets its value: the device is made again.
        FFast.Track(VK_ERROR_DEVICE_LOST);
    finally
      FFast.UnlockQueue;
    end;
  finally
    Unlock;
  end;
  FCmdValues[Index] := FValue;
  if (Res <> VK_SUCCESS) {$IFDEF ANDROID}and (Res <> VK_SUBOPTIMAL_KHR){$ENDIF} then
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
var
  Needs: Cardinal;
  V: TGpuVkVariant;
begin
  inherited Create;
  FBoundGen := -1;
  FConstGen := -1;
  FSetGen := -1;
  for Needs := 0 to GpuNeedAll do
  begin
    GVariantOf[Needs] := TGpuVkVariant.Full;
    for V := Low(TGpuVkVariant) to High(TGpuVkVariant) do
      if ((Needs and not VariantNeeds[V]) = 0) and (VariantCost[V] < VariantCost[GVariantOf[Needs]]) then
        GVariantOf[Needs] := V;
  end;
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
  V: TGpuVkVariant;
begin
  C := GCtx;
  if C <> nil then
  begin
    // Submitted command buffers may still use them.
    for I := 0 to 3 do
    begin
      C.Retire(TGpuVkObject.Pipeline, FPipeBlend[I]);
      C.Retire(TGpuVkObject.Pipeline, FPipeCopy[I]);
      C.Retire(TGpuVkObject.Pipeline, FPipeDual[I]);
      for V := Low(TGpuVkVariant) to High(TGpuVkVariant) do
        C.Retire(TGpuVkObject.Pipeline, FVariantPipes[I, V]);
    end;
    for I := 0 to 1 do
    begin
      C.Retire(TGpuVkObject.Pipeline, FInteriorPipes[I]);
      for V := Low(TGpuVkVariant) to High(TGpuVkVariant) do
        C.Retire(TGpuVkObject.Pipeline, FMeshPipes[I, V]);
    end;
    C.Retire(TGpuVkObject.ShaderModule, FVSMeshZ);
    C.Retire(TGpuVkObject.ShaderModule, FVSFlatZ);
    C.Retire(TGpuVkObject.ShaderModule, FVSInterior);
    C.Retire(TGpuVkObject.ShaderModule, FPSInterior);
    for V := Low(TGpuVkVariant) to High(TGpuVkVariant) do
      C.Retire(TGpuVkObject.ShaderModule, FVariantPS[V]);
    C.Retire(TGpuVkObject.ShaderModule, FVSFlat);
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

function TGpuVkRenderer.NewPipeline(const AFormat: TVkFormat; const ABlend, ADual: Boolean;
  const APixel, AVertex: TVkShaderModule; const ADepth: Integer; const AGeometry: TGpuVkGeometry): TVkPipeline;
const
  MainVS: PAnsiChar = 'VSMain';
  MainPS: PAnsiChar = 'PSMain';
  MainDual: PAnsiChar = 'PSMainDual';
  InteriorVS: PAnsiChar = 'VSInterior';
  InteriorPS: PAnsiChar = 'PSInterior';
  MeshVS: PAnsiChar = 'VSMesh';
var
  C: TGpuVkContext;
  Stages: array[0..1] of TVkPipelineShaderStageCreateInfo;
  Bindings: array[0..1] of TVkVertexInputBindingDescription;
  Attributes: array[0..6] of TVkVertexInputAttributeDescription;
  DepthState: TVkPipelineDepthStencilStateCreateInfo;
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

  procedure Attribute(const AIndex: Integer; const AFormat: TVkFormat; const AOffset: Cardinal;
    const ABinding: Cardinal = 0);
  begin
    Attributes[AIndex].location := AIndex;
    Attributes[AIndex].binding := ABinding;
    Attributes[AIndex].format := AFormat;
    Attributes[AIndex].offset := AOffset;
  end;

begin
  C := GpuVk;
  FillChar(Stages, SizeOf(Stages), 0);
  Stages[0].sType := VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
  Stages[0].stage := VK_SHADER_STAGE_VERTEX_BIT;
  Stages[0].module := FVS;
  if AVertex <> VK_NULL_HANDLE then
    Stages[0].module := AVertex;
  case AGeometry of
    TGpuVkGeometry.Interiors: Stages[0].pName := InteriorVS;
    TGpuVkGeometry.Meshes: Stages[0].pName := MeshVS;
  else
    Stages[0].pName := MainVS;
  end;
  Stages[1].sType := VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
  Stages[1].stage := VK_SHADER_STAGE_FRAGMENT_BIT;
  if APixel <> VK_NULL_HANDLE then
  begin
    Stages[1].module := APixel;
    if AGeometry = TGpuVkGeometry.Interiors then
      Stages[1].pName := InteriorPS
    else
      Stages[1].pName := MainPS;
  end
  else if ADual then
  begin
    Stages[1].module := FPSDual;
    Stages[1].pName := MainDual;
  end
  else
  begin
    Stages[1].module := FPS;
    Stages[1].pName := MainPS;
  end;
  FillChar(Bindings, SizeOf(Bindings), 0);
  FillChar(Attributes, SizeOf(Attributes), 0);
  FillChar(VertexInput, SizeOf(VertexInput), 0);
  VertexInput.sType := VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
  VertexInput.vertexBindingDescriptionCount := 1;
  VertexInput.vertexAttributeDescriptionCount := 6;
  if AGeometry = TGpuVkGeometry.Interiors then
  begin
    // Triangles of TGpuVkInteriorVertex.
    Bindings[0].binding := 0;
    Bindings[0].stride := SizeOf(TGpuVkInteriorVertex);
    Bindings[0].inputRate := VK_VERTEX_INPUT_RATE_VERTEX;
    Attribute(0, VK_FORMAT_R32G32B32_SFLOAT, 0);
    Attribute(1, VK_FORMAT_R32G32B32A32_SFLOAT, 12);
    VertexInput.vertexAttributeDescriptionCount := 2;
  end
  else
  begin
    // One instance per primitive (a strip of four vertices); the first 84 bytes of TGpuInstance.
    Bindings[0].binding := 0;
    Bindings[0].stride := GpuInstanceStride;
    Bindings[0].inputRate := VK_VERTEX_INPUT_RATE_INSTANCE;
    Attribute(0, VK_FORMAT_R32G32B32A32_SFLOAT, 0);
    Attribute(1, VK_FORMAT_R32G32B32A32_SFLOAT, 16);
    Attribute(2, VK_FORMAT_R32G32B32A32_SFLOAT, 32);
    Attribute(3, VK_FORMAT_R32G32B32A32_SFLOAT, 48);
    Attribute(4, VK_FORMAT_R32G32B32A32_UINT, 64);
    Attribute(5, VK_FORMAT_R32_SFLOAT, 80);
    if AGeometry = TGpuVkGeometry.Meshes then
    begin
      // And the local positions of the triangles (two floats a vertex).
      Bindings[1].binding := 1;
      Bindings[1].stride := 8;
      Bindings[1].inputRate := VK_VERTEX_INPUT_RATE_VERTEX;
      Attribute(6, VK_FORMAT_R32G32_SFLOAT, 0, 1);
      VertexInput.vertexBindingDescriptionCount := 2;
      VertexInput.vertexAttributeDescriptionCount := 7;
    end;
  end;
  VertexInput.pVertexBindingDescriptions := @Bindings[0];
  VertexInput.pVertexAttributeDescriptions := @Attributes[0];
  FillChar(Assembly, SizeOf(Assembly), 0);
  Assembly.sType := VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
  if AGeometry = TGpuVkGeometry.Quads then
    Assembly.topology := VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP
  else
    Assembly.topology := VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
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
  FillChar(DepthState, SizeOf(DepthState), 0);
  DepthState.sType := VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO;
  if ADepth > 0 then
  begin
    // The depth buffer of opaque interiors (its stencil aspect unused): later instances are closer.
    Rendering.depthAttachmentFormat := C.Fast.DepthFormat;
    Rendering.stencilAttachmentFormat := C.Fast.DepthFormat;
    DepthState.depthTestEnable := Ord(ADepth >= 2);
    DepthState.depthWriteEnable := Ord(ADepth >= 3);
    DepthState.depthCompareOp := VK_COMPARE_OP_LESS;
    DepthState.maxDepthBounds := 1;
  end;
  FillChar(Info, SizeOf(Info), 0);
  Info.sType := VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
  try
    C.Fast.PipelineTarget(Info, @Rendering, 1);
  except
    on E: EFastVulkan do
      raise EFastDevice.Create(E.Message);
  end;
  if ADepth > 0 then
    Info.pDepthStencilState := @DepthState;
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
  Push: TVkPushConstantRange;
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
  // The depth number base of a draw (shader DepthConstants; vertex shaders of targets with a depth buffer).
  Push.stageFlags := Ord(VK_SHADER_STAGE_VERTEX_BIT);
  Push.offset := 0;
  Push.size := SizeOf(Cardinal);
  LayoutInfo.pushConstantRangeCount := 1;
  LayoutInfo.pPushConstantRanges := @Push;
  C.Check(C.Vk.CreatePipelineLayout(C.Device, @LayoutInfo, nil, @FLayout), 'vkCreatePipelineLayout');
  FVS := NewModule(@FastCanvasVkVS[0], Length(FastCanvasVkVS));
  FPS := NewModule(@FastCanvasVkPS[0], Length(FastCanvasVkPS));
  FPipeBlend[0] := NewPipeline(VK_FORMAT_B8G8R8A8_UNORM, True, False);
  FPipeCopy[0] := NewPipeline(VK_FORMAT_B8G8R8A8_UNORM, False, False);
  // The variants: a phone (Mali-G57) shades large areas several times faster with them; a discrete GPU shades fast
  // enough anyway, and their vertex shader and splits only cost it (2026-10-14, RX 9070 XT: paragraph light 1950
  // against 1370 FPS).
  FVariants := C.Fast.Properties.deviceType <> VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU;
  if GetEnvironmentVariable(VariantVariable) = '0' then
    FVariants := False
  else if GetEnvironmentVariable(VariantVariable) = '1' then
    FVariants := True;
  // A draw costs a phone about what some ten thousand pixels of a cheaper variant save. Paths: bands of two pixels
  // (a pixel of the wave of PortProbe goes through about a third of the edges of six-edge bands).
  FSplitCost := 16384;
  if FVariants then
    FBandPixels := 2;
  // Opaque interiors where the variants are (they draw through them), unless turned off.
  FInteriors := FVariants and (C.Fast.DepthFormat <> VK_FORMAT_UNDEFINED) and
    (GetEnvironmentVariable(InteriorVariable) <> '0');
  // Paths as pieces need the depth buffer of the interiors.
  FPathMeshes := FInteriors and (GetEnvironmentVariable(PathMeshVariable) <> '0');
  SetLength(FRampTexels, GpuRampRows);
  SetLength(FRampLinear, GpuRampRows);

  FAtlas := NewTexture(VK_FORMAT_R8_UNORM, GpuAtlasSize, GpuAtlasSize);
  FRamps := NewTexture(VK_FORMAT_R8G8B8A8_UNORM, GpuRampWidth, GpuRampRows);
  // The texture of a slot without one (and of a slot whose texture is the target).
  FEmpty := NewTexture(VK_FORMAT_B8G8R8A8_UNORM, 1, 1);
  FClips := NewTable(GpuMaxClips * GpuClipFloat4s);
  FPaints := NewTable(GpuMaxPaints * GpuPaintFloat4s);
  CreateEdgeTable(GpuEdgesInitial);
end;

function TGpuVkRenderer.TargetSlot: Integer;
begin
  Result := Ord(TGpuVkSurface(FTarget).Format = VK_FORMAT_R8G8B8A8_UNORM);
  // The rendering instance the draw goes into has the depth buffer (TGpuVkContext.StartTarget: the target wants one).
  if GpuVk.RenderingDepth then
    Inc(Result, 2);
end;

function TGpuVkRenderer.TargetPipeline: TVkPipeline;
var
  S: Integer;
begin
  S := TargetSlot;
  if FDual and not FCopy and GpuVk.Fast.DualSource then
  begin
    // ClearType text in the frame: everything blends with the second output (the same result for the rest).
    if FPipeDual[S] = VK_NULL_HANDLE then
    begin
      if FPSDual = VK_NULL_HANDLE then
        FPSDual := NewModule(@FastCanvasVkPSDual[0], Length(FastCanvasVkPSDual));
      FPipeDual[S] := NewPipeline(SlotFormats[S], True, True, VK_NULL_HANDLE, VK_NULL_HANDLE, Ord(S >= 2));
    end;
    Exit(FPipeDual[S]);
  end;
  // With the depth buffer: no test (these draws come after everything before them).
  if FCopy then
  begin
    if FPipeCopy[S] = VK_NULL_HANDLE then
      FPipeCopy[S] := NewPipeline(SlotFormats[S], False, False, VK_NULL_HANDLE, VK_NULL_HANDLE, Ord(S >= 2));
    Result := FPipeCopy[S];
  end
  else
  begin
    if FPipeBlend[S] = VK_NULL_HANDLE then
      FPipeBlend[S] := NewPipeline(SlotFormats[S], True, False, VK_NULL_HANDLE, VK_NULL_HANDLE, Ord(S >= 2));
    Result := FPipeBlend[S];
  end;
end;

function TGpuVkRenderer.VariantPipeline(const AVariant: TGpuVkVariant): TVkPipeline;
var
  Code: Pointer;
  Words, S: Integer;
begin
  S := TargetSlot;
  Result := FVariantPipes[S, AVariant];
  if Result <> VK_NULL_HANDLE then
    Exit;
  // Targets with the depth buffer: the vertex shader with the instances' depth, the depth test.
  if (S >= 2) and (FVSFlatZ = VK_NULL_HANDLE) then
    FVSFlatZ := NewModule(@FastCanvasVkVSFlatZ[0], Length(FastCanvasVkVSFlatZ));
  if FVariantPS[AVariant] <> VK_NULL_HANDLE then
  begin
    if S >= 2 then
      Result := NewPipeline(SlotFormats[S], True, False, FVariantPS[AVariant], FVSFlatZ, 2)
    else
      Result := NewPipeline(SlotFormats[S], True, False, FVariantPS[AVariant], FVSFlat);
    FVariantPipes[S, AVariant] := Result;
    Exit;
  end;
  case AVariant of
    TGpuVkVariant.Shapes:
      begin
        Code := @FastCanvasVkPSShapes[0];
        Words := Length(FastCanvasVkPSShapes);
      end;
    TGpuVkVariant.ShapesClip:
      begin
        Code := @FastCanvasVkPSShapesClip[0];
        Words := Length(FastCanvasVkPSShapesClip);
      end;
    TGpuVkVariant.Glyphs:
      begin
        Code := @FastCanvasVkPSGlyphs[0];
        Words := Length(FastCanvasVkPSGlyphs);
      end;
    TGpuVkVariant.GlyphsClip:
      begin
        Code := @FastCanvasVkPSGlyphsClip[0];
        Words := Length(FastCanvasVkPSGlyphsClip);
      end;
    TGpuVkVariant.Images:
      begin
        Code := @FastCanvasVkPSImages[0];
        Words := Length(FastCanvasVkPSImages);
      end;
    TGpuVkVariant.ImagesClip:
      begin
        Code := @FastCanvasVkPSImagesClip[0];
        Words := Length(FastCanvasVkPSImagesClip);
      end;
    TGpuVkVariant.Ui:
      begin
        Code := @FastCanvasVkPSUi[0];
        Words := Length(FastCanvasVkPSUi);
      end;
    TGpuVkVariant.UiClip:
      begin
        Code := @FastCanvasVkPSUiClip[0];
        Words := Length(FastCanvasVkPSUiClip);
      end;
    TGpuVkVariant.Paths:
      begin
        Code := @FastCanvasVkPSPaths[0];
        Words := Length(FastCanvasVkPSPaths);
      end;
    TGpuVkVariant.PathsClip:
      begin
        Code := @FastCanvasVkPSPathsClip[0];
        Words := Length(FastCanvasVkPSPathsClip);
      end;
  else
    Code := @FastCanvasVkPSFlat[0];
    Words := Length(FastCanvasVkPSFlat);
  end;
  if FVSFlat = VK_NULL_HANDLE then
    FVSFlat := NewModule(@FastCanvasVkVSFlat[0], Length(FastCanvasVkVSFlat));
  FVariantPS[AVariant] := NewModule(Code, Words);
  if S >= 2 then
    Result := NewPipeline(SlotFormats[S], True, False, FVariantPS[AVariant], FVSFlatZ, 2)
  else
    Result := NewPipeline(SlotFormats[S], True, False, FVariantPS[AVariant], FVSFlat);
  FVariantPipes[S, AVariant] := Result;
end;

/// <summary>Greedy: an instance joins the run when the run's variant draws it, or when the variant that draws both
/// costs the pixels of the run and its own less than a draw more would (FSplitCost); a large instance that a cheaper
/// variant draws starts a run of its own. The order of the instances is kept (they blend in it).</summary>
function TGpuVkRenderer.Hollow(const AIndex: Integer; out ABands: TGpuBands; out ACount: Integer): Boolean;
var
  Area: Single;
begin
  // Four draws more pay for an inside of this many pixels of a small shader.
  Result := ((FPending[AIndex].Flags and 15) = GpuKindStrokeRect) and HollowBands(@FPending[AIndex], ABands, ACount,
    Area) and (Area * VariantCost[TGpuVkVariant.Shapes] > 4 * FSplitCost);
end;

function TGpuVkRenderer.NextRun(const AFirst: Integer; out AVariant: TGpuVkVariant): Integer;
var
  I, BandCount: Integer;
  Needs, Run: Cardinal;
  Area, RunArea: Single;
  V, Own, Joint: TGpuVkVariant;
  Bands: TGpuBands;
begin
  Run := InstanceNeeds(@FPending[AFirst], RunArea);
  V := GVariantOf[Run];
  I := AFirst + 1;
  while I < FPendingCount do
  begin
    // An outline drawn around its inside (DrawPending) is a run of its own, and so is a path drawn as pieces.
    if Hollow(I, Bands, BandCount) or (FRunStopMesh and ((FPending[I].Flags and GpuMesh) <> 0)) then
      Break;
    Needs := InstanceNeeds(@FPending[I], Area);
    Own := GVariantOf[Needs];
    if (Needs and not VariantNeeds[V]) = 0 then
    begin
      if Area * (VariantCost[V] - VariantCost[Own]) > FSplitCost then
        Break;
    end
    else
    begin
      Joint := GVariantOf[Run or Needs];
      if RunArea * (VariantCost[Joint] - VariantCost[V]) + Area * (VariantCost[Joint] - VariantCost[Own]) >
        FSplitCost then
        Break;
      Run := Run or Needs;
      V := Joint;
    end;
    RunArea := RunArea + Area;
    Inc(I);
  end;
  AVariant := V;
  Result := I - AFirst;
end;

function TGpuVkRenderer.InteriorPaint(const AInstance: PGpuInstance; out ARow: Integer): Boolean;
var
  P: PGpuInstance;
  Area: Single;
  G: ^TGpuPaint;
begin
  Result := False;
  P := AInstance;
  ARow := -1;
  if (P.Color shr 24) <> 255 then
    Exit;
  if (InstanceNeeds(P, Area) and (GpuNeedClips or GpuNeedBrushes)) <> 0 then
    Exit;
  if P.Paint <> 0 then
  begin
    // A linear gradient over a ramp that is opaque and linear.
    if P.Paint > Cardinal(Length(FPaintData)) then
      Exit;
    G := @FPaintData[P.Paint - 1];
    if G.Data[11] >= 1.5 then
      Exit;
    ARow := Trunc(G.Data[10] * GpuRampRows);
    if (ARow < 0) or (ARow >= Length(FRampLinear)) or not FRampLinear[ARow] or
      not (Sqr(G.Data[2] - G.Data[0]) + Sqr(G.Data[3] - G.Data[1]) > 1E-12) then
      Exit;
  end;
  Result := True;
end;

function TGpuVkRenderer.InteriorVertex(const AInstance: PGpuInstance; const ARow: Integer; const X, Y, AZ: Single;
  var AOut: PGpuVkInteriorVertex): Boolean;
var
  P: PGpuInstance;
  G: ^TGpuPaint;
  Ex, Ey, T, U, F: Single;
  K: Integer;
  C0, C1: Cardinal;
begin
  P := AInstance;
  AOut.X := X * P.M11 + Y * P.M21 + P.Dx;
  AOut.Y := X * P.M12 + Y * P.M22 + P.Dy;
  AOut.Z := AZ;
  AOut.A := 1;
  if ARow < 0 then
  begin
    // The color the shader unpacks.
    AOut.R := ((P.Color shr 16) and 255) / 255;
    AOut.G := ((P.Color shr 8) and 255) / 255;
    AOut.B := (P.Color and 255) / 255;
  end
  else
  begin
    // The gradient there, without clamping (else no interior), from the ramp as the sampler reads it: texel centers
    // at t * 255.
    G := @FPaintData[P.Paint - 1];
    Ex := G.Data[2] - G.Data[0];
    Ey := G.Data[3] - G.Data[1];
    T := ((X - G.Data[0]) * Ex + (Y - G.Data[1]) * Ey) / (Ex * Ex + Ey * Ey);
    if not ((T >= 0) and (T <= 1)) then
      Exit(False);
    U := T * (GpuRampWidth - 1);
    K := Min(Trunc(U), GpuRampWidth - 2);
    F := U - K;
    C0 := FRampTexels[ARow][K];
    C1 := FRampTexels[ARow][K + 1];
    AOut.R := ((C0 and 255) * (1 - F) + (C1 and 255) * F) / 255;
    AOut.G := (((C0 shr 8) and 255) * (1 - F) + ((C1 shr 8) and 255) * F) / 255;
    AOut.B := (((C0 shr 16) and 255) * (1 - F) + ((C1 shr 16) and 255) * F) / 255;
  end;
  Inc(AOut);
  Result := True;
end;

function TGpuVkRenderer.InteriorOf(const AInstance: PGpuInstance; const AZ: Single;
  const AOut: PGpuVkInteriorVertex): Boolean;
const
  // Margins in pixels (local units of one pixel, see the shader's w): half a pixel, so that the coverage is 1 at
  // every pixel center inside, and a little more for rounding.
  HalfPixel = 0.52;
var
  P: PGpuInstance;
  Area, Det, W, Mx, My, X0, Y0, X1, Y1: Single;
  Row: Integer;
  V: PGpuVkInteriorVertex;
begin
  Result := False;
  P := AInstance;
  if (P.Flags and 15) <> GpuKindFillRect then
    Exit;
  InstanceNeeds(P, Area);
  // Too small for the triangles to pay.
  if (Area < 256) or not InteriorPaint(P, Row) then
    Exit;
  Det := P.M11 * P.M22 - P.M12 * P.M21;
  if not (Abs(Det) > 1E-12) then
    Exit;
  // The size of a pixel in local units as the shader takes it from the derivatives of the local position.
  W := Sqrt(0.5 * (Sqr(P.M11) + Sqr(P.M12) + Sqr(P.M21) + Sqr(P.M22))) / Abs(Det);
  Mx := HalfPixel * W;
  My := Mx;
  // Rounded corners: inside them on both axes.
  if (((P.Flags shr GpuCornerShift) and 15) <> 0) and (P.Rx > 0) and (P.Ry > 0) then
  begin
    Mx := Mx + Abs(P.Rx);
    My := My + Abs(P.Ry);
  end;
  X0 := Min(P.X0, P.X1) + Mx;
  X1 := Max(P.X0, P.X1) - Mx;
  Y0 := Min(P.Y0, P.Y1) + My;
  Y1 := Max(P.Y0, P.Y1) - My;
  if not ((X1 - X0) * (Y1 - Y0) * Abs(Det) >= 64) or not (Abs(X0) + Abs(X1) + Abs(Y0) + Abs(Y1) < 1E7) then
    Exit;
  V := AOut;
  Result := InteriorVertex(P, Row, X0, Y0, AZ, V) and InteriorVertex(P, Row, X1, Y0, AZ, V) and
    InteriorVertex(P, Row, X0, Y1, AZ, V) and InteriorVertex(P, Row, X1, Y0, AZ, V) and
    InteriorVertex(P, Row, X1, Y1, AZ, V) and InteriorVertex(P, Row, X0, Y1, AZ, V);
end;

function TGpuVkRenderer.MeshInterior(const AInstance: PGpuInstance; const ARef: Integer; const AZ: Single;
  const AOut: PGpuVkInteriorVertex): Integer;
var
  P: PGpuInstance;
  R: ^TGpuVkMeshRef;
  S: ^TGpuVkPiece;
  Row, I: Integer;
  V: PGpuVkInteriorVertex;
begin
  // The solid pieces of an opaque path (PathCoverage is 1 at their pixel centers).
  Result := 0;
  P := AInstance;
  R := @FMeshRefs[ARef];
  if (R.Solid = 0) or not InteriorPaint(P, Row) then
    Exit;
  V := AOut;
  for I := 0 to R.Solid - 1 do
  begin
    S := @FMeshPieces[R.First + R.Cover + I];
    if not (InteriorVertex(P, Row, S.L0, S.Y0, AZ, V) and InteriorVertex(P, Row, S.R0, S.Y0, AZ, V) and
      InteriorVertex(P, Row, S.L1, S.Y1, AZ, V) and InteriorVertex(P, Row, S.R0, S.Y0, AZ, V) and
      InteriorVertex(P, Row, S.R1, S.Y1, AZ, V) and InteriorVertex(P, Row, S.L1, S.Y1, AZ, V)) then
      // A gradient that clamps there: the whole path in pass two.
      Exit(0);
    Inc(Result, 6);
  end;
end;

procedure TGpuVkRenderer.DrawInteriors(const ABase: Cardinal);
var
  C: TGpuVkContext;
  I, N, S, Ref, Need: Integer;
  Z: Single;
  P: PByte;
  Buffer: TVkBuffer;
  Offset: UInt64;
begin
  N := 0;
  Need := 6 * FPendingCount + 6 * FMeshPieceCount;
  if Length(FInteriorData) < Need then
    SetLength(FInteriorData, Max(Need, 2 * Length(FInteriorData)));
  Ref := FMeshRefCount - 1;
  // Front to back: the later an instance, the closer (the GPU drops what an earlier one would shade under it).
  for I := FPendingCount - 1 downto 0 do
  begin
    Z := 1 - (ABase + Cardinal(I) + 1) * (1 / DepthNumbers);
    if (FPending[I].Flags and GpuMesh) <> 0 then
    begin
      while (Ref >= 0) and (FMeshRefs[Ref].Index > I) do
        Dec(Ref);
      if (Ref >= 0) and (FMeshRefs[Ref].Index = I) then
        Inc(N, MeshInterior(@FPending[I], Ref, Z, @FInteriorData[N]));
    end
    else if InteriorOf(@FPending[I], Z, @FInteriorData[N]) then
      Inc(N, 6);
  end;
  if N = 0 then
    Exit;
  C := GpuVk;
  P := C.Upload(N * SizeOf(TGpuVkInteriorVertex), 16, Buffer, Offset);
  Move(FInteriorData[0], P^, N * SizeOf(TGpuVkInteriorVertex));
  S := TargetSlot and 1;
  if FInteriorPipes[S] = VK_NULL_HANDLE then
  begin
    if FVSInterior = VK_NULL_HANDLE then
      FVSInterior := NewModule(@FastCanvasVkVSInterior[0], Length(FastCanvasVkVSInterior));
    if FPSInterior = VK_NULL_HANDLE then
      FPSInterior := NewModule(@FastCanvasVkPSInterior[0], Length(FastCanvasVkPSInterior));
    FInteriorPipes[S] := NewPipeline(SlotFormats[S], False, False, FPSInterior, FVSInterior, 3,
      TGpuVkGeometry.Interiors);
  end;
  if FBoundPipe <> FInteriorPipes[S] then
  begin
    C.Vk.CmdBindPipeline(C.Cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, FInteriorPipes[S]);
    FBoundPipe := FInteriorPipes[S];
  end;
  C.Vk.CmdBindVertexBuffers(C.Cmd, 0, 1, @Buffer, @Offset);
  C.Vk.CmdDraw(C.Cmd, N, 1, 0, 0);
  Inc(FDrawCalls);
end;

procedure TGpuVkRenderer.AddMesh(const APieces: Pointer; const ACover, ASolid: Integer);
var
  R: ^TGpuVkMeshRef;
begin
  if not FPathMeshes or (FPendingCount = 0) or (ACover <= 0) then
    Exit;
  if FMeshRefCount = Length(FMeshRefs) then
    SetLength(FMeshRefs, Max(16, 2 * FMeshRefCount));
  if FMeshPieceCount + ACover + ASolid > Length(FMeshPieces) then
    SetLength(FMeshPieces, Max(FMeshPieceCount + ACover + ASolid, 2 * Length(FMeshPieces)));
  R := @FMeshRefs[FMeshRefCount];
  Inc(FMeshRefCount);
  R.Index := FPendingCount - 1;
  R.First := FMeshPieceCount;
  R.Cover := ACover;
  R.Solid := ASolid;
  Move(APieces^, FMeshPieces[FMeshPieceCount], (ACover + ASolid) * SizeOf(TGpuVkPiece));
  Inc(FMeshPieceCount, ACover + ASolid);
  FPending[FPendingCount - 1].Flags := FPending[FPendingCount - 1].Flags or GpuMesh;
end;

function TGpuVkRenderer.UploadMeshes(out ABuffer: TVkBuffer; out AOffset: UInt64): Boolean;
var
  I, J, N: Integer;
  R: ^TGpuVkMeshRef;
  S: ^TGpuVkPiece;
  D: PSingle;
  P: PByte;

  procedure Put(const X, Y: Single);
  begin
    D^ := X;
    Inc(D);
    D^ := Y;
    Inc(D);
  end;

begin
  // The cover pieces of every path of the draw as triangles of local positions (TGpuVkMeshRef.Vertex: the first).
  N := 0;
  for I := 0 to FMeshRefCount - 1 do
    Inc(N, 6 * FMeshRefs[I].Cover);
  Result := N > 0;
  if not Result then
    Exit;
  P := GpuVk.Upload(N * 8, 16, ABuffer, AOffset);
  D := PSingle(P);
  N := 0;
  for I := 0 to FMeshRefCount - 1 do
  begin
    R := @FMeshRefs[I];
    R.Vertex := N;
    for J := 0 to R.Cover - 1 do
    begin
      S := @FMeshPieces[R.First + J];
      Put(S.L0, S.Y0);
      Put(S.R0, S.Y0);
      Put(S.L1, S.Y1);
      Put(S.R0, S.Y0);
      Put(S.R1, S.Y1);
      Put(S.L1, S.Y1);
    end;
    Inc(N, 6 * R.Cover);
  end;
end;

function TGpuVkRenderer.MeshPipeline(const AVariant: TGpuVkVariant): TVkPipeline;
var
  S: Integer;
begin
  S := TargetSlot and 1;
  Result := FMeshPipes[S, AVariant];
  if Result <> VK_NULL_HANDLE then
    Exit;
  // The variant's pixel shader (made with its pipeline).
  VariantPipeline(AVariant);
  if FVSMeshZ = VK_NULL_HANDLE then
    FVSMeshZ := NewModule(@FastCanvasVkVSMeshZ[0], Length(FastCanvasVkVSMeshZ));
  // The depth test and writes: a pixel two pieces of the path overlap at is shaded once.
  Result := NewPipeline(SlotFormats[S], True, False, FVariantPS[AVariant], FVSMeshZ, 3, TGpuVkGeometry.Meshes);
  FMeshPipes[S, AVariant] := Result;
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
  // Opaque interiors on large targets (windows, client-sized bitmaps): before their first rendering instance.
  if FInteriors and (ATarget <> nil) and (ATarget.Width * ATarget.Height >= DepthMinPixels) then
    TGpuVkSurface(ATarget).WantDepth := True;
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
  I, First, Count, BandCount: Integer;
  Variant: TGpuVkVariant;
  Variants: Boolean;
  Bands: TGpuBands;
  Area: Single;
  Base: Cardinal;
  MeshBuffer: TVkBuffer;
  MeshOffset: UInt64;
  Ref: Integer;
  Area_, Band: TRect;

  procedure SetScissorRect(const ACmd: TVkCommandBuffer; const R: TRect);
  begin
    Scissor.offset.x := R.Left;
    Scissor.offset.y := R.Top;
    Scissor.extent.width := Max(0, R.Width);
    Scissor.extent.height := Max(0, R.Height);
    C.Vk.CmdSetScissor(ACmd, 0, 1, @Scissor);
  end;

begin
  if (FPendingCount = 0) or (FTarget = nil) or (TGpuVkSurface(FTarget).Image = VK_NULL_HANDLE) then
  begin
    FPendingCount := 0;
    FMeshRefCount := 0;
    FMeshPieceCount := 0;
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
    FBoundW := FWidth;
    FBoundH := FHeight;
    FBoundScissor := TRect.Create(-1, -1, -1, -1);
  end;
  // The target, or the part a partial frame updates (SetScissor).
  Area_ := TRect.Create(0, 0, Max(0, Min(FWidth, Target.Width)), Max(0, Min(FHeight, Target.Height)));
  if not FScissor.IsEmpty then
    Area_.Intersect(FScissor);
  if Area_.IsEmpty then
    Area_ := TRect.Empty;
  if Area_ <> FBoundScissor then
  begin
    SetScissorRect(Cmd, Area_);
    FBoundScissor := Area_;
  end;
  C.Vk.CmdBindDescriptorSets(Cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, FLayout, 0, 1, @Set_, 0, nil);
  Variants := FVariants and not FCopy and not (FDual and C.Fast.DualSource);
  if Variants and C.RenderingDepth then
  begin
    // A depth number per instance, from where the rendering instance's numbers are (the depth buffer is cleared
    // when they run out), then the opaque interiors (pass one); the draws below test against them (pass two).
    if C.DepthCount + Cardinal(FPendingCount) >= DepthNumbers - 1 then
      C.ClearDepth;
    Base := C.DepthCount;
    C.DepthCount := Base + Cardinal(FPendingCount);
    C.Vk.CmdPushConstants(Cmd, FLayout, Ord(VK_SHADER_STAGE_VERTEX_BIT), 0, SizeOf(Base), @Base);
    DrawInteriors(Base);
  end;
  C.Vk.CmdBindVertexBuffers(Cmd, 0, 1, @Buffer, @Offset);
  // Paths with pieces on a target with the depth buffer: drawn by their cover pieces (local positions at binding 1).
  FRunStopMesh := Variants and C.RenderingDepth and UploadMeshes(MeshBuffer, MeshOffset);
  if FRunStopMesh then
    C.Vk.CmdBindVertexBuffers(Cmd, 1, 1, @MeshBuffer, @MeshOffset);
  Ref := 0;
  First := 0;
  while First < FPendingCount do
  begin
    if FRunStopMesh and ((FPending[First].Flags and GpuMesh) <> 0) then
    begin
      while (Ref < FMeshRefCount - 1) and (FMeshRefs[Ref].Index < First) do
        Inc(Ref);
      if FMeshRefs[Ref].Index = First then
      begin
        Pipe := MeshPipeline(GVariantOf[InstanceNeeds(@FPending[First], Area)]);
        if Pipe <> FBoundPipe then
        begin
          C.Vk.CmdBindPipeline(Cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, Pipe);
          FBoundPipe := Pipe;
        end;
        C.Vk.CmdDraw(Cmd, 6 * FMeshRefs[Ref].Cover, 1, FMeshRefs[Ref].Vertex, First);
        Inc(FDrawCalls);
        Inc(First);
        Continue;
      end;
    end;
    // Blending draws: runs of the variants of the pixel shader (the pipelines share the layout: the set stays
    // bound). Copies and dual-source blending: one draw with the full shader.
    BandCount := 0;
    if Variants and Hollow(First, Bands, BandCount) then
    begin
      Count := 1;
      Pipe := VariantPipeline(GVariantOf[InstanceNeeds(@FPending[First], Area)]);
    end
    else if Variants then
    begin
      Count := NextRun(First, Variant);
      Pipe := VariantPipeline(Variant);
    end
    else
    begin
      Count := FPendingCount;
      Pipe := TargetPipeline;
    end;
    if Pipe <> FBoundPipe then
    begin
      C.Vk.CmdBindPipeline(Cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, Pipe);
      FBoundPipe := Pipe;
    end;
    if BandCount > 0 then
    begin
      // A large rectangle outline: the same triangles in the rectangles around its inside (scissors), where its
      // pixels are; the inside, which it leaves as it is, is not shaded.
      for I := 0 to BandCount - 1 do
      begin
        Band := Bands[I];
        Band.Intersect(Area_);
        if Band.IsEmpty then
          Continue;
        SetScissorRect(Cmd, Band);
        C.Vk.CmdDraw(Cmd, 4, 1, 0, First);
        Inc(FDrawCalls);
      end;
      SetScissorRect(Cmd, Area_);
    end
    else
    begin
      C.Vk.CmdDraw(Cmd, 4, Count, 0, First);
      Inc(FDrawCalls);
    end;
    Inc(First, Count);
  end;
  FRunStopMesh := False;
  FPendingCount := 0;
  FMeshRefCount := 0;
  FMeshPieceCount := 0;
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
var
  P: PCardinal;
  I, K: Integer;
  Linear: Boolean;
  A, B, V: Integer;
begin
  GpuVk.CopyToImage(FRamps.Image, FRamps.Use, 4, 0, ARow, GpuRampWidth, 1, AData, GpuRampWidth * 4);
  if not FInteriors or (ARow < 0) or (ARow >= Length(FRampTexels)) then
    Exit;
  Move(AData^, FRampTexels[ARow][0], GpuRampWidth * 4);
  // Opaque, and every channel within a level of the line from the first texel to the last.
  P := @FRampTexels[ARow][0];
  Linear := True;
  for I := 0 to GpuRampWidth - 1 do
  begin
    if (FRampTexels[ARow][I] shr 24) <> 255 then
    begin
      Linear := False;
      Break;
    end;
    for K := 0 to 2 do
    begin
      A := (P^ shr (8 * K)) and 255;
      B := (FRampTexels[ARow][GpuRampWidth - 1] shr (8 * K)) and 255;
      V := (FRampTexels[ARow][I] shr (8 * K)) and 255;
      if Abs(V - (A + (B - A) * I / (GpuRampWidth - 1))) > 1 then
        Linear := False;
    end;
    if not Linear then
      Break;
  end;
  FRampLinear[ARow] := Linear;
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

class function TGpuVkBackend.CreateWindow(const AHandle: TGpuWindowHandle; const ALayered: Boolean): TGpuWindow;
begin
  Result := TGpuVkWindow.Create(AHandle, ALayered);
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
