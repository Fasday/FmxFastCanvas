unit FastCanvas.TextPango;

{ The Pango text engine of FastCanvas (FastCanvas.Text), Linux only, the default there (FastCanvasTextEngine Native):
  the system's text libraries, so that a Linux program needs no Skia for its text.

  TFastPangoTextLayout lays text out with a PangoLayout on a PangoFT2 font map (fontconfig's fonts and font fallback,
  HarfBuzz shaping, line breaking, bidi, ellipsizing) with absolute font sizes (FMX's sizes are pixels) and glyph
  positions that are not rounded. The layout's runs become the glyph runs right away; the PangoFont of a run is told
  by its fontconfig pattern (font file, face index, synthetic emboldening and slant) and the position of its HarfBuzz
  font on the axes of a variable font, and gets an FT_Face of this unit's own FreeType library at that position,
  which makes the glyph coverage (unhinted outlines rendered at the canvas's subpixel positions: plain coverage, which
  the canvas corrects for gamma and contrast as it does DirectWrite's), the glyph outlines (large and rotated text)
  and the CPU image of layouts with color glyphs (the bitmaps of color fonts such as Noto Color Emoji, scaled; COLR
  layers as FreeType renders them). Hit testing and regions ask the PangoLayout, made again when asked for (cached
  layouts do not keep it).

  How FMX's layout parameters map, as FastCanvas.TextSkia maps them: WordWrap wraps at word boundaries, inside a word
  longer than the line (PANGO_WRAP_WORD_CHAR); without it lines are as long as they are and the text is moved by the
  alignment (overflowing text extends past the box as with DirectWrite). Trimming: without WordWrap every line
  (paragraph) is ellipsized at the box width; with it, the lines that fit in the box are shown, the last one
  ellipsized. Character trimming is Pango's (PANGO_ELLIPSIZE_END); word trimming cuts at the last word boundary before
  Pango's cut instead (a line of one word keeps its first character), leaving out the white space before it, as
  DirectWrite does, and lays the shortened text out again (positions and ranges are mapped between the texts). Leading
  and trailing alignment follow RightToLeft (the base direction of the paragraphs, not guessed from the text); the
  vertical alignment moves the layout in the box.
  Lines are as high as their fonts' ascent and descent (HarfBuzz's metrics: hhea, or OS/2 with USE_TYPO_METRICS).

  Libraries, loaded at run time (dlopen) on first use; GTK 3, which FMX needs on Linux, brings them:
  libpango-1.0.so.0 and libpangoft2-1.0.so.0 (Pango 1.44 or later), libgobject-2.0.so.0, libglib-2.0.so.0,
  libharfbuzz.so.0, libfontconfig.so.1, libfreetype.so.6. Pango is not thread-safe: every Pango call holds one lock;
  the FreeType faces another (glyphs are made on the render thread).

  Written from the Pango, fontconfig, HarfBuzz and FreeType documentation and headers (struct layouts checked with
  offsetof against Pango 1.57 and FreeType 2.14); no code from the FMX canvases. }

interface

{$IFDEF LINUX}

uses
  System.Types, System.UITypes, System.SysUtils, System.Math, System.Generics.Collections, FMX.Types, FMX.Graphics,
  FMX.TextLayout, FastCanvas.Text;

type
  /// <summary>The style of a range of the text.</summary>
  TFastPangoStyle = record
    Family: string;
    Size: Single;
    Weight: TFontWeight;
    Slant: TFontSlant;
    Stretch: TFontStretch;
    Underline, StrikeOut: Boolean;
    HasColor: Boolean;
    Color: TAlphaColor;
  end;

  /// <summary>Layout data of Pango: what its PangoLayout is made of (made again for hit testing), the runs, and where
  /// the layout sits in the layout box.</summary>
  TFastPangoLayoutData = class(TFastLayoutData)
  private
    /// <summary>The text laid out: the layout's text, or with word trimming that text shortened at word boundaries,
    /// with the ellipses as characters.</summary>
    FText: string;
    /// <summary>With word trimming: the index in the layout's text of every index of FText (and of its end); nil
    /// when FText is the layout's text.</summary>
    FMap: TArray<Integer>;
    FStyles: TArray<TFastPangoStyle>;
    /// <summary>The style of every UTF-16 code unit of FText (index into FStyles).</summary>
    FCharStyles: TArray<Integer>;
    /// <summary>FText in UTF-8 (nul-terminated), the UTF-16 index of every byte and the byte offset of every UTF-16
    /// index (both up to the end).</summary>
    FUtf8: TBytes;
    FByteToChar, FCharToByte: TArray<Integer>;
    FRtl: Boolean;
    /// <summary>PangoAlignment; the width in Pango units (-1: lines as long as they are); with ellipsizing the height
    /// in Pango units (the lines that fit), -1: every paragraph one line.</summary>
    FAlign, FWidth, FHeight: Integer;
    FEllipsize: Boolean;
    /// <summary>The PangoLayout (used under the Pango lock); nil until asked for again.</summary>
    FLayout: Pointer;
    procedure SetText(const AText: string; const ACharStyles: TArray<Integer>);
    function MakeLayout: Pointer;
    function Layout: Pointer;
    procedure TrimWords;
    procedure Analyse;
    /// <summary>The index in FText of an index of the layout's text.</summary>
    function ShownIndex(const AIndex: Integer): Integer;
    /// <summary>The index in the layout's text of an index of FText.</summary>
    function TextIndex(const AIndex: Integer): Integer;
  protected
    procedure CollectRuns; override;
  public
    /// <summary>The layout's origin in the layout box.</summary>
    Dx, Dy: Single;
    /// <summary>The text (its lines) in the layout box.</summary>
    TextRect: TRectF;
    destructor Destroy; override;
    function RenderColor(const AScale, ADx, ADy: Single; const AColor: TAlphaColor; const AWidth, AHeight: Integer;
      out APixels: TBytes): Boolean; override;
  end;

  TFastPangoTextLayout = class(TFastTextLayout)
  protected
    procedure DoRenderLayout; override;
    function GetTextHeight: Single; override;
    function GetTextWidth: Single; override;
    function GetTextRect: TRectF; override;
    function DoPositionAtPoint(const APoint: TPointF): Integer; override;
    function DoRegionForRange(const ARange: TTextRange): TRegion; override;
  public
    procedure ConvertToPath(const APath: TPathData); override;
  end;

  TFastPangoEngine = class(TFastTextEngine)
  public
    class function LayoutClass: TTextLayoutClass; override;
    class function RasterizeGlyph(const AFace: IInterface; const AGlyph: Word; const AEmSize, ASubX: Single;
      const AKind: TFastGlyphKind; const AMaxSize: Integer; var AMode: Integer; var ABuffer: TBytes;
      out ABounds: TRect): Boolean; override;
    class function GlyphOutline(const AFace: IInterface; const AGlyph: Word; const AEmSize: Single;
      const ASideways: Boolean; out APoints: TArray<TPathPoint>): Boolean; override;
    class procedure Shutdown; override;
  end;

var
  /// <summary>Glyph coverage hinted lightly: FreeType's light hinting (vertically only, stems and the x-height on the
  /// pixel grid; the look of GTK's text with fontconfig's default hintslight). False: unhinted outlines, as
  /// FastCanvas.TextSkia rasterizes. Set before the first text is drawn (glyphs stay in the atlas).</summary>
  FastPangoLightHinting: Boolean = False;

/// <summary>The versions of Pango and FreeType the engine runs on ('Pango 1.57.0, FreeType 2.14.2'), loading the
/// libraries; the reason when it cannot.</summary>
function FastPangoVersion: string;

{$ENDIF}

implementation

{$IFDEF LINUX}

uses
  Posix.Dlfcn, FastCanvas.Geometry;

{$POINTERMATH ON}

const
  PANGO_SCALE = 1024;
  PANGO_GLYPH_EMPTY = $0FFFFFFF;
  PANGO_GLYPH_UNKNOWN_FLAG = $10000000;
  PANGO_ANALYSIS_FLAG_IS_ELLIPSIS = 2;
  PANGO_WRAP_WORD_CHAR = 2;
  PANGO_ELLIPSIZE_END = 3;
  PANGO_ALIGN_LEFT = 0;
  PANGO_ALIGN_CENTER = 1;
  PANGO_ALIGN_RIGHT = 2;
  PANGO_DIRECTION_LTR = 0;
  PANGO_DIRECTION_RTL = 1;
  PANGO_STYLE_NORMAL = 0;
  PANGO_STYLE_OBLIQUE = 1;
  PANGO_STYLE_ITALIC = 2;
  PANGO_UNDERLINE_SINGLE = 1;
  /// <summary>PangoLogAttr bits: a line may break before the character; the character is white space; a cursor may
  /// stand before it (a grapheme starts).</summary>
  LogAttrLineBreak = $1;
  LogAttrWhite = $8;
  LogAttrCursorPosition = $10;

  FT_LOAD_DEFAULT = 0;
  FT_LOAD_NO_HINTING = $2;
  FT_LOAD_NO_BITMAP = $8;
  FT_LOAD_TARGET_LIGHT = $10000;
  FT_LOAD_COLOR = $100000;
  FT_RENDER_MODE_NORMAL = 0;
  FT_RENDER_MODE_MONO = 2;
  FT_PIXEL_MODE_MONO = 1;
  FT_PIXEL_MODE_GRAY = 2;
  FT_PIXEL_MODE_BGRA = 7;
  FT_GLYPH_FORMAT_OUTLINE = $6F75746C;
  FT_GLYPH_FORMAT_BITMAP = $62697473;
  FT_FACE_FLAG_SCALABLE = $1;
  FT_FACE_FLAG_COLOR = $4000;

  FcResultMatch = 0;

  /// <summary>FMX's font weights as CSS weights (FastCanvas.TextSkia's).</summary>
  FontWeights: array[TFontWeight] of Integer = (100, 200, 300, 350, 400, 500, 600, 700, 800, 900, 950);
  /// <summary>Pango units of the widest and highest box (a million pixels: within its 32-bit units).</summary>
  MaxPangoSize = 1E6;
  /// <summary>PangoFonts the table of fonts keeps before it starts over.</summary>
  MaxFonts = 1024;
  /// <summary>The smallest font size given to Pango (pixels; it takes no size of 0).</summary>
  MinFontSize = 0.1;

type
  // Pango's structs (pango-glyph.h, pango-item.h, pango-layout.h; x86-64, offsets checked with offsetof).
  TPangoRectangle = record
    X, Y, Width, Height: Integer;
  end;
  PPangoRectangle = ^TPangoRectangle;

  TPangoGlyphInfo = record
    Glyph: Cardinal;
    Width, XOffset, YOffset: Integer;
    Attr: Cardinal;
  end;
  PPangoGlyphInfo = ^TPangoGlyphInfo;

  TPangoGlyphString = record
    NumGlyphs: Integer;
    Glyphs: PPangoGlyphInfo;
    LogClusters: PInteger;
    Space: Integer;
  end;
  PPangoGlyphString = ^TPangoGlyphString;

  TPangoAnalysis = record
    ShapeEngine, LangEngine, Font: Pointer;
    Level, Gravity, Flags, Script: Byte;
    Language, ExtraAttrs: Pointer;
  end;

  TPangoItem = record
    Offset, Length, NumChars: Integer;
    Analysis: TPangoAnalysis;
  end;
  PPangoItem = ^TPangoItem;

  /// <summary>PangoGlyphItem (PangoLayoutRun); YOffset and the x offsets since Pango 1.50.</summary>
  TPangoGlyphItem = record
    Item: PPangoItem;
    Glyphs: PPangoGlyphString;
    YOffset, StartXOffset, EndXOffset: Integer;
  end;
  PPangoGlyphItem = ^TPangoGlyphItem;

  PGSList = ^TGSList;
  TGSList = record
    Data: Pointer;
    Next: PGSList;
  end;

  TPangoLayoutLine = record
    Layout: Pointer;
    StartIndex, Length: Integer;
    /// <summary>The runs (PPangoGlyphItem) in visual order, left to right.</summary>
    Runs: PGSList;
    /// <summary>is_paragraph_start (bit 0), resolved_dir (bits 1 to 3).</summary>
    Bits: Cardinal;
  end;
  PPangoLayoutLine = ^TPangoLayoutLine;

  TFcMatrix = record
    XX, XY, YX, YY: Double;
  end;
  PFcMatrix = ^TFcMatrix;

  // FreeType's structs (freetype.h, ftimage.h; FT_Long, FT_Pos and FT_Fixed are C longs: 64-bit), up to the fields
  // used.
  TFTVector = record
    X, Y: NativeInt;
  end;
  PFTVector = ^TFTVector;

  TFTMatrix = record
    XX, XY, YX, YY: NativeInt;
  end;
  PFTMatrix = ^TFTMatrix;

  TFTBitmap = record
    Rows, Width: Cardinal;
    Pitch: Integer;
    Buffer: PByte;
    NumGrays: Word;
    PixelMode, PaletteMode: Byte;
    Palette: Pointer;
  end;

  TFTBitmapSize = record
    Height, Width: SmallInt;
    Size, XPpem, YPpem: NativeInt;
  end;
  PFTBitmapSize = ^TFTBitmapSize;

  TFTOutline = record
    NContours, NPoints: Word;
    Points, Tags, Contours: Pointer;
    Flags: Integer;
  end;
  PFTOutline = ^TFTOutline;

  TFTGlyphMetrics = record
    Width, Height, HoriBearingX, HoriBearingY, HoriAdvance, VertBearingX, VertBearingY, VertAdvance: NativeInt;
  end;

  TFTGlyphSlotRec = record
    Library_, Face, Next: Pointer;
    GlyphIndex: Cardinal;
    Generic: array[0..1] of Pointer;
    Metrics: TFTGlyphMetrics;
    LinearHoriAdvance, LinearVertAdvance: NativeInt;
    Advance: TFTVector;
    Format: Cardinal;
    Bitmap: TFTBitmap;
    BitmapLeft, BitmapTop: Integer;
    Outline: TFTOutline;
  end;
  PFTGlyphSlotRec = ^TFTGlyphSlotRec;

  TFTFaceRec = record
    NumFaces, FaceIndex, FaceFlags, StyleFlags, NumGlyphs: NativeInt;
    FamilyName, StyleName: PAnsiChar;
    NumFixedSizes: Integer;
    AvailableSizes: PFTBitmapSize;
    NumCharmaps: Integer;
    Charmaps: Pointer;
    Generic: array[0..1] of Pointer;
    BBox: array[0..3] of NativeInt;
    UnitsPerEM: Word;
    Ascender, Descender, Height, MaxAdvanceWidth, MaxAdvanceHeight, UnderlinePosition,
      UnderlineThickness: SmallInt;
    Glyph: PFTGlyphSlotRec;
    Size: Pointer;
    Charmap: Pointer;
  end;
  PFTFaceRec = ^TFTFaceRec;

  TFTOutlineFuncs = record
    MoveTo, LineTo, ConicTo, CubicTo: Pointer;
    Shift: Integer;
    Delta: NativeInt;
  end;
  PFTOutlineFuncs = ^TFTOutlineFuncs;

// The layouts above, as offsetof and sizeof give them (explore.c, Pango 1.57, FreeType 2.14, x86-64).
{$IF (SizeOf(TPangoGlyphInfo) <> 20) or (SizeOf(TPangoGlyphString) <> 32) or (SizeOf(TPangoAnalysis) <> 48) or
  (SizeOf(TPangoItem) <> 64) or (SizeOf(TPangoGlyphItem) <> 32) or (SizeOf(TPangoLayoutLine) <> 32)}
  {$MESSAGE FATAL 'Pango struct layout'}
{$ENDIF}
{$IF (SizeOf(TFTBitmap) <> 40) or (SizeOf(TFTBitmapSize) <> 32) or (SizeOf(TFTOutline) <> 40) or
  (SizeOf(TFTGlyphSlotRec) <> 240) or (SizeOf(TFTFaceRec) <> 176) or (SizeOf(TFTOutlineFuncs) <> 48)}
  {$MESSAGE FATAL 'FreeType struct layout'}
{$ENDIF}

var
  // GLib, GObject.
  g_object_ref: function(AObject: Pointer): Pointer; cdecl;
  g_object_unref: procedure(AObject: Pointer); cdecl;
  g_free: procedure(AMem: Pointer); cdecl;
  // Pango.
  pango_version: function: Integer; cdecl;
  pango_version_string: function: PAnsiChar; cdecl;
  pango_ft2_font_map_new: function: Pointer; cdecl;
  pango_ft2_font_map_set_resolution: procedure(AFontMap: Pointer; ADpiX, ADpiY: Double); cdecl;
  pango_fc_font_get_pattern: function(AFont: Pointer): Pointer; cdecl;
  pango_font_map_create_context: function(AFontMap: Pointer): Pointer; cdecl;
  pango_context_set_round_glyph_positions: procedure(AContext: Pointer; ARound: Integer); cdecl;
  pango_context_set_base_dir: procedure(AContext: Pointer; ADirection: Integer); cdecl;
  pango_layout_new: function(AContext: Pointer): Pointer; cdecl;
  pango_layout_set_text: procedure(ALayout: Pointer; AText: PAnsiChar; ALength: Integer); cdecl;
  pango_layout_set_font_description: procedure(ALayout, ADesc: Pointer); cdecl;
  pango_layout_set_attributes: procedure(ALayout, AAttrs: Pointer); cdecl;
  pango_layout_set_width: procedure(ALayout: Pointer; AWidth: Integer); cdecl;
  pango_layout_set_height: procedure(ALayout: Pointer; AHeight: Integer); cdecl;
  pango_layout_set_wrap: procedure(ALayout: Pointer; AWrap: Integer); cdecl;
  pango_layout_set_ellipsize: procedure(ALayout: Pointer; AEllipsize: Integer); cdecl;
  pango_layout_set_alignment: procedure(ALayout: Pointer; AAlignment: Integer); cdecl;
  pango_layout_set_auto_dir: procedure(ALayout: Pointer; AAutoDir: Integer); cdecl;
  pango_layout_get_extents: procedure(ALayout: Pointer; AInk, ALogical: PPangoRectangle); cdecl;
  pango_layout_is_ellipsized: function(ALayout: Pointer): Integer; cdecl;
  pango_layout_get_log_attrs_readonly: function(ALayout: Pointer; out ACount: Integer): PCardinal; cdecl;
  pango_layout_get_iter: function(ALayout: Pointer): Pointer; cdecl;
  pango_layout_iter_free: procedure(AIter: Pointer); cdecl;
  pango_layout_iter_next_run: function(AIter: Pointer): Integer; cdecl;
  pango_layout_iter_next_line: function(AIter: Pointer): Integer; cdecl;
  pango_layout_iter_get_run_readonly: function(AIter: Pointer): PPangoGlyphItem; cdecl;
  pango_layout_iter_get_line_readonly: function(AIter: Pointer): PPangoLayoutLine; cdecl;
  pango_layout_iter_get_run_extents: procedure(AIter: Pointer; AInk, ALogical: PPangoRectangle); cdecl;
  pango_layout_iter_get_baseline: function(AIter: Pointer): Integer; cdecl;
  pango_layout_iter_get_line_extents: procedure(AIter: Pointer; AInk, ALogical: PPangoRectangle); cdecl;
  pango_layout_iter_get_line_yrange: procedure(AIter: Pointer; out AY0, AY1: Integer); cdecl;
  pango_layout_xy_to_index: function(ALayout: Pointer; AX, AY: Integer; out AIndex, ATrailing: Integer): Integer;
    cdecl;
  pango_layout_index_to_pos: procedure(ALayout: Pointer; AIndex: Integer; APos: PPangoRectangle); cdecl;
  pango_layout_line_get_x_ranges: procedure(ALine: PPangoLayoutLine; AStart, AEnd: Integer; out ARanges: PInteger;
    out ACount: Integer); cdecl;
  pango_font_description_new: function: Pointer; cdecl;
  pango_font_description_free: procedure(ADesc: Pointer); cdecl;
  pango_font_description_set_family: procedure(ADesc: Pointer; AFamily: PAnsiChar); cdecl;
  pango_font_description_set_absolute_size: procedure(ADesc: Pointer; ASize: Double); cdecl;
  pango_font_description_set_weight: procedure(ADesc: Pointer; AWeight: Integer); cdecl;
  pango_font_description_set_style: procedure(ADesc: Pointer; AStyle: Integer); cdecl;
  pango_font_description_set_stretch: procedure(ADesc: Pointer; AStretch: Integer); cdecl;
  pango_attr_list_new: function: Pointer; cdecl;
  pango_attr_list_unref: procedure(AList: Pointer); cdecl;
  pango_attr_list_insert: procedure(AList, AAttr: Pointer); cdecl;
  pango_attr_family_new: function(AFamily: PAnsiChar): Pointer; cdecl;
  pango_attr_size_new_absolute: function(ASize: Integer): Pointer; cdecl;
  pango_attr_weight_new: function(AWeight: Integer): Pointer; cdecl;
  pango_attr_style_new: function(AStyle: Integer): Pointer; cdecl;
  pango_attr_stretch_new: function(AStretch: Integer): Pointer; cdecl;
  pango_attr_foreground_new: function(ARed, AGreen, ABlue: Word): Pointer; cdecl;
  pango_attr_foreground_alpha_new: function(AAlpha: Word): Pointer; cdecl;
  pango_attr_underline_new: function(AUnderline: Integer): Pointer; cdecl;
  pango_attr_strikethrough_new: function(AStrikethrough: Integer): Pointer; cdecl;
  pango_font_get_metrics: function(AFont, ALanguage: Pointer): Pointer; cdecl;
  pango_font_metrics_unref: procedure(AMetrics: Pointer); cdecl;
  pango_font_metrics_get_underline_position: function(AMetrics: Pointer): Integer; cdecl;
  pango_font_metrics_get_underline_thickness: function(AMetrics: Pointer): Integer; cdecl;
  pango_font_metrics_get_strikethrough_position: function(AMetrics: Pointer): Integer; cdecl;
  pango_font_metrics_get_strikethrough_thickness: function(AMetrics: Pointer): Integer; cdecl;
  pango_font_get_hb_font: function(AFont: Pointer): Pointer; cdecl;
  // HarfBuzz.
  hb_font_get_scale: procedure(AFont: Pointer; out AXScale, AYScale: Integer); cdecl;
  hb_font_get_glyph_h_advance: function(AFont: Pointer; AGlyph: Cardinal): Integer; cdecl;
  hb_font_get_var_coords_normalized: function(AFont: Pointer; out ALength: Cardinal): PInteger; cdecl;
  // fontconfig.
  FcPatternGetString: function(APattern: Pointer; AObject: PAnsiChar; AN: Integer; out AValue: PAnsiChar): Integer;
    cdecl;
  FcPatternGetInteger: function(APattern: Pointer; AObject: PAnsiChar; AN: Integer; out AValue: Integer): Integer;
    cdecl;
  FcPatternGetBool: function(APattern: Pointer; AObject: PAnsiChar; AN: Integer; out AValue: Integer): Integer; cdecl;
  FcPatternGetMatrix: function(APattern: Pointer; AObject: PAnsiChar; AN: Integer; out AValue: PFcMatrix): Integer;
    cdecl;
  // FreeType.
  FT_Init_FreeType: function(out ALibrary: Pointer): Integer; cdecl;
  FT_Library_Version: procedure(ALibrary: Pointer; out AMajor, AMinor, APatch: Integer); cdecl;
  FT_New_Face: function(ALibrary: Pointer; APath: PAnsiChar; AIndex: NativeInt; out AFace: PFTFaceRec): Integer; cdecl;
  FT_Done_Face: function(AFace: PFTFaceRec): Integer; cdecl;
  FT_Set_Char_Size: function(AFace: PFTFaceRec; AWidth, AHeight: NativeInt; AHorzDpi, AVertDpi: Cardinal): Integer;
    cdecl;
  FT_Select_Size: function(AFace: PFTFaceRec; AStrike: Integer): Integer; cdecl;
  FT_Set_Transform: procedure(AFace: PFTFaceRec; AMatrix: PFTMatrix; ADelta: PFTVector); cdecl;
  FT_Load_Glyph: function(AFace: PFTFaceRec; AGlyph: Cardinal; AFlags: Integer): Integer; cdecl;
  FT_Render_Glyph: function(ASlot: PFTGlyphSlotRec; AMode: Integer): Integer; cdecl;
  FT_GlyphSlot_Embolden: procedure(ASlot: PFTGlyphSlotRec); cdecl;
  FT_Set_Var_Blend_Coordinates: function(AFace: PFTFaceRec; ACount: Cardinal; ACoords: PNativeInt): Integer; cdecl;
  FT_Outline_Decompose: function(AOutline: PFTOutline; AFuncs: PFTOutlineFuncs; AUser: Pointer): Integer; cdecl;

type
  /// <summary>A font file (with its face index, synthetic bold and slant) as the font face of runs: one object per
  /// face, so that the glyph cache knows it again. Its FreeType face is used under GFtLock.</summary>
  TPangoFace = class(TInterfacedObject)
  private
    FFile: UTF8String;
    FIndex: Integer;
    FEmbolden: Boolean;
    FHasMatrix: Boolean;
    FMatrix: TFTMatrix;
    /// <summary>Variable fonts: the position on the axes HarfBuzz shapes with (normalized, 16.16).</summary>
    FCoords: TArray<NativeInt>;
    FFace: PFTFaceRec;
    FOpened: Boolean;
    FScalable: Boolean;
    /// <summary>A color font (emoji): its layouts are drawn on the CPU (RenderColor).</summary>
    FColor: Boolean;
    /// <summary>Fonts of bitmaps only: the strike used (the largest) and its pixels per em.</summary>
    FStrike: Integer;
    FStrikePpem: Single;
    /// <summary>The pixels per em set on the face (0: none; -1: the strike).</summary>
    FSize: Single;
    function Open: Boolean;
    /// <summary>The glyph into the face's slot at AEmSize pixels per em, moved ASubX pixels to the right (emboldened
    /// as fontconfig says). False when it cannot be loaded.</summary>
    function Load(const AGlyph: Cardinal; const AEmSize, ASubX: Single; const AFlags: Integer): Boolean;
    function Slot: PFTGlyphSlotRec; inline;
  public
    destructor Destroy; override;
  end;

  /// <summary>What a PangoFont of the font map stands for: its face and its pixels per em.</summary>
  TPangoFontInfo = record
    Face: IInterface;
    EmSize: Single;
  end;

var
  /// <summary>Guards every Pango call and the tables of fonts and faces.</summary>
  GPangoLock: TObject;
  /// <summary>Guards the FreeType library and faces.</summary>
  GFtLock: TObject;
  /// <summary>0: the libraries not loaded yet; 1: loaded; -1: not there (GLoadError says why).</summary>
  GLoaded: Integer;
  GLoadError: string;
  GFontMap, GContextLtr, GContextRtl: Pointer;
  GPangoVersion: Integer;
  GFt: Pointer;
  /// <summary>PangoFonts (referenced) and what they stand for.</summary>
  GFonts: TDictionary<Pointer, TPangoFontInfo>;
  /// <summary>The faces by file, index and synthesis.</summary>
  GFaces: TDictionary<string, IInterface>;

/// <summary>Loads the libraries and makes the font map and contexts (under GPangoLock). False when something is
/// missing (GLoadError).</summary>
function LoadPango: Boolean;
var
  Missing: string;

  function Lib(const AName: string): NativeUInt;
  begin
    Result := dlopen(MarshaledAString(UTF8String(AName)), RTLD_NOW);
    if Result = 0 then
      Missing := Missing + ' ' + AName;
  end;

  function Sym(const ALib: NativeUInt; const AName: string; const AOptional: Boolean = False): Pointer;
  begin
    Result := nil;
    if ALib <> 0 then
      Result := dlsym(ALib, MarshaledAString(UTF8String(AName)));
    if (Result = nil) and not AOptional then
      Missing := Missing + ' ' + AName;
  end;

var
  GObject, GLib, Pango, PangoFt2, HarfBuzz, Fc, Ft: NativeUInt;
begin
  if GLoaded <> 0 then
    Exit(GLoaded > 0);
  GLoaded := -1;
  Missing := '';
  GLib := Lib('libglib-2.0.so.0');
  GObject := Lib('libgobject-2.0.so.0');
  Pango := Lib('libpango-1.0.so.0');
  PangoFt2 := Lib('libpangoft2-1.0.so.0');
  HarfBuzz := Lib('libharfbuzz.so.0');
  Fc := Lib('libfontconfig.so.1');
  Ft := Lib('libfreetype.so.6');
  @g_object_ref := Sym(GObject, 'g_object_ref');
  @g_object_unref := Sym(GObject, 'g_object_unref');
  @g_free := Sym(GLib, 'g_free');
  @pango_version := Sym(Pango, 'pango_version');
  @pango_version_string := Sym(Pango, 'pango_version_string');
  @pango_ft2_font_map_new := Sym(PangoFt2, 'pango_ft2_font_map_new');
  @pango_ft2_font_map_set_resolution := Sym(PangoFt2, 'pango_ft2_font_map_set_resolution');
  // Pango 1.48 and later; before, the pattern is the field after the GObject (PangoFcFont.font_pattern).
  @pango_fc_font_get_pattern := Sym(PangoFt2, 'pango_fc_font_get_pattern', True);
  @pango_font_map_create_context := Sym(Pango, 'pango_font_map_create_context');
  @pango_context_set_round_glyph_positions := Sym(Pango, 'pango_context_set_round_glyph_positions');
  @pango_context_set_base_dir := Sym(Pango, 'pango_context_set_base_dir');
  @pango_layout_new := Sym(Pango, 'pango_layout_new');
  @pango_layout_set_text := Sym(Pango, 'pango_layout_set_text');
  @pango_layout_set_font_description := Sym(Pango, 'pango_layout_set_font_description');
  @pango_layout_set_attributes := Sym(Pango, 'pango_layout_set_attributes');
  @pango_layout_set_width := Sym(Pango, 'pango_layout_set_width');
  @pango_layout_set_height := Sym(Pango, 'pango_layout_set_height');
  @pango_layout_set_wrap := Sym(Pango, 'pango_layout_set_wrap');
  @pango_layout_set_ellipsize := Sym(Pango, 'pango_layout_set_ellipsize');
  @pango_layout_set_alignment := Sym(Pango, 'pango_layout_set_alignment');
  @pango_layout_set_auto_dir := Sym(Pango, 'pango_layout_set_auto_dir');
  @pango_layout_get_extents := Sym(Pango, 'pango_layout_get_extents');
  @pango_layout_is_ellipsized := Sym(Pango, 'pango_layout_is_ellipsized');
  @pango_layout_get_log_attrs_readonly := Sym(Pango, 'pango_layout_get_log_attrs_readonly');
  @pango_layout_get_iter := Sym(Pango, 'pango_layout_get_iter');
  @pango_layout_iter_free := Sym(Pango, 'pango_layout_iter_free');
  @pango_layout_iter_next_run := Sym(Pango, 'pango_layout_iter_next_run');
  @pango_layout_iter_next_line := Sym(Pango, 'pango_layout_iter_next_line');
  @pango_layout_iter_get_run_readonly := Sym(Pango, 'pango_layout_iter_get_run_readonly');
  @pango_layout_iter_get_line_readonly := Sym(Pango, 'pango_layout_iter_get_line_readonly');
  @pango_layout_iter_get_run_extents := Sym(Pango, 'pango_layout_iter_get_run_extents');
  @pango_layout_iter_get_baseline := Sym(Pango, 'pango_layout_iter_get_baseline');
  @pango_layout_iter_get_line_extents := Sym(Pango, 'pango_layout_iter_get_line_extents');
  @pango_layout_iter_get_line_yrange := Sym(Pango, 'pango_layout_iter_get_line_yrange');
  @pango_layout_xy_to_index := Sym(Pango, 'pango_layout_xy_to_index');
  @pango_layout_index_to_pos := Sym(Pango, 'pango_layout_index_to_pos');
  @pango_layout_line_get_x_ranges := Sym(Pango, 'pango_layout_line_get_x_ranges');
  @pango_font_description_new := Sym(Pango, 'pango_font_description_new');
  @pango_font_description_free := Sym(Pango, 'pango_font_description_free');
  @pango_font_description_set_family := Sym(Pango, 'pango_font_description_set_family');
  @pango_font_description_set_absolute_size := Sym(Pango, 'pango_font_description_set_absolute_size');
  @pango_font_description_set_weight := Sym(Pango, 'pango_font_description_set_weight');
  @pango_font_description_set_style := Sym(Pango, 'pango_font_description_set_style');
  @pango_font_description_set_stretch := Sym(Pango, 'pango_font_description_set_stretch');
  @pango_attr_list_new := Sym(Pango, 'pango_attr_list_new');
  @pango_attr_list_unref := Sym(Pango, 'pango_attr_list_unref');
  @pango_attr_list_insert := Sym(Pango, 'pango_attr_list_insert');
  @pango_attr_family_new := Sym(Pango, 'pango_attr_family_new');
  @pango_attr_size_new_absolute := Sym(Pango, 'pango_attr_size_new_absolute');
  @pango_attr_weight_new := Sym(Pango, 'pango_attr_weight_new');
  @pango_attr_style_new := Sym(Pango, 'pango_attr_style_new');
  @pango_attr_stretch_new := Sym(Pango, 'pango_attr_stretch_new');
  @pango_attr_foreground_new := Sym(Pango, 'pango_attr_foreground_new');
  @pango_attr_foreground_alpha_new := Sym(Pango, 'pango_attr_foreground_alpha_new');
  @pango_attr_underline_new := Sym(Pango, 'pango_attr_underline_new');
  @pango_attr_strikethrough_new := Sym(Pango, 'pango_attr_strikethrough_new');
  @pango_font_get_metrics := Sym(Pango, 'pango_font_get_metrics');
  @pango_font_metrics_unref := Sym(Pango, 'pango_font_metrics_unref');
  @pango_font_metrics_get_underline_position := Sym(Pango, 'pango_font_metrics_get_underline_position');
  @pango_font_metrics_get_underline_thickness := Sym(Pango, 'pango_font_metrics_get_underline_thickness');
  @pango_font_metrics_get_strikethrough_position := Sym(Pango, 'pango_font_metrics_get_strikethrough_position');
  @pango_font_metrics_get_strikethrough_thickness := Sym(Pango, 'pango_font_metrics_get_strikethrough_thickness');
  @pango_font_get_hb_font := Sym(Pango, 'pango_font_get_hb_font');
  @hb_font_get_scale := Sym(HarfBuzz, 'hb_font_get_scale');
  @hb_font_get_glyph_h_advance := Sym(HarfBuzz, 'hb_font_get_glyph_h_advance');
  @hb_font_get_var_coords_normalized := Sym(HarfBuzz, 'hb_font_get_var_coords_normalized');
  @FcPatternGetString := Sym(Fc, 'FcPatternGetString');
  @FcPatternGetInteger := Sym(Fc, 'FcPatternGetInteger');
  @FcPatternGetBool := Sym(Fc, 'FcPatternGetBool');
  @FcPatternGetMatrix := Sym(Fc, 'FcPatternGetMatrix');
  @FT_Init_FreeType := Sym(Ft, 'FT_Init_FreeType');
  @FT_Library_Version := Sym(Ft, 'FT_Library_Version');
  @FT_New_Face := Sym(Ft, 'FT_New_Face');
  @FT_Done_Face := Sym(Ft, 'FT_Done_Face');
  @FT_Set_Char_Size := Sym(Ft, 'FT_Set_Char_Size');
  @FT_Select_Size := Sym(Ft, 'FT_Select_Size');
  @FT_Set_Transform := Sym(Ft, 'FT_Set_Transform');
  @FT_Load_Glyph := Sym(Ft, 'FT_Load_Glyph');
  @FT_Render_Glyph := Sym(Ft, 'FT_Render_Glyph');
  @FT_GlyphSlot_Embolden := Sym(Ft, 'FT_GlyphSlot_Embolden');
  @FT_Set_Var_Blend_Coordinates := Sym(Ft, 'FT_Set_Var_Blend_Coordinates');
  @FT_Outline_Decompose := Sym(Ft, 'FT_Outline_Decompose');
  if Missing <> '' then
  begin
    GLoadError := 'missing (Pango 1.44 or later needed):' + Missing;
    Exit(False);
  end;
  if FT_Init_FreeType(GFt) <> 0 then
  begin
    GLoadError := 'FT_Init_FreeType failed';
    Exit(False);
  end;
  GPangoVersion := pango_version;
  GFontMap := pango_ft2_font_map_new;
  pango_ft2_font_map_set_resolution(GFontMap, 96, 96);
  // One context per base direction: FMX's RightToLeft sets the paragraphs' direction (not guessed from the text);
  // positions in fractions of a pixel (the canvas places glyphs at quarter pixels).
  GContextLtr := pango_font_map_create_context(GFontMap);
  GContextRtl := pango_font_map_create_context(GFontMap);
  pango_context_set_base_dir(GContextLtr, PANGO_DIRECTION_LTR);
  pango_context_set_base_dir(GContextRtl, PANGO_DIRECTION_RTL);
  pango_context_set_round_glyph_positions(GContextLtr, 0);
  pango_context_set_round_glyph_positions(GContextRtl, 0);
  GFonts := TDictionary<Pointer, TPangoFontInfo>.Create;
  GFaces := TDictionary<string, IInterface>.Create;
  GLoaded := 1;
  Result := True;
end;

/// <summary>LoadPango under the lock, raising when the libraries are not there.</summary>
procedure EnsurePango;
var
  Ok: Boolean;
begin
  TMonitor.Enter(GPangoLock);
  try
    Ok := LoadPango;
  finally
    TMonitor.Exit(GPangoLock);
  end;
  if not Ok then
    raise Exception.Create('FastCanvas: the Pango text engine cannot run: ' + GLoadError);
end;

function FastPangoVersion: string;
var
  Major, Minor, Patch: Integer;
begin
  TMonitor.Enter(GPangoLock);
  try
    if not LoadPango then
      Exit(GLoadError);
    FT_Library_Version(GFt, Major, Minor, Patch);
    Result := Format('Pango %s, FreeType %d.%d.%d', [string(UTF8String(pango_version_string)), Major, Minor, Patch]);
  finally
    TMonitor.Exit(GPangoLock);
  end;
end;

{ TPangoFace }

destructor TPangoFace.Destroy;
begin
  if FFace <> nil then
  begin
    // The lock is gone after the engine's shutdown, and with it any other user of the face.
    if GFtLock <> nil then
      TMonitor.Enter(GFtLock);
    try
      FT_Done_Face(FFace);
    finally
      if GFtLock <> nil then
        TMonitor.Exit(GFtLock);
    end;
  end;
  inherited;
end;

function TPangoFace.Slot: PFTGlyphSlotRec;
begin
  Result := FFace.Glyph;
end;

function TPangoFace.Open: Boolean;
var
  I: Integer;
  Best: NativeInt;
  Sizes: PFTBitmapSize;
begin
  if not FOpened then
  begin
    FOpened := True;
    if FT_New_Face(GFt, PAnsiChar(FFile), FIndex, FFace) <> 0 then
      FFace := nil
    else
    begin
      if FCoords <> nil then
        FT_Set_Var_Blend_Coordinates(FFace, Length(FCoords), @FCoords[0]);
      FScalable := FFace.FaceFlags and FT_FACE_FLAG_SCALABLE <> 0;
      if FFace.FaceFlags and FT_FACE_FLAG_COLOR <> 0 then
        FColor := True;
      // Bitmap fonts (Noto Color Emoji: one strike of 109 pixels per em): the largest strike, scaled when drawn.
      Best := -1;
      Sizes := FFace.AvailableSizes;
      for I := 0 to FFace.NumFixedSizes - 1 do
        if Sizes[I].YPpem > Best then
        begin
          Best := Sizes[I].YPpem;
          FStrike := I;
          FStrikePpem := Sizes[I].YPpem / 64;
        end;
    end;
  end;
  Result := FFace <> nil;
end;

function TPangoFace.Load(const AGlyph: Cardinal; const AEmSize, ASubX: Single; const AFlags: Integer): Boolean;
var
  Delta: TFTVector;
begin
  Result := False;
  if not Open then
    Exit;
  if FScalable then
  begin
    if FSize <> AEmSize then
    begin
      FSize := 0;
      if (AEmSize <= 0) or (FT_Set_Char_Size(FFace, 0, Max(Round(AEmSize * 64), 1), 72, 72) <> 0) then
        Exit;
      FSize := AEmSize;
    end;
  end
  else if FSize <> -1 then
  begin
    if (FFace.NumFixedSizes = 0) or (FT_Select_Size(FFace, FStrike) <> 0) then
      Exit;
    FSize := -1;
  end;
  // The subpixel position as a translation of the outline (26.6), after fontconfig's matrix (synthetic slant).
  Delta.X := Round(ASubX * 64);
  Delta.Y := 0;
  if FHasMatrix then
    FT_Set_Transform(FFace, @FMatrix, @Delta)
  else
    FT_Set_Transform(FFace, nil, @Delta);
  if FT_Load_Glyph(FFace, AGlyph, AFlags) <> 0 then
    Exit;
  if FEmbolden and (Slot.Format = FT_GLYPH_FORMAT_OUTLINE) then
    FT_GlyphSlot_Embolden(Slot);
  Result := True;
end;

/// <summary>The face object of a TFastGlyphRun.FontFace; nil for another engine's.</summary>
function FaceObject(const AFace: IInterface): TPangoFace;
var
  O: TObject;
begin
  Result := nil;
  if AFace = nil then
    Exit;
  O := AFace as TObject;
  if O is TPangoFace then
    Result := TPangoFace(O);
end;

/// <summary>The face and pixels per em of a PangoFont (under GPangoLock).</summary>
function FontInfo(const AFont: Pointer): TPangoFontInfo;
var
  Pattern: Pointer;
  FileName: PAnsiChar;
  Index, Embolden, Color: Integer;
  M: PFcMatrix;
  HasMatrix: Boolean;
  Key: string;
  Face: TPangoFace;
  Hb, Font: Pointer;
  Sx, Sy, I: Integer;
  Coords: PInteger;
  CoordCount: Cardinal;
begin
  if (AFont = nil) or GFonts.TryGetValue(AFont, Result) then
  begin
    if AFont = nil then
      Result := Default(TPangoFontInfo);
    Exit;
  end;
  Result := Default(TPangoFontInfo);
  // The fonts are kept (referenced) by the table; a program that goes through many sizes starts it over now and
  // then (the runs hold their faces).
  if GFonts.Count >= MaxFonts then
  begin
    for Font in GFonts.Keys do
      g_object_unref(Font);
    GFonts.Clear;
  end;
  if Assigned(pango_fc_font_get_pattern) then
    Pattern := pango_fc_font_get_pattern(AFont)
  else
    Pattern := PPointer(PByte(AFont) + 3 * SizeOf(Pointer))^;
  // The size HarfBuzz shapes with (bitmap fonts: the requested size, not the strike's), and the position on the axes
  // of a variable font (normalized, 2.14).
  Hb := pango_font_get_hb_font(AFont);
  Sx := 0;
  Sy := 0;
  Coords := nil;
  CoordCount := 0;
  if Hb <> nil then
  begin
    hb_font_get_scale(Hb, Sx, Sy);
    Coords := hb_font_get_var_coords_normalized(Hb, CoordCount);
  end;
  Result.EmSize := Abs(Sy) / PANGO_SCALE;
  FileName := nil;
  Index := 0;
  Embolden := 0;
  Color := 0;
  M := nil;
  if (Pattern <> nil) and (FcPatternGetString(Pattern, 'file', 0, FileName) = FcResultMatch) then
  begin
    FcPatternGetInteger(Pattern, 'index', 0, Index);
    FcPatternGetBool(Pattern, 'embolden', 0, Embolden);
    FcPatternGetBool(Pattern, 'color', 0, Color);
    HasMatrix := (FcPatternGetMatrix(Pattern, 'matrix', 0, M) = FcResultMatch) and (M <> nil) and
      ((M.XX <> 1) or (M.XY <> 0) or (M.YX <> 0) or (M.YY <> 1));
    Key := Format('%s|%d|%d', [string(UTF8String(FileName)), Index, Embolden]);
    if HasMatrix then
      Key := Key + Format('|%g,%g,%g,%g', [M.XX, M.XY, M.YX, M.YY], TFormatSettings.Invariant);
    if Coords = nil then
      CoordCount := 0;
    for I := 0 to Integer(CoordCount) - 1 do
      Key := Key + Format('|%d', [Coords[I]]);
    if not GFaces.TryGetValue(Key, Result.Face) then
    begin
      Face := TPangoFace.Create;
      Result.Face := Face;
      Face.FFile := UTF8String(FileName);
      Face.FIndex := Index;
      Face.FEmbolden := Embolden <> 0;
      Face.FColor := Color <> 0;
      Face.FHasMatrix := HasMatrix;
      if HasMatrix then
      begin
        Face.FMatrix.XX := Round(M.XX * 65536);
        Face.FMatrix.XY := Round(M.XY * 65536);
        Face.FMatrix.YX := Round(M.YX * 65536);
        Face.FMatrix.YY := Round(M.YY * 65536);
      end;
      // FreeType's blend coordinates are 16.16.
      SetLength(Face.FCoords, CoordCount);
      for I := 0 to Integer(CoordCount) - 1 do
        Face.FCoords[I] := NativeInt(Coords[I]) * 4;
      // Opened here: the face tells color fonts that fontconfig does not mark.
      TMonitor.Enter(GFtLock);
      try
        Face.Open;
      finally
        TMonitor.Exit(GFtLock);
      end;
      GFaces.Add(Key, Result.Face);
    end;
  end;
  g_object_ref(AFont);
  GFonts.Add(AFont, Result);
end;

/// <summary>AText in UTF-8 (lone surrogates as U+FFFD, nul characters as spaces: the byte offsets stay Pango's),
/// nul-terminated, with the UTF-16 index of every byte and the byte offset of every UTF-16 index.</summary>
procedure ToUtf8(const AText: string; out ABytes: TBytes; out AByteToChar, ACharToByte: TArray<Integer>);
var
  P: PChar;
  Len, I, N, B, K, Start: Integer;
  C: Cardinal;
begin
  Len := Length(AText);
  P := PChar(AText);
  SetLength(ABytes, Len * 3 + 1);
  SetLength(AByteToChar, Len * 3 + 1);
  SetLength(ACharToByte, Len + 1);
  B := 0;
  I := 0;
  while I < Len do
  begin
    C := Ord(P[I]);
    N := 1;
    if (C >= $D800) and (C <= $DBFF) and (I + 1 < Len) and (Ord(P[I + 1]) >= $DC00) and (Ord(P[I + 1]) <= $DFFF) then
    begin
      C := $10000 + ((C - $D800) shl 10) + (Cardinal(Ord(P[I + 1])) - $DC00);
      N := 2;
    end
    else if (C >= $D800) and (C <= $DFFF) then
      C := $FFFD
    else if C = 0 then
      C := $20;
    Start := B;
    ACharToByte[I] := B;
    if N = 2 then
      ACharToByte[I + 1] := B;
    if C < $80 then
    begin
      ABytes[B] := C;
      Inc(B);
    end
    else if C < $800 then
    begin
      ABytes[B] := $C0 or (C shr 6);
      ABytes[B + 1] := $80 or (C and $3F);
      Inc(B, 2);
    end
    else if C < $10000 then
    begin
      ABytes[B] := $E0 or (C shr 12);
      ABytes[B + 1] := $80 or ((C shr 6) and $3F);
      ABytes[B + 2] := $80 or (C and $3F);
      Inc(B, 3);
    end
    else
    begin
      ABytes[B] := $F0 or (C shr 18);
      ABytes[B + 1] := $80 or ((C shr 12) and $3F);
      ABytes[B + 2] := $80 or ((C shr 6) and $3F);
      ABytes[B + 3] := $80 or (C and $3F);
      Inc(B, 4);
    end;
    for K := Start to B - 1 do
      AByteToChar[K] := I;
    Inc(I, N);
  end;
  ACharToByte[Len] := B;
  AByteToChar[B] := Len;
  ABytes[B] := 0;
  SetLength(ABytes, B + 1);
  SetLength(AByteToChar, B + 1);
end;

function StyleOf(const AFont: TFont): TFastPangoStyle;
begin
  Result := Default(TFastPangoStyle);
  Result.Family := AFont.Family;
  Result.Size := AFont.Size;
  Result.Weight := AFont.StyleExt.Weight;
  Result.Slant := AFont.StyleExt.Slant;
  Result.Stretch := AFont.StyleExt.Stretch;
  Result.Underline := TFontStyle.fsUnderline in AFont.StyleExt.SimpleStyle;
  Result.StrikeOut := TFontStyle.fsStrikeOut in AFont.StyleExt.SimpleStyle;
end;

function SameStyle(const A, B: TFastPangoStyle): Boolean;
begin
  Result := (A.Family = B.Family) and (A.Size = B.Size) and (A.Weight = B.Weight) and (A.Slant = B.Slant) and
    (A.Stretch = B.Stretch) and (A.Underline = B.Underline) and (A.StrikeOut = B.StrikeOut) and
    (A.HasColor = B.HasColor) and (A.Color = B.Color);
end;

function PangoStyle(const ASlant: TFontSlant): Integer;
begin
  case ASlant of
    TFontSlant.Italic: Result := PANGO_STYLE_ITALIC;
    TFontSlant.Oblique: Result := PANGO_STYLE_OBLIQUE;
  else
    Result := PANGO_STYLE_NORMAL;
  end;
end;

/// <summary>An attribute over the bytes AStart to AEnd into AList.</summary>
procedure InsertAttr(const AList, AAttr: Pointer; const AStart, AEnd: Integer);
begin
  if AAttr = nil then
    Exit;
  // PangoAttribute: the class, then start_index and end_index (guint).
  PCardinal(PByte(AAttr) + SizeOf(Pointer))^ := AStart;
  PCardinal(PByte(AAttr) + SizeOf(Pointer) + 4)^ := AEnd;
  pango_attr_list_insert(AList, AAttr);
end;

function IsHighSurrogate(const C: Char): Boolean; inline;
begin
  Result := (Ord(C) >= $D800) and (Ord(C) <= $DBFF);
end;

function IsLowSurrogate(const C: Char): Boolean; inline;
begin
  Result := (Ord(C) >= $DC00) and (Ord(C) <= $DFFF);
end;

{ TFastPangoLayoutData }

destructor TFastPangoLayoutData.Destroy;
begin
  if FLayout <> nil then
  begin
    // The lock is gone after the engine's shutdown, and with it any other user of Pango.
    if GPangoLock <> nil then
      TMonitor.Enter(GPangoLock);
    try
      g_object_unref(FLayout);
    finally
      if GPangoLock <> nil then
        TMonitor.Exit(GPangoLock);
    end;
  end;
  inherited;
end;

procedure TFastPangoLayoutData.SetText(const AText: string; const ACharStyles: TArray<Integer>);
begin
  FText := AText;
  FCharStyles := ACharStyles;
  ToUtf8(FText, FUtf8, FByteToChar, FCharToByte);
end;

function TFastPangoLayoutData.TextIndex(const AIndex: Integer): Integer;
begin
  if FMap = nil then
    Result := AIndex
  else
    Result := FMap[EnsureRange(AIndex, 0, High(FMap))];
end;

function TFastPangoLayoutData.ShownIndex(const AIndex: Integer): Integer;
var
  I: Integer;
begin
  if FMap = nil then
    Exit(EnsureRange(AIndex, 0, Length(FText)));
  // The last index of FText at or before it (a range left out maps to its ellipsis).
  Result := 0;
  for I := 0 to High(FMap) do
    if FMap[I] <= AIndex then
      Result := I
    else
      Break;
end;

/// <summary>A PangoLayout of the text with the layout's parameters (under the Pango lock).</summary>
function TFastPangoLayoutData.MakeLayout: Pointer;
var
  Desc, Attrs: Pointer;
  Base, S: TFastPangoStyle;
  Start, I, B0, B1: Integer;
  Family: UTF8String;
  C: TAlphaColorRec;
begin
  if FRtl then
    Result := pango_layout_new(GContextRtl)
  else
    Result := pango_layout_new(GContextLtr);
  pango_layout_set_auto_dir(Result, 0);
  Base := FStyles[0];
  Desc := pango_font_description_new;
  Family := UTF8String(Base.Family);
  pango_font_description_set_family(Desc, PAnsiChar(Family));
  pango_font_description_set_absolute_size(Desc, Max(Base.Size, MinFontSize) * PANGO_SCALE);
  pango_font_description_set_weight(Desc, FontWeights[Base.Weight]);
  pango_font_description_set_style(Desc, PangoStyle(Base.Slant));
  pango_font_description_set_stretch(Desc, Ord(Base.Stretch));
  pango_layout_set_font_description(Result, Desc);
  pango_font_description_free(Desc);
  pango_layout_set_text(Result, PAnsiChar(@FUtf8[0]), Length(FUtf8) - 1);
  // The styles of the ranges as attributes: fonts, decorations, colors (the canvas draws the runs in their colors;
  // the attribute makes Pango end a run where the color changes).
  Attrs := nil;
  Start := 0;
  while Start < Length(FText) do
  begin
    I := Start + 1;
    while (I < Length(FText)) and (FCharStyles[I] = FCharStyles[Start]) do
      Inc(I);
    S := FStyles[FCharStyles[Start]];
    if (FCharStyles[Start] <> 0) or S.Underline or S.StrikeOut or S.HasColor then
    begin
      if Attrs = nil then
        Attrs := pango_attr_list_new;
      B0 := FCharToByte[Start];
      B1 := FCharToByte[I];
      if S.Family <> Base.Family then
      begin
        Family := UTF8String(S.Family);
        InsertAttr(Attrs, pango_attr_family_new(PAnsiChar(Family)), B0, B1);
      end;
      if S.Size <> Base.Size then
        InsertAttr(Attrs, pango_attr_size_new_absolute(Round(Max(S.Size, MinFontSize) * PANGO_SCALE)), B0, B1);
      if S.Weight <> Base.Weight then
        InsertAttr(Attrs, pango_attr_weight_new(FontWeights[S.Weight]), B0, B1);
      if S.Slant <> Base.Slant then
        InsertAttr(Attrs, pango_attr_style_new(PangoStyle(S.Slant)), B0, B1);
      if S.Stretch <> Base.Stretch then
        InsertAttr(Attrs, pango_attr_stretch_new(Ord(S.Stretch)), B0, B1);
      if S.Underline then
        InsertAttr(Attrs, pango_attr_underline_new(PANGO_UNDERLINE_SINGLE), B0, B1);
      if S.StrikeOut then
        InsertAttr(Attrs, pango_attr_strikethrough_new(1), B0, B1);
      if S.HasColor then
      begin
        C.Color := S.Color;
        InsertAttr(Attrs, pango_attr_foreground_new(C.R * 257, C.G * 257, C.B * 257), B0, B1);
        InsertAttr(Attrs, pango_attr_foreground_alpha_new(C.A * 257), B0, B1);
      end;
    end;
    Start := I;
  end;
  if Attrs <> nil then
  begin
    pango_layout_set_attributes(Result, Attrs);
    pango_attr_list_unref(Attrs);
  end;
  pango_layout_set_alignment(Result, FAlign);
  pango_layout_set_width(Result, FWidth);
  if FWidth >= 0 then
    pango_layout_set_wrap(Result, PANGO_WRAP_WORD_CHAR);
  if FEllipsize then
  begin
    pango_layout_set_ellipsize(Result, PANGO_ELLIPSIZE_END);
    pango_layout_set_height(Result, FHeight);
  end;
end;

/// <summary>The PangoLayout, made again when the data does not keep it (under the Pango lock).</summary>
function TFastPangoLayoutData.Layout: Pointer;
begin
  if FLayout = nil then
    FLayout := MakeLayout;
  Result := FLayout;
end;

/// <summary>Word trimming, as DirectWrite trims: every line Pango ellipsized ends at the last word boundary before
/// Pango's cut instead (where the line has one before it), without the white space before it, followed by an
/// ellipsis; FText becomes that text (FMap maps it to the layout's). FLayout is the layout to look at; the caller
/// makes a new one when FMap is set. Under the Pango lock.</summary>
procedure TFastPangoLayoutData.TrimWords;
type
  TCut = record
    LineStart, CutStart, CutEnd: Integer;
  end;
var
  Cuts: TList<TCut>;
  Cut: TCut;
  Iter: Pointer;
  Run: PPangoGlyphItem;
  Line: PPangoLayoutLine;
  Attrs: PCardinal;
  Count, I, N, P, Prev: Integer;
  CodePoints: TArray<Integer>;
  Shown: TStringBuilder;
  Map, Styles: TList<Integer>;

  function Attr(const AIndex: Integer): Cardinal;
  begin
    if CodePoints[AIndex] < Count then
      Result := Attrs[CodePoints[AIndex]]
    else
      Result := 0;
  end;

  procedure Keep(const AFrom, ATo: Integer);
  var
    K: Integer;
  begin
    for K := AFrom to ATo - 1 do
    begin
      Shown.Append(FText.Chars[K]);
      Map.Add(K);
      Styles.Add(FCharStyles[K]);
    end;
  end;

begin
  if pango_layout_is_ellipsized(FLayout) = 0 then
    Exit;
  Cuts := TList<TCut>.Create;
  Shown := TStringBuilder.Create;
  Map := TList<Integer>.Create;
  Styles := TList<Integer>.Create;
  try
    // The ellipsis runs: their items stand for the text left out.
    Iter := pango_layout_get_iter(FLayout);
    repeat
      Run := pango_layout_iter_get_run_readonly(Iter);
      if (Run <> nil) and (Run.Item.Analysis.Flags and PANGO_ANALYSIS_FLAG_IS_ELLIPSIS <> 0) then
      begin
        Line := pango_layout_iter_get_line_readonly(Iter);
        Cut.LineStart := FByteToChar[EnsureRange(Line.StartIndex, 0, High(FByteToChar))];
        Cut.CutStart := FByteToChar[EnsureRange(Run.Item.Offset, 0, High(FByteToChar))];
        Cut.CutEnd := FByteToChar[EnsureRange(Run.Item.Offset + Run.Item.Length, 0, High(FByteToChar))];
        Cuts.Add(Cut);
      end;
    until pango_layout_iter_next_run(Iter) = 0;
    pango_layout_iter_free(Iter);
    if Cuts.Count = 0 then
      Exit;
    // The break opportunities (log attributes: one per character, that is code point, and one for the end).
    Attrs := pango_layout_get_log_attrs_readonly(FLayout, Count);
    SetLength(CodePoints, Length(FText) + 1);
    N := 0;
    for I := 0 to Length(FText) - 1 do
    begin
      CodePoints[I] := N;
      if not (IsHighSurrogate(FText.Chars[I]) and (I + 1 < Length(FText)) and IsLowSurrogate(FText.Chars[I + 1])) then
        Inc(N);
    end;
    CodePoints[Length(FText)] := N;
    Prev := 0;
    for Cut in Cuts do
    begin
      P := Cut.CutStart;
      while (P > Cut.LineStart) and ((Attr(P) and LogAttrLineBreak = 0) or IsLowSurrogate(FText.Chars[P])) do
        Dec(P);
      if P <= Cut.LineStart then
      begin
        // No word fits: the line's first character (grapheme) stays, as DirectWrite trims.
        P := Cut.LineStart + 1;
        while (P < Length(FText)) and ((Attr(P) and LogAttrCursorPosition = 0) or IsLowSurrogate(FText.Chars[P])) do
          Inc(P);
      end;
      while (P > Cut.LineStart) and (Attr(P - 1) and LogAttrWhite <> 0) do
        Dec(P);
      P := Max(P, Prev);
      Keep(Prev, P);
      Shown.Append(#$2026);
      Map.Add(P);
      if P > 0 then
        Styles.Add(FCharStyles[P - 1])
      else
        Styles.Add(FCharStyles[Min(Cut.CutStart, High(FCharStyles))]);
      Prev := Max(Cut.CutEnd, P);
    end;
    Keep(Prev, Length(FText));
    Map.Add(Length(FText));
    FMap := Map.ToArray;
    SetText(Shown.ToString, Styles.ToArray);
  finally
    Cuts.Free;
    Shown.Free;
    Map.Free;
    Styles.Free;
  end;
end;

/// <summary>The width Pango added to an ellipsis at the end of a line (it fills the line to the box's edge), in
/// Pango units; 0 without one.</summary>
function EllipsisExtra(const ALine: PPangoLayoutLine): Integer;
var
  Node: PGSList;
  Run: PPangoGlyphItem;
  G: PPangoGlyphInfo;
  Hb: Pointer;
begin
  Result := 0;
  if (ALine = nil) or (ALine.Runs = nil) then
    Exit;
  Node := ALine.Runs;
  while Node.Next <> nil do
    Node := Node.Next;
  Run := Node.Data;
  if (Run = nil) or (Run.Item.Analysis.Flags and PANGO_ANALYSIS_FLAG_IS_ELLIPSIS = 0) or
    (Run.Glyphs.NumGlyphs <= 0) then
    Exit;
  G := Run.Glyphs.Glyphs + Run.Glyphs.NumGlyphs - 1;
  if G.Glyph and PANGO_GLYPH_UNKNOWN_FLAG <> 0 then
    Exit;
  Hb := pango_font_get_hb_font(Run.Item.Analysis.Font);
  // The font's scale is Pango units per em: the advance comes in Pango units.
  if Hb <> nil then
    Result := Max(G.Width - hb_font_get_glyph_h_advance(Hb, G.Glyph), 0);
end;

procedure TFastPangoLayoutData.CollectRuns;
begin
  // Collected when the layout is made (Analyse).
end;

/// <summary>Runs, decorations and ink of FLayout, moved by Dx, Dy (under the Pango lock).</summary>
procedure TFastPangoLayoutData.Analyse;
var
  RunList: TList<TFastGlyphRun>;
  DecoList: TList<TFastTextDecoration>;
  Iter, Metrics: Pointer;
  Run: PPangoGlyphItem;
  G: PPangoGlyphInfo;
  R: TFastGlyphRun;
  D: TFastTextDecoration;
  Info: TPangoFontInfo;
  Style: TFastPangoStyle;
  Logical, LayoutInk, LayoutLogical: TPangoRectangle;
  Pen, I, N, Index, Left, Right: Integer;
  X0, X1, Pos, Thickness: Single;
  Ink: TRectF;
  HasInk: Boolean;
  Face: TPangoFace;
begin
  RunList := TList<TFastGlyphRun>.Create;
  DecoList := TList<TFastTextDecoration>.Create;
  try
    Iter := pango_layout_get_iter(FLayout);
    repeat
      Run := pango_layout_iter_get_run_readonly(Iter);
      if (Run = nil) or (Run.Glyphs.NumGlyphs <= 0) then
        Continue;
      Info := FontInfo(Run.Item.Analysis.Font);
      Face := FaceObject(Info.Face);
      if Face = nil then
        Continue;
      pango_layout_iter_get_run_extents(Iter, nil, @Logical);
      Index := FByteToChar[EnsureRange(Run.Item.Offset, 0, High(FByteToChar))];
      if Index < Length(FCharStyles) then
        Style := FStyles[FCharStyles[Index]]
      else
        Style := FStyles[0];
      R := Default(TFastGlyphRun);
      R.FontFace := Info.Face;
      R.EmSize := Info.EmSize;
      R.BidiLevel := Run.Item.Analysis.Level;
      // The run's start on the line's baseline; glyph strings are in visual order, left to right.
      R.OriginX := Dx + Logical.X / PANGO_SCALE;
      R.OriginY := Dy + pango_layout_iter_get_baseline(Iter) / PANGO_SCALE;
      if GPangoVersion >= 15000 then
        R.OriginY := R.OriginY - Run.YOffset / PANGO_SCALE;
      SetLength(R.Glyphs, Run.Glyphs.NumGlyphs);
      SetLength(R.X, Run.Glyphs.NumGlyphs);
      SetLength(R.Y, Run.Glyphs.NumGlyphs);
      N := 0;
      Pen := 0;
      G := Run.Glyphs.Glyphs;
      for I := 0 to Run.Glyphs.NumGlyphs - 1 do
      begin
        // Empty glyphs (spaces at line ends, controls) take their place only; unknown characters the font's
        // missing glyph (Pango draws their codes in a box).
        if G.Glyph <> PANGO_GLYPH_EMPTY then
        begin
          if G.Glyph and PANGO_GLYPH_UNKNOWN_FLAG <> 0 then
            R.Glyphs[N] := 0
          else
            R.Glyphs[N] := Word(G.Glyph);
          R.X[N] := (Pen + G.XOffset) / PANGO_SCALE;
          R.Y[N] := G.YOffset / PANGO_SCALE;
          Inc(N);
        end;
        Inc(Pen, G.Width);
        Inc(G);
      end;
      SetLength(R.Glyphs, N);
      SetLength(R.X, N);
      SetLength(R.Y, N);
      R.HasColor := Style.HasColor;
      R.Color := Style.Color;
      if N > 0 then
      begin
        RunList.Add(R);
        if Face.FColor then
          ColorGlyphs := True;
      end;
      if Style.Underline or Style.StrikeOut then
      begin
        // Pango's positions are the tops of the lines above the baseline.
        Metrics := pango_font_get_metrics(Run.Item.Analysis.Font, nil);
        X0 := R.OriginX;
        X1 := R.OriginX + Logical.Width / PANGO_SCALE;
        D.Color := Style.Color;
        D.HasColor := Style.HasColor;
        if Style.Underline then
        begin
          Pos := pango_font_metrics_get_underline_position(Metrics) / PANGO_SCALE;
          Thickness := pango_font_metrics_get_underline_thickness(Metrics) / PANGO_SCALE;
          if Thickness <= 0 then
            Thickness := Max(R.EmSize / 14, 1);
          D.Rect := TRectF.Create(X0, R.OriginY - Pos, X1, R.OriginY - Pos + Thickness);
          DecoList.Add(D);
        end;
        if Style.StrikeOut then
        begin
          Pos := pango_font_metrics_get_strikethrough_position(Metrics) / PANGO_SCALE;
          Thickness := pango_font_metrics_get_strikethrough_thickness(Metrics) / PANGO_SCALE;
          if Thickness <= 0 then
            Thickness := Max(R.EmSize / 14, 1);
          D.Rect := TRectF.Create(X0, R.OriginY - Pos, X1, R.OriginY - Pos + Thickness);
          DecoList.Add(D);
        end;
        pango_font_metrics_unref(Metrics);
      end;
    until pango_layout_iter_next_run(Iter) = 0;
    pango_layout_iter_free(Iter);
    Runs := RunList.ToArray;
    Decorations := DecoList.ToArray;
  finally
    RunList.Free;
    DecoList.Free;
  end;

  // The text: the lines' extent, an ellipsis at the end of a line as wide as its glyph (Pango widens it to the
  // box's edge), the layout's height.
  pango_layout_get_extents(FLayout, @LayoutInk, @LayoutLogical);
  Left := MaxInt;
  Right := -MaxInt;
  Iter := pango_layout_get_iter(FLayout);
  repeat
    pango_layout_iter_get_line_extents(Iter, nil, @Logical);
    if Logical.Width <= 0 then
      Continue;
    Left := Min(Left, Logical.X);
    Right := Max(Right, Logical.X + Logical.Width - EllipsisExtra(pango_layout_iter_get_line_readonly(Iter)));
  until pango_layout_iter_next_line(Iter) = 0;
  pango_layout_iter_free(Iter);
  if Left > Right then
  begin
    Left := LayoutLogical.X;
    Right := LayoutLogical.X;
  end;
  TextRect := TRectF.Create(Dx + Left / PANGO_SCALE, Dy + LayoutLogical.Y / PANGO_SCALE, Dx + Right / PANGO_SCALE,
    Dy + (LayoutLogical.Y + LayoutLogical.Height) / PANGO_SCALE);
  HasInk := (LayoutInk.Width > 0) and (LayoutInk.Height > 0);
  if HasInk then
    Ink := TRectF.Create(Dx + LayoutInk.X / PANGO_SCALE, Dy + LayoutInk.Y / PANGO_SCALE,
      Dx + (LayoutInk.X + LayoutInk.Width) / PANGO_SCALE, Dy + (LayoutInk.Y + LayoutInk.Height) / PANGO_SCALE)
  else
    Ink := TextRect;
  for I := 0 to High(Decorations) do
    Ink := TRectF.Union(Ink, Decorations[I].Rect);
  Overhang.Left := -Ink.Left;
  Overhang.Top := -Ink.Top;
  Overhang.Right := Ink.Right - LayoutWidth;
  Overhang.Bottom := Ink.Bottom - LayoutHeight;
  InkOutside := (Overhang.Left > 0.01) or (Overhang.Top > 0.01) or (Overhang.Right > 0.01) or
    (Overhang.Bottom > 0.01);
end;

{ Drawing on the CPU (layouts with color glyphs) }

/// <summary>A pixel of premultiplied BGRA under the premultiplied color B, G, R, A at coverage C (0..255).</summary>
procedure BlendPixel(const ADst: PByte; const C, B, G, R, A: Cardinal); inline;
var
  Ca, Inv: Cardinal;
begin
  Ca := (A * C + 127) div 255;
  Inv := 255 - Ca;
  ADst[0] := Min((B * C + ADst[0] * Inv + 127) div 255, 255);
  ADst[1] := Min((G * C + ADst[1] * Inv + 127) div 255, 255);
  ADst[2] := Min((R * C + ADst[2] * Inv + 127) div 255, 255);
  ADst[3] := Min(Ca + (ADst[3] * Inv + 127) div 255, 255);
end;

/// <summary>Coverage (AW x AH bytes, rows APitch apart) at (AX, AY) in AColor over premultiplied BGRA pixels (rows
/// AStride apart), inside AClip.</summary>
procedure BlendCoverage(const APixels: PByte; const AStride: Integer; const AClip: TRect; const AX, AY, AW,
  AH: Integer; const ASrc: PByte; const APitch: Integer; const AColor: TAlphaColor);
var
  X, Y, X0, X1, Y0, Y1: Integer;
  A, R, G, B: Cardinal;
  S, D: PByte;
begin
  A := AColor shr 24;
  R := ((AColor shr 16) and $FF) * A div 255;
  G := ((AColor shr 8) and $FF) * A div 255;
  B := (AColor and $FF) * A div 255;
  X0 := Max(AX, AClip.Left);
  X1 := Min(AX + AW, AClip.Right);
  Y0 := Max(AY, AClip.Top);
  Y1 := Min(AY + AH, AClip.Bottom);
  for Y := Y0 to Y1 - 1 do
  begin
    S := ASrc + (Y - AY) * APitch + (X0 - AX);
    D := APixels + Y * AStride + X0 * 4;
    for X := X0 to X1 - 1 do
    begin
      if S^ <> 0 then
        BlendPixel(D, S^, B, G, R, A);
      Inc(S);
      Inc(D, 4);
    end;
  end;
end;

/// <summary>A premultiplied BGRA image (AW x AH, rows APitch apart) scaled by AScale with its top left at (AX, AY)
/// over premultiplied BGRA pixels, inside AClip: every pixel takes the image's area it covers (a box filter).
/// </summary>
procedure BlendImage(const APixels: PByte; const AStride: Integer; const AClip: TRect; const AX, AY,
  AScale: Single; const ASrc: PByte; const AW, AH, APitch: Integer);
var
  Px, Py, Sx, Sy, PX0, PX1, PY0, PY1: Integer;
  Fx0, Fx1, Fy0, Fy1, Wy, W, Area, A, Inv: Single;
  Acc: array[0..3] of Single;
  S, D: PByte;
begin
  if AScale <= 0 then
    Exit;
  PX0 := Max(Floor(AX), AClip.Left);
  PX1 := Min(Ceil(AX + AW * AScale), AClip.Right);
  PY0 := Max(Floor(AY), AClip.Top);
  PY1 := Min(Ceil(AY + AH * AScale), AClip.Bottom);
  // A pixel covers 1 / AScale^2 pixels of the image.
  Area := AScale * AScale;
  for Py := PY0 to PY1 - 1 do
  begin
    Fy0 := Max((Py - AY) / AScale, 0);
    Fy1 := Min((Py + 1 - AY) / AScale, AH);
    if Fy1 <= Fy0 then
      Continue;
    for Px := PX0 to PX1 - 1 do
    begin
      Fx0 := Max((Px - AX) / AScale, 0);
      Fx1 := Min((Px + 1 - AX) / AScale, AW);
      if Fx1 <= Fx0 then
        Continue;
      Acc[0] := 0;
      Acc[1] := 0;
      Acc[2] := 0;
      Acc[3] := 0;
      for Sy := Floor(Fy0) to Min(Ceil(Fy1), AH) - 1 do
      begin
        Wy := Min(Sy + 1, Fy1) - Max(Sy, Fy0);
        S := ASrc + Sy * APitch + Floor(Fx0) * 4;
        for Sx := Floor(Fx0) to Min(Ceil(Fx1), AW) - 1 do
        begin
          W := Wy * (Min(Sx + 1, Fx1) - Max(Sx, Fx0));
          Acc[0] := Acc[0] + S[0] * W;
          Acc[1] := Acc[1] + S[1] * W;
          Acc[2] := Acc[2] + S[2] * W;
          Acc[3] := Acc[3] + S[3] * W;
          Inc(S, 4);
        end;
      end;
      A := Min(Acc[3] * Area, 255);
      if A <= 0 then
        Continue;
      Inv := 1 - A / 255;
      D := APixels + Py * AStride + Px * 4;
      D[0] := Min(Round(Acc[0] * Area + D[0] * Inv), 255);
      D[1] := Min(Round(Acc[1] * Area + D[1] * Inv), 255);
      D[2] := Min(Round(Acc[2] * Area + D[2] * Inv), 255);
      D[3] := Min(Round(A + D[3] * Inv), 255);
    end;
  end;
end;

/// <summary>A rectangle in AColor, its edges antialiased, over premultiplied BGRA pixels inside AClip.</summary>
procedure BlendRect(const APixels: PByte; const AStride: Integer; const AClip: TRect; const ARect: TRectF;
  const AColor: TAlphaColor);
var
  X, Y: Integer;
  Cy, Cx: Single;
  A, R, G, B: Cardinal;
begin
  A := AColor shr 24;
  R := ((AColor shr 16) and $FF) * A div 255;
  G := ((AColor shr 8) and $FF) * A div 255;
  B := (AColor and $FF) * A div 255;
  for Y := Max(Floor(ARect.Top), AClip.Top) to Min(Ceil(ARect.Bottom), AClip.Bottom) - 1 do
  begin
    Cy := Min(Y + 1, ARect.Bottom) - Max(Y, ARect.Top);
    if Cy <= 0 then
      Continue;
    for X := Max(Floor(ARect.Left), AClip.Left) to Min(Ceil(ARect.Right), AClip.Right) - 1 do
    begin
      Cx := Min(X + 1, ARect.Right) - Max(X, ARect.Left);
      if Cx > 0 then
        BlendPixel(APixels + Y * AStride + X * 4, Round(Min(Cx * Cy, 1) * 255), B, G, R, A);
    end;
  end;
end;

function TFastPangoLayoutData.RenderColor(const AScale, ADx, ADy: Single; const AColor: TAlphaColor; const AWidth,
  AHeight: Integer; out APixels: TBytes): Boolean;
var
  Clip: TRect;
  Run: TFastGlyphRun;
  Face: TPangoFace;
  Slot: PFTGlyphSlotRec;
  Deco: TFastTextDecoration;
  Color: TAlphaColor;
  Em, Gx, Gy, S: Single;
  I, Ix, Iy, Stride, Flags: Integer;
begin
  Result := False;
  APixels := nil;
  if (AWidth <= 0) or (AHeight <= 0) then
    Exit;
  Stride := AWidth * 4;
  SetLength(APixels, Stride * AHeight);
  FillChar(APixels[0], Length(APixels), 0);
  Clip := TRect.Create(0, 0, AWidth, AHeight);
  if InkOutside then
    Clip.Intersect(TRect.Create(Floor(ADx), Floor(ADy), Ceil(ADx + LayoutWidth * AScale),
      Ceil(ADy + LayoutHeight * AScale)));
  TMonitor.Enter(GFtLock);
  try
    for Run in Runs do
    begin
      Face := FaceObject(Run.FontFace);
      if Face = nil then
        Continue;
      if Run.HasColor then
        Color := Run.Color
      else
        Color := AColor or $FF000000;
      Em := Run.EmSize * AScale;
      for I := 0 to High(Run.Glyphs) do
      begin
        Gx := (Run.OriginX + Run.X[I]) * AScale + ADx;
        Gy := (Run.OriginY + Run.Y[I]) * AScale + ADy;
        if Face.FColor then
        begin
          // Color glyphs: bitmaps (CBDT, sbix) at the strike's size, scaled; COLR layers rendered by FreeType.
          if not Face.Load(Run.Glyphs[I], Em, 0, FT_LOAD_COLOR) then
            Continue;
          Slot := Face.Slot;
          if (Slot.Format = FT_GLYPH_FORMAT_OUTLINE) and (FT_Render_Glyph(Slot, FT_RENDER_MODE_NORMAL) <> 0) then
            Continue;
          if Slot.Bitmap.PixelMode = FT_PIXEL_MODE_BGRA then
          begin
            if Face.FScalable or (Face.FStrikePpem <= 0) then
              S := 1
            else
              S := Em / Face.FStrikePpem;
            BlendImage(@APixels[0], Stride, Clip, Gx + Slot.BitmapLeft * S, Gy - Slot.BitmapTop * S, S,
              Slot.Bitmap.Buffer, Slot.Bitmap.Width, Slot.Bitmap.Rows, Slot.Bitmap.Pitch);
            Continue;
          end;
          if Slot.Bitmap.PixelMode = FT_PIXEL_MODE_GRAY then
            BlendCoverage(@APixels[0], Stride, Clip, Round(Gx) + Slot.BitmapLeft, Round(Gy) - Slot.BitmapTop,
              Slot.Bitmap.Width, Slot.Bitmap.Rows, Slot.Bitmap.Buffer, Slot.Bitmap.Pitch, Color);
          Continue;
        end;
        // Coverage at the glyph's subpixel position, the baseline on a whole pixel (as the canvas draws).
        Ix := Floor(Gx);
        Iy := Round(Gy);
        if FastPangoLightHinting then
          Flags := FT_LOAD_TARGET_LIGHT or FT_LOAD_NO_BITMAP
        else
          Flags := FT_LOAD_NO_HINTING or FT_LOAD_NO_BITMAP;
        if not Face.Load(Run.Glyphs[I], Em, Gx - Ix, Flags) then
          Continue;
        Slot := Face.Slot;
        if (Slot.Format = FT_GLYPH_FORMAT_OUTLINE) and (FT_Render_Glyph(Slot, FT_RENDER_MODE_NORMAL) <> 0) then
          Continue;
        if Slot.Bitmap.PixelMode = FT_PIXEL_MODE_GRAY then
          BlendCoverage(@APixels[0], Stride, Clip, Ix + Slot.BitmapLeft, Iy - Slot.BitmapTop, Slot.Bitmap.Width,
            Slot.Bitmap.Rows, Slot.Bitmap.Buffer, Slot.Bitmap.Pitch, Color);
      end;
    end;
  finally
    TMonitor.Exit(GFtLock);
  end;
  for Deco in Decorations do
  begin
    if Deco.HasColor then
      Color := Deco.Color
    else
      Color := AColor or $FF000000;
    BlendRect(@APixels[0], Stride, Clip, TRectF.Create(Deco.Rect.Left * AScale + ADx, Deco.Rect.Top * AScale + ADy,
      Deco.Rect.Right * AScale + ADx, Deco.Rect.Bottom * AScale + ADy), Color);
  end;
  Result := True;
end;

{ TFastPangoTextLayout }

procedure TFastPangoTextLayout.DoRenderLayout;
var
  Key: string;
  Cached: Boolean;
  D: TFastPangoLayoutData;
  W, H, HAlign: Single;
  I, J, K: Integer;
  Attr: TTextAttributedRange;
  S: TFastPangoStyle;
  CharStyles: TArray<Integer>;
  Ink, Logical: TPangoRectangle;

  function StyleIndex(const AStyle: TFastPangoStyle): Integer;
  var
    N: Integer;
  begin
    for N := 0 to High(D.FStyles) do
      if SameStyle(D.FStyles[N], AStyle) then
        Exit(N);
    Result := Length(D.FStyles);
    D.FStyles := D.FStyles + [AStyle];
  end;

begin
  if Text.IsEmpty then
  begin
    SetData(nil);
    Exit;
  end;
  Cached := AttributesCount = 0;
  if Cached then
  begin
    Key := FastLayoutCacheKey(Self);
    if UseCached(Key) then
      Exit;
  end;
  EnsurePango;

  D := TFastPangoLayoutData.Create;
  try
    // The styles: the layout's font, then the attributes in their order.
    D.FStyles := [StyleOf(Font)];
    SetLength(CharStyles, Length(Text));
    for I := 0 to AttributesCount - 1 do
    begin
      Attr := Attributes[I];
      for J := Max(Attr.Range.Pos, 0) to Min(Attr.Range.Pos + Attr.Range.Length, Length(Text)) - 1 do
      begin
        S := D.FStyles[CharStyles[J]];
        if Attr.Attribute.Font <> nil then
        begin
          K := Ord(S.HasColor);
          S := StyleOf(Attr.Attribute.Font);
          S.HasColor := K <> 0;
          S.Color := D.FStyles[CharStyles[J]].Color;
        end;
        if Attr.Attribute.Color <> TAlphaColorRec.Null then
        begin
          S.Color := Attr.Attribute.Color;
          S.HasColor := True;
        end;
        CharStyles[J] := StyleIndex(S);
      end;
    end;
    D.SetText(Text, CharStyles);
    D.FRtl := RightToLeft;
    case HorizontalAlign of
      TTextAlign.Center: HAlign := 0.5;
      TTextAlign.Trailing: HAlign := 1;
    else
      HAlign := 0;
    end;
    if RightToLeft then
      HAlign := 1 - HAlign;
    if HAlign = 0 then
      D.FAlign := PANGO_ALIGN_LEFT
    else if HAlign = 1 then
      D.FAlign := PANGO_ALIGN_RIGHT
    else
      D.FAlign := PANGO_ALIGN_CENTER;
    W := Max(MaxSize.X - Padding.Left - Padding.Right, 0);
    H := Max(MaxSize.Y - Padding.Top - Padding.Bottom, 0);
    D.LayoutWidth := W;
    D.LayoutHeight := H;
    // Lines as long as they are without WordWrap and Trimming; else wrapped or ellipsized at the box's width, and
    // with both the lines that fit in its height (half a pixel to spare, as FastCanvas.TextSkia).
    D.FWidth := -1;
    D.FHeight := -1;
    if WordWrap or (Trimming <> TTextTrimming.None) then
      D.FWidth := Round(Min(W, MaxPangoSize) * PANGO_SCALE);
    D.FEllipsize := Trimming <> TTextTrimming.None;
    if D.FEllipsize and WordWrap then
      D.FHeight := Round(Min(H + 0.5, MaxPangoSize) * PANGO_SCALE);
    TMonitor.Enter(GPangoLock);
    try
      D.FLayout := D.MakeLayout;
      if Trimming = TTextTrimming.Word then
      begin
        D.TrimWords;
        if D.FMap <> nil then
        begin
          g_object_unref(D.FLayout);
          D.FLayout := D.MakeLayout;
        end;
      end;
      pango_layout_get_extents(D.FLayout, @Ink, @Logical);
      // Lines as long as they are: Pango aligns them with the longest; the alignment moves that in the box.
      if D.FWidth < 0 then
        D.Dx := (W - Logical.Width / PANGO_SCALE) * HAlign - Logical.X / PANGO_SCALE
      else
        D.Dx := 0;
      case VerticalAlign of
        TTextAlign.Center: D.Dy := (H - Logical.Height / PANGO_SCALE) / 2;
        TTextAlign.Trailing: D.Dy := H - Logical.Height / PANGO_SCALE;
      else
        D.Dy := 0;
      end;
      D.Dy := D.Dy - Logical.Y / PANGO_SCALE;
      D.Analyse;
      // Made again for hit testing: cached layouts do not keep it.
      g_object_unref(D.FLayout);
      D.FLayout := nil;
    finally
      TMonitor.Exit(GPangoLock);
    end;
  except
    D.Free;
    raise;
  end;
  SetData(D);
  if Cached then
    CacheData(Key);
end;

procedure UpdateRect(const ALayout: TFastPangoTextLayout; out ARect: TRectF);
var
  R: TRectF;
  L, T: Single;
begin
  if ALayout.Data = nil then
  begin
    ARect := TRectF.Empty;
    Exit;
  end;
  // As the DirectWrite layout reports it: from the text's top-left (not before the box), at most the box's size.
  R := TFastPangoLayoutData(ALayout.Data).TextRect;
  L := Max(R.Left, 0);
  T := Max(R.Top, 0);
  ARect := TRectF.Create(L, T, L + Min(R.Width, ALayout.MaxSize.X),
    T + Min(Min(R.Height, ALayout.Data.LayoutHeight), ALayout.MaxSize.Y));
end;

function TFastPangoTextLayout.GetTextRect: TRectF;
begin
  UpdateRect(Self, Result);
  Result.Offset(LayoutOrigin);
end;

function TFastPangoTextLayout.GetTextWidth: Single;
var
  R: TRectF;
begin
  UpdateRect(Self, R);
  Result := R.Width;
end;

function TFastPangoTextLayout.GetTextHeight: Single;
var
  R: TRectF;
begin
  UpdateRect(Self, R);
  Result := R.Height;
end;

function TFastPangoTextLayout.DoPositionAtPoint(const APoint: TPointF): Integer;
var
  D: TFastPangoLayoutData;
  P: TPointF;
  Index, Trailing, I: Integer;
begin
  D := TFastPangoLayoutData(Data);
  if D = nil then
    Exit(-1);
  P := APoint - LayoutOrigin;
  Index := 0;
  Trailing := 0;
  TMonitor.Enter(GPangoLock);
  try
    pango_layout_xy_to_index(D.Layout, Round((P.X - D.Dx) * PANGO_SCALE), Round((P.Y - D.Dy) * PANGO_SCALE), Index,
      Trailing);
  finally
    TMonitor.Exit(GPangoLock);
  end;
  // The trailing edge of a grapheme: after its characters.
  I := D.FByteToChar[EnsureRange(Index, 0, High(D.FByteToChar))];
  while (Trailing > 0) and (I < Length(D.FText)) do
  begin
    if IsHighSurrogate(D.FText.Chars[I]) and (I + 1 < Length(D.FText)) then
      Inc(I, 2)
    else
      Inc(I);
    Dec(Trailing);
  end;
  Result := EnsureRange(D.TextIndex(I), 0, Text.Length);
end;

function TFastPangoTextLayout.DoRegionForRange(const ARange: TTextRange): TRegion;
var
  D: TFastPangoLayoutData;
  L, Iter: Pointer;
  Line: PPangoLayoutLine;
  O: TPointF;
  S0, S1, B0, B1, Y0, Y1, N, K, LineEnd: Integer;
  Ranges: PInteger;
  Pos: TPangoRectangle;
  List: TList<TRectF>;
begin
  Result := nil;
  D := TFastPangoLayoutData(Data);
  if (D = nil) or Text.IsEmpty then
    Exit;
  O := LayoutOrigin + TPointF.Create(D.Dx, D.Dy);
  TMonitor.Enter(GPangoLock);
  try
    L := D.Layout;
    if ARange.Length <= 0 then
    begin
      // A caret: a zero-width rectangle at the leading edge of the character (after the last one at the end).
      S0 := D.ShownIndex(EnsureRange(ARange.Pos, 0, Text.Length));
      pango_layout_index_to_pos(L, D.FCharToByte[S0], @Pos);
      SetLength(Result, 1);
      Result[0] := TRectF.Create(O.X + Pos.X / PANGO_SCALE, O.Y + Pos.Y / PANGO_SCALE, O.X + Pos.X / PANGO_SCALE,
        O.Y + (Pos.Y + Pos.Height) / PANGO_SCALE);
      Exit;
    end;
    S0 := D.ShownIndex(EnsureRange(ARange.Pos, 0, Text.Length));
    S1 := D.ShownIndex(EnsureRange(ARange.Pos + ARange.Length, 0, Text.Length));
    // A range into text left out by word trimming takes its ellipsis.
    if (D.TextIndex(S1) < ARange.Pos + ARange.Length) and (S1 < Length(D.FText)) then
      Inc(S1);
    B0 := D.FCharToByte[S0];
    B1 := D.FCharToByte[S1];
    List := TList<TRectF>.Create;
    try
      Iter := pango_layout_get_iter(L);
      repeat
        Line := pango_layout_iter_get_line_readonly(Iter);
        LineEnd := Line.StartIndex + Line.Length;
        if (B0 < LineEnd) and (B1 > Line.StartIndex) then
        begin
          pango_layout_iter_get_line_yrange(Iter, Y0, Y1);
          Ranges := nil;
          N := 0;
          // The ranges are relative to the layout, left to right.
          pango_layout_line_get_x_ranges(Line, Max(B0, Line.StartIndex), Min(B1, LineEnd), Ranges, N);
          for K := 0 to N - 1 do
            List.Add(TRectF.Create(O.X + Ranges[2 * K] / PANGO_SCALE, O.Y + Y0 / PANGO_SCALE,
              O.X + Ranges[2 * K + 1] / PANGO_SCALE, O.Y + Y1 / PANGO_SCALE));
          g_free(Ranges);
        end;
      until pango_layout_iter_next_line(Iter) = 0;
      pango_layout_iter_free(Iter);
      SetLength(Result, List.Count);
      for K := 0 to List.Count - 1 do
        Result[K] := List[K];
    finally
      List.Free;
    end;
  finally
    TMonitor.Exit(GPangoLock);
  end;
end;

procedure TFastPangoTextLayout.ConvertToPath(const APath: TPathData);
var
  R: TFastGlyphRun;
  O: TPointF;
  Points: TArray<TPathPoint>;
  I, K: Integer;
begin
  if (APath = nil) or (Data = nil) then
    Exit;
  Data.EnsureRuns;
  for R in Data.Runs do
    for I := 0 to High(R.Glyphs) do
      if TFastPangoEngine.GlyphOutline(R.FontFace, R.Glyphs[I], R.EmSize, False, Points) then
      begin
        O := LayoutOrigin + TPointF.Create(R.OriginX + R.X[I], R.OriginY + R.Y[I]);
        K := 0;
        while K < Length(Points) do
        begin
          case Points[K].Kind of
            TPathPointKind.MoveTo:
              APath.MoveTo(Points[K].Point + O);
            TPathPointKind.LineTo:
              APath.LineTo(Points[K].Point + O);
            TPathPointKind.CurveTo:
              if K + 2 < Length(Points) then
              begin
                APath.CurveTo(Points[K].Point + O, Points[K + 1].Point + O, Points[K + 2].Point + O);
                Inc(K, 2);
              end;
            TPathPointKind.Close:
              APath.ClosePath;
          end;
          Inc(K);
        end;
      end;
end;

{ Glyph outlines }

type
  /// <summary>Collects an outline as FMX path points (FT_Outline_Decompose).</summary>
  TOutlineSink = record
    Points: TArray<TPathPoint>;
    Count: Integer;
    Open: Boolean;
    Last: TPointF;
    procedure Add(const AKind: TPathPointKind; const APoint: TPointF);
  end;
  POutlineSink = ^TOutlineSink;

procedure TOutlineSink.Add(const AKind: TPathPointKind; const APoint: TPointF);
begin
  if Count = Length(Points) then
    SetLength(Points, Max(64, 2 * Count));
  Points[Count].Kind := AKind;
  Points[Count].Point := APoint;
  Inc(Count);
end;

/// <summary>A point of the outline (26.6, y upwards) in pixels, y downwards.</summary>
function SinkPoint(const V: PFTVector): TPointF; inline;
begin
  Result := TPointF.Create(V.X / 64, -V.Y / 64);
end;

function OutlineMoveTo(const ATo: PFTVector; AUser: Pointer): Integer; cdecl;
var
  S: POutlineSink;
begin
  S := AUser;
  if S.Open then
    S.Add(TPathPointKind.Close, S.Last);
  S.Last := SinkPoint(ATo);
  S.Add(TPathPointKind.MoveTo, S.Last);
  S.Open := True;
  Result := 0;
end;

function OutlineLineTo(const ATo: PFTVector; AUser: Pointer): Integer; cdecl;
var
  S: POutlineSink;
begin
  S := AUser;
  S.Last := SinkPoint(ATo);
  S.Add(TPathPointKind.LineTo, S.Last);
  Result := 0;
end;

function OutlineConicTo(const AControl, ATo: PFTVector; AUser: Pointer): Integer; cdecl;
var
  S: POutlineSink;
  C, P: TPointF;
begin
  // The quadratic curve as the cubic of the same curve.
  S := AUser;
  C := SinkPoint(AControl);
  P := SinkPoint(ATo);
  S.Add(TPathPointKind.CurveTo, S.Last + (C - S.Last) * (2 / 3));
  S.Add(TPathPointKind.CurveTo, P + (C - P) * (2 / 3));
  S.Add(TPathPointKind.CurveTo, P);
  S.Last := P;
  Result := 0;
end;

function OutlineCubicTo(const AControl1, AControl2, ATo: PFTVector; AUser: Pointer): Integer; cdecl;
var
  S: POutlineSink;
begin
  S := AUser;
  S.Add(TPathPointKind.CurveTo, SinkPoint(AControl1));
  S.Add(TPathPointKind.CurveTo, SinkPoint(AControl2));
  S.Last := SinkPoint(ATo);
  S.Add(TPathPointKind.CurveTo, S.Last);
  Result := 0;
end;

{ TFastPangoEngine }

class function TFastPangoEngine.LayoutClass: TTextLayoutClass;
begin
  Result := TFastPangoTextLayout;
end;

class function TFastPangoEngine.RasterizeGlyph(const AFace: IInterface; const AGlyph: Word; const AEmSize,
  ASubX: Single; const AKind: TFastGlyphKind; const AMaxSize: Integer; var AMode: Integer; var ABuffer: TBytes;
  out ABounds: TRect): Boolean;
var
  Face: TPangoFace;
  Slot: PFTGlyphSlotRec;
  Flags, Mode, W, H, X, Y: Integer;
  Src, Dst: PByte;
begin
  Result := False;
  ABounds := TRect.Empty;
  Face := FaceObject(AFace);
  if Face = nil then
    Exit;
  TMonitor.Enter(GFtLock);
  try
    // Outlines at the subpixel position (plain coverage), unhinted as FastCanvas.TextSkia rasterizes, or hinted
    // vertically only (the subpixel translation comes after the hinting).
    if not Face.FScalable then
      Flags := FT_LOAD_DEFAULT
    else if FastPangoLightHinting and (AKind <> TFastGlyphKind.Aliased) then
      Flags := FT_LOAD_TARGET_LIGHT or FT_LOAD_NO_BITMAP
    else
      Flags := FT_LOAD_NO_HINTING or FT_LOAD_NO_BITMAP;
    if not Face.Load(AGlyph, AEmSize, ASubX, Flags) then
      Exit;
    Slot := Face.Slot;
    if Slot.Format = FT_GLYPH_FORMAT_OUTLINE then
    begin
      if AKind = TFastGlyphKind.Aliased then
        Mode := FT_RENDER_MODE_MONO
      else
        Mode := FT_RENDER_MODE_NORMAL;
      if FT_Render_Glyph(Slot, Mode) <> 0 then
        Exit;
    end;
    W := Slot.Bitmap.Width;
    H := Slot.Bitmap.Rows;
    if (W <= 0) or (H <= 0) or (W > AMaxSize) or (H > AMaxSize) or
      not (Slot.Bitmap.PixelMode in [FT_PIXEL_MODE_GRAY, FT_PIXEL_MODE_MONO]) then
      Exit;
    if Length(ABuffer) < W * H then
      SetLength(ABuffer, W * H);
    for Y := 0 to H - 1 do
    begin
      Src := Slot.Bitmap.Buffer + Y * Slot.Bitmap.Pitch;
      Dst := @ABuffer[Y * W];
      if Slot.Bitmap.PixelMode = FT_PIXEL_MODE_GRAY then
        Move(Src^, Dst^, W)
      else
        for X := 0 to W - 1 do
          if Src[X shr 3] and ($80 shr (X and 7)) <> 0 then
            Dst[X] := 255
          else
            Dst[X] := 0;
    end;
    ABounds := TRect.Create(Slot.BitmapLeft, -Slot.BitmapTop, Slot.BitmapLeft + W, H - Slot.BitmapTop);
    Result := True;
  finally
    TMonitor.Exit(GFtLock);
  end;
end;

class function TFastPangoEngine.GlyphOutline(const AFace: IInterface; const AGlyph: Word; const AEmSize: Single;
  const ASideways: Boolean; out APoints: TArray<TPathPoint>): Boolean;
var
  Face: TPangoFace;
  Funcs: TFTOutlineFuncs;
  Sink: TOutlineSink;
begin
  APoints := nil;
  Face := FaceObject(AFace);
  if Face = nil then
    Exit(False);
  Result := True;
  TMonitor.Enter(GFtLock);
  try
    // A glyph without an outline (a space, a color bitmap) has no points.
    if not Face.Load(AGlyph, AEmSize, 0, FT_LOAD_NO_HINTING or FT_LOAD_NO_BITMAP) or
      (Face.Slot.Format <> FT_GLYPH_FORMAT_OUTLINE) then
      Exit;
    Funcs := Default(TFTOutlineFuncs);
    Funcs.MoveTo := @OutlineMoveTo;
    Funcs.LineTo := @OutlineLineTo;
    Funcs.ConicTo := @OutlineConicTo;
    Funcs.CubicTo := @OutlineCubicTo;
    Sink := Default(TOutlineSink);
    if FT_Outline_Decompose(@Face.Slot.Outline, @Funcs, @Sink) <> 0 then
      Exit;
    if Sink.Open then
      Sink.Add(TPathPointKind.Close, Sink.Last);
    APoints := Copy(Sink.Points, 0, Sink.Count);
  finally
    TMonitor.Exit(GFtLock);
  end;
end;

class procedure TFastPangoEngine.Shutdown;
var
  Font: Pointer;
begin
  if GPangoLock = nil then
    Exit;
  TMonitor.Enter(GPangoLock);
  try
    if GFonts <> nil then
    begin
      for Font in GFonts.Keys do
        g_object_unref(Font);
      // The faces go with their last reference (FT_Done_Face).
      FreeAndNil(GFonts);
      FreeAndNil(GFaces);
    end;
    // Layouts that are left hold their context and font map.
    if GContextLtr <> nil then
      g_object_unref(GContextLtr);
    if GContextRtl <> nil then
      g_object_unref(GContextRtl);
    if GFontMap <> nil then
      g_object_unref(GFontMap);
    GContextLtr := nil;
    GContextRtl := nil;
    GFontMap := nil;
    GLoaded := 0;
  finally
    TMonitor.Exit(GPangoLock);
  end;
  // As the layout cache's lock (FastTextShutdown): layouts made after this would need the device, which is gone.
  FreeAndNil(GPangoLock);
  FreeAndNil(GFtLock);
end;

{$ENDIF}

{$IFDEF LINUX}
initialization
  // Freed by Shutdown (FastTextShutdown), not here: layouts are made and destroyed with the forms, after the unit
  // finalizations.
  GPangoLock := TObject.Create;
  GFtLock := TObject.Create;
  FastRegisterTextEngine(TFastCanvasEngine.Native, TFastPangoEngine);
{$ENDIF}
end.
