// Native DLSS SR inputs and presentation. Motion vectors exclude the projection jitter.
cbuffer Constants : register(b0)
{
    row_major float4x4 CurrentMVP;
    row_major float4x4 PreviousMVP;
    float2 JitterNdc;
    float2 RenderSize;
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

float2 PSMotion(MotionVertex v) : SV_Target
{
    float2 current = v.Current.xy / v.Current.w;
    float2 previous = v.Previous.xy / v.Previous.w;
    return (previous - current) * float2(0.5, -0.5) * RenderSize;
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

// Fullscreen passes reuse the first four constant floats. x: decode; y: encode.
float4 PSCopy(ScreenVertex v) : SV_Target
{
    float4 c = Source.SampleLevel(LinearClamp, v.UV, 0);
    if (CurrentMVP[0][0] != 0) c.rgb = Decode(c.rgb);
    if (CurrentMVP[0][1] != 0) c.rgb = Encode(c.rgb);
    return float4(c.rgb, 1);
}
float PSDepth(ScreenVertex v) : SV_Target
{
    return Source.Load(int3(v.Position.xy, 0)).r;
}
