unit FastCanvas.Hdr;

{ HDR output of FastCanvas windows: the setting, and what the display a window is on can show.

  A window on a display in HDR mode (Windows HDR on: the output's color space is BT.2020 with the PQ curve) gets an
  FP16 swap chain in the scRGB color space (linear light, BT.709 primaries, 1.0 = 80 nits) when FastCanvasHdr says so
  (FastCanvas.Canvas, Direct3D 12). SDR content is shown at Windows' SDR content brightness (the "SDR content
  brightness" slider: the SDR white level of the display), as Windows shows the 8-bit windows of other programs.

  Display state comes from DXGI (IDXGIOutput6.GetDesc1: color space, minimum, peak and full-frame luminance) and the
  display configuration (DisplayConfigGetDeviceInfo, DISPLAYCONFIG_DEVICE_INFO_GET_SDR_WHITE_LEVEL). It is cached and
  read again when DXGI reports that the outputs changed (IDXGIFactory1.IsCurrent: a display added or removed, a mode
  change, Windows HDR switched on or off), when a window is on a monitor the cache does not know (at most once a
  second), and after FastHdrRefresh; the SDR white levels of displays in HDR mode once a second (the slider changes
  nothing DXGI reports). Any thread. }

interface

uses
  Winapi.Windows;

type
  /// <summary>FastCanvasHdr: whether windows output HDR.</summary>
  TFastCanvasHdr = (
    /// <summary>8-bit swap chains, as before (no cost).</summary>
    Off,
    /// <summary>A window on a display in HDR mode gets an FP16 scRGB swap chain; on an SDR display an 8-bit one.
    /// Follows the window to another monitor and Windows HDR being switched on or off.</summary>
    Auto,
    /// <summary>Testing: every window gets an FP16 scRGB swap chain, also on SDR displays (Windows then composes it to
    /// SDR, values above SDR white clip).</summary>
    Force);

  /// <summary>What a window shows: whether its output is HDR, and the display's levels. Nits are cd/m2.</summary>
  TFastHdrInfo = record
    /// <summary>The window's output is an FP16 scRGB swap chain: values above SDR white reach the compositor.
    /// </summary>
    Output: Boolean;
    /// <summary>The window's display is in HDR mode (Windows HDR on).</summary>
    DisplayHdr: Boolean;
    /// <summary>The display's luminance of SDR white (what 1.0 of SDR content is shown as): Windows' SDR content
    /// brightness on a display in HDR mode; 80 (scRGB 1.0, the display's own white) on a display in SDR mode.
    /// </summary>
    SdrWhiteNits: Single;
    /// <summary>Windows' SDR content brightness setting of the display (what SdrWhiteNits becomes in HDR mode), read
    /// in either mode; 0 when unknown.</summary>
    SdrWhiteSettingNits: Single;
    /// <summary>The display's peak luminance as it reports it (also in SDR mode; 0 when unknown).</summary>
    PeakNits: Single;
    /// <summary>The largest luminance the display keeps over the whole screen (0 when unknown).</summary>
    MaxFullFrameNits: Single;
    MinNits: Single;
    /// <summary>The largest value worth producing, in SDR white units (1.0 = SDR white): PeakNits / SdrWhiteNits with
    /// HDR output on a display in HDR mode, else 1. Tone-map to it.</summary>
    function Headroom: Single;
    /// <summary>scRGB value of SDR white: SdrWhiteNits / 80 (1 on a display in SDR mode).</summary>
    function WhiteScale: Single;
  end;

var
  /// <summary>HDR output of windows (FastCanvasBackend = D3D12; ignored on Direct3D 11): the windows of 2D forms
  /// drawn by FastCanvas, and of TForm3D drawn by its Direct3D 12 3D context. Read at every window frame, can be
  /// changed at run time. Transparent forms stay SDR.</summary>
  FastCanvasHdr: TFastCanvasHdr = TFastCanvasHdr.Off;
  /// <summary>Testing aid: above 0, the SDR white level (nits) of every display, also of displays in SDR mode (with
  /// FastCanvasHdr = Force: the scaling of SDR content can be checked on an SDR display).</summary>
  FastCanvasHdrTestWhite: Single = 0;

/// <summary>The display a window is on (the monitor with the largest part of it); Output = False. Any thread; cheap
/// unless the displays changed.</summary>
function FastHdrDisplayOf(const AWnd: HWND): TFastHdrInfo;
/// <summary>The next FastHdrDisplayOf reads the displays again (for a program that sees WM_DISPLAYCHANGE or
/// WM_SETTINGCHANGE before DXGI does).</summary>
procedure FastHdrRefresh;

implementation

uses
  System.SysUtils, System.Math, Winapi.MultiMon, DX12.DXGI, DX12.DXGI1_6;

{ Display configuration (wingdi.h; not in Winapi.Windows) }

type
  TDisplayConfigPathSourceInfo = record
    AdapterId: TLUID;
    Id: Cardinal;
    ModeInfoIdx: Cardinal;
    StatusFlags: Cardinal;
  end;

  TDisplayConfigPathTargetInfo = record
    AdapterId: TLUID;
    Id: Cardinal;
    ModeInfoIdx: Cardinal;
    OutputTechnology, Rotation, Scaling: Cardinal;
    RefreshNumerator, RefreshDenominator: Cardinal;
    ScanLineOrdering: Cardinal;
    TargetAvailable: LongBool;
    StatusFlags: Cardinal;
  end;

  TDisplayConfigPathInfo = record
    SourceInfo: TDisplayConfigPathSourceInfo;
    TargetInfo: TDisplayConfigPathTargetInfo;
    Flags: Cardinal;
  end;

  /// <summary>DISPLAYCONFIG_MODE_INFO: 64 bytes, not read.</summary>
  TDisplayConfigModeInfo = record
    Data: array[0..63] of Byte;
  end;

  TDisplayConfigDeviceInfoHeader = record
    InfoType: Cardinal;
    Size: Cardinal;
    AdapterId: TLUID;
    Id: Cardinal;
  end;

  TDisplayConfigSourceDeviceName = record
    Header: TDisplayConfigDeviceInfoHeader;
    ViewGdiDeviceName: array[0..31] of WideChar;
  end;

  TDisplayConfigSdrWhiteLevel = record
    Header: TDisplayConfigDeviceInfoHeader;
    SdrWhiteLevel: Cardinal;
  end;

  /// <summary>DXGI_OUTPUT_DESC1 with the C layout (the header's AttachedToDesktop is a 1-byte Boolean).</summary>
  TOutputDesc1 = record
    DeviceName: array[0..31] of WideChar;
    DesktopCoordinates: TRect;
    AttachedToDesktop: LongBool;
    Rotation: Cardinal;
    Monitor: HMONITOR;
    BitsPerColor: Cardinal;
    ColorSpace: Cardinal;
    Primaries: array[0..7] of Single;
    MinLuminance, MaxLuminance, MaxFullFrameLuminance: Single;
  end;
  PDxgiOutputDesc1 = ^TDXGI_OUTPUT_DESC1;

const
  QDC_ONLY_ACTIVE_PATHS = 2;
  DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME = 1;
  DISPLAYCONFIG_DEVICE_INFO_GET_SDR_WHITE_LEVEL = 11;
  /// <summary>DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020: the output of a display in HDR mode.</summary>
  ColorSpaceHdr10 = 12;
  /// <summary>SDR white levels of displays in HDR mode read again this often (ms); a monitor the cache does not know
  /// makes it enumerate again at most this often.</summary>
  WhitePeriod = 1000;

function GetDisplayConfigBufferSizes(Flags: Cardinal; var NumPathArrayElements, NumModeInfoArrayElements: Cardinal):
  Longint; stdcall; external user32;
function QueryDisplayConfig(Flags: Cardinal; var NumPathArrayElements: Cardinal; PathArray: Pointer;
  var NumModeInfoArrayElements: Cardinal; ModeInfoArray: Pointer; CurrentTopologyId: Pointer): Longint; stdcall;
  external user32;
function DisplayConfigGetDeviceInfo(RequestPacket: Pointer): Longint; stdcall; external user32;

{ TFastHdrInfo }

function TFastHdrInfo.Headroom: Single;
begin
  if Output and DisplayHdr and (SdrWhiteNits > 0) and (PeakNits > SdrWhiteNits) then
    Result := PeakNits / SdrWhiteNits
  else
    Result := 1;
end;

function TFastHdrInfo.WhiteScale: Single;
begin
  if SdrWhiteNits > 0 then
    Result := SdrWhiteNits / 80
  else
    Result := 1;
end;

{ Cache }

type
  TDisplayEntry = record
    Monitor: HMONITOR;
    DeviceName: string;
    /// <summary>The display path's target, for its SDR white level.</summary>
    AdapterId: TLUID;
    TargetId: Cardinal;
    HasTarget: Boolean;
    Info: TFastHdrInfo;
  end;

var
  GLock: TObject;
  GFactory: IDXGIFactory1;
  GEntries: TArray<TDisplayEntry>;
  GEnumerated, GWhiteRead: UInt64;
  /// <summary>FastHdrRefresh asked for a new enumeration; some display is in HDR mode.</summary>
  GRefresh, GAnyHdr: Boolean;

/// <summary>Windows' SDR content brightness of a display, nits; 0 when unknown.</summary>
function ReadWhiteLevel(const AEntry: TDisplayEntry): Single;
var
  W: TDisplayConfigSdrWhiteLevel;
begin
  Result := 0;
  if not AEntry.HasTarget then
    Exit;
  FillChar(W, SizeOf(W), 0);
  W.Header.InfoType := DISPLAYCONFIG_DEVICE_INFO_GET_SDR_WHITE_LEVEL;
  W.Header.Size := SizeOf(W);
  W.Header.AdapterId := AEntry.AdapterId;
  W.Header.Id := AEntry.TargetId;
  // In thousandths of 80 nits.
  if (DisplayConfigGetDeviceInfo(@W) = ERROR_SUCCESS) and (W.SdrWhiteLevel > 0) then
    Result := W.SdrWhiteLevel / 1000 * 80;
end;

/// <summary>The SDR white levels of the displays in HDR mode (80 nits on the others).</summary>
procedure ReadWhiteLevels;
var
  I: Integer;
  W: Single;
begin
  for I := 0 to High(GEntries) do
  begin
    W := 80;
    if GEntries[I].Info.DisplayHdr then
    begin
      W := ReadWhiteLevel(GEntries[I]);
      if W <= 0 then
        W := 80;
      GEntries[I].Info.SdrWhiteSettingNits := W;
    end;
    GEntries[I].Info.SdrWhiteNits := W;
  end;
  GWhiteRead := GetTickCount64;
end;

/// <summary>The display paths' targets of the entries (matched by GDI device name).</summary>
procedure ReadTargets;
var
  NumPaths, NumModes: Cardinal;
  Paths: TArray<TDisplayConfigPathInfo>;
  Modes: TArray<TDisplayConfigModeInfo>;
  Res: Longint;
  Name: TDisplayConfigSourceDeviceName;
  I, J: Integer;
begin
  repeat
    if GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, NumPaths, NumModes) <> ERROR_SUCCESS then
      Exit;
    SetLength(Paths, NumPaths);
    SetLength(Modes, NumModes);
    Res := QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, NumPaths, Pointer(Paths), NumModes, Pointer(Modes), nil);
  until Res <> ERROR_INSUFFICIENT_BUFFER;
  if Res <> ERROR_SUCCESS then
    Exit;
  for I := 0 to Integer(NumPaths) - 1 do
  begin
    FillChar(Name, SizeOf(Name), 0);
    Name.Header.InfoType := DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME;
    Name.Header.Size := SizeOf(Name);
    Name.Header.AdapterId := Paths[I].SourceInfo.AdapterId;
    Name.Header.Id := Paths[I].SourceInfo.Id;
    if DisplayConfigGetDeviceInfo(@Name) <> ERROR_SUCCESS then
      Continue;
    for J := 0 to High(GEntries) do
      if SameText(GEntries[J].DeviceName, string(PWideChar(@Name.ViewGdiDeviceName[0]))) then
      begin
        GEntries[J].AdapterId := Paths[I].TargetInfo.AdapterId;
        GEntries[J].TargetId := Paths[I].TargetInfo.Id;
        GEntries[J].HasTarget := True;
      end;
  end;
end;

/// <summary>Every output of every adapter, with a new factory (the old one may hold stale outputs).</summary>
procedure Enumerate;
var
  Adapter: IDXGIAdapter1;
  Output: IDXGIOutput;
  Output6: IDXGIOutput6;
  Desc: TDXGI_OUTPUT_DESC;
  Desc1: TOutputDesc1;
  E: TDisplayEntry;
  A, O: Cardinal;
  I: Integer;
  List: TArray<TDisplayEntry>;
begin
  GFactory := nil;
  GEntries := nil;
  GEnumerated := GetTickCount64;
  if Failed(CreateDXGIFactory1(IID_IDXGIFactory1, GFactory)) then
  begin
    GFactory := nil;
    Exit;
  end;
  A := 0;
  while Succeeded(GFactory.EnumAdapters1(A, Adapter)) do
  begin
    O := 0;
    while Succeeded(Adapter.EnumOutputs(O, Output)) do
    begin
      E := Default(TDisplayEntry);
      E.Info.SdrWhiteNits := 80;
      if Supports(Output, IDXGIOutput6, Output6) then
      begin
        FillChar(Desc1, SizeOf(Desc1), 0);
        if Succeeded(Output6.GetDesc1(PDxgiOutputDesc1(@Desc1)^)) then
        begin
          E.Monitor := Desc1.Monitor;
          E.DeviceName := PWideChar(@Desc1.DeviceName[0]);
          E.Info.DisplayHdr := Desc1.ColorSpace = ColorSpaceHdr10;
          E.Info.PeakNits := Desc1.MaxLuminance;
          E.Info.MaxFullFrameNits := Desc1.MaxFullFrameLuminance;
          E.Info.MinNits := Desc1.MinLuminance;
        end;
        Output6 := nil;
      end;
      if (E.Monitor = 0) and Succeeded(Output.GetDesc(Desc)) then
      begin
        E.Monitor := Desc.Monitor;
        E.DeviceName := PWideChar(@Desc.DeviceName[0]);
      end;
      if E.Monitor <> 0 then
        List := List + [E];
      Output := nil;
      Inc(O);
    end;
    Adapter := nil;
    Inc(A);
  end;
  GEntries := List;
  GRefresh := False;
  ReadTargets;
  // The setting of every display once; displays in HDR mode use it (ReadWhiteLevels reads them again later).
  GAnyHdr := False;
  for I := 0 to High(GEntries) do
  begin
    GEntries[I].Info.SdrWhiteSettingNits := ReadWhiteLevel(GEntries[I]);
    GAnyHdr := GAnyHdr or GEntries[I].Info.DisplayHdr;
  end;
  ReadWhiteLevels;
end;

function Find(const AMonitor: HMONITOR; out AInfo: TFastHdrInfo): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(GEntries) do
    if GEntries[I].Monitor = AMonitor then
    begin
      AInfo := GEntries[I].Info;
      Exit(True);
    end;
  Result := False;
end;

function FastHdrDisplayOf(const AWnd: HWND): TFastHdrInfo;
var
  Monitor: HMONITOR;
  Tick: UInt64;
begin
  Result := Default(TFastHdrInfo);
  Result.SdrWhiteNits := 80;
  Monitor := MonitorFromWindow(AWnd, MONITOR_DEFAULTTONEAREST);
  TMonitor.Enter(GLock);
  try
    Tick := GetTickCount64;
    if (GFactory = nil) or GRefresh or not GFactory.IsCurrent then
      Enumerate
    else if (Tick - GWhiteRead >= WhitePeriod) and GAnyHdr then
      ReadWhiteLevels;
    if not Find(Monitor, Result) and (Tick - GEnumerated >= WhitePeriod) then
    begin
      // A monitor DXGI did not list when the cache was made.
      Enumerate;
      Find(Monitor, Result);
    end;
    Result.Output := False;
  finally
    TMonitor.Exit(GLock);
  end;
  if FastCanvasHdrTestWhite > 0 then
    Result.SdrWhiteNits := FastCanvasHdrTestWhite;
end;

procedure FastHdrRefresh;
begin
  GRefresh := True;
end;

initialization
  GLock := TObject.Create;
finalization
  GFactory := nil;
  GLock.Free;
end.
