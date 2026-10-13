# Third-party notices

FastCanvas is MIT-licensed (`LICENSE`). It includes or adapts the following third-party work.

## DelphiDX12 (Apache License 2.0)

`third_party/delphidx12`: Delphi translations of the Direct3D 12 and DXGI headers, a subset vendored with local
patches (`third_party/delphidx12/PROVENANCE.md`).

- Upstream: https://github.com/CMCHTPC/DelphiDX12
- Copyright (C) 2013-2025 Norbert Sonnleitner; Microsoft notices retained in the translated units.
- License: Apache License, Version 2.0 (`third_party/delphidx12/LICENSE.txt`).

## Microsoft Terminal (MIT License)

The grayscale text blending of the canvas (`src/Canvas/Shaders/FastCanvas.hlsl`, function `TextAlpha`, and
`TGpuRenderer.ReadTextParameters` in `src/Canvas/FastCanvas.Gpu.pas`) follows the formulas of
`src/renderer/atlas/dwrite_helpers.hlsl` and `dwrite_helpers.cpp` of Microsoft Terminal, which reproduce
DirectWrite's own grayscale contrast enhancement and gamma correction.

- Upstream: https://github.com/microsoft/terminal

```
MIT License

Copyright (c) Microsoft Corporation. All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Algorithms from publications

- Interleaved gradient noise (J. Jimenez, "Next Generation Post Processing in Call of Duty: Advanced Warfare",
  SIGGRAPH 2014), used to rotate the ray samples per pixel in `src/Canvas/Shaders/FastRay.hlsl`.
- Schlick's approximation of the Fresnel factor, in the same file.

## Embarcadero RAD Studio

FastCanvas is written from scratch. The FireMonkey sources were read for the contracts it implements (`TCanvas`,
`TTextLayout`, `TContext3D`, the way forms paint); the source references in comments (`FMX.Graphics.pas:980-1229`
and similar) point to the RAD Studio 13 sources and contain no code from them. Building FastCanvas requires a RAD
Studio / Delphi license.
