unit FastCanvas.Platform;

{ What the canvas needs of the windows of FMX's platform: the window its backend presents to (TGpuWindowHandle), and
  the size of a form's client area in pixels.

  - Windows: the HWND of the form.
  - Android: the native window (ANativeWindow) of the form's surface; a reference the canvas holds until it goes. The
    surface goes away when the app goes to the background (Holder is nil then) and FMX makes the form's canvas again
    when it comes back (surfaceCreated, surfaceChanged: TCustomForm.RecreateResources).
  - Linux: the X11 window of the GTK drawing area of the form's client area (made native) and its display, through
    GDK (libgdk-3.so.0, libgtk-3.so.0, loaded on first use). FMX's FMUX runs GTK on X11 (FMUX_INIT_NOWAYLAND; under
    a Wayland session through XWayland).
  - Linux on FMXWayland (a native Wayland platform for FMX that replaces libfmux; FastCanvas does not depend on it):
    FMXWayland registers the platform service IFMXWaylandNativeWindow, declared here again (same GUID, methods and
    signatures). A toplevel window is the wl_surface of the form on FMXWayland's wl_display; while the canvas holds
    it, FMXWayland's own frames are off (SetExternalPresentation) and the canvas presents through Vulkan's Wayland
    surface; its size in pixels is the buffer size FMXWayland reports (with a fractional scale FMXWayland's viewport
    maps it to the window). Popups (combo box lists, menus: xdg_popups, which FMXWayland makes again at every show
    and move) and transparent forms are not presented by the canvas: their frames are read back and handed to
    FMXWayland's frame with FmuxCanvasDrawBitmap, as FMX's Skia raster canvas does (FastWindowReadback,
    FastWindowShowPixels). Before FMXWayland unmaps a toplevel (FMX hides the form) the canvas stops presenting to
    it (FastWindowUnmapping), since a buffer committed to an unmapped xdg_surface is a protocol error. }

interface

uses
  System.Types, FMX.Types, FastCanvas.Gpu;

{$IF Defined(LINUX)}
type
  /// <summary>FMXWayland's platform service for GPU canvases (FMXWayland.Native, see its README): the same GUID,
  /// methods in the same order and signatures, so that FastCanvas finds it without depending on FMXWayland. Main
  /// thread.</summary>
  IFMXWaylandNativeWindow = interface
    ['{B04A2FBC-1322-42BC-98A6-D526A7854F2C}']
    /// <summary>The wl_display* of the process's connection to the compositor.</summary>
    function GetWaylandDisplay: Pointer;
    /// <summary>The wl_surface* of the window of AHandle; nil if AHandle is not a window of FMXWayland.</summary>
    function GetWaylandSurface(const AHandle: TWindowHandle): Pointer;
    /// <summary>Size of the window's surface in buffer pixels (logical client size x scale, rounded).</summary>
    function GetBufferSize(const AHandle: TWindowHandle): TSize;
    /// <summary>Buffer pixels per logical pixel.</summary>
    function GetScale(const AHandle: TWindowHandle): Single;
    /// <summary>True: the caller presents to the surface itself; FMXWayland keeps calling FMX's paint but stops
    /// attaching its own frames. False: FMXWayland's frames again.</summary>
    procedure SetExternalPresentation(const AHandle: TWindowHandle; const AValue: Boolean);
  end;

/// <summary>FMXWayland's service when FMX runs on it, else nil (FMX's GTK platform).</summary>
function FastWaylandService: IFMXWaylandNativeWindow;
{$ENDIF}

/// <summary>The window of a form's handle; Window = 0 when it has none now (Android: no surface). Main thread.
/// </summary>
function FastWindowOf(const AHandle: TWindowHandle): TGpuWindowHandle;
/// <summary>Lets go of what FastWindowOf took (Android: the native window's reference).</summary>
procedure FastReleaseWindow(var AWindow: TGpuWindowHandle);
/// <summary>The form's window can be drawn into now (Android: it has its surface).</summary>
function FastWindowReady(const AHandle: TWindowHandle): Boolean;
/// <summary>The size of the client area in pixels: of the native window where there is one, else the logical size
/// times the scale.</summary>
function FastWindowPixelSize(const AHandle: TWindowHandle; const AWindow: TGpuWindowHandle;
  const ALogicalWidth, ALogicalHeight: Single): TSize;
/// <summary>Android: FMX's platform forgets the rectangles a form invalidates and paints the whole form
/// (TFormRender.Render: PaintRects([ClientRect])); its window service is wrapped (FastCanvas installs it) so that they
/// are kept for partial frames. Elsewhere nothing. Main thread, before forms are made.</summary>
procedure FastKeepInvalidated;
/// <summary>Android: the rectangles invalidated in the form of the handle since the last call (logical units), and
/// that they are known; False where FastKeepInvalidated keeps none (other platforms: FMX passes them itself), or none
/// were invalidated (the platform paints for a reason of its own: the whole form).</summary>
function FastTakeInvalidated(const AHandle: TWindowHandle; out ARects: TArray<TRectF>): Boolean;
/// <summary>The window's frames go to the platform as pixels rather than to a swap chain: on FMXWayland popups and
/// transparent forms (FastWindowShowPixels after every frame). False elsewhere. Main thread.</summary>
function FastWindowReadback(const AHandle: TWindowHandle): Boolean;
/// <summary>FastWindowReadback: hands a frame (AWidth x AHeight premultiplied BGRA pixels, rows AWidth * 4 bytes
/// apart, for a client area of ALogical units) to the platform's paint context AContext (what FMX gave BeginScene).
/// Main thread.</summary>
procedure FastWindowShowPixels(const AContext: THandle; const ABits: Pointer; const AWidth, AHeight: Integer;
  const ALogical: TSizeF);
/// <summary>FMXWayland: the window service is wrapped so that FastWindowUnmapping is told before a form's window is
/// hidden. Elsewhere nothing. Main thread, before forms are made.</summary>
procedure FastWatchUnmapping;

var
  /// <summary>Set by the canvas: the platform is about to unmap the window whose native window (TGpuWindowHandle.
  /// Window: FMXWayland's wl_surface) is ANative; nothing may be presented to it until the platform paints it again.
  /// Main thread.</summary>
  FastWindowUnmapping: procedure(const ANative: NativeUInt);

implementation

uses
{$IF Defined(MSWINDOWS)}
  Winapi.Windows, FMX.Platform.Win;
{$ELSEIF Defined(ANDROID)}
  System.UITypes, System.Generics.Collections, FMX.Forms, FMX.Platform, Androidapi.JNI.GraphicsContentViewText,
  Androidapi.JNIBridge, Androidapi.NativeWindow, Androidapi.NativeWindowJni, FMX.Platform.UI.Android;
{$ELSE}
  System.SysUtils, System.UITypes, System.Generics.Collections, Posix.Dlfcn, FMX.Forms, FMX.Platform,
  FMX.Platform.Linux, FMUX.Api;
{$ENDIF}

{$IF Defined(MSWINDOWS)}

function FastWindowOf(const AHandle: TWindowHandle): TGpuWindowHandle;
begin
  Result := Default(TGpuWindowHandle);
  Result.Window := NativeUInt(WindowHandleToPlatform(AHandle).Wnd);
end;

procedure FastReleaseWindow(var AWindow: TGpuWindowHandle);
begin
  AWindow := Default(TGpuWindowHandle);
end;

function FastWindowReady(const AHandle: TWindowHandle): Boolean;
begin
  Result := True;
end;

function FastWindowPixelSize(const AHandle: TWindowHandle; const AWindow: TGpuWindowHandle;
  const ALogicalWidth, ALogicalHeight: Single): TSize;
begin
  Result := WindowHandleToPlatform(AHandle).WndClientSize;
end;

procedure FastKeepInvalidated;
begin
end;

function FastTakeInvalidated(const AHandle: TWindowHandle; out ARects: TArray<TRectF>): Boolean;
begin
  ARects := nil;
  Result := False;
end;

function FastWindowReadback(const AHandle: TWindowHandle): Boolean;
begin
  Result := False;
end;

procedure FastWindowShowPixels(const AContext: THandle; const ABits: Pointer; const AWidth, AHeight: Integer;
  const ALogical: TSizeF);
begin
end;

procedure FastWatchUnmapping;
begin
end;

{$ELSE}

type
  /// <summary>The window service of FMX's platform with what the canvas needs to know of it: on Android the
  /// rectangles forms invalidate, kept by window handle (FastKeepInvalidated); on FMXWayland the windows about to be
  /// hidden (FastWatchUnmapping). Everything else as the platform's.</summary>
  TFastWindowService = class(TInterfacedObject, IFMXWindowService)
  private
    FInner: IFMXWindowService;
    /// <summary>FastWindowUnmapping for the window of AForm (FMXWayland).</summary>
    procedure Unmapping(const AForm: TCommonCustomForm);
  public
    constructor Create(const AInner: IFMXWindowService);
    function FindForm(const AHandle: TWindowHandle): TCommonCustomForm;
    function CreateWindow(const AForm: TCommonCustomForm): TWindowHandle;
    procedure DestroyWindow(const AForm: TCommonCustomForm);
    procedure ReleaseWindow(const AForm: TCommonCustomForm);
    procedure SetWindowState(const AForm: TCommonCustomForm; const AState: TWindowState);
    procedure ShowWindow(const AForm: TCommonCustomForm);
    procedure HideWindow(const AForm: TCommonCustomForm);
    function ShowWindowModal(const AForm: TCommonCustomForm): TModalResult;
    procedure InvalidateWindowRect(const AForm: TCommonCustomForm; R: TRectF);
    procedure InvalidateImmediately(const AForm: TCommonCustomForm);
    procedure SetWindowRect(const AForm: TCommonCustomForm; ARect: TRectF);
    function GetWindowRect(const AForm: TCommonCustomForm): TRectF;
    function GetClientSize(const AForm: TCommonCustomForm): TPointF;
    procedure SetClientSize(const AForm: TCommonCustomForm; const ASize: TPointF);
    procedure SetWindowCaption(const AForm: TCommonCustomForm; const ACaption: string);
    procedure SetCapture(const AForm: TCommonCustomForm);
    procedure ReleaseCapture(const AForm: TCommonCustomForm);
    function ClientToScreen(const AForm: TCommonCustomForm; const AFormPoint: TPointF): TPointF;
    function ScreenToClient(const AForm: TCommonCustomForm; const AScreenPoint: TPointF): TPointF;
    procedure BringToFront(const AForm: TCommonCustomForm);
    procedure SendToBack(const AForm: TCommonCustomForm);
    procedure Activate(const AForm: TCommonCustomForm);
    function GetWindowScale(const AForm: TCommonCustomForm): Single;
    function CanShowModal: Boolean;
  end;

const
  /// <summary>More rectangles than this become their union (as FMX's forms do).</summary>
  MaxKeptRects = 20;

var
  /// <summary>Main thread: the window service is wrapped (FastKeepInvalidated, FastWatchUnmapping).</summary>
  GWrapped: Boolean;
  /// <summary>Main thread: the rectangles invalidated in each window since FastTakeInvalidated took them (Android).
  /// </summary>
  GInvalidated: TDictionary<TWindowHandle, TArray<TRectF>>;
{$IF Defined(LINUX)}
  /// <summary>Main thread: FastWindowUnmapping is told about windows the platform hides (FMXWayland).</summary>
  GWatchUnmapping: Boolean;
{$ENDIF}

/// <summary>Wraps the platform's window service once.</summary>
procedure WrapWindowService;
var
  Inner: IFMXWindowService;
begin
  if GWrapped or not TPlatformServices.Current.SupportsPlatformService(IFMXWindowService, Inner) then
    Exit;
  GWrapped := True;
  TPlatformServices.Current.RemovePlatformService(IFMXWindowService);
  TPlatformServices.Current.AddPlatformService(IFMXWindowService, TFastWindowService.Create(Inner));
end;

{$IF Defined(LINUX)}
function WaylandSurfaceOf(const AHandle: TWindowHandle; out AService: IFMXWaylandNativeWindow): Pointer; forward;
{$ENDIF}

constructor TFastWindowService.Create(const AInner: IFMXWindowService);
begin
  inherited Create;
  FInner := AInner;
end;

procedure TFastWindowService.Unmapping(const AForm: TCommonCustomForm);
{$IF Defined(LINUX)}
var
  Svc: IFMXWaylandNativeWindow;
  Surface: Pointer;
{$ENDIF}
begin
{$IF Defined(LINUX)}
  if not GWatchUnmapping or not Assigned(FastWindowUnmapping) or (AForm = nil) or not AForm.IsHandleAllocated then
    Exit;
  Surface := WaylandSurfaceOf(AForm.Handle, Svc);
  if Surface <> nil then
    FastWindowUnmapping(NativeUInt(Surface));
{$ENDIF}
end;

function TFastWindowService.FindForm(const AHandle: TWindowHandle): TCommonCustomForm;
begin
  Result := FInner.FindForm(AHandle);
end;

function TFastWindowService.CreateWindow(const AForm: TCommonCustomForm): TWindowHandle;
begin
  Result := FInner.CreateWindow(AForm);
end;

procedure TFastWindowService.DestroyWindow(const AForm: TCommonCustomForm);
begin
  if (GInvalidated <> nil) and AForm.IsHandleAllocated then
    GInvalidated.Remove(AForm.Handle);
  FInner.DestroyWindow(AForm);
end;

procedure TFastWindowService.ReleaseWindow(const AForm: TCommonCustomForm);
begin
  // FMX's Linux platform hides the window here.
  Unmapping(AForm);
  FInner.ReleaseWindow(AForm);
end;

procedure TFastWindowService.SetWindowState(const AForm: TCommonCustomForm; const AState: TWindowState);
begin
  FInner.SetWindowState(AForm, AState);
end;

procedure TFastWindowService.ShowWindow(const AForm: TCommonCustomForm);
begin
  FInner.ShowWindow(AForm);
end;

procedure TFastWindowService.HideWindow(const AForm: TCommonCustomForm);
begin
  Unmapping(AForm);
  FInner.HideWindow(AForm);
end;

function TFastWindowService.ShowWindowModal(const AForm: TCommonCustomForm): TModalResult;
begin
  Result := FInner.ShowWindowModal(AForm);
end;

procedure TFastWindowService.InvalidateWindowRect(const AForm: TCommonCustomForm; R: TRectF);
var
  Rects: TArray<TRectF>;
  I: Integer;
begin
  if (GInvalidated <> nil) and AForm.IsHandleAllocated then
  begin
    if not GInvalidated.TryGetValue(AForm.Handle, Rects) then
      Rects := nil;
    Rects := Rects + [R];
    if Length(Rects) > MaxKeptRects then
    begin
      for I := 1 to High(Rects) do
        Rects[0] := TRectF.Union(Rects[0], Rects[I]);
      SetLength(Rects, 1);
    end;
    GInvalidated.AddOrSetValue(AForm.Handle, Rects);
  end;
  FInner.InvalidateWindowRect(AForm, R);
end;

procedure TFastWindowService.InvalidateImmediately(const AForm: TCommonCustomForm);
begin
  FInner.InvalidateImmediately(AForm);
end;

procedure TFastWindowService.SetWindowRect(const AForm: TCommonCustomForm; ARect: TRectF);
begin
  FInner.SetWindowRect(AForm, ARect);
end;

function TFastWindowService.GetWindowRect(const AForm: TCommonCustomForm): TRectF;
begin
  Result := FInner.GetWindowRect(AForm);
end;

function TFastWindowService.GetClientSize(const AForm: TCommonCustomForm): TPointF;
begin
  Result := FInner.GetClientSize(AForm);
end;

procedure TFastWindowService.SetClientSize(const AForm: TCommonCustomForm; const ASize: TPointF);
begin
  FInner.SetClientSize(AForm, ASize);
end;

procedure TFastWindowService.SetWindowCaption(const AForm: TCommonCustomForm; const ACaption: string);
begin
  FInner.SetWindowCaption(AForm, ACaption);
end;

procedure TFastWindowService.SetCapture(const AForm: TCommonCustomForm);
begin
  FInner.SetCapture(AForm);
end;

procedure TFastWindowService.ReleaseCapture(const AForm: TCommonCustomForm);
begin
  FInner.ReleaseCapture(AForm);
end;

function TFastWindowService.ClientToScreen(const AForm: TCommonCustomForm; const AFormPoint: TPointF): TPointF;
begin
  Result := FInner.ClientToScreen(AForm, AFormPoint);
end;

function TFastWindowService.ScreenToClient(const AForm: TCommonCustomForm; const AScreenPoint: TPointF): TPointF;
begin
  Result := FInner.ScreenToClient(AForm, AScreenPoint);
end;

procedure TFastWindowService.BringToFront(const AForm: TCommonCustomForm);
begin
  FInner.BringToFront(AForm);
end;

procedure TFastWindowService.SendToBack(const AForm: TCommonCustomForm);
begin
  FInner.SendToBack(AForm);
end;

procedure TFastWindowService.Activate(const AForm: TCommonCustomForm);
begin
  FInner.Activate(AForm);
end;

{$WARN SYMBOL_DEPRECATED OFF}
function TFastWindowService.GetWindowScale(const AForm: TCommonCustomForm): Single;
begin
  Result := FInner.GetWindowScale(AForm);
end;
{$WARN SYMBOL_DEPRECATED ON}

function TFastWindowService.CanShowModal: Boolean;
begin
  Result := FInner.CanShowModal;
end;

function FastTakeInvalidated(const AHandle: TWindowHandle; out ARects: TArray<TRectF>): Boolean;
begin
  ARects := nil;
  Result := (GInvalidated <> nil) and GInvalidated.TryGetValue(AHandle, ARects) and (Length(ARects) > 0);
  if GInvalidated <> nil then
    GInvalidated.Remove(AHandle);
end;

{$IF Defined(ANDROID)}

function FastWindowOf(const AHandle: TWindowHandle): TGpuWindowHandle;
var
  Holder: JSurfaceHolder;
  Surface: Pointer;
begin
  Result := Default(TGpuWindowHandle);
  if not (AHandle is TAndroidWindowHandle) then
    Exit;
  Holder := TAndroidWindowHandle(AHandle).Holder;
  if Holder = nil then
    Exit;
  Surface := (Holder.getSurface as ILocalObject).GetObjectID;
  if Surface <> nil then
    Result.Window := NativeUInt(ANativeWindow_fromSurface(TJNIResolver.GetJNIEnv, Surface));
end;

procedure FastReleaseWindow(var AWindow: TGpuWindowHandle);
begin
  if AWindow.Window <> 0 then
    ANativeWindow_release(PANativeWindow(AWindow.Window));
  AWindow := Default(TGpuWindowHandle);
end;

function FastWindowReady(const AHandle: TWindowHandle): Boolean;
begin
  Result := (AHandle is TAndroidWindowHandle) and (TAndroidWindowHandle(AHandle).Holder <> nil);
end;

function FastWindowPixelSize(const AHandle: TWindowHandle; const AWindow: TGpuWindowHandle;
  const ALogicalWidth, ALogicalHeight: Single): TSize;
var
  W, H: Integer;
begin
  W := 0;
  H := 0;
  if AWindow.Window <> 0 then
  begin
    W := ANativeWindow_getWidth(PANativeWindow(AWindow.Window));
    H := ANativeWindow_getHeight(PANativeWindow(AWindow.Window));
  end;
  if (W <= 0) or (H <= 0) then
  begin
    W := Round(ALogicalWidth * AHandle.Scale);
    H := Round(ALogicalHeight * AHandle.Scale);
  end;
  Result := TSize.Create(W, H);
end;

procedure FastKeepInvalidated;
begin
  if GInvalidated = nil then
    GInvalidated := TDictionary<TWindowHandle, TArray<TRectF>>.Create;
  WrapWindowService;
end;

function FastWindowReadback(const AHandle: TWindowHandle): Boolean;
begin
  Result := False;
end;

procedure FastWindowShowPixels(const AContext: THandle; const ABits: Pointer; const AWidth, AHeight: Integer;
  const ALogical: TSizeF);
begin
end;

procedure FastWatchUnmapping;
begin
end;

{$ELSE}

type
  TGtkWidgetGetWindow = function(AWidget: Pointer): Pointer; cdecl;
  TGdkWindowEnsureNative = function(AWindow: Pointer): Integer; cdecl;
  TGdkWindowGetDisplay = function(AWindow: Pointer): Pointer; cdecl;
  TGdkX11WindowGetXid = function(AWindow: Pointer): NativeUInt; cdecl;
  TGdkX11DisplayGetXDisplay = function(ADisplay: Pointer): Pointer; cdecl;

var
  GGdkLoaded: Boolean;
  gtk_widget_get_window: TGtkWidgetGetWindow;
  gdk_window_ensure_native: TGdkWindowEnsureNative;
  gdk_window_get_display: TGdkWindowGetDisplay;
  gdk_x11_window_get_xid: TGdkX11WindowGetXid;
  gdk_x11_display_get_xdisplay: TGdkX11DisplayGetXDisplay;

/// <summary>The GTK and GDK functions (the libraries FMUX has loaded already). False without X11 (Wayland).
/// </summary>
function LoadGdk: Boolean;
var
  Gtk, Gdk: NativeUInt;
begin
  if not GGdkLoaded then
  begin
    GGdkLoaded := True;
    Gtk := NativeUInt(dlopen('libgtk-3.so.0', RTLD_LAZY));
    Gdk := NativeUInt(dlopen('libgdk-3.so.0', RTLD_LAZY));
    if (Gtk <> 0) and (Gdk <> 0) then
    begin
      @gtk_widget_get_window := dlsym(Gtk, 'gtk_widget_get_window');
      @gdk_window_ensure_native := dlsym(Gdk, 'gdk_window_ensure_native');
      @gdk_window_get_display := dlsym(Gdk, 'gdk_window_get_display');
      @gdk_x11_window_get_xid := dlsym(Gdk, 'gdk_x11_window_get_xid');
      @gdk_x11_display_get_xdisplay := dlsym(Gdk, 'gdk_x11_display_get_xdisplay');
    end;
  end;
  Result := Assigned(gtk_widget_get_window) and Assigned(gdk_window_ensure_native) and
    Assigned(gdk_window_get_display) and Assigned(gdk_x11_window_get_xid) and Assigned(gdk_x11_display_get_xdisplay);
end;

function FastWaylandService: IFMXWaylandNativeWindow;
begin
  // Registered by FMXWayland when it connects (FmuxInit, while FMX.Platform initializes); never under FMX's GTK
  // platform. Not kept here: forms (and with them canvases) are freed after the unit finalizations.
  if not TPlatformServices.Current.SupportsPlatformService(IFMXWaylandNativeWindow, Result) then
    Result := nil;
end;

/// <summary>The wl_surface of an FMXWayland window and the service; nil (and AService nil) for other windows.
/// </summary>
function WaylandSurfaceOf(const AHandle: TWindowHandle; out AService: IFMXWaylandNativeWindow): Pointer;
begin
  Result := nil;
  AService := nil;
  if not (AHandle is TLinuxWindowHandle) then
    Exit;
  AService := FastWaylandService;
  if AService <> nil then
    Result := AService.GetWaylandSurface(AHandle);
  if Result = nil then
    AService := nil;
end;

function FastWindowReadback(const AHandle: TWindowHandle): Boolean;
var
  Svc: IFMXWaylandNativeWindow;
  Windows: IFMXWindowService;
  Form: TCommonCustomForm;
begin
  Result := False;
  if WaylandSurfaceOf(AHandle, Svc) = nil then
    Exit;
  // xdg_popups are made again at every show and move (FMXWayland), transparent forms need the frame's alpha: their
  // frames go to the platform's paint context.
  Form := nil;
  if TPlatformServices.Current.SupportsPlatformService(IFMXWindowService, Windows) then
    Form := Windows.FindForm(AHandle);
  Result := (Form <> nil) and ((Form.FormStyle = TFormStyle.Popup) or Form.Transparency);
end;

procedure FastWindowShowPixels(const AContext: THandle; const ABits: Pointer; const AWidth, AHeight: Integer;
  const ALogical: TSizeF);
var
  Bitmap: Pointer;
begin
  if (AContext = 0) or (ABits = nil) or (AWidth <= 0) or (AHeight <= 0) then
    Exit;
  // What FMX's Skia raster canvas does with its frame on Linux (FMX.Skia.Canvas, TSkRasterCanvas.SwapBuffers): an
  // FMUX bitmap over the pixels, drawn 1:1 into the platform's frame.
  Bitmap := FmuxBitmapCreate(AWidth, AHeight, ABits);
  if Bitmap = nil then
    Exit;
  try
    FmuxCanvasDrawBitmap(Pointer(AContext), Bitmap, TRectF.Create(0, 0, AWidth, AHeight),
      TRectF.Create(0, 0, ALogical.Width, ALogical.Height), 1, True);
  finally
    FmuxBitmapDestroy(Bitmap);
  end;
end;

function FastWindowOf(const AHandle: TWindowHandle): TGpuWindowHandle;
var
  Area, Window: Pointer;
  Svc: IFMXWaylandNativeWindow;
begin
  Result := Default(TGpuWindowHandle);
  if not (AHandle is TLinuxWindowHandle) then
    Exit;
  // FMXWayland: the window's wl_surface; FMXWayland's own frames stop while the canvas presents to it.
  Window := WaylandSurfaceOf(AHandle, Svc);
  if Window <> nil then
  begin
    if FastWindowReadback(AHandle) then
      Exit;
    Result.Display := Svc.GetWaylandDisplay;
    if Result.Display = nil then
      Exit;
    Result.Window := NativeUInt(Window);
    Result.Wayland := True;
    Result.Owner := AHandle;
    Svc.SetExternalPresentation(AHandle, True);
    Exit;
  end;
  if not LoadGdk then
    Exit;
  // The drawing area of the client area; its GDK window made native gets an X11 window of its own.
  Area := TLinuxWindowHandle(AHandle).NativeDrawingArea;
  if Area = nil then
    Area := TLinuxWindowHandle(AHandle).NativeHandle;
  if Area = nil then
    Exit;
  Window := gtk_widget_get_window(Area);
  if (Window = nil) or (gdk_window_ensure_native(Window) = 0) then
    Exit;
  Result.Display := gdk_x11_display_get_xdisplay(gdk_window_get_display(Window));
  Result.Window := gdk_x11_window_get_xid(Window);
  if Result.Display = nil then
    Result.Window := 0;
end;

procedure FastReleaseWindow(var AWindow: TGpuWindowHandle);
var
  Svc: IFMXWaylandNativeWindow;
begin
  // FMXWayland shows its own frames again (the form's handle outlives the canvas and the 3D context: FMX frees them
  // first). Nothing when FMXWayland no longer knows the window.
  if AWindow.Wayland and (AWindow.Owner is TWindowHandle) and
    (WaylandSurfaceOf(TWindowHandle(AWindow.Owner), Svc) = Pointer(AWindow.Window)) then
    Svc.SetExternalPresentation(TWindowHandle(AWindow.Owner), False);
  AWindow := Default(TGpuWindowHandle);
end;

function FastWindowReady(const AHandle: TWindowHandle): Boolean;
begin
  Result := True;
end;

function FastWindowPixelSize(const AHandle: TWindowHandle; const AWindow: TGpuWindowHandle;
  const ALogicalWidth, ALogicalHeight: Single): TSize;
var
  Svc: IFMXWaylandNativeWindow;
begin
  // FMXWayland: the size of the window's buffers (and of its frames read back), which its viewport maps to the
  // window at a fractional scale.
  if WaylandSurfaceOf(AHandle, Svc) <> nil then
    Result := Svc.GetBufferSize(AHandle)
  else
    Result := TSize.Create(Round(ALogicalWidth * AHandle.Scale), Round(ALogicalHeight * AHandle.Scale));
end;

procedure FastKeepInvalidated;
begin
end;

procedure FastWatchUnmapping;
begin
  if FastWaylandService = nil then
    Exit;
  GWatchUnmapping := True;
  WrapWindowService;
end;

{$ENDIF}

{$ENDIF}

end.
