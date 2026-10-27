// Created by Angelo Cammalleri on 27.10.2026.
#include <metal_stdlib>
using namespace metal;
struct LegacyVertex { float x, y, u, v, r, g, b, a; };
struct RasterVertex {
    float4 position [[position]];
    float2 uv;
    float4 color;
    float4 glyphBounds [[flat]];
};
struct DrawUniforms { uint textured, replace, distanceField, glyphAtlas; };
struct GlyphUniforms { uint enabled, firstVertex; float inverseWidth, inverseHeight; };
vertex RasterVertex legacyVertex(uint index [[vertex_id]],
                                device const LegacyVertex *vertices [[buffer(0)]],
                                constant float2 &logicalSize [[buffer(1)]],
                                constant GlyphUniforms &glyph [[buffer(2)]]) {
    LegacyVertex v = vertices[index];
    RasterVertex out;
    out.position = float4(v.x / logicalSize.x * 2.0 - 1.0,
                         1.0 - v.y / logicalSize.y * 2.0, 0.0, 1.0);
    out.uv = float2(v.u, v.v);
    out.color = float4(v.r, v.g, v.b, v.a);
    out.glyphBounds = float4(0.0, 0.0, 1.0, 1.0);
    if (glyph.enabled) {
        // Use the triangle's cell rather than floor(interpolatedUV * grid): an
        // exact cell-edge UV must not select the glyph on the other side.
        uint first = glyph.firstVertex + (index - glyph.firstVertex) / 3 * 3;
        float2 a = float2(vertices[first].u, vertices[first].v);
        float2 b = float2(vertices[first + 1].u, vertices[first + 1].v);
        float2 c = float2(vertices[first + 2].u, vertices[first + 2].v);
        float2 center = (min(a, min(b, c)) + max(a, max(b, c))) * 0.5;
        const float2 grid = float2(16.0, 8.0);
        float2 cell = clamp(floor(center * grid), float2(0.0), grid - 1.0);
        float2 halfTexel = float2(glyph.inverseWidth, glyph.inverseHeight) * 0.5;
        out.glyphBounds = float4(cell / grid + halfTexel,
                                 (cell + 1.0) / grid - halfTexel);
    }
    return out;
}
fragment float4 legacyFragment(RasterVertex in [[stage_in]],
                               constant DrawUniforms &draw [[buffer(0)]],
                               texture2d<float> image [[texture(0)]],
                               sampler imageSampler [[sampler(0)]]) {
    float4 color = in.color;
    if (draw.textured) {
        float2 uv = draw.glyphAtlas ? clamp(in.uv, in.glyphBounds.xy, in.glyphBounds.zw) : in.uv;
        float4 texel = image.sample(imageSampler, uv);
        if (draw.distanceField) {
            float halfWidth = max(fwidth(texel.a), 0.0001) * 0.5;
            texel.a = smoothstep(0.5 - halfWidth, 0.5 + halfWidth, texel.a);
            if (draw.distanceField == 2) {
                float foreground = texel.a;
                float alpha = foreground + texel.r * (1.0 - foreground);
                float gray = alpha > 0.0 ? (238.0 / 255.0) * foreground / alpha : 0.0;
                texel = float4(gray, gray, gray, alpha);
            }
        }
        color = draw.replace ? texel : color * texel;
    }
    return color;
}
