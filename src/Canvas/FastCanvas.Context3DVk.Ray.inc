{ Ray-traced effects of FastCanvas.Context3DVk (included in its implementation), ported from
  FastCanvas.Context3D12.Ray.inc. Render thread, device lock held, unless a routine says otherwise.

  The opaque objects of a scene with ray-traced effects (a TCmdRayObject before their draw) go into a top-level
  acceleration structure as instances of bottom-level structures, one per geometry: a geometry is built once from the
  vertices and indices its first draw uploaded (their device addresses in the upload memory) and kept while scenes
  use it. At the end of the scene (TCmdRay) the top-level structure is built and full-screen passes (FastRay.hlsl as
  SPIR-V with ray queries, FastCanvas.VkRayShaders.inc) trace rays from the pixels' surfaces:
  - shadows and ambient occlusion darken the color already in the target: hard shadows in one pass; soft shadows and
    ambient occlusion at half resolution into a factor texture, then smoothed and upsampled into the target;
  - reflections blend into it what the surfaces of light materials mirror; for them every geometry keeps a copy of its
    vertices and indices on the GPU (an array of storage buffers in the shaders) and every instance a record of its
    material, and the textures of the materials form an array of images.
  Descriptor sets of a pass come from a descriptor pool of their own, retired with the pass. Not on Vulkan: the
  application passes of TFastContext3D12 (RayScene, RayDispatch, RayDraw). }

{$I FastCanvas.VkRayShaders.inc}

const
  /// <summary>Scenes after which a geometry no scene used is released.</summary>
  BlasKeepPasses = 300;
  NoGeometry = $FFFFFFFF;
  /// <summary>Geometries and textures a pass with reflections binds at most (array sizes of the set layouts).
  /// </summary>
  RayMaxArray = 1024;

type
  /// <summary>Bottom-level acceleration structure of one geometry, and (reflections) a copy of its vertices and
  /// indices the shaders read: the vertices, then the indices from IndexOffset.</summary>
  TBlasVk = class
  public
    Accel: TVkAccelerationStructureKHR;
    Buffer: TVkBuffer;
    Memory: TFastVkAllocation;
    Address: UInt64;
    LastUse: Integer;
    Data: TVkBuffer;
    DataMemory: TFastVkAllocation;
    DataSize: UInt64;
    Stride, PositionOffset, NormalOffset, TexCoordOffset, IndexOffset: Integer;
    Index16: Boolean;
    /// <summary>The ray pass that numbered it (Slot: its place in the pass's geometry array).</summary>
    Stamp, Slot: Integer;
    destructor Destroy; override;
    procedure Drop(const AContext: TGpuVkContext);
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

  TRayStateVk = class
  public
    Blas: TObjectDictionary<UInt64, TBlasVk>;
    Stale: TList<UInt64>;
    Tlas: TVkAccelerationStructureKHR;
    TlasBuffer: TVkBuffer;
    TlasMemory: TFastVkAllocation;
    TlasSize: UInt64;
    Scratch: TVkBuffer;
    ScratchMemory: TFastVkAllocation;
    ScratchSize: UInt64;
    /// <summary>The scene and the number of its instances the top-level structure holds.</summary>
    TlasScene, TlasCount: Integer;
    /// <summary>Scenes with ray tracing so far (a geometry's LastUse is one of them).</summary>
    Pass: Integer;
    Sampler: TVkSampler;
    SetLayouts: array[0..2] of TVkDescriptorSetLayout;
    Layout: TVkPipelineLayout;
    /// <summary>VS, then PSRay, PSHalf, PSBlur, PSReflect, each without and with multisampled depth.</summary>
    Modules: array[0..8] of TVkShaderModule;
    Pipes: TDictionary<UInt64, TVkPipeline>;
    /// <summary>The factor of soft shadows and ambient occlusion before it is smoothed (R8, half the target's size).
    /// </summary>
    Factor: IInterface;
    // A ray pass with reflections: the geometries and textures its instances use, numbered.
    Geometries: TList<TBlasVk>;
    Textures: TList<TTextureVk>;
    TextureSlots: TDictionary<Pointer, Integer>;
    Records: TArray<TRayInstanceData>;
    constructor Create;
    destructor Destroy; override;
    /// <summary>Destroys the Vulkan objects now (the GPU is idle).</summary>
    procedure Drop(const AContext: TGpuVkContext);
    function Module(const AIndex: Integer): TVkShaderModule;
    /// <summary>AKind: 0 hard shadows straight into the target (multiplied), 1 soft shadows and ambient occlusion
    /// into the factor texture, 2 the factor smoothed (and hard shadows) into the target (multiplied), 3 reflections
    /// blended into the target. AMultisample: the depth buffer has samples.</summary>
    function Pipe(const AKind: Integer; const AFormat: TVkFormat; const ASamples: Integer;
      const AMultisample: Boolean): TVkPipeline;
  end;

function RaySupported: Boolean;
var
  V: TFastVulkan;
begin
  TFastDevice.Ensure;
  V := TFastDevice.Vulkan;
  Result := (V <> nil) and V.RayQuery;
end;

/// <summary>A device-local buffer of AUsage with a device address (acceleration structures, their scratch memory,
/// geometry copies).</summary>
function NewRayBuffer(const C: TGpuVkContext; const ASize: UInt64; const AUsage: TVkBufferUsageFlags;
  out AMemory: TFastVkAllocation): TVkBuffer;
begin
  Result := C.NewBuffer(ASize, AUsage or Ord(VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT),
    Ord(VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT), 0, AMemory);
end;

{ TBlasVk }

destructor TBlasVk.Destroy;
var
  C: TGpuVkContext;
begin
  C := GpuVkCurrent;
  if C <> nil then
  begin
    // Command buffers not executed yet may use them.
    C.Retire(TGpuVkObject.AccelerationStructure, Accel);
    C.Retire(TGpuVkObject.Buffer, Buffer);
    C.Retire(TGpuVkObject.Memory, MemoryHandle(Memory));
    C.Retire(TGpuVkObject.Buffer, Data);
    C.Retire(TGpuVkObject.Memory, MemoryHandle(DataMemory));
  end;
  inherited;
end;

procedure TBlasVk.Drop(const AContext: TGpuVkContext);
begin
  AContext.DestroyObject(TGpuVkObject.AccelerationStructure, Accel);
  AContext.DestroyObject(TGpuVkObject.Buffer, Buffer);
  AContext.DestroyObject(TGpuVkObject.Memory, MemoryHandle(Memory));
  AContext.DestroyObject(TGpuVkObject.Buffer, Data);
  AContext.DestroyObject(TGpuVkObject.Memory, MemoryHandle(DataMemory));
  Accel := VK_NULL_HANDLE;
  Buffer := VK_NULL_HANDLE;
  Memory := nil;
  Data := VK_NULL_HANDLE;
  DataMemory := nil;
end;

{ TRayStateVk }

constructor TRayStateVk.Create;
var
  C: TGpuVkContext;
  SamplerInfo: TVkSamplerCreateInfo;
  Bindings: array[0..5] of TVkDescriptorSetLayoutBinding;
  ArrayBinding: TVkDescriptorSetLayoutBinding;
  ArrayFlags: TVkDescriptorBindingFlags;
  FlagsInfo: TVkDescriptorSetLayoutBindingFlagsCreateInfo;
  SetInfo: TVkDescriptorSetLayoutCreateInfo;
  LayoutInfo: TVkPipelineLayoutCreateInfo;
  I: Integer;

  procedure Bind(const AIndex, ABinding: Integer; const AType: TVkDescriptorType; const ASampler: PVkSampler = nil);
  begin
    Bindings[AIndex].binding := ABinding;
    Bindings[AIndex].descriptorType := AType;
    Bindings[AIndex].descriptorCount := 1;
    Bindings[AIndex].stageFlags := Ord(VK_SHADER_STAGE_FRAGMENT_BIT);
    Bindings[AIndex].pImmutableSamplers := ASampler;
  end;

begin
  inherited Create;
  C := GpuVk;
  Blas := TObjectDictionary<UInt64, TBlasVk>.Create([doOwnsValues]);
  Stale := TList<UInt64>.Create;
  TlasScene := -1;
  Pipes := TDictionary<UInt64, TVkPipeline>.Create;
  Geometries := TList<TBlasVk>.Create;
  Textures := TList<TTextureVk>.Create;
  TextureSlots := TDictionary<Pointer, Integer>.Create;
  // s0: linear, repeating (the textures of reflected surfaces).
  FillChar(SamplerInfo, SizeOf(SamplerInfo), 0);
  SamplerInfo.sType := VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
  SamplerInfo.magFilter := VK_FILTER_LINEAR;
  SamplerInfo.minFilter := VK_FILTER_LINEAR;
  SamplerInfo.mipmapMode := VK_SAMPLER_MIPMAP_MODE_LINEAR;
  SamplerInfo.addressModeU := VK_SAMPLER_ADDRESS_MODE_REPEAT;
  SamplerInfo.addressModeV := VK_SAMPLER_ADDRESS_MODE_REPEAT;
  SamplerInfo.addressModeW := VK_SAMPLER_ADDRESS_MODE_REPEAT;
  SamplerInfo.maxAnisotropy := 1;
  SamplerInfo.compareOp := VK_COMPARE_OP_NEVER;
  SamplerInfo.maxLod := VK_LOD_CLAMP_NONE;
  Check(C.Vk.CreateSampler(C.Device, @SamplerInfo, nil, @Sampler), 'vkCreateSampler (ray)');
  // Set 0: b0 the constants, t0 the scene, t1 the depth buffer, t2 the factor texture, t3 the instance records, s0.
  FillChar(Bindings, SizeOf(Bindings), 0);
  Bind(0, 0, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER);
  Bind(1, 16, VK_DESCRIPTOR_TYPE_ACCELERATION_STRUCTURE_KHR);
  Bind(2, 17, VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE);
  Bind(3, 18, VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE);
  Bind(4, 19, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER);
  Bind(5, 32, VK_DESCRIPTOR_TYPE_SAMPLER, @Sampler);
  FillChar(SetInfo, SizeOf(SetInfo), 0);
  SetInfo.sType := VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
  SetInfo.bindingCount := Length(Bindings);
  SetInfo.pBindings := @Bindings[0];
  Check(C.Vk.CreateDescriptorSetLayout(C.Device, @SetInfo, nil, @SetLayouts[0]), 'vkCreateDescriptorSetLayout (ray)');
  // Sets 1 and 2: the geometries (storage buffers) and textures of a pass with reflections, as many as it has.
  for I := 1 to 2 do
  begin
    FillChar(ArrayBinding, SizeOf(ArrayBinding), 0);
    ArrayBinding.binding := 16;
    if I = 1 then
      ArrayBinding.descriptorType := VK_DESCRIPTOR_TYPE_STORAGE_BUFFER
    else
      ArrayBinding.descriptorType := VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE;
    ArrayBinding.descriptorCount := RayMaxArray;
    ArrayBinding.stageFlags := Ord(VK_SHADER_STAGE_FRAGMENT_BIT);
    ArrayFlags := Ord(VK_DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT) or
      Ord(VK_DESCRIPTOR_BINDING_VARIABLE_DESCRIPTOR_COUNT_BIT);
    FillChar(FlagsInfo, SizeOf(FlagsInfo), 0);
    FlagsInfo.sType := VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO;
    FlagsInfo.bindingCount := 1;
    FlagsInfo.pBindingFlags := @ArrayFlags;
    FillChar(SetInfo, SizeOf(SetInfo), 0);
    SetInfo.sType := VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
    SetInfo.pNext := @FlagsInfo;
    SetInfo.bindingCount := 1;
    SetInfo.pBindings := @ArrayBinding;
    Check(C.Vk.CreateDescriptorSetLayout(C.Device, @SetInfo, nil, @SetLayouts[I]),
      'vkCreateDescriptorSetLayout (ray arrays)');
  end;
  FillChar(LayoutInfo, SizeOf(LayoutInfo), 0);
  LayoutInfo.sType := VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
  LayoutInfo.setLayoutCount := Length(SetLayouts);
  LayoutInfo.pSetLayouts := @SetLayouts[0];
  Check(C.Vk.CreatePipelineLayout(C.Device, @LayoutInfo, nil, @Layout), 'vkCreatePipelineLayout (ray)');
end;

destructor TRayStateVk.Destroy;
var
  C: TGpuVkContext;
  P: TVkPipeline;
  I: Integer;
begin
  Blas.Free;
  Stale.Free;
  Geometries.Free;
  Textures.Free;
  TextureSlots.Free;
  // Command buffers not executed yet may use them.
  C := GpuVkCurrent;
  if C <> nil then
  begin
    C.Retire(TGpuVkObject.AccelerationStructure, Tlas);
    C.Retire(TGpuVkObject.Buffer, TlasBuffer);
    C.Retire(TGpuVkObject.Memory, MemoryHandle(TlasMemory));
    C.Retire(TGpuVkObject.Buffer, Scratch);
    C.Retire(TGpuVkObject.Memory, MemoryHandle(ScratchMemory));
    for P in Pipes.Values do
      C.Retire(TGpuVkObject.Pipeline, P);
    C.Retire(TGpuVkObject.PipelineLayout, Layout);
    for I := 0 to High(SetLayouts) do
      C.Retire(TGpuVkObject.SetLayout, SetLayouts[I]);
    for I := 0 to High(Modules) do
      C.Retire(TGpuVkObject.ShaderModule, Modules[I]);
    C.Retire(TGpuVkObject.Sampler, Sampler);
  end;
  Pipes.Free;
  inherited;
end;

procedure TRayStateVk.Drop(const AContext: TGpuVkContext);
var
  B: TBlasVk;
  P: TVkPipeline;
  I: Integer;
begin
  for B in Blas.Values do
    B.Drop(AContext);
  AContext.DestroyObject(TGpuVkObject.AccelerationStructure, Tlas);
  AContext.DestroyObject(TGpuVkObject.Buffer, TlasBuffer);
  AContext.DestroyObject(TGpuVkObject.Memory, MemoryHandle(TlasMemory));
  AContext.DestroyObject(TGpuVkObject.Buffer, Scratch);
  AContext.DestroyObject(TGpuVkObject.Memory, MemoryHandle(ScratchMemory));
  for P in Pipes.Values do
    AContext.DestroyObject(TGpuVkObject.Pipeline, P);
  Pipes.Clear;
  AContext.DestroyObject(TGpuVkObject.PipelineLayout, Layout);
  for I := 0 to High(SetLayouts) do
    AContext.DestroyObject(TGpuVkObject.SetLayout, SetLayouts[I]);
  for I := 0 to High(Modules) do
    AContext.DestroyObject(TGpuVkObject.ShaderModule, Modules[I]);
  AContext.DestroyObject(TGpuVkObject.Sampler, Sampler);
  Tlas := VK_NULL_HANDLE;
  TlasBuffer := VK_NULL_HANDLE;
  TlasMemory := nil;
  Scratch := VK_NULL_HANDLE;
  ScratchMemory := nil;
  Layout := VK_NULL_HANDLE;
  FillChar(SetLayouts, SizeOf(SetLayouts), 0);
  FillChar(Modules, SizeOf(Modules), 0);
  Sampler := VK_NULL_HANDLE;
end;

function TRayStateVk.Module(const AIndex: Integer): TVkShaderModule;
var
  C: TGpuVkContext;
  Info: TVkShaderModuleCreateInfo;
begin
  if Modules[AIndex] = VK_NULL_HANDLE then
  begin
    C := GpuVk;
    FillChar(Info, SizeOf(Info), 0);
    Info.sType := VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
    case AIndex of
      0:
        begin
          Info.codeSize := SizeOf(FastRayVkVS);
          Info.pCode := @FastRayVkVS[0];
        end;
      1:
        begin
          Info.codeSize := SizeOf(FastRayVkPS);
          Info.pCode := @FastRayVkPS[0];
        end;
      2:
        begin
          Info.codeSize := SizeOf(FastRayVkPSMS);
          Info.pCode := @FastRayVkPSMS[0];
        end;
      3:
        begin
          Info.codeSize := SizeOf(FastHalfVkPS);
          Info.pCode := @FastHalfVkPS[0];
        end;
      4:
        begin
          Info.codeSize := SizeOf(FastHalfVkPSMS);
          Info.pCode := @FastHalfVkPSMS[0];
        end;
      5:
        begin
          Info.codeSize := SizeOf(FastBlurVkPS);
          Info.pCode := @FastBlurVkPS[0];
        end;
      6:
        begin
          Info.codeSize := SizeOf(FastBlurVkPSMS);
          Info.pCode := @FastBlurVkPSMS[0];
        end;
      7:
        begin
          Info.codeSize := SizeOf(FastReflectVkPS);
          Info.pCode := @FastReflectVkPS[0];
        end;
    else
      Info.codeSize := SizeOf(FastReflectVkPSMS);
      Info.pCode := @FastReflectVkPSMS[0];
    end;
    Check(C.Vk.CreateShaderModule(C.Device, @Info, nil, @Modules[AIndex]), 'vkCreateShaderModule (ray)');
  end;
  Result := Modules[AIndex];
end;

function TRayStateVk.Pipe(const AKind: Integer; const AFormat: TVkFormat; const ASamples: Integer;
  const AMultisample: Boolean): TVkPipeline;
const
  // The pixel shader of a kind (Modules) and its entry point.
  Shaders: array[0..3] of Integer = (1, 3, 5, 7);
  Entries: array[0..3] of PAnsiChar = ('PSRay', 'PSHalf', 'PSBlur', 'PSReflect');
var
  C: TGpuVkContext;
  Key: UInt64;
  Stages: array[0..1] of TVkPipelineShaderStageCreateInfo;
  VertexInput: TVkPipelineVertexInputStateCreateInfo;
  Assembly: TVkPipelineInputAssemblyStateCreateInfo;
  ViewportState: TVkPipelineViewportStateCreateInfo;
  Raster: TVkPipelineRasterizationStateCreateInfo;
  Multisample: TVkPipelineMultisampleStateCreateInfo;
  DepthStencil: TVkPipelineDepthStencilStateCreateInfo;
  Attachment: TVkPipelineColorBlendAttachmentState;
  Blend: TVkPipelineColorBlendStateCreateInfo;
  DynamicStates: array[0..1] of TVkDynamicState;
  Dynamic: TVkPipelineDynamicStateCreateInfo;
  ColorFormat: TVkFormat;
  Rendering: TVkPipelineRenderingCreateInfo;
  Info: TVkGraphicsPipelineCreateInfo;
begin
  Key := UInt64(Ord(AFormat)) or (UInt64(ASamples) shl 32) or (UInt64(AKind) shl 40) or
    (UInt64(Ord(AMultisample)) shl 48);
  if Pipes.TryGetValue(Key, Result) then
    Exit;
  C := GpuVk;
  FillChar(Stages, SizeOf(Stages), 0);
  Stages[0].sType := VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
  Stages[0].stage := VK_SHADER_STAGE_VERTEX_BIT;
  Stages[0].module := Module(0);
  Stages[0].pName := 'VSMain';
  Stages[1].sType := VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
  Stages[1].stage := VK_SHADER_STAGE_FRAGMENT_BIT;
  Stages[1].module := Module(Shaders[AKind] + Ord(AMultisample));
  Stages[1].pName := Entries[AKind];
  FillChar(VertexInput, SizeOf(VertexInput), 0);
  VertexInput.sType := VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
  FillChar(Assembly, SizeOf(Assembly), 0);
  Assembly.sType := VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
  Assembly.topology := VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
  FillChar(ViewportState, SizeOf(ViewportState), 0);
  ViewportState.sType := VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
  ViewportState.viewportCount := 1;
  ViewportState.scissorCount := 1;
  FillChar(Raster, SizeOf(Raster), 0);
  Raster.sType := VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
  Raster.polygonMode := VK_POLYGON_MODE_FILL;
  Raster.cullMode := Ord(VK_CULL_MODE_NONE);
  Raster.frontFace := VK_FRONT_FACE_CLOCKWISE;
  Raster.lineWidth := 1;
  FillChar(Multisample, SizeOf(Multisample), 0);
  Multisample.sType := VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
  Multisample.rasterizationSamples := TVkSampleCountFlagBits(Max(ASamples, 1));
  FillChar(DepthStencil, SizeOf(DepthStencil), 0);
  DepthStencil.sType := VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO;
  // Shadows and occlusion: the color in the target times the factor of the pass. Reflections: the target times
  // (1 - share) plus the reflected color times the share (premultiplied by the pass). Alpha kept; the factor texture
  // is written as it is.
  FillChar(Attachment, SizeOf(Attachment), 0);
  Attachment.blendEnable := Ord(AKind <> 1);
  if AKind = 3 then
  begin
    Attachment.srcColorBlendFactor := VK_BLEND_FACTOR_ONE;
    Attachment.dstColorBlendFactor := VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
  end
  else
  begin
    Attachment.srcColorBlendFactor := VK_BLEND_FACTOR_ZERO;
    Attachment.dstColorBlendFactor := VK_BLEND_FACTOR_SRC_COLOR;
  end;
  Attachment.colorBlendOp := VK_BLEND_OP_ADD;
  Attachment.srcAlphaBlendFactor := VK_BLEND_FACTOR_ZERO;
  Attachment.dstAlphaBlendFactor := VK_BLEND_FACTOR_ONE;
  Attachment.alphaBlendOp := VK_BLEND_OP_ADD;
  Attachment.colorWriteMask := Ord(VK_COLOR_COMPONENT_R_BIT) or Ord(VK_COLOR_COMPONENT_G_BIT) or
    Ord(VK_COLOR_COMPONENT_B_BIT) or Ord(VK_COLOR_COMPONENT_A_BIT);
  FillChar(Blend, SizeOf(Blend), 0);
  Blend.sType := VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
  Blend.attachmentCount := 1;
  Blend.pAttachments := @Attachment;
  DynamicStates[0] := VK_DYNAMIC_STATE_VIEWPORT;
  DynamicStates[1] := VK_DYNAMIC_STATE_SCISSOR;
  FillChar(Dynamic, SizeOf(Dynamic), 0);
  Dynamic.sType := VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
  Dynamic.dynamicStateCount := Length(DynamicStates);
  Dynamic.pDynamicStates := @DynamicStates[0];
  ColorFormat := AFormat;
  if AKind = 1 then
    ColorFormat := VK_FORMAT_R8_UNORM;
  FillChar(Rendering, SizeOf(Rendering), 0);
  Rendering.sType := VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO;
  Rendering.colorAttachmentCount := 1;
  Rendering.pColorAttachmentFormats := @ColorFormat;
  FillChar(Info, SizeOf(Info), 0);
  Info.sType := VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
  Info.pNext := @Rendering;
  Info.stageCount := Length(Stages);
  Info.pStages := @Stages[0];
  Info.pVertexInputState := @VertexInput;
  Info.pInputAssemblyState := @Assembly;
  Info.pViewportState := @ViewportState;
  Info.pRasterizationState := @Raster;
  Info.pMultisampleState := @Multisample;
  Info.pDepthStencilState := @DepthStencil;
  Info.pColorBlendState := @Blend;
  Info.pDynamicState := @Dynamic;
  Info.layout := Layout;
  Info.basePipelineIndex := -1;
  Result := VK_NULL_HANDLE;
  Check(C.Fast.Track(C.Vk.CreateGraphicsPipelines(C.Device, VK_NULL_HANDLE, 1, @Info, nil, @Result)),
    'vkCreateGraphicsPipelines (ray)');
  Pipes.Add(Key, Result);
end;

/// <summary>The ray-tracing state of the render thread, nil without ray queries.</summary>
function RayState: TRayStateVk;
begin
  if (R.Ray = nil) and RaySupported then
    R.Ray := TRayStateVk.Create;
  Result := TRayStateVk(R.Ray);
end;

/// <summary>Device lock held: everything of the render thread's ray tracing goes once the GPU is done with it.
/// </summary>
procedure RayClear;
var
  I: Integer;
begin
  FreeAndNil(R.Ray);
  R.InstanceCount := 0;
  R.RayScene := 0;
  R.RayObjectPending := False;
  R.RayObjectTexture := nil;
  for I := 0 to High(R.Materials) do
    R.Materials[I].Texture := nil;
end;

/// <summary>The recording context shuts down (the GPU is idle): everything of the ray tracing goes now.</summary>
procedure RayDrop(const AContext: TGpuVkContext);
begin
  if R.Ray <> nil then
    TRayStateVk(R.Ray).Drop(AContext);
  RayClear;
end;

/// <summary>The scene AScene begins on the render thread (its first object): the instances of the previous scene go,
/// and geometries no scene used for a while are released.</summary>
procedure RayBeginScene(const S: TRayStateVk; const AScene: Integer);
var
  Pair: TPair<UInt64, TBlasVk>;
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
  // Released through Retire: command buffers not executed yet may use them.
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

/// <summary>The object whose draw follows (TCmdRayObject).</summary>
procedure HandleRayObject(const AData: Pointer);
var
  O: PCmdRayObject;
begin
  O := AData;
  R.RayObject := O^;
  if O.Texture <> nil then
    R.RayObjectTexture := TTextureVk(O.Texture)
  else
    R.RayObjectTexture := nil;
  R.RayObjectPending := True;
end;

/// <summary>Reflections: a copy of the geometry the draw just uploaded, which the shaders read, and its layout.
/// </summary>
procedure CopyGeometry(const C: TGpuVkContext; const B: TBlasVk; const ADraw: PCmdDraw;
  const AVertices: TVkBuffer; const AVertexOffset: UInt64; const AIndices: TVkBuffer; const AIndexOffset: UInt64);
var
  Regions: array[0..1] of TVkBufferCopy;
begin
  B.IndexOffset := AlignUp(ADraw.VertexBytes, 16);
  B.DataSize := UInt64(B.IndexOffset) + UInt64(AlignUp(ADraw.IndexBytes, 4));
  B.Data := C.NewBuffer(B.DataSize, Ord(VK_BUFFER_USAGE_STORAGE_BUFFER_BIT) or Ord(VK_BUFFER_USAGE_TRANSFER_DST_BIT),
    Ord(VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT), 0, B.DataMemory);
  Regions[0].srcOffset := AVertexOffset;
  Regions[0].dstOffset := 0;
  Regions[0].size := ADraw.VertexBytes;
  Regions[1].srcOffset := AIndexOffset;
  Regions[1].dstOffset := B.IndexOffset;
  Regions[1].size := ADraw.IndexBytes;
  C.Vk.CmdCopyBuffer(C.TransferCmd, AVertices, B.Data, 1, @Regions[0]);
  C.Vk.CmdCopyBuffer(C.TransferCmd, AIndices, B.Data, 1, @Regions[1]);
  // Read by the passes of the scene, later in this command buffer or in later ones.
  C.MemoryBarrier(StageTransfer, AccessTransferWrite, StageFragmentShader, AccessShaderRead);
  B.Stride := ADraw.VertexStride;
  B.PositionOffset := R.RayObject.PositionOffset;
  B.NormalOffset := R.RayObject.NormalOffset;
  B.TexCoordOffset := R.RayObject.TexCoordOffset;
  B.Index16 := not ADraw.Index32;
end;

/// <summary>Builds B from the geometry of the draw (vertices and indices in upload memory, alive until the command
/// buffer has run). False when there is nothing to build.</summary>
function BuildBlas(const C: TGpuVkContext; const B: TBlasVk; const ADraw: PCmdDraw; const AVertexAddress,
  AIndexAddress: UInt64): Boolean;
var
  Geometry: TVkAccelerationStructureGeometryKHR;
  Build: TVkAccelerationStructureBuildGeometryInfoKHR;
  Sizes: TVkAccelerationStructureBuildSizesInfoKHR;
  Range: TVkAccelerationStructureBuildRangeInfoKHR;
  PRange: PVkAccelerationStructureBuildRangeInfoKHR;
  Create: TVkAccelerationStructureCreateInfoKHR;
  AddressInfo: TVkAccelerationStructureDeviceAddressInfoKHR;
  Primitives: Cardinal;
  Scratch: TVkBuffer;
  ScratchMemory: TFastVkAllocation;
  Align: UInt64;
begin
  Result := False;
  Primitives := ADraw.IndexCount div 3;
  if Primitives = 0 then
    Exit;
  FillChar(Geometry, SizeOf(Geometry), 0);
  Geometry.sType := VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_GEOMETRY_KHR;
  Geometry.geometryType := VK_GEOMETRY_TYPE_TRIANGLES_KHR;
  Geometry.flags := Ord(VK_GEOMETRY_OPAQUE_BIT_KHR);
  Geometry.geometry.triangles.sType := VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_GEOMETRY_TRIANGLES_DATA_KHR;
  Geometry.geometry.triangles.vertexFormat := VK_FORMAT_R32G32B32_SFLOAT;
  Geometry.geometry.triangles.vertexData.deviceAddress := AVertexAddress + UInt64(R.RayObject.PositionOffset);
  Geometry.geometry.triangles.vertexStride := ADraw.VertexStride;
  Geometry.geometry.triangles.maxVertex := Max(ADraw.VertexBytes div Max(ADraw.VertexStride, 1) - 1, 0);
  if ADraw.Index32 then
    Geometry.geometry.triangles.indexType := VK_INDEX_TYPE_UINT32
  else
    Geometry.geometry.triangles.indexType := VK_INDEX_TYPE_UINT16;
  Geometry.geometry.triangles.indexData.deviceAddress := AIndexAddress;
  FillChar(Build, SizeOf(Build), 0);
  Build.sType := VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_BUILD_GEOMETRY_INFO_KHR;
  Build.type_ := VK_ACCELERATION_STRUCTURE_TYPE_BOTTOM_LEVEL_KHR;
  Build.flags := Ord(VK_BUILD_ACCELERATION_STRUCTURE_PREFER_FAST_TRACE_BIT_KHR);
  Build.mode := VK_BUILD_ACCELERATION_STRUCTURE_MODE_BUILD_KHR;
  Build.geometryCount := 1;
  Build.pGeometries := @Geometry;
  FillChar(Sizes, SizeOf(Sizes), 0);
  Sizes.sType := VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_BUILD_SIZES_INFO_KHR;
  C.Vk.GetAccelerationStructureBuildSizesKHR(C.Device, VK_ACCELERATION_STRUCTURE_BUILD_TYPE_DEVICE_KHR, @Build,
    @Primitives, @Sizes);
  if Sizes.accelerationStructureSize = 0 then
    Exit;
  B.Buffer := NewRayBuffer(C, Sizes.accelerationStructureSize,
    Ord(VK_BUFFER_USAGE_ACCELERATION_STRUCTURE_STORAGE_BIT_KHR), B.Memory);
  FillChar(Create, SizeOf(Create), 0);
  Create.sType := VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_CREATE_INFO_KHR;
  Create.buffer := B.Buffer;
  Create.size := Sizes.accelerationStructureSize;
  Create.type_ := VK_ACCELERATION_STRUCTURE_TYPE_BOTTOM_LEVEL_KHR;
  Check(C.Fast.Track(C.Vk.CreateAccelerationStructureKHR(C.Device, @Create, nil, @B.Accel)),
    'vkCreateAccelerationStructureKHR');
  FillChar(AddressInfo, SizeOf(AddressInfo), 0);
  AddressInfo.sType := VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_DEVICE_ADDRESS_INFO_KHR;
  AddressInfo.accelerationStructure := B.Accel;
  B.Address := C.Vk.GetAccelerationStructureDeviceAddressKHR(C.Device, @AddressInfo);
  // Scratch memory of this build only.
  Align := C.Fast.ScratchAlignment;
  Scratch := NewRayBuffer(C, Sizes.buildScratchSize + Align, Ord(VK_BUFFER_USAGE_STORAGE_BUFFER_BIT), ScratchMemory);
  C.Retire(TGpuVkObject.Buffer, Scratch);
  C.Retire(TGpuVkObject.Memory, MemoryHandle(ScratchMemory));
  Build.dstAccelerationStructure := B.Accel;
  Build.scratchData.deviceAddress := (C.BufferAddress(Scratch) + Align - 1) div Align * Align;
  FillChar(Range, SizeOf(Range), 0);
  Range.primitiveCount := Primitives;
  PRange := @Range;
  C.Vk.CmdBuildAccelerationStructuresKHR(C.TransferCmd, 1, @Build, @PRange);
  Result := True;
end;

/// <summary>An object of the scene (R.RayObject), just drawn from the upload memory of AVertexBuffer and
/// AIndexBuffer: its geometry's structure (built on first use) as an instance with the object's transform; with
/// reflections, its geometry's copy and its material.</summary>
procedure RayAfterDraw(const AContext: TGpuVkContext; const ADraw: PCmdDraw; const AVertexBuffer: TVkBuffer;
  const AVertexOffset: UInt64; const AIndexBuffer: TVkBuffer; const AIndexOffset: UInt64);
var
  S: TRayStateVk;
  B: TBlasVk;
  O: PCmdRayObject;
  P: ^TVkAccelerationStructureInstanceKHR;
  M: ^TRayMaterial;
begin
  if not R.RayObjectPending then
    Exit;
  R.RayObjectPending := False;
  try
    S := RayState;
    O := @R.RayObject;
    if (S = nil) or (ADraw.IndexCount < 3) then
      Exit;
    RayBeginScene(S, O.Scene);
    if not S.Blas.TryGetValue(O.Geometry, B) then
    begin
      B := TBlasVk.Create;
      B.Stamp := -1;
      if not BuildBlas(AContext, B, ADraw, AContext.BufferAddress(AVertexBuffer) + AVertexOffset,
        AContext.BufferAddress(AIndexBuffer) + AIndexOffset) then
      begin
        B.Free;
        Exit;
      end;
      S.Blas.Add(O.Geometry, B);
    end;
    B.LastUse := S.Pass;
    if (O.Kind <> 255) and (B.Data = VK_NULL_HANDLE) then
      CopyGeometry(AContext, B, ADraw, AVertexBuffer, AVertexOffset, AIndexBuffer, AIndexOffset);
    if R.InstanceCount = Length(R.Instances) then
    begin
      SetLength(R.Instances, Max(64, 2 * R.InstanceCount));
      SetLength(R.Materials, Length(R.Instances));
    end;
    P := @R.Instances[R.InstanceCount];
    Move(O.Transform, P.transform, SizeOf(P.transform));
    // Instance custom index: the index of the instance (its material record); mask $FF; opaque. Facing does not
    // matter: the passes cull nothing.
    P.instanceCustomIndexMask := Cardinal(R.InstanceCount and $FFFFFF) or (Cardinal($FF) shl 24);
    P.instanceShaderBindingTableRecordOffsetFlags := Cardinal(Ord(VK_GEOMETRY_INSTANCE_FORCE_OPAQUE_BIT_KHR)) shl 24;
    P.accelerationStructureReference := B.Address;
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
  finally
    R.RayObjectTexture := nil;
  end;
end;

/// <summary>Reflections: numbers the geometries and textures of the scene's instances and fills their records.
/// False when a pass cannot take them all.</summary>
function PrepareReflections(const S: TRayStateVk): Boolean;
var
  I, Slot: Integer;
  M: ^TRayMaterial;
  B: TBlasVk;
  D: ^TRayInstanceData;
  T: TTextureVk;
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
    B := TBlasVk(M.Blas);
    if (B <> nil) and (B.Data <> VK_NULL_HANDLE) then
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
      T := TTextureVk(M.Texture as TObject);
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
  Result := (S.Geometries.Count <= RayMaxArray) and (S.Textures.Count <= RayMaxArray);
end;

/// <summary>The top-level structure of the scene in progress (R.RayScene) from its instances: built unless it holds
/// them already.</summary>
procedure RayBuildTlas(const C: TGpuVkContext; const S: TRayStateVk);
var
  P: PByte;
  InstBuffer: TVkBuffer;
  InstOffset: UInt64;
  Bytes: Integer;
  Geometry: TVkAccelerationStructureGeometryKHR;
  Build: TVkAccelerationStructureBuildGeometryInfoKHR;
  Sizes: TVkAccelerationStructureBuildSizesInfoKHR;
  Range: TVkAccelerationStructureBuildRangeInfoKHR;
  PRange: PVkAccelerationStructureBuildRangeInfoKHR;
  Create: TVkAccelerationStructureCreateInfoKHR;
  Count: Cardinal;
  Align: UInt64;
begin
  if (S.Tlas <> VK_NULL_HANDLE) and (S.TlasScene = R.RayScene) and (S.TlasCount = R.InstanceCount) then
    Exit;
  // The instances of the scene.
  Bytes := R.InstanceCount * SizeOf(TVkAccelerationStructureInstanceKHR);
  P := C.Upload(Max(Bytes, SizeOf(TVkAccelerationStructureInstanceKHR)), 16, InstBuffer, InstOffset);
  if Bytes > 0 then
    Move(R.Instances[0], P^, Bytes);
  Count := R.InstanceCount;
  FillChar(Geometry, SizeOf(Geometry), 0);
  Geometry.sType := VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_GEOMETRY_KHR;
  Geometry.geometryType := VK_GEOMETRY_TYPE_INSTANCES_KHR;
  Geometry.geometry.instances.sType := VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_GEOMETRY_INSTANCES_DATA_KHR;
  Geometry.geometry.instances.arrayOfPointers := VK_FALSE;
  Geometry.geometry.instances.data.deviceAddress := C.BufferAddress(InstBuffer) + InstOffset;
  FillChar(Build, SizeOf(Build), 0);
  Build.sType := VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_BUILD_GEOMETRY_INFO_KHR;
  Build.type_ := VK_ACCELERATION_STRUCTURE_TYPE_TOP_LEVEL_KHR;
  Build.flags := Ord(VK_BUILD_ACCELERATION_STRUCTURE_PREFER_FAST_TRACE_BIT_KHR);
  Build.mode := VK_BUILD_ACCELERATION_STRUCTURE_MODE_BUILD_KHR;
  Build.geometryCount := 1;
  Build.pGeometries := @Geometry;
  FillChar(Sizes, SizeOf(Sizes), 0);
  Sizes.sType := VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_BUILD_SIZES_INFO_KHR;
  C.Vk.GetAccelerationStructureBuildSizesKHR(C.Device, VK_ACCELERATION_STRUCTURE_BUILD_TYPE_DEVICE_KHR, @Build,
    @Count, @Sizes);
  if (Sizes.accelerationStructureSize > S.TlasSize) or (S.Tlas = VK_NULL_HANDLE) then
  begin
    C.Retire(TGpuVkObject.AccelerationStructure, S.Tlas);
    C.Retire(TGpuVkObject.Buffer, S.TlasBuffer);
    C.Retire(TGpuVkObject.Memory, MemoryHandle(S.TlasMemory));
    S.Tlas := VK_NULL_HANDLE;
    S.TlasBuffer := VK_NULL_HANDLE;
    S.TlasMemory := nil;
    S.TlasSize := AlignUp(Max(Sizes.accelerationStructureSize, 256) * 2, 64 * 1024);
    S.TlasBuffer := NewRayBuffer(C, S.TlasSize, Ord(VK_BUFFER_USAGE_ACCELERATION_STRUCTURE_STORAGE_BIT_KHR),
      S.TlasMemory);
    FillChar(Create, SizeOf(Create), 0);
    Create.sType := VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_CREATE_INFO_KHR;
    Create.buffer := S.TlasBuffer;
    Create.size := S.TlasSize;
    Create.type_ := VK_ACCELERATION_STRUCTURE_TYPE_TOP_LEVEL_KHR;
    Check(C.Fast.Track(C.Vk.CreateAccelerationStructureKHR(C.Device, @Create, nil, @S.Tlas)),
      'vkCreateAccelerationStructureKHR (top level)');
  end;
  Align := C.Fast.ScratchAlignment;
  if (Sizes.buildScratchSize + Align > S.ScratchSize) or (S.Scratch = VK_NULL_HANDLE) then
  begin
    C.Retire(TGpuVkObject.Buffer, S.Scratch);
    C.Retire(TGpuVkObject.Memory, MemoryHandle(S.ScratchMemory));
    S.Scratch := VK_NULL_HANDLE;
    S.ScratchMemory := nil;
    S.ScratchSize := AlignUp(Max(Sizes.buildScratchSize, 256) * 2 + Align, 64 * 1024);
    S.Scratch := NewRayBuffer(C, S.ScratchSize, Ord(VK_BUFFER_USAGE_STORAGE_BUFFER_BIT), S.ScratchMemory);
  end;
  // The bottom levels are built, the passes before have read the top level and its scratch memory is free.
  C.MemoryBarrier(StageAccelerationBuild or StageFragmentShader, AccessAccelerationWrite,
    StageAccelerationBuild, AccessAccelerationRead or AccessAccelerationWrite);
  Build.dstAccelerationStructure := S.Tlas;
  Build.scratchData.deviceAddress := (C.BufferAddress(S.Scratch) + Align - 1) div Align * Align;
  FillChar(Range, SizeOf(Range), 0);
  Range.primitiveCount := Count;
  PRange := @Range;
  C.Vk.CmdBuildAccelerationStructuresKHR(C.TransferCmd, 1, @Build, @PRange);
  // The passes read it.
  C.MemoryBarrier(StageAccelerationBuild, AccessAccelerationWrite, StageFragmentShader, AccessAccelerationRead);
  S.TlasScene := R.RayScene;
  S.TlasCount := R.InstanceCount;
end;

/// <summary>A full-screen pass of kind AKind (TRayStateVk.Pipe) into ATarget.</summary>
procedure RayPass(const C: TGpuVkContext; const S: TRayStateVk; const ATarget: TTextureVk; const AKind,
  ASamples: Integer; const AMultisample: Boolean; const ASets: array of TVkDescriptorSet);
var
  Was: TGpuVkUse;
  Color: TVkRenderingAttachmentInfo;
  Info: TVkRenderingInfo;
  Viewport: TVkViewport;
  Scissor: TVkRect2D;
  Cmd: TVkCommandBuffer;
  Format: TVkFormat;
begin
  Was := ATarget.CurrentUse;
  // The factor texture is written whole; the target keeps its colors (multiplied, blended).
  ATarget.UseAs(TGpuVkUse.ColorTarget, AKind = 1);
  if (Was = TGpuVkUse.ColorTarget) and (AKind <> 1) then
    C.MemoryBarrier(StageColorOutput, AccessColorWrite, StageColorOutput, AccessColorRead or AccessColorWrite);
  FillChar(Color, SizeOf(Color), 0);
  Color.sType := VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO;
  Color.imageView := ATarget.GpuView;
  Color.imageLayout := VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
  Color.resolveMode := VK_RESOLVE_MODE_NONE;
  if AKind = 1 then
    Color.loadOp := VK_ATTACHMENT_LOAD_OP_DONT_CARE
  else
    Color.loadOp := VK_ATTACHMENT_LOAD_OP_LOAD;
  Color.storeOp := VK_ATTACHMENT_STORE_OP_STORE;
  FillChar(Info, SizeOf(Info), 0);
  Info.sType := VK_STRUCTURE_TYPE_RENDERING_INFO;
  Info.renderArea.extent.width := ATarget.Width;
  Info.renderArea.extent.height := ATarget.Height;
  Info.layerCount := 1;
  Info.colorAttachmentCount := 1;
  Info.pColorAttachments := @Color;
  C.BeginRenderingInfo(S, Info);
  Cmd := C.Cmd;
  Format := ATarget.Format;
  C.Vk.CmdBindPipeline(Cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, S.Pipe(AKind, Format, ASamples, AMultisample));
  // Negative height, as the 3D draws: VSMain gives Direct3D's clip space.
  Viewport.x := 0;
  Viewport.y := ATarget.Height;
  Viewport.width := ATarget.Width;
  Viewport.height := -ATarget.Height;
  Viewport.minDepth := 0;
  Viewport.maxDepth := 1;
  C.Vk.CmdSetViewport(Cmd, 0, 1, @Viewport);
  Scissor.offset.x := 0;
  Scissor.offset.y := 0;
  Scissor.extent.width := ATarget.Width;
  Scissor.extent.height := ATarget.Height;
  C.Vk.CmdSetScissor(Cmd, 0, 1, @Scissor);
  C.Vk.CmdBindDescriptorSets(Cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, S.Layout, 0, Length(ASets), @ASets[0], 0, nil);
  C.Vk.CmdDraw(Cmd, 3, 1, 0, 0);
  C.EndRendering;
end;

/// <summary>The scene's top-level structure, then the passes over the target (TCmdRay).</summary>
procedure HandleRay(const AData: Pointer);
var
  Cm: PCmdRay;
  S: TRayStateVk;
  C: TGpuVkContext;
  T, D, F: TTextureVk;
  Shadows, Reflect, MS: Boolean;
  I, ConstBytes, Bytes, NG, NT: Integer;
  P: PByte;
  ConstBuffer, RecordBuffer: TVkBuffer;
  ConstOffset, RecordOffset: UInt64;
  Sizes: array[0..4] of TVkDescriptorPoolSize;
  PoolInfo: TVkDescriptorPoolCreateInfo;
  Pool: TVkDescriptorPool;
  Counts: array[0..2] of Cardinal;
  CountInfo: TVkDescriptorSetVariableDescriptorCountAllocateInfo;
  AllocInfo: TVkDescriptorSetAllocateInfo;
  Sets: array[0..2] of TVkDescriptorSet;
  Writes: array[0..6] of TVkWriteDescriptorSet;
  AccelWrite: TVkWriteDescriptorSetAccelerationStructureKHR;
  Constants, Records: TVkDescriptorBufferInfo;
  DepthImage, FactorImage: TVkDescriptorImageInfo;
  GeometryInfos: TArray<TVkDescriptorBufferInfo>;
  TextureInfos: TArray<TVkDescriptorImageInfo>;
  N: Integer;
begin
  Cm := AData;
  S := RayState;
  if (S = nil) or (R.RayScene <> Cm.Scene) or (R.InstanceCount = 0) then
    Exit;
  C := GpuVk;
  T := Cm.Target;
  D := Cm.Depth;
  if (T.GpuImage = VK_NULL_HANDLE) or (D.Image = VK_NULL_HANDLE) then
    Exit;
  MS := D.Samples > 1;
  Shadows := (((Cm.Flags and RayShadowsOn) <> 0) and (Cm.LightCount > 0)) or (Cm.AOSamples > 0);
  Reflect := ((Cm.Flags and RayReflect) <> 0) and PrepareReflections(S);
  if not (Shadows or Reflect) then
    Exit;
  // A texture that is the target itself (a material showing its own viewport) cannot be read while it is drawn into.
  if Reflect then
    for I := 0 to S.Textures.Count - 1 do
      if S.Textures[I] = T then
        S.Textures[I] := G.Blank;
  // Several rays per pixel: traced at half resolution into a texture, smoothed and upsampled into the target.
  F := nil;
  if Shadows and ((Cm.Softness > 0) or (Cm.AOSamples > 0)) then
  begin
    if S.Factor <> nil then
      F := TTextureVk(S.Factor as TObject);
    if (F = nil) or (F.Width <> (Cm.Width + 1) div 2) or (F.Height <> (Cm.Height + 1) div 2) then
    begin
      F := NewTextureVk((Cm.Width + 1) div 2, (Cm.Height + 1) div 2, 1, 1, VK_FORMAT_R8_UNORM,
        Ord(VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT) or Ord(VK_IMAGE_USAGE_SAMPLED_BIT));
      S.Factor := F;
    end;
  end;
  EnsureBlank;

  RayBuildTlas(C, S);

  // What the passes read: the depth buffer, the factor texture, the textures of reflected surfaces.
  D.UseAs(TGpuVkUse.DepthRead);
  if F <> nil then
    F.UseAs(TGpuVkUse.ShaderRead);
  if Reflect then
    for I := 0 to S.Textures.Count - 1 do
      S.Textures[I].UseAs(TGpuVkUse.ShaderRead);
  G.Blank.UseAs(TGpuVkUse.ShaderRead);
  ConstBytes := SizeOf(TCmdRay) - (PByte(@Cm.InvViewProj) - PByte(Cm));
  P := C.Upload(AlignUp(ConstBytes, 16), C.UniformAlign, ConstBuffer, ConstOffset);
  Move(Cm.InvViewProj, P^, ConstBytes);
  NG := 0;
  NT := 0;
  if Reflect then
  begin
    NG := S.Geometries.Count;
    NT := S.Textures.Count;
    Bytes := R.InstanceCount * SizeOf(TRayInstanceData);
    P := C.Upload(Bytes, 256, RecordBuffer, RecordOffset);
    Move(S.Records[0], P^, Bytes);
  end
  else
  begin
    // The records are not read: any buffer.
    RecordBuffer := ConstBuffer;
    RecordOffset := ConstOffset;
    Bytes := SizeOf(TRayInstanceData);
  end;

  // The descriptor sets of the passes, from a pool of their own that goes with them.
  Sizes[0].type_ := VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
  Sizes[0].descriptorCount := 1;
  Sizes[1].type_ := VK_DESCRIPTOR_TYPE_ACCELERATION_STRUCTURE_KHR;
  Sizes[1].descriptorCount := 1;
  Sizes[2].type_ := VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE;
  Sizes[2].descriptorCount := 2 + Max(NT, 1);
  Sizes[3].type_ := VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
  Sizes[3].descriptorCount := 1 + Max(NG, 1);
  Sizes[4].type_ := VK_DESCRIPTOR_TYPE_SAMPLER;
  Sizes[4].descriptorCount := 1;
  FillChar(PoolInfo, SizeOf(PoolInfo), 0);
  PoolInfo.sType := VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
  PoolInfo.maxSets := 3;
  PoolInfo.poolSizeCount := Length(Sizes);
  PoolInfo.pPoolSizes := @Sizes[0];
  Pool := VK_NULL_HANDLE;
  C.Check(C.Vk.CreateDescriptorPool(C.Device, @PoolInfo, nil, @Pool), 'vkCreateDescriptorPool (ray)');
  C.Cmd;
  C.Retire(TGpuVkObject.DescriptorPool, Pool);
  Counts[0] := 0;
  Counts[1] := Max(NG, 1);
  Counts[2] := Max(NT, 1);
  FillChar(CountInfo, SizeOf(CountInfo), 0);
  CountInfo.sType := VK_STRUCTURE_TYPE_DESCRIPTOR_SET_VARIABLE_DESCRIPTOR_COUNT_ALLOCATE_INFO;
  CountInfo.descriptorSetCount := 3;
  CountInfo.pDescriptorCounts := @Counts[0];
  FillChar(AllocInfo, SizeOf(AllocInfo), 0);
  AllocInfo.sType := VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
  AllocInfo.pNext := @CountInfo;
  AllocInfo.descriptorPool := Pool;
  AllocInfo.descriptorSetCount := 3;
  AllocInfo.pSetLayouts := @S.SetLayouts[0];
  C.Check(C.Vk.AllocateDescriptorSets(C.Device, @AllocInfo, @Sets[0]), 'vkAllocateDescriptorSets (ray)');
  Constants.buffer := ConstBuffer;
  Constants.offset := ConstOffset;
  Constants.range := AlignUp(ConstBytes, 16);
  Records.buffer := RecordBuffer;
  Records.offset := RecordOffset;
  Records.range := Bytes;
  DepthImage.sampler := VK_NULL_HANDLE;
  DepthImage.imageView := D.DepthView;
  DepthImage.imageLayout := VK_IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL;
  FactorImage.sampler := VK_NULL_HANDLE;
  if F <> nil then
    FactorImage.imageView := F.View
  else
    FactorImage.imageView := G.Blank.View;
  FactorImage.imageLayout := VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
  FillChar(AccelWrite, SizeOf(AccelWrite), 0);
  AccelWrite.sType := VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET_ACCELERATION_STRUCTURE_KHR;
  AccelWrite.accelerationStructureCount := 1;
  AccelWrite.pAccelerationStructures := @S.Tlas;
  FillChar(Writes, SizeOf(Writes), 0);
  for I := 0 to High(Writes) do
  begin
    Writes[I].sType := VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    Writes[I].dstSet := Sets[0];
    Writes[I].descriptorCount := 1;
  end;
  Writes[0].dstBinding := 0;
  Writes[0].descriptorType := VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
  Writes[0].pBufferInfo := @Constants;
  Writes[1].pNext := @AccelWrite;
  Writes[1].dstBinding := 16;
  Writes[1].descriptorType := VK_DESCRIPTOR_TYPE_ACCELERATION_STRUCTURE_KHR;
  Writes[2].dstBinding := 17;
  Writes[2].descriptorType := VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE;
  Writes[2].pImageInfo := @DepthImage;
  Writes[3].dstBinding := 18;
  Writes[3].descriptorType := VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE;
  Writes[3].pImageInfo := @FactorImage;
  Writes[4].dstBinding := 19;
  Writes[4].descriptorType := VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
  Writes[4].pBufferInfo := @Records;
  N := 5;
  if NG > 0 then
  begin
    SetLength(GeometryInfos, NG);
    for I := 0 to NG - 1 do
    begin
      GeometryInfos[I].buffer := S.Geometries[I].Data;
      GeometryInfos[I].offset := 0;
      GeometryInfos[I].range := S.Geometries[I].DataSize;
    end;
    Writes[N].dstSet := Sets[1];
    Writes[N].dstBinding := 16;
    Writes[N].descriptorCount := NG;
    Writes[N].descriptorType := VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
    Writes[N].pBufferInfo := @GeometryInfos[0];
    Inc(N);
  end;
  if NT > 0 then
  begin
    SetLength(TextureInfos, NT);
    for I := 0 to NT - 1 do
    begin
      TextureInfos[I].sampler := VK_NULL_HANDLE;
      TextureInfos[I].imageView := S.Textures[I].GpuView;
      if TextureInfos[I].imageView = VK_NULL_HANDLE then
        TextureInfos[I].imageView := G.Blank.View;
      TextureInfos[I].imageLayout := VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    end;
    Writes[N].dstSet := Sets[2];
    Writes[N].dstBinding := 16;
    Writes[N].descriptorCount := NT;
    Writes[N].descriptorType := VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE;
    Writes[N].pImageInfo := @TextureInfos[0];
    Inc(N);
  end;
  C.Vk.UpdateDescriptorSets(C.Device, N, @Writes[0], 0, nil);

  if Shadows then
  begin
    if F <> nil then
    begin
      RayPass(C, S, F, 1, 1, MS, Sets);
      F.UseAs(TGpuVkUse.ShaderRead);
      RayPass(C, S, T, 2, Cm.Samples, MS, Sets);
    end
    else
      RayPass(C, S, T, 0, Cm.Samples, MS, Sets);
  end;
  if Reflect then
    RayPass(C, S, T, 3, Cm.Samples, MS, Sets);

  // Other pipelines and descriptor sets are bound: the canvas and the 3D commands set theirs again.
  C.Owner := nil;
  for I := 0 to R.InstanceCount - 1 do
    R.Materials[I].Texture := nil;
end;

{ Recording (the thread that draws) }

/// <summary>The material of the draw that follows, from the constants of FMX's standard materials.</summary>
procedure ReadMaterial(const O: PCmdRayObject; const ATexture: IInterface);

  function Get(const AValue: TFastMaterialValue; const ADest: Pointer): Boolean;
  var
    S: TFastShader;
    Data: TBytes;
  begin
    S := TFastContext3D.FVS;
    Data := TFastContext3D.FVSData;
    if (S = nil) or (S.Material[AValue] < 0) or (S.Material[AValue] + S.MaterialSize[AValue] > Length(Data)) then
    begin
      S := TFastContext3D.FPS;
      Data := TFastContext3D.FPSData;
    end;
    Result := (S <> nil) and (S.Material[AValue] >= 0) and
      (S.Material[AValue] + S.MaterialSize[AValue] <= Length(Data));
    if Result then
    begin
      FillChar(ADest^, 16, 0);
      Move(Data[S.Material[AValue]], ADest^, S.MaterialSize[AValue]);
    end;
  end;

var
  Opts, Modulation: array[0..3] of Single;
begin
  if Get(TFastMaterialValue.Diffuse, @O.Diffuse) then
  begin
    O.Kind := 3;
    Get(TFastMaterialValue.Specular, @O.Specular);
    Get(TFastMaterialValue.Ambient, @O.Ambient);
    Get(TFastMaterialValue.Emission, @O.Emission);
    if Get(TFastMaterialValue.Opts, @Opts) then
      O.Shininess := Opts[0];
    O.Textured := (ATexture <> nil) and Get(TFastMaterialValue.Modulation, @Modulation) and (Modulation[0] > 0);
  end
  else if Get(TFastMaterialValue.Color, @O.Diffuse) then
    O.Kind := 1
  else if (TFastContext3D.FPS <> nil) and (TFastContext3D.FPS.Texture0 >= 0) then
  begin
    O.Kind := 2;
    O.Textured := ATexture <> nil;
  end
  else
    O.Kind := 0;
  if O.Textured then
    O.Texture := ATexture as TObject;
end;

/// <summary>Identifies a geometry across frames: the arrays FMX passes (a mesh keeps them while it does not change),
/// their sizes and a few positions (a mesh changed in place).</summary>
function GeometryKey(const AVertices, AIndices: Pointer; const AVertexSize, AVertexCount, AIndexSize,
  AIndexCount, APositionOffset: Integer): UInt64;
var
  I: Integer;
  P: PByte;
begin
  Result := FastHashMix(UInt64(AVertices), UInt64(AIndices));
  Result := FastHashMix(Result, (UInt64(Cardinal(AVertexSize)) shl 32) or Cardinal(AVertexCount));
  Result := FastHashMix(Result, (UInt64(Cardinal(AIndexSize)) shl 32) or Cardinal(AIndexCount));
  if AVertexCount > 0 then
    for I := 0 to 7 do
    begin
      P := PByte(AVertices) + NativeInt(Int64(I) * (AVertexCount - 1) div 7) * AVertexSize + APositionOffset;
      Result := FastHashMix(Result, PUInt64(P)^);
      Result := FastHashMix(Result, PCardinal(P + 8)^);
    end;
end;

procedure TFastContext3DVk.RecordRayObject(const AVertices, AIndices: Pointer; const AVertexSize, AVertexCount,
  AIndexSize, AIndexCount, APosition, ANormal, ATexCoord: Integer);
var
  O: PCmdRayObject;
  Tex: IInterface;
  M: TMatrix3D;
begin
  Tex := nil;
  if FRay.Reflections and (FPS <> nil) and (FPS.Texture0 >= 0) and (FPS.Texture0 <= High(FUnits)) then
    Tex := FUnits[FPS.Texture0];
  O := Rec(HandleRayObject, SizeOf(TCmdRayObject), Tex);
  FillChar(O^, SizeOf(TCmdRayObject), 0);
  O.Scene := FScene;
  O.PositionOffset := APosition;
  O.NormalOffset := ANormal;
  O.TexCoordOffset := ATexCoord;
  O.Geometry := GeometryKey(AVertices, AIndices, AVertexSize, AVertexCount, AIndexSize, AIndexCount, APosition);
  // Acceleration structures want the object-to-world transform as three rows of a column-vector matrix: FMX's
  // transposed.
  M := CurrentMatrix;
  O.Transform[0, 0] := M.m11;
  O.Transform[0, 1] := M.m21;
  O.Transform[0, 2] := M.m31;
  O.Transform[0, 3] := M.m41;
  O.Transform[1, 0] := M.m12;
  O.Transform[1, 1] := M.m22;
  O.Transform[1, 2] := M.m32;
  O.Transform[1, 3] := M.m42;
  O.Transform[2, 0] := M.m13;
  O.Transform[2, 1] := M.m23;
  O.Transform[2, 2] := M.m33;
  O.Transform[2, 3] := M.m43;
  if FRay.Reflections then
    ReadMaterial(O, Tex)
  else
    O.Kind := 255;
  if O.Texture <> nil then
    TTextureVk(O.Texture).Used := True;
  Inc(FRayObjects);
end;

type
  TMatrix4D = array[0..3, 0..3] of Double;

function MulD(const A, B: TMatrix4D): TMatrix4D;
var
  I, J, K: Integer;
  S: Double;
begin
  for I := 0 to 3 do
    for J := 0 to 3 do
    begin
      S := 0;
      for K := 0 to 3 do
        S := S + A[I, K] * B[K, J];
      Result[I, J] := S;
    end;
end;

/// <summary>Gauss-Jordan with partial pivoting; False for a singular matrix.</summary>
function InverseD(const A: TMatrix4D; out R: TMatrix4D): Boolean;
var
  M: TMatrix4D;
  I, J, K, P: Integer;
  F, T: Double;
begin
  M := A;
  for I := 0 to 3 do
    for J := 0 to 3 do
      R[I, J] := Ord(I = J);
  for K := 0 to 3 do
  begin
    P := K;
    for I := K + 1 to 3 do
      if Abs(M[I, K]) > Abs(M[P, K]) then
        P := I;
    if M[P, K] = 0 then
      Exit(False);
    if P <> K then
      for J := 0 to 3 do
      begin
        T := M[P, J];
        M[P, J] := M[K, J];
        M[K, J] := T;
        T := R[P, J];
        R[P, J] := R[K, J];
        R[K, J] := T;
      end;
    F := 1 / M[K, K];
    for J := 0 to 3 do
    begin
      M[K, J] := M[K, J] * F;
      R[K, J] := R[K, J] * F;
    end;
    for I := 0 to 3 do
      if I <> K then
      begin
        F := M[I, K];
        if F <> 0 then
          for J := 0 to 3 do
          begin
            M[I, J] := M[I, J] - F * M[K, J];
            R[I, J] := R[I, J] - F * R[K, J];
          end;
      end;
  end;
  Result := True;
end;

procedure TFastContext3DVk.RecordRay;
var
  C: PCmdRay;
  T: TTextureVk;
  Px: TSize;
  I, J: Integer;
  Light: TLightDescription;
  N: Cardinal;
  Dir: TPoint3D;
  CutOff: Single;
  V, P, M, Inv: TMatrix4D;
  Src: TMatrix3D;
begin
  T := TTextureVk(DrawTarget);
  if (T = nil) or (FDepth = nil) then
    Exit;
  Px := TargetPixels;
  C := Rec(HandleRay, SizeOf(TCmdRay), T);
  FillChar(C^, SizeOf(TCmdRay), 0);
  C.Target := T;
  C.Depth := FDepth as TObject;
  Keep(FDepth);
  C.Scene := FScene;
  C.Width := Px.Width;
  C.Height := Px.Height;
  C.Samples := T.Samples;
  // World = (ndc.x, ndc.y, depth, 1) * Inverse(View * Projection), divided by w (row vectors, as FMX), relative to
  // the camera (the view without its translation), in double precision as TFastContext3D12.RayCamera.
  Src := CurrentCameraMatrix;
  for I := 0 to 3 do
    for J := 0 to 3 do
      V[I, J] := Src.M[I].V[J];
  Src := CurrentProjectionMatrix;
  for I := 0 to 3 do
    for J := 0 to 3 do
      P[I, J] := Src.M[I].V[J];
  if InverseD(V, Inv) then
    for J := 0 to 2 do
      C.CameraPos[J] := Inv[3, J]
  else
    for J := 0 to 2 do
      C.CameraPos[J] := CurrentCameraInvMatrix.M[3].V[J];
  V[3, 0] := 0;
  V[3, 1] := 0;
  V[3, 2] := 0;
  M := MulD(V, P);
  if InverseD(M, Inv) then
  begin
    for I := 0 to 3 do
      for J := 0 to 3 do
        C.InvViewProj[I * 4 + J] := Inv[I, J];
  end
  else
  begin
    Src := (CurrentCameraMatrix * CurrentProjectionMatrix).Inverse;
    Move(Src, C.InvViewProj, SizeOf(C.InvViewProj));
  end;
  C.PixelToNdc[0] := 2 / Max(Px.Width, 1);
  C.PixelToNdc[1] := -2 / Max(Px.Height, 1);
  C.Strength := EnsureRange(FRay.ShadowStrength, 0, 1);
  if FRay.Shadows then
    C.Flags := C.Flags or RayShadowsOn;
  if FRay.Reflections then
  begin
    C.Flags := C.Flags or RayReflect;
    C.ReflectStrength := EnsureRange(FRay.ReflectionStrength, 0, 1);
    C.Background[0] := TAlphaColorRec(FClearColor).R / 255;
    C.Background[1] := TAlphaColorRec(FClearColor).G / 255;
    C.Background[2] := TAlphaColorRec(FClearColor).B / 255;
    C.Background[3] := 1;
  end;
  if FRay.Shadows and (FRay.ShadowSoftness > 0) then
  begin
    C.Softness := FRay.ShadowSoftness;
    C.ShadowSamples := EnsureRange(FRay.ShadowSamples, 1, 64);
  end;
  if FRay.AmbientOcclusion and (FRay.AORadius > 0) then
  begin
    C.AORadius := FRay.AORadius;
    C.AOStrength := EnsureRange(FRay.AOStrength, 0, 1);
    C.AOSamples := EnsureRange(FRay.AOSamples, 1, 64);
  end;
  N := 0;
  for I := 0 to Lights.Count - 1 do
  begin
    if not (FRay.Shadows or FRay.Reflections) then
      Break;
    Light := Lights[I];
    if not Light.Enabled or (N > High(C.LightPos)) then
      Continue;
    C.LightPos[N, 0] := Light.Position.X;
    C.LightPos[N, 1] := Light.Position.Y;
    C.LightPos[N, 2] := Light.Position.Z;
    C.LightPos[N, 3] := Ord(Light.LightType);
    Dir := Light.Direction;
    C.LightDir[N, 0] := Dir.X;
    C.LightDir[N, 1] := Dir.Y;
    C.LightDir[N, 2] := Dir.Z;
    CutOff := EnsureRange(Light.SpotCutOff, 0, 180);
    C.LightDir[N, 3] := Cos(DegToRad(CutOff));
    C.LightWeight[N, 0] := (0.299 * TAlphaColorRec(Light.Color).R + 0.587 * TAlphaColorRec(Light.Color).G +
      0.114 * TAlphaColorRec(Light.Color).B) / 255;
    C.LightWeight[N, 1] := Light.SpotExponent;
    C.LightColor[N, 0] := TAlphaColorRec(Light.Color).R / 255;
    C.LightColor[N, 1] := TAlphaColorRec(Light.Color).G / 255;
    C.LightColor[N, 2] := TAlphaColorRec(Light.Color).B / 255;
    Inc(N);
  end;
  C.LightCount := N;
end;
