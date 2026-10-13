unit Bench.Canvases;

{ Registry of canvases the benchmark can select. Each entry sets FMX globals before
  Application.Initialize and describes what anti-aliasing it uses for a given TForm.Quality.
  Later stages register their own canvases from separate units. }

interface

uses
  System.SysUtils, System.Generics.Collections, FMX.Types, Bench.Config, Common.Csv;

type
  TBenchCanvasSetup = reference to procedure(const AConfig: TBenchConfig);
  TBenchCanvasAA = reference to procedure(const AConfig: TBenchConfig; out AGeometry, AText: string);

  TBenchCanvasInfo = class
  public
    Name: string;
    Description: string;
    ExpectedClass: string;
    Setup: TBenchCanvasSetup;
    AntiAliasing: TBenchCanvasAA;
    /// <summary>Effective canvas options for the CSV; nil for canvases without options.</summary>
    Options: TFunc<string>;
    /// <summary>Called before the screen is captured: a canvas with a render thread finishes the frame.</summary>
    BeforeCapture: TProc;
    /// <summary>Time the canvas' render thread has been busy so far, ms; nil for canvases without one.</summary>
    RenderBusyMs: TFunc<Double>;
    /// <summary>ID of the canvas' render thread (0 = none yet); for --profile-thread=render.</summary>
    RenderThreadId: TFunc<Cardinal>;
    /// <summary>Makes the canvas recreate its graphics device as after a device removal (--device-loss); nil when
    /// the canvas cannot.</summary>
    SimulateDeviceLoss: TProc;
    DeviceResets: TFunc<Integer>;
  end;

procedure RegisterBenchCanvas(const AName, ADescription, AExpectedClass: string;
  const ASetup: TBenchCanvasSetup; const AAntiAliasing: TBenchCanvasAA);
function FindBenchCanvas(const AName: string): TBenchCanvasInfo;
function BenchCanvases: TArray<TBenchCanvasInfo>;

/// <summary>Resets FMX globals to the values every run starts from.</summary>
procedure ResetGlobals(const AConfig: TBenchConfig);
/// <summary>Adds all FMX Global* flags that influence rendering.</summary>
procedure AddGlobalFlagColumns(const ARow: TCsvRow);

implementation

uses
  FMX.Skia, FMX.Skia.Canvas.Vulkan;

var
  GCanvases: TObjectList<TBenchCanvasInfo>;

procedure RegisterBenchCanvas(const AName, ADescription, AExpectedClass: string;
  const ASetup: TBenchCanvasSetup; const AAntiAliasing: TBenchCanvasAA);
var
  Info: TBenchCanvasInfo;
begin
  if FindBenchCanvas(AName) <> nil then
    raise EArgumentException.CreateFmt('Canvas "%s" is already registered', [AName]);
  Info := TBenchCanvasInfo.Create;
  Info.Name := AName.ToLower;
  Info.Description := ADescription;
  Info.ExpectedClass := AExpectedClass;
  Info.Setup := ASetup;
  Info.AntiAliasing := AAntiAliasing;
  GCanvases.Add(Info);
end;

function FindBenchCanvas(const AName: string): TBenchCanvasInfo;
var
  Info: TBenchCanvasInfo;
begin
  for Info in GCanvases do
    if SameText(Info.Name, AName) then
      Exit(Info);
  Result := nil;
end;

function BenchCanvases: TArray<TBenchCanvasInfo>;
begin
  Result := GCanvases.ToArray;
end;

procedure ResetGlobals(const AConfig: TBenchConfig);
begin
  GlobalPreferredFramesPerSecond := AConfig.Fps;
  GlobalUseDX := True;
  GlobalUseDXSoftware := False;
  GlobalUseDirect2D := True;
  GlobalUseGPUCanvas := False;
  GlobalUseVulkan := True;
  GlobalUseSkia := False;
  GlobalUseSkiaRasterWhenAvailable := True;
  // FMX.Skia is linked into the exe, so keep the platform image codecs unless Skia is selected.
  GlobalDisableSkiaCodecsReplacement := True;
  GlobalUseSkiaVulkanFifoKHR := False;
end;

procedure AddGlobalFlagColumns(const ARow: TCsvRow);
begin
  ARow.Add('g_preferred_fps', GlobalPreferredFramesPerSecond);
  ARow.AddBool('g_use_dx', GlobalUseDX);
  ARow.AddBool('g_use_dx_in_dx9_mode', GlobalUseDXInDX9Mode);
  ARow.AddBool('g_use_dx_software', GlobalUseDXSoftware);
  ARow.AddBool('g_use_direct2d', GlobalUseDirect2D);
  ARow.AddBool('g_use_gdiplus_cleartype', GlobalUseGDIPlusClearType);
  ARow.AddBool('g_use_gpu_canvas', GlobalUseGPUCanvas);
  ARow.AddBool('g_use_vulkan', GlobalUseVulkan);
  ARow.AddBool('g_disable_focus_effect', GlobalDisableFocusEffect);
  ARow.AddBool('g_use_skia', GlobalUseSkia);
  ARow.AddBool('g_use_skia_raster_when_available', GlobalUseSkiaRasterWhenAvailable);
  ARow.AddBool('g_use_skia_filters', GlobalUseSkiaFilters);
  ARow.AddBool('g_skia_bitmaps_in_parallel', GlobalSkiaBitmapsInParallel);
  ARow.AddBool('g_disable_skia_codecs_replacement', GlobalDisableSkiaCodecsReplacement);
  ARow.AddBool('g_use_skia_vulkan_fifo', GlobalUseSkiaVulkanFifoKHR);
end;

initialization
  GCanvases := TObjectList<TBenchCanvasInfo>.Create(True);
finalization
  GCanvases.Free;
end.
