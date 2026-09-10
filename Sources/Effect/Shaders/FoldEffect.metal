// Duofy fold effect. Loaded at RUNTIME (not compiled by Xcode): edit, save, and the app reloads it.
// Keep `FoldUniforms` in sync with FoldParams.Uniforms in FoldParams.swift.
//
// Model (after elijah-semyonov/DuoLikeAnimation, adapted for a laptop lid):
//   The desktop lives on a fixed plane: the screen at the moment the effect starts. The eye stays where
//   it was, on that plane's normal through the screen center. Only the glass (the lid) moves: it rotates
//   by `tilt` around the hinge edge, rising toward the eye. For each screen pixel we
//     1. place it in 3D on the rotated glass,
//     2. cast a ray from the eye through it to the desktop plane (z = 0),
//     3. blur the desktop around the hit with a radius proportional to the glass-to-plane gap,
//     4. darken, tint, and add a sheen in proportion.
#include <metal_stdlib>
using namespace metal;

struct FoldUniforms {
    float tilt;         // radians the lid has closed since the effect started
    float eyeDistance;  // pixels from the eye to the desktop plane
    float blurSpread;   // blur radius (px) gained per px of glass-to-plane gap
    float darkening;    // light lost per px of blur radius
    float frost;        // 0..1 white haze at full blur
    float sheen;        // 0..1 highlight band strength
    float vignette;     // 0..1 edge darkening
    float hinge;        // 0 = bottom edge (laptop), 1 = top edge
    float2 size;        // drawable size in pixels
    float progress;     // 0..1 normalized closing progress (for cosmetic terms)
    float time;         // seconds
    float maxTaps;      // blur kernel cap
    float rampTilt;     // radians over which blur/darkening ease in from zero
    float minLight;     // brightness floor for the darkening term
    float pad0;
};

struct VOut { float4 pos [[position]]; float2 uv; };

vertex VOut fold_vertex(uint vid [[vertex_id]], constant FoldUniforms &u [[buffer(0)]]) {
    const float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    VOut o;
    o.pos = float4(corners[vid], 0.0, 1.0);
    o.uv = float2(corners[vid].x * 0.5 + 0.5, 0.5 - corners[vid].y * 0.5);   // uv.y = 0 at top
    return o;
}

constant float kGoldenAngle = 2.39996322972865332;
constant float kTwoPi = 6.28318530717958648;

static float hash21(float2 p) { return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453); }

fragment float4 fold_fragment(VOut in [[stage_in]],
                              texture2d<float> tex [[texture(0)]],
                              constant FoldUniforms &u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
    const float2 size = u.size;
    const float2 p = in.uv * size;                  // pixel position, y down
    const float tilt = max(u.tilt, 0.0);

    if (tilt < 1e-4) {
        return float4(tex.sample(s, in.uv).rgb, 1.0);
    }

    // Distance of this pixel from the hinge edge, along the glass.
    const float hingeY = mix(size.y, 0.0, u.hinge);
    const float side   = mix(-1.0, 1.0, u.hinge);   // direction away from the hinge, in y-down pixels
    const float d      = abs(p.y - hingeY);

    // Glass pixel in 3D (z toward the eye); the glass folds toward the eye as the lid closes.
    const float3 glass = float3(p.x, hingeY + side * d * cos(tilt), d * sin(tilt));
    const float3 eye   = float3(size * 0.5, u.eyeDistance);

    const float depth = eye.z - glass.z;
    if (depth <= 1e-3) return float4(0, 0, 0, 1);
    const float  t   = eye.z / depth;
    const float2 hit = eye.xy + (glass.xy - eye.xy) * t;

    // Ease the frost in over the first degrees so the onset is gradual instead of a switch.
    const float ramp   = smoothstep(0.0, 1.0, tilt / max(u.rampTilt, 1e-3));
    const float gap    = glass.z;
    const float radius = u.blurSpread * ramp * gap;

    if (any(hit < -radius) || any(hit > size + radius)) return float4(0, 0, 0, 1);

    const float2 hitUV = hit / size;
    float3 col;
    if (radius < 0.5) {
        col = tex.sample(s, hitUV).rgb;
    } else {
        // Vogel disk with per-pixel rotation; sample a coarser mip as the kernel grows to keep it cheap.
        const int   taps     = clamp(int(radius * 2.0), 6, int(u.maxTaps));
        const float rotation = hash21(p) * kTwoPi;
        const float lod      = max(0.0, log2(radius / float(taps)) + 1.5);
        float3 sum = 0.0;
        for (int i = 0; i < taps; ++i) {
            const float r = radius * sqrt((float(i) + 0.5) / float(taps));
            const float a = float(i) * kGoldenAngle + rotation;
            const float2 off = r * float2(cos(a), sin(a));
            sum += tex.sample(s, (hit + off) / size, level(lod)).rgb;
        }
        col = sum / float(taps);
    }

    // Frosted glass absorbs in proportion to how much it scatters.
    const float attenuation = max(1.0 - u.darkening * radius, u.minLight);
    col *= attenuation;

    // Cosmetics: vignette on the glass, sheen band sweeping with progress, frost haze.
    const float2 c = in.uv - 0.5;
    col *= 1.0 - u.vignette * u.progress * dot(c, c) * 2.0;
    const float bandPos = mix(0.85 - 0.7 * u.progress, 0.15 + 0.7 * u.progress, u.hinge);
    col += u.sheen * u.progress * exp(-pow((in.uv.y - bandPos) * 6.0, 2.0)) * 0.2;
    col = mix(col, float3(1.0), u.frost * saturate(radius / 40.0));

    return float4(col, 1.0);
}
