#include <metal_stdlib>
using namespace metal;

// The overlay's waveform: one full-screen triangle, and the fragment shader
// draws a glowing line whose height follows the recent mic level.

struct Varyings {
    float4 position [[position]];
    float2 uv;
};

// Matches `WaveUniforms` in Overlay.swift.
struct Uniforms {
    float time;
    float count;
    float active;
};

vertex Varyings overlayVertex(uint id [[vertex_id]]) {
    // A triangle that covers the view: (0,0), (2,0), (0,2) in uv.
    float2 p = float2((id << 1) & 2, id & 2);
    Varyings out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    out.uv = float2(p.x, 1.0 - p.y);
    return out;
}

fragment float4 overlayFragment(
    Varyings in [[stage_in]],
    constant Uniforms &u [[buffer(0)]],
    constant float *levels [[buffer(1)]])
{
    float x = in.uv.x;
    // Levels are oldest first, so the newest sound enters at the right.
    float position = x * (u.count - 1.0);
    int i = int(floor(position));
    int j = min(i + 1, int(u.count) - 1);
    float level = mix(levels[i], levels[j], fract(position));

    // Fade out at both ends, so the line seems to come from nowhere.
    float edges = smoothstep(0.0, 0.12, x) * smoothstep(1.0, 0.88, x);
    float amplitude = (0.06 + level * 0.85) * edges;
    float wave = 0.6 * sin(x * 17.0 - u.time * 3.1) + 0.4 * sin(x * 6.0 + u.time * 1.3);

    float y = in.uv.y * 2.0 - 1.0;
    float distance = abs(y - amplitude * wave);
    float core = smoothstep(0.07, 0.0, distance);
    float glow = exp(-distance * 7.0) * (0.25 + 0.6 * level);

    float3 color = mix(float3(0.40, 0.62, 1.00), float3(0.86, 0.46, 1.00), x);
    // Dimmer once you stop talking and it is only transcribing.
    float alpha = saturate(core + glow) * mix(0.45, 1.0, u.active);
    return float4(color * alpha, alpha);
}
