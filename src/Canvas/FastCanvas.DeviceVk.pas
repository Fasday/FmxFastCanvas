unit FastCanvas.DeviceVk;

{ The Vulkan device of FastCanvas (FastCanvasBackend = Vulkan): the loader, an instance (Vulkan 1.3, VK_KHR_surface
  and VK_KHR_win32_surface), the physical device (a discrete graphics card first, with a graphics queue family that
  presents to windows), the logical device with dynamic rendering, synchronization2 and timeline semaphores, its
  graphics queue and the device command table, and memory type lookup. Buffer device address, acceleration
  structures and ray query with descriptor indexing are enabled too where the device has them (the ray-traced effects
  of the 3D context need them), and VK_KHR_present_mode_fifo_latest_ready.

  Memory: blocks of VkDeviceMemory per memory type (32 MB device-local, 8 MB host-visible), buffers and images in
  blocks of their own (no bufferImageGranularity between them), suballocated first fit with merged free ranges;
  resources larger than half a block get memory of their own. Host-visible blocks stay mapped. An empty block is
  freed unless it is the last one of its kind. Thread-safe (the 3D context makes textures on the main thread while
  the render thread draws).

  FASTCANVAS_VK_DEBUG=<file>: the Khronos validation layer, whose warnings and errors a VK_EXT_debug_utils messenger
  appends to that file (as FASTCANVAS_D3D12_DEBUG does for the Direct3D 12 debug layer). FASTCANVAS_VK_STATS=<file>:
  a line with the peak numbers of memory objects and allocations appended when the device goes. FASTCANVAS_VK_API=1.1
  or 1.2: an instance of that version, so any device is used the way of devices below Vulkan 1.3 (a test of that
  path).

  The loader is held until Destroy: the unit Vulkan frees its handle in its finalization, which runs before FMX frees
  the forms and the canvas shuts the device down (FastCanvas.Service). Thread use as with Direct3D 12: the device is
  free-threaded, command recording is done with the device lock held (TFastDevice.Lock); submissions and presents
  take the queue lock (LockQueue), which the threads presenting windows take without the device lock.

  Other platforms: VK_KHR_android_surface (Android) or VK_KHR_xlib_surface (Linux, X11) instead of
  VK_KHR_win32_surface; the queue family is the first one that draws (whether it presents to a window is asked when
  the window's surface is made). Devices below Vulkan 1.3 (many phones have 1.1) are Legacy: dynamic rendering,
  synchronization2 and (below 1.2) timeline semaphores come from their extensions where the device has them, the KHR
  commands then stand in for the core ones; push descriptors (the 3D context) where the device has them, no ray
  tracing features.

  Vulkan 1.1 is the least the canvas needs (negative viewport heights, vkGetPhysicalDeviceFeatures2), with
  VK_KHR_swapchain; each of the three features is optional (many 2021-2024 phones have none but timeline semaphores):
  without dynamic rendering the recording context draws in render passes (RenderPass, CompatiblePass: made once per
  set of attachments and kept with the device; pipelines are made for a compatible one, PipelineTarget), without
  synchronization2 it issues vkCmdPipelineBarrier and vkQueueSubmit, without timeline semaphores a fence per
  submission tells what the GPU has done (FastCanvas.GpuVk). FASTCANVAS_VK_LEGACY=1: neither dynamic rendering,
  synchronization2 nor push descriptors on any device; FASTCANVAS_VK_NOTIMELINE=1: no timeline semaphores (tests of
  those paths on a desktop GPU, ray tracing included). FASTCANVAS_VK_NOPUSH=1: push descriptors stay off (a test of
  the 3D context's path without them). }

interface

uses
  {$IFDEF MSWINDOWS}Winapi.Windows, {$ENDIF}System.SysUtils, System.Generics.Collections, Vulkan;

type
  EFastVulkan = class(Exception);

  /// <summary>The attachments of a render pass (devices without dynamic rendering): one color attachment, and one of
  /// depth and stencil unless DepthFormat is VK_FORMAT_UNDEFINED, each in one layout throughout (the barriers before
  /// the pass change layouts, as with dynamic rendering).</summary>
  TFastVkPassKey = packed record
    ColorFormat, DepthFormat: TVkFormat;
    Samples: Cardinal;
    ColorLayout, DepthLayout: TVkImageLayout;
    ColorLoad, DepthLoad, StencilLoad: TVkAttachmentLoadOp;
    ColorStore, DepthStore, StencilStore: TVkAttachmentStoreOp;
  end;

  /// <summary>The memory of a resource: a range of a block of TFastVulkan, or a memory object of its own.</summary>
  TFastVkAllocation = class
  private
    /// <summary>TFastVkBlock; nil: the memory object is the allocation's own.</summary>
    FBlock: TObject;
  public
    Memory: TVkDeviceMemory;
    Offset, Size: UInt64;
    /// <summary>The properties of the memory type.</summary>
    Flags: TVkMemoryPropertyFlags;
    /// <summary>Host-visible memory: the address of Offset (mapped while the memory exists); else nil.</summary>
    Cpu: PByte;
  end;

  TFastVulkan = class
  private
{$IFDEF MSWINDOWS}
    FAllocLock, FQueueLock: TRTLCriticalSection;
{$ELSE}
    /// <summary>Monitors (TMonitor) off Windows.</summary>
    FAllocLock, FQueueLock: TObject;
{$ENDIF}
    /// <summary>Per memory type, for optimal images (False) and buffers (True).</summary>
    FPools: array[0..VK_MAX_MEMORY_TYPES - 1, Boolean] of TList<TObject>;
    FMemoryObjects, FPeakMemoryObjects, FAllocations, FPeakAllocations: Integer;
    FMemoryBytes, FPeakMemoryBytes, FAllocatedBytes, FPeakAllocatedBytes: UInt64;
    FLibrary: HMODULE;
    FInstanceVk: TVulkan;
    FVk: TVulkan;
    FInstance: TVkInstance;
    FMessenger: TVkDebugUtilsMessengerEXT;
    FPhysical: TVkPhysicalDevice;
    FProperties: TVkPhysicalDeviceProperties;
    FMemory: TVkPhysicalDeviceMemoryProperties;
    FDevice: TVkDevice;
    FQueue: TVkQueue;
    FQueueFamily: Cardinal;
    FDebug: Boolean;
    FLost: Boolean;
    FDualSource: Boolean;
    FBufferDeviceAddress, FAccelerationStructure, FRayQuery: Boolean;
    FFifoLatestReady: Boolean;
    FPushDescriptor: Boolean;
    FDepthFormat: TVkFormat;
    FScratchAlignment: Cardinal;
    /// <summary>The version of the instance (what the loader offers, at most 1.3).</summary>
    FInstanceVersion: Cardinal;
    /// <summary>The device is used through extensions below Vulkan 1.3.</summary>
    FLegacy: Boolean;
    FDynamicRendering, FSynchronization2, FTimelineSemaphore: Boolean;
    /// <summary>Render passes made so far (RenderPass); TMonitor of the dictionary guards it.</summary>
    FPasses: TDictionary<TFastVkPassKey, TVkRenderPass>;
    procedure CreateInstance;
    procedure PickDevice(const APreferSoftware: Boolean);
    procedure CreateDevice;
    procedure CreateLegacyDevice(const AExts: TArray<TVkExtensionProperties>; const AFifoName: PAnsiChar);
    /// <summary>The depth and stencil format of the 3D context (DepthFormat).</summary>
    procedure FindDepthFormat;
    function GetDeviceName: string;
    function GetApiVersion: Cardinal;
    /// <summary>A memory object of ASize bytes of type AType (ADeviceAddress: for buffers with device addresses),
    /// mapped when host-visible; VK_NULL_HANDLE when the device has no more memory.</summary>
    function NewMemory(const AType: Integer; const ASize: UInt64; const ADeviceAddress: Boolean;
      out ACpu: PByte): TVkDeviceMemory;
    procedure FreeMemory(const AMemory: TVkDeviceMemory; const ASize: UInt64);
    procedure WriteStats;
    procedure LockAlloc; inline;
    procedure UnlockAlloc; inline;
  public
    /// <summary>Raises EFastVulkan, with what each device lacks, when there is no Vulkan 1.1 device that draws and
    /// presents to windows. APreferSoftware: a CPU implementation first (TFastDevice.UseWarp).</summary>
    constructor Create(const APreferSoftware: Boolean);
    /// <summary>Everything made on the device must be destroyed before.</summary>
    destructor Destroy; override;
    /// <summary>Notes a lost device (VK_ERROR_DEVICE_LOST); the result unchanged.</summary>
    function Track(const ARes: TVkResult): TVkResult;
    /// <summary>Raises EFastVulkan when ARes is an error (a lost device is noted first).</summary>
    procedure Check(const ARes: TVkResult; const AWhat: string);
    /// <summary>A memory type of ATypeBits with ARequired, and with APreferred too when there is one; -1: none.
    /// </summary>
    function MemoryType(const ATypeBits: Cardinal; const ARequired, APreferred: TVkMemoryPropertyFlags): Integer;
    /// <summary>Memory for a resource with ARequirements, of a type with ARequired (and APreferred when there is one).
    /// ABuffer: for a buffer (they share blocks with buffers only). Thread-safe. Raises EFastVulkan when there is
    /// none.</summary>
    function Allocate(const ARequirements: TVkMemoryRequirements; const ARequired, APreferred: TVkMemoryPropertyFlags;
      const ABuffer: Boolean): TFastVkAllocation;
    /// <summary>Gives the memory back and frees AAllocation (nil: nothing); the GPU must be done with it.
    /// Thread-safe.</summary>
    procedure Release(const AAllocation: TFastVkAllocation);
    /// <summary>Host-visible memory that is not coherent: the CPU sees what the GPU wrote to the allocation.</summary>
    procedure Invalidate(const AAllocation: TFastVkAllocation);
    /// <summary>Without dynamic rendering: the render pass of AKey (made on first use, kept until the device goes).
    /// Thread-safe.</summary>
    function RenderPass(const AKey: TFastVkPassKey): TVkRenderPass;
    /// <summary>A render pass that pipelines and framebuffers for these attachments are made with (ADepthFormat
    /// VK_FORMAT_UNDEFINED: color only); every render pass of the same formats and samples is compatible with it.
    /// Thread-safe.</summary>
    function CompatiblePass(const AColorFormat: TVkFormat; const ASamples: Integer;
      const ADepthFormat: TVkFormat): TVkRenderPass;
    /// <summary>What a graphics pipeline draws into: ARendering in AInfo's chain with dynamic rendering (AInfo.pNext
    /// must be free), else the compatible render pass of ARendering's formats and ASamples.</summary>
    procedure PipelineTarget(var AInfo: TVkGraphicsPipelineCreateInfo; const ARendering: PVkPipelineRenderingCreateInfo;
      const ASamples: Integer);
    /// <summary>Memory objects there are now, and at most so far; allocations likewise.</summary>
    property MemoryObjects: Integer read FMemoryObjects;
    property PeakMemoryObjects: Integer read FPeakMemoryObjects;
    property Allocations: Integer read FAllocations;
    property PeakAllocations: Integer read FPeakAllocations;
    /// <summary>Device commands (loaded for the device).</summary>
    property Vk: TVulkan read FVk;
    /// <summary>Instance commands (surfaces and other instance-level functions).</summary>
    property InstanceVk: TVulkan read FInstanceVk;
    property Instance: TVkInstance read FInstance;
    property Physical: TVkPhysicalDevice read FPhysical;
    property Properties: TVkPhysicalDeviceProperties read FProperties;
    property Device: TVkDevice read FDevice;
    /// <summary>Submissions to the queue and presents are made between LockQueue and UnlockQueue (the presenting
    /// threads of windows use it without the device lock); never held while waiting for the GPU or the display.
    /// </summary>
    procedure LockQueue; inline;
    procedure UnlockQueue; inline;
    /// <summary>The graphics queue, which also presents.</summary>
    property Queue: TVkQueue read FQueue;
    property QueueFamily: Cardinal read FQueueFamily;
    /// <summary>The validation layer is on (FASTCANVAS_VK_DEBUG).</summary>
    property Debug: Boolean read FDebug;
    /// <summary>A call returned VK_ERROR_DEVICE_LOST: the device has to be made again.</summary>
    property Lost: Boolean read FLost;
    /// <summary>Dual-source blending (ClearType text).</summary>
    property DualSource: Boolean read FDualSource;
    /// <summary>Features of the 3D context's ray-traced effects (RayQuery: with descriptor indexing).</summary>
    property BufferDeviceAddress: Boolean read FBufferDeviceAddress;
    property AccelerationStructure: Boolean read FAccelerationStructure;
    property RayQuery: Boolean read FRayQuery;
    /// <summary>VK_PRESENT_MODE_FIFO_LATEST_READY_KHR is enabled (a swap chain may use it where the surface offers
    /// it).</summary>
    property FifoLatestReady: Boolean read FFifoLatestReady;
    /// <summary>VK_KHR_push_descriptor is enabled (the 3D context pushes its descriptors; else it binds sets of the
    /// recording context's pools).</summary>
    property PushDescriptor: Boolean read FPushDescriptor;
    /// <summary>The depth and stencil format of the 3D context: D32_SFLOAT_S8_UINT, else D24_UNORM_S8_UINT (as
    /// attachment and sampled); VK_FORMAT_UNDEFINED: none.</summary>
    property DepthFormat: TVkFormat read FDepthFormat;
    /// <summary>Alignment of the scratch memory of acceleration structure builds.</summary>
    property ScratchAlignment: Cardinal read FScratchAlignment;
    /// <summary>Below Vulkan 1.3: dynamic rendering, synchronization2 (and timeline semaphores) are extensions, where
    /// the device has them.</summary>
    property Legacy: Boolean read FLegacy;
    /// <summary>Dynamic rendering is enabled; else draws run in render passes (RenderPass).</summary>
    property DynamicRendering: Boolean read FDynamicRendering;
    /// <summary>Synchronization2 is enabled; else barriers and submissions are those of Vulkan 1.0.</summary>
    property Synchronization2: Boolean read FSynchronization2;
    /// <summary>Timeline semaphores are enabled; else every submission signals a fence.</summary>
    property TimelineSemaphore: Boolean read FTimelineSemaphore;
    /// <summary>The device's name (diagnostics).</summary>
    property DeviceName: string read GetDeviceName;
    /// <summary>The Vulkan version of the device's driver (diagnostics; the canvas uses at most 1.3).</summary>
    property ApiVersion: Cardinal read GetApiVersion;
  end;

/// <summary>A Vulkan version as text: "1.3.280".</summary>
function FastVulkanVersionText(const AVersion: Cardinal): string;

implementation

uses
  System.Math;

const
  DebugVariable = 'FASTCANVAS_VK_DEBUG';
  StatsVariable = 'FASTCANVAS_VK_STATS';
  ApiVariable = 'FASTCANVAS_VK_API';
  NoPushVariable = 'FASTCANVAS_VK_NOPUSH';
  LegacyVariable = 'FASTCANVAS_VK_LEGACY';
  NoTimelineVariable = 'FASTCANVAS_VK_NOTIMELINE';
  ValidationLayer: AnsiString = 'VK_LAYER_KHRONOS_validation';
  /// <summary>Messages logged per process at most.</summary>
  MaxMessages = 2000;
  DeviceBlockSize = 32 * 1024 * 1024;
  HostBlockSize = 8 * 1024 * 1024;

  /// <summary>The Vulkan loader of the platform.</summary>
  LoaderName =
    {$IF Defined(MSWINDOWS)}'vulkan-1.dll'{$ELSEIF Defined(ANDROID)}'libvulkan.so'{$ELSE}'libvulkan.so.1'{$ENDIF};
  /// <summary>The surface extension of the platform's windows.</summary>
  SurfaceExtension = {$IF Defined(MSWINDOWS)}VK_KHR_WIN32_SURFACE_EXTENSION_NAME{$ELSEIF Defined(ANDROID)}
    VK_KHR_ANDROID_SURFACE_EXTENSION_NAME{$ELSE}VK_KHR_XLIB_SURFACE_EXTENSION_NAME{$ENDIF};

type
  TFastVkRange = record
    Offset, Size: UInt64;
  end;

  /// <summary>A memory object suballocated by TFastVulkan.</summary>
  TFastVkBlock = class
  public
    Memory: TVkDeviceMemory;
    Size: UInt64;
    Cpu: PByte;
    Flags: TVkMemoryPropertyFlags;
    /// <summary>Free ranges by offset; no two touch.</summary>
    Ranges: TArray<TFastVkRange>;
    FreeCount: Integer;
    Live: Integer;
    /// <summary>The list of TFastVulkan the block is in.</summary>
    Pool: TList<TObject>;
    /// <summary>The offset of ASize bytes aligned to AAlign taken from the free ranges; False when they have none.
    /// </summary>
    function Take(const ASize, AAlign: UInt64; out AOffset: UInt64): Boolean;
    procedure Give(const AOffset, ASize: UInt64);
  end;

function TFastVkBlock.Take(const ASize, AAlign: UInt64; out AOffset: UInt64): Boolean;
var
  I, J: Integer;
  R: TFastVkRange;
  Start, Tail: UInt64;
begin
  for I := 0 to FreeCount - 1 do
  begin
    R := Ranges[I];
    Start := (R.Offset + AAlign - 1) and not (AAlign - 1);
    if Start + ASize > R.Offset + R.Size then
      Continue;
    Tail := R.Offset + R.Size - (Start + ASize);
    if Start > R.Offset then
    begin
      // The bytes before the aligned start stay free; the tail too, as a range of its own after them.
      Ranges[I].Size := Start - R.Offset;
      if Tail > 0 then
      begin
        if FreeCount = Length(Ranges) then
          SetLength(Ranges, 2 * FreeCount + 4);
        for J := FreeCount downto I + 2 do
          Ranges[J] := Ranges[J - 1];
        Ranges[I + 1].Offset := Start + ASize;
        Ranges[I + 1].Size := Tail;
        Inc(FreeCount);
      end;
    end
    else if Tail > 0 then
    begin
      Ranges[I].Offset := Start + ASize;
      Ranges[I].Size := Tail;
    end
    else
    begin
      for J := I to FreeCount - 2 do
        Ranges[J] := Ranges[J + 1];
      Dec(FreeCount);
    end;
    AOffset := Start;
    Inc(Live);
    Exit(True);
  end;
  Result := False;
end;

procedure TFastVkBlock.Give(const AOffset, ASize: UInt64);
var
  I, J: Integer;
begin
  Dec(Live);
  // The first range after the one given back.
  I := 0;
  while (I < FreeCount) and (Ranges[I].Offset < AOffset) do
    Inc(I);
  if (I > 0) and (Ranges[I - 1].Offset + Ranges[I - 1].Size = AOffset) then
  begin
    Inc(Ranges[I - 1].Size, ASize);
    if (I < FreeCount) and (AOffset + ASize = Ranges[I].Offset) then
    begin
      // It closes the gap between two ranges.
      Inc(Ranges[I - 1].Size, Ranges[I].Size);
      for J := I to FreeCount - 2 do
        Ranges[J] := Ranges[J + 1];
      Dec(FreeCount);
    end;
    Exit;
  end;
  if (I < FreeCount) and (AOffset + ASize = Ranges[I].Offset) then
  begin
    Ranges[I].Offset := AOffset;
    Inc(Ranges[I].Size, ASize);
    Exit;
  end;
  if FreeCount = Length(Ranges) then
    SetLength(Ranges, 2 * FreeCount + 4);
  for J := FreeCount downto I + 1 do
    Ranges[J] := Ranges[J - 1];
  Ranges[I].Offset := AOffset;
  Ranges[I].Size := ASize;
  Inc(FreeCount);
end;

var
  /// <summary>Not deleted: the device is destroyed after the unit finalizations, and may still report then.
  /// </summary>
{$IFDEF MSWINDOWS}
  GLogLock: TRTLCriticalSection;
{$ELSE}
  GLogLock: TObject;
{$ENDIF}
  GLogged: Integer;

function FastVulkanVersionText(const AVersion: Cardinal): string;
begin
  Result := Format('%d.%d.%d', [(AVersion shr 22) and $7F, (AVersion shr 12) and $3FF, AVersion and $FFF]);
end;

procedure EnterLog; inline;
begin
{$IFDEF MSWINDOWS}
  EnterCriticalSection(GLogLock);
{$ELSE}
  TMonitor.Enter(GLogLock);
{$ENDIF}
end;

procedure LeaveLog; inline;
begin
{$IFDEF MSWINDOWS}
  LeaveCriticalSection(GLogLock);
{$ELSE}
  TMonitor.Exit(GLogLock);
{$ENDIF}
end;

/// <summary>The messenger: warnings and errors of the validation layer into the file FASTCANVAS_VK_DEBUG names.
/// Called on the thread of the Vulkan call that caused the message.</summary>
function DebugCallback(messageSeverity: TVkDebugUtilsMessageSeverityFlagBitsEXT;
  messageTypes: TVkDebugUtilsMessageTypeFlagsEXT; const pCallbackData: PVkDebugUtilsMessengerCallbackDataEXT;
  pUserData: PVkVoid): TVkBool32; {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
var
  F: TextFile;
  Name, Kind, Id: string;
begin
  Result := VK_FALSE;
  if pCallbackData = nil then
    Exit;
  Id := '';
  if pCallbackData.pMessageIdName <> nil then
    Id := string(UTF8String(pCallbackData.pMessageIdName));
  if Ord(messageSeverity) >= Ord(VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT) then
    Kind := 'error'
  else if Id = 'Loader Message' then
    // Warnings of the loader are about the layers installed on the machine (duplicate or broken manifests of
    // overlays), not about the canvas.
    Exit
  else
    Kind := 'warning';
  EnterLog;
  try
    if GLogged >= MaxMessages then
      Exit;
    Inc(GLogged);
    Name := GetEnvironmentVariable(DebugVariable);
    AssignFile(F, Name);
    try
      if FileExists(Name) then
        Append(F)
      else
        Rewrite(F);
      try
        Writeln(F, Format('[%s] %s: %s', [Kind, Id, string(UTF8String(pCallbackData.pMessage))]));
      finally
        CloseFile(F);
      end;
    except
      // The log is a development aid only.
    end;
  finally
    LeaveLog;
  end;
end;

function HasExtension(const AList: TArray<TVkExtensionProperties>; const AName: AnsiString): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(AList) do
    if AnsiString(PAnsiChar(@AList[I].extensionName[0])) = AName then
      Exit(True);
  Result := False;
end;

type
  /// <summary>What a device has of the optional features (DeviceCaps).</summary>
  TFastVkCaps = record
    DynamicRendering, Synchronization2, Timeline, DualSource: Boolean;
  end;

/// <summary>The optional features of a device used at AVersion (the device's version, at most the instance's): those
/// of the core version, else of their extensions.</summary>
function DeviceCaps(const AVk: TVulkan; const ADevice: TVkPhysicalDevice; const AVersion: Cardinal;
  const AExts: TArray<TVkExtensionProperties>): TFastVkCaps;
var
  Features: TVkPhysicalDeviceFeatures2;
  F12: TVkPhysicalDeviceVulkan12Features;
  F13: TVkPhysicalDeviceVulkan13Features;
  Dynamic: TVkPhysicalDeviceDynamicRenderingFeatures;
  Sync2: TVkPhysicalDeviceSynchronization2Features;
  Timeline: TVkPhysicalDeviceTimelineSemaphoreFeatures;
  DynamicExt, Sync2Ext, TimelineExt: Boolean;
  Chain: Pointer;
begin
  FillChar(F12, SizeOf(F12), 0);
  F12.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES;
  FillChar(F13, SizeOf(F13), 0);
  F13.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES;
  FillChar(Dynamic, SizeOf(Dynamic), 0);
  Dynamic.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES;
  FillChar(Sync2, SizeOf(Sync2), 0);
  Sync2.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SYNCHRONIZATION_2_FEATURES;
  FillChar(Timeline, SizeOf(Timeline), 0);
  Timeline.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TIMELINE_SEMAPHORE_FEATURES;
  // Only structures of the version and of extensions the device has go into the chain. Dynamic rendering needs
  // depth_stencil_resolve, which needs create_renderpass2 (both core in 1.2).
  DynamicExt := (AVersion < VK_API_VERSION_1_3) and HasExtension(AExts, VK_KHR_DYNAMIC_RENDERING_EXTENSION_NAME) and
    ((AVersion >= VK_API_VERSION_1_2) or (HasExtension(AExts, VK_KHR_DEPTH_STENCIL_RESOLVE_EXTENSION_NAME) and
    HasExtension(AExts, VK_KHR_CREATE_RENDERPASS_2_EXTENSION_NAME)));
  Sync2Ext := (AVersion < VK_API_VERSION_1_3) and HasExtension(AExts, VK_KHR_SYNCHRONIZATION_2_EXTENSION_NAME);
  TimelineExt := (AVersion < VK_API_VERSION_1_2) and HasExtension(AExts, VK_KHR_TIMELINE_SEMAPHORE_EXTENSION_NAME);
  Chain := nil;
  if AVersion >= VK_API_VERSION_1_2 then
  begin
    F12.pNext := Chain;
    Chain := @F12;
  end;
  if AVersion >= VK_API_VERSION_1_3 then
  begin
    F13.pNext := Chain;
    Chain := @F13;
  end;
  if DynamicExt then
  begin
    Dynamic.pNext := Chain;
    Chain := @Dynamic;
  end;
  if Sync2Ext then
  begin
    Sync2.pNext := Chain;
    Chain := @Sync2;
  end;
  if TimelineExt then
  begin
    Timeline.pNext := Chain;
    Chain := @Timeline;
  end;
  FillChar(Features, SizeOf(Features), 0);
  Features.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2;
  Features.pNext := Chain;
  AVk.GetPhysicalDeviceFeatures2(ADevice, @Features);
  Result.DynamicRendering := ((AVersion >= VK_API_VERSION_1_3) and (F13.dynamicRendering <> VK_FALSE)) or
    (DynamicExt and (Dynamic.dynamicRendering <> VK_FALSE));
  Result.Synchronization2 := ((AVersion >= VK_API_VERSION_1_3) and (F13.synchronization2 <> VK_FALSE)) or
    (Sync2Ext and (Sync2.synchronization2 <> VK_FALSE));
  Result.Timeline := ((AVersion >= VK_API_VERSION_1_2) and (F12.timelineSemaphore <> VK_FALSE)) or
    (TimelineExt and (Timeline.timelineSemaphore <> VK_FALSE));
  Result.DualSource := Features.features.dualSrcBlend <> VK_FALSE;
end;

/// <summary>What the formats of a device lack of what the canvas uses (mandatory in Vulkan, asked all the same);
/// '': nothing.</summary>
function FormatsMissing(const AVk: TVulkan; const ADevice: TVkPhysicalDevice): string;
const
  Sampled = Ord(VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT) or Ord(VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT);
var
  S: string;

  procedure Need(const AFormat: TVkFormat; const AName: string; const AFeatures: TVkFormatFeatureFlags;
    const ABuffer: Boolean; const AWhat: string);
  var
    Props: TVkFormatProperties;
    Have: TVkFormatFeatureFlags;
  begin
    FillChar(Props, SizeOf(Props), 0);
    AVk.GetPhysicalDeviceFormatProperties(ADevice, AFormat, @Props);
    if ABuffer then
      Have := Props.bufferFeatures
    else
      Have := Props.optimalTilingFeatures;
    if (Have and AFeatures) = AFeatures then
      Exit;
    if S <> '' then
      S := S + ', ';
    S := S + AName + ' without ' + AWhat;
  end;

begin
  S := '';
  Need(VK_FORMAT_B8G8R8A8_UNORM, 'B8G8R8A8_UNORM', Sampled or Ord(VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT) or
    Ord(VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BLEND_BIT) or Ord(VK_FORMAT_FEATURE_BLIT_SRC_BIT), False,
    'sampling, blending or blits');
  Need(VK_FORMAT_R8_UNORM, 'R8_UNORM', Sampled, False, 'filtered sampling');
  Need(VK_FORMAT_R8G8B8A8_UNORM, 'R8G8B8A8_UNORM', Sampled, False, 'filtered sampling');
  Need(VK_FORMAT_R32G32B32A32_SFLOAT, 'R32G32B32A32_SFLOAT', Ord(VK_FORMAT_FEATURE_UNIFORM_TEXEL_BUFFER_BIT), True,
    'uniform texel buffers');
  Result := S;
end;

{ TFastVulkan }

constructor TFastVulkan.Create(const APreferSoftware: Boolean);
begin
  inherited Create;
{$IFDEF MSWINDOWS}
  InitializeCriticalSection(FAllocLock);
  InitializeCriticalSection(FQueueLock);
{$ELSE}
  FAllocLock := TObject.Create;
  FQueueLock := TObject.Create;
{$ENDIF}
  FPasses := TDictionary<TFastVkPassKey, TVkRenderPass>.Create;
  FDebug := GetEnvironmentVariable(DebugVariable) <> '';
  CreateInstance;
  PickDevice(APreferSoftware);
  CreateDevice;
end;

destructor TFastVulkan.Destroy;
var
  T: Integer;
  B: Boolean;
  O: TObject;
  P: TVkRenderPass;
begin
  if FDevice <> VK_NULL_HANDLE then
    FVk.DeviceWaitIdle(FDevice);
  WriteStats;
  if FPasses <> nil then
  begin
    if FDevice <> VK_NULL_HANDLE then
      for P in FPasses.Values do
        FVk.DestroyRenderPass(FDevice, P, nil);
    FreeAndNil(FPasses);
  end;
  // Blocks still there: empty ones kept for reuse (allocations still alive would be a leak of their owners).
  for T := 0 to High(FPools) do
    for B := False to True do
      if FPools[T, B] <> nil then
      begin
        for O in FPools[T, B] do
        begin
          FreeMemory(TFastVkBlock(O).Memory, TFastVkBlock(O).Size);
          O.Free;
        end;
        FreeAndNil(FPools[T, B]);
      end;
  if FDevice <> VK_NULL_HANDLE then
    FVk.DestroyDevice(FDevice, nil);
  if FMessenger <> VK_NULL_HANDLE then
    FInstanceVk.DestroyDebugUtilsMessengerEXT(FInstance, FMessenger, nil);
  if FInstance <> VK_NULL_HANDLE then
    FInstanceVk.DestroyInstance(FInstance, nil);
  FVk.Free;
  FInstanceVk.Free;
  if FLibrary <> 0 then
    FreeLibrary(FLibrary);
{$IFDEF MSWINDOWS}
  DeleteCriticalSection(FAllocLock);
  DeleteCriticalSection(FQueueLock);
{$ELSE}
  FAllocLock.Free;
  FQueueLock.Free;
{$ENDIF}
  inherited;
end;

procedure TFastVulkan.LockQueue;
begin
{$IFDEF MSWINDOWS}
  EnterCriticalSection(FQueueLock);
{$ELSE}
  TMonitor.Enter(FQueueLock);
{$ENDIF}
end;

procedure TFastVulkan.UnlockQueue;
begin
{$IFDEF MSWINDOWS}
  LeaveCriticalSection(FQueueLock);
{$ELSE}
  TMonitor.Exit(FQueueLock);
{$ENDIF}
end;

procedure TFastVulkan.LockAlloc;
begin
{$IFDEF MSWINDOWS}
  EnterCriticalSection(FAllocLock);
{$ELSE}
  TMonitor.Enter(FAllocLock);
{$ENDIF}
end;

procedure TFastVulkan.UnlockAlloc;
begin
{$IFDEF MSWINDOWS}
  LeaveCriticalSection(FAllocLock);
{$ELSE}
  TMonitor.Exit(FAllocLock);
{$ENDIF}
end;

procedure TFastVulkan.WriteStats;
var
  Name: string;
  F: TextFile;
begin
  Name := GetEnvironmentVariable(StatsVariable);
  if Name = '' then
    Exit;
  AssignFile(F, Name);
  try
    if FileExists(Name) then
      Append(F)
    else
      Rewrite(F);
    try
      Writeln(F, Format('memory objects: %d at most (%d MB), %d left; allocations: %d at most (%d MB), %d left ' +
        '(limit %u); dynamic rendering %s, synchronization2 %s, timeline semaphores %s, push descriptors %s, ' +
        'render passes %d', [FPeakMemoryObjects, FPeakMemoryBytes shr 20, FMemoryObjects, FPeakAllocations,
        FPeakAllocatedBytes shr 20, FAllocations, FProperties.limits.maxMemoryAllocationCount,
        BoolToStr(FDynamicRendering, True), BoolToStr(FSynchronization2, True), BoolToStr(FTimelineSemaphore, True),
        BoolToStr(FPushDescriptor, True), FPasses.Count]));
    finally
      CloseFile(F);
    end;
  except
    // A development aid only.
  end;
end;

procedure TFastVulkan.CreateInstance;
var
  Version, Count: Cardinal;
  App: TVkApplicationInfo;
  Info: TVkInstanceCreateInfo;
  Messenger: TVkDebugUtilsMessengerCreateInfoEXT;
  Layers: TArray<TVkLayerProperties>;
  Available: TArray<TVkExtensionProperties>;
  LayerNames, ExtNames: TArray<PAnsiChar>;
  Validation: Boolean;
  Cmds: TVulkanCommands;
  Res: TVkResult;
  I: Integer;
  Names: string;
begin
  // Our own reference: the loader stays until Destroy, whatever the unit Vulkan does in its finalization.
  FLibrary := LoadLibrary(LoaderName);
  if (FLibrary = 0) or not LoadVulkanLibrary or not LoadVulkanGlobalCommands then
    raise EFastVulkan.Create('FastCanvas: no Vulkan loader (' + LoaderName + ')');
  Version := VK_API_VERSION_1_0;
  if Assigned(vkEnumerateInstanceVersion) then
    vkEnumerateInstanceVersion(@Version);
  if (Version and $1FFFFFFF) < VK_API_VERSION_1_1 then
    raise EFastVulkan.CreateFmt('FastCanvas: Vulkan 1.1 is required (the loader has %s)',
      [FastVulkanVersionText(Version)]);
  FInstanceVersion := VK_API_VERSION_1_3;
  if (Version and $1FFFFFFF) < VK_API_VERSION_1_3 then
    FInstanceVersion := Version and $1FFFFFFF;
  // FASTCANVAS_VK_API=1.1 or 1.2: an instance of that version, which takes any device the way of devices below 1.3.
  if GetEnvironmentVariable(ApiVariable) = '1.1' then
    FInstanceVersion := Min(FInstanceVersion, VK_API_VERSION_1_1)
  else if GetEnvironmentVariable(ApiVariable) = '1.2' then
    FInstanceVersion := Min(FInstanceVersion, VK_API_VERSION_1_2);
  Count := 0;
  vkEnumerateInstanceExtensionProperties(nil, @Count, nil);
  SetLength(Available, Count);
  if Count > 0 then
    vkEnumerateInstanceExtensionProperties(nil, @Count, @Available[0]);
  if not HasExtension(Available, SurfaceExtension) then
  begin
    Names := '';
    for I := 0 to High(Available) do
      Names := Names + ' ' + string(AnsiString(PAnsiChar(@Available[I].extensionName[0])));
    raise EFastVulkan.CreateFmt('FastCanvas: the Vulkan loader has no %s (it has%s)', [SurfaceExtension, Names]);
  end;
  ExtNames := [PAnsiChar(VK_KHR_SURFACE_EXTENSION_NAME), PAnsiChar(SurfaceExtension)];
  Validation := False;
  if FDebug then
  begin
    Count := 0;
    vkEnumerateInstanceLayerProperties(@Count, nil);
    SetLength(Layers, Count);
    if Count > 0 then
      vkEnumerateInstanceLayerProperties(@Count, @Layers[0]);
    for I := 0 to High(Layers) do
      if AnsiString(PAnsiChar(@Layers[I].layerName[0])) = ValidationLayer then
        Validation := True;
    if Validation then
      LayerNames := [PAnsiChar(ValidationLayer)];
    // The layer brings the messenger extension when the loader does not list it.
    FDebug := HasExtension(Available, VK_EXT_DEBUG_UTILS_EXTENSION_NAME) or Validation;
    if FDebug then
      ExtNames := ExtNames + [PAnsiChar(VK_EXT_DEBUG_UTILS_EXTENSION_NAME)];
  end;
  FillChar(App, SizeOf(App), 0);
  App.sType := VK_STRUCTURE_TYPE_APPLICATION_INFO;
  App.pApplicationName := 'FastCanvas';
  App.pEngineName := 'FastCanvas';
  App.apiVersion := FInstanceVersion;
  FillChar(Messenger, SizeOf(Messenger), 0);
  Messenger.sType := VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT;
  Messenger.messageSeverity := Ord(VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT) or
    Ord(VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT);
  Messenger.messageType := Ord(VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT) or
    Ord(VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT) or Ord(VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT);
  Messenger.pfnUserCallback := DebugCallback;
  FillChar(Info, SizeOf(Info), 0);
  Info.sType := VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
  // The messenger in the chain reports the creation and destruction of the instance too.
  if FDebug then
    Info.pNext := @Messenger;
  Info.pApplicationInfo := @App;
  Info.enabledLayerCount := Length(LayerNames);
  if LayerNames <> nil then
    Info.ppEnabledLayerNames := @LayerNames[0];
  Info.enabledExtensionCount := Length(ExtNames);
  Info.ppEnabledExtensionNames := @ExtNames[0];
  Res := vkCreateInstance(@Info, nil, @FInstance);
  if Res <> VK_SUCCESS then
    raise EFastVulkan.CreateFmt('FastCanvas: cannot create a Vulkan instance (%d)', [Ord(Res)]);
  LoadVulkanInstanceCommands(vkGetInstanceProcAddr, FInstance, Cmds);
  FInstanceVk := TVulkan.Create(Cmds);
  if FDebug and Assigned(Cmds.CreateDebugUtilsMessengerEXT) then
    FInstanceVk.CreateDebugUtilsMessengerEXT(FInstance, @Messenger, nil, @FMessenger);
end;

procedure TFastVulkan.PickDevice(const APreferSoftware: Boolean);
var
  Count, Families, Family, Version: Cardinal;
  Devices: TArray<TVkPhysicalDevice>;
  Props: TVkPhysicalDeviceProperties;
  Queues: TArray<TVkQueueFamilyProperties>;
  Exts: TArray<TVkExtensionProperties>;
  Caps: TFastVkCaps;
  I, F, Score, Best: Integer;
  Name, Rejected, Missing: string;
begin
  Count := 0;
  FInstanceVk.EnumeratePhysicalDevices(FInstance, @Count, nil);
  SetLength(Devices, Count);
  if Count > 0 then
    FInstanceVk.EnumeratePhysicalDevices(FInstance, @Count, @Devices[0]);
  Best := -1;
  Rejected := '';
  for I := 0 to High(Devices) do
  begin
    FInstanceVk.GetPhysicalDeviceProperties(Devices[I], @Props);
    Name := Format('%s (Vulkan %s)', [string(UTF8String(PAnsiChar(@Props.deviceName[0]))),
      FastVulkanVersionText(Props.apiVersion)]);
    // The version in use: the device's, at most the instance's.
    Version := Min(Props.apiVersion and $1FFFFFFF, FInstanceVersion);
    if Version < VK_API_VERSION_1_1 then
    begin
      Rejected := Rejected + '; ' + Name + ': Vulkan 1.1 is needed';
      Continue;
    end;
    Count := 0;
    FInstanceVk.EnumerateDeviceExtensionProperties(Devices[I], nil, @Count, nil);
    SetLength(Exts, Count);
    if Count > 0 then
      FInstanceVk.EnumerateDeviceExtensionProperties(Devices[I], nil, @Count, @Exts[0]);
    // Everything the device lacks, at once.
    Missing := '';
    if not HasExtension(Exts, VK_KHR_SWAPCHAIN_EXTENSION_NAME) then
      Missing := 'no VK_KHR_swapchain';
    if FormatsMissing(FInstanceVk, Devices[I]) <> '' then
    begin
      if Missing <> '' then
        Missing := Missing + ', ';
      Missing := Missing + FormatsMissing(FInstanceVk, Devices[I]);
    end;
    // A family that draws and presents to windows (one queue for everything).
    Families := 0;
    FInstanceVk.GetPhysicalDeviceQueueFamilyProperties(Devices[I], @Families, nil);
    SetLength(Queues, Families);
    if Families > 0 then
      FInstanceVk.GetPhysicalDeviceQueueFamilyProperties(Devices[I], @Families, @Queues[0]);
    Family := High(Cardinal);
    for F := 0 to Integer(Families) - 1 do
      if ((Queues[F].queueFlags and Ord(VK_QUEUE_GRAPHICS_BIT)) <> 0)
{$IFDEF MSWINDOWS}
        and (FInstanceVk.GetPhysicalDeviceWin32PresentationSupportKHR(Devices[I], Cardinal(F)) <> VK_FALSE)
{$ENDIF}
        then
      begin
        Family := F;
        Break;
      end;
    if Family = High(Cardinal) then
    begin
      if Missing <> '' then
        Missing := Missing + ', ';
      Missing := Missing + 'no queue family that draws' {$IFDEF MSWINDOWS}+ ' and presents to windows'{$ENDIF};
    end;
    if Missing <> '' then
    begin
      Rejected := Rejected + '; ' + Name + ': ' + Missing;
      Continue;
    end;
    case Props.deviceType of
      VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU: Score := 4;
      VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU: Score := 3;
      VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU: Score := 2;
      VK_PHYSICAL_DEVICE_TYPE_CPU:
        if APreferSoftware then
          Score := 5
        else
          Score := 1;
    else
      Score := 0;
    end;
    if Score > Best then
    begin
      Caps := DeviceCaps(FInstanceVk, Devices[I], Version, Exts);
      Best := Score;
      FPhysical := Devices[I];
      FQueueFamily := Family;
      FProperties := Props;
      FDualSource := Caps.DualSource;
      FLegacy := Version < VK_API_VERSION_1_3;
      // FASTCANVAS_VK_LEGACY=1, FASTCANVAS_VK_NOTIMELINE=1: the paths of devices without them, on any device.
      FDynamicRendering := Caps.DynamicRendering and (GetEnvironmentVariable(LegacyVariable) <> '1');
      FSynchronization2 := Caps.Synchronization2 and (GetEnvironmentVariable(LegacyVariable) <> '1');
      FTimelineSemaphore := Caps.Timeline and (GetEnvironmentVariable(NoTimelineVariable) <> '1');
    end;
  end;
  if Best < 0 then
  begin
    if Rejected = '' then
      Rejected := '; there are no Vulkan devices';
    raise EFastVulkan.Create('FastCanvas: no Vulkan 1.1 device that draws and presents' + Rejected);
  end;
  FInstanceVk.GetPhysicalDeviceMemoryProperties(FPhysical, @FMemory);
end;

function TFastVulkan.GetDeviceName: string;
begin
  Result := string(UTF8String(PAnsiChar(@FProperties.deviceName[0])));
end;

function TFastVulkan.GetApiVersion: Cardinal;
begin
  Result := FProperties.apiVersion and $1FFFFFFF;
end;

procedure TFastVulkan.CreateDevice;
var
  Count: Cardinal;
  Exts: TArray<TVkExtensionProperties>;
  Names: TArray<PAnsiChar>;
  Priority: Single;
  Queue: TVkDeviceQueueCreateInfo;
  Info: TVkDeviceCreateInfo;
  Features: TVkPhysicalDeviceFeatures2;
  F13: TVkPhysicalDeviceVulkan13Features;
  F12: TVkPhysicalDeviceVulkan12Features;
  AccelFeatures: TVkPhysicalDeviceAccelerationStructureFeaturesKHR;
  RayFeatures: TVkPhysicalDeviceRayQueryFeaturesKHR;
  FifoFeatures: TVkPhysicalDevicePresentModeFifoLatestReadyFeaturesKHR;
  Cmds: TVulkanCommands;
  Res: TVkResult;
  Ray: Boolean;
  FifoName: PAnsiChar;
  AccelProps: TVkPhysicalDeviceAccelerationStructurePropertiesKHR;
  Props2: TVkPhysicalDeviceProperties2;
begin
  Count := 0;
  FInstanceVk.EnumerateDeviceExtensionProperties(FPhysical, nil, @Count, nil);
  SetLength(Exts, Count);
  if Count > 0 then
    FInstanceVk.EnumerateDeviceExtensionProperties(FPhysical, nil, @Count, @Exts[0]);
  FifoName := nil;
  if HasExtension(Exts, VK_KHR_PRESENT_MODE_FIFO_LATEST_READY_EXTENSION_NAME) then
    FifoName := VK_KHR_PRESENT_MODE_FIFO_LATEST_READY_EXTENSION_NAME
  else if HasExtension(Exts, VK_EXT_PRESENT_MODE_FIFO_LATEST_READY_EXTENSION_NAME) then
    FifoName := VK_EXT_PRESENT_MODE_FIFO_LATEST_READY_EXTENSION_NAME;
  FScratchAlignment := 256;
  if FLegacy then
  begin
    CreateLegacyDevice(Exts, FifoName);
    FindDepthFormat;
    Exit;
  end;
  Names := [PAnsiChar(VK_KHR_SWAPCHAIN_EXTENSION_NAME)];
  Ray := HasExtension(Exts, VK_KHR_ACCELERATION_STRUCTURE_EXTENSION_NAME) and
    HasExtension(Exts, VK_KHR_DEFERRED_HOST_OPERATIONS_EXTENSION_NAME);

  // What the device has of the optional features.
  FillChar(FifoFeatures, SizeOf(FifoFeatures), 0);
  FifoFeatures.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PRESENT_MODE_FIFO_LATEST_READY_FEATURES_KHR;
  FillChar(RayFeatures, SizeOf(RayFeatures), 0);
  RayFeatures.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_RAY_QUERY_FEATURES_KHR;
  FillChar(AccelFeatures, SizeOf(AccelFeatures), 0);
  AccelFeatures.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ACCELERATION_STRUCTURE_FEATURES_KHR;
  AccelFeatures.pNext := @RayFeatures;
  FillChar(F12, SizeOf(F12), 0);
  F12.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES;
  if Ray then
    F12.pNext := @AccelFeatures;
  FillChar(F13, SizeOf(F13), 0);
  F13.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES;
  F13.pNext := @F12;
  FillChar(Features, SizeOf(Features), 0);
  Features.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2;
  Features.pNext := @F13;
  if FifoName <> nil then
  begin
    FifoFeatures.pNext := @F13;
    Features.pNext := @FifoFeatures;
  end;
  FInstanceVk.GetPhysicalDeviceFeatures2(FPhysical, @Features);
  FFifoLatestReady := (FifoName <> nil) and (FifoFeatures.presentModeFifoLatestReady <> VK_FALSE);
  FBufferDeviceAddress := F12.bufferDeviceAddress <> VK_FALSE;
  FAccelerationStructure := Ray and FBufferDeviceAddress and (AccelFeatures.accelerationStructure <> VK_FALSE);
  // The ray-traced effects of the 3D context index arrays of buffers and textures in their shaders.
  FRayQuery := FAccelerationStructure and HasExtension(Exts, VK_KHR_RAY_QUERY_EXTENSION_NAME) and
    (RayFeatures.rayQuery <> VK_FALSE) and (F12.runtimeDescriptorArray <> VK_FALSE) and
    (F12.shaderStorageBufferArrayNonUniformIndexing <> VK_FALSE) and
    (F12.shaderSampledImageArrayNonUniformIndexing <> VK_FALSE) and
    (F12.descriptorBindingPartiallyBound <> VK_FALSE) and (F12.descriptorBindingVariableDescriptorCount <> VK_FALSE);

  // What is turned on.
  FillChar(RayFeatures, SizeOf(RayFeatures), 0);
  RayFeatures.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_RAY_QUERY_FEATURES_KHR;
  RayFeatures.rayQuery := VK_TRUE;
  FillChar(AccelFeatures, SizeOf(AccelFeatures), 0);
  AccelFeatures.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ACCELERATION_STRUCTURE_FEATURES_KHR;
  AccelFeatures.accelerationStructure := VK_TRUE;
  if FRayQuery then
    AccelFeatures.pNext := @RayFeatures;
  FillChar(F12, SizeOf(F12), 0);
  F12.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES;
  if FTimelineSemaphore then
    F12.timelineSemaphore := VK_TRUE;
  if FBufferDeviceAddress then
    F12.bufferDeviceAddress := VK_TRUE;
  if FRayQuery then
  begin
    F12.runtimeDescriptorArray := VK_TRUE;
    F12.shaderStorageBufferArrayNonUniformIndexing := VK_TRUE;
    F12.shaderSampledImageArrayNonUniformIndexing := VK_TRUE;
    F12.descriptorBindingPartiallyBound := VK_TRUE;
    F12.descriptorBindingVariableDescriptorCount := VK_TRUE;
  end;
  if FAccelerationStructure then
  begin
    F12.pNext := @AccelFeatures;
    Names := Names + [PAnsiChar(VK_KHR_ACCELERATION_STRUCTURE_EXTENSION_NAME),
      PAnsiChar(VK_KHR_DEFERRED_HOST_OPERATIONS_EXTENSION_NAME)];
    if FRayQuery then
      Names := Names + [PAnsiChar(VK_KHR_RAY_QUERY_EXTENSION_NAME)];
  end;
  FillChar(F13, SizeOf(F13), 0);
  F13.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES;
  F13.pNext := @F12;
  if FDynamicRendering then
    F13.dynamicRendering := VK_TRUE;
  if FSynchronization2 then
    F13.synchronization2 := VK_TRUE;
  FillChar(Features, SizeOf(Features), 0);
  Features.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2;
  Features.pNext := @F13;
  if FDualSource then
    Features.features.dualSrcBlend := VK_TRUE;
  // FASTCANVAS_VK_NOPUSH=1 or FASTCANVAS_VK_LEGACY=1: the 3D context's path without push descriptors (a test of that
  // path).
  FPushDescriptor := HasExtension(Exts, VK_KHR_PUSH_DESCRIPTOR_EXTENSION_NAME) and
    (GetEnvironmentVariable(NoPushVariable) <> '1') and (GetEnvironmentVariable(LegacyVariable) <> '1');
  if FPushDescriptor then
    Names := Names + [PAnsiChar(VK_KHR_PUSH_DESCRIPTOR_EXTENSION_NAME)];
  if FFifoLatestReady then
  begin
    FillChar(FifoFeatures, SizeOf(FifoFeatures), 0);
    FifoFeatures.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PRESENT_MODE_FIFO_LATEST_READY_FEATURES_KHR;
    FifoFeatures.presentModeFifoLatestReady := VK_TRUE;
    FifoFeatures.pNext := @F13;
    Features.pNext := @FifoFeatures;
    Names := Names + [FifoName];
  end;

  Priority := 1;
  FillChar(Queue, SizeOf(Queue), 0);
  Queue.sType := VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
  Queue.queueFamilyIndex := FQueueFamily;
  Queue.queueCount := 1;
  Queue.pQueuePriorities := @Priority;
  FillChar(Info, SizeOf(Info), 0);
  Info.sType := VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
  Info.pNext := @Features;
  Info.queueCreateInfoCount := 1;
  Info.pQueueCreateInfos := @Queue;
  Info.enabledExtensionCount := Length(Names);
  Info.ppEnabledExtensionNames := @Names[0];
  Res := FInstanceVk.CreateDevice(FPhysical, @Info, nil, @FDevice);
  if Res <> VK_SUCCESS then
    raise EFastVulkan.CreateFmt('FastCanvas: cannot create the Vulkan device (%d)', [Ord(Res)]);
  LoadVulkanDeviceCommands(vkGetDeviceProcAddr, FDevice, Cmds);
  FVk := TVulkan.Create(Cmds);
  FVk.GetDeviceQueue(FDevice, FQueueFamily, 0, @FQueue);
  if FAccelerationStructure then
  begin
    FillChar(AccelProps, SizeOf(AccelProps), 0);
    AccelProps.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ACCELERATION_STRUCTURE_PROPERTIES_KHR;
    FillChar(Props2, SizeOf(Props2), 0);
    Props2.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2;
    Props2.pNext := @AccelProps;
    FInstanceVk.GetPhysicalDeviceProperties2(FPhysical, @Props2);
    FScratchAlignment := Max(AccelProps.minAccelerationStructureScratchOffsetAlignment, 1);
  end;
  FindDepthFormat;
end;

procedure TFastVulkan.FindDepthFormat;
const
  DepthNeeds = Ord(VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT) or Ord(VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT);
var
  Depth: TVkFormat;
  Props: TVkFormatProperties;
begin
  FDepthFormat := VK_FORMAT_UNDEFINED;
  for Depth in [VK_FORMAT_D32_SFLOAT_S8_UINT, VK_FORMAT_D24_UNORM_S8_UINT] do
  begin
    FInstanceVk.GetPhysicalDeviceFormatProperties(FPhysical, Depth, @Props);
    if (Props.optimalTilingFeatures and DepthNeeds) = DepthNeeds then
    begin
      FDepthFormat := Depth;
      Break;
    end;
  end;
end;

procedure TFastVulkan.CreateLegacyDevice(const AExts: TArray<TVkExtensionProperties>; const AFifoName: PAnsiChar);
var
  Names: TArray<PAnsiChar>;
  Priority: Single;
  Queue: TVkDeviceQueueCreateInfo;
  Info: TVkDeviceCreateInfo;
  Features: TVkPhysicalDeviceFeatures2;
  Dynamic: TVkPhysicalDeviceDynamicRenderingFeatures;
  Sync2: TVkPhysicalDeviceSynchronization2Features;
  Timeline: TVkPhysicalDeviceTimelineSemaphoreFeatures;
  FifoFeatures: TVkPhysicalDevicePresentModeFifoLatestReadyFeaturesKHR;
  Cmds: TVulkanCommands;
  Res: TVkResult;
  Version: Cardinal;
  Chain: Pointer;
begin
  // The version in use: the device's, at most the instance's. The extensions of the features PickDevice found.
  Version := Min(GetApiVersion, FInstanceVersion);
  Names := [PAnsiChar(VK_KHR_SWAPCHAIN_EXTENSION_NAME)];
  if FDynamicRendering then
  begin
    Names := Names + [PAnsiChar(VK_KHR_DYNAMIC_RENDERING_EXTENSION_NAME)];
    if Version < VK_API_VERSION_1_2 then
      Names := Names + [PAnsiChar(VK_KHR_DEPTH_STENCIL_RESOLVE_EXTENSION_NAME),
        PAnsiChar(VK_KHR_CREATE_RENDERPASS_2_EXTENSION_NAME)];
  end;
  if FSynchronization2 then
    Names := Names + [PAnsiChar(VK_KHR_SYNCHRONIZATION_2_EXTENSION_NAME)];
  if FTimelineSemaphore and (Version < VK_API_VERSION_1_2) then
    Names := Names + [PAnsiChar(VK_KHR_TIMELINE_SEMAPHORE_EXTENSION_NAME)];
  // The optional extensions as on Vulkan 1.3 (no ray tracing: its shaders are built for Vulkan 1.2 with buffer
  // device addresses and descriptor indexing).
  FPushDescriptor := HasExtension(AExts, VK_KHR_PUSH_DESCRIPTOR_EXTENSION_NAME) and
    (GetEnvironmentVariable(NoPushVariable) <> '1') and (GetEnvironmentVariable(LegacyVariable) <> '1');
  if FPushDescriptor then
    Names := Names + [PAnsiChar(VK_KHR_PUSH_DESCRIPTOR_EXTENSION_NAME)];
  FillChar(FifoFeatures, SizeOf(FifoFeatures), 0);
  FifoFeatures.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PRESENT_MODE_FIFO_LATEST_READY_FEATURES_KHR;
  if AFifoName <> nil then
  begin
    FillChar(Features, SizeOf(Features), 0);
    Features.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2;
    Features.pNext := @FifoFeatures;
    FInstanceVk.GetPhysicalDeviceFeatures2(FPhysical, @Features);
  end;
  FFifoLatestReady := (AFifoName <> nil) and (FifoFeatures.presentModeFifoLatestReady <> VK_FALSE);
  // Only the features in use go into the chain (each structure needs its extension, or Vulkan 1.2 for timeline
  // semaphores).
  Chain := nil;
  FillChar(Timeline, SizeOf(Timeline), 0);
  Timeline.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TIMELINE_SEMAPHORE_FEATURES;
  Timeline.timelineSemaphore := VK_TRUE;
  if FTimelineSemaphore then
    Chain := @Timeline;
  FillChar(Sync2, SizeOf(Sync2), 0);
  Sync2.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SYNCHRONIZATION_2_FEATURES;
  Sync2.synchronization2 := VK_TRUE;
  if FSynchronization2 then
  begin
    Sync2.pNext := Chain;
    Chain := @Sync2;
  end;
  FillChar(Dynamic, SizeOf(Dynamic), 0);
  Dynamic.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES;
  Dynamic.dynamicRendering := VK_TRUE;
  if FDynamicRendering then
  begin
    Dynamic.pNext := Chain;
    Chain := @Dynamic;
  end;
  FillChar(FifoFeatures, SizeOf(FifoFeatures), 0);
  FifoFeatures.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PRESENT_MODE_FIFO_LATEST_READY_FEATURES_KHR;
  FifoFeatures.presentModeFifoLatestReady := VK_TRUE;
  if FFifoLatestReady then
  begin
    FifoFeatures.pNext := Chain;
    Chain := @FifoFeatures;
    Names := Names + [AFifoName];
  end;
  FillChar(Features, SizeOf(Features), 0);
  Features.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2;
  Features.pNext := Chain;
  if FDualSource then
    Features.features.dualSrcBlend := VK_TRUE;
  Priority := 1;
  FillChar(Queue, SizeOf(Queue), 0);
  Queue.sType := VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
  Queue.queueFamilyIndex := FQueueFamily;
  Queue.queueCount := 1;
  Queue.pQueuePriorities := @Priority;
  FillChar(Info, SizeOf(Info), 0);
  Info.sType := VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
  Info.pNext := @Features;
  Info.queueCreateInfoCount := 1;
  Info.pQueueCreateInfos := @Queue;
  Info.enabledExtensionCount := Length(Names);
  Info.ppEnabledExtensionNames := @Names[0];
  Res := FInstanceVk.CreateDevice(FPhysical, @Info, nil, @FDevice);
  if Res <> VK_SUCCESS then
    raise EFastVulkan.CreateFmt('FastCanvas: cannot create the Vulkan device (%d)', [Ord(Res)]);
  LoadVulkanDeviceCommands(vkGetDeviceProcAddr, FDevice, Cmds);
  // The commands of the extensions under their core names (the same signatures).
  if not Assigned(Cmds.CmdBeginRendering) then
    @Cmds.CmdBeginRendering := @Cmds.CmdBeginRenderingKHR;
  if not Assigned(Cmds.CmdEndRendering) then
    @Cmds.CmdEndRendering := @Cmds.CmdEndRenderingKHR;
  if not Assigned(Cmds.CmdPipelineBarrier2) then
    @Cmds.CmdPipelineBarrier2 := @Cmds.CmdPipelineBarrier2KHR;
  if not Assigned(Cmds.QueueSubmit2) then
    @Cmds.QueueSubmit2 := @Cmds.QueueSubmit2KHR;
  if not Assigned(Cmds.WaitSemaphores) then
    @Cmds.WaitSemaphores := @Cmds.WaitSemaphoresKHR;
  if not Assigned(Cmds.GetSemaphoreCounterValue) then
    @Cmds.GetSemaphoreCounterValue := @Cmds.GetSemaphoreCounterValueKHR;
  if (FDynamicRendering and (not Assigned(Cmds.CmdBeginRendering) or not Assigned(Cmds.CmdEndRendering))) or
    (FSynchronization2 and (not Assigned(Cmds.CmdPipelineBarrier2) or not Assigned(Cmds.QueueSubmit2))) or
    (FTimelineSemaphore and (not Assigned(Cmds.WaitSemaphores) or not Assigned(Cmds.GetSemaphoreCounterValue))) then
    raise EFastVulkan.Create('FastCanvas: the Vulkan device lacks commands of its extensions');
  FVk := TVulkan.Create(Cmds);
  FVk.GetDeviceQueue(FDevice, FQueueFamily, 0, @FQueue);
end;

function TFastVulkan.Track(const ARes: TVkResult): TVkResult;
begin
  if ARes = VK_ERROR_DEVICE_LOST then
    FLost := True;
  Result := ARes;
end;

procedure TFastVulkan.Check(const ARes: TVkResult; const AWhat: string);
begin
  if Ord(Track(ARes)) < 0 then
    raise EFastVulkan.CreateFmt('FastCanvas: %s failed (%d)', [AWhat, Ord(ARes)]);
end;

function TFastVulkan.MemoryType(const ATypeBits: Cardinal; const ARequired,
  APreferred: TVkMemoryPropertyFlags): Integer;
var
  I: Integer;
  Wanted: TVkMemoryPropertyFlags;
begin
  Wanted := ARequired or APreferred;
  for I := 0 to Integer(FMemory.memoryTypeCount) - 1 do
    if ((ATypeBits and (1 shl I)) <> 0) and ((FMemory.memoryTypes[I].propertyFlags and Wanted) = Wanted) then
      Exit(I);
  for I := 0 to Integer(FMemory.memoryTypeCount) - 1 do
    if ((ATypeBits and (1 shl I)) <> 0) and ((FMemory.memoryTypes[I].propertyFlags and ARequired) = ARequired) then
      Exit(I);
  Result := -1;
end;

function TFastVulkan.NewMemory(const AType: Integer; const ASize: UInt64; const ADeviceAddress: Boolean;
  out ACpu: PByte): TVkDeviceMemory;
var
  Info: TVkMemoryAllocateInfo;
  FlagsInfo: TVkMemoryAllocateFlagsInfo;
  P: Pointer;
  Res: TVkResult;
begin
  ACpu := nil;
  FillChar(Info, SizeOf(Info), 0);
  Info.sType := VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
  Info.allocationSize := ASize;
  Info.memoryTypeIndex := AType;
  if ADeviceAddress then
  begin
    FillChar(FlagsInfo, SizeOf(FlagsInfo), 0);
    FlagsInfo.sType := VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_FLAGS_INFO;
    FlagsInfo.flags := Ord(VK_MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT);
    Info.pNext := @FlagsInfo;
  end;
  Result := VK_NULL_HANDLE;
  Res := Track(FVk.AllocateMemory(FDevice, @Info, nil, @Result));
  if (Res = VK_ERROR_OUT_OF_DEVICE_MEMORY) or (Res = VK_ERROR_OUT_OF_HOST_MEMORY) then
    Exit(VK_NULL_HANDLE);
  Check(Res, 'vkAllocateMemory');
  if (FMemory.memoryTypes[AType].propertyFlags and Ord(VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)) <> 0 then
  begin
    Res := FVk.MapMemory(FDevice, Result, 0, VK_WHOLE_SIZE, 0, @P);
    if Res <> VK_SUCCESS then
    begin
      FVk.FreeMemory(FDevice, Result, nil);
      Check(Res, 'vkMapMemory');
    end;
    ACpu := P;
  end;
  Inc(FMemoryObjects);
  if FMemoryObjects > FPeakMemoryObjects then
    FPeakMemoryObjects := FMemoryObjects;
  Inc(FMemoryBytes, ASize);
  if FMemoryBytes > FPeakMemoryBytes then
    FPeakMemoryBytes := FMemoryBytes;
end;

procedure TFastVulkan.FreeMemory(const AMemory: TVkDeviceMemory; const ASize: UInt64);
begin
  if AMemory = VK_NULL_HANDLE then
    Exit;
  // Freeing memory unmaps it.
  FVk.FreeMemory(FDevice, AMemory, nil);
  Dec(FMemoryObjects);
  Dec(FMemoryBytes, ASize);
end;

function TFastVulkan.Allocate(const ARequirements: TVkMemoryRequirements; const ARequired,
  APreferred: TVkMemoryPropertyFlags; const ABuffer: Boolean): TFastVkAllocation;
var
  Index, I: Integer;
  Flags: TVkMemoryPropertyFlags;
  Host, Address: Boolean;
  BlockSize, Align, Offset: UInt64;
  Pool: TList<TObject>;
  B: TFastVkBlock;
  Cpu: PByte;
  Memory: TVkDeviceMemory;
begin
  Index := MemoryType(ARequirements.memoryTypeBits, ARequired, APreferred);
  if Index < 0 then
    raise EFastVulkan.Create('FastCanvas: no Vulkan memory type for a resource');
  Flags := FMemory.memoryTypes[Index].propertyFlags;
  Host := (Flags and Ord(VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)) <> 0;
  // Buffers may take device addresses (acceleration structures): their memory allows them.
  Address := ABuffer and FBufferDeviceAddress;
  if Host then
    BlockSize := HostBlockSize
  else
    BlockSize := DeviceBlockSize;
  if BlockSize > FMemory.memoryHeaps[FMemory.memoryTypes[Index].heapIndex].size div 8 then
    BlockSize := FMemory.memoryHeaps[FMemory.memoryTypes[Index].heapIndex].size div 8;
  Align := Max(ARequirements.alignment, 1);
  // Ranges of non-coherent memory are flushed and invalidated in whole atoms: no two allocations share one.
  if Host and ((Flags and Ord(VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) = 0) then
    Align := Max(Align, FProperties.limits.nonCoherentAtomSize);
  Result := TFastVkAllocation.Create;
  LockAlloc;
  try
    try
      Result.Flags := Flags;
      if ARequirements.size > BlockSize div 2 then
      begin
        // Large: memory of its own.
        Result.Memory := NewMemory(Index, ARequirements.size, Address, Cpu);
        if Result.Memory = VK_NULL_HANDLE then
          raise EFastVulkan.CreateFmt('FastCanvas: out of Vulkan memory (%d MB)', [ARequirements.size shr 20]);
        Result.Size := ARequirements.size;
        Result.Cpu := Cpu;
      end
      else
      begin
        if FPools[Index, ABuffer] = nil then
          FPools[Index, ABuffer] := TList<TObject>.Create;
        Pool := FPools[Index, ABuffer];
        B := nil;
        for I := 0 to Pool.Count - 1 do
          if TFastVkBlock(Pool[I]).Take(ARequirements.size, Align, Offset) then
          begin
            B := TFastVkBlock(Pool[I]);
            Break;
          end;
        if B = nil then
        begin
          Memory := NewMemory(Index, BlockSize, Address, Cpu);
          if Memory = VK_NULL_HANDLE then
          begin
            // No room for a block: memory of its own may still fit.
            Result.Memory := NewMemory(Index, ARequirements.size, Address, Cpu);
            if Result.Memory = VK_NULL_HANDLE then
              raise EFastVulkan.CreateFmt('FastCanvas: out of Vulkan memory (%d KB)', [ARequirements.size shr 10]);
            Result.Size := ARequirements.size;
            Result.Cpu := Cpu;
          end
          else
          begin
            B := TFastVkBlock.Create;
            B.Memory := Memory;
            B.Size := BlockSize;
            B.Cpu := Cpu;
            B.Flags := Flags;
            SetLength(B.Ranges, 4);
            B.Ranges[0].Offset := 0;
            B.Ranges[0].Size := BlockSize;
            B.FreeCount := 1;
            B.Pool := Pool;
            Pool.Add(B);
            B.Take(ARequirements.size, Align, Offset);
          end;
        end;
        if B <> nil then
        begin
          Result.FBlock := B;
          Result.Memory := B.Memory;
          Result.Offset := Offset;
          Result.Size := ARequirements.size;
          if B.Cpu <> nil then
            Result.Cpu := B.Cpu + Offset;
        end;
      end;
      Inc(FAllocations);
      Inc(FAllocatedBytes, Result.Size);
      if FAllocatedBytes > FPeakAllocatedBytes then
        FPeakAllocatedBytes := FAllocatedBytes;
      if FAllocations > FPeakAllocations then
        FPeakAllocations := FAllocations;
    except
      Result.Free;
      raise;
    end;
  finally
    UnlockAlloc;
  end;
end;

procedure TFastVulkan.Release(const AAllocation: TFastVkAllocation);
var
  B: TFastVkBlock;
  Pool: TList<TObject>;
  I, Empty: Integer;
begin
  if AAllocation = nil then
    Exit;
  LockAlloc;
  try
    Dec(FAllocations);
    Dec(FAllocatedBytes, AAllocation.Size);
    B := TFastVkBlock(AAllocation.FBlock);
    if B = nil then
      FreeMemory(AAllocation.Memory, AAllocation.Size)
    else
    begin
      B.Give(AAllocation.Offset, AAllocation.Size);
      if B.Live = 0 then
      begin
        // An empty block goes unless it is the only empty one of its pool (a resource made and freed again and
        // again does not make and free a block each time).
        Pool := B.Pool;
        Empty := 0;
        for I := 0 to Pool.Count - 1 do
          if TFastVkBlock(Pool[I]).Live = 0 then
            Inc(Empty);
        if Empty > 1 then
        begin
          Pool.Remove(B);
          FreeMemory(B.Memory, B.Size);
          B.Free;
        end;
      end;
    end;
  finally
    UnlockAlloc;
  end;
  AAllocation.Free;
end;

procedure TFastVulkan.Invalidate(const AAllocation: TFastVkAllocation);
var
  Range: TVkMappedMemoryRange;
  Atom, Limit: UInt64;
begin
  if (AAllocation = nil) or (AAllocation.Cpu = nil) or
    ((AAllocation.Flags and Ord(VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) <> 0) then
    Exit;
  Atom := Max(FProperties.limits.nonCoherentAtomSize, 1);
  FillChar(Range, SizeOf(Range), 0);
  Range.sType := VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE;
  Range.memory := AAllocation.Memory;
  Range.offset := AAllocation.Offset div Atom * Atom;
  Range.size := (AAllocation.Offset + AAllocation.Size - Range.offset + Atom - 1) div Atom * Atom;
  if AAllocation.FBlock <> nil then
    Limit := TFastVkBlock(AAllocation.FBlock).Size
  else
    Limit := AAllocation.Size;
  if Range.offset + Range.size > Limit then
    Range.size := VK_WHOLE_SIZE;
  FVk.InvalidateMappedMemoryRanges(FDevice, 1, @Range);
end;

function TFastVulkan.RenderPass(const AKey: TFastVkPassKey): TVkRenderPass;
var
  Attachments: array[0..1] of TVkAttachmentDescription;
  ColorRef, DepthRef: TVkAttachmentReference;
  Subpass: TVkSubpassDescription;
  Info: TVkRenderPassCreateInfo;
  Res: TVkResult;
begin
  TMonitor.Enter(FPasses);
  try
    if FPasses.TryGetValue(AKey, Result) then
      Exit;
    // One subpass; the attachments keep their layouts (no dependencies: barriers outside the pass order it).
    FillChar(Attachments, SizeOf(Attachments), 0);
    Attachments[0].format := AKey.ColorFormat;
    Attachments[0].samples := TVkSampleCountFlagBits(Max(AKey.Samples, 1));
    Attachments[0].loadOp := AKey.ColorLoad;
    Attachments[0].storeOp := AKey.ColorStore;
    Attachments[0].stencilLoadOp := VK_ATTACHMENT_LOAD_OP_DONT_CARE;
    Attachments[0].stencilStoreOp := VK_ATTACHMENT_STORE_OP_DONT_CARE;
    Attachments[0].initialLayout := AKey.ColorLayout;
    Attachments[0].finalLayout := AKey.ColorLayout;
    ColorRef.attachment := 0;
    ColorRef.layout := AKey.ColorLayout;
    FillChar(Subpass, SizeOf(Subpass), 0);
    Subpass.pipelineBindPoint := VK_PIPELINE_BIND_POINT_GRAPHICS;
    Subpass.colorAttachmentCount := 1;
    Subpass.pColorAttachments := @ColorRef;
    FillChar(Info, SizeOf(Info), 0);
    Info.sType := VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
    Info.attachmentCount := 1;
    Info.pAttachments := @Attachments[0];
    Info.subpassCount := 1;
    Info.pSubpasses := @Subpass;
    if AKey.DepthFormat <> VK_FORMAT_UNDEFINED then
    begin
      Attachments[1].format := AKey.DepthFormat;
      Attachments[1].samples := Attachments[0].samples;
      Attachments[1].loadOp := AKey.DepthLoad;
      Attachments[1].storeOp := AKey.DepthStore;
      Attachments[1].stencilLoadOp := AKey.StencilLoad;
      Attachments[1].stencilStoreOp := AKey.StencilStore;
      Attachments[1].initialLayout := AKey.DepthLayout;
      Attachments[1].finalLayout := AKey.DepthLayout;
      DepthRef.attachment := 1;
      DepthRef.layout := AKey.DepthLayout;
      Subpass.pDepthStencilAttachment := @DepthRef;
      Info.attachmentCount := 2;
    end;
    Result := VK_NULL_HANDLE;
    Res := FVk.CreateRenderPass(FDevice, @Info, nil, @Result);
    Check(Res, 'vkCreateRenderPass');
    FPasses.Add(AKey, Result);
  finally
    TMonitor.Exit(FPasses);
  end;
end;

function TFastVulkan.CompatiblePass(const AColorFormat: TVkFormat; const ASamples: Integer;
  const ADepthFormat: TVkFormat): TVkRenderPass;
var
  Key: TFastVkPassKey;
begin
  // Compatibility asks for the formats and samples only: the attachments as the canvas leaves them.
  FillChar(Key, SizeOf(Key), 0);
  Key.ColorFormat := AColorFormat;
  Key.DepthFormat := ADepthFormat;
  Key.Samples := Max(ASamples, 1);
  Key.ColorLayout := VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
  Key.ColorLoad := VK_ATTACHMENT_LOAD_OP_LOAD;
  Key.ColorStore := VK_ATTACHMENT_STORE_OP_STORE;
  if ADepthFormat <> VK_FORMAT_UNDEFINED then
  begin
    Key.DepthLayout := VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;
    Key.DepthLoad := VK_ATTACHMENT_LOAD_OP_LOAD;
    Key.DepthStore := VK_ATTACHMENT_STORE_OP_STORE;
    Key.StencilLoad := VK_ATTACHMENT_LOAD_OP_LOAD;
    Key.StencilStore := VK_ATTACHMENT_STORE_OP_STORE;
  end;
  Result := RenderPass(Key);
end;

procedure TFastVulkan.PipelineTarget(var AInfo: TVkGraphicsPipelineCreateInfo;
  const ARendering: PVkPipelineRenderingCreateInfo; const ASamples: Integer);
begin
  if FDynamicRendering then
  begin
    AInfo.pNext := ARendering;
    Exit;
  end;
  AInfo.renderPass := CompatiblePass(ARendering.pColorAttachmentFormats^, ASamples,
    ARendering.depthAttachmentFormat);
  AInfo.subpass := 0;
end;

initialization
{$IFDEF MSWINDOWS}
  InitializeCriticalSection(GLogLock);
{$ELSE}
  GLogLock := TObject.Create;
{$ENDIF}
end.
