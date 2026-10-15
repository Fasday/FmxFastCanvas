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
  application's own shader) raises EContext3DException: not supported, unless it has a SPIR-V source of its own (raw
  draws, below). One descriptor set layout, pushed per draw
  (VK_KHR_push_descriptor; without it written into a set of the recording context's pools and bound): binding 0 the
  vertex constants, 1 the pixel constants, 2..9 the texture units with their samplers. Clip space as
  with Direct3D: the viewport flips y (negative height), FMX's projection has Direct3D's depth range.

  Targets: TViewport3D and filters draw into textures (a bitmap of the canvas is used in place: DoBitmapToTexture,
  DoCopyToBitmap), a TForm3D into the frame surface of a window of the canvas back end (TGpuVkWindow: presented by its
  own thread). Depth and stencil in D32_SFLOAT_S8_UINT (the AMD driver has no D24_UNORM_S8_UINT). Mipmaps are made on
  the CPU when a texture is updated.

  Multisampling and tilers: the multisampled color (and the depth, where no ray-traced effects read it) is a transient
  attachment. A rendering instance into the target looks ahead in the chunk being executed (EndsInPass): when nothing
  but the scene's own draws and clears comes before the scene's end, it resolves into the scene's texture at its end
  (a subpass resolve attachment, or the resolve mode of dynamic rendering) and does not store the samples, the depth
  and the stencil unless a later scene reads them (TFastContext3DVk.FKeep), so a tiler keeps them in tile memory;
  else it stores them as before, and the scene's end resolves them in a rendering instance of its own (ResolvePass).
  A scene holds the canvas's chunk (FastChunkHold) so that its commands reach the render thread together.

  Raw draws (FastCanvas.Context3D: DrawRaw, CopyToTexture, ReadTarget, TFastTexture, TFastBuffer): the shaders' SPIR-V
  sources (FastShaderArchSpirV, dxc of the HLSL the Direct3D contexts take as DXBC), their resources moved to a
  descriptor set of their own when they are loaded (LoadRawSpirV: b0 of each stage at BindingVS / BindingPS, tN at
  RawBindingImages + N, sN at RawBindingSamplers + N); pipelines cached by shaders, layout and the whole raw state,
  samplers by their description; raw textures are TTextureVk (cubes of six layers), raw buffers TRawBufferVk; uploads,
  writes and copies are commands in program order (outside rendering, with their barriers). A context that draws raw
  keeps its depth in memory.

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
    /// <summary>What the scenes read of the scene before (KeepColor, KeepDepth, KeepStencil: a scene drew before it
    /// cleared them, or ended without clearing its multisampled color); the rest is not stored at a scene's end. And
    /// what the scene in progress has cleared so far.</summary>
    FKeep: Cardinal;
    FSceneCleared: Cardinal;
    /// <summary>The scene in progress holds the canvas's chunk (FastChunkHold): its commands reach the render thread
    /// together, so that its rendering instance can last to its end (EndsInPass).</summary>
    FHolding: Boolean;
    /// <summary>A window (TForm3D): the window of the canvas back end that presents the frames, and the texture of its
    /// frame surface.</summary>
    FWindow: TObject;
    /// <summary>The platform's window FWindow presents to (FastCanvas.Platform); held until FWindow goes.</summary>
    FWindowHandle: TGpuWindowHandle;
    FFrame: IInterface;
    /// <summary>The context has drawn raw (or copied or read its target so): its depth and stencil are kept in memory
    /// (not transient, copied and read; stored at every scene's end).</summary>
    FRawDepth: Boolean;
    procedure CreateTargets;
    /// <summary>Raw draws, copies and reads: the depth buffer in memory from now on (FRawDepth).</summary>
    procedure UseRawDepth;
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
    { Raw draws (FastCanvas.Context3D): the shaders' SPIR-V sources (FastShaderArchSpirV) }
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
  /// <summary>Bindings of the descriptor set of raw draws: the constants (b0) of the stages at BindingVS and
  /// BindingPS, the textures t0..t7 at RawBindingImages + N, their samplers s0..s7 at RawBindingSamplers + N (where
  /// dxc puts them with -fvk-t-shift 16 0 -fvk-s-shift 32 0; the shaders' bindings are set so when they are loaded).
  /// </summary>
  RawBindingImages = 16;
  RawBindingSamplers = 32;
  /// <summary>Raw texture uploads and buffer writes up to this size travel in the command stream, larger ones in a
  /// blob.</summary>
  RawInlineData = 64 * 1024;
  /// <summary>Accesses of vertex input (synchronization2 values, the same in Vulkan 1.0).</summary>
  AccessIndexRead = UInt64($2);
  AccessVertexRead = UInt64($4);
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
    /// <summary>A cube map (6 layers, a cube view): raw textures.</summary>
    Cube: Boolean;
    /// <summary>A block-compressed format: the bytes of a 4 x 4 block (zeroed by a copy, not a clear); 0: none.
    /// </summary>
    BlockBytes: Integer;
    /// <summary>An attachment only (VK_IMAGE_USAGE_TRANSIENT_ATTACHMENT_BIT, lazily allocated memory where the device
    /// has it): never copied, cleared or read outside rendering; a tiler need not keep it in memory.</summary>
    Transient: Boolean;
    Canvas: IInterface;
    Window: TGpuVkWindow;
    // Render thread.
    WindowSurface: TGpuVkSurface;
    Use: TGpuVkUse;
    /// <summary>A target the GPU has not cleared yet, or whose content (a depth image: its depth) a rendering instance
    /// did not store: cleared before its next use (by the load operation of its next rendering instance; else
    /// transparent, depth 1).</summary>
    Uncleared: Boolean;
    /// <summary>A depth image whose stencil is not defined likewise (cleared to 0).</summary>
    StencilUncleared: Boolean;
    /// <summary>Recording thread: a recorded command refers to it (updates go through the stream from then on).
    /// </summary>
    Used: Boolean;
    /// <summary>A raw texture of a block-compressed format the device cannot sample (no textureCompressionBC): it is
    /// RGBA8, R8 or RG8, and uploads are decoded on the CPU.</summary>
    Decode: TFastTextureFormat;
    Decoded: Boolean;
    destructor Destroy; override;
    /// <summary>Destroys the Vulkan objects now (the GPU is idle).</summary>
    procedure Drop(const AContext: TGpuVkContext);
    /// <summary>Render thread: zeroes every level of a block-compressed image (a copy of zeros: such images cannot be
    /// cleared).</summary>
    procedure ZeroBlocks(const AContext: TGpuVkContext);
    /// <summary>The view shaders sample (a depth image: its depth).</summary>
    function SampledView: TVkImageView;
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
    /// <summary>A shader of raw draws (SPIR-V of the application): its entry point, the semantics (upper case, with
    /// their index) and locations of the inputs of a vertex shader, the texture units a pixel shader declares as cube
    /// maps.</summary>
    Raw: Boolean;
    Entry: AnsiString;
    InputNames: TArray<string>;
    InputIndices, InputLocations: TArray<Integer>;
    CubeUnits: Cardinal;
    destructor Destroy; override;
  end;

  /// <summary>The buffer of a TFastBuffer (raw draws): device-local, a vertex and index buffer.</summary>
  TRawBufferVk = class(TInterfacedObject)
  public
    Buffer: TVkBuffer;
    Memory: TFastVkAllocation;
    Size: UInt64;
    destructor Destroy; override;
    procedure Drop(const AContext: TGpuVkContext);
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

  TRawPipeKey = packed record
    VS, PS: Integer;
    Layout: UInt64;
    Stride: Integer;
    State: TFastRawState;
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
    /// <summary>Raw draws: the descriptor set layout (RawBinding*), pipelines by the hash of their key, samplers by
    /// the hash of their description, a white cube map for cube units without a texture.</summary>
    RawSetLayout: TVkDescriptorSetLayout;
    RawLayout: TVkPipelineLayout;
    RawPipes: TDictionary<UInt64, TVkPipeline>;
    RawSamplers: TDictionary<UInt64, TVkSampler>;
    BlankCube: TTextureVk;
    BlankCubeRef: IInterface;
    constructor Create;
    destructor Destroy; override;
    /// <summary>The Vulkan objects go now (AContext: the GPU is idle) or once the GPU is done (nil).</summary>
    procedure Release(const AContext: TGpuVkContext);
    function Pipe(const AKey: TPipeKey; const ALayout: TFastVertexLayout): TVkPipeline;
    function Layout_(const ADeclaration: TVertexDeclaration; out AOffsets: TLayoutOffsets): TFastVertexLayout;
    function RawPipe(const AKey: TRawPipeKey; const AVS, APS: TShaderVk; const ALayout: TFastVertexLayout;
      const AState: TFastRawState): TVkPipeline;
    function RawSampler(const ASampler: TFastSampler): TVkSampler;
  end;

  // Commands (payloads of FastBridge.RecordNative).

  PCmdTarget = ^TCmdTarget;
  TCmdTarget = packed record
    Target, Depth: Pointer;   // TTextureVk, kept alive by the command
    Width, Height: Integer;
    /// <summary>KeepColor, KeepDepth, KeepStencil: what has to outlast the scene (TFastContext3DVk.FKeep).</summary>
    Keep: Cardinal;
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

  PCmdEnd = ^TCmdEnd;
  /// <summary>A scene ends: its multisampled target is resolved into Dest (nil: not multisampled).</summary>
  TCmdEnd = packed record
    Target, Depth, Dest: Pointer;   // TTextureVk, kept alive by the command
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

  PCmdRawDraw = ^TCmdRawDraw;
  /// <summary>A raw draw. Followed by the vertices and the indices when they are not in buffers, then the constants of
  /// the two stages.</summary>
  TCmdRawDraw = packed record
    Pipe: TVkPipeline;
    StencilRef: Cardinal;
    /// <summary>Pixels of the target; an empty Viewport: the whole target.</summary>
    Scissor, Viewport: TRect;
    VertexBuffer, IndexBuffer: Pointer;   // TRawBufferVk, kept alive by the command; nil: the data follows
    VertexOffset, IndexOffset: Integer;
    VertexBytes, IndexBytes, VertexStride, IndexCount, BaseVertex: Integer;
    Index32: Boolean;
    Pad: array[0..2] of Byte;
    VSBytes, PSBytes: Integer;
    VSBlock, PSBlock: Integer;
    /// <summary>TTextureVk, kept alive by the command, or the blank texture of the unit's kind.</summary>
    Units: array[0..MaxUnits - 1] of Pointer;
    Samplers: array[0..MaxUnits - 1] of TVkSampler;
  end;

  PCmdRawUpload = ^TCmdRawUpload;
  /// <summary>Pixels (or blocks) into a rectangle of a level of a layer of a raw texture: from Blob (a TBlob), or
  /// following the command when it is nil; rows of RowBytes (block rows for compressed formats).</summary>
  TCmdRawUpload = packed record
    Texture: Pointer;   // TTextureVk
    Blob: Pointer;
    Mip, Layer, X, Y, Width, Height, Rows, RowBytes: Integer;
  end;

  PCmdRawWrite = ^TCmdRawWrite;
  /// <summary>Bytes into a raw buffer (from Blob or following the command); Fill: the whole buffer zeroed.</summary>
  TCmdRawWrite = packed record
    Buffer: Pointer;   // TRawBufferVk
    Blob: Pointer;
    Offset, Size: Integer;
    Fill: Boolean;
    Pad: array[0..2] of Byte;
  end;

  PCmdRawCopy = ^TCmdRawCopy;
  /// <summary>A rectangle of the target's color, or its whole depth and stencil (Depth), into a raw texture.</summary>
  TCmdRawCopy = packed record
    Source, Dest: Pointer;   // TTextureVk
    Rect: TRect;
    X, Y: Integer;
    Depth: Boolean;
    Pad: array[0..2] of Byte;
  end;

  PCmdRawReadback = ^TCmdRawReadback;
  TCmdRawReadback = packed record
    Source: Pointer;   // TTextureVk
    Buffer: TVkBuffer;
    Rect: TRect;
    Aspect: Cardinal;
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
  // TCmdTarget.Keep: the multisampled color, the depth, the stencil of a scene are read by a later scene (it draws
  // before it clears them), so they are stored at the end of every scene.
  KeepColor = 1;
  KeepDepth = 2;
  KeepStencil = 4;

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
    /// <summary>TCmdTarget.Keep of the target.</summary>
    Keep: Cardinal;
    /// <summary>The depth texture of the rendering instance begun last (C.Rendering is its target).</summary>
    RenderDepth: TObject;
    /// <summary>The rendering instance begun last lasts to the end of the scene of EndsTarget (EndsInPass): it
    /// resolves the target at its end, and EndsDiscard (KeepColor, KeepDepth, KeepStencil bits) says what it does not
    /// store.</summary>
    Ends: Boolean;
    EndsTarget, EndsDepth: IInterface;
    EndsDiscard: Cardinal;
    Pipe: TVkPipeline;
    Scissor: TRect;
    StencilRef: Cardinal;
    /// <summary>The viewport set last: the whole target of this size, -1: none, -2: ViewportRect (a raw draw's).
    /// </summary>
    ViewportW, ViewportH: Integer;
    ViewportRect: TRect;
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
/// cleared by the render thread before their first use. ATransient: an attachment only (AUsage has nothing but
/// attachment bits), see TTextureVk.Transient. ACube: a cube map (6 layers).</summary>
function NewTextureVk(const AWidth, AHeight, AMips, ASamples: Integer; const AFormat: TVkFormat;
  const AUsage: TVkImageUsageFlags; const ADepth: Boolean = False; const AAlpha: Boolean = False;
  const ATransient: Boolean = False; const ACube: Boolean = False): TTextureVk;
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
    Result.Cube := ACube;
    Result.Transient := ATransient;
    Result.Uncleared := (AUsage and (Ord(VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT) or
      Ord(VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT))) <> 0;
    Result.StencilUncleared := ADepth;
    FillChar(Info, SizeOf(Info), 0);
    Info.sType := VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    if ACube then
      Info.flags := Ord(VK_IMAGE_CREATE_CUBE_COMPATIBLE_BIT);
    Info.imageType := VK_IMAGE_TYPE_2D;
    Info.format := AFormat;
    Info.extent.width := Max(AWidth, 1);
    Info.extent.height := Max(AHeight, 1);
    Info.extent.depth := 1;
    Info.mipLevels := Result.Mips;
    Info.arrayLayers := IfThen(ACube, 6, 1);
    Info.samples := TVkSampleCountFlagBits(Result.Samples);
    Info.tiling := VK_IMAGE_TILING_OPTIMAL;
    if ATransient then
      Info.usage := AUsage or Ord(VK_IMAGE_USAGE_TRANSIENT_ATTACHMENT_BIT)
    else
      Info.usage := AUsage or Ord(VK_IMAGE_USAGE_TRANSFER_DST_BIT);
    Info.sharingMode := VK_SHARING_MODE_EXCLUSIVE;
    Info.initialLayout := VK_IMAGE_LAYOUT_UNDEFINED;
    Check(F.Track(F.Vk.CreateImage(F.Device, @Info, nil, @Result.Image)), 'vkCreateImage');
    // Dropped with the recording context from here on.
    AddLive(Result);
    F.Vk.GetImageMemoryRequirements(F.Device, Result.Image, @Req);
    try
      Result.Memory := F.Allocate(Req, Ord(VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT),
        IfThen(ATransient, Ord(VK_MEMORY_PROPERTY_LAZILY_ALLOCATED_BIT), 0), False);
    except
      on E: EFastVulkan do
        raise EContext3DException.Create(E.Message);
    end;
    Check(F.Vk.BindImageMemory(F.Device, Result.Image, Result.Memory.Memory, Result.Memory.Offset),
      'vkBindImageMemory');
    FillChar(ViewInfo, SizeOf(ViewInfo), 0);
    ViewInfo.sType := VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    ViewInfo.image := Result.Image;
    if ACube then
      ViewInfo.viewType := VK_IMAGE_VIEW_TYPE_CUBE
    else
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
  Result.layerCount := IfThen(Cube, 6, 1);
end;

function TTextureVk.SampledView: TVkImageView;
begin
  if IsDepth then
    Result := DepthView
  else
    Result := GpuView;
end;

procedure TTextureVk.ZeroBlocks(const AContext: TGpuVkContext);
var
  Level, W, H: Integer;
  Bytes: NativeInt;
  P: PByte;
  Buf: TVkBuffer;
  Off: UInt64;
  Region: TVkBufferImageCopy;
begin
  for Level := 0 to Max(Mips, 1) - 1 do
  begin
    W := Max(1, Width shr Level);
    H := Max(1, Height shr Level);
    Bytes := NativeInt((W + 3) div 4) * ((H + 3) div 4) * BlockBytes * IfThen(Cube, 6, 1);
    P := AContext.Upload(Bytes, 16, Buf, Off);
    FillChar(P^, Bytes, 0);
    FillChar(Region, SizeOf(Region), 0);
    Region.bufferOffset := Off;
    Region.imageSubresource.aspectMask := Ord(VK_IMAGE_ASPECT_COLOR_BIT);
    Region.imageSubresource.mipLevel := Level;
    Region.imageSubresource.layerCount := IfThen(Cube, 6, 1);
    Region.imageExtent.width := W;
    Region.imageExtent.height := H;
    Region.imageExtent.depth := 1;
    AContext.Vk.CmdCopyBufferToImage(AContext.TransferCmd, Buf, Image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1,
      @Region);
  end;
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
  // Attachments only: their rendering instances clear them (load operations, EnsureRendering).
  if Uncleared and not Transient then
  begin
    // A new target or depth buffer: transparent, or depth 1 (as Direct3D 12 clears them).
    Uncleared := False;
    StencilUncleared := False;
    if not ADiscard then
    begin
      C.Transition(Image, Use, TGpuVkUse.TransferDst, True, @Rg);
      if IsDepth then
      begin
        Depth.depth := 1;
        Depth.stencil := 0;
        C.Vk.CmdClearDepthStencilImage(C.TransferCmd, Image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, @Depth, 1, @Rg);
      end
      else if BlockBytes > 0 then
        ZeroBlocks(C)
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

{ TRawBufferVk }

destructor TRawBufferVk.Destroy;
var
  C: TGpuVkContext;
begin
  // Any thread: the last reference may go with a command chunk on the render thread.
  if (Buffer <> VK_NULL_HANDLE) or (Memory <> nil) then
  begin
    TFastDevice.Lock;
    try
      C := GpuVkCurrent;
      if C <> nil then
      begin
        C.Retire(TGpuVkObject.Buffer, Buffer);
        C.Retire(TGpuVkObject.Memory, MemoryHandle(Memory));
      end
      else if Memory <> nil then
        TFastDevice.Vulkan.Release(Memory);
      Buffer := VK_NULL_HANDLE;
      Memory := nil;
    finally
      TFastDevice.Unlock;
    end;
    RemoveLive(Self);
  end;
  inherited;
end;

procedure TRawBufferVk.Drop(const AContext: TGpuVkContext);
begin
  AContext.DestroyObject(TGpuVkObject.Buffer, Buffer);
  AContext.DestroyObject(TGpuVkObject.Memory, MemoryHandle(Memory));
  Buffer := VK_NULL_HANDLE;
  Memory := nil;
end;

{ TShared }

constructor TShared.Create;
var
  Sampler: TVkSamplerCreateInfo;
  Bindings: array[0..BindingUnits + MaxUnits - 1] of TVkDescriptorSetLayoutBinding;
  RawBindings: array[0..2 + 2 * MaxUnits - 1] of TVkDescriptorSetLayoutBinding;
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
  // Raw draws: the constants of the stages, the textures and their samplers apart (as dxc makes them of HLSL).
  RawPipes := TDictionary<UInt64, TVkPipeline>.Create;
  RawSamplers := TDictionary<UInt64, TVkSampler>.Create;
  FillChar(RawBindings, SizeOf(RawBindings), 0);
  RawBindings[0] := Bindings[0];
  RawBindings[1] := Bindings[1];
  for I := 0 to MaxUnits - 1 do
  begin
    RawBindings[2 + I].binding := RawBindingImages + I;
    RawBindings[2 + I].descriptorType := VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE;
    RawBindings[2 + I].descriptorCount := 1;
    RawBindings[2 + I].stageFlags := Ord(VK_SHADER_STAGE_FRAGMENT_BIT);
    RawBindings[2 + MaxUnits + I].binding := RawBindingSamplers + I;
    RawBindings[2 + MaxUnits + I].descriptorType := VK_DESCRIPTOR_TYPE_SAMPLER;
    RawBindings[2 + MaxUnits + I].descriptorCount := 1;
    RawBindings[2 + MaxUnits + I].stageFlags := Ord(VK_SHADER_STAGE_FRAGMENT_BIT);
  end;
  SetInfo.bindingCount := Length(RawBindings);
  SetInfo.pBindings := @RawBindings[0];
  Check(Vk.CreateDescriptorSetLayout(Device, @SetInfo, nil, @RawSetLayout), 'vkCreateDescriptorSetLayout (raw)');
  LayoutInfo.pSetLayouts := @RawSetLayout;
  Check(Vk.CreatePipelineLayout(Device, @LayoutInfo, nil, @RawLayout), 'vkCreatePipelineLayout (raw)');
  // White 1x1: texture units without a texture sample it (filled by the render thread before its first use).
  Blank := NewTextureVk(1, 1, 1, 1, VK_FORMAT_B8G8R8A8_UNORM, Ord(VK_IMAGE_USAGE_SAMPLED_BIT));
  BlankRef := Blank;
  BlankCube := NewTextureVk(1, 1, 1, 1, VK_FORMAT_B8G8R8A8_UNORM, Ord(VK_IMAGE_USAGE_SAMPLED_BIT), False, False,
    False, True);
  BlankCubeRef := BlankCube;
end;

destructor TShared.Destroy;
begin
  BlankRef := nil;
  BlankCubeRef := nil;
  Pipes.Free;
  Layouts.Free;
  Offsets.Free;
  RawPipes.Free;
  RawSamplers.Free;
  inherited;
end;

procedure TShared.Release(const AContext: TGpuVkContext);
var
  C: TGpuVkContext;
  P: TVkPipeline;
  Smp: TVkSampler;
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
    for P in RawPipes.Values do
      Go(TGpuVkObject.Pipeline, P);
    RawPipes.Clear;
    for Smp in RawSamplers.Values do
      Go(TGpuVkObject.Sampler, Smp);
    RawSamplers.Clear;
    Go(TGpuVkObject.PipelineLayout, Layout);
    Go(TGpuVkObject.SetLayout, SetLayout);
    Go(TGpuVkObject.PipelineLayout, RawLayout);
    Go(TGpuVkObject.SetLayout, RawSetLayout);
    for I := 0 to High(Samplers) do
      Go(TGpuVkObject.Sampler, Samplers[I]);
    Layout := VK_NULL_HANDLE;
    SetLayout := VK_NULL_HANDLE;
    RawLayout := VK_NULL_HANDLE;
    RawSetLayout := VK_NULL_HANDLE;
    FillChar(Samplers, SizeOf(Samplers), 0);
    if (AContext <> nil) and (Blank <> nil) then
      Blank.Drop(AContext);
    if (AContext <> nil) and (BlankCube <> nil) then
      BlankCube.Drop(AContext);
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

/// <summary>The Vulkan format of a DXGI_FORMAT of a raw vertex element (VK_FORMAT_UNDEFINED: none).</summary>
function RawVertexFormat(const ADxgi: Integer): TVkFormat;
begin
  case ADxgi of
    2: Result := VK_FORMAT_R32G32B32A32_SFLOAT;
    3: Result := VK_FORMAT_R32G32B32A32_UINT;
    4: Result := VK_FORMAT_R32G32B32A32_SINT;
    6: Result := VK_FORMAT_R32G32B32_SFLOAT;
    7: Result := VK_FORMAT_R32G32B32_UINT;
    8: Result := VK_FORMAT_R32G32B32_SINT;
    10: Result := VK_FORMAT_R16G16B16A16_SFLOAT;
    11: Result := VK_FORMAT_R16G16B16A16_UNORM;
    12: Result := VK_FORMAT_R16G16B16A16_UINT;
    13: Result := VK_FORMAT_R16G16B16A16_SNORM;
    14: Result := VK_FORMAT_R16G16B16A16_SINT;
    16: Result := VK_FORMAT_R32G32_SFLOAT;
    17: Result := VK_FORMAT_R32G32_UINT;
    18: Result := VK_FORMAT_R32G32_SINT;
    24: Result := VK_FORMAT_A2B10G10R10_UNORM_PACK32;
    28: Result := VK_FORMAT_R8G8B8A8_UNORM;
    30: Result := VK_FORMAT_R8G8B8A8_UINT;
    31: Result := VK_FORMAT_R8G8B8A8_SNORM;
    32: Result := VK_FORMAT_R8G8B8A8_SINT;
    34: Result := VK_FORMAT_R16G16_SFLOAT;
    35: Result := VK_FORMAT_R16G16_UNORM;
    36: Result := VK_FORMAT_R16G16_UINT;
    37: Result := VK_FORMAT_R16G16_SNORM;
    38: Result := VK_FORMAT_R16G16_SINT;
    41: Result := VK_FORMAT_R32_SFLOAT;
    42: Result := VK_FORMAT_R32_UINT;
    43: Result := VK_FORMAT_R32_SINT;
    49: Result := VK_FORMAT_R8G8_UNORM;
    50: Result := VK_FORMAT_R8G8_UINT;
    51: Result := VK_FORMAT_R8G8_SNORM;
    52: Result := VK_FORMAT_R8G8_SINT;
    54: Result := VK_FORMAT_R16_SFLOAT;
    56: Result := VK_FORMAT_R16_UNORM;
    57: Result := VK_FORMAT_R16_UINT;
    58: Result := VK_FORMAT_R16_SNORM;
    59: Result := VK_FORMAT_R16_SINT;
    61: Result := VK_FORMAT_R8_UNORM;
    62: Result := VK_FORMAT_R8_UINT;
    63: Result := VK_FORMAT_R8_SNORM;
    64: Result := VK_FORMAT_R8_SINT;
    87: Result := VK_FORMAT_B8G8R8A8_UNORM;
  else
    Result := VK_FORMAT_UNDEFINED;
  end;
end;

function TShared.RawPipe(const AKey: TRawPipeKey; const AVS, APS: TShaderVk; const ALayout: TFastVertexLayout;
  const AState: TFastRawState): TVkPipeline;
const
  Culls: array[TFastCullMode] of TVkCullModeFlagBits = (VK_CULL_MODE_NONE, VK_CULL_MODE_FRONT_BIT,
    VK_CULL_MODE_BACK_BIT);
  Blends: array[TFastBlend] of TVkBlendFactor = (VK_BLEND_FACTOR_ZERO, VK_BLEND_FACTOR_ONE,
    VK_BLEND_FACTOR_SRC_COLOR, VK_BLEND_FACTOR_ONE_MINUS_SRC_COLOR, VK_BLEND_FACTOR_SRC_ALPHA,
    VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA, VK_BLEND_FACTOR_DST_ALPHA, VK_BLEND_FACTOR_ONE_MINUS_DST_ALPHA,
    VK_BLEND_FACTOR_DST_COLOR, VK_BLEND_FACTOR_ONE_MINUS_DST_COLOR);
  Ops: array[TFastBlendOp] of TVkBlendOp = (VK_BLEND_OP_ADD, VK_BLEND_OP_SUBTRACT, VK_BLEND_OP_REVERSE_SUBTRACT,
    VK_BLEND_OP_MIN, VK_BLEND_OP_MAX);
  Topologies: array[TPrimitivesKind] of TVkPrimitiveTopology = (VK_PRIMITIVE_TOPOLOGY_POINT_LIST,
    VK_PRIMITIVE_TOPOLOGY_LINE_LIST, VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST);
var
  Hash: UInt64;
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
  Loc, I, J, N: Integer;
  Provided: Cardinal;
  Name: string;

  function Face(const AFace: TFastStencilFace): TVkStencilOpState;
  begin
    // The values of Direct3D are those of Vulkan plus one.
    Result.failOp := TVkStencilOp(Ord(AFace.Fail) - 1);
    Result.passOp := TVkStencilOp(Ord(AFace.Pass) - 1);
    Result.depthFailOp := TVkStencilOp(Ord(AFace.DepthFail) - 1);
    Result.compareOp := TVkCompareOp(Ord(AFace.Func) - 1);
    Result.compareMask := AState.StencilReadMask;
    Result.writeMask := AState.StencilWriteMask;
    Result.reference := 0;
  end;

begin
  Hash := FastHash(@AKey, SizeOf(AKey));
  if RawPipes.TryGetValue(Hash, Result) then
    Exit;
  FillChar(Stages, SizeOf(Stages), 0);
  Stages[0].sType := VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
  Stages[0].stage := VK_SHADER_STAGE_VERTEX_BIT;
  Stages[0].module := AVS.Module;
  Stages[0].pName := PAnsiChar(AVS.Entry);
  Stages[1].sType := VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
  Stages[1].stage := VK_SHADER_STAGE_FRAGMENT_BIT;
  Stages[1].module := APS.Module;
  Stages[1].pName := PAnsiChar(APS.Entry);
  // The elements the vertex shader reads, at the locations of their semantics (dxc names its inputs in.var.<semantic>);
  // without names the elements in order. An input the layout lacks reads the first bytes of the vertex.
  Binding.binding := 0;
  Binding.stride := AKey.Stride;
  Binding.inputRate := VK_VERTEX_INPUT_RATE_VERTEX;
  SetLength(Attributes, Length(ALayout.Elements) + 32);
  N := 0;
  Provided := 0;
  for I := 0 to High(ALayout.Elements) do
  begin
    E := ALayout.Elements[I];
    Loc := -1;
    if Length(AVS.InputNames) > 0 then
    begin
      Name := UpperCase(string(AnsiString(E.Semantic)));
      for J := 0 to High(AVS.InputNames) do
        if (AVS.InputNames[J] = Name) and (AVS.InputIndices[J] = E.SemanticIndex) then
        begin
          Loc := AVS.InputLocations[J];
          Break;
        end;
    end
    else
      Loc := I;
    if (Loc < 0) or (Loc > 31) or ((AVS.Inputs and (Cardinal(1) shl Loc)) = 0) or
      ((Provided and (Cardinal(1) shl Loc)) <> 0) or (RawVertexFormat(E.Format) = VK_FORMAT_UNDEFINED) then
      Continue;
    Attributes[N].location := Loc;
    Attributes[N].binding := 0;
    Attributes[N].format := RawVertexFormat(E.Format);
    Attributes[N].offset := E.Offset;
    Provided := Provided or (Cardinal(1) shl Loc);
    Inc(N);
  end;
  for I := 0 to 31 do
    if ((AVS.Inputs and (Cardinal(1) shl I)) <> 0) and ((Provided and (Cardinal(1) shl I)) = 0) then
    begin
      Attributes[N].location := I;
      Attributes[N].binding := 0;
      Attributes[N].format := VK_FORMAT_R8G8B8A8_UNORM;
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
  Assembly.topology := Topologies[TPrimitivesKind(Min(AKey.Topology, 2))];
  FillChar(ViewportState, SizeOf(ViewportState), 0);
  ViewportState.sType := VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
  ViewportState.viewportCount := 1;
  ViewportState.scissorCount := 1;
  FillChar(Raster, SizeOf(Raster), 0);
  Raster.sType := VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
  if AState.Wireframe and (Fast.Features.fillModeNonSolid <> VK_FALSE) then
    Raster.polygonMode := VK_POLYGON_MODE_LINE
  else
    Raster.polygonMode := VK_POLYGON_MODE_FILL;
  Raster.cullMode := Ord(Culls[AState.Cull]);
  // The viewport keeps Direct3D's y direction: its winding is the target's.
  if AState.FrontCounterClockwise then
    Raster.frontFace := VK_FRONT_FACE_COUNTER_CLOCKWISE
  else
    Raster.frontFace := VK_FRONT_FACE_CLOCKWISE;
  if (AState.DepthBias <> 0) or (AState.SlopeScaledDepthBias <> 0) then
  begin
    Raster.depthBiasEnable := VK_TRUE;
    Raster.depthBiasConstantFactor := AState.DepthBias;
    Raster.depthBiasSlopeFactor := AState.SlopeScaledDepthBias;
    if Fast.Features.depthBiasClamp <> VK_FALSE then
      Raster.depthBiasClamp := AState.DepthBiasClamp;
  end;
  Raster.lineWidth := 1;
  FillChar(Multisample, SizeOf(Multisample), 0);
  Multisample.sType := VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
  Multisample.rasterizationSamples := TVkSampleCountFlagBits(Max(AKey.Samples, 1));
  FillChar(DepthStencil, SizeOf(DepthStencil), 0);
  DepthStencil.sType := VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO;
  DepthStencil.depthTestEnable := Ord(AState.DepthEnable and AKey.Depth);
  DepthStencil.depthWriteEnable := Ord(AState.DepthEnable and AState.DepthWrite and AKey.Depth);
  DepthStencil.depthCompareOp := TVkCompareOp(Ord(AState.DepthFunc) - 1);
  DepthStencil.stencilTestEnable := Ord(AState.StencilEnable and AKey.Depth);
  DepthStencil.front := Face(AState.FrontFace);
  DepthStencil.back := Face(AState.BackFace);
  DepthStencil.maxDepthBounds := 1;
  FillChar(Attachment, SizeOf(Attachment), 0);
  Attachment.blendEnable := Ord(AState.BlendEnable);
  Attachment.srcColorBlendFactor := Blends[AState.SrcBlend];
  Attachment.dstColorBlendFactor := Blends[AState.DestBlend];
  Attachment.colorBlendOp := Ops[AState.BlendOp];
  Attachment.srcAlphaBlendFactor := Blends[AState.SrcBlendAlpha];
  Attachment.dstAlphaBlendFactor := Blends[AState.DestBlendAlpha];
  Attachment.alphaBlendOp := Ops[AState.BlendOpAlpha];
  // Bit 0 red .. 3 alpha, as Vulkan's.
  Attachment.colorWriteMask := AState.WriteMask and $F;
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
  Info.layout := RawLayout;
  Info.basePipelineIndex := -1;
  Result := VK_NULL_HANDLE;
  Check(Fast.Track(Vk.CreateGraphicsPipelines(Device, VK_NULL_HANDLE, 1, @Info, nil, @Result)),
    'vkCreateGraphicsPipelines (raw)');
  RawPipes.Add(Hash, Result);
end;

function TShared.RawSampler(const ASampler: TFastSampler): TVkSampler;
const
  // Direct3D's address modes 1..5: wrap, mirror, clamp, border, mirror once (mirrored here: Vulkan's mirror clamp to
  // edge is an optional feature).
  Modes: array[0..5] of TVkSamplerAddressMode = (VK_SAMPLER_ADDRESS_MODE_REPEAT, VK_SAMPLER_ADDRESS_MODE_REPEAT,
    VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT, VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
    VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER, VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT);
var
  Key: UInt64;
  Info: TVkSamplerCreateInfo;
  F: Cardinal;
  C: array[0..3] of Single;
  Black, White, Clear: Single;

  function Mode(const AMode: Byte): TVkSamplerAddressMode;
  begin
    Result := Modes[Min(AMode, 5)];
  end;

begin
  Key := FastHash(@ASampler, SizeOf(ASampler));
  if RawSamplers.TryGetValue(Key, Result) then
    Exit;
  // D3D11_FILTER: bit 0 linear mip levels, bit 2 linear magnification, bit 4 linear minification, 0x40 anisotropic,
  // 0x80 comparison (sampled as the plain filter here).
  F := ASampler.Filter;
  FillChar(Info, SizeOf(Info), 0);
  Info.sType := VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
  if (F and $10) <> 0 then
    Info.minFilter := VK_FILTER_LINEAR
  else
    Info.minFilter := VK_FILTER_NEAREST;
  if (F and $4) <> 0 then
    Info.magFilter := VK_FILTER_LINEAR
  else
    Info.magFilter := VK_FILTER_NEAREST;
  if (F and $1) <> 0 then
    Info.mipmapMode := VK_SAMPLER_MIPMAP_MODE_LINEAR
  else
    Info.mipmapMode := VK_SAMPLER_MIPMAP_MODE_NEAREST;
  Info.addressModeU := Mode(ASampler.AddressU);
  Info.addressModeV := Mode(ASampler.AddressV);
  Info.addressModeW := Mode(ASampler.AddressW);
  Info.mipLodBias := EnsureRange(ASampler.MipLODBias, -Fast.Properties.limits.maxSamplerLodBias,
    Fast.Properties.limits.maxSamplerLodBias);
  Info.maxAnisotropy := 1;
  if ((F and $40) <> 0) and (ASampler.MaxAnisotropy > 1) and (Fast.Features.samplerAnisotropy <> VK_FALSE) then
  begin
    Info.anisotropyEnable := VK_TRUE;
    Info.maxAnisotropy := Min(Single(ASampler.MaxAnisotropy), Fast.Properties.limits.maxSamplerAnisotropy);
  end;
  Info.compareOp := VK_COMPARE_OP_NEVER;
  Info.minLod := ASampler.MinLOD;
  if ASampler.MaxLOD >= VK_LOD_CLAMP_NONE then
    Info.maxLod := VK_LOD_CLAMP_NONE
  else
    Info.maxLod := Max(ASampler.MaxLOD, ASampler.MinLOD);
  // The nearest of Vulkan's fixed border colors.
  Move(ASampler.BorderColor, C, SizeOf(C));
  Clear := Sqr(C[0]) + Sqr(C[1]) + Sqr(C[2]) + Sqr(C[3]);
  Black := Sqr(C[0]) + Sqr(C[1]) + Sqr(C[2]) + Sqr(C[3] - 1);
  White := Sqr(C[0] - 1) + Sqr(C[1] - 1) + Sqr(C[2] - 1) + Sqr(C[3] - 1);
  if (Clear <= Black) and (Clear <= White) then
    Info.borderColor := VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK
  else if Black <= White then
    Info.borderColor := VK_BORDER_COLOR_FLOAT_OPAQUE_BLACK
  else
    Info.borderColor := VK_BORDER_COLOR_FLOAT_OPAQUE_WHITE;
  Result := VK_NULL_HANDLE;
  Check(Vk.CreateSampler(Device, @Info, nil, @Result), 'vkCreateSampler (raw)');
  RawSamplers.Add(Key, Result);
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
  C: TGpuVkContext;
  P: PByte;
  Buf: TVkBuffer;
  Off: UInt64;
  Region: TVkBufferImageCopy;
begin
  if G.BlankReady then
    Exit;
  C := GpuVk;
  B := G.Blank;
  White := $FFFFFFFF;
  B.Uncleared := False;
  C.CopyToImage(B.Image, B.Use, 4, 0, 0, 1, 1, @White, 4);
  B.UseAs(TGpuVkUse.ShaderRead);
  // The cube map of raw draws: its six faces.
  B := G.BlankCube;
  B.Uncleared := False;
  P := C.Upload(6 * 4, 16, Buf, Off);
  FillChar(P^, 6 * 4, $FF);
  B.UseAs(TGpuVkUse.TransferDst, True);
  FillChar(Region, SizeOf(Region), 0);
  Region.bufferOffset := Off;
  Region.imageSubresource.aspectMask := Ord(VK_IMAGE_ASPECT_COLOR_BIT);
  Region.imageSubresource.layerCount := 6;
  Region.imageExtent.width := 1;
  Region.imageExtent.height := 1;
  Region.imageExtent.depth := 1;
  C.Vk.CmdCopyBufferToImage(C.TransferCmd, Buf, B.Image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, @Region);
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

procedure HandleDraw(const AData: Pointer); forward;
procedure HandleRawDraw(const AData: Pointer); forward;
procedure HandleClear(const AData: Pointer); forward;
procedure HandleTarget(const AData: Pointer); forward;
procedure HandleEnd(const AData: Pointer); forward;

/// <summary>Before a rendering instance into T (and D) begins: whether it can last to the end of the scene. The
/// commands that follow in the chunk up to the scene's end (AEnd) must be draws into T whose textures are ready (no
/// barrier, no upload: nothing ends the instance), clears of T, and T as the target again; anything else (a copy, a
/// texture update, a ray pass, the canvas, another target) or the chunk's end before the scene's end: False. The
/// draws must not read the texture the scene resolves into.</summary>
function EndsInPass(const T, D: TTextureVk; out AEnd: PCmdEnd): Boolean;
var
  Cursor, Data: Pointer;
  H: TFastNativeHandler;
  Draw: PCmdDraw;
  Dest: TTextureVk;
  Pending: TGpuVkSurface;
  I: Integer;
begin
  Result := False;
  AEnd := nil;
  // The first draw makes the blank texture otherwise (a copy).
  if not Assigned(FastBridge.NextCommand) or not G.BlankReady then
    Exit;
  Pending := GpuVk.PendingClear;
  Cursor := nil;
  while FastBridge.NextCommand(Cursor, H, Data) do
    if @H = @HandleDraw then
    begin
      Draw := Data;
      // A texture to be moved to another use, or a canvas bitmap whose clear is still deferred.
      for I := 0 to Draw.UnitCount - 1 do
        if (TTextureVk(Draw.Units[I]).CurrentUse <> TGpuVkUse.ShaderRead) or
          ((Pending <> nil) and (TTextureVk(Draw.Units[I]).Surface = Pending)) then
          Exit;
    end
    else if @H = @HandleRawDraw then
    begin
      // A raw draw likewise (its buffers had their barriers when they were written: a write is another command).
      for I := 0 to MaxUnits - 1 do
        if (TTextureVk(PCmdRawDraw(Data).Units[I]).CurrentUse <> TGpuVkUse.ShaderRead) or
          ((Pending <> nil) and (TTextureVk(PCmdRawDraw(Data).Units[I]).Surface = Pending)) then
          Exit;
    end
    else if @H = @HandleClear then
    begin
      if (PCmdClear(Data).Target <> Pointer(T)) or (PCmdClear(Data).Depth <> Pointer(D)) then
        Exit;
    end
    else if @H = @HandleTarget then
    begin
      if (PCmdTarget(Data).Target <> Pointer(T)) or (PCmdTarget(Data).Depth <> Pointer(D)) or
        (PCmdTarget(Data).Width <> R.Width) or (PCmdTarget(Data).Height <> R.Height) then
        Exit;
    end
    else if @H = @HandleEnd then
    begin
      if PCmdEnd(Data).Target <> Pointer(T) then
        Exit;
      AEnd := Data;
      Break;
    end
    else
      Exit;
  if AEnd = nil then
    Exit;
  Dest := AEnd.Dest;
  if Dest <> nil then
  begin
    if (Dest.GpuView = VK_NULL_HANDLE) or (Dest.Width < R.Width) or (Dest.Height < R.Height) then
      Exit;
    // A material that shows the target's own texture: it is read while the instance resolves into it.
    Cursor := nil;
    while FastBridge.NextCommand(Cursor, H, Data) and (Data <> Pointer(AEnd)) do
      if @H = @HandleDraw then
      begin
        for I := 0 to PCmdDraw(Data).UnitCount - 1 do
          if TTextureVk(PCmdDraw(Data).Units[I]).GpuImage = Dest.GpuImage then
            Exit;
      end
      else if @H = @HandleRawDraw then
        for I := 0 to MaxUnits - 1 do
          if TTextureVk(PCmdRawDraw(Data).Units[I]).GpuImage = Dest.GpuImage then
            Exit;
  end;
  Result := True;
end;

/// <summary>The rendering instance that was to last to the end of a scene (R.Ends) has ended: ALost, before the
/// scene's end (what it did not store is gone: counted, and cleared before its next use).</summary>
procedure ForgetEnds(const ALost: Boolean);
var
  T, D: TTextureVk;
begin
  if not R.Ends then
    Exit;
  R.Ends := False;
  T := nil;
  if R.EndsTarget <> nil then
    T := TTextureVk(R.EndsTarget as TObject);
  D := nil;
  if R.EndsDepth <> nil then
    D := TTextureVk(R.EndsDepth as TObject);
  if (T <> nil) and ((R.EndsDiscard and KeepColor) <> 0) then
    T.Uncleared := True;
  if (D <> nil) and ((R.EndsDiscard and KeepDepth) <> 0) then
    D.Uncleared := True;
  if (D <> nil) and ((R.EndsDiscard and KeepStencil) <> 0) then
    D.StencilUncleared := True;
  R.EndsTarget := nil;
  R.EndsDepth := nil;
  if ALost and GpuVkTiming then
    Inc(GpuVkTimeScenes[2]);
end;

/// <summary>Rendering into the target (and depth buffer) for the commands that follow: begun again after barriers,
/// when another target was drawn into, or to clear (AClear: with the attachments' clear operations). An instance that
/// lasts to the end of the scene (EndsInPass) resolves a multisampled target into the scene's texture at its end and
/// does not store what no later scene reads (TCmdTarget.Keep): on a tiler the samples and the depth stay in tile
/// memory. Content that is not defined (a new target, or not stored at the end of the last scene) is cleared by the
/// load operations: transparent, depth 1, stencil 0, as Direct3D 12 clears new targets.</summary>
procedure EnsureRendering(const AClear: PCmdClear);
var
  C: TGpuVkContext;
  T, D, Dest: TTextureVk;
  ColorWas, DepthWas, DestWas: TGpuVkUse;
  Color, Depth, Stencil: TVkRenderingAttachmentInfo;
  Info: TVkRenderingInfo;
  ClearColor, ClearDepth, ClearStencil, ColorZero, DepthOne, StencilZero, Ends: Boolean;
  Last: PCmdEnd;
  Discard: Cardinal;
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
  // An instance that was to last to the scene's end is ended before it.
  ForgetEnds(True);
  ClearColor := (AClear <> nil) and AClear.ClearColor;
  ClearDepth := (AClear <> nil) and AClear.ClearDepth;
  ClearStencil := (AClear <> nil) and AClear.ClearStencil;
  ColorZero := not ClearColor and T.Uncleared and (T.Canvas = nil) and (T.Window = nil);
  DepthOne := (D <> nil) and not ClearDepth and D.Uncleared;
  StencilZero := (D <> nil) and not ClearStencil and D.StencilUncleared;
  Ends := False;
  Dest := nil;
  Discard := 0;
  if ((T.Samples > 1) or (D <> nil)) and EndsInPass(T, D, Last) then
  begin
    Ends := True;
    Dest := Last.Dest;
    Discard := (KeepColor or KeepDepth or KeepStencil) and not R.Keep;
    // The texture's own color is the scene's image.
    if T.Samples = 1 then
      Discard := Discard and not KeepColor;
    if D = nil then
      Discard := Discard and not (KeepDepth or KeepStencil);
  end;
  ColorWas := T.CurrentUse;
  // Cleared by the load operations below.
  T.UseAs(TGpuVkUse.ColorTarget, ClearColor or ColorZero);
  T.Uncleared := False;
  DepthWas := TGpuVkUse.Undefined;
  if D <> nil then
  begin
    DepthWas := D.CurrentUse;
    D.Uncleared := False;
    D.StencilUncleared := False;
    D.UseAs(TGpuVkUse.DepthTarget, (ClearDepth or DepthOne) and (ClearStencil or StencilZero));
  end;
  // Drawn in an earlier rendering instance: its writes come before the next ones (blending and tests read them).
  if ColorWas = TGpuVkUse.ColorTarget then
    C.MemoryBarrier(StageColorOutput, AccessColorWrite, StageColorOutput, AccessColorRead or AccessColorWrite);
  if (D <> nil) and (DepthWas = TGpuVkUse.DepthTarget) then
    C.MemoryBarrier(StageLateTests, AccessDepthWrite, StageEarlyTests or StageLateTests,
      AccessDepthRead or AccessDepthWrite);
  if Dest <> nil then
  begin
    // The resolve writes all of it, after what wrote it before.
    DestWas := Dest.CurrentUse;
    Dest.UseAs(TGpuVkUse.ColorTarget, True);
    if DestWas = TGpuVkUse.ColorTarget then
      C.MemoryBarrier(StageColorOutput, AccessColorWrite, StageColorOutput, AccessColorWrite);
  end;
  FillChar(Color, SizeOf(Color), 0);
  Color.sType := VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO;
  Color.imageView := T.GpuView;
  Color.imageLayout := VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
  Color.resolveMode := VK_RESOLVE_MODE_NONE;
  Color.loadOp := VK_ATTACHMENT_LOAD_OP_LOAD;
  Color.storeOp := VK_ATTACHMENT_STORE_OP_STORE;
  if ClearColor then
  begin
    Color.loadOp := VK_ATTACHMENT_LOAD_OP_CLEAR;
    Move(AClear.Color, Color.clearValue.color.float32, SizeOf(AClear.Color));
  end
  else if ColorZero then
    Color.loadOp := VK_ATTACHMENT_LOAD_OP_CLEAR;
  if (Discard and KeepColor) <> 0 then
    Color.storeOp := VK_ATTACHMENT_STORE_OP_DONT_CARE;
  if Dest <> nil then
  begin
    Color.resolveMode := VK_RESOLVE_MODE_AVERAGE_BIT;
    Color.resolveImageView := Dest.GpuView;
    Color.resolveImageLayout := VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
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
    Depth.clearValue.depthStencil.depth := 1;
    if ClearDepth then
      Depth.clearValue.depthStencil.depth := AClear.DepthValue;
    if ClearStencil then
      Depth.clearValue.depthStencil.stencil := AClear.Stencil;
    Stencil.clearValue := Depth.clearValue;
    if ClearDepth or DepthOne then
      Depth.loadOp := VK_ATTACHMENT_LOAD_OP_CLEAR;
    if ClearStencil or StencilZero then
      Stencil.loadOp := VK_ATTACHMENT_LOAD_OP_CLEAR;
    if (Discard and KeepDepth) <> 0 then
      Depth.storeOp := VK_ATTACHMENT_STORE_OP_DONT_CARE;
    if (Discard and KeepStencil) <> 0 then
      Stencil.storeOp := VK_ATTACHMENT_STORE_OP_DONT_CARE;
    Info.pDepthAttachment := @Depth;
    Info.pStencilAttachment := @Stencil;
  end;
  C.BeginRenderingInfo(T, Info, T.Format, T.Samples);
  R.RenderDepth := D;
  if Ends then
  begin
    R.Ends := True;
    R.EndsTarget := T;
    R.EndsDepth := D;
    R.EndsDiscard := Discard;
  end
  else if ((T.Samples > 1) or (D <> nil)) and GpuVkTiming then
    Inc(GpuVkTimeScenes[3]);
end;

procedure HandleTarget(const AData: Pointer);
var
  C: PCmdTarget;
  Same: Boolean;
begin
  C := AData;
  // The same target again: its rendering instance, if one is active, goes on.
  Same := (R.Target <> nil) and ((R.Target as TObject) = TObject(C.Target)) and (R.Width = C.Width) and
    (R.Height = C.Height) and (((R.Depth = nil) and (C.Depth = nil)) or
    ((R.Depth <> nil) and ((R.Depth as TObject) = TObject(C.Depth))));
  R.Target := TTextureVk(C.Target);
  if C.Depth <> nil then
    R.Depth := TTextureVk(C.Depth)
  else
    R.Depth := nil;
  R.Width := C.Width;
  R.Height := C.Height;
  R.Keep := C.Keep;
  // Rendering begins with the first clear or draw.
  if not Same then
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
    // Not the target of the commands (never so far): a clear of its color outside rendering (not of an attachment
    // only, which its next rendering instance clears).
    if (T = nil) or not C.ClearColor or (T.GpuImage = VK_NULL_HANDLE) or T.Transient then
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

{ Raw draws (render thread) }

/// <summary>Constants of a raw draw (ABytes recorded at AData) into upload memory, zeroed up to the shader's uniform
/// block.</summary>
function RawConstants(const C: TGpuVkContext; const AData: PByte; const ABytes, ABlock: Integer;
  out AInfo: TVkDescriptorBufferInfo): PByte;
var
  Size: Integer;
  P: PByte;
begin
  Size := AlignUp(Max(Max(ABlock, ABytes), 16), 16);
  P := C.Upload(Size, C.UniformAlign, AInfo.buffer, AInfo.offset);
  if ABytes > 0 then
    Move(AData^, P^, ABytes);
  if ABytes < Size then
    FillChar((P + ABytes)^, Size - ABytes, 0);
  AInfo.range := Size;
  Result := AData + ABytes;
end;

procedure HandleRawDraw(const AData: Pointer);
var
  C: PCmdRawDraw;
  Ctx: TGpuVkContext;
  Cmd: TVkCommandBuffer;
  Src, P: PByte;
  VBuf, IBuf: TVkBuffer;
  VOff, IOff: UInt64;
  I: Integer;
  VP: TRect;
  Full: Boolean;
  Viewport: TVkViewport;
  Scissor: TVkRect2D;
  Buffers: array[0..1] of TVkDescriptorBufferInfo;
  Images, Samplers: array[0..MaxUnits - 1] of TVkDescriptorImageInfo;
  Writes: array[0..3] of TVkWriteDescriptorSet;
  DescSet: TVkDescriptorSet;
begin
  C := AData;
  Ctx := Begin3D;
  if R.Target = nil then
    Exit;
  if not G.BlankReady then
    EnsureBlank;
  for I := 0 to MaxUnits - 1 do
    TTextureVk(C.Units[I]).UseAs(TGpuVkUse.ShaderRead);
  EnsureRendering(nil);
  Cmd := Ctx.Cmd;
  if C.Pipe <> R.Pipe then
  begin
    Ctx.Vk.CmdBindPipeline(Cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, C.Pipe);
    R.Pipe := C.Pipe;
  end;
  VP := C.Viewport;
  if VP.IsEmpty then
    VP := TRect.Create(0, 0, R.Width, R.Height);
  Full := VP = TRect.Create(0, 0, R.Width, R.Height);
  if not ((Full and (R.ViewportW = R.Width) and (R.ViewportH = R.Height)) or
    (not Full and (R.ViewportW = -2) and (R.ViewportRect = VP))) then
  begin
    // Negative height: y down in the target, as Direct3D's viewports map clip space.
    Viewport.x := VP.Left;
    Viewport.y := VP.Bottom;
    Viewport.width := VP.Width;
    Viewport.height := -VP.Height;
    Viewport.minDepth := 0;
    Viewport.maxDepth := 1;
    Ctx.Vk.CmdSetViewport(Cmd, 0, 1, @Viewport);
    if Full then
    begin
      R.ViewportW := R.Width;
      R.ViewportH := R.Height;
    end
    else
    begin
      R.ViewportW := -2;
      R.ViewportRect := VP;
    end;
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
  Src := PByte(C) + SizeOf(TCmdRawDraw);
  if C.VertexBuffer <> nil then
  begin
    VBuf := TRawBufferVk(C.VertexBuffer).Buffer;
    VOff := C.VertexOffset;
  end
  else
  begin
    P := Ctx.Upload(C.VertexBytes, 16, VBuf, VOff);
    Move(Src^, P^, C.VertexBytes);
    Inc(Src, C.VertexBytes);
  end;
  if C.IndexBuffer <> nil then
  begin
    IBuf := TRawBufferVk(C.IndexBuffer).Buffer;
    IOff := C.IndexOffset;
  end
  else
  begin
    P := Ctx.Upload(C.IndexBytes, 16, IBuf, IOff);
    Move(Src^, P^, C.IndexBytes);
    Inc(Src, AlignUp(C.IndexBytes, 4));
  end;
  if (VBuf = VK_NULL_HANDLE) or (IBuf = VK_NULL_HANDLE) then
    Exit;
  Src := RawConstants(Ctx, Src, C.VSBytes, C.VSBlock, Buffers[0]);
  RawConstants(Ctx, Src, C.PSBytes, C.PSBlock, Buffers[1]);
  for I := 0 to MaxUnits - 1 do
  begin
    Images[I].sampler := VK_NULL_HANDLE;
    Images[I].imageView := TTextureVk(C.Units[I]).SampledView;
    if Images[I].imageView = VK_NULL_HANDLE then
      Images[I].imageView := G.Blank.View;
    Images[I].imageLayout := VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    Samplers[I].sampler := C.Samplers[I];
    Samplers[I].imageView := VK_NULL_HANDLE;
    Samplers[I].imageLayout := VK_IMAGE_LAYOUT_UNDEFINED;
  end;
  FillChar(Writes, SizeOf(Writes), 0);
  for I := 0 to High(Writes) do
    Writes[I].sType := VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
  Writes[0].dstBinding := BindingVS;
  Writes[0].descriptorCount := 1;
  Writes[0].descriptorType := VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
  Writes[0].pBufferInfo := @Buffers[0];
  Writes[1].dstBinding := BindingPS;
  Writes[1].descriptorCount := 1;
  Writes[1].descriptorType := VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
  Writes[1].pBufferInfo := @Buffers[1];
  // Consecutive bindings of one type and stage: one write each for the textures and the samplers.
  Writes[2].dstBinding := RawBindingImages;
  Writes[2].descriptorCount := MaxUnits;
  Writes[2].descriptorType := VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE;
  Writes[2].pImageInfo := @Images[0];
  Writes[3].dstBinding := RawBindingSamplers;
  Writes[3].descriptorCount := MaxUnits;
  Writes[3].descriptorType := VK_DESCRIPTOR_TYPE_SAMPLER;
  Writes[3].pImageInfo := @Samplers[0];
  if G.Push then
    Ctx.Vk.CmdPushDescriptorSetKHR(Cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, G.RawLayout, 0, Length(Writes),
      @Writes[0])
  else
  begin
    DescSet := Ctx.AllocSet(G.RawSetLayout);
    for I := 0 to High(Writes) do
      Writes[I].dstSet := DescSet;
    Ctx.Vk.UpdateDescriptorSets(Ctx.Device, Length(Writes), @Writes[0], 0, nil);
    Ctx.Vk.CmdBindDescriptorSets(Cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, G.RawLayout, 0, 1, @DescSet, 0, nil);
  end;
  // FMX's next draw binds its own descriptors again.
  R.Pushed := False;
  Ctx.Vk.CmdBindVertexBuffers(Cmd, 0, 1, @VBuf, @VOff);
  if C.Index32 then
    Ctx.Vk.CmdBindIndexBuffer(Cmd, IBuf, IOff, VK_INDEX_TYPE_UINT32)
  else
    Ctx.Vk.CmdBindIndexBuffer(Cmd, IBuf, IOff, VK_INDEX_TYPE_UINT16);
  Ctx.Vk.CmdDrawIndexed(Cmd, C.IndexCount, 1, 0, C.BaseVertex, 0);
end;

procedure HandleRawUpload(const AData: Pointer);
var
  C: PCmdRawUpload;
  T: TTextureVk;
  Ctx: TGpuVkContext;
  Src, P: PByte;
  Buf: TVkBuffer;
  Off: UInt64;
  Bytes: NativeInt;
  Region: TVkBufferImageCopy;
  Written: Boolean;
begin
  C := AData;
  T := C.Texture;
  if T.Image = VK_NULL_HANDLE then
    Exit;
  if C.Blob <> nil then
    Src := @TBlob(C.Blob).Data[0]
  else
    Src := PByte(C) + SizeOf(TCmdRawUpload);
  Ctx := GpuVk;
  Bytes := NativeInt(C.Rows) * C.RowBytes;
  P := Ctx.Upload(Bytes, 16, Buf, Off);
  Move(Src^, P^, Bytes);
  // After the zeroes of a new texture and the copies before (they may overlap).
  Written := T.Uncleared or (T.CurrentUse = TGpuVkUse.TransferDst);
  T.UseAs(TGpuVkUse.TransferDst);
  if Written then
    Ctx.MemoryBarrier(StageTransfer, AccessTransferWrite, StageTransfer, AccessTransferWrite);
  FillChar(Region, SizeOf(Region), 0);
  Region.bufferOffset := Off;
  Region.imageSubresource.aspectMask := Ord(VK_IMAGE_ASPECT_COLOR_BIT);
  Region.imageSubresource.mipLevel := C.Mip;
  Region.imageSubresource.baseArrayLayer := C.Layer;
  Region.imageSubresource.layerCount := 1;
  Region.imageOffset.x := C.X;
  Region.imageOffset.y := C.Y;
  Region.imageExtent.width := C.Width;
  Region.imageExtent.height := C.Height;
  Region.imageExtent.depth := 1;
  Ctx.Vk.CmdCopyBufferToImage(Ctx.TransferCmd, Buf, T.Image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, @Region);
end;

procedure HandleRawWrite(const AData: Pointer);
var
  C: PCmdRawWrite;
  B: TRawBufferVk;
  Ctx: TGpuVkContext;
  Src, P: PByte;
  Region: TVkBufferCopy;
  Buf: TVkBuffer;
begin
  C := AData;
  B := C.Buffer;
  if B.Buffer = VK_NULL_HANDLE then
    Exit;
  Ctx := GpuVk;
  // After the draws that read the buffer and the writes before.
  Ctx.MemoryBarrier(StageVertexInput or StageTransfer, AccessTransferWrite, StageTransfer, AccessTransferWrite);
  if C.Fill then
    Ctx.Vk.CmdFillBuffer(Ctx.TransferCmd, B.Buffer, 0, VK_WHOLE_SIZE, 0)
  else
  begin
    if C.Blob <> nil then
      Src := @TBlob(C.Blob).Data[0]
    else
      Src := PByte(C) + SizeOf(TCmdRawWrite);
    P := Ctx.Upload(C.Size, 16, Buf, Region.srcOffset);
    Move(Src^, P^, C.Size);
    Region.dstOffset := C.Offset;
    Region.size := C.Size;
    Ctx.Vk.CmdCopyBuffer(Ctx.TransferCmd, Buf, B.Buffer, 1, @Region);
  end;
  // Before the draws after it.
  Ctx.MemoryBarrier(StageTransfer, AccessTransferWrite, StageVertexInput, AccessIndexRead or AccessVertexRead);
end;

procedure HandleRawCopy(const AData: Pointer);
var
  C: PCmdRawCopy;
  Ctx: TGpuVkContext;
  S, D: TTextureVk;
  Written: Boolean;
  Region: TVkImageCopy;
  Blit: TVkImageBlit;
begin
  C := AData;
  S := C.Source;
  D := C.Dest;
  if (S.GpuImage = VK_NULL_HANDLE) or (D.Image = VK_NULL_HANDLE) then
    Exit;
  Ctx := GpuVk;
  S.UseAs(TGpuVkUse.TransferSrc);
  Written := D.Uncleared or (D.CurrentUse = TGpuVkUse.TransferDst);
  D.UseAs(TGpuVkUse.TransferDst);
  if Written then
    Ctx.MemoryBarrier(StageTransfer, AccessTransferWrite, StageTransfer, AccessTransferWrite);
  FillChar(Region, SizeOf(Region), 0);
  if C.Depth then
  begin
    // The whole depth and stencil, into a texture of the depth buffer's format.
    Region.srcSubresource.aspectMask := Ord(VK_IMAGE_ASPECT_DEPTH_BIT) or Ord(VK_IMAGE_ASPECT_STENCIL_BIT);
    Region.srcSubresource.layerCount := 1;
    Region.dstSubresource := Region.srcSubresource;
    Region.extent.width := Min(S.Width, D.Width);
    Region.extent.height := Min(S.Height, D.Height);
    Region.extent.depth := 1;
    Ctx.Vk.CmdCopyImage(Ctx.TransferCmd, S.GpuImage, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, D.Image,
      VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, @Region);
  end
  else if S.Format = D.Format then
  begin
    Region.srcSubresource := ColorLayers;
    Region.srcOffset.x := C.Rect.Left;
    Region.srcOffset.y := C.Rect.Top;
    Region.dstSubresource := ColorLayers;
    Region.dstOffset.x := C.X;
    Region.dstOffset.y := C.Y;
    Region.extent.width := C.Rect.Width;
    Region.extent.height := C.Rect.Height;
    Region.extent.depth := 1;
    Ctx.Vk.CmdCopyImage(Ctx.TransferCmd, S.GpuImage, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, D.Image,
      VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, @Region);
  end
  else
  begin
    // Another format: converted one to one.
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
    Ctx.Vk.CmdBlitImage(Ctx.TransferCmd, S.GpuImage, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, D.Image,
      VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, @Blit, VK_FILTER_NEAREST);
  end;
end;

procedure HandleRawReadback(const AData: Pointer);
var
  C: PCmdRawReadback;
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
  Region.imageSubresource.aspectMask := C.Aspect;
  Region.imageSubresource.layerCount := 1;
  Region.imageOffset.x := C.Rect.Left;
  Region.imageOffset.y := C.Rect.Top;
  Region.imageExtent.width := C.Rect.Width;
  Region.imageExtent.height := C.Rect.Height;
  Region.imageExtent.depth := 1;
  Ctx.Vk.CmdCopyImageToBuffer(Ctx.TransferCmd, S.GpuImage, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, C.Buffer, 1,
    @Region);
  Ctx.MemoryBarrier(StageTransfer, AccessTransferWrite, StageHost, AccessHostRead);
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

/// <summary>A rendering instance of its own that resolves the multisampled S into D (the scene's rendering instances
/// were split: S was stored); ADiscard: S is not stored again.</summary>
procedure ResolvePass(const S, D: TTextureVk; const ADiscard: Boolean);
var
  C: TGpuVkContext;
  Was, DestWas: TGpuVkUse;
  Zero: Boolean;
  Color: TVkRenderingAttachmentInfo;
  Info: TVkRenderingInfo;
begin
  if (S.GpuView = VK_NULL_HANDLE) or (D.GpuView = VK_NULL_HANDLE) then
    Exit;
  C := GpuVk;
  // Not drawn since its content was left out: the resolve is transparent.
  Zero := S.Uncleared;
  Was := S.CurrentUse;
  S.UseAs(TGpuVkUse.ColorTarget, Zero);
  S.Uncleared := False;
  if Was = TGpuVkUse.ColorTarget then
    C.MemoryBarrier(StageColorOutput, AccessColorWrite, StageColorOutput, AccessColorRead or AccessColorWrite);
  DestWas := D.CurrentUse;
  D.UseAs(TGpuVkUse.ColorTarget, True);
  if DestWas = TGpuVkUse.ColorTarget then
    C.MemoryBarrier(StageColorOutput, AccessColorWrite, StageColorOutput, AccessColorWrite);
  FillChar(Color, SizeOf(Color), 0);
  Color.sType := VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO;
  Color.imageView := S.GpuView;
  Color.imageLayout := VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
  Color.resolveMode := VK_RESOLVE_MODE_AVERAGE_BIT;
  Color.resolveImageView := D.GpuView;
  Color.resolveImageLayout := VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
  if Zero then
    Color.loadOp := VK_ATTACHMENT_LOAD_OP_CLEAR
  else
    Color.loadOp := VK_ATTACHMENT_LOAD_OP_LOAD;
  if ADiscard then
    Color.storeOp := VK_ATTACHMENT_STORE_OP_DONT_CARE
  else
    Color.storeOp := VK_ATTACHMENT_STORE_OP_STORE;
  FillChar(Info, SizeOf(Info), 0);
  Info.sType := VK_STRUCTURE_TYPE_RENDERING_INFO;
  Info.renderArea.extent.width := Max(Min(S.Width, D.Width), 1);
  Info.renderArea.extent.height := Max(Min(S.Height, D.Height), 1);
  Info.layerCount := 1;
  Info.colorAttachmentCount := 1;
  Info.pColorAttachments := @Color;
  // No draws: the subpass ends at once, with the resolve.
  C.BeginRenderingInfo(G, Info, S.Format, S.Samples);
  C.EndRendering;
  if ADiscard then
    S.Uncleared := True;
end;

procedure HandleEnd(const AData: Pointer);
var
  C: PCmdEnd;
  Ctx: TGpuVkContext;
  T: TTextureVk;
begin
  C := AData;
  T := C.Target;
  Ctx := GpuVk;
  if R.Ends and (R.EndsTarget <> nil) and ((R.EndsTarget as TObject) = TObject(T)) and (Ctx.Rendering = T) then
  begin
    // The scene's one rendering instance ends: its resolve is written, what it does not store is gone.
    Ctx.EndRendering;
    ForgetEnds(False);
    if GpuVkTiming then
      Inc(GpuVkTimeScenes[0]);
    Exit;
  end;
  if R.Ends then
  begin
    // Ended before the scene's end: the resolve has the image as drawn until then.
    ForgetEnds(True);
    Exit;
  end;
  if (C.Dest <> nil) and (T.Samples > 1) then
  begin
    ResolvePass(T, C.Dest, (R.Keep and KeepColor) = 0);
    if GpuVkTiming then
      Inc(GpuVkTimeScenes[1]);
  end;
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
    R.Ends := False;
    R.EndsTarget := nil;
    R.EndsDepth := nil;
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
  if FHolding then
    Dec(FastChunkHold);
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
{$IFDEF LINUX}
  else if Parent <> nil then
  begin
    // The platform's pixels (FMXWayland: the buffer size its viewport maps to the window).
    Result := FastWindowPixelSize(Parent, FWindowHandle, Width, Height);
    Result := TSize.Create(Max(1, Result.Width), Max(1, Result.Height));
  end
{$ENDIF}
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
  // The samples are resolved by the scene's rendering instances (EnsureRendering, ResolvePass): an attachment only,
  // which a tiler keeps in tile memory.
  if FSamples > 1 then
    FMSColor := NewTextureVk(Px.Width, Px.Height, 1, FSamples, TVkFormat(FFormat),
      Ord(VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT), False, False, True);
  // The ray-traced effects read the depth, raw draws copy and read it; else it is an attachment only too.
  if DepthStencil then
    if RaySupported or FRawDepth then
      FDepth := NewTextureVk(Px.Width, Px.Height, 1, FSamples, S.DepthFormat,
        Ord(VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT) or IfThen(RaySupported, Ord(VK_IMAGE_USAGE_SAMPLED_BIT), 0) or
        Ord(VK_IMAGE_USAGE_TRANSFER_SRC_BIT), True)
    else
      FDepth := NewTextureVk(Px.Width, Px.Height, 1, FSamples, S.DepthFormat,
        Ord(VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT), True, False, True);
  FKeep := 0;
  if FRawDepth then
    FKeep := KeepDepth or KeepStencil;
end;

procedure TFastContext3DVk.UseRawDepth;
var
  Px: TSize;
begin
  if FRawDepth then
    Exit;
  FRawDepth := True;
  // Copied and read after the scene too: stored at its end.
  FKeep := FKeep or KeepDepth or KeepStencil;
  if (FDepth <> nil) and TTextureVk(FDepth as TObject).Transient then
  begin
    Px := TargetPixels;
    FDepth := NewTextureVk(Px.Width, Px.Height, 1, FSamples, Shared.DepthFormat,
      Ord(VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT) or Ord(VK_IMAGE_USAGE_TRANSFER_SRC_BIT), True);
  end;
  if BeginSceneCount > 0 then
    RecordTarget;
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
  C.Keep := FKeep;
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
  FSceneCleared := 0;
  if (FMSColor <> nil) or (FDepth <> nil) then
  begin
    Inc(FastChunkHold);
    FHolding := True;
  end;
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
  T, Target: TTextureVk;
  C: PCmdEnd;
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
  // A scene that did not clear its multisampled color resolves what the scene before left in it.
  if (FMSColor <> nil) and ((FSceneCleared and KeepColor) = 0) then
    FKeep := FKeep or KeepColor;
  Target := TTextureVk(DrawTarget);
  if Target <> nil then
  begin
    C := Rec(HandleEnd, SizeOf(TCmdEnd), Target);
    C.Target := Target;
    C.Depth := nil;
    if FDepth <> nil then
    begin
      C.Depth := FDepth as TObject;
      Keep(FDepth);
    end;
    C.Dest := nil;
    if (FMSColor <> nil) and (T <> nil) then
    begin
      C.Dest := T;
      T.Used := True;
      Keep(T);
    end;
  end;
  if FHolding then
  begin
    Dec(FastChunkHold);
    FHolding := False;
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
  if C.ClearColor then
    FSceneCleared := FSceneCleared or KeepColor;
  if C.ClearDepth then
    FSceneCleared := FSceneCleared or KeepDepth;
  if C.ClearStencil then
    FSceneCleared := FSceneCleared or KeepStencil;
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

var
  /// <summary>TFastShader.Id: the SPIR-V of a shader of raw draws (shader modules are made again after a device
  /// loss).</summary>
  GRawCode: TDictionary<Integer, TBytes>;

/// <summary>A raw shader's SPIR-V (as dxc makes it of HLSL) as the context loads it: its resources moved to the
/// bindings of the raw descriptor set (the constant buffer of a vertex shader at BindingVS, of a pixel shader at
/// BindingPS, texture tN at RawBindingImages + N, sampler sN at RawBindingSamplers + N, set 0: dxc gives tN, sN, bN the
/// binding N, or N plus a shift of 16), and what the pipelines need of it (AShader: entry point, inputs, uniform block,
/// cube units). Raises EContext3DException for SPIR-V it cannot take.</summary>
procedure LoadRawSpirV(const ACode: TBytes; const AVertex: Boolean; const AShader: TShaderVk;
  out AWords: TArray<Cardinal>);
const
  OpName = 5;
  OpEntryPoint = 15;
  OpTypeInt = 21;
  OpTypeFloat = 22;
  OpTypeVector = 23;
  OpTypeMatrix = 24;
  OpTypeImage = 25;
  OpTypeSampler = 26;
  OpTypeArray = 28;
  OpTypeStruct = 30;
  OpTypePointer = 32;
  OpConstant = 43;
  OpVariable = 59;
  OpDecorate = 71;
  OpMemberDecorate = 72;
  DecBlock = 2;
  DecRowMajor = 4;
  DecArrayStride = 6;
  DecMatrixStride = 7;
  DecBuiltIn = 11;
  DecLocation = 30;
  DecBinding = 33;
  DecDescriptorSet = 34;
  DecOffset = 35;
  ScUniformConstant = 0;
  ScInput = 1;
  ScUniform = 2;
  ScPushConstant = 9;
  ScStorageBuffer = 12;
  DimCube = 3;
var
  W: TArray<Cardinal>;
  Bound, Op, Len, Pos, Id, Model, I, J, U, Unit_: Integer;
  TypeOp, Arg1, Arg2, Constant, Location, BindingPos, SetPos, Stride, VarStorage, VarType: TArray<Integer>;
  IsBuiltIn, IsBlock: TArray<Boolean>;
  Members: TArray<TArray<Integer>>;
  Names: TArray<string>;
  MemberDec: TDictionary<UInt64, Integer>;
  Entry: AnsiString;
  Name, Sem: string;
  HasBlock: Boolean;
  Pointee: Integer;

  function Fail(const AWhat: string): EContext3DException;
  begin
    Result := EContext3DException.Create('FastContext3DVk: raw shader: ' + AWhat);
  end;

  function Text(const AFrom, AEnd: Integer): string;
  var
    S: AnsiString;
  begin
    // A literal string: bytes in words, nul-terminated.
    S := '';
    if AFrom < AEnd then
      S := PAnsiChar(@W[AFrom]);
    Result := string(S);
  end;

  function MemberKey(const AStruct, AMember, ADecoration: Integer): UInt64;
  begin
    Result := (UInt64(AStruct) shl 32) or (UInt64(AMember) shl 8) or UInt64(ADecoration);
  end;

  /// <summary>Bytes of a type in a uniform block (a struct: up to the end of its last member).</summary>
  function TypeSize(const AType, AMatrixStride: Integer; const ARowMajor: Boolean): Integer;
  var
    MStride, M, Offset, Matrix, Row: Integer;
  begin
    Result := 0;
    if (AType <= 0) or (AType >= Bound) then
      Exit;
    case TypeOp[AType] of
      OpTypeInt, OpTypeFloat: Result := Arg1[AType] div 8;
      OpTypeVector: Result := Arg2[AType] * TypeSize(Arg1[AType], 0, False);
      OpTypeMatrix:
        begin
          MStride := AMatrixStride;
          if MStride = 0 then
            MStride := 16;
          // SPIR-V's row-major: a stride per row (the components of a column).
          if ARowMajor and (Arg1[AType] > 0) and (Arg1[AType] < Bound) then
            Result := MStride * Arg2[Arg1[AType]]
          else
            Result := MStride * Arg2[AType];
        end;
      OpTypeArray:
        if (Arg2[AType] > 0) and (Arg2[AType] < Bound) then
        begin
          if Stride[AType] > 0 then
            Result := Constant[Arg2[AType]] * Stride[AType]
          else
            Result := Constant[Arg2[AType]] * TypeSize(Arg1[AType], AMatrixStride, ARowMajor);
        end;
      OpTypeStruct:
        for M := 0 to High(Members[AType]) do
        begin
          if not MemberDec.TryGetValue(MemberKey(AType, M, DecOffset), Offset) then
            Continue;
          if not MemberDec.TryGetValue(MemberKey(AType, M, DecMatrixStride), Matrix) then
            Matrix := 0;
          Result := Max(Result, Offset + TypeSize(Members[AType][M], Matrix,
            MemberDec.TryGetValue(MemberKey(AType, M, DecRowMajor), Row)));
        end;
    end;
  end;

begin
  if (Length(ACode) < 20) or ((Length(ACode) and 3) <> 0) then
    raise Fail('not SPIR-V');
  SetLength(W, Length(ACode) div 4);
  Move(ACode[0], W[0], Length(ACode));
  if W[0] <> FastSpirVMagic then
    raise Fail('not SPIR-V');
  Bound := W[3];
  if (Bound <= 0) or (Bound > 4 * 1024 * 1024) then
    raise Fail('bad SPIR-V header');
  SetLength(TypeOp, Bound);
  SetLength(Arg1, Bound);
  SetLength(Arg2, Bound);
  SetLength(Constant, Bound);
  SetLength(Location, Bound);
  SetLength(BindingPos, Bound);
  SetLength(SetPos, Bound);
  SetLength(Stride, Bound);
  SetLength(VarStorage, Bound);
  SetLength(VarType, Bound);
  SetLength(IsBuiltIn, Bound);
  SetLength(IsBlock, Bound);
  SetLength(Members, Bound);
  SetLength(Names, Bound);
  for I := 0 to Bound - 1 do
  begin
    Location[I] := -1;
    BindingPos[I] := -1;
    SetPos[I] := -1;
    VarStorage[I] := -1;
  end;
  Model := -1;
  MemberDec := TDictionary<UInt64, Integer>.Create;
  try
    Pos := 5;
    while Pos < Length(W) do
    begin
      Op := W[Pos] and $FFFF;
      Len := W[Pos] shr 16;
      if (Len = 0) or (Pos + Len > Length(W)) then
        raise Fail('bad SPIR-V instruction');
      case Op of
        OpName:
          if W[Pos + 1] < Cardinal(Bound) then
            Names[W[Pos + 1]] := Text(Pos + 2, Pos + Len);
        OpEntryPoint:
          if Model < 0 then
          begin
            Model := W[Pos + 1];
            Entry := AnsiString(Text(Pos + 3, Pos + Len));
          end;
        OpTypeInt, OpTypeFloat, OpTypeVector, OpTypeMatrix, OpTypeImage, OpTypeSampler, OpTypeArray, OpTypePointer:
          begin
            Id := W[Pos + 1];
            if (Id > 0) and (Id < Bound) then
            begin
              TypeOp[Id] := Op;
              if Len > 2 then
                Arg1[Id] := W[Pos + 2];
              if Len > 3 then
                Arg2[Id] := W[Pos + 3];
              // OpTypeImage: the dimension is the third word.
              if Op = OpTypeImage then
                Arg1[Id] := W[Pos + 3];
            end;
          end;
        OpTypeStruct:
          begin
            Id := W[Pos + 1];
            if (Id > 0) and (Id < Bound) then
            begin
              TypeOp[Id] := Op;
              SetLength(Members[Id], Len - 2);
              for I := 0 to Len - 3 do
                Members[Id][I] := W[Pos + 2 + I];
            end;
          end;
        OpConstant:
          if (W[Pos + 2] < Cardinal(Bound)) and (Len > 3) then
            Constant[W[Pos + 2]] := W[Pos + 3];
        OpVariable:
          if W[Pos + 2] < Cardinal(Bound) then
          begin
            VarType[W[Pos + 2]] := W[Pos + 1];
            VarStorage[W[Pos + 2]] := W[Pos + 3];
          end;
        OpDecorate:
          begin
            Id := W[Pos + 1];
            if (Id > 0) and (Id < Bound) and (Len > 2) then
              case W[Pos + 2] of
                DecBlock: IsBlock[Id] := True;
                DecBuiltIn: IsBuiltIn[Id] := True;
                DecArrayStride: Stride[Id] := W[Pos + 3];
                DecLocation: Location[Id] := W[Pos + 3];
                DecBinding: BindingPos[Id] := Pos + 3;
                DecDescriptorSet: SetPos[Id] := Pos + 3;
              end;
          end;
        OpMemberDecorate:
          if Len > 3 then
            case W[Pos + 3] of
              DecOffset, DecMatrixStride:
                MemberDec.AddOrSetValue(MemberKey(W[Pos + 1], W[Pos + 2], W[Pos + 3]), W[Pos + 4]);
              DecRowMajor:
                MemberDec.AddOrSetValue(MemberKey(W[Pos + 1], W[Pos + 2], W[Pos + 3]), 1);
            end;
      end;
      Inc(Pos, Len);
    end;
    // Vertex 0, Fragment 4.
    if AVertex and (Model <> 0) then
      raise Fail('not a vertex shader');
    if not AVertex and (Model <> 4) then
      raise Fail('not a pixel shader');
    AShader.Entry := Entry;
    AShader.Block := 0;
    AShader.Inputs := 0;
    AShader.CubeUnits := 0;
    HasBlock := False;
    for Id := 1 to Bound - 1 do
    begin
      if VarStorage[Id] < 0 then
        Continue;
      Pointee := 0;
      if (VarType[Id] > 0) and (VarType[Id] < Bound) and (TypeOp[VarType[Id]] = OpTypePointer) then
        Pointee := Arg2[VarType[Id]];
      case VarStorage[Id] of
        ScInput:
          if AVertex and not IsBuiltIn[Id] and (Location[Id] >= 0) and (Location[Id] < 32) then
          begin
            AShader.Inputs := AShader.Inputs or (Cardinal(1) shl Location[Id]);
            // dxc: in.var.<SEMANTIC><index>
            Name := Names[Id];
            if Name.StartsWith('in.var.', True) then
            begin
              Sem := UpperCase(Name.Substring(7));
              J := Length(Sem);
              while (J > 0) and CharInSet(Sem[J], ['0'..'9']) do
                Dec(J);
              U := 0;
              if J < Length(Sem) then
                U := StrToIntDef(Copy(Sem, J + 1, MaxInt), 0);
              AShader.InputNames := AShader.InputNames + [Copy(Sem, 1, J)];
              AShader.InputIndices := AShader.InputIndices + [U];
              AShader.InputLocations := AShader.InputLocations + [Location[Id]];
            end;
          end;
        ScUniformConstant, ScUniform, ScStorageBuffer, ScPushConstant:
          begin
            if (BindingPos[Id] < 0) or (Pointee <= 0) or (Pointee >= Bound) then
              raise Fail(Format('resource "%s" without a binding', [Names[Id]]));
            Unit_ := Integer(W[BindingPos[Id]]) mod 16;
            if (VarStorage[Id] = ScUniform) and (TypeOp[Pointee] = OpTypeStruct) and IsBlock[Pointee] then
            begin
              if HasBlock then
                raise Fail('more than one constant buffer (one at b0)');
              HasBlock := True;
              AShader.Block := TypeSize(Pointee, 0, False);
              W[BindingPos[Id]] := IfThen(AVertex, BindingVS, BindingPS);
            end
            else if (VarStorage[Id] = ScUniformConstant) and (TypeOp[Pointee] = OpTypeImage) and not AVertex and
              (Unit_ < MaxUnits) then
            begin
              W[BindingPos[Id]] := RawBindingImages + Unit_;
              if Arg1[Pointee] = DimCube then
                AShader.CubeUnits := AShader.CubeUnits or (Cardinal(1) shl Unit_);
            end
            else if (VarStorage[Id] = ScUniformConstant) and (TypeOp[Pointee] = OpTypeSampler) and not AVertex and
              (Unit_ < MaxUnits) then
              W[BindingPos[Id]] := RawBindingSamplers + Unit_
            else
              raise Fail(Format('resource "%s": raw draws take a constant buffer at b0, textures at t0-t7 and ' +
                'samplers at s0-s7 of the pixel shader', [Names[Id]]));
            if SetPos[Id] >= 0 then
              W[SetPos[Id]] := 0;
          end;
      end;
    end;
  finally
    MemberDec.Free;
  end;
  AWords := W;
end;

/// <summary>The shader module of a raw shader's SPIR-V.</summary>
function NewRawShaderVk(const ACode: TBytes; const AVertex: Boolean): TShaderVk;
var
  F: TFastVulkan;
  Info: TVkShaderModuleCreateInfo;
  Words: TArray<Cardinal>;
begin
  GpuVk;
  F := TFastDevice.Vulkan;
  Result := TShaderVk.Create;
  try
    Result.Raw := True;
    LoadRawSpirV(ACode, AVertex, Result, Words);
    FillChar(Info, SizeOf(Info), 0);
    Info.sType := VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
    Info.codeSize := Length(Words) * 4;
    Info.pCode := @Words[0];
    Check(F.Vk.CreateShaderModule(F.Device, @Info, nil, @Result.Module), 'vkCreateShaderModule (raw)');
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
  Code: TBytes;
begin
  if AShader.Native = nil then
  begin
    if (GShaderEntries <> nil) and GShaderEntries.TryGetValue(AShader.Id, Entry) then
      AShader.Native := NewShaderVk(Entry)
    else if (GRawCode <> nil) and GRawCode.TryGetValue(AShader.Id, Code) then
      AShader.Native := NewRawShaderVk(Code, AShader.Kind = TContextShaderKind.VertexShader)
    else
      Exit(nil);
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
  // A draw before the scene clears the multisampled color, the depth or the stencil it uses: later scenes read what
  // the scene before left there too (stored at every scene's end from now on).
  if (FMSColor <> nil) and ((FSceneCleared and KeepColor) = 0) then
    FKeep := FKeep or KeepColor;
  if (FDepth <> nil) and (FState.DepthTest or FState.DepthWrite) and ((FSceneCleared and KeepDepth) = 0) then
    FKeep := FKeep or KeepDepth;
  if (FDepth <> nil) and FState.Stencil and ((FSceneCleared and KeepStencil) = 0) then
    FKeep := FKeep or KeepStencil;
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

{ Raw draws (recording) }

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

procedure TFastContext3DVk.DrawRaw(const ADraw: TFastRawDraw);
var
  VS, PS: TFastShader;
  VSObj, PSObj: TShaderVk;
  S: TShared;
  T: TTextureVk;
  Key: TRawPipeKey;
  Pipe: TVkPipeline;
  C: PCmdRawDraw;
  VBytes, IBytes, VSBytes, PSBytes, I: Integer;
  Dst: PByte;
  Px: TSize;
  VObj, IObj: IInterface;
  Units: array[0..MaxUnits - 1] of IInterface;
  Samplers: array[0..MaxUnits - 1] of TVkSampler;
  Cube: Boolean;
begin
  if (BeginSceneCount = 0) or (ADraw.IndexCount <= 0) then
    Exit;
  VS := RawShader(ADraw.VertexShader);
  PS := RawShader(ADraw.PixelShader);
  if (VS = nil) or (PS = nil) then
    Exit;
  VSObj := ShaderObject(VS);
  PSObj := ShaderObject(PS);
  if (VSObj = nil) or (PSObj = nil) or not VSObj.Raw or not PSObj.Raw then
    Exit;
  UseRawDepth;
  T := TTextureVk(DrawTarget);
  if T = nil then
    Exit;
  S := Shared;
  // The GPU objects first: without one (no device right now) nothing is recorded.
  VObj := nil;
  IObj := nil;
  if ADraw.VertexBuffer <> nil then
  begin
    VObj := ADraw.VertexBuffer.Native;
    if VObj = nil then
      Exit;
    VBytes := 0;
  end
  else
  begin
    if (ADraw.Vertices = nil) or (ADraw.VertexCount <= 0) or (ADraw.Stride <= 0) then
      Exit;
    VBytes := ADraw.Stride * ADraw.VertexCount;
  end;
  if ADraw.IndexBuffer <> nil then
  begin
    IObj := ADraw.IndexBuffer.Native;
    if IObj = nil then
      Exit;
    IBytes := 0;
  end
  else
  begin
    if ADraw.Indices = nil then
      Exit;
    IBytes := ADraw.IndexCount * (2 + 2 * Ord(ADraw.Index32));
  end;
  VSBytes := 0;
  if ADraw.VSConstants <> nil then
    VSBytes := Max(ADraw.VSConstantSize, 0);
  PSBytes := 0;
  if ADraw.PSConstants <> nil then
    PSBytes := Max(ADraw.PSConstantSize, 0);
  FillChar(Key, SizeOf(Key), 0);
  Key.VS := VS.Id;
  Key.PS := PS.Id;
  Key.Layout := ADraw.Layout.Hash;
  Key.Stride := ADraw.Stride;
  Key.State := ADraw.State;
  Key.Topology := Ord(ADraw.Kind);
  Key.Samples := T.Samples;
  Key.Depth := FDepth <> nil;
  Key.Format := Ord(T.Format);
  // Made before the command: a pipeline or sampler that fails leaves no command half written.
  Pipe := S.RawPipe(Key, VSObj, PSObj, ADraw.Layout, ADraw.State);
  for I := 0 to MaxUnits - 1 do
  begin
    Samplers[I] := S.RawSampler(ADraw.Samplers[I]);
    // A texture of the kind the pixel shader declares (else the blank one of that kind).
    Units[I] := nil;
    if ADraw.Textures[I] <> nil then
    begin
      Units[I] := ADraw.Textures[I].Native;
      Cube := ((PSObj.CubeUnits shr I) and 1) <> 0;
      if (Units[I] <> nil) and (TTextureVk(Units[I] as TObject).Cube <> Cube) then
        Units[I] := nil;
    end;
  end;
  // A draw before the scene clears the multisampled color: later scenes read what the scene before left there too
  // (the depth and stencil of a context that draws raw are kept anyway).
  if (FMSColor <> nil) and ((FSceneCleared and KeepColor) = 0) then
    FKeep := FKeep or KeepColor;
  C := Rec(HandleRawDraw, SizeOf(TCmdRawDraw) + VBytes + AlignUp(IBytes, 4) + VSBytes + PSBytes);
  C.Pipe := Pipe;
  C.StencilRef := ADraw.StencilRef;
  Px := TargetPixels;
  if ADraw.Scissor.IsEmpty then
    C.Scissor := TRect.Create(0, 0, Px.Width, Px.Height)
  else
    C.Scissor := ADraw.Scissor;
  C.Viewport := ADraw.Viewport;
  C.VertexBuffer := nil;
  C.IndexBuffer := nil;
  if VObj <> nil then
  begin
    C.VertexBuffer := VObj as TObject;
    Keep(VObj);
  end;
  if IObj <> nil then
  begin
    C.IndexBuffer := IObj as TObject;
    Keep(IObj);
  end;
  C.VertexOffset := ADraw.VertexOffset;
  C.IndexOffset := ADraw.IndexOffset;
  C.VertexBytes := VBytes;
  C.IndexBytes := IBytes;
  C.VertexStride := ADraw.Stride;
  C.IndexCount := ADraw.IndexCount;
  if ADraw.IndexBuffer <> nil then
    C.BaseVertex := ADraw.BaseVertex
  else
    C.BaseVertex := 0;
  C.Index32 := ADraw.Index32;
  C.VSBytes := VSBytes;
  C.PSBytes := PSBytes;
  C.VSBlock := VSObj.Block;
  C.PSBlock := PSObj.Block;
  for I := 0 to MaxUnits - 1 do
  begin
    if Units[I] <> nil then
    begin
      C.Units[I] := Units[I] as TObject;
      TTextureVk(C.Units[I]).Used := True;
      Keep(Units[I]);
    end
    else if ((PSObj.CubeUnits shr I) and 1) <> 0 then
      C.Units[I] := S.BlankCube
    else
      C.Units[I] := S.Blank;
    C.Samplers[I] := Samplers[I];
  end;
  Dst := PByte(C) + SizeOf(TCmdRawDraw);
  if VBytes > 0 then
  begin
    Move(ADraw.Vertices^, Dst^, VBytes);
    Inc(Dst, VBytes);
  end;
  if IBytes > 0 then
  begin
    Move(ADraw.Indices^, Dst^, IBytes);
    Inc(Dst, AlignUp(IBytes, 4));
  end;
  if VSBytes > 0 then
  begin
    Move(ADraw.VSConstants^, Dst^, VSBytes);
    Inc(Dst, VSBytes);
  end;
  if PSBytes > 0 then
    Move(ADraw.PSConstants^, Dst^, PSBytes);
  // FMX's next draw sends its constants again.
  FVSDirty := True;
  FPSDirty := True;
end;

procedure TFastContext3DVk.CopyToTexture(const ADest: TFastTexture; const ADestX, ADestY: Integer;
  const ASource: TRect; const ADepth: Boolean);
var
  Src, D: TTextureVk;
  Obj: IInterface;
  C: PCmdRawCopy;
  R: TRect;
begin
  if (ADest = nil) or (BeginSceneCount = 0) then
    Exit;
  TCanvas.Lock;
  try
    Obj := ADest.Native;
    if Obj = nil then
      Exit;
    D := TTextureVk(Obj as TObject);
    if ADepth then
    begin
      UseRawDepth;
      if (FDepth = nil) or (FSamples > 1) or not D.IsDepth then
        Exit;
      Src := TTextureVk(FDepth as TObject);
      R := TRect.Create(0, 0, Min(Src.Width, D.Width), Min(Src.Height, D.Height));
    end
    else
    begin
      if (FMSColor <> nil) or D.IsDepth or (D.BlockBytes > 0) or D.Cube then
        Exit;
      Src := TTextureVk(DrawTarget);
      if Src = nil then
        Exit;
      R := TRect.Intersect(ASource, TRect.Create(0, 0, Src.Width, Src.Height));
      R.Right := Min(R.Right, R.Left + D.Width - ADestX);
      R.Bottom := Min(R.Bottom, R.Top + D.Height - ADestY);
    end;
    if R.IsEmpty or (ADestX < 0) or (ADestY < 0) then
      Exit;
    Src.Used := True;
    D.Used := True;
    C := Rec(HandleRawCopy, SizeOf(TCmdRawCopy), Src);
    C.Source := Src;
    C.Dest := D;
    Keep(Obj);
    C.Rect := R;
    C.X := ADestX;
    C.Y := ADestY;
    C.Depth := ADepth;
  finally
    TCanvas.Unlock;
  end;
end;

procedure TFastContext3DVk.ReadTarget(const ARect: TRect; const AKind: TFastReadKind; const ADest: Pointer;
  const APitch: Integer);
var
  Src: TTextureVk;
  Ctx: TGpuVkContext;
  Buffer: TVkBuffer;
  Memory: TFastVkAllocation;
  C: PCmdRawReadback;
  R: TRect;
  X, Y, Bpp: Integer;
  Aspect: Cardinal;
  Row: PByte;
  Unorm: Boolean;
begin
  if AKind = TFastReadKind.Color then
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
    if BytesPerPixel(Src.Format) <> 4 then
      Exit;
    Aspect := Ord(VK_IMAGE_ASPECT_COLOR_BIT);
    Bpp := 4;
  end
  else
  begin
    UseRawDepth;
    if (FDepth = nil) or (FSamples > 1) then
      Exit;
    Src := TTextureVk(FDepth as TObject);
    // Copies of the depth aspect: 32-bit float, or 24 bits in 32 (D24_UNORM_S8_UINT); of the stencil: a byte.
    if AKind = TFastReadKind.Depth then
    begin
      Aspect := Ord(VK_IMAGE_ASPECT_DEPTH_BIT);
      Bpp := 4;
    end
    else
    begin
      Aspect := Ord(VK_IMAGE_ASPECT_STENCIL_BIT);
      Bpp := 1;
    end;
  end;
  Unorm := Src.Format = VK_FORMAT_D24_UNORM_S8_UINT;
  R := TRect.Intersect(ARect, TRect.Create(0, 0, Src.Width, Src.Height));
  if R.IsEmpty then
    Exit;
  TFastDevice.Lock;
  try
    Ctx := GpuVk;
    Buffer := Ctx.NewBuffer(UInt64(R.Width) * UInt64(R.Height) * UInt64(Bpp), Ord(VK_BUFFER_USAGE_TRANSFER_DST_BIT),
      Ord(VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT), Ord(VK_MEMORY_PROPERTY_HOST_CACHED_BIT), Memory);
  finally
    TFastDevice.Unlock;
  end;
  try
    TCanvas.Lock;
    try
      Src.Used := True;
      C := Rec(HandleRawReadback, SizeOf(TCmdRawReadback), Src);
      C.Source := Src;
      C.Buffer := Buffer;
      C.Rect := R;
      C.Aspect := Aspect;
    finally
      TCanvas.Unlock;
    end;
    // Everything recorded so far runs, then the GPU finishes it.
    FastBridge.Sync();
    TGpuVkBackend.WaitIdle;
    TFastDevice.Vulkan.Invalidate(Memory);
    for Y := 0 to R.Height - 1 do
    begin
      Row := Memory.Cpu + NativeInt(Y) * R.Width * Bpp;
      if (AKind = TFastReadKind.Depth) and Unorm then
        for X := 0 to R.Width - 1 do
          PSingle(PByte(ADest) + NativeInt(Y) * APitch + X * 4)^ := (PCardinal(Row + X * 4)^ and $FFFFFF) / $FFFFFF
      else
        Move(Row^, (PByte(ADest) + NativeInt(Y) * APitch)^, R.Width * Bpp);
    end;
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

/// <summary>The Vulkan format of a raw texture format (Depth24: the device's depth and stencil format).</summary>
function RawTextureFormat(const AFormat: TFastTextureFormat; const ADepth: TVkFormat): TVkFormat;
begin
  case AFormat of
    TFastTextureFormat.RGBA8: Result := VK_FORMAT_R8G8B8A8_UNORM;
    TFastTextureFormat.BGRA8: Result := VK_FORMAT_B8G8R8A8_UNORM;
    TFastTextureFormat.R8: Result := VK_FORMAT_R8_UNORM;
    TFastTextureFormat.RG8: Result := VK_FORMAT_R8G8_UNORM;
    TFastTextureFormat.R16: Result := VK_FORMAT_R16_UNORM;
    TFastTextureFormat.RG16: Result := VK_FORMAT_R16G16_UNORM;
    TFastTextureFormat.RGBA16F: Result := VK_FORMAT_R16G16B16A16_SFLOAT;
    TFastTextureFormat.RGBA32F: Result := VK_FORMAT_R32G32B32A32_SFLOAT;
    // Direct3D's BC1 has one bit of alpha.
    TFastTextureFormat.BC1: Result := VK_FORMAT_BC1_RGBA_UNORM_BLOCK;
    TFastTextureFormat.BC2: Result := VK_FORMAT_BC2_UNORM_BLOCK;
    TFastTextureFormat.BC3: Result := VK_FORMAT_BC3_UNORM_BLOCK;
    TFastTextureFormat.BC4: Result := VK_FORMAT_BC4_UNORM_BLOCK;
    TFastTextureFormat.BC5: Result := VK_FORMAT_BC5_UNORM_BLOCK;
  else
    Result := ADepth;
  end;
end;

/// <summary>The format a block-compressed format is decoded into where the device has no BC formats.</summary>
function DecodedFormat(const AFormat: TFastTextureFormat): TFastTextureFormat;
begin
  case AFormat of
    TFastTextureFormat.BC4: Result := TFastTextureFormat.R8;
    TFastTextureFormat.BC5: Result := TFastTextureFormat.RG8;
  else
    Result := TFastTextureFormat.RGBA8;
  end;
end;

/// <summary>The 8 values of a BC3 alpha / BC4 block (at P) and its 3-bit indices.</summary>
procedure AlphaBlock(const P: PByte; out AValues: array of Byte; out AIndices: UInt64);
var
  A0, A1, K: Integer;
begin
  A0 := P[0];
  A1 := P[1];
  AValues[0] := A0;
  AValues[1] := A1;
  if A0 > A1 then
    for K := 1 to 6 do
      AValues[1 + K] := ((7 - K) * A0 + K * A1 + 3) div 7
  else
  begin
    for K := 1 to 4 do
      AValues[1 + K] := ((5 - K) * A0 + K * A1 + 2) div 5;
    AValues[6] := 0;
    AValues[7] := 255;
  end;
  AIndices := 0;
  for K := 0 to 5 do
    AIndices := AIndices or (UInt64(P[2 + K]) shl (8 * K));
end;

/// <summary>A BC1 color block (at P) into ADest's 16 pixels (RGBA, rows of 4); ABC1: the three-color mode with a
/// transparent black when color0 <= color1 (BC2 and BC3 always have four colors).</summary>
procedure ColorBlock(const P: PByte; const ABC1: Boolean; var ADest: array of Cardinal);
var
  C0, C1: Word;
  Pal: array[0..3, 0..3] of Integer;
  Idx: Cardinal;
  I, K: Integer;

  procedure Expand(const AColor: Word; const AIndex: Integer);
  var
    V: Integer;
  begin
    V := (AColor shr 11) and 31;
    Pal[AIndex, 0] := (V shl 3) or (V shr 2);
    V := (AColor shr 5) and 63;
    Pal[AIndex, 1] := (V shl 2) or (V shr 4);
    V := AColor and 31;
    Pal[AIndex, 2] := (V shl 3) or (V shr 2);
    Pal[AIndex, 3] := 255;
  end;

begin
  C0 := PWord(P)^;
  C1 := PWord(P + 2)^;
  Idx := PCardinal(P + 4)^;
  Expand(C0, 0);
  Expand(C1, 1);
  for K := 0 to 2 do
    if (C0 > C1) or not ABC1 then
    begin
      Pal[2, K] := (2 * Pal[0, K] + Pal[1, K] + 1) div 3;
      Pal[3, K] := (Pal[0, K] + 2 * Pal[1, K] + 1) div 3;
    end
    else
    begin
      Pal[2, K] := (Pal[0, K] + Pal[1, K]) div 2;
      Pal[3, K] := 0;
    end;
  Pal[2, 3] := 255;
  if (C0 > C1) or not ABC1 then
    Pal[3, 3] := 255
  else
    Pal[3, 3] := 0;
  for I := 0 to 15 do
  begin
    K := (Idx shr (2 * I)) and 3;
    ADest[I] := Cardinal(Pal[K, 0]) or (Cardinal(Pal[K, 1]) shl 8) or (Cardinal(Pal[K, 2]) shl 16) or
      (Cardinal(Pal[K, 3]) shl 24);
  end;
end;

/// <summary>Blocks of BC1-BC5 (rows of ARowPitch bytes) decoded into AWidth x AHeight pixels of DecodedFormat.
/// </summary>
function DecodeBlocks(const AFormat: TFastTextureFormat; const AData: Pointer; const ARowPitch, AWidth,
  AHeight: Integer): TBytes;
var
  Bpp, BX, BY, I, X, Y, Ch: Integer;
  Block: PByte;
  Pixels: array[0..15] of Cardinal;
  Values: array[0..7] of Byte;
  Indices: UInt64;
  Out_: PByte;
begin
  Bpp := FastTextureBlockBytes(DecodedFormat(AFormat));
  SetLength(Result, NativeInt(AWidth) * AHeight * Bpp);
  for BY := 0 to (AHeight + 3) div 4 - 1 do
    for BX := 0 to (AWidth + 3) div 4 - 1 do
    begin
      Block := PByte(AData) + NativeInt(BY) * ARowPitch + BX * FastTextureBlockBytes(AFormat);
      case AFormat of
        TFastTextureFormat.BC1: ColorBlock(Block, True, Pixels);
        TFastTextureFormat.BC2:
          begin
            ColorBlock(Block + 8, False, Pixels);
            for I := 0 to 15 do
              Pixels[I] := (Pixels[I] and $FFFFFF) or
                (Cardinal(((PUInt64(Block)^ shr (4 * I)) and $F) * 17) shl 24);
          end;
        TFastTextureFormat.BC3:
          begin
            ColorBlock(Block + 8, False, Pixels);
            AlphaBlock(Block, Values, Indices);
            for I := 0 to 15 do
              Pixels[I] := (Pixels[I] and $FFFFFF) or (Cardinal(Values[(Indices shr (3 * I)) and 7]) shl 24);
          end;
      else
        // BC4: red; BC5: red and green.
        for Ch := 0 to Ord(AFormat = TFastTextureFormat.BC5) do
        begin
          AlphaBlock(Block + 8 * Ch, Values, Indices);
          for I := 0 to 15 do
          begin
            if Ch = 0 then
              Pixels[I] := 0;
            Pixels[I] := Pixels[I] or (Cardinal(Values[(Indices shr (3 * I)) and 7]) shl (8 * Ch));
          end;
        end;
      end;
      for I := 0 to 15 do
      begin
        X := BX * 4 + (I and 3);
        Y := BY * 4 + (I shr 2);
        if (X < AWidth) and (Y < AHeight) then
        begin
          Out_ := @Result[(NativeInt(Y) * AWidth + X) * Bpp];
          Move(Pixels[I], Out_^, Bpp);
        end;
      end;
    end;
end;

class function TFastContext3DVk.NewTextureObject(const ATexture: TFastTexture): IInterface;
var
  F: TFastVulkan;
  T: TTextureVk;
  Format: TVkFormat;
  Props: TVkFormatProperties;
  Decode: Boolean;
begin
  TFastDevice.Ensure;
  F := TFastDevice.Vulkan;
  if (F = nil) or (F.DepthFormat = VK_FORMAT_UNDEFINED) then
    raise EContext3DException.Create('FastContext3DVk: raw textures need the Vulkan canvas');
  // Block-compressed formats are decoded on the CPU where the device has none of them (phones).
  Decode := FastTextureCompressed(ATexture.Format) and (F.Features.textureCompressionBC = VK_FALSE);
  if Decode then
    Format := RawTextureFormat(DecodedFormat(ATexture.Format), F.DepthFormat)
  else
    Format := RawTextureFormat(ATexture.Format, F.DepthFormat);
  FillChar(Props, SizeOf(Props), 0);
  F.InstanceVk.GetPhysicalDeviceFormatProperties(F.Physical, Format, @Props);
  if (Props.optimalTilingFeatures and Ord(VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT)) = 0 then
    raise EContext3DException.CreateFmt('FastContext3DVk: the device cannot sample textures of the raw format %d',
      [Ord(ATexture.Format)]);
  T := NewTextureVk(ATexture.Width, ATexture.Height, ATexture.Mips, 1, Format, Ord(VK_IMAGE_USAGE_SAMPLED_BIT) or
    Ord(VK_IMAGE_USAGE_TRANSFER_SRC_BIT), ATexture.Format = TFastTextureFormat.Depth24, False, False,
    ATexture.Kind = TFastTextureKind.Cube);
  Result := T;
  // Zeroed before its first use (as Direct3D 12's committed resources are).
  T.Uncleared := True;
  T.Decode := ATexture.Format;
  T.Decoded := Decode;
  if FastTextureCompressed(ATexture.Format) and not Decode then
    T.BlockBytes := FastTextureBlockBytes(ATexture.Format);
end;

class procedure TFastContext3DVk.UploadTextureObject(const ATexture: TFastTexture; const AObject: IInterface;
  const AFace, AMip, X, Y, AWidth, AHeight: Integer; const AData: Pointer; const ARowPitch: Integer);
var
  T: TTextureVk;
  C: PCmdRawUpload;
  B: TBlob;
  BRef: IInterface;
  Rows, RowBytes, Pitch, I: Integer;
  Src, Dst: PByte;
  Pixels: TBytes;
begin
  T := TTextureVk(AObject as TObject);
  // A depth texture is written by copies of the depth buffer only.
  if T.IsDepth then
    Exit;
  Src := AData;
  Pitch := ARowPitch;
  if T.Decoded then
  begin
    Pixels := DecodeBlocks(ATexture.Format, AData, ARowPitch, AWidth, AHeight);
    Rows := AHeight;
    RowBytes := AWidth * FastTextureBlockBytes(DecodedFormat(ATexture.Format));
    Src := @Pixels[0];
    Pitch := RowBytes;
  end
  else if T.BlockBytes > 0 then
  begin
    Rows := (AHeight + 3) div 4;
    RowBytes := ((AWidth + 3) div 4) * T.BlockBytes;
  end
  else
  begin
    Rows := AHeight;
    RowBytes := AWidth * FastTextureBlockBytes(ATexture.Format);
  end;
  if NativeInt(Rows) * RowBytes <= RawInlineData then
  begin
    C := Rec(HandleRawUpload, SizeOf(TCmdRawUpload) + AlignUp(Rows * RowBytes, 4), AObject);
    C.Blob := nil;
    Dst := PByte(C) + SizeOf(TCmdRawUpload);
  end
  else
  begin
    B := TBlob.Create;
    BRef := B;
    SetLength(B.Data, NativeInt(Rows) * RowBytes);
    C := Rec(HandleRawUpload, SizeOf(TCmdRawUpload), AObject);
    C.Blob := B;
    Keep(BRef);
    Dst := @B.Data[0];
  end;
  for I := 0 to Rows - 1 do
    Move((Src + NativeInt(I) * Pitch)^, (Dst + NativeInt(I) * RowBytes)^, RowBytes);
  T.Used := True;
  C.Texture := T;
  C.Mip := AMip;
  C.Layer := AFace;
  C.X := X;
  C.Y := Y;
  C.Width := AWidth;
  C.Height := AHeight;
  C.Rows := Rows;
  C.RowBytes := RowBytes;
end;

class function TFastContext3DVk.NewBufferObject(const ABuffer: TFastBuffer): IInterface;
var
  F: TFastVulkan;
  B: TRawBufferVk;
  Info: TVkBufferCreateInfo;
  Req: TVkMemoryRequirements;
  C: PCmdRawWrite;
begin
  TFastDevice.Ensure;
  F := TFastDevice.Vulkan;
  if F = nil then
    raise EContext3DException.Create('FastContext3DVk: raw buffers need the Vulkan canvas');
  // The recording context exists: it drops what is left of the buffers when it shuts down.
  GpuVk;
  B := TRawBufferVk.Create;
  Result := B;
  B.Size := AlignUp(Max(ABuffer.Size, 16), 16);
  FillChar(Info, SizeOf(Info), 0);
  Info.sType := VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
  Info.size := B.Size;
  Info.usage := Ord(VK_BUFFER_USAGE_VERTEX_BUFFER_BIT) or Ord(VK_BUFFER_USAGE_INDEX_BUFFER_BIT) or
    Ord(VK_BUFFER_USAGE_TRANSFER_DST_BIT);
  Info.sharingMode := VK_SHARING_MODE_EXCLUSIVE;
  Check(F.Track(F.Vk.CreateBuffer(F.Device, @Info, nil, @B.Buffer)), 'vkCreateBuffer (raw)');
  AddLive(B);
  F.Vk.GetBufferMemoryRequirements(F.Device, B.Buffer, @Req);
  try
    B.Memory := F.Allocate(Req, Ord(VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT), 0, True);
  except
    on E: EFastVulkan do
      raise EContext3DException.Create(E.Message);
  end;
  Check(F.Vk.BindBufferMemory(F.Device, B.Buffer, B.Memory.Memory, B.Memory.Offset), 'vkBindBufferMemory (raw)');
  // Zeroed in order with the commands (as Direct3D 12's committed buffers are).
  C := Rec(HandleRawWrite, SizeOf(TCmdRawWrite), Result);
  C.Buffer := B;
  C.Blob := nil;
  C.Offset := 0;
  C.Size := 0;
  C.Fill := True;
end;

class procedure TFastContext3DVk.WriteBufferObject(const ABuffer: TFastBuffer; const AObject: IInterface;
  const AOffset: Integer; const AData: Pointer; const ASize: Integer);
var
  C: PCmdRawWrite;
  B: TBlob;
  BRef: IInterface;
begin
  if ASize <= RawInlineData then
  begin
    C := Rec(HandleRawWrite, SizeOf(TCmdRawWrite) + AlignUp(ASize, 4), AObject);
    C.Blob := nil;
    Move(AData^, (PByte(C) + SizeOf(TCmdRawWrite))^, ASize);
  end
  else
  begin
    B := TBlob.Create;
    BRef := B;
    SetLength(B.Data, ASize);
    Move(AData^, B.Data[0], ASize);
    C := Rec(HandleRawWrite, SizeOf(TCmdRawWrite), AObject);
    C.Blob := B;
    Keep(BRef);
  end;
  C.Buffer := AObject as TObject;
  C.Offset := AOffset;
  C.Size := ASize;
  C.Fill := False;
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
  // No Direct3D source (off Windows): the variables of a raw shader's SPIR-V source, or the entry of the GLSL source
  // and stage (one layout per source and stage, checked by tools\compile-fmx-shaders-vk.ps1) has the Direct3D
  // variables.
  AVariables := nil;
  Result := False;
  if FastSpirVSource(Shader, Glsl) then
  begin
    AVariables := Copy(Glsl.Variables);
    Exit(True);
  end;
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
  Code: TBytes;
begin
  Entry := -1;
  Name := '?';
  // A shader of raw draws: its own SPIR-V.
  if (GPendingShader <> nil) and FastSpirVSource(GPendingShader, Glsl) then
  begin
    Code := Copy(TBytes(Glsl.Code));
    AShader.Native := NewRawShaderVk(Code, AShader.Kind = TContextShaderKind.VertexShader);
    if GRawCode = nil then
      GRawCode := TDictionary<Integer, TBytes>.Create;
    GRawCode.AddOrSetValue(AShader.Id, Code);
    Exit;
  end;
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
      'the shaders of FMX''s materials and filters (FastCanvas.VkFmxShaders.inc) and shaders with a SPIR-V source ' +
      '(FastShaderArchSpirV) in raw draws', [Name]);
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
  R.Ends := False;
  R.EndsTarget := nil;
  R.EndsDepth := nil;
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
    else if O is TRawBufferVk then
      TRawBufferVk(O).Drop(AContext)
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
  // Raw textures and buffers get new (empty) objects on the new device when used next.
  TFastContext3D.RawDeviceLost;
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
  // A program that unregisters the context class before the canvas class (a console program): the pipelines,
  // layouts and samplers go with the recording context.
  if G <> nil then
    G.Release(nil);
  FreeAndNil(G);
  FreeAndNil(GShaderEntries);
  FreeAndNil(GRawCode);
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
  TFastContext3D.SetInstalled(TFastContext3DVk);
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
