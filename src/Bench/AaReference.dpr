program AaReference;

{ Reference image for the "aa" scene (Bench.Scenes.AA).

  Draws DrawAaPattern with the Skia raster canvas into offscreen bitmaps K times larger than the
  screenshot, averages every K x K block (box filter) and saves a PNG of the screenshot size. The
  supersampled image is rendered in chunks, so it never has to fit into one bitmap.

  The benchmark control is the full client area in logical units: logical (x, y) is physical
  (x * scale, y * scale), so the supersampled canvas uses the matrix scale * K followed by the chunk
  offset. The time is the one of the benchmark screenshot (frame / fps). Bitmaps are sampled
  nearest-neighbour (canvas quality HighPerformance); after the box filter this is the exact area
  average of the bitmap pixels. The box filter averages sRGB values (as coverage blending in sRGB
  space does) unless --gamma=linear.

  Also writes <out>.regions.csv: bands, sections and crop centres of the pattern in physical
  pixels, for tools\compare-aa.ps1. }

{$APPTYPE CONSOLE}
{$R WinApp.res}

uses
  System.SysUtils,
  System.StrUtils,
  System.Types,
  System.UITypes,
  System.Math,
  System.Math.Vectors,
  System.Classes,
  System.IOUtils,
  System.Diagnostics,
  FMX.Types,
  FMX.Graphics,
  FMX.Forms,
  FMX.Skia,
  Bench.Config in 'Bench.Config.pas',
  Bench.Scenes in 'Bench.Scenes.pas',
  Bench.Scenes.AA in 'Bench.Scenes.AA.pas';

type
  ERefConfig = class(Exception);

  TRefConfig = record
    Width, Height: Integer;  // physical pixels (the screenshot size)
    Scale: Single;           // monitor scale of the benchmark window
    K: Integer;              // supersampling factor per axis
    ChunkPx: Integer;        // side of the supersampled chunk bitmap
    Frame: Integer;
    Fps: Integer;
    Tiles: Integer;
    Linear: Boolean;
    OutPng: string;
  end;

const
  UsageText =
    'AaReference --scale=<s> --out=<png> [options]' + sLineBreak +
    '  --size=WxH     screenshot size, physical pixels, default 1920x1080' + sLineBreak +
    '  --scale=<s>    monitor scale of the benchmark run (CSV column "scale"), required' + sLineBreak +
    '  --k=<int>      supersampling per axis, default 8' + sLineBreak +
    '  --chunk=<px>   supersampled chunk side, default 2048' + sLineBreak +
    '  --frame=<int>  frame of the screenshot, default 60' + sLineBreak +
    '  --fps=<int>    fps of the benchmark run, default 240 (time = frame / fps)' + sLineBreak +
    '  --n=<int>      tiles (scene N), default 4' + sLineBreak +
    '  --gamma=srgb|linear  space of the box filter, default srgb' + sLineBreak +
    '  --out=<png>    output image; regions go to <out without .png>.regions.csv' + sLineBreak;

function ParseInt(const AName, AValue: string; const AMin: Integer): Integer;
begin
  if not TryStrToInt(AValue, Result) or (Result < AMin) then
    raise ERefConfig.CreateFmt('Invalid value for --%s: "%s"', [AName, AValue]);
end;

function ParseCommandLine: TRefConfig;
var
  I, P: Integer;
  Arg, Name, Value: string;
  Parts: TArray<string>;
  S: Double;
begin
  Result := Default(TRefConfig);
  Result.Width := 1920;
  Result.Height := 1080;
  Result.K := 8;
  Result.ChunkPx := 2048;
  Result.Frame := 60;
  Result.Fps := 240;
  Result.Tiles := 4;
  for I := 1 to ParamCount do
  begin
    Arg := ParamStr(I);
    if not Arg.StartsWith('--') then
      raise ERefConfig.CreateFmt('Unexpected argument "%s"', [Arg]);
    Arg := Arg.Substring(2);
    P := Arg.IndexOf('=');
    if P < 0 then
      raise ERefConfig.CreateFmt('Option --%s needs a value', [Arg]);
    Name := Arg.Substring(0, P).ToLower;
    Value := Arg.Substring(P + 1);
    if Name = 'size' then
    begin
      Parts := Value.ToLower.Split(['x']);
      if (Length(Parts) <> 2) or not TryStrToInt(Parts[0], Result.Width) or
        not TryStrToInt(Parts[1], Result.Height) or (Result.Width <= 0) or (Result.Height <= 0) then
        raise ERefConfig.CreateFmt('Invalid value for --size: "%s"', [Value]);
    end
    else if Name = 'scale' then
    begin
      if not TryStrToFloat(Value, S, TFormatSettings.Invariant) or (S <= 0) then
        raise ERefConfig.CreateFmt('Invalid value for --scale: "%s"', [Value]);
      Result.Scale := S;
    end
    else if Name = 'k' then
      Result.K := ParseInt(Name, Value, 1)
    else if Name = 'chunk' then
      Result.ChunkPx := ParseInt(Name, Value, 64)
    else if Name = 'frame' then
      Result.Frame := ParseInt(Name, Value, 0)
    else if Name = 'fps' then
      Result.Fps := ParseInt(Name, Value, 1)
    else if Name = 'n' then
      Result.Tiles := ParseInt(Name, Value, 1)
    else if Name = 'gamma' then
    begin
      if SameText(Value, 'srgb') then
        Result.Linear := False
      else if SameText(Value, 'linear') then
        Result.Linear := True
      else
        raise ERefConfig.CreateFmt('Invalid value for --gamma: "%s"', [Value]);
    end
    else if Name = 'out' then
      Result.OutPng := Value
    else
      raise ERefConfig.CreateFmt('Unknown option --%s', [Name]);
  end;
  if Result.Scale = 0 then
    raise ERefConfig.Create('--scale is required');
  if Result.OutPng = '' then
    raise ERefConfig.Create('--out is required');
  if Result.ChunkPx < Result.K then
    raise ERefConfig.Create('--chunk must not be smaller than --k');
end;

var
  SrgbToLinear: array[Byte] of Double;

function LinearToSrgb(const AValue: Double): Byte;
var
  V: Double;
begin
  if AValue <= 0.0031308 then
    V := AValue * 12.92
  else
    V := 1.055 * Power(AValue, 1 / 2.4) - 0.055;
  Result := EnsureRange(Round(V * 255), 0, 255);
end;

procedure InitGamma;
var
  I: Integer;
  C: Double;
begin
  for I := 0 to 255 do
  begin
    C := I / 255;
    if C <= 0.04045 then
      SrgbToLinear[I] := C / 12.92
    else
      SrgbToLinear[I] := Power((C + 0.055) / 1.055, 2.4);
  end;
end;

{ Renders the supersampled pattern chunk by chunk into AOut (AConfig.Width * AConfig.Height). }
procedure RenderReference(const AConfig: TRefConfig; var AOut: TArray<TAlphaColor>);
var
  Chunk: TBitmap;
  Data: TBitmapData;
  Bounds: TRectF;
  Time: Double;
  OutChunk, CX, CY, CW, CH, X, Y, SX, SY, Idx, Chunks: Integer;
  Line: TArray<TAlphaColor>;
  SumR, SumG, SumB: TArray<Double>;
  C: TAlphaColor;
  N: Double;
  Rec: TAlphaColorRec;
begin
  Bounds := TRectF.Create(0, 0, AConfig.Width / AConfig.Scale, AConfig.Height / AConfig.Scale);
  Time := AConfig.Frame / AConfig.Fps;
  OutChunk := AConfig.ChunkPx div AConfig.K;
  N := Sqr(AConfig.K);
  SetLength(AOut, AConfig.Width * AConfig.Height);
  SetLength(Line, OutChunk * AConfig.K);
  SetLength(SumR, OutChunk);
  SetLength(SumG, OutChunk);
  SetLength(SumB, OutChunk);
  Chunks := 0;
  Chunk := TBitmap.Create(OutChunk * AConfig.K, OutChunk * AConfig.K);
  try
    // Nearest-neighbour bitmap sampling; Skia anti-aliases geometry at every quality.
    Chunk.CanvasQuality := TCanvasQuality.HighPerformance;
    Writeln(Format('canvas=%s chunk=%dx%d k=%d time=%.6f tiles=%d', [Chunk.Canvas.ClassName, Chunk.Width,
      Chunk.Height, AConfig.K, Time, AConfig.Tiles], TFormatSettings.Invariant));
    CY := 0;
    while CY < AConfig.Height do
    begin
      CH := Min(OutChunk, AConfig.Height - CY);
      CX := 0;
      while CX < AConfig.Width do
      begin
        CW := Min(OutChunk, AConfig.Width - CX);
        if not Chunk.Canvas.BeginScene then
          raise Exception.Create('BeginScene failed');
        try
          Chunk.Canvas.Clear(TAlphaColors.White);
          Chunk.Canvas.SetMatrix(TMatrix.CreateScaling(AConfig.Scale * AConfig.K, AConfig.Scale * AConfig.K) *
            TMatrix.CreateTranslation(-CX * AConfig.K, -CY * AConfig.K));
          DrawAaPattern(Chunk.Canvas, Bounds, Time, AConfig.Tiles, AConfig.Scale);
        finally
          Chunk.Canvas.EndScene;
        end;
        Inc(Chunks);

        if not Chunk.Map(TMapAccess.Read, Data) then
          raise Exception.Create('Cannot map the chunk bitmap');
        try
          for Y := 0 to CH - 1 do
          begin
            FillChar(SumR[0], CW * SizeOf(Double), 0);
            FillChar(SumG[0], CW * SizeOf(Double), 0);
            FillChar(SumB[0], CW * SizeOf(Double), 0);
            for SY := 0 to AConfig.K - 1 do
            begin
              ScanlineToAlphaColor(Data.GetScanline(Y * AConfig.K + SY), @Line[0], CW * AConfig.K, Data.PixelFormat);
              for X := 0 to CW - 1 do
                for SX := 0 to AConfig.K - 1 do
                begin
                  Rec := TAlphaColorRec(Line[X * AConfig.K + SX]);
                  if AConfig.Linear then
                  begin
                    SumR[X] := SumR[X] + SrgbToLinear[Rec.R];
                    SumG[X] := SumG[X] + SrgbToLinear[Rec.G];
                    SumB[X] := SumB[X] + SrgbToLinear[Rec.B];
                  end
                  else
                  begin
                    SumR[X] := SumR[X] + Rec.R;
                    SumG[X] := SumG[X] + Rec.G;
                    SumB[X] := SumB[X] + Rec.B;
                  end;
                end;
            end;
            for X := 0 to CW - 1 do
            begin
              Rec.A := $FF;
              if AConfig.Linear then
              begin
                Rec.R := LinearToSrgb(SumR[X] / N);
                Rec.G := LinearToSrgb(SumG[X] / N);
                Rec.B := LinearToSrgb(SumB[X] / N);
              end
              else
              begin
                Rec.R := EnsureRange(Round(SumR[X] / N), 0, 255);
                Rec.G := EnsureRange(Round(SumG[X] / N), 0, 255);
                Rec.B := EnsureRange(Round(SumB[X] / N), 0, 255);
              end;
              C := TAlphaColor(Rec);
              Idx := (CY + Y) * AConfig.Width + CX + X;
              AOut[Idx] := C;
            end;
          end;
        finally
          Chunk.Unmap(Data);
        end;
        Inc(CX, OutChunk);
      end;
      Inc(CY, OutChunk);
    end;
  finally
    Chunk.Free;
  end;
  Writeln(Format('chunks=%d', [Chunks]));
end;

procedure SavePng(const AConfig: TRefConfig; const APixels: TArray<TAlphaColor>);
var
  Bmp: TBitmap;
  Data: TBitmapData;
  Y: Integer;
  Dir: string;
begin
  Bmp := TBitmap.Create(AConfig.Width, AConfig.Height);
  try
    if not Bmp.Map(TMapAccess.Write, Data) then
      raise Exception.Create('Cannot map the output bitmap');
    try
      for Y := 0 to AConfig.Height - 1 do
        AlphaColorToScanline(@APixels[Y * AConfig.Width], Data.GetScanline(Y), AConfig.Width, Data.PixelFormat);
    finally
      Bmp.Unmap(Data);
    end;
    Dir := TPath.GetDirectoryName(TPath.GetFullPath(AConfig.OutPng));
    if (Dir <> '') and not TDirectory.Exists(Dir) then
      TDirectory.CreateDirectory(Dir);
    Bmp.SaveToFile(AConfig.OutPng);
  finally
    Bmp.Free;
  end;
end;

function RegionsFileName(const AConfig: TRefConfig): string;
begin
  Result := TPath.ChangeExtension(AConfig.OutPng, '.regions.csv');
end;

procedure SaveRegions(const AConfig: TRefConfig);
var
  Regions: TArray<TAaRegion>;
  R: TAaRegion;
  Lines: TStringList;
  F: TFormatSettings;
  S: Single;
begin
  F := TFormatSettings.Invariant;
  S := AConfig.Scale;
  Regions := AaPatternRegions(TRectF.Create(0, 0, AConfig.Width / S, AConfig.Height / S), AConfig.Tiles);
  Lines := TStringList.Create;
  try
    Lines.Add('tile,kind,name,x,y,w,h');
    for R in Regions do
      Lines.Add(Format('%d,%s,%s,%.2f,%.2f,%.2f,%.2f', [R.Tile, AaRegionKindName(R.Kind), R.Name,
        R.Rect.Left * S, R.Rect.Top * S, R.Rect.Width * S, R.Rect.Height * S], F));
    Lines.WriteBOM := False;
    Lines.SaveToFile(RegionsFileName(AConfig), TEncoding.ASCII);
  finally
    Lines.Free;
  end;
end;

var
  Config: TRefConfig;
  Pixels: TArray<TAlphaColor>;
  Watch: TStopwatch;
begin
  try
    Config := ParseCommandLine;
  except
    on E: ERefConfig do
    begin
      Writeln(ErrOutput, 'ERROR: ' + E.Message);
      Writeln(ErrOutput, UsageText);
      ExitCode := 2;
      Exit;
    end;
  end;
  try
    // Skia raster, chosen as in Bench.Canvases.Builtin (docs/BENCHMARKS.md).
    GlobalUseSkia := True;
    GlobalUseSkiaRasterWhenAvailable := True;
    Application.Initialize;
    InitGamma;
    Watch := TStopwatch.StartNew;
    try
      RenderReference(Config, Pixels);
      SavePng(Config, Pixels);
      SaveRegions(Config);
    finally
      FreeAaPatternResources;
    end;
    Writeln(Format('%s %dx%d scale=%.3f gamma=%s, %.1f s', [Config.OutPng, Config.Width, Config.Height, Config.Scale,
      IfThen(Config.Linear, 'linear', 'srgb'), Watch.Elapsed.TotalSeconds], TFormatSettings.Invariant));
    Writeln('regions: ' + RegionsFileName(Config));
  except
    on E: Exception do
    begin
      Writeln(ErrOutput, 'ERROR: ' + E.ClassName + ': ' + E.Message);
      ExitCode := 1;
    end;
  end;
end.
