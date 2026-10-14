{ Native DLSS SR (originally written by Hemul GM, https://github.com/HemulGM). A low-resolution 3D scene is
  reconstructed before the first screen-projected draw.
  The settings panel is composited afterward at the window's resolution.
  The state of a context lives as long as the context: made when DLSS is first wanted (DlssMode, DlssAvailable,
  DlssStatus), with the NGX session of the device (TFastDlss.Acquire) and the context's feature; FreeBuffer drops its
  textures only, a device loss its feature and the objects of the old device. }

{$I FastCanvas.DlssShaders.inc}

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
    InputSize, OutputSize: TSize;
    Color, Prepared, Depth, LinearDepth, Motion, Output: IInterface;
    Root: ID3D12RootSignature;
    Psos: TDictionary<UInt64, ID3D12PipelineState>;
    Models: TDictionary<UInt64, TDlssHistory>;
    Occurrences: TDictionary<UInt64, Integer>;
    Frame: Cardinal;
    Jitter: TPointF;
    LastTick: UInt64;
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
    Jitter: TPointF;
    Reset: Boolean;
    FrameTime: Single;
    View: TFastDlssView;
  end;
  TDlssMotionConstants = packed record
    Current, Previous: TMatrix3D;
    JitterNdc, Size: TPointF;
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
  Motion := nil;
  Output := nil;
  Frame := 0;
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
  Motion := NewTexture(InputSize.Width, InputSize.Height, 1, 1, DXGI_FORMAT_R16G16_FLOAT,
    D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET, D3D12_RESOURCE_STATE_RENDER_TARGET);
  Output := NewTexture(OutputSize.Width, OutputSize.Height, 1, 1, DXGI_FORMAT_R16G16B16A16_FLOAT,
    D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
  DlssTexture(Output).Uncleared := False;
end;

procedure TDlssState.EnsureRoot;
var Params: array[0..1] of TD3D12_ROOT_PARAMETER; Range: TD3D12_DESCRIPTOR_RANGE;
  Sampler: TD3D12_STATIC_SAMPLER_DESC; Desc: TD3D12_ROOT_SIGNATURE_DESC; Blob, Errors: ID3DBlob;
begin
  if Root <> nil then Exit;
  Range.Init(D3D12_DESCRIPTOR_RANGE_TYPE_SRV, 1, 0);
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
    UInt64(Ord(AFormat)) shl 8 or UInt64(ACull shl 4 or AKind);
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
  if AKind = 0 then
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
    Desc.DepthStencilState.DepthEnable := True;
    Desc.DepthStencilState.DepthWriteMask := D3D12_DEPTH_WRITE_MASK_ZERO;
    Desc.DepthStencilState.DepthFunc := D3D12_COMPARISON_FUNC_LESS_EQUAL;
    Desc.DSVFormat := DXGI_FORMAT_D24_UNORM_S8_UINT;
  end
  else
  begin
    Desc.VS := TD3D12_SHADER_BYTECODE.Create(@DlssVSFull[0], Length(DlssVSFull));
    if AKind = 2 then Desc.PS := TD3D12_SHADER_BYTECODE.Create(@DlssPSDepth[0], Length(DlssPSDepth))
    else Desc.PS := TD3D12_SHADER_BYTECODE.Create(@DlssPSCopy[0], Length(DlssPSCopy));
  end;
  Check(TFastDevice.D3D12.CreateGraphicsPipelineState(@Desc, IID_ID3D12PipelineState, Result), 'DLSS pipeline');
  Psos.Add(Key, Result);
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
  S.Feature.Configure(Ctx.List, S.InputSize, S.OutputSize, S.Mode, S.Hdr);
  T := DlssTexture(S.Motion);
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
  Motion := DlssTexture(S.Motion); Depth := DlssTexture(S.Depth);
  Motion.Use(D3D12_RESOURCE_STATE_RENDER_TARGET);
  // Tested, not written (the pipeline's write mask is zero): the depth buffer stays in the state of the scene's draws,
  // no transition per object.
  Depth.Use(D3D12_RESOURCE_STATE_DEPTH_WRITE);
  Ctx.FlushBarriers;
  Constants.Current := C.DlssCurrent; Constants.Previous := C.DlssPrevious;
  Constants.JitterNdc := PointF(2 * S.Jitter.X / S.InputSize.Width, -2 * S.Jitter.Y / S.InputSize.Height);
  Constants.Size := PointF(S.InputSize.Width, S.InputSize.Height);
  P := Ctx.Upload(256, 256, Res, Off, Gpu);
  Move(Constants, P^, SizeOf(Constants));
  S.EnsureRoot;
  L := Ctx.List;
  L.SetGraphicsRootSignature(S.Root);
  L.SetPipelineState(S.Pso(0, C.VertexStride, C.DlssPosition, C.DlssCull, Motion.Format));
  L.SetGraphicsRootConstantBufferView(0, Gpu);
  Rtv := Motion.RenderTarget; Dsv := Depth.DepthView;
  L.OMSetRenderTargets(1, @Rtv, False, @Dsv);
  SetArea(L, S.InputSize.Width, S.InputSize.Height);
  L.IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
  L.IASetVertexBuffers(0, 1, @VB); L.IASetIndexBuffer(IB);
  L.DrawIndexedInstanced(C.IndexCount, 1, 0, 0, 0);
  DlssInvalidateReplay;
end;

procedure DlssBlit(const S: TDlssState; const Src, Dst: TTexture12; const ADepth, ADecode, AEncode: Boolean;
  const AMotionScale: Single = 0);
var Ctx: TGpu12Context; Cpu, Rtv: TD3D12_CPU_DESCRIPTOR_HANDLE; GpuTable: TD3D12_GPU_DESCRIPTOR_HANDLE;
  K: array[0..3] of Single; Res: ID3D12Resource; Off, Gpu: UInt64; P: PByte; L: ID3D12GraphicsCommandList;
begin
  Ctx := Gpu12;
  Cpu := Ctx.AllocTable(1, GpuTable);
  if ADepth then
  begin
    Src.Use(TD3D12_RESOURCE_STATES(Ord(D3D12_RESOURCE_STATE_DEPTH_READ) or Ord(StateRead)));
    Rtv := DepthShaderView(Src, Ctx);
    Ctx.Device.CopyDescriptorsSimple(1, Cpu, Rtv, D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    Ctx.SrvPool.Release(Rtv);
  end
  else
  begin
    Src.Use(StateRead);
    Ctx.Device.CopyDescriptorsSimple(1, Cpu, Src.ShaderView, D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
  end;
  Dst.Use(D3D12_RESOURCE_STATE_RENDER_TARGET);
  Ctx.FlushBarriers;
  K[0] := Ord(ADecode); K[1] := Ord(AEncode); K[2] := AMotionScale; K[3] := 0;
  P := Ctx.Upload(256, 256, Res, Off, Gpu); FillChar(P^, 256, 0); Move(K, P^, SizeOf(K));
  S.EnsureRoot;
  DlssInvalidateReplay;
  L := Ctx.List;
  L.SetGraphicsRootSignature(S.Root);
  L.SetGraphicsRootConstantBufferView(0, Gpu);
  L.SetGraphicsRootDescriptorTable(1, GpuTable);
  L.SetPipelineState(S.Pso(1 + Ord(ADepth), 0, 0, 0, Dst.Format));
  Rtv := Dst.RenderTarget;
  L.OMSetRenderTargets(1, @Rtv, False, nil);
  SetArea(L, Dst.Width, Dst.Height);
  L.IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
  L.DrawInstanced(3, 1, 0, 0);
  DlssInvalidateReplay;
end;

procedure HandleDlssFinish(const AData: Pointer);
var C: PCmdDlssFinish; S: TDlssState; Ctx: TGpu12Context; Output: TTexture12; Barrier: TD3D12_RESOURCE_BARRIER;
begin
  C := AData; S := TDlssState(C.State); Ctx := Gpu12;
  DlssBlit(S, DlssTexture(S.Color), DlssTexture(S.Prepared), False, S.Hdr, False);
  DlssBlit(S, DlssTexture(S.Depth), DlssTexture(S.LinearDepth), True, False, False);
  DlssTexture(S.Prepared).Use(D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
  DlssTexture(S.LinearDepth).Use(D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
  DlssTexture(S.Motion).Use(D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
  Output := DlssTexture(S.Output);
  Output.Use(D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
  Ctx.FlushBarriers;
  if S.Feature.Evaluate(Ctx.List, DlssTexture(S.Prepared).Resource, DlssTexture(S.LinearDepth).Resource,
    DlssTexture(S.Motion).Resource, Output.Resource, C.Jitter, C.Reset, C.FrameTime) then
  begin
    Barrier := TD3D12_RESOURCE_BARRIER.CreateUAV(Output.Resource);
    Ctx.List.ResourceBarrier(1, @Barrier);
    case C.View of
      TFastDlssView.Input: DlssBlit(S, DlssTexture(S.Color), TTexture12(C.Target), False, False, False);
      TFastDlssView.Motion: DlssBlit(S, DlssTexture(S.Motion), TTexture12(C.Target), False, False, False, 0.1);
    else
      DlssBlit(S, Output, TTexture12(C.Target), False, False, S.Hdr);
    end;
  end
  else
    // A runtime failure keeps the demo visible; the UI shows the NGX error and does not report DLSS as active.
    DlssBlit(S, DlssTexture(S.Color), TTexture12(C.Target), False, False, False);
  DlssInvalidateReplay;
end;

procedure TFastContext3D12.EnsureDlss;
begin
  if FDlssState = nil then
    FDlssState := TDlssState.Create;
  TDlssState(FDlssState as TObject).EnsureSession;
end;

function TFastContext3D12.GetDlssAvailable: Boolean;
begin
  if (Texture <> nil) or not DepthStencil then
    Exit(False);
  EnsureDlss;
  Result := TDlssState(FDlssState as TObject).Feature <> nil;
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
  TFastDlss.Lock;
  try
    if S.Feature <> nil then
      Result := S.Feature.Frames;
  finally
    TFastDlss.Unlock;
  end;
end;

procedure TFastContext3D12.FinishDlssScene;
var S: TDlssState; C: PCmdDlssFinish; Target: TTexture12; Now: UInt64;
begin
  if not FDlssPhase then Exit;
  S := TDlssState(FDlssState as TObject);
  if (FScene <> 0) and (FRayObjects > 0) and (FRay.Shadows or FRay.AmbientOcclusion or FRay.Reflections) then RecordRay;
  FScene := 0;
  FDlssPhase := False;
  Target := TTexture12(DrawTarget);
  C := Rec(HandleDlssFinish, SizeOf(TCmdDlssFinish), FDlssState);
  C.State := S; C.Target := Target; C.Jitter := S.Jitter; C.Reset := S.Frame = 1; C.View := FastDlssView;
  if FastDlssJitterTest in [TFastDlssJitterTest.NegateX, TFastDlssJitterTest.NegateXY] then
    C.Jitter.X := -C.Jitter.X;
  if FastDlssJitterTest in [TFastDlssJitterTest.NegateY, TFastDlssJitterTest.NegateXY] then
    C.Jitter.Y := -C.Jitter.Y;
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
