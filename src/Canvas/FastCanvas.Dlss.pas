unit FastCanvas.Dlss;

{ Native NVIDIA DLSS Super Resolution through the driver NGX Core. The declarations follow NVIDIA's
  nvsdk_ngx.h / nvsdk_ngx_params.h. No C++ wrapper or static NGX library is linked. Win64 only.
  GPU work, feature creation and release belong to the render thread; the caller waits for the GPU before release. }

interface

uses
  System.SysUtils, System.Types, DX12.D3D12;

type
  TFastDlssMode = (Off, Quality, Balanced, Performance, UltraPerformance, DLAA);

  TFastDlss = class(TInterfacedObject)
  private
    FDevice: ID3D12Device;
    FModule: NativeUInt;
    FParameters, FFeature: Pointer;
    FInitialized, FAvailable: Boolean;
    FError: string;
    FInput, FOutput: TSize;
    FMode: TFastDlssMode;
    FHdr: Boolean;
    FFrames: Int64;
    FInit, FAllocate, FCapabilities, FDestroy, FCreate, FEvaluate, FRelease, FShutdown: Pointer;
    function Slot(const AIndex: Integer): Pointer;
    procedure SetUInt(const AName: PAnsiChar; const AValue: Cardinal);
    procedure SetInt(const AName: PAnsiChar; const AValue: Integer);
    procedure SetFloat(const AName: PAnsiChar; const AValue: Single);
    procedure SetResource(const AName: PAnsiChar; const AValue: ID3D12Resource);
    function GetInt(const AName: PAnsiChar; out AValue: Integer): Cardinal;
    function GetUInt(const AName: PAnsiChar; out AValue: Cardinal): Cardinal;
    function GetPointer(const AName: PAnsiChar; out AValue: Pointer): Cardinal;
    function Check(const AResult: Cardinal; const AOperation: string): Boolean;
    procedure Initialize;
  public
    constructor Create(const ADevice: ID3D12Device);
    destructor Destroy; override;
    function RenderSize(const AOutput: TSize; const AMode: TFastDlssMode): TSize;
    function Configure(const AList: ID3D12GraphicsCommandList; const AInput, AOutput: TSize;
      const AMode: TFastDlssMode; const AHdr: Boolean): Boolean;
    function Evaluate(const AList: ID3D12GraphicsCommandList;
      const AColor, ADepth, AMotion, AOutput: ID3D12Resource; const AJitter: TPointF;
      const AReset: Boolean; const AFrameTimeMs: Single): Boolean;
    procedure ReleaseFeature;
    property Available: Boolean read FAvailable;
    property Error: string read FError;
    property Frames: Int64 read FFrames;
  end;

function DlssModeName(const AMode: TFastDlssMode): string;

implementation

uses
  Winapi.Windows, System.Win.Registry, System.IOUtils, System.Math;

type
  TInit = function(ProjectId: PAnsiChar; EngineType: Integer; EngineVersion: PAnsiChar;
    DataPath: PWideChar; Device: Pointer; SdkVersion: Cardinal; FeatureInfo: Pointer): Cardinal; cdecl;
  TParameters = function(out Parameters: Pointer): Cardinal; cdecl;
  TDestroyParameters = function(Parameters: Pointer): Cardinal; cdecl;
  TCreateFeature = function(List: Pointer; Feature: Integer; Parameters: Pointer; out Handle: Pointer): Cardinal; cdecl;
  TEvaluateFeature = function(List, Handle, Parameters, Callback: Pointer): Cardinal; cdecl;
  TReleaseFeature = function(Handle: Pointer): Cardinal; cdecl;
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
  NgxProject: PAnsiChar = 'c735b8b8-4d1e-4c96-8320-b3e663d7222d';
  PerfQuality: array[TFastDlssMode] of Integer = (2, 2, 1, 0, 3, 5);

function DlssModeName(const AMode: TFastDlssMode): string;
const Names: array[TFastDlssMode] of string = ('Off', 'Quality', 'Balanced', 'Performance', 'Ultra Performance', 'DLAA');
begin
  Result := Names[AMode];
end;

var NgxCoreModule: HMODULE;

function NgxCorePath: string;
const
  Keys: array[0..2] of string = (
    'SYSTEM\CurrentControlSet\Services\nvlddmkm\Parameters\NGXCore',
    'SYSTEM\CurrentControlSet\Services\nvlddmkm\NGXCore',
    'SOFTWARE\NVIDIA Corporation\Global\NGXCore');
var R: TRegistry; I: Integer; Dir, Name: string;
begin
  Result := '';
  R := TRegistry.Create(KEY_READ or KEY_WOW64_64KEY);
  try
    R.RootKey := HKEY_LOCAL_MACHINE;
    for I := 0 to High(Keys) do
      if R.OpenKeyReadOnly(Keys[I]) then
      begin
        if I = 2 then Name := 'FullPath' else Name := 'NGXPath';
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

constructor TFastDlss.Create(const ADevice: ID3D12Device);
begin
  inherited Create;
  FDevice := ADevice;
  Initialize;
end;

function TFastDlss.Check(const AResult: Cardinal; const AOperation: string): Boolean;
begin
  Result := (AResult and $FFF00000) <> $BAD00000;
  if not Result then FError := Format('%s: NGX 0x%.8x', [AOperation, AResult]);
end;

function TFastDlss.Slot(const AIndex: Integer): Pointer;
begin
  // MSVC groups virtual overloads in reverse order: Set(void*) is slot 0, Get(void**) slot 8.
  Result := PPointer(PByte(PPointer(FParameters)^) + AIndex * SizeOf(Pointer))^;
end;

procedure TFastDlss.SetUInt(const AName: PAnsiChar; const AValue: Cardinal);
begin TSetUInt(Slot(4))(FParameters, AName, AValue); end;
procedure TFastDlss.SetInt(const AName: PAnsiChar; const AValue: Integer);
begin TSetInt(Slot(3))(FParameters, AName, AValue); end;
procedure TFastDlss.SetFloat(const AName: PAnsiChar; const AValue: Single);
begin TSetFloat(Slot(6))(FParameters, AName, AValue); end;
procedure TFastDlss.SetResource(const AName: PAnsiChar; const AValue: ID3D12Resource);
begin TSetResource(Slot(1))(FParameters, AName, Pointer(AValue)); end;
function TFastDlss.GetInt(const AName: PAnsiChar; out AValue: Integer): Cardinal;
begin Result := TGetInt(Slot(11))(FParameters, AName, AValue); end;
function TFastDlss.GetUInt(const AName: PAnsiChar; out AValue: Cardinal): Cardinal;
begin Result := TGetUInt(Slot(12))(FParameters, AName, AValue); end;
function TFastDlss.GetPointer(const AName: PAnsiChar; out AValue: Pointer): Cardinal;
begin Result := TGetPointer(Slot(8))(FParameters, AName, AValue); end;

procedure TFastDlss.Initialize;
var Core, DataPath: string; Supported: Integer;
begin
{$IFNDEF WIN64}
  FError := 'DLSS requires Win64';
  Exit;
{$ENDIF}
  if FDevice = nil then begin FError := 'DLSS requires Direct3D 12'; Exit; end;
  if not FileExists(TPath.Combine(ExtractFilePath(ParamStr(0)), 'nvngx_dlss.dll')) then
  begin FError := 'nvngx_dlss.dll is missing next to the EXE'; Exit; end;
  Core := NgxCorePath;
  if Core = '' then begin FError := 'NVIDIA NGX driver runtime is unavailable'; Exit; end;
  if NgxCoreModule = 0 then
    NgxCoreModule := LoadLibraryEx(PChar(Core), 0, $100 or $1000);
  FModule := NgxCoreModule;
  if FModule = 0 then begin FError := 'Cannot load NVIDIA NGX driver runtime'; Exit; end;
  FInit := GetProcAddress(FModule, 'NVSDK_NGX_D3D12_Init_ProjectID');
  FAllocate := GetProcAddress(FModule, 'NVSDK_NGX_D3D12_AllocateParameters');
  FCapabilities := GetProcAddress(FModule, 'NVSDK_NGX_D3D12_GetCapabilityParameters');
  FDestroy := GetProcAddress(FModule, 'NVSDK_NGX_D3D12_DestroyParameters');
  FCreate := GetProcAddress(FModule, 'NVSDK_NGX_D3D12_CreateFeature');
  FEvaluate := GetProcAddress(FModule, 'NVSDK_NGX_D3D12_EvaluateFeature');
  FRelease := GetProcAddress(FModule, 'NVSDK_NGX_D3D12_ReleaseFeature');
  FShutdown := GetProcAddress(FModule, 'NVSDK_NGX_D3D12_Shutdown1');
  if (FInit = nil) or (FAllocate = nil) or (FCapabilities = nil) or (FDestroy = nil) or (FCreate = nil) or
    (FEvaluate = nil) or (FRelease = nil) or (FShutdown = nil) then
  begin FError := 'The NVIDIA NGX driver API is incomplete'; Exit; end;
  DataPath := TPath.Combine(ExtractFilePath(ParamStr(0)), 'ngx');
  ForceDirectories(DataPath);
  if not Check(TInit(FInit)(NgxProject, 0, 'FastCanvas 1.0', PWideChar(DataPath), Pointer(FDevice), NgxSdkVersion, nil), 'Initialize DLSS') then Exit;
  FInitialized := True;
  if not Check(TParameters(FCapabilities)(FParameters), 'Query DLSS support') then Exit;
  Supported := 0;
  if not Check(GetInt('SuperSampling.Available', Supported), 'Query DLSS capability') or (Supported = 0) then
  begin
    if FError = '' then FError := 'DLSS Super Resolution is unavailable (check NVIDIA GPU, driver and nvngx_dlss.dll)';
    Exit;
  end;
  FAvailable := True;
end;

destructor TFastDlss.Destroy;
var DevicesLeft: Cardinal;
begin
  ReleaseFeature;
  if (FParameters <> nil) and (FDestroy <> nil) then TDestroyParameters(FDestroy)(FParameters);
  if FInitialized then TShutdown(FShutdown)(Pointer(FDevice), DevicesLeft);
  FDevice := nil;
  // NGX Core follows the process lifetime, as in NVIDIA's header-only loader.
  inherited;
end;

procedure TFastDlss.ReleaseFeature;
begin
  if FFeature <> nil then
  begin
    TReleaseFeature(FRelease)(FFeature);
    FFeature := nil;
  end;
end;

function TFastDlss.RenderSize(const AOutput: TSize; const AMode: TFastDlssMode): TSize;
const Ratios: array[TFastDlssMode] of Single = (1, 2 / 3, 0.58, 0.5, 1 / 3, 1);
var Callback: Pointer; W, H: Cardinal;
begin
  Result := TSize.Create(Max(1, Round(AOutput.Width * Ratios[AMode])), Max(1, Round(AOutput.Height * Ratios[AMode])));
  if not FAvailable or (AMode = TFastDlssMode.Off) then Exit(AOutput);
  Callback := nil;
  if GetPointer('DLSSOptimalSettingsCallback', Callback) = NgxSuccess then
    if Callback <> nil then
    begin
      SetUInt('Width', AOutput.Width); SetUInt('Height', AOutput.Height);
      SetInt('PerfQualityValue', PerfQuality[AMode]);
      if TOptimalSettings(Callback)(FParameters) = NgxSuccess then
        if (GetUInt('OutWidth', W) = NgxSuccess) and (GetUInt('OutHeight', H) = NgxSuccess) and (W > 0) and (H > 0) then
          Result := TSize.Create(W, H);
    end;
end;

function TFastDlss.Configure(const AList: ID3D12GraphicsCommandList; const AInput, AOutput: TSize;
  const AMode: TFastDlssMode; const AHdr: Boolean): Boolean;
var Flags: Integer;
begin
  Result := False;
  if not FAvailable or (AMode = TFastDlssMode.Off) then Exit;
  if (FFeature <> nil) and (FInput = AInput) and (FOutput = AOutput) and (FMode = AMode) and (FHdr = AHdr) then Exit(True);
  // The renderer waits for earlier evaluations before changing feature dimensions or mode.
  ReleaseFeature;
  SetUInt('Width', AInput.Width); SetUInt('Height', AInput.Height);
  SetUInt('OutWidth', AOutput.Width); SetUInt('OutHeight', AOutput.Height);
  SetInt('PerfQualityValue', PerfQuality[AMode]);
  Flags := 2 or 64; // low-resolution, unjittered motion vectors; auto exposure
  if AHdr then Flags := Flags or 1;
  SetInt('DLSS.Feature.Create.Flags', Flags);
  SetInt('DLSS.Enable.Output.Subrects', 0);
  SetUInt('CreationNodeMask', 1); SetUInt('VisibilityNodeMask', 1);
  Result := Check(TCreateFeature(FCreate)(Pointer(AList), 1, FParameters, FFeature), 'Create DLSS SR');
  if Result then begin FInput := AInput; FOutput := AOutput; FMode := AMode; FHdr := AHdr; FError := ''; end;
end;

function TFastDlss.Evaluate(const AList: ID3D12GraphicsCommandList;
  const AColor, ADepth, AMotion, AOutput: ID3D12Resource; const AJitter: TPointF;
  const AReset: Boolean; const AFrameTimeMs: Single): Boolean;
begin
  Result := False;
  if FFeature = nil then Exit;
  SetResource('Color', AColor); SetResource('Depth', ADepth);
  SetResource('MotionVectors', AMotion); SetResource('Output', AOutput);
  SetFloat('Jitter.Offset.X', AJitter.X); SetFloat('Jitter.Offset.Y', AJitter.Y);
  SetFloat('MV.Scale.X', 1); SetFloat('MV.Scale.Y', 1);
  SetFloat('DLSS.Pre.Exposure', 1); SetFloat('DLSS.Exposure.Scale', 1);
  SetFloat('FrameTimeDeltaInMsec', AFrameTimeMs);
  SetInt('Reset', Ord(AReset));
  SetUInt('DLSS.Render.Subrect.Dimensions.Width', FInput.Width);
  SetUInt('DLSS.Render.Subrect.Dimensions.Height', FInput.Height);
  Result := Check(TEvaluateFeature(FEvaluate)(Pointer(AList), FFeature, FParameters, nil), 'Evaluate DLSS SR');
  if Result then Inc(FFrames);
end;

end.
