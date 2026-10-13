{ Ray tracing of FastCanvas.Context3D12 (included in its implementation). Render thread, device lock held, unless a
  routine says otherwise.

  The opaque objects of a scene with ray-traced effects or RayScene (a TCmdRayObject before their draw) go into a
  top-level acceleration structure as instances of bottom-level structures, one per geometry: a geometry is built
  once from the vertices and indices of its first draw and kept while scenes use it (one with an application key,
  RayGeometryKey, is built again in place when its version changes). The top-level structure is built when the scene
  first needs it: at its first application pass (TCmdRayPass), again when objects were added since, and at the end
  of the scene for the built-in effects (TCmdRay), where full-screen passes (Shaders\FastRay.hlsl) trace rays from
  the pixels' surfaces:
  - shadows and ambient occlusion darken the color already in the target: hard shadows in one pass; soft shadows and
    ambient occlusion (several rays per pixel) at half resolution into a factor texture, then smoothed and upsampled
    into the target;
  - reflections blend into it what the surfaces of light materials mirror. For them every geometry keeps a copy of
    its vertices and indices on the GPU and every instance a record of its material (normals, texture coordinates
    and colors of the surfaces the reflected rays hit).
  Application passes run the application's DXIL (compute or full-screen pixel shaders) with a fixed root signature
  (Shaders\FastRayApp.hlsli) over the scene, the depth buffer and the application's buffers, images and textures. }

{$I FastCanvas.RayShaders.inc}

const
  /// <summary>Scenes after which a geometry identified by its contents that no scene used is released.</summary>
  BlasKeepPasses = 300;
  /// <summary>Scenes after which a geometry with an application key that no scene used is released (the keys of
  /// animated models change with the models on screen).</summary>
  KeyedKeepPasses = 3;
  NoGeometry = $FFFFFFFF;
  /// <summary>Application passes: the states of the resources they read.</summary>
  StateRayRead = TD3D12_RESOURCE_STATES(Ord(D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE) or
    Ord(D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE));

type
  /// <summary>Bottom-level acceleration structure of one geometry, and (reflections) a copy of its vertices and
  /// indices the shaders read: the vertices, then the indices from IndexOffset.</summary>
  TBlas = class
  public
    Resource: ID3D12Resource;
    Address: UInt64;
    /// <summary>Bytes of Resource: a rebuild that needs more takes a new one.</summary>
    Capacity: UInt64;
    LastUse: Integer;
    Data: ID3D12Resource;
    DataView: TD3D12_CPU_DESCRIPTOR_HANDLE;
    Stride, PositionOffset, NormalOffset, TexCoordOffset, IndexOffset: Integer;
    Index16: Boolean;
    /// <summary>The ray pass that numbered it (Slot: its place in the pass's geometry table).</summary>
    Stamp, Slot: Integer;
    /// <summary>A geometry with an application key: the version built, whether it was built again (later builds
    /// prefer speed), its scratch memory, and the list and barrier epoch of its last build (a rebuild before the next
    /// barrier would overwrite memory that build still uses).</summary>
    Keyed, Rebuilt: Boolean;
    Version: Cardinal;
    Scratch: ID3D12Resource;
    ScratchSize: UInt64;
    BuildGen, BuildEpoch: Integer;
    destructor Destroy; override;
  end;

  /// <summary>An instance of a scene with reflections, as FastRay.hlsl reads it (InstanceData).</summary>
  TRayInstanceData = packed record
    Geometry: Cardinal;
    Texture: Integer;
    Kind: Cardinal;
    F0: Single;
    Diffuse, Ambient, Emission, Specular: array[0..3] of Single;
    Stride, PositionOffset: Cardinal;
    NormalOffset, TexCoordOffset: Integer;
    IndexOffset, Index16: Cardinal;
    Gloss: Single;
    Pad: Cardinal;
  end;

  TRayState = class
  public
    /// <summary>Unique for the process: application shaders keep pipelines made for one state.</summary>
    Serial: Integer;
    Device5: ID3D12Device5;
    Blas: TObjectDictionary<UInt64, TBlas>;
    /// <summary>Geometries with an application key (RayGeometryKey).</summary>
    Keyed: TObjectDictionary<UInt64, TBlas>;
    Stale: TList<UInt64>;
    Tlas, TlasScratch: ID3D12Resource;
    TlasSize, ScratchSize: UInt64;
    /// <summary>The scene and the number of its instances the top-level structure holds.</summary>
    TlasScene, TlasCount: Integer;
    /// <summary>Global UAV barriers recorded so far, and the list and epoch of the last command that read the
    /// acceleration structures (a pass): a geometry built again in place must not overwrite what it still reads.
    /// </summary>
    Epoch, ReadGen, ReadEpoch: Integer;
    Root: ID3D12RootSignature;
    /// <summary>The root signature of application passes (FastRayApp.hlsli), made on first use.</summary>
    AppRoot: ID3D12RootSignature;
    Psos: TDictionary<Cardinal, ID3D12PipelineState>;
    /// <summary>Scenes with ray tracing so far (a geometry's LastUse is one of them).</summary>
    Pass: Integer;
    /// <summary>The factor of soft shadows and ambient occlusion before it is smoothed (R8, half the target's size).
    /// </summary>
    Factor: IInterface;
    // A ray pass with reflections: the geometries and textures its instances use, numbered.
    Geometries: TList<TBlas>;
    Textures: TList<TTexture12>;
    TextureSlots: TDictionary<Pointer, Integer>;
    Records: TArray<TRayInstanceData>;
    List4: ID3D12GraphicsCommandList4;
    List4Ctx: Pointer;
    List4Gen: Integer;
    constructor Create(const ADevice5: ID3D12Device5);
    destructor Destroy; override;
    function List: ID3D12GraphicsCommandList4;
    /// <summary>AKind: 0 hard shadows straight into the target (multiplied), 1 soft shadows and ambient occlusion
    /// into the factor texture, 2 the factor smoothed (and hard shadows) into the target (multiplied), 3 reflections
    /// blended into the target. AMultisample: the depth buffer has samples.</summary>
    function Pso(const AKind: Integer; const AFormat: TDXGI_FORMAT; const ASamples: Integer;
      const AMultisample: Boolean): ID3D12PipelineState;
    function AppRootSignature: ID3D12RootSignature;
  end;

  /// <summary>The GPU memory of a TFastRayBuffer or TFastRayImage on the current device. Made on the recording thread
  /// (the device is free-threaded); its state and views belong to the render thread.</summary>
  TRayResource12 = class(TInterfacedObject)
  public
    Resource: ID3D12Resource;
    IsBuffer: Boolean;
    Format: TDXGI_FORMAT;
    /// <summary>Buffers: bytes of Resource (a multiple of 16).</summary>
    Bytes: UInt64;
    Width, Height: Integer;
    State: TD3D12_RESOURCE_STATES;
    /// <summary>Buffers: the list State was set in (buffers go back to the common state after every list).</summary>
    StateCtx: Pointer;
    StateGen: Integer;
    /// <summary>The recording context whose pools hold Srv and Uav.</summary>
    Owner: TGpu12Context;
    Srv, Uav: TD3D12_CPU_DESCRIPTOR_HANDLE;
    destructor Destroy; override;
    /// <summary>The resource in AState for the commands that follow.</summary>
    procedure Use(const AState: TD3D12_RESOURCE_STATES);
    function ShaderView: TD3D12_CPU_DESCRIPTOR_HANDLE;
    function UnorderedView: TD3D12_CPU_DESCRIPTOR_HANDLE;
  end;

  /// <summary>An application shader (TFastRayShader) and its pipelines. The pipelines are made on the render thread
  /// for one ray state (Serial) and dropped with it (a device loss).</summary>
  TRayShader12 = class(TInterfacedObject)
  public
    Code: TBytes;
    Compute: Boolean;
    Blend: TFastRayBlend;
    Serial: Integer;
    /// <summary>Compute: key 0; pixel: per target format. nil: could not be made (not tried again).</summary>
    Psos: TDictionary<Cardinal, ID3D12PipelineState>;
    FError: string;
    constructor Create(const ADxil: array of Byte; const ACompute: Boolean; const ABlend: TFastRayBlend);
    destructor Destroy; override;
    /// <summary>Device lock held: the pipelines go (once the GPU is done with them).</summary>
    procedure ClearPsos;
    function Pso(const S: TRayState; const AFormat: TDXGI_FORMAT): ID3D12PipelineState;
    /// <summary>Any thread.</summary>
    function Error: string;
  end;

var
  /// <summary>DXR tier 1.1 on the device: -1 not known yet, 0 no, 1 yes.</summary>
  GRaySupport: Integer = -1;
  GRayStateSerial: Integer;
  /// <summary>The application shaders that exist (device lock).</summary>
  GRayShaders: TList<TRayShader12>;

function RaySupported: Boolean;
var
  Options: TD3D12_FEATURE_DATA_D3D12_OPTIONS5;
begin
  if GRaySupport < 0 then
  begin
    GRaySupport := 0;
    TFastDevice.Ensure;
    if TFastDevice.D3D12 <> nil then
    begin
      FillChar(Options, SizeOf(Options), 0);
      if Succeeded(TFastDevice.D3D12.CheckFeatureSupport(D3D12_FEATURE_D3D12_OPTIONS5, @Options, SizeOf(Options))) and
        (Ord(Options.RaytracingTier) >= Ord(D3D12_RAYTRACING_TIER_1_1)) then
        GRaySupport := 1;
    end;
  end;
  Result := GRaySupport = 1;
end;

function NewBuffer(const ASize: UInt64; const AState: TD3D12_RESOURCE_STATES): ID3D12Resource;
var
  Props: TD3D12_HEAP_PROPERTIES;
  Desc: TD3D12_RESOURCE_DESC;
begin
  Props := TD3D12_HEAP_PROPERTIES.Create(D3D12_HEAP_TYPE_DEFAULT);
  Desc := TD3D12_RESOURCE_DESC.CreateBuffer(AlignUp(ASize, D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BYTE_ALIGNMENT),
    D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
  Check(Gpu12.Device.CreateCommittedResource(@Props, D3D12_HEAP_FLAG_NONE, @Desc, AState, nil, IID_ID3D12Resource,
    Result), 'CreateCommittedResource (ray tracing)');
end;

{ TBlas }

destructor TBlas.Destroy;
var
  C: TGpu12Context;
begin
  C := Gpu12Current;
  if C <> nil then
  begin
    C.Retire(Resource);
    C.Retire(Data);
    C.Retire(Scratch);
    if Data <> nil then
      C.SrvPool.Release(DataView);
  end;
  inherited;
end;

{ TRayState }

constructor TRayState.Create(const ADevice5: ID3D12Device5);
var
  Ranges: array[0..2] of TD3D12_DESCRIPTOR_RANGE;
  Params: array[0..5] of TD3D12_ROOT_PARAMETER;
  Sampler: TD3D12_STATIC_SAMPLER_DESC;
  RootDesc: TD3D12_ROOT_SIGNATURE_DESC;
  Blob, Errors: ID3DBlob;
  Res: HResult;
begin
  inherited Create;
  Serial := AtomicIncrement(GRayStateSerial);
  Device5 := ADevice5;
  Blas := TObjectDictionary<UInt64, TBlas>.Create([doOwnsValues]);
  Keyed := TObjectDictionary<UInt64, TBlas>.Create([doOwnsValues]);
  Stale := TList<UInt64>.Create;
  TlasScene := -1;
  Psos := TDictionary<Cardinal, ID3D12PipelineState>.Create;
  Geometries := TList<TBlas>.Create;
  Textures := TList<TTexture12>.Create;
  TextureSlots := TDictionary<Pointer, Integer>.Create;
  // b0 constants; t0 the scene (root shader resource view of the acceleration structure); t1 the depth buffer and t2
  // the factor texture; t3 the instance records (reflections); the geometries (space 1) and textures (space 2) of a
  // pass with reflections, as many as it has; s0 linear, repeating.
  Ranges[0].Init(D3D12_DESCRIPTOR_RANGE_TYPE_SRV, 2, 1);
  Ranges[1].Init(D3D12_DESCRIPTOR_RANGE_TYPE_SRV, Cardinal(-1), 0, 1);
  Ranges[2].Init(D3D12_DESCRIPTOR_RANGE_TYPE_SRV, Cardinal(-1), 0, 2);
  Params[0].InitAsConstantBufferView(0, 0, D3D12_SHADER_VISIBILITY_PIXEL);
  Params[1].InitAsShaderResourceView(0, 0, D3D12_SHADER_VISIBILITY_PIXEL);
  Params[2].InitAsDescriptorTable(1, @Ranges[0], D3D12_SHADER_VISIBILITY_PIXEL);
  Params[3].InitAsShaderResourceView(3, 0, D3D12_SHADER_VISIBILITY_PIXEL);
  Params[4].InitAsDescriptorTable(1, @Ranges[1], D3D12_SHADER_VISIBILITY_PIXEL);
  Params[5].InitAsDescriptorTable(1, @Ranges[2], D3D12_SHADER_VISIBILITY_PIXEL);
  Sampler := TD3D12_STATIC_SAMPLER_DESC.Create(0, D3D12_FILTER_MIN_MAG_MIP_LINEAR, D3D12_TEXTURE_ADDRESS_MODE_WRAP,
    D3D12_TEXTURE_ADDRESS_MODE_WRAP, D3D12_TEXTURE_ADDRESS_MODE_WRAP, 0, 1, D3D12_COMPARISON_FUNC_NEVER,
    D3D12_STATIC_BORDER_COLOR_TRANSPARENT_BLACK, 0, D3D12_FLOAT32_MAX, D3D12_SHADER_VISIBILITY_PIXEL);
  RootDesc.Init(Length(Params), @Params[0], 1, @Sampler, D3D12_ROOT_SIGNATURE_FLAG_NONE);
  Res := D3D12SerializeRootSignature(RootDesc, D3D_ROOT_SIGNATURE_VERSION_1, @Blob, @Errors);
  if Failed(Res) and (Errors <> nil) then
    raise EContext3DException.CreateFmt('FastContext3D12: ray root signature: %s',
      [string(PAnsiChar(Errors.GetBufferPointer))]);
  Check(Res, 'D3D12SerializeRootSignature (ray)');
  Check(Device5.CreateRootSignature(0, Blob.GetBufferPointer, Blob.GetBufferSize, IID_ID3D12RootSignature, Root),
    'CreateRootSignature (ray)');
end;

destructor TRayState.Destroy;
var
  C: TGpu12Context;
  P: ID3D12PipelineState;
begin
  Blas.Free;
  Keyed.Free;
  Stale.Free;
  Geometries.Free;
  Textures.Free;
  TextureSlots.Free;
  // Lists not executed yet may use them.
  C := Gpu12Current;
  if C <> nil then
  begin
    C.Retire(Tlas);
    C.Retire(TlasScratch);
    C.Retire(Root);
    C.Retire(AppRoot);
    for P in Psos.Values do
      C.Retire(P);
  end;
  Psos.Free;
  inherited;
end;

function TRayState.AppRootSignature: ID3D12RootSignature;
const
  Filters: array[0..3] of TD3D12_FILTER = (D3D12_FILTER_MIN_MAG_MIP_LINEAR, D3D12_FILTER_MIN_MAG_MIP_LINEAR,
    D3D12_FILTER_MIN_MAG_MIP_POINT, D3D12_FILTER_MIN_MAG_MIP_POINT);
  Modes: array[0..3] of TD3D12_TEXTURE_ADDRESS_MODE = (D3D12_TEXTURE_ADDRESS_MODE_WRAP,
    D3D12_TEXTURE_ADDRESS_MODE_CLAMP, D3D12_TEXTURE_ADDRESS_MODE_CLAMP, D3D12_TEXTURE_ADDRESS_MODE_WRAP);
var
  Ranges: array[0..6] of TD3D12_DESCRIPTOR_RANGE;
  Params: array[0..9] of TD3D12_ROOT_PARAMETER;
  Samplers: array[0..3] of TD3D12_STATIC_SAMPLER_DESC;
  RootDesc: TD3D12_ROOT_SIGNATURE_DESC;
  Blob, Errors: ID3DBlob;
  Res: HResult;
  I: Integer;
begin
  if AppRoot <> nil then
    Exit(AppRoot);
  // b0 frame constants, b1 application constants, t0 the scene (root shader resource view), t1 the depth buffer; the
  // SRV entries as raw buffers (space 1), float textures (space 2) and uint textures (space 3), the UAV entries the
  // same way: one table typed three times, each typing a root parameter of its own over the same descriptors.
  Ranges[0].Init(D3D12_DESCRIPTOR_RANGE_TYPE_SRV, 1, 1);
  for I := 1 to 3 do
  begin
    Ranges[I].Init(D3D12_DESCRIPTOR_RANGE_TYPE_SRV, Cardinal(-1), 0, I);
    Ranges[I + 3].Init(D3D12_DESCRIPTOR_RANGE_TYPE_UAV, Cardinal(-1), 0, I);
  end;
  Params[0].InitAsConstantBufferView(0);
  Params[1].InitAsConstantBufferView(1);
  Params[2].InitAsShaderResourceView(0);
  for I := 0 to High(Ranges) do
    Params[3 + I].InitAsDescriptorTable(1, @Ranges[I]);
  for I := 0 to High(Samplers) do
    Samplers[I] := TD3D12_STATIC_SAMPLER_DESC.Create(I, Filters[I], Modes[I], Modes[I], Modes[I], 0, 1,
      D3D12_COMPARISON_FUNC_NEVER, D3D12_STATIC_BORDER_COLOR_TRANSPARENT_BLACK, 0, D3D12_FLOAT32_MAX);
  RootDesc.Init(Length(Params), @Params[0], Length(Samplers), @Samplers[0], D3D12_ROOT_SIGNATURE_FLAG_NONE);
  Res := D3D12SerializeRootSignature(RootDesc, D3D_ROOT_SIGNATURE_VERSION_1, @Blob, @Errors);
  if Failed(Res) and (Errors <> nil) then
    raise EContext3DException.CreateFmt('FastContext3D12: application ray root signature: %s',
      [string(PAnsiChar(Errors.GetBufferPointer))]);
  Check(Res, 'D3D12SerializeRootSignature (application ray passes)');
  Check(Device5.CreateRootSignature(0, Blob.GetBufferPointer, Blob.GetBufferSize, IID_ID3D12RootSignature, AppRoot),
    'CreateRootSignature (application ray passes)');
  Result := AppRoot;
end;

function TRayState.List: ID3D12GraphicsCommandList4;
var
  C: TGpu12Context;
begin
  C := Gpu12;
  if (List4 = nil) or (List4Ctx <> Pointer(C)) or (List4Gen <> C.ListGen) then
  begin
    List4 := nil;
    Check(C.List.QueryInterface(IID_ID3D12GraphicsCommandList4, List4), 'QueryInterface (ID3D12GraphicsCommandList4)');
    List4Ctx := C;
    List4Gen := C.ListGen;
  end;
  Result := List4;
end;

function TRayState.Pso(const AKind: Integer; const AFormat: TDXGI_FORMAT; const ASamples: Integer;
  const AMultisample: Boolean): ID3D12PipelineState;
var
  Key: Cardinal;
  Desc: TD3D12_GRAPHICS_PIPELINE_STATE_DESC;
begin
  Key := Cardinal(Ord(AFormat)) or (Cardinal(ASamples) shl 16) or (Cardinal(AKind) shl 24) or
    (Cardinal(Ord(AMultisample)) shl 28);
  if Psos.TryGetValue(Key, Result) then
    Exit;
  Desc := Default(TD3D12_GRAPHICS_PIPELINE_STATE_DESC);
  Desc.pRootSignature := Root;
  Desc.VS := TD3D12_SHADER_BYTECODE.Create(@FastRayVS[0], Length(FastRayVS));
  case AKind of
    1:
      if AMultisample then
        Desc.PS := TD3D12_SHADER_BYTECODE.Create(@FastHalfPSMS[0], Length(FastHalfPSMS))
      else
        Desc.PS := TD3D12_SHADER_BYTECODE.Create(@FastHalfPS[0], Length(FastHalfPS));
    2:
      if AMultisample then
        Desc.PS := TD3D12_SHADER_BYTECODE.Create(@FastBlurPSMS[0], Length(FastBlurPSMS))
      else
        Desc.PS := TD3D12_SHADER_BYTECODE.Create(@FastBlurPS[0], Length(FastBlurPS));
    3:
      if AMultisample then
        Desc.PS := TD3D12_SHADER_BYTECODE.Create(@FastReflectPSMS[0], Length(FastReflectPSMS))
      else
        Desc.PS := TD3D12_SHADER_BYTECODE.Create(@FastReflectPS[0], Length(FastReflectPS));
  else
    if AMultisample then
      Desc.PS := TD3D12_SHADER_BYTECODE.Create(@FastRayPSMS[0], Length(FastRayPSMS))
    else
      Desc.PS := TD3D12_SHADER_BYTECODE.Create(@FastRayPS[0], Length(FastRayPS));
  end;
  // Shadows and occlusion: the color in the target times the factor of the pass. Reflections: the target times
  // (1 - share) plus the reflected color times the share (premultiplied by the pass). Alpha kept; the factor texture
  // is written as it is.
  Desc.BlendState.RenderTarget[0].BlendEnable := AKind <> 1;
  if AKind = 3 then
  begin
    Desc.BlendState.RenderTarget[0].SrcBlend := D3D12_BLEND_ONE;
    Desc.BlendState.RenderTarget[0].DestBlend := D3D12_BLEND_INV_SRC_ALPHA;
  end
  else
  begin
    Desc.BlendState.RenderTarget[0].SrcBlend := D3D12_BLEND_ZERO;
    Desc.BlendState.RenderTarget[0].DestBlend := D3D12_BLEND_SRC_COLOR;
  end;
  Desc.BlendState.RenderTarget[0].BlendOp := D3D12_BLEND_OP_ADD;
  Desc.BlendState.RenderTarget[0].SrcBlendAlpha := D3D12_BLEND_ZERO;
  Desc.BlendState.RenderTarget[0].DestBlendAlpha := D3D12_BLEND_ONE;
  Desc.BlendState.RenderTarget[0].BlendOpAlpha := D3D12_BLEND_OP_ADD;
  Desc.BlendState.RenderTarget[0].LogicOp := D3D12_LOGIC_OP_NOOP;
  Desc.BlendState.RenderTarget[0].RenderTargetWriteMask := Ord(D3D12_COLOR_WRITE_ENABLE_ALL);
  Desc.SampleMask := $FFFFFFFF;
  Desc.RasterizerState := TD3D12_RASTERIZER_DESC.Create(D3D12_DEFAULT);
  Desc.RasterizerState.CullMode := D3D12_CULL_MODE_NONE;
  Desc.DepthStencilState := TD3D12_DEPTH_STENCIL_DESC.Create(D3D12_DEFAULT);
  Desc.DepthStencilState.DepthEnable := False;
  Desc.DepthStencilState.DepthWriteMask := D3D12_DEPTH_WRITE_MASK_ZERO;
  Desc.PrimitiveTopologyType := D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
  Desc.NumRenderTargets := 1;
  Desc.RTVFormats[0] := AFormat;
  Desc.DSVFormat := DXGI_FORMAT_UNKNOWN;
  Desc.SampleDesc.Count := ASamples;
  if AKind = 1 then
    Desc.RTVFormats[0] := DXGI_FORMAT_R8_UNORM;
  Check(Device5.CreateGraphicsPipelineState(@Desc, IID_ID3D12PipelineState, Result), 'CreateGraphicsPipelineState (ray)');
  Psos.Add(Key, Result);
end;

/// <summary>The ray-tracing state of the render thread, nil without DXR tier 1.1.</summary>
function RayState: TRayState;
var
  D5: ID3D12Device5;
begin
  if (R.Ray = nil) and RaySupported and Succeeded(Gpu12.Device.QueryInterface(IID_ID3D12Device5, D5)) then
    R.Ray := TRayState.Create(D5);
  Result := TRayState(R.Ray);
end;

/// <summary>Device lock held (or the canvas has shut down): everything of the render thread's ray tracing goes,
/// application pipelines included.</summary>
procedure RayClear;
var
  I: Integer;
  Sh: TRayShader12;
begin
  FreeAndNil(R.Ray);
  R.InstanceCount := 0;
  R.RayScene := 0;
  R.RayObjectPending := False;
  R.RayObjectTexture := nil;
  for I := 0 to High(R.Materials) do
    R.Materials[I].Texture := nil;
  if GRayShaders <> nil then
    for Sh in GRayShaders do
      Sh.ClearPsos;
end;

/// <summary>A UAV barrier over everything: acceleration structure builds and the passes' writes are done before what
/// follows.</summary>
procedure RayBarrier(const S: TRayState);
var
  Barrier: TD3D12_RESOURCE_BARRIER;
begin
  Gpu12.FlushBarriers;
  Barrier := TD3D12_RESOURCE_BARRIER.CreateUAV(nil);
  Gpu12.List.ResourceBarrier(1, @Barrier);
  Inc(S.Epoch);
end;

/// <summary>The scene AScene begins on the render thread (its first object or pass): the instances of the previous
/// scene go, and geometries no scene used for a while are released.</summary>
procedure RayBeginScene(const S: TRayState; const AScene: Integer);
var
  Pair: TPair<UInt64, TBlas>;
  K: UInt64;
  I: Integer;
begin
  if R.RayScene = AScene then
    Exit;
  R.RayScene := AScene;
  for I := 0 to R.InstanceCount - 1 do
    R.Materials[I].Texture := nil;
  R.InstanceCount := 0;
  Inc(S.Pass);
  // Released through Retire: lists not executed yet may use them.
  if S.Keyed.Count > 0 then
  begin
    S.Stale.Clear;
    for Pair in S.Keyed do
      if S.Pass - Pair.Value.LastUse > KeyedKeepPasses then
        S.Stale.Add(Pair.Key);
    for K in S.Stale do
      S.Keyed.Remove(K);
  end;
  if S.Pass mod 64 = 0 then
  begin
    S.Stale.Clear;
    for Pair in S.Blas do
      if S.Pass - Pair.Value.LastUse > BlasKeepPasses then
        S.Stale.Add(Pair.Key);
    for K in S.Stale do
      S.Blas.Remove(K);
  end;
end;

{ TRayResource12 }

destructor TRayResource12.Destroy;
var
  C: TGpu12Context;
begin
  // Any thread: the last reference may go with a command chunk on the render thread.
  if (Resource <> nil) or (Owner <> nil) then
  begin
    TFastDevice.Lock;
    try
      C := Gpu12Current;
      if (C <> nil) and (C = Owner) then
      begin
        C.SrvPool.Release(Srv);
        C.SrvPool.Release(Uav);
      end;
      if C <> nil then
        C.Retire(Resource);
      Resource := nil;
    finally
      TFastDevice.Unlock;
    end;
  end;
  inherited;
end;

procedure TRayResource12.Use(const AState: TD3D12_RESOURCE_STATES);
var
  C: TGpu12Context;
begin
  C := Gpu12;
  // The open list: a buffer's state is the common state again in a list after the one that set it.
  C.List;
  if IsBuffer and ((StateCtx <> Pointer(C)) or (StateGen <> C.ListGen)) then
    State := D3D12_RESOURCE_STATE_COMMON;
  StateCtx := C;
  StateGen := C.ListGen;
  C.Transition(Resource, State, AState);
end;

function TRayResource12.ShaderView: TD3D12_CPU_DESCRIPTOR_HANDLE;
var
  C: TGpu12Context;
  Desc: TD3D12_SHADER_RESOURCE_VIEW_DESC;
begin
  C := Gpu12;
  if Owner <> C then
  begin
    Owner := C;
    Srv.ptr := 0;
    Uav.ptr := 0;
  end;
  if Srv.ptr = 0 then
  begin
    Srv := C.SrvPool.Alloc;
    if IsBuffer then
    begin
      FillChar(Desc, SizeOf(Desc), 0);
      Desc.Format := DXGI_FORMAT_R32_TYPELESS;
      Desc.ViewDimension := D3D12_SRV_DIMENSION_BUFFER;
      Desc.Shader4ComponentMapping := D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
      Desc.Buffer.NumElements := Bytes div 4;
      Desc.Buffer.Flags := D3D12_BUFFER_SRV_FLAG_RAW;
      C.Device.CreateShaderResourceView(Resource, @Desc, Srv);
    end
    else
      C.Device.CreateShaderResourceView(Resource, nil, Srv);
  end;
  Result := Srv;
end;

function TRayResource12.UnorderedView: TD3D12_CPU_DESCRIPTOR_HANDLE;
var
  C: TGpu12Context;
  Desc: TD3D12_UNORDERED_ACCESS_VIEW_DESC;
begin
  C := Gpu12;
  if Owner <> C then
  begin
    Owner := C;
    Srv.ptr := 0;
    Uav.ptr := 0;
  end;
  if Uav.ptr = 0 then
  begin
    Uav := C.SrvPool.Alloc;
    FillChar(Desc, SizeOf(Desc), 0);
    if IsBuffer then
    begin
      Desc.Format := DXGI_FORMAT_R32_TYPELESS;
      Desc.ViewDimension := D3D12_UAV_DIMENSION_BUFFER;
      Desc.Buffer.NumElements := Bytes div 4;
      Desc.Buffer.Flags := D3D12_BUFFER_UAV_FLAG_RAW;
    end
    else
    begin
      Desc.Format := Format;
      Desc.ViewDimension := D3D12_UAV_DIMENSION_TEXTURE2D;
    end;
    C.Device.CreateUnorderedAccessView(Resource, nil, Desc, Uav);
  end;
  Result := Uav;
end;

/// <summary>Recording thread: the GPU memory of a buffer (AImage False: ABytes) or an image (AFormat, AWidth x
/// AHeight), zeroed, usable as SRV and UAV.</summary>
function NewRayResource(const AImage: Boolean; const ABytes: Integer; const AFormat: TDXGI_FORMAT;
  const AWidth, AHeight: Integer): TRayResource12;
var
  Props: TD3D12_HEAP_PROPERTIES;
  Desc: TD3D12_RESOURCE_DESC;
begin
  if TFastDevice.D3D12 = nil then
    raise EContext3DException.Create('FastContext3D12: ray buffers and images need the Direct3D 12 canvas');
  Result := TRayResource12.Create;
  try
    Result.IsBuffer := not AImage;
    Result.State := D3D12_RESOURCE_STATE_COMMON;
    Props := TD3D12_HEAP_PROPERTIES.Create(D3D12_HEAP_TYPE_DEFAULT);
    if AImage then
    begin
      Result.Format := AFormat;
      Result.Width := AWidth;
      Result.Height := AHeight;
      Desc := TD3D12_RESOURCE_DESC.CreateTex2D(AFormat, AWidth, AHeight, 1, 1, 1, 0,
        D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
    end
    else
    begin
      Result.Bytes := AlignUp(Max(ABytes, 16), 16);
      Desc := TD3D12_RESOURCE_DESC.CreateBuffer(Result.Bytes, D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
    end;
    // Committed resources of the default heap come zeroed.
    Check(TFastDevice.D3D12.CreateCommittedResource(@Props, D3D12_HEAP_FLAG_NONE, @Desc, D3D12_RESOURCE_STATE_COMMON,
      nil, IID_ID3D12Resource, Result.Resource), 'CreateCommittedResource (ray buffer or image)');
  except
    Result.Free;
    raise;
  end;
end;

{ TRayShader12 }

constructor TRayShader12.Create(const ADxil: array of Byte; const ACompute: Boolean; const ABlend: TFastRayBlend);
begin
  inherited Create;
  SetLength(Code, Length(ADxil));
  if Length(ADxil) > 0 then
    Move(ADxil[0], Code[0], Length(ADxil));
  Compute := ACompute;
  Blend := ABlend;
  Psos := TDictionary<Cardinal, ID3D12PipelineState>.Create;
  TFastDevice.Lock;
  try
    if GRayShaders = nil then
      GRayShaders := TList<TRayShader12>.Create;
    GRayShaders.Add(Self);
  finally
    TFastDevice.Unlock;
  end;
end;

destructor TRayShader12.Destroy;
begin
  TFastDevice.Lock;
  try
    if GRayShaders <> nil then
    begin
      GRayShaders.Remove(Self);
      if GRayShaders.Count = 0 then
        FreeAndNil(GRayShaders);
    end;
    ClearPsos;
  finally
    TFastDevice.Unlock;
  end;
  Psos.Free;
  inherited;
end;

procedure TRayShader12.ClearPsos;
var
  C: TGpu12Context;
  P: ID3D12PipelineState;
begin
  C := Gpu12Current;
  if C <> nil then
    for P in Psos.Values do
      C.Retire(P);
  Psos.Clear;
end;

function TRayShader12.Error: string;
begin
  TMonitor.Enter(Self);
  try
    Result := FError;
  finally
    TMonitor.Exit(Self);
  end;
end;

function TRayShader12.Pso(const S: TRayState; const AFormat: TDXGI_FORMAT): ID3D12PipelineState;
var
  Key: Cardinal;
  CDesc: TD3D12_COMPUTE_PIPELINE_STATE_DESC;
  GDesc: TD3D12_GRAPHICS_PIPELINE_STATE_DESC;
  Root: ID3D12RootSignature;
  Res: HResult;
  T: ^TD3D12_RENDER_TARGET_BLEND_DESC;
begin
  if Serial <> S.Serial then
  begin
    ClearPsos;
    Serial := S.Serial;
  end;
  Key := 0;
  if not Compute then
    Key := Cardinal(Ord(AFormat));
  if Psos.TryGetValue(Key, Result) then
    Exit;
  Root := S.AppRootSignature;
  if Compute then
  begin
    FillChar(CDesc, SizeOf(CDesc), 0);
    // The header declares the field as a pointer to an interface: it is the interface pointer itself.
    CDesc.pRootSignature := PID3D12RootSignature(Pointer(Root));
    CDesc.CS := TD3D12_SHADER_BYTECODE.Create(@Code[0], Length(Code));
    Res := S.Device5.CreateComputePipelineState(CDesc, IID_ID3D12PipelineState, Result);
  end
  else
  begin
    GDesc := Default(TD3D12_GRAPHICS_PIPELINE_STATE_DESC);
    GDesc.pRootSignature := Root;
    GDesc.VS := TD3D12_SHADER_BYTECODE.Create(@FastRayVS[0], Length(FastRayVS));
    GDesc.PS := TD3D12_SHADER_BYTECODE.Create(@Code[0], Length(Code));
    T := @GDesc.BlendState.RenderTarget[0];
    T.BlendEnable := Blend <> TFastRayBlend.Replace;
    T.BlendOp := D3D12_BLEND_OP_ADD;
    T.BlendOpAlpha := D3D12_BLEND_OP_ADD;
    T.LogicOp := D3D12_LOGIC_OP_NOOP;
    T.RenderTargetWriteMask := Ord(D3D12_COLOR_WRITE_ENABLE_ALL);
    // Alpha: as the colors for premultiplied blending; kept by multiplying and adding.
    T.SrcBlendAlpha := D3D12_BLEND_ZERO;
    T.DestBlendAlpha := D3D12_BLEND_ONE;
    case Blend of
      TFastRayBlend.Premultiplied:
        begin
          T.SrcBlend := D3D12_BLEND_ONE;
          T.DestBlend := D3D12_BLEND_INV_SRC_ALPHA;
          T.SrcBlendAlpha := D3D12_BLEND_ONE;
          T.DestBlendAlpha := D3D12_BLEND_INV_SRC_ALPHA;
        end;
      TFastRayBlend.Multiply:
        begin
          T.SrcBlend := D3D12_BLEND_ZERO;
          T.DestBlend := D3D12_BLEND_SRC_COLOR;
        end;
      TFastRayBlend.Add:
        begin
          T.SrcBlend := D3D12_BLEND_ONE;
          T.DestBlend := D3D12_BLEND_ONE;
        end;
    else
      T.SrcBlend := D3D12_BLEND_ONE;
      T.DestBlend := D3D12_BLEND_ZERO;
      T.SrcBlendAlpha := D3D12_BLEND_ONE;
      T.DestBlendAlpha := D3D12_BLEND_ZERO;
    end;
    GDesc.SampleMask := $FFFFFFFF;
    GDesc.RasterizerState := TD3D12_RASTERIZER_DESC.Create(D3D12_DEFAULT);
    GDesc.RasterizerState.CullMode := D3D12_CULL_MODE_NONE;
    GDesc.DepthStencilState := TD3D12_DEPTH_STENCIL_DESC.Create(D3D12_DEFAULT);
    GDesc.DepthStencilState.DepthEnable := False;
    GDesc.DepthStencilState.DepthWriteMask := D3D12_DEPTH_WRITE_MASK_ZERO;
    GDesc.PrimitiveTopologyType := D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
    GDesc.NumRenderTargets := 1;
    GDesc.RTVFormats[0] := AFormat;
    GDesc.DSVFormat := DXGI_FORMAT_UNKNOWN;
    GDesc.SampleDesc.Count := 1;
    Res := S.Device5.CreateGraphicsPipelineState(@GDesc, IID_ID3D12PipelineState, Result);
  end;
  if Failed(Res) then
  begin
    // Unsigned DXIL, another root signature, a pixel shader with more inputs than the position: the passes with this
    // shader are skipped; the application reads the error.
    Result := nil;
    TMonitor.Enter(Self);
    try
      FError := Format('FastContext3D12: the pipeline of an application ray shader could not be made (0x%.8x)',
        [Cardinal(Res)]);
    finally
      TMonitor.Exit(Self);
    end;
  end;
  Psos.Add(Key, Result);
end;

/// <summary>The object whose draw follows (TCmdRayObject).</summary>
procedure HandleRayObject(const AData: Pointer);
var
  O: PCmdRayObject;
begin
  O := AData;
  R.RayObject := O^;
  R.RayObjectTexture := TTexture12(O.Texture);
  R.RayObjectPending := True;
end;

/// <summary>Reflections: a copy of the geometry the draw just uploaded (vertices from AVertices at AVertexOffset,
/// indices from AIndices at AIndexOffset), which the shaders read, and its layout.</summary>
procedure CopyGeometry(const B: TBlas; const C: PCmdDraw; const AVertices: ID3D12Resource; const AVertexOffset: UInt64;
  const AIndices: ID3D12Resource; const AIndexOffset: UInt64);
var
  Ctx: TGpu12Context;
  Size: UInt64;
  Props: TD3D12_HEAP_PROPERTIES;
  Desc: TD3D12_RESOURCE_DESC;
  View: TD3D12_SHADER_RESOURCE_VIEW_DESC;
  Barrier: TD3D12_RESOURCE_BARRIER;
begin
  Ctx := Gpu12;
  B.IndexOffset := AlignUp(C.VertexBytes, 16);
  Size := UInt64(B.IndexOffset) + UInt64(AlignUp(C.IndexBytes, 4));
  Props := TD3D12_HEAP_PROPERTIES.Create(D3D12_HEAP_TYPE_DEFAULT);
  Desc := TD3D12_RESOURCE_DESC.CreateBuffer(Size);
  // Buffers start in the common state (and go back to it after every list): copied into, then read by the shaders
  // of this list; later lists read it straight from the common state.
  Check(Ctx.Device.CreateCommittedResource(@Props, D3D12_HEAP_FLAG_NONE, @Desc, D3D12_RESOURCE_STATE_COMMON, nil,
    IID_ID3D12Resource, B.Data), 'CreateCommittedResource (ray geometry)');
  Ctx.FlushBarriers;
  Barrier := TD3D12_RESOURCE_BARRIER.CreateTransition(Pointer(B.Data), D3D12_RESOURCE_STATE_COMMON,
    D3D12_RESOURCE_STATE_COPY_DEST);
  Ctx.List.ResourceBarrier(1, @Barrier);
  Ctx.List.CopyBufferRegion(B.Data, 0, AVertices, AVertexOffset, C.VertexBytes);
  Ctx.List.CopyBufferRegion(B.Data, B.IndexOffset, AIndices, AIndexOffset, C.IndexBytes);
  Barrier := TD3D12_RESOURCE_BARRIER.CreateTransition(Pointer(B.Data), D3D12_RESOURCE_STATE_COPY_DEST,
    TD3D12_RESOURCE_STATES(Ord(D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE) or
    Ord(D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE)));
  Ctx.List.ResourceBarrier(1, @Barrier);
  FillChar(View, SizeOf(View), 0);
  View.Format := DXGI_FORMAT_R32_TYPELESS;
  View.ViewDimension := D3D12_SRV_DIMENSION_BUFFER;
  View.Shader4ComponentMapping := D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
  View.Buffer.FirstElement := 0;
  View.Buffer.NumElements := Size div 4;
  View.Buffer.Flags := D3D12_BUFFER_SRV_FLAG_RAW;
  B.DataView := Ctx.SrvPool.Alloc;
  Ctx.Device.CreateShaderResourceView(B.Data, @View, B.DataView);
  B.Stride := C.VertexStride;
  B.PositionOffset := R.RayObject.PositionOffset;
  B.NormalOffset := R.RayObject.NormalOffset;
  B.TexCoordOffset := R.RayObject.TexCoordOffset;
  B.Index16 := C.IndexFormat = DXGI_FORMAT_R16_UINT;
end;

/// <summary>Builds B from the geometry of the draw C (vertices and indices in upload memory, alive until the list has
/// run). False when there is nothing to build.</summary>
function BuildBlas(const S: TRayState; const B: TBlas; const C: PCmdDraw; const VB: TD3D12_VERTEX_BUFFER_VIEW;
  const IB: TD3D12_INDEX_BUFFER_VIEW; const O: PCmdRayObject): Boolean;
var
  Ctx: TGpu12Context;
  Geometry: TD3D12_RAYTRACING_GEOMETRY_DESC;
  Inputs: TD3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS;
  Info: TD3D12_RAYTRACING_ACCELERATION_STRUCTURE_PREBUILD_INFO;
  Build: TD3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_DESC;
  Scratch: ID3D12Resource;
  ScratchSize: UInt64;
begin
  Result := False;
  Ctx := Gpu12;
  FillChar(Geometry, SizeOf(Geometry), 0);
  Geometry._Type := D3D12_RAYTRACING_GEOMETRY_TYPE_TRIANGLES;
  Geometry.Flags := D3D12_RAYTRACING_GEOMETRY_FLAG_OPAQUE;
  Geometry.Triangles.IndexFormat := C.IndexFormat;
  Geometry.Triangles.VertexFormat := DXGI_FORMAT_R32G32B32_FLOAT;
  Geometry.Triangles.IndexCount := C.IndexCount - C.IndexCount mod 3;
  Geometry.Triangles.VertexCount := C.VertexBytes div C.VertexStride;
  Geometry.Triangles.IndexBuffer := IB.BufferLocation;
  Geometry.Triangles.VertexBuffer.StartAddress := VB.BufferLocation + UInt64(O.PositionOffset);
  Geometry.Triangles.VertexBuffer.StrideInBytes := C.VertexStride;
  FillChar(Inputs, SizeOf(Inputs), 0);
  Inputs._Type := D3D12_RAYTRACING_ACCELERATION_STRUCTURE_TYPE_BOTTOM_LEVEL;
  // A geometry built again and again (an animated model) is built fast rather than traced fast.
  if B.Rebuilt then
    Inputs.Flags := D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_PREFER_FAST_BUILD
  else
    Inputs.Flags := D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_PREFER_FAST_TRACE;
  Inputs.NumDescs := 1;
  Inputs.DescsLayout := D3D12_ELEMENTS_LAYOUT_ARRAY;
  Inputs.pGeometryDescs := @Geometry;
  S.Device5.GetRaytracingAccelerationStructurePrebuildInfo(@Inputs, Info);
  if Info.ResultDataMaxSizeInBytes = 0 then
    Exit;
  // Built again in place: what reads the structure (a pass) or builds it (its last build, with the same scratch
  // memory) since the last barrier of this list finishes first.
  if (B.Resource <> nil) and (((S.ReadGen = Ctx.ListGen) and (S.ReadEpoch = S.Epoch)) or
    ((B.BuildGen = Ctx.ListGen) and (B.BuildEpoch = S.Epoch))) then
    RayBarrier(S);
  if Info.ResultDataMaxSizeInBytes > B.Capacity then
  begin
    Ctx.Retire(B.Resource);
    B.Capacity := AlignUp(Info.ResultDataMaxSizeInBytes, D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BYTE_ALIGNMENT);
    B.Resource := NewBuffer(B.Capacity, D3D12_RESOURCE_STATE_RAYTRACING_ACCELERATION_STRUCTURE);
    B.Address := B.Resource.GetGPUVirtualAddress;
  end;
  ScratchSize := Max(Info.ScratchDataSizeInBytes, 256);
  if B.Keyed then
  begin
    // Its own scratch memory, kept for the next version.
    if ScratchSize > B.ScratchSize then
    begin
      Ctx.Retire(B.Scratch);
      B.ScratchSize := AlignUp(ScratchSize, 256);
      B.Scratch := NewBuffer(B.ScratchSize, D3D12_RESOURCE_STATE_COMMON);
    end;
    Scratch := B.Scratch;
  end
  else
  begin
    Scratch := NewBuffer(ScratchSize, D3D12_RESOURCE_STATE_COMMON);
    Ctx.Retire(Scratch);
  end;
  FillChar(Build, SizeOf(Build), 0);
  Build.DestAccelerationStructureData := B.Address;
  Build.Inputs := Inputs;
  Build.ScratchAccelerationStructureData := Scratch.GetGPUVirtualAddress;
  Ctx.FlushBarriers;
  S.List.BuildRaytracingAccelerationStructure(@Build, 0, nil);
  B.BuildGen := Ctx.ListGen;
  B.BuildEpoch := S.Epoch;
  Result := True;
end;

/// <summary>An object of the scene (R.RayObject), just drawn from VB and IB: its geometry's structure (built on first
/// use, or again when its application version changed) as an instance with the object's transform, mask and user
/// value; with reflections, its geometry's copy and its material.</summary>
procedure RayAddObject(const C: PCmdDraw; const VB: TD3D12_VERTEX_BUFFER_VIEW; const IB: TD3D12_INDEX_BUFFER_VIEW;
  const AVertices: ID3D12Resource; const AVertexOffset: UInt64; const AIndices: ID3D12Resource;
  const AIndexOffset: UInt64);
var
  S: TRayState;
  B: TBlas;
  O: PCmdRayObject;
  P: ^TD3D12_RAYTRACING_INSTANCE_DESC;
  M: ^TRayMaterial;
  T: ^TRayTransform;
  Flags: Cardinal;
begin
  S := RayState;
  O := @R.RayObject;
  if (S = nil) or (C.IndexCount < 3) then
    Exit;
  RayBeginScene(S, O.Scene);
  if O.Keyed then
  begin
    if not S.Keyed.TryGetValue(O.Geometry, B) then
    begin
      B := TBlas.Create;
      B.Stamp := -1;
      B.Keyed := True;
      B.Version := O.Version;
      if not BuildBlas(S, B, C, VB, IB, O) then
      begin
        B.Free;
        Exit;
      end;
      S.Keyed.Add(O.Geometry, B);
    end
    else if B.Version <> O.Version then
    begin
      B.Version := O.Version;
      B.Rebuilt := True;
      if not BuildBlas(S, B, C, VB, IB, O) then
        Exit;
      // The copy reflections read is made again from this draw.
      if B.Data <> nil then
      begin
        Gpu12.Retire(B.Data);
        Gpu12.SrvPool.Release(B.DataView);
        B.Data := nil;
        B.DataView.ptr := 0;
      end;
    end;
  end
  else if not S.Blas.TryGetValue(O.Geometry, B) then
  begin
    B := TBlas.Create;
    B.Stamp := -1;
    if not BuildBlas(S, B, C, VB, IB, O) then
    begin
      B.Free;
      Exit;
    end;
    S.Blas.Add(O.Geometry, B);
  end;
  B.LastUse := S.Pass;
  if (O.Kind <> 255) and (B.Data = nil) then
    CopyGeometry(B, C, AVertices, AVertexOffset, AIndices, AIndexOffset);
  if R.InstanceCount = Length(R.Instances) then
  begin
    SetLength(R.Instances, Max(64, 2 * R.InstanceCount));
    SetLength(R.Materials, Length(R.Instances));
  end;
  P := @R.Instances[R.InstanceCount];
  Move(O.Transform, P.Transform, SizeOf(P.Transform));
  // Instance ID: the index of the instance (its material record); the draw's mask; the draw's user value as the hit
  // group contribution (inline ray queries read it, no shader table does); opaque.
  P.Instance := Cardinal(R.InstanceCount and $FFFFFF) or (Cardinal(O.Mask) shl 24);
  Flags := Cardinal(Ord(D3D12_RAYTRACING_INSTANCE_FLAG_FORCE_OPAQUE));
  // Front faces as the raster's. DXR takes a triangle as front facing when it is clockwise seen from the ray, in
  // object space; the raster when it is clockwise on screen, and FMX's cameras (y down) see a triangle's object-space
  // winding the other way round (RayAppProbe --facing=1: with DXR's default, rays culling back faces lose every
  // surface the raster shows). The raster's winding also flips with a mirroring object matrix (negative
  // determinant), which DXR's object-space rule ignores: counter-clockwise front faces unless the matrix mirrors.
  T := @O.Transform;
  if T[0, 0] * (T[1, 1] * T[2, 2] - T[1, 2] * T[2, 1]) - T[0, 1] * (T[1, 0] * T[2, 2] - T[1, 2] * T[2, 0]) +
    T[0, 2] * (T[1, 0] * T[2, 1] - T[1, 1] * T[2, 0]) > 0 then
    Flags := Flags or Cardinal(Ord(D3D12_RAYTRACING_INSTANCE_FLAG_TRIANGLE_FRONT_COUNTERCLOCKWISE));
  P.InstanceContribution := (O.User and $FFFFFF) or (Flags shl 24);
  P.AccelerationStructure := B.Address;
  M := @R.Materials[R.InstanceCount];
  M.Blas := B;
  M.Kind := O.Kind;
  M.Textured := O.Textured;
  M.Texture := R.RayObjectTexture;
  Move(O.Diffuse, M.Diffuse, SizeOf(M.Diffuse));
  Move(O.Ambient, M.Ambient, SizeOf(M.Ambient));
  Move(O.Emission, M.Emission, SizeOf(M.Emission));
  Move(O.Specular, M.Specular, SizeOf(M.Specular));
  M.Shininess := O.Shininess;
  Inc(R.InstanceCount);
end;

/// <summary>Viewport and scissor over AWidth x AHeight pixels.</summary>
procedure SetArea(const L: ID3D12GraphicsCommandList; const AWidth, AHeight: Integer);
var
  VP: TD3D12_VIEWPORT;
  Rect: TRect;
begin
  VP.TopLeftX := 0;
  VP.TopLeftY := 0;
  VP.Width := AWidth;
  VP.Height := AHeight;
  VP.MinDepth := 0;
  VP.MaxDepth := 1;
  L.RSSetViewports(1, @VP);
  Rect := TRect.Create(0, 0, AWidth, AHeight);
  L.RSSetScissorRects(1, @Rect);
end;

/// <summary>Reflections: numbers the geometries and textures of the scene's instances and fills their records.
/// False when a pass cannot take them all.</summary>
function PrepareReflections(const S: TRayState): Boolean;
var
  I, Slot: Integer;
  M: ^TRayMaterial;
  B: TBlas;
  D: ^TRayInstanceData;
  T: TTexture12;
begin
  S.Geometries.Clear;
  S.Textures.Clear;
  S.TextureSlots.Clear;
  if Length(S.Records) < R.InstanceCount then
    SetLength(S.Records, R.InstanceCount);
  for I := 0 to R.InstanceCount - 1 do
  begin
    M := @R.Materials[I];
    D := @S.Records[I];
    FillChar(D^, SizeOf(D^), 0);
    D.Geometry := NoGeometry;
    D.Texture := -1;
    D.NormalOffset := -1;
    D.TexCoordOffset := -1;
    B := TBlas(M.Blas);
    if (B <> nil) and (B.Data <> nil) then
    begin
      if B.Stamp <> S.Pass then
      begin
        B.Stamp := S.Pass;
        B.Slot := S.Geometries.Count;
        S.Geometries.Add(B);
      end;
      D.Geometry := B.Slot;
      D.Stride := B.Stride;
      D.PositionOffset := B.PositionOffset;
      D.NormalOffset := B.NormalOffset;
      D.TexCoordOffset := B.TexCoordOffset;
      D.IndexOffset := B.IndexOffset;
      D.Index16 := Ord(B.Index16);
    end;
    if M.Textured and (M.Texture <> nil) then
    begin
      T := TTexture12(M.Texture as TObject);
      if not S.TextureSlots.TryGetValue(T, Slot) then
      begin
        Slot := S.Textures.Count;
        S.Textures.Add(T);
        S.TextureSlots.Add(T, Slot);
      end;
      D.Texture := Slot;
    end;
    D.Kind := M.Kind;
    Move(M.Diffuse, D.Diffuse, SizeOf(D.Diffuse));
    Move(M.Ambient, D.Ambient, SizeOf(D.Ambient));
    Move(M.Emission, D.Emission, SizeOf(D.Emission));
    Move(M.Specular, D.Specular, SizeOf(D.Specular));
    D.Specular[3] := M.Shininess;
    // Light materials reflect as much as their specular color, the more the shinier.
    D.Gloss := EnsureRange(M.Shininess / 128, 0, 1);
    if M.Kind = 3 then
      D.F0 := EnsureRange(0.299 * M.Specular[0] + 0.587 * M.Specular[1] + 0.114 * M.Specular[2], 0, 1) * D.Gloss;
  end;
  // Two more descriptors: the depth buffer and the factor texture.
  Result := S.Geometries.Count + S.Textures.Count + 2 <= 1024;
end;

/// <summary>The top-level structure of the scene in progress (R.RayScene) from its instances so far: built unless it
/// holds them already (an earlier pass of the scene built it, and no object was added since).</summary>
procedure RayBuildTlas(const S: TRayState);
var
  Ctx: TGpu12Context;
  Inputs: TD3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS;
  Info: TD3D12_RAYTRACING_ACCELERATION_STRUCTURE_PREBUILD_INFO;
  Build: TD3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_DESC;
  P: PByte;
  Res: ID3D12Resource;
  Off, InstGpu: UInt64;
  Bytes: Integer;
begin
  if (S.Tlas <> nil) and (S.TlasScene = R.RayScene) and (S.TlasCount = R.InstanceCount) then
    Exit;
  Ctx := Gpu12;
  // The instances of the scene (none: an empty structure, every ray misses).
  Bytes := R.InstanceCount * SizeOf(TD3D12_RAYTRACING_INSTANCE_DESC);
  P := Ctx.Upload(Max(Bytes, SizeOf(TD3D12_RAYTRACING_INSTANCE_DESC)), D3D12_RAYTRACING_INSTANCE_DESCS_BYTE_ALIGNMENT,
    Res, Off, InstGpu);
  if Bytes > 0 then
    Move(R.Instances[0], P^, Bytes);
  FillChar(Inputs, SizeOf(Inputs), 0);
  Inputs._Type := D3D12_RAYTRACING_ACCELERATION_STRUCTURE_TYPE_TOP_LEVEL;
  Inputs.Flags := D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_PREFER_FAST_TRACE;
  Inputs.NumDescs := R.InstanceCount;
  Inputs.DescsLayout := D3D12_ELEMENTS_LAYOUT_ARRAY;
  Inputs.InstanceDescs := InstGpu;
  S.Device5.GetRaytracingAccelerationStructurePrebuildInfo(@Inputs, Info);
  if (Info.ResultDataMaxSizeInBytes > S.TlasSize) or (S.Tlas = nil) then
  begin
    Ctx.Retire(S.Tlas);
    S.TlasSize := AlignUp(Max(Info.ResultDataMaxSizeInBytes, 256) * 2, 64 * 1024);
    S.Tlas := NewBuffer(S.TlasSize, D3D12_RESOURCE_STATE_RAYTRACING_ACCELERATION_STRUCTURE);
  end;
  if (Info.ScratchDataSizeInBytes > S.ScratchSize) or (S.TlasScratch = nil) then
  begin
    Ctx.Retire(S.TlasScratch);
    S.ScratchSize := AlignUp(Max(Info.ScratchDataSizeInBytes, 256) * 2, 64 * 1024);
    S.TlasScratch := NewBuffer(S.ScratchSize, D3D12_RESOURCE_STATE_COMMON);
  end;
  // The bottom levels are built, the previous passes have read the top level.
  RayBarrier(S);
  FillChar(Build, SizeOf(Build), 0);
  Build.DestAccelerationStructureData := S.Tlas.GetGPUVirtualAddress;
  Build.Inputs := Inputs;
  Build.ScratchAccelerationStructureData := S.TlasScratch.GetGPUVirtualAddress;
  S.List.BuildRaytracingAccelerationStructure(@Build, 0, nil);
  RayBarrier(S);
  S.TlasScene := R.RayScene;
  S.TlasCount := R.InstanceCount;
end;

/// <summary>The scene's top-level structure, then the passes over the target (TCmdRay).</summary>
procedure HandleRay(const AData: Pointer);
var
  C: PCmdRay;
  S: TRayState;
  Ctx: TGpu12Context;
  L: ID3D12GraphicsCommandList;
  T, D, F: TTexture12;
  Table, DepthSrv: TD3D12_CPU_DESCRIPTOR_HANDLE;
  TableGpu, Gpu4: TD3D12_GPU_DESCRIPTOR_HANDLE;
  P: PByte;
  Res: ID3D12Resource;
  Off, Gpu, RecordsGpu: UInt64;
  Bytes, ConstBytes, I, N: Integer;
  Rtv: TD3D12_CPU_DESCRIPTOR_HANDLE;
  Shadows, Reflect: Boolean;
begin
  C := AData;
  S := RayState;
  if (S = nil) or (R.RayScene <> C.Scene) or (R.InstanceCount = 0) then
    Exit;
  Ctx := Gpu12;
  T := C.Target;
  D := C.Depth;
  Shadows := (((C.Flags and RayShadowsOn) <> 0) and (C.LightCount > 0)) or (C.AOSamples > 0);
  Reflect := ((C.Flags and RayReflect) <> 0) and PrepareReflections(S);
  // A texture that is the target itself (a material showing its own viewport) cannot be read while it is drawn into.
  if Reflect then
    for I := 0 to S.Textures.Count - 1 do
      if S.Textures[I] = T then
        S.Textures[I] := G.Blank;
  // First, as it may hand the list to the GPU when the descriptor ring is full: the depth buffer and the factor
  // texture, then the geometries and the textures of the reflections.
  N := 2;
  if Reflect then
    Inc(N, S.Geometries.Count + S.Textures.Count);
  Table := Ctx.AllocTable(N, TableGpu);
  L := Ctx.List;
  // Several rays per pixel: traced at half resolution into a texture, smoothed and upsampled into the target.
  F := nil;
  if Shadows and ((C.Softness > 0) or (C.AOSamples > 0)) then
  begin
    if S.Factor <> nil then
      F := TTexture12(S.Factor as TObject);
    if (F = nil) or (F.Width <> (C.Width + 1) div 2) or (F.Height <> (C.Height + 1) div 2) then
    begin
      F := NewTexture((C.Width + 1) div 2, (C.Height + 1) div 2, 1, 1, DXGI_FORMAT_R8_UNORM,
        D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET, D3D12_RESOURCE_STATE_RENDER_TARGET);
      S.Factor := F;
    end;
  end;

  RayBuildTlas(S);

  // The passes: the depth buffer read, the target drawn into.
  T.Use(D3D12_RESOURCE_STATE_RENDER_TARGET);
  D.Use(TD3D12_RESOURCE_STATES(Ord(D3D12_RESOURCE_STATE_DEPTH_READ) or Ord(D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE)));
  if Reflect then
    for I := 0 to S.Textures.Count - 1 do
      S.Textures[I].Use(StateRead);
  Ctx.FlushBarriers;
  DepthSrv := DepthShaderView(D, Ctx);
  Ctx.Device.CopyDescriptorsSimple(1, Table, DepthSrv, D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
  Ctx.SrvPool.Release(DepthSrv);
  if F <> nil then
    Ctx.Device.CopyDescriptorsSimple(1, Offset(Table, 1, Ctx.SrvIncrement), F.ShaderView,
      D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV)
  else
    Ctx.Device.CopyDescriptorsSimple(1, Offset(Table, 1, Ctx.SrvIncrement), G.Blank.ShaderView,
      D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
  L.SetGraphicsRootSignature(S.Root);
  ConstBytes := SizeOf(TCmdRay) - (PByte(@C.InvViewProj) - PByte(C));
  P := Ctx.Upload(AlignUp(ConstBytes, 256), 256, Res, Off, Gpu);
  Move(C.InvViewProj, P^, ConstBytes);
  L.SetGraphicsRootConstantBufferView(0, Gpu);
  L.SetGraphicsRootShaderResourceView(1, S.Tlas.GetGPUVirtualAddress);
  L.SetGraphicsRootDescriptorTable(2, TableGpu);
  L.IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);

  if Shadows then
  begin
    if F <> nil then
    begin
      F.Use(D3D12_RESOURCE_STATE_RENDER_TARGET);
      Ctx.FlushBarriers;
      Rtv := F.RenderTarget;
      L.OMSetRenderTargets(1, @Rtv, False, nil);
      L.SetPipelineState(S.Pso(1, DXGI_FORMAT_R8_UNORM, 1, D.Samples > 1));
      SetArea(L, F.Width, F.Height);
      L.DrawInstanced(3, 1, 0, 0);
      F.Use(StateRead);
      Ctx.FlushBarriers;
      Rtv := T.RenderTarget;
      L.OMSetRenderTargets(1, @Rtv, False, nil);
      L.SetPipelineState(S.Pso(2, T.Format, C.Samples, D.Samples > 1));
    end
    else
    begin
      Rtv := T.RenderTarget;
      L.OMSetRenderTargets(1, @Rtv, False, nil);
      L.SetPipelineState(S.Pso(0, T.Format, C.Samples, D.Samples > 1));
    end;
    SetArea(L, C.Width, C.Height);
    L.DrawInstanced(3, 1, 0, 0);
  end;

  if Reflect then
  begin
    // The geometries, then the textures, after the two descriptors above.
    for I := 0 to S.Geometries.Count - 1 do
      Ctx.Device.CopyDescriptorsSimple(1, Offset(Table, 2 + I, Ctx.SrvIncrement), S.Geometries[I].DataView,
        D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    for I := 0 to S.Textures.Count - 1 do
      Ctx.Device.CopyDescriptorsSimple(1, Offset(Table, 2 + S.Geometries.Count + I, Ctx.SrvIncrement),
        S.Textures[I].ShaderView, D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    Bytes := R.InstanceCount * SizeOf(TRayInstanceData);
    P := Ctx.Upload(Bytes, 256, Res, Off, RecordsGpu);
    Move(S.Records[0], P^, Bytes);
    L.SetGraphicsRootShaderResourceView(3, RecordsGpu);
    // An empty table points at the start of the allocation: past its end may be past the end of the heap.
    Gpu4 := TableGpu;
    if S.Geometries.Count > 0 then
      Gpu4.ptr := TableGpu.ptr + UInt64(2) * Ctx.SrvIncrement;
    L.SetGraphicsRootDescriptorTable(4, Gpu4);
    Gpu4 := TableGpu;
    if S.Textures.Count > 0 then
      Gpu4.ptr := TableGpu.ptr + UInt64(2 + S.Geometries.Count) * Ctx.SrvIncrement;
    L.SetGraphicsRootDescriptorTable(5, Gpu4);
    Rtv := T.RenderTarget;
    L.OMSetRenderTargets(1, @Rtv, False, nil);
    L.SetPipelineState(S.Pso(3, T.Format, C.Samples, D.Samples > 1));
    SetArea(L, C.Width, C.Height);
    L.DrawInstanced(3, 1, 0, 0);
  end;

  // The root signature and the target changed: the canvas and the 3D commands set theirs again.
  Ctx.Owner := nil;
  R.TargetBound := False;
  S.ReadGen := Ctx.ListGen;
  S.ReadEpoch := S.Epoch;
  for I := 0 to R.InstanceCount - 1 do
    R.Materials[I].Texture := nil;
end;

{ Application passes }

/// <summary>Bytes into a TFastRayBuffer (TCmdRayWrite).</summary>
procedure HandleRayWrite(const AData: Pointer);
var
  C: PCmdRayWrite;
  B: TRayResource12;
  Ctx: TGpu12Context;
  Src, P: PByte;
  Res: ID3D12Resource;
  Off, Gpu: UInt64;
begin
  C := AData;
  B := C.Buffer;
  if B.Resource = nil then
    Exit;
  if C.Blob <> nil then
    Src := @TBlob(C.Blob).Data[0]
  else
    Src := PByte(C) + SizeOf(TCmdRayWrite);
  Ctx := Gpu12;
  P := Ctx.Upload(C.Size, 16, Res, Off, Gpu);
  Move(Src^, P^, C.Size);
  B.Use(D3D12_RESOURCE_STATE_COPY_DEST);
  Ctx.FlushBarriers;
  Ctx.List.CopyBufferRegion(B.Resource, C.Offset, Res, Off, C.Size);
end;

/// <summary>An application pass (TCmdRayPass): the scene's top-level structure if it does not hold the objects drawn
/// so far, then the compute dispatch or the full-screen pixel pass with the fixed root signature (FastRayApp.hlsli).
/// </summary>
procedure HandleRayPass(const AData: Pointer);
var
  C: PCmdRayPass;
  S: TRayState;
  Sh: TRayShader12;
  Ctx: TGpu12Context;
  L: ID3D12GraphicsCommandList;
  T, D, Tex: TTexture12;
  Pso: ID3D12PipelineState;
  E: PRayEntry;
  Views: TArray<TD3D12_CPU_DESCRIPTOR_HANDLE>;
  N, I: Integer;
  Table, View, Rtv: TD3D12_CPU_DESCRIPTOR_HANDLE;
  TableGpu, SrvGpu, UavGpu: TD3D12_GPU_DESCRIPTOR_HANDLE;
  P: PByte;
  Res: ID3D12Resource;
  Off, FrameGpu, AppGpu, Scene: UInt64;
begin
  C := AData;
  S := RayState;
  if S = nil then
    Exit;
  Sh := TRayShader12(C.Shader);
  T := C.Target;
  D := C.Depth;
  Pso := Sh.Pso(S, T.Format);
  if Pso = nil then
    Exit;
  RayBeginScene(S, C.Scene);
  EnsureBlank;
  Ctx := Gpu12;
  N := 1 + C.SrvCount + C.UavCount;
  // First, as it may hand the list to the GPU when the descriptor ring is full: the depth buffer, the SRV entries, the
  // UAV entries.
  Table := Ctx.AllocTable(N, TableGpu);
  RayBuildTlas(S);
  L := Ctx.List;

  // The states: the SRV entries and the depth buffer read, the UAV entries written, the target drawn into. A pixel
  // pass cannot read the target it draws into: such an entry reads the blank texture.
  E := PRayEntry(PByte(C) + SizeOf(TCmdRayPass));
  SetLength(Views, N);
  for I := 0 to C.SrvCount + C.UavCount - 1 do
  begin
    if E[I].Texture then
    begin
      Tex := TTexture12(E[I].Obj);
      if (not Sh.Compute and (Tex = T)) or (Tex.GpuResource = nil) then
        Tex := G.Blank;
      Tex.Use(StateRayRead);
      Views[1 + I] := Tex.ShaderView;
    end
    else if I < C.SrvCount then
    begin
      TRayResource12(E[I].Obj).Use(StateRayRead);
      Views[1 + I] := TRayResource12(E[I].Obj).ShaderView;
    end
    else
    begin
      TRayResource12(E[I].Obj).Use(D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
      Views[1 + I] := TRayResource12(E[I].Obj).UnorderedView;
    end;
  end;
  View.ptr := 0;
  if D <> nil then
  begin
    D.Use(TD3D12_RESOURCE_STATES(Ord(D3D12_RESOURCE_STATE_DEPTH_READ) or Ord(StateRayRead)));
    View := DepthShaderView(D, Ctx);
    Views[0] := View;
  end
  else
    Views[0] := G.Blank.ShaderView;
  if not Sh.Compute then
    T.Use(D3D12_RESOURCE_STATE_RENDER_TARGET);
  // The writes of earlier passes (and the structures' builds) are done before this pass reads or writes.
  RayBarrier(S);
  for I := 0 to N - 1 do
    Ctx.Device.CopyDescriptorsSimple(1, Offset(Table, I, Ctx.SrvIncrement), Views[I],
      D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
  if View.ptr <> 0 then
    Ctx.SrvPool.Release(View);
  // An empty table points at the start of the allocation: past its end may be past the end of the heap.
  SrvGpu := TableGpu;
  if C.SrvCount > 0 then
    SrvGpu.ptr := TableGpu.ptr + Ctx.SrvIncrement;
  UavGpu := TableGpu;
  if C.UavCount > 0 then
    UavGpu.ptr := TableGpu.ptr + UInt64(1 + C.SrvCount) * Ctx.SrvIncrement;

  P := Ctx.Upload(AlignUp(SizeOf(TRayFrame), 256), 256, Res, Off, FrameGpu);
  Move(C.Frame, P^, SizeOf(TRayFrame));
  AppGpu := FrameGpu;
  if C.ConstantSize > 0 then
  begin
    P := Ctx.Upload(AlignUp(C.ConstantSize, 256), 256, Res, Off, AppGpu);
    Move((PByte(E) + (C.SrvCount + C.UavCount) * SizeOf(TRayEntry))^, P^, C.ConstantSize);
  end;
  Scene := S.Tlas.GetGPUVirtualAddress;
  if Sh.Compute then
  begin
    L.SetComputeRootSignature(S.AppRoot);
    L.SetComputeRootConstantBufferView(0, FrameGpu);
    L.SetComputeRootConstantBufferView(1, AppGpu);
    L.SetComputeRootShaderResourceView(2, Scene);
    L.SetComputeRootDescriptorTable(3, TableGpu);
    for I := 4 to 6 do
      L.SetComputeRootDescriptorTable(I, SrvGpu);
    for I := 7 to 9 do
      L.SetComputeRootDescriptorTable(I, UavGpu);
    L.SetPipelineState(Pso);
    L.Dispatch(C.GroupsX, C.GroupsY, C.GroupsZ);
  end
  else
  begin
    L.SetGraphicsRootSignature(S.AppRoot);
    L.SetGraphicsRootConstantBufferView(0, FrameGpu);
    L.SetGraphicsRootConstantBufferView(1, AppGpu);
    L.SetGraphicsRootShaderResourceView(2, Scene);
    L.SetGraphicsRootDescriptorTable(3, TableGpu);
    for I := 4 to 6 do
      L.SetGraphicsRootDescriptorTable(I, SrvGpu);
    for I := 7 to 9 do
      L.SetGraphicsRootDescriptorTable(I, UavGpu);
    Rtv := T.RenderTarget;
    L.OMSetRenderTargets(1, @Rtv, False, nil);
    L.SetPipelineState(Pso);
    SetArea(L, C.Width, C.Height);
    L.IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    L.DrawInstanced(3, 1, 0, 0);
  end;
  // The root signature, the pipeline and the target changed: the canvas and the 3D commands set theirs again.
  Ctx.Owner := nil;
  R.TargetBound := False;
  S.ReadGen := Ctx.ListGen;
  S.ReadEpoch := S.Epoch;
end;
