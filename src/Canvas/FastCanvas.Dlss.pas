unit FastCanvas.Dlss;

{ Native NVIDIA DLSS Super Resolution through the driver's NGX Core. The declarations follow NVIDIA's nvsdk_ngx.h and
  nvsdk_ngx_params.h (NVIDIA RTX SDK, see THIRD_PARTY_NOTICES.md). No C++ wrapper or static NGX library is linked;
  nvngx_dlss.dll of the DLSS SDK goes next to the EXE. Win64 only. Originally written by Hemul GM
  (https://github.com/HemulGM).

  One NGX session per device for the process (TFastDlss.Acquire, main thread): initialized when a 3D context first
  uses DLSS, shut down when its last user (the DLSS state of a 3D context) goes, with its window; a new device gets a
  session of its own, so the shutdown of the old one never touches it. Nothing is left for the unit finalization: FMX
  frees the forms before it (DoneApplication), and NGX must not be shut down there. A TFastDlssFeature per 3D context: created and evaluated by the render thread, released when the
  GPU is done with it. The NGX parameter block is shared: every use holds the lock of the unit. }

interface

uses
  System.SysUtils, System.Types, DX12.D3D12;

type
  {$SCOPEDENUMS ON}
  TFastDlssMode = (Off, Quality, Balanced, Performance, UltraPerformance, DLAA);
  /// <summary>Diagnostics of the jitter (FastDlssJitterTest).</summary>
  TFastDlssJitterTest = (Normal, Off, NegateX, NegateY, NegateXY);
  /// <summary>Diagnostics: what a window with DLSS shows (FastDlssView).</summary>
  TFastDlssView = (Output, Input, Motion);
  /// <summary>Diagnostics without NGX (FastDlssEmulate).</summary>
  TFastDlssEmulation = (Off, Temporal, Accumulate);
  /// <summary>NVIDIA's DLSS models (render presets, FastDlssPreset). Default: model M for Quality and Balanced (NVIDIA's
  /// default there, K, left a speckled halo around a bright object moving over a dark background on an RTX 3090; M did
  /// not), NVIDIA's choice for the other modes; Nvidia: NVIDIA's choice for every mode.</summary>
  TFastDlssPreset = (Default, Nvidia, J, K, L, M);
  {$SCOPEDENUMS OFF}

  /// <summary>The NGX session of a device, reference counted: held by the DLSS states of the 3D contexts and by the
  /// features made on it (the unit keeps a weak reference for Acquire).</summary>
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
    FHdr, FAutoExposure: Boolean;
    FPreset: TFastDlssPreset;
    FFrames: Int64;
    FError: string;
    function Check(const AResult: Cardinal; const AOperation: string): Boolean;
  public
    constructor Create(const ASession: TFastDlss);
    destructor Destroy; override;
    /// <summary>The feature for these sizes, mode and settings, made again when they changed (the context waited for
    /// the GPU before it changed them). AAutoExposure: DLSS measures the exposure (else Evaluate gets an exposure
    /// texture); APreset: the model of the mode.</summary>
    function Configure(const AList: ID3D12GraphicsCommandList; const AInput, AOutput: TSize;
      const AMode: TFastDlssMode; const AHdr, AAutoExposure: Boolean; const APreset: TFastDlssPreset): Boolean;
    /// <summary>AExposure: a 1x1 texture of the exposure without auto exposure, nil with it.</summary>
    function Evaluate(const AList: ID3D12GraphicsCommandList;
      const AColor, ADepth, AMotion, AOutput, AExposure: ID3D12Resource; const AJitter: TPointF;
      const AReset: Boolean; const AFrameTimeMs: Single): Boolean;
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
  /// <summary>Diagnostics: Input shows the scene DLSS gets (render size, jittered), Motion its motion vectors (grey:
  /// still; red and green: towards the previous position, 0.1 per pixel). Read at every frame.</summary>
  FastDlssView: TFastDlssView = TFastDlssView.Output;
  /// <summary>Diagnostics on any graphics card with Direct3D 12: the whole DLSS phase runs (the render size of the
  /// mode, the jitter, the motion vectors, the depth) and a simple shader stands in for NGX. Temporal: the frames
  /// accumulate along the motion vectors, the history clamped to the colors around each pixel (as temporal
  /// antialiasing does); Accumulate: unclamped, each pixel along its own vector, the history dropped only where the
  /// frame before had other surfaces (so edges show the current frame alone), so that wrong motion vectors leave
  /// trails. Window contexts with a depth buffer report DLSS as available and do not start NGX. Read when the context
  /// makes its buffers (a change applies at its next scene).</summary>
  FastDlssEmulate: TFastDlssEmulation = TFastDlssEmulation.Off;
  /// <summary>The motion of the pixels no object pass wrote (the background, objects without depth write): the
  /// camera's, reprojected from the depth (the background as seen at infinity). DLSS needs vectors for every pixel;
  /// False leaves them zero there (diagnostics: only the objects' own vectors). Read at every frame.</summary>
  FastDlssCameraMotion: Boolean = True;
  /// <summary>The DLSS model of every mode (DLSS.Hint.Render.Preset.*). Read when the feature is made.</summary>
  FastDlssPreset: TFastDlssPreset = TFastDlssPreset.Default;
  /// <summary>True: DLSS measures the exposure itself (its AutoExposure flag). False: a fixed exposure of 1 (a 1x1
  /// exposure texture; the colors are already exposed for the display). Read when the feature is made.</summary>
  FastDlssAutoExposure: Boolean = True;
  /// <summary>The motion pass rasterizes conservatively where the device can: thin features (a cone's tip at the
  /// render size of Performance and Ultra Performance) get their vectors in every pixel they touch, as NVIDIA's guide
  /// recommends (3.6.4). Read when the context makes its buffers.</summary>
  FastDlssConservativeMotion: Boolean = True;

function DlssModeName(const AMode: TFastDlssMode): string;
/// <summary>The render size of a mode by NVIDIA's usual ratios (the emulation; NGX's optimal settings with DLSS).
/// </summary>
function DlssRenderSize(const AOutput: TSize; const AMode: TFastDlssMode): TSize;

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
  // The export of the driver's NGX Core, not the function of nvsdk_ngx.h of that name (one parameter, in NVIDIA's
  // static library): it writes the number of devices left to the second parameter.
  TShutdown = function(Device: Pointer; out DevicesLeft: Cardinal): Cardinal; cdecl;
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
  // NVSDK_NGX_DLSS_Hint_Render_Preset of nvsdk_ngx_defs.h, and the parameters that take it.
  PresetValues: array[TFastDlssPreset] of Cardinal = (0, 0, 10, 11, 12, 13);
  PresetM = 13;
  PresetNames: array[0..4] of PAnsiChar = ('DLSS.Hint.Render.Preset.DLAA', 'DLSS.Hint.Render.Preset.Quality',
    'DLSS.Hint.Render.Preset.Balanced', 'DLSS.Hint.Render.Preset.Performance',
    'DLSS.Hint.Render.Preset.UltraPerformance');
  // NVSDK_NGX_DLSS_Feature_Flags.
  FlagIsHdr = 1;
  FlagMVLowRes = 2;
  FlagAutoExposure = 64;

var
  /// <summary>The driver's NGX Core, loaded once for the process (as NVIDIA's loader does).</summary>
  NgxCoreModule: HMODULE;
  /// <summary>The session of the current device (Acquire), weak: cleared by its destructor. Guarded by GLock.</summary>
  GShared: TFastDlss;
  /// <summary>Guards the NGX parameter block, the errors of the features and GShared. A critical section of the system,
  /// never deleted: 3D contexts may still use it after the unit finalization.</summary>
  GLock: TRTLCriticalSection;

function DlssModeName(const AMode: TFastDlssMode): string;
const
  Names: array[TFastDlssMode] of string = ('Off', 'Quality', 'Balanced', 'Performance', 'Ultra Performance', 'DLAA');
begin
  Result := Names[AMode];
end;

function DlssRenderSize(const AOutput: TSize; const AMode: TFastDlssMode): TSize;
const
  Ratios: array[TFastDlssMode] of Single = (1, 2 / 3, 0.58, 0.5, 1 / 3, 1);
begin
  Result := TSize.Create(Max(1, Round(AOutput.Width * Ratios[AMode])), Max(1, Round(AOutput.Height * Ratios[AMode])));
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
  // The caller takes a reference at once (a new session has none).
  EnterCriticalSection(GLock);
  try
    Result := GShared;
  finally
    LeaveCriticalSection(GLock);
  end;
  if (Result <> nil) and (Result.FDevice = ADevice) then
    Exit;
  // First use, or a new device: the old session goes when its users do.
  Result := TFastDlss.Create(ADevice);
  EnterCriticalSection(GLock);
  try
    GShared := Result;
  finally
    LeaveCriticalSection(GLock);
  end;
end;

class procedure TFastDlss.Lock;
begin
  EnterCriticalSection(GLock);
end;

class procedure TFastDlss.Unlock;
begin
  LeaveCriticalSection(GLock);
end;

constructor TFastDlss.Create(const ADevice: ID3D12Device);
begin
  inherited Create;
  FDevice := ADevice;
  Initialize;
end;

destructor TFastDlss.Destroy;
var
  DevicesLeft: Cardinal;
begin
  EnterCriticalSection(GLock);
  try
    if GShared = Self then
      GShared := nil;
  finally
    LeaveCriticalSection(GLock);
  end;
  if (FParameters <> nil) and (FDestroy <> nil) then
    TDestroyParameters(FDestroy)(FParameters);
  if FInitialized then
    TShutdown(FShutdown)(Pointer(FDevice), DevicesLeft);
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
var
  Callback: Pointer;
  W, H: Cardinal;
begin
  Result := DlssRenderSize(AOutput, AMode);
  if not FAvailable or (AMode = TFastDlssMode.Off) then
    Exit(AOutput);
  EnterCriticalSection(GLock);
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
    LeaveCriticalSection(GLock);
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
  const AMode: TFastDlssMode; const AHdr, AAutoExposure: Boolean; const APreset: TFastDlssPreset): Boolean;
var
  Flags: Integer;
  S: TFastDlss;
  I: Integer;
  Value: Cardinal;
begin
  Result := False;
  S := FSession;
  if not S.FAvailable or (AMode = TFastDlssMode.Off) then
    Exit;
  if (FHandle <> nil) and (FInput = AInput) and (FOutput = AOutput) and (FMode = AMode) and (FHdr = AHdr) and
    (FAutoExposure = AAutoExposure) and (FPreset = APreset) then
    Exit(True);
  EnterCriticalSection(GLock);
  try
    Release;
    S.SetUInt('Width', AInput.Width);
    S.SetUInt('Height', AInput.Height);
    S.SetUInt('OutWidth', AOutput.Width);
    S.SetUInt('OutHeight', AOutput.Height);
    S.SetInt('PerfQualityValue', PerfQuality[AMode]);
    // Motion vectors at the render size, without the jitter (MVJittered 0), depth with the near plane at 0
    // (DepthInverted 0).
    Flags := FlagMVLowRes;
    if AAutoExposure then
      Flags := Flags or FlagAutoExposure;
    if AHdr then
      Flags := Flags or FlagIsHdr;
    S.SetInt('DLSS.Feature.Create.Flags', Flags);
    S.SetInt('DLSS.Enable.Output.Subrects', 0);
    S.SetUInt('CreationNodeMask', 1);
    S.SetUInt('VisibilityNodeMask', 1);
    // The parameter block is shared: every hint is set (0: NVIDIA's default model of the mode).
    for I := Low(PresetNames) to High(PresetNames) do
    begin
      Value := PresetValues[APreset];
      // PresetNames 1 and 2: Quality and Balanced.
      if (APreset = TFastDlssPreset.Default) and (I in [1, 2]) then
        Value := PresetM;
      S.SetUInt(PresetNames[I], Value);
    end;
    Result := Check(TCreateFeature(S.FCreate)(Pointer(AList), 1, S.FParameters, FHandle), 'Create DLSS SR');
    if Result then
    begin
      FInput := AInput;
      FOutput := AOutput;
      FMode := AMode;
      FHdr := AHdr;
      FAutoExposure := AAutoExposure;
      FPreset := APreset;
      FError := '';
    end;
  finally
    LeaveCriticalSection(GLock);
  end;
end;

function TFastDlssFeature.Evaluate(const AList: ID3D12GraphicsCommandList;
  const AColor, ADepth, AMotion, AOutput, AExposure: ID3D12Resource; const AJitter: TPointF;
  const AReset: Boolean; const AFrameTimeMs: Single): Boolean;
var
  S: TFastDlss;
begin
  Result := False;
  if FHandle = nil then
    Exit;
  S := FSession;
  EnterCriticalSection(GLock);
  try
    S.SetResource('Color', AColor);
    S.SetResource('Depth', ADepth);
    S.SetResource('MotionVectors', AMotion);
    S.SetResource('Output', AOutput);
    S.SetResource('ExposureTexture', AExposure);
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
    LeaveCriticalSection(GLock);
  end;
  if Result then
    AtomicIncrement(FFrames);
end;

function TFastDlssFeature.Error: string;
begin
  EnterCriticalSection(GLock);
  try
    Result := FError;
  finally
    LeaveCriticalSection(GLock);
  end;
end;

function TFastDlssFeature.Frames: Int64;
begin
  Result := AtomicCmpExchange(FFrames, 0, 0);
end;

initialization
  InitializeCriticalSection(GLock);
end.
