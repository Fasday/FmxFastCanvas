// Native DLSS SR inputs and presentation. Motion vectors exclude the projection jitter.
cbuffer Constants : register(b0)
{
    row_major float4x4 CurrentMVP;
    row_major float4x4 PreviousMVP;
    float2 JitterNdc;
    float2 RenderSize;
    float4 Options;
    float2 OutputSize;
    float2 JitterPixels;
    // x, y: the distance of a depth, |y / (depth + x)|; zw: the jitter of the frame before, in pixels.
    float4 DepthParams;
};

struct MotionVertex
{
    float4 Position : SV_Position;
    float4 Current : TEXCOORD0;
    float4 Previous : TEXCOORD1;
};

MotionVertex VSMotion(float3 position : POSITION)
{
    MotionVertex v;
    v.Current = mul(float4(position, 1), CurrentMVP);
    v.Previous = mul(float4(position, 1), PreviousMVP);
    v.Position = v.Current;
    v.Position.xy += JitterNdc * v.Position.w;
    return v;
}

// The object's vector in pixels of the render size, blue 1: written (PSResolve keeps it).
float4 PSMotion(MotionVertex v) : SV_Target
{
    float2 current = v.Current.xy / v.Current.w;
    float2 previous = v.Previous.xy / v.Previous.w;
    return float4((previous - current) * float2(0.5, -0.5) * RenderSize, 1, 1);
}

struct ScreenVertex { float4 Position : SV_Position; float2 UV : TEXCOORD0; };
ScreenVertex VSFull(uint id : SV_VertexID)
{
    ScreenVertex v;
    v.UV = float2((id << 1) & 2, id & 2);
    v.Position = float4(v.UV * float2(2, -2) + float2(-1, 1), 0, 1);
    return v;
}

Texture2D<float4> Source : register(t0);
Texture2D<float4> Source1 : register(t1);
Texture2D<float4> Source2 : register(t2);
Texture2D<float4> Source3 : register(t3);
Texture2D<float4> Source4 : register(t4);
SamplerState LinearClamp : register(s0);

float3 Decode(float3 c)
{
    return float3(c.r <= 0.04045 ? c.r / 12.92 : pow(max((c.r + 0.055) / 1.055, 0), 2.4),
                  c.g <= 0.04045 ? c.g / 12.92 : pow(max((c.g + 0.055) / 1.055, 0), 2.4),
                  c.b <= 0.04045 ? c.b / 12.92 : pow(max((c.b + 0.055) / 1.055, 0), 2.4));
}
float3 Encode(float3 c)
{
    c = max(c, 0);
    return float3(c.r <= 0.0031308 ? c.r * 12.92 : 1.055 * pow(c.r, 1.0 / 2.4) - 0.055,
                  c.g <= 0.0031308 ? c.g * 12.92 : 1.055 * pow(c.g, 1.0 / 2.4) - 0.055,
                  c.b <= 0.0031308 ? c.b * 12.92 : 1.055 * pow(c.b, 1.0 / 2.4) - 0.055);
}

// Fullscreen passes reuse the first four constant floats. x: decode; y: encode; z: motion vectors shown, scale.
float4 PSCopy(ScreenVertex v) : SV_Target
{
    float4 c = Source.SampleLevel(LinearClamp, v.UV, 0);
    if (CurrentMVP[0][2] != 0) c.rgb = float3(saturate(0.5 + c.rg * CurrentMVP[0][2]), 0.5);
    if (CurrentMVP[0][0] != 0) c.rgb = Decode(c.rgb);
    if (CurrentMVP[0][1] != 0) c.rgb = Encode(c.rgb);
    return float4(c.rgb, 1);
}
float PSDepth(ScreenVertex v) : SV_Target
{
    return Source.Load(int3(v.Position.xy, 0)).r;
}

// The motion of every pixel (Source: the objects' vectors, Source1: the depth). Where no object pass wrote (the
// background, objects without depth write), the camera's: CurrentMVP takes the clip position now to the one before,
// PreviousMVP the same without the camera's change of position (the background, at depth 1, as seen at infinity).
// The pixel's position is taken without the jitter, as the objects' vectors. Options.x 0: zero there.
float2 PSResolve(ScreenVertex v) : SV_Target
{
    int3 p = int3(v.Position.xy, 0);
    float4 m = Source.Load(p);
    if (m.b > 0.5)
        return m.rg;
    if (Options.x == 0)
        return 0;
    float depth = Source1.Load(p).r;
    float2 ndc = v.Position.xy / RenderSize * float2(2, -2) + float2(-1, 1) - JitterNdc;
    float4 previous = depth < 1 ? mul(float4(ndc, depth, 1), CurrentMVP) : mul(float4(ndc, 1, 1), PreviousMVP);
    if (previous.w <= 0)
        return 0;
    return (previous.xy / previous.w - ndc) * float2(0.5, -0.5) * RenderSize;
}

float Distance(float depth)
{
    return abs(DepthParams.y / (depth + DepthParams.x));
}

// The stand-in for NGX (FastDlssEmulate), at the output size. Source: the scene (render size, jittered), Source1: the
// history (the last output), Source2: the motion vectors, Source3: the depth, Source4: the depth of the frame before.
// The scene at this pixel blends with the history where a vector points to. Options.y: no history (the first frame).
// Options.z 1, Temporal (as temporal antialiasing): the vector of the nearest surface around the pixel, the history
// clamped to the colors around it, dropped where the frame before had no surface at that distance there (disoccluded).
// Options.z 0, Accumulate: the pixel's own vector, the history unclamped, dropped unless all the surfaces the frame
// before had there are at its distance (no blends of other surfaces at edges): what is left of the history follows
// the vectors alone, so wrong ones leave trails.
float4 PSEmulate(ScreenVertex v) : SV_Target
{
    float2 uv = v.Position.xy / OutputSize;
    // Where the scene at uv lies in the jittered input.
    float2 pixel = uv * RenderSize + JitterPixels;
    int2 last = int2(RenderSize) - 1;
    int2 center = clamp(int2(pixel), 0, last);
    bool temporal = Options.z != 0;
    float3 current = Source.SampleLevel(LinearClamp, pixel / RenderSize, 0).rgb;
    float3 lo = current;
    float3 hi = current;
    float depth = Source3.Load(int3(center, 0)).r;
    int2 closest = center;
    [unroll] for (int y = -1; y <= 1; y++)
    {
        [unroll] for (int x = -1; x <= 1; x++)
        {
            int3 q = int3(clamp(center + int2(x, y), 0, last), 0);
            float3 c = Source.Load(q).rgb;
            lo = min(lo, c);
            hi = max(hi, c);
            float d = Source3.Load(q).r;
            if (temporal && d < depth)
            {
                depth = d;
                closest = q.xy;
            }
        }
    }
    float2 previous = uv + Source2.Load(int3(closest, 0)).rg / RenderSize;
    float weight = 0.1;
    if (Options.y != 0 || any(previous != saturate(previous)))
        weight = 1;
    // The surfaces the frame before had around the pixel it showed this one at (its jitter).
    float distance = Distance(depth);
    float nearest = 1e30;
    float farthest = 0;
    int2 base = int2(floor(previous * RenderSize + DepthParams.zw - 0.5));
    [unroll] for (int j = 0; j <= 1; j++)
    {
        [unroll] for (int i = 0; i <= 1; i++)
        {
            float change = abs(Distance(Source4.Load(int3(clamp(base + int2(i, j), 0, last), 0)).r) - distance);
            nearest = min(nearest, change);
            farthest = max(farthest, change);
        }
    }
    if ((temporal ? nearest : farthest) > 0.1 * distance)
        weight = 1;
    float3 history = Source1.SampleLevel(LinearClamp, previous, 0).rgb;
    if (temporal)
        history = clamp(history, lo, hi);
    return float4(lerp(history, current, weight), 1);
}

// A constant (Options.x): the exposure texture.
float4 PSFill(ScreenVertex v) : SV_Target
{
    return Options.xxxx;
}
