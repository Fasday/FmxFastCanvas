unit Bench.Canvases.Fast;

{ The FastCanvas variants of the benchmark (fc on Direct3D 11, fcdx12 on Direct3D 12, ray-traced effects, measurement
  aids). }

interface

implementation

uses
  System.SysUtils, System.TypInfo, FMX.Graphics, Bench.Config, Bench.Canvases,
  FastCanvas.Context3D11, FastCanvas.Context3D12, FastCanvas.Device, FastCanvas.Hdr, FastCanvas.Canvas;


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
          SameText(Name, 'MainThread') or SameText(Name, 'D3D12') or
          SameText(Name, 'RayShadows') or SameText(Name, 'RaySoft') or SameText(Name, 'RayAO') or
          SameText(Name, 'NoPartial') or SameText(Name, 'RayReflect') or SameText(Name, 'HdrForce') or
          SameText(Name, 'HdrAuto') or SameText(Name, 'Composition') then
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
      if (ABaseOptions + ',' + AConfig.CanvasOpts).Contains('D3D12') then
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
      InstallFastCanvas;
      // The 3D context (TEffect filters, TViewport3D) on the canvas device: our own; SeparateContext3D keeps the stock
      // context on its own device.
      if not (ABaseOptions + ',' + AConfig.CanvasOpts).Contains('SeparateContext3D') then
        if FastCanvasBackend = TFastCanvasBackend.D3D12 then
          InstallFastContext3D12
        else
          InstallFastContext3D11;
    end,
    procedure(const AConfig: TBenchConfig; out AGeometry, AText: string)
    begin
      if AConfig.Quality = TCanvasQuality.HighPerformance then
        AGeometry := 'none'
      else
        AGeometry := 'analytic';
      AText := 'gray-atlas';
    end);
  FindBenchCanvas(AName).Options :=
    function: string
    begin
      Result := FastCanvasOptionsText(FastCanvasOptions);
      if not FastCanvasRenderThread then
        Result := Result + '+MainThread';
      if FastCanvasBackend = TFastCanvasBackend.D3D12 then
      begin
        Result := Result + '+D3D12';
        if not FastCanvasPartialFrames then
          Result := Result + '+NoPartial';
      end;
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
  RegisterFastCanvas('fcdx12', 'FastCanvas on Direct3D 12 (stage 5: canvas and own 3D context)', 'D3D12');
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
  RegisterFastCanvas('fcst', 'FastCanvas without the render thread (commands executed on the main thread)',
    'MainThread');
  RegisterFastCanvas('fcheapsleep', 'FastCanvas with the memory manager sleeping on lock contention (RTL default)',
    'HeapSleep');
end;

initialization
  RegisterFastCanvases;
end.
