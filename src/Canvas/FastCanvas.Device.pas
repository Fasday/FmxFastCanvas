unit FastCanvas.Device;

{ The graphics device of FastCanvas: one device per process, of the graphics API that FastCanvasBackend selects when
  it is created, with the DXGI factory, a multithreaded Direct2D factory and the DirectWrite factory.

  - Direct3D 11: the device and its immediate context, and a Direct2D 1.1 device on it (only the D2DText measurement
    aid draws with Direct2D).
  - Direct3D 12: the device and its direct queue; the canvas records and submits its own command lists
    (FastCanvas.Gpu12). No Direct2D device: the Direct2D factory serves the CPU geometry (Simplify, Widen,
    FillContainsPoint) and the software rasterization of color fonts.
  - Vulkan: the instance, device and graphics queue of FastCanvas.DeviceVk; the canvas records and submits its own
    command buffers (FastCanvas.GpuVk). The Direct2D factory as with Direct3D 12; no DXGI factory.

  Thread use: the device, the queue and the factories are free-threaded. The immediate context (Direct3D 11) and the
  open command list (Direct3D 12) or command buffer (Vulkan) are used by the render thread, and by other threads
  only between Lock and Unlock (the Direct2D multithread lock, which Direct2D itself takes around its use of the
  context). }

interface

uses
  DX12.D3D12, DX12.D3DCommon,
  Winapi.Windows, Winapi.DXGI, Winapi.DXGI1_2, Winapi.D3DCommon, Winapi.D3D11, Winapi.D2D1, System.SysUtils,
  FastCanvas.D2D1Ext, FastCanvas.DWriteExt, FastCanvas.DeviceVk;

type
  EFastDevice = class(Exception);

  {$SCOPEDENUMS ON}
  TFastCanvasBackend = (D3D11, D3D12, Vulkan);
  /// <summary>Direct3D 12 DRED auto-breadcrumbs (FastCanvasD3D12Breadcrumbs).</summary>
  TFastCanvasBreadcrumbs = (Off, On, Nvidia);
  {$SCOPEDENUMS OFF}

var
  /// <summary>The graphics API of the canvas. Read when the device is created (the first canvas, bitmap or text
  /// layout): set it before Application.Initialize.</summary>
  FastCanvasBackend: TFastCanvasBackend = TFastCanvasBackend.D3D11;
  /// <summary>Direct3D 12: DRED auto-breadcrumbs, the GPU records which commands it finished (for diagnosing a
  /// removed device); costs GPU time. Nvidia: on NVIDIA graphics cards only (a hang of ray tracing structure builds on
  /// an RTX 5080 with driver 610.88 went away with them). Read when the device is created.</summary>
  FastCanvasD3D12Breadcrumbs: TFastCanvasBreadcrumbs = TFastCanvasBreadcrumbs.Off;

type
  TFastDevice = class sealed
  private type
    /// <summary>The device and the factories. On the heap, not in class variables: the finalization of this unit
    /// would release managed class variables, while forms, canvases and bitmaps are freed by FMX after the unit
    /// finalizations (FinalizeForms) and still use them; the canvas service releases them then (Finish).</summary>
    TRefs = record
      D3D: ID3D11Device;
      Context: ID3D11DeviceContext;
      DXGIFactory: IDXGIFactory2;
      D2DFactory: ID2D1Factory1;
      D2DDevice: ID2D1Device;
      D2DLock: ID2D1Multithread;
      DWrite: IDWriteFactory;
      DWrite2: IDWriteFactory2;
      D3D12: ID3D12Device;
      Queue: ID3D12CommandQueue;
      /// <summary>Owned: freed by Release and ResetDevice.</summary>
      Vulkan: TFastVulkan;
    end;
    PRefs = ^TRefs;
  private class var
    FBackend: TFastCanvasBackend;
    /// <summary>nil after Finish.</summary>
    FRefs: PRefs;
    FLevel: D3D_FEATURE_LEVEL;
    FHardware: Boolean;
    FTearing: Boolean;
    FCreateLock: TObject;
    FUseWarp: Boolean;
    FDebug12: Boolean;
    FVendorId: Cardinal;
    class procedure CreateDevice; static;
    class procedure CreateDevice12; static;
    class procedure CreateDeviceVk; static;
    class procedure CreateFactories; static;
    class procedure CheckTearing; static;
    class function GetD3D: ID3D11Device; static;
    class function GetContext: ID3D11DeviceContext; static;
    class function GetDXGIFactory: IDXGIFactory2; static;
    class function GetD2DFactory: ID2D1Factory1; static;
    class function GetD2DDevice: ID2D1Device; static;
    class function GetDWrite: IDWriteFactory; static;
    class function GetDWrite2: IDWriteFactory2; static;
    class function GetD3D12: ID3D12Device; static;
    class function GetQueue: ID3D12CommandQueue; static;
    class function GetVulkan: TFastVulkan; static;
  public
    class constructor Create;
    /// <summary>Creates the device and factories on first use. Raises EFastDevice when the graphics API is missing.
    /// </summary>
    class procedure Ensure; static;
    /// <summary>Releases the device and the factories (they can be made again).</summary>
    class procedure Release; static;
    /// <summary>Shutdown, after every form is freed: Release, and the device cannot be made again.</summary>
    class procedure Finish; static;
    /// <summary>Replaces the device (and its context or queue) by a new one of the same backend, after the device was
    /// removed; the factories and the lock stay. The caller makes sure nothing uses the old device meanwhile.
    /// </summary>
    class procedure ResetDevice; static;
    class function Ready: Boolean; static;
    class procedure Lock; static;
    class procedure Unlock; static;
    /// <summary>S_OK, or the reason the device stopped working (DXGI_ERROR_DEVICE_REMOVED and friends).</summary>
    class function RemovedReason: HResult; static;
    /// <summary>The graphics API of the current device.</summary>
    class property Backend: TFastCanvasBackend read FBackend;
    /// <summary>Direct3D 11: the device and its immediate context; else nil.</summary>
    class property D3D: ID3D11Device read GetD3D;
    class property Context: ID3D11DeviceContext read GetContext;
    class property FeatureLevel: D3D_FEATURE_LEVEL read FLevel;
    class property Hardware: Boolean read FHardware;
    class property DXGIFactory: IDXGIFactory2 read GetDXGIFactory;
    class property TearingSupported: Boolean read FTearing;
    class property D2DFactory: ID2D1Factory1 read GetD2DFactory;
    /// <summary>Direct3D 11 only, else nil.</summary>
    class property D2DDevice: ID2D1Device read GetD2DDevice;
    class property DWrite: IDWriteFactory read GetDWrite;
    /// <summary>nil before Windows 8.1.</summary>
    class property DWrite2: IDWriteFactory2 read GetDWrite2;
    /// <summary>Set before the first use: WARP (software) instead of the hardware adapter.</summary>
    class property UseWarp: Boolean read FUseWarp write FUseWarp;
    /// <summary>Direct3D 12: the device and its direct queue; else nil.</summary>
    class property D3D12: ID3D12Device read GetD3D12;
    class property Queue: ID3D12CommandQueue read GetQueue;
    /// <summary>Vulkan: the instance, device and queue; else nil.</summary>
    class property Vulkan: TFastVulkan read GetVulkan;
    /// <summary>Direct3D 12 with the debug layer (environment variable FASTCANVAS_D3D12_DEBUG: the file its messages
    /// go to).</summary>
    class property Debug12: Boolean read FDebug12;
    /// <summary>PCI vendor of the graphics card of the device ($10DE NVIDIA, $1002 AMD, $8086 Intel, $1414 WARP).
    /// </summary>
    class property AdapterVendorId: Cardinal read FVendorId;
    /// <summary>Largest texture side for the feature level (Vulkan: of the device's limits).</summary>
    class function MaxTextureSize: Integer; static;
  end;

implementation

uses
  DX12.D3D12SDKLayers, DX12.DXGI1_4, System.Math, Winapi.DXGI1_3, Winapi.DxgiType, Vulkan;

/// <summary>CreateDXGIFactory2 with the interface ID by reference, as dxgi.dll takes it (REFIID). Winapi.DXGI1_3
/// declares it by value, which only Win64 passes as a pointer: a Win32 build wrote the factory to an address made of
/// the GUID's bytes (an access violation in dxgi.dll).</summary>
function CreateDXGIFactory2(Flags: UINT; const [ref] riid: TGUID; out ppFactory): HResult; stdcall;
  external 'dxgi.dll';

{ TFastDevice }

class constructor TFastDevice.Create;
begin
  // Freed by Finish, not by a class destructor: forms, canvases and bitmaps are destroyed by FMX after the unit
  // finalizations, and the canvas service shuts the device down then (FastCanvas.Service).
  FCreateLock := TObject.Create;
  New(FRefs);
end;

class function TFastDevice.GetD3D: ID3D11Device;
begin
  if FRefs <> nil then
    Result := FRefs.D3D
  else
    Result := nil;
end;

class function TFastDevice.GetContext: ID3D11DeviceContext;
begin
  if FRefs <> nil then
    Result := FRefs.Context
  else
    Result := nil;
end;

class function TFastDevice.GetDXGIFactory: IDXGIFactory2;
begin
  if FRefs <> nil then
    Result := FRefs.DXGIFactory
  else
    Result := nil;
end;

class function TFastDevice.GetD2DFactory: ID2D1Factory1;
begin
  if FRefs <> nil then
    Result := FRefs.D2DFactory
  else
    Result := nil;
end;

class function TFastDevice.GetD2DDevice: ID2D1Device;
begin
  if FRefs <> nil then
    Result := FRefs.D2DDevice
  else
    Result := nil;
end;

class function TFastDevice.GetDWrite: IDWriteFactory;
begin
  if FRefs <> nil then
    Result := FRefs.DWrite
  else
    Result := nil;
end;

class function TFastDevice.GetDWrite2: IDWriteFactory2;
begin
  if FRefs <> nil then
    Result := FRefs.DWrite2
  else
    Result := nil;
end;

class function TFastDevice.GetD3D12: ID3D12Device;
begin
  if FRefs <> nil then
    Result := FRefs.D3D12
  else
    Result := nil;
end;

class function TFastDevice.GetQueue: ID3D12CommandQueue;
begin
  if FRefs <> nil then
    Result := FRefs.Queue
  else
    Result := nil;
end;

class function TFastDevice.GetVulkan: TFastVulkan;
begin
  if FRefs <> nil then
    Result := FRefs.Vulkan
  else
    Result := nil;
end;

class procedure TFastDevice.CheckTearing;
var
  Factory5: IDXGIFactory5;
  Tearing: BOOL;
begin
  Tearing := False;
  FTearing := Supports(FRefs.DXGIFactory, IDXGIFactory5, Factory5) and
    Succeeded(Factory5.CheckFeatureSupport(DXGI_FEATURE_PRESENT_ALLOW_TEARING, @Tearing, SizeOf(Tearing))) and Tearing;
end;

class procedure TFastDevice.CreateDevice;
const
  Levels: array[0..3] of D3D_FEATURE_LEVEL = (D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0,
    D3D_FEATURE_LEVEL_10_1, D3D_FEATURE_LEVEL_10_0);

  function TryCreate(const ADriver: D3D_DRIVER_TYPE): Boolean;
  var
    Res: HResult;
  begin
    Res := D3D11CreateDevice(nil, ADriver, 0, D3D11_CREATE_DEVICE_BGRA_SUPPORT, @Levels[0], Length(Levels),
      D3D11_SDK_VERSION, FRefs.D3D, FLevel, FRefs.Context);
    // Runtimes that do not know 11_1 reject the whole list.
    if Res = E_INVALIDARG then
      Res := D3D11CreateDevice(nil, ADriver, 0, D3D11_CREATE_DEVICE_BGRA_SUPPORT, @Levels[1], Length(Levels) - 1,
        D3D11_SDK_VERSION, FRefs.D3D, FLevel, FRefs.Context);
    Result := Succeeded(Res) and (FRefs.D3D <> nil);
  end;

var
  Device: IDXGIDevice;
  Adapter: IDXGIAdapter;
  Desc: TDXGIAdapterDesc;
begin
  FHardware := not FUseWarp and TryCreate(D3D_DRIVER_TYPE_HARDWARE);
  if not FHardware and not TryCreate(D3D_DRIVER_TYPE_WARP) then
    raise EFastDevice.Create('FastCanvas: cannot create a Direct3D 11 device');
  FVendorId := 0;
  if Supports(FRefs.D3D, IDXGIDevice, Device) and Succeeded(Device.GetParent(IDXGIAdapter, Adapter)) and (Adapter <> nil) then
  begin
    Adapter.GetParent(IDXGIFactory2, FRefs.DXGIFactory);
    if Succeeded(Adapter.GetDesc(Desc)) then
      FVendorId := Desc.VendorId;
  end;
  if FRefs.DXGIFactory = nil then
    raise EFastDevice.Create('FastCanvas: DXGI 1.2 is required');
  CheckTearing;
end;

class procedure TFastDevice.CreateDevice12;
var
  Desc: TD3D12_COMMAND_QUEUE_DESC;
  Debug: ID3D12Debug;
  Factory4: IDXGIFactory4;
  Adapter: IDXGIAdapter;
  First: IDXGIAdapter1;
  AdapterDesc: TDXGIAdapterDesc;
  Desc1: TDXGIAdapterDesc1;
  Dred: ID3D12DeviceRemovedExtendedDataSettings;
  Res: HResult;
begin
  if not FDebug12 then
    FDebug12 := GetEnvironmentVariable('FASTCANVAS_D3D12_DEBUG') <> '';
  if FDebug12 and Succeeded(D3D12GetDebugInterface(IID_ID3D12Debug, Debug)) then
    Debug.EnableDebugLayer;
  if Failed(CreateDXGIFactory2(0, IDXGIFactory2, FRefs.DXGIFactory)) or (FRefs.DXGIFactory = nil) then
    raise EFastDevice.Create('FastCanvas: DXGI 1.3 is required');
  Adapter := nil;
  if FUseWarp and Supports(FRefs.DXGIFactory, IDXGIFactory4, Factory4) then
    Factory4.EnumWarpAdapter(IDXGIAdapter, Adapter);
  // The vendor of the adapter: WARP, or the first one (D3D12CreateDevice's default).
  FVendorId := 0;
  if Adapter <> nil then
  begin
    if Succeeded(Adapter.GetDesc(AdapterDesc)) then
      FVendorId := AdapterDesc.VendorId;
  end
  else if Succeeded(FRefs.DXGIFactory.EnumAdapters1(0, First)) and Succeeded(First.GetDesc1(Desc1)) then
    FVendorId := Desc1.VendorId;
  if ((FastCanvasD3D12Breadcrumbs = TFastCanvasBreadcrumbs.On) or
    ((FastCanvasD3D12Breadcrumbs = TFastCanvasBreadcrumbs.Nvidia) and (FVendorId = $10DE))) and
    Succeeded(D3D12GetDebugInterface(IID_ID3D12DeviceRemovedExtendedDataSettings, Dred)) then
    Dred.SetAutoBreadcrumbsEnablement(D3D12_DRED_ENABLEMENT_FORCED_ON);
  Res := D3D12CreateDevice(Adapter, DX12.D3DCommon.D3D_FEATURE_LEVEL_11_0, IID_ID3D12Device, @FRefs.D3D12);
  if Failed(Res) or (FRefs.D3D12 = nil) then
    raise EFastDevice.CreateFmt('FastCanvas: cannot create a Direct3D 12 device (0x%.8x)', [Cardinal(Res)]);
  FillChar(Desc, SizeOf(Desc), 0);
  Desc._Type := D3D12_COMMAND_LIST_TYPE_DIRECT;
  Res := FRefs.D3D12.CreateCommandQueue(Desc, IID_ID3D12CommandQueue, FRefs.Queue);
  if Failed(Res) then
    raise EFastDevice.CreateFmt('FastCanvas: cannot create the Direct3D 12 queue (0x%.8x)', [Cardinal(Res)]);
  FLevel := D3D_FEATURE_LEVEL_11_0;
  FHardware := Adapter = nil;
  CheckTearing;
end;

class procedure TFastDevice.CreateDeviceVk;
begin
  try
    FRefs.Vulkan := TFastVulkan.Create(FUseWarp);
  except
    on E: EFastVulkan do
      raise EFastDevice.Create(E.Message);
  end;
  FVendorId := FRefs.Vulkan.Properties.vendorID;
  FHardware := FRefs.Vulkan.Properties.deviceType <> VK_PHYSICAL_DEVICE_TYPE_CPU;
  FLevel := D3D_FEATURE_LEVEL_11_0;
  // Windows present with VK_PRESENT_MODE_IMMEDIATE_KHR when they allow tearing (FastCanvas.GpuVk), no DXGI flag.
  FTearing := False;
end;

class procedure TFastDevice.CreateFactories;
var
  Factory: ID2D1Factory;
  Device: IDXGIDevice;
  Unk: IUnknown;
begin
  if Failed(D2D1CreateFactory(D2D1_FACTORY_TYPE_MULTI_THREADED, ID2D1Factory1, nil, Factory)) or
    not Supports(Factory, ID2D1Factory1, FRefs.D2DFactory) then
    raise EFastDevice.Create('FastCanvas: Direct2D 1.1 is required');
  Supports(FRefs.D2DFactory, ID2D1Multithread, FRefs.D2DLock);
  if (FRefs.D3D <> nil) and (not Supports(FRefs.D3D, IDXGIDevice, Device) or Failed(FRefs.D2DFactory.CreateDevice(Device, FRefs.D2DDevice))) then
    raise EFastDevice.Create('FastCanvas: cannot create the Direct2D device');
  if Succeeded(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, IDWriteFactory2, Unk)) and
    Supports(Unk, IDWriteFactory2, FRefs.DWrite2) then
    FRefs.DWrite := FRefs.DWrite2
  else if Failed(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, IDWriteFactory, Unk)) or
    not Supports(Unk, IDWriteFactory, FRefs.DWrite) then
    raise EFastDevice.Create('FastCanvas: cannot create the DirectWrite factory');
end;

class procedure TFastDevice.Ensure;
var
  Mask: TArithmeticExceptionMask;
begin
  if FRefs = nil then
    raise EFastDevice.Create('FastCanvas: the device is shut down');
  if FRefs.DWrite <> nil then
    Exit;
  TMonitor.Enter(FCreateLock);
  try
    if FRefs.DWrite <> nil then
      Exit;
    // Direct3D and Direct2D expect the floating point exceptions masked.
    Mask := GetExceptionMask;
    SetExceptionMask(exAllArithmeticExceptions);
    try
      try
        FBackend := FastCanvasBackend;
        case FBackend of
          TFastCanvasBackend.D3D12: CreateDevice12;
          TFastCanvasBackend.Vulkan: CreateDeviceVk;
        else
          CreateDevice;
        end;
        CreateFactories;
      except
        Release;
        raise;
      end;
    finally
      SetExceptionMask(Mask);
    end;
  finally
    TMonitor.Exit(FCreateLock);
  end;
end;

class procedure TFastDevice.Finish;
begin
  if FRefs = nil then
    Exit;
  Release;
  Dispose(FRefs);
  FRefs := nil;
  FreeAndNil(FCreateLock);
end;

class procedure TFastDevice.Release;
begin
  if FRefs = nil then
    Exit;
  if FRefs.Context <> nil then
  begin
    FRefs.Context.ClearState;
    FRefs.Context.Flush;
  end;
  FRefs.Queue := nil;
  FRefs.D3D12 := nil;
  FreeAndNil(FRefs.Vulkan);
  FRefs.D2DDevice := nil;
  FRefs.D2DLock := nil;
  FRefs.D2DFactory := nil;
  FRefs.DWrite2 := nil;
  FRefs.DWrite := nil;
  FRefs.DXGIFactory := nil;
  FRefs.Context := nil;
  FRefs.D3D := nil;
end;

class procedure TFastDevice.ResetDevice;
var
  Mask: TArithmeticExceptionMask;
  Device: IDXGIDevice;
begin
  if FRefs = nil then
    Exit;
  TMonitor.Enter(FCreateLock);
  try
    if FRefs.Context <> nil then
    begin
      // A window takes a new flip-model swap chain only when the old one is destroyed.
      FRefs.Context.ClearState;
      FRefs.Context.Flush;
    end;
    FRefs.D2DDevice := nil;
    FRefs.DXGIFactory := nil;
    FRefs.Context := nil;
    FRefs.D3D := nil;
    FRefs.Queue := nil;
    FRefs.D3D12 := nil;
    FreeAndNil(FRefs.Vulkan);
    Mask := GetExceptionMask;
    SetExceptionMask(exAllArithmeticExceptions);
    try
      case FBackend of
        TFastCanvasBackend.D3D12: CreateDevice12;
        TFastCanvasBackend.Vulkan: CreateDeviceVk;
      else
        CreateDevice;
      end;
      if FRefs.D2DFactory = nil then
        CreateFactories
      else if (FRefs.D3D <> nil) and (not Supports(FRefs.D3D, IDXGIDevice, Device) or
        Failed(FRefs.D2DFactory.CreateDevice(Device, FRefs.D2DDevice))) then
        raise EFastDevice.Create('FastCanvas: cannot create the Direct2D device');
    finally
      SetExceptionMask(Mask);
    end;
  finally
    TMonitor.Exit(FCreateLock);
  end;
end;

class function TFastDevice.Ready: Boolean;
begin
  Result := (FRefs <> nil) and (FRefs.DWrite <> nil) and
    ((FRefs.D3D <> nil) or (FRefs.D3D12 <> nil) or (FRefs.Vulkan <> nil));
end;

class procedure TFastDevice.Lock;
begin
  if (FRefs <> nil) and (FRefs.D2DLock <> nil) then
    FRefs.D2DLock.Enter;
end;

class procedure TFastDevice.Unlock;
begin
  if (FRefs <> nil) and (FRefs.D2DLock <> nil) then
    FRefs.D2DLock.Leave;
end;

class function TFastDevice.RemovedReason: HResult;
begin
  if FRefs = nil then
    Result := S_OK
  else if FRefs.D3D12 <> nil then
    Result := FRefs.D3D12.GetDeviceRemovedReason
  else if FRefs.D3D <> nil then
    Result := FRefs.D3D.GetDeviceRemovedReason
  else if (FRefs.Vulkan <> nil) and FRefs.Vulkan.Lost then
    Result := DXGI_ERROR_DEVICE_REMOVED
  else
    Result := S_OK;
end;

class function TFastDevice.MaxTextureSize: Integer;
begin
  if (FRefs <> nil) and (FRefs.Vulkan <> nil) then
    Result := FRefs.Vulkan.Properties.limits.maxImageDimension2D
  else if ((FRefs <> nil) and (FRefs.D3D12 <> nil)) or (FLevel >= D3D_FEATURE_LEVEL_11_0) then
    Result := 16384
  else
    Result := 8192;
end;

end.
