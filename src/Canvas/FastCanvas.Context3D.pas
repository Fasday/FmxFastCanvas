unit FastCanvas.Context3D;

{ Own TContext3D of FastCanvas (stage 5): the part that does not depend on the graphics API. Devices derive from
  TFastContext3D (FastCanvas.Context3D11 for Direct3D 11; Direct3D 12 later).

  What FMX asks of a 3D context (FMX.Types3D.pas:625-856): render into a window (TForm3D) or into a TTexture
  (TViewport3D, the filters of effects); set the pipeline state piece by piece (TContextState, stencil, scissor);
  set a vertex and a pixel shader of its own (TContextShader with bytecode per architecture) and their variables by
  name; draw vertex and index arrays it passes by pointer on every draw; manage textures.

  Done here, once for every device:
  - Shaders: the bytecode a Direct3D device takes (FMX ships DX11_level_9 for Windows; DX11 and DX10 are taken when
    present), the variables with their constant buffer offsets, the constant buffer size. A variable is found by
    comparing the string pointer first: FMX passes the same string constants (material properties) every time.
    (The stock DX11 context copies the whole shader source record and compares names with SameText for every
    variable of every draw: 36 % of the frame of the viewport3d scene, measured 2026-10-07.)
  - The constant buffer contents of both stages and their dirty flags.
  - The pipeline state FMX sets, as a small record the devices use as a cache key.
  - Texture units: the device texture objects set through texture variables.
  - Vertex declarations: the input elements with their DXGI formats, and a hash for layout caches. }

interface

{$SCOPEDENUMS ON}

uses
  System.Types, System.UITypes, System.SysUtils, System.Math, System.Math.Vectors, System.Generics.Collections,
  FMX.Types, FMX.Types3D, FMX.Graphics;

type
  /// <summary>Values of FMX's standard materials (TColorMaterial, TTextureMaterial, TLightMaterial,
  /// FMX.Materials.pas:300-304, 589-596, 3842-3881) that ray-traced reflections read from the constants.</summary>
  TFastMaterialValue = (Diffuse, Specular, Ambient, Emission, Opts, Color, Modulation);

  /// <summary>A shader of FMX as the devices see it; TContextShader.Handle points to it.</summary>
  TFastShader = class
  public
    /// <summary>Unique for the process (pipeline and layout keys; a freed shader's address can be reused).</summary>
    Id: Integer;
    Kind: TContextShaderKind;
    Code: TBytes;
    Variables: TContextShaderVariables;
    /// <summary>Bytes of the constant buffer (multiple of 16).</summary>
    ConstantSize: Integer;
    /// <summary>Texture units the shader samples (highest texture variable index + 1).</summary>
    TextureUnits: Integer;
    /// <summary>Byte offsets of the material values in the constants, -1 when the shader has no such variable.
    /// </summary>
    Material: array[TFastMaterialValue] of Integer;
    /// <summary>Their sizes in bytes (at most 16).</summary>
    MaterialSize: array[TFastMaterialValue] of Integer;
    /// <summary>Texture unit of the variable texture0 of the standard materials, -1 without one.</summary>
    Texture0: Integer;
    /// <summary>The device's shader object.</summary>
    Native: IInterface;
    function Find(const AName: string): Integer;
  end;

  /// <summary>The pipeline state as FMX sets it; compared and hashed as bytes.</summary>
  TFastPipelineState = packed record
    Blend: Boolean;
    ColorWrite: Boolean;
    DepthTest: Boolean;
    DepthWrite: Boolean;
    Stencil: Boolean;
    Scissor: Boolean;
    /// <summary>0: none; 1: cull back faces (csFrontFace); 2: cull front faces (csBackFace).</summary>
    Cull: Byte;
    StencilFail, StencilDepthFail, StencilPass: TStencilOp;
    StencilFunc: TStencilFunc;
    StencilMask: Byte;
  end;

  /// <summary>An input element of a vertex declaration. Format: a DXGI_FORMAT value (the same in Direct3D 11 and
  /// 12).</summary>
  TFastVertexElement = record
    Semantic: PAnsiChar;
    SemanticIndex: Integer;
    Format: Integer;
    Offset: Integer;
  end;

  TFastVertexLayout = record
    Elements: TArray<TFastVertexElement>;
    Hash: UInt64;
  end;

  TFastContext3D = class(TContext3D)
  public class var
    // The state FMX sets, shared by all contexts as FMX itself keeps it (TContext3D.FCurrentStates); public for the
    // device units.
    FVS, FPS: TFastShader;
    FVSData, FPSData: TBytes;
    FVSDirty, FPSDirty: Boolean;
    FState: TFastPipelineState;
    FStateDirty: Boolean;
    FStencilRef: Cardinal;
    /// <summary>Device texture objects of the texture units (kept alive while set) and the sampler filters.</summary>
    FUnits: array[0..7] of IInterface;
    FUnitFilters: array[0..7] of Byte;
    FUnitsDirty: Boolean;
    FScissor: TRect;
    FScissorDirty: Boolean;
    FNextShaderId: Integer;
    FShaders: TList<TFastShader>;
    /// <summary>The context service shut down (ShutdownBase).</summary>
    FFinished: Boolean;
  protected
    { state }
    procedure DoSetContextState(AState: TContextState); override;
    procedure DoSetStencilOp(const Fail, ZFail, ZPass: TStencilOp); override;
    procedure DoSetStencilFunc(const Func: TStencilfunc; Ref, Mask: Cardinal); override;
    procedure DoSetScissorRect(const ScissorRect: TRectF); override;
    function GetIndexBufferSupport: TContext3D.TIndexBufferSupport; override;
    { shaders }
    class procedure DoInitializeShader(const Shader: TContextShader); override;
    class procedure DoFinalizeShader(const Shader: TContextShader); override;
    procedure DoSetShaders(const VertexShader, PixelShader: TContextShader); override;
    procedure DoSetShaderVariable(const Name: string; const Data: array of TVector3D); overload; override;
    procedure DoSetShaderVariable(const Name: string; const Texture: TTexture); overload; override;
    procedure DoSetShaderVariable(const Name: string; const Matrix: TMatrix3D); overload; override;
    /// <summary>Device: the shader object for AShader.Code (AShader.Kind), stored in AShader.Native.</summary>
    class procedure CreateNativeShader(const AShader: TFastShader); virtual; abstract;
    /// <summary>Device: the texture object of a TTexture (from its Handle), or nil.</summary>
    class function TextureObject(const ATexture: TTexture): IInterface; virtual; abstract;
  public
    /// <summary>The input elements of a vertex declaration (FMX's vertex formats, as its DX11 context maps them).</summary>
    class function VertexLayout(const ADeclaration: TVertexDeclaration): TFastVertexLayout;
    /// <summary>Forgets every shader object and texture unit (the device was replaced).</summary>
    class procedure ResetShaderObjects;
    /// <summary>Initial pipeline state (blending on, depth test off, back faces culled) and empty units.</summary>
    class procedure ResetDeviceState;
    class function PixelFormat: TPixelFormat; override;
    class function MaxTextureSize: Integer; override;
    class procedure ShutdownBase;
  end;

/// <summary>DXGI_FORMAT value of a pixel format, 0 when the format has no texture equivalent.</summary>
function FastDxgiFormat(const AFormat: TPixelFormat): Integer;
/// <summary>A 64-bit hash of ASize bytes, eight at a time (keys of per-draw lookups: a byte at a time cost about
/// 0.1 us per draw).</summary>
function FastHash(const AData: Pointer; const ASize: Integer; const ASeed: UInt64 = $CBF29CE484222325): UInt64;
/// <summary>One step of FastHash: AValue mixed into AHash (a bijection of AHash for a given AValue).</summary>
function FastHashMix(const AHash, AValue: UInt64): UInt64; inline;

implementation

const
  // DXGI_FORMAT values (dxgiformat.h).
  DXGI_FORMAT_R32G32B32A32_FLOAT = 2;
  DXGI_FORMAT_R32G32B32_FLOAT = 6;
  DXGI_FORMAT_R16G16B16A16_FLOAT = 10;
  DXGI_FORMAT_R16G16B16A16_UNORM = 11;
  DXGI_FORMAT_R32G32_FLOAT = 16;
  DXGI_FORMAT_R10G10B10A2_UNORM = 24;
  DXGI_FORMAT_R8G8B8A8_UNORM = 28;
  DXGI_FORMAT_R16G16_FLOAT = 34;
  DXGI_FORMAT_R32_FLOAT = 41;
  DXGI_FORMAT_R16_FLOAT = 54;
  DXGI_FORMAT_R16_UNORM = 56;
  DXGI_FORMAT_R8_UNORM = 61;
  DXGI_FORMAT_A8_UNORM = 65;
  DXGI_FORMAT_B5G6R5_UNORM = 85;
  DXGI_FORMAT_B5G5R5A1_UNORM = 86;
  DXGI_FORMAT_B8G8R8A8_UNORM = 87;
  DXGI_FORMAT_B4G4R4A4_UNORM = 115;

  SemPosition: PAnsiChar = 'POSITION';
  SemNormal: PAnsiChar = 'NORMAL';
  SemColor: PAnsiChar = 'COLOR';
  SemTexCoord: PAnsiChar = 'TEXCOORD';
  SemBinormal: PAnsiChar = 'BINORMAL';
  SemTangent: PAnsiChar = 'TANGENT';

function FastHashMix(const AHash, AValue: UInt64): UInt64;
begin
  Result := (AHash xor AValue) * UInt64($9E3779B97F4A7C15);
  Result := Result xor (Result shr 32);
end;

function FastHash(const AData: Pointer; const ASize: Integer; const ASeed: UInt64): UInt64;
var
  P: PByte;
  N, I: Integer;
  V: UInt64;
begin
  Result := FastHashMix(ASeed, UInt64(ASize));
  P := AData;
  N := ASize;
  while N >= 8 do
  begin
    Result := FastHashMix(Result, PUInt64(P)^);
    Inc(P, 8);
    Dec(N, 8);
  end;
  if N > 0 then
  begin
    V := 0;
    for I := 0 to N - 1 do
      V := V or (UInt64(P[I]) shl (8 * I));
    Result := FastHashMix(Result, V);
  end;
end;

function FastDxgiFormat(const AFormat: TPixelFormat): Integer;
begin
  case AFormat of
    TPixelFormat.RGBA: Result := DXGI_FORMAT_R8G8B8A8_UNORM;
    TPixelFormat.BGRA: Result := DXGI_FORMAT_B8G8R8A8_UNORM;
    TPixelFormat.RGBA16: Result := DXGI_FORMAT_R16G16B16A16_UNORM;
    TPixelFormat.BGR_565: Result := DXGI_FORMAT_B5G6R5_UNORM;
    TPixelFormat.BGRA4: Result := DXGI_FORMAT_B4G4R4A4_UNORM;
    TPixelFormat.BGR5_A1: Result := DXGI_FORMAT_B5G5R5A1_UNORM;
    TPixelFormat.RGB10_A2: Result := DXGI_FORMAT_R10G10B10A2_UNORM;
    TPixelFormat.L: Result := DXGI_FORMAT_R8_UNORM;
    TPixelFormat.L16: Result := DXGI_FORMAT_R16_UNORM;
    TPixelFormat.A: Result := DXGI_FORMAT_A8_UNORM;
    TPixelFormat.R16F: Result := DXGI_FORMAT_R16_FLOAT;
    TPixelFormat.RG16F: Result := DXGI_FORMAT_R16G16_FLOAT;
    TPixelFormat.RGBA16F: Result := DXGI_FORMAT_R16G16B16A16_FLOAT;
    TPixelFormat.R32F: Result := DXGI_FORMAT_R32_FLOAT;
    TPixelFormat.RG32F: Result := DXGI_FORMAT_R32G32_FLOAT;
    TPixelFormat.RGBA32F: Result := DXGI_FORMAT_R32G32B32A32_FLOAT;
  else
    Result := 0;
  end;
end;

{ TFastShader }

function TFastShader.Find(const AName: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(Variables) do
    if Pointer(Variables[I].Name) = Pointer(AName) then
      Exit(I);
  for I := 0 to High(Variables) do
    if SameText(Variables[I].Name, AName) then
    begin
      // The next lookup with this string instance takes the fast path.
      Variables[I].Name := AName;
      Exit(I);
    end;
  Result := -1;
end;

{ TFastContext3D }

/// <summary>Where the values of the standard materials are in the shader's constants (names of FMX.Materials.pas).
/// </summary>
procedure FindMaterialValues(const S: TFastShader);
const
  Names: array[TFastMaterialValue] of string = ('MaterialDiffuse', 'MaterialSpecular', 'MaterialAmbient',
    'MaterialEmission', 'MaterialOpts', 'MaterialColor', 'Modulation');
var
  M: TFastMaterialValue;
  I: Integer;
begin
  S.Texture0 := -1;
  for M := Low(M) to High(M) do
    S.Material[M] := -1;
  for I := 0 to High(S.Variables) do
    if S.Variables[I].Kind = TContextShaderVariableKind.Texture then
    begin
      if SameText(S.Variables[I].Name, 'texture0') then
        S.Texture0 := S.Variables[I].Index;
    end
    else
      for M := Low(M) to High(M) do
        if SameText(S.Variables[I].Name, Names[M]) and (S.Variables[I].Size > 0) and
          (S.Variables[I].Index + Min(S.Variables[I].Size, 16) <= S.ConstantSize) then
        begin
          S.Material[M] := S.Variables[I].Index;
          S.MaterialSize[M] := Min(S.Variables[I].Size, 16);
        end;
end;

class function TFastContext3D.PixelFormat: TPixelFormat;
begin
  Result := TPixelFormat.BGRA;
end;

class function TFastContext3D.MaxTextureSize: Integer;
begin
  Result := 16384;
end;

function TFastContext3D.GetIndexBufferSupport: TContext3D.TIndexBufferSupport;
begin
  Result := TIndexBufferSupport.Int32;
end;

class procedure TFastContext3D.ResetDeviceState;
var
  I: Integer;
begin
  FillChar(FState, SizeOf(FState), 0);
  FState.Blend := True;
  FState.ColorWrite := True;
  FState.DepthWrite := True;
  FState.Cull := 1;
  FState.StencilFail := TStencilOp.Keep;
  FState.StencilDepthFail := TStencilOp.Keep;
  FState.StencilPass := TStencilOp.Keep;
  FState.StencilFunc := TStencilFunc.Always;
  FState.StencilMask := $FF;
  FStateDirty := True;
  FStencilRef := 0;
  for I := 0 to High(FUnits) do
  begin
    FUnits[I] := nil;
    FUnitFilters[I] := 0;
  end;
  FUnitsDirty := True;
  FScissorDirty := True;
  FVS := nil;
  FPS := nil;
  FVSDirty := True;
  FPSDirty := True;
end;

procedure TFastContext3D.DoSetContextState(AState: TContextState);
begin
  case AState of
    TContextState.csZTestOn: FState.DepthTest := True;
    TContextState.csZTestOff: FState.DepthTest := False;
    TContextState.csZWriteOn: FState.DepthWrite := True;
    TContextState.csZWriteOff: FState.DepthWrite := False;
    TContextState.csAlphaBlendOn: FState.Blend := True;
    TContextState.csAlphaBlendOff: FState.Blend := False;
    TContextState.csStencilOn: FState.Stencil := True;
    TContextState.csStencilOff: FState.Stencil := False;
    TContextState.csColorWriteOn: FState.ColorWrite := True;
    TContextState.csColorWriteOff: FState.ColorWrite := False;
    TContextState.csScissorOn:
      begin
        FState.Scissor := True;
        FScissorDirty := True;
      end;
    TContextState.csScissorOff: FState.Scissor := False;
    TContextState.csFrontFace: FState.Cull := 1;
    TContextState.csBackFace: FState.Cull := 2;
    TContextState.csAllFace: FState.Cull := 0;
  else
    Exit;
  end;
  FStateDirty := True;
end;

procedure TFastContext3D.DoSetStencilOp(const Fail, ZFail, ZPass: TStencilOp);
begin
  FState.StencilFail := Fail;
  FState.StencilDepthFail := ZFail;
  FState.StencilPass := ZPass;
  FStateDirty := True;
end;

procedure TFastContext3D.DoSetStencilFunc(const Func: TStencilfunc; Ref, Mask: Cardinal);
begin
  FState.StencilFunc := Func;
  FState.StencilMask := Byte(Mask);
  FStencilRef := Ref;
  FStateDirty := True;
end;

procedure TFastContext3D.DoSetScissorRect(const ScissorRect: TRectF);
begin
  FScissor := TRectF.Create(ScissorRect.Left * Scale, ScissorRect.Top * Scale, ScissorRect.Right * Scale,
    ScissorRect.Bottom * Scale).Round;
  FScissorDirty := True;
end;

class procedure TFastContext3D.DoInitializeShader(const Shader: TContextShader);
var
  Src: TContextShaderSource;
  S: TFastShader;
  V: TContextShaderVariable;
  I: Integer;
begin
  // A Direct3D 10+ device: DX11, then DX10, then DX11_level_9 (all FMX ships for Windows: DX11_level_9).
  Src := Shader.GetSourceByArch(TContextShaderArch.DX11);
  if not Src.IsDefined then
    Src := Shader.GetSourceByArch(TContextShaderArch.DX10);
  if not Src.IsDefined then
    Src := Shader.GetSourceByArch(TContextShaderArch.DX11_level_9);
  if not Src.IsDefined then
    Exit;
  S := TFastShader.Create;
  try
    Inc(FNextShaderId);
    S.Id := FNextShaderId;
    S.Kind := Shader.Kind;
    S.Code := Copy(TBytes(Src.Code));
    S.Variables := Copy(Src.Variables);
    S.ConstantSize := 0;
    S.TextureUnits := 0;
    for I := 0 to High(S.Variables) do
    begin
      V := S.Variables[I];
      if V.Kind = TContextShaderVariableKind.Texture then
        S.TextureUnits := Max(S.TextureUnits, Min(V.Index + 1, Length(FUnits)))
      else
        S.ConstantSize := Max(S.ConstantSize, V.Index + V.Size);
    end;
    S.ConstantSize := (S.ConstantSize + 15) and not 15;
    FindMaterialValues(S);
    CreateNativeShader(S);
  except
    S.Free;
    raise;
  end;
  if FShaders = nil then
    FShaders := TList<TFastShader>.Create;
  FShaders.Add(S);
  Shader.Handle := THandle(S);
end;

class procedure TFastContext3D.DoFinalizeShader(const Shader: TContextShader);
var
  S: TFastShader;
begin
  S := TFastShader(Shader.Handle);
  Shader.Handle := 0;
  if S = nil then
    Exit;
  if FVS = S then
    FVS := nil;
  if FPS = S then
    FPS := nil;
  if FShaders <> nil then
  begin
    FShaders.Remove(S);
    if FFinished and (FShaders.Count = 0) then
      FreeAndNil(FShaders);
  end;
  S.Free;
end;

class procedure TFastContext3D.ResetShaderObjects;
var
  S: TFastShader;
  I: Integer;
begin
  if FShaders <> nil then
    for S in FShaders do
      S.Native := nil;
  for I := 0 to High(FUnits) do
    FUnits[I] := nil;
end;

class procedure TFastContext3D.ShutdownBase;
begin
  // The TFastShader objects stay until FMX finalizes its shaders (DoFinalizeShader frees them; TShaderManager goes
  // before the context service in FinalizeForms, but not when shaders outlive it). Only the device objects go now,
  // and the list with the last shader.
  ResetShaderObjects;
  FVS := nil;
  FPS := nil;
  FFinished := True;
  if (FShaders <> nil) and (FShaders.Count = 0) then
    FreeAndNil(FShaders);
end;

procedure TFastContext3D.DoSetShaders(const VertexShader, PixelShader: TContextShader);
var
  V, P: TFastShader;
begin
  V := nil;
  P := nil;
  if VertexShader <> nil then
    V := TFastShader(VertexShader.Handle);
  if PixelShader <> nil then
    P := TFastShader(PixelShader.Handle);
  if V <> FVS then
  begin
    FVS := V;
    if V <> nil then
      SetLength(FVSData, V.ConstantSize);
    FVSDirty := True;
  end;
  if P <> FPS then
  begin
    FPS := P;
    if P <> nil then
      SetLength(FPSData, P.ConstantSize);
    FPSDirty := True;
    FUnitsDirty := True;
  end;
end;

procedure TFastContext3D.DoSetShaderVariable(const Name: string; const Data: array of TVector3D);
var
  I, N: Integer;
begin
  if Length(Data) = 0 then
    Exit;
  if FVS <> nil then
  begin
    I := FVS.Find(Name);
    if (I >= 0) and (FVS.Variables[I].Kind <> TContextShaderVariableKind.Texture) then
    begin
      N := Min(Length(Data) * SizeOf(TVector3D), FVS.Variables[I].Size);
      N := Min(N, Length(FVSData) - FVS.Variables[I].Index);
      if N > 0 then
        Move(Data[0], FVSData[FVS.Variables[I].Index], N);
      FVSDirty := True;
      Exit;
    end;
  end;
  if FPS <> nil then
  begin
    I := FPS.Find(Name);
    if (I >= 0) and (FPS.Variables[I].Kind <> TContextShaderVariableKind.Texture) then
    begin
      N := Min(Length(Data) * SizeOf(TVector3D), FPS.Variables[I].Size);
      N := Min(N, Length(FPSData) - FPS.Variables[I].Index);
      if N > 0 then
        Move(Data[0], FPSData[FPS.Variables[I].Index], N);
      FPSDirty := True;
    end;
  end;
end;

procedure TFastContext3D.DoSetShaderVariable(const Name: string; const Texture: TTexture);
var
  I, U: Integer;
  Filters: Byte;
begin
  if FPS = nil then
    Exit;
  I := FPS.Find(Name);
  if (I < 0) or (FPS.Variables[I].Kind <> TContextShaderVariableKind.Texture) then
    Exit;
  U := FPS.Variables[I].Index;
  if (U < 0) or (U > High(FUnits)) then
    Exit;
  if Texture <> nil then
  begin
    FUnits[U] := TextureObject(Texture);
    Filters := Ord(Texture.MinFilter = TTextureFilter.Linear) or (Ord(Texture.MagFilter = TTextureFilter.Linear) shl 1);
  end
  else
  begin
    FUnits[U] := nil;
    Filters := 3;
  end;
  FUnitFilters[U] := Filters;
  FUnitsDirty := True;
end;

procedure TFastContext3D.DoSetShaderVariable(const Name: string; const Matrix: TMatrix3D);
begin
  DoSetShaderVariable(Name, Matrix.M);
end;

class function TFastContext3D.VertexLayout(const ADeclaration: TVertexDeclaration): TFastVertexLayout;
var
  E: TVertexElement;
  N: Integer;

  procedure Add(const ASemantic: PAnsiChar; const AIndex, AFormat, AOffset: Integer);
  begin
    Result.Elements[N].Semantic := ASemantic;
    Result.Elements[N].SemanticIndex := AIndex;
    Result.Elements[N].Format := AFormat;
    Result.Elements[N].Offset := AOffset;
    Inc(N);
  end;

begin
  SetLength(Result.Elements, Length(ADeclaration));
  N := 0;
  for E in ADeclaration do
    case E.Format of
      TVertexFormat.Vertex: Add(SemPosition, 0, DXGI_FORMAT_R32G32B32_FLOAT, E.Offset);
      TVertexFormat.Normal: Add(SemNormal, 0, DXGI_FORMAT_R32G32B32_FLOAT, E.Offset);
      // Byte colors as RGBA: the level 9 feature levels FMX targets have no BGRA vertex format.
      TVertexFormat.Color0: Add(SemColor, 0, DXGI_FORMAT_R8G8B8A8_UNORM, E.Offset);
      TVertexFormat.Color1: Add(SemColor, 1, DXGI_FORMAT_R8G8B8A8_UNORM, E.Offset);
      TVertexFormat.Color2: Add(SemColor, 2, DXGI_FORMAT_R8G8B8A8_UNORM, E.Offset);
      TVertexFormat.Color3: Add(SemColor, 3, DXGI_FORMAT_R8G8B8A8_UNORM, E.Offset);
      TVertexFormat.ColorF0: Add(SemColor, 0, DXGI_FORMAT_R32G32B32A32_FLOAT, E.Offset);
      TVertexFormat.ColorF1: Add(SemColor, 1, DXGI_FORMAT_R32G32B32A32_FLOAT, E.Offset);
      TVertexFormat.ColorF2: Add(SemColor, 2, DXGI_FORMAT_R32G32B32A32_FLOAT, E.Offset);
      TVertexFormat.ColorF3: Add(SemColor, 3, DXGI_FORMAT_R32G32B32A32_FLOAT, E.Offset);
      TVertexFormat.TexCoord0: Add(SemTexCoord, 0, DXGI_FORMAT_R32G32_FLOAT, E.Offset);
      TVertexFormat.TexCoord1: Add(SemTexCoord, 1, DXGI_FORMAT_R32G32_FLOAT, E.Offset);
      TVertexFormat.TexCoord2: Add(SemTexCoord, 2, DXGI_FORMAT_R32G32_FLOAT, E.Offset);
      TVertexFormat.TexCoord3: Add(SemTexCoord, 3, DXGI_FORMAT_R32G32_FLOAT, E.Offset);
      TVertexFormat.BiNormal: Add(SemBinormal, 0, DXGI_FORMAT_R32G32B32_FLOAT, E.Offset);
      TVertexFormat.Tangent: Add(SemTangent, 0, DXGI_FORMAT_R32G32B32_FLOAT, E.Offset);
    end;
  SetLength(Result.Elements, N);
  Result.Hash := $CBF29CE484222325;
  for N := 0 to High(Result.Elements) do
  begin
    Result.Hash := FastHash(@Result.Elements[N].SemanticIndex, 3 * SizeOf(Integer), Result.Hash);
    Result.Hash := FastHash(Result.Elements[N].Semantic, 1, Result.Hash);
  end;
end;

end.
