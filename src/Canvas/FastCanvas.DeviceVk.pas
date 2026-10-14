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
  a line with the peak numbers of memory objects and allocations appended when the device goes.

  The loader is held until Destroy: the unit Vulkan frees its handle in its finalization, which runs before FMX frees
  the forms and the canvas shuts the device down (FastCanvas.Service). Thread use as with Direct3D 12: the device is
  free-threaded, command recording is done with the device lock held (TFastDevice.Lock); submissions and presents
  take the queue lock (LockQueue), which the threads presenting windows take without the device lock. }

interface

uses
  Winapi.Windows, System.SysUtils, System.Generics.Collections, Vulkan;

type
  EFastVulkan = class(Exception);

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
    FAllocLock, FQueueLock: TRTLCriticalSection;
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
    procedure CreateInstance;
    procedure PickDevice(const APreferSoftware: Boolean);
    procedure CreateDevice;
    /// <summary>A memory object of ASize bytes of type AType (ADeviceAddress: for buffers with device addresses),
    /// mapped when host-visible; VK_NULL_HANDLE when the device has no more memory.</summary>
    function NewMemory(const AType: Integer; const ASize: UInt64; const ADeviceAddress: Boolean;
      out ACpu: PByte): TVkDeviceMemory;
    procedure FreeMemory(const AMemory: TVkDeviceMemory; const ASize: UInt64);
    procedure WriteStats;
  public
    /// <summary>Raises EFastVulkan when there is no Vulkan 1.3 device that can present to windows.
    /// APreferSoftware: a CPU implementation first (TFastDevice.UseWarp).</summary>
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
    /// <summary>VK_KHR_push_descriptor is enabled (the 3D context needs it).</summary>
    property PushDescriptor: Boolean read FPushDescriptor;
    /// <summary>The depth and stencil format of the 3D context: D32_SFLOAT_S8_UINT, else D24_UNORM_S8_UINT (as
    /// attachment and sampled); VK_FORMAT_UNDEFINED: none.</summary>
    property DepthFormat: TVkFormat read FDepthFormat;
    /// <summary>Alignment of the scratch memory of acceleration structure builds.</summary>
    property ScratchAlignment: Cardinal read FScratchAlignment;
  end;

implementation

uses
  System.Math;

const
  DebugVariable = 'FASTCANVAS_VK_DEBUG';
  StatsVariable = 'FASTCANVAS_VK_STATS';
  ValidationLayer: AnsiString = 'VK_LAYER_KHRONOS_validation';
  /// <summary>Messages logged per process at most.</summary>
  MaxMessages = 2000;
  DeviceBlockSize = 32 * 1024 * 1024;
  HostBlockSize = 8 * 1024 * 1024;

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
  GLogLock: TRTLCriticalSection;
  GLogged: Integer;

/// <summary>The messenger: warnings and errors of the validation layer into the file FASTCANVAS_VK_DEBUG names.
/// Called on the thread of the Vulkan call that caused the message.</summary>
function DebugCallback(messageSeverity: TVkDebugUtilsMessageSeverityFlagBitsEXT;
  messageTypes: TVkDebugUtilsMessageTypeFlagsEXT; const pCallbackData: PVkDebugUtilsMessengerCallbackDataEXT;
  pUserData: PVkVoid): TVkBool32; stdcall;
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
  EnterCriticalSection(GLogLock);
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
    LeaveCriticalSection(GLogLock);
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

{ TFastVulkan }

constructor TFastVulkan.Create(const APreferSoftware: Boolean);
begin
  inherited Create;
  InitializeCriticalSection(FAllocLock);
  InitializeCriticalSection(FQueueLock);
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
begin
  if FDevice <> VK_NULL_HANDLE then
    FVk.DeviceWaitIdle(FDevice);
  WriteStats;
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
  DeleteCriticalSection(FAllocLock);
  DeleteCriticalSection(FQueueLock);
  inherited;
end;

procedure TFastVulkan.LockQueue;
begin
  EnterCriticalSection(FQueueLock);
end;

procedure TFastVulkan.UnlockQueue;
begin
  LeaveCriticalSection(FQueueLock);
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
        '(limit %u)', [FPeakMemoryObjects, FPeakMemoryBytes shr 20, FMemoryObjects, FPeakAllocations,
        FPeakAllocatedBytes shr 20, FAllocations, FProperties.limits.maxMemoryAllocationCount]));
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
begin
  // Our own reference: the loader stays until Destroy, whatever the unit Vulkan does in its finalization.
  FLibrary := LoadLibrary('vulkan-1.dll');
  if (FLibrary = 0) or not LoadVulkanLibrary or not LoadVulkanGlobalCommands then
    raise EFastVulkan.Create('FastCanvas: no Vulkan loader (vulkan-1.dll)');
  Version := VK_API_VERSION_1_0;
  if Assigned(vkEnumerateInstanceVersion) then
    vkEnumerateInstanceVersion(@Version);
  if (Version and $1FFFFFFF) < VK_API_VERSION_1_3 then
    raise EFastVulkan.Create('FastCanvas: Vulkan 1.3 is required');
  Count := 0;
  vkEnumerateInstanceExtensionProperties(nil, @Count, nil);
  SetLength(Available, Count);
  if Count > 0 then
    vkEnumerateInstanceExtensionProperties(nil, @Count, @Available[0]);
  ExtNames := [PAnsiChar(VK_KHR_SURFACE_EXTENSION_NAME), PAnsiChar(VK_KHR_WIN32_SURFACE_EXTENSION_NAME)];
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
  App.apiVersion := VK_API_VERSION_1_3;
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
  Count, Families, Family: Cardinal;
  Devices: TArray<TVkPhysicalDevice>;
  Props: TVkPhysicalDeviceProperties;
  Queues: TArray<TVkQueueFamilyProperties>;
  Exts: TArray<TVkExtensionProperties>;
  Features: TVkPhysicalDeviceFeatures2;
  F13: TVkPhysicalDeviceVulkan13Features;
  F12: TVkPhysicalDeviceVulkan12Features;
  I, F, Score, Best: Integer;
begin
  Count := 0;
  FInstanceVk.EnumeratePhysicalDevices(FInstance, @Count, nil);
  SetLength(Devices, Count);
  if Count > 0 then
    FInstanceVk.EnumeratePhysicalDevices(FInstance, @Count, @Devices[0]);
  Best := -1;
  for I := 0 to High(Devices) do
  begin
    FInstanceVk.GetPhysicalDeviceProperties(Devices[I], @Props);
    if (Props.apiVersion and $1FFFFFFF) < VK_API_VERSION_1_3 then
      Continue;
    FillChar(F12, SizeOf(F12), 0);
    F12.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES;
    FillChar(F13, SizeOf(F13), 0);
    F13.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES;
    F13.pNext := @F12;
    FillChar(Features, SizeOf(Features), 0);
    Features.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2;
    Features.pNext := @F13;
    FInstanceVk.GetPhysicalDeviceFeatures2(Devices[I], @Features);
    if (F13.dynamicRendering = VK_FALSE) or (F13.synchronization2 = VK_FALSE) or (F12.timelineSemaphore = VK_FALSE) then
      Continue;
    Count := 0;
    FInstanceVk.EnumerateDeviceExtensionProperties(Devices[I], nil, @Count, nil);
    SetLength(Exts, Count);
    if Count > 0 then
      FInstanceVk.EnumerateDeviceExtensionProperties(Devices[I], nil, @Count, @Exts[0]);
    if not HasExtension(Exts, VK_KHR_SWAPCHAIN_EXTENSION_NAME) then
      Continue;
    // A family that draws and presents to windows (one queue for everything).
    Families := 0;
    FInstanceVk.GetPhysicalDeviceQueueFamilyProperties(Devices[I], @Families, nil);
    SetLength(Queues, Families);
    if Families > 0 then
      FInstanceVk.GetPhysicalDeviceQueueFamilyProperties(Devices[I], @Families, @Queues[0]);
    Family := High(Cardinal);
    for F := 0 to Integer(Families) - 1 do
      if ((Queues[F].queueFlags and Ord(VK_QUEUE_GRAPHICS_BIT)) <> 0) and
        (FInstanceVk.GetPhysicalDeviceWin32PresentationSupportKHR(Devices[I], Cardinal(F)) <> VK_FALSE) then
      begin
        Family := F;
        Break;
      end;
    if Family = High(Cardinal) then
      Continue;
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
      Best := Score;
      FPhysical := Devices[I];
      FQueueFamily := Family;
      FProperties := Props;
      FDualSource := Features.features.dualSrcBlend <> VK_FALSE;
    end;
  end;
  if Best < 0 then
    raise EFastVulkan.Create('FastCanvas: no Vulkan 1.3 device with dynamic rendering and a queue that presents');
  FInstanceVk.GetPhysicalDeviceMemoryProperties(FPhysical, @FMemory);
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
  Depth: TVkFormat;
  Props: TVkFormatProperties;
  AccelProps: TVkPhysicalDeviceAccelerationStructurePropertiesKHR;
  Props2: TVkPhysicalDeviceProperties2;
const
  DepthNeeds = Ord(VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT) or Ord(VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT);
begin
  Count := 0;
  FInstanceVk.EnumerateDeviceExtensionProperties(FPhysical, nil, @Count, nil);
  SetLength(Exts, Count);
  if Count > 0 then
    FInstanceVk.EnumerateDeviceExtensionProperties(FPhysical, nil, @Count, @Exts[0]);
  Names := [PAnsiChar(VK_KHR_SWAPCHAIN_EXTENSION_NAME)];
  Ray := HasExtension(Exts, VK_KHR_ACCELERATION_STRUCTURE_EXTENSION_NAME) and
    HasExtension(Exts, VK_KHR_DEFERRED_HOST_OPERATIONS_EXTENSION_NAME);
  FifoName := nil;
  if HasExtension(Exts, VK_KHR_PRESENT_MODE_FIFO_LATEST_READY_EXTENSION_NAME) then
    FifoName := VK_KHR_PRESENT_MODE_FIFO_LATEST_READY_EXTENSION_NAME
  else if HasExtension(Exts, VK_EXT_PRESENT_MODE_FIFO_LATEST_READY_EXTENSION_NAME) then
    FifoName := VK_EXT_PRESENT_MODE_FIFO_LATEST_READY_EXTENSION_NAME;

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
  F13.dynamicRendering := VK_TRUE;
  F13.synchronization2 := VK_TRUE;
  FillChar(Features, SizeOf(Features), 0);
  Features.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2;
  Features.pNext := @F13;
  if FDualSource then
    Features.features.dualSrcBlend := VK_TRUE;
  FPushDescriptor := HasExtension(Exts, VK_KHR_PUSH_DESCRIPTOR_EXTENSION_NAME);
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
  FScratchAlignment := 256;
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
  EnterCriticalSection(FAllocLock);
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
    LeaveCriticalSection(FAllocLock);
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
  EnterCriticalSection(FAllocLock);
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
    LeaveCriticalSection(FAllocLock);
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

initialization
  InitializeCriticalSection(GLogLock);
end.
