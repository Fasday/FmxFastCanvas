unit FastCanvas.Dlss;

{ Native NVIDIA DLSS Super Resolution through the driver's NGX Core. The declarations follow NVIDIA's nvsdk_ngx.h and
  nvsdk_ngx_params.h (NVIDIA RTX SDK, see THIRD_PARTY_NOTICES.md). No C++ wrapper or static NGX library is linked;
  nvngx_dlss.dll of the DLSS SDK goes next to the EXE. Win64 only.

  One NGX session per device for the process (TFastDlss.Acquire, main thread): initialized when a 3D context first
  uses DLSS, shut down when its last user goes (a new device gets a session of its own, so the shutdown of the old one
  never touches it). A TFastDlssFeature per 3D context: created and evaluated by the render thread, released when the
  GPU is done with it. The NGX parameter block is shared: every use holds the lock of the unit. }

interface

uses
  System.SysUtils, System.Types, DX12.D3D12;

type
  {$SCOPEDENUMS ON}
  TFastDlssMode = (Off, Quality, Balanced, Performance, UltraPerformance, DLAA);
  /// <summary>Diagnostics of the jitter (FastDlssJitterTest).</summary>
  TFastDlssJitterTest = (Normal, Off, NegateX, NegateY, NegateXY);
  {$SCOPEDENUMS OFF}

  /// <summary>The NGX session of a device (reference counted: held by the unit for the current device and by the
  /// features made on it).</summary>
  TFastDlss = class(TInterfacedObject)
  private
    FDevice: ID3D12Device;
    FParameters: Pointer;
    FInitialized, FAvailable: Boolean;
    FError: string;
    FInit, FCapabilities, FDestroy, FCreate, FEvaluate, FRelease, FShutdown: Pointer;
    procedure Initialize;
    function Slot(const AIndex: Integer): Pointer;
    procedure SetUInt(const AName: PAnsiChar; const AValue: Cardinal);
    procedure SetInt(const AName: PAnsiChar; const AValue: Integer);
    procedure SetFloat(const AName: PAnsiChar; const AValue: Single);
    procedure SetResource(const AName: PAnsiChar; const AValue: ID3D12Resource);
    function GetInt(const AName: PAnsiChar; out AValue: Integer): Cardinal;
    function GetUInt(const AName: PAnsiChar; out AValue: Cardinal): Cardinal;
    function GetPointer(const AName: PAnsiChar; out AValue: Pointer): Cardinal;
  public
    constructor Create(const ADevice: ID3D12Device);
    destructor Destroy; override;
    /// <summary>The session of ADevice, initialized on first use; a new device gets a new one. Main thread.</summary>
    class function Acquire(const ADevice: ID3D12Device): TFastDlss;
    /// <summary>The render size for an output size and mode (NVIDIA's optimal settings). Main thread.</summary>
    function RenderSize(const AOutput: TSize; const AMode: TFastDlssMode): TSize;
    /// <summary>The lock of the NGX parameter block and of the errors; also held by the 3D context while it
    /// replaces its feature, against readers on other threads.</summary>
    class procedure Lock; static;
    class procedure Unlock; static;
    property Device: ID3D12Device read FDevice;
    /// <summary>DLSS SR can be used: NVIDIA graphics card, driver with NGX, nvngx_dlss.dll, Win64.</summary>
    property Available: Boolean read FAvailable;
    /// <summary>Why it cannot (set when the session is made).</summary>
    property Error: string read FError;
  end;

  /// <summary>The DLSS SR feature of a 3D context. Configure and Evaluate on the render thread; Release and Destroy
  /// when the GPU is done with it.</summary>
  TFastDlssFeature = class
  private
    FSession: TFastDlss;
    FSessionRef: IInterface;
    FHandle: Pointer;
    FInput, FOutput: TSize;
    FMode: TFastDlssMode;
    FHdr: Boolean;
    FFrames: Int64;
    FError: string;
    function Check(const AResult: Cardinal; const AOperation: string): Boolean;
  public
    constructor Create(const ASession: TFastDlss);
    destructor Destroy; override;
    /// <summary>The feature for these sizes and mode, made again when they changed (the context waited for the GPU
    /// before it changed them).</summary>
    function Configure(const AList: ID3D12GraphicsCommandList; const AInput, AOutput: TSize;
      const AMode: TFastDlssMode; const AHdr: Boolean): Boolean;
    function Evaluate(const AList: ID3D12GraphicsCommandList; const AColor, ADepth, AMotion, AOutput: ID3D12Resource;
      const AJitter: TPointF; const AReset: Boolean; const AFrameTimeMs: Single): Boolean;
    procedure Release;
    property Session: TFastDlss read FSession;
    /// <summary>The last NGX error of Configure or Evaluate, '' when they worked. Any thread.</summary>
    function Error: string;
    /// <summary>Evaluations that worked. Any thread.</summary>
    function Frames: Int64;
  end;

var
  /// <summary>The NGX project ID of the application (a GUID of its own, as NVIDIA asks of applications without an
  /// engine ID); read when the session is made.</summary>
  FastDlssProjectId: string = 'c735b8b8-4d1e-4c96-8320-b3e663d7222d';
  /// <summary>Where NGX keeps its logs and data; '' = %LOCALAPPDATA%\FastCanvas\NGX (the folder of the EXE may not be
  /// writable).</summary>
  FastDlssDataPath: string = '';
  /// <summary>Diagnostics: Off renders without the subpixel jitter; NegateX, NegateY, NegateXY send DLSS the jitter
  /// with these components negated (the projection keeps it as it is). The variant whose edges stand still on a still
  /// scene tells the convention DLSS expects. Read at every frame.</summary>
  FastDlssJitterTest: TFastDlssJitterTest = TFastDlssJitterTest.Normal;

function DlssModeName(const AMode: TFastDlssMode): string;

implementation

uses
  Winapi.Windows, System.Win.Registry, System.IOUtils, System.Math, FastCanvas.Device;

type
  TInit = function(ProjectId: PAnsiChar; EngineType: Integer; EngineVersion: PAnsiChar;
    DataPath: PWideChar; Device: Pointer; SdkVersion: Cardinal; FeatureInfo: Pointer): Cardinal; cdecl;
  TParameters = function(out Parameters: Pointer): Cardinal; cdecl;
  TDestroyParameters = function(Parameters: Pointer): Cardinal; cdecl;
  TCreateFeature = function(List: Pointer; Feature: Integer; Parameters: Pointer; out Handle: Pointer): Cardinal; cdecl;
  TEvaluateFeature = function(List, Handle, Parameters, Callback: Pointer): Cardinal; cdecl;
  TReleaseFeature = function(Handle: Pointer): Cardinal; cdecl;
  TShutdown = function(Device: Pointer): Cardinal; cdecl;
  TSetUInt = procedure(Parameters: Pointer; Name: PAnsiChar; Value: Cardinal); cdecl;
  TSetInt = procedure(Parameters: Pointer; Name: PAnsiChar; Value: Integer); cdecl;
  TSetFloat = procedure(Parameters: Pointer; Name: PAnsiChar; Value: Single); cdecl;
  TSetResource = procedure(Parameters: Pointer; Name: PAnsiChar; Value: Pointer); cdecl;
  TGetInt = function(Parameters: Pointer; Name: PAnsiChar; out Value: Integer): Cardinal; cdecl;
  TGetUInt = function(Parameters: Pointer; Name: PAnsiChar; out Value: Cardinal): Cardinal; cdecl;
  TGetPointer = function(Parameters: Pointer; Name: PAnsiChar; out Value: Pointer): Cardinal; cdecl;
  TOptimalSettings = function(Parameters: Pointer): Cardinal; cdecl;

const
  NgxSuccess = 1;
  NgxSdkVersion = $15;
  NvidiaVendorId = $10DE;
  LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR = $100;
  LOAD_LIBRARY_SEARCH_DEFAULT_DIRS = $1000;
  PerfQuality: array[TFastDlssMode] of Integer = (2, 2, 1, 0, 3, 5);

var
  /// <summary>The driver's NGX Core, loaded once for the process (as NVIDIA's loader does).</summary>
  NgxCoreModule: HMODULE;
  /// <summary>The session of the current device (Acquire).</summary>
  GShared: IInterface;
  /// <summary>Guards the NGX parameter block and the errors of the features.</summary>
  GLock: TObject;

function DlssModeName(const AMode: TFastDlssMode): string;
const
  Names: array[TFastDlssMode] of string = ('Off', 'Quality', 'Balanced', 'Performance', 'Ultra Performance', 'DLAA');
begin
  Result := Names[AMode];
end;

function NgxCorePath: string;
const
  Keys: array[0..2] of string = (
    'SYSTEM\CurrentControlSet\Services\nvlddmkm\Parameters\NGXCore',
    'SYSTEM\CurrentControlSet\Services\nvlddmkm\NGXCore',
    'SOFTWARE\NVIDIA Corporation\Global\NGXCore');
var
  R: TRegistry;
  I: Integer;
  Dir, Name: string;
begin
  Result := '';
  R := TRegistry.Create(KEY_READ or KEY_WOW64_64KEY);
  try
    R.RootKey := HKEY_LOCAL_MACHINE;
    for I := 0 to High(Keys) do
      if R.OpenKeyReadOnly(Keys[I]) then
      begin
        if I = 2 then
          Name := 'FullPath'
        else
          Name := 'NGXPath';
        if R.ValueExists(Name) then
        begin
          Dir := R.ReadString(Name);
          if FileExists(TPath.Combine(Dir, '_nvngx.dll')) then
            Exit(TPath.Combine(Dir, '_nvngx.dll'));
          if FileExists(TPath.Combine(Dir, 'nvngx.dll')) then
            Exit(TPath.Combine(Dir, 'nvngx.dll'));
        end;
        R.CloseKey;
      end;
  finally
    R.Free;
  end;
end;

/// <summary>FastDlssDataPath, made if missing; else the temporary folder.</summary>
function NgxDataPath: string;
begin
  Result := FastDlssDataPath;
  if Result = '' then
    Result := TPath.Combine(GetEnvironmentVariable('LOCALAPPDATA'), 'FastCanvas\NGX');
  if (Result = '') or not ForceDirectories(Result) then
    Result := TPath.Combine(TPath.GetTempPath, 'FastCanvas\NGX');
  ForceDirectories(Result);
end;

{ TFastDlss }

class function TFastDlss.Acquire(const ADevice: ID3D12Device): TFastDlss;
begin
  if (GShared = nil) or (TFastDlss(GShared as TObject).FDevice <> ADevice) then
    // A new device: the old session goes when its features do.
    GShared := TFastDlss.Create(ADevice);
  Result := TFastDlss(GShared as TObject);
end;

class procedure TFastDlss.Lock;
begin
  TMonitor.Enter(GLock);
end;

class procedure TFastDlss.Unlock;
begin
  TMonitor.Exit(GLock);
end;

constructor TFastDlss.Create(const ADevice: ID3D12Device);
begin
  inherited Create;
  FDevice := ADevice;
  Initialize;
end;

destructor TFastDlss.Destroy;
begin
  if (FParameters <> nil) and (FDestroy <> nil) then
    TDestroyParameters(FDestroy)(FParameters);
  if FInitialized then
    TShutdown(FShutdown)(Pointer(FDevice));
  FDevice := nil;
  inherited;
end;

function TFastDlss.Slot(const AIndex: Integer): Pointer;
begin
  // NVSDK_NGX_Parameter is a C++ class: MSVC puts each group of virtual overloads in reverse order, Set(void*) is
  // slot 0, Get(void**) slot 8.
  Result := PPointer(PByte(PPointer(FParameters)^) + AIndex * SizeOf(Pointer))^;
end;

procedure TFastDlss.SetUInt(const AName: PAnsiChar; const AValue: Cardinal);
begin
  TSetUInt(Slot(4))(FParameters, AName, AValue);
end;

procedure TFastDlss.SetInt(const AName: PAnsiChar; const AValue: Integer);
begin
  TSetInt(Slot(3))(FParameters, AName, AValue);
end;

procedure TFastDlss.SetFloat(const AName: PAnsiChar; const AValue: Single);
begin
  TSetFloat(Slot(6))(FParameters, AName, AValue);
end;

procedure TFastDlss.SetResource(const AName: PAnsiChar; const AValue: ID3D12Resource);
begin
  TSetResource(Slot(1))(FParameters, AName, Pointer(AValue));
end;

function TFastDlss.GetInt(const AName: PAnsiChar; out AValue: Integer): Cardinal;
begin
  Result := TGetInt(Slot(11))(FParameters, AName, AValue);
end;

function TFastDlss.GetUInt(const AName: PAnsiChar; out AValue: Cardinal): Cardinal;
begin
  Result := TGetUInt(Slot(12))(FParameters, AName, AValue);
end;

function TFastDlss.GetPointer(const AName: PAnsiChar; out AValue: Pointer): Cardinal;
begin
  Result := TGetPointer(Slot(8))(FParameters, AName, AValue);
end;

procedure TFastDlss.Initialize;
var
  Core, DataPath: string;
  Project: AnsiString;
  Supported: Integer;
  Res: Cardinal;
begin
{$IFNDEF WIN64}
  FError := 'DLSS needs a Win64 program';
  Exit;
{$ENDIF}
  if FDevice = nil then
  begin
    FError := 'DLSS needs Direct3D 12';
    Exit;
  end;
  if TFastDevice.AdapterVendorId <> NvidiaVendorId then
  begin
    FError := 'DLSS needs an NVIDIA RTX graphics card';
    Exit;
  end;
  Core := NgxCorePath;
  if Core = '' then
  begin
    FError := 'The NVIDIA driver has no NGX (update the driver)';
    Exit;
  end;
  if not FileExists(TPath.Combine(ExtractFilePath(ParamStr(0)), 'nvngx_dlss.dll')) then
  begin
    FError := 'nvngx_dlss.dll is missing next to the program';
    Exit;
  end;
  if NgxCoreModule = 0 then
    NgxCoreModule := LoadLibraryEx(PChar(Core), 0, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR or
      LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
  if NgxCoreModule = 0 then
  begin
    FError := 'Cannot load the NVIDIA NGX driver runtime';
    Exit;
  end;
  FInit := GetProcAddress(NgxCoreModule, 'NVSDK_NGX_D3D12_Init_ProjectID');
  FCapabilities := GetProcAddress(NgxCoreModule, 'NVSDK_NGX_D3D12_GetCapabilityParameters');
  FDestroy := GetProcAddress(NgxCoreModule, 'NVSDK_NGX_D3D12_DestroyParameters');
  FCreate := GetProcAddress(NgxCoreModule, 'NVSDK_NGX_D3D12_CreateFeature');
  FEvaluate := GetProcAddress(NgxCoreModule, 'NVSDK_NGX_D3D12_EvaluateFeature');
  FRelease := GetProcAddress(NgxCoreModule, 'NVSDK_NGX_D3D12_ReleaseFeature');
  FShutdown := GetProcAddress(NgxCoreModule, 'NVSDK_NGX_D3D12_Shutdown1');
  if (FInit = nil) or (FCapabilities = nil) or (FDestroy = nil) or (FCreate = nil) or (FEvaluate = nil) or
    (FRelease = nil) or (FShutdown = nil) then
  begin
    FError := 'The NVIDIA NGX driver API is incomplete';
    Exit;
  end;
  DataPath := NgxDataPath;
  Project := AnsiString(FastDlssProjectId);
  Res := TInit(FInit)(PAnsiChar(Project), 0, 'FastCanvas 1.0', PWideChar(DataPath), Pointer(FDevice), NgxSdkVersion,
    nil);
  if Res and $FFF00000 = $BAD00000 then
  begin
    FError := Format('Initialize DLSS: NGX 0x%.8x', [Res]);
    Exit;
  end;
  FInitialized := True;
  Res := TParameters(FCapabilities)(FParameters);
  if Res and $FFF00000 = $BAD00000 then
  begin
    FError := Format('Query DLSS support: NGX 0x%.8x', [Res]);
    Exit;
  end;
  Supported := 0;
  if (GetInt('SuperSampling.Available', Supported) <> NgxSuccess) or (Supported = 0) then
  begin
    FError := 'DLSS Super Resolution is not available on this graphics card or driver';
    Exit;
  end;
  FAvailable := True;
end;

function TFastDlss.RenderSize(const AOutput: TSize; const AMode: TFastDlssMode): TSize;
const
  Ratios: array[TFastDlssMode] of Single = (1, 2 / 3, 0.58, 0.5, 1 / 3, 1);
var
  Callback: Pointer;
  W, H: Cardinal;
begin
  Result := TSize.Create(Max(1, Round(AOutput.Width * Ratios[AMode])), Max(1, Round(AOutput.Height * Ratios[AMode])));
  if not FAvailable or (AMode = TFastDlssMode.Off) then
    Exit(AOutput);
  TMonitor.Enter(GLock);
  try
    Callback := nil;
    if (GetPointer('DLSSOptimalSettingsCallback', Callback) = NgxSuccess) and (Callback <> nil) then
    begin
      SetUInt('Width', AOutput.Width);
      SetUInt('Height', AOutput.Height);
      SetInt('PerfQualityValue', PerfQuality[AMode]);
      if (TOptimalSettings(Callback)(FParameters) = NgxSuccess) and (GetUInt('OutWidth', W) = NgxSuccess) and
        (GetUInt('OutHeight', H) = NgxSuccess) and (W > 0) and (H > 0) then
        Result := TSize.Create(W, H);
    end;
  finally
    TMonitor.Exit(GLock);
  end;
end;

{ TFastDlssFeature }

constructor TFastDlssFeature.Create(const ASession: TFastDlss);
begin
  inherited Create;
  FSession := ASession;
  FSessionRef := ASession;
end;

destructor TFastDlssFeature.Destroy;
begin
  Release;
  FSessionRef := nil;
  inherited;
end;

function TFastDlssFeature.Check(const AResult: Cardinal; const AOperation: string): Boolean;
begin
  Result := AResult and $FFF00000 <> $BAD00000;
  if not Result then
    FError := Format('%s: NGX 0x%.8x', [AOperation, AResult]);
end;

procedure TFastDlssFeature.Release;
begin
  if FHandle <> nil then
  begin
    TReleaseFeature(FSession.FRelease)(FHandle);
    FHandle := nil;
  end;
end;

function TFastDlssFeature.Configure(const AList: ID3D12GraphicsCommandList; const AInput, AOutput: TSize;
  const AMode: TFastDlssMode; const AHdr: Boolean): Boolean;
var
  Flags: Integer;
  S: TFastDlss;
begin
  Result := False;
  S := FSession;
  if not S.FAvailable or (AMode = TFastDlssMode.Off) then
    Exit;
  if (FHandle <> nil) and (FInput = AInput) and (FOutput = AOutput) and (FMode = AMode) and (FHdr = AHdr) then
    Exit(True);
  TMonitor.Enter(GLock);
  try
    Release;
    S.SetUInt('Width', AInput.Width);
    S.SetUInt('Height', AInput.Height);
    S.SetUInt('OutWidth', AOutput.Width);
    S.SetUInt('OutHeight', AOutput.Height);
    S.SetInt('PerfQualityValue', PerfQuality[AMode]);
    // Motion vectors at the render size, without the jitter; auto exposure.
    Flags := 2 or 64;
    if AHdr then
      Flags := Flags or 1;
    S.SetInt('DLSS.Feature.Create.Flags', Flags);
    S.SetInt('DLSS.Enable.Output.Subrects', 0);
    S.SetUInt('CreationNodeMask', 1);
    S.SetUInt('VisibilityNodeMask', 1);
    Result := Check(TCreateFeature(S.FCreate)(Pointer(AList), 1, S.FParameters, FHandle), 'Create DLSS SR');
    if Result then
    begin
      FInput := AInput;
      FOutput := AOutput;
      FMode := AMode;
      FHdr := AHdr;
      FError := '';
    end;
  finally
    TMonitor.Exit(GLock);
  end;
end;

function TFastDlssFeature.Evaluate(const AList: ID3D12GraphicsCommandList;
  const AColor, ADepth, AMotion, AOutput: ID3D12Resource; const AJitter: TPointF; const AReset: Boolean;
  const AFrameTimeMs: Single): Boolean;
var
  S: TFastDlss;
begin
  Result := False;
  if FHandle = nil then
    Exit;
  S := FSession;
  TMonitor.Enter(GLock);
  try
    S.SetResource('Color', AColor);
    S.SetResource('Depth', ADepth);
    S.SetResource('MotionVectors', AMotion);
    S.SetResource('Output', AOutput);
    S.SetFloat('Jitter.Offset.X', AJitter.X);
    S.SetFloat('Jitter.Offset.Y', AJitter.Y);
    S.SetFloat('MV.Scale.X', 1);
    S.SetFloat('MV.Scale.Y', 1);
    S.SetFloat('DLSS.Pre.Exposure', 1);
    S.SetFloat('DLSS.Exposure.Scale', 1);
    S.SetFloat('FrameTimeDeltaInMsec', AFrameTimeMs);
    S.SetInt('Reset', Ord(AReset));
    S.SetUInt('DLSS.Render.Subrect.Dimensions.Width', FInput.Width);
    S.SetUInt('DLSS.Render.Subrect.Dimensions.Height', FInput.Height);
    Result := Check(TEvaluateFeature(S.FEvaluate)(Pointer(AList), FHandle, S.FParameters, nil), 'Evaluate DLSS SR');
  finally
    TMonitor.Exit(GLock);
  end;
  if Result then
    AtomicIncrement(FFrames);
end;

function TFastDlssFeature.Error: string;
begin
  TMonitor.Enter(GLock);
  try
    Result := FError;
  finally
    TMonitor.Exit(GLock);
  end;
end;

function TFastDlssFeature.Frames: Int64;
begin
  Result := AtomicCmpExchange(FFrames, 0, 0);
end;

initialization
  GLock := TObject.Create;
finalization
  // A session still held by a feature goes with it (FMX frees the last forms after the unit finalizations).
  GShared := nil;
  FreeAndNil(GLock);
end.
