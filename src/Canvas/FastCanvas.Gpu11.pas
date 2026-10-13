unit FastCanvas.Gpu11;

{ Direct3D 11 backend of the FastCanvas renderer (FastCanvas.Gpu): textures, swap chains and the instanced
  pipeline on the immediate context of TFastDevice.

  The immediate context is shared with Direct2D (the D2DText measurement aid) and with the 3D context (command lists
  executed in the stream): after they used it, Invalidate makes the next draw set the whole pipeline state again. }

interface

uses
  Winapi.Windows, Winapi.D3D11, Winapi.D3DCommon, Winapi.DxgiFormat, Winapi.DXGI, Winapi.DXGI1_2, Winapi.DxgiType,
  System.SysUtils, System.Types, System.Math, FastCanvas.D2D1Ext, FastCanvas.Device, FastCanvas.Gpu;

type
  TGpu11Surface = class(TGpuSurface)
  private
    FTexture: ID3D11Texture2D;
    FView: ID3D11ShaderResourceView;
    FTarget: ID3D11RenderTargetView;
    FStaging: ID3D11Texture2D;
    /// <summary>The staging copy holds the current content (no GPU write since it was taken).</summary>
    FStagingValid: Boolean;
  public
    constructor Create(const AWidth, AHeight: Integer; const AData: Pointer; const APitch: Integer);
    /// <summary>A texture made elsewhere (a swap chain buffer): render target only.</summary>
    constructor CreateOver(const ATexture: ID3D11Texture2D; const AWidth, AHeight: Integer);
    function TargetView: ID3D11RenderTargetView;
    procedure Upload(const AData: Pointer; const APitch: Integer); override;
    function Map(out AData: Pointer; out APitch: Integer): Boolean; override;
    procedure Unmap(const AWritten: Boolean); override;
    procedure CopyFrom(const ASource: TGpuSurface); override;
    procedure GpuWritten; override;
    property Texture: ID3D11Texture2D read FTexture;
    property View: ID3D11ShaderResourceView read FView;
  end;

  TGpu11Window = class(TGpuWindow)
  private
    FSwapChain: IDXGISwapChain1;
    /// <summary>The swap chain presents with tearing allowed; what the canvas asked for (the swap chain is made again
    /// when that changes).</summary>
    FTearing, FTearingAsked: Boolean;
    /// <summary>The swap chain is a composition one, shown by FComposition.</summary>
    FComposed: Boolean;
    FComposition: TGpuComposition;
    FWidth, FHeight: Integer;
    /// <summary>The back buffer (flip model under Direct3D 11: buffer 0 is always the current one), or the texture of a
    /// layered window.</summary>
    FBuffer: TGpu11Surface;
    FStaging: ID3D11Texture2D;
    procedure ReleaseBuffers;
  public
    destructor Destroy; override;
    /// <summary>Direct3D 11 outputs SDR only: AOutput.Hdr is not taken.</summary>
    function Prepare(const AWidth, AHeight: Integer; const ATearing: Boolean; const AOutput: TGpuOutput): TGpuSurface;
      override;
    function Present: HResult; override;
    procedure ReadPixels(const ABits: Pointer; const AWidth, AHeight: Integer); override;
  end;

  TGpu11Renderer = class(TGpuRenderer)
  private
    FVS: ID3D11VertexShader;
    FPS: ID3D11PixelShader;
    FLayout: ID3D11InputLayout;
    FBlend: ID3D11BlendState;
    FBlendCopy: ID3D11BlendState;
    FRaster: ID3D11RasterizerState;
    FSamplers: array[0..2] of ID3D11SamplerState;
    FFrameCB: ID3D11Buffer;
    FVB: ID3D11Buffer;
    FVBSize, FVBPos: Integer;
    FClipBuf, FPaintBuf, FEdgeBuf: ID3D11Buffer;
    FRamps, FAtlas: ID3D11Texture2D;
    // t0..t7 the slot textures, t8 atlas, t9 ramps, t10 clips, t11 paints, t12 edges.
    FViews: array[0..12] of ID3D11ShaderResourceView;
    FStateApplied: Boolean;
    procedure CreatePipeline;
    procedure ApplyState;
    procedure UploadTables;
  protected
    procedure DrawPending; override;
    procedure UploadEdgeRange; override;
    procedure CreateEdgeTable(const ACapacity: Integer); override;
  public
    constructor Create;
    procedure BeginTarget(const ATarget: TGpuSurface; const AWidth, AHeight: Integer;
      const AAliased: Boolean); override;
    procedure Flush; override;
    procedure Invalidate; override;
    procedure Clear(const AColor: Cardinal); override;
    procedure FillCopy(const ARect: TRectF; const AColor: Cardinal; const AClip: Cardinal); override;
    procedure UploadRamp(const ARow: Integer; const AData: Pointer); override;
    procedure UploadGlyph(const X, Y, W, H: Integer; const AData: Pointer; const APitch: Integer); override;
  end;

  TGpu11Backend = class(TGpuBackend)
  public
    class function CreateRenderer: TGpuRenderer; override;
    class function CreateSurface(const AWidth, AHeight: Integer; const AData: Pointer;
      const APitch: Integer): TGpuSurface; override;
    class function CreateWindow(const AWnd: HWND; const ALayered: Boolean): TGpuWindow; override;
    class procedure WaitIdle; override;
  end;

implementation

{$I FastCanvas.Shaders.inc}

var
  GZero: TBytes;
  GZeroLock: TObject;

{ TGpu11Surface }

constructor TGpu11Surface.Create(const AWidth, AHeight: Integer; const AData: Pointer; const APitch: Integer);
var
  Desc: TD3D11_TEXTURE2D_DESC;
  Init: D3D11_SUBRESOURCE_DATA;
  Res: HResult;
begin
  inherited Create;
  FWidth := AWidth;
  FHeight := AHeight;
  if TFastDevice.D3D = nil then
    raise EFastDevice.Create('FastCanvas: no Direct3D 11 device');
  FillChar(Desc, SizeOf(Desc), 0);
  Desc.Width := AWidth;
  Desc.Height := AHeight;
  Desc.MipLevels := 1;
  Desc.ArraySize := 1;
  Desc.Format := DXGI_FORMAT_B8G8R8A8_UNORM;
  Desc.SampleDesc.Count := 1;
  Desc.Usage := D3D11_USAGE_DEFAULT;
  Desc.BindFlags := D3D11_BIND_SHADER_RESOURCE or D3D11_BIND_RENDER_TARGET;
  Init.SysMemSlicePitch := 0;
  if AData <> nil then
  begin
    Init.pSysMem := AData;
    Init.SysMemPitch := APitch;
    Res := TFastDevice.D3D.CreateTexture2D(Desc, @Init, FTexture);
  end
  else
  begin
    // A new bitmap is transparent black.
    TMonitor.Enter(GZeroLock);
    try
      if Length(GZero) < AWidth * 4 * AHeight then
        SetLength(GZero, AWidth * 4 * AHeight);
      Init.pSysMem := @GZero[0];
      Init.SysMemPitch := AWidth * 4;
      Res := TFastDevice.D3D.CreateTexture2D(Desc, @Init, FTexture);
    finally
      TMonitor.Exit(GZeroLock);
    end;
  end;
  if Failed(Res) then
    raise EFastDevice.CreateFmt('FastCanvas: cannot create a %dx%d bitmap (0x%.8x)', [AWidth, AHeight, Cardinal(Res)]);
  GpuCheck(TFastDevice.D3D.CreateShaderResourceView(FTexture, nil, FView), 'CreateShaderResourceView');
end;

constructor TGpu11Surface.CreateOver(const ATexture: ID3D11Texture2D; const AWidth, AHeight: Integer);
begin
  inherited Create;
  FWidth := AWidth;
  FHeight := AHeight;
  FTexture := ATexture;
end;

function TGpu11Surface.TargetView: ID3D11RenderTargetView;
begin
  if (FTarget = nil) and (FTexture <> nil) then
    TFastDevice.D3D.CreateRenderTargetView(FTexture, nil, FTarget);
  Result := FTarget;
end;

procedure TGpu11Surface.GpuWritten;
begin
  FStagingValid := False;
end;

procedure TGpu11Surface.Upload(const AData: Pointer; const APitch: Integer);
begin
  TFastDevice.Context.UpdateSubresource(FTexture, 0, nil, AData, APitch, 0);
  FStagingValid := False;
end;

function TGpu11Surface.Map(out AData: Pointer; out APitch: Integer): Boolean;
var
  Desc: TD3D11_TEXTURE2D_DESC;
  Mapped: D3D11_MAPPED_SUBRESOURCE;
begin
  Result := False;
  AData := nil;
  APitch := 0;
  if FStaging = nil then
  begin
    FTexture.GetDesc(Desc);
    Desc.Usage := D3D11_USAGE_STAGING;
    Desc.BindFlags := 0;
    Desc.CPUAccessFlags := D3D11_CPU_ACCESS_READ or D3D11_CPU_ACCESS_WRITE;
    Desc.MiscFlags := 0;
    if Failed(TFastDevice.D3D.CreateTexture2D(Desc, nil, FStaging)) then
      Exit;
    FStagingValid := False;
  end;
  if not FStagingValid then
  begin
    TFastDevice.Context.CopyResource(FStaging, FTexture);
    FStagingValid := True;
  end;
  if Succeeded(TFastDevice.Context.Map(FStaging, 0, D3D11_MAP_READ_WRITE, 0, Mapped)) then
  begin
    AData := Mapped.pData;
    APitch := Mapped.RowPitch;
    Result := True;
  end;
end;

procedure TGpu11Surface.Unmap(const AWritten: Boolean);
begin
  TFastDevice.Context.Unmap(FStaging, 0);
  if AWritten then
    TFastDevice.Context.CopyResource(FTexture, FStaging);
end;

procedure TGpu11Surface.CopyFrom(const ASource: TGpuSurface);
begin
  TFastDevice.Context.CopyResource(FTexture, TGpu11Surface(ASource).FTexture);
  FStagingValid := False;
end;

{ TGpu11Window }

destructor TGpu11Window.Destroy;
begin
  ReleaseBuffers;
  // The visual lets go of the swap chain and the window of the target.
  FreeAndNil(FComposition);
  FSwapChain := nil;
  inherited;
end;

procedure TGpu11Window.ReleaseBuffers;
begin
  FreeAndNil(FBuffer);
  FStaging := nil;
end;

function TGpu11Window.Prepare(const AWidth, AHeight: Integer; const ATearing: Boolean;
  const AOutput: TGpuOutput): TGpuSurface;
var
  Desc: TDXGISwapChainDesc1;
  Tex: TD3D11_TEXTURE2D_DESC;
  Flags: Cardinal;
  Res: HResult;
  Texture: ID3D11Texture2D;
  D3D: ID3D11Device;
  Fresh: Boolean;
begin
  D3D := TFastDevice.D3D;
  if FLayered then
  begin
    if (FBuffer <> nil) and ((AWidth <> FWidth) or (AHeight <> FHeight)) then
      ReleaseBuffers;
    if FBuffer = nil then
    begin
      FillChar(Tex, SizeOf(Tex), 0);
      Tex.Width := AWidth;
      Tex.Height := AHeight;
      Tex.MipLevels := 1;
      Tex.ArraySize := 1;
      Tex.Format := DXGI_FORMAT_B8G8R8A8_UNORM;
      Tex.SampleDesc.Count := 1;
      Tex.Usage := D3D11_USAGE_DEFAULT;
      Tex.BindFlags := D3D11_BIND_RENDER_TARGET or D3D11_BIND_SHADER_RESOURCE;
      GpuCheck(D3D.CreateTexture2D(Tex, nil, Texture), 'CreateTexture2D (layered window)');
      Tex.Usage := D3D11_USAGE_STAGING;
      Tex.BindFlags := 0;
      Tex.CPUAccessFlags := D3D11_CPU_ACCESS_READ;
      GpuCheck(D3D.CreateTexture2D(Tex, nil, FStaging), 'CreateTexture2D (layered window copy)');
      FBuffer := TGpu11Surface.CreateOver(Texture, AWidth, AHeight);
    end;
  end
  else
  begin
    if (FSwapChain <> nil) and ((ATearing <> FTearingAsked) or (AOutput.Composition <> FComposed)) then
    begin
      // A window takes a new flip-model swap chain only when the old one is gone.
      ReleaseBuffers;
      TFastDevice.Context.OMSetRenderTargets(0, nil, nil);
      if FComposition <> nil then
        FComposition.SetContent(nil);
      FSwapChain := nil;
      TFastDevice.Context.Flush;
    end;
    Fresh := False;
    if (FSwapChain <> nil) and ((AWidth <> FWidth) or (AHeight <> FHeight)) then
    begin
      // ResizeBuffers needs every reference to the buffers gone, bound views included.
      ReleaseBuffers;
      Fresh := True;
      TFastDevice.Context.OMSetRenderTargets(0, nil, nil);
      if FTearing then
        Flags := DXGI_SWAP_CHAIN_FLAG_ALLOW_TEARING
      else
        Flags := 0;
      if Failed(FSwapChain.ResizeBuffers(0, AWidth, AHeight, DXGI_FORMAT_UNKNOWN, Flags)) then
      begin
        FSwapChain := nil;
        TFastDevice.Context.Flush;
      end;
    end;
    if FSwapChain = nil then
    begin
      FillChar(Desc, SizeOf(Desc), 0);
      Desc.Width := AWidth;
      Desc.Height := AHeight;
      Desc.Format := DXGI_FORMAT_B8G8R8A8_UNORM;
      Desc.SampleDesc.Count := 1;
      Desc.BufferUsage := DXGI_USAGE_RENDER_TARGET_OUTPUT;
      Desc.BufferCount := 2;
      Desc.Scaling := DXGI_SCALING_STRETCH;
      Desc.SwapEffect := DXGI_SWAP_EFFECT_FLIP_DISCARD;
      FTearingAsked := ATearing;
      FComposed := AOutput.Composition;
      Fresh := True;
      if FComposed then
      begin
        if FComposition = nil then
          FComposition := TGpuComposition.Create;
        if not FComposition.Bind(FWnd) then
        begin
          FreeAndNil(FComposition);
          FComposed := False;
        end;
      end
      else
        FreeAndNil(FComposition);
      if FComposed then
      begin
        // The frame's alpha (premultiplied, as the canvas draws) decides what shows through. Tearing is for swap
        // chains of a window only.
        Desc.AlphaMode := DXGI_ALPHA_MODE_PREMULTIPLIED;
        FTearing := False;
        Res := TFastDevice.DXGIFactory.CreateSwapChainForComposition(D3D, @Desc, nil, FSwapChain);
      end
      else
      begin
        Desc.AlphaMode := DXGI_ALPHA_MODE_IGNORE;
        FTearing := ATearing and TFastDevice.TearingSupported;
        if FTearing then
          Desc.Flags := DXGI_SWAP_CHAIN_FLAG_ALLOW_TEARING;
        Res := TFastDevice.DXGIFactory.CreateSwapChainForHwnd(D3D, FWnd, @Desc, nil, nil, FSwapChain);
      end;
      if Failed(Res) then
        raise EFastDevice.CreateFmt('FastCanvas: cannot create the swap chain (0x%.8x)', [Cardinal(Res)]);
      if FComposed then
        FComposition.SetContent(FSwapChain)
      else
        TFastDevice.DXGIFactory.MakeWindowAssociation(FWnd, DXGI_MWA_NO_WINDOW_CHANGES);
    end;
    if FBuffer = nil then
    begin
      GpuCheck(FSwapChain.GetBuffer(0, ID3D11Texture2D, Texture), 'GetBuffer');
      FBuffer := TGpu11Surface.CreateOver(Texture, AWidth, AHeight);
    end;
    if FComposed and Fresh then
      // A new or resized window: its own surface under the visual is white or undefined.
      TGpuComposition.ClearWindow(FWnd);
  end;
  FWidth := AWidth;
  FHeight := AHeight;
  Result := FBuffer;
end;

function TGpu11Window.Present: HResult;
var
  Flags: Cardinal;
begin
  if FSwapChain = nil then
    Exit(S_OK);
  Flags := 0;
  if FTearing then
    Flags := DXGI_PRESENT_ALLOW_TEARING;
  Result := FSwapChain.Present(0, Flags);
end;

procedure TGpu11Window.ReadPixels(const ABits: Pointer; const AWidth, AHeight: Integer);
var
  Mapped: D3D11_MAPPED_SUBRESOURCE;
  I: Integer;
begin
  if (FStaging = nil) or (FBuffer = nil) then
    Exit;
  TFastDevice.Context.CopyResource(FStaging, FBuffer.Texture);
  if Succeeded(TFastDevice.Context.Map(FStaging, 0, D3D11_MAP_READ, 0, Mapped)) then
  try
    for I := 0 to Min(AHeight, FHeight) - 1 do
      Move((PByte(Mapped.pData) + Cardinal(I) * Mapped.RowPitch)^, (PByte(ABits) + I * AWidth * 4)^,
        Min(AWidth, FWidth) * 4);
  finally
    TFastDevice.Context.Unmap(FStaging, 0);
  end;
end;

{ TGpu11Renderer }

constructor TGpu11Renderer.Create;
begin
  inherited Create;
  CreatePipeline;
end;

procedure TGpu11Renderer.CreatePipeline;
var
  D3D: ID3D11Device;
  Elements: array[0..5] of D3D11_INPUT_ELEMENT_DESC;
  Blend: D3D11_BLEND_DESC;
  Raster: D3D11_RASTERIZER_DESC;
  Sampler: D3D11_SAMPLER_DESC;
  Buf: TD3D11_BUFFER_DESC;
  Tex: TD3D11_TEXTURE2D_DESC;
  View: D3D11_SHADER_RESOURCE_VIEW_DESC;
  I: Integer;

  procedure Element(const AIndex: Integer; const AName: PAnsiChar; const AFormat: DXGI_FORMAT; const AOffset: Cardinal);
  begin
    Elements[AIndex].SemanticName := AName;
    Elements[AIndex].SemanticIndex := 0;
    Elements[AIndex].Format := AFormat;
    Elements[AIndex].InputSlot := 0;
    Elements[AIndex].AlignedByteOffset := AOffset;
    Elements[AIndex].InputSlotClass := D3D11_INPUT_PER_INSTANCE_DATA;
    Elements[AIndex].InstanceDataStepRate := 1;
  end;

  function TableBuffer(const AFloat4s: Integer): ID3D11Buffer;
  begin
    FillChar(Buf, SizeOf(Buf), 0);
    Buf.ByteWidth := AFloat4s * 16;
    Buf.Usage := D3D11_USAGE_DEFAULT;
    Buf.BindFlags := D3D11_BIND_SHADER_RESOURCE;
    GpuCheck(D3D.CreateBuffer(Buf, nil, Result), 'CreateBuffer (table)');
  end;

  function TableView(const ABuffer: ID3D11Buffer; const AFloat4s: Integer): ID3D11ShaderResourceView;
  begin
    FillChar(View, SizeOf(View), 0);
    View.Format := DXGI_FORMAT_R32G32B32A32_FLOAT;
    View.ViewDimension := D3D11_SRV_DIMENSION_BUFFER;
    View.Buffer.FirstElement := 0;
    View.Buffer.NumElements := AFloat4s;
    GpuCheck(D3D.CreateShaderResourceView(ABuffer, @View, Result), 'CreateShaderResourceView (table)');
  end;

  function Texture(const AWidth, AHeight: Integer; const AFormat: DXGI_FORMAT; out AView: ID3D11ShaderResourceView): ID3D11Texture2D;
  begin
    FillChar(Tex, SizeOf(Tex), 0);
    Tex.Width := AWidth;
    Tex.Height := AHeight;
    Tex.MipLevels := 1;
    Tex.ArraySize := 1;
    Tex.Format := AFormat;
    Tex.SampleDesc.Count := 1;
    Tex.Usage := D3D11_USAGE_DEFAULT;
    Tex.BindFlags := D3D11_BIND_SHADER_RESOURCE;
    GpuCheck(D3D.CreateTexture2D(Tex, nil, Result), 'CreateTexture2D');
    GpuCheck(D3D.CreateShaderResourceView(Result, nil, AView), 'CreateShaderResourceView');
  end;

begin
  D3D := TFastDevice.D3D;
  GpuCheck(D3D.CreateVertexShader(@FastCanvasVS[0], Length(FastCanvasVS), nil, @FVS), 'CreateVertexShader');
  GpuCheck(D3D.CreatePixelShader(@FastCanvasPS[0], Length(FastCanvasPS), nil, FPS), 'CreatePixelShader');
  Element(0, 'RECT', DXGI_FORMAT_R32G32B32A32_FLOAT, 0);
  Element(1, 'XFORM', DXGI_FORMAT_R32G32B32A32_FLOAT, 16);
  Element(2, 'XLATE', DXGI_FORMAT_R32G32B32A32_FLOAT, 32);
  Element(3, 'UVRECT', DXGI_FORMAT_R32G32B32A32_FLOAT, 48);
  Element(4, 'DATA', DXGI_FORMAT_R32G32B32A32_UINT, 64);
  Element(5, 'STROKE', DXGI_FORMAT_R32_FLOAT, 80);
  GpuCheck(D3D.CreateInputLayout(@Elements[0], Length(Elements), @FastCanvasVS[0], Length(FastCanvasVS), FLayout),
    'CreateInputLayout');

  // Premultiplied alpha: result = source + destination * (1 - source alpha).
  FillChar(Blend, SizeOf(Blend), 0);
  Blend.RenderTarget[0].BlendEnable := True;
  Blend.RenderTarget[0].SrcBlend := D3D11_BLEND_ONE;
  Blend.RenderTarget[0].DestBlend := D3D11_BLEND_INV_SRC_ALPHA;
  Blend.RenderTarget[0].BlendOp := D3D11_BLEND_OP_ADD;
  Blend.RenderTarget[0].SrcBlendAlpha := D3D11_BLEND_ONE;
  Blend.RenderTarget[0].DestBlendAlpha := D3D11_BLEND_INV_SRC_ALPHA;
  Blend.RenderTarget[0].BlendOpAlpha := D3D11_BLEND_OP_ADD;
  Blend.RenderTarget[0].RenderTargetWriteMask := Byte(D3D11_COLOR_WRITE_ENABLE_ALL);
  GpuCheck(D3D.CreateBlendState(Blend, FBlend), 'CreateBlendState');
  Blend.RenderTarget[0].BlendEnable := False;
  GpuCheck(D3D.CreateBlendState(Blend, FBlendCopy), 'CreateBlendState (copy)');

  FillChar(Raster, SizeOf(Raster), 0);
  Raster.FillMode := D3D11_FILL_SOLID;
  Raster.CullMode := D3D11_CULL_NONE;
  Raster.DepthClipEnable := True;
  GpuCheck(D3D.CreateRasterizerState(Raster, FRaster), 'CreateRasterizerState');

  // s0 linear clamp, s1 point clamp, s2 linear wrap (bitmap brushes in tile mode).
  for I := 0 to 2 do
  begin
    FillChar(Sampler, SizeOf(Sampler), 0);
    if I = 1 then
      Sampler.Filter := D3D11_FILTER_MIN_MAG_MIP_POINT
    else
      Sampler.Filter := D3D11_FILTER_MIN_MAG_MIP_LINEAR;
    if I = 2 then
    begin
      Sampler.AddressU := D3D11_TEXTURE_ADDRESS_WRAP;
      Sampler.AddressV := D3D11_TEXTURE_ADDRESS_WRAP;
    end
    else
    begin
      Sampler.AddressU := D3D11_TEXTURE_ADDRESS_CLAMP;
      Sampler.AddressV := D3D11_TEXTURE_ADDRESS_CLAMP;
    end;
    Sampler.AddressW := D3D11_TEXTURE_ADDRESS_CLAMP;
    Sampler.MaxAnisotropy := 1;
    Sampler.ComparisonFunc := D3D11_COMPARISON_NEVER;
    Sampler.MaxLOD := D3D11_FLOAT32_MAX;
    GpuCheck(D3D.CreateSamplerState(Sampler, FSamplers[I]), 'CreateSamplerState');
  end;

  FillChar(Buf, SizeOf(Buf), 0);
  Buf.ByteWidth := SizeOf(TGpuFrameConstants);
  Buf.Usage := D3D11_USAGE_DEFAULT;
  Buf.BindFlags := D3D11_BIND_CONSTANT_BUFFER;
  GpuCheck(D3D.CreateBuffer(Buf, nil, FFrameCB), 'CreateBuffer (constants)');

  FClipBuf := TableBuffer(GpuMaxClips * GpuClipFloat4s);
  FViews[10] := TableView(FClipBuf, GpuMaxClips * GpuClipFloat4s);
  FPaintBuf := TableBuffer(GpuMaxPaints * GpuPaintFloat4s);
  FViews[11] := TableView(FPaintBuf, GpuMaxPaints * GpuPaintFloat4s);
  CreateEdgeTable(GpuEdgesInitial);
  FAtlas := Texture(GpuAtlasSize, GpuAtlasSize, DXGI_FORMAT_R8_UNORM, FViews[8]);
  FRamps := Texture(GpuRampWidth, GpuRampRows, DXGI_FORMAT_R8G8B8A8_UNORM, FViews[9]);
end;

procedure TGpu11Renderer.Invalidate;
begin
  FStateApplied := False;
end;

procedure TGpu11Renderer.ApplyState;
const
  Factor: TFourSingleArray = (1, 1, 1, 1);
var
  Ctx: ID3D11DeviceContext;
  Viewport: D3D11_VIEWPORT;
  Stride, Offset: Cardinal;
  Constants: TGpuFrameConstants;
begin
  Ctx := TFastDevice.Context;
  if FFrameDirty then
  begin
    Constants := FrameConstants;
    Ctx.UpdateSubresource(FFrameCB, 0, nil, @Constants, 0, 0);
    FFrameDirty := False;
  end;
  if FStateApplied then
    Exit;
  Ctx.OMSetRenderTargets(1, TGpu11Surface(FTarget).TargetView, nil);
  Viewport.TopLeftX := 0;
  Viewport.TopLeftY := 0;
  Viewport.Width := FWidth;
  Viewport.Height := FHeight;
  Viewport.MinDepth := 0;
  Viewport.MaxDepth := 1;
  Ctx.RSSetViewports(1, @Viewport);
  Ctx.RSSetState(FRaster);
  Ctx.OMSetBlendState(FBlend, Factor, $FFFFFFFF);
  Ctx.OMSetDepthStencilState(nil, 0);
  Ctx.IASetInputLayout(FLayout);
  Ctx.IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP);
  Stride := GpuInstanceStride;
  Offset := 0;
  Ctx.IASetVertexBuffers(0, 1, FVB, @Stride, @Offset);
  Ctx.VSSetShader(FVS, nil, 0);
  Ctx.GSSetShader(nil, nil, 0);
  Ctx.PSSetShader(FPS, nil, 0);
  Ctx.VSSetConstantBuffers(0, 1, FFrameCB);
  Ctx.PSSetConstantBuffers(0, 1, FFrameCB);
  Ctx.PSSetSamplers(0, Length(FSamplers), FSamplers[0]);
  Ctx.PSSetShaderResources(0, Length(FViews), FViews[0]);
  FStateApplied := True;
end;

procedure TGpu11Renderer.BeginTarget(const ATarget: TGpuSurface; const AWidth, AHeight: Integer;
  const AAliased: Boolean);
begin
  if (ATarget = FTarget) and (AWidth = FWidth) and (AHeight = FHeight) and (AAliased = FAliased) then
    Exit;
  inherited;
  FStateApplied := False;
  if ATarget = nil then
    // The renderer must not keep a view of buffers that are about to be resized.
    TFastDevice.Context.OMSetRenderTargets(0, nil, nil);
end;

procedure TGpu11Renderer.UploadTables;
var
  Ctx: ID3D11DeviceContext;
  Box: D3D11_BOX;
  Data: PSingle;
  First, Count: Integer;
begin
  Ctx := TFastDevice.Context;
  Box.top := 0;
  Box.bottom := 1;
  Box.front := 0;
  Box.back := 1;
  Data := TakeClips(First, Count);
  if Count > 0 then
  begin
    Box.left := First * GpuClipFloat4s * 16;
    Box.right := (First + Count) * GpuClipFloat4s * 16;
    Ctx.UpdateSubresource(FClipBuf, 0, @Box, Data, 0, 0);
  end;
  UploadEdgeRange;
  if TakePaints(First, Count) then
  begin
    Box.left := First * GpuPaintFloat4s * 16;
    Box.right := (First + Count) * GpuPaintFloat4s * 16;
    Ctx.UpdateSubresource(FPaintBuf, 0, @Box, @FPaintData[First], 0, 0);
  end;
end;

procedure TGpu11Renderer.DrawPending;
var
  Ctx: ID3D11DeviceContext;
  Bytes: Integer;
  Buf: TD3D11_BUFFER_DESC;
  Mapped: D3D11_MAPPED_SUBRESOURCE;
  MapType: D3D11_MAP;
  Start, I: Integer;
  S: TGpuSurface;
begin
  if (FPendingCount = 0) or (FTarget = nil) then
  begin
    FPendingCount := 0;
    Exit;
  end;
  Ctx := TFastDevice.Context;
  UploadTables;
  Bytes := FPendingCount * GpuInstanceStride;
  if Bytes > FVBSize then
  begin
    FVB := nil;
    FVBSize := Max(Bytes, Max(4 * 1024 * 1024, 2 * FVBSize));
    FillChar(Buf, SizeOf(Buf), 0);
    Buf.ByteWidth := FVBSize;
    Buf.Usage := D3D11_USAGE_DYNAMIC;
    Buf.BindFlags := D3D11_BIND_VERTEX_BUFFER;
    Buf.CPUAccessFlags := D3D11_CPU_ACCESS_WRITE;
    GpuCheck(TFastDevice.D3D.CreateBuffer(Buf, nil, FVB), 'CreateBuffer (instances)');
    FVBPos := FVBSize;
    FStateApplied := False;
  end;
  if FVBPos + Bytes > FVBSize then
  begin
    MapType := D3D11_MAP_WRITE_DISCARD;
    FVBPos := 0;
  end
  else
    MapType := D3D11_MAP_WRITE_NO_OVERWRITE;
  GpuCheck(Ctx.Map(FVB, 0, MapType, 0, Mapped), 'Map (instances)');
  Move(FPending[0], PByte(Mapped.pData)[FVBPos], Bytes);
  Ctx.Unmap(FVB, 0);
  ApplyState;
  if FSlotCount > 0 then
  begin
    for I := 0 to FSlotCount - 1 do
    begin
      S := IGpuTexture(FSlotTex[I]).Surface;
      if (S <> nil) and (S <> FTarget) then
        FViews[I] := TGpu11Surface(S).View
      else
        FViews[I] := nil;
    end;
    Ctx.PSSetShaderResources(0, FSlotCount, FViews[0]);
  end;
  Start := FVBPos div GpuInstanceStride;
  Ctx.DrawInstanced(4, FPendingCount, 0, Start);
  Inc(FDrawCalls);
  // Next run starts on an instance boundary of the same stride.
  FVBPos := (Start + FPendingCount) * GpuInstanceStride;
  FPendingCount := 0;
end;

procedure TGpu11Renderer.Flush;
var
  I: Integer;
begin
  inherited;
  for I := 0 to GpuSlotCount - 1 do
    FViews[I] := nil;
end;

procedure TGpu11Renderer.Clear(const AColor: Cardinal);
var
  C: TFourSingleArray;
begin
  Flush;
  if FTarget = nil then
    Exit;
  // The target holds premultiplied colors.
  C[3] := (AColor shr 24) / 255;
  C[0] := ((AColor shr 16) and $FF) / 255 * C[3];
  C[1] := ((AColor shr 8) and $FF) / 255 * C[3];
  C[2] := (AColor and $FF) / 255 * C[3];
  TFastDevice.Context.ClearRenderTargetView(TGpu11Surface(FTarget).TargetView, C);
end;

procedure TGpu11Renderer.FillCopy(const ARect: TRectF; const AColor: Cardinal; const AClip: Cardinal);
const
  Factor: TFourSingleArray = (1, 1, 1, 1);
var
  I: TGpuInstance;
begin
  Flush;
  if FTarget = nil then
    Exit;
  FillChar(I, SizeOf(I), 0);
  I.X0 := ARect.Left;
  I.Y0 := ARect.Top;
  I.X1 := ARect.Right;
  I.Y1 := ARect.Bottom;
  I.M11 := 1;
  I.M22 := 1;
  I.Color := AColor;
  I.Flags := GpuKindSolid;
  I.Clip := AClip;
  Add(@I, 1);
  ApplyState;
  TFastDevice.Context.OMSetBlendState(FBlendCopy, Factor, $FFFFFFFF);
  DrawPending;
  TFastDevice.Context.OMSetBlendState(FBlend, Factor, $FFFFFFFF);
end;

procedure TGpu11Renderer.UploadRamp(const ARow: Integer; const AData: Pointer);
var
  Box: D3D11_BOX;
begin
  Box.left := 0;
  Box.right := GpuRampWidth;
  Box.top := ARow;
  Box.bottom := ARow + 1;
  Box.front := 0;
  Box.back := 1;
  TFastDevice.Context.UpdateSubresource(FRamps, 0, @Box, AData, GpuRampWidth * 4, 0);
end;

procedure TGpu11Renderer.CreateEdgeTable(const ACapacity: Integer);
var
  Buf: TD3D11_BUFFER_DESC;
  View: D3D11_SHADER_RESOURCE_VIEW_DESC;
begin
  FViews[12] := nil;
  FEdgeBuf := nil;
  FillChar(Buf, SizeOf(Buf), 0);
  Buf.ByteWidth := ACapacity * 16;
  Buf.Usage := D3D11_USAGE_DEFAULT;
  Buf.BindFlags := D3D11_BIND_SHADER_RESOURCE;
  GpuCheck(TFastDevice.D3D.CreateBuffer(Buf, nil, FEdgeBuf), 'CreateBuffer (edges)');
  FillChar(View, SizeOf(View), 0);
  View.Format := DXGI_FORMAT_R32G32B32A32_FLOAT;
  View.ViewDimension := D3D11_SRV_DIMENSION_BUFFER;
  View.Buffer.FirstElement := 0;
  View.Buffer.NumElements := ACapacity;
  GpuCheck(TFastDevice.D3D.CreateShaderResourceView(FEdgeBuf, @View, FViews[12]), 'CreateShaderResourceView (edges)');
  FEdgeCapacity := ACapacity;
  FEdgeLo := 0;
  FEdgeHi := 0;
  FStateApplied := False;
end;

procedure TGpu11Renderer.UploadEdgeRange;
var
  Box: D3D11_BOX;
begin
  if FEdgeHi <= FEdgeLo then
    Exit;
  Box.left := FEdgeLo * 16;
  Box.right := FEdgeHi * 16;
  Box.top := 0;
  Box.bottom := 1;
  Box.front := 0;
  Box.back := 1;
  TFastDevice.Context.UpdateSubresource(FEdgeBuf, 0, @Box, @FEdgeData[0], 0, 0);
  FEdgeLo := 0;
  FEdgeHi := 0;
end;

procedure TGpu11Renderer.UploadGlyph(const X, Y, W, H: Integer; const AData: Pointer; const APitch: Integer);
var
  Box: D3D11_BOX;
begin
  if (W <= 0) or (H <= 0) then
    Exit;
  Box.left := X;
  Box.right := X + W;
  Box.top := Y;
  Box.bottom := Y + H;
  Box.front := 0;
  Box.back := 1;
  TFastDevice.Context.UpdateSubresource(FAtlas, 0, @Box, AData, APitch, 0);
end;

{ TGpu11Backend }

class function TGpu11Backend.CreateRenderer: TGpuRenderer;
begin
  Result := TGpu11Renderer.Create;
end;

class function TGpu11Backend.CreateSurface(const AWidth, AHeight: Integer; const AData: Pointer;
  const APitch: Integer): TGpuSurface;
begin
  Result := TGpu11Surface.Create(AWidth, AHeight, AData, APitch);
end;

class function TGpu11Backend.CreateWindow(const AWnd: HWND; const ALayered: Boolean): TGpuWindow;
begin
  Result := TGpu11Window.Create(AWnd, ALayered);
end;

class procedure TGpu11Backend.WaitIdle;
begin
  // Direct3D 11 keeps what the GPU still uses alive itself.
  if TFastDevice.Context <> nil then
    TFastDevice.Context.Flush;
end;

initialization
  GZeroLock := TObject.Create;
finalization
  GZeroLock.Free;
end.
