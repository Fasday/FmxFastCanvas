// Ray-traced effects of the FastCanvas Direct3D 12 3D context (FastCanvas.Context3D12, stage 5).
//
// Full-screen passes over a finished 3D scene: every pixel's world position comes from the depth buffer, rays go
// from there through the scene's acceleration structure (inline ray queries, DXR tier 1.1):
// - shadows: to the lights, one ray each (hard), or several within the light's angular radius (soft);
// - ambient occlusion: several rays over the hemisphere of the surface, up to a radius.
// The result is a factor that multiplies the color already in the target (blend: destination * source).
// - Hard shadows alone: PSRay, one pass at full resolution into the target.
// - Soft shadows or ambient occlusion: PSHalf traces them at half resolution (one pixel of every 2x2 block) into a
//   factor texture; PSBlur smooths and upsamples it within surfaces (the depth buffer tells them apart), adds hard
//   shadows at full resolution if they are on, and multiplies the target.
// Reflections (PSReflect, full resolution, after them): a ray from the camera finds the object of the pixel (and
// checks it against the depth buffer), its material says how much it reflects, and a mirrored ray finds what it
// reflects, shaded as FMX shades its material (FMX.Materials.pas: emission + ambient + lights times diffuse +
// specular, times the texture); blended in: target * (1 - share) + reflected color * share.
//
// Compiled by tools/compile-shaders.ps1 (dxc, shader model 6.5) into src/Canvas/FastCanvas.RayShaders.inc.

#define MAX_LIGHTS 8

cbuffer Ray : register(b0)
{
    // Pixel (ndc.x, ndc.y, depth, 1) to its offset from the camera, row-vector convention: offset = x * r0 + y * r1 +
    // z * r2 + r3 (relative to the camera: well conditioned far from the origin, where world positions keep few bits).
    float4 InvViewProj[4];
    float4 CameraPos;      // xyz
    float2 PixelToNdc;     // 2 / width, -2 / height (full resolution)
    float  Strength;       // 0..1: the share of a light's contribution a shadow takes away
    uint   LightCount;
    float4 LightPos[MAX_LIGHTS];    // xyz: position (point, spot); w: type (0 directional, 1 point, 2 spot)
    float4 LightDir[MAX_LIGHTS];    // xyz: direction the light travels (directional, spot); w: cos of the spot cut-off
    float4 LightWeight[MAX_LIGHTS]; // x: luminance of the light color; y: spot exponent
    float  Softness;       // tangent of the lights' angular radius (0: hard shadows)
    uint   ShadowSamples;  // rays per light and pixel (soft shadows)
    float  AORadius;       // 0: no ambient occlusion
    float  AOStrength;
    uint   AOSamples;
    uint   Flags;          // FLAG_SHADOWS, FLAG_REFLECT
    float  ReflectStrength;
    float  Pad;
    float4 LightColor[MAX_LIGHTS];  // rgb
    float4 Background;     // rgb: what reflected rays that leave the scene see
};

#define FLAG_SHADOWS 1
#define FLAG_REFLECT 4

RaytracingAccelerationStructure Scene : register(t0);
#ifdef MULTISAMPLE
Texture2DMS<float> Depth : register(t1);
#else
Texture2D<float> Depth : register(t1);
#endif
Texture2D<float> Factor : register(t2);

// Reflections: per instance (InstanceID of the acceleration structure) its geometry and material.
struct InstanceData
{
    uint   Geometry;     // index into Geometries, NO_GEOMETRY: none
    int    Texture;      // index into Textures, -1: none
    uint   Kind;         // 0 unknown (gray, lit), 1 color, 2 texture, 3 light material
    float  F0;           // reflectance at normal incidence, 0: no reflection
    float4 Diffuse;
    float4 Ambient;
    float4 Emission;
    float4 Specular;     // w: shininess
    uint   Stride;
    uint   PositionOffset;
    int    NormalOffset;   // -1: none
    int    TexCoordOffset; // -1: none
    uint   IndexOffset;
    uint   Index16;
    float  Gloss;        // shininess / 128
    uint   Pad;
};
#define NO_GEOMETRY 0xFFFFFFFF

StructuredBuffer<InstanceData> Instances : register(t3);
ByteAddressBuffer Geometries[] : register(t0, space1);   // vertices, then indices from IndexOffset
Texture2D Textures[] : register(t0, space2);
SamplerState WrapSampler : register(s0);

static const float PI = 3.14159265;

float4 VSMain(uint id : SV_VertexID) : SV_Position
{
    // One triangle over the whole target.
    float2 uv = float2((id << 1) & 2, id & 2);
    return float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
}

float LoadDepth(int2 pixel)
{
#ifdef MULTISAMPLE
    return Depth.Load(pixel, 0);
#else
    return Depth.Load(int3(pixel, 0));
#endif
}

// A point of the screen at a depth as an offset from the camera.
float3 CameraOffset(float2 pixel, float depth)
{
    float2 ndc = float2(-1, 1) + pixel * PixelToNdc;
    float4 h = ndc.x * InvViewProj[0] + ndc.y * InvViewProj[1] + depth * InvViewProj[2] + InvViewProj[3];
    return h.xyz / h.w;
}

// The step to the neighbour on the same surface: of the two neighbours along an axis, the one whose depth continues
// the pixel's best (the other may be across an edge). p: the pixel's offset from the camera.
float3 SurfaceStep(int2 pixel, int2 axis, float depth, float3 p)
{
    float dA = LoadDepth(pixel + axis);
    float dB = LoadDepth(pixel - axis);
    if (abs(dA - depth) <= abs(dB - depth))
        return CameraOffset(float2(pixel + axis) + 0.5, dA) - p;
    return p - CameraOffset(float2(pixel - axis) + 0.5, dB);
}

// The surface seen at a pixel: where its rays start (off the surface by a share of the distance to the camera, as
// depth precision falls with it) and its normal toward the camera. False for the background.
bool SurfaceAt(int2 pixel, out float3 origin, out float3 n)
{
    origin = 0;
    n = 0;
    float depth = LoadDepth(pixel);
    if (depth >= 1)
        return false;
    float3 p = CameraOffset(float2(pixel) + 0.5, depth);
    float3 c = cross(SurfaceStep(pixel, int2(0, 1), depth, p), SurfaceStep(pixel, int2(1, 0), depth, p));
    float cl = length(c);
    if (cl <= 0)
        return false;
    n = c / cl;
    if (dot(n, p) > 0)
        n = -n;
    origin = CameraPos.xyz + (p + n * (0.002 * length(p) + 1e-4));
    return true;
}

// Distance to the first hit, or -1.
float Trace(float3 origin, float3 dir, float tMax)
{
    RayQuery<RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH | RAY_FLAG_SKIP_PROCEDURAL_PRIMITIVES | RAY_FLAG_FORCE_OPAQUE> q;
    RayDesc ray;
    ray.Origin = origin;
    ray.Direction = dir;
    ray.TMin = 0;
    ray.TMax = tMax;
    q.TraceRayInline(Scene, RAY_FLAG_NONE, 0xFF, ray);
    q.Proceed();
    return q.CommittedStatus() == COMMITTED_TRIANGLE_HIT ? q.CommittedRayT() : -1;
}

// Interleaved gradient noise (Jimenez 2014): a value per pixel that tiles without visible pattern; the blur pass
// smooths what it leaves.
float PixelNoise(float2 pixel)
{
    return frac(52.9829189 * frac(dot(pixel, float2(0.06711056, 0.00583715))));
}

void Basis(float3 n, out float3 t, out float3 b)
{
    t = normalize(abs(n.x) > 0.5 ? cross(n, float3(0, 1, 0)) : cross(n, float3(1, 0, 0)));
    b = cross(n, t);
}

// 1 - Strength * the share of the lights' contribution that does not reach the surface.
float ShadowFactor(float3 origin, float3 n, float rotation, bool soft)
{
    uint samples = soft ? max(ShadowSamples, 1) : 1;
    float total = 0;
    float blocked = 0;
    [loop]
    for (uint i = 0; i < LightCount; i++)
    {
        float3 l;
        float tMax;
        uint type = (uint)LightPos[i].w;
        if (type == 0)
        {
            l = -normalize(LightDir[i].xyz);
            tMax = 1e6;
        }
        else
        {
            l = LightPos[i].xyz - origin;
            tMax = length(l);
            l /= max(tMax, 1e-6);
            if (type == 2 && dot(-l, normalize(LightDir[i].xyz)) < LightDir[i].w)
                continue;
        }
        float w = saturate(dot(n, l)) * LightWeight[i].x;
        if (w <= 0)
            continue;
        total += w;
        float3 t, b;
        Basis(l, t, b);
        float hits = 0;
        [loop]
        for (uint k = 0; k < samples; k++)
        {
            float3 dir = l;
            if (soft)
            {
                // Vogel disk over the light's disc, turned per pixel.
                float r = sqrt((k + 0.5) / samples) * Softness;
                float a = k * 2.39996323 + rotation;
                dir = normalize(l + (t * cos(a) + b * sin(a)) * r);
            }
            if (Trace(origin, dir, tMax) >= 0)
                hits += 1;
        }
        blocked += w * hits / samples;
    }
    return total > 0 ? 1 - Strength * blocked / total : 1;
}

// 1 - AOStrength * the occlusion of the hemisphere (near occluders count more).
float AOFactor(float3 origin, float3 n, float noise, float rotation)
{
    float3 t, b;
    Basis(n, t, b);
    float occlusion = 0;
    [loop]
    for (uint k = 0; k < AOSamples; k++)
    {
        // Cosine-weighted over the hemisphere, stratified, turned per pixel.
        float u = (k + frac(noise * 7.13)) / AOSamples;
        float a = k * 2.39996323 + rotation;
        float s = sqrt(u);
        float3 dir = t * (s * cos(a)) + b * (s * sin(a)) + n * sqrt(1 - u);
        float hit = Trace(origin, dir, AORadius);
        if (hit >= 0)
            occlusion += 1 - hit / AORadius;
    }
    return 1 - AOStrength * occlusion / AOSamples;
}

// Hard shadows at full resolution, straight into the target.
float4 PSRay(float4 pos : SV_Position) : SV_Target
{
    float3 origin, n;
    float f = 1;
    if (SurfaceAt(int2(pos.xy), origin, n))
        f = ShadowFactor(origin, n, 0, false);
    return float4(f, f, f, 1);
}

// Soft shadows and ambient occlusion at half resolution: at the top-left pixel of every 2x2 block of the target.
float4 PSHalf(float4 pos : SV_Position) : SV_Target
{
    float3 origin, n;
    float f = 1;
    if (SurfaceAt(int2(pos.xy) * 2, origin, n))
    {
        float noise = PixelNoise(pos.xy);
        float rotation = noise * 2 * PI;
        if (Softness > 0)
            f = ShadowFactor(origin, n, rotation, true);
        if (AOSamples > 0)
            f *= AOFactor(origin, n, noise, rotation);
    }
    return float4(f, f, f, 1);
}

// Depth change per pixel along an axis on the pixel's own surface: the smaller of the two one-sided differences.
float DepthSlope(int2 pixel, int2 axis, float depth)
{
    float a = LoadDepth(pixel + axis) - depth;
    float b = depth - LoadDepth(pixel - axis);
    return abs(a) <= abs(b) ? a : b;
}

// The half-resolution factor smoothed and upsampled within the pixel's surface: the 5x5 nearest blocks, weighted by
// distance and by how well their depth continues the plane of the pixel (depth is affine across a plane on screen).
// Then hard shadows at full resolution, if they are on; the target times the result.
float4 PSBlur(float4 pos : SV_Position) : SV_Target
{
    int2 pixel = int2(pos.xy);
    float depth = LoadDepth(pixel);
    if (depth >= 1)
        return float4(1, 1, 1, 1);
    float gx = DepthSlope(pixel, int2(1, 0), depth);
    float gy = DepthSlope(pixel, int2(0, 1), depth);
    float g = abs(gx) + abs(gy) + 1e-7;
    int2 center = pixel >> 1;
    float sum = 0;
    float weight = 0;
    [unroll]
    for (int y = -2; y <= 2; y++)
    {
        [unroll]
        for (int x = -2; x <= 2; x++)
        {
            int2 q = center + int2(x, y);
            float2 delta = float2(q * 2 - pixel);
            float expected = depth + gx * delta.x + gy * delta.y;
            float tolerance = g * (1 + 0.5 * (abs(delta.x) + abs(delta.y)));
            float w = exp(-dot(delta, delta) / 18) * saturate(1 - abs(LoadDepth(q * 2) - expected) / tolerance);
            sum += Factor.Load(int3(q, 0)) * w;
            weight += w;
        }
    }
    float f = weight > 1e-4 ? sum / weight : Factor.Load(int3(center, 0));
    if (Softness <= 0 && LightCount > 0 && (Flags & FLAG_SHADOWS) != 0)
    {
        float3 origin, n;
        if (SurfaceAt(pixel, origin, n))
            f *= ShadowFactor(origin, n, 0, false);
    }
    return float4(f, f, f, 1);
}

// ---- Reflections ----

struct Hit
{
    float    T;
    uint     Instance;
    uint     Primitive;
    float2   Barycentrics;
    float3x4 ObjectToWorld;
};

// The closest triangle along the ray.
bool TraceClosest(float3 origin, float3 dir, float tMax, out Hit h)
{
    RayQuery<RAY_FLAG_SKIP_PROCEDURAL_PRIMITIVES | RAY_FLAG_FORCE_OPAQUE> q;
    RayDesc ray;
    ray.Origin = origin;
    ray.Direction = dir;
    ray.TMin = 0;
    ray.TMax = tMax;
    q.TraceRayInline(Scene, RAY_FLAG_NONE, 0xFF, ray);
    while (q.Proceed())
    {
    }
    h = (Hit)0;
    if (q.CommittedStatus() != COMMITTED_TRIANGLE_HIT)
        return false;
    h.T = q.CommittedRayT();
    h.Instance = q.CommittedInstanceID();
    h.Primitive = q.CommittedPrimitiveIndex();
    h.Barycentrics = q.CommittedTriangleBarycentrics();
    h.ObjectToWorld = q.CommittedObjectToWorld3x4();
    return true;
}

uint LoadIndex(uint g, uint offset, bool index16)
{
    if (index16)
    {
        uint w = Geometries[NonUniformResourceIndex(g)].Load(offset & ~3u);
        return (offset & 2) != 0 ? (w >> 16) : (w & 0xFFFF);
    }
    return Geometries[NonUniformResourceIndex(g)].Load(offset);
}

float3 LoadFloat3(uint g, uint offset)
{
    return asfloat(Geometries[NonUniformResourceIndex(g)].Load3(offset));
}

float2 LoadFloat2(uint g, uint offset)
{
    return asfloat(Geometries[NonUniformResourceIndex(g)].Load2(offset));
}

// The surface at a hit: its world normal (toward the ray's origin) and texture coordinates.
void SurfaceAt(Hit h, float3 dir, InstanceData inst, out float3 n, out float2 uv)
{
    float3 on = 0;
    uv = 0;
    if (inst.Geometry != NO_GEOMETRY)
    {
        uint g = inst.Geometry;
        uint size = inst.Index16 != 0 ? 2 : 4;
        uint base = inst.IndexOffset + h.Primitive * 3 * size;
        uint i0 = LoadIndex(g, base, inst.Index16 != 0);
        uint i1 = LoadIndex(g, base + size, inst.Index16 != 0);
        uint i2 = LoadIndex(g, base + 2 * size, inst.Index16 != 0);
        float3 w = float3(1 - h.Barycentrics.x - h.Barycentrics.y, h.Barycentrics.x, h.Barycentrics.y);
        if (inst.NormalOffset >= 0)
            on = w.x * LoadFloat3(g, i0 * inst.Stride + inst.NormalOffset) +
                 w.y * LoadFloat3(g, i1 * inst.Stride + inst.NormalOffset) +
                 w.z * LoadFloat3(g, i2 * inst.Stride + inst.NormalOffset);
        if (dot(on, on) <= 1e-12)
        {
            float3 p0 = LoadFloat3(g, i0 * inst.Stride + inst.PositionOffset);
            float3 p1 = LoadFloat3(g, i1 * inst.Stride + inst.PositionOffset);
            float3 p2 = LoadFloat3(g, i2 * inst.Stride + inst.PositionOffset);
            on = cross(p1 - p0, p2 - p0);
        }
        if (inst.TexCoordOffset >= 0)
            uv = w.x * LoadFloat2(g, i0 * inst.Stride + inst.TexCoordOffset) +
                 w.y * LoadFloat2(g, i1 * inst.Stride + inst.TexCoordOffset) +
                 w.z * LoadFloat2(g, i2 * inst.Stride + inst.TexCoordOffset);
    }
    // Normals go to world space with the inverse transpose of the object's matrix: its cofactors (scaled meshes).
    float3x3 a = (float3x3)h.ObjectToWorld;
    n = float3(dot(cross(a[1], a[2]), on), dot(cross(a[2], a[0]), on), dot(cross(a[0], a[1]), on));
    float l = length(n);
    n = l > 0 ? n / l : -dir;
    if (dot(n, dir) > 0)
        n = -n;
}

// The color of a surface as FMX's standard materials shade it, lit from the scene's lights (shadowed when shadows
// are on); toViewer: the direction it is seen from.
float3 Shade(InstanceData inst, float3 origin, float3 n, float2 uv, float3 toViewer)
{
    float3 tex = 1;
    if (inst.Texture >= 0)
        tex = Textures[NonUniformResourceIndex((uint)inst.Texture)].SampleLevel(WrapSampler, uv, 0).rgb;
    if (inst.Kind == 1)
        return inst.Diffuse.rgb;
    if (inst.Kind == 2)
        return tex;
    float3 albedo = inst.Kind == 3 ? inst.Diffuse.rgb : float3(0.6, 0.6, 0.6);
    float3 diffuse = 0;
    float specular = 0;
    bool shadows = (Flags & FLAG_SHADOWS) != 0;
    [loop]
    for (uint i = 0; i < LightCount; i++)
    {
        float3 l;
        float tMax;
        float atten = 1;
        uint type = (uint)LightPos[i].w;
        if (type == 0)
        {
            l = -normalize(LightDir[i].xyz);
            tMax = 1e6;
        }
        else
        {
            l = LightPos[i].xyz - origin;
            tMax = length(l);
            l /= max(tMax, 1e-6);
            if (type == 2)
            {
                float spot = dot(-l, normalize(LightDir[i].xyz));
                atten = spot > LightDir[i].w ? pow(saturate(spot), LightWeight[i].y) : 0;
            }
        }
        float nl = saturate(dot(n, l)) * atten;
        if (nl <= 0)
            continue;
        float visible = 1;
        if (shadows && Trace(origin, l, tMax) >= 0)
            visible = 1 - Strength;
        diffuse += LightColor[i].rgb * nl * visible;
        if (inst.Kind == 3)
            specular += pow(saturate(dot(n, normalize(l + toViewer))), max(inst.Specular.w, 1)) * atten * visible;
    }
    float3 c;
    if (inst.Kind == 3)
        c = saturate(inst.Emission.rgb + inst.Ambient.rgb + diffuse * albedo + specular * inst.Specular.rgb) * tex;
    else
        c = saturate(0.2 * albedo + diffuse * albedo);
    return c;
}

float4 PSReflect(float4 pos : SV_Position) : SV_Target
{
    int2 pixel = int2(pos.xy);
    float depth = LoadDepth(pixel);
    if (depth >= 1)
        return 0;
    float3 toSurface = CameraOffset(pos.xy, depth);
    float distance = length(toSurface);
    float3 dir = toSurface / max(distance, 1e-6);
    // The object of the pixel; something drawn in front of it that is not in the scene (a 2D layer, a transparent
    // object) shows in the depth buffer and is left alone.
    Hit h;
    if (!TraceClosest(CameraPos.xyz, dir, distance * 1.05 + 0.01, h) || abs(h.T - distance) > 0.004 * distance + 1e-3)
        return 0;
    InstanceData inst = Instances[h.Instance];
    if (inst.F0 <= 0)
        return 0;
    float3 n;
    float2 uv;
    SurfaceAt(h, dir, inst, n, uv);
    // Schlick's Fresnel: up to the gloss at grazing angles.
    float grazing = pow(1 - saturate(dot(n, -dir)), 5);
    float share = ReflectStrength * (inst.F0 + (inst.Gloss - inst.F0) * grazing);
    if (share <= 0)
        return 0;
    float3 r = reflect(dir, n);
    float3 origin = CameraPos.xyz + dir * h.T + n * (0.002 * distance + 1e-4);
    float3 color = Background.rgb;
    Hit h2;
    if (TraceClosest(origin, r, 1e6, h2))
    {
        InstanceData inst2 = Instances[h2.Instance];
        float3 n2;
        float2 uv2;
        SurfaceAt(h2, r, inst2, n2, uv2);
        float3 p2 = origin + r * h2.T + n2 * (0.002 * (distance + h2.T) + 1e-4);
        color = Shade(inst2, p2, n2, uv2, -r);
    }
    return float4(color * share, share);
}