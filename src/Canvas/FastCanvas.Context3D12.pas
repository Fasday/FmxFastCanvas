unit FastCanvas.Context3D12;

{ Own Direct3D 12 3D context of FastCanvas (stage 5), on the device and queue of the canvas when it runs on
  Direct3D 12 (FastCanvasBackend = D3D12).

  Recording: the thread that draws (the main thread) writes compact commands into the canvas command stream
  (FastBridge.RecordNative): targets, clears, draws with their vertices, indices and changed constants, copies,
  texture updates, presents. The render thread replays them into the canvas's own command list, in program order
  with the 2D work: one list and one ExecuteCommandLists per chunk of the stream for both, no driver work on the
  main thread. (A first version recorded a list per batch on the main thread: a dozen lists per frame of the effects
  scene cost 20 % of the frame rate and 1.5 MB per allocator, measured 2026-10-08.)

  Main thread: pipeline state objects (one per shader pair, vertex layout, state, target format), the root
  signature, sampler tables and resources are made where FMX asks for them; the Direct3D 12 device is free-threaded.
  Render thread: resource states, descriptors of views, upload memory and shader-visible descriptor tables, all
  from the canvas's recording context (FastCanvas.Gpu12), which also keeps released resources until the GPU is done.

  Bitmaps of the canvas are used in place (DoBitmapToTexture, DoCopyToBitmap): their state is the canvas's. Mipmaps
  are made on the CPU when a texture is updated (Direct3D 12 has no GenerateMips).

  Ray-traced effects (RayTracing, FastContext3DRayTracing; DXR tier 1.1): shadows from the scene's lights, ambient
  occlusion and reflections in light materials, added to any FMX scene after it is drawn
  (FastCanvas.Context3D12.Ray.inc). Off, they cost nothing.

  Application ray passes (RayScene, RayDispatch, RayDraw; DXR tier 1.1): the application runs its own DXIL, compute
  or full-screen pixel shaders, over the acceleration structure of the opaque objects drawn so far, the depth buffer,
  and its own buffers (TFastRayBuffer), images (TFastRayImage) and FMX textures, with a fixed root signature
  (Shaders\FastRayApp.hlsli). Threads as for everything else: recorded on the thread that draws, in its order with
  the draws; executed on the render thread. They need a 3D target without multisampling: an application that uses
  them asks TFastContext3D12.RayTracingSupported and then turns multisampling off.

  HDR: a context that draws into a texture (TViewport3D) has an RGBA16F target with Hdr; a window context (TForm3D)
  outputs HDR as the canvas does the windows of 2D forms (FastCanvas.Hdr.FastCanvasHdr, the window's display): an FP16
  scRGB swap chain, the scene in an RGBA16F target, the output pass of the canvas at Present. DrawIntensity takes
  draws above SDR white. }

interface

{$SCOPEDENUMS ON}

uses
  System.Types, System.UITypes, System.SysUtils, System.Math, System.Math.Vectors, System.Generics.Collections,
  FMX.Types, FMX.Types3D, FMX.Graphics, FastCanvas.Context3D, FastCanvas.Dlss;

type
  /// <summary>Ray-traced effects of a TFastContext3D12 (DXR tier 1.1 hardware; ignored without it).</summary>
  TFastRayTracing = record
    /// <summary>Shadows of the opaque 3D objects from the lights of the scene (TLight).</summary>
    Shadows: Boolean;
    /// <summary>0..1: the share of a light's contribution a shadow takes away.</summary>
    ShadowStrength: Single;
    /// <summary>0: hard shadows (one ray per light and pixel); more: softer (the lights' angular radius, as its
    /// tangent: 0.05 is about 3 degrees), traced at half resolution and smoothed.</summary>
    ShadowSoftness: Single;
    /// <summary>Rays per light and pixel for soft shadows.</summary>
    ShadowSamples: Integer;
    /// <summary>Ambient occlusion: surfaces darken where other surfaces are near (corners, gaps, contacts). Traced at
    /// half resolution and smoothed.</summary>
    AmbientOcclusion: Boolean;
    /// <summary>How far occluders count, in scene units.</summary>
    AORadius: Single;
    /// <summary>0..1: how dark a fully occluded surface gets.</summary>
    AOStrength: Single;
    /// <summary>Rays per pixel for ambient occlusion.</summary>
    AOSamples: Integer;
    /// <summary>Mirror reflections of the scene in the surfaces of TLightMaterial (TLightMaterialSource): as strong
    /// as their specular color times Shininess / 128, more at grazing angles (Fresnel). The surfaces seen in them
    /// are shaded as FMX shades them (colors, textures, lights, shadows when Shadows is on); a ray that leaves the
    /// scene sees the scene's clear color. One more ray per pixel, plus one per light for shadows in reflections.
    /// </summary>
    Reflections: Boolean;
    /// <summary>0..1: scales every reflection.</summary>
    ReflectionStrength: Single;
  end;

  /// <summary>Pixel formats of TFastRayImage: unsigned normalized (R8, RGBA8), float (F) and unsigned integer (UI,
  /// read and written in HLSL through AppUTextures / AppUImages).</summary>
  TFastRayFormat = (R8, RGBA8, R16F, RG16F, RGBA16F, R32F, RG32F, RGBA32F, R32UI, RG32UI, RGBA32UI);

  /// <summary>GPU memory of application ray passes (TFastRayBuffer, TFastRayImage), usable as SRV and UAV entries of
  /// TFastContext3D12.RayDispatch and RayDraw. Made zeroed on the Direct3D 12 device of the canvas (FastCanvasBackend =
  /// D3D12); the object may be freed while recorded passes still use it (they keep the memory).</summary>
  TFastRayResource = class abstract
  private
    FNative: IInterface;
    FDeviceGen: Integer;
    FGeneration: Integer;
    function GetGeneration: Integer;
  protected
    function CreateNative: IInterface; virtual; abstract;
    /// <summary>The GPU memory on the current device (made again after a device loss), nil when it cannot be made
    /// (no device right now). Holds TCanvas.Lock.</summary>
    function Native: IInterface;
  public
    constructor Create;
    destructor Destroy; override;
    /// <summary>Counts the times the GPU memory was made: 1 after Create, more after a device loss (the contents are
    /// lost: zero again). Compare it with the value of the last upload and write the contents again when it differs.
    /// Reading it makes the memory on a new device.</summary>
    property Generation: Integer read GetGeneration;
  end;

  /// <summary>A GPU buffer of application ray passes: ByteAddressBuffer (SRV entry) and RWByteAddressBuffer (UAV
  /// entry) in HLSL.</summary>
  TFastRayBuffer = class(TFastRayResource)
  private
    FSize: Integer;
  protected
    function CreateNative: IInterface; override;
  public
    constructor Create(const ASize: Integer);
    /// <summary>ASize bytes of AData into the buffer at AOffset: copied now, recorded into the command stream (any
    /// time, inside a 3D scene or outside) and written on the render thread in stream order: passes recorded later
    /// see the data, passes recorded before do not.</summary>
    procedure Write(const AOffset: Integer; const AData; const ASize: Integer);
    property Size: Integer read FSize;
  end;

  /// <summary>A 2D image of application ray passes, kept between frames: Texture2D (SRV entry) and RWTexture2D (UAV
  /// entry) in HLSL.</summary>
  TFastRayImage = class(TFastRayResource)
  private
    FFormat: TFastRayFormat;
    FWidth, FHeight: Integer;
  protected
    function CreateNative: IInterface; override;
  public
    constructor Create(const AFormat: TFastRayFormat; const AWidth, AHeight: Integer);
    property Format: TFastRayFormat read FFormat;
    property Width: Integer read FWidth;
    property Height: Integer read FHeight;
  end;

  /// <summary>How a pixel pass blends its result S into the target D: Replace (D = S); Premultiplied (FMX colors,
  /// D = S + D * (1 - S.a)); Multiply (D.rgb = D.rgb * S.rgb, D.a kept); Add (D.rgb = D.rgb + S.rgb, D.a kept).
  /// </summary>
  TFastRayBlend = (Replace, Premultiplied, Multiply, Add);

  /// <summary>An application shader of ray passes: compute (cs_6_5) or a full-screen pixel pass (ps_6_5) blended into
  /// the 3D target; signed DXIL compiled against Shaders\FastRayApp.hlsli. Its pipelines are made on the render thread
  /// when a pass first needs them, and again after a device loss. Free it any time (recorded passes keep it).</summary>
  TFastRayShader = class
  private
    FNative: IInterface;
    FCompute: Boolean;
    FBlend: TFastRayBlend;
    function GetError: string;
  public
    constructor CreateCompute(const ADxil: array of Byte);
    constructor CreatePixel(const ADxil: array of Byte; const ABlend: TFastRayBlend);
    destructor Destroy; override;
    property IsCompute: Boolean read FCompute;
    property Blend: TFastRayBlend read FBlend;
    /// <summary>Not empty when the render thread could not make the pipeline (unsigned DXIL, registers outside
    /// FastRayApp.hlsli, a pixel shader that takes more than SV_Position): its passes are skipped.</summary>
    property Error: string read GetError;
  end;

  /// <summary>The camera of a scene as the ray tracing uses it: multiplied and inverted in double precision, rounded
  /// to single. FMX row vectors: clip = world * ViewProj; Rel: relative to the camera's Position.</summary>
  TFastRayCamera = record
    ViewProj, InvViewProj, ViewProjRel, InvViewProjRel: TMatrix3D;
    Position: array[0..2] of Single;
  end;

  TFastContext3D12 = class(TFastContext3D)
  private
    FDlssMode, FDlssBuiltMode: TFastDlssMode;
    FDlssBuiltEmulate: TFastDlssEmulation;
    FDlssState: IInterface;
    FDlssPhase: Boolean;
    /// <summary>The DLSS state of the context and the session of the device (made on first use). Main thread.
    /// </summary>
    procedure EnsureDlss;
    function GetDlssAvailable: Boolean;
    function GetDlssStatus: string;
    function GetDlssFrames: Int64;
    procedure FinishDlssScene;
    procedure RecordDlssMotion(const C: Pointer; const AGeometry: UInt64; const APosition, ACull: Integer);
  private
    FRay: TFastRayTracing;
    // Application ray passes and the attributes of the draws that enter the scene.
    FRayScene, FRayInclude: Boolean;
    FRayMask: Byte;
    FRayUser: Cardinal;
    FRayKey: UInt64;
    FRayVersion: Cardinal;
    /// <summary>Draws of the scene in progress enter its acceleration structure (built-in effects or RayScene).
    /// </summary>
    FRayCollect: Boolean;
    /// <summary>Scenes with application passes so far, and the frame index of the last one.</summary>
    FRayFrames, FRayFrameIndex: Cardinal;
    FRayPassScene: Boolean;
    /// <summary>HDR target: asked for (Hdr), and the RGBA16F texture the scene ends in instead of the TTexture.
    /// </summary>
    FHdr: Boolean;
    FHdrColor: IInterface;
    /// <summary>Serial of the scene in progress (the render thread collects its objects for ray tracing).</summary>
    FScene: Integer;
    FRayObjects: Integer;
    /// <summary>The color the scene in progress was cleared with (what reflected rays that leave the scene see).
    /// </summary>
    FClearColor: TAlphaColor;
    FFormat: Integer;
    FSamples: Integer;
    FMSColor: IInterface;
    FDepth: IInterface;
    FSwapChain: IInterface;
    FBuffers: TArray<IInterface>;
    FBuffer: IInterface;
    FTearing: Boolean;
    /// <summary>Window (TForm3D): HDR output asked for when the swap chain was made (FastCanvasHdr, the window's
    /// display), and whether the swap chain is FP16 scRGB (the scene then ends in FHdrColor, which goes to the buffer
    /// at Present); the scRGB value of SDR white for the next Present.</summary>
    FWindowHdrAsked, FWindowHdr: Boolean;
    FWhiteScale: Single;
    FDrawIntensity: Single;
    procedure CreateTargets;
    function WindowHdrWanted(out AWhiteScale: Single): Boolean;
    procedure RecordRay;
    procedure RecordRayObject(const AVertices, AIndices: Pointer; const AVertexSize, AVertexCount, AIndexSize,
      AIndexCount, APosition, ANormal, ATexCoord: Integer);
    function RecordRayPass(const AShader: TFastRayShader; const ACompute: Boolean; const ASrvs, AUavs: array of TObject;
      const AConstants: Pointer; const AConstantSize, AGroupsX, AGroupsY, AGroupsZ: Integer): Boolean;
    procedure SetRayScene(const AValue: Boolean);
    function GetRayPassesAvailable: Boolean;
    function GetRayTarget: TObject;
    function RayCamera: TFastRayCamera;
    function TargetPixels: TSize;
    /// <summary>The texture drawn into: the multisampled buffer, the window buffer or the target texture.</summary>
    function DrawTarget: TObject;
    procedure RecordTarget;
  protected
    procedure DoCreateBuffer; override;
    procedure DoResize; override;
    procedure DoFreeBuffer; override;
    procedure DoCopyToBitmap(const Dest: TBitmap; const ARect: TRect); override;
    procedure DoCopyToBits(const Bits: Pointer; const Pitch: Integer; const ARect: TRect); override;
    function DoBeginScene: Boolean; override;
    procedure DoEndScene; override;
    procedure DoSetShaderVariable(const Name: string; const Data: array of TVector3D); overload; override;
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
    /// <summary>The device can trace rays from shaders (DXR tier 1.1). For application passes this is the test that
    /// decides whether to use them, and so whether to turn multisampling off (they need a target without it):
    /// RayPassesAvailable is False while a context is multisampled.</summary>
    class function RayTracingSupported: Boolean;
    /// <summary>Ray-traced effects; a new context starts with FastContext3DRayTracing. Read at every scene.</summary>
    property RayTracing: TFastRayTracing read FRay write FRay;
    /// <summary>Native NVIDIA DLSS SR in window contexts. Off preserves the stock resolution/MSAA path.
    /// The renderer applies mode changes at the next scene and keeps screen-projected UI at output resolution.</summary>
    property DlssMode: TFastDlssMode read FDlssMode write FDlssMode;
    property DlssAvailable: Boolean read GetDlssAvailable;
    property DlssStatus: string read GetDlssStatus;
    /// <summary>Successful NGX evaluations, for diagnostics (zero is not reported as active DLSS).</summary>
    property DlssFrames: Int64 read GetDlssFrames;
    property RayShadows: Boolean read FRay.Shadows write FRay.Shadows;
    property RayShadowStrength: Single read FRay.ShadowStrength write FRay.ShadowStrength;
    property RayShadowSoftness: Single read FRay.ShadowSoftness write FRay.ShadowSoftness;
    property RayAmbientOcclusion: Boolean read FRay.AmbientOcclusion write FRay.AmbientOcclusion;
    property RayReflections: Boolean read FRay.Reflections write FRay.Reflections;
    property RayReflectionStrength: Single read FRay.ReflectionStrength write FRay.ReflectionStrength;

    { Application ray passes (DXR tier 1.1). Main thread (the thread that draws the scene). }

    /// <summary>A compute pass at this point of the scene (between draws, inside BeginScene / EndScene):
    /// AGroupsX x AGroupsY x AGroupsZ thread groups of AShader (compute). ASrvs: TFastRayBuffer, TFastRayImage or FMX
    /// TTexture; AUavs: TFastRayBuffer or TFastRayImage (an object is not both in one pass); AConstants: AConstantSize
    /// bytes (at most 4096) for register b1, copied now. On the render thread, in stream order: the first pass of a
    /// scene builds the scene's top-level acceleration structure from the objects drawn so far, a later one builds it
    /// again if objects were added since. False when nothing was recorded: no scene in progress, no DXR tier 1.1,
    /// multisampling (RayPassesAvailable), a resource without GPU memory (no device right now).</summary>
    function RayDispatch(const AShader: TFastRayShader; const ASrvs, AUavs: array of TObject; const AConstants;
      const AConstantSize, AGroupsX, AGroupsY: Integer; const AGroupsZ: Integer = 1): Boolean;
    /// <summary>A full-screen pixel pass over the 3D target at this point of the scene, blended as AShader says
    /// (pixel shader). As RayDispatch otherwise; an SRV entry that is the target itself (RayTarget, Texture) reads a
    /// white texture: a pass cannot read what it draws into (copy it in a compute pass first).</summary>
    function RayDraw(const AShader: TFastRayShader; const ASrvs: array of TObject; const AConstants;
      const AConstantSize: Integer): Boolean; overload;
    /// <summary>A pixel pass that also writes UAV entries.</summary>
    function RayDraw(const AShader: TFastRayShader; const ASrvs, AUavs: array of TObject; const AConstants;
      const AConstantSize: Integer): Boolean; overload;
    /// <summary>Draws after this is True enter the scene's acceleration structure: triangles with depth test and
    /// write, float3 positions, in a 3D (not screen) projection, as for the built-in effects, with the attributes
    /// below. Read at every draw; not kept by a new context (TViewport3D makes a new one when it is resized). Does
    /// nothing with multisampling (RayPassesAvailable False), unless a built-in effect collects the objects anyway.
    /// </summary>
    property RayScene: Boolean read FRayScene write SetRayScene;
    /// <summary>Default True. False keeps the next draws out of the scene (a view weapon, glass), for the built-in
    /// effects too.</summary>
    property RayInclude: Boolean read FRayInclude write FRayInclude;
    /// <summary>Default $FF: the instance mask of the next draws (the built-in effects trace with $FF).</summary>
    property RayInstanceMask: Byte read FRayMask write FRayMask;
    /// <summary>Default 0: 24 bits of the next draws that shaders read as the committed instance's
    /// InstanceContributionToHitGroupIndex (InstanceID stays the instance's index in the scene).</summary>
    property RayInstanceUser: Cardinal read FRayUser write FRayUser;
    /// <summary>Default 0: the next draws' geometries are identified by their vertex and index arrays and sizes and a
    /// few positions, built once and kept while scenes use them (300 scenes). Otherwise the application's key for the
    /// geometry of the next draws: its structure is built again in place when RayGeometryVersion changes (animated
    /// models), and released when no scene used the key for 3 scenes.</summary>
    property RayGeometryKey: UInt64 read FRayKey write FRayKey;
    property RayGeometryVersion: Cardinal read FRayVersion write FRayVersion;
    /// <summary>RayDispatch and RayDraw run on this context: DXR tier 1.1, and a 3D target without multisampling
    /// (TViewport3D.Multisample = None, TForm3D.Multisample = None). Known once the context has its buffers. False
    /// while the context is multisampled, so it cannot tell whether turning multisampling off would help: an
    /// application deciding that asks the class function RayTracingSupported.</summary>
    property RayPassesAvailable: Boolean read GetRayPassesAvailable;
    /// <summary>FrameIndex of the frame constants (b0) of the latest scene with application passes: 0 for the first,
    /// one more for every scene with passes after it.</summary>
    property RayFrameIndex: Cardinal read FRayFrameIndex;
    /// <summary>An SRV entry of RayDispatch meaning the 3D target as drawn so far in the scene (Texture2D<float4>:
    /// what FMX's materials and earlier passes wrote, sRGB-encoded, premultiplied; above 1 only on an HDR target). It
    /// is the texture the context draws into now: the RGBA16F target with Hdr or with the HDR output of a TForm3D, the
    /// swap chain buffer of a TForm3D otherwise, else the viewport's texture. The context's own Texture as an SRV entry
    /// means the same (with Hdr, Texture holds the image only after the scene). Not a UAV entry; RayDraw reads it as
    /// white.</summary>
    property RayTarget: TObject read GetRayTarget;

    { HDR }

    /// <summary>Default False. True: a context that draws into a texture (TViewport3D) draws into an RGBA16F target
    /// instead, whose values may go above 1 (SDR white): FMX's materials draw there as on an 8-bit target
    /// (sRGB-encoded colors), and application passes may write more than 1 (FastSrgbEncode of FastRayApp.hlsli: the
    /// encoding of linear light, 1.0 = SDR white). The image goes on to the TBitmap the viewport draws (its HDR
    /// content), and a form whose window outputs HDR (FastCanvas.Canvas.FastCanvasHdrInfo) shows it unclipped; on an
    /// SDR window it clips at 1, and the CPU reads it clipped. Applied at the next BeginScene. A window context
    /// (TForm3D) ignores it: it has an HDR target exactly while its window outputs HDR (FastCanvas.Hdr.FastCanvasHdr,
    /// as for 2D forms).</summary>
    property Hdr: Boolean read FHdr write FHdr;
    /// <summary>Default 1. The colors of the next draws times this, in linear light (exact for white, close for other
    /// colors: the factor applies to the sRGB-encoded color). Above 1 they go above SDR white on an HDR target (a
    /// TForm3D whose window outputs HDR, a TViewport3D with Hdr), and an HDR window shows them brighter than white:
    /// lamps, screens, the sky; on an 8-bit target they clip at 1. Read at every draw; a new context starts with 1.
    /// </summary>
    property DrawIntensity: Single read FDrawIntensity write FDrawIntensity;
  end;

var
  /// <summary>Native DLSS SR mode for new Win64 window contexts.</summary>
  FastContext3DDlssMode: TFastDlssMode = TFastDlssMode.Off;
  /// <summary>Ray-traced effects every new TFastContext3D12 starts with (TViewport3D, TForm3D, filters).</summary>
  FastContext3DRayTracing: TFastRayTracing = (Shadows: False; ShadowStrength: 0.7; ShadowSoftness: 0;
    ShadowSamples: 8; AmbientOcclusion: False; AORadius: 1; AOStrength: 0.6; AOSamples: 8; Reflections: False;
    ReflectionStrength: 1);

/// <summary>Makes TFastContext3D12 the default 3D context. Call before Application.Initialize, after the canvas
/// (FastCanvas.Canvas.InstallFastCanvas) with FastCanvasBackend = D3D12. FastContext3DFragile
/// (FastCanvas.Context3D11) applies.</summary>
procedure InstallFastContext3D12;

implementation

uses
  DX12.D3D12, DX12.D3DCommon, DX12.DXGI, DX12.DXGI1_2, DX12.DXGI1_4,
  Winapi.Windows, FMX.Platform.Win, FastCanvas.Device, FastCanvas.Gpu, FastCanvas.Gpu12, FastCanvas.Bridge,
  System.Classes, System.Diagnostics, FMX.Forms3D, FastCanvas.Service, FastCanvas.Context3D11, FastCanvas.Hdr;

type
  // Winapi.Windows declares a TBitmap too.
  TBitmap = FMX.Graphics.TBitmap;

const
  StateRead = D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE;
  SamplerHeapSize = 2048;
  SwapBuffers = 3;

type
  /// <summary>Texture of a TTexture (its Handle holds one reference), a buffer of a target, or a bitmap of the canvas
  /// used in place (Canvas set: IGpuTexture). State and views belong to the render thread.</summary>
  TTexture12 = class(TInterfacedObject)
  public
    /// <summary>Unique for the process: the render thread compares textures by it (an address can be reused).
    /// </summary>
    Id: Integer;
    Resource: ID3D12Resource;
    Format: TDXGI_FORMAT;
    Width, Height, Mips, Samples: Integer;
    Canvas: IInterface;
    /// <summary>Recording thread: a recorded command refers to it (updates go through the stream from then on).
    /// </summary>
    Used: Boolean;
    // Render thread.
    State: TD3D12_RESOURCE_STATES;
    Srv, Rtv, Dsv: TD3D12_CPU_DESCRIPTOR_HANDLE;
    /// <summary>The recording context that has used it (its views come from that context's pools).</summary>
    Owner: TGpu12Context;
    /// <summary>A render target the GPU has not cleared yet (render targets need it before their first use).
    /// </summary>
    Uncleared: Boolean;
    destructor Destroy; override;
    /// <summary>Render thread: the resource in AState for the commands that follow.</summary>
    procedure Use(const AState: TD3D12_RESOURCE_STATES);
    function GpuResource: ID3D12Resource;
    function ShaderView: TD3D12_CPU_DESCRIPTOR_HANDLE;
    function RenderTarget: TD3D12_CPU_DESCRIPTOR_HANDLE;
    function DepthView: TD3D12_CPU_DESCRIPTOR_HANDLE;
  end;

  /// <summary>Bytes that travel with a command and are too large for the stream (texture updates).</summary>
  TBlob = class(TInterfacedObject)
  public
    Data: TBytes;
  end;

  TLayoutOffsets = record
    Position, Normal, TexCoord: Integer;
  end;

  /// <summary>Render thread: the geometry and material of an instance of a scene with ray-traced reflections.
  /// </summary>
  TRayMaterial = record
    Blas: Pointer;   // TBlas
    Texture: IInterface;
    Kind: Byte;
    Textured: Boolean;
    Diffuse, Ambient, Emission, Specular: array[0..3] of Single;
    Shininess: Single;
  end;

  TPsoKey = packed record
    VS, PS: Integer;
    Layout: UInt64;
    State: TFastPipelineState;
    Topology: Byte;
    Samples: Byte;
    Depth: Boolean;
    /// <summary>The color is scaled by the blend factor (DrawIntensity).</summary>
    Scaled: Boolean;
    Format: Integer;
  end;

  TShared = class
  public
    Device: ID3D12Device;
    Root: ID3D12RootSignature;
    Psos: TDictionary<UInt64, ID3D12PipelineState>;
    Layouts: TDictionary<UInt64, TFastVertexLayout>;
    /// <summary>Byte offsets of position, normal and texture coordinates of a layout (Layouts' keys).</summary>
    Offsets: TDictionary<UInt64, TLayoutOffsets>;
    SamplerHeap: ID3D12DescriptorHeap;
    SamplerCpu: TD3D12_CPU_DESCRIPTOR_HANDLE;
    SamplerGpu: TD3D12_GPU_DESCRIPTOR_HANDLE;
    SamplerIncrement: Cardinal;
    SamplerNext: Integer;
    SamplerTables: TDictionary<Cardinal, UInt64>;
    SamplerSource: ID3D12DescriptorHeap;
    SamplerSourceCpu: TD3D12_CPU_DESCRIPTOR_HANDLE;
    Blank: TTexture12;
    BlankRef: IInterface;
    /// <summary>Render thread: the blank texture holds its white pixel.</summary>
    BlankReady: Boolean;
    // Recording thread: the last target and constants recorded (the render thread keeps its own copies).
    constructor Create;
    destructor Destroy; override;
    function Pso(const AKey: TPsoKey; const ALayout: TFastVertexLayout): ID3D12PipelineState;
    function Layout(const ADeclaration: TVertexDeclaration; out AOffsets: TLayoutOffsets): TFastVertexLayout;
    /// <summary>The samplers of 8 texture units (2 bits of AFilters each: SamplerFilters); ABias: their texture LOD
    /// bias (the scene of DLSS).</summary>
    function SamplerTable(const AFilters: Cardinal; const ABias: Single = 0): UInt64;
  end;

  // Commands (payloads of FastBridge.RecordNative).

  PCmdTarget = ^TCmdTarget;
  TCmdTarget = packed record
    Target, Depth: Pointer;   // TTexture12, kept alive by the command
    Width, Height: Integer;
  end;

  PCmdClear = ^TCmdClear;
  TCmdClear = packed record
    Target, Depth: Pointer;
    Color: TSingleArray4;
    ClearColor: Boolean;
    Stencil: Byte;
    Pad: Word;
    DepthFlags: Cardinal;
    DepthValue: Single;
  end;

  PCmdDraw = ^TCmdDraw;
  /// <summary>Followed by the vertices, the indices, then the constants of the stages that changed.</summary>
  TCmdDraw = packed record
    Pso: Pointer;
    Topology: TD3D_PRIMITIVE_TOPOLOGY;
    StencilRef: Cardinal;
    Scissor: TRect;
    VertexBytes, IndexBytes, VertexStride, IndexCount: Integer;
    IndexFormat: TDXGI_FORMAT;
    VSBytes, PSBytes: Integer;   // 0: unchanged
    UnitCount: Integer;
    Units: array[0..7] of Pointer;   // TTexture12, kept alive by the command
    Samplers: UInt64;
    /// <summary>The blend factor of a scaled pipeline (DrawIntensity, sRGB-encoded); -1: not scaled.</summary>
    Factor: Single;
    DlssState: Pointer;
    DlssCurrent, DlssPrevious: TMatrix3D;
    DlssPosition, DlssCull: Integer;
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
    /// <summary>The key of the geometry: from its arrays and contents, or the application's (Keyed, with Version).
    /// </summary>
    Geometry: UInt64;
    Version: Cardinal;
    /// <summary>The instance's mask and 24 bits of the application.</summary>
    User: Cardinal;
    Mask: Byte;
    Keyed: Boolean;
    Pad2: Word;
    /// <summary>Object to world: three rows of a column-vector matrix (FMX's matrix transposed).</summary>
    Transform: TRayTransform;
    /// <summary>0: unknown (gray, lit), 1: TColorMaterial (Diffuse), 2: TTextureMaterial, 3: TLightMaterial; 255: no
    /// reflections in this scene (the rest is not set).</summary>
    Kind: Byte;
    Textured: Boolean;
    Pad: Word;
    Diffuse, Ambient, Emission, Specular: array[0..3] of Single;
    Shininess: Single;
    Texture: Pointer;   // TTexture12 of texture0 (kept alive by the command), nil without one
  end;

const
  // TCmdRay.Flags (FastRay.hlsl).
  RayShadowsOn = 1;
  RayReflect = 4;

type
  PCmdRay = ^TCmdRay;
  /// <summary>The ray-traced pass over a finished scene (constants of FastRay.hlsl).</summary>
  TCmdRay = packed record
    Target, Depth: Pointer;   // TTexture12, kept alive by the command
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

  /// <summary>The frame constants of application passes (b0 of FastRayApp.hlsli).</summary>
  TRayFrame = packed record
    /// <summary>FMX matrices as they are (row vectors); the HLSL declares them row_major.</summary>
    InvViewProj, ViewProj: TMatrix3D;
    CameraPos, TargetSize: array[0..3] of Single;
    FrameIndex: Cardinal;
    Pad: array[0..2] of Cardinal;
    /// <summary>The same relative to the camera (appended: the offsets above stay).</summary>
    InvViewProjRel, ViewProjRel: TMatrix3D;
  end;

  /// <summary>An SRV or UAV entry of an application pass.</summary>
  TRayEntry = packed record
    Obj: Pointer;   // TRayResource12, or TTexture12 when Texture; kept alive by the command
    Texture: Boolean;
    Pad: array[0..6] of Byte;
  end;
  {$POINTERMATH ON}
  PRayEntry = ^TRayEntry;
  {$POINTERMATH OFF}

  PCmdRayPass = ^TCmdRayPass;
  /// <summary>An application pass. Followed by SrvCount + UavCount TRayEntry, then ConstantSize bytes.</summary>
  TCmdRayPass = packed record
    Scene: Integer;
    SrvCount, UavCount, ConstantSize: Integer;
    GroupsX, GroupsY, GroupsZ: Integer;
    Width, Height: Integer;
    Shader: Pointer;   // TRayShader12, kept alive by the command
    Target, Depth: Pointer;   // TTexture12, kept alive by the command; Depth nil without a depth buffer
    Frame: TRayFrame;
  end;

  PCmdRayWrite = ^TCmdRayWrite;
  /// <summary>Bytes into a ray buffer: from Blob (a TBlob) or, when it is nil, following the command.</summary>
  TCmdRayWrite = packed record
    Buffer: Pointer;   // TRayResource12, kept alive by the command
    Blob: Pointer;
    Offset, Size: Integer;
  end;

const
  // TCmdCopy.DestMode: a bitmap of the canvas as it is, its 8-bit content, its HDR content.
  CopyDestAsIs = 0;
  CopyDestSdr = 1;
  CopyDestHdr = 2;

type
  PCmdCopy = ^TCmdCopy;
  TCmdCopy = packed record
    Source, Dest: Pointer;   // TTexture12
    Box: TD3D12_BOX;
    X, Y: Integer;
    DestMode: Integer;
  end;

  PCmdResolve = ^TCmdResolve;
  TCmdResolve = packed record
    Source, Dest: Pointer;
    Format: TDXGI_FORMAT;
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
    Dest: Pointer;   // ID3D12Resource (read-back buffer)
    Footprint: TD3D12_PLACED_SUBRESOURCE_FOOTPRINT;
  end;

  PCmdOutputHdr = ^TCmdOutputHdr;
  /// <summary>HDR output of a TForm3D window: the RGBA16F target into the FP16 scRGB swap chain buffer.</summary>
  TCmdOutputHdr = packed record
    Source, Dest: Pointer;   // TTexture12
    Scale: Single;
  end;

  PCmdPresent = ^TCmdPresent;
  TCmdPresent = packed record
    Buffer: Pointer;
    SwapChain: Pointer;   // IDXGISwapChain3
    Flags: Cardinal;
  end;

  /// <summary>Render-thread state of the 3D commands on the canvas's open list.</summary>
  TReplay = record
    Ctx: Pointer;
    ListGen: Integer;
    /// <summary>The target of the commands (kept alive here: commands of later chunks draw into it).</summary>
    Target, Depth: IInterface;
    Width, Height: Integer;
    TargetBound: Boolean;
    Pso: ID3D12PipelineState;
    Topology: TD3D_PRIMITIVE_TOPOLOGY;
    StencilRef: Cardinal;
    Scissor: TRect;
    UnitIds: array[0..7] of Integer;
    UnitsBound: Boolean;
    Samplers: UInt64;
    BlendFactor: Single;
    // The constants last recorded, set again after the canvas has used the list.
    VS, PS: TBytes;
    VSLen, PSLen: Integer;
    VSBound, PSBound: Boolean;
    // Ray tracing: the objects of the scene in progress, and what lasts across scenes (FastCanvas.Context3D12 ray
    // section).
    RayScene: Integer;
    Instances: TArray<TD3D12_RAYTRACING_INSTANCE_DESC>;
    InstanceCount: Integer;
    Ray: TObject;
    /// <summary>The ray object command before the draw in progress (Pending), and per instance its geometry and
    /// material (reflections).</summary>
    RayObject: TCmdRayObject;
    RayObjectTexture: IInterface;
    RayObjectPending: Boolean;
    Materials: TArray<TRayMaterial>;
  end;

var
  G: TShared;
  GScenes: TList<TFastContext3D12>;
  GContexts: TList<TFastContext3D12>;
  /// <summary>Render thread.</summary>
  R: TReplay;
  /// <summary>Identifies the 3D context as the owner of the open list (TGpu12Context.Owner).</summary>
  GOwnerTag: TObject;
  /// <summary>TFastContext3D12.RayTarget: an SRV entry meaning the 3D target of the scene in progress.</summary>
  GRayTarget: TObject;

procedure Check(const ARes: HResult; const AWhat: string);
begin
  if Failed(ARes) then
    raise EContext3DException.CreateFmt('FastContext3D12: %s failed (0x%.8x)', [AWhat, Cardinal(ARes)]);
end;

function NewTexture(const AWidth, AHeight, AMips, ASamples: Integer; const AFormat: TDXGI_FORMAT;
  const AFlags: TD3D12_RESOURCE_FLAGS; const AState: TD3D12_RESOURCE_STATES): TTexture12; forward;

var
  GSharedLock: TObject;

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
      try
        // White 1x1: texture units without a texture sample it (filled by the render thread before its first use:
        // no recording here, which may run in a message handler on any thread).
        S.Blank := NewTexture(1, 1, 1, 1, DXGI_FORMAT_B8G8R8A8_UNORM, D3D12_RESOURCE_FLAG_NONE,
          D3D12_RESOURCE_STATE_COPY_DEST);
        S.BlankRef := S.Blank;
      except
        S.Free;
        raise;
      end;
      G := S;
    end;
  finally
    TMonitor.Exit(GSharedLock);
  end;
  Result := G;
end;

function Offset(const AHandle: TD3D12_CPU_DESCRIPTOR_HANDLE; const AIndex: Integer;
  const AIncrement: Cardinal): TD3D12_CPU_DESCRIPTOR_HANDLE; inline;
begin
  Result.ptr := AHandle.ptr + SIZE_T(AIndex) * AIncrement;
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

var
  GNextTextureId: Integer;

function NewTexture12: TTexture12;
begin
  Result := TTexture12.Create;
  Result.Id := AtomicIncrement(GNextTextureId);
  Result.Mips := 1;
  Result.Samples := 1;
end;

{ TTexture12 }

destructor TTexture12.Destroy;
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
        C.RtvPool.Release(Rtv);
        C.DsvPool.Release(Dsv);
      end;
      // Command lists not executed yet may use it.
      if C <> nil then
        C.Retire(Resource);
      Resource := nil;
    finally
      TFastDevice.Unlock;
    end;
  end;
  inherited;
end;

/// <summary>The canvas surface of a bitmap used in place, else nil.</summary>
function CanvasSurface(const ATexture: TTexture12): TGpu12Surface; inline;
var
  S: TGpuSurface;
begin
  Result := nil;
  if ATexture.Canvas <> nil then
  begin
    S := IGpuTexture(ATexture.Canvas).Surface;
    if S is TGpu12Surface then
      Result := TGpu12Surface(S);
  end;
end;

function TTexture12.GpuResource: ID3D12Resource;
var
  S: TGpu12Surface;
begin
  if Canvas = nil then
    Exit(Resource);
  S := CanvasSurface(Self);
  if S <> nil then
    Result := S.Resource
  else
    Result := nil;
end;

/// <summary>Views made with another recording context (before a device reset) are gone.</summary>
procedure CheckOwner(const ATexture: TTexture12; const AContext: TGpu12Context); inline;
begin
  if ATexture.Owner <> AContext then
  begin
    ATexture.Owner := AContext;
    ATexture.Srv.ptr := 0;
    ATexture.Rtv.ptr := 0;
    ATexture.Dsv.ptr := 0;
  end;
end;

procedure TTexture12.Use(const AState: TD3D12_RESOURCE_STATES);
const
  Transparent: TSingleArray4 = (0, 0, 0, 0);
var
  C: TGpu12Context;
  S: TGpu12Surface;
begin
  C := Gpu12;
  if Canvas <> nil then
  begin
    S := CanvasSurface(Self);
    if S <> nil then
      S.Use(AState);
    Exit;
  end;
  if Uncleared then
  begin
    // A new render target or depth buffer is cleared before anything else uses it.
    Uncleared := False;
    if Format = DXGI_FORMAT_D24_UNORM_S8_UINT then
    begin
      C.Transition(Resource, State, D3D12_RESOURCE_STATE_DEPTH_WRITE);
      C.FlushBarriers;
      C.List.ClearDepthStencilView(DepthView, TD3D12_CLEAR_FLAGS(3), 1, 0, 0, nil);
    end
    else
    begin
      C.Transition(Resource, State, D3D12_RESOURCE_STATE_RENDER_TARGET);
      C.FlushBarriers;
      C.List.ClearRenderTargetView(RenderTarget, Transparent, 0, nil);
    end;
  end;
  C.Transition(Resource, State, AState);
end;

function TTexture12.ShaderView: TD3D12_CPU_DESCRIPTOR_HANDLE;
var
  C: TGpu12Context;
  S: TGpu12Surface;
begin
  if Canvas <> nil then
  begin
    S := CanvasSurface(Self);
    if S <> nil then
      Exit(S.Srv);
    Exit(G.Blank.ShaderView);
  end;
  C := Gpu12;
  CheckOwner(Self, C);
  if Srv.ptr = 0 then
  begin
    Srv := C.SrvPool.Alloc;
    C.Device.CreateShaderResourceView(Resource, nil, Srv);
  end;
  Result := Srv;
end;

function TTexture12.RenderTarget: TD3D12_CPU_DESCRIPTOR_HANDLE;
var
  C: TGpu12Context;
  S: TGpu12Surface;
begin
  if Canvas <> nil then
  begin
    S := CanvasSurface(Self);
    if S <> nil then
      Exit(S.Rtv);
    Result.ptr := 0;
    Exit;
  end;
  C := Gpu12;
  CheckOwner(Self, C);
  if Rtv.ptr = 0 then
  begin
    Rtv := C.RtvPool.Alloc;
    C.Device.CreateRenderTargetView(Resource, nil, Rtv);
  end;
  Result := Rtv;
end;

/// <summary>Render thread: a shader view of a depth buffer (its depth as R24), in a descriptor of AContext's pool
/// the caller releases.</summary>
function DepthShaderView(const ATexture: TTexture12; const AContext: TGpu12Context): TD3D12_CPU_DESCRIPTOR_HANDLE;
var
  Desc: TD3D12_SHADER_RESOURCE_VIEW_DESC;
begin
  FillChar(Desc, SizeOf(Desc), 0);
  Desc.Format := DXGI_FORMAT_R24_UNORM_X8_TYPELESS;
  Desc.Shader4ComponentMapping := D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
  if ATexture.Samples > 1 then
    Desc.ViewDimension := D3D12_SRV_DIMENSION_TEXTURE2DMS
  else
  begin
    Desc.ViewDimension := D3D12_SRV_DIMENSION_TEXTURE2D;
    Desc.Texture2D.MipLevels := 1;
  end;
  Result := AContext.SrvPool.Alloc;
  AContext.Device.CreateShaderResourceView(ATexture.Resource, @Desc, Result);
end;

function TTexture12.DepthView: TD3D12_CPU_DESCRIPTOR_HANDLE;
var
  C: TGpu12Context;
  Desc: TD3D12_DEPTH_STENCIL_VIEW_DESC;
begin
  C := Gpu12;
  CheckOwner(Self, C);
  if Dsv.ptr = 0 then
  begin
    FillChar(Desc, SizeOf(Desc), 0);
    Desc.Format := Format;
    if Samples > 1 then
      Desc.ViewDimension := D3D12_DSV_DIMENSION_TEXTURE2DMS
    else
      Desc.ViewDimension := D3D12_DSV_DIMENSION_TEXTURE2D;
    Dsv := C.DsvPool.Alloc;
    C.Device.CreateDepthStencilView(Resource, Desc, Dsv);
  end;
  Result := Dsv;
end;

{ TShared }

const
  SamplerFilters: array[0..3] of TD3D12_FILTER = (D3D12_FILTER_MIN_MAG_MIP_POINT,
    D3D12_FILTER_MIN_LINEAR_MAG_MIP_POINT, D3D12_FILTER_MIN_POINT_MAG_MIP_LINEAR, D3D12_FILTER_MIN_MAG_MIP_LINEAR);

/// <summary>A sampler of FMX's texture units: clamped, one of SamplerFilters.</summary>
function SamplerDesc(const AFilter: Integer; const ABias: Single): TD3D12_SAMPLER_DESC;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Filter := SamplerFilters[AFilter];
  Result.AddressU := D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
  Result.AddressV := D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
  Result.AddressW := D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
  Result.MipLODBias := ABias;
  Result.MaxAnisotropy := 1;
  Result.ComparisonFunc := D3D12_COMPARISON_FUNC_NEVER;
  Result.MinLOD := -MaxSingle;
  Result.MaxLOD := MaxSingle;
end;

constructor TShared.Create;
var
  Ranges: array[0..1] of TD3D12_DESCRIPTOR_RANGE;
  Params: array[0..3] of TD3D12_ROOT_PARAMETER;
  RootDesc: TD3D12_ROOT_SIGNATURE_DESC;
  Blob, Errors: ID3DBlob;
  Res: HResult;
  HeapDesc: TD3D12_DESCRIPTOR_HEAP_DESC;
  Sampler: TD3D12_SAMPLER_DESC;
  I: Integer;
begin
  inherited Create;
  TFastDevice.Ensure;
  Device := TFastDevice.D3D12;
  if Device = nil then
    raise EContext3DException.Create('FastContext3D12: the canvas has no Direct3D 12 device');
  Psos := TDictionary<UInt64, ID3D12PipelineState>.Create;
  Layouts := TDictionary<UInt64, TFastVertexLayout>.Create;
  Offsets := TDictionary<UInt64, TLayoutOffsets>.Create;
  SamplerTables := TDictionary<Cardinal, UInt64>.Create;

  Ranges[0].Init(D3D12_DESCRIPTOR_RANGE_TYPE_SRV, 8, 0);
  Ranges[1].Init(D3D12_DESCRIPTOR_RANGE_TYPE_SAMPLER, 8, 0);
  Params[0].InitAsConstantBufferView(0, 0, D3D12_SHADER_VISIBILITY_VERTEX);
  Params[1].InitAsConstantBufferView(0, 0, D3D12_SHADER_VISIBILITY_PIXEL);
  Params[2].InitAsDescriptorTable(1, @Ranges[0], D3D12_SHADER_VISIBILITY_PIXEL);
  Params[3].InitAsDescriptorTable(1, @Ranges[1], D3D12_SHADER_VISIBILITY_PIXEL);
  RootDesc.Init(Length(Params), @Params[0], 0, nil, D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT);
  Res := D3D12SerializeRootSignature(RootDesc, D3D_ROOT_SIGNATURE_VERSION_1, @Blob, @Errors);
  if Failed(Res) and (Errors <> nil) then
    raise EContext3DException.CreateFmt('FastContext3D12: root signature: %s',
      [string(PAnsiChar(Errors.GetBufferPointer))]);
  Check(Res, 'D3D12SerializeRootSignature');
  Check(Device.CreateRootSignature(0, Blob.GetBufferPointer, Blob.GetBufferSize, IID_ID3D12RootSignature, Root),
    'CreateRootSignature');

  FillChar(HeapDesc, SizeOf(HeapDesc), 0);
  HeapDesc._Type := D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER;
  HeapDesc.NumDescriptors := SamplerHeapSize;
  HeapDesc.Flags := D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
  Check(Device.CreateDescriptorHeap(@HeapDesc, IID_ID3D12DescriptorHeap, @SamplerHeap), 'CreateDescriptorHeap (samplers)');
  SamplerHeap.GetCPUDescriptorHandleForHeapStart(SamplerCpu);
  SamplerHeap.GetGPUDescriptorHandleForHeapStart(SamplerGpu);
  SamplerIncrement := Device.GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER);
  HeapDesc.NumDescriptors := 4;
  HeapDesc.Flags := D3D12_DESCRIPTOR_HEAP_FLAG_NONE;
  Check(Device.CreateDescriptorHeap(@HeapDesc, IID_ID3D12DescriptorHeap, @SamplerSource), 'CreateDescriptorHeap');
  SamplerSource.GetCPUDescriptorHandleForHeapStart(SamplerSourceCpu);
  for I := 0 to 3 do
  begin
    Sampler := SamplerDesc(I, 0);
    Device.CreateSampler(Sampler, Offset(SamplerSourceCpu, I, SamplerIncrement));
  end;
end;

destructor TShared.Destroy;
begin
  BlankRef := nil;
  Psos.Free;
  Layouts.Free;
  Offsets.Free;
  SamplerTables.Free;
  inherited;
end;

function TShared.Layout(const ADeclaration: TVertexDeclaration; out AOffsets: TLayoutOffsets): TFastVertexLayout;
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

function TShared.SamplerTable(const AFilters: Cardinal; const ABias: Single): UInt64;
var
  I: Integer;
  Dst: TD3D12_CPU_DESCRIPTOR_HANDLE;
  Key: Cardinal;
  Bias: SmallInt;
begin
  // The bias in 1/256 steps above the 16 bits of the filters.
  Bias := SmallInt(EnsureRange(Round(ABias * 256), -32768, 32767));
  Key := AFilters or (Cardinal(Word(Bias)) shl 16);
  if SamplerTables.TryGetValue(Key, Result) then
    Exit;
  if SamplerNext + 8 > SamplerHeapSize then
  begin
    // A table per filter combination; FMX uses a handful. Start over when the heap is full.
    FastBridge.Sync();
    TGpu12Backend.WaitIdle;
    SamplerTables.Clear;
    SamplerNext := 0;
  end;
  for I := 0 to 7 do
  begin
    Dst := Offset(SamplerCpu, SamplerNext + I, SamplerIncrement);
    if Bias = 0 then
      Device.CopyDescriptorsSimple(1, Dst, Offset(SamplerSourceCpu, (AFilters shr (2 * I)) and 3, SamplerIncrement),
        D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER)
    else
      Device.CreateSampler(SamplerDesc((AFilters shr (2 * I)) and 3, Bias / 256), Dst);
  end;
  Result := SamplerGpu.ptr + UInt64(SamplerNext) * SamplerIncrement;
  SamplerTables.Add(Key, Result);
  Inc(SamplerNext, 8);
end;

function TShared.Pso(const AKey: TPsoKey; const ALayout: TFastVertexLayout): ID3D12PipelineState;
const
  Ops: array[TStencilOp] of TD3D12_STENCIL_OP = (D3D12_STENCIL_OP_KEEP, D3D12_STENCIL_OP_ZERO,
    D3D12_STENCIL_OP_REPLACE, D3D12_STENCIL_OP_INCR_SAT, D3D12_STENCIL_OP_DECR_SAT, D3D12_STENCIL_OP_INVERT);
  Funcs: array[TStencilFunc] of TD3D12_COMPARISON_FUNC = (D3D12_COMPARISON_FUNC_NEVER, D3D12_COMPARISON_FUNC_LESS,
    D3D12_COMPARISON_FUNC_LESS_EQUAL, D3D12_COMPARISON_FUNC_GREATER, D3D12_COMPARISON_FUNC_GREATER_EQUAL,
    D3D12_COMPARISON_FUNC_EQUAL, D3D12_COMPARISON_FUNC_NOT_EQUAL, D3D12_COMPARISON_FUNC_ALWAYS);
  Culls: array[0..2] of TD3D12_CULL_MODE = (D3D12_CULL_MODE_NONE, D3D12_CULL_MODE_BACK, D3D12_CULL_MODE_FRONT);
var
  Hash: UInt64;
  Desc: TD3D12_GRAPHICS_PIPELINE_STATE_DESC;
  Elements: TArray<TD3D12_INPUT_ELEMENT_DESC>;
  I: Integer;
  S: TFastPipelineState;
begin
  Hash := FastHash(@AKey, SizeOf(AKey));
  if Psos.TryGetValue(Hash, Result) then
    Exit;
  S := AKey.State;
  SetLength(Elements, Length(ALayout.Elements));
  for I := 0 to High(Elements) do
  begin
    Elements[I].SemanticName := ALayout.Elements[I].Semantic;
    Elements[I].SemanticIndex := ALayout.Elements[I].SemanticIndex;
    Elements[I].Format := TDXGI_FORMAT(ALayout.Elements[I].Format);
    Elements[I].InputSlot := 0;
    Elements[I].AlignedByteOffset := ALayout.Elements[I].Offset;
    Elements[I].InputSlotClass := D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA;
    Elements[I].InstanceDataStepRate := 0;
  end;
  Desc := Default(TD3D12_GRAPHICS_PIPELINE_STATE_DESC);
  Desc.pRootSignature := Root;
  Desc.VS := TD3D12_SHADER_BYTECODE.Create(@TFastContext3D.FVS.Code[0], Length(TFastContext3D.FVS.Code));
  Desc.PS := TD3D12_SHADER_BYTECODE.Create(@TFastContext3D.FPS.Code[0], Length(TFastContext3D.FPS.Code));
  // FMX colors are premultiplied.
  Desc.BlendState.RenderTarget[0].BlendEnable := S.Blend;
  Desc.BlendState.RenderTarget[0].SrcBlend := D3D12_BLEND_ONE;
  Desc.BlendState.RenderTarget[0].DestBlend := D3D12_BLEND_INV_SRC_ALPHA;
  Desc.BlendState.RenderTarget[0].BlendOp := D3D12_BLEND_OP_ADD;
  Desc.BlendState.RenderTarget[0].SrcBlendAlpha := D3D12_BLEND_ONE;
  Desc.BlendState.RenderTarget[0].DestBlendAlpha := D3D12_BLEND_INV_SRC_ALPHA;
  Desc.BlendState.RenderTarget[0].BlendOpAlpha := D3D12_BLEND_OP_ADD;
  Desc.BlendState.RenderTarget[0].LogicOp := D3D12_LOGIC_OP_NOOP;
  if AKey.Scaled then
  begin
    // DrawIntensity: the color times the blend factor, blended as without it (or replacing the target).
    Desc.BlendState.RenderTarget[0].BlendEnable := True;
    Desc.BlendState.RenderTarget[0].SrcBlend := D3D12_BLEND_BLEND_FACTOR;
    if not S.Blend then
    begin
      Desc.BlendState.RenderTarget[0].DestBlend := D3D12_BLEND_ZERO;
      Desc.BlendState.RenderTarget[0].DestBlendAlpha := D3D12_BLEND_ZERO;
    end;
  end;
  if S.ColorWrite then
    Desc.BlendState.RenderTarget[0].RenderTargetWriteMask := Ord(D3D12_COLOR_WRITE_ENABLE_ALL);
  Desc.SampleMask := $FFFFFFFF;
  Desc.RasterizerState := TD3D12_RASTERIZER_DESC.Create(D3D12_DEFAULT);
  Desc.RasterizerState.CullMode := Culls[Min(S.Cull, 2)];
  Desc.RasterizerState.FrontCounterClockwise := False;
  Desc.RasterizerState.DepthClipEnable := True;
  Desc.RasterizerState.MultisampleEnable := True;
  Desc.RasterizerState.AntialiasedLineEnable := True;
  Desc.DepthStencilState := TD3D12_DEPTH_STENCIL_DESC.Create(D3D12_DEFAULT);
  Desc.DepthStencilState.DepthEnable := S.DepthTest and AKey.Depth;
  if S.DepthWrite then
    Desc.DepthStencilState.DepthWriteMask := D3D12_DEPTH_WRITE_MASK_ALL
  else
    Desc.DepthStencilState.DepthWriteMask := D3D12_DEPTH_WRITE_MASK_ZERO;
  Desc.DepthStencilState.DepthFunc := D3D12_COMPARISON_FUNC_LESS_EQUAL;
  Desc.DepthStencilState.StencilEnable := S.Stencil and AKey.Depth;
  Desc.DepthStencilState.StencilReadMask := S.StencilMask;
  Desc.DepthStencilState.StencilWriteMask := S.StencilMask;
  Desc.DepthStencilState.FrontFace.StencilFailOp := Ops[S.StencilFail];
  Desc.DepthStencilState.FrontFace.StencilDepthFailOp := Ops[S.StencilDepthFail];
  Desc.DepthStencilState.FrontFace.StencilPassOp := Ops[S.StencilPass];
  Desc.DepthStencilState.FrontFace.StencilFunc := Funcs[S.StencilFunc];
  Desc.DepthStencilState.BackFace := Desc.DepthStencilState.FrontFace;
  if Length(Elements) > 0 then
    Desc.InputLayout.pInputElementDescs := @Elements[0];
  Desc.InputLayout.NumElements := Length(Elements);
  Desc.PrimitiveTopologyType := TD3D12_PRIMITIVE_TOPOLOGY_TYPE(AKey.Topology);
  Desc.NumRenderTargets := 1;
  Desc.RTVFormats[0] := TDXGI_FORMAT(AKey.Format);
  if AKey.Depth then
    Desc.DSVFormat := DXGI_FORMAT_D24_UNORM_S8_UINT
  else
    Desc.DSVFormat := DXGI_FORMAT_UNKNOWN;
  Desc.SampleDesc.Count := AKey.Samples;
  Check(Device.CreateGraphicsPipelineState(@Desc, IID_ID3D12PipelineState, Result), 'CreateGraphicsPipelineState');
  Psos.Add(Hash, Result);
end;

{ Replay (render thread, device lock held) }

/// <summary>The canvas's open list, with the root signature and heaps of the 3D context set (the canvas set its
/// own since the last 3D command, or a new list began).</summary>
function Begin3D: ID3D12GraphicsCommandList;
var
  C: TGpu12Context;
  Heaps: array[0..1] of ID3D12DescriptorHeap;
  T, D: TTexture12;
  Rtv, Dsv: TD3D12_CPU_DESCRIPTOR_HANDLE;
  VP: TD3D12_VIEWPORT;
begin
  C := Gpu12;
  Result := C.List;
  if (R.Ctx <> Pointer(C)) or (R.ListGen <> C.ListGen) or (C.Owner <> GOwnerTag) then
  begin
    if (R.Ctx <> Pointer(C)) or (R.ListGen <> C.ListGen) then
    begin
      // A new list: no sampler heap, nothing bound.
      Heaps[0] := C.Heap;
      Heaps[1] := G.SamplerHeap;
      Result.SetDescriptorHeaps(2, @Heaps[0]);
    end;
    R.Ctx := C;
    R.ListGen := C.ListGen;
    C.Owner := GOwnerTag;
    Result.SetGraphicsRootSignature(G.Root);
    R.Pso := nil;
    R.Topology := D3D_PRIMITIVE_TOPOLOGY_UNDEFINED;
    R.StencilRef := $FFFFFFFF;
    R.Scissor := TRect.Empty;
    R.UnitsBound := False;
    R.Samplers := 0;
    R.BlendFactor := -1;
    R.VSBound := False;
    R.PSBound := False;
    R.TargetBound := False;
  end;
  if not R.TargetBound and (R.Target <> nil) then
  begin
    R.TargetBound := True;
    T := TTexture12(R.Target as TObject);
    D := nil;
    if R.Depth <> nil then
      D := TTexture12(R.Depth as TObject);
    Rtv := T.RenderTarget;
    if D <> nil then
    begin
      Dsv := D.DepthView;
      Result.OMSetRenderTargets(1, @Rtv, False, @Dsv);
    end
    else
      Result.OMSetRenderTargets(1, @Rtv, False, nil);
    VP.TopLeftX := 0;
    VP.TopLeftY := 0;
    VP.Width := R.Width;
    VP.Height := R.Height;
    VP.MinDepth := 0;
    VP.MaxDepth := 1;
    Result.RSSetViewports(1, @VP);
  end;
end;

/// <summary>The target and depth buffer in the states for drawing.</summary>
procedure UseTarget;
begin
  if R.Target <> nil then
    TTexture12(R.Target as TObject).Use(D3D12_RESOURCE_STATE_RENDER_TARGET);
  if R.Depth <> nil then
    TTexture12(R.Depth as TObject).Use(D3D12_RESOURCE_STATE_DEPTH_WRITE);
end;

procedure HandleTarget(const AData: Pointer);
var
  C: PCmdTarget;
  T, D: TTexture12;
  H: IGpuHdrTexture;
begin
  C := AData;
  T := C.Target;
  D := C.Depth;
  // A bitmap of the canvas drawn into (a filter's target) with HDR content: 8-bit first, as the pipelines expect.
  if (T.Canvas <> nil) and Supports(T.Canvas, IGpuHdrTexture, H) then
    H.Demote;
  R.Target := T;
  R.Depth := D;
  R.Width := C.Width;
  R.Height := C.Height;
  R.TargetBound := False;
  // Bound by Begin3D, in the states for drawing (a new target is cleared first).
  UseTarget;
  Gpu12.FlushBarriers;
  Begin3D;
end;

procedure HandleClear(const AData: Pointer);
var
  C: PCmdClear;
  L: ID3D12GraphicsCommandList;
  T, D: TTexture12;
begin
  C := AData;
  T := C.Target;
  D := C.Depth;
  L := Begin3D;
  if C.ClearColor and (T <> nil) then
  begin
    T.Use(D3D12_RESOURCE_STATE_RENDER_TARGET);
    Gpu12.FlushBarriers;
    L.ClearRenderTargetView(T.RenderTarget, C.Color, 0, nil);
  end;
  if (C.DepthFlags <> 0) and (D <> nil) then
  begin
    D.Use(D3D12_RESOURCE_STATE_DEPTH_WRITE);
    Gpu12.FlushBarriers;
    L.ClearDepthStencilView(D.DepthView, TD3D12_CLEAR_FLAGS(C.DepthFlags), C.DepthValue, C.Stencil, 0, nil);
  end;
end;

/// <summary>The blank texture holds its white pixel (before its first use).</summary>
procedure EnsureBlank;
var
  White: Cardinal;
begin
  if G.BlankReady then
    Exit;
  White := $FFFFFFFF;
  Gpu12.CopyToTexture(G.Blank.Resource, G.Blank.State, DXGI_FORMAT_B8G8R8A8_UNORM, 4, 0, 0, 1, 1, @White, 4);
  G.Blank.Use(StateRead);
  G.BlankReady := True;
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

function ToSingle(const A: TMatrix4D): TMatrix3D;
var
  I, J: Integer;
begin
  for I := 0 to 3 do
    for J := 0 to 3 do
      Result.M[I].V[J] := A[I, J];
end;


{$I FastCanvas.Context3D12.Ray.inc}
{$I FastCanvas.Context3D12.Dlss.inc}

procedure HandleDraw(const AData: Pointer);
var
  C: PCmdDraw;
  Ctx: TGpu12Context;
  L: ID3D12GraphicsCommandList;
  P, Src: PByte;
  Res, VRes, IRes: ID3D12Resource;
  Off, Gpu, VOff, IOff: UInt64;
  VB: TD3D12_VERTEX_BUFFER_VIEW;
  IB: TD3D12_INDEX_BUFFER_VIEW;
  Table: TD3D12_CPU_DESCRIPTOR_HANDLE;
  TableGpu: TD3D12_GPU_DESCRIPTOR_HANDLE;
  I: Integer;
  U: TTexture12;
  NeedTable: Boolean;
  Factor: TSingleArray4;
begin
  C := AData;
  Ctx := Gpu12;
  L := Begin3D;
  NeedTable := not R.UnitsBound;
  if not NeedTable then
    for I := 0 to C.UnitCount - 1 do
      if TTexture12(C.Units[I]).Id <> R.UnitIds[I] then
      begin
        NeedTable := True;
        Break;
      end;
  if not G.BlankReady then
    EnsureBlank;
  if NeedTable and (C.UnitCount > 0) then
  begin
    // May hand the list to the GPU when the descriptor ring is full: then the next list is set up again.
    Table := Ctx.AllocTable(8, TableGpu);
    L := Begin3D;
    for I := 0 to 7 do
    begin
      if I < C.UnitCount then
      begin
        U := TTexture12(C.Units[I]);
        R.UnitIds[I] := U.Id;
      end
      else
        U := G.Blank;
      Ctx.Device.CopyDescriptorsSimple(1, Offset(Table, I, Ctx.SrvIncrement), U.ShaderView,
        D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    end;
    L.SetGraphicsRootDescriptorTable(2, TableGpu);
    R.UnitsBound := True;
  end;
  UseTarget;
  for I := 0 to C.UnitCount - 1 do
    TTexture12(C.Units[I]).Use(StateRead);
  Ctx.FlushBarriers;
  if C.Pso <> Pointer(R.Pso) then
  begin
    R.Pso := ID3D12PipelineState(C.Pso);
    L.SetPipelineState(R.Pso);
  end;
  if (C.Factor >= 0) and (C.Factor <> R.BlendFactor) then
  begin
    Factor[0] := C.Factor;
    Factor[1] := C.Factor;
    Factor[2] := C.Factor;
    Factor[3] := 1;
    L.OMSetBlendFactor(Factor);
    R.BlendFactor := C.Factor;
  end;
  if C.Topology <> R.Topology then
  begin
    L.IASetPrimitiveTopology(C.Topology);
    R.Topology := C.Topology;
  end;
  if C.StencilRef <> R.StencilRef then
  begin
    L.OMSetStencilRef(C.StencilRef);
    R.StencilRef := C.StencilRef;
  end;
  if C.Scissor <> R.Scissor then
  begin
    L.RSSetScissorRects(1, @C.Scissor);
    R.Scissor := C.Scissor;
  end;
  if (C.UnitCount > 0) and (C.Samplers <> R.Samplers) then
  begin
    TableGpu.ptr := C.Samplers;
    L.SetGraphicsRootDescriptorTable(3, TableGpu);
    R.Samplers := C.Samplers;
  end;
  Src := PByte(C) + SizeOf(TCmdDraw);
  P := Ctx.Upload(C.VertexBytes, 16, VRes, VOff, Gpu);
  Move(Src^, P^, C.VertexBytes);
  VB.BufferLocation := Gpu;
  VB.SizeInBytes := C.VertexBytes;
  VB.StrideInBytes := C.VertexStride;
  L.IASetVertexBuffers(0, 1, @VB);
  Inc(Src, C.VertexBytes);
  P := Ctx.Upload(C.IndexBytes, 16, Res, Off, Gpu);
  IRes := Res;
  IOff := Off;
  Move(Src^, P^, C.IndexBytes);
  IB.BufferLocation := Gpu;
  IB.SizeInBytes := C.IndexBytes;
  IB.Format := C.IndexFormat;
  L.IASetIndexBuffer(IB);
  Inc(Src, AlignUp(C.IndexBytes, 4));
  if C.VSBytes > 0 then
  begin
    if Length(R.VS) < C.VSBytes then
      SetLength(R.VS, C.VSBytes);
    Move(Src^, R.VS[0], C.VSBytes);
    R.VSLen := C.VSBytes;
    R.VSBound := False;
    Inc(Src, C.VSBytes);
  end;
  if C.PSBytes > 0 then
  begin
    if Length(R.PS) < C.PSBytes then
      SetLength(R.PS, C.PSBytes);
    Move(Src^, R.PS[0], C.PSBytes);
    R.PSLen := C.PSBytes;
    R.PSBound := False;
  end;
  if not R.VSBound and (R.VSLen > 0) then
  begin
    P := Ctx.Upload(AlignUp(R.VSLen, 256), 256, Res, Off, Gpu);
    Move(R.VS[0], P^, R.VSLen);
    L.SetGraphicsRootConstantBufferView(0, Gpu);
    R.VSBound := True;
  end;
  if not R.PSBound and (R.PSLen > 0) then
  begin
    P := Ctx.Upload(AlignUp(R.PSLen, 256), 256, Res, Off, Gpu);
    Move(R.PS[0], P^, R.PSLen);
    L.SetGraphicsRootConstantBufferView(1, Gpu);
    R.PSBound := True;
  end;
  L.DrawIndexedInstanced(C.IndexCount, 1, 0, 0, 0);
  if R.RayObjectPending then
  begin
    R.RayObjectPending := False;
    RayAddObject(C, VB, IB, VRes, VOff, IRes, IOff);
    R.RayObjectTexture := nil;
  end;
  DlssMotionDraw(C, VB, IB);
end;

procedure HandleCopy(const AData: Pointer);
var
  C: PCmdCopy;
  S, D: TTexture12;
  DstLoc, SrcLoc: TD3D12_TEXTURE_COPY_LOCATION;
  H: IGpuHdrTexture;
begin
  C := AData;
  S := C.Source;
  D := C.Dest;
  // Into a bitmap of the canvas: its HDR content (an HDR target) or its 8-bit content; the bitmap's surface follows.
  if (C.DestMode <> CopyDestAsIs) and (D.Canvas <> nil) and Supports(D.Canvas, IGpuHdrTexture, H) then
    if C.DestMode = CopyDestHdr then
    begin
      if H.HdrTarget = nil then
        Exit;
    end
    else
      H.SdrTarget;
  if (S.GpuResource = nil) or (D.GpuResource = nil) then
    Exit;
  S.Use(D3D12_RESOURCE_STATE_COPY_SOURCE);
  D.Use(D3D12_RESOURCE_STATE_COPY_DEST);
  Gpu12.FlushBarriers;
  DstLoc := TD3D12_TEXTURE_COPY_LOCATION.Create(D.GpuResource, 0);
  SrcLoc := TD3D12_TEXTURE_COPY_LOCATION.Create(S.GpuResource, 0);
  Gpu12.List.CopyTextureRegion(@DstLoc, C.X, C.Y, 0, @SrcLoc, @C.Box);
end;

procedure HandleResolve(const AData: Pointer);
var
  C: PCmdResolve;
  S, D: TTexture12;
begin
  C := AData;
  S := C.Source;
  D := C.Dest;
  S.Use(D3D12_RESOURCE_STATE_RESOLVE_SOURCE);
  D.Use(D3D12_RESOURCE_STATE_RESOLVE_DEST);
  Gpu12.FlushBarriers;
  Gpu12.List.ResolveSubresource(D.GpuResource, 0, S.GpuResource, 0, C.Format);
end;

procedure HandleOutputHdr(const AData: Pointer);
var
  C: PCmdOutputHdr;
  S, D: TTexture12;
begin
  C := AData;
  S := C.Source;
  D := C.Dest;
  S.Use(StateRead);
  D.Use(D3D12_RESOURCE_STATE_RENDER_TARGET);
  Gpu12.OutputHdrViews(S.ShaderView, D.RenderTarget, D.Width, D.Height, C.Scale, False);
  // The pass bound its own target, root signature and pipeline.
  R.TargetBound := False;
end;

/// <summary>Device lock held: every level of a texture into the canvas's open list.</summary>
procedure HandleUploadData(const T: TTexture12; const B: TBlob; const ABytesPerPixel: Integer);
var
  Src: PByte;
  Level, W, H: Integer;
begin
  if T.Resource = nil then
    Exit;
  Src := @B.Data[0];
  W := T.Width;
  H := T.Height;
  for Level := 0 to T.Mips - 1 do
  begin
    Gpu12.CopyToTexture(T.Resource, T.State, T.Format, ABytesPerPixel, 0, 0, W, H, Src, W * ABytesPerPixel, Level);
    Inc(Src, NativeInt(W) * H * ABytesPerPixel);
    W := Max(1, W div 2);
    H := Max(1, H div 2);
  end;
  T.Use(StateRead);
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
  S: TTexture12;
  DstLoc, SrcLoc: TD3D12_TEXTURE_COPY_LOCATION;
begin
  C := AData;
  S := C.Source;
  if S.GpuResource = nil then
    Exit;
  S.Use(D3D12_RESOURCE_STATE_COPY_SOURCE);
  Gpu12.FlushBarriers;
  DstLoc := TD3D12_TEXTURE_COPY_LOCATION.Create(ID3D12Resource(C.Dest), C.Footprint);
  SrcLoc := TD3D12_TEXTURE_COPY_LOCATION.Create(S.GpuResource, 0);
  Gpu12.List.CopyTextureRegion(@DstLoc, 0, 0, 0, @SrcLoc, nil);
end;

procedure HandlePresent(const AData: Pointer);
var
  C: PCmdPresent;
begin
  C := AData;
  TTexture12(C.Buffer).Use(D3D12_RESOURCE_STATE_PRESENT);
  // The window buffer is not drawn into any more.
  R.Target := nil;
  R.Depth := nil;
  Gpu12.Submit;
  // A removed device is found by the canvas at its next scene (TFastDevice.RemovedReason).
  IDXGISwapChain3(C.SwapChain).Present(0, C.Flags);
end;

/// <summary>Forgets the render-thread state (after a Sync: the render thread is idle).</summary>
procedure ClearReplay;
begin
  TFastDevice.Lock;
  try
    RayClear;
    R.Target := nil;
    R.Depth := nil;
    R.Pso := nil;
    R.Ctx := nil;
    R.ListGen := -1;
    R.UnitsBound := False;
  finally
    TFastDevice.Unlock;
  end;
end;

var
  GSceneSerial: Integer;

procedure RunPendingReset; forward;

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

{ TFastContext3D12 }

constructor TFastContext3D12.CreateFromWindow(const AParent: TWindowHandle; const AWidth, AHeight: Single;
  const AMultisample: TMultisample; const ADepthStencil: Boolean);
begin
  inherited;
  FDlssMode := FastContext3DDlssMode;
  FRay := FastContext3DRayTracing;
  FRayInclude := True;
  FRayMask := $FF;
  FDrawIntensity := 1;
  GContexts.Add(Self);
  CreateBuffer;
end;

constructor TFastContext3D12.CreateFromTexture(const ATexture: TTexture; const AMultisample: TMultisample;
  const ADepthStencil: Boolean);
begin
  inherited;
  FRay := FastContext3DRayTracing;
  FRayInclude := True;
  FRayMask := $FF;
  FDrawIntensity := 1;
  GContexts.Add(Self);
  CreateBuffer;
end;

destructor TFastContext3D12.Destroy;
begin
  if GContexts <> nil then
  begin
    GContexts.Remove(Self);
    GScenes.Remove(Self);
  end;
  inherited;
end;

class function TFastContext3D12.Valid: Boolean;
begin
  TFastDevice.Ensure;
  Result := TFastDevice.D3D12 <> nil;
end;

class function TFastContext3D12.RayTracingSupported: Boolean;
begin
  Result := RaySupported;
end;

class function TFastContext3D12.Style: TContextStyles;
begin
  if FastContext3DFragile then
    Result := [TContextStyle.Fragile]
  else
    Result := [];
end;

function TFastContext3D12.TargetPixels: TSize;
begin
  if FDlssPhase then
    Exit(TDlssState(FDlssState as TObject).InputSize);
  if Texture <> nil then
    Result := TSize.Create(Texture.Width, Texture.Height)
  else
    Result := TSize.Create(Max(1, Round(Width * Scale)), Max(1, Round(Height * Scale)));
end;

/// <summary>Main thread: a texture resource (the render thread clears render targets and depth buffers before their
/// first use).</summary>
function NewTexture(const AWidth, AHeight, AMips, ASamples: Integer; const AFormat: TDXGI_FORMAT;
  const AFlags: TD3D12_RESOURCE_FLAGS; const AState: TD3D12_RESOURCE_STATES): TTexture12;
var
  Props: TD3D12_HEAP_PROPERTIES;
  Desc: TD3D12_RESOURCE_DESC;
  Clear: TD3D12_CLEAR_VALUE;
  PClear: PD3D12_CLEAR_VALUE;
begin
  Result := NewTexture12;
  try
    Result.Width := AWidth;
    Result.Height := AHeight;
    Result.Mips := AMips;
    Result.Samples := ASamples;
    Result.Format := AFormat;
    Result.State := AState;
    Result.Uncleared := AFlags <> D3D12_RESOURCE_FLAG_NONE;
    FillChar(Clear, SizeOf(Clear), 0);
    Clear.Format := AFormat;
    PClear := nil;
    if AFlags = D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL then
    begin
      Clear.DepthStencil.Depth := 1;
      PClear := @Clear;
    end
    else if AFlags = D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET then
      PClear := @Clear;
    Props := TD3D12_HEAP_PROPERTIES.Create(D3D12_HEAP_TYPE_DEFAULT);
    Desc := TD3D12_RESOURCE_DESC.CreateTex2D(AFormat, AWidth, AHeight, 1, AMips, ASamples, 0, AFlags);
    // A depth buffer is also read by shaders (ray-traced effects): typeless, viewed as D24S8 and as R24.
    if AFormat = DXGI_FORMAT_D24_UNORM_S8_UINT then
      Desc.Format := DXGI_FORMAT_R24G8_TYPELESS;
    Check(TFastDevice.D3D12.CreateCommittedResource(@Props, D3D12_HEAP_FLAG_NONE, @Desc, AState, PClear,
      IID_ID3D12Resource, Result.Resource), 'CreateCommittedResource (texture)');
  except
    Result.Free;
    raise;
  end;
end;

/// <summary>The buffers of an FP16 swap chain are in the scRGB color space (linear light, BT.709 primaries, 1.0 = 80
/// nits). False when the swap chain cannot present it.</summary>
function SetScRgb(const ASwap: IDXGISwapChain3): Boolean;
var
  Support: UINT;
begin
  Support := 0;
  Result := Succeeded(ASwap.CheckColorSpaceSupport(DXGI_COLOR_SPACE_RGB_FULL_G10_NONE_P709, Support)) and
    ((Support and Ord(DXGI_SWAP_CHAIN_COLOR_SPACE_SUPPORT_FLAG_PRESENT)) <> 0) and
    Succeeded(ASwap.SetColorSpace1(DXGI_COLOR_SPACE_RGB_FULL_G10_NONE_P709));
end;

/// <summary>Window context: its window outputs HDR now (FastCanvasHdr, the display the window is on), as
/// TFastTarget.Prepare decides for the windows of 2D forms; AWhiteScale: the scRGB value of SDR white there.</summary>
function TFastContext3D12.WindowHdrWanted(out AWhiteScale: Single): Boolean;
var
  Info: TFastHdrInfo;
begin
  AWhiteScale := 1;
  Result := False;
  if (Texture <> nil) or (Parent = nil) or (FastCanvasHdr = TFastCanvasHdr.Off) then
    Exit;
  Info := FastHdrDisplayOf(WindowHandleToPlatform(Parent).Wnd);
  AWhiteScale := Info.WhiteScale;
  Result := (FastCanvasHdr = TFastCanvasHdr.Force) or Info.DisplayHdr;
end;

procedure TFastContext3D12.CreateTargets;
var
  S: TShared;
  Px: TSize;
  Levels: TD3D12_FEATURE_DATA_MULTISAMPLE_QUALITY_LEVELS;
  Wanted, I: Integer;
  Chain: TDXGI_SWAP_CHAIN_DESC1;
  Factory: IDXGIFactory2;
  Swap: IDXGISwapChain1;
  Swap3: IDXGISwapChain3;
  Buffer: ID3D12Resource;
  T: TTexture12;
  Wnd: HWND;
  BufferFormat: TDXGI_FORMAT;
  Dlss: TDlssState; DepthSize: TSize;
begin
  S := Shared;
  Px := TargetPixels;
  FWindowHdr := False;
  if Texture = nil then
  begin
    // A window (TForm3D): flip-model swap chain on the canvas queue; FP16 in the scRGB color space while the window
    // outputs HDR (FastCanvasHdr and the display it is on, as for the windows of 2D forms).
    if not Supports(TFastDevice.DXGIFactory, IDXGIFactory2, Factory) then
      raise EContext3DException.Create('FastContext3D12: DXGI 1.2 is required');
    Wnd := WindowHandleToPlatform(Parent).Wnd;
    FWindowHdrAsked := WindowHdrWanted(FWhiteScale);
    FWindowHdr := FWindowHdrAsked;
    if FWindowHdr then
      BufferFormat := DXGI_FORMAT_R16G16B16A16_FLOAT
    else
      BufferFormat := DXGI_FORMAT_B8G8R8A8_UNORM;
    FillChar(Chain, SizeOf(Chain), 0);
    Chain.Width := Px.Width;
    Chain.Height := Px.Height;
    Chain.Format := BufferFormat;
    Chain.SampleDesc.Count := 1;
    Chain.BufferUsage := DXGI_USAGE_RENDER_TARGET_OUTPUT;
    Chain.BufferCount := SwapBuffers;
    Chain.Scaling := DXGI_SCALING_STRETCH;
    Chain.SwapEffect := DXGI_SWAP_EFFECT_FLIP_DISCARD;
    Chain.AlphaMode := DXGI_ALPHA_MODE_IGNORE;
    FTearing := TFastDevice.TearingSupported;
    if FTearing then
      Chain.Flags := Ord(DXGI_SWAP_CHAIN_FLAG_ALLOW_TEARING);
    Check(Factory.CreateSwapChainForHwnd(TFastDevice.Queue, Wnd, @Chain, nil, nil, Swap), 'CreateSwapChainForHwnd');
    if not Supports(Swap, IDXGISwapChain3, Swap3) then
      raise EContext3DException.Create('FastContext3D12: DXGI 1.4 is required');
    Factory.MakeWindowAssociation(Wnd, DXGI_MWA_NO_WINDOW_CHANGES);
    if FWindowHdr and not SetScRgb(Swap3) then
    begin
      // No scRGB on this swap chain: SDR.
      FWindowHdr := False;
      BufferFormat := DXGI_FORMAT_B8G8R8A8_UNORM;
      Check(Swap3.ResizeBuffers(0, Px.Width, Px.Height, BufferFormat, Chain.Flags), 'ResizeBuffers');
    end;
    FSwapChain := Swap3;
    SetLength(FBuffers, SwapBuffers);
    for I := 0 to SwapBuffers - 1 do
    begin
      Check(Swap3.GetBuffer(I, IID_ID3D12Resource, Buffer), 'GetBuffer');
      T := NewTexture12;
      T.Resource := Buffer;
      T.State := D3D12_RESOURCE_STATE_PRESENT;
      T.Format := BufferFormat;
      T.Width := Px.Width;
      T.Height := Px.Height;
      FBuffers[I] := T;
      Buffer := nil;
    end;
  end;
  if Texture <> nil then
    FFormat := FastDxgiFormat(Texture.PixelFormat)
  else
    FFormat := Ord(DXGI_FORMAT_B8G8R8A8_UNORM);
  if FFormat = 0 then
    FFormat := Ord(DXGI_FORMAT_B8G8R8A8_UNORM);
  if (FHdr and (Texture <> nil)) or FWindowHdr then
  begin
    // HDR: the scene ends in a texture of its own, RGBA16F: copied into the viewport's bitmap as its HDR content, or
    // into the window's buffer at Present (OutputHdr: sRGB-decoded, SDR white at the display's SDR white level).
    FFormat := Ord(DXGI_FORMAT_R16G16B16A16_FLOAT);
    FHdrColor := NewTexture(Px.Width, Px.Height, 1, 1, DXGI_FORMAT_R16G16B16A16_FLOAT,
      D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET, D3D12_RESOURCE_STATE_RENDER_TARGET);
  end;
  FDlssBuiltMode := FDlssMode;
  FDlssBuiltEmulate := FastDlssEmulate;
  DepthSize := Px;
  // DLSS (a window with a depth buffer): the session of the device is made when DLSS is first wanted, and stays.
  if (Texture = nil) and DepthStencil and (FDlssMode <> TFastDlssMode.Off) then
  begin
    EnsureDlss;
    Dlss := TDlssState(FDlssState as TObject);
    Dlss.Mode := FDlssMode;
    Dlss.Emulation := FastDlssEmulate;
    Dlss.Active := (Dlss.Emulation <> TFastDlssEmulation.Off) or (Dlss.Feature <> nil);
    if Dlss.Active then
    begin
      Dlss.OutputSize := Px;
      if Dlss.Emulation <> TFastDlssEmulation.Off then
        Dlss.InputSize := DlssRenderSize(Px, FDlssMode)
      else
        Dlss.InputSize := Dlss.Session.RenderSize(Px, FDlssMode);
      Dlss.Hdr := FWindowHdr;
      Dlss.AutoExposure := FastDlssAutoExposure;
      Dlss.Preset := FastDlssPreset;
      Dlss.Conservative := FastDlssConservativeMotion and DlssConservativeSupported;
      Dlss.MipBias := Log2(Dlss.InputSize.Width / Dlss.OutputSize.Width) - 1;
      Dlss.MakeTextures;
      DepthSize := Dlss.InputSize;
    end;
  end;
  case Multisample of
    TMultisample.TwoSamples: Wanted := 2;
    TMultisample.FourSamples: Wanted := 4;
  else
    Wanted := 1;
  end;
  if (FDlssState <> nil) and TDlssState(FDlssState as TObject).Active then Wanted := 1;
  FSamples := 1;
  while Wanted > 1 do
  begin
    FillChar(Levels, SizeOf(Levels), 0);
    Levels.Format := TDXGI_FORMAT(FFormat);
    Levels.SampleCount := Wanted;
    if Succeeded(S.Device.CheckFeatureSupport(D3D12_FEATURE_MULTISAMPLE_QUALITY_LEVELS, @Levels, SizeOf(Levels))) and
      (Levels.NumQualityLevels > 0) then
    begin
      FSamples := Wanted;
      Break;
    end;
    Wanted := Wanted div 2;
  end;
  if FSamples > 1 then
    FMSColor := NewTexture(Px.Width, Px.Height, 1, FSamples, TDXGI_FORMAT(FFormat),
      D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET, D3D12_RESOURCE_STATE_RENDER_TARGET);
  if DepthStencil then
    FDepth := NewTexture(DepthSize.Width, DepthSize.Height, 1, FSamples, DXGI_FORMAT_D24_UNORM_S8_UINT,
      D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL, D3D12_RESOURCE_STATE_DEPTH_WRITE);
  if (FDlssState <> nil) and TDlssState(FDlssState as TObject).Active then
    TDlssState(FDlssState as TObject).Depth := FDepth;
end;

procedure TFastContext3D12.DoCreateBuffer;
begin
  CreateTargets;
end;

procedure TFastContext3D12.DoResize;
begin
end;

procedure TFastContext3D12.DoFreeBuffer;
begin
  if FSwapChain <> nil then
  begin
    // A swap chain goes (or is resized) only when nothing refers to its buffers, the GPU and the render thread
    // included.
    if Assigned(FastBridge.Sync) then
      FastBridge.Sync();
    ClearReplay;
  end;
  FBuffer := nil;
  FBuffers := nil;
  FMSColor := nil;
  FHdrColor := nil;
  FDepth := nil;
  if FSwapChain <> nil then
  begin
    if TFastDevice.D3D12 <> nil then
      TGpu12Backend.WaitIdle;
    FSwapChain := nil;
  end;
  FDlssPhase := False;
  // The GPU is done with the DLSS textures; the feature is made again for new sizes (its session stays).
  if FDlssState <> nil then
    TDlssState(FDlssState as TObject).DropTextures;
end;

function TFastContext3D12.DrawTarget: TObject;
begin
  if FDlssPhase then Exit(DlssTexture(TDlssState(FDlssState as TObject).Color));
  if FMSColor <> nil then
    Exit(FMSColor as TObject);
  if FHdrColor <> nil then
    Exit(FHdrColor as TObject);
  if FSwapChain <> nil then
  begin
    if FBuffer <> nil then
      Exit(FBuffer as TObject);
    Exit(nil);
  end;
  Result := nil;
  if (Texture <> nil) and (Texture.Handle <> 0) then
    Result := TTexture12(Texture.Handle);
end;

/// <summary>Records the target of this context as the target of the commands that follow.</summary>
procedure TFastContext3D12.RecordTarget;
var
  T: TTexture12;
  C: PCmdTarget;
  Px: TSize;
begin
  T := TTexture12(DrawTarget);
  if T = nil then
    Exit;
  Px := TargetPixels;
  T.Used := True;
  C := Rec(HandleTarget, SizeOf(TCmdTarget), T);
  C.Target := T;
  C.Depth := nil;
  if (FDepth <> nil) and ((FDlssState = nil) or not TDlssState(FDlssState as TObject).Active or FDlssPhase) then
  begin
    C.Depth := FDepth as TObject;
    Keep(FDepth);
  end;
  C.Width := Px.Width;
  C.Height := Px.Height;
  FScissorDirty := True;
end;

function TFastContext3D12.DoBeginScene: Boolean;
var
  Scale: Single; Dlss: TDlssState; BeginCmd: PCmdDlssBegin;
begin
  FDlssPhase := False;
  RunPendingReset;
  if (Texture = nil) and ((FDlssBuiltMode <> FDlssMode) or
    ((FDlssMode <> TFastDlssMode.Off) and (FDlssBuiltEmulate <> FastDlssEmulate))) then
  begin
    FreeBuffer;
    CreateBuffer;
  end;
  if FSwapChain <> nil then
  begin
    // A window: HDR output switched (FastCanvasHdr, the window on another display, Windows HDR switched): a new swap
    // chain in the other format. The SDR white level of the display may change at any time.
    if WindowHdrWanted(Scale) <> FWindowHdrAsked then
    begin
      FreeBuffer;
      CreateBuffer;
    end;
    FWhiteScale := Scale;
  end
  else if (FHdr and (Texture <> nil)) <> (FHdrColor <> nil) then
  begin
    // Hdr changed: the targets in the other format (commands that use the old ones keep them).
    FreeBuffer;
    CreateBuffer;
  end;
  if FSwapChain <> nil then
    FBuffer := FBuffers[IDXGISwapChain3(FSwapChain).GetCurrentBackBufferIndex mod Cardinal(Length(FBuffers))];
  if (FDlssState <> nil) and TDlssState(FDlssState as TObject).Active then
  begin
    Dlss := TDlssState(FDlssState as TObject);
    Dlss.NextFrame;
    FDlssPhase := True;
    BeginCmd := Rec(HandleDlssBegin, SizeOf(TCmdDlssBegin), FDlssState);
    BeginCmd.State := Dlss;
  end;
  Result := (DrawTarget <> nil) and inherited DoBeginScene;
  if not Result then
    Exit;
  GScenes.Add(Self);
  RecordTarget;
  // The render thread keeps the constants it was sent: send them again for this scene's shaders.
  FVSDirty := True;
  FPSDirty := True;
  // Ray-traced effects need a depth buffer (the surfaces of the pixels) and the hardware; RayScene the hardware and
  // no multisampling (application passes are skipped with it).
  FScene := 0;
  FRayObjects := 0;
  FRayPassScene := False;
  FRayCollect := ((FRay.Shadows or FRay.AmbientOcclusion or FRay.Reflections) and (FDepth <> nil)) or
    (FRayScene and (FSamples <= 1));
  if FRayCollect then
  begin
    FRayCollect := RaySupported;
    if FRayCollect then
    begin
      Inc(GSceneSerial);
      FScene := GSceneSerial;
    end;
  end;
end;

procedure TFastContext3D12.SetRayScene(const AValue: Boolean);
begin
  FRayScene := AValue;
  // Inside a scene: the draws that follow enter it (or not, unless the built-in effects collect them).
  if BeginSceneCount > 0 then
  begin
    FRayCollect := (FRayScene and (FSamples <= 1)) or
      ((FRay.Shadows or FRay.AmbientOcclusion or FRay.Reflections) and (FDepth <> nil));
    FRayCollect := FRayCollect and RaySupported;
    if FRayCollect and (FScene = 0) then
    begin
      Inc(GSceneSerial);
      FScene := GSceneSerial;
    end;
  end;
end;

function TFastContext3D12.GetRayTarget: TObject;
begin
  Result := GRayTarget;
end;

function TFastContext3D12.GetRayPassesAvailable: Boolean;
begin
  Result := (FSamples <= 1) and RaySupported;
end;

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

/// <summary>An object of the scene for the ray-traced effects; recorded before its draw.</summary>
procedure TFastContext3D12.RecordRayObject(const AVertices, AIndices: Pointer; const AVertexSize, AVertexCount,
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
  if FRayKey <> 0 then
  begin
    O.Geometry := FRayKey;
    O.Keyed := True;
    O.Version := FRayVersion;
  end
  else
    O.Geometry := GeometryKey(AVertices, AIndices, AVertexSize, AVertexCount, AIndexSize, AIndexCount, APosition);
  O.Mask := FRayMask;
  O.User := FRayUser and $FFFFFF;
  // DXR wants the object-to-world transform as three rows of a column-vector matrix: FMX's transposed.
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
  Inc(FRayObjects);
end;

/// <summary>The camera of the scene in progress, multiplied and inverted in double precision (single precision lost
/// pixels far from the origin: RayAppProbe --far), rounded to single.</summary>
function TFastContext3D12.RayCamera: TFastRayCamera;
var
  V, P, M, Inv: TMatrix4D;
  I, J: Integer;
  Src: TMatrix3D;
begin
  Src := CurrentCameraMatrix;
  for I := 0 to 3 do
    for J := 0 to 3 do
      V[I, J] := Src.M[I].V[J];
  Src := CurrentProjectionMatrix;
  if FDlssPhase then Src := Src * TDlssState(FDlssState as TObject).JitterMatrix;
  for I := 0 to 3 do
    for J := 0 to 3 do
      P[I, J] := Src.M[I].V[J];
  // World to clip (row vectors, as FMX) and back.
  M := MulD(V, P);
  Result.ViewProj := ToSingle(M);
  if InverseD(M, Inv) then
    Result.InvViewProj := ToSingle(Inv)
  else
    Result.InvViewProj := (CurrentCameraMatrix * CurrentProjectionMatrix).Inverse;
  // The camera: where the view takes the origin from.
  if InverseD(V, Inv) then
    for J := 0 to 2 do
      Result.Position[J] := Inv[3, J]
  else
    for J := 0 to 2 do
      Result.Position[J] := CurrentCameraInvMatrix.M[3].V[J];
  // Relative to the camera: the view without its translation (p * V = (p - camera) * V's 3 x 3 part).
  V[3, 0] := 0;
  V[3, 1] := 0;
  V[3, 2] := 0;
  M := MulD(V, P);
  Result.ViewProjRel := ToSingle(M);
  if InverseD(M, Inv) then
    Result.InvViewProjRel := ToSingle(Inv)
  else
    Result.InvViewProjRel := Result.ViewProjRel.Inverse;
end;

/// <summary>The ray-traced pass over the finished scene: the objects drawn so far, the camera and the lights.
/// </summary>
procedure TFastContext3D12.RecordRay;
var
  C: PCmdRay;
  Cam: TFastRayCamera;
  T: TTexture12;
  Px: TSize;
  I: Integer;
  Light: TLightDescription;
  N: Cardinal;
  Dir: TPoint3D;
  CutOff: Single;
begin
  T := TTexture12(DrawTarget);
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
  // World = (ndc.x, ndc.y, depth, 1) * Inverse(View * Projection), divided by w (row vectors, as FMX).
  // The camera-relative inverse: the shaders work with offsets from the camera (precise far from the origin).
  Cam := RayCamera;
  Move(Cam.InvViewProjRel, C.InvViewProj, SizeOf(C.InvViewProj));
  C.CameraPos[0] := Cam.Position[0];
  C.CameraPos[1] := Cam.Position[1];
  C.CameraPos[2] := Cam.Position[2];
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

const
  /// <summary>Most SRV and UAV entries of one application pass (with the depth buffer, within a block of the
  /// descriptor ring).</summary>
  RayMaxEntries = 1000;
  RayMaxConstants = 4096;

/// <summary>An application pass at this point of the scene (TCmdRayPass).</summary>
function TFastContext3D12.RecordRayPass(const AShader: TFastRayShader; const ACompute: Boolean;
  const ASrvs, AUavs: array of TObject; const AConstants: Pointer; const AConstantSize, AGroupsX, AGroupsY,
  AGroupsZ: Integer): Boolean;
var
  T: TTexture12;
  Refs: TArray<IInterface>;
  Textures: TArray<Boolean>;
  N, I: Integer;
  O: TObject;
  C: PCmdRayPass;
  E: PRayEntry;
  Px: TSize;
  Cam: TFastRayCamera;
begin
  Result := False;
  if (AShader = nil) or (AShader.FCompute <> ACompute) then
    raise EArgumentException.Create('FastContext3D12: RayDispatch takes a compute shader, RayDraw a pixel shader');
  if (AConstantSize < 0) or (AConstantSize > RayMaxConstants) then
    raise EArgumentOutOfRangeException.CreateFmt('FastContext3D12: ray pass constants of %d bytes (0..%d)',
      [AConstantSize, RayMaxConstants]);
  N := Length(ASrvs) + Length(AUavs);
  if N > RayMaxEntries then
    raise EArgumentOutOfRangeException.CreateFmt('FastContext3D12: %d entries in a ray pass (at most %d)',
      [N, RayMaxEntries]);
  if (AGroupsX > 65535) or (AGroupsY > 65535) or (AGroupsZ > 65535) then
    raise EArgumentOutOfRangeException.Create('FastContext3D12: more than 65535 thread groups along an axis');
  if (BeginSceneCount = 0) or (FSamples > 1) or (AGroupsX <= 0) or (AGroupsY <= 0) or (AGroupsZ <= 0) or
    not RaySupported then
    Exit;
  T := TTexture12(DrawTarget);
  if T = nil then
    Exit;
  // The GPU memory of every entry first: a resource without one (no device right now) skips the pass.
  SetLength(Refs, N);
  SetLength(Textures, N);
  for I := 0 to N - 1 do
  begin
    if I < Length(ASrvs) then
      O := ASrvs[I]
    else
      O := AUavs[I - Length(ASrvs)];
    if O is TFastRayResource then
    begin
      Refs[I] := TFastRayResource(O).Native;
      if Refs[I] = nil then
        Exit;
    end
    else if (O <> nil) and ((O = GRayTarget) or (O = Texture)) then
    begin
      // The 3D target as drawn so far in this scene: the texture the context draws into now (the RGBA16F one with Hdr;
      // Texture itself holds the image only after the scene).
      if I >= Length(ASrvs) then
        raise EArgumentException.CreateFmt('FastContext3D12: entry %d of a ray pass: the 3D target is an SRV entry ' +
          'only', [I]);
      Refs[I] := T;
      Textures[I] := True;
    end
    else if (O is TTexture) and (I < Length(ASrvs)) then
    begin
      Refs[I] := TextureObject(TTexture(O));
      // A texture without pixels reads white.
      if Refs[I] = nil then
        Refs[I] := Shared.BlankRef;
      TTexture12(Refs[I] as TObject).Used := True;
      Textures[I] := True;
    end
    else
      raise EArgumentException.CreateFmt('FastContext3D12: entry %d of a ray pass is not a TFastRayBuffer, a ' +
        'TFastRayImage or (SRV entries) a TTexture', [I]);
  end;
  // A scene without objects so far: its structure is empty (until objects come).
  if FScene = 0 then
  begin
    Inc(GSceneSerial);
    FScene := GSceneSerial;
  end;
  if not FRayPassScene then
  begin
    FRayPassScene := True;
    FRayFrameIndex := FRayFrames;
    Inc(FRayFrames);
  end;
  Px := TargetPixels;
  C := Rec(HandleRayPass, SizeOf(TCmdRayPass) + N * SizeOf(TRayEntry) + AlignUp(AConstantSize, 4), AShader.FNative);
  FillChar(C^, SizeOf(TCmdRayPass), 0);
  C.Scene := FScene;
  C.SrvCount := Length(ASrvs);
  C.UavCount := Length(AUavs);
  C.ConstantSize := AConstantSize;
  C.GroupsX := AGroupsX;
  C.GroupsY := AGroupsY;
  C.GroupsZ := AGroupsZ;
  C.Width := Px.Width;
  C.Height := Px.Height;
  C.Shader := AShader.FNative as TObject;
  T.Used := True;
  C.Target := T;
  Keep(T);
  if FDepth <> nil then
  begin
    C.Depth := FDepth as TObject;
    Keep(FDepth);
  end;
  // Clip = world * ViewProj, world = (ndc.x, ndc.y, depth, 1) * InvViewProj, divided by w (row vectors, as FMX).
  Cam := RayCamera;
  C.Frame.ViewProj := Cam.ViewProj;
  C.Frame.InvViewProj := Cam.InvViewProj;
  C.Frame.CameraPos[0] := Cam.Position[0];
  C.Frame.CameraPos[1] := Cam.Position[1];
  C.Frame.CameraPos[2] := Cam.Position[2];
  C.Frame.CameraPos[3] := 1;
  C.Frame.InvViewProjRel := Cam.InvViewProjRel;
  C.Frame.ViewProjRel := Cam.ViewProjRel;
  C.Frame.TargetSize[0] := Px.Width;
  C.Frame.TargetSize[1] := Px.Height;
  C.Frame.TargetSize[2] := 1 / Max(Px.Width, 1);
  C.Frame.TargetSize[3] := 1 / Max(Px.Height, 1);
  C.Frame.FrameIndex := FRayFrameIndex;
  E := PRayEntry(PByte(C) + SizeOf(TCmdRayPass));
  for I := 0 to N - 1 do
  begin
    FillChar(E[I], SizeOf(TRayEntry), 0);
    E[I].Obj := Refs[I] as TObject;
    E[I].Texture := Textures[I];
    Keep(Refs[I]);
  end;
  if AConstantSize > 0 then
    Move(AConstants^, (PByte(E) + N * SizeOf(TRayEntry))^, AConstantSize);
  Result := True;
end;

function TFastContext3D12.RayDispatch(const AShader: TFastRayShader; const ASrvs, AUavs: array of TObject;
  const AConstants; const AConstantSize, AGroupsX, AGroupsY: Integer; const AGroupsZ: Integer): Boolean;
begin
  Result := RecordRayPass(AShader, True, ASrvs, AUavs, @AConstants, AConstantSize, AGroupsX, AGroupsY, AGroupsZ);
end;

function TFastContext3D12.RayDraw(const AShader: TFastRayShader; const ASrvs: array of TObject; const AConstants;
  const AConstantSize: Integer): Boolean;
begin
  Result := RecordRayPass(AShader, False, ASrvs, [], @AConstants, AConstantSize, 1, 1, 1);
end;

function TFastContext3D12.RayDraw(const AShader: TFastRayShader; const ASrvs, AUavs: array of TObject;
  const AConstants; const AConstantSize: Integer): Boolean;
begin
  Result := RecordRayPass(AShader, False, ASrvs, AUavs, @AConstants, AConstantSize, 1, 1, 1);
end;

procedure TFastContext3D12.DoEndScene;
var
  T, B: TTexture12;
  C: PCmdResolve;
  O: PCmdOutputHdr;
  P: PCmdPresent;
begin
  FinishDlssScene;
  // Where the scene ends: the RGBA16F target (Hdr, a window with HDR output), the window's buffer, the texture.
  T := nil;
  if FHdrColor <> nil then
    T := TTexture12(FHdrColor as TObject)
  else if FSwapChain <> nil then
    T := TTexture12(FBuffer as TObject)
  else if (Texture <> nil) and (Texture.Handle <> 0) then
    T := TTexture12(Texture.Handle);
  if (FScene <> 0) and (FRayObjects > 0) and ((FRay.Shadows and (Lights.Count > 0)) or FRay.AmbientOcclusion or
    FRay.Reflections) then
    RecordRay;
  FScene := 0;
  if (FMSColor <> nil) and (T <> nil) then
  begin
    C := Rec(HandleResolve, SizeOf(TCmdResolve), FMSColor);
    C.Source := FMSColor as TObject;
    C.Dest := T;
    C.Format := T.Format;
    Keep(T);
  end;
  GScenes.Remove(Self);
  if GScenes.Count > 0 then
    GScenes.Last.RecordTarget;
  if (FSwapChain <> nil) and (BeginSceneCount = 1) then
  begin
    B := TTexture12(FBuffer as TObject);
    if FWindowHdr and (T <> nil) and (T <> B) then
    begin
      // HDR output: the frame into the FP16 scRGB buffer, SDR white at the display's SDR white level.
      O := Rec(HandleOutputHdr, SizeOf(TCmdOutputHdr), FBuffer);
      O.Source := T;
      O.Dest := B;
      O.Scale := FWhiteScale;
      Keep(T);
    end;
    // Presented where the canvas executes its commands, after them. The next scene needs the index of the next
    // buffer: wait for the present.
    P := Rec(HandlePresent, SizeOf(TCmdPresent), FSwapChain);
    P.Buffer := B;
    T := B;
    P.SwapChain := Pointer(FSwapChain);
    if FTearing then
      P.Flags := DXGI_PRESENT_ALLOW_TEARING
    else
      P.Flags := 0;
    Keep(T);
    FastBridge.Sync();
  end;
  inherited;
end;

procedure TFastContext3D12.DoClear(const ATarget: TClearTargets; const AColor: TAlphaColor; const ADepth: Single;
  const AStencil: Cardinal);
var
  C: PCmdClear;
  T: TTexture12;
begin
  T := TTexture12(DrawTarget);
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
  C.DepthFlags := 0;
  if TClearTarget.Depth in ATarget then
    C.DepthFlags := C.DepthFlags or Cardinal(Ord(D3D12_CLEAR_FLAG_DEPTH));
  if TClearTarget.Stencil in ATarget then
    C.DepthFlags := C.DepthFlags or Cardinal(Ord(D3D12_CLEAR_FLAG_STENCIL));
  C.DepthValue := ADepth;
  C.Stencil := Byte(AStencil);
  C.Pad := 0;
end;

/// <summary>The sRGB encoding of linear light, continued above 1 (FastSrgbEncode of FastRayApp.hlsli).</summary>
function SrgbEncode(const AValue: Single): Single;
begin
  if AValue <= 0.0031308 then
    Result := AValue * 12.92
  else
    Result := 1.055 * Power(AValue, 1 / 2.4) - 0.055;
end;

procedure TFastContext3D12.DoDrawPrimitivesBatch(const AKind: TPrimitivesKind; const Vertices, Indices: Pointer;
  const VertexDeclaration: TVertexDeclaration; const VertexSize, VertexCount, IndexSize, IndexCount: Integer);
const
  Topologies: array[TPrimitivesKind] of TD3D_PRIMITIVE_TOPOLOGY = (D3D_PRIMITIVE_TOPOLOGY_POINTLIST,
    D3D_PRIMITIVE_TOPOLOGY_LINELIST, D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
  Types: array[TPrimitivesKind] of TD3D12_PRIMITIVE_TOPOLOGY_TYPE = (D3D12_PRIMITIVE_TOPOLOGY_TYPE_POINT,
    D3D12_PRIMITIVE_TOPOLOGY_TYPE_LINE, D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE);
var
  S: TShared;
  T: TTexture12;
  Key: TPsoKey;
  Layout: TFastVertexLayout;
  C: PCmdDraw;
  VBytes, IBytes, VSBytes, PSBytes, I, N: Integer;
  Dst: PByte;
  Filters: Cardinal;
  Px: TSize;
  Offsets: TLayoutOffsets;
begin
  if (FVS = nil) or (FPS = nil) or (VertexCount <= 0) or (IndexCount <= 0) or (Length(FVS.Code) = 0) or
    (Length(FPS.Code) = 0) then
    Exit;
  if FDlssPhase and CurrentStates[TContextState.cs2DScene] then
    FinishDlssScene;
  T := TTexture12(DrawTarget);
  if T = nil then
    Exit;
  S := Shared;
  Layout := S.Layout(VertexDeclaration, Offsets);
  FillChar(Key, SizeOf(Key), 0);
  Key.VS := FVS.Id;
  Key.PS := FPS.Id;
  Key.Layout := Layout.Hash;
  Key.State := FState;
  // Scissor and stencil reference are not part of a pipeline state.
  Key.State.Scissor := False;
  Key.Topology := Ord(Types[AKind]);
  Key.Samples := T.Samples;
  Key.Depth := (FDepth <> nil) and ((FDlssState = nil) or not TDlssState(FDlssState as TObject).Active or FDlssPhase);
  Key.Format := Ord(T.Format);
  Key.Scaled := FDrawIntensity <> 1;
  VBytes := VertexSize * VertexCount;
  IBytes := IndexSize * IndexCount;
  VSBytes := 0;
  if FVSDirty then
    VSBytes := Length(FVSData);
  PSBytes := 0;
  if FPSDirty then
    PSBytes := Length(FPSData);
  // An opaque object of a scene with ray-traced effects or RayScene: drawn in world space (not a 2D layer drawn in
  // screen space), with depth test and write, with float3 positions, not kept out by the application. Recorded before
  // the draw, which brings the vertices.
  if (FScene <> 0) and FRayCollect and FRayInclude and (AKind = TPrimitivesKind.Triangles) and FState.DepthTest and
    FState.DepthWrite and (Offsets.Position >= 0) and CurrentStates[TContextState.cs3DScene] and
    not CurrentStates[TContextState.cs2DScene] then
    RecordRayObject(Vertices, Indices, VertexSize, VertexCount, IndexSize, IndexCount, Offsets.Position, Offsets.Normal,
      Offsets.TexCoord);
  C := Rec(HandleDraw, SizeOf(TCmdDraw) + VBytes + AlignUp(IBytes, 4) + VSBytes + PSBytes);
  C.Pso := Pointer(S.Pso(Key, Layout));
  if Key.Scaled then
    // The target holds sRGB-encoded colors: the encoding of the intensity scales white exactly.
    C.Factor := SrgbEncode(Max(FDrawIntensity, 0))
  else
    C.Factor := -1;
  C.DlssState := nil;
  if FDlssPhase and (AKind = TPrimitivesKind.Triangles) and CurrentStates[TContextState.cs3DScene] then
    RecordDlssMotion(C, GeometryKey(Vertices, Indices, VertexSize, VertexCount, IndexSize, IndexCount, Offsets.Position),
      Offsets.Position, FState.Cull);
  C.Topology := Topologies[AKind];
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
  if IndexSize = SizeOf(Cardinal) then
    C.IndexFormat := DXGI_FORMAT_R32_UINT
  else
    C.IndexFormat := DXGI_FORMAT_R16_UINT;
  C.VSBytes := VSBytes;
  C.PSBytes := PSBytes;
  N := Min(FPS.TextureUnits, 8);
  C.UnitCount := N;
  Filters := 0;
  for I := 0 to 7 do
  begin
    if I < N then
    begin
      if FUnits[I] <> nil then
      begin
        C.Units[I] := FUnits[I] as TObject;
        TTexture12(C.Units[I]).Used := True;
        Keep(FUnits[I]);
      end
      else
        C.Units[I] := S.Blank;
      Filters := Filters or (Cardinal(FUnitFilters[I] and 3) shl (2 * I));
    end
    else
    begin
      C.Units[I] := nil;
      Filters := Filters or (Cardinal(3) shl (2 * I));
    end;
  end;
  C.Samplers := 0;
  if (N > 0) and FDlssPhase then
    // Textures as sharp as at the output size (NVIDIA's DLSS programming guide, mip-map bias).
    C.Samplers := S.SamplerTable(Filters, TDlssState(FDlssState as TObject).MipBias)
  else if N > 0 then
    C.Samplers := S.SamplerTable(Filters);
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

function BytesPerPixel(const AFormat: TDXGI_FORMAT): Integer;
begin
  case AFormat of
    DXGI_FORMAT_R32G32B32A32_FLOAT: Result := 16;
    DXGI_FORMAT_R16G16B16A16_FLOAT, DXGI_FORMAT_R16G16B16A16_UNORM, DXGI_FORMAT_R32G32_FLOAT: Result := 8;
    DXGI_FORMAT_R16G16_FLOAT, DXGI_FORMAT_R32_FLOAT, DXGI_FORMAT_R10G10B10A2_UNORM, DXGI_FORMAT_R8G8B8A8_UNORM,
    DXGI_FORMAT_B8G8R8A8_UNORM: Result := 4;
    DXGI_FORMAT_R16_FLOAT, DXGI_FORMAT_R16_UNORM, DXGI_FORMAT_B5G6R5_UNORM, DXGI_FORMAT_B5G5R5A1_UNORM,
    DXGI_FORMAT_B4G4R4A4_UNORM: Result := 2;
  else
    Result := 1;
  end;
end;

/// <summary>Mipmaps are made on the CPU, for the 8-bit four-channel formats.</summary>
function CanMip(const AFormat: TDXGI_FORMAT): Boolean;
begin
  Result := (AFormat = DXGI_FORMAT_B8G8R8A8_UNORM) or (AFormat = DXGI_FORMAT_R8G8B8A8_UNORM);
end;

class function TFastContext3D12.TextureObject(const ATexture: TTexture): IInterface;
begin
  if ATexture.Handle = 0 then
    ATexture.Initialize;
  if ATexture.Handle <> 0 then
    Result := TTexture12(ATexture.Handle)
  else
    Result := nil;
end;

class procedure TFastContext3D12.DoInitializeTexture(const Texture: TTexture);
var
  T: TTexture12;
  Format: TDXGI_FORMAT;
  Mips: Integer;
begin
  if (Texture.Width <= 0) or (Texture.Height <= 0) then
    Exit;
  if Texture.PixelFormat = TPixelFormat.None then
    Texture.PixelFormat := TPixelFormat.BGRA;
  Format := TDXGI_FORMAT(FastDxgiFormat(Texture.PixelFormat));
  if Ord(Format) = 0 then
    raise EContext3DException.CreateFmt('FastContext3D12: no texture format for pixel format %d',
      [Ord(Texture.PixelFormat)]);
  Mips := 1;
  if (TTextureStyle.MipMaps in Texture.Style) and CanMip(Format) then
    Mips := Floor(Log2(Max(Texture.Width, Texture.Height))) + 1;
  // Committed resources come zeroed, except render targets: those are cleared before their first use.
  if TTextureStyle.RenderTarget in Texture.Style then
    T := NewTexture(Texture.Width, Texture.Height, Mips, 1, Format, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET,
      D3D12_RESOURCE_STATE_RENDER_TARGET)
  else
    T := NewTexture(Texture.Width, Texture.Height, Mips, 1, Format, D3D12_RESOURCE_FLAG_NONE, StateRead);
  IInterface(T)._AddRef;
  ITextureAccess(Texture).Handle := THandle(T);
end;

class procedure TFastContext3D12.DoFinalizeTexture(const Texture: TTexture);
var
  T: TTexture12;
begin
  T := TTexture12(Texture.Handle);
  ITextureAccess(Texture).Handle := 0;
  // Commands not executed yet keep their own reference; the GPU's use is covered by the destructor.
  if T <> nil then
    IInterface(T)._Release;
end;

class procedure TFastContext3D12.DoUpdateTexture(const Texture: TTexture; const Bits: Pointer; const Pitch: Integer);
var
  T: TTexture12;
  B: TBlob;
  BRef: IInterface;
  Bpp, Level, W, H, NW, NH, X, Y, Ch, Sum, X0, X1, Y0, Y1, Row: Integer;
  Total, Pos, Prev: NativeInt;
  C: PCmdUpload;
begin
  if Texture.Handle = 0 then
    Texture.Initialize;
  T := TTexture12(Texture.Handle);
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
    // handler on any thread): the copy goes straight into the canvas's open list, under the device lock only.
    TFastDevice.Lock;
    try
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

class function TFastContext3D12.DoBitmapToTexture(const Bitmap: TBitmap): TTexture;
var
  Surf: IInterface;
  S: TGpuSurface;
  T: TTexture12;
begin
  // A bitmap of the canvas is a texture on the same device: used in place (no read-back, no upload). The caller owns
  // the TTexture (TFilterContext3D frees it, FMX.Filter.pas:1870-1872); freeing it drops this reference only.
  Surf := nil;
  if Assigned(FastBridge.BitmapSurface) then
    Surf := FastBridge.BitmapSurface(Bitmap);
  S := nil;
  if Surf <> nil then
    S := IGpuTexture(Surf).Surface;
  if not (S is TGpu12Surface) then
    Exit(inherited DoBitmapToTexture(Bitmap));
  T := NewTexture12;
  IInterface(T)._AddRef;
  try
    T.Canvas := Surf;
    T.Format := DXGI_FORMAT_B8G8R8A8_UNORM;
    T.Width := S.Width;
    T.Height := S.Height;
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

procedure TFastContext3D12.DoCopyToBitmap(const Dest: TBitmap; const ARect: TRect);
var
  Surf: IInterface;
  Src, D: TTexture12;
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
    ((Texture.PixelFormat <> TPixelFormat.BGRA) and (FHdrColor = nil)) or
    not (IGpuTexture(Surf).Surface is TGpu12Surface) then
  begin
    inherited;
    Exit;
  end;
  // HDR: the image goes into the bitmap's HDR content.
  if FHdrColor <> nil then
    Src := TTexture12(FHdrColor as TObject)
  else
    Src := TTexture12(Texture.Handle);
  R := TRect.Intersect(ARect, TRect.Create(0, 0, Min(Src.Width, Dest.Width), Min(Src.Height, Dest.Height)));
  if R.IsEmpty then
    Exit;
  D := NewTexture12;
  DRef := D;
  D.Canvas := Surf;
  D.Format := DXGI_FORMAT_B8G8R8A8_UNORM;
  D.Width := Dest.Width;
  D.Height := Dest.Height;
  TCanvas.Lock;
  try
    Src.Used := True;
    C := Rec(HandleCopy, SizeOf(TCmdCopy), Src);
    C.Source := Src;
    C.Dest := D;
    Keep(DRef);
    C.Box.left := R.Left;
    C.Box.top := R.Top;
    C.Box.front := 0;
    C.Box.right := R.Right;
    C.Box.bottom := R.Bottom;
    C.Box.back := 1;
    C.X := R.Left;
    C.Y := R.Top;
    if FHdrColor <> nil then
      C.DestMode := CopyDestHdr
    else
      C.DestMode := CopyDestSdr;
    FastBridge.BitmapWritten(Dest);
  finally
    TCanvas.Unlock;
  end;
end;

procedure TFastContext3D12.DoCopyToBits(const Bits: Pointer; const Pitch: Integer; const ARect: TRect);
var
  Src: TTexture12;
  Desc: TD3D12_RESOURCE_DESC;
  Footprint: TD3D12_PLACED_SUBRESOURCE_FOOTPRINT;
  Total, Size: UInt64;
  Props: TD3D12_HEAP_PROPERTIES;
  Buf: TD3D12_RESOURCE_DESC;
  Readback: ID3D12Resource;
  C: PCmdReadback;
  Range: TD3D12_RANGE;
  P: Pointer;
  R: TRect;
  X, Y: Integer;
begin
  if FHdrColor <> nil then
    // HDR: read clipped to 8 bits.
    Src := TTexture12(FHdrColor as TObject)
  else if Texture <> nil then
  begin
    if Texture.Handle = 0 then
      Exit;
    Src := TTexture12(Texture.Handle);
  end
  else if FBuffer <> nil then
    Src := TTexture12(FBuffer as TObject)
  else
    Exit;
  R := TRect.Intersect(ARect, TRect.Create(0, 0, Src.Width, Src.Height));
  if R.IsEmpty or (Src.Resource = nil) and (Src.Canvas = nil) then
    Exit;
  FillChar(Desc, SizeOf(Desc), 0);
  Desc := TD3D12_RESOURCE_DESC.CreateTex2D(Src.Format, Src.Width, Src.Height, 1, 1);
  Shared.Device.GetCopyableFootprints(@Desc, 0, 1, 0, @Footprint, nil, nil, Total);
  Size := Max(Total, UInt64(Footprint.Footprint.RowPitch) * Cardinal(Src.Height));
  Props := TD3D12_HEAP_PROPERTIES.Create(D3D12_HEAP_TYPE_READBACK);
  Buf := TD3D12_RESOURCE_DESC.CreateBuffer(Size);
  Check(G.Device.CreateCommittedResource(@Props, D3D12_HEAP_FLAG_NONE, @Buf, D3D12_RESOURCE_STATE_COPY_DEST, nil,
    IID_ID3D12Resource, Readback), 'CreateCommittedResource (read-back)');
  TCanvas.Lock;
  try
    Src.Used := True;
    C := Rec(HandleReadback, SizeOf(TCmdReadback), Src);
    C.Source := Src;
    C.Dest := Pointer(Readback);
    C.Footprint := Footprint;
  finally
    TCanvas.Unlock;
  end;
  // Everything recorded so far runs, then the GPU finishes it.
  FastBridge.Sync();
  TGpu12Backend.WaitIdle;
  Range._Begin := 0;
  Range._End := Size;
  Check(Readback.Map(0, @Range, P), 'Map (read-back)');
  try
    if Src.Format = DXGI_FORMAT_R16G16B16A16_FLOAT then
      for Y := R.Top to R.Bottom - 1 do
        for X := R.Left to R.Right - 1 do
          PCardinal(PByte(Bits) + NativeInt(Y) * Pitch + X * 4)^ := GpuHalfTexelToBgra(PWord(PByte(P) +
            NativeInt(Y) * NativeInt(Footprint.Footprint.RowPitch) + X * 8))
    else
      for Y := R.Top to R.Bottom - 1 do
        Move((PByte(P) + NativeInt(Y) * NativeInt(Footprint.Footprint.RowPitch) + R.Left * 4)^,
          (PByte(Bits) + NativeInt(Y) * Pitch + R.Left * 4)^, R.Width * 4);
  finally
    Range._End := 0;
    Readback.Unmap(0, @Range);
  end;
end;

{ Shaders }

class procedure TFastContext3D12.CreateNativeShader(const AShader: TFastShader);
begin
  // Pipeline state objects take the bytecode itself.
end;

{ Application ray resources and shaders }

var
  /// <summary>One more at every device loss: ray buffers and images made before are on the old device (TCanvas.Lock).
  /// </summary>
  GRayDeviceGen: Integer;
  /// <summary>The ray buffers and images that exist (TCanvas.Lock).</summary>
  GRayResources: TList<TFastRayResource>;

const
  RayFormats: array[TFastRayFormat] of TDXGI_FORMAT = (DXGI_FORMAT_R8_UNORM, DXGI_FORMAT_R8G8B8A8_UNORM,
    DXGI_FORMAT_R16_FLOAT, DXGI_FORMAT_R16G16_FLOAT, DXGI_FORMAT_R16G16B16A16_FLOAT, DXGI_FORMAT_R32_FLOAT,
    DXGI_FORMAT_R32G32_FLOAT, DXGI_FORMAT_R32G32B32A32_FLOAT, DXGI_FORMAT_R32_UINT, DXGI_FORMAT_R32G32_UINT,
    DXGI_FORMAT_R32G32B32A32_UINT);
  /// <summary>Writes up to this size travel in the command stream, larger ones in a blob.</summary>
  RayInlineWrite = 64 * 1024;

{ TFastRayResource }

constructor TFastRayResource.Create;
begin
  inherited Create;
  if not Assigned(FastBridge.RecordNative) then
    raise EContext3DException.Create('FastContext3D12: ray buffers and images need FastCanvas (InstallFastCanvas)');
  TCanvas.Lock;
  try
    if GRayResources = nil then
      GRayResources := TList<TFastRayResource>.Create;
    GRayResources.Add(Self);
    // Made now: no Direct3D 12 device raises here.
    FNative := CreateNative;
    FDeviceGen := GRayDeviceGen;
    FGeneration := 1;
  finally
    TCanvas.Unlock;
  end;
end;

destructor TFastRayResource.Destroy;
begin
  TCanvas.Lock;
  try
    if GRayResources <> nil then
    begin
      GRayResources.Remove(Self);
      if GRayResources.Count = 0 then
        FreeAndNil(GRayResources);
    end;
    // Recorded commands keep their own reference.
    FNative := nil;
  finally
    TCanvas.Unlock;
  end;
  inherited;
end;

function TFastRayResource.Native: IInterface;
begin
  TCanvas.Lock;
  try
    if (FNative = nil) or (FDeviceGen <> GRayDeviceGen) then
    begin
      FNative := nil;
      try
        FNative := CreateNative;
      except
        // No device right now (removed and not replaced yet): nothing uses the resource until there is one.
        Exit(nil);
      end;
      FDeviceGen := GRayDeviceGen;
      Inc(FGeneration);
    end;
    Result := FNative;
  finally
    TCanvas.Unlock;
  end;
end;

function TFastRayResource.GetGeneration: Integer;
begin
  Native;
  Result := FGeneration;
end;

{ TFastRayBuffer }

constructor TFastRayBuffer.Create(const ASize: Integer);
begin
  if ASize <= 0 then
    raise EArgumentOutOfRangeException.CreateFmt('FastContext3D12: a ray buffer of %d bytes', [ASize]);
  FSize := ASize;
  inherited Create;
end;

function TFastRayBuffer.CreateNative: IInterface;
begin
  Result := NewRayResource(False, FSize, DXGI_FORMAT_UNKNOWN, 0, 0);
end;

procedure TFastRayBuffer.Write(const AOffset: Integer; const AData; const ASize: Integer);
var
  N: IInterface;
  C: PCmdRayWrite;
  B: TBlob;
  BRef: IInterface;
begin
  if ASize <= 0 then
    Exit;
  if (AOffset < 0) or (AOffset > FSize - ASize) then
    raise EArgumentOutOfRangeException.CreateFmt('FastContext3D12: %d bytes at %d into a ray buffer of %d bytes',
      [ASize, AOffset, FSize]);
  TCanvas.Lock;
  try
    N := Native;
    if N = nil then
      Exit;
    if ASize <= RayInlineWrite then
    begin
      C := Rec(HandleRayWrite, SizeOf(TCmdRayWrite) + AlignUp(ASize, 4), N);
      C.Blob := nil;
      Move(AData, (PByte(C) + SizeOf(TCmdRayWrite))^, ASize);
    end
    else
    begin
      B := TBlob.Create;
      BRef := B;
      SetLength(B.Data, ASize);
      Move(AData, B.Data[0], ASize);
      C := Rec(HandleRayWrite, SizeOf(TCmdRayWrite), N);
      C.Blob := B;
      Keep(BRef);
    end;
    C.Buffer := N as TObject;
    C.Offset := AOffset;
    C.Size := ASize;
  finally
    TCanvas.Unlock;
  end;
end;

{ TFastRayImage }

constructor TFastRayImage.Create(const AFormat: TFastRayFormat; const AWidth, AHeight: Integer);
begin
  if (AWidth <= 0) or (AHeight <= 0) or (AWidth > 16384) or (AHeight > 16384) then
    raise EArgumentOutOfRangeException.CreateFmt('FastContext3D12: a ray image of %d x %d pixels', [AWidth, AHeight]);
  FFormat := AFormat;
  FWidth := AWidth;
  FHeight := AHeight;
  inherited Create;
end;

function TFastRayImage.CreateNative: IInterface;
begin
  Result := NewRayResource(True, 0, RayFormats[FFormat], FWidth, FHeight);
end;

{ TFastRayShader }

procedure CheckDxil(const ADxil: array of Byte);
begin
  // A DXIL container starts as every shader container does.
  if (Length(ADxil) < 32) or (ADxil[0] <> Ord('D')) or (ADxil[1] <> Ord('X')) or (ADxil[2] <> Ord('B')) or
    (ADxil[3] <> Ord('C')) then
    raise EArgumentException.Create('FastContext3D12: an application ray shader takes a compiled shader (DXIL)');
end;

constructor TFastRayShader.CreateCompute(const ADxil: array of Byte);
begin
  inherited Create;
  CheckDxil(ADxil);
  FCompute := True;
  FNative := TRayShader12.Create(ADxil, True, TFastRayBlend.Replace);
end;

constructor TFastRayShader.CreatePixel(const ADxil: array of Byte; const ABlend: TFastRayBlend);
begin
  inherited Create;
  CheckDxil(ADxil);
  FBlend := ABlend;
  FNative := TRayShader12.Create(ADxil, False, ABlend);
end;

destructor TFastRayShader.Destroy;
begin
  // Recorded passes keep their own reference.
  FNative := nil;
  inherited;
end;

function TFastRayShader.GetError: string;
begin
  if FNative <> nil then
    Result := TRayShader12(FNative as TObject).Error
  else
    Result := '';
end;

{ Device loss and installation }

/// <summary>The canvas is about to replace the device (it has executed its stream; TContextLostMessage has been
/// sent: FMX finalized its fragile textures and shaders). Everything made on the old device goes, once the GPU is
/// done with it.</summary>
procedure ContextsDeviceLost;
var
  C: TFastContext3D12;
  Res: TFastRayResource;
begin
  // Ray buffers and images get GPU memory on the new device when they are used next (Generation tells).
  Inc(GRayDeviceGen);
  if GRayResources <> nil then
    for Res in GRayResources do
      Res.FNative := nil;
  if G = nil then
    Exit;
  ClearReplay;
  for C in GContexts do
    C.FreeBuffer;
  TFastContext3D.ResetShaderObjects;
  TGpu12Backend.WaitIdle;
  // DLSS features and pipelines of the old device (the session of the new one is made at the next use).
  for C in GContexts do
    if C.FDlssState <> nil then
      TDlssState(C.FDlssState as TObject).DeviceLost;
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
  Contexts: TArray<TFastContext3D12>;
  C: TFastContext3D12;
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
/// gone. The buffers are made on the main thread before its next 3D scene: a scene in progress there (its target and
/// depth buffer already recorded) must not see them replaced (the stress run found draws for a new depth buffer into a
/// target recorded without one).</summary>
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
  // The canvas has shut down before (FMX.Forms.pas:8517-8519): it executed its stream and waited for the GPU.
  RayClear;
  R.Target := nil;
  R.Depth := nil;
  R.Pso := nil;
  R.Ctx := nil;
  TFastContext3D.ShutdownBase;
  FreeAndNil(G);
  // The last step of FMX's shutdown (FinalizeForms): the forms and their contexts are gone.
  if (GContexts <> nil) and (GContexts.Count = 0) then
  begin
    FreeAndNil(GContexts);
    FreeAndNil(GScenes);
    FreeAndNil(GOwnerTag);
    FreeAndNil(GSharedLock);
  end;
end;

/// <summary>FastBridge.DrawsWindow: AForm is a TForm3D whose window a TFastContext3D12 draws.</summary>
function DrawsWindow(const AForm: TObject): Boolean;
begin
  Result := (AForm is TCustomForm3D) and (TCustomForm3D(AForm).Context is TFastContext3D12);
end;

procedure InstallFastContext3D12;
begin
  if GContexts = nil then
  begin
    GContexts := TList<TFastContext3D12>.Create;
    GScenes := TList<TFastContext3D12>.Create;
    GOwnerTag := TObject.Create;
    GSharedLock := TObject.Create;
  end;
  TFastContext3D.ResetDeviceState;
  InstallContextService(TFastContext3D12, Shutdown);
  FastBridge.DeviceLost := ContextsDeviceLost;
  FastBridge.DeviceReset := ContextsDeviceReset;
  FastBridge.DrawsWindow := DrawsWindow;
end;

initialization
  GRayTarget := TObject.Create;
finalization
  FreeAndNil(GRayTarget);
end.
