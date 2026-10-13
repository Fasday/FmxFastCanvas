unit FastCanvas.DCompExt;

{ The part of DirectComposition (dcomp.h, Windows 8.1+) that FastCanvas uses to show a swap chain in a window:
  a device, a target bound to the window and one visual whose content is the swap chain. The RTL has no
  DirectComposition unit. Translated from the Windows SDK header dcomp.h (10.0.22621), with the same rules as
  FastCanvas.D2D1Ext: the vtable order follows the header exactly; methods after the last one used here are left
  out (an interface may end early), methods before it keep their slot with simplified but ABI-compatible
  parameters and are never called (their C++ overloads share a name, so the second one of a pair gets a suffix). }

interface

uses
  Winapi.Windows;

type
  IDCompositionVisual = interface;

  /// <summary>Binds a visual tree to a window.</summary>
  IDCompositionTarget = interface(IUnknown)
    ['{eacdd04c-117e-4e17-88f4-d1b12b0e3d89}']
    function SetRoot(const visual: IDCompositionVisual): HResult; stdcall;
  end;

  IDCompositionVisual = interface(IUnknown)
    ['{4d93059d-097b-4651-9a60-f0f25116e2f3}']
    // Not called: slots 3..14.
    function SetOffsetX(const animation: IUnknown): HResult; stdcall;
    function SetOffsetX1(offsetX: Single): HResult; stdcall;
    function SetOffsetY(const animation: IUnknown): HResult; stdcall;
    function SetOffsetY1(offsetY: Single): HResult; stdcall;
    function SetTransform(matrix: Pointer): HResult; stdcall;
    function SetTransform1(const transform: IUnknown): HResult; stdcall;
    function SetTransformParent(const visual: IUnknown): HResult; stdcall;
    function SetEffect(const effect: IUnknown): HResult; stdcall;
    function SetBitmapInterpolationMode(interpolationMode: Integer): HResult; stdcall;
    function SetBorderMode(borderMode: Integer): HResult; stdcall;
    function SetClip(rect: Pointer): HResult; stdcall;
    function SetClip1(const clip: IUnknown): HResult; stdcall;
    /// <summary>A swap chain made by CreateSwapChainForComposition (or nil).</summary>
    function SetContent(const content: IUnknown): HResult; stdcall;
  end;

  IDCompositionDevice = interface(IUnknown)
    ['{C37EA93A-E7AA-450D-B16F-9746CB0407F3}']
    /// <summary>Applies the changes made since the last call.</summary>
    function Commit: HResult; stdcall;
    function WaitForCommitCompletion: HResult; stdcall;
    // Not called.
    function GetFrameStatistics(statistics: Pointer): HResult; stdcall;
    /// <summary>topmost: the visuals go above the window's child windows; False: below them.</summary>
    function CreateTargetForHwnd(hwnd: HWND; topmost: BOOL; out target: IDCompositionTarget): HResult; stdcall;
    function CreateVisual(out visual: IDCompositionVisual): HResult; stdcall;
  end;

{$WARN SYMBOL_PLATFORM OFF}
/// <summary>renderingDevice may be nil (no DirectComposition surfaces are made here, swap chains are made by DXGI);
/// iid: IDCompositionDevice (a version 2 device behind a version 1 interface). Loaded on first use.</summary>
function DCompositionCreateDevice2(const renderingDevice: IUnknown; const iid: TGUID; out dcompositionDevice): HResult;
  stdcall; external 'dcomp.dll' delayed;
{$WARN SYMBOL_PLATFORM DEFAULT}

implementation

end.
