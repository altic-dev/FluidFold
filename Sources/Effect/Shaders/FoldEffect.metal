// Duofy fold effect. Loaded at RUNTIME (not compiled by Xcode) so you can edit
// this file, save, and the running app reloads it. Keep the `FoldUniforms`
// layout in sync with FoldParams.swift -> FoldUniforms.
#include <metal_stdlib>
using namespace metal;

struct FoldUniforms {
    float progress;     // 0 = lid open (effect start), 1 = fully folded
    float tilt;         // radians, rotation of the desktop about its top edge
    float camDist;      // camera distance; smaller = stronger perspective
    float blurLod;      // mip level used for blur (0 = sharp)
    float shade;        // 0..1 darkening toward the far (bottom) edge
    float frost;        // 0..1 white haze
    float sheen;        // 0..1 moving highlight band (Silk)
    float vignette;     // 0..1 darken screen corners
    float scale;        // uniform shrink of the panel (1 = none)
    float yOffset;      // NDC shift of the panel (settle / drop)
    float aspect;       // viewport width / height
    float time;         // seconds, for subtle motion
    float hinge;        // pivot edge: 0 = bottom (MacBook lid), 1 = top
    float pad0;
};

struct VOut {
    float4 pos [[position]];
    float2 uv;
};

// Full-screen quad rotated around its top edge (the hinge) with perspective.
vertex VOut fold_vertex(uint vid [[vertex_id]], constant FoldUniforms &u [[buffer(0)]]) {
    const float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    float2 c = corners[vid] * u.scale;
    float hingeY = mix(-1.0, 1.0, u.hinge);
    float h = c.y - hingeY;                   // 0 at the hinge edge
    float y = hingeY + h * cos(u.tilt) + u.yOffset;
    float z = -abs(h) * sin(u.tilt);          // negative = away from the viewer
    float w = (u.camDist - z) / u.camDist;    // perspective divide
    VOut o;
    o.pos = float4(c.x, y, 0.0, w);          // x and y shrink via the divide by w
    o.uv = float2(corners[vid].x * 0.5 + 0.5, 0.5 - corners[vid].y * 0.5);
    return o;
}

fragment float4 fold_fragment(VOut in [[stage_in]],
                              texture2d<float> tex [[texture(0)]],
                              constant FoldUniforms &u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
    float3 col = tex.sample(s, in.uv, level(u.blurLod)).rgb;

    // Shade: darken toward the edge that moves away from the viewer.
    float far = smoothstep(0.0, 1.0, mix(1.0 - in.uv.y, in.uv.y, u.hinge));
    col *= 1.0 - u.shade * u.progress * far;

    // Vignette on the panel itself.
    float2 d = in.uv - 0.5;
    col *= 1.0 - u.vignette * u.progress * dot(d, d) * 2.0;

    // Sheen: soft highlight band sweeping down with progress.
    float bandPos = mix(0.85 - 0.7 * u.progress, 0.15 + 0.7 * u.progress, u.hinge);
    float band = exp(-pow((in.uv.y - bandPos) * 6.0, 2.0));
    col += u.sheen * u.progress * band * 0.25;

    // Frost: white haze.
    col = mix(col, float3(1.0), u.frost * u.progress);

    return float4(col, 1.0);
}
