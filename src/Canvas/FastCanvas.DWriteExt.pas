unit FastCanvas.DWriteExt;

{ DirectWrite 1/2 and Direct2D multithread declarations that the RTL unit Winapi.D2D1 lacks (it covers
  DirectWrite 1.0 only). Translated from the Windows SDK headers dwrite_1.h, dwrite_2.h and d2d1_1.h; the
  same rules as FastCanvas.D2D1Ext apply (exact vtable order, unused methods keep their slot with simplified
  but ABI-compatible parameters, clashing names get a suffix). }

interface

uses
  Winapi.Windows, Winapi.D2D1;

const
  DWRITE_GRID_FIT_MODE_DEFAULT = 0;
  DWRITE_GRID_FIT_MODE_DISABLED = 1;
  DWRITE_GRID_FIT_MODE_ENABLED = 2;

  DWRITE_TEXT_ANTIALIAS_MODE_CLEARTYPE = 0;
  DWRITE_TEXT_ANTIALIAS_MODE_GRAYSCALE = 1;

  /// <summary>OpenType table tags as read by IDWriteFontFace.TryGetFontTable (bytes in file order).</summary>
  DWRITE_TABLE_COLR = Ord('C') or (Ord('O') shl 8) or (Ord('L') shl 16) or (Ord('R') shl 24);
  DWRITE_TABLE_CBDT = Ord('C') or (Ord('B') shl 8) or (Ord('D') shl 16) or (Ord('T') shl 24);
  DWRITE_TABLE_SBIX = Ord('s') or (Ord('b') shl 8) or (Ord('i') shl 16) or (Ord('x') shl 24);
  DWRITE_TABLE_SVG = Ord('S') or (Ord('V') shl 8) or (Ord('G') shl 16) or (Ord(' ') shl 24);

type
  IDWriteRenderingParams1 = interface(IDWriteRenderingParams)
    ['{94413cf4-a6fc-4248-8b50-6674348fcad3}']
    function GetGrayscaleEnhancedContrast: Single; stdcall;
  end;

  IDWriteFactory1 = interface(IDWriteFactory)
    ['{30572f99-dac6-41db-a16e-0486307e606a}']
    function GetEudcFontCollection(out fontCollection: IDWriteFontCollection; checkForUpdates: BOOL): HResult; stdcall;
    function CreateCustomRenderingParams1(gamma, enhancedContrast, enhancedContrastGrayscale, clearTypeLevel: Single;
      pixelGeometry: DWRITE_PIXEL_GEOMETRY; renderingMode: DWRITE_RENDERING_MODE;
      out renderingParams: IUnknown): HResult; stdcall;
  end;

  IDWriteFactory2 = interface(IDWriteFactory1)
    ['{0439fc60-ca44-4994-8dee-3a9af7b732ec}']
    function GetSystemFontFallback(out fontFallback: IUnknown): HResult; stdcall;
    function CreateFontFallbackBuilder(out fontFallbackBuilder: IUnknown): HResult; stdcall;
    function TranslateColorGlyphRun(baselineOriginX, baselineOriginY: Single; glyphRun: PDwriteGlyphRun;
      glyphRunDescription: Pointer; measuringMode: DWRITE_MEASURING_MODE; worldToDeviceTransform: PDwriteMatrix;
      colorPaletteIndex: Cardinal; out colorLayers: IUnknown): HResult; stdcall;
    function CreateCustomRenderingParams2(gamma, enhancedContrast, grayscaleEnhancedContrast, clearTypeLevel: Single;
      pixelGeometry: DWRITE_PIXEL_GEOMETRY; renderingMode: DWRITE_RENDERING_MODE; gridFitMode: Integer;
      out renderingParams: IUnknown): HResult; stdcall;
    /// <summary>antialiasMode GRAYSCALE with texture type DWRITE_TEXTURE_ALIASED_1x1 gives 8-bit coverage.</summary>
    function CreateGlyphRunAnalysis2(glyphRun: PDwriteGlyphRun; transform: PDwriteMatrix;
      renderingMode: DWRITE_RENDERING_MODE; measuringMode: DWRITE_MEASURING_MODE; gridFitMode: Integer;
      antialiasMode: Integer; baselineOriginX, baselineOriginY: Single;
      out glyphRunAnalysis: IDWriteGlyphRunAnalysis): HResult; stdcall;
  end;

  /// <summary>d2d1_1.h. QueryInterface of a multithreaded ID2D1Factory1: the lock Direct2D takes around its use
  /// of the Direct3D immediate context.</summary>
  ID2D1Multithread = interface(IUnknown)
    ['{31e6e7bc-e0ff-4d46-8c64-a0a8c41c15d3}']
    function GetMultithreadProtected: BOOL; stdcall;
    procedure Enter; stdcall;
    procedure Leave; stdcall;
  end;

implementation

end.
