#include <metal_stdlib>
using namespace metal;

// The overlay's display, after Teenage Engineering's: black glass, thin
// glowing vector lines, a few saturated accents. One full-screen triangle; the
// fragment shader draws, left to right, a tape reel, a scope over a scrolling
// tape ruler, and a segmented level meter. Everything is measured in pixels.

struct Varyings {
    float4 position [[position]];
    float2 uv;
};

// Matches `WaveUniforms` in Overlay.swift, field for field.
struct Uniforms {
    float4 tint;      // the phase colour: the playhead
    float2 size;      // drawable size in pixels
    float time;       // seconds, always running: the traces' motion
    float count;      // entries in `levels`
    float active;     // 1 while recording, 0 while transcribing
    float elapsed;    // seconds of tape: only advances while recording
    float cutCount;   // entries in `cuts`
    float scale;      // pixels per point
};

constant float3 cream = float3(0.93, 0.91, 0.86);
constant float3 blue = float3(0.38, 0.60, 1.00);
constant float3 orange = float3(1.00, 0.62, 0.20);
constant float3 red = float3(1.00, 0.30, 0.18);
constant float3 dim = float3(0.15, 0.15, 0.16);
constant float3 grid = float3(0.20, 0.15, 0.17);

vertex Varyings overlayVertex(uint id [[vertex_id]]) {
    float2 p = float2((id << 1) & 2, id & 2);
    Varyings out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    out.uv = float2(p.x, 1.0 - p.y);
    return out;
}

// Coverage of a stroke `width` pixels wide at distance `d`, antialiased.
static float stroke(float d, float width) {
    return 1.0 - smoothstep(width * 0.5 - 0.5, width * 0.5 + 0.5, d);
}

// Coverage of a filled shape whose signed distance is `d`.
static float fill(float d) {
    return 1.0 - smoothstep(-0.5, 0.5, d);
}

static float3 over(float3 under, float3 color, float coverage) {
    return mix(under, color, saturate(coverage));
}

fragment float4 overlayFragment(
    Varyings in [[stage_in]],
    constant Uniforms &u [[buffer(0)]],
    constant float *levels [[buffer(1)]],
    constant float *cuts [[buffer(2)]])
{
    float s = u.scale;
    float2 p = in.uv * u.size;
    float W = u.size.x;
    float H = u.size.y;
    float3 color = float3(0.0);
    float newest = levels[int(u.count) - 1];

    // Reel: a square at the left. Turns with the tape, so it stops when the
    // recording does.
    {
        float2 c = float2(H * 0.5, H * 0.5);
        float2 d = p - c;
        float r = length(d);
        float angle = atan2(d.y, d.x) - u.elapsed * 2.2;
        color = over(color, cream, stroke(abs(r - H * 0.44), 1.2 * s));
        // Tape wound on the hub: thickens as the recording gets longer.
        float wound = H * (0.25 + 0.12 * saturate(u.elapsed / 120.0));
        color = over(color, float3(0.30, 0.29, 0.27), fill(r - wound) * (1.0 - fill(r - H * 0.24)));
        color = over(color, cream, fill(r - H * 0.24) * (1.0 - fill(r - H * 0.10)));
        // Three notches on the hub, the reel's only moving part you can see.
        float third = 2.0 * M_PI_F / 3.0;
        float spoke = angle - third * round(angle / third);
        float across = r * abs(sin(spoke));
        float inSpan = step(H * 0.10, r) * step(r, H * 0.20) * step(0.0, cos(spoke));
        color = over(color, float3(0.0), stroke(across, 2.2 * s) * inSpan);
        color = over(color, cream, fill(r - H * 0.035));
    }

    float meterWidth = 46.0 * s;
    float left = H + 12.0 * s;
    float right = W - meterWidth - 12.0 * s;
    float rulerHeight = 13.0 * s;
    float scopeBottom = H - rulerHeight - 3.0 * s;
    float middle = scopeBottom * 0.5;

    if (p.x > left && p.x < right) {
        float x = (p.x - left) / (right - left);

        // Grid: thin verticals, and dashed guides at the trace's full swing.
        float column = fmod(p.x - left, 22.0 * s);
        float onGrid = stroke(min(column, 22.0 * s - column), 1.0 * s) * step(p.y, scopeBottom);
        color = over(color, grid, onGrid * 0.9);
        float dash = step(fmod(p.x, 7.0 * s), 3.5 * s);
        float guide = min(abs(p.y - middle + scopeBottom * 0.36), abs(p.y - middle - scopeBottom * 0.36));
        color = over(color, blue * 0.45, stroke(guide, 1.0 * s) * dash);

        // Scope: three traces, oldest level at the left, pinched at both ends
        // so they cross like a Lissajous figure.
        float position = x * (u.count - 1.0);
        int i = int(floor(position));
        int j = min(i + 1, int(u.count) - 1);
        float level = mix(levels[i], levels[j], fract(position));
        float pinch = sin(x * M_PI_F);
        float swing = scopeBottom * 0.36 * (0.08 + 0.92 * level) * pinch;
        float glow = 0.0;
        float core = 0.0;
        for (int k = 0; k < 3; k++) {
            float phase = float(k) * 2.1;
            float speed = 2.4 + float(k) * 0.7;
            float y = middle + swing * sin(x * M_PI_F * (3.0 + float(k)) - u.time * speed + phase);
            float d = abs(p.y - y);
            core = max(core, stroke(d, 1.4 * s) * (k == 0 ? 1.0 : 0.6));
            glow += exp(-d / (5.0 * s)) * (0.10 + 0.35 * level);
        }
        float bright = mix(0.4, 1.0, u.active);
        color += blue * glow * 0.5 * bright;
        color = over(color, mix(blue, cream, 0.25), core * bright);

        // Tape ruler: ticks scroll left as tape runs; whole seconds are long.
        float perSecond = 44.0 * s;
        float t = u.elapsed - (right - p.x) / perSecond;
        float quarter = fract(t * 4.0);
        float tickDistance = min(quarter, 1.0 - quarter) * perSecond / 4.0;
        bool whole = fract(t + 0.125) < 0.25;
        float tickTop = H - (whole ? rulerHeight : rulerHeight * 0.45);
        float tick = stroke(tickDistance, 1.2 * s) * step(tickTop, p.y) * step(0.0, t);
        color = over(color, whole ? cream : cream * 0.45, tick);

        // Chunk cuts: where a pause was heard and a phrase was sent off.
        for (int k = 0; k < int(u.cutCount); k++) {
            float2 at = float2(right - (u.elapsed - cuts[k]) * perSecond, H - rulerHeight * 0.5);
            float r = length(p - at);
            color = over(color, orange, fill(r - 3.2 * s));
            color += orange * exp(-r / (4.0 * s)) * 0.25;
        }
    }

    // Playhead: now, in the phase colour.
    color = over(color, u.tint.rgb, stroke(abs(p.x - right), 1.4 * s) * step(p.y, H - 1.0 * s));

    // Level meter: ten bars, the top three red.
    if (p.x > W - meterWidth) {
        float slot = meterWidth / 10.0;
        int bar = int((p.x - (W - meterWidth)) / slot);
        float center = W - meterWidth + (float(bar) + 0.5) * slot;
        float inBar = stroke(abs(p.x - center), 2.0 * s) * step(H * 0.18, p.y) * step(p.y, H * 0.82);
        bool lit = float(bar) < newest * 10.0 * u.active + 0.5 * u.active;
        float3 barColor = lit ? (bar >= 7 ? red : cream) : dim;
        color = over(color, barColor, inBar);
        if (lit && bar >= 7) color += red * 0.15 * inBar;
    }

    return float4(color, 1.0);
}
