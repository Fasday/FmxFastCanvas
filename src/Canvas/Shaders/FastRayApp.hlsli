// Registers of application ray passes of the FastCanvas Direct3D 12 3D context (FastCanvas.Context3D12:
// TFastContext3D12.RayDispatch, TFastContext3D12.RayDraw). Include it in the HLSL of a pass and compile with dxc
// (shader model 6.5: cs_6_5 or ps_6_5); Direct3D 12 takes only signed DXIL (dxc signs it with dxil.dll from its
// folder). Declarations a shader does not use cost nothing.
//
// - A compute pass (cs_6_5) runs AGroupsX x AGroupsY x AGroupsZ thread groups.
// - A pixel pass (ps_6_5) runs once per pixel of the 3D target over a full-screen triangle: its entry point takes
//   only the position, float4 main(float4 pos : SV_Position) : SV_Target, and its result is blended into the target
//   as its TFastRayBlend says.
// - Scene: the opaque objects of the scene drawn so far (TFastContext3D12.RayScene). Per instance:
//   InstanceID() / CommittedInstanceID() is its index in the scene, InstanceMask the draw's RayInstanceMask, and
//   CommittedInstanceContributionToHitGroupIndex() the draw's RayInstanceUser (24 bits). The transforms are FMX's
//   object matrices (world space). Instances are opaque triangles.
// - The SRV and UAV entries of a pass are numbered in the order the pass lists them: entry i is AppBuffers[i] when it
//   is a TFastRayBuffer, AppTextures[i] (AppUTextures[i] for the UI formats) when it is a TFastRayImage or an FMX
//   TTexture; the same for AppRWBuffers / AppImages / AppUImages. Use NonUniformResourceIndex when an index differs
//   between threads.
// - The 3D target as drawn so far in the scene (TFastContext3D12.RayTarget, or the context's own Texture, as an SRV
//   entry of a compute pass): AppTextures[i], sRGB-encoded premultiplied colors (FastSrgbDecode for linear light), above
//   1 only with an HDR target. A pixel pass reads it as white (it draws into it).
// - Facing: a triangle is front facing for the rays (CommittedTriangleFrontFace, RAY_FLAG_CULL_BACK_FACING_TRIANGLES,
//   RAY_FLAG_CULL_FRONT_FACING_TRIANGLES) where FMX's raster takes it as front facing. The raster culls back faces by
//   default (csFrontFace, TControl3D.TwoSide off), so rays with RAY_FLAG_CULL_BACK_FACING_TRIANGLES drop what it
//   drops. FastCanvas sets the instances' winding for this (DXR's default, clockwise seen from the ray in object
//   space, is the raster's back face with FMX's cameras); an object whose matrix mirrors (negative determinant, e.g.
//   Scale.X = -1) flips the raster's winding, and its instance is flipped with it. A projection that mirrors the whole
//   image (not FMX's cameras) would flip the raster's facing for everything, not the rays'.

#ifndef FAST_RAY_APP_HLSLI
#define FAST_RAY_APP_HLSLI

cbuffer FastFrame : register(b0)
{
    row_major float4x4 InvViewProj;   // clip -> world (FMX row vectors: mul(float4(x, y, depth, 1), InvViewProj))
    row_major float4x4 ViewProj;      // world -> clip
    float4   CameraPos;     // world
    float4   TargetSize;    // width, height, 1 / width, 1 / height
    uint     FrameIndex;    // increments every scene with application passes
    uint3    FastPad;
    // The same relative to the camera (offsets from CameraPos), well conditioned far from the origin: the matrices
    // above mix the camera's position, thousands of units, with the near plane's 1, and a point near the camera loses
    // most of its bits in them. (All four are multiplied and inverted in double precision, then rounded.)
    row_major float4x4 InvViewProjRel; // clip -> offset from CameraPos: mul(float4(x, y, depth, 1), InvViewProjRel)
    row_major float4x4 ViewProjRel;    // offset from CameraPos -> clip
};
// cbuffer of the application: register(b1), up to 4096 bytes
RaytracingAccelerationStructure Scene : register(t0);
Texture2D<float> Depth : register(t1);       // the scene's depth buffer (no multisampling with application passes)
ByteAddressBuffer   AppBuffers[]  : register(t0, space1);  // the SRV entries, in the order given ...
Texture2D<float4>   AppTextures[] : register(t0, space2);  // ... the same table typed as textures
Texture2D<uint4>    AppUTextures[] : register(t0, space3); // ... and as textures of the UI formats (R32UI, RG32UI, RGBA32UI)
RWByteAddressBuffer AppRWBuffers[] : register(u0, space1); // the UAV entries, in the order given ...
RWTexture2D<float4> AppImages[]    : register(u0, space2); // ... the same table typed as images
RWTexture2D<uint4>  AppUImages[]   : register(u0, space3); // ... and as images of the UI formats
SamplerState LinearWrap : register(s0); SamplerState LinearClamp : register(s1);
SamplerState PointClamp : register(s2); SamplerState PointWrap : register(s3);

// Depth is 0 at the near plane and 1 at the far plane; 1 where nothing was drawn (and everywhere when the 3D context
// has no depth buffer). Pixel (x, y) has its center at (x + 0.5, y + 0.5), y downward; clip y is upward.

// A point on the screen (pixel coordinates, e.g. a pixel center) at a depth buffer value, as an offset from the
// camera (CameraPos). Far from the origin, work with such offsets (distances, directions, normals from neighbouring
// pixels) and add CameraPos only where a world position is needed: a float world position thousands of units out
// keeps only a few thousandths of a unit.
float3 FastCameraOffset(float2 pixel, float depth)
{
    float2 ndc = float2(pixel.x * TargetSize.z * 2 - 1, 1 - pixel.y * TargetSize.w * 2);
    float4 h = mul(float4(ndc, depth, 1), InvViewProjRel);
    return h.xyz / h.w;
}

// The world position of a point on the screen (pixel coordinates) at a depth buffer value.
float3 FastWorldPosition(float2 pixel, float depth)
{
    return CameraPos.xyz + FastCameraOffset(pixel, depth);
}

// The ray from the camera through a point on the screen (pixel coordinates); its direction from the near plane
// (depth 0), where the inverse has nothing to cancel.
RayDesc FastCameraRay(float2 pixel)
{
    RayDesc ray;
    ray.Origin = CameraPos.xyz;
    ray.Direction = normalize(FastCameraOffset(pixel, 0));
    ray.TMin = 0;
    ray.TMax = 1e30;
    return ray;
}

// Where a point given as an offset from the camera is on the screen: pixel coordinates (x, y) and its depth buffer
// value (z).
float3 FastScreenPosition(float3 offset)
{
    float4 c = mul(float4(offset, 1), ViewProjRel);
    float3 n = c.xyz / c.w;
    return float3((n.x + 1) * 0.5 * TargetSize.x, (1 - n.y) * 0.5 * TargetSize.y, n.z);
}

// Colors. A 3D target holds sRGB-encoded colors (what FMX's materials write, what the display shows as sRGB), with SDR
// white at 1.0. An HDR target (TFastContext3D12.Hdr: RGBA16F) holds the same encoding beyond 1: write
// FastSrgbEncode(linear) with linear light in SDR white units (1.0 = SDR white, the display's SDR white level in nits;
// 2.0 = twice that), up to the headroom of the window's display (FastCanvas.Canvas.FastCanvasHdrInfo(Form).Headroom,
// passed in the application's constants); an 8-bit target and an SDR window clip at 1. The curve is the sRGB one,
// continued above 1 by the same formula.
float3 FastSrgbEncode(float3 linearLight)
{
    float3 c = max(linearLight, 0);
    return lerp(1.055 * pow(c, 1 / 2.4) - 0.055, c * 12.92, (float3)(c <= 0.0031308));
}

float3 FastSrgbDecode(float3 encoded)
{
    float3 c = max(encoded, 0);
    return lerp(pow((c + 0.055) / 1.055, 2.4), c / 12.92, (float3)(c <= 0.04045));
}

#endif // FAST_RAY_APP_HLSLI
