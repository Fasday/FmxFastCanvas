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

  /// <summary>Ray-traced effects of the 3D contexts that trace rays (TFastContext3D12: DXR tier 1.1; TFastContext3DVk:
  /// ray queries); ignored without the hardware.</summary>
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
    /// <summary>A layout of the given elements (raw draws: any DXGI formats and semantics), with its hash.</summary>
    class function Create(const AElements: array of TFastVertexElement): TFastVertexLayout; static;
  end;

  { Raw draws: the 3D pipeline of Direct3D for programs that bring their own shaders, vertex formats and states
    (USAGE.md, "Raw draws"). The enumerations have the values of Direct3D 11 and 12 (the same in both); the Vulkan
    context maps them. }

  TFastBlend = (Zero = 1, One = 2, SrcColor = 3, InvSrcColor = 4, SrcAlpha = 5, InvSrcAlpha = 6, DestAlpha = 7,
    InvDestAlpha = 8, DestColor = 9, InvDestColor = 10);
  TFastBlendOp = (Add = 1, Subtract = 2, RevSubtract = 3, Min = 4, Max = 5);
  TFastCompare = (Never = 1, Less = 2, Equal = 3, LessEqual = 4, Greater = 5, NotEqual = 6, GreaterEqual = 7,
    Always = 8);
  TFastStencilOp = (Keep = 1, Zero = 2, Replace = 3, IncrSat = 4, DecrSat = 5, Invert = 6, Incr = 7, Decr = 8);
  /// <summary>The faces that are not drawn.</summary>
  TFastCullMode = (None = 1, Front = 2, Back = 3);

  TFastStencilFace = packed record
    Fail, DepthFail, Pass: TFastStencilOp;
    Func: TFastCompare;
  end;

  /// <summary>Blend, depth-stencil and rasterizer state of a raw draw. Start from Default (no blending, all channels
  /// written, depth test LessEqual with writes, no stencil, no culling, clockwise front faces).</summary>
  TFastRawState = packed record
    BlendEnable: Boolean;
    SrcBlend, DestBlend: TFastBlend;
    BlendOp: TFastBlendOp;
    SrcBlendAlpha, DestBlendAlpha: TFastBlend;
    BlendOpAlpha: TFastBlendOp;
    /// <summary>Bit 0 red, 1 green, 2 blue, 3 alpha.</summary>
    WriteMask: Byte;
    DepthEnable: Boolean;
    DepthWrite: Boolean;
    DepthFunc: TFastCompare;
    StencilEnable: Boolean;
    StencilReadMask, StencilWriteMask: Byte;
    FrontFace, BackFace: TFastStencilFace;
    Cull: TFastCullMode;
    Wireframe: Boolean;
    FrontCounterClockwise: Boolean;
    Pad: Byte;
    /// <summary>Added to the depth of the pixels in units of the depth buffer's resolution (D24: 2^-24).</summary>
    DepthBias: Integer;
    SlopeScaledDepthBias: Single;
    DepthBiasClamp: Single;
    class function Default: TFastRawState; static;
  end;

  /// <summary>A sampler of a raw draw: Filter is a D3D11_FILTER / D3D12_FILTER value, the address modes D3D's
  /// (1 wrap, 2 mirror, 3 clamp, 4 border). Vulkan: the border color is the nearest of transparent black, opaque
  /// black and opaque white; comparison filters sample as the plain ones.</summary>
  TFastSampler = packed record
    Filter: Cardinal;
    AddressU, AddressV, AddressW: Byte;
    MaxAnisotropy: Byte;
    MipLODBias, MinLOD, MaxLOD: Single;
    BorderColor: array[0..3] of Single;
    /// <summary>Trilinear, wrapping, all mip levels.</summary>
    class function Default: TFastSampler; static;
  end;

  TFastTextureKind = (Texture2D, Cube);
  /// <summary>Texture formats of raw draws. Depth24: a copy of a depth buffer (CopyToTexture), sampled as its depth
  /// (R24, 0..1).</summary>
  TFastTextureFormat = (RGBA8, BGRA8, R8, RG8, R16, RG16, RGBA16F, RGBA32F, BC1, BC2, BC3, BC4, BC5, Depth24);

  /// <summary>A texture for raw draws: 2D or cube, any of TFastTextureFormat, with explicit mip levels. Its GPU memory
  /// belongs to the installed 3D context (InstallFastContext3D11 / 12 / Vk). Upload is recorded in program order with
  /// the draws (main thread, as the scenes).</summary>
  TFastTexture = class
  private
    FKind: TFastTextureKind;
    FFormat: TFastTextureFormat;
    FWidth, FHeight, FMips: Integer;
    FNative: IInterface;
    FDeviceGen: Integer;
    FGeneration: Integer;
    function GetGeneration: Integer;
  public
    constructor Create(const AKind: TFastTextureKind; const AFormat: TFastTextureFormat;
      const AWidth, AHeight, AMips: Integer);
    destructor Destroy; override;
    /// <summary>Pixels into a rectangle of a mip level of a face (0 for 2D; cube faces +X, -X, +Y, -Y, +Z, -Z).
    /// Compressed formats: blocks of 4 x 4 pixels, X and Y multiples of 4, ARowPitch the bytes of a row of blocks.
    /// </summary>
    procedure Upload(const AFace, AMip, X, Y, AWidth, AHeight: Integer; const AData: Pointer; const ARowPitch: Integer);
    /// <summary>The object of the installed context (nil without a device right now).</summary>
    function Native: IInterface;
    property Kind: TFastTextureKind read FKind;
    property Format: TFastTextureFormat read FFormat;
    property Width: Integer read FWidth;
    property Height: Integer read FHeight;
    property Mips: Integer read FMips;
    /// <summary>1 after Create; grows when a device loss gave the texture new (zeroed) GPU memory.</summary>
    property Generation: Integer read GetGeneration;
  end;

  /// <summary>A vertex or index buffer in GPU memory for raw draws. Write is recorded in program order.</summary>
  TFastBuffer = class
  private
    FSize: Integer;
    FIndex: Boolean;
    FNative: IInterface;
    FDeviceGen: Integer;
    FGeneration: Integer;
    function GetGeneration: Integer;
  public
    constructor Create(const ASize: Integer; const AIndex: Boolean);
    destructor Destroy; override;
    procedure Write(const AOffset: Integer; const AData: Pointer; const ASize: Integer);
    function Native: IInterface;
    property Size: Integer read FSize;
    property IsIndex: Boolean read FIndex;
    property Generation: Integer read GetGeneration;
  end;

  /// <summary>A draw with the program's shaders (TContextShader with DX11 / DX10 bytecode for Direct3D and a SPIR-V
  /// source (FastShaderArchSpirV) for Vulkan, from the same HLSL: their constant buffers at b0, textures at tN with
  /// their samplers at sN), vertex layout and state, between BeginScene and EndScene.
  /// Geometry from memory (Vertices / Indices, copied when recorded) or from TFastBuffers (the offsets in bytes).
  /// Rectangles in pixels of the target, top-left origin; an empty Scissor clips nothing, an empty Viewport is the
  /// whole target.</summary>
  TFastRawDraw = record
    VertexShader, PixelShader: TContextShader;
    Layout: TFastVertexLayout;
    Stride: Integer;
    Kind: TPrimitivesKind;
    Vertices: Pointer;
    VertexCount: Integer;
    VertexBuffer: TFastBuffer;
    VertexOffset: Integer;
    Indices: Pointer;
    IndexBuffer: TFastBuffer;
    IndexOffset: Integer;
    Index32: Boolean;
    IndexCount: Integer;
    /// <summary>Added to the indices (buffers only).</summary>
    BaseVertex: Integer;
    VSConstants, PSConstants: Pointer;
    VSConstantSize, PSConstantSize: Integer;
    Textures: array[0..7] of TFastTexture;
    Samplers: array[0..7] of TFastSampler;
    State: TFastRawState;
    StencilRef: Byte;
    Scissor: TRect;
    Viewport: TRect;
  end;

  TFastReadKind = (Color, Depth, Stencil);

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
    /// <summary>Raw draws: the installed context class (it makes the objects of TFastTexture and TFastBuffer), and
    /// one more at every device loss (those objects are made again, empty).</summary>
    FInstalled: TContextClass;
    FDeviceGen: Integer;
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
    /// <summary>Device: the variables of a shader FMX ships no Direct3D source for (off Windows), as the Direct3D
    /// source lays them out (constant offsets and sizes, texture units); False: the shader is not taken.</summary>
    class function ShaderLayout(const Shader: TContextShader; out AVariables: TContextShaderVariables): Boolean;
      virtual;
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

    { Raw draws (USAGE.md, "Raw draws"). Main thread, as the scenes. }

    /// <summary>Draws with the program's shaders, layout, geometry, textures and state (TFastRawDraw), between
    /// BeginScene and EndScene. FMX's own state (SetContextState, the material of the next DrawPrimitives) is not
    /// changed by it.</summary>
    procedure DrawRaw(const ADraw: TFastRawDraw); virtual; abstract;
    /// <summary>Copies ASource (pixels of the target, top-left origin) of what the scene has drawn so far into ADest
    /// at (ADestX, ADestY), mip level 0. ADepth: the depth buffer instead (the whole of it into a Depth24 texture of
    /// its size). The color copy needs a texture of the target's format (BGRA8 for TViewport3D-like targets).
    /// </summary>
    procedure CopyToTexture(const ADest: TFastTexture; const ADestX, ADestY: Integer; const ASource: TRect;
      const ADepth: Boolean); virtual; abstract;
    /// <summary>Waits for what was recorded and reads ARect of the target: Color as the target stores it (4 bytes
    /// per pixel, BGRA), Depth as 4 bytes per pixel (0..1 as Single), Stencil 1 byte per pixel. Rows of APitch bytes,
    /// top first.</summary>
    procedure ReadTarget(const ARect: TRect; const AKind: TFastReadKind; const ADest: Pointer;
      const APitch: Integer); virtual; abstract;
    /// <summary>The context class installed last (InstallFastContext3D11 / 12 / Vk); raw draws need one.</summary>
    class function Installed: TContextClass;
    /// <summary>Device of the installed class: the objects of TFastTexture and TFastBuffer.</summary>
    class function NewTextureObject(const ATexture: TFastTexture): IInterface; virtual; abstract;
    class procedure UploadTextureObject(const ATexture: TFastTexture; const AObject: IInterface;
      const AFace, AMip, X, Y, AWidth, AHeight: Integer; const AData: Pointer; const ARowPitch: Integer);
      virtual; abstract;
    class function NewBufferObject(const ABuffer: TFastBuffer): IInterface; virtual; abstract;
    class procedure WriteBufferObject(const ABuffer: TFastBuffer; const AObject: IInterface; const AOffset: Integer;
      const AData: Pointer; const ASize: Integer); virtual; abstract;
    /// <summary>The installer of a context class (raw draws use it) and the device loss handlers.</summary>
    class procedure SetInstalled(const AClass: TContextClass);
    class procedure RawDeviceLost;
  end;

  TFastContext3DClass = class of TFastContext3D;

const
  /// <summary>The arch of a raw-draw shader's SPIR-V source (TContextShaderSource) for TFastContext3DVk. FMX has no
  /// arch for SPIR-V and none of its own contexts takes a source of this one (TContextShaderSource.IsDefined is False
  /// for it); TFastContext3DVk takes the source whose code starts with SPIR-V's magic number.</summary>
  FastShaderArchSpirV = TContextShaderArch.Undefined;
  FastSpirVMagic = Cardinal($07230203);

var
  /// <summary>Ray-traced effects every new 3D context that traces rays starts with (TViewport3D, TForm3D, filters).
  /// </summary>
  FastContext3DRayTracing: TFastRayTracing = (Shadows: False; ShadowStrength: 0.7; ShadowSoftness: 0;
    ShadowSamples: 8; AmbientOcclusion: False; AORadius: 1; AOStrength: 0.6; AOSamples: 8; Reflections: False;
    ReflectionStrength: 1);
  /// <summary>TContextStyle.Fragile: FMX keeps a copy of texture pixels and recreates textures and shaders after a
  /// device loss (TContextLostMessage / TContextResetMessage). Costs a message subscription per TTexture. Read when
  /// the context class is installed (FastCanvas.Context3D11 has it as well).</summary>
  FastContext3DFragile: Boolean = True;

/// <summary>Bytes of a block (compressed formats: 4 x 4 pixels) or pixel of a raw texture format.</summary>
function FastTextureBlockBytes(const AFormat: TFastTextureFormat): Integer;
/// <summary>The format is compressed in blocks of 4 x 4 pixels.</summary>
function FastTextureCompressed(const AFormat: TFastTextureFormat): Boolean;
/// <summary>DXGI_FORMAT of a raw texture format: the resource format (Depth24: R24G8_TYPELESS) and the format of its
/// shader view (Depth24: R24_UNORM_X8_TYPELESS).</summary>
function FastTextureDxgiFormat(const AFormat: TFastTextureFormat; const AView: Boolean): Integer;
/// <summary>The SPIR-V source of a shader (of FastShaderArchSpirV, its code starting with SPIR-V's magic number);
/// False without one.</summary>
function FastSpirVSource(const AShader: TContextShader; out ASource: TContextShaderSource): Boolean;

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
  DXGI_FORMAT_R16G16_UNORM = 35;
  DXGI_FORMAT_R24G8_TYPELESS = 44;
  DXGI_FORMAT_R24_UNORM_X8_TYPELESS = 46;
  DXGI_FORMAT_R8G8_UNORM = 49;
  DXGI_FORMAT_BC1_UNORM = 71;
  DXGI_FORMAT_BC2_UNORM = 74;
  DXGI_FORMAT_BC3_UNORM = 77;
  DXGI_FORMAT_BC4_UNORM = 80;
  DXGI_FORMAT_BC5_UNORM = 83;

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

function FastTextureBlockBytes(const AFormat: TFastTextureFormat): Integer;
begin
  case AFormat of
    TFastTextureFormat.R8: Result := 1;
    TFastTextureFormat.RG8, TFastTextureFormat.R16: Result := 2;
    TFastTextureFormat.RGBA16F, TFastTextureFormat.BC1, TFastTextureFormat.BC4: Result := 8;
    TFastTextureFormat.RGBA32F, TFastTextureFormat.BC2, TFastTextureFormat.BC3, TFastTextureFormat.BC5: Result := 16;
  else
    Result := 4;
  end;
end;

function FastTextureCompressed(const AFormat: TFastTextureFormat): Boolean;
begin
  Result := AFormat in [TFastTextureFormat.BC1, TFastTextureFormat.BC2, TFastTextureFormat.BC3, TFastTextureFormat.BC4,
    TFastTextureFormat.BC5];
end;

function FastTextureDxgiFormat(const AFormat: TFastTextureFormat; const AView: Boolean): Integer;
begin
  case AFormat of
    TFastTextureFormat.RGBA8: Result := DXGI_FORMAT_R8G8B8A8_UNORM;
    TFastTextureFormat.BGRA8: Result := DXGI_FORMAT_B8G8R8A8_UNORM;
    TFastTextureFormat.R8: Result := DXGI_FORMAT_R8_UNORM;
    TFastTextureFormat.RG8: Result := DXGI_FORMAT_R8G8_UNORM;
    TFastTextureFormat.R16: Result := DXGI_FORMAT_R16_UNORM;
    TFastTextureFormat.RG16: Result := DXGI_FORMAT_R16G16_UNORM;
    TFastTextureFormat.RGBA16F: Result := DXGI_FORMAT_R16G16B16A16_FLOAT;
    TFastTextureFormat.RGBA32F: Result := DXGI_FORMAT_R32G32B32A32_FLOAT;
    TFastTextureFormat.BC1: Result := DXGI_FORMAT_BC1_UNORM;
    TFastTextureFormat.BC2: Result := DXGI_FORMAT_BC2_UNORM;
    TFastTextureFormat.BC3: Result := DXGI_FORMAT_BC3_UNORM;
    TFastTextureFormat.BC4: Result := DXGI_FORMAT_BC4_UNORM;
    TFastTextureFormat.BC5: Result := DXGI_FORMAT_BC5_UNORM;
  else
    if AView then
      Result := DXGI_FORMAT_R24_UNORM_X8_TYPELESS
    else
      Result := DXGI_FORMAT_R24G8_TYPELESS;
  end;
end;

function FastSpirVSource(const AShader: TContextShader; out ASource: TContextShaderSource): Boolean;
begin
  ASource := AShader.GetSourceByArch(FastShaderArchSpirV);
  Result := (Length(ASource.Code) >= 20) and ((Length(ASource.Code) and 3) = 0) and
    (PCardinal(@ASource.Code[0])^ = FastSpirVMagic);
end;

{ TFastVertexLayout }

class function TFastVertexLayout.Create(const AElements: array of TFastVertexElement): TFastVertexLayout;
var
  N: Integer;
begin
  SetLength(Result.Elements, Length(AElements));
  for N := 0 to High(AElements) do
    Result.Elements[N] := AElements[N];
  Result.Hash := $CBF29CE484222325;
  for N := 0 to High(Result.Elements) do
  begin
    Result.Hash := FastHash(@Result.Elements[N].SemanticIndex, 3 * SizeOf(Integer), Result.Hash);
    Result.Hash := FastHash(Result.Elements[N].Semantic, Length(AnsiString(Result.Elements[N].Semantic)),
      Result.Hash);
  end;
end;

{ TFastRawState }

class function TFastRawState.Default: TFastRawState;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.SrcBlend := TFastBlend.One;
  Result.DestBlend := TFastBlend.Zero;
  Result.BlendOp := TFastBlendOp.Add;
  Result.SrcBlendAlpha := TFastBlend.One;
  Result.DestBlendAlpha := TFastBlend.Zero;
  Result.BlendOpAlpha := TFastBlendOp.Add;
  Result.WriteMask := $F;
  Result.DepthEnable := True;
  Result.DepthWrite := True;
  Result.DepthFunc := TFastCompare.LessEqual;
  Result.StencilReadMask := $FF;
  Result.StencilWriteMask := $FF;
  Result.FrontFace.Fail := TFastStencilOp.Keep;
  Result.FrontFace.DepthFail := TFastStencilOp.Keep;
  Result.FrontFace.Pass := TFastStencilOp.Keep;
  Result.FrontFace.Func := TFastCompare.Always;
  Result.BackFace := Result.FrontFace;
  Result.Cull := TFastCullMode.None;
end;

{ TFastSampler }

class function TFastSampler.Default: TFastSampler;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Filter := $15;   // MIN_MAG_MIP_LINEAR
  Result.AddressU := 1;
  Result.AddressV := 1;
  Result.AddressW := 1;
  Result.MaxAnisotropy := 1;
  Result.MinLOD := 0;
  Result.MaxLOD := MaxSingle;
end;

{ TFastTexture }

constructor TFastTexture.Create(const AKind: TFastTextureKind; const AFormat: TFastTextureFormat;
  const AWidth, AHeight, AMips: Integer);
begin
  inherited Create;
  if (AWidth <= 0) or (AHeight <= 0) or (AWidth > 16384) or (AHeight > 16384) or (AMips <= 0) or
    ((AKind = TFastTextureKind.Cube) and (AWidth <> AHeight)) then
    raise EArgumentOutOfRangeException.CreateFmt('FastContext3D: a texture of %d x %d pixels, %d levels',
      [AWidth, AHeight, AMips]);
  FKind := AKind;
  FFormat := AFormat;
  FWidth := AWidth;
  FHeight := AHeight;
  FMips := AMips;
  // The GPU memory now: no installed context raises here.
  Native;
end;

destructor TFastTexture.Destroy;
begin
  // Recorded commands keep their own reference.
  TCanvas.Lock;
  try
    FNative := nil;
  finally
    TCanvas.Unlock;
  end;
  inherited;
end;

function TFastTexture.Native: IInterface;
begin
  TCanvas.Lock;
  try
    if (FNative = nil) or (FDeviceGen <> TFastContext3D.FDeviceGen) then
    begin
      if TFastContext3D.FInstalled = nil then
        raise EContext3DException.Create('FastContext3D: raw draws need InstallFastContext3D11, 12 or Vk');
      FNative := nil;
      try
        FNative := TFastContext3DClass(TFastContext3D.FInstalled).NewTextureObject(Self);
      except
        // No device right now (removed and not replaced yet).
        if FGeneration > 0 then
          Exit(nil);
        raise;
      end;
      FDeviceGen := TFastContext3D.FDeviceGen;
      Inc(FGeneration);
    end;
    Result := FNative;
  finally
    TCanvas.Unlock;
  end;
end;

function TFastTexture.GetGeneration: Integer;
begin
  Native;
  Result := FGeneration;
end;

procedure TFastTexture.Upload(const AFace, AMip, X, Y, AWidth, AHeight: Integer; const AData: Pointer;
  const ARowPitch: Integer);
var
  W, H: Integer;
  N: IInterface;
begin
  if (AWidth <= 0) or (AHeight <= 0) or (AData = nil) then
    Exit;
  W := Max(1, FWidth shr AMip);
  H := Max(1, FHeight shr AMip);
  if (AMip < 0) or (AMip >= FMips) or (AFace < 0) or ((FKind = TFastTextureKind.Texture2D) and (AFace > 0)) or
    (AFace > 5) or (X < 0) or (Y < 0) or (X + AWidth > W) or (Y + AHeight > H) or
    (FastTextureCompressed(FFormat) and (((X and 3) <> 0) or ((Y and 3) <> 0))) then
    raise EArgumentOutOfRangeException.CreateFmt('FastContext3D: upload of %d x %d at (%d, %d) into level %d face %d',
      [AWidth, AHeight, X, Y, AMip, AFace]);
  TCanvas.Lock;
  try
    N := Native;
    if N <> nil then
      TFastContext3DClass(TFastContext3D.FInstalled).UploadTextureObject(Self, N, AFace, AMip, X, Y, AWidth,
        AHeight, AData, ARowPitch);
  finally
    TCanvas.Unlock;
  end;
end;

{ TFastBuffer }

constructor TFastBuffer.Create(const ASize: Integer; const AIndex: Boolean);
begin
  inherited Create;
  if ASize <= 0 then
    raise EArgumentOutOfRangeException.CreateFmt('FastContext3D: a buffer of %d bytes', [ASize]);
  FSize := ASize;
  FIndex := AIndex;
  Native;
end;

destructor TFastBuffer.Destroy;
begin
  TCanvas.Lock;
  try
    FNative := nil;
  finally
    TCanvas.Unlock;
  end;
  inherited;
end;

function TFastBuffer.Native: IInterface;
begin
  TCanvas.Lock;
  try
    if (FNative = nil) or (FDeviceGen <> TFastContext3D.FDeviceGen) then
    begin
      if TFastContext3D.FInstalled = nil then
        raise EContext3DException.Create('FastContext3D: raw draws need InstallFastContext3D11, 12 or Vk');
      FNative := nil;
      try
        FNative := TFastContext3DClass(TFastContext3D.FInstalled).NewBufferObject(Self);
      except
        if FGeneration > 0 then
          Exit(nil);
        raise;
      end;
      FDeviceGen := TFastContext3D.FDeviceGen;
      Inc(FGeneration);
    end;
    Result := FNative;
  finally
    TCanvas.Unlock;
  end;
end;

function TFastBuffer.GetGeneration: Integer;
begin
  Native;
  Result := FGeneration;
end;

procedure TFastBuffer.Write(const AOffset: Integer; const AData: Pointer; const ASize: Integer);
var
  N: IInterface;
begin
  if (ASize <= 0) or (AData = nil) then
    Exit;
  if (AOffset < 0) or (AOffset > FSize - ASize) then
    raise EArgumentOutOfRangeException.CreateFmt('FastContext3D: %d bytes at %d into a buffer of %d bytes',
      [ASize, AOffset, FSize]);
  TCanvas.Lock;
  try
    N := Native;
    if N <> nil then
      TFastContext3DClass(TFastContext3D.FInstalled).WriteBufferObject(Self, N, AOffset, AData, ASize);
  finally
    TCanvas.Unlock;
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

class function TFastContext3D.Installed: TContextClass;
begin
  Result := FInstalled;
end;

class procedure TFastContext3D.SetInstalled(const AClass: TContextClass);
begin
  FInstalled := AClass;
end;

class procedure TFastContext3D.RawDeviceLost;
begin
  Inc(FDeviceGen);
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

class function TFastContext3D.ShaderLayout(const Shader: TContextShader;
  out AVariables: TContextShaderVariables): Boolean;
begin
  AVariables := nil;
  Result := False;
end;

class procedure TFastContext3D.DoInitializeShader(const Shader: TContextShader);
var
  Src: TContextShaderSource;
  Variables: TContextShaderVariables;
  S: TFastShader;
  V: TContextShaderVariable;
  I: Integer;
begin
  // A Direct3D 10+ device: DX11, then DX10, then DX11_level_9 (all FMX ships for Windows: DX11_level_9). Elsewhere
  // the device may know the layout (ShaderLayout).
  Src := Shader.GetSourceByArch(TContextShaderArch.DX11);
  if not Src.IsDefined then
    Src := Shader.GetSourceByArch(TContextShaderArch.DX10);
  if not Src.IsDefined then
    Src := Shader.GetSourceByArch(TContextShaderArch.DX11_level_9);
  if Src.IsDefined then
    Variables := Src.Variables
  else if not ShaderLayout(Shader, Variables) then
    Exit;
  S := TFastShader.Create;
  try
    Inc(FNextShaderId);
    S.Id := FNextShaderId;
    S.Kind := Shader.Kind;
    S.Code := Copy(TBytes(Src.Code));
    S.Variables := Copy(Variables);
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
