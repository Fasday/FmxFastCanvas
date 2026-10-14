unit Bench.Config;

{ Command line of the benchmark. All options use the form --name=value; flags are --name. }

interface

uses
  System.SysUtils, FMX.Graphics;

type
  TBenchMode = (Throughput, Paced);
  TBenchPreset = (Light, Medium, Heavy);
  TVkFifoOption = (Auto, Off, On);

  TBenchConfig = record
    CanvasName: string;
    SceneName: string;
    N: Integer;              // 0 = scene default for the preset
    Preset: TBenchPreset;
    Width, Height: Integer;  // client area, physical pixels
    Monitor: string;         // primary | secondary | 1-based index | device name
    Mode: TBenchMode;
    Fps: Integer;            // GlobalPreferredFramesPerSecond
    WarmupSec: Double;
    WarmupMinFrames: Integer;
    DurationSec: Double;
    OutCsv: string;
    FramesCsv: string;
    Screenshot: string;
    ScreenshotFrame: Integer; // animation frame the screenshot shows (default 60)
    Profile: string;         // sampling profile of the measured frames (Common.Profiler)
    ProfileThread: string;   // main | render
    ProfileIntervalUs: Integer;
    DeviceLossSec: Double;   // simulated device loss every so many seconds of warmup and measurement (0 = off)
    Transparency: Boolean;
    Quality: TCanvasQuality;
    Split: Boolean;          // wrap PaintRects in our own BeginScene/EndScene
    VkFifo: TVkFifoOption;
    CanvasOpts: string;      // canvas-specific switches, e.g. "-PathCache,+AllowTearing"
    Tag: string;
    ListOnly: Boolean;
    HelpOnly: Boolean;
    CommandLine: string;
  end;

  EBenchConfig = class(Exception);

function ParseCommandLine: TBenchConfig;
function ModeName(const AMode: TBenchMode): string;
function PresetName(const APreset: TBenchPreset): string;
function QualityName(const AQuality: TCanvasQuality): string;
function UsageText: string;

implementation

{$IFDEF MSWINDOWS}
uses
  Winapi.Windows;
{$ENDIF}

/// <summary>The command line as one string (off Windows: the arguments joined by spaces).</summary>
function CommandLineText: string;
{$IFDEF MSWINDOWS}
begin
  Result := string(GetCommandLine);
end;
{$ELSE}
var
  I: Integer;
begin
  Result := ParamStr(0);
  for I := 1 to ParamCount do
    Result := Result + ' ' + ParamStr(I);
end;
{$ENDIF}

function ModeName(const AMode: TBenchMode): string;
begin
  case AMode of
    TBenchMode.Throughput: Result := 'throughput';
  else
    Result := 'paced';
  end;
end;

function PresetName(const APreset: TBenchPreset): string;
begin
  case APreset of
    TBenchPreset.Light: Result := 'light';
    TBenchPreset.Heavy: Result := 'heavy';
  else
    Result := 'medium';
  end;
end;

function QualityName(const AQuality: TCanvasQuality): string;
begin
  case AQuality of
    TCanvasQuality.HighPerformance: Result := 'perf';
    TCanvasQuality.HighQuality: Result := 'high';
  else
    Result := 'default';
  end;
end;

function UsageText: string;
begin
  Result :=
    'FmxCanvasBench [options]' + sLineBreak +
    '  --canvas=<name>         canvas (see --list), default d2d' + sLineBreak +
    '  --scene=<name>          scene (see --list), default rects' + sLineBreak +
    '  --preset=light|medium|heavy  scene complexity preset, default medium' + sLineBreak +
    '  --n=<int>               scene complexity, overrides the preset' + sLineBreak +
    '  --size=WxH              client area in physical pixels, default 1920x1080' + sLineBreak +
    '  --monitor=<m>           primary|secondary|<1-based index>|DISPLAYn, default primary' + sLineBreak +
    '  --mode=throughput|paced default throughput' + sLineBreak +
    '  --fps=<int>             GlobalPreferredFramesPerSecond, default 240' + sLineBreak +
    '  --warmup=<sec>          default 2 (and at least 120 frames)' + sLineBreak +
    '  --duration=<sec>        measured time, default 5' + sLineBreak +
    '  --quality=default|perf|high  TForm.Quality, default default' + sLineBreak +
    '  --transparency          form with Transparency = True' + sLineBreak +
    '  --split=0|1             split frame into record/EndScene, default 1' + sLineBreak +
    '  --vkfifo=auto|0|1       GlobalUseSkiaVulkanFifoKHR; auto = 1 for paced, 0 for throughput' + sLineBreak +
    '  --copts=<list>          options of our canvases: all|none|+Name|-Name, comma separated' + sLineBreak +
    '  --out=<csv>             append one result row' + sLineBreak +
    '  --frames=<csv>          write per-frame samples' + sLineBreak +
    '  --screenshot=<png>      capture the window after the run' + sLineBreak +
    '  --shot-frame=<n>        animation frame of the screenshot (default 60)' + sLineBreak +
    '  --profile=<txt>         sample the stacks of a thread during the measurement (tools\profile-report.ps1)' + sLineBreak +
    '  --profile-thread=main|render   thread to sample (default main)' + sLineBreak +
    '  --profile-interval=<us> sampling interval (default 250)' + sLineBreak +
    '  --device-loss=<sec>     simulate a graphics device loss every <sec> seconds (canvases that support it)' + sLineBreak +
    '  --tag=<text>            free label stored in the CSV' + sLineBreak +
    '  --list                  list canvases and scenes' + sLineBreak;
end;

function ParseSize(const AValue: string; out AWidth, AHeight: Integer): Boolean;
var
  Parts: TArray<string>;
begin
  Parts := AValue.ToLower.Split(['x']);
  Result := (Length(Parts) = 2) and TryStrToInt(Parts[0], AWidth) and TryStrToInt(Parts[1], AHeight) and
    (AWidth > 0) and (AHeight > 0);
end;

function ParseFloat(const AName, AValue: string): Double;
begin
  if not TryStrToFloat(AValue, Result, TFormatSettings.Invariant) or (Result < 0) then
    raise EBenchConfig.CreateFmt('Invalid value for --%s: "%s"', [AName, AValue]);
end;

function ParseInt(const AName, AValue: string; const AMin: Integer): Integer;
begin
  if not TryStrToInt(AValue, Result) or (Result < AMin) then
    raise EBenchConfig.CreateFmt('Invalid value for --%s: "%s"', [AName, AValue]);
end;

function ParseBool(const AName, AValue: string): Boolean;
begin
  if (AValue = '') or (AValue = '1') or SameText(AValue, 'true') or SameText(AValue, 'on') then
    Result := True
  else if (AValue = '0') or SameText(AValue, 'false') or SameText(AValue, 'off') then
    Result := False
  else
    raise EBenchConfig.CreateFmt('Invalid value for --%s: "%s"', [AName, AValue]);
end;

function ParseCommandLine: TBenchConfig;
var
  I, P: Integer;
  Arg, Name, Value: string;
begin
  Result := Default(TBenchConfig);
  Result.ProfileThread := 'main';
  Result.ProfileIntervalUs := 250;
  Result.CanvasName := 'd2d';
  Result.SceneName := 'rects';
  Result.Preset := TBenchPreset.Medium;
  Result.Width := 1920;
  Result.Height := 1080;
  Result.Monitor := 'primary';
  Result.Mode := TBenchMode.Throughput;
  Result.Fps := 240;
  Result.ScreenshotFrame := 60;
  Result.WarmupSec := 2;
  Result.WarmupMinFrames := 120;
  Result.DurationSec := 5;
  Result.Quality := TCanvasQuality.SystemDefault;
  Result.Split := True;
  Result.VkFifo := TVkFifoOption.Auto;
  Result.CommandLine := CommandLineText;

  for I := 1 to ParamCount do
  begin
    Arg := ParamStr(I);
    if not Arg.StartsWith('--') then
      raise EBenchConfig.CreateFmt('Unexpected argument "%s"', [Arg]);
    Arg := Arg.Substring(2);
    P := Arg.IndexOf('=');
    if P >= 0 then
    begin
      Name := Arg.Substring(0, P).ToLower;
      Value := Arg.Substring(P + 1);
    end
    else
    begin
      Name := Arg.ToLower;
      Value := '';
    end;

    if Name = 'canvas' then
      Result.CanvasName := Value.ToLower
    else if Name = 'scene' then
      Result.SceneName := Value.ToLower
    else if Name = 'n' then
      Result.N := ParseInt(Name, Value, 1)
    else if Name = 'preset' then
    begin
      if SameText(Value, 'light') then
        Result.Preset := TBenchPreset.Light
      else if SameText(Value, 'medium') then
        Result.Preset := TBenchPreset.Medium
      else if SameText(Value, 'heavy') then
        Result.Preset := TBenchPreset.Heavy
      else
        raise EBenchConfig.CreateFmt('Invalid value for --preset: "%s"', [Value]);
    end
    else if Name = 'size' then
    begin
      if not ParseSize(Value, Result.Width, Result.Height) then
        raise EBenchConfig.CreateFmt('Invalid value for --size: "%s"', [Value]);
    end
    else if Name = 'monitor' then
      Result.Monitor := Value
    else if Name = 'mode' then
    begin
      if SameText(Value, 'throughput') then
        Result.Mode := TBenchMode.Throughput
      else if SameText(Value, 'paced') then
        Result.Mode := TBenchMode.Paced
      else
        raise EBenchConfig.CreateFmt('Invalid value for --mode: "%s"', [Value]);
    end
    else if Name = 'fps' then
      Result.Fps := ParseInt(Name, Value, 1)
    else if Name = 'warmup' then
      Result.WarmupSec := ParseFloat(Name, Value)
    else if Name = 'duration' then
    begin
      Result.DurationSec := ParseFloat(Name, Value);
      if Result.DurationSec <= 0 then
        raise EBenchConfig.Create('--duration must be positive');
    end
    else if Name = 'quality' then
    begin
      if SameText(Value, 'default') then
        Result.Quality := TCanvasQuality.SystemDefault
      else if SameText(Value, 'perf') then
        Result.Quality := TCanvasQuality.HighPerformance
      else if SameText(Value, 'high') then
        Result.Quality := TCanvasQuality.HighQuality
      else
        raise EBenchConfig.CreateFmt('Invalid value for --quality: "%s"', [Value]);
    end
    else if Name = 'transparency' then
      Result.Transparency := ParseBool(Name, Value)
    else if Name = 'split' then
      Result.Split := ParseBool(Name, Value)
    else if Name = 'vkfifo' then
    begin
      if SameText(Value, 'auto') then
        Result.VkFifo := TVkFifoOption.Auto
      else if ParseBool(Name, Value) then
        Result.VkFifo := TVkFifoOption.On
      else
        Result.VkFifo := TVkFifoOption.Off;
    end
    else if Name = 'copts' then
      Result.CanvasOpts := Value
    else if Name = 'out' then
      Result.OutCsv := Value
    else if Name = 'frames' then
      Result.FramesCsv := Value
    else if Name = 'screenshot' then
      Result.Screenshot := Value
    else if Name = 'shot-frame' then
      Result.ScreenshotFrame := ParseInt(Name, Value, 0)
    else if Name = 'profile' then
      Result.Profile := Value
    else if Name = 'profile-thread' then
      Result.ProfileThread := Value
    else if Name = 'profile-interval' then
      Result.ProfileIntervalUs := StrToInt(Value)
    else if Name = 'device-loss' then
      Result.DeviceLossSec := StrToFloat(Value, TFormatSettings.Invariant)
    else if Name = 'tag' then
      Result.Tag := Value
    else if Name = 'list' then
      Result.ListOnly := True
    else if (Name = 'help') or (Name = '?') then
      Result.HelpOnly := True
    else
      raise EBenchConfig.CreateFmt('Unknown option --%s', [Name]);
  end;
end;

end.
