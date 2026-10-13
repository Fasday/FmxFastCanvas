// HDR output of a FastCanvas window (FastCanvas.Gpu12): the window's surface into its FP16 swap chain buffer, whose
// color space is scRGB (linear light, BT.709 primaries, 1.0 = 80 nits).
//
// The surface holds what an 8-bit window holds, premultiplied sRGB-encoded colors with SDR white at 1.0, plus HDR
// content above 1 (bitmaps of HDR 3D contexts). It is decoded with the sRGB curve, as Windows shows the 8-bit windows
// of other programs on an HDR display, and scaled so that SDR white comes out at the display's SDR white level.
//
// Compiled by tools/compile-shaders.ps1 (fxc, vs_4_0 / ps_4_0) into src/Canvas/FastCanvas.Shaders.inc.

cbuffer Output : register(b0)
{
    float Scale;    // scRGB value of SDR white: the SDR white level in nits / 80
    float Linear;   // 1: the surface holds linear light already (measurement aid HdrLinearBlend)
    float2 Pad;
};

Texture2D Source : register(t0);

float4 VSOutput(uint id : SV_VertexID) : SV_Position
{
    // One triangle over the whole target.
    float2 uv = float2((id << 1) & 2, id & 2);
    return float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
}

float4 PSOutput(float4 pos : SV_Position) : SV_Target
{
    // The window's alpha is not shown (DXGI_ALPHA_MODE_IGNORE), as on 8-bit swap chains.
    float3 c = max(Source.Load(int3(pos.xy, 0)).rgb, 0);
    if (Linear < 0.5)
        c = c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4);
    return float4(c * Scale, 1);
}
