unit FastCanvas.DeviceVk;

{ The Vulkan device of FastCanvas (FastCanvasBackend = Vulkan): the loader, an instance (Vulkan 1.3, VK_KHR_surface
  and VK_KHR_win32_surface), the physical device (a discrete graphics card first, with a graphics queue family that
  presents to windows), the logical device with dynamic rendering, synchronization2 and timeline semaphores, its
  graphics queue and the device command table, and memory type lookup. Buffer device address, acceleration
  structures and ray query are enabled too where the device has them (the 3D context of a later stage needs them).

  FASTCANVAS_VK_DEBUG=<file>: the Khronos validation layer, whose warnings and errors a VK_EXT_debug_utils messenger
  appends to that file (as FASTCANVAS_D3D12_DEBUG does for the Direct3D 12 debug layer).

  The loader is held until Destroy: the unit Vulkan frees its handle in its finalization, which runs before FMX frees
  the forms and the canvas shuts the device down (FastCanvas.Service). Thread use as with Direct3D 12: the device is
  free-threaded, the queue and command recording are used with the device lock held (TFastDevice.Lock).

  Other platforms: VK_KHR_android_surface (Android) or VK_KHR_xlib_surface (Linux, X11) instead of
  VK_KHR_win32_surface; the queue family is the first one that draws (whether it presents to a window is asked when
  the window's surface is made). Devices below Vulkan 1.3 (many phones have 1.1) are taken when they have the
  extensions of the same features (VK_KHR_dynamic_rendering, VK_KHR_synchronization2, and below 1.2
  VK_KHR_timeline_semaphore): Legacy, the KHR commands then stand in for the core ones; no ray tracing features. }

interface

uses
  {$IFDEF MSWINDOWS}Winapi.Windows, {$ENDIF}System.SysUtils, Vulkan;

type
  EFastVulkan = class(Exception);

  TFastVulkan = class
  private
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
    /// <summary>The version of the instance (what the loader offers, at most 1.3).</summary>
    FInstanceVersion: Cardinal;
    /// <summary>The device is used through extensions below Vulkan 1.3.</summary>
    FLegacy: Boolean;
    procedure CreateInstance;
    procedure PickDevice(const APreferSoftware: Boolean);
    procedure CreateDevice;
    /// <summary>A device below Vulkan 1.3 (or of an instance below 1.3): True when it has the extensions and features
    /// the canvas needs; AFeatures: its core features.</summary>
    function LegacyFeatures(const ADevice: TVkPhysicalDevice; const AVersion: Cardinal;
      const AExts: TArray<TVkExtensionProperties>; out AFeatures: TVkPhysicalDeviceFeatures2): Boolean;
    procedure CreateLegacyDevice;
    function GetDeviceName: string;
    function GetApiVersion: Cardinal;
  public
    /// <summary>Raises EFastVulkan when there is no Vulkan 1.3 device (or 1.1 with the extensions of the same
    /// features) that can present to windows. APreferSoftware: a CPU implementation first (TFastDevice.UseWarp).
    /// </summary>
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
    /// <summary>Memory for ARequirements (see MemoryType); AFlags: the properties of the type taken. Raises when
    /// there is none.</summary>
    function Allocate(const ARequirements: TVkMemoryRequirements; const ARequired, APreferred: TVkMemoryPropertyFlags;
      out AFlags: TVkMemoryPropertyFlags): TVkDeviceMemory;
    /// <summary>Device commands (loaded for the device).</summary>
    property Vk: TVulkan read FVk;
    /// <summary>Instance commands (surfaces and other instance-level functions).</summary>
    property InstanceVk: TVulkan read FInstanceVk;
    property Instance: TVkInstance read FInstance;
    property Physical: TVkPhysicalDevice read FPhysical;
    property Properties: TVkPhysicalDeviceProperties read FProperties;
    property Device: TVkDevice read FDevice;
    /// <summary>The graphics queue, which also presents; used with the device lock held.</summary>
    property Queue: TVkQueue read FQueue;
    property QueueFamily: Cardinal read FQueueFamily;
    /// <summary>The validation layer is on (FASTCANVAS_VK_DEBUG).</summary>
    property Debug: Boolean read FDebug;
    /// <summary>A call returned VK_ERROR_DEVICE_LOST: the device has to be made again.</summary>
    property Lost: Boolean read FLost;
    /// <summary>Dual-source blending (ClearType text).</summary>
    property DualSource: Boolean read FDualSource;
    /// <summary>Features on for the 3D context of a later stage.</summary>
    property BufferDeviceAddress: Boolean read FBufferDeviceAddress;
    property AccelerationStructure: Boolean read FAccelerationStructure;
    property RayQuery: Boolean read FRayQuery;
    /// <summary>Below Vulkan 1.3: dynamic rendering, synchronization2 (and timeline semaphores) are extensions.
    /// </summary>
    property Legacy: Boolean read FLegacy;
    /// <summary>The device's name (diagnostics).</summary>
    property DeviceName: string read GetDeviceName;
    /// <summary>The Vulkan version of the device's driver (diagnostics; the canvas uses at most 1.3).</summary>
    property ApiVersion: Cardinal read GetApiVersion;
  end;

/// <summary>A Vulkan version as text: "1.3.280".</summary>
function FastVulkanVersionText(const AVersion: Cardinal): string;

implementation

const
  DebugVariable = 'FASTCANVAS_VK_DEBUG';
  ValidationLayer: AnsiString = 'VK_LAYER_KHRONOS_validation';
  /// <summary>Messages logged per process at most.</summary>
  MaxMessages = 2000;

  /// <summary>The Vulkan loader of the platform.</summary>
  LoaderName =
    {$IF Defined(MSWINDOWS)}'vulkan-1.dll'{$ELSEIF Defined(ANDROID)}'libvulkan.so'{$ELSE}'libvulkan.so.1'{$ENDIF};
  /// <summary>The surface extension of the platform's windows.</summary>
  SurfaceExtension = {$IF Defined(MSWINDOWS)}VK_KHR_WIN32_SURFACE_EXTENSION_NAME{$ELSEIF Defined(ANDROID)}
    VK_KHR_ANDROID_SURFACE_EXTENSION_NAME{$ELSE}VK_KHR_XLIB_SURFACE_EXTENSION_NAME{$ENDIF};

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

{ TFastVulkan }

constructor TFastVulkan.Create(const APreferSoftware: Boolean);
begin
  inherited Create;
  FDebug := GetEnvironmentVariable(DebugVariable) <> '';
  CreateInstance;
  PickDevice(APreferSoftware);
  CreateDevice;
end;

destructor TFastVulkan.Destroy;
begin
  if FDevice <> VK_NULL_HANDLE then
  begin
    FVk.DeviceWaitIdle(FDevice);
    FVk.DestroyDevice(FDevice, nil);
  end;
  if FMessenger <> VK_NULL_HANDLE then
    FInstanceVk.DestroyDebugUtilsMessengerEXT(FInstance, FMessenger, nil);
  if FInstance <> VK_NULL_HANDLE then
    FInstanceVk.DestroyInstance(FInstance, nil);
  FVk.Free;
  FInstanceVk.Free;
  if FLibrary <> 0 then
    FreeLibrary(FLibrary);
  inherited;
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
  Count, Families, Family: Cardinal;
  Devices: TArray<TVkPhysicalDevice>;
  Props: TVkPhysicalDeviceProperties;
  Queues: TArray<TVkQueueFamilyProperties>;
  Exts: TArray<TVkExtensionProperties>;
  Features: TVkPhysicalDeviceFeatures2;
  F13: TVkPhysicalDeviceVulkan13Features;
  F12: TVkPhysicalDeviceVulkan12Features;
  I, F, Score, Best: Integer;
  Legacy: Boolean;
  Name, Rejected: string;
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
    Count := 0;
    FInstanceVk.EnumerateDeviceExtensionProperties(Devices[I], nil, @Count, nil);
    SetLength(Exts, Count);
    if Count > 0 then
      FInstanceVk.EnumerateDeviceExtensionProperties(Devices[I], nil, @Count, @Exts[0]);
    Legacy := ((Props.apiVersion and $1FFFFFFF) < VK_API_VERSION_1_3) or (FInstanceVersion < VK_API_VERSION_1_3);
    if Legacy then
    begin
      if not LegacyFeatures(Devices[I], Props.apiVersion, Exts, Features) then
      begin
        Rejected := Rejected + '; ' + Name + ': no dynamic rendering, synchronization2 or timeline semaphores';
        Continue;
      end;
    end
    else
    begin
      FillChar(F12, SizeOf(F12), 0);
      F12.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES;
      FillChar(F13, SizeOf(F13), 0);
      F13.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES;
      F13.pNext := @F12;
      FillChar(Features, SizeOf(Features), 0);
      Features.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2;
      Features.pNext := @F13;
      FInstanceVk.GetPhysicalDeviceFeatures2(Devices[I], @Features);
      if (F13.dynamicRendering = VK_FALSE) or (F13.synchronization2 = VK_FALSE) or
        (F12.timelineSemaphore = VK_FALSE) then
      begin
        Rejected := Rejected + '; ' + Name + ': no dynamic rendering, synchronization2 or timeline semaphores';
        Continue;
      end;
    end;
    if not HasExtension(Exts, VK_KHR_SWAPCHAIN_EXTENSION_NAME) then
    begin
      Rejected := Rejected + '; ' + Name + ': no swap chains';
      Continue;
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
      Rejected := Rejected + '; ' + Name + ': no queue family that draws and presents';
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
      Best := Score;
      FPhysical := Devices[I];
      FQueueFamily := Family;
      FProperties := Props;
      FDualSource := Features.features.dualSrcBlend <> VK_FALSE;
      FLegacy := Legacy;
    end;
  end;
  if Best < 0 then
    raise EFastVulkan.Create('FastCanvas: no Vulkan 1.3 device with dynamic rendering and a queue that presents' +
      Rejected);
  FInstanceVk.GetPhysicalDeviceMemoryProperties(FPhysical, @FMemory);
end;

function TFastVulkan.LegacyFeatures(const ADevice: TVkPhysicalDevice; const AVersion: Cardinal;
  const AExts: TArray<TVkExtensionProperties>; out AFeatures: TVkPhysicalDeviceFeatures2): Boolean;
var
  Dynamic: TVkPhysicalDeviceDynamicRenderingFeatures;
  Sync2: TVkPhysicalDeviceSynchronization2Features;
  Timeline: TVkPhysicalDeviceTimelineSemaphoreFeatures;
  Version: Cardinal;
begin
  FillChar(AFeatures, SizeOf(AFeatures), 0);
  Version := AVersion and $1FFFFFFF;
  if Version > FInstanceVersion then
    Version := FInstanceVersion;
  Result := False;
  // Dynamic rendering needs depth_stencil_resolve, which needs create_renderpass2 (both core in 1.2).
  if (Version < VK_API_VERSION_1_1) or not HasExtension(AExts, VK_KHR_DYNAMIC_RENDERING_EXTENSION_NAME) or
    not HasExtension(AExts, VK_KHR_SYNCHRONIZATION_2_EXTENSION_NAME) then
    Exit;
  if (Version < VK_API_VERSION_1_2) and (not HasExtension(AExts, VK_KHR_TIMELINE_SEMAPHORE_EXTENSION_NAME) or
    not HasExtension(AExts, VK_KHR_DEPTH_STENCIL_RESOLVE_EXTENSION_NAME) or
    not HasExtension(AExts, VK_KHR_CREATE_RENDERPASS_2_EXTENSION_NAME)) then
    Exit;
  FillChar(Timeline, SizeOf(Timeline), 0);
  Timeline.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TIMELINE_SEMAPHORE_FEATURES;
  FillChar(Sync2, SizeOf(Sync2), 0);
  Sync2.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SYNCHRONIZATION_2_FEATURES;
  Sync2.pNext := @Timeline;
  FillChar(Dynamic, SizeOf(Dynamic), 0);
  Dynamic.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES;
  Dynamic.pNext := @Sync2;
  AFeatures.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2;
  AFeatures.pNext := @Dynamic;
  FInstanceVk.GetPhysicalDeviceFeatures2(ADevice, @AFeatures);
  AFeatures.pNext := nil;
  Result := (Dynamic.dynamicRendering <> VK_FALSE) and (Sync2.synchronization2 <> VK_FALSE) and
    (Timeline.timelineSemaphore <> VK_FALSE);
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
  Cmds: TVulkanCommands;
  Res: TVkResult;
  Ray: Boolean;
begin
  if FLegacy then
  begin
    CreateLegacyDevice;
    Exit;
  end;
  Count := 0;
  FInstanceVk.EnumerateDeviceExtensionProperties(FPhysical, nil, @Count, nil);
  SetLength(Exts, Count);
  if Count > 0 then
    FInstanceVk.EnumerateDeviceExtensionProperties(FPhysical, nil, @Count, @Exts[0]);
  Names := [PAnsiChar(VK_KHR_SWAPCHAIN_EXTENSION_NAME)];
  Ray := HasExtension(Exts, VK_KHR_ACCELERATION_STRUCTURE_EXTENSION_NAME) and
    HasExtension(Exts, VK_KHR_DEFERRED_HOST_OPERATIONS_EXTENSION_NAME);

  // What the device has of the optional features.
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
  FInstanceVk.GetPhysicalDeviceFeatures2(FPhysical, @Features);
  FBufferDeviceAddress := F12.bufferDeviceAddress <> VK_FALSE;
  FAccelerationStructure := Ray and FBufferDeviceAddress and (AccelFeatures.accelerationStructure <> VK_FALSE);
  FRayQuery := FAccelerationStructure and HasExtension(Exts, VK_KHR_RAY_QUERY_EXTENSION_NAME) and
    (RayFeatures.rayQuery <> VK_FALSE);

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
end;

procedure TFastVulkan.CreateLegacyDevice;
var
  Names: TArray<PAnsiChar>;
  Priority: Single;
  Queue: TVkDeviceQueueCreateInfo;
  Info: TVkDeviceCreateInfo;
  Features: TVkPhysicalDeviceFeatures2;
  Dynamic: TVkPhysicalDeviceDynamicRenderingFeatures;
  Sync2: TVkPhysicalDeviceSynchronization2Features;
  Timeline: TVkPhysicalDeviceTimelineSemaphoreFeatures;
  Cmds: TVulkanCommands;
  Res: TVkResult;
begin
  Names := [PAnsiChar(VK_KHR_SWAPCHAIN_EXTENSION_NAME), PAnsiChar(VK_KHR_DYNAMIC_RENDERING_EXTENSION_NAME),
    PAnsiChar(VK_KHR_SYNCHRONIZATION_2_EXTENSION_NAME)];
  if GetApiVersion < VK_API_VERSION_1_2 then
    Names := Names + [PAnsiChar(VK_KHR_TIMELINE_SEMAPHORE_EXTENSION_NAME),
      PAnsiChar(VK_KHR_DEPTH_STENCIL_RESOLVE_EXTENSION_NAME), PAnsiChar(VK_KHR_CREATE_RENDERPASS_2_EXTENSION_NAME)];
  FillChar(Timeline, SizeOf(Timeline), 0);
  Timeline.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TIMELINE_SEMAPHORE_FEATURES;
  Timeline.timelineSemaphore := VK_TRUE;
  FillChar(Sync2, SizeOf(Sync2), 0);
  Sync2.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SYNCHRONIZATION_2_FEATURES;
  Sync2.pNext := @Timeline;
  Sync2.synchronization2 := VK_TRUE;
  FillChar(Dynamic, SizeOf(Dynamic), 0);
  Dynamic.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES;
  Dynamic.pNext := @Sync2;
  Dynamic.dynamicRendering := VK_TRUE;
  FillChar(Features, SizeOf(Features), 0);
  Features.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2;
  Features.pNext := @Dynamic;
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
  if not Assigned(Cmds.CmdBeginRendering) or not Assigned(Cmds.CmdPipelineBarrier2) or
    not Assigned(Cmds.QueueSubmit2) or not Assigned(Cmds.WaitSemaphores) then
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

function TFastVulkan.Allocate(const ARequirements: TVkMemoryRequirements; const ARequired,
  APreferred: TVkMemoryPropertyFlags; out AFlags: TVkMemoryPropertyFlags): TVkDeviceMemory;
var
  Info: TVkMemoryAllocateInfo;
  Index: Integer;
begin
  Index := MemoryType(ARequirements.memoryTypeBits, ARequired, APreferred);
  if Index < 0 then
    raise EFastVulkan.Create('FastCanvas: no Vulkan memory type for a resource');
  AFlags := FMemory.memoryTypes[Index].propertyFlags;
  FillChar(Info, SizeOf(Info), 0);
  Info.sType := VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
  Info.allocationSize := ARequirements.size;
  Info.memoryTypeIndex := Index;
  Result := VK_NULL_HANDLE;
  Check(FVk.AllocateMemory(FDevice, @Info, nil, @Result), 'vkAllocateMemory');
end;

initialization
{$IFDEF MSWINDOWS}
  InitializeCriticalSection(GLogLock);
{$ELSE}
  GLogLock := TObject.Create;
{$ENDIF}
end.
