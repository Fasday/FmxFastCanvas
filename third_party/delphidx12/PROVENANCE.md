# DelphiDX12 provenance

A subset of the Direct3D 12 / DXGI translations of DelphiDX12, vendored with a few local patches for Delphi 37
(Delphi 13) on Win64.

- Upstream: https://github.com/CMCHTPC/DelphiDX12
- Revision: `900c20e7be0d51c3543a9cd6c9afda788cd2429d`
- Revision date/tag: 2026-04-23, `1.619.2`
- Imported header baseline: Windows SDK `10.0.22621.0` from upstream `Historic/Units`. This is the latest
  Delphi-compatible set in the pinned revision and includes DXGI 1.6 plus DXR 1.1 (`ID3D12Device5`,
  `ID3D12GraphicsCommandList4`).
- License: Apache License 2.0 for the translation (`LICENSE.txt`), with the Microsoft MIT notices retained in the
  translated units.

## Imported scope

Only the D3D12/DXGI units FastCanvas needs, from upstream `Historic/Units`, under `src/`:

- `DX12.D3D12.pas`, `DX12.D3D12SDKLayers.pas`, `DX12.D3DCommon.pas`
- `DX12.DXGI.pas` and `DX12.DXGI1_2.pas` through `DX12.DXGI1_6.pas`

Samples, DirectXTK, audio, Direct2D, DirectML, DirectStorage and unrelated Win32 translations are not vendored.

## Local patches

Minimal; upstream copyright and license headers are kept.

- `DX12.DXGI.pas`: remove the duplicate local `HMONITOR = HANDLE` alias, because Delphi 37 already exposes
  `Winapi.Windows.HMONITOR`.
- `DX12.D3D12.pas`: keep two managed-record `Initialize` declarations FPC-only, translate FPC `constref` parameters
  to Delphi `const`, use `THANDLE`/`TGUID` for Delphi WinAPI types, and replace an invalid dynamic-array pointer cast
  with explicit descriptor-range pointer arithmetic. Correct the Win64 ABI layout of
  `D3D12_ROOT_PARAMETER`/`D3D12_ROOT_PARAMETER1`, and initialize the default rasterizer, blend and depth-stencil
  descriptors in Delphi builds instead of relying on FPC-only managed-record initializers. Pass CPU descriptor
  handles by value in device methods, matching the Win64 D3D12 ABI instead of Delphi `const` record-by-reference
  semantics. Match Delphi's official Win64 COM declarations for descriptor-handle and resource-desc aggregate returns
  by using `out` procedures rather than invalid function-result combinations.
- Every unit: `{$WARNINGS OFF}` and `{$HINTS OFF}` after its `unit` line (the translation produces W1012 subrange
  warnings in Delphi 37; the FastCanvas build is kept free of warnings).

Known layout issue, not patched: `DX12.D3D12SDKLayers` is compiled with `{$A4}`, so records with pointers
(`D3D12_MESSAGE`, `D3D12_INFO_QUEUE_FILTER_DESC`) do not have the C layout on Win64. `FastCanvas.Gpu12` uses its own
copies of these records.
