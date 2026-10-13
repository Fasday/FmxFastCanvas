// FastCanvas GPU primitives (stage 4).
//
// One instanced draw renders a run of primitives: every instance is a quad (4-vertex triangle strip) around a
// shape in its local space, transformed by the instance's 2x3 matrix into render target pixels. The pixel
// shader evaluates a signed distance to the shape edge and turns it into analytic coverage, so fills, strokes,
// ellipses, lines and images of any kind, color and clip can share one draw call.
//
// Compiled by tools/compile-shaders.ps1 (fxc, vs_4_0 / ps_4_0: Direct3D feature level 10_0 and up) into
// src/Canvas/FastCanvas.Shaders.inc. Keep the instance layout in sync with TGpuInstance (FastCanvas.Gpu.pas).

cbuffer Frame : register(b0)
{
    float2 ViewScale;    // 2 / width, -2 / height of the render target
    float  Aliased;      // 1: hard edges (TCanvasQuality.HighPerformance)
    float  TextContrast; // grayscale enhanced contrast of the system text rendering parameters
    float4 GammaRatios;  // alpha correction for the system text gamma (see TextAlpha)
    uint   RegionFirst;  // a frame that updates part of a window: the boxes of these clip entries (see ClipFactor)
    uint   RegionCount;  // 0: the whole target
};

Texture2D Tex0 : register(t0);
Texture2D Tex1 : register(t1);
Texture2D Tex2 : register(t2);
Texture2D Tex3 : register(t3);
Texture2D Tex4 : register(t4);
Texture2D Tex5 : register(t5);
Texture2D Tex6 : register(t6);
Texture2D Tex7 : register(t7);
Texture2D<float> GlyphAtlas : register(t8);
Texture2D Ramps : register(t9);
Buffer<float4> Clips : register(t10);   // 5 x float4 per clip, see ClipFactor
Buffer<float4> Paints : register(t11);  // 3 x float4 per paint, see PaintColor
Buffer<float4> Edges : register(t12);   // path edges (x0, y0, x1, y1) in local space, see PathCoverage

SamplerState LinearSampler : register(s0);
SamplerState PointSampler : register(s1);
SamplerState WrapSampler : register(s2);   // linear, repeating (bitmap brushes in tile mode)

#define KIND_FILL_RECT      0
#define KIND_STROKE_RECT    1
#define KIND_FILL_ELLIPSE   2
#define KIND_STROKE_ELLIPSE 3
#define KIND_LINE           4
#define KIND_IMAGE          5
#define KIND_GLYPH          6
#define KIND_SOLID          7   // pixel-aligned quad without antialiasing (clears)
#define KIND_PATH           8   // filled polygon: the edges of Edges[start .. start + count)

#define JOIN_MITER 0
#define JOIN_ROUND 1
#define JOIN_BEVEL 2

#define CAP_FLAT   0
#define CAP_SQUARE 1
#define CAP_ROUND  2

#define FLAG_DASHED 0x10000   // lines: the paint index is a dash pattern

struct Instance
{
    float4 Rect   : RECT;    // shape rectangle in local space (x0, y0, x1, y1); lines: (p0, p1)
    float4 M      : XFORM;   // local to pixels: m11, m12, m21, m22
    float4 TR     : XLATE;   // translation (m31, m32), corner radii (rx, ry)
    float4 Uv     : UVRECT;  // images and glyphs: texture coordinates of the rectangle corners
    uint4  Data   : DATA;    // color (TAlphaColor), flags, clip index, paint index + 1 (0 = solid color)
    float  Stroke : STROKE;  // stroke width in local units (0 = fill)
};

struct Varyings
{
    float4 Pos : SV_Position;
    float2 Local : LOCAL;                      // local position; lines: (along, across) the segment
    float2 Uv : TEXCOORD0;
    nointerpolation float4 Rect : RECT;
    nointerpolation float4 Shape : SHAPE;      // radii, half stroke, segment length
    nointerpolation float4 UvRect : UVRECT;
    nointerpolation uint4 Data : DATA;
};

Varyings VSMain(Instance inst, uint vid : SV_VertexID)
{
    Varyings o;
    uint kind = inst.Data.y & 15;
    float2 corner = float2(vid & 1, vid >> 1);
    // Pixels per local unit along the local axes: one device pixel of antialiasing ring around the shape.
    float2 scale = float2(length(inst.M.xy), length(inst.M.zw));
    float2 onePixel = 1.0 / max(scale, 1e-6);
    float halfStroke = inst.Stroke * 0.5;
    float2 local;
    o.Shape = float4(inst.TR.zw, halfStroke, 0);
    o.Rect = inst.Rect;
    if (kind == KIND_LINE)
    {
        float2 p0 = inst.Rect.xy;
        float2 seg = inst.Rect.zw - p0;
        float len = length(seg);
        float2 dir = len > 1e-6 ? seg / len : float2(1, 0);
        float2 nrm = float2(-dir.y, dir.x);
        uint cap = (inst.Data.y >> 10) & 3;
        float ext = (cap == CAP_FLAT ? 0 : halfStroke);
        float m = 1.0 / max(min(scale.x, scale.y), 1e-6);
        float u = lerp(-ext - m, len + ext + m, corner.x);
        float v = lerp(-halfStroke - m, halfStroke + m, corner.y);
        local = p0 + dir * u + nrm * v;
        o.Local = float2(u, v);
        o.Shape.w = len;
    }
    else
    {
        float2 grow = onePixel;
        if (kind == KIND_STROKE_RECT || kind == KIND_STROKE_ELLIPSE)
            grow += halfStroke;
        if (kind == KIND_GLYPH || kind == KIND_SOLID)
            grow = 0;
        local = lerp(inst.Rect.xy - grow, inst.Rect.zw + grow, corner);
        o.Local = local;
    }
    float2 size = inst.Rect.zw - inst.Rect.xy;
    float2 f = (local - inst.Rect.xy) / max(abs(size), 1e-6);
    o.Uv = lerp(inst.Uv.xy, inst.Uv.zw, f);
    o.UvRect = inst.Uv;
    float2 dev = float2(local.x * inst.M.x + local.y * inst.M.z + inst.TR.x,
                        local.x * inst.M.y + local.y * inst.M.w + inst.TR.y);
    o.Pos = float4(dev.x * ViewScale.x - 1, dev.y * ViewScale.y + 1, 0, 1);
    o.Data = inst.Data;
    return o;
}

float4 UnpackColor(uint c)
{
    return float4((c >> 16) & 255, (c >> 8) & 255, c & 255, c >> 24) / 255.0;
}

// Signed distance (negative inside) to the axis-aligned box with half size b, point q relative to its center.
float BoxDistance(float2 q, float2 b)
{
    float2 d = abs(q) - b;
    return length(max(d, 0)) + min(max(d.x, d.y), 0);
}

// Approximate signed distance to an ellipse with radii r centered at the origin (exact for circles).
float EllipseDistance(float2 p, float2 r)
{
    r = max(r, 1e-6);
    float k1 = length(p / r);
    float k2 = length(p / (r * r));
    return k2 > 1e-12 ? k1 * (k1 - 1) / k2 : -min(r.x, r.y);
}

// Rounded box: corners whose bit is set in mask (1 top-left, 2 top-right, 4 bottom-left, 8 bottom-right) are
// elliptical with radii r, the others square.
float RoundBoxDistance(float2 q, float2 b, float2 r, uint mask)
{
    uint bit = (q.x < 0 ? (q.y < 0 ? 1 : 4) : (q.y < 0 ? 2 : 8));
    if ((mask & bit) != 0 && r.x > 0 && r.y > 0)
    {
        float2 e = abs(q) - (b - r);
        if (e.x > 0 && e.y > 0)
            return EllipseDistance(e, r);
    }
    return BoxDistance(q, b);
}

// Distance to the dashes of a line. u, v: along and across the segment [0, len]; h: half the stroke width.
// Pattern (paint table entry): dash and gap lengths in stroke widths, their count, the offset and the period.
// Every dash piece inside the segment gets the cap, as Direct2D draws dashes with the dash cap.
float DashedLineDistance(float u, float v, float len, float h, uint cap, uint index)
{
    float4 g0 = Paints.Load(index * 3);
    float4 g1 = Paints.Load(index * 3 + 1);
    float4 g2 = Paints.Load(index * 3 + 2);
    float w = 2 * h;
    float dashes[6] = { g0.x, g0.y, g0.z, g0.w, g1.x, g1.y };
    uint count = (uint)g1.z;
    float offset = g1.w * w;
    float period = max(g2.x * w, 1e-3);
    float ext = (cap == CAP_FLAT ? 0 : h);
    float k0 = floor((u + offset) / period);
    float d = 1e9;
    [unroll] for (int k = -1; k <= 1; k++)
    {
        float s = (k0 + k) * period - offset;
        [unroll] for (uint j = 0; j < 6; j += 2)
        {
            if (j < count)
            {
                float a = s;
                float e = s + dashes[j] * w;
                s = e + dashes[j + 1] * w;
                float ca = max(a, 0);
                float ce = min(e, len);
                if (ce >= ca)
                {
                    float dd;
                    if (cap == CAP_ROUND)
                        dd = length(float2(u - clamp(u, ca, ce), v)) - h;
                    else
                        dd = max(max(ca - ext - u, u - ce - ext), abs(v) - h);
                    d = min(d, dd);
                }
            }
        }
    }
    return d;
}

float ClipFactor(float2 p, uint index)
{
    uint base = index * 5;
    float4 box = Clips.Load(base);
    if (p.x < box.x || p.y < box.y || p.x >= box.z || p.y >= box.w)
        return 0;
    if (RegionCount > 0)
    {
        // Several rectangles to update: the clip box holds their union, the pixel must be in one of them.
        bool inside = false;
        [loop] for (uint r = 0; r < RegionCount && !inside; r++)
        {
            float4 b = Clips.Load((RegionFirst + r) * 5);
            inside = p.x >= b.x && p.y >= b.y && p.x < b.z && p.y < b.w;
        }
        if (!inside)
            return 0;
    }
    [unroll] for (uint k = 0; k < 2; k++)
    {
        // Oriented rectangle: inverse matrix (a, b, c, d), (tx, ty, width, height); width < 0: unused;
        // height < 0: the area outside the rectangle (ExcludeClipRect), height = -1 - h.
        float4 inv = Clips.Load(base + 1 + 2 * k);
        float4 rc = Clips.Load(base + 2 + 2 * k);
        if (rc.z >= 0)
        {
            float2 l = float2(p.x * inv.x + p.y * inv.z + rc.x, p.x * inv.y + p.y * inv.w + rc.y);
            bool exclude = rc.w < 0;
            float hh = exclude ? -1 - rc.w : rc.w;
            bool inside = l.x >= 0 && l.y >= 0 && l.x < rc.z && l.y < hh;
            if (inside == exclude)
                return 0;
        }
    }
    return 1;
}

// Straight (not premultiplied) color of a gradient paint at a local position.
float4 PaintColor(uint index, float2 local)
{
    uint base = index * 3;
    float4 g0 = Paints.Load(base);
    float4 g1 = Paints.Load(base + 1);
    float4 g2 = Paints.Load(base + 2);
    float t;
    if (g2.w < 1.5)
    {
        // Linear: g0 = start and stop points.
        float2 se = g0.zw - g0.xy;
        t = dot(local - g0.xy, se) / max(dot(se, se), 1e-12);
    }
    else
    {
        // Radial: g0, g1.xy = local-to-brush inverse matrix, g1.zw = center, g2.xy = radii; ramp runs edge to center.
        float2 bp = float2(local.x * g0.x + local.y * g0.z + g1.x, local.x * g0.y + local.y * g0.w + g1.y);
        t = 1 - length((bp - g1.zw) / max(g2.xy, 1e-6));
    }
    t = saturate(t);
    return Ramps.SampleLevel(LinearSampler, float2((t * 255 + 0.5) / 256, g2.z), 0);
}

// Premultiplied color of a bitmap brush (paint kind 3) at a local position. g0, g1.xy: local to texture
// coordinates (0..1 over the bitmap); g1.z: 1 = repeat (TWrapMode.Tile), 0 = clamp to the edge pixels; the texture
// is in the slot of the instance.
float4 ImagePaint(uint index, uint slot, float2 local)
{
    float4 g0 = Paints.Load(index * 3);
    float4 g1 = Paints.Load(index * 3 + 1);
    float2 uv = float2(local.x * g0.x + local.y * g0.z + g1.x, local.x * g0.y + local.y * g0.w + g1.y);
    float4 c = 0;
    if (g1.z > 0.5)
    {
        switch (slot)
        {
            case 0: c = Tex0.SampleLevel(WrapSampler, uv, 0); break;
            case 1: c = Tex1.SampleLevel(WrapSampler, uv, 0); break;
            case 2: c = Tex2.SampleLevel(WrapSampler, uv, 0); break;
            case 3: c = Tex3.SampleLevel(WrapSampler, uv, 0); break;
            case 4: c = Tex4.SampleLevel(WrapSampler, uv, 0); break;
            case 5: c = Tex5.SampleLevel(WrapSampler, uv, 0); break;
            case 6: c = Tex6.SampleLevel(WrapSampler, uv, 0); break;
            default: c = Tex7.SampleLevel(WrapSampler, uv, 0); break;
        }
    }
    else
    {
        switch (slot)
        {
            case 0: c = Tex0.SampleLevel(LinearSampler, uv, 0); break;
            case 1: c = Tex1.SampleLevel(LinearSampler, uv, 0); break;
            case 2: c = Tex2.SampleLevel(LinearSampler, uv, 0); break;
            case 3: c = Tex3.SampleLevel(LinearSampler, uv, 0); break;
            case 4: c = Tex4.SampleLevel(LinearSampler, uv, 0); break;
            case 5: c = Tex5.SampleLevel(LinearSampler, uv, 0); break;
            case 6: c = Tex6.SampleLevel(LinearSampler, uv, 0); break;
            default: c = Tex7.SampleLevel(LinearSampler, uv, 0); break;
        }
    }
    return c;
}

float4 SampleSlot(uint slot, float2 uv, float4 uvRect, bool nearest)
{
    float w = 1, h = 1;
    switch (slot)
    {
        case 0: Tex0.GetDimensions(w, h); break;
        case 1: Tex1.GetDimensions(w, h); break;
        case 2: Tex2.GetDimensions(w, h); break;
        case 3: Tex3.GetDimensions(w, h); break;
        case 4: Tex4.GetDimensions(w, h); break;
        case 5: Tex5.GetDimensions(w, h); break;
        case 6: Tex6.GetDimensions(w, h); break;
        default: Tex7.GetDimensions(w, h); break;
    }
    // Keep bilinear taps inside the source rectangle (images taken from a larger bitmap, e.g. a style atlas).
    float2 inset = 0.5 / float2(w, h);
    float2 lo = min(uvRect.xy, uvRect.zw) + inset;
    float2 hi = max(uvRect.xy, uvRect.zw) - inset;
    uv = clamp(uv, min(lo, (lo + hi) * 0.5), max(hi, (lo + hi) * 0.5));
    float4 c = 0;
    if (nearest)
    {
        // The centre of the texel, chosen here: when a pixel centre falls on a texel border (a bitmap at a half-pixel
        // offset), the sampler's own rounding picks either side, and Direct3D 11 and 12 picked differently. A
        // 1/256-texel bias settles such ties the same way everywhere.
        float2 size = float2(w, h);
        uv = (clamp(floor(uv * size + 1.0 / 256), 0, size - 1) + 0.5) / size;
        switch (slot)
        {
            case 0: c = Tex0.SampleLevel(PointSampler, uv, 0); break;
            case 1: c = Tex1.SampleLevel(PointSampler, uv, 0); break;
            case 2: c = Tex2.SampleLevel(PointSampler, uv, 0); break;
            case 3: c = Tex3.SampleLevel(PointSampler, uv, 0); break;
            case 4: c = Tex4.SampleLevel(PointSampler, uv, 0); break;
            case 5: c = Tex5.SampleLevel(PointSampler, uv, 0); break;
            case 6: c = Tex6.SampleLevel(PointSampler, uv, 0); break;
            default: c = Tex7.SampleLevel(PointSampler, uv, 0); break;
        }
    }
    else
    {
        switch (slot)
        {
            case 0: c = Tex0.SampleLevel(LinearSampler, uv, 0); break;
            case 1: c = Tex1.SampleLevel(LinearSampler, uv, 0); break;
            case 2: c = Tex2.SampleLevel(LinearSampler, uv, 0); break;
            case 3: c = Tex3.SampleLevel(LinearSampler, uv, 0); break;
            case 4: c = Tex4.SampleLevel(LinearSampler, uv, 0); break;
            case 5: c = Tex5.SampleLevel(LinearSampler, uv, 0); break;
            case 6: c = Tex6.SampleLevel(LinearSampler, uv, 0); break;
            default: c = Tex7.SampleLevel(LinearSampler, uv, 0); break;
        }
    }
    return c;
}

// Coverage of a glyph pixel as DirectWrite blends grayscale text: contrast enhancement that depends on the text
// color, then a gamma-dependent alpha correction. The formulas follow Microsoft Terminal's
// src/renderer/atlas/dwrite_helpers.hlsl and dwrite_helpers.cpp (Copyright (c) Microsoft Corporation, MIT
// license), which reproduce DirectWrite's native algorithm. The atlas holds raw coverage
// (IDWriteGlyphRunAnalysis::CreateAlphaTexture), so nothing is applied twice.
float TextAlpha(float alpha, float3 color)
{
    float k = TextContrast * saturate(dot(color, float3(0.30, 0.59, 0.11) * -4.0) + 3.0);
    float a = alpha * (k + 1.0) / (alpha * k + 1.0);
    float f = dot(color, float3(0.25, 0.5, 0.25));
    float4 g = GammaRatios;
    return a + a * (1.0 - a) * ((g.x * f + g.y) * a + (g.z * f + g.w));
}

// Antiderivative of clamp(t, 0, 1).
float RampIntegral(float t)
{
    return t <= 0 ? 0 : (t >= 1 ? t - 0.5 : 0.5 * t * t);
}

// Area coverage of a pixel by a polygon (a path fill, or the outline of a widened stroke).
//
// The pixel is taken as the square of side w (the size of a pixel in local units) centred at the local position,
// axis-aligned in local space. Its coverage is the integral of the winding number over the square, summed edge by
// edge: an edge adds the area of the square left of it within its vertical span, signed by its direction (a ray to
// +x crosses the edges right of a point). Non-zero rule: |integral| clamped to 1; even-odd: a triangle wave of it.
//
// The edges of a path are split into horizontal bands of its local bounds (rect); a band lists every edge that
// overlaps it, widened by more than half a pixel, so one band holds all the edges the square needs. Band b of the
// path: Edges[header + b / 2] = (start, count) of bands 2k and 2k + 1, as uint bits.
float PathCoverage(float2 l, float w, float4 rect, uint header, uint bands, bool evenOdd)
{
    float t = (l.y - rect.y) / max(rect.w - rect.y, 1e-6) * bands;
    uint band = (uint)clamp(floor(t), 0, bands - 1);
    float4 h = Edges.Load(header + band / 2);
    uint2 se = (band & 1) != 0 ? asuint(h.zw) : asuint(h.xy);
    float inv = 1 / max(w, 1e-6);
    float2 corner = l - 0.5 * w;
    float acc = 0;
    [loop] for (uint k = 0; k < se.y; k++)
    {
        float4 e = Edges.Load(se.x + k);
        float2 a = (e.xy - corner) * inv;
        float2 b = (e.zw - corner) * inv;
        float y0 = max(min(a.y, b.y), 0);
        float y1 = min(max(a.y, b.y), 1);
        if (y1 > y0)
        {
            float slope = (b.x - a.x) / (b.y - a.y);
            float fa = a.x + (y0 - a.y) * slope;
            float fb = a.x + (y1 - a.y) * slope;
            float avg = abs(fb - fa) < 1e-4 ? saturate(0.5 * (fa + fb)) : (RampIntegral(fb) - RampIntegral(fa)) / (fb - fa);
            acc += (b.y > a.y ? 1 : -1) * (y1 - y0) * avg;
        }
    }
    acc = abs(acc);
    return evenOdd ? 1 - abs(1 - fmod(acc, 2)) : saturate(acc);
}

// The premultiplied color of a pixel of a primitive.
float4 Shade(Varyings i)
{
    uint flags = i.Data.y;
    uint kind = flags & 15;
    float2 c = (i.Rect.xy + i.Rect.zw) * 0.5;
    float2 b = (i.Rect.zw - i.Rect.xy) * 0.5;
    float2 q = i.Local - c;
    float h = i.Shape.z;
    float d = -1;

    if (kind == KIND_FILL_RECT)
    {
        d = RoundBoxDistance(q, b, i.Shape.xy, (flags >> 12) & 15);
    }
    else if (kind == KIND_STROKE_RECT)
    {
        uint mask = (flags >> 12) & 15;
        uint bit = (q.x < 0 ? (q.y < 0 ? 1 : 4) : (q.y < 0 ? 2 : 8));
        // Rounded corners take the offset of the ellipse; square corners the join of the stroke.
        if ((mask & bit) != 0 && i.Shape.x > 0 && i.Shape.y > 0)
            d = abs(RoundBoxDistance(q, b, i.Shape.xy, mask)) - h;
        else
        {
            float2 e = abs(q) - b;
            float m = max(e.x, e.y);           // L-infinity distance: sharp (mitered) corners
            float outer = m - h;
            uint join = (flags >> 8) & 3;
            if (join == JOIN_ROUND)
                outer = length(max(e, 0)) + min(m, 0) - h;
            else if (join == JOIN_BEVEL)
                outer = max(m - h, (e.x + e.y - h) * 0.70710678);
            d = max(outer, -m - h);
        }
    }
    else if (kind == KIND_FILL_ELLIPSE)
    {
        d = EllipseDistance(q, b);
    }
    else if (kind == KIND_STROKE_ELLIPSE)
    {
        d = abs(EllipseDistance(q, b)) - h;
    }
    else if (kind == KIND_LINE)
    {
        float len = i.Shape.w;
        float u = i.Local.x;
        float v = i.Local.y;
        uint cap = (flags >> 10) & 3;
        if ((flags & FLAG_DASHED) != 0)
            d = DashedLineDistance(u, v, len, h, cap, i.Data.w - 1);
        else if (cap == CAP_ROUND)
            d = length(float2(u - clamp(u, 0, len), v)) - h;
        else
        {
            float ext = (cap == CAP_FLAT ? 0 : h);
            d = max(abs(u - len * 0.5) - (len * 0.5 + ext), abs(v) - h);
        }
    }
    else if (kind == KIND_IMAGE)
    {
        d = BoxDistance(q, b);
    }

    // Size of a pixel in local units, from the derivatives of the local position (not of d: strokes take abs()
    // of a distance, whose derivative vanishes on the centre line and would make thin strokes hard-edged).
    float2 lx = ddx(i.Local);
    float2 ly = ddy(i.Local);
    float w = sqrt(0.5 * (dot(lx, lx) + dot(ly, ly)));
    float coverage;
    if (kind == KIND_PATH)
    {
        coverage = PathCoverage(i.Local, w, i.Rect, asuint(i.UvRect.x), asuint(i.UvRect.y), asuint(i.UvRect.z) != 0);
        if (Aliased > 0.5)
            coverage = coverage >= 0.5 ? 1 : 0;
    }
    else if (kind == KIND_GLYPH || kind == KIND_SOLID || Aliased > 0.5)
        coverage = d <= 0 ? 1 : 0;
    else
        coverage = saturate(0.5 - d / max(w, 1e-6));
    coverage *= ClipFactor(i.Pos.xy, i.Data.z);

    float4 color;
    float4 tint = UnpackColor(i.Data.x);
    if (kind == KIND_IMAGE)
    {
        // Textures hold premultiplied alpha; the instance color carries the opacity in alpha.
        color = SampleSlot((flags >> 4) & 7, i.Uv, i.UvRect, ((flags >> 7) & 1) != 0) * tint.a;
    }
    else if (kind == KIND_GLYPH)
    {
        float a = TextAlpha(GlyphAtlas.SampleLevel(PointSampler, i.Uv, 0), tint.rgb);
        color = float4(tint.rgb * tint.a, tint.a) * a;
    }
    else
    {
        float4 s = tint;
        float4 imageColor = 0;
        bool image = false;
        if (i.Data.w != 0 && kind != KIND_LINE)
        {
            uint p = i.Data.w - 1;
            if (Paints.Load(p * 3 + 2).w > 2.5)
            {
                imageColor = ImagePaint(p, (flags >> 4) & 7, i.Local) * tint.a;
                image = true;
            }
            else
            {
                s = PaintColor(p, i.Local);
                s.a *= tint.a;
            }
        }
        color = image ? imageColor : float4(s.rgb * s.a, s.a);
    }
    return color * coverage;
}

float4 PSMain(Varyings i) : SV_Target
{
    return Shade(i);
}

// Measurement aid (TFastCanvasOption.HdrLinearBlend, HDR windows): the color turned into linear light before it is
// blended, so that blending, antialiasing and text are mixed in linear light instead of in sRGB-encoded values as on
// SDR targets.
float4 PSMainLinear(Varyings i) : SV_Target
{
    float4 c = Shade(i);
    float3 s = c.a > 0 ? max(c.rgb / c.a, 0) : 0;
    s = s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4);
    return float4(s * c.a, c.a);
}
