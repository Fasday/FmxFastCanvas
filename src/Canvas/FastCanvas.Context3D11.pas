unit FastCanvas.Context3D11;

{ Own Direct3D 11 3D context of FastCanvas (stage 5), on the device of the installed canvas (FastCanvas.Bridge).

  Recording: every 3D command goes to one deferred context; its command list enters the canvas command stream
  (FastBridge.ExecuteCommandList) when the canvas records its next command or waits (FastDeferredPending /
  FastDeferredFlush), so 3D work runs in program order with the 2D work, on the render thread or inline. Nothing
  touches the immediate context except CPU read-back (after a sync).

  Per draw: vertices and indices into dynamic ring buffers (NO_OVERWRITE after the first DISCARD of a command
  list), constant buffers only when a variable changed, state objects, input layouts and samplers from caches,
  shader resource views made once per texture.

  Targets: a TTexture (TViewport3D, filters) through its render target view, with a multisampled buffer resolved
  at EndScene; a window (TForm3D) through a flip-model swap chain on the canvas device. TViewport3D and the
  filters exchange pixels with canvas bitmaps on the GPU (DoCopyToBitmap, DoBitmapToTexture). }

interface

{$SCOPEDENUMS ON}

uses
  System.Types, System.UITypes, System.SysUtils, System.Math, System.Generics.Collections, FMX.Types,
  FMX.Types3D, FMX.Graphics, FastCanvas.Context3D;

type
  TFastContext3D11 = class(TFastContext3D)
  private
    FMSColor: IInterface;
    FMSView: IInterface;
    FDepth: IInterface;
    FDepthView: IInterface;
    FSwapChain: IInterface;
    FBackView: IInterface;
    FSamples: Integer;
    procedure CreateTargets;
    function TargetView: IInterface;
    procedure BindTarget;
    procedure SetViewport(const ARect: TRect);
    function TargetPixels: TSize;
    function TargetTexture: IInterface;
  protected
    procedure DoCreateBuffer; override;
    procedure DoResize; override;
    procedure DoFreeBuffer; override;
    procedure DoCopyToBitmap(const Dest: TBitmap; const ARect: TRect); override;
    procedure DoCopyToBits(const Bits: Pointer; const Pitch: Integer; const ARect: TRect); override;
    function DoBeginScene: Boolean; override;
    procedure DoEndScene; override;
    procedure DoClear(const ATarget: TClearTargets; const AColor: TAlphaColor; const ADepth: Single;
      const AStencil: Cardinal); override;
    procedure DoDrawPrimitivesBatch(const AKind: TPrimitivesKind; const Vertices, Indices: Pointer;
      const VertexDeclaration: TVertexDeclaration; const VertexSize, VertexCount, IndexSize,
      IndexCount: Integer); override;
    class procedure DoInitializeTexture(const Texture: TTexture); override;
    class procedure DoFinalizeTexture(const Texture: TTexture); override;
    class procedure DoUpdateTexture(const Texture: TTexture; const Bits: Pointer; const Pitch: Integer); override;
    class function DoBitmapToTexture(const Bitmap: TBitmap): TTexture; override;
    class procedure CreateNativeShader(const AShader: TFastShader); override;
    class function TextureObject(const ATexture: TTexture): IInterface; override;
    constructor CreateFromWindow(const AParent: TWindowHandle; const AWidth, AHeight: Single;
      const AMultisample: TMultisample; const ADepthStencil: Boolean); override;
    constructor CreateFromTexture(const ATexture: TTexture; const AMultisample: TMultisample;
      const ADepthStencil: Boolean); override;
  public
    destructor Destroy; override;
    class function Valid: Boolean; override;
    class function Style: TContextStyles; override;
    { Raw draws (FastCanvas.Context3D) }
    procedure DrawRaw(const ADraw: TFastRawDraw); override;
    procedure CopyToTexture(const ADest: TFastTexture; const ADestX, ADestY: Integer; const ASource: TRect;
      const ADepth: Boolean); override;
    procedure ReadTarget(const ARect: TRect; const AKind: TFastReadKind; const ADest: Pointer;
      const APitch: Integer); override;
    class function NewTextureObject(const ATexture: TFastTexture): IInterface; override;
    class procedure UploadTextureObject(const ATexture: TFastTexture; const AObject: IInterface;
      const AFace, AMip, X, Y, AWidth, AHeight: Integer; const AData: Pointer; const ARowPitch: Integer); override;
    class function NewBufferObject(const ABuffer: TFastBuffer): IInterface; override;
    class procedure WriteBufferObject(const ABuffer: TFastBuffer; const AObject: IInterface; const AOffset: Integer;
      const AData: Pointer; const ASize: Integer); override;
  end;

var
  /// <summary>TContextStyle.Fragile: FMX keeps a copy of texture pixels and recreates textures and shaders after a
  /// device loss (TContextLostMessage / TContextResetMessage). Costs a message subscription per TTexture. Read when
  /// the context class is installed. The one of FastCanvas.Context3D, which the Vulkan 3D context takes too (also off
  /// Windows).</summary>
  FastContext3DFragile: Boolean absolute FastCanvas.Context3D.FastContext3DFragile;

/// <summary>Makes TFastContext3D11 the default 3D context. Call before Application.Initialize, after the canvas
/// (FastCanvas.Canvas.InstallFastCanvas).</summary>
procedure InstallFastContext3D11;

implementation

uses
  Winapi.Windows, Winapi.DXGI, Winapi.DXGI1_2, Winapi.DxgiFormat, Winapi.DxgiType, Winapi.D3D11, Winapi.D3DCommon,
  System.Classes, FMX.Platform.Win, FastCanvas.Bridge, FastCanvas.Service;

type
  // Winapi.Windows declares a TBitmap too.
  TBitmap = FMX.Graphics.TBitmap;

  /// <summary>Texture object of a TTexture (its Handle holds one reference).</summary>
  TTexture11 = class(TInterfacedObject)
  public
    Texture: ID3D11Texture2D;
    View: ID3D11ShaderResourceView;
    Target: ID3D11RenderTargetView;
    Format: DXGI_FORMAT;
    Width, Height: Integer;
    MipMaps: Boolean;
    /// <summary>A command recorded so far refers to the texture (sticky).</summary>
    Used: Boolean;
    function RenderTarget: ID3D11RenderTargetView;
  end;

  TShader11 = class(TInterfacedObject)
  public
    VS: ID3D11VertexShader;
    PS: ID3D11PixelShader;
  end;

  /// <summary>The texture of a TFastTexture (raw draws).</summary>
  TRawTexture11 = class(TInterfacedObject)
  public
    Texture: ID3D11Texture2D;
    View: ID3D11ShaderResourceView;
  end;

  /// <summary>The buffer of a TFastBuffer (raw draws).</summary>
  TRawBuffer11 = class(TInterfacedObject)
  public
    Buffer: ID3D11Buffer;
  end;

  TRing = record
    Buffer: ID3D11Buffer;
    Size, Pos: Integer;
    /// <summary>The next Map discards: a new buffer, or the first write into a command list.</summary>
    Fresh: Boolean;
  end;

  TShared = class
  public
    Device: ID3D11Device;
    DC: ID3D11DeviceContext;
    Vertices, Indices: TRing;
    VSConstants, PSConstants: TDictionary<Integer, ID3D11Buffer>;
    Blends: TDictionary<Word, ID3D11BlendState>;
    DepthStates: TDictionary<UInt64, ID3D11DepthStencilState>;
    Rasters: TDictionary<Word, ID3D11RasterizerState>;
    Layouts: TDictionary<UInt64, ID3D11InputLayout>;
    Samplers: array[0..3] of ID3D11SamplerState;
    Blank: TTexture11;
    BlankRef: IInterface;
    // Bound on DC since its last command list.
    BoundVS: ID3D11VertexShader;
    BoundPS: ID3D11PixelShader;
    BoundLayout: ID3D11InputLayout;
    BoundTopology: D3D11_PRIMITIVE_TOPOLOGY;
    BoundBlend: ID3D11BlendState;
    BoundDepth: ID3D11DepthStencilState;
    BoundRef: Cardinal;
    BoundRaster: ID3D11RasterizerState;
    BoundVSConstants, BoundPSConstants: ID3D11Buffer;
    Fresh: Boolean;
    // Raw draws: state objects by the hash of their description, and whether a raw draw left a viewport other than
    // the whole target bound (FMX's draws set it back).
    RawBlends: TDictionary<UInt64, ID3D11BlendState>;
    RawDepths: TDictionary<UInt64, ID3D11DepthStencilState>;
    RawRasters: TDictionary<UInt64, ID3D11RasterizerState>;
    RawSamplers: TDictionary<UInt64, ID3D11SamplerState>;
    ViewportChanged: Boolean;
    /// <summary>The driver records command lists itself (D3D11_FEATURE_THREADING); without, UpdateSubresource on a
    /// deferred context with a box offsets the source by the box too (the documented workaround adjusts it).</summary>
    DriverCommandLists: Boolean;
    constructor Create;
    destructor Destroy; override;
    procedure Invalidate;
    function Upload(var ARing: TRing; const ABind: Cardinal; const AData: Pointer; const ASize: Integer): Integer;
    function Constants(const AVertex: Boolean; const AData: TBytes): ID3D11Buffer; overload;
    function Constants(const AVertex: Boolean; const AData: Pointer; const ASize: Integer): ID3D11Buffer; overload;
    function RawBlend(const AState: TFastRawState): ID3D11BlendState;
    function RawDepth(const AState: TFastRawState): ID3D11DepthStencilState;
    function RawRaster(const AState: TFastRawState; const AScissor: Boolean): ID3D11RasterizerState;
    function RawSampler(const ASampler: TFastSampler): ID3D11SamplerState;
    function Blend: ID3D11BlendState;
    function DepthState: ID3D11DepthStencilState;
    function Raster: ID3D11RasterizerState;
    function Layout(const AShader: TFastShader; const ALayout: TFastVertexLayout): ID3D11InputLayout;
    function Sampler(const AFilters: Byte): ID3D11SamplerState;
  end;

var
  G: TShared;
  // Contexts in a scene, innermost last (the target to bind again when an inner scene ends), and every live
  // context (buffers made again after a device loss). Kept across device losses.
  GScenes: TList<TFastContext3D11>;
  GContexts: TList<TFastContext3D11>;

procedure Check(const ARes: HResult; const AWhat: string);
begin
  if Failed(ARes) then
    raise EContext3DException.CreateFmt('FastContext3D11: %s failed (0x%.8x)', [AWhat, Cardinal(ARes)]);
end;

/// <summary>The shared objects; created with the first use, after the canvas device exists.</summary>
function Shared: TShared;
begin
  if G = nil then
    G := TShared.Create;
  Result := G;
end;

/// <summary>Hands the commands recorded so far to the canvas command stream (FastDeferredFlush).</summary>
procedure FlushDeferred;
var
  List: ID3D11CommandList;
begin
  FastDeferredPending := False;
  if G = nil then
    Exit;
  // FALSE: the deferred context goes back to its default state; Invalidate binds everything again.
  if Succeeded(G.DC.FinishCommandList(False, List)) then
    FastBridge.ExecuteCommandList(List);
  G.Invalidate;
  // The target of the scene in progress, if any, is bound again in the next command list.
  if GScenes.Count > 0 then
    GScenes.Last.BindTarget;
end;

/// <summary>Something was recorded: the canvas flushes it before its next command.</summary>
procedure Recorded; inline;
begin
  FastDeferredPending := True;
  FastDeferredFlush := FlushDeferred;
end;

{ TTexture11 }

function TTexture11.RenderTarget: ID3D11RenderTargetView;
begin
  if Target = nil then
    Check(G.Device.CreateRenderTargetView(Texture, nil, Target), 'CreateRenderTargetView');
  Result := Target;
end;

{ TShared }

constructor TShared.Create;
var
  Desc: TD3D11_TEXTURE2D_DESC;
  Init: D3D11_SUBRESOURCE_DATA;
  White: Cardinal;
  Threading: TD3D11_FEATURE_DATA_THREADING;
begin
  inherited;
  Device := FastBridge.Device();
  if Device = nil then
    raise EContext3DException.Create('FastContext3D11: the canvas has no Direct3D 11 device');
  Check(Device.CreateDeferredContext(0, DC), 'CreateDeferredContext');
  VSConstants := TDictionary<Integer, ID3D11Buffer>.Create;
  PSConstants := TDictionary<Integer, ID3D11Buffer>.Create;
  Blends := TDictionary<Word, ID3D11BlendState>.Create;
  DepthStates := TDictionary<UInt64, ID3D11DepthStencilState>.Create;
  Rasters := TDictionary<Word, ID3D11RasterizerState>.Create;
  Layouts := TDictionary<UInt64, ID3D11InputLayout>.Create;
  RawBlends := TDictionary<UInt64, ID3D11BlendState>.Create;
  RawDepths := TDictionary<UInt64, ID3D11DepthStencilState>.Create;
  RawRasters := TDictionary<UInt64, ID3D11RasterizerState>.Create;
  RawSamplers := TDictionary<UInt64, ID3D11SamplerState>.Create;
  FillChar(Threading, SizeOf(Threading), 0);
  DriverCommandLists := Succeeded(Device.CheckFeatureSupport(D3D11_FEATURE_THREADING, @Threading,
    SizeOf(Threading))) and Threading.DriverCommandLists;
  // Small: every command list starts with a DISCARD, which renames the whole buffer (effects record one list per
  // filter pass). The rings grow when a draw does not fit.
  Vertices.Size := 256 * 1024;
  Indices.Size := 64 * 1024;
  // White 1x1: texture units without a texture sample it.
  FillChar(Desc, SizeOf(Desc), 0);
  Desc.Width := 1;
  Desc.Height := 1;
  Desc.MipLevels := 1;
  Desc.ArraySize := 1;
  Desc.Format := DXGI_FORMAT_B8G8R8A8_UNORM;
  Desc.SampleDesc.Count := 1;
  Desc.Usage := D3D11_USAGE_IMMUTABLE;
  Desc.BindFlags := D3D11_BIND_SHADER_RESOURCE;
  White := $FFFFFFFF;
  Init.pSysMem := @White;
  Init.SysMemPitch := 4;
  Init.SysMemSlicePitch := 0;
  Blank := TTexture11.Create;
  BlankRef := Blank;
  Check(Device.CreateTexture2D(Desc, @Init, Blank.Texture), 'CreateTexture2D (blank)');
  Check(Device.CreateShaderResourceView(Blank.Texture, nil, Blank.View), 'CreateShaderResourceView (blank)');
  Invalidate;
end;

destructor TShared.Destroy;
begin
  VSConstants.Free;
  PSConstants.Free;
  Blends.Free;
  DepthStates.Free;
  Rasters.Free;
  Layouts.Free;
  RawBlends.Free;
  RawDepths.Free;
  RawRasters.Free;
  RawSamplers.Free;
  inherited;
end;

procedure TShared.Invalidate;
begin
  BoundVS := nil;
  BoundPS := nil;
  BoundLayout := nil;
  BoundTopology := D3D11_PRIMITIVE_TOPOLOGY_UNDEFINED;
  BoundBlend := nil;
  BoundDepth := nil;
  BoundRaster := nil;
  BoundVSConstants := nil;
  BoundPSConstants := nil;
  Vertices.Fresh := True;
  Indices.Fresh := True;
  Fresh := True;
  TFastContext3D.FUnitsDirty := True;
  TFastContext3D.FScissorDirty := True;
  TFastContext3D.FVSDirty := True;
  TFastContext3D.FPSDirty := True;
end;

function TShared.Upload(var ARing: TRing; const ABind: Cardinal; const AData: Pointer; const ASize: Integer): Integer;
var
  Desc: TD3D11_BUFFER_DESC;
  Mapped: D3D11_MAPPED_SUBRESOURCE;
  MapType: D3D11_MAP;
begin
  // Grows when a draw does not fit, or when one command list fills it (each wrap renames the buffer).
  if (ASize > ARing.Size) or (not ARing.Fresh and (ARing.Pos + ASize > ARing.Size) and (ARing.Size < 64 * 1024 * 1024)) then
  begin
    ARing.Buffer := nil;
    ARing.Size := Max(ASize, 2 * ARing.Size);
  end;
  if ARing.Buffer = nil then
  begin
    FillChar(Desc, SizeOf(Desc), 0);
    Desc.ByteWidth := ARing.Size;
    Desc.Usage := D3D11_USAGE_DYNAMIC;
    Desc.BindFlags := ABind;
    Desc.CPUAccessFlags := D3D11_CPU_ACCESS_WRITE;
    Check(Device.CreateBuffer(Desc, nil, ARing.Buffer), 'CreateBuffer (geometry)');
    ARing.Fresh := True;
  end;
  // A command list starts with a DISCARD of every dynamic buffer it maps (deferred context rule).
  if ARing.Fresh or (ARing.Pos + ASize > ARing.Size) then
  begin
    MapType := D3D11_MAP_WRITE_DISCARD;
    ARing.Pos := 0;
    ARing.Fresh := False;
  end
  else
    MapType := D3D11_MAP_WRITE_NO_OVERWRITE;
  Check(DC.Map(ARing.Buffer, 0, MapType, 0, Mapped), 'Map (geometry)');
  Move(AData^, (PByte(Mapped.pData) + ARing.Pos)^, ASize);
  DC.Unmap(ARing.Buffer, 0);
  Result := ARing.Pos;
  // Offsets of index buffers must stay aligned for 32-bit indices.
  ARing.Pos := (ARing.Pos + ASize + 15) and not 15;
end;

function TShared.Constants(const AVertex: Boolean; const AData: TBytes): ID3D11Buffer;
var
  Map: TDictionary<Integer, ID3D11Buffer>;
  Desc: TD3D11_BUFFER_DESC;
  Mapped: D3D11_MAPPED_SUBRESOURCE;
begin
  if AVertex then
    Map := VSConstants
  else
    Map := PSConstants;
  if not Map.TryGetValue(Length(AData), Result) then
  begin
    FillChar(Desc, SizeOf(Desc), 0);
    Desc.ByteWidth := Length(AData);
    Desc.Usage := D3D11_USAGE_DYNAMIC;
    Desc.BindFlags := D3D11_BIND_CONSTANT_BUFFER;
    Desc.CPUAccessFlags := D3D11_CPU_ACCESS_WRITE;
    Check(Device.CreateBuffer(Desc, nil, Result), 'CreateBuffer (constants)');
    Map.Add(Length(AData), Result);
  end;
  Check(DC.Map(Result, 0, D3D11_MAP_WRITE_DISCARD, 0, Mapped), 'Map (constants)');
  Move(AData[0], Mapped.pData^, Length(AData));
  DC.Unmap(Result, 0);
end;

function TShared.Constants(const AVertex: Boolean; const AData: Pointer; const ASize: Integer): ID3D11Buffer;
var
  Map: TDictionary<Integer, ID3D11Buffer>;
  Desc: TD3D11_BUFFER_DESC;
  Mapped: D3D11_MAPPED_SUBRESOURCE;
  Size: Integer;
begin
  if AVertex then
    Map := VSConstants
  else
    Map := PSConstants;
  Size := (ASize + 15) and not 15;
  if not Map.TryGetValue(Size, Result) then
  begin
    FillChar(Desc, SizeOf(Desc), 0);
    Desc.ByteWidth := Size;
    Desc.Usage := D3D11_USAGE_DYNAMIC;
    Desc.BindFlags := D3D11_BIND_CONSTANT_BUFFER;
    Desc.CPUAccessFlags := D3D11_CPU_ACCESS_WRITE;
    Check(Device.CreateBuffer(Desc, nil, Result), 'CreateBuffer (constants)');
    Map.Add(Size, Result);
  end;
  Check(DC.Map(Result, 0, D3D11_MAP_WRITE_DISCARD, 0, Mapped), 'Map (constants)');
  Move(AData^, Mapped.pData^, ASize);
  DC.Unmap(Result, 0);
end;

function TShared.RawBlend(const AState: TFastRawState): ID3D11BlendState;
var
  Key: UInt64;
  Desc: TD3D11_BLEND_DESC;
begin
  Key := FastHash(@AState.BlendEnable, 8);
  if RawBlends.TryGetValue(Key, Result) then
    Exit;
  FillChar(Desc, SizeOf(Desc), 0);
  Desc.RenderTarget[0].BlendEnable := AState.BlendEnable;
  Desc.RenderTarget[0].SrcBlend := D3D11_BLEND(Ord(AState.SrcBlend));
  Desc.RenderTarget[0].DestBlend := D3D11_BLEND(Ord(AState.DestBlend));
  Desc.RenderTarget[0].BlendOp := D3D11_BLEND_OP(Ord(AState.BlendOp));
  Desc.RenderTarget[0].SrcBlendAlpha := D3D11_BLEND(Ord(AState.SrcBlendAlpha));
  Desc.RenderTarget[0].DestBlendAlpha := D3D11_BLEND(Ord(AState.DestBlendAlpha));
  Desc.RenderTarget[0].BlendOpAlpha := D3D11_BLEND_OP(Ord(AState.BlendOpAlpha));
  Desc.RenderTarget[0].RenderTargetWriteMask := AState.WriteMask and $F;
  Check(Device.CreateBlendState(Desc, Result), 'CreateBlendState (raw)');
  RawBlends.Add(Key, Result);
end;

function TShared.RawDepth(const AState: TFastRawState): ID3D11DepthStencilState;
var
  Key: UInt64;
  Desc: TD3D11_DEPTH_STENCIL_DESC;
begin
  Key := FastHash(@AState.DepthEnable, NativeInt(@AState.Cull) - NativeInt(@AState.DepthEnable));
  if RawDepths.TryGetValue(Key, Result) then
    Exit;
  FillChar(Desc, SizeOf(Desc), 0);
  Desc.DepthEnable := AState.DepthEnable;
  if AState.DepthWrite then
    Desc.DepthWriteMask := D3D11_DEPTH_WRITE_MASK_ALL
  else
    Desc.DepthWriteMask := D3D11_DEPTH_WRITE_MASK_ZERO;
  Desc.DepthFunc := D3D11_COMPARISON_FUNC(Ord(AState.DepthFunc));
  Desc.StencilEnable := AState.StencilEnable;
  Desc.StencilReadMask := AState.StencilReadMask;
  Desc.StencilWriteMask := AState.StencilWriteMask;
  Desc.FrontFace.StencilFailOp := D3D11_STENCIL_OP(Ord(AState.FrontFace.Fail));
  Desc.FrontFace.StencilDepthFailOp := D3D11_STENCIL_OP(Ord(AState.FrontFace.DepthFail));
  Desc.FrontFace.StencilPassOp := D3D11_STENCIL_OP(Ord(AState.FrontFace.Pass));
  Desc.FrontFace.StencilFunc := D3D11_COMPARISON_FUNC(Ord(AState.FrontFace.Func));
  Desc.BackFace.StencilFailOp := D3D11_STENCIL_OP(Ord(AState.BackFace.Fail));
  Desc.BackFace.StencilDepthFailOp := D3D11_STENCIL_OP(Ord(AState.BackFace.DepthFail));
  Desc.BackFace.StencilPassOp := D3D11_STENCIL_OP(Ord(AState.BackFace.Pass));
  Desc.BackFace.StencilFunc := D3D11_COMPARISON_FUNC(Ord(AState.BackFace.Func));
  Check(Device.CreateDepthStencilState(Desc, Result), 'CreateDepthStencilState (raw)');
  RawDepths.Add(Key, Result);
end;

function TShared.RawRaster(const AState: TFastRawState; const AScissor: Boolean): ID3D11RasterizerState;
var
  Key: UInt64;
  Desc: TD3D11_RASTERIZER_DESC;
begin
  Key := FastHash(@AState.Cull, SizeOf(AState) - (NativeInt(@AState.Cull) - NativeInt(@AState)), Ord(AScissor));
  if RawRasters.TryGetValue(Key, Result) then
    Exit;
  FillChar(Desc, SizeOf(Desc), 0);
  if AState.Wireframe then
    Desc.FillMode := D3D11_FILL_WIREFRAME
  else
    Desc.FillMode := D3D11_FILL_SOLID;
  Desc.CullMode := D3D11_CULL_MODE(Ord(AState.Cull));
  Desc.FrontCounterClockwise := AState.FrontCounterClockwise;
  Desc.DepthBias := AState.DepthBias;
  Desc.DepthBiasClamp := AState.DepthBiasClamp;
  Desc.SlopeScaledDepthBias := AState.SlopeScaledDepthBias;
  Desc.DepthClipEnable := True;
  Desc.ScissorEnable := AScissor;
  Desc.MultisampleEnable := True;
  Check(Device.CreateRasterizerState(Desc, Result), 'CreateRasterizerState (raw)');
  RawRasters.Add(Key, Result);
end;

function TShared.RawSampler(const ASampler: TFastSampler): ID3D11SamplerState;
var
  Key: UInt64;
  Desc: TD3D11_SAMPLER_DESC;
begin
  Key := FastHash(@ASampler, SizeOf(ASampler));
  if RawSamplers.TryGetValue(Key, Result) then
    Exit;
  FillChar(Desc, SizeOf(Desc), 0);
  Desc.Filter := D3D11_FILTER(ASampler.Filter);
  Desc.AddressU := D3D11_TEXTURE_ADDRESS_MODE(ASampler.AddressU);
  Desc.AddressV := D3D11_TEXTURE_ADDRESS_MODE(ASampler.AddressV);
  Desc.AddressW := D3D11_TEXTURE_ADDRESS_MODE(ASampler.AddressW);
  Desc.MipLODBias := ASampler.MipLODBias;
  Desc.MaxAnisotropy := Max(1, ASampler.MaxAnisotropy);
  Desc.ComparisonFunc := D3D11_COMPARISON_NEVER;
  Move(ASampler.BorderColor, Desc.BorderColor, SizeOf(Desc.BorderColor));
  Desc.MinLOD := ASampler.MinLOD;
  Desc.MaxLOD := ASampler.MaxLOD;
  Check(Device.CreateSamplerState(Desc, Result), 'CreateSamplerState (raw)');
  RawSamplers.Add(Key, Result);
end;

function TShared.Blend: ID3D11BlendState;
var
  Key: Word;
  Desc: TD3D11_BLEND_DESC;
begin
  Key := Ord(TFastContext3D.FState.Blend) or (Ord(TFastContext3D.FState.ColorWrite) shl 1);
  if Blends.TryGetValue(Key, Result) then
    Exit;
  FillChar(Desc, SizeOf(Desc), 0);
  // FMX colors are premultiplied.
  Desc.RenderTarget[0].BlendEnable := TFastContext3D.FState.Blend;
  Desc.RenderTarget[0].SrcBlend := D3D11_BLEND_ONE;
  Desc.RenderTarget[0].DestBlend := D3D11_BLEND_INV_SRC_ALPHA;
  Desc.RenderTarget[0].BlendOp := D3D11_BLEND_OP_ADD;
  Desc.RenderTarget[0].SrcBlendAlpha := D3D11_BLEND_ONE;
  Desc.RenderTarget[0].DestBlendAlpha := D3D11_BLEND_INV_SRC_ALPHA;
  Desc.RenderTarget[0].BlendOpAlpha := D3D11_BLEND_OP_ADD;
  if TFastContext3D.FState.ColorWrite then
    Desc.RenderTarget[0].RenderTargetWriteMask := Byte(D3D11_COLOR_WRITE_ENABLE_ALL)
  else
    Desc.RenderTarget[0].RenderTargetWriteMask := 0;
  Check(Device.CreateBlendState(Desc, Result), 'CreateBlendState');
  Blends.Add(Key, Result);
end;

function TShared.DepthState: ID3D11DepthStencilState;
const
  Ops: array[TStencilOp] of D3D11_STENCIL_OP = (D3D11_STENCIL_OP_KEEP, D3D11_STENCIL_OP_ZERO,
    D3D11_STENCIL_OP_REPLACE, D3D11_STENCIL_OP_INCR_SAT, D3D11_STENCIL_OP_DECR_SAT, D3D11_STENCIL_OP_INVERT);
  Funcs: array[TStencilFunc] of D3D11_COMPARISON_FUNC = (D3D11_COMPARISON_NEVER, D3D11_COMPARISON_LESS,
    D3D11_COMPARISON_LESS_EQUAL, D3D11_COMPARISON_GREATER, D3D11_COMPARISON_GREATER_EQUAL, D3D11_COMPARISON_EQUAL,
    D3D11_COMPARISON_NOT_EQUAL, D3D11_COMPARISON_ALWAYS);
var
  Key: UInt64;
  S: TFastPipelineState;
  Desc: TD3D11_DEPTH_STENCIL_DESC;
begin
  S := TFastContext3D.FState;
  Key := Ord(S.DepthTest) or (Ord(S.DepthWrite) shl 1) or (Ord(S.Stencil) shl 2) or (UInt64(Ord(S.StencilFail)) shl 3) or
    (UInt64(Ord(S.StencilDepthFail)) shl 6) or (UInt64(Ord(S.StencilPass)) shl 9) or
    (UInt64(Ord(S.StencilFunc)) shl 12) or (UInt64(S.StencilMask) shl 16);
  if DepthStates.TryGetValue(Key, Result) then
    Exit;
  FillChar(Desc, SizeOf(Desc), 0);
  Desc.DepthEnable := S.DepthTest;
  if S.DepthWrite then
    Desc.DepthWriteMask := D3D11_DEPTH_WRITE_MASK_ALL
  else
    Desc.DepthWriteMask := D3D11_DEPTH_WRITE_MASK_ZERO;
  Desc.DepthFunc := D3D11_COMPARISON_LESS_EQUAL;
  Desc.StencilEnable := S.Stencil;
  Desc.StencilReadMask := S.StencilMask;
  Desc.StencilWriteMask := S.StencilMask;
  Desc.FrontFace.StencilFailOp := Ops[S.StencilFail];
  Desc.FrontFace.StencilDepthFailOp := Ops[S.StencilDepthFail];
  Desc.FrontFace.StencilPassOp := Ops[S.StencilPass];
  Desc.FrontFace.StencilFunc := Funcs[S.StencilFunc];
  Desc.BackFace := Desc.FrontFace;
  Check(Device.CreateDepthStencilState(Desc, Result), 'CreateDepthStencilState');
  DepthStates.Add(Key, Result);
end;

function TShared.Raster: ID3D11RasterizerState;
const
  Culls: array[0..2] of D3D11_CULL_MODE = (D3D11_CULL_NONE, D3D11_CULL_BACK, D3D11_CULL_FRONT);
var
  Key: Word;
  Desc: TD3D11_RASTERIZER_DESC;
begin
  Key := TFastContext3D.FState.Cull or (Ord(TFastContext3D.FState.Scissor) shl 2);
  if Rasters.TryGetValue(Key, Result) then
    Exit;
  FillChar(Desc, SizeOf(Desc), 0);
  Desc.FillMode := D3D11_FILL_SOLID;
  Desc.CullMode := Culls[Min(TFastContext3D.FState.Cull, 2)];
  Desc.FrontCounterClockwise := False;
  Desc.DepthClipEnable := True;
  Desc.ScissorEnable := TFastContext3D.FState.Scissor;
  Desc.MultisampleEnable := True;
  Desc.AntialiasedLineEnable := True;
  Check(Device.CreateRasterizerState(Desc, Result), 'CreateRasterizerState');
  Rasters.Add(Key, Result);
end;

function TShared.Layout(const AShader: TFastShader; const ALayout: TFastVertexLayout): ID3D11InputLayout;
var
  Key: UInt64;
  Elements: TArray<TD3D11_INPUT_ELEMENT_DESC>;
  I: Integer;
begin
  Key := FastHash(@AShader.Id, SizeOf(Integer), ALayout.Hash);
  if Layouts.TryGetValue(Key, Result) then
    Exit;
  SetLength(Elements, Length(ALayout.Elements));
  for I := 0 to High(Elements) do
  begin
    Elements[I].SemanticName := ALayout.Elements[I].Semantic;
    Elements[I].SemanticIndex := ALayout.Elements[I].SemanticIndex;
    Elements[I].Format := DXGI_FORMAT(ALayout.Elements[I].Format);
    Elements[I].InputSlot := 0;
    Elements[I].AlignedByteOffset := ALayout.Elements[I].Offset;
    Elements[I].InputSlotClass := D3D11_INPUT_PER_VERTEX_DATA;
    Elements[I].InstanceDataStepRate := 0;
  end;
  if Length(Elements) = 0 then
    Exit(nil);
  Check(Device.CreateInputLayout(@Elements[0], Length(Elements), @AShader.Code[0], Length(AShader.Code), Result),
    'CreateInputLayout');
  Layouts.Add(Key, Result);
end;

function TShared.Sampler(const AFilters: Byte): ID3D11SamplerState;
const
  // Bit 0: linear minification, bit 1: linear magnification.
  Filters: array[0..3] of D3D11_FILTER = (D3D11_FILTER_MIN_MAG_MIP_POINT, D3D11_FILTER_MIN_LINEAR_MAG_MIP_POINT,
    D3D11_FILTER_MIN_POINT_MAG_MIP_LINEAR, D3D11_FILTER_MIN_MAG_MIP_LINEAR);
var
  Desc: TD3D11_SAMPLER_DESC;
begin
  Result := Samplers[AFilters and 3];
  if Result <> nil then
    Exit;
  FillChar(Desc, SizeOf(Desc), 0);
  Desc.Filter := Filters[AFilters and 3];
  Desc.AddressU := D3D11_TEXTURE_ADDRESS_CLAMP;
  Desc.AddressV := D3D11_TEXTURE_ADDRESS_CLAMP;
  Desc.AddressW := D3D11_TEXTURE_ADDRESS_CLAMP;
  Desc.MaxAnisotropy := 1;
  Desc.ComparisonFunc := D3D11_COMPARISON_NEVER;
  Desc.MinLOD := -MaxSingle;
  Desc.MaxLOD := MaxSingle;
  Check(Device.CreateSamplerState(Desc, Result), 'CreateSamplerState');
  Samplers[AFilters and 3] := Result;
end;

procedure RunPendingReset; forward;

{ TFastContext3D11 }

constructor TFastContext3D11.CreateFromWindow(const AParent: TWindowHandle; const AWidth, AHeight: Single;
  const AMultisample: TMultisample; const ADepthStencil: Boolean);
begin
  inherited;
  GContexts.Add(Self);
  CreateBuffer;
end;

constructor TFastContext3D11.CreateFromTexture(const ATexture: TTexture; const AMultisample: TMultisample;
  const ADepthStencil: Boolean);
begin
  inherited;
  GContexts.Add(Self);
  CreateBuffer;
end;

destructor TFastContext3D11.Destroy;
begin
  if GContexts <> nil then
  begin
    GContexts.Remove(Self);
    GScenes.Remove(Self);
  end;
  inherited;
end;

class function TFastContext3D11.Valid: Boolean;
begin
  Result := Assigned(FastBridge.Device);
end;

class function TFastContext3D11.Style: TContextStyles;
begin
  if FastContext3DFragile then
    Result := [TContextStyle.Fragile]
  else
    Result := [];
end;

function TFastContext3D11.TargetPixels: TSize;
begin
  if Texture <> nil then
    Result := TSize.Create(Texture.Width, Texture.Height)
  else
    Result := TSize.Create(Max(1, Round(Width * Scale)), Max(1, Round(Height * Scale)));
end;

procedure TFastContext3D11.CreateTargets;
var
  S: TShared;
  Px: TSize;
  Desc: TD3D11_TEXTURE2D_DESC;
  Chain: TDXGISwapChainDesc1;
  Levels: Cardinal;
  Wanted: Integer;
  Tex: ID3D11Texture2D;
  View: ID3D11RenderTargetView;
  DView: ID3D11DepthStencilView;
  Swap: IDXGISwapChain1;
  Dev: IDXGIDevice;
  Adapter: IDXGIAdapter;
  Factory: IDXGIFactory2;
  Back: ID3D11Texture2D;
  Format: DXGI_FORMAT;
begin
  S := Shared;
  Px := TargetPixels;
  if Texture <> nil then
    Format := DXGI_FORMAT(FastDxgiFormat(Texture.PixelFormat))
  else
    Format := DXGI_FORMAT_B8G8R8A8_UNORM;
  if Format = DXGI_FORMAT_UNKNOWN then
    Format := DXGI_FORMAT_B8G8R8A8_UNORM;
  case Multisample of
    TMultisample.TwoSamples: Wanted := 2;
    TMultisample.FourSamples: Wanted := 4;
  else
    Wanted := 1;
  end;
  FSamples := 1;
  while Wanted > 1 do
  begin
    if Succeeded(S.Device.CheckMultisampleQualityLevels(Format, Wanted, Levels)) and (Levels > 0) then
    begin
      FSamples := Wanted;
      Break;
    end;
    Wanted := Wanted div 2;
  end;
  if Texture = nil then
  begin
    // A window (TForm3D): flip-model swap chain on the canvas device.
    if not Supports(S.Device, IDXGIDevice, Dev) or Failed(Dev.GetAdapter(Adapter)) or
      Failed(Adapter.GetParent(IDXGIFactory2, Factory)) then
      raise EContext3DException.Create('FastContext3D11: DXGI 1.2 is required');
    FillChar(Chain, SizeOf(Chain), 0);
    Chain.Width := Px.Width;
    Chain.Height := Px.Height;
    Chain.Format := DXGI_FORMAT_B8G8R8A8_UNORM;
    Chain.SampleDesc.Count := 1;
    Chain.BufferUsage := DXGI_USAGE_RENDER_TARGET_OUTPUT;
    Chain.BufferCount := 2;
    Chain.Scaling := DXGI_SCALING_STRETCH;
    Chain.SwapEffect := DXGI_SWAP_EFFECT_FLIP_DISCARD;
    Chain.AlphaMode := DXGI_ALPHA_MODE_IGNORE;
    Check(Factory.CreateSwapChainForHwnd(S.Device, WindowHandleToPlatform(Parent).Wnd, @Chain, nil, nil, Swap),
      'CreateSwapChainForHwnd');
    Factory.MakeWindowAssociation(WindowHandleToPlatform(Parent).Wnd, DXGI_MWA_NO_WINDOW_CHANGES);
    FSwapChain := Swap;
    Check(Swap.GetBuffer(0, ID3D11Texture2D, Back), 'GetBuffer');
    Check(S.Device.CreateRenderTargetView(Back, nil, View), 'CreateRenderTargetView (window)');
    FBackView := View;
  end;
  if FSamples > 1 then
  begin
    FillChar(Desc, SizeOf(Desc), 0);
    Desc.Width := Px.Width;
    Desc.Height := Px.Height;
    Desc.MipLevels := 1;
    Desc.ArraySize := 1;
    Desc.Format := Format;
    Desc.SampleDesc.Count := FSamples;
    Desc.Usage := D3D11_USAGE_DEFAULT;
    Desc.BindFlags := D3D11_BIND_RENDER_TARGET;
    Check(S.Device.CreateTexture2D(Desc, nil, Tex), 'CreateTexture2D (multisampled)');
    Check(S.Device.CreateRenderTargetView(Tex, nil, View), 'CreateRenderTargetView (multisampled)');
    FMSColor := Tex;
    FMSView := View;
  end;
  if DepthStencil then
  begin
    FillChar(Desc, SizeOf(Desc), 0);
    Desc.Width := Px.Width;
    Desc.Height := Px.Height;
    Desc.MipLevels := 1;
    Desc.ArraySize := 1;
    Desc.Format := DXGI_FORMAT_D24_UNORM_S8_UINT;
    Desc.SampleDesc.Count := FSamples;
    Desc.Usage := D3D11_USAGE_DEFAULT;
    Desc.BindFlags := D3D11_BIND_DEPTH_STENCIL;
    Tex := nil;
    Check(S.Device.CreateTexture2D(Desc, nil, Tex), 'CreateTexture2D (depth)');
    Check(S.Device.CreateDepthStencilView(Tex, nil, DView), 'CreateDepthStencilView');
    FDepth := Tex;
    FDepthView := DView;
  end;
end;

procedure TFastContext3D11.DoCreateBuffer;
begin
  CreateTargets;
end;

procedure TFastContext3D11.DoResize;
begin
end;

procedure TFastContext3D11.DoFreeBuffer;
begin
  FMSColor := nil;
  FMSView := nil;
  FDepth := nil;
  FDepthView := nil;
  FBackView := nil;
  FSwapChain := nil;
end;

/// <summary>The render target view drawn into: the multisampled buffer, the window buffer or the texture.</summary>
function TFastContext3D11.TargetView: IInterface;
var
  T: TTexture11;
begin
  if FMSView <> nil then
    Exit(FMSView);
  if FBackView <> nil then
    Exit(FBackView);
  Result := nil;
  if (Texture <> nil) and (Texture.Handle <> 0) then
  begin
    T := TTexture11(Texture.Handle);
    T.Used := True;
    Result := T.RenderTarget;
  end;
end;

procedure TFastContext3D11.SetViewport(const ARect: TRect);
var
  VP: D3D11_VIEWPORT;
  Px: TSize;
begin
  if ARect.IsEmpty then
  begin
    Px := TargetPixels;
    VP.TopLeftX := 0;
    VP.TopLeftY := 0;
    VP.Width := Px.Width;
    VP.Height := Px.Height;
  end
  else
  begin
    VP.TopLeftX := ARect.Left;
    VP.TopLeftY := ARect.Top;
    VP.Width := ARect.Width;
    VP.Height := ARect.Height;
  end;
  VP.MinDepth := 0;
  VP.MaxDepth := 1;
  G.DC.RSSetViewports(1, @VP);
  G.ViewportChanged := not ARect.IsEmpty;
end;

procedure TFastContext3D11.BindTarget;
var
  View: ID3D11RenderTargetView;
begin
  View := ID3D11RenderTargetView(TargetView);
  G.DC.OMSetRenderTargets(1, View, ID3D11DepthStencilView(FDepthView));
  SetViewport(TRect.Empty);
  FScissorDirty := True;
end;

function TFastContext3D11.DoBeginScene: Boolean;
begin
  RunPendingReset;
  Result := (TargetView <> nil) and inherited DoBeginScene;
  if not Result then
    Exit;
  GScenes.Add(Self);
  BindTarget;
  Recorded;
end;

procedure TFastContext3D11.DoEndScene;
var
  T: TTexture11;
  Back: ID3D11Texture2D;
  Swap: IDXGISwapChain1;
begin
  if (FMSColor <> nil) and (Texture <> nil) and (Texture.Handle <> 0) then
  begin
    T := TTexture11(Texture.Handle);
    T.Used := True;
    G.DC.ResolveSubresource(T.Texture, 0, ID3D11Texture2D(FMSColor), 0, T.Format);
  end;
  if FSwapChain <> nil then
  begin
    Swap := IDXGISwapChain1(FSwapChain);
    if FMSColor <> nil then
    begin
      Swap.GetBuffer(0, ID3D11Texture2D, Back);
      G.DC.ResolveSubresource(Back, 0, ID3D11Texture2D(FMSColor), 0, DXGI_FORMAT_B8G8R8A8_UNORM);
    end;
  end;
  GScenes.Remove(Self);
  if GScenes.Count > 0 then
    GScenes.Last.BindTarget;
  Recorded;
  if (FSwapChain <> nil) and (BeginSceneCount = 1) then
  begin
    // The frame runs where the canvas executes its commands; present after it, there.
    TCanvas.Lock;
    try
      FastFlushDeferred;
      if Assigned(FastBridge.RunOnRender) then
        FastBridge.RunOnRender(
          procedure
          begin
            Swap.Present(0, 0);
          end);
      FastBridge.Sync();
      if not Assigned(FastBridge.RunOnRender) then
        Swap.Present(0, 0);
    finally
      TCanvas.Unlock;
    end;
  end;
  inherited;
end;

procedure TFastContext3D11.DoClear(const ATarget: TClearTargets; const AColor: TAlphaColor; const ADepth: Single;
  const AStencil: Cardinal);
var
  C: TFourSingleArray;
  Flags: Cardinal;
  View: ID3D11RenderTargetView;
begin
  if (TClearTarget.Color in ATarget) then
  begin
    View := ID3D11RenderTargetView(TargetView);
    if View <> nil then
    begin
      C[0] := TAlphaColorRec(AColor).R / 255;
      C[1] := TAlphaColorRec(AColor).G / 255;
      C[2] := TAlphaColorRec(AColor).B / 255;
      C[3] := TAlphaColorRec(AColor).A / 255;
      G.DC.ClearRenderTargetView(View, C);
    end;
  end;
  if FDepthView <> nil then
  begin
    Flags := 0;
    if TClearTarget.Depth in ATarget then
      Flags := Flags or Cardinal(D3D11_CLEAR_DEPTH);
    if TClearTarget.Stencil in ATarget then
      Flags := Flags or Cardinal(D3D11_CLEAR_STENCIL);
    if Flags <> 0 then
      G.DC.ClearDepthStencilView(ID3D11DepthStencilView(FDepthView), Flags, ADepth, Byte(AStencil));
  end;
  Recorded;
end;

procedure TFastContext3D11.DoDrawPrimitivesBatch(const AKind: TPrimitivesKind; const Vertices, Indices: Pointer;
  const VertexDeclaration: TVertexDeclaration; const VertexSize, VertexCount, IndexSize, IndexCount: Integer);
const
  Topologies: array[TPrimitivesKind] of D3D11_PRIMITIVE_TOPOLOGY = (D3D11_PRIMITIVE_TOPOLOGY_POINTLIST,
    D3D11_PRIMITIVE_TOPOLOGY_LINELIST, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
  BlendFactor: TFourSingleArray = (1, 1, 1, 1);
var
  S: TShared;
  DC: ID3D11DeviceContext;
  VSObj, PSObj: TShader11;
  Layout: ID3D11InputLayout;
  VOffset, IOffset, Stride: Cardinal;
  B: ID3D11BlendState;
  D: ID3D11DepthStencilState;
  R: ID3D11RasterizerState;
  CB: ID3D11Buffer;
  Views: array[0..7] of ID3D11ShaderResourceView;
  Samps: array[0..7] of ID3D11SamplerState;
  I, N: Integer;
  T: TTexture11;
  Rect: D3D11_RECT;
begin
  if (FVS = nil) or (FPS = nil) or (VertexCount <= 0) or (IndexCount <= 0) then
    Exit;
  S := Shared;
  DC := S.DC;
  VSObj := TShader11(FVS.Native as TObject);
  PSObj := TShader11(FPS.Native as TObject);
  if (VSObj = nil) or (PSObj = nil) then
    Exit;
  // A raw draw left a viewport of its own.
  if S.ViewportChanged then
    SetViewport(TRect.Empty);
  Layout := S.Layout(FVS, VertexLayout(VertexDeclaration));
  if Layout = nil then
    Exit;
  VOffset := S.Upload(S.Vertices, D3D11_BIND_VERTEX_BUFFER, Vertices, VertexSize * VertexCount);
  IOffset := S.Upload(S.Indices, D3D11_BIND_INDEX_BUFFER, Indices, IndexSize * IndexCount);
  Stride := VertexSize;
  DC.IASetVertexBuffers(0, 1, S.Vertices.Buffer, @Stride, @VOffset);
  if IndexSize = SizeOf(Cardinal) then
    DC.IASetIndexBuffer(S.Indices.Buffer, DXGI_FORMAT_R32_UINT, IOffset)
  else
    DC.IASetIndexBuffer(S.Indices.Buffer, DXGI_FORMAT_R16_UINT, IOffset);
  if Layout <> S.BoundLayout then
  begin
    DC.IASetInputLayout(Layout);
    S.BoundLayout := Layout;
  end;
  if Topologies[AKind] <> S.BoundTopology then
  begin
    DC.IASetPrimitiveTopology(Topologies[AKind]);
    S.BoundTopology := Topologies[AKind];
  end;
  if VSObj.VS <> S.BoundVS then
  begin
    DC.VSSetShader(VSObj.VS, nil, 0);
    S.BoundVS := VSObj.VS;
  end;
  if PSObj.PS <> S.BoundPS then
  begin
    DC.PSSetShader(PSObj.PS, nil, 0);
    S.BoundPS := PSObj.PS;
  end;
  if FVSDirty and (Length(FVSData) > 0) then
  begin
    CB := S.Constants(True, FVSData);
    if CB <> S.BoundVSConstants then
    begin
      DC.VSSetConstantBuffers(0, 1, CB);
      S.BoundVSConstants := CB;
    end;
    FVSDirty := False;
  end;
  if FPSDirty and (Length(FPSData) > 0) then
  begin
    CB := S.Constants(False, FPSData);
    if CB <> S.BoundPSConstants then
    begin
      DC.PSSetConstantBuffers(0, 1, CB);
      S.BoundPSConstants := CB;
    end;
    FPSDirty := False;
  end;
  if FStateDirty or S.Fresh then
  begin
    B := S.Blend;
    if B <> S.BoundBlend then
    begin
      DC.OMSetBlendState(B, BlendFactor, $FFFFFFFF);
      S.BoundBlend := B;
    end;
    D := S.DepthState;
    if (D <> S.BoundDepth) or (FStencilRef <> S.BoundRef) then
    begin
      DC.OMSetDepthStencilState(D, FStencilRef);
      S.BoundDepth := D;
      S.BoundRef := FStencilRef;
    end;
    R := S.Raster;
    if R <> S.BoundRaster then
    begin
      DC.RSSetState(R);
      S.BoundRaster := R;
    end;
    FStateDirty := False;
    S.Fresh := False;
  end;
  if FState.Scissor and FScissorDirty then
  begin
    Rect.Left := FScissor.Left;
    Rect.Top := FScissor.Top;
    Rect.Right := FScissor.Right;
    Rect.Bottom := FScissor.Bottom;
    DC.RSSetScissorRects(1, @Rect);
    FScissorDirty := False;
  end;
  if FUnitsDirty and (FPS.TextureUnits > 0) then
  begin
    N := FPS.TextureUnits;
    for I := 0 to N - 1 do
    begin
      if FUnits[I] <> nil then
      begin
        T := TTexture11(FUnits[I] as TObject);
        T.Used := True;
      end
      else
        T := S.Blank;
      Views[I] := T.View;
      Samps[I] := S.Sampler(FUnitFilters[I]);
    end;
    DC.PSSetShaderResources(0, N, Views[0]);
    DC.PSSetSamplers(0, N, Samps[0]);
    FUnitsDirty := False;
  end;
  DC.DrawIndexed(IndexCount, 0, 0);
  Recorded;
end;

{ Raw draws }

/// <summary>The FastCanvas shader of a TContextShader (made on first use).</summary>
function RawShader(const AShader: TContextShader): TFastShader;
begin
  Result := nil;
  if AShader = nil then
    Exit;
  if AShader.Handle = 0 then
    TContextManager.InitializeShader(AShader);
  Result := TFastShader(AShader.Handle);
end;

procedure TFastContext3D11.DrawRaw(const ADraw: TFastRawDraw);
const
  Topologies: array[TPrimitivesKind] of D3D11_PRIMITIVE_TOPOLOGY = (D3D11_PRIMITIVE_TOPOLOGY_POINTLIST,
    D3D11_PRIMITIVE_TOPOLOGY_LINELIST, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
  BlendFactor: TFourSingleArray = (1, 1, 1, 1);
var
  S: TShared;
  DC: ID3D11DeviceContext;
  VS, PS: TFastShader;
  VSObj, PSObj: TShader11;
  Layout: ID3D11InputLayout;
  VB, IB, CB: ID3D11Buffer;
  VOffset, IOffset, Stride: Cardinal;
  Views: array[0..7] of ID3D11ShaderResourceView;
  Samps: array[0..7] of ID3D11SamplerState;
  I, N: Integer;
  T: TRawTexture11;
  Rect: D3D11_RECT;
  Scissor: Boolean;
begin
  if (BeginSceneCount = 0) or (ADraw.IndexCount <= 0) then
    Exit;
  VS := RawShader(ADraw.VertexShader);
  PS := RawShader(ADraw.PixelShader);
  if (VS = nil) or (PS = nil) or (VS.Native = nil) or (PS.Native = nil) then
    Exit;
  VSObj := TShader11(VS.Native as TObject);
  PSObj := TShader11(PS.Native as TObject);
  S := Shared;
  DC := S.DC;
  Layout := S.Layout(VS, ADraw.Layout);
  if Layout = nil then
    Exit;
  // geometry
  Stride := ADraw.Stride;
  if ((ADraw.VertexBuffer <> nil) and (ADraw.VertexBuffer.Native = nil)) or
    ((ADraw.IndexBuffer <> nil) and (ADraw.IndexBuffer.Native = nil)) then
    Exit;
  if ADraw.VertexBuffer <> nil then
  begin
    VB := TRawBuffer11(ADraw.VertexBuffer.Native as TObject).Buffer;
    VOffset := ADraw.VertexOffset;
  end
  else
  begin
    if (ADraw.Vertices = nil) or (ADraw.VertexCount <= 0) then
      Exit;
    VOffset := S.Upload(S.Vertices, D3D11_BIND_VERTEX_BUFFER, ADraw.Vertices, ADraw.Stride * ADraw.VertexCount);
    VB := S.Vertices.Buffer;
  end;
  if ADraw.IndexBuffer <> nil then
  begin
    IB := TRawBuffer11(ADraw.IndexBuffer.Native as TObject).Buffer;
    IOffset := ADraw.IndexOffset;
  end
  else
  begin
    if ADraw.Indices = nil then
      Exit;
    IOffset := S.Upload(S.Indices, D3D11_BIND_INDEX_BUFFER, ADraw.Indices,
      ADraw.IndexCount * (2 + 2 * Ord(ADraw.Index32)));
    IB := S.Indices.Buffer;
  end;
  DC.IASetVertexBuffers(0, 1, VB, @Stride, @VOffset);
  if ADraw.Index32 then
    DC.IASetIndexBuffer(IB, DXGI_FORMAT_R32_UINT, IOffset)
  else
    DC.IASetIndexBuffer(IB, DXGI_FORMAT_R16_UINT, IOffset);
  if Layout <> S.BoundLayout then
  begin
    DC.IASetInputLayout(Layout);
    S.BoundLayout := Layout;
  end;
  if Topologies[ADraw.Kind] <> S.BoundTopology then
  begin
    DC.IASetPrimitiveTopology(Topologies[ADraw.Kind]);
    S.BoundTopology := Topologies[ADraw.Kind];
  end;
  if VSObj.VS <> S.BoundVS then
  begin
    DC.VSSetShader(VSObj.VS, nil, 0);
    S.BoundVS := VSObj.VS;
  end;
  if PSObj.PS <> S.BoundPS then
  begin
    DC.PSSetShader(PSObj.PS, nil, 0);
    S.BoundPS := PSObj.PS;
  end;
  // constants (FMX's draws set theirs again)
  if (ADraw.VSConstants <> nil) and (ADraw.VSConstantSize > 0) then
  begin
    CB := S.Constants(True, ADraw.VSConstants, ADraw.VSConstantSize);
    DC.VSSetConstantBuffers(0, 1, CB);
    S.BoundVSConstants := CB;
  end;
  if (ADraw.PSConstants <> nil) and (ADraw.PSConstantSize > 0) then
  begin
    CB := S.Constants(False, ADraw.PSConstants, ADraw.PSConstantSize);
    DC.PSSetConstantBuffers(0, 1, CB);
    S.BoundPSConstants := CB;
  end;
  FVSDirty := True;
  FPSDirty := True;
  // state
  Scissor := not ADraw.Scissor.IsEmpty;
  S.BoundBlend := S.RawBlend(ADraw.State);
  DC.OMSetBlendState(S.BoundBlend, BlendFactor, $FFFFFFFF);
  S.BoundDepth := S.RawDepth(ADraw.State);
  S.BoundRef := ADraw.StencilRef;
  DC.OMSetDepthStencilState(S.BoundDepth, ADraw.StencilRef);
  S.BoundRaster := S.RawRaster(ADraw.State, Scissor);
  DC.RSSetState(S.BoundRaster);
  FStateDirty := True;
  if Scissor then
  begin
    Rect.Left := ADraw.Scissor.Left;
    Rect.Top := ADraw.Scissor.Top;
    Rect.Right := ADraw.Scissor.Right;
    Rect.Bottom := ADraw.Scissor.Bottom;
    DC.RSSetScissorRects(1, @Rect);
  end;
  FScissorDirty := True;
  if not ADraw.Viewport.IsEmpty or S.ViewportChanged then
    SetViewport(ADraw.Viewport);
  // textures: the units the pixel shader samples, and any set beyond them
  N := PS.TextureUnits;
  for I := 0 to High(ADraw.Textures) do
    if ADraw.Textures[I] <> nil then
      N := Max(N, I + 1);
  if N > 0 then
  begin
    for I := 0 to N - 1 do
    begin
      if (ADraw.Textures[I] <> nil) and (ADraw.Textures[I].Native <> nil) then
      begin
        T := TRawTexture11(ADraw.Textures[I].Native as TObject);
        Views[I] := T.View;
      end
      else
        Views[I] := S.Blank.View;
      Samps[I] := S.RawSampler(ADraw.Samplers[I]);
    end;
    DC.PSSetShaderResources(0, N, Views[0]);
    DC.PSSetSamplers(0, N, Samps[0]);
  end;
  FUnitsDirty := True;
  if ADraw.IndexBuffer <> nil then
    DC.DrawIndexed(ADraw.IndexCount, 0, ADraw.BaseVertex)
  else
    DC.DrawIndexed(ADraw.IndexCount, 0, 0);
  Recorded;
end;

/// <summary>The texture the scene draws into (resolved, without multisampling).</summary>
function TFastContext3D11.TargetTexture: IInterface;
var
  T: TTexture11;
  Back: ID3D11Texture2D;
begin
  Result := nil;
  if (Texture <> nil) and (Texture.Handle <> 0) then
  begin
    T := TTexture11(Texture.Handle);
    T.Used := True;
    if FMSColor <> nil then
      G.DC.ResolveSubresource(T.Texture, 0, ID3D11Texture2D(FMSColor), 0, T.Format);
    Result := T.Texture;
  end
  else if FSwapChain <> nil then
  begin
    IDXGISwapChain1(FSwapChain).GetBuffer(0, ID3D11Texture2D, Back);
    if FMSColor <> nil then
      G.DC.ResolveSubresource(Back, 0, ID3D11Texture2D(FMSColor), 0, DXGI_FORMAT_B8G8R8A8_UNORM);
    Result := Back;
  end;
end;

procedure TFastContext3D11.CopyToTexture(const ADest: TFastTexture; const ADestX, ADestY: Integer;
  const ASource: TRect; const ADepth: Boolean);
var
  Src: ID3D11Texture2D;
  Dst: TRawTexture11;
  Box: D3D11_BOX;
begin
  if ADest = nil then
    Exit;
  TCanvas.Lock;
  try
    Dst := TRawTexture11(ADest.Native as TObject);
    if Dst = nil then
      Exit;
    if ADepth then
    begin
      // A depth buffer is copied whole (Direct3D 11 copies depth-stencil resources only so).
      if (FDepth = nil) or (FSamples > 1) then
        Exit;
      Shared.DC.CopyResource(Dst.Texture, ID3D11Texture2D(FDepth));
    end
    else
    begin
      Src := ID3D11Texture2D(TargetTexture);
      if Src = nil then
        Exit;
      Box.left := ASource.Left;
      Box.top := ASource.Top;
      Box.front := 0;
      Box.right := ASource.Right;
      Box.bottom := ASource.Bottom;
      Box.back := 1;
      Shared.DC.CopySubresourceRegion(Dst.Texture, 0, ADestX, ADestY, 0, Src, 0, @Box);
    end;
    Recorded;
  finally
    TCanvas.Unlock;
  end;
end;

procedure TFastContext3D11.ReadTarget(const ARect: TRect; const AKind: TFastReadKind; const ADest: Pointer;
  const APitch: Integer);
var
  Src, Staging: ID3D11Texture2D;
  Desc: TD3D11_TEXTURE2D_DESC;
  Mapped: D3D11_MAPPED_SUBRESOURCE;
  Ctx: ID3D11DeviceContext;
  R: TRect;
  X, Y: Integer;
  Texel: Cardinal;
  Row: PByte;
begin
  TCanvas.Lock;
  try
    if AKind = TFastReadKind.Color then
      Src := ID3D11Texture2D(TargetTexture)
    else if FSamples <= 1 then
      Src := ID3D11Texture2D(FDepth)
    else
      Src := nil;
    if Src = nil then
      Exit;
    // Everything recorded so far has to run before the read.
    FastFlushDeferred;
  finally
    TCanvas.Unlock;
  end;
  FastBridge.Sync();
  Src.GetDesc(Desc);
  R := TRect.Intersect(ARect, TRect.Create(0, 0, Desc.Width, Desc.Height));
  if R.IsEmpty then
    Exit;
  Desc.MipLevels := 1;
  Desc.ArraySize := 1;
  Desc.SampleDesc.Count := 1;
  Desc.SampleDesc.Quality := 0;
  Desc.Usage := D3D11_USAGE_STAGING;
  Desc.BindFlags := 0;
  Desc.CPUAccessFlags := D3D11_CPU_ACCESS_READ;
  Desc.MiscFlags := 0;
  Check(Shared.Device.CreateTexture2D(Desc, nil, Staging), 'CreateTexture2D (staging)');
  FastBridge.Lock();
  try
    Shared.Device.GetImmediateContext(Ctx);
    Ctx.CopyResource(Staging, Src);
    Check(Ctx.Map(Staging, 0, D3D11_MAP_READ, 0, Mapped), 'Map (staging)');
    try
      for Y := R.Top to R.Bottom - 1 do
      begin
        Row := PByte(Mapped.pData) + Cardinal(Y) * Mapped.RowPitch;
        case AKind of
          TFastReadKind.Color:
            Move((Row + R.Left * 4)^, (PByte(ADest) + (Y - R.Top) * APitch)^, R.Width * 4);
          TFastReadKind.Depth:
            for X := R.Left to R.Right - 1 do
            begin
              Texel := PCardinal(Row + X * 4)^;
              PSingle(PByte(ADest) + (Y - R.Top) * APitch + (X - R.Left) * 4)^ := (Texel and $FFFFFF) / $FFFFFF;
            end;
        else
          for X := R.Left to R.Right - 1 do
            (PByte(ADest) + (Y - R.Top) * APitch + (X - R.Left))^ := PCardinal(Row + X * 4)^ shr 24;
        end;
      end;
    finally
      Ctx.Unmap(Staging, 0);
    end;
  finally
    FastBridge.Unlock();
  end;
end;

class function TFastContext3D11.NewTextureObject(const ATexture: TFastTexture): IInterface;
var
  T: TRawTexture11;
  Desc: TD3D11_TEXTURE2D_DESC;
  View: TD3D11_SHADER_RESOURCE_VIEW_DESC;
begin
  T := TRawTexture11.Create;
  Result := T;
  FillChar(Desc, SizeOf(Desc), 0);
  Desc.Width := ATexture.Width;
  Desc.Height := ATexture.Height;
  Desc.MipLevels := ATexture.Mips;
  Desc.Format := DXGI_FORMAT(FastTextureDxgiFormat(ATexture.Format, False));
  Desc.SampleDesc.Count := 1;
  Desc.Usage := D3D11_USAGE_DEFAULT;
  Desc.BindFlags := D3D11_BIND_SHADER_RESOURCE;
  FillChar(View, SizeOf(View), 0);
  View.Format := DXGI_FORMAT(FastTextureDxgiFormat(ATexture.Format, True));
  if ATexture.Kind = TFastTextureKind.Cube then
  begin
    Desc.ArraySize := 6;
    Desc.MiscFlags := Ord(D3D11_RESOURCE_MISC_TEXTURECUBE);
    View.ViewDimension := D3D11_SRV_DIMENSION_TEXTURECUBE;
    View.TextureCube.MipLevels := ATexture.Mips;
  end
  else
  begin
    Desc.ArraySize := 1;
    View.ViewDimension := D3D11_SRV_DIMENSION_TEXTURE2D;
    View.Texture2D.MipLevels := ATexture.Mips;
  end;
  Check(Shared.Device.CreateTexture2D(Desc, nil, T.Texture), 'CreateTexture2D (raw)');
  Check(G.Device.CreateShaderResourceView(T.Texture, @View, T.View), 'CreateShaderResourceView (raw)');
end;

class procedure TFastContext3D11.UploadTextureObject(const ATexture: TFastTexture; const AObject: IInterface;
  const AFace, AMip, X, Y, AWidth, AHeight: Integer; const AData: Pointer; const ARowPitch: Integer);
var
  T: TRawTexture11;
  Box: D3D11_BOX;
  Src: PByte;
begin
  T := TRawTexture11(AObject as TObject);
  Box.left := X;
  Box.top := Y;
  Box.front := 0;
  Box.right := X + AWidth;
  Box.bottom := Y + AHeight;
  Box.back := 1;
  Src := AData;
  // UpdateSubresource of a deferred context without the driver's command lists offsets the source by the box
  // (documented workaround: the source pointer goes back by as much).
  if not Shared.DriverCommandLists then
  begin
    if FastTextureCompressed(ATexture.Format) then
      Dec(Src, (Y div 4) * ARowPitch + (X div 4) * FastTextureBlockBytes(ATexture.Format))
    else
      Dec(Src, Y * ARowPitch + X * FastTextureBlockBytes(ATexture.Format));
  end;
  G.DC.UpdateSubresource(T.Texture, Cardinal(AMip + AFace * ATexture.Mips), @Box, Src, ARowPitch, 0);
  Recorded;
end;

class function TFastContext3D11.NewBufferObject(const ABuffer: TFastBuffer): IInterface;
var
  B: TRawBuffer11;
  Desc: TD3D11_BUFFER_DESC;
begin
  B := TRawBuffer11.Create;
  Result := B;
  FillChar(Desc, SizeOf(Desc), 0);
  Desc.ByteWidth := (ABuffer.Size + 15) and not 15;
  Desc.Usage := D3D11_USAGE_DEFAULT;
  if ABuffer.IsIndex then
    Desc.BindFlags := D3D11_BIND_INDEX_BUFFER
  else
    Desc.BindFlags := D3D11_BIND_VERTEX_BUFFER;
  Check(Shared.Device.CreateBuffer(Desc, nil, B.Buffer), 'CreateBuffer (raw)');
end;

class procedure TFastContext3D11.WriteBufferObject(const ABuffer: TFastBuffer; const AObject: IInterface;
  const AOffset: Integer; const AData: Pointer; const ASize: Integer);
var
  Box: D3D11_BOX;
  Src: PByte;
begin
  Box.left := AOffset;
  Box.top := 0;
  Box.front := 0;
  Box.right := AOffset + ASize;
  Box.bottom := 1;
  Box.back := 1;
  Src := AData;
  if not Shared.DriverCommandLists then
    Dec(Src, AOffset);
  G.DC.UpdateSubresource(TRawBuffer11(AObject as TObject).Buffer, 0, @Box, Src, 0, 0);
  Recorded;
end;

{ Textures }

class function TFastContext3D11.TextureObject(const ATexture: TTexture): IInterface;
begin
  if ATexture.Handle = 0 then
    ATexture.Initialize;
  if ATexture.Handle <> 0 then
    Result := TTexture11(ATexture.Handle)
  else
    Result := nil;
end;

class procedure TFastContext3D11.DoInitializeTexture(const Texture: TTexture);
var
  T: TTexture11;
  Desc: TD3D11_TEXTURE2D_DESC;
  Format: Integer;
begin
  if (Texture.Width <= 0) or (Texture.Height <= 0) then
    Exit;
  if Texture.PixelFormat = TPixelFormat.None then
    Texture.PixelFormat := TPixelFormat.BGRA;
  Format := FastDxgiFormat(Texture.PixelFormat);
  if Format = 0 then
    raise EContext3DException.CreateFmt('FastContext3D11: no texture format for pixel format %d',
      [Ord(Texture.PixelFormat)]);
  T := TTexture11.Create;
  IInterface(T)._AddRef;
  try
    T.Format := DXGI_FORMAT(Format);
    T.Width := Texture.Width;
    T.Height := Texture.Height;
    T.MipMaps := TTextureStyle.MipMaps in Texture.Style;
    FillChar(Desc, SizeOf(Desc), 0);
    Desc.Width := Texture.Width;
    Desc.Height := Texture.Height;
    Desc.ArraySize := 1;
    Desc.Format := T.Format;
    Desc.SampleDesc.Count := 1;
    Desc.Usage := D3D11_USAGE_DEFAULT;
    Desc.BindFlags := D3D11_BIND_SHADER_RESOURCE;
    if T.MipMaps then
    begin
      // A full chain made by GenerateMips after every update.
      Desc.MipLevels := 0;
      Desc.BindFlags := Desc.BindFlags or D3D11_BIND_RENDER_TARGET;
      Desc.MiscFlags := Ord(D3D11_RESOURCE_MISC_GENERATE_MIPS);
    end
    else
      Desc.MipLevels := 1;
    if TTextureStyle.RenderTarget in Texture.Style then
      Desc.BindFlags := Desc.BindFlags or D3D11_BIND_RENDER_TARGET;
    Check(Shared.Device.CreateTexture2D(Desc, nil, T.Texture), 'CreateTexture2D');
    Check(G.Device.CreateShaderResourceView(T.Texture, nil, T.View), 'CreateShaderResourceView');
  except
    IInterface(T)._Release;
    raise;
  end;
  ITextureAccess(Texture).Handle := THandle(T);
end;

class procedure TFastContext3D11.DoFinalizeTexture(const Texture: TTexture);
var
  T: TTexture11;
begin
  T := TTexture11(Texture.Handle);
  ITextureAccess(Texture).Handle := 0;
  // Command lists that use it keep the D3D11 objects alive.
  if T <> nil then
    IInterface(T)._Release;
end;

class procedure TFastContext3D11.DoUpdateTexture(const Texture: TTexture; const Bits: Pointer; const Pitch: Integer);
var
  T: TTexture11;
  Ctx: ID3D11DeviceContext;
begin
  if Texture.Handle = 0 then
    Texture.Initialize;
  T := TTexture11(Texture.Handle);
  if (T = nil) or (Bits = nil) then
    Exit;
  if not T.Used then
  begin
    // No command refers to the texture yet (a new texture, or one made again after a device reset, in a message
    // handler on any thread): straight into the texture on the immediate context, under the device lock only. Taking
    // TCanvas.Lock there can deadlock with a main thread that holds it and waits for the message manager.
    FastBridge.Lock();
    try
      Shared.Device.GetImmediateContext(Ctx);
      Ctx.UpdateSubresource(T.Texture, 0, nil, Bits, Pitch, 0);
      if T.MipMaps then
        Ctx.GenerateMips(T.View);
    finally
      FastBridge.Unlock();
    end;
    Exit;
  end;
  TCanvas.Lock;
  try
    // In program order with the draws: a deferred context copies the data into the command list.
    Shared.DC.UpdateSubresource(T.Texture, 0, nil, Bits, Pitch, 0);
    if T.MipMaps then
      G.DC.GenerateMips(T.View);
    Recorded;
  finally
    TCanvas.Unlock;
  end;
end;

class function TFastContext3D11.DoBitmapToTexture(const Bitmap: TBitmap): TTexture;
var
  Tex: ID3D11Texture2D;
  T: TTexture11;
  Desc: TD3D11_TEXTURE2D_DESC;
begin
  // A bitmap of the canvas is a texture on the same device: use it as it is (no read-back, no upload). The caller
  // owns the TTexture (TFilterContext3D frees it, FMX.Filter.pas:1870-1872); freeing it drops this reference only.
  Tex := FastBridge.BitmapTexture(Bitmap);
  if Tex = nil then
    Exit(inherited DoBitmapToTexture(Bitmap));
  Tex.GetDesc(Desc);
  T := TTexture11.Create;
  IInterface(T)._AddRef;
  try
    T.Texture := Tex;
    // The canvas draws into and from it.
    T.Used := True;
    T.Format := Desc.Format;
    T.Width := Desc.Width;
    T.Height := Desc.Height;
    Check(Shared.Device.CreateShaderResourceView(Tex, nil, T.View), 'CreateShaderResourceView (bitmap)');
    Result := TTexture.Create;
    // Not recreated after a device loss: it belongs to the bitmap.
    Result.Style := [TTextureStyle.RenderTarget, TTextureStyle.Volatile];
    Result.PixelFormat := TPixelFormat.BGRA;
    Result.SetSize(Bitmap.Width, Bitmap.Height);
    ITextureAccess(Result).TextureScale := Bitmap.BitmapScale;
  except
    IInterface(T)._Release;
    raise;
  end;
  ITextureAccess(Result).Handle := THandle(T);
end;

procedure TFastContext3D11.DoCopyToBitmap(const Dest: TBitmap; const ARect: TRect);
var
  DestTex: ID3D11Texture2D;
  T: TTexture11;
  R: TRect;
  Box: D3D11_BOX;
begin
  // A bitmap of the canvas: a GPU copy in the command stream (the stock path reads the target into memory and
  // uploads it again). The texture holds the resolved samples once the scene has ended.
  DestTex := FastBridge.BitmapTexture(Dest);
  if (DestTex = nil) or (Texture = nil) or (Texture.Handle = 0) or ((FMSColor <> nil) and (BeginSceneCount > 0)) or
    (Texture.PixelFormat <> TPixelFormat.BGRA) then
  begin
    inherited;
    Exit;
  end;
  T := TTexture11(Texture.Handle);
  T.Used := True;
  R := TRect.Intersect(ARect, TRect.Create(0, 0, Min(T.Width, Dest.Width), Min(T.Height, Dest.Height)));
  if R.IsEmpty then
    Exit;
  Box.left := R.Left;
  Box.top := R.Top;
  Box.front := 0;
  Box.right := R.Right;
  Box.bottom := R.Bottom;
  Box.back := 1;
  TCanvas.Lock;
  try
    Shared.DC.CopySubresourceRegion(DestTex, 0, R.Left, R.Top, 0, T.Texture, 0, @Box);
    FastBridge.BitmapWritten(Dest);
    Recorded;
  finally
    TCanvas.Unlock;
  end;
end;

procedure TFastContext3D11.DoCopyToBits(const Bits: Pointer; const Pitch: Integer; const ARect: TRect);
var
  Src, Staging: ID3D11Texture2D;
  Desc: TD3D11_TEXTURE2D_DESC;
  Mapped: D3D11_MAPPED_SUBRESOURCE;
  Ctx: ID3D11DeviceContext;
  R: TRect;
  Y: Integer;
begin
  if Texture <> nil then
  begin
    if Texture.Handle = 0 then
      Exit;
    Src := TTexture11(Texture.Handle).Texture;
  end
  else if FSwapChain <> nil then
    IDXGISwapChain1(FSwapChain).GetBuffer(0, ID3D11Texture2D, Src)
  else
    Exit;
  Src.GetDesc(Desc);
  R := TRect.Intersect(ARect, TRect.Create(0, 0, Desc.Width, Desc.Height));
  if R.IsEmpty then
    Exit;
  // Everything recorded so far has to run before the read.
  TCanvas.Lock;
  try
    FastFlushDeferred;
  finally
    TCanvas.Unlock;
  end;
  FastBridge.Sync();
  Desc.MipLevels := 1;
  Desc.Usage := D3D11_USAGE_STAGING;
  Desc.BindFlags := 0;
  Desc.CPUAccessFlags := D3D11_CPU_ACCESS_READ;
  Desc.MiscFlags := 0;
  Check(Shared.Device.CreateTexture2D(Desc, nil, Staging), 'CreateTexture2D (staging)');
  FastBridge.Lock();
  try
    Shared.Device.GetImmediateContext(Ctx);
    Ctx.CopySubresourceRegion(Staging, 0, 0, 0, 0, Src, 0, nil);
    Check(Ctx.Map(Staging, 0, D3D11_MAP_READ, 0, Mapped), 'Map (staging)');
    try
      for Y := R.Top to R.Bottom - 1 do
        Move((PByte(Mapped.pData) + Cardinal(Y) * Mapped.RowPitch + Cardinal(R.Left) * 4)^,
          (PByte(Bits) + Y * Pitch + R.Left * 4)^, R.Width * 4);
    finally
      Ctx.Unmap(Staging, 0);
    end;
  finally
    FastBridge.Unlock();
  end;
end;

{ Shaders }

class procedure TFastContext3D11.CreateNativeShader(const AShader: TFastShader);
var
  S: TShader11;
begin
  S := TShader11.Create;
  AShader.Native := S;
  if AShader.Kind = TContextShaderKind.VertexShader then
    Check(Shared.Device.CreateVertexShader(@AShader.Code[0], Length(AShader.Code), nil, @S.VS), 'CreateVertexShader')
  else
    Check(Shared.Device.CreatePixelShader(@AShader.Code[0], Length(AShader.Code), nil, S.PS), 'CreatePixelShader');
end;

{ Device loss and installation }

/// <summary>The canvas is about to replace the device (TContextLostMessage has been sent: FMX finalized its fragile
/// textures and shaders). Everything made on the old device goes.</summary>
procedure ContextsDeviceLost;
var
  C: TFastContext3D11;
begin
  FastDeferredPending := False;
  // Raw textures and buffers get new (empty) objects on the new device when used next.
  TFastContext3D.RawDeviceLost;
  if G = nil then
    Exit;
  for C in GContexts do
    C.FreeBuffer;
  TFastContext3D.ResetShaderObjects;
  FreeAndNil(G);
end;

var
  /// <summary>1: the device was replaced on another thread; the contexts make their buffers on the main thread.
  /// </summary>
  GResetPending: Integer;

/// <summary>Main thread, outside any 3D scene: the contexts make their buffers on the new device, and FMX sends its
/// states again.</summary>
procedure RunPendingReset;
var
  Contexts: TArray<TFastContext3D11>;
  C: TFastContext3D11;
begin
  if (GResetPending = 0) or (GScenes.Count > 0) then
    Exit;
  AtomicExchange(GResetPending, 0);
  TFastContext3D.ResetDeviceState;
  TContext3D.ResetStates;
  // The contexts registered themselves with the old shared object.
  Contexts := GContexts.ToArray;
  for C in Contexts do
    C.CreateBuffer;
end;

/// <summary>The canvas has a new device and TContextResetMessage has been sent, on whichever thread found the device
/// gone. The buffers are made on the main thread before its next 3D scene: a scene in progress there must not see
/// them replaced (as found in the Direct3D 12 context).</summary>
procedure ContextsDeviceReset;
begin
  AtomicExchange(GResetPending, 1);
  if GetCurrentThreadId = MainThreadID then
    RunPendingReset
  else
    TThread.ForceQueue(nil,
      procedure
      begin
        TCanvas.Lock;
        try
          RunPendingReset;
        finally
          TCanvas.Unlock;
        end;
      end);
end;

procedure Shutdown;
begin
  FastDeferredPending := False;
  TFastContext3D.ShutdownBase;
  FreeAndNil(G);
  // The last step of FMX's shutdown (FinalizeForms): the forms and their contexts are gone.
  if (GContexts <> nil) and (GContexts.Count = 0) then
  begin
    FreeAndNil(GContexts);
    FreeAndNil(GScenes);
  end;
end;

procedure InstallFastContext3D11;
begin
  if GContexts = nil then
  begin
    GContexts := TList<TFastContext3D11>.Create;
    GScenes := TList<TFastContext3D11>.Create;
  end;
  TFastContext3D.ResetDeviceState;
  TFastContext3D.SetInstalled(TFastContext3D11);
  InstallContextService(TFastContext3D11, Shutdown);
  FastBridge.DeviceLost := ContextsDeviceLost;
  FastBridge.DeviceReset := ContextsDeviceReset;
end;

end.
