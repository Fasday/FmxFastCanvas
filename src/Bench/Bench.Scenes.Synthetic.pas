unit Bench.Scenes.Synthetic;

{ Synthetic scenes: primitives drawn directly in Paint of one full-client control. }

interface

implementation

uses
  System.Types, System.UITypes, FMX.Types, FMX.Graphics, Bench.Config, Bench.Scenes;

type
  TRectsScene = class(TBenchPaintScene)
  private
    FItems: TArray<TMovingItem>;
  protected
    procedure Draw(const ACanvas: TCanvas; const ARect: TRectF); override;
  public
    class function Name: string; override;
    class function Description: string; override;
    class function DefaultN(const APreset: TBenchPreset): Integer; override;
    procedure Setup; override;
  end;

{ TRectsScene }

class function TRectsScene.Name: string;
begin
  Result := 'rects';
end;

class function TRectsScene.Description: string;
begin
  Result := 'FillRect with a solid brush, N rectangles 8..96 px';
end;

class function TRectsScene.DefaultN(const APreset: TBenchPreset): Integer;
begin
  // D2D throughput frame: ~2 / ~8 / ~20 ms (0.55 us per rect, measured 2026-10-06).
  case APreset of
    TBenchPreset.Light: Result := 4000;
    TBenchPreset.Heavy: Result := 36000;
  else
    Result := 16000;
  end;
end;

procedure TRectsScene.Setup;
begin
  inherited;
  GenerateMovingItems(FItems, N, 1, 8, 96);
end;

procedure TRectsScene.Draw(const ACanvas: TCanvas; const ARect: TRectF);
var
  I: Integer;
begin
  ACanvas.Fill.Kind := TBrushKind.Solid;
  for I := 0 to High(FItems) do
  begin
    ACanvas.Fill.Color := FItems[I].Color;
    ACanvas.FillRect(MovingItemRect(FItems[I], ARect, Time), 0, 0, [], 1);
  end;
end;

initialization
  RegisterBenchScene(TRectsScene);
end.
