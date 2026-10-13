unit Common.Csv;

{ Ordered name/value rows written as CSV (UTF-8 without BOM, LF, comma, invariant numbers). }

interface

uses
  System.SysUtils, System.Generics.Collections;

type
  TCsvRow = class
  private
    FNames: TList<string>;
    FValues: TList<string>;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Add(const AName, AValue: string); overload;
    procedure Add(const AName: string; const AValue: Integer); overload;
    procedure Add(const AName: string; const AValue: Int64); overload;
    procedure Add(const AName: string; const AValue: Double; const ADecimals: Integer = 3); overload;
    procedure AddBool(const AName: string; const AValue: Boolean);
    function HeaderLine: string;
    function ValueLine: string;
    function IndexOf(const AName: string): Integer;
    function ValueOf(const AName: string): string;
    property Names: TList<string> read FNames;
    property Values: TList<string> read FValues;
  end;

function CsvEscape(const AValue: string): string;
function CsvFloat(const AValue: Double; const ADecimals: Integer = 3): string;

/// <summary>Appends the row. Writes the header if the file is new or empty. Raises if the
/// existing header differs, so that rows of different schemas are never mixed.</summary>
procedure AppendCsvRow(const AFileName: string; const ARow: TCsvRow);

/// <summary>Writes a whole table (header + rows) to a new file.</summary>
procedure WriteCsvTable(const AFileName: string; const AHeader: string; const ALines: TArray<string>);

var
  CsvFormat: TFormatSettings;

implementation

uses
  System.Classes, System.IOUtils, System.Math;

function CsvEscape(const AValue: string): string;
begin
  if AValue.IndexOfAny([',', '"', #10, #13]) >= 0 then
    Result := '"' + AValue.Replace('"', '""') + '"'
  else
    Result := AValue;
end;

function CsvFloat(const AValue: Double; const ADecimals: Integer): string;
begin
  if IsNan(AValue) or IsInfinite(AValue) then
    Result := ''
  else
    Result := FloatToStrF(AValue, ffFixed, 18, ADecimals, CsvFormat);
end;

{ TCsvRow }

constructor TCsvRow.Create;
begin
  inherited;
  FNames := TList<string>.Create;
  FValues := TList<string>.Create;
end;

destructor TCsvRow.Destroy;
begin
  FValues.Free;
  FNames.Free;
  inherited;
end;

procedure TCsvRow.Add(const AName, AValue: string);
begin
  if IndexOf(AName) >= 0 then
    raise EArgumentException.CreateFmt('Duplicate CSV column "%s"', [AName]);
  FNames.Add(AName);
  FValues.Add(AValue);
end;

procedure TCsvRow.Add(const AName: string; const AValue: Integer);
begin
  Add(AName, IntToStr(AValue));
end;

procedure TCsvRow.Add(const AName: string; const AValue: Int64);
begin
  Add(AName, IntToStr(AValue));
end;

procedure TCsvRow.Add(const AName: string; const AValue: Double; const ADecimals: Integer);
begin
  Add(AName, CsvFloat(AValue, ADecimals));
end;

procedure TCsvRow.AddBool(const AName: string; const AValue: Boolean);
begin
  if AValue then
    Add(AName, '1')
  else
    Add(AName, '0');
end;

function TCsvRow.HeaderLine: string;
var
  I: Integer;
  SB: TStringBuilder;
begin
  SB := TStringBuilder.Create;
  try
    for I := 0 to FNames.Count - 1 do
    begin
      if I > 0 then
        SB.Append(',');
      SB.Append(CsvEscape(FNames[I]));
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

function TCsvRow.ValueLine: string;
var
  I: Integer;
  SB: TStringBuilder;
begin
  SB := TStringBuilder.Create;
  try
    for I := 0 to FValues.Count - 1 do
    begin
      if I > 0 then
        SB.Append(',');
      SB.Append(CsvEscape(FValues[I]));
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

function TCsvRow.IndexOf(const AName: string): Integer;
begin
  Result := FNames.IndexOf(AName);
end;

function TCsvRow.ValueOf(const AName: string): string;
var
  I: Integer;
begin
  I := IndexOf(AName);
  if I >= 0 then
    Result := FValues[I]
  else
    Result := '';
end;

function ReadFirstLine(const AFileName: string): string;
var
  Reader: TStreamReader;
begin
  Reader := TStreamReader.Create(AFileName, TEncoding.UTF8, True);
  try
    if Reader.EndOfStream then
      Result := ''
    else
      Result := Reader.ReadLine;
  finally
    Reader.Free;
  end;
end;

procedure AppendText(const AFileName, AText: string; const ACreate: Boolean);
var
  Stream: TFileStream;
  Bytes: TBytes;
begin
  if ACreate then
    Stream := TFileStream.Create(AFileName, fmCreate or fmShareDenyWrite)
  else
  begin
    Stream := TFileStream.Create(AFileName, fmOpenReadWrite or fmShareDenyWrite);
    Stream.Seek(0, soEnd);
  end;
  try
    Bytes := TEncoding.UTF8.GetBytes(AText);
    if Length(Bytes) > 0 then
      Stream.WriteBuffer(Bytes[0], Length(Bytes));
  finally
    Stream.Free;
  end;
end;

procedure EnsureDir(const AFileName: string);
var
  Dir: string;
begin
  Dir := TPath.GetDirectoryName(TPath.GetFullPath(AFileName));
  if (Dir <> '') and not TDirectory.Exists(Dir) then
    TDirectory.CreateDirectory(Dir);
end;

procedure AppendCsvRow(const AFileName: string; const ARow: TCsvRow);
var
  Header, Existing: string;
begin
  EnsureDir(AFileName);
  Header := ARow.HeaderLine;
  if TFile.Exists(AFileName) and (TFile.GetSize(AFileName) > 0) then
  begin
    Existing := ReadFirstLine(AFileName);
    if Existing <> Header then
      raise Exception.CreateFmt('CSV header of "%s" differs from the current schema; ' +
        'use a new output file', [AFileName]);
    AppendText(AFileName, ARow.ValueLine + #10, False);
  end
  else
    AppendText(AFileName, Header + #10 + ARow.ValueLine + #10, True);
end;

procedure WriteCsvTable(const AFileName: string; const AHeader: string; const ALines: TArray<string>);
var
  SB: TStringBuilder;
  Line: string;
begin
  EnsureDir(AFileName);
  SB := TStringBuilder.Create;
  try
    SB.Append(AHeader).Append(#10);
    for Line in ALines do
      SB.Append(Line).Append(#10);
    AppendText(AFileName, SB.ToString, True);
  finally
    SB.Free;
  end;
end;

initialization
  CsvFormat := TFormatSettings.Invariant;
end.
