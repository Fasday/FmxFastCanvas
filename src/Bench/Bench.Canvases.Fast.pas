unit Bench.Canvases.Fast;

{ The FastCanvas variants of the benchmark (fc on Direct3D 11, fcdx12 on Direct3D 12, fcvk on Vulkan, ray-traced
  effects, measurement aids). }

interface

implementation

uses
  System.SysUtils, System.TypInfo, FMX.Graphics, Bench.Config, Bench.Canvases,
  FastCanvas.Context3D11, FastCanvas.Context3D12, FastCanvas.Context3DVk, FastCanvas.Device, FastCanvas.Hdr,
  FastCanvas.Geometry, FastCanvas.GeometryOwn, FastCanvas.Text, FastCanvas.Canvas;


function FastCanvasOptionsText(const AOptions: TFastCanvasOptions): string;
var
  O: TFastCanvasOption;
begin
  Result := '';
  for O := Low(TFastCanvasOption) to High(TFastCanvasOption) do
    if O in AOptions then
    begin
      if Result <> '' then
        Result := Result + '+';
      Result := Result + GetEnumName(TypeInfo(TFastCanvasOption), Ord(O));
    end;
  if Result = '' then
    Result := 'none';
end;

/// <summary>A FastCanvas variant. ABaseOptions, then --copts: comma separated, none | +Name | -Name | Name of
/// TFastCanvasOption, applied left to right, and the bench options below.</summary>
procedure RegisterFastCanvas(const AName, ADescription, ABaseOptions: string);
begin
  RegisterBenchCanvas(AName, ADescription, 'TFastCanvas',
    procedure(const AConfig: TBenchConfig)
    var
      Token, Name: string;
      Value: Integer;
    begin
      FastCanvasOptions := [];
      // Throughput means no vsync wait. A flip-model swap chain presenting with sync interval 0 is still held to the
      // refresh rate when DWM runs the window in independent flip, unless tearing is allowed (exactly 240 or 120 FPS
      // otherwise). --copts=-AllowTearing turns it off.
      if AConfig.Mode = TBenchMode.Throughput then
        Include(FastCanvasOptions, TFastCanvasOption.AllowTearing);
      for Token in (ABaseOptions + ',' + AConfig.CanvasOpts).Split([',']) do
      begin
        Name := Token.Trim;
        // Bench options, not canvas options: the stock 3D context on its own device; the memory manager left
        // sleeping on lock contention; no render thread (FastCanvasRenderThread).
        if (Name = '') or SameText(Name, 'SeparateContext3D') or SameText(Name, 'HeapSleep') or
          SameText(Name, 'MainThread') or SameText(Name, 'D3D12') or SameText(Name, 'Vulkan') or
          SameText(Name, 'RayShadows') or SameText(Name, 'RaySoft') or SameText(Name, 'RayAO') or
          SameText(Name, 'NoPartial') or SameText(Name, 'RayReflect') or SameText(Name, 'HdrForce') or
          SameText(Name, 'HdrAuto') or SameText(Name, 'Composition') or SameText(Name, 'ClearType') or
          SameText(Name, 'TextAliased') or SameText(Name, 'TextSystem') or SameText(Name, 'SkiaGeometry') or
          SameText(Name, 'SkiaText') or SameText(Name, 'OwnGeometry') then
          Continue;
        if SameText(Name, 'none') then
        begin
          FastCanvasOptions := [];
          Continue;
        end;
        Value := GetEnumValue(TypeInfo(TFastCanvasOption), Name.TrimLeft(['+', '-']));
        if (Value < Ord(Low(TFastCanvasOption))) or (Value > Ord(High(TFastCanvasOption))) then
          raise EBenchConfig.CreateFmt('Unknown canvas option "%s"', [Name]);
        if Name.StartsWith('-') then
          Exclude(FastCanvasOptions, TFastCanvasOption(Value))
        else
          Include(FastCanvasOptions, TFastCanvasOption(Value));
      end;
      if GetEnvironmentVariable('FC_IN_FLIGHT') <> '' then
        FastCanvasFramesInFlight := StrToInt(GetEnvironmentVariable('FC_IN_FLIGHT'));
      FastCanvasNoHeapSleep := not (ABaseOptions + ',' + AConfig.CanvasOpts).Contains('HeapSleep');
      FastCanvasRenderThread := not (ABaseOptions + ',' + AConfig.CanvasOpts).Contains('MainThread');
      FastCanvasPartialFrames := not (ABaseOptions + ',' + AConfig.CanvasOpts).Contains('NoPartial');
      if (ABaseOptions + ',' + AConfig.CanvasOpts).Contains('Vulkan') then
        FastCanvasBackend := TFastCanvasBackend.Vulkan
      else if (ABaseOptions + ',' + AConfig.CanvasOpts).Contains('D3D12') then
        FastCanvasBackend := TFastCanvasBackend.D3D12
      else
        FastCanvasBackend := TFastCanvasBackend.D3D11;
      FastContext3DRayTracing.Shadows := (ABaseOptions + ',' + AConfig.CanvasOpts).Contains('RayShadows');
      if (ABaseOptions + ',' + AConfig.CanvasOpts).Contains('RaySoft') then
        FastContext3DRayTracing.ShadowSoftness := 0.05
      else
        FastContext3DRayTracing.ShadowSoftness := 0;
      FastContext3DRayTracing.AmbientOcclusion := (ABaseOptions + ',' + AConfig.CanvasOpts).Contains('RayAO');
      FastContext3DRayTracing.Reflections := (ABaseOptions + ',' + AConfig.CanvasOpts).Contains('RayReflect');
      // HDR output of the windows: forced (FP16 scRGB swap chains, also on an SDR display) or where the display is in
      // HDR mode.
      if (ABaseOptions + ',' + AConfig.CanvasOpts).Contains('HdrForce') then
        FastCanvasHdr := TFastCanvasHdr.Force
      else if (ABaseOptions + ',' + AConfig.CanvasOpts).Contains('HdrAuto') then
        FastCanvasHdr := TFastCanvasHdr.Auto
      else
        FastCanvasHdr := TFastCanvasHdr.Off;
      // Windows shown by DirectComposition (composition swap chains, premultiplied alpha), else by swap chains of the
      // windows (the canvas's default is Composition). Composition presents without tearing (with AllowTearing the
      // canvas would take Flip): in throughput mode it is not held to the refresh rate anyway, DWM composes it.
      if (ABaseOptions + ',' + AConfig.CanvasOpts).Contains('Composition') then
      begin
        FastCanvasPresentation := TFastCanvasPresentation.Composition;
        Exclude(FastCanvasOptions, TFastCanvasOption.AllowTearing);
      end
      else
        FastCanvasPresentation := TFastCanvasPresentation.Flip;
      // Text antialiasing: ClearType in the window frames (dual-source blending), aliased, as Windows draws it, else
      // grayscale as the stock canvas.
      if (ABaseOptions + ',' + AConfig.CanvasOpts).Contains('ClearType') then
        FastCanvasTextAntialias := TFastTextAntialias.ClearType
      else if (ABaseOptions + ',' + AConfig.CanvasOpts).Contains('TextAliased') then
        FastCanvasTextAntialias := TFastTextAntialias.Aliased
      else if (ABaseOptions + ',' + AConfig.CanvasOpts).Contains('TextSystem') then
        FastCanvasTextAntialias := TFastTextAntialias.System
      else
        FastCanvasTextAntialias := TFastTextAntialias.Grayscale;
      // The CPU engines: Skia's, FastCanvas's own geometry (Android's and Linux's) or Direct2D's and DirectWrite's.
      if (ABaseOptions + ',' + AConfig.CanvasOpts).Contains('SkiaGeometry') then
        FastCanvasGeometryEngine := TFastCanvasEngine.Skia
      else if (ABaseOptions + ',' + AConfig.CanvasOpts).Contains('OwnGeometry') then
        FastCanvasGeometryEngine := TFastCanvasEngine.Own
      else
        FastCanvasGeometryEngine := TFastCanvasEngine.Native;
      if (ABaseOptions + ',' + AConfig.CanvasOpts).Contains('SkiaText') then
        FastCanvasTextEngine := TFastCanvasEngine.Skia
      else
        FastCanvasTextEngine := TFastCanvasEngine.Native;
      InstallFastCanvas;
      // The 3D context (TEffect filters, TViewport3D) on the canvas device: our own; SeparateContext3D keeps the stock
      // context on its own device.
      if not (ABaseOptions + ',' + AConfig.CanvasOpts).Contains('SeparateContext3D') then
        case FastCanvasBackend of
          TFastCanvasBackend.D3D11: InstallFastContext3D11;
          TFastCanvasBackend.D3D12: InstallFastContext3D12;
          TFastCanvasBackend.Vulkan: InstallFastContext3DVk;
        end;
    end,
    procedure(const AConfig: TBenchConfig; out AGeometry, AText: string)
    begin
      if AConfig.Quality = TCanvasQuality.HighPerformance then
        AGeometry := 'none'
      else
        AGeometry := 'analytic';
      case FastCanvasTextAntialias of
        TFastTextAntialias.ClearType: AText := 'cleartype-atlas';
        TFastTextAntialias.Aliased: AText := 'aliased-atlas';
        TFastTextAntialias.System: AText := 'system-atlas';
      else
        AText := 'gray-atlas';
      end;
      if FastCanvasTextEngine = TFastCanvasEngine.Skia then
        AText := 'skia-' + AText;
    end);
  FindBenchCanvas(AName).Options :=
    function: string
    begin
      Result := FastCanvasOptionsText(FastCanvasOptions);
      if not FastCanvasRenderThread then
        Result := Result + '+MainThread';
      if FastCanvasBackend = TFastCanvasBackend.D3D12 then
        Result := Result + '+D3D12'
      else if FastCanvasBackend = TFastCanvasBackend.Vulkan then
        Result := Result + '+Vulkan';
      if (FastCanvasBackend <> TFastCanvasBackend.D3D11) and not FastCanvasPartialFrames then
        Result := Result + '+NoPartial';
      if FastContext3DRayTracing.Shadows then
        Result := Result + '+RayShadows';
      if FastContext3DRayTracing.ShadowSoftness > 0 then
        Result := Result + '+RaySoft';
      if FastContext3DRayTracing.AmbientOcclusion then
        Result := Result + '+RayAO';
      if FastContext3DRayTracing.Reflections then
        Result := Result + '+RayReflect';
      case FastCanvasHdr of
        TFastCanvasHdr.Force: Result := Result + '+HdrForce';
        TFastCanvasHdr.Auto: Result := Result + '+HdrAuto';
      end;
      if FastCanvasPresentation = TFastCanvasPresentation.Composition then
        Result := Result + '+Composition';
      case FastCanvasTextAntialias of
        TFastTextAntialias.ClearType: Result := Result + '+ClearType';
        TFastTextAntialias.Aliased: Result := Result + '+TextAliased';
        TFastTextAntialias.System: Result := Result + '+TextSystem';
      end;
      if FastCanvasGeometryEngine = TFastCanvasEngine.Skia then
        Result := Result + '+SkiaGeometry'
      else if FastCanvasGeometryEngine = TFastCanvasEngine.Own then
        Result := Result + '+OwnGeometry';
      if FastCanvasTextEngine = TFastCanvasEngine.Skia then
        Result := Result + '+SkiaText';
    end;
  FindBenchCanvas(AName).RenderBusyMs :=
    function: Double
    begin
      Result := FastCanvasRenderBusyMs;
    end;
  FindBenchCanvas(AName).RenderThreadId :=
    function: Cardinal
    begin
      Result := FastCanvasRenderThreadId;
    end;
  FindBenchCanvas(AName).BeforeCapture :=
    procedure
    begin
      FastCanvasSync;
    end;
  FindBenchCanvas(AName).SimulateDeviceLoss :=
    procedure
    begin
      FastCanvasSimulateDeviceLoss;
    end;
  FindBenchCanvas(AName).DeviceResets :=
    function: Integer
    begin
      Result := FastCanvasDeviceResets;
    end;
end;

procedure RegisterFastCanvases;
begin
  RegisterFastCanvas('fc', 'FastCanvas (stage 4: own GPU renderer, glyph atlas, render thread; own 3D context)', '');
  RegisterFastCanvas('fcsep', 'FastCanvas with the stock 3D context on its own device', 'SeparateContext3D');
  RegisterFastCanvas('fcd2dtext', 'FastCanvas with Direct2D text (measurement aid)', 'D2DText');
  RegisterFastCanvas('fcd2dtextct', 'FastCanvas with Direct2D ClearType text (measurement aid, reference of fcct)',
    'D2DText,ClearType');
  RegisterFastCanvas('fcd2dtextaliased',
    'FastCanvas with Direct2D aliased text (measurement aid, reference of fcaliased)', 'D2DText,TextAliased');
  RegisterFastCanvas('fcdx12', 'FastCanvas on Direct3D 12 (stage 5: canvas and own 3D context)', 'D3D12');
  RegisterFastCanvas('fcct', 'FastCanvas with ClearType text (dual-source blending of the window frames)',
    'ClearType');
  RegisterFastCanvas('fcdx12ct', 'FastCanvas on Direct3D 12 with ClearType text (dual-source blending)',
    'D3D12,ClearType');
  RegisterFastCanvas('fcaliased', 'FastCanvas with aliased text (no antialiasing)', 'TextAliased');
  RegisterFastCanvas('fcsystext', 'FastCanvas with text antialiased as Windows draws it (TFastTextAntialias.System)',
    'TextSystem');
  RegisterFastCanvas('fcdx12rt', 'FastCanvas on Direct3D 12 with ray-traced shadows in 3D scenes (DXR 1.1)',
    'D3D12,RayShadows');
  RegisterFastCanvas('fcdx12ao', 'FastCanvas on Direct3D 12 with ray-traced shadows and ambient occlusion (8 rays)',
    'D3D12,RayShadows,RayAO');
  RegisterFastCanvas('fcdx12soft',
    'FastCanvas on Direct3D 12 with soft ray-traced shadows (8 rays per light) and ambient occlusion (8 rays)',
    'D3D12,RayShadows,RaySoft,RayAO');
  RegisterFastCanvas('fcdx12refl', 'FastCanvas on Direct3D 12 with ray-traced shadows and reflections',
    'D3D12,RayShadows,RayReflect');
  RegisterFastCanvas('fcdx12sep', 'FastCanvas on Direct3D 12 with the stock 3D context on its own device',
    'D3D12,SeparateContext3D');
  RegisterFastCanvas('fcdx12hdr',
    'FastCanvas on Direct3D 12 with HDR output forced (FP16 scRGB swap chain, also on an SDR display)',
    'D3D12,HdrForce');
  RegisterFastCanvas('fcdx12hdrauto',
    'FastCanvas on Direct3D 12 with HDR output where the display is in HDR mode (FastCanvasHdr = Auto)',
    'D3D12,HdrAuto');
  RegisterFastCanvas('fcdc', 'FastCanvas with windows shown by DirectComposition (composition swap chains)',
    'Composition');
  RegisterFastCanvas('fcdx12dc',
    'FastCanvas on Direct3D 12 with windows shown by DirectComposition (composition swap chains)',
    'D3D12,Composition');
  RegisterFastCanvas('fcvk', 'FastCanvas on Vulkan (canvas and own 3D context)', 'Vulkan');
  RegisterFastCanvas('fcvksep', 'FastCanvas on Vulkan with the stock 3D context on its own device',
    'Vulkan,SeparateContext3D');
  RegisterFastCanvas('fcvkrt', 'FastCanvas on Vulkan with ray-traced shadows in 3D scenes (ray queries)',
    'Vulkan,RayShadows');
  RegisterFastCanvas('fcvkao', 'FastCanvas on Vulkan with ray-traced shadows and ambient occlusion (8 rays)',
    'Vulkan,RayShadows,RayAO');
  RegisterFastCanvas('fcvksoft',
    'FastCanvas on Vulkan with soft ray-traced shadows (8 rays per light) and ambient occlusion (8 rays)',
    'Vulkan,RayShadows,RaySoft,RayAO');
  RegisterFastCanvas('fcvkrefl', 'FastCanvas on Vulkan with ray-traced shadows and reflections',
    'Vulkan,RayShadows,RayReflect');
  RegisterFastCanvas('fcvkskia',
    'FastCanvas on Vulkan with the Skia geometry and text engines (those of Android and Linux)',
    'Vulkan,SkiaGeometry,SkiaText');
  RegisterFastCanvas('fcvkown',
    'FastCanvas on Vulkan with its own geometry engine (that of Android and Linux; text by DirectWrite)',
    'Vulkan,OwnGeometry');
  RegisterFastCanvas('fcst', 'FastCanvas without the render thread (commands executed on the main thread)',
    'MainThread');
  RegisterFastCanvas('fcheapsleep', 'FastCanvas with the memory manager sleeping on lock contention (RTL default)',
    'HeapSleep');
end;

initialization
  RegisterFastCanvases;
end.
