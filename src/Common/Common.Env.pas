unit Common.Env;

{ Test bench environment: OS, CPU, GPU and driver, display, DPI, power plan, memory, build info. }

interface

uses
  Winapi.Windows, Common.Csv;

type
  TMemoryInfo = record
    WorkingSet: UInt64;
    PeakWorkingSet: UInt64;
    PrivateBytes: UInt64;
  end;

  TMonitorDesc = record
    Handle: HMONITOR;
    Device: string;
    Primary: Boolean;
    Bounds: TRect;
    WorkArea: TRect;
  end;

  TDisplayInfo = record
    Device: string;         // monitor the window is on, e.g. \\.\DISPLAY2
    Primary: Boolean;
    ModeHz: Integer;        // EnumDisplaySettings of the window's monitor
    DwmHz: Double;          // DwmGetCompositionTimingInfo refresh period
    Width, Height: Integer; // monitor resolution, physical pixels
    Dpi: Integer;           // window DPI
  end;

function GetMemoryInfo: TMemoryInfo;
function GetDisplayInfo(const AWnd: HWND): TDisplayInfo;

/// <summary>Monitors with the primary first, the others ordered by their left edge.</summary>
function EnumMonitors: TArray<TMonitorDesc>;
/// <summary>ASpec: primary, secondary, a 1-based index into EnumMonitors, or a device name
/// (DISPLAY3 or \\.\DISPLAY3).</summary>
function FindMonitor(const ASpec: string; out AMonitor: TMonitorDesc): Boolean;

/// <summary>Adds static environment columns (OS, CPU, GPU, power plan, build) to the row.</summary>
procedure AddEnvironmentColumns(const ARow: TCsvRow);

function BuildCommitText: string;

implementation

uses
  System.SysUtils, System.Generics.Collections, System.Generics.Defaults, System.Win.Registry,
  Winapi.DXGI, Winapi.Dwmapi, Winapi.MultiMon;

{$I BuildInfo.inc}

const
  ENUM_CURRENT_SETTINGS = DWORD(-1);

type
  TProcessMemoryCountersEx = record
    cb: DWORD;
    PageFaultCount: DWORD;
    PeakWorkingSetSize: SIZE_T;
    WorkingSetSize: SIZE_T;
    QuotaPeakPagedPoolUsage: SIZE_T;
    QuotaPagedPoolUsage: SIZE_T;
    QuotaPeakNonPagedPoolUsage: SIZE_T;
    QuotaNonPagedPoolUsage: SIZE_T;
    PagefileUsage: SIZE_T;
    PeakPagefileUsage: SIZE_T;
    PrivateUsage: SIZE_T;
  end;

function GetProcessMemoryInfoApi(Process: THandle; var Counters: TProcessMemoryCountersEx;
  cb: DWORD): BOOL; stdcall; external 'psapi.dll' name 'GetProcessMemoryInfo';
function GetDpiForWindowApi(Wnd: HWND): UINT; stdcall; external user32 name 'GetDpiForWindow';
function EnumDisplayMonitorsApi(DC: HDC; Clip: PRect; EnumProc: Pointer; Data: LPARAM): BOOL; stdcall;
  external user32 name 'EnumDisplayMonitors';
function PowerGetActiveScheme(UserRootPowerKey: HKEY; out ActivePolicyGuid: PGUID): DWORD; stdcall;
  external 'powrprof.dll';
function PowerReadFriendlyName(RootPowerKey: HKEY; SchemeGuid, SubGroupOfPowerSettingsGuid,
  PowerSettingGuid: PGUID; Buffer: PByte; var BufferSize: DWORD): DWORD; stdcall; external 'powrprof.dll';

function BuildCommitText: string;
begin
  Result := BuildCommit;
  if BuildDirty then
    Result := Result + '-dirty';
end;

function GetMemoryInfo: TMemoryInfo;
var
  C: TProcessMemoryCountersEx;
begin
  Result := Default(TMemoryInfo);
  FillChar(C, SizeOf(C), 0);
  C.cb := SizeOf(C);
  if GetProcessMemoryInfoApi(GetCurrentProcess, C, SizeOf(C)) then
  begin
    Result.WorkingSet := C.WorkingSetSize;
    Result.PeakWorkingSet := C.PeakWorkingSetSize;
    Result.PrivateBytes := C.PrivateUsage;
  end;
end;

function GetDisplayInfo(const AWnd: HWND): TDisplayInfo;
var
  Mon: HMONITOR;
  MI: TMonitorInfoEx;
  DM: TDeviceMode;
  Timing: TDwmTimingInfo;
  Freq: Int64;
begin
  Result := Default(TDisplayInfo);
  if AWnd <> 0 then
    Mon := MonitorFromWindow(AWnd, MONITOR_DEFAULTTOPRIMARY)
  else
    Mon := MonitorFromPoint(TPoint.Create(0, 0), MONITOR_DEFAULTTOPRIMARY);
  FillChar(MI, SizeOf(MI), 0);
  MI.cbSize := SizeOf(MI);
  if GetMonitorInfo(Mon, @MI) then
  begin
    Result.Device := string(PChar(@MI.szDevice[0]));
    Result.Primary := (MI.dwFlags and MONITORINFOF_PRIMARY) <> 0;
    FillChar(DM, SizeOf(DM), 0);
    DM.dmSize := SizeOf(DM);
    if EnumDisplaySettings(MI.szDevice, ENUM_CURRENT_SETTINGS, DM) then
    begin
      Result.ModeHz := DM.dmDisplayFrequency;
      Result.Width := DM.dmPelsWidth;
      Result.Height := DM.dmPelsHeight;
    end;
  end;
  FillChar(Timing, SizeOf(Timing), 0);
  Timing.cbSize := SizeOf(Timing);
  QueryPerformanceFrequency(Freq);
  if Succeeded(DwmGetCompositionTimingInfo(0, Timing)) and (Timing.qpcRefreshPeriod > 0) then
    Result.DwmHz := Freq / Timing.qpcRefreshPeriod;
  if AWnd <> 0 then
    Result.Dpi := GetDpiForWindowApi(AWnd);
end;

function MonitorEnumProc(AMonitor: HMONITOR; ADC: HDC; ARect: PRect; AData: LPARAM): BOOL; stdcall;
var
  MI: TMonitorInfoEx;
  Desc: TMonitorDesc;
begin
  FillChar(MI, SizeOf(MI), 0);
  MI.cbSize := SizeOf(MI);
  if GetMonitorInfo(AMonitor, @MI) then
  begin
    Desc.Handle := AMonitor;
    Desc.Device := string(PChar(@MI.szDevice[0]));
    Desc.Primary := (MI.dwFlags and MONITORINFOF_PRIMARY) <> 0;
    Desc.Bounds := MI.rcMonitor;
    Desc.WorkArea := MI.rcWork;
    TList<TMonitorDesc>(Pointer(AData)).Add(Desc);
  end;
  Result := True;
end;

function EnumMonitors: TArray<TMonitorDesc>;
var
  List: TList<TMonitorDesc>;
begin
  List := TList<TMonitorDesc>.Create;
  try
    EnumDisplayMonitorsApi(0, nil, @MonitorEnumProc, LPARAM(List));
    List.Sort(TComparer<TMonitorDesc>.Construct(
      function(const A, B: TMonitorDesc): Integer
      begin
        if A.Primary <> B.Primary then
          Result := Ord(B.Primary) - Ord(A.Primary)
        else
          Result := A.Bounds.Left - B.Bounds.Left;
      end));
    Result := List.ToArray;
  finally
    List.Free;
  end;
end;

function FindMonitor(const ASpec: string; out AMonitor: TMonitorDesc): Boolean;
var
  Monitors: TArray<TMonitorDesc>;
  M: TMonitorDesc;
  Index: Integer;
  Spec: string;
begin
  Monitors := EnumMonitors;
  Result := False;
  AMonitor := Default(TMonitorDesc);
  Spec := ASpec.Trim;
  if (Spec = '') or SameText(Spec, 'primary') then
    Index := 1
  else if SameText(Spec, 'secondary') then
    Index := 2
  else if not TryStrToInt(Spec, Index) then
  begin
    for M in Monitors do
      if SameText(M.Device, Spec) or SameText(M.Device, '\\.\' + Spec) then
      begin
        AMonitor := M;
        Exit(True);
      end;
    Exit;
  end;
  if (Index >= 1) and (Index <= Length(Monitors)) then
  begin
    AMonitor := Monitors[Index - 1];
    Result := True;
  end;
end;

function ReadRegString(const AKey, AName: string): string;
var
  Reg: TRegistry;
begin
  Result := '';
  Reg := TRegistry.Create(KEY_READ or KEY_WOW64_64KEY);
  try
    Reg.RootKey := HKEY_LOCAL_MACHINE;
    if Reg.OpenKeyReadOnly(AKey) and Reg.ValueExists(AName) then
      case Reg.GetDataType(AName) of
        rdInteger:
          Result := IntToStr(Reg.ReadInteger(AName));
      else
        Result := Reg.ReadString(AName);
      end;
  finally
    Reg.Free;
  end;
end;

procedure AddOsColumns(const ARow: TCsvRow);
const
  NtKey = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion';
var
  Product, Build, Ubr: string;
begin
  Product := ReadRegString(NtKey, 'ProductName');
  Build := ReadRegString(NtKey, 'CurrentBuild');
  Ubr := ReadRegString(NtKey, 'UBR');
  // ProductName still says "Windows 10" on Windows 11.
  if (StrToIntDef(Build, 0) >= 22000) and Product.StartsWith('Windows 10') then
    Product := 'Windows 11' + Product.Substring(Length('Windows 10'));
  ARow.Add('os', Product);
  ARow.Add('os_version', ReadRegString(NtKey, 'DisplayVersion'));
  if Ubr <> '' then
    ARow.Add('os_build', Build + '.' + Ubr)
  else
    ARow.Add('os_build', Build);
end;

procedure AddCpuColumns(const ARow: TCsvRow);
begin
  ARow.Add('cpu', ReadRegString('HARDWARE\DESCRIPTION\System\CentralProcessor\0',
    'ProcessorNameString').Trim);
  ARow.Add('cpu_threads', CPUCount);
end;

procedure AddGpuColumns(const ARow: TCsvRow);
var
  Factory: IDXGIFactory1;
  Adapter: IDXGIAdapter1;
  Desc: TDXGIAdapterDesc1;
  Umd: LARGE_INTEGER;
  Name, Driver, Ids: string;
begin
  Name := '';
  Driver := '';
  Ids := '';
  if Succeeded(CreateDXGIFactory1(IDXGIFactory1, Factory)) and
    Succeeded(Factory.EnumAdapters1(0, Adapter)) and Succeeded(Adapter.GetDesc1(Desc)) then
  begin
    Name := string(PWideChar(@Desc.Description[0])).Trim;
    Ids := Format('%.4x:%.4x', [Desc.VendorId, Desc.DeviceId]);
    if Succeeded(Adapter.CheckInterfaceSupport(IDXGIDevice, Umd)) then
      Driver := Format('%d.%d.%d.%d', [HiWord(Umd.HighPart), LoWord(Umd.HighPart),
        HiWord(Umd.LowPart), LoWord(Umd.LowPart)]);
  end;
  ARow.Add('gpu', Name);
  ARow.Add('gpu_id', Ids);
  ARow.Add('gpu_driver', Driver);
end;

procedure AddPowerColumns(const ARow: TCsvRow);
var
  Scheme: PGUID;
  Buf: array[0..255] of Byte;
  Size: DWORD;
  Name: string;
begin
  Name := '';
  Scheme := nil;
  if (PowerGetActiveScheme(0, Scheme) = ERROR_SUCCESS) and (Scheme <> nil) then
    try
      Size := SizeOf(Buf);
      if PowerReadFriendlyName(0, Scheme, nil, nil, @Buf[0], Size) = ERROR_SUCCESS then
        Name := string(PWideChar(@Buf[0]))
      else
        Name := GUIDToString(Scheme^);
    finally
      LocalFree(HLOCAL(Scheme));
    end;
  ARow.Add('power_plan', Name);
end;

procedure AddEnvironmentColumns(const ARow: TCsvRow);
begin
  AddOsColumns(ARow);
  AddCpuColumns(ARow);
  AddGpuColumns(ARow);
  AddPowerColumns(ARow);
  ARow.Add('delphi', BuildCompilerVersion);
  ARow.Add('build_config', BuildConfig);
  ARow.Add('commit', BuildCommitText);
end;

end.
