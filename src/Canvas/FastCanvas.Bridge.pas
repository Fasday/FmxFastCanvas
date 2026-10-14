unit FastCanvas.Bridge;

{ What a 3D context needs from the installed FastCanvas canvas to run on the same Direct3D 11 device: the device
  and its immediate context, the lock that guards the context, the D3D11 texture behind a TBitmap of the canvas,
  and, while the canvas records for its render thread, a way to put Direct3D command lists into the command
  stream. The canvas that is installed fills FastBridge (FastCanvas.Canvas.InstallFastCanvas), the 3D context only talks to
  FastBridge.

  Deferred 3D work: while the canvas records (FastBridge.Recording), the 3D context records into a deferred
  context and sets FastDeferredPending. The canvas calls FastDeferredFlush before it records its next command
  and before it waits for the render thread, so the command list lands in the stream at the right place.

  Android and Linux: no Direct3D members; the rest (lock, the command stream, bitmap surfaces) is there for a 3D
  context on the Vulkan device. }

interface

uses
  System.SysUtils, {$IFDEF MSWINDOWS}Winapi.D3DCommon, Winapi.D3D11, {$ENDIF}FMX.Graphics;

type
  /// <summary>Executes a command recorded with FastBridge.RecordNative (AData: its payload).</summary>
  TFastNativeHandler = procedure(const AData: Pointer);

  TFastBridge = record
{$IFDEF MSWINDOWS}
    Device: function: ID3D11Device;
    ImmediateContext: function: ID3D11DeviceContext;
    FeatureLevel: function: D3D_FEATURE_LEVEL;
{$ENDIF}
    Hardware: function: Boolean;
    /// <summary>Guards the immediate context against the render thread and Direct2D.</summary>
    Lock: procedure;
    Unlock: procedure;
    /// <summary>Waits until the render thread has executed everything recorded so far.</summary>
    Sync: procedure;
    /// <summary>True when drawing on this thread is recorded for the render thread.</summary>
    Recording: function: Boolean;
{$IFDEF MSWINDOWS}
    /// <summary>Puts a command list (from a deferred context of the device) into the command stream.</summary>
    ExecuteCommandList: procedure(const AList: ID3D11CommandList);
    /// <summary>The texture of a TBitmap whose handle belongs to the canvas, else nil (Direct3D 11).</summary>
    BitmapTexture: function(const ABitmap: TBitmap): ID3D11Texture2D;
{$ENDIF}
    /// <summary>The handle object of a TBitmap of the canvas (FastCanvas.Gpu.IGpuTexture: the surface of any backend),
    /// else nil.</summary>
    BitmapSurface: function(const ABitmap: TBitmap): IInterface;
    /// <summary>The GPU wrote the texture of the bitmap (a later Map must read it again).</summary>
    BitmapWritten: procedure(const ABitmap: TBitmap);
    /// <summary>Set by the 3D context. The canvas is about to replace the device (after a removal): drop everything
    /// made on the old one. TContextLostMessage has been sent.</summary>
    DeviceLost: procedure;
    /// <summary>Set by the 3D context. The canvas has a new device; TContextResetMessage has been sent.</summary>
    DeviceReset: procedure;
    /// <summary>Set by the Direct3D 12 3D context: AForm is a TForm3D whose window it draws (and outputs in HDR as
    /// the canvas does the windows of 2D forms: FastCanvasHdrInfo).</summary>
    DrawsWindow: function(const AForm: TObject): Boolean;
    /// <summary>Runs AProc where the canvas executes its commands (render thread, or the recording thread), in stream
    /// order, with the device lock held and the canvas's own drawing so far submitted to the immediate context: the
    /// Direct3D 12 3D context executes its command lists and copies between its textures and canvas bitmaps here.
    /// </summary>
    RunOnRender: procedure(const AProc: TProc);
    /// <summary>A command of ASize bytes in the canvas command stream (the payload is returned for the caller to fill;
    /// AHandler executes it where the canvas executes its commands, after the canvas's own drawing so far, with the
    /// device lock held). ARef lives until the command has run. The caller holds TCanvas.Lock while it fills the
    /// payload.</summary>
    RecordNative: function(const AHandler: TFastNativeHandler; const ASize: Integer; const ARef: IInterface): Pointer;
    /// <summary>One more object that lives until the command recorded last has run.</summary>
    KeepAlive: procedure(const ARef: IInterface);
    /// <summary>In a native command's handler: the command after ACursor in the chunk being executed (ACursor nil: the
    /// one after the command running now), and ACursor moved past it. AHandler: its handler (AData its payload), nil
    /// for a command of the canvas. False at the end of the chunk (later commands are not known yet).</summary>
    NextCommand: function(var ACursor: Pointer; out AHandler: TFastNativeHandler; out AData: Pointer): Boolean;
  end;

  TFastFlushProc = procedure;

var
  FastBridge: TFastBridge;
  FastDeferredPending: Boolean;
  FastDeferredFlush: TFastFlushProc;

/// <summary>Called by the canvas: hands pending deferred 3D work to the command stream.</summary>
procedure FastFlushDeferred; inline;

implementation

procedure FastFlushDeferred;
begin
  if FastDeferredPending and Assigned(FastDeferredFlush) then
    FastDeferredFlush();
end;

end.
