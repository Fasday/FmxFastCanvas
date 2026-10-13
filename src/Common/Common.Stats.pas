unit Common.Stats;

{ Descriptive statistics over sample arrays. Percentiles use the nearest-rank method. }

interface

type
  TSampleStats = record
    Count: Integer;
    Min, Max, Mean, StdDev: Double;
    Median, P95, P99: Double;
  end;

function ComputeStats(const AValues: TArray<Double>): TSampleStats;
/// <summary>Share (0..1) of values that are less than or equal to AThreshold.</summary>
function ShareAtMost(const AValues: TArray<Double>; const AThreshold: Double): Double;
/// <summary>Number of values strictly greater than AThreshold.</summary>
function CountAbove(const AValues: TArray<Double>; const AThreshold: Double): Integer;

implementation

uses
  System.Math, System.Generics.Collections;

function Percentile(const ASorted: TArray<Double>; const AP: Double): Double;
var
  Rank: Integer;
begin
  Rank := Ceil(AP * Length(ASorted));
  if Rank < 1 then
    Rank := 1;
  if Rank > Length(ASorted) then
    Rank := Length(ASorted);
  Result := ASorted[Rank - 1];
end;

function ComputeStats(const AValues: TArray<Double>): TSampleStats;
var
  Sorted: TArray<Double>;
  I, N: Integer;
  Sum, SumSq, D: Double;
begin
  Result := Default(TSampleStats);
  N := Length(AValues);
  Result.Count := N;
  if N = 0 then
    Exit;
  Sorted := Copy(AValues);
  TArray.Sort<Double>(Sorted);
  Result.Min := Sorted[0];
  Result.Max := Sorted[N - 1];
  Sum := 0;
  for I := 0 to N - 1 do
    Sum := Sum + Sorted[I];
  Result.Mean := Sum / N;
  SumSq := 0;
  for I := 0 to N - 1 do
  begin
    D := Sorted[I] - Result.Mean;
    SumSq := SumSq + D * D;
  end;
  if N > 1 then
    Result.StdDev := Sqrt(SumSq / (N - 1));
  if Odd(N) then
    Result.Median := Sorted[N div 2]
  else
    Result.Median := (Sorted[N div 2 - 1] + Sorted[N div 2]) / 2;
  Result.P95 := Percentile(Sorted, 0.95);
  Result.P99 := Percentile(Sorted, 0.99);
end;

function ShareAtMost(const AValues: TArray<Double>; const AThreshold: Double): Double;
var
  I, Hits: Integer;
begin
  if Length(AValues) = 0 then
    Exit(0);
  Hits := 0;
  for I := 0 to High(AValues) do
    if AValues[I] <= AThreshold then
      Inc(Hits);
  Result := Hits / Length(AValues);
end;

function CountAbove(const AValues: TArray<Double>; const AThreshold: Double): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(AValues) do
    if AValues[I] > AThreshold then
      Inc(Result);
end;

end.
