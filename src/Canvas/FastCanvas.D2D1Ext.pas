unit FastCanvas.D2D1Ext;

{ Minimal Direct2D 1.1 / 1.2 and DXGI 1.5 declarations on top of the RTL units Winapi.D2D1,
  Winapi.DXGI and Winapi.DXGI1_2 (which only cover Direct2D 1.0 and DXGI 1.2).

  Translated from the Windows SDK headers d2d1_1.h, d2d1_2.h and dxgi1_5.h (10.0.22621), with
  DelphiDX12 (https://github.com/CMCHTPC/DelphiDX12, Historic/Units, rev 900c20e, Apache 2.0) as a
  cross-reference.

  Rules:
  - The vtable order follows the C++ headers exactly. C++ inline overloads are not part of it.
  - Methods that are called here have exact parameter types. Methods that are never called keep
    their slot with simplified but ABI-compatible parameters (interfaces as IUnknown, structures
    as pointers).
  - Methods that would clash with a method of the same name in an ancestor interface get the
    suffix 1 (only the slot position matters for COM).
  - Small structures are passed by value without const: Delphi may pass a const record by
    reference, which breaks the Win64 ABI for 8-byte structures. }

interface

uses
  Winapi.Windows, Winapi.DXGI, Winapi.DXGI1_2, Winapi.DXGI1_4, Winapi.D2D1, Winapi.DxgiFormat;

const
  D2D1_BITMAP_OPTIONS_NONE = $0;
  D2D1_BITMAP_OPTIONS_TARGET = $1;
  D2D1_BITMAP_OPTIONS_CANNOT_DRAW = $2;
  D2D1_BITMAP_OPTIONS_CPU_READ = $4;
  D2D1_BITMAP_OPTIONS_GDI_COMPATIBLE = $8;

  D2D1_DEVICE_CONTEXT_OPTIONS_NONE = 0;
  D2D1_DEVICE_CONTEXT_OPTIONS_ENABLE_MULTITHREADED_OPTIMIZATIONS = 1;

  D2D1_INTERPOLATION_MODE_NEAREST_NEIGHBOR = 0;
  D2D1_INTERPOLATION_MODE_LINEAR = 1;
  D2D1_INTERPOLATION_MODE_CUBIC = 2;
  D2D1_INTERPOLATION_MODE_MULTI_SAMPLE_LINEAR = 3;
  D2D1_INTERPOLATION_MODE_ANISOTROPIC = 4;
  D2D1_INTERPOLATION_MODE_HIGH_QUALITY_CUBIC = 5;

  D2D1_PRIMITIVE_BLEND_SOURCE_OVER = 0;
  D2D1_PRIMITIVE_BLEND_COPY = 1;

  // dxgi1_5.h / dxgi.h
  DXGI_FEATURE_PRESENT_ALLOW_TEARING = 0;
  DXGI_SWAP_CHAIN_FLAG_ALLOW_TEARING = 2048;
  DXGI_PRESENT_ALLOW_TEARING = $200;

type
  TD2D1BitmapProperties1 = record
    pixelFormat: TD2D1PixelFormat;
    dpiX: Single;
    dpiY: Single;
    bitmapOptions: Cardinal;
    colorContext: Pointer; // ID2D1ColorContext, not used
  end;
  PD2D1BitmapProperties1 = ^TD2D1BitmapProperties1;

  TD2D1MappedRect = record
    pitch: Cardinal;
    bits: PByte;
  end;

  ID2D1Device = interface;

  ID2D1Bitmap1 = interface(ID2D1Bitmap)
    ['{a898a84c-3873-4588-b08b-ebbf978df041}']
    procedure GetColorContext(out colorContext: IUnknown); stdcall;
    function GetOptions: Cardinal; stdcall;
    function GetSurface(out dxgiSurface: IDXGISurface): HResult; stdcall;
    function Map(options: Cardinal; out mappedRect: TD2D1MappedRect): HResult; stdcall;
    function Unmap: HResult; stdcall;
  end;

  ID2D1DeviceContext = interface(ID2D1RenderTarget)
    ['{e8f7fe7a-191c-466d-ad95-975678bda998}']
    function CreateBitmap1(size: D2D1_SIZE_U; sourceData: Pointer; pitch: Cardinal;
      bitmapProperties: PD2D1BitmapProperties1; out bitmap: ID2D1Bitmap1): HResult; stdcall;
    function CreateBitmapFromWicBitmap1(wicBitmapSource: IUnknown; bitmapProperties: PD2D1BitmapProperties1;
      out bitmap: ID2D1Bitmap1): HResult; stdcall;
    function CreateColorContext(space: Cardinal; profile: PByte; profileSize: Cardinal;
      out colorContext: IUnknown): HResult; stdcall;
    function CreateColorContextFromFilename(filename: PWideChar; out colorContext: IUnknown): HResult; stdcall;
    function CreateColorContextFromWicColorContext(wicColorContext: IUnknown;
      out colorContext: IUnknown): HResult; stdcall;
    function CreateBitmapFromDxgiSurface(surface: IDXGISurface; bitmapProperties: PD2D1BitmapProperties1;
      out bitmap: ID2D1Bitmap1): HResult; stdcall;
    function CreateEffect(const effectId: TGUID; out effect: IUnknown): HResult; stdcall;
    function CreateGradientStopCollection1(stops: PD2D1GradientStop; stopsCount: Cardinal;
      preInterpolationSpace, postInterpolationSpace, bufferPrecision, extendMode,
      colorInterpolationMode: Cardinal; out gradientStopCollection: ID2D1GradientStopCollection): HResult; stdcall;
    function CreateImageBrush(image: IUnknown; imageBrushProperties: Pointer; brushProperties: Pointer;
      out imageBrush: IUnknown): HResult; stdcall;
    function CreateBitmapBrush1(bitmap: ID2D1Bitmap; bitmapBrushProperties: Pointer; brushProperties: Pointer;
      out bitmapBrush: IUnknown): HResult; stdcall;
    function CreateCommandList(out commandList: IUnknown): HResult; stdcall;
    function IsDxgiFormatSupported(format: DXGI_FORMAT): BOOL; stdcall;
    function IsBufferPrecisionSupported(bufferPrecision: Cardinal): BOOL; stdcall;
    function GetImageLocalBounds(image: IUnknown; out localBounds: TD2D1RectF): HResult; stdcall;
    function GetImageWorldBounds(image: IUnknown; out worldBounds: TD2D1RectF): HResult; stdcall;
    function GetGlyphRunWorldBounds(baselineOrigin: TD2D1Point2F; glyphRun: Pointer; measuringMode: Cardinal;
      out bounds: TD2D1RectF): HResult; stdcall;
    procedure GetDevice(out device: ID2D1Device); stdcall;
    /// <summary>image: ID2D1Image (an ID2D1Bitmap1 created with D2D1_BITMAP_OPTIONS_TARGET) or nil.</summary>
    procedure SetTarget(image: IUnknown); stdcall;
    procedure GetTarget(out image: IUnknown); stdcall;
    procedure SetRenderingControls(renderingControls: Pointer); stdcall;
    procedure GetRenderingControls(renderingControls: Pointer); stdcall;
    procedure SetPrimitiveBlend(primitiveBlend: Cardinal); stdcall;
    function GetPrimitiveBlend: Cardinal; stdcall;
    procedure SetUnitMode(unitMode: Cardinal); stdcall;
    function GetUnitMode: Cardinal; stdcall;
    procedure DrawGlyphRun1(baselineOrigin: TD2D1Point2F; glyphRun: Pointer; glyphRunDescription: Pointer;
      foregroundBrush: ID2D1Brush; measuringMode: Cardinal); stdcall;
    procedure DrawImage(image: IUnknown; targetOffset: PD2D1Point2F; imageRectangle: PD2D1RectF;
      interpolationMode: Cardinal; compositeMode: Cardinal); stdcall;
    procedure DrawGdiMetafile(gdiMetafile: IUnknown; targetOffset: PD2D1Point2F); stdcall;
    procedure DrawBitmap1(bitmap: ID2D1Bitmap; destinationRectangle: PD2D1RectF; opacity: Single;
      interpolationMode: Cardinal; sourceRectangle: PD2D1RectF; perspectiveTransform: Pointer); stdcall;
    procedure PushLayer1(layerParameters: Pointer; layer: ID2D1Layer); stdcall;
    function InvalidateEffectInputRectangle(effect: IUnknown; input: Cardinal;
      inputRectangle: PD2D1RectF): HResult; stdcall;
    function GetEffectInvalidRectangleCount(effect: IUnknown; out rectangleCount: Cardinal): HResult; stdcall;
    function GetEffectInvalidRectangles(effect: IUnknown; rectangles: PD2D1RectF;
      rectanglesCount: Cardinal): HResult; stdcall;
    function GetEffectRequiredInputRectangles(renderEffect: IUnknown; renderImageRectangle: PD2D1RectF;
      inputDescriptions: Pointer; requiredInputRects: PD2D1RectF; inputCount: Cardinal): HResult; stdcall;
    procedure FillOpacityMask1(opacityMask: ID2D1Bitmap; brush: ID2D1Brush; destinationRectangle: PD2D1RectF;
      sourceRectangle: PD2D1RectF); stdcall;
  end;

  ID2D1Device = interface(ID2D1Resource)
    ['{47dd575d-ac05-4cdd-8049-9b02cd16f44c}']
    function CreateDeviceContext(options: Cardinal; out deviceContext: ID2D1DeviceContext): HResult; stdcall;
    function CreatePrintControl(wicFactory: IUnknown; documentTarget: IUnknown; printControlProperties: Pointer;
      out printControl: IUnknown): HResult; stdcall;
    procedure SetMaximumTextureMemory(maximumInBytes: UInt64); stdcall;
    function GetMaximumTextureMemory: UInt64; stdcall;
    procedure ClearResources(millisecondsSinceUse: Cardinal); stdcall;
  end;

  ID2D1Factory1 = interface(ID2D1Factory)
    ['{bb12d362-daee-4b9a-aa1d-14ba401cfa1f}']
    function CreateDevice(dxgiDevice: IDXGIDevice; out d2dDevice: ID2D1Device): HResult; stdcall;
    function CreateStrokeStyle1(strokeStyleProperties: Pointer; dashes: PSingle; dashesCount: Cardinal;
      out strokeStyle: IUnknown): HResult; stdcall;
    function CreatePathGeometry1(out pathGeometry: IUnknown): HResult; stdcall;
    function CreateDrawingStateBlock1(drawingStateDescription: Pointer; textRenderingParams: IUnknown;
      out drawingStateBlock: IUnknown): HResult; stdcall;
    function CreateGdiMetafile(metafileStream: IUnknown; out metafile: IUnknown): HResult; stdcall;
    function RegisterEffectFromStream(const classId: TGUID; propertyXml: IUnknown; bindings: Pointer;
      bindingsCount: Cardinal; effectFactory: Pointer): HResult; stdcall;
    function RegisterEffectFromString(const classId: TGUID; propertyXml: PWideChar; bindings: Pointer;
      bindingsCount: Cardinal; effectFactory: Pointer): HResult; stdcall;
    function UnregisterEffect(const classId: TGUID): HResult; stdcall;
    function GetRegisteredEffects(effects: PGUID; effectsCount: Cardinal; effectsReturned: PCardinal;
      effectsRegistered: PCardinal): HResult; stdcall;
    function GetEffectProperties(const effectId: TGUID; out properties: IUnknown): HResult; stdcall;
  end;

  { Direct2D 1.2 }

  ID2D1GeometryRealization = interface(ID2D1Resource)
    ['{a16907d7-bc02-4801-99e8-8cf7f485f774}']
  end;

  ID2D1DeviceContext1 = interface(ID2D1DeviceContext)
    ['{d37f57e4-6908-459f-a199-e72f24f79987}']
    function CreateFilledGeometryRealization(geometry: ID2D1Geometry; flatteningTolerance: Single;
      out geometryRealization: ID2D1GeometryRealization): HResult; stdcall;
    function CreateStrokedGeometryRealization(geometry: ID2D1Geometry; flatteningTolerance: Single;
      strokeWidth: Single; strokeStyle: ID2D1StrokeStyle;
      out geometryRealization: ID2D1GeometryRealization): HResult; stdcall;
    procedure DrawGeometryRealization(geometryRealization: ID2D1GeometryRealization; brush: ID2D1Brush); stdcall;
  end;

  { DXGI 1.5 }

  IDXGIFactory5 = interface(IDXGIFactory4)
    ['{7632e1f5-ee65-4dca-87fd-84cd75f8838d}']
    function CheckFeatureSupport(Feature: Cardinal; pFeatureSupportData: Pointer;
      FeatureSupportDataSize: Cardinal): HResult; stdcall;
  end;

function D2D1BitmapProperties1(const AFormat: DXGI_FORMAT; const AAlphaMode: TD2D1AlphaMode;
  const AOptions: Cardinal): TD2D1BitmapProperties1;

/// <summary>D3D11On12CreateDevice from d3d11.dll. Winapi.D3D11on12 imports it from d3d12.dll, where it does
/// not exist (the call fails with the delay-load error C06D007F).</summary>
{$WARN SYMBOL_PLATFORM OFF}
function D3D11On12CreateDevice(pDevice: IUnknown; Flags: Cardinal; pFeatureLevels: Pointer;
  FeatureLevels: Cardinal; ppCommandQueues: PPointer; NumQueues: Cardinal; NodeMask: Cardinal;
  out ppDevice: IUnknown; out ppImmediateContext: IUnknown; pChosenFeatureLevel: PCardinal): HResult; stdcall;
  external 'd3d11.dll' name 'D3D11On12CreateDevice' delayed;
{$WARN SYMBOL_PLATFORM DEFAULT}

implementation

function D2D1BitmapProperties1(const AFormat: DXGI_FORMAT; const AAlphaMode: TD2D1AlphaMode;
  const AOptions: Cardinal): TD2D1BitmapProperties1;
begin
  Result.pixelFormat.format := AFormat;
  Result.pixelFormat.alphaMode := AAlphaMode;
  Result.dpiX := 96;
  Result.dpiY := 96;
  Result.bitmapOptions := AOptions;
  Result.colorContext := nil;
end;

end.
