unit FastCanvas.Platform;

{ What the canvas needs of the windows of FMX's platform: the window its backend presents to (TGpuWindowHandle), and
  the size of a form's client area in pixels.

  - Windows: the HWND of the form.
  - Android: the native window (ANativeWindow) of the form's surface; a reference the canvas holds until it goes. The
    surface goes away when the app goes to the background (Holder is nil then) and FMX makes the form's canvas again
    when it comes back (surfaceCreated, surfaceChanged: TCustomForm.RecreateResources).
  - Linux: the X11 window of the GTK drawing area of the form's client area (made native) and its display, through
    GDK (libgdk-3.so.0, libgtk-3.so.0, loaded on first use). FMX's FMUX runs GTK on X11 (FMUX_INIT_NOWAYLAND; under
    a Wayland session through XWayland); Wayland windows are not supported. }

interface

uses
  System.Types, FMX.Types, FastCanvas.Gpu;

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

implementation

uses
{$IF Defined(MSWINDOWS)}
  Winapi.Windows, FMX.Platform.Win;
{$ELSEIF Defined(ANDROID)}
  System.UITypes, System.Generics.Collections, FMX.Forms, FMX.Platform, Androidapi.JNI.GraphicsContentViewText,
  Androidapi.JNIBridge, Androidapi.NativeWindow, Androidapi.NativeWindowJni, FMX.Platform.UI.Android;
{$ELSE}
  System.SysUtils, Posix.Dlfcn, FMX.Platform.Linux;
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

{$ELSEIF Defined(ANDROID)}

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

type
  /// <summary>The window service of FMX's platform with the rectangles forms invalidate kept by window handle
  /// (FastKeepInvalidated): everything else as the platform's.</summary>
  TKeepingWindowService = class(TInterfacedObject, IFMXWindowService)
  private
    FInner: IFMXWindowService;
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
  /// <summary>Main thread: the rectangles invalidated in each window since FastTakeInvalidated took them.</summary>
  GInvalidated: TDictionary<TWindowHandle, TArray<TRectF>>;

constructor TKeepingWindowService.Create(const AInner: IFMXWindowService);
begin
  inherited Create;
  FInner := AInner;
end;

function TKeepingWindowService.FindForm(const AHandle: TWindowHandle): TCommonCustomForm;
begin
  Result := FInner.FindForm(AHandle);
end;

function TKeepingWindowService.CreateWindow(const AForm: TCommonCustomForm): TWindowHandle;
begin
  Result := FInner.CreateWindow(AForm);
end;

procedure TKeepingWindowService.DestroyWindow(const AForm: TCommonCustomForm);
begin
  if (GInvalidated <> nil) and AForm.IsHandleAllocated then
    GInvalidated.Remove(AForm.Handle);
  FInner.DestroyWindow(AForm);
end;

procedure TKeepingWindowService.ReleaseWindow(const AForm: TCommonCustomForm);
begin
  FInner.ReleaseWindow(AForm);
end;

procedure TKeepingWindowService.SetWindowState(const AForm: TCommonCustomForm; const AState: TWindowState);
begin
  FInner.SetWindowState(AForm, AState);
end;

procedure TKeepingWindowService.ShowWindow(const AForm: TCommonCustomForm);
begin
  FInner.ShowWindow(AForm);
end;

procedure TKeepingWindowService.HideWindow(const AForm: TCommonCustomForm);
begin
  FInner.HideWindow(AForm);
end;

function TKeepingWindowService.ShowWindowModal(const AForm: TCommonCustomForm): TModalResult;
begin
  Result := FInner.ShowWindowModal(AForm);
end;

procedure TKeepingWindowService.InvalidateWindowRect(const AForm: TCommonCustomForm; R: TRectF);
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

procedure TKeepingWindowService.InvalidateImmediately(const AForm: TCommonCustomForm);
begin
  FInner.InvalidateImmediately(AForm);
end;

procedure TKeepingWindowService.SetWindowRect(const AForm: TCommonCustomForm; ARect: TRectF);
begin
  FInner.SetWindowRect(AForm, ARect);
end;

function TKeepingWindowService.GetWindowRect(const AForm: TCommonCustomForm): TRectF;
begin
  Result := FInner.GetWindowRect(AForm);
end;

function TKeepingWindowService.GetClientSize(const AForm: TCommonCustomForm): TPointF;
begin
  Result := FInner.GetClientSize(AForm);
end;

procedure TKeepingWindowService.SetClientSize(const AForm: TCommonCustomForm; const ASize: TPointF);
begin
  FInner.SetClientSize(AForm, ASize);
end;

procedure TKeepingWindowService.SetWindowCaption(const AForm: TCommonCustomForm; const ACaption: string);
begin
  FInner.SetWindowCaption(AForm, ACaption);
end;

procedure TKeepingWindowService.SetCapture(const AForm: TCommonCustomForm);
begin
  FInner.SetCapture(AForm);
end;

procedure TKeepingWindowService.ReleaseCapture(const AForm: TCommonCustomForm);
begin
  FInner.ReleaseCapture(AForm);
end;

function TKeepingWindowService.ClientToScreen(const AForm: TCommonCustomForm; const AFormPoint: TPointF): TPointF;
begin
  Result := FInner.ClientToScreen(AForm, AFormPoint);
end;

function TKeepingWindowService.ScreenToClient(const AForm: TCommonCustomForm; const AScreenPoint: TPointF): TPointF;
begin
  Result := FInner.ScreenToClient(AForm, AScreenPoint);
end;

procedure TKeepingWindowService.BringToFront(const AForm: TCommonCustomForm);
begin
  FInner.BringToFront(AForm);
end;

procedure TKeepingWindowService.SendToBack(const AForm: TCommonCustomForm);
begin
  FInner.SendToBack(AForm);
end;

procedure TKeepingWindowService.Activate(const AForm: TCommonCustomForm);
begin
  FInner.Activate(AForm);
end;

{$WARN SYMBOL_DEPRECATED OFF}
function TKeepingWindowService.GetWindowScale(const AForm: TCommonCustomForm): Single;
begin
  Result := FInner.GetWindowScale(AForm);
end;
{$WARN SYMBOL_DEPRECATED ON}

function TKeepingWindowService.CanShowModal: Boolean;
begin
  Result := FInner.CanShowModal;
end;

procedure FastKeepInvalidated;
var
  Inner: IFMXWindowService;
begin
  if (GInvalidated <> nil) or
    not TPlatformServices.Current.SupportsPlatformService(IFMXWindowService, Inner) then
    Exit;
  GInvalidated := TDictionary<TWindowHandle, TArray<TRectF>>.Create;
  TPlatformServices.Current.RemovePlatformService(IFMXWindowService);
  TPlatformServices.Current.AddPlatformService(IFMXWindowService, TKeepingWindowService.Create(Inner));
end;

function FastTakeInvalidated(const AHandle: TWindowHandle; out ARects: TArray<TRectF>): Boolean;
begin
  ARects := nil;
  Result := (GInvalidated <> nil) and GInvalidated.TryGetValue(AHandle, ARects) and (Length(ARects) > 0);
  if GInvalidated <> nil then
    GInvalidated.Remove(AHandle);
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

function FastWindowOf(const AHandle: TWindowHandle): TGpuWindowHandle;
var
  Area, Window: Pointer;
begin
  Result := Default(TGpuWindowHandle);
  if not (AHandle is TLinuxWindowHandle) or not LoadGdk then
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
  Result := TSize.Create(Round(ALogicalWidth * AHandle.Scale), Round(ALogicalHeight * AHandle.Scale));
end;

procedure FastKeepInvalidated;
begin
end;

function FastTakeInvalidated(const AHandle: TWindowHandle; out ARects: TArray<TRectF>): Boolean;
begin
  ARects := nil;
  Result := False;
end;

{$ENDIF}

end.
