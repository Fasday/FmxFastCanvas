unit Bench.Canvases.Builtin;

{ The five canvases that ship with FMX on Windows (docs/BENCHMARKS.md). }

interface

implementation

uses
  FMX.Types, FMX.Graphics, FMX.Skia, FMX.Skia.Canvas.Vulkan, Bench.Config, Bench.Canvases;

procedure RegisterBuiltinCanvases;
begin
  RegisterBenchCanvas('d2d', 'Direct2D 1.0 on D3D10.1 (FMX default)', 'TCanvasD2D',
    procedure(const AConfig: TBenchConfig)
    begin
    end,
    procedure(const AConfig: TBenchConfig; out AGeometry, AText: string)
    begin
      if AConfig.Quality = TCanvasQuality.HighPerformance then
        AGeometry := 'none'
      else
        AGeometry := 'analytic';
      AText := 'd2d-default';
    end);

  RegisterBenchCanvas('gpu', 'FMX GPU canvas on TDX11Context', 'TCanvasGpu',
    procedure(const AConfig: TBenchConfig)
    begin
      GlobalUseGPUCanvas := True;
    end,
    procedure(const AConfig: TBenchConfig; out AGeometry, AText: string)
    begin
      if AConfig.Quality = TCanvasQuality.HighQuality then
        AGeometry := 'msaa4'
      else
        AGeometry := 'none';
      AText := 'gdi-glyph-cache';
    end);

  RegisterBenchCanvas('gdip', 'GDI+', 'TCanvasGdiPlus',
    procedure(const AConfig: TBenchConfig)
    begin
      GlobalUseDirect2D := False;
    end,
    procedure(const AConfig: TBenchConfig; out AGeometry, AText: string)
    begin
      // HighQuality maps to SmoothingModeHighQuality only before Vista (FMX.Canvas.GDIP.pas:228-235).
      if AConfig.Quality = TCanvasQuality.HighPerformance then
        AGeometry := 'none'
      else
        AGeometry := 'gdip-8x8';
      if GlobalUseGDIPlusClearType then
        AText := 'cleartype-gridfit'
      else
        AText := 'antialias';
    end);

  RegisterBenchCanvas('skia', 'Skia raster (CPU)', 'TSkRasterCanvas',
    procedure(const AConfig: TBenchConfig)
    begin
      GlobalUseSkia := True;
      GlobalUseSkiaRasterWhenAvailable := True;
      GlobalDisableSkiaCodecsReplacement := False;
    end,
    procedure(const AConfig: TBenchConfig; out AGeometry, AText: string)
    begin
      AGeometry := 'analytic';
      AText := 'skia-default';
    end);

  RegisterBenchCanvas('skiavk', 'Skia Vulkan (GPU)', 'TVkCanvas',
    procedure(const AConfig: TBenchConfig)
    begin
      GlobalUseSkia := True;
      GlobalUseSkiaRasterWhenAvailable := False;
      GlobalDisableSkiaCodecsReplacement := False;
      case AConfig.VkFifo of
        TVkFifoOption.On: GlobalUseSkiaVulkanFifoKHR := True;
        TVkFifoOption.Off: GlobalUseSkiaVulkanFifoKHR := False;
      else
        // AGENTS.md, measurement rule 5: FIFO everywhere except the unlimited (throughput) mode.
        GlobalUseSkiaVulkanFifoKHR := AConfig.Mode = TBenchMode.Paced;
      end;
    end,
    procedure(const AConfig: TBenchConfig; out AGeometry, AText: string)
    begin
      AGeometry := 'analytic';
      AText := 'skia-default';
    end);
end;

initialization
  RegisterBuiltinCanvases;
end.
