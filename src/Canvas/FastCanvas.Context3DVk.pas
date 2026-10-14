unit FastCanvas.Context3DVk;

{ Own Vulkan 3D context of FastCanvas, on the device and queue of the canvas when it runs on Vulkan
  (FastCanvasBackend = Vulkan); modelled on FastCanvas.Context3D12.

  Recording: the thread that draws (the main thread) writes compact commands into the canvas command stream
  (FastBridge.RecordNative): targets, clears, draws with their vertices, indices and changed constants, copies,
  texture updates, window frames and presents. The render thread replays them into the canvas's own command buffer
  (FastCanvas.GpuVk), in program order with the 2D work: one command buffer and one submission per chunk of the
  stream for both.

  Main thread: pipelines (one per shader pair, vertex layout and stride, state, target format and samples), shader
  modules, images and their memory are made where FMX asks for them (the Vulkan device is free-threaded, the memory
  allocator of FastCanvas.DeviceVk takes its own lock). Render thread: image layouts, rendering instances (dynamic
  rendering), upload memory and push descriptors, all on the canvas's recording context, which also keeps released
  objects until the GPU is done.

  Shaders: FMX's own shaders as SPIR-V made from their GLSL sources (tools\compile-fmx-shaders-vk.ps1,
  FastCanvas.VkFmxShaders.inc), found by a hash of the GLSL source and of the Direct3D variables; their constants are
  laid out as for Direct3D (FastCanvas.Context3D), one uniform block per stage. Off Windows FMX ships no Direct3D
  sources: the table's copy of their variables gives the layout (ShaderLayout). A shader without SPIR-V there (an
  application's own shader) raises EContext3DException: not supported. One descriptor set layout, pushed per draw
  (VK_KHR_push_descriptor; without it written into a set of the recording context's pools and bound): binding 0 the
  vertex constants, 1 the pixel constants, 2..9 the texture units with their samplers. Clip space as
  with Direct3D: the viewport flips y (negative height), FMX's projection has Direct3D's depth range.

  Targets: TViewport3D and filters draw into textures (a bitmap of the canvas is used in place: DoBitmapToTexture,
  DoCopyToBitmap), a TForm3D into the frame surface of a window of the canvas back end (TGpuVkWindow: presented by its
  own thread). Depth and stencil in D32_SFLOAT_S8_UINT (the AMD driver has no D24_UNORM_S8_UINT). Multisampling with
  a resolve at the end of the scene. Mipmaps are made on the CPU when a texture is updated.

  Ray-traced effects (RayTracing, FastContext3DRayTracing: shadows, soft shadows, ambient occlusion, reflections) with
  ray queries over the scene's acceleration structures (FastCanvas.Context3DVk.Ray.inc), where the device has them
  (RayTracingSupported; AMD's 32-bit driver has not: the scenes are drawn without). Not on Vulkan: HDR targets and
  output, DLSS, application ray passes (RayDispatch, RayDraw), DrawIntensity. }

interface

{$SCOPEDENUMS ON}

uses
  System.Types, System.UITypes, System.SysUtils, System.Math, System.Math.Vectors, System.Generics.Collections,
  FMX.Types, FMX.Types3D, FMX.Graphics, FastCanvas.Gpu, FastCanvas.Context3D;

type
  TFastContext3DVk = class(TFastContext3D)
  private
    FRay: TFastRayTracing;
    /// <summary>Serial of the scene in progress whose objects enter the ray tracing (0: none), and their number.
    /// </summary>
    FScene: Integer;
    FRayObjects: Integer;
    FClearColor: TAlphaColor;
    FFormat: Integer;
    FSamples: Integer;
    FMSColor: IInterface;
    FDepth: IInterface;
    /// <summary>A window (TForm3D): the window of the canvas back end that presents the frames, and the texture of its
    /// frame surface.</summary>
    FWindow: TObject;
    /// <summary>The platform's window FWindow presents to (FastCanvas.Platform); held until FWindow goes.</summary>
    FWindowHandle: TGpuWindowHandle;
    FFrame: IInterface;
    procedure CreateTargets;
    function TargetPixels: TSize;
    /// <summary>The texture drawn into: the multisampled one, the window's frame or the target texture.</summary>
    function DrawTarget: TObject;
    procedure RecordTarget;
    procedure RecordRayObject(const AVertices, AIndices: Pointer; const AVertexSize, AVertexCount, AIndexSize,
      AIndexCount, APosition, ANormal, ATexCoord: Integer);
    procedure RecordRay;
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
    class procedure DoInitializeShader(const Shader: TContextShader); override;
    class procedure DoInitializeTexture(const Texture: TTexture); override;
    class procedure DoFinalizeTexture(const Texture: TTexture); override;
    class procedure DoUpdateTexture(const Texture: TTexture; const Bits: Pointer; const Pitch: Integer); override;
    class function DoBitmapToTexture(const Bitmap: TBitmap): TTexture; override;
    class procedure CreateNativeShader(const AShader: TFastShader); override;
    class function ShaderLayout(const Shader: TContextShader; out AVariables: TContextShaderVariables): Boolean;
      override;
    class function TextureObject(const ATexture: TTexture): IInterface; override;
    constructor CreateFromWindow(const AParent: TWindowHandle; const AWidth, AHeight: Single;
      const AMultisample: TMultisample; const ADepthStencil: Boolean); override;
    constructor CreateFromTexture(const ATexture: TTexture; const AMultisample: TMultisample;
      const ADepthStencil: Boolean); override;
  public
    destructor Destroy; override;
    class function Valid: Boolean; override;
    class function Style: TContextStyles; override;
    /// <summary>The device traces rays from shaders (VK_KHR_ray_query with acceleration structures).</summary>
    class function RayTracingSupported: Boolean;
    /// <summary>Ray-traced effects (as TFastContext3D12.RayTracing); a new context starts with
    /// FastContext3DRayTracing (FastCanvas.Context3D). Read at every scene.</summary>
    property RayTracing: TFastRayTracing read FRay write FRay;
  end;

/// <summary>Makes TFastContext3DVk the default 3D context. Call before Application.Initialize, after the canvas
/// (FastCanvas.Canvas.InstallFastCanvas) with FastCanvasBackend = Vulkan. FastContext3DFragile
/// (FastCanvas.Context3D) applies.</summary>
procedure InstallFastContext3DVk;

implementation

uses
  {$IFDEF MSWINDOWS}Winapi.Windows, {$ELSE}FastCanvas.RenderQueue, {$ENDIF}System.Classes, FMX.Forms3D, Vulkan,
  FastCanvas.Device, FastCanvas.DeviceVk, FastCanvas.GpuVk, FastCanvas.Bridge, FastCanvas.Service,
  FastCanvas.Platform;

{$I FastCanvas.VkFmxShaders.inc}

{$IFDEF MSWINDOWS}
type
  // Winapi.Windows declares a TBitmap too.
  TBitmap = FMX.Graphics.TBitmap;
{$ENDIF}

const
  MaxUnits = 8;
  /// <summary>Bindings of the descriptor set: the constants of the stages, then the texture units.</summary>
  BindingVS = 0;
  BindingPS = 1;
  BindingUnits = 2;
  /// <summary>Attribute locations of the vertex elements (tools\compile-fmx-shaders-vk.ps1).</summary>
  LocPosition = 0;
  LocNormal = 1;
  LocColor = 2;
  LocTexCoord = 6;
  LocBinormal = 10;
  LocTangent = 11;

type
  /// <summary>An image of the 3D context (a TTexture's, a target's), a bitmap of the canvas used in place (Canvas:
  /// IGpuTexture), or the frame of a window (Window: its surface for the frame, set on the render thread). Its Vulkan
  /// objects go with the last reference, or at once when the recording context shuts down (Drop).</summary>
  TTextureVk = class(TInterfacedObject)
  public
    /// <summary>Unique for the process: the render thread compares textures by it (an address can be reused).
    /// </summary>
    Id: Integer;
    Image: TVkImage;
    Memory: TFastVkAllocation;
    /// <summary>All mip levels; color, or depth and stencil (attachments).</summary>
    View: TVkImageView;
    /// <summary>A depth image: its depth only (shaders read it: ray tracing).</summary>
    DepthView: TVkImageView;
    Format: TVkFormat;
    Width, Height, Mips, Samples: Integer;
    IsDepth: Boolean;
    Canvas: IInterface;
    Window: TGpuVkWindow;
    // Render thread.
    WindowSurface: TGpuVkSurface;
    Use: TGpuVkUse;
    /// <summary>A target the GPU has not cleared yet (cleared before its first use).</summary>
    Uncleared: Boolean;
    /// <summary>Recording thread: a recorded command refers to it (updates go through the stream from then on).
    /// </summary>
    Used: Boolean;
    destructor Destroy; override;
    /// <summary>Destroys the Vulkan objects now (the GPU is idle).</summary>
    procedure Drop(const AContext: TGpuVkContext);
    /// <summary>The surface of the canvas this texture stands for, else nil.</summary>
    function Surface: TGpuVkSurface;
    function GpuImage: TVkImage;
    function GpuView: TVkImageView;
    function Range: TVkImageSubresourceRange;
    /// <summary>Render thread: the image in ANew for the commands that follow (a new target is cleared first).
    /// </summary>
    procedure UseAs(const ANew: TGpuVkUse; const ADiscard: Boolean = False);
    function CurrentUse: TGpuVkUse;
  end;

  /// <summary>The shader module of a TFastShader (its Native).</summary>
  TShaderVk = class(TInterfacedObject)
  public
    Module: TVkShaderModule;
    /// <summary>Bytes of the uniform block; attribute locations a vertex shader reads.</summary>
    Block: Integer;
    Inputs: Cardinal;
    destructor Destroy; override;
  end;

  /// <summary>Bytes that travel with a command and are too large for the stream (texture updates).</summary>
  TBlob = class(TInterfacedObject)
  public
    Data: TBytes;
  end;

  TLayoutOffsets = record
    Position, Normal, TexCoord: Integer;
  end;

  TPipeKey = packed record
    VS, PS: Integer;
    Layout: UInt64;
    Stride: Integer;
    State: TFastPipelineState;
    Topology: Byte;
    Samples: Byte;
    Depth: Boolean;
    Pad: Byte;
    Format: Integer;
  end;

  TShared = class
  public
    Fast: TFastVulkan;
    Vk: TVulkan;
    Device: TVkDevice;
    DepthFormat: TVkFormat;
    /// <summary>The descriptors of a draw are pushed (VK_KHR_push_descriptor); else they are written into a set of
    /// the recording context's descriptor pools, which is bound.</summary>
    Push: Boolean;
    SetLayout: TVkDescriptorSetLayout;
    Layout: TVkPipelineLayout;
    /// <summary>Clamped samplers: bit 0 linear minification, bit 1 linear magnification and mip levels.</summary>
    Samplers: array[0..3] of TVkSampler;
    Pipes: TDictionary<UInt64, TVkPipeline>;
    Layouts: TDictionary<UInt64, TFastVertexLayout>;
    Offsets: TDictionary<UInt64, TLayoutOffsets>;
    Blank: TTextureVk;
    BlankRef: IInterface;
    /// <summary>Render thread: the blank texture holds its white pixel.</summary>
    BlankReady: Boolean;
    constructor Create;
    destructor Destroy; override;
    /// <summary>The Vulkan objects go now (AContext: the GPU is idle) or once the GPU is done (nil).</summary>
    procedure Release(const AContext: TGpuVkContext);
    function Pipe(const AKey: TPipeKey; const ALayout: TFastVertexLayout): TVkPipeline;
    function Layout_(const ADeclaration: TVertexDeclaration; out AOffsets: TLayoutOffsets): TFastVertexLayout;
  end;

  // Commands (payloads of FastBridge.RecordNative).

  PCmdTarget = ^TCmdTarget;
  TCmdTarget = packed record
    Target, Depth: Pointer;   // TTextureVk, kept alive by the command
    Width, Height: Integer;
  end;

  PCmdClear = ^TCmdClear;
  TCmdClear = packed record
    Target, Depth: Pointer;
    Color: array[0..3] of Single;
    ClearColor, ClearDepth, ClearStencil: Boolean;
    Stencil: Byte;
    DepthValue: Single;
  end;

  PCmdDraw = ^TCmdDraw;
  /// <summary>Followed by the vertices, the indices, then the constants of the stages that changed.</summary>
  TCmdDraw = packed record
    Pipe: TVkPipeline;
    StencilRef: Cardinal;
    Scissor: TRect;
    VertexBytes, IndexBytes, VertexStride, IndexCount: Integer;
    Index32: Boolean;
    Pad: array[0..2] of Byte;
    VSBytes, PSBytes: Integer;   // 0: unchanged
    VSBlock, PSBlock: Integer;
    UnitCount: Integer;
    Units: array[0..MaxUnits - 1] of Pointer;   // TTextureVk, kept alive by the command
    /// <summary>Two bits per unit: the sampler (TShared.Samplers).</summary>
    Filters: Cardinal;
  end;

  PCmdCopy = ^TCmdCopy;
  TCmdCopy = packed record
    Source, Dest: Pointer;   // TTextureVk
    Rect: TRect;
    X, Y: Integer;
  end;

  PCmdResolve = ^TCmdResolve;
  TCmdResolve = packed record
    Source, Dest: Pointer;
  end;

  PCmdUpload = ^TCmdUpload;
  TCmdUpload = packed record
    Texture: Pointer;
    Blob: Pointer;   // TBlob: the levels one after the other, rows of Width * BytesPerPixel
    BytesPerPixel: Integer;
  end;

  PCmdReadback = ^TCmdReadback;
  TCmdReadback = packed record
    Source: Pointer;
    Buffer: TVkBuffer;
    Rect: TRect;
  end;

  PCmdFrame = ^TCmdFrame;
  /// <summary>A window's frame begins: its surface for the frame (TGpuVkWindow.Prepare).</summary>
  TCmdFrame = packed record
    Texture: Pointer;   // TTextureVk with Window
    Width, Height: Integer;
  end;

  PCmdPresent = ^TCmdPresent;
  TCmdPresent = packed record
    Texture: Pointer;   // TTextureVk with Window
  end;

  TRayTransform = array[0..2, 0..3] of Single;

  PCmdRayObject = ^TCmdRayObject;
  /// <summary>Before the draw of an opaque object of a scene with ray-traced effects: its triangles go into the
  /// scene's acceleration structure; with reflections, its vertex layout and material too.</summary>
  TCmdRayObject = packed record
    Scene: Integer;
    /// <summary>Byte offsets in a vertex: float3 position, float3 normal and float2 texture coordinates (-1: none).
    /// </summary>
    PositionOffset, NormalOffset, TexCoordOffset: Integer;
    /// <summary>The key of the geometry (its arrays and contents).</summary>
    Geometry: UInt64;
    /// <summary>Object to world: three rows of a column-vector matrix (FMX's matrix transposed).</summary>
    Transform: TRayTransform;
    /// <summary>0: unknown (gray, lit), 1: TColorMaterial (Diffuse), 2: TTextureMaterial, 3: TLightMaterial; 255: no
    /// reflections in this scene (the rest is not set).</summary>
    Kind: Byte;
    Textured: Boolean;
    Pad: Word;
    Diffuse, Ambient, Emission, Specular: array[0..3] of Single;
    Shininess: Single;
    Texture: Pointer;   // TTextureVk of texture0 (kept alive by the command), nil without one
  end;

const
  // TCmdRay.Flags (FastRay.hlsl).
  RayShadowsOn = 1;
  RayReflect = 4;

type
  PCmdRay = ^TCmdRay;
  /// <summary>The ray-traced passes over a finished scene (constants of FastRay.hlsl from InvViewProj on).</summary>
  TCmdRay = packed record
    Target, Depth: Pointer;   // TTextureVk, kept alive by the command
    Scene: Integer;
    Width, Height, Samples: Integer;
    /// <summary>Clip to the offset from the camera (CameraPos).</summary>
    InvViewProj: array[0..15] of Single;
    CameraPos: array[0..3] of Single;
    PixelToNdc: array[0..1] of Single;
    Strength: Single;
    LightCount: Cardinal;
    LightPos, LightDir, LightWeight: array[0..7, 0..3] of Single;
    Softness: Single;
    ShadowSamples: Cardinal;
    AORadius, AOStrength: Single;
    AOSamples: Cardinal;
    /// <summary>RayShadowsOn, RayReflect.</summary>
    Flags: Cardinal;
    ReflectStrength: Single;
    Pad: Single;
    LightColor: array[0..7, 0..3] of Single;
    Background: array[0..3] of Single;
  end;

  /// <summary>Render thread: the geometry and material of an instance of a scene with reflections.</summary>
  TRayMaterial = record
    Blas: TObject;   // TBlasVk
    Texture: IInterface;
    Kind: Byte;
    Textured: Boolean;
    Diffuse, Ambient, Emission, Specular: array[0..3] of Single;
    Shininess: Single;
  end;

  /// <summary>Render-thread state of the 3D commands on the canvas's open command buffer.</summary>
  TReplay = record
    Ctx: Pointer;
    ListGen: Integer;
    /// <summary>The target of the commands (kept alive here: commands of later chunks draw into it).</summary>
    Target, Depth: IInterface;
    Width, Height: Integer;
    /// <summary>The depth texture of the rendering instance begun last (C.Rendering is its target).</summary>
    RenderDepth: TObject;
    Pipe: TVkPipeline;
    Scissor: TRect;
    StencilRef: Cardinal;
    ViewportW, ViewportH: Integer;
    // The constants last recorded, uploaded again for a new command buffer or a new block size.
    VS, PS: TBytes;
    VSLen, PSLen: Integer;
    VSBuf, PSBuf: TVkBuffer;
    VSOff, PSOff: UInt64;
    VSBound, PSBound: Integer;
    /// <summary>Push descriptors written last (with these units and constants), valid while Pushed.</summary>
    Pushed: Boolean;
    UnitIds: array[0..MaxUnits - 1] of Integer;
    Filters: Cardinal;
    UnitCount: Integer;
    // Ray tracing: the objects of the scene in progress, and what lasts across scenes (TRayStateVk).
    Ray: TObject;
    RayScene: Integer;
    Instances: TArray<TVkAccelerationStructureInstanceKHR>;
    InstanceCount: Integer;
    /// <summary>The ray object command before the draw in progress (Pending), and per instance its geometry and
    /// material (reflections).</summary>
    RayObject: TCmdRayObject;
    RayObjectTexture: IInterface;
    RayObjectPending: Boolean;
    Materials: TArray<TRayMaterial>;
  end;

var
  G: TShared;
  GScenes: TList<TFastContext3DVk>;
  GContexts: TList<TFastContext3DVk>;
  /// <summary>Render thread.</summary>
  R: TReplay;
  /// <summary>Identifies the 3D context as the owner of the open command buffer (TGpuVkContext.Owner).</summary>
  GOwnerTag: TObject;
  GSharedLock: TObject;
  /// <summary>Textures and shader modules that hold Vulkan objects (dropped when the recording context shuts down).
  /// </summary>
  GLive: TList<TObject>;
{$IFDEF MSWINDOWS}
  GLiveLock: TRTLCriticalSection;
{$ELSE}
  GLiveLock: TObject;
{$ENDIF}
  GNextTextureId: Integer;
  /// <summary>The shader whose TFastShader is being made (DoInitializeShader, main thread).</summary>
  GPendingShader: TContextShader;

procedure Check(const ARes: TVkResult; const AWhat: string);
begin
  if Ord(ARes) < 0 then
  begin
    if TFastDevice.Vulkan <> nil then
      TFastDevice.Vulkan.Track(ARes);
    raise EContext3DException.CreateFmt('FastContext3DVk: %s failed (%d)', [AWhat, Ord(ARes)]);
  end;
end;

function AlignUp(const AValue: NativeInt; const AAlign: Integer): NativeInt; inline;
begin
  Result := (AValue + AAlign - 1) and not NativeInt(AAlign - 1);
end;

/// <summary>A command in the canvas stream, keeping ARef alive. The caller holds TCanvas.Lock.</summary>
function Rec(const AHandler: TFastNativeHandler; const ASize: Integer; const ARef: IInterface = nil): Pointer; inline;
begin
  Result := FastBridge.RecordNative(AHandler, ASize, ARef);
end;

procedure Keep(const ARef: IInterface); inline;
begin
  if ARef <> nil then
    FastBridge.KeepAlive(ARef);
end;

procedure LockLive; inline;
begin
{$IFDEF MSWINDOWS}
  EnterCriticalSection(GLiveLock);
{$ELSE}
  TMonitor.Enter(GLiveLock);
{$ENDIF}
end;

procedure UnlockLive; inline;
begin
{$IFDEF MSWINDOWS}
  LeaveCriticalSection(GLiveLock);
{$ELSE}
  TMonitor.Exit(GLiveLock);
{$ENDIF}
end;

procedure AddLive(const AObject: TObject);
begin
  LockLive;
  try
    if GLive = nil then
      GLive := TList<TObject>.Create;
    GLive.Add(AObject);
  finally
    UnlockLive;
  end;
end;

procedure RemoveLive(const AObject: TObject);
begin
  LockLive;
  try
    if GLive <> nil then
    begin
      GLive.Remove(AObject);
      if (GLive.Count = 0) and (GContexts = nil) then
        FreeAndNil(GLive);
    end;
  finally
    UnlockLive;
  end;
end;

/// <summary>The Vulkan format of a pixel format (VK_FORMAT_UNDEFINED: none); AAlpha: an 8-bit alpha texture (R8 read
/// as alpha).</summary>
function VkFormatOf(const AFormat: TPixelFormat; out AAlpha: Boolean): TVkFormat;
begin
  AAlpha := False;
  case AFormat of
    TPixelFormat.RGBA: Result := VK_FORMAT_R8G8B8A8_UNORM;
    TPixelFormat.BGRA: Result := VK_FORMAT_B8G8R8A8_UNORM;
    TPixelFormat.RGBA16: Result := VK_FORMAT_R16G16B16A16_UNORM;
    // The DXGI formats of FastDxgiFormat name the components from the lowest bits, Vulkan's packed ones from the
    // highest.
    TPixelFormat.BGR_565: Result := VK_FORMAT_R5G6B5_UNORM_PACK16;
    TPixelFormat.BGRA4: Result := VK_FORMAT_A4R4G4B4_UNORM_PACK16;
    TPixelFormat.BGR5_A1: Result := VK_FORMAT_A1R5G5B5_UNORM_PACK16;
    TPixelFormat.RGB10_A2: Result := VK_FORMAT_A2B10G10R10_UNORM_PACK32;
    TPixelFormat.L: Result := VK_FORMAT_R8_UNORM;
    TPixelFormat.L16: Result := VK_FORMAT_R16_UNORM;
    TPixelFormat.A:
      begin
        Result := VK_FORMAT_R8_UNORM;
        AAlpha := True;
      end;
    TPixelFormat.R16F: Result := VK_FORMAT_R16_SFLOAT;
    TPixelFormat.RG16F: Result := VK_FORMAT_R16G16_SFLOAT;
    TPixelFormat.RGBA16F: Result := VK_FORMAT_R16G16B16A16_SFLOAT;
    TPixelFormat.R32F: Result := VK_FORMAT_R32_SFLOAT;
    TPixelFormat.RG32F: Result := VK_FORMAT_R32G32_SFLOAT;
    TPixelFormat.RGBA32F: Result := VK_FORMAT_R32G32B32A32_SFLOAT;
  else
    Result := VK_FORMAT_UNDEFINED;
  end;
end;

function BytesPerPixel(const AFormat: TVkFormat): Integer;
begin
  case AFormat of
    VK_FORMAT_R32G32B32A32_SFLOAT: Result := 16;
    VK_FORMAT_R16G16B16A16_SFLOAT, VK_FORMAT_R16G16B16A16_UNORM, VK_FORMAT_R32G32_SFLOAT: Result := 8;
    VK_FORMAT_R16G16_SFLOAT, VK_FORMAT_R32_SFLOAT, VK_FORMAT_A2B10G10R10_UNORM_PACK32, VK_FORMAT_R8G8B8A8_UNORM,
    VK_FORMAT_B8G8R8A8_UNORM: Result := 4;
    VK_FORMAT_R16_SFLOAT, VK_FORMAT_R16_UNORM, VK_FORMAT_R5G6B5_UNORM_PACK16, VK_FORMAT_A4R4G4B4_UNORM_PACK16,
    VK_FORMAT_A1R5G5B5_UNORM_PACK16: Result := 2;
  else
    Result := 1;
  end;
end;

/// <summary>Mipmaps are made on the CPU, for the 8-bit four-channel formats.</summary>
function CanMip(const AFormat: TVkFormat): Boolean;
begin
  Result := (AFormat = VK_FORMAT_B8G8R8A8_UNORM) or (AFormat = VK_FORMAT_R8G8B8A8_UNORM);
end;

/// <summary>An image of the 3D context with its memory and views (any thread). Render targets and depth buffers are
/// cleared by the render thread before their first use.</summary>
function NewTextureVk(const AWidth, AHeight, AMips, ASamples: Integer; const AFormat: TVkFormat;
  const AUsage: TVkImageUsageFlags; const ADepth: Boolean = False; const AAlpha: Boolean = False): TTextureVk;
var
  F: TFastVulkan;
  Info: TVkImageCreateInfo;
  ViewInfo: TVkImageViewCreateInfo;
  Req: TVkMemoryRequirements;
begin
  // The recording context exists: it drops what is left of the textures when it shuts down.
  GpuVk;
  F := TFastDevice.Vulkan;
  if F = nil then
    raise EContext3DException.Create('FastContext3DVk: the canvas has no Vulkan device');
  Result := TTextureVk.Create;
  try
    Result.Id := AtomicIncrement(GNextTextureId);
    Result.Width := AWidth;
    Result.Height := AHeight;
    Result.Mips := Max(AMips, 1);
    Result.Samples := Max(ASamples, 1);
    Result.Format := AFormat;
    Result.IsDepth := ADepth;
    Result.Uncleared := (AUsage and (Ord(VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT) or
      Ord(VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT))) <> 0;
    FillChar(Info, SizeOf(Info), 0);
    Info.sType := VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    Info.imageType := VK_IMAGE_TYPE_2D;
    Info.format := AFormat;
    Info.extent.width := Max(AWidth, 1);
    Info.extent.height := Max(AHeight, 1);
    Info.extent.depth := 1;
    Info.mipLevels := Result.Mips;
    Info.arrayLayers := 1;
    Info.samples := TVkSampleCountFlagBits(Result.Samples);
    Info.tiling := VK_IMAGE_TILING_OPTIMAL;
    Info.usage := AUsage or Ord(VK_IMAGE_USAGE_TRANSFER_DST_BIT);
    Info.sharingMode := VK_SHARING_MODE_EXCLUSIVE;
    Info.initialLayout := VK_IMAGE_LAYOUT_UNDEFINED;
    Check(F.Track(F.Vk.CreateImage(F.Device, @Info, nil, @Result.Image)), 'vkCreateImage');
    // Dropped with the recording context from here on.
    AddLive(Result);
    F.Vk.GetImageMemoryRequirements(F.Device, Result.Image, @Req);
    try
      Result.Memory := F.Allocate(Req, Ord(VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT), 0, False);
    except
      on E: EFastVulkan do
        raise EContext3DException.Create(E.Message);
    end;
    Check(F.Vk.BindImageMemory(F.Device, Result.Image, Result.Memory.Memory, Result.Memory.Offset),
      'vkBindImageMemory');
    FillChar(ViewInfo, SizeOf(ViewInfo), 0);
    ViewInfo.sType := VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    ViewInfo.image := Result.Image;
    ViewInfo.viewType := VK_IMAGE_VIEW_TYPE_2D;
    ViewInfo.format := AFormat;
    if AAlpha then
    begin
      // DXGI_FORMAT_A8_UNORM reads (0, 0, 0, a).
      ViewInfo.components.r := VK_COMPONENT_SWIZZLE_ZERO;
      ViewInfo.components.g := VK_COMPONENT_SWIZZLE_ZERO;
      ViewInfo.components.b := VK_COMPONENT_SWIZZLE_ZERO;
      ViewInfo.components.a := VK_COMPONENT_SWIZZLE_R;
    end;
    ViewInfo.subresourceRange := Result.Range;
    Check(F.Vk.CreateImageView(F.Device, @ViewInfo, nil, @Result.View), 'vkCreateImageView');
    if ADepth then
    begin
      ViewInfo.subresourceRange.aspectMask := Ord(VK_IMAGE_ASPECT_DEPTH_BIT);
      Check(F.Vk.CreateImageView(F.Device, @ViewInfo, nil, @Result.DepthView), 'vkCreateImageView (depth)');
    end;
  except
    Result.Free;
    raise;
  end;
end;

{ TTextureVk }

destructor TTextureVk.Destroy;
var
  C: TGpuVkContext;
begin
  // Any thread: the last reference may go with a command chunk on the render thread.
  if (Image <> VK_NULL_HANDLE) or (Memory <> nil) then
  begin
    TFastDevice.Lock;
    try
      // Command buffers not executed yet may use it.
      C := GpuVkCurrent;
      if C <> nil then
      begin
        C.Retire(TGpuVkObject.ImageView, View);
        C.Retire(TGpuVkObject.ImageView, DepthView);
        C.Retire(TGpuVkObject.Image, Image);
        C.Retire(TGpuVkObject.Memory, MemoryHandle(Memory));
      end
      else if Memory <> nil then
        // Not made through a recording context (it was dropped otherwise): give the memory back.
        TFastDevice.Vulkan.Release(Memory);
      View := VK_NULL_HANDLE;
      DepthView := VK_NULL_HANDLE;
      Image := VK_NULL_HANDLE;
      Memory := nil;
    finally
      TFastDevice.Unlock;
    end;
    RemoveLive(Self);
  end;
  inherited;
end;

procedure TTextureVk.Drop(const AContext: TGpuVkContext);
begin
  AContext.DestroyObject(TGpuVkObject.ImageView, View);
  AContext.DestroyObject(TGpuVkObject.ImageView, DepthView);
  AContext.DestroyObject(TGpuVkObject.Image, Image);
  AContext.DestroyObject(TGpuVkObject.Memory, MemoryHandle(Memory));
  View := VK_NULL_HANDLE;
  DepthView := VK_NULL_HANDLE;
  Image := VK_NULL_HANDLE;
  Memory := nil;
  WindowSurface := nil;
end;

function TTextureVk.Surface: TGpuVkSurface;
var
  S: TGpuSurface;
begin
  Result := nil;
  if Window <> nil then
    Exit(WindowSurface);
  if Canvas <> nil then
  begin
    S := IGpuTexture(Canvas).Surface;
    if S is TGpuVkSurface then
      Result := TGpuVkSurface(S);
  end;
end;

function TTextureVk.GpuImage: TVkImage;
var
  S: TGpuVkSurface;
begin
  if (Canvas = nil) and (Window = nil) then
    Exit(Image);
  S := Surface;
  if S <> nil then
    Result := S.Image
  else
    Result := VK_NULL_HANDLE;
end;

function TTextureVk.GpuView: TVkImageView;
var
  S: TGpuVkSurface;
begin
  if (Canvas = nil) and (Window = nil) then
    Exit(View);
  S := Surface;
  if S <> nil then
    Result := S.View
  else
    Result := VK_NULL_HANDLE;
end;

function TTextureVk.Range: TVkImageSubresourceRange;
begin
  if IsDepth then
    Result.aspectMask := Ord(VK_IMAGE_ASPECT_DEPTH_BIT) or Ord(VK_IMAGE_ASPECT_STENCIL_BIT)
  else
    Result.aspectMask := Ord(VK_IMAGE_ASPECT_COLOR_BIT);
  Result.baseMipLevel := 0;
  Result.levelCount := Max(Mips, 1);
  Result.baseArrayLayer := 0;
  Result.layerCount := 1;
end;

function TTextureVk.CurrentUse: TGpuVkUse;
var
  S: TGpuVkSurface;
begin
  if (Canvas = nil) and (Window = nil) then
    Exit(Use);
  S := Surface;
  if S <> nil then
    Result := S.State
  else
    Result := TGpuVkUse.Undefined;
end;

procedure TTextureVk.UseAs(const ANew: TGpuVkUse; const ADiscard: Boolean);
var
  C: TGpuVkContext;
  S: TGpuVkSurface;
  Rg: TVkImageSubresourceRange;
  Color: TVkClearColorValue;
  Depth: TVkClearDepthStencilValue;
begin
  if (Canvas <> nil) or (Window <> nil) then
  begin
    S := Surface;
    if S <> nil then
      S.Use(ANew);
    Exit;
  end;
  if Image = VK_NULL_HANDLE then
    Exit;
  C := GpuVk;
  Rg := Range;
  if Uncleared then
  begin
    // A new target or depth buffer: transparent, or depth 1 (as Direct3D 12 clears them).
    Uncleared := False;
    if not ADiscard then
    begin
      C.Transition(Image, Use, TGpuVkUse.TransferDst, True, @Rg);
      if IsDepth then
      begin
        Depth.depth := 1;
        Depth.stencil := 0;
        C.Vk.CmdClearDepthStencilImage(C.TransferCmd, Image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, @Depth, 1, @Rg);
      end
      else
      begin
        FillChar(Color, SizeOf(Color), 0);
        C.Vk.CmdClearColorImage(C.TransferCmd, Image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, @Color, 1, @Rg);
      end;
    end;
  end;
  C.Transition(Image, Use, ANew, ADiscard, @Rg);
end;

{ TShaderVk }

destructor TShaderVk.Destroy;
var
  C: TGpuVkContext;
begin
  if Module <> VK_NULL_HANDLE then
  begin
    TFastDevice.Lock;
    try
      C := GpuVkCurrent;
      if C <> nil then
        C.Retire(TGpuVkObject.ShaderModule, Module);
      Module := VK_NULL_HANDLE;
    finally
      TFastDevice.Unlock;
    end;
    RemoveLive(Self);
  end;
  inherited;
end;

{ TShared }

constructor TShared.Create;
var
  Sampler: TVkSamplerCreateInfo;
  Bindings: array[0..BindingUnits + MaxUnits - 1] of TVkDescriptorSetLayoutBinding;
  SetInfo: TVkDescriptorSetLayoutCreateInfo;
  LayoutInfo: TVkPipelineLayoutCreateInfo;
  I: Integer;
begin
  inherited Create;
  TFastDevice.Ensure;
  Fast := TFastDevice.Vulkan;
  if Fast = nil then
    raise EContext3DException.Create('FastContext3DVk: the canvas has no Vulkan device');
  if Fast.DepthFormat = VK_FORMAT_UNDEFINED then
    raise EContext3DException.Create('FastContext3DVk: the Vulkan device has no depth and stencil format');
  Vk := Fast.Vk;
  Device := Fast.Device;
  DepthFormat := Fast.DepthFormat;
  Push := Fast.PushDescriptor;
  Pipes := TDictionary<UInt64, TVkPipeline>.Create;
  Layouts := TDictionary<UInt64, TFastVertexLayout>.Create;
  Offsets := TDictionary<UInt64, TLayoutOffsets>.Create;
  for I := 0 to High(Samplers) do
  begin
    FillChar(Sampler, SizeOf(Sampler), 0);
    Sampler.sType := VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
    // As the filters of Direct3D 12: MIN_MAG_MIP_POINT, MIN_LINEAR_MAG_MIP_POINT, MIN_POINT_MAG_MIP_LINEAR,
    // MIN_MAG_MIP_LINEAR.
    if (I and 1) <> 0 then
      Sampler.minFilter := VK_FILTER_LINEAR
    else
      Sampler.minFilter := VK_FILTER_NEAREST;
    if (I and 2) <> 0 then
    begin
      Sampler.magFilter := VK_FILTER_LINEAR;
      Sampler.mipmapMode := VK_SAMPLER_MIPMAP_MODE_LINEAR;
    end
    else
    begin
      Sampler.magFilter := VK_FILTER_NEAREST;
      Sampler.mipmapMode := VK_SAMPLER_MIPMAP_MODE_NEAREST;
    end;
    Sampler.addressModeU := VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    Sampler.addressModeV := VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    Sampler.addressModeW := VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    Sampler.maxAnisotropy := 1;
    Sampler.compareOp := VK_COMPARE_OP_NEVER;
    Sampler.minLod := 0;
    Sampler.maxLod := VK_LOD_CLAMP_NONE;
    Check(Vk.CreateSampler(Device, @Sampler, nil, @Samplers[I]), 'vkCreateSampler');
  end;
  FillChar(Bindings, SizeOf(Bindings), 0);
  Bindings[0].binding := BindingVS;
  Bindings[0].descriptorType := VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
  Bindings[0].descriptorCount := 1;
  Bindings[0].stageFlags := Ord(VK_SHADER_STAGE_VERTEX_BIT);
  Bindings[1].binding := BindingPS;
  Bindings[1].descriptorType := VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
  Bindings[1].descriptorCount := 1;
  Bindings[1].stageFlags := Ord(VK_SHADER_STAGE_FRAGMENT_BIT);
  for I := 0 to MaxUnits - 1 do
  begin
    Bindings[BindingUnits + I].binding := BindingUnits + I;
    Bindings[BindingUnits + I].descriptorType := VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    Bindings[BindingUnits + I].descriptorCount := 1;
    Bindings[BindingUnits + I].stageFlags := Ord(VK_SHADER_STAGE_FRAGMENT_BIT);
  end;
  FillChar(SetInfo, SizeOf(SetInfo), 0);
  SetInfo.sType := VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
  if Push then
    SetInfo.flags := Ord(VK_DESCRIPTOR_SET_LAYOUT_CREATE_PUSH_DESCRIPTOR_BIT_KHR);
  SetInfo.bindingCount := Length(Bindings);
  SetInfo.pBindings := @Bindings[0];
  Check(Vk.CreateDescriptorSetLayout(Device, @SetInfo, nil, @SetLayout), 'vkCreateDescriptorSetLayout');
  FillChar(LayoutInfo, SizeOf(LayoutInfo), 0);
  LayoutInfo.sType := VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
  LayoutInfo.setLayoutCount := 1;
  LayoutInfo.pSetLayouts := @SetLayout;
  Check(Vk.CreatePipelineLayout(Device, @LayoutInfo, nil, @Layout), 'vkCreatePipelineLayout');
  // White 1x1: texture units without a texture sample it (filled by the render thread before its first use).
  Blank := NewTextureVk(1, 1, 1, 1, VK_FORMAT_B8G8R8A8_UNORM, Ord(VK_IMAGE_USAGE_SAMPLED_BIT));
  BlankRef := Blank;
end;

destructor TShared.Destroy;
begin
  BlankRef := nil;
  Pipes.Free;
  Layouts.Free;
  Offsets.Free;
  inherited;
end;

procedure TShared.Release(const AContext: TGpuVkContext);
var
  C: TGpuVkContext;
  P: TVkPipeline;
  I: Integer;

  procedure Go(const AKind: TGpuVkObject; const AHandle: UInt64);
  begin
    if AContext <> nil then
      AContext.DestroyObject(AKind, AHandle)
    else if C <> nil then
      C.Retire(AKind, AHandle);
  end;

begin
  TFastDevice.Lock;
  try
    C := GpuVkCurrent;
    for P in Pipes.Values do
      Go(TGpuVkObject.Pipeline, P);
    Pipes.Clear;
    Go(TGpuVkObject.PipelineLayout, Layout);
    Go(TGpuVkObject.SetLayout, SetLayout);
    for I := 0 to High(Samplers) do
      Go(TGpuVkObject.Sampler, Samplers[I]);
    Layout := VK_NULL_HANDLE;
    SetLayout := VK_NULL_HANDLE;
    FillChar(Samplers, SizeOf(Samplers), 0);
    if (AContext <> nil) and (Blank <> nil) then
      Blank.Drop(AContext);
  finally
    TFastDevice.Unlock;
  end;
end;

function TShared.Layout_(const ADeclaration: TVertexDeclaration; out AOffsets: TLayoutOffsets): TFastVertexLayout;
var
  Key: UInt64;
  E: TVertexElement;
begin
  // FMX passes a few declarations over and over: no arrays made per draw.
  if Length(ADeclaration) = 0 then
    Key := 0
  else
    Key := FastHash(@ADeclaration[0], Length(ADeclaration) * SizeOf(TVertexElement));
  if Layouts.TryGetValue(Key, Result) then
  begin
    AOffsets := Offsets[Key];
    Exit;
  end;
  Result := TFastContext3D.VertexLayout(ADeclaration);
  Layouts.Add(Key, Result);
  AOffsets.Position := -1;
  AOffsets.Normal := -1;
  AOffsets.TexCoord := -1;
  for E in ADeclaration do
    case E.Format of
      TVertexFormat.Vertex:
        if AOffsets.Position < 0 then
          AOffsets.Position := E.Offset;
      TVertexFormat.Normal:
        if AOffsets.Normal < 0 then
          AOffsets.Normal := E.Offset;
      TVertexFormat.TexCoord0:
        if AOffsets.TexCoord < 0 then
          AOffsets.TexCoord := E.Offset;
    end;
  Offsets.Add(Key, AOffsets);
end;

/// <summary>The attribute location of a vertex element (-1: none the shaders read).</summary>
function ElementLocation(const AElement: TFastVertexElement): Integer;
var
  S: AnsiString;
begin
  S := AnsiString(AElement.Semantic);
  if S = 'POSITION' then
    Result := LocPosition
  else if S = 'NORMAL' then
    Result := LocNormal
  else if (S = 'COLOR') and (AElement.SemanticIndex <= 3) then
    Result := LocColor + AElement.SemanticIndex
  else if (S = 'TEXCOORD') and (AElement.SemanticIndex <= 3) then
    Result := LocTexCoord + AElement.SemanticIndex
  else if S = 'BINORMAL' then
    Result := LocBinormal
  else if S = 'TANGENT' then
    Result := LocTangent
  else
    Result := -1;
end;

/// <summary>The Vulkan format of a DXGI_FORMAT of FastCanvas.Context3D.VertexLayout.</summary>
function VertexFormat(const ADxgi: Integer): TVkFormat;
begin
  case ADxgi of
    2: Result := VK_FORMAT_R32G32B32A32_SFLOAT;
    6: Result := VK_FORMAT_R32G32B32_SFLOAT;
    16: Result := VK_FORMAT_R32G32_SFLOAT;
    28: Result := VK_FORMAT_R8G8B8A8_UNORM;
  else
    Result := VK_FORMAT_R32G32B32_SFLOAT;
  end;
end;

function TShared.Pipe(const AKey: TPipeKey; const ALayout: TFastVertexLayout): TVkPipeline;
const
  Ops: array[TStencilOp] of TVkStencilOp = (VK_STENCIL_OP_KEEP, VK_STENCIL_OP_ZERO, VK_STENCIL_OP_REPLACE,
    VK_STENCIL_OP_INCREMENT_AND_CLAMP, VK_STENCIL_OP_DECREMENT_AND_CLAMP, VK_STENCIL_OP_INVERT);
  Funcs: array[TStencilFunc] of TVkCompareOp = (VK_COMPARE_OP_NEVER, VK_COMPARE_OP_LESS, VK_COMPARE_OP_LESS_OR_EQUAL,
    VK_COMPARE_OP_GREATER, VK_COMPARE_OP_GREATER_OR_EQUAL, VK_COMPARE_OP_EQUAL, VK_COMPARE_OP_NOT_EQUAL,
    VK_COMPARE_OP_ALWAYS);
  Culls: array[0..2] of TVkCullModeFlagBits = (VK_CULL_MODE_NONE, VK_CULL_MODE_BACK_BIT, VK_CULL_MODE_FRONT_BIT);
  Topologies: array[0..2] of TVkPrimitiveTopology = (VK_PRIMITIVE_TOPOLOGY_POINT_LIST,
    VK_PRIMITIVE_TOPOLOGY_LINE_LIST, VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST);
  MainName: PAnsiChar = 'main';
var
  Hash: UInt64;
  VS, PS: TShaderVk;
  S: TFastPipelineState;
  Stages: array[0..1] of TVkPipelineShaderStageCreateInfo;
  Binding: TVkVertexInputBindingDescription;
  Attributes: TArray<TVkVertexInputAttributeDescription>;
  VertexInput: TVkPipelineVertexInputStateCreateInfo;
  Assembly: TVkPipelineInputAssemblyStateCreateInfo;
  ViewportState: TVkPipelineViewportStateCreateInfo;
  Raster: TVkPipelineRasterizationStateCreateInfo;
  Multisample: TVkPipelineMultisampleStateCreateInfo;
  DepthStencil: TVkPipelineDepthStencilStateCreateInfo;
  Attachment: TVkPipelineColorBlendAttachmentState;
  Blend: TVkPipelineColorBlendStateCreateInfo;
  DynamicStates: array[0..2] of TVkDynamicState;
  Dynamic: TVkPipelineDynamicStateCreateInfo;
  ColorFormat: TVkFormat;
  Rendering: TVkPipelineRenderingCreateInfo;
  Info: TVkGraphicsPipelineCreateInfo;
  E: TFastVertexElement;
  Loc, I, N: Integer;
  Provided: Cardinal;
begin
  Hash := FastHash(@AKey, SizeOf(AKey));
  if Pipes.TryGetValue(Hash, Result) then
    Exit;
  VS := TShaderVk(TFastContext3D.FVS.Native as TObject);
  PS := TShaderVk(TFastContext3D.FPS.Native as TObject);
  S := AKey.State;
  FillChar(Stages, SizeOf(Stages), 0);
  Stages[0].sType := VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
  Stages[0].stage := VK_SHADER_STAGE_VERTEX_BIT;
  Stages[0].module := VS.Module;
  Stages[0].pName := MainName;
  Stages[1].sType := VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
  Stages[1].stage := VK_SHADER_STAGE_FRAGMENT_BIT;
  Stages[1].module := PS.Module;
  Stages[1].pName := MainName;
  // The elements the vertex shader reads; one it reads that the declaration lacks takes the position's bytes (as
  // Direct3D 12 would refuse the pipeline, FMX does not draw so).
  Binding.binding := 0;
  Binding.stride := AKey.Stride;
  Binding.inputRate := VK_VERTEX_INPUT_RATE_VERTEX;
  SetLength(Attributes, 16);
  N := 0;
  Provided := 0;
  for E in ALayout.Elements do
  begin
    Loc := ElementLocation(E);
    if (Loc < 0) or ((VS.Inputs and (Cardinal(1) shl Loc)) = 0) or ((Provided and (Cardinal(1) shl Loc)) <> 0) then
      Continue;
    Attributes[N].location := Loc;
    Attributes[N].binding := 0;
    Attributes[N].format := VertexFormat(E.Format);
    Attributes[N].offset := E.Offset;
    Provided := Provided or (Cardinal(1) shl Loc);
    Inc(N);
  end;
  for I := 0 to 15 do
    if ((VS.Inputs and (Cardinal(1) shl I)) <> 0) and ((Provided and (Cardinal(1) shl I)) = 0) then
    begin
      Attributes[N].location := I;
      Attributes[N].binding := 0;
      Attributes[N].format := VK_FORMAT_R32G32B32_SFLOAT;
      Attributes[N].offset := 0;
      Inc(N);
    end;
  FillChar(VertexInput, SizeOf(VertexInput), 0);
  VertexInput.sType := VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
  VertexInput.vertexBindingDescriptionCount := 1;
  VertexInput.pVertexBindingDescriptions := @Binding;
  VertexInput.vertexAttributeDescriptionCount := N;
  if N > 0 then
    VertexInput.pVertexAttributeDescriptions := @Attributes[0];
  FillChar(Assembly, SizeOf(Assembly), 0);
  Assembly.sType := VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
  Assembly.topology := Topologies[Min(AKey.Topology, 2)];
  FillChar(ViewportState, SizeOf(ViewportState), 0);
  ViewportState.sType := VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
  ViewportState.viewportCount := 1;
  ViewportState.scissorCount := 1;
  FillChar(Raster, SizeOf(Raster), 0);
  Raster.sType := VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
  Raster.polygonMode := VK_POLYGON_MODE_FILL;
  Raster.cullMode := Ord(Culls[Min(S.Cull, 2)]);
  // Clockwise in the target's pixels is the front, as with Direct3D (the viewport keeps its y direction).
  Raster.frontFace := VK_FRONT_FACE_CLOCKWISE;
  Raster.lineWidth := 1;
  FillChar(Multisample, SizeOf(Multisample), 0);
  Multisample.sType := VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
  Multisample.rasterizationSamples := TVkSampleCountFlagBits(Max(AKey.Samples, 1));
  FillChar(DepthStencil, SizeOf(DepthStencil), 0);
  DepthStencil.sType := VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO;
  DepthStencil.depthTestEnable := Ord(S.DepthTest and AKey.Depth);
  DepthStencil.depthWriteEnable := Ord(S.DepthWrite and AKey.Depth);
  DepthStencil.depthCompareOp := VK_COMPARE_OP_LESS_OR_EQUAL;
  DepthStencil.stencilTestEnable := Ord(S.Stencil and AKey.Depth);
  DepthStencil.front.failOp := Ops[S.StencilFail];
  DepthStencil.front.depthFailOp := Ops[S.StencilDepthFail];
  DepthStencil.front.passOp := Ops[S.StencilPass];
  DepthStencil.front.compareOp := Funcs[S.StencilFunc];
  DepthStencil.front.compareMask := S.StencilMask;
  DepthStencil.front.writeMask := S.StencilMask;
  DepthStencil.back := DepthStencil.front;
  DepthStencil.maxDepthBounds := 1;
  // FMX colors are premultiplied.
  FillChar(Attachment, SizeOf(Attachment), 0);
  Attachment.blendEnable := Ord(S.Blend);
  Attachment.srcColorBlendFactor := VK_BLEND_FACTOR_ONE;
  Attachment.dstColorBlendFactor := VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
  Attachment.colorBlendOp := VK_BLEND_OP_ADD;
  Attachment.srcAlphaBlendFactor := VK_BLEND_FACTOR_ONE;
  Attachment.dstAlphaBlendFactor := VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
  Attachment.alphaBlendOp := VK_BLEND_OP_ADD;
  if S.ColorWrite then
    Attachment.colorWriteMask := Ord(VK_COLOR_COMPONENT_R_BIT) or Ord(VK_COLOR_COMPONENT_G_BIT) or
      Ord(VK_COLOR_COMPONENT_B_BIT) or Ord(VK_COLOR_COMPONENT_A_BIT);
  FillChar(Blend, SizeOf(Blend), 0);
  Blend.sType := VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
  Blend.attachmentCount := 1;
  Blend.pAttachments := @Attachment;
  DynamicStates[0] := VK_DYNAMIC_STATE_VIEWPORT;
  DynamicStates[1] := VK_DYNAMIC_STATE_SCISSOR;
  DynamicStates[2] := VK_DYNAMIC_STATE_STENCIL_REFERENCE;
  FillChar(Dynamic, SizeOf(Dynamic), 0);
  Dynamic.sType := VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
  Dynamic.dynamicStateCount := Length(DynamicStates);
  Dynamic.pDynamicStates := @DynamicStates[0];
  ColorFormat := TVkFormat(AKey.Format);
  FillChar(Rendering, SizeOf(Rendering), 0);
  Rendering.sType := VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO;
  Rendering.colorAttachmentCount := 1;
  Rendering.pColorAttachmentFormats := @ColorFormat;
  if AKey.Depth then
  begin
    Rendering.depthAttachmentFormat := DepthFormat;
    Rendering.stencilAttachmentFormat := DepthFormat;
  end;
  FillChar(Info, SizeOf(Info), 0);
  Info.sType := VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
  // Dynamic rendering, else a render pass of the same attachments.
  try
    Fast.PipelineTarget(Info, @Rendering, Max(AKey.Samples, 1));
  except
    on E: EFastVulkan do
      raise EContext3DException.Create(E.Message);
  end;
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
  Check(Fast.Track(Vk.CreateGraphicsPipelines(Device, VK_NULL_HANDLE, 1, @Info, nil, @Result)),
    'vkCreateGraphicsPipelines');
  Pipes.Add(Hash, Result);
end;

function Shared: TShared;
var
  S: TShared;
begin
  if G <> nil then
    Exit(G);
  // Also made in message handlers of other threads (textures made again after a device reset).
  TMonitor.Enter(GSharedLock);
  try
    if G = nil then
    begin
      S := TShared.Create;
      G := S;
    end;
  finally
    TMonitor.Exit(GSharedLock);
  end;
  Result := G;
end;

/// <summary>Render thread: the blank texture holds its white pixel (before its first use).</summary>
procedure EnsureBlank;
var
  White: Cardinal;
  B: TTextureVk;
begin
  if G.BlankReady then
    Exit;
  B := G.Blank;
  White := $FFFFFFFF;
  B.Uncleared := False;
  GpuVk.CopyToImage(B.Image, B.Use, 4, 0, 0, 1, 1, @White, 4);
  B.UseAs(TGpuVkUse.ShaderRead);
  G.BlankReady := True;
end;

{$I FastCanvas.Context3DVk.Ray.inc}

{ Replay (render thread, device lock held) }

/// <summary>The open command buffer with the 3D state bound (again after the canvas used it or a new one began).
/// </summary>
function Begin3D: TGpuVkContext;
begin
  Result := GpuVk;
  // A new command buffer has nothing bound.
  Result.Cmd;
  if (R.Ctx <> Pointer(Result)) or (R.ListGen <> Result.ListGen) or (Result.Owner <> GOwnerTag) then
  begin
    if (R.Ctx <> Pointer(Result)) or (R.ListGen <> Result.ListGen) then
    begin
      // Upload memory of the constants belongs to the command buffer that used it.
      R.VSBound := -1;
      R.PSBound := -1;
    end;
    R.Ctx := Result;
    R.ListGen := Result.ListGen;
    Result.Owner := GOwnerTag;
    R.Pipe := VK_NULL_HANDLE;
    R.Scissor := TRect.Create(-1, -1, -1, -1);
    R.StencilRef := $FFFFFFFF;
    R.ViewportW := -1;
    R.Pushed := False;
  end;
end;

/// <summary>Rendering into the target (and depth buffer) for the commands that follow: begun again after barriers,
/// when another target was drawn into, or to clear (AClear: with the attachments' clear operations).</summary>
procedure EnsureRendering(const AClear: PCmdClear);
var
  C: TGpuVkContext;
  T, D: TTextureVk;
  ColorWas, DepthWas: TGpuVkUse;
  Color, Depth, Stencil: TVkRenderingAttachmentInfo;
  Info: TVkRenderingInfo;
begin
  C := Begin3D;
  if R.Target = nil then
    Exit;
  T := TTextureVk(R.Target as TObject);
  D := nil;
  if R.Depth <> nil then
    D := TTextureVk(R.Depth as TObject);
  if (AClear = nil) and (C.Rendering = T) and (R.RenderDepth = D) and not C.HasBarriers then
    Exit;
  ColorWas := T.CurrentUse;
  T.UseAs(TGpuVkUse.ColorTarget, (AClear <> nil) and AClear.ClearColor);
  DepthWas := TGpuVkUse.Undefined;
  if D <> nil then
  begin
    DepthWas := D.CurrentUse;
    D.UseAs(TGpuVkUse.DepthTarget, (AClear <> nil) and AClear.ClearDepth and AClear.ClearStencil);
  end;
  // Drawn in an earlier rendering instance: its writes come before the next ones (blending and tests read them).
  if ColorWas = TGpuVkUse.ColorTarget then
    C.MemoryBarrier(StageColorOutput, AccessColorWrite, StageColorOutput, AccessColorRead or AccessColorWrite);
  if (D <> nil) and (DepthWas = TGpuVkUse.DepthTarget) then
    C.MemoryBarrier(StageLateTests, AccessDepthWrite, StageEarlyTests or StageLateTests,
      AccessDepthRead or AccessDepthWrite);
  FillChar(Color, SizeOf(Color), 0);
  Color.sType := VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO;
  Color.imageView := T.GpuView;
  Color.imageLayout := VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
  Color.resolveMode := VK_RESOLVE_MODE_NONE;
  Color.loadOp := VK_ATTACHMENT_LOAD_OP_LOAD;
  Color.storeOp := VK_ATTACHMENT_STORE_OP_STORE;
  if (AClear <> nil) and AClear.ClearColor then
  begin
    Color.loadOp := VK_ATTACHMENT_LOAD_OP_CLEAR;
    Move(AClear.Color, Color.clearValue.color.float32, SizeOf(AClear.Color));
  end;
  FillChar(Info, SizeOf(Info), 0);
  Info.sType := VK_STRUCTURE_TYPE_RENDERING_INFO;
  Info.renderArea.extent.width := Max(R.Width, 1);
  Info.renderArea.extent.height := Max(R.Height, 1);
  Info.layerCount := 1;
  Info.colorAttachmentCount := 1;
  Info.pColorAttachments := @Color;
  if D <> nil then
  begin
    FillChar(Depth, SizeOf(Depth), 0);
    Depth.sType := VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO;
    Depth.imageView := D.View;
    Depth.imageLayout := VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;
    Depth.resolveMode := VK_RESOLVE_MODE_NONE;
    Depth.loadOp := VK_ATTACHMENT_LOAD_OP_LOAD;
    Depth.storeOp := VK_ATTACHMENT_STORE_OP_STORE;
    Stencil := Depth;
    if AClear <> nil then
    begin
      Depth.clearValue.depthStencil.depth := AClear.DepthValue;
      Depth.clearValue.depthStencil.stencil := AClear.Stencil;
      Stencil.clearValue := Depth.clearValue;
      if AClear.ClearDepth then
        Depth.loadOp := VK_ATTACHMENT_LOAD_OP_CLEAR;
      if AClear.ClearStencil then
        Stencil.loadOp := VK_ATTACHMENT_LOAD_OP_CLEAR;
    end;
    Info.pDepthAttachment := @Depth;
    Info.pStencilAttachment := @Stencil;
  end;
  C.BeginRenderingInfo(T, Info, T.Format, T.Samples);
  R.RenderDepth := D;
end;

procedure HandleTarget(const AData: Pointer);
var
  C: PCmdTarget;
begin
  C := AData;
  R.Target := TTextureVk(C.Target);
  if C.Depth <> nil then
    R.Depth := TTextureVk(C.Depth)
  else
    R.Depth := nil;
  R.Width := C.Width;
  R.Height := C.Height;
  // Rendering begins with the first clear or draw.
  R.RenderDepth := nil;
  R.ViewportW := -1;
end;

procedure HandleClear(const AData: Pointer);
var
  C: PCmdClear;
  Ctx: TGpuVkContext;
  T, D: TTextureVk;
  Attachments: array[0..1] of TVkClearAttachment;
  Rect: TVkClearRect;
  N: Integer;
  Color: TVkClearColorValue;
  Rg: TVkImageSubresourceRange;
begin
  C := AData;
  Ctx := Begin3D;
  T := C.Target;
  D := C.Depth;
  if (R.Target = nil) or (T <> TTextureVk(R.Target as TObject)) then
  begin
    // Not the target of the commands (never so far): a clear of its color outside rendering.
    if (T = nil) or not C.ClearColor or (T.GpuImage = VK_NULL_HANDLE) then
      Exit;
    T.UseAs(TGpuVkUse.TransferDst, True);
    Move(C.Color, Color.float32, SizeOf(C.Color));
    Rg := ColorRange;
    Ctx.Vk.CmdClearColorImage(Ctx.TransferCmd, T.GpuImage, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, @Color, 1, @Rg);
    Exit;
  end;
  if (Ctx.Rendering = T) and (R.RenderDepth = D) and not Ctx.HasBarriers then
  begin
    // Inside rendering: the attachments are cleared where they are.
    FillChar(Attachments, SizeOf(Attachments), 0);
    N := 0;
    if C.ClearColor then
    begin
      Attachments[N].aspectMask := Ord(VK_IMAGE_ASPECT_COLOR_BIT);
      Attachments[N].colorAttachment := 0;
      Move(C.Color, Attachments[N].clearValue.color.float32, SizeOf(C.Color));
      Inc(N);
    end;
    if (D <> nil) and (C.ClearDepth or C.ClearStencil) then
    begin
      if C.ClearDepth then
        Attachments[N].aspectMask := Ord(VK_IMAGE_ASPECT_DEPTH_BIT);
      if C.ClearStencil then
        Attachments[N].aspectMask := Attachments[N].aspectMask or Ord(VK_IMAGE_ASPECT_STENCIL_BIT);
      Attachments[N].clearValue.depthStencil.depth := C.DepthValue;
      Attachments[N].clearValue.depthStencil.stencil := C.Stencil;
      Inc(N);
    end;
    if N = 0 then
      Exit;
    FillChar(Rect, SizeOf(Rect), 0);
    Rect.rect.extent.width := Max(R.Width, 1);
    Rect.rect.extent.height := Max(R.Height, 1);
    Rect.layerCount := 1;
    Ctx.Vk.CmdClearAttachments(Ctx.Cmd, N, @Attachments[0], 1, @Rect);
  end
  else
    EnsureRendering(C);
end;

/// <summary>ABytes of constants (AData, ALen bytes recorded) into upload memory for the open command buffer, zeroed
/// up to the shader's uniform block (ABlock).</summary>
procedure UploadConstants(const C: TGpuVkContext; const AData: TBytes; const ALen, ABlock: Integer;
  out ABuffer: TVkBuffer; out AOffset: UInt64);
var
  Size, N: Integer;
  P: PByte;
begin
  Size := AlignUp(Max(ABlock, 16), 16);
  P := C.Upload(Size, C.UniformAlign, ABuffer, AOffset);
  N := Min(ALen, Size);
  if N > 0 then
    Move(AData[0], P^, N);
  if N < Size then
    FillChar((P + N)^, Size - N, 0);
end;

procedure HandleDraw(const AData: Pointer);
var
  C: PCmdDraw;
  Ctx: TGpuVkContext;
  Cmd: TVkCommandBuffer;
  Src, P: PByte;
  VBuf, IBuf: TVkBuffer;
  VOff, IOff: UInt64;
  I: Integer;
  U: TTextureVk;
  View: TVkImageView;
  Viewport: TVkViewport;
  Scissor: TVkRect2D;
  Buffers: array[0..1] of TVkDescriptorBufferInfo;
  Images: array[0..MaxUnits - 1] of TVkDescriptorImageInfo;
  Writes: array[0..2] of TVkWriteDescriptorSet;
  DescSet: TVkDescriptorSet;
begin
  C := AData;
  Ctx := Begin3D;
  if R.Target = nil then
    Exit;
  if not G.BlankReady then
    EnsureBlank;
  // What the draw reads in the state it needs (the barriers go before rendering begins).
  for I := 0 to C.UnitCount - 1 do
    TTextureVk(C.Units[I]).UseAs(TGpuVkUse.ShaderRead);
  EnsureRendering(nil);
  Cmd := Ctx.Cmd;
  if C.Pipe <> R.Pipe then
  begin
    Ctx.Vk.CmdBindPipeline(Cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, C.Pipe);
    R.Pipe := C.Pipe;
  end;
  if (R.ViewportW <> R.Width) or (R.ViewportH <> R.Height) then
  begin
    // Negative height: y down in the target, as Direct3D's clip space maps it.
    Viewport.x := 0;
    Viewport.y := R.Height;
    Viewport.width := R.Width;
    Viewport.height := -R.Height;
    Viewport.minDepth := 0;
    Viewport.maxDepth := 1;
    Ctx.Vk.CmdSetViewport(Cmd, 0, 1, @Viewport);
    R.ViewportW := R.Width;
    R.ViewportH := R.Height;
  end;
  if C.Scissor <> R.Scissor then
  begin
    Scissor.offset.x := EnsureRange(C.Scissor.Left, 0, Max(R.Width, 1));
    Scissor.offset.y := EnsureRange(C.Scissor.Top, 0, Max(R.Height, 1));
    Scissor.extent.width := Max(0, Min(C.Scissor.Right, R.Width) - Scissor.offset.x);
    Scissor.extent.height := Max(0, Min(C.Scissor.Bottom, R.Height) - Scissor.offset.y);
    Ctx.Vk.CmdSetScissor(Cmd, 0, 1, @Scissor);
    R.Scissor := C.Scissor;
  end;
  if C.StencilRef <> R.StencilRef then
  begin
    Ctx.Vk.CmdSetStencilReference(Cmd, Ord(VK_STENCIL_FACE_FRONT_AND_BACK), C.StencilRef);
    R.StencilRef := C.StencilRef;
  end;
  Src := PByte(C) + SizeOf(TCmdDraw);
  P := Ctx.Upload(C.VertexBytes, 16, VBuf, VOff);
  Move(Src^, P^, C.VertexBytes);
  Inc(Src, C.VertexBytes);
  P := Ctx.Upload(C.IndexBytes, 16, IBuf, IOff);
  Move(Src^, P^, C.IndexBytes);
  Inc(Src, AlignUp(C.IndexBytes, 4));
  if C.VSBytes > 0 then
  begin
    if Length(R.VS) < C.VSBytes then
      SetLength(R.VS, C.VSBytes);
    Move(Src^, R.VS[0], C.VSBytes);
    R.VSLen := C.VSBytes;
    R.VSBound := -1;
    Inc(Src, C.VSBytes);
  end;
  if C.PSBytes > 0 then
  begin
    if Length(R.PS) < C.PSBytes then
      SetLength(R.PS, C.PSBytes);
    Move(Src^, R.PS[0], C.PSBytes);
    R.PSLen := C.PSBytes;
    R.PSBound := -1;
  end;
  if R.VSBound <> C.VSBlock then
  begin
    UploadConstants(Ctx, R.VS, R.VSLen, C.VSBlock, R.VSBuf, R.VSOff);
    R.VSBound := C.VSBlock;
    R.Pushed := False;
  end;
  if R.PSBound <> C.PSBlock then
  begin
    UploadConstants(Ctx, R.PS, R.PSLen, C.PSBlock, R.PSBuf, R.PSOff);
    R.PSBound := C.PSBlock;
    R.Pushed := False;
  end;
  if R.Pushed and ((C.UnitCount <> R.UnitCount) or (C.Filters <> R.Filters)) then
    R.Pushed := False;
  if R.Pushed then
    for I := 0 to C.UnitCount - 1 do
      if TTextureVk(C.Units[I]).Id <> R.UnitIds[I] then
      begin
        R.Pushed := False;
        Break;
      end;
  if not R.Pushed then
  begin
    Buffers[0].buffer := R.VSBuf;
    Buffers[0].offset := R.VSOff;
    Buffers[0].range := AlignUp(Max(C.VSBlock, 16), 16);
    Buffers[1].buffer := R.PSBuf;
    Buffers[1].offset := R.PSOff;
    Buffers[1].range := AlignUp(Max(C.PSBlock, 16), 16);
    for I := 0 to MaxUnits - 1 do
    begin
      View := VK_NULL_HANDLE;
      if I < C.UnitCount then
      begin
        U := TTextureVk(C.Units[I]);
        View := U.GpuView;
        R.UnitIds[I] := U.Id;
        Images[I].sampler := G.Samplers[(C.Filters shr (2 * I)) and 3];
      end
      else
        Images[I].sampler := G.Samplers[3];
      if View = VK_NULL_HANDLE then
        View := G.Blank.View;
      Images[I].imageView := View;
      Images[I].imageLayout := VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    end;
    FillChar(Writes, SizeOf(Writes), 0);
    for I := 0 to High(Writes) do
      Writes[I].sType := VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    // One write per stage: consecutive bindings in one write must share their stages.
    Writes[0].dstBinding := BindingVS;
    Writes[0].descriptorCount := 1;
    Writes[0].descriptorType := VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    Writes[0].pBufferInfo := @Buffers[0];
    Writes[1].dstBinding := BindingPS;
    Writes[1].descriptorCount := 1;
    Writes[1].descriptorType := VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    Writes[1].pBufferInfo := @Buffers[1];
    Writes[2].dstBinding := BindingUnits;
    Writes[2].descriptorCount := MaxUnits;
    Writes[2].descriptorType := VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    Writes[2].pImageInfo := @Images[0];
    if G.Push then
      Ctx.Vk.CmdPushDescriptorSetKHR(Cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, G.Layout, 0, Length(Writes), @Writes[0])
    else
    begin
      // Without push descriptors: a set of the open command buffer's pool (released with it), written and bound.
      DescSet := Ctx.AllocSet(G.SetLayout);
      for I := 0 to High(Writes) do
        Writes[I].dstSet := DescSet;
      Ctx.Vk.UpdateDescriptorSets(Ctx.Device, Length(Writes), @Writes[0], 0, nil);
      Ctx.Vk.CmdBindDescriptorSets(Cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, G.Layout, 0, 1, @DescSet, 0, nil);
    end;
    R.UnitCount := C.UnitCount;
    R.Filters := C.Filters;
    R.Pushed := True;
  end;
  Ctx.Vk.CmdBindVertexBuffers(Cmd, 0, 1, @VBuf, @VOff);
  if C.Index32 then
    Ctx.Vk.CmdBindIndexBuffer(Cmd, IBuf, IOff, VK_INDEX_TYPE_UINT32)
  else
    Ctx.Vk.CmdBindIndexBuffer(Cmd, IBuf, IOff, VK_INDEX_TYPE_UINT16);
  Ctx.Vk.CmdDrawIndexed(Cmd, C.IndexCount, 1, 0, 0, 0);
  RayAfterDraw(Ctx, C, VBuf, VOff, IBuf, IOff);
end;

procedure HandleCopy(const AData: Pointer);
var
  C: PCmdCopy;
  Ctx: TGpuVkContext;
  S, D: TTextureVk;
  Region: TVkImageCopy;
  Blit: TVkImageBlit;
begin
  C := AData;
  S := C.Source;
  D := C.Dest;
  if (S.GpuImage = VK_NULL_HANDLE) or (D.GpuImage = VK_NULL_HANDLE) or C.Rect.IsEmpty then
    Exit;
  Ctx := GpuVk;
  S.UseAs(TGpuVkUse.TransferSrc);
  // A copy into it before (it stays in TransferDst): the writes are ordered by a barrier of their own.
  if D.CurrentUse = TGpuVkUse.TransferDst then
    Ctx.MemoryBarrier(StageTransfer, AccessTransferWrite, StageTransfer, AccessTransferWrite);
  D.UseAs(TGpuVkUse.TransferDst);
  if S.Format = D.Format then
  begin
    FillChar(Region, SizeOf(Region), 0);
    Region.srcSubresource := ColorLayers;
    Region.srcOffset.x := C.Rect.Left;
    Region.srcOffset.y := C.Rect.Top;
    Region.dstSubresource := ColorLayers;
    Region.dstOffset.x := C.X;
    Region.dstOffset.y := C.Y;
    Region.extent.width := C.Rect.Width;
    Region.extent.height := C.Rect.Height;
    Region.extent.depth := 1;
    Ctx.Vk.CmdCopyImage(Ctx.TransferCmd, S.GpuImage, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, D.GpuImage,
      VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, @Region);
  end
  else
  begin
    // Another format (an RGBA texture into a bitmap): converted one to one.
    FillChar(Blit, SizeOf(Blit), 0);
    Blit.srcSubresource := ColorLayers;
    Blit.srcOffsets[0].x := C.Rect.Left;
    Blit.srcOffsets[0].y := C.Rect.Top;
    Blit.srcOffsets[1].x := C.Rect.Right;
    Blit.srcOffsets[1].y := C.Rect.Bottom;
    Blit.srcOffsets[1].z := 1;
    Blit.dstSubresource := ColorLayers;
    Blit.dstOffsets[0].x := C.X;
    Blit.dstOffsets[0].y := C.Y;
    Blit.dstOffsets[1].x := C.X + C.Rect.Width;
    Blit.dstOffsets[1].y := C.Y + C.Rect.Height;
    Blit.dstOffsets[1].z := 1;
    Ctx.Vk.CmdBlitImage(Ctx.TransferCmd, S.GpuImage, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, D.GpuImage,
      VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, @Blit, VK_FILTER_NEAREST);
  end;
end;

procedure HandleResolve(const AData: Pointer);
var
  C: PCmdResolve;
  Ctx: TGpuVkContext;
  S, D: TTextureVk;
  Region: TVkImageResolve;
begin
  C := AData;
  S := C.Source;
  D := C.Dest;
  if (S.GpuImage = VK_NULL_HANDLE) or (D.GpuImage = VK_NULL_HANDLE) then
    Exit;
  Ctx := GpuVk;
  S.UseAs(TGpuVkUse.TransferSrc);
  if D.CurrentUse = TGpuVkUse.TransferDst then
    Ctx.MemoryBarrier(StageTransfer, AccessTransferWrite, StageTransfer, AccessTransferWrite);
  D.UseAs(TGpuVkUse.TransferDst, True);
  FillChar(Region, SizeOf(Region), 0);
  Region.srcSubresource := ColorLayers;
  Region.dstSubresource := ColorLayers;
  Region.extent.width := Min(S.Width, D.Width);
  Region.extent.height := Min(S.Height, D.Height);
  Region.extent.depth := 1;
  Ctx.Vk.CmdResolveImage(Ctx.TransferCmd, S.GpuImage, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, D.GpuImage,
    VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, @Region);
end;

/// <summary>Device lock held: every level of a texture into the open command buffer.</summary>
procedure HandleUploadData(const T: TTextureVk; const B: TBlob; const ABytesPerPixel: Integer);
var
  Src: PByte;
  Level, W, H: Integer;
begin
  if T.Image = VK_NULL_HANDLE then
    Exit;
  Src := @B.Data[0];
  W := T.Width;
  H := T.Height;
  // All levels at once (the copies keep the image in TransferDst).
  T.UseAs(TGpuVkUse.TransferDst, True);
  for Level := 0 to T.Mips - 1 do
  begin
    GpuVk.CopyToImage(T.Image, T.Use, ABytesPerPixel, 0, 0, W, H, Src, W * ABytesPerPixel, Level);
    Inc(Src, NativeInt(W) * H * ABytesPerPixel);
    W := Max(1, W div 2);
    H := Max(1, H div 2);
  end;
  T.UseAs(TGpuVkUse.ShaderRead);
end;

procedure HandleUpload(const AData: Pointer);
var
  C: PCmdUpload;
begin
  C := AData;
  HandleUploadData(C.Texture, C.Blob, C.BytesPerPixel);
end;

procedure HandleReadback(const AData: Pointer);
var
  C: PCmdReadback;
  Ctx: TGpuVkContext;
  S: TTextureVk;
  Region: TVkBufferImageCopy;
begin
  C := AData;
  S := C.Source;
  if S.GpuImage = VK_NULL_HANDLE then
    Exit;
  Ctx := GpuVk;
  S.UseAs(TGpuVkUse.TransferSrc);
  FillChar(Region, SizeOf(Region), 0);
  Region.imageSubresource := ColorLayers;
  Region.imageOffset.x := C.Rect.Left;
  Region.imageOffset.y := C.Rect.Top;
  Region.imageExtent.width := C.Rect.Width;
  Region.imageExtent.height := C.Rect.Height;
  Region.imageExtent.depth := 1;
  Ctx.Vk.CmdCopyImageToBuffer(Ctx.TransferCmd, S.GpuImage, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, C.Buffer, 1,
    @Region);
  // The copy's writes are for the host to read.
  Ctx.MemoryBarrier(StageTransfer, AccessTransferWrite, StageHost, AccessHostRead);
end;

procedure HandleFrame(const AData: Pointer);
var
  C: PCmdFrame;
  T: TTextureVk;
  Output: TGpuOutput;
begin
  C := AData;
  T := C.Texture;
  // The window's surface for this frame (8-bit; presented with tearing allowed, as the Direct3D 12 context does).
  Output := Default(TGpuOutput);
  T.WindowSurface := TGpuVkSurface(T.Window.Prepare(C.Width, C.Height, True, Output));
end;

procedure HandlePresent(const AData: Pointer);
var
  C: PCmdPresent;
  T: TTextureVk;
begin
  C := AData;
  T := C.Texture;
  // The window's surface is not drawn into any more.
  R.Target := nil;
  R.Depth := nil;
  GpuVk.EndRendering;
  // A lost device is found by the canvas at its next scene (TFastDevice.RemovedReason).
  T.Window.Present;
end;

/// <summary>Forgets the render-thread state (after a Sync: the render thread is idle).</summary>
procedure ClearReplay;
begin
  TFastDevice.Lock;
  try
    RayClear;
    R.Target := nil;
    R.Depth := nil;
    R.RenderDepth := nil;
    R.Pipe := VK_NULL_HANDLE;
    R.Ctx := nil;
    R.ListGen := -1;
    R.Pushed := False;
    R.VSBound := -1;
    R.PSBound := -1;
  finally
    TFastDevice.Unlock;
  end;
end;

var
  GSceneSerial: Integer;

procedure RunPendingReset; forward;

{ TFastContext3DVk }

constructor TFastContext3DVk.CreateFromWindow(const AParent: TWindowHandle; const AWidth, AHeight: Single;
  const AMultisample: TMultisample; const ADepthStencil: Boolean);
begin
  inherited;
  FRay := FastContext3DRayTracing;
  GContexts.Add(Self);
  CreateBuffer;
end;

constructor TFastContext3DVk.CreateFromTexture(const ATexture: TTexture; const AMultisample: TMultisample;
  const ADepthStencil: Boolean);
begin
  inherited;
  FRay := FastContext3DRayTracing;
  GContexts.Add(Self);
  CreateBuffer;
end;

destructor TFastContext3DVk.Destroy;
begin
  if GContexts <> nil then
  begin
    GContexts.Remove(Self);
    GScenes.Remove(Self);
  end;
  inherited;
end;

class function TFastContext3DVk.Valid: Boolean;
var
  V: TFastVulkan;
begin
  TFastDevice.Ensure;
  V := TFastDevice.Vulkan;
  Result := (V <> nil) and (V.DepthFormat <> VK_FORMAT_UNDEFINED);
end;

class function TFastContext3DVk.RayTracingSupported: Boolean;
begin
  Result := RaySupported;
end;

class function TFastContext3DVk.Style: TContextStyles;
begin
  if FastContext3DFragile then
    Result := [TContextStyle.Fragile]
  else
    Result := [];
end;

function TFastContext3DVk.TargetPixels: TSize;
begin
  if Texture <> nil then
    Result := TSize.Create(Texture.Width, Texture.Height)
  else
    Result := TSize.Create(Max(1, Round(Width * Scale)), Max(1, Round(Height * Scale)));
end;

procedure TFastContext3DVk.CreateTargets;
var
  S: TShared;
  Px: TSize;
  T: TTextureVk;
  Alpha: Boolean;
  Wanted: Integer;
  Counts: TVkSampleCountFlags;
begin
  S := Shared;
  Px := TargetPixels;
  if Texture = nil then
  begin
    // A window (TForm3D): frames are drawn into the frame surface of a window of the canvas back end, which presents
    // them on a thread of its own.
    FWindowHandle := FastWindowOf(Parent);
    FWindow := TGpuVkWindow.Create(FWindowHandle, False);
    T := TTextureVk.Create;
    T.Id := AtomicIncrement(GNextTextureId);
    T.Window := TGpuVkWindow(FWindow);
    T.Format := VK_FORMAT_B8G8R8A8_UNORM;
    T.Width := Px.Width;
    T.Height := Px.Height;
    T.Mips := 1;
    T.Samples := 1;
    FFrame := T;
    FFormat := Ord(VK_FORMAT_B8G8R8A8_UNORM);
  end
  else
  begin
    FFormat := Ord(VkFormatOf(Texture.PixelFormat, Alpha));
    if FFormat = Ord(VK_FORMAT_UNDEFINED) then
      FFormat := Ord(VK_FORMAT_B8G8R8A8_UNORM);
  end;
  case Multisample of
    TMultisample.TwoSamples: Wanted := 2;
    TMultisample.FourSamples: Wanted := 4;
  else
    Wanted := 1;
  end;
  Counts := S.Fast.Properties.limits.framebufferColorSampleCounts and
    S.Fast.Properties.limits.framebufferDepthSampleCounts;
  while (Wanted > 1) and ((Counts and Cardinal(Wanted)) = 0) do
    Wanted := Wanted div 2;
  FSamples := Wanted;
  if FSamples > 1 then
    FMSColor := NewTextureVk(Px.Width, Px.Height, 1, FSamples, TVkFormat(FFormat),
      Ord(VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT) or Ord(VK_IMAGE_USAGE_TRANSFER_SRC_BIT));
  if DepthStencil then
    FDepth := NewTextureVk(Px.Width, Px.Height, 1, FSamples, S.DepthFormat,
      Ord(VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT) or Ord(VK_IMAGE_USAGE_SAMPLED_BIT), True);
end;

procedure TFastContext3DVk.DoCreateBuffer;
begin
  CreateTargets;
end;

procedure TFastContext3DVk.DoResize;
begin
end;

procedure TFastContext3DVk.DoFreeBuffer;
begin
  if FWindow <> nil then
  begin
    // The window goes only when nothing refers to it, the render thread included.
    if Assigned(FastBridge.Sync) then
      FastBridge.Sync();
    ClearReplay;
  end;
  FFrame := nil;
  FMSColor := nil;
  FDepth := nil;
  FreeAndNil(FWindow);
  // After the window: its surface is made from the native window.
  FastReleaseWindow(FWindowHandle);
end;

function TFastContext3DVk.DrawTarget: TObject;
begin
  if FMSColor <> nil then
    Exit(FMSColor as TObject);
  if FFrame <> nil then
    Exit(FFrame as TObject);
  Result := nil;
  if (Texture <> nil) and (Texture.Handle <> 0) then
    Result := TTextureVk(Texture.Handle);
end;

/// <summary>Records the target of this context as the target of the commands that follow.</summary>
procedure TFastContext3DVk.RecordTarget;
var
  T: TTextureVk;
  C: PCmdTarget;
  Px: TSize;
begin
  T := TTextureVk(DrawTarget);
  if T = nil then
    Exit;
  Px := TargetPixels;
  T.Used := True;
  C := Rec(HandleTarget, SizeOf(TCmdTarget), T);
  C.Target := T;
  C.Depth := nil;
  if FDepth <> nil then
  begin
    C.Depth := FDepth as TObject;
    Keep(FDepth);
  end;
  C.Width := Px.Width;
  C.Height := Px.Height;
  FScissorDirty := True;
end;

function TFastContext3DVk.DoBeginScene: Boolean;
var
  F: PCmdFrame;
  Px: TSize;
begin
  RunPendingReset;
  Result := (DrawTarget <> nil) and inherited DoBeginScene;
  if not Result then
    Exit;
  GScenes.Add(Self);
  if FFrame <> nil then
  begin
    Px := TargetPixels;
    F := Rec(HandleFrame, SizeOf(TCmdFrame), FFrame);
    F.Texture := FFrame as TObject;
    F.Width := Px.Width;
    F.Height := Px.Height;
  end;
  RecordTarget;
  // The render thread keeps the constants it was sent: send them again for this scene's shaders.
  FVSDirty := True;
  FPSDirty := True;
  // Ray-traced effects need a depth buffer (the surfaces of the pixels) and the hardware.
  FScene := 0;
  FRayObjects := 0;
  if (FRay.Shadows or FRay.AmbientOcclusion or FRay.Reflections) and (FDepth <> nil) and RaySupported then
  begin
    Inc(GSceneSerial);
    FScene := GSceneSerial;
  end;
end;

procedure TFastContext3DVk.DoEndScene;
var
  T: TTextureVk;
  C: PCmdResolve;
  P: PCmdPresent;
begin
  // Where the scene ends: the window's frame, the texture.
  T := nil;
  if FFrame <> nil then
    T := TTextureVk(FFrame as TObject)
  else if (Texture <> nil) and (Texture.Handle <> 0) then
    T := TTextureVk(Texture.Handle);
  if (FScene <> 0) and (FRayObjects > 0) and ((FRay.Shadows and (Lights.Count > 0)) or FRay.AmbientOcclusion or
    FRay.Reflections) then
    RecordRay;
  FScene := 0;
  if (FMSColor <> nil) and (T <> nil) then
  begin
    C := Rec(HandleResolve, SizeOf(TCmdResolve), FMSColor);
    C.Source := FMSColor as TObject;
    C.Dest := T;
    T.Used := True;
    Keep(T);
  end;
  GScenes.Remove(Self);
  if GScenes.Count > 0 then
    GScenes.Last.RecordTarget;
  if (FFrame <> nil) and (BeginSceneCount = 1) then
  begin
    // Presented where the canvas executes its commands, after them; the window's thread shows it. The next scene
    // waits for this one, as with Direct3D 12.
    P := Rec(HandlePresent, SizeOf(TCmdPresent), FFrame);
    P.Texture := FFrame as TObject;
    FastBridge.Sync();
  end;
  inherited;
end;

procedure TFastContext3DVk.DoClear(const ATarget: TClearTargets; const AColor: TAlphaColor; const ADepth: Single;
  const AStencil: Cardinal);
var
  C: PCmdClear;
  T: TTextureVk;
begin
  T := TTextureVk(DrawTarget);
  if T = nil then
    Exit;
  C := Rec(HandleClear, SizeOf(TCmdClear), T);
  C.Target := T;
  C.Depth := nil;
  if FDepth <> nil then
  begin
    C.Depth := FDepth as TObject;
    Keep(FDepth);
  end;
  C.ClearColor := TClearTarget.Color in ATarget;
  if C.ClearColor then
    FClearColor := AColor;
  C.Color[0] := TAlphaColorRec(AColor).R / 255;
  C.Color[1] := TAlphaColorRec(AColor).G / 255;
  C.Color[2] := TAlphaColorRec(AColor).B / 255;
  C.Color[3] := TAlphaColorRec(AColor).A / 255;
  C.ClearDepth := (TClearTarget.Depth in ATarget) and (FDepth <> nil);
  C.ClearStencil := (TClearTarget.Stencil in ATarget) and (FDepth <> nil);
  C.DepthValue := ADepth;
  C.Stencil := Byte(AStencil);
end;

var
  /// <summary>TFastShader.Id: its entry of VkFmxShaders (shader modules are made again after a device loss).
  /// </summary>
  GShaderEntries: TDictionary<Integer, Integer>;

/// <summary>The shader module of a shader's entry of VkFmxShaders.</summary>
function NewShaderVk(const AEntry: Integer): TShaderVk;
var
  F: TFastVulkan;
  Info: TVkShaderModuleCreateInfo;
begin
  GpuVk;
  F := TFastDevice.Vulkan;
  Result := TShaderVk.Create;
  try
    Result.Block := VkFmxShaders[AEntry].Block;
    Result.Inputs := VkFmxShaders[AEntry].Inputs;
    FillChar(Info, SizeOf(Info), 0);
    Info.sType := VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
    Info.codeSize := VkFmxShaders[AEntry].Count * 4;
    Info.pCode := @VkFmxWords[VkFmxShaders[AEntry].First];
    Check(F.Vk.CreateShaderModule(F.Device, @Info, nil, @Result.Module), 'vkCreateShaderModule');
    AddLive(Result);
  except
    Result.Free;
    raise;
  end;
end;

/// <summary>The shader module of a shader, made again when the device was replaced; nil without SPIR-V.</summary>
function ShaderObject(const AShader: TFastShader): TShaderVk;
var
  Entry: Integer;
begin
  if AShader.Native = nil then
  begin
    if (GShaderEntries = nil) or not GShaderEntries.TryGetValue(AShader.Id, Entry) then
      Exit(nil);
    AShader.Native := NewShaderVk(Entry);
  end;
  Result := TShaderVk(AShader.Native as TObject);
end;

procedure TFastContext3DVk.DoDrawPrimitivesBatch(const AKind: TPrimitivesKind; const Vertices, Indices: Pointer;
  const VertexDeclaration: TVertexDeclaration; const VertexSize, VertexCount, IndexSize, IndexCount: Integer);
var
  S: TShared;
  T: TTextureVk;
  VS, PS: TShaderVk;
  Key: TPipeKey;
  Layout: TFastVertexLayout;
  C: PCmdDraw;
  VBytes, IBytes, VSBytes, PSBytes, I, N: Integer;
  Dst: PByte;
  Px: TSize;
  Offsets: TLayoutOffsets;
begin
  if (FVS = nil) or (FPS = nil) or (VertexCount <= 0) or (IndexCount <= 0) then
    Exit;
  T := TTextureVk(DrawTarget);
  if T = nil then
    Exit;
  VS := ShaderObject(FVS);
  PS := ShaderObject(FPS);
  if (VS = nil) or (PS = nil) then
    Exit;
  S := Shared;
  Layout := S.Layout_(VertexDeclaration, Offsets);
  FillChar(Key, SizeOf(Key), 0);
  Key.VS := FVS.Id;
  Key.PS := FPS.Id;
  Key.Layout := Layout.Hash;
  Key.Stride := VertexSize;
  Key.State := FState;
  // Scissor and stencil reference are not part of a pipeline.
  Key.State.Scissor := False;
  Key.Topology := Ord(AKind);
  Key.Samples := T.Samples;
  Key.Depth := FDepth <> nil;
  Key.Format := Ord(T.Format);
  VBytes := VertexSize * VertexCount;
  IBytes := IndexSize * IndexCount;
  VSBytes := 0;
  if FVSDirty then
    VSBytes := Length(FVSData);
  PSBytes := 0;
  if FPSDirty then
    PSBytes := Length(FPSData);
  // An opaque object of a scene with ray-traced effects: drawn in world space (not a 2D layer drawn in screen space),
  // with depth test and write, with float3 positions. Recorded before the draw, which brings the vertices.
  if (FScene <> 0) and (AKind = TPrimitivesKind.Triangles) and FState.DepthTest and FState.DepthWrite and
    (Offsets.Position >= 0) and CurrentStates[TContextState.cs3DScene] and
    not CurrentStates[TContextState.cs2DScene] then
    RecordRayObject(Vertices, Indices, VertexSize, VertexCount, IndexSize, IndexCount, Offsets.Position,
      Offsets.Normal, Offsets.TexCoord);
  C := Rec(HandleDraw, SizeOf(TCmdDraw) + VBytes + AlignUp(IBytes, 4) + VSBytes + PSBytes);
  C.Pipe := S.Pipe(Key, Layout);
  C.StencilRef := FStencilRef;
  if FState.Scissor then
    C.Scissor := FScissor
  else
  begin
    Px := TargetPixels;
    C.Scissor := TRect.Create(0, 0, Px.Width, Px.Height);
  end;
  C.VertexBytes := VBytes;
  C.IndexBytes := IBytes;
  C.VertexStride := VertexSize;
  C.IndexCount := IndexCount;
  C.Index32 := IndexSize = SizeOf(Cardinal);
  C.VSBytes := VSBytes;
  C.PSBytes := PSBytes;
  C.VSBlock := Max(VS.Block, Length(FVSData));
  C.PSBlock := Max(PS.Block, Length(FPSData));
  N := Min(FPS.TextureUnits, MaxUnits);
  C.UnitCount := N;
  C.Filters := 0;
  for I := 0 to MaxUnits - 1 do
    if I < N then
    begin
      if FUnits[I] <> nil then
      begin
        C.Units[I] := FUnits[I] as TObject;
        TTextureVk(C.Units[I]).Used := True;
        Keep(FUnits[I]);
      end
      else
        C.Units[I] := S.Blank;
      C.Filters := C.Filters or (Cardinal(FUnitFilters[I] and 3) shl (2 * I));
    end
    else
      C.Units[I] := nil;
  Dst := PByte(C) + SizeOf(TCmdDraw);
  Move(Vertices^, Dst^, VBytes);
  Inc(Dst, VBytes);
  Move(Indices^, Dst^, IBytes);
  Inc(Dst, AlignUp(IBytes, 4));
  if VSBytes > 0 then
  begin
    Move(FVSData[0], Dst^, VSBytes);
    Inc(Dst, VSBytes);
    FVSDirty := False;
  end;
  if PSBytes > 0 then
  begin
    Move(FPSData[0], Dst^, PSBytes);
    FPSDirty := False;
  end;
end;

{ Textures }

class function TFastContext3DVk.TextureObject(const ATexture: TTexture): IInterface;
begin
  if ATexture.Handle = 0 then
    ATexture.Initialize;
  if ATexture.Handle <> 0 then
    Result := TTextureVk(ATexture.Handle)
  else
    Result := nil;
end;

class procedure TFastContext3DVk.DoInitializeTexture(const Texture: TTexture);
var
  T: TTextureVk;
  Format: TVkFormat;
  Alpha: Boolean;
  Mips: Integer;
  Usage: TVkImageUsageFlags;
begin
  if (Texture.Width <= 0) or (Texture.Height <= 0) then
    Exit;
  if Texture.PixelFormat = TPixelFormat.None then
    Texture.PixelFormat := TPixelFormat.BGRA;
  Format := VkFormatOf(Texture.PixelFormat, Alpha);
  if Format = VK_FORMAT_UNDEFINED then
    raise EContext3DException.CreateFmt('FastContext3DVk: no texture format for pixel format %d',
      [Ord(Texture.PixelFormat)]);
  Mips := 1;
  if (TTextureStyle.MipMaps in Texture.Style) and CanMip(Format) then
    Mips := Floor(Log2(Max(Texture.Width, Texture.Height))) + 1;
  Usage := Ord(VK_IMAGE_USAGE_SAMPLED_BIT) or Ord(VK_IMAGE_USAGE_TRANSFER_SRC_BIT);
  // Render targets are cleared before their first use; other textures hold zeros until they are updated.
  if TTextureStyle.RenderTarget in Texture.Style then
    Usage := Usage or Ord(VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT);
  T := NewTextureVk(Texture.Width, Texture.Height, Mips, 1, Format, Usage, False, Alpha);
  if not (TTextureStyle.RenderTarget in Texture.Style) then
    T.Uncleared := True;
  IInterface(T)._AddRef;
  ITextureAccess(Texture).Handle := THandle(T);
end;

class procedure TFastContext3DVk.DoFinalizeTexture(const Texture: TTexture);
var
  T: TTextureVk;
begin
  T := TTextureVk(Texture.Handle);
  ITextureAccess(Texture).Handle := 0;
  // Commands not executed yet keep their own reference; the GPU's use is covered by the destructor.
  if T <> nil then
    IInterface(T)._Release;
end;

class procedure TFastContext3DVk.DoUpdateTexture(const Texture: TTexture; const Bits: Pointer; const Pitch: Integer);
var
  T: TTextureVk;
  B: TBlob;
  BRef: IInterface;
  Bpp, Level, W, H, NW, NH, X, Y, Ch, Sum, X0, X1, Y0, Y1, Row: Integer;
  Total, Pos, Prev: NativeInt;
  C: PCmdUpload;
begin
  if Texture.Handle = 0 then
    Texture.Initialize;
  T := TTextureVk(Texture.Handle);
  if (T = nil) or (Bits = nil) then
    Exit;
  Bpp := BytesPerPixel(T.Format);
  // Every level packed (rows of Width * Bpp): too large for the stream, so in a blob the command keeps.
  Total := 0;
  W := T.Width;
  H := T.Height;
  for Level := 0 to T.Mips - 1 do
  begin
    Inc(Total, NativeInt(W) * H * Bpp);
    W := Max(1, W div 2);
    H := Max(1, H div 2);
  end;
  B := TBlob.Create;
  BRef := B;
  SetLength(B.Data, Total);
  Row := T.Width * Bpp;
  for Y := 0 to T.Height - 1 do
    Move((PByte(Bits) + NativeInt(Y) * Pitch)^, B.Data[NativeInt(Y) * Row], Row);
  // Box filter of the level above (edge pixels repeated for odd sizes); four 8-bit channels (CanMip).
  Prev := 0;
  Pos := NativeInt(T.Width) * T.Height * Bpp;
  W := T.Width;
  H := T.Height;
  for Level := 1 to T.Mips - 1 do
  begin
    NW := Max(1, W div 2);
    NH := Max(1, H div 2);
    for Y := 0 to NH - 1 do
    begin
      Y0 := Min(2 * Y, H - 1);
      Y1 := Min(2 * Y + 1, H - 1);
      for X := 0 to NW - 1 do
      begin
        X0 := Min(2 * X, W - 1);
        X1 := Min(2 * X + 1, W - 1);
        for Ch := 0 to 3 do
        begin
          Sum := B.Data[Prev + (NativeInt(Y0) * W + X0) * 4 + Ch] + B.Data[Prev + (NativeInt(Y0) * W + X1) * 4 + Ch] +
            B.Data[Prev + (NativeInt(Y1) * W + X0) * 4 + Ch] + B.Data[Prev + (NativeInt(Y1) * W + X1) * 4 + Ch];
          B.Data[Pos + (NativeInt(Y) * NW + X) * 4 + Ch] := (Sum + 2) shr 2;
        end;
      end;
    end;
    Prev := Pos;
    Inc(Pos, NativeInt(NW) * NH * 4);
    W := NW;
    H := NH;
  end;
  if not T.Used then
  begin
    // No command refers to the texture yet (a new texture, or one made again after a device reset, in a message
    // handler on any thread): the copy goes straight into the canvas's open command buffer, under the device lock.
    TFastDevice.Lock;
    try
      T.Uncleared := False;
      HandleUploadData(T, B, Bpp);
    finally
      TFastDevice.Unlock;
    end;
    Exit;
  end;
  TCanvas.Lock;
  try
    C := Rec(HandleUpload, SizeOf(TCmdUpload), T);
    C.Texture := T;
    C.Blob := B;
    C.BytesPerPixel := Bpp;
    Keep(BRef);
  finally
    TCanvas.Unlock;
  end;
end;

class function TFastContext3DVk.DoBitmapToTexture(const Bitmap: TBitmap): TTexture;
var
  Surf: IInterface;
  S: TGpuSurface;
  T: TTextureVk;
begin
  // A bitmap of the canvas is a texture on the same device: used in place (no read-back, no upload). The caller owns
  // the TTexture (TFilterContext3D frees it, FMX.Filter.pas:1870-1872); freeing it drops this reference only.
  Surf := nil;
  if Assigned(FastBridge.BitmapSurface) then
    Surf := FastBridge.BitmapSurface(Bitmap);
  S := nil;
  if Surf <> nil then
    S := IGpuTexture(Surf).Surface;
  if not (S is TGpuVkSurface) then
    Exit(inherited DoBitmapToTexture(Bitmap));
  T := TTextureVk.Create;
  T.Id := AtomicIncrement(GNextTextureId);
  IInterface(T)._AddRef;
  try
    T.Canvas := Surf;
    T.Format := VK_FORMAT_B8G8R8A8_UNORM;
    T.Width := S.Width;
    T.Height := S.Height;
    T.Mips := 1;
    T.Samples := 1;
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

procedure TFastContext3DVk.DoCopyToBitmap(const Dest: TBitmap; const ARect: TRect);
var
  Surf: IInterface;
  Src, D: TTextureVk;
  DRef: IInterface;
  R: TRect;
  C: PCmdCopy;
begin
  // A bitmap of the canvas: a GPU copy in the command stream (the stock path reads the target into memory and
  // uploads it again). The texture holds the resolved samples once the scene has ended.
  Surf := nil;
  if Assigned(FastBridge.BitmapSurface) then
    Surf := FastBridge.BitmapSurface(Dest);
  if (Surf = nil) or (Texture = nil) or (Texture.Handle = 0) or ((FMSColor <> nil) and (BeginSceneCount > 0)) or
    not (IGpuTexture(Surf).Surface is TGpuVkSurface) then
  begin
    inherited;
    Exit;
  end;
  Src := TTextureVk(Texture.Handle);
  R := TRect.Intersect(ARect, TRect.Create(0, 0, Min(Src.Width, Dest.Width), Min(Src.Height, Dest.Height)));
  if R.IsEmpty then
    Exit;
  D := TTextureVk.Create;
  DRef := D;
  D.Id := AtomicIncrement(GNextTextureId);
  D.Canvas := Surf;
  D.Format := VK_FORMAT_B8G8R8A8_UNORM;
  D.Width := Dest.Width;
  D.Height := Dest.Height;
  D.Mips := 1;
  D.Samples := 1;
  TCanvas.Lock;
  try
    Src.Used := True;
    C := Rec(HandleCopy, SizeOf(TCmdCopy), Src);
    C.Source := Src;
    C.Dest := D;
    Keep(DRef);
    C.Rect := R;
    C.X := R.Left;
    C.Y := R.Top;
    FastBridge.BitmapWritten(Dest);
  finally
    TCanvas.Unlock;
  end;
end;

procedure TFastContext3DVk.DoCopyToBits(const Bits: Pointer; const Pitch: Integer; const ARect: TRect);
var
  Src: TTextureVk;
  Ctx: TGpuVkContext;
  Buffer: TVkBuffer;
  Memory: TFastVkAllocation;
  C: PCmdReadback;
  R: TRect;
  Y: Integer;
begin
  if Texture <> nil then
  begin
    if Texture.Handle = 0 then
      Exit;
    Src := TTextureVk(Texture.Handle);
  end
  else if FFrame <> nil then
    Src := TTextureVk(FFrame as TObject)
  else
    Exit;
  R := TRect.Intersect(ARect, TRect.Create(0, 0, Src.Width, Src.Height));
  if R.IsEmpty or (BytesPerPixel(Src.Format) <> 4) then
    Exit;
  TFastDevice.Lock;
  try
    Ctx := GpuVk;
    Buffer := Ctx.NewBuffer(UInt64(R.Width) * UInt64(R.Height) * 4, Ord(VK_BUFFER_USAGE_TRANSFER_DST_BIT),
      Ord(VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT), Ord(VK_MEMORY_PROPERTY_HOST_CACHED_BIT), Memory);
  finally
    TFastDevice.Unlock;
  end;
  try
    TCanvas.Lock;
    try
      Src.Used := True;
      C := Rec(HandleReadback, SizeOf(TCmdReadback), Src);
      C.Source := Src;
      C.Buffer := Buffer;
      C.Rect := R;
    finally
      TCanvas.Unlock;
    end;
    // Everything recorded so far runs, then the GPU finishes it.
    FastBridge.Sync();
    TGpuVkBackend.WaitIdle;
    TFastDevice.Vulkan.Invalidate(Memory);
    for Y := 0 to R.Height - 1 do
      Move((Memory.Cpu + NativeInt(Y) * R.Width * 4)^, (PByte(Bits) + NativeInt(R.Top + Y) * Pitch + R.Left * 4)^,
        R.Width * 4);
  finally
    TFastDevice.Lock;
    try
      Ctx := GpuVkCurrent;
      if Ctx <> nil then
      begin
        Ctx.Retire(TGpuVkObject.Buffer, Buffer);
        Ctx.Retire(TGpuVkObject.Memory, MemoryHandle(Memory));
      end;
    finally
      TFastDevice.Unlock;
    end;
  end;
end;

{ Shaders }

/// <summary>FNV-1a of bytes.</summary>
function Fnv(const AData: Pointer; const ASize: Integer; const AHash: UInt64 = $CBF29CE484222325): UInt64;
var
  P: PByte;
  I: Integer;
begin
  Result := AHash;
  P := AData;
  for I := 0 to ASize - 1 do
  begin
    Result := (Result xor P[I]) * UInt64($100000001B3);
  end;
end;

/// <summary>The hash of Direct3D variables as tools\compile-fmx-shaders-vk.ps1 makes it: per variable its name in
/// upper case (UTF-16), its kind, index and size.</summary>
function VariablesHash(const AVariables: TContextShaderVariables): UInt64;
var
  V: TContextShaderVariable;
  Name: string;
  N: array[0..2] of Integer;
begin
  Result := $CBF29CE484222325;
  for V in AVariables do
  begin
    Name := UpperCase(V.Name);
    if Name <> '' then
      Result := Fnv(@Name[1], Length(Name) * SizeOf(Char), Result);
    N[0] := Ord(V.Kind);
    N[1] := V.Index;
    N[2] := V.Size;
    Result := Fnv(@N[0], SizeOf(N), Result);
  end;
end;

class procedure TFastContext3DVk.DoInitializeShader(const Shader: TContextShader);
begin
  // CreateNativeShader looks the shader's GLSL source up.
  GPendingShader := Shader;
  try
    inherited;
  finally
    GPendingShader := nil;
  end;
end;

class function TFastContext3DVk.ShaderLayout(const Shader: TContextShader;
  out AVariables: TContextShaderVariables): Boolean;
var
  Glsl: TContextShaderSource;
  Hash: UInt64;
  I, J: Integer;
  V: TVkFmxVariable;
begin
  // No Direct3D source (off Windows): the entry of the GLSL source and stage (one layout per source and stage,
  // checked by tools\compile-fmx-shaders-vk.ps1) has the Direct3D variables.
  AVariables := nil;
  Result := False;
  Glsl := Shader.GetSourceByArch(TContextShaderArch.GLSL);
  if not Glsl.IsDefined or (Length(Glsl.Code) = 0) then
    Exit;
  Hash := Fnv(@Glsl.Code[0], Length(Glsl.Code));
  for I := 0 to High(VkFmxShaders) do
    if (VkFmxShaders[I].Hash = Hash) and (VkFmxShaders[I].Vertex = (Shader.Kind = TContextShaderKind.VertexShader)) then
    begin
      SetLength(AVariables, VkFmxShaders[I].VarCount);
      for J := 0 to VkFmxShaders[I].VarCount - 1 do
      begin
        V := VkFmxVariables[VkFmxShaders[I].VarFirst + J];
        AVariables[J] := TContextShaderVariable.Create(V.Name, V.Kind, V.Index, V.Size);
      end;
      Exit(True);
    end;
end;

class procedure TFastContext3DVk.CreateNativeShader(const AShader: TFastShader);
var
  Glsl: TContextShaderSource;
  Hash, Vars: UInt64;
  I, Entry: Integer;
  Name: string;
begin
  Entry := -1;
  Name := '?';
  if GPendingShader <> nil then
  begin
    Name := GPendingShader.Name;
    Glsl := GPendingShader.GetSourceByArch(TContextShaderArch.GLSL);
    if Glsl.IsDefined and (Length(Glsl.Code) > 0) then
    begin
      Hash := Fnv(@Glsl.Code[0], Length(Glsl.Code));
      // The variables FastCanvas.Context3D took: of the Direct3D source, or of ShaderLayout.
      Vars := VariablesHash(AShader.Variables);
      for I := 0 to High(VkFmxShaders) do
        if (VkFmxShaders[I].Hash = Hash) and (VkFmxShaders[I].Vars = Vars) and
          (VkFmxShaders[I].Vertex = (AShader.Kind = TContextShaderKind.VertexShader)) then
        begin
          Entry := I;
          Break;
        end;
    end;
  end;
  if Entry < 0 then
    raise EContext3DException.CreateFmt('FastContext3DVk: no SPIR-V for the shader "%s": the Vulkan 3D context runs ' +
      'the shaders of FMX''s materials and filters (FastCanvas.VkFmxShaders.inc), not shaders of applications', [Name]);
  if GShaderEntries = nil then
    GShaderEntries := TDictionary<Integer, Integer>.Create;
  GShaderEntries.AddOrSetValue(AShader.Id, Entry);
  AShader.Native := NewShaderVk(Entry);
end;

{ Device loss and installation }

/// <summary>The recording context of the canvas shuts down (device lock held, the GPU idle): every Vulkan object of
/// the 3D context goes now (textures FMX still holds keep their objects without Vulkan ones; shader modules are made
/// again when needed).</summary>
procedure DropAll(const AContext: TGpuVkContext);
var
  O: TObject;
  Live: TArray<TObject>;
begin
  R.Target := nil;
  R.Depth := nil;
  R.RenderDepth := nil;
  R.Ctx := nil;
  R.ListGen := -1;
  LockLive;
  try
    if GLive <> nil then
    begin
      Live := GLive.ToArray;
      GLive.Clear;
    end;
  finally
    UnlockLive;
  end;
  for O in Live do
    if O is TTextureVk then
      TTextureVk(O).Drop(AContext)
    else if O is TShaderVk then
    begin
      AContext.DestroyObject(TGpuVkObject.ShaderModule, TShaderVk(O).Module);
      TShaderVk(O).Module := VK_NULL_HANDLE;
    end;
  // After the textures: those that go with the ray-tracing state have nothing left to release.
  RayDrop(AContext);
  if G <> nil then
  begin
    G.Release(AContext);
    FreeAndNil(G);
  end;
end;

/// <summary>The canvas is about to replace the device (it has executed its stream; TContextLostMessage has been
/// sent: FMX finalized its fragile textures and shaders). Everything made on the old device goes, once the GPU is
/// done with it.</summary>
procedure ContextsDeviceLost;
var
  C: TFastContext3DVk;
begin
  ClearReplay;
  for C in GContexts do
    C.FreeBuffer;
  TFastContext3D.ResetShaderObjects;
  TGpuVkBackend.WaitIdle;
  if G <> nil then
  begin
    G.Release(nil);
    FreeAndNil(G);
  end;
end;

var
  /// <summary>1: the device was replaced on another thread; the contexts make their buffers on the main thread.
  /// </summary>
  GResetPending: Integer;

/// <summary>Main thread, outside any 3D scene: the contexts make their buffers on the new device, and FMX sends its
/// states again.</summary>
procedure RunPendingReset;
var
  Contexts: TArray<TFastContext3DVk>;
  C: TFastContext3DVk;
begin
  if (GResetPending = 0) or (GScenes.Count > 0) then
    Exit;
  AtomicExchange(GResetPending, 0);
  TFastContext3D.ResetDeviceState;
  TContext3D.ResetStates;
  Contexts := GContexts.ToArray;
  for C in Contexts do
    C.CreateBuffer;
end;

/// <summary>The canvas has a new device and TContextResetMessage has been sent, on whichever thread found the device
/// gone. The buffers are made on the main thread before its next 3D scene (as FastCanvas.Context3D12 does).</summary>
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
  // The canvas has shut down before (FMX.Forms.pas:8517-8519): its recording context dropped every Vulkan object
  // of this unit (DropAll).
  R.Target := nil;
  R.Depth := nil;
  R.Ctx := nil;
  R.VS := nil;
  R.PS := nil;
  TFastContext3D.ShutdownBase;
  FreeAndNil(G);
  FreeAndNil(GShaderEntries);
  if @GpuVkShutdownHook = @DropAll then
    GpuVkShutdownHook := nil;
  // The last step of FMX's shutdown (FinalizeForms): the forms and their contexts are gone.
  if (GContexts <> nil) and (GContexts.Count = 0) then
  begin
    FreeAndNil(GContexts);
    FreeAndNil(GScenes);
    FreeAndNil(GOwnerTag);
    FreeAndNil(GSharedLock);
    LockLive;
    try
      if (GLive <> nil) and (GLive.Count = 0) then
        FreeAndNil(GLive);
    finally
      UnlockLive;
    end;
  end;
end;

procedure InstallFastContext3DVk;
begin
  if GContexts = nil then
  begin
    GContexts := TList<TFastContext3DVk>.Create;
    GScenes := TList<TFastContext3DVk>.Create;
    GOwnerTag := TObject.Create;
    GSharedLock := TObject.Create;
  end;
  TFastContext3D.ResetDeviceState;
  InstallContextService(TFastContext3DVk, Shutdown);
  FastBridge.DeviceLost := ContextsDeviceLost;
  FastBridge.DeviceReset := ContextsDeviceReset;
  GpuVkShutdownHook := DropAll;
end;

initialization
{$IFDEF MSWINDOWS}
  InitializeCriticalSection(GLiveLock);
{$ELSE}
  GLiveLock := TObject.Create;
{$ENDIF}
finalization
  // Not deleted: textures and shaders may be freed after the unit finalizations (FMX frees forms later).
end.
