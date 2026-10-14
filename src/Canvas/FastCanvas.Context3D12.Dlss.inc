{ Native DLSS SR (originally written by Hemul GM, https://github.com/HemulGM). A low-resolution 3D scene is
  reconstructed before the first screen-projected draw.
  The settings panel is composited afterward at the window's resolution.
  The state of a context lives as long as the context: made when DLSS is first wanted (DlssMode, DlssAvailable,
  DlssStatus), with the NGX session of the device (TFastDlss.Acquire) and the context's feature; FreeBuffer drops its
  textures only, a device loss its feature and the objects of the old device.
  Motion vectors: every opaque object draws its own after its draw (DlssMotionDraw, flagged in blue); at the finish
  the pixels no object wrote get the camera's motion from the depth (PSResolve), as DLSS needs vectors everywhere.
  FastDlssEmulate: the same phase with a shader instead of NGX (PSEmulate), on any graphics card. }

{$I FastCanvas.DlssShaders.inc}

const
  // Pipelines of TDlssState.Pso: the objects' motion, then full-screen passes.
  DlssMotionPass = 0;
  DlssCopyPass = 1;
  DlssDepthPass = 2;
  DlssResolvePass = 3;
  DlssEmulatePass = 4;
  DlssFillPass = 5;
  /// <summary>Shader views of a full-screen pass (Source .. Source4 of FastDlss.hlsl).</summary>
  DlssSources = 5;

type
  TDlssHistory = record
    Matrix: TMatrix3D;
    Frame: Cardinal;
  end;

  TDlssState = class(TInterfacedObject)
  public
    /// <summary>The NGX session of the device (EnsureSession, main thread), nil before.</summary>
    Session: TFastDlss;
    SessionRef: IInterface;
    /// <summary>The context's DLSS feature, nil when DLSS is not available. Replaced only while the render thread
    /// and the GPU do not use it (TFastDlss.Lock for readers on other threads).</summary>
    Feature: TFastDlssFeature;
    Mode: TFastDlssMode;
    Hdr, Active: Boolean;
    /// <summary>Taken from FastDlssEmulate, FastDlssAutoExposure, FastDlssPreset and FastDlssConservativeMotion when the
    /// textures are made (Conservative: and the device rasterizes conservatively).</summary>
    Emulation: TFastDlssEmulation;
    AutoExposure: Boolean;
    Preset: TFastDlssPreset;
    Conservative: Boolean;
    /// <summary>The texture LOD bias of the scene's samplers: log2(render width / output width) - 1, as NVIDIA's
    /// guide recommends (textures sampled as at the output size).</summary>
    MipBias: Single;
    InputSize, OutputSize: TSize;
    /// <summary>ObjectMotion: the objects' vectors (blue 1 where written); Motion: the vectors of every pixel, given
    /// to DLSS; History, PreviousDepth: the last output and depth of the emulation; Exposure: 1x1, without auto
    /// exposure.</summary>
    Color, Prepared, Depth, LinearDepth, ObjectMotion, Motion, Output, History, PreviousDepth, Exposure: IInterface;
    Root: ID3D12RootSignature;
    Psos: TDictionary<UInt64, ID3D12PipelineState>;
    Models: TDictionary<UInt64, TDlssHistory>;
    Occurrences: TDictionary<UInt64, Integer>;
    Frame: Cardinal;
    Jitter, PreviousJitter: TPointF;
    LastTick: UInt64;
    /// <summary>The camera (world to clip, without the jitter; Rel: about the camera's position) at the finish of
    /// frame CameraFrame. Main thread.</summary>
    CameraViewProj, CameraViewProjRel: TMatrix4D;
    CameraFrame: Cardinal;
    /// <summary>Frames the emulation made (render thread).</summary>
    EmulatedFrames: Int64;
    constructor Create;
    destructor Destroy; override;
    /// <summary>The session of the current device and a feature on it. Main thread.</summary>
    procedure EnsureSession;
    /// <summary>FreeBuffer: the textures go (made again for the new size); the history starts over.</summary>
    procedure DropTextures;
    /// <summary>The device is gone and the GPU idle: its feature and objects go.</summary>
    procedure DeviceLost;
    procedure MakeTextures;
    procedure EnsureRoot;
    function Pso(const AKind, AStride, AOffset, ACull: Integer; const AFormat: TDXGI_FORMAT): ID3D12PipelineState;
    function JitterMatrix: TMatrix3D;
    procedure NextFrame;
  end;

  PCmdDlssBegin = ^TCmdDlssBegin;
  TCmdDlssBegin = packed record
    State: Pointer;
  end;
  PCmdDlssFinish = ^TCmdDlssFinish;
  TCmdDlssFinish = packed record
    State, Target: Pointer;
    /// <summary>The jitter sent to NGX (FastDlssJitterTest), and the one of the projection.</summary>
    Jitter, Applied: TPointF;
    Reset, CameraMotion: Boolean;
    FrameTime: Single;
    View: TFastDlssView;
    /// <summary>The clip position (without the jitter) now to the one of the frame before; Rel: without the camera's
    /// change of position.</summary>
    ClipToPrevious, ClipToPreviousRel: TMatrix3D;
    /// <summary>The emulation: the distance of a depth (FastDlss.hlsl, DepthParams.xy), the jitter of the frame
    /// before.</summary>
    DepthToDistance, PreviousJitter: TPointF;
  end;
  /// <summary>The constants of FastDlss.hlsl.</summary>
  TDlssMotionConstants = packed record
    Current, Previous: TMatrix3D;
    JitterNdc, Size: TPointF;
    Options: array[0..3] of Single;
    OutputSize, Jitter: TPointF;
    DepthToDistance, PreviousJitter: TPointF;
  end;

function DlssTexture(const ARef: IInterface): TTexture12; inline;
begin
  Result := TTexture12(ARef as TObject);
end;

constructor TDlssState.Create;
begin
  inherited;
  Psos := TDictionary<UInt64, ID3D12PipelineState>.Create;
  Models := TDictionary<UInt64, TDlssHistory>.Create;
  Occurrences := TDictionary<UInt64, Integer>.Create;
end;

destructor TDlssState.Destroy;
begin
  // The context has drained the render queue and waited for the GPU (FreeBuffer).
  Feature.Free;
  Psos.Free;
  Models.Free;
  Occurrences.Free;
  inherited;
end;

procedure TDlssState.EnsureSession;
begin
  if (Session <> nil) and (Session.Device = TFastDevice.D3D12) then
    Exit;
  // First use, or a new device (DeviceLost released the feature of the old one).
  DeviceLost;
  Session := TFastDlss.Acquire(TFastDevice.D3D12);
  SessionRef := Session;
  if Session.Available then
    Feature := TFastDlssFeature.Create(Session);
end;

procedure TDlssState.DropTextures;
begin
  Active := False;
  Color := nil;
  Prepared := nil;
  Depth := nil;
  LinearDepth := nil;
  ObjectMotion := nil;
  Motion := nil;
  Output := nil;
  History := nil;
  PreviousDepth := nil;
  Exposure := nil;
  Frame := 0;
  CameraFrame := 0;
  LastTick := 0;
  Models.Clear;
end;

procedure TDlssState.DeviceLost;
var
  F: TFastDlssFeature;
begin
  DropTextures;
  TFastDlss.Lock;
  try
    F := Feature;
    Feature := nil;
  finally
    TFastDlss.Unlock;
  end;
  F.Free;
  Root := nil;
  Psos.Clear;
  Session := nil;
  SessionRef := nil;
end;

procedure TDlssState.MakeTextures;
begin
  Color := NewTexture(InputSize.Width, InputSize.Height, 1, 1, DXGI_FORMAT_R16G16B16A16_FLOAT,
    D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET, D3D12_RESOURCE_STATE_RENDER_TARGET);
  Prepared := NewTexture(InputSize.Width, InputSize.Height, 1, 1, DXGI_FORMAT_R16G16B16A16_FLOAT,
    D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET, D3D12_RESOURCE_STATE_RENDER_TARGET);
  LinearDepth := NewTexture(InputSize.Width, InputSize.Height, 1, 1, DXGI_FORMAT_R32_FLOAT,
    D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET, D3D12_RESOURCE_STATE_RENDER_TARGET);
  ObjectMotion := NewTexture(InputSize.Width, InputSize.Height, 1, 1, DXGI_FORMAT_R16G16B16A16_FLOAT,
    D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET, D3D12_RESOURCE_STATE_RENDER_TARGET);
  Motion := NewTexture(InputSize.Width, InputSize.Height, 1, 1, DXGI_FORMAT_R16G16_FLOAT,
    D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET, D3D12_RESOURCE_STATE_RENDER_TARGET);
  if Emulation <> TFastDlssEmulation.Off then
  begin
    // The emulation draws its output and reads it back as the history of the next frame.
    Output := NewTexture(OutputSize.Width, OutputSize.Height, 1, 1, DXGI_FORMAT_R16G16B16A16_FLOAT,
      D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET, D3D12_RESOURCE_STATE_RENDER_TARGET);
    History := NewTexture(OutputSize.Width, OutputSize.Height, 1, 1, DXGI_FORMAT_R16G16B16A16_FLOAT,
      D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET, D3D12_RESOURCE_STATE_RENDER_TARGET);
    PreviousDepth := NewTexture(InputSize.Width, InputSize.Height, 1, 1, DXGI_FORMAT_R32_FLOAT,
      D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET, D3D12_RESOURCE_STATE_RENDER_TARGET);
    Exit;
  end;
  Output := NewTexture(OutputSize.Width, OutputSize.Height, 1, 1, DXGI_FORMAT_R16G16B16A16_FLOAT,
    D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
  DlssTexture(Output).Uncleared := False;
  if not AutoExposure then
    Exposure := NewTexture(1, 1, 1, 1, DXGI_FORMAT_R32_FLOAT, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET,
      D3D12_RESOURCE_STATE_RENDER_TARGET);
end;

procedure TDlssState.EnsureRoot;
var Params: array[0..1] of TD3D12_ROOT_PARAMETER; Range: TD3D12_DESCRIPTOR_RANGE;
  Sampler: TD3D12_STATIC_SAMPLER_DESC; Desc: TD3D12_ROOT_SIGNATURE_DESC; Blob, Errors: ID3DBlob;
begin
  if Root <> nil then Exit;
  Range.Init(D3D12_DESCRIPTOR_RANGE_TYPE_SRV, DlssSources, 0);
  Params[0].InitAsConstantBufferView(0);
  Params[1].InitAsDescriptorTable(1, @Range, D3D12_SHADER_VISIBILITY_PIXEL);
  Sampler := TD3D12_STATIC_SAMPLER_DESC.Create(0, D3D12_FILTER_MIN_MAG_MIP_LINEAR,
    D3D12_TEXTURE_ADDRESS_MODE_CLAMP, D3D12_TEXTURE_ADDRESS_MODE_CLAMP, D3D12_TEXTURE_ADDRESS_MODE_CLAMP);
  Desc.Init(Length(Params), @Params[0], 1, @Sampler,
    D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT);
  Check(D3D12SerializeRootSignature(Desc, D3D_ROOT_SIGNATURE_VERSION_1, @Blob, @Errors), 'DLSS root signature');
  Check(TFastDevice.D3D12.CreateRootSignature(0, Blob.GetBufferPointer, Blob.GetBufferSize, IID_ID3D12RootSignature,
    Root), 'DLSS CreateRootSignature');
end;

function TDlssState.Pso(const AKind, AStride, AOffset, ACull: Integer;
  const AFormat: TDXGI_FORMAT): ID3D12PipelineState;
var Desc: TD3D12_GRAPHICS_PIPELINE_STATE_DESC; Element: TD3D12_INPUT_ELEMENT_DESC; Key: UInt64;
// As the scene's draws (TFastContext3D.FState.Cull): 1 culls the back faces.
const Culls: array[0..2] of TD3D12_CULL_MODE = (D3D12_CULL_MODE_NONE, D3D12_CULL_MODE_BACK, D3D12_CULL_MODE_FRONT);
begin
  Key := UInt64(Cardinal(AStride)) shl 32 or UInt64(Cardinal(AOffset)) shl 16 or
    UInt64(Ord(AFormat)) shl 8 or UInt64(ACull shl 4 or AKind) or UInt64(Ord(Conservative)) shl 63;
  if Psos.TryGetValue(Key, Result) then Exit;
  EnsureRoot;
  Desc := Default(TD3D12_GRAPHICS_PIPELINE_STATE_DESC);
  Desc.pRootSignature := Root;
  Desc.RasterizerState := TD3D12_RASTERIZER_DESC.Create(D3D12_DEFAULT);
  Desc.RasterizerState.CullMode := D3D12_CULL_MODE_NONE;
  Desc.BlendState := TD3D12_BLEND_DESC.Create(D3D12_DEFAULT);
  Desc.DepthStencilState := TD3D12_DEPTH_STENCIL_DESC.Create(D3D12_DEFAULT);
  Desc.DepthStencilState.DepthEnable := False;
  Desc.DepthStencilState.StencilEnable := False;
  Desc.SampleMask := $FFFFFFFF;
  Desc.SampleDesc.Count := 1;
  Desc.PrimitiveTopologyType := D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
  Desc.NumRenderTargets := 1;
  Desc.RTVFormats[0] := AFormat;
  if AKind = DlssMotionPass then
  begin
    Element := Default(TD3D12_INPUT_ELEMENT_DESC);
    Element.SemanticName := 'POSITION';
    Element.Format := DXGI_FORMAT_R32G32B32_FLOAT;
    Element.AlignedByteOffset := AOffset;
    Element.InputSlotClass := D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA;
    Desc.InputLayout.pInputElementDescs := @Element;
    Desc.InputLayout.NumElements := 1;
    Desc.VS := TD3D12_SHADER_BYTECODE.Create(@DlssVSMotion[0], Length(DlssVSMotion));
    Desc.PS := TD3D12_SHADER_BYTECODE.Create(@DlssPSMotion[0], Length(DlssPSMotion));
    Desc.RasterizerState.CullMode := Culls[EnsureRange(ACull, 0, 2)];
    // Pulled slightly towards the camera: FMX's shaders and this one compute the depth with other instructions, the
    // test must not depend on the last bits.
    Desc.RasterizerState.DepthBias := -64;
    // Thin features (a cone's tip at the render size) cover a pixel only now and then: conservative rasterization
    // gives every pixel they touch their vectors (NVIDIA's DLSS guide, 3.6.4).
    if Conservative then
      Desc.RasterizerState.ConservativeRaster := D3D12_CONSERVATIVE_RASTERIZATION_MODE_ON;
    Desc.DepthStencilState.DepthEnable := True;
    Desc.DepthStencilState.DepthWriteMask := D3D12_DEPTH_WRITE_MASK_ZERO;
    Desc.DepthStencilState.DepthFunc := D3D12_COMPARISON_FUNC_LESS_EQUAL;
    Desc.DSVFormat := DXGI_FORMAT_D24_UNORM_S8_UINT;
  end
  else
  begin
    Desc.VS := TD3D12_SHADER_BYTECODE.Create(@DlssVSFull[0], Length(DlssVSFull));
    case AKind of
      DlssDepthPass: Desc.PS := TD3D12_SHADER_BYTECODE.Create(@DlssPSDepth[0], Length(DlssPSDepth));
      DlssResolvePass: Desc.PS := TD3D12_SHADER_BYTECODE.Create(@DlssPSResolve[0], Length(DlssPSResolve));
      DlssEmulatePass: Desc.PS := TD3D12_SHADER_BYTECODE.Create(@DlssPSEmulate[0], Length(DlssPSEmulate));
      DlssFillPass: Desc.PS := TD3D12_SHADER_BYTECODE.Create(@DlssPSFill[0], Length(DlssPSFill));
    else
      Desc.PS := TD3D12_SHADER_BYTECODE.Create(@DlssPSCopy[0], Length(DlssPSCopy));
    end;
  end;
  Check(TFastDevice.D3D12.CreateGraphicsPipelineState(@Desc, IID_ID3D12PipelineState, Result), 'DLSS pipeline');
  Psos.Add(Key, Result);
end;

/// <summary>The device rasterizes conservatively (D3D12_OPTIONS: tier 1 or higher).</summary>
function DlssConservativeSupported: Boolean;
var
  Options: TD3D12_FEATURE_DATA_D3D12_OPTIONS;
begin
  Options := Default(TD3D12_FEATURE_DATA_D3D12_OPTIONS);
  Result := Succeeded(TFastDevice.D3D12.CheckFeatureSupport(D3D12_FEATURE_D3D12_OPTIONS, @Options, SizeOf(Options))) and
    (Ord(Options.ConservativeRasterizationTier) >= Ord(D3D12_CONSERVATIVE_RASTERIZATION_TIER_1));
end;

function Halton(var AIndex: Cardinal; const ABase: Cardinal): Single;
var F: Single;
begin
  Result := 0; F := 1;
  while AIndex > 0 do
  begin
    F := F / ABase;
    Result := Result + F * (AIndex mod ABase);
    AIndex := AIndex div ABase;
  end;
end;

procedure TDlssState.NextFrame;
var I, J, Phases: Cardinal; Key: UInt64;
begin
  Inc(Frame);
  for Key in Models.Keys.ToArray do
    if Models[Key].Frame + 1 < Frame then Models.Remove(Key);
  Phases := Max(8, Ceil(8 * Sqr(OutputSize.Width / InputSize.Width)));
  I := (Frame - 1) mod Phases + 1; J := I;
  Jitter := PointF(Halton(I, 2) - 0.5, Halton(J, 3) - 0.5);
  if FastDlssJitterTest = TFastDlssJitterTest.Off then
    Jitter := PointF(0, 0);
  Occurrences.Clear;
end;

function TDlssState.JitterMatrix: TMatrix3D;
begin
  Result := TMatrix3D.Identity;
  Result.m41 := 2 * Jitter.X / InputSize.Width;
  Result.m42 := -2 * Jitter.Y / InputSize.Height;
end;

procedure DlssInvalidateReplay;
var Heaps: array[0..1] of ID3D12DescriptorHeap;
begin
  Heaps[0] := Gpu12.Heap; Heaps[1] := G.SamplerHeap;
  Gpu12.List.SetDescriptorHeaps(Length(Heaps), @Heaps[0]);
  Gpu12.Owner := nil;
  R.TargetBound := False;
  R.UnitsBound := False;
  R.VSBound := False;
  R.PSBound := False;
end;

procedure HandleDlssBegin(const AData: Pointer);
const Zero: TSingleArray4 = (0, 0, 0, 0);
var S: TDlssState; T: TTexture12; Ctx: TGpu12Context;
begin
  S := TDlssState(PCmdDlssBegin(AData).State);
  Ctx := Gpu12;
  if S.Emulation = TFastDlssEmulation.Off then
    S.Feature.Configure(Ctx.List, S.InputSize, S.OutputSize, S.Mode, S.Hdr, S.AutoExposure, S.Preset);
  T := DlssTexture(S.ObjectMotion);
  T.Use(D3D12_RESOURCE_STATE_RENDER_TARGET);
  Ctx.FlushBarriers;
  Ctx.List.ClearRenderTargetView(T.RenderTarget, Zero, 0, nil);
  DlssInvalidateReplay;
end;

procedure DlssMotionDraw(const C: PCmdDraw; const VB: TD3D12_VERTEX_BUFFER_VIEW; const IB: TD3D12_INDEX_BUFFER_VIEW);
var S: TDlssState; Motion, Depth: TTexture12; Ctx: TGpu12Context; L: ID3D12GraphicsCommandList;
  Constants: TDlssMotionConstants; Res: ID3D12Resource; Off, Gpu: UInt64; P: PByte;
  Rtv, Dsv: TD3D12_CPU_DESCRIPTOR_HANDLE;
begin
  if C.DlssState = nil then Exit;
  S := TDlssState(C.DlssState);
  Ctx := Gpu12;
  Motion := DlssTexture(S.ObjectMotion); Depth := DlssTexture(S.Depth);
  Motion.Use(D3D12_RESOURCE_STATE_RENDER_TARGET);
  // Tested, not written (the pipeline's write mask is zero): the depth buffer stays in the state of the scene's draws,
  // no transition per object.
  Depth.Use(D3D12_RESOURCE_STATE_DEPTH_WRITE);
  Ctx.FlushBarriers;
  Constants := Default(TDlssMotionConstants);
  Constants.Current := C.DlssCurrent; Constants.Previous := C.DlssPrevious;
  Constants.JitterNdc := PointF(2 * S.Jitter.X / S.InputSize.Width, -2 * S.Jitter.Y / S.InputSize.Height);
  Constants.Size := PointF(S.InputSize.Width, S.InputSize.Height);
  P := Ctx.Upload(256, 256, Res, Off, Gpu);
  Move(Constants, P^, SizeOf(Constants));
  S.EnsureRoot;
  L := Ctx.List;
  L.SetGraphicsRootSignature(S.Root);
  L.SetPipelineState(S.Pso(DlssMotionPass, C.VertexStride, C.DlssPosition, C.DlssCull, Motion.Format));
  L.SetGraphicsRootConstantBufferView(0, Gpu);
  Rtv := Motion.RenderTarget; Dsv := Depth.DepthView;
  L.OMSetRenderTargets(1, @Rtv, False, @Dsv);
  SetArea(L, S.InputSize.Width, S.InputSize.Height);
  L.IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
  L.IASetVertexBuffers(0, 1, @VB); L.IASetIndexBuffer(IB);
  L.DrawIndexedInstanced(C.IndexCount, 1, 0, 0, 0);
  DlssInvalidateReplay;
end;

/// <summary>A full-screen pass into ADst with the pipeline AKind: ASources are Source .. Source4 of FastDlss.hlsl
/// (the last one repeated; ADepth: a depth buffer, read as R24), AConstants its constants.</summary>
procedure DlssDraw(const S: TDlssState; const AKind: Integer; const ASources: array of TTexture12;
  const ADepth: Boolean; const ADst: TTexture12; const AConstants: TDlssMotionConstants);
var Ctx: TGpu12Context; Cpu, View, Rtv: TD3D12_CPU_DESCRIPTOR_HANDLE; GpuTable: TD3D12_GPU_DESCRIPTOR_HANDLE;
  Res: ID3D12Resource; Off, Gpu: UInt64; P: PByte; L: ID3D12GraphicsCommandList; I: Integer;
begin
  Ctx := Gpu12;
  Cpu := Ctx.AllocTable(DlssSources, GpuTable);
  if ADepth then
  begin
    ASources[0].Use(TD3D12_RESOURCE_STATES(Ord(D3D12_RESOURCE_STATE_DEPTH_READ) or Ord(StateRead)));
    View := DepthShaderView(ASources[0], Ctx);
    for I := 0 to DlssSources - 1 do
      Ctx.Device.CopyDescriptorsSimple(1, Offset(Cpu, I, Ctx.SrvIncrement), View,
        D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    Ctx.SrvPool.Release(View);
  end
  else
  begin
    for I := 0 to High(ASources) do
      ASources[I].Use(StateRead);
    for I := 0 to DlssSources - 1 do
      Ctx.Device.CopyDescriptorsSimple(1, Offset(Cpu, I, Ctx.SrvIncrement),
        ASources[Min(I, High(ASources))].ShaderView, D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
  end;
  ADst.Use(D3D12_RESOURCE_STATE_RENDER_TARGET);
  Ctx.FlushBarriers;
  P := Ctx.Upload(256, 256, Res, Off, Gpu); FillChar(P^, 256, 0); Move(AConstants, P^, SizeOf(AConstants));
  S.EnsureRoot;
  DlssInvalidateReplay;
  L := Ctx.List;
  L.SetGraphicsRootSignature(S.Root);
  L.SetGraphicsRootConstantBufferView(0, Gpu);
  L.SetGraphicsRootDescriptorTable(1, GpuTable);
  L.SetPipelineState(S.Pso(AKind, 0, 0, 0, ADst.Format));
  Rtv := ADst.RenderTarget;
  L.OMSetRenderTargets(1, @Rtv, False, nil);
  SetArea(L, ADst.Width, ADst.Height);
  L.IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
  L.DrawInstanced(3, 1, 0, 0);
  DlssInvalidateReplay;
end;

procedure DlssBlit(const S: TDlssState; const Src, Dst: TTexture12; const ADepth, ADecode, AEncode: Boolean;
  const AMotionScale: Single = 0);
var K: TDlssMotionConstants;
begin
  K := Default(TDlssMotionConstants);
  K.Current.m11 := Ord(ADecode); K.Current.m12 := Ord(AEncode); K.Current.m13 := AMotionScale;
  DlssDraw(S, DlssCopyPass + Ord(ADepth), [Src], ADepth, Dst, K);
end;

procedure HandleDlssFinish(const AData: Pointer);
var C: PCmdDlssFinish; S: TDlssState; Ctx: TGpu12Context; Output, Exposure: TTexture12;
  Barrier: TD3D12_RESOURCE_BARRIER; K: TDlssMotionConstants; Done: Boolean; ExposureResource: ID3D12Resource;
  Last: IInterface;
begin
  C := AData; S := TDlssState(C.State); Ctx := Gpu12;
  DlssBlit(S, DlssTexture(S.Color), DlssTexture(S.Prepared), False, S.Hdr, False);
  DlssBlit(S, DlssTexture(S.Depth), DlssTexture(S.LinearDepth), True, False, False);
  // The vectors of every pixel: the objects' where they wrote, the camera's elsewhere.
  K := Default(TDlssMotionConstants);
  K.Current := C.ClipToPrevious; K.Previous := C.ClipToPreviousRel;
  K.JitterNdc := PointF(2 * C.Applied.X / S.InputSize.Width, -2 * C.Applied.Y / S.InputSize.Height);
  K.Size := PointF(S.InputSize.Width, S.InputSize.Height);
  K.Options[0] := Ord(C.CameraMotion);
  DlssDraw(S, DlssResolvePass, [DlssTexture(S.ObjectMotion), DlssTexture(S.LinearDepth)], False,
    DlssTexture(S.Motion), K);
  Output := DlssTexture(S.Output);
  if S.Emulation <> TFastDlssEmulation.Off then
  begin
    K.Options[0] := 0;
    K.Options[1] := Ord(C.Reset);
    K.Options[2] := Ord(S.Emulation = TFastDlssEmulation.Temporal);
    K.OutputSize := PointF(S.OutputSize.Width, S.OutputSize.Height);
    K.Jitter := C.Applied;
    K.DepthToDistance := C.DepthToDistance;
    K.PreviousJitter := C.PreviousJitter;
    DlssDraw(S, DlssEmulatePass, [DlssTexture(S.Prepared), DlssTexture(S.History), DlssTexture(S.Motion),
      DlssTexture(S.LinearDepth), DlssTexture(S.PreviousDepth)], False, Output, K);
    AtomicIncrement(S.EmulatedFrames);
    Done := True;
  end
  else
  begin
    ExposureResource := nil;
    if S.Exposure <> nil then
    begin
      // A fixed exposure of 1.
      Exposure := DlssTexture(S.Exposure);
      K := Default(TDlssMotionConstants);
      K.Options[0] := 1;
      DlssDraw(S, DlssFillPass, [DlssTexture(S.Prepared)], False, Exposure, K);
      Exposure.Use(D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
      ExposureResource := Exposure.Resource;
    end;
    DlssTexture(S.Prepared).Use(D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    DlssTexture(S.LinearDepth).Use(D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    DlssTexture(S.Motion).Use(D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    Output.Use(D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    Ctx.FlushBarriers;
    Done := S.Feature.Evaluate(Ctx.List, DlssTexture(S.Prepared).Resource, DlssTexture(S.LinearDepth).Resource,
      DlssTexture(S.Motion).Resource, Output.Resource, ExposureResource, C.Jitter, C.Reset, C.FrameTime);
    if Done then
    begin
      Barrier := TD3D12_RESOURCE_BARRIER.CreateUAV(Output.Resource);
      Ctx.List.ResourceBarrier(1, @Barrier);
    end;
  end;
  if Done then
    case C.View of
      TFastDlssView.Input: DlssBlit(S, DlssTexture(S.Color), TTexture12(C.Target), False, False, False);
      TFastDlssView.Motion: DlssBlit(S, DlssTexture(S.Motion), TTexture12(C.Target), False, False, False, 0.1);
    else
      DlssBlit(S, Output, TTexture12(C.Target), False, False, S.Hdr);
    end
  else
    // A runtime failure keeps the demo visible; the UI shows the NGX error and does not report DLSS as active.
    DlssBlit(S, DlssTexture(S.Color), TTexture12(C.Target), False, False, False);
  if S.Emulation <> TFastDlssEmulation.Off then
  begin
    // This output and depth are the history of the next frame.
    Last := S.Output;
    S.Output := S.History;
    S.History := Last;
    Last := S.LinearDepth;
    S.LinearDepth := S.PreviousDepth;
    S.PreviousDepth := Last;
  end;
  DlssInvalidateReplay;
end;

procedure TFastContext3D12.EnsureDlss;
begin
  if FDlssState = nil then
    FDlssState := TDlssState.Create;
  // The emulation does not start NGX.
  if FastDlssEmulate = TFastDlssEmulation.Off then
    TDlssState(FDlssState as TObject).EnsureSession;
end;

function TFastContext3D12.GetDlssAvailable: Boolean;
begin
  if (Texture <> nil) or not DepthStencil then
    Exit(False);
  EnsureDlss;
  Result := (FastDlssEmulate <> TFastDlssEmulation.Off) or (TDlssState(FDlssState as TObject).Feature <> nil);
end;

function TFastContext3D12.GetDlssStatus: string;
var
  S: TDlssState;
begin
  if Texture <> nil then
    Exit('DLSS needs the window of a TForm3D');
  if not DepthStencil then
    Exit('DLSS needs a depth buffer');
  if not GetDlssAvailable then
    Exit(TDlssState(FDlssState as TObject).Session.Error);
  // Not the device lock: the render thread holds it for whole frames.
  S := TDlssState(FDlssState as TObject);
  if S.Active and (S.Emulation <> TFastDlssEmulation.Off) and (FDlssMode <> TFastDlssMode.Off) then
  begin
    if AtomicCmpExchange(S.EmulatedFrames, 0, 0) = 0 then
      Exit('Starting the emulation...');
    Exit(Format('Emulated %s: %dx%d -> %dx%d', [DlssModeName(FDlssMode), S.InputSize.Width, S.InputSize.Height,
      S.OutputSize.Width, S.OutputSize.Height]));
  end;
  TFastDlss.Lock;
  try
    if S.Feature = nil then
      Exit('Off');
    Result := S.Feature.Error;
    if Result <> '' then
      Exit;
    if (FDlssMode = TFastDlssMode.Off) or not S.Active then
      Exit('Off');
    if S.Feature.Frames = 0 then
      Exit('Starting DLSS SR...');
    Result := Format('%s: %dx%d -> %dx%d', [DlssModeName(FDlssMode), S.InputSize.Width, S.InputSize.Height,
      S.OutputSize.Width, S.OutputSize.Height]);
  finally
    TFastDlss.Unlock;
  end;
end;

function TFastContext3D12.GetDlssFrames: Int64;
var
  S: TDlssState;
begin
  Result := 0;
  if FDlssState = nil then
    Exit;
  S := TDlssState(FDlssState as TObject);
  if S.Emulation <> TFastDlssEmulation.Off then
    Exit(AtomicCmpExchange(S.EmulatedFrames, 0, 0));
  TFastDlss.Lock;
  try
    if S.Feature <> nil then
      Result := S.Feature.Frames;
  finally
    TFastDlss.Unlock;
  end;
end;

procedure TFastContext3D12.FinishDlssScene;
var S: TDlssState; C: PCmdDlssFinish; Target: TTexture12; Now: UInt64; M: TMatrix3D; V, P, ViewProj, ViewProjRel,
  Inv: TMatrix4D; I, J: Integer;
begin
  if not FDlssPhase then Exit;
  S := TDlssState(FDlssState as TObject);
  if (FScene <> 0) and (FRayObjects > 0) and (FRay.Shadows or FRay.AmbientOcclusion or FRay.Reflections) then RecordRay;
  FScene := 0;
  FDlssPhase := False;
  Target := TTexture12(DrawTarget);
  C := Rec(HandleDlssFinish, SizeOf(TCmdDlssFinish), FDlssState);
  C.State := S; C.Target := Target; C.Jitter := S.Jitter; C.Applied := S.Jitter; C.Reset := S.Frame = 1;
  C.View := FastDlssView; C.CameraMotion := FastDlssCameraMotion;
  if FastDlssJitterTest in [TFastDlssJitterTest.NegateX, TFastDlssJitterTest.NegateXY] then
    C.Jitter.X := -C.Jitter.X;
  if FastDlssJitterTest in [TFastDlssJitterTest.NegateY, TFastDlssJitterTest.NegateXY] then
    C.Jitter.Y := -C.Jitter.Y;
  // The camera's motion since the frame before, for the pixels without an object's vector: the camera without the
  // jitter (row vectors: world * view * projection) in double precision; Rel: the view without its translation (the
  // background, at infinity).
  M := CurrentCameraMatrix;
  for I := 0 to 3 do
    for J := 0 to 3 do
      V[I, J] := M.M[I].V[J];
  M := CurrentProjectionMatrix;
  for I := 0 to 3 do
    for J := 0 to 3 do
      P[I, J] := M.M[I].V[J];
  ViewProj := MulD(V, P);
  V[3, 0] := 0;
  V[3, 1] := 0;
  V[3, 2] := 0;
  ViewProjRel := MulD(V, P);
  C.ClipToPrevious := TMatrix3D.Identity;
  C.ClipToPreviousRel := TMatrix3D.Identity;
  if (S.CameraFrame > 0) and (S.CameraFrame + 1 = S.Frame) then
  begin
    if InverseD(ViewProj, Inv) then
      C.ClipToPrevious := ToSingle(MulD(Inv, S.CameraViewProj));
    if InverseD(ViewProjRel, Inv) then
      C.ClipToPreviousRel := ToSingle(MulD(Inv, S.CameraViewProjRel));
  end;
  S.CameraViewProj := ViewProj;
  S.CameraViewProjRel := ViewProjRel;
  S.CameraFrame := S.Frame;
  // The emulation's test of disocclusion: the view distance of a depth (z of the depth: P43 / (depth P34 - P33)).
  C.DepthToDistance := PointF(0, 1);
  if P[2, 3] <> 0 then
    C.DepthToDistance := PointF(-P[2, 2] / P[2, 3], P[3, 2] / P[2, 3]);
  C.PreviousJitter := S.PreviousJitter;
  S.PreviousJitter := S.Jitter;
  Now := TStopwatch.GetTimeStamp;
  if S.LastTick = 0 then
    C.FrameTime := 16.667
  else
    C.FrameTime := EnsureRange((Now - S.LastTick) * 1000 / TStopwatch.Frequency, 0.1, 1000);
  S.LastTick := Now;
  Keep(Target);
  RecordTarget;
end;

procedure TFastContext3D12.DoSetShaderVariable(const Name: string; const Data: array of TVector3D);
var M: TMatrix3D;
begin
  if FDlssPhase and not CurrentStates[TContextState.cs2DScene] and (Name = 'MVPMatrix') and (Length(Data) = 4) then
  begin
    Move(Data[0], M, SizeOf(M));
    M := M * TDlssState(FDlssState as TObject).JitterMatrix;
    inherited DoSetShaderVariable(Name, M.M);
  end
  else inherited;
end;

procedure TFastContext3D12.RecordDlssMotion(const C: Pointer; const AGeometry: UInt64;
  const APosition, ACull: Integer);
var D: PCmdDraw; S: TDlssState; Key: UInt64; Occurrence: Integer; History: TDlssHistory;
begin
  D := C; D.DlssState := nil;
  if not FDlssPhase or not FState.DepthTest or not FState.DepthWrite or (APosition < 0) then Exit;
  S := TDlssState(FDlssState as TObject);
  if not S.Occurrences.TryGetValue(AGeometry, Occurrence) then Occurrence := 0;
  S.Occurrences.AddOrSetValue(AGeometry, Occurrence + 1);
  Key := FastHashMix(AGeometry, Occurrence);
  D.DlssState := S; D.DlssPosition := APosition; D.DlssCull := ACull;
  // The matrix FMX gives its shaders (ApplyMaterial: CurrentMatrix * (camera * projection)), not the same product in
  // another order: the depth of the motion pass stays that of the scene's draw.
  D.DlssCurrent := CurrentModelViewProjectionMatrix;
  if S.Models.TryGetValue(Key, History) and (History.Frame + 1 = S.Frame) then D.DlssPrevious := History.Matrix
  else D.DlssPrevious := D.DlssCurrent;
  History.Matrix := D.DlssCurrent; History.Frame := S.Frame;
  S.Models.AddOrSetValue(Key, History);
  Keep(FDlssState);
end;
