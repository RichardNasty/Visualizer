#include <metal_stdlib>
using namespace metal;

// Every field is a float4 so the layout matches the Swift `Uniforms` struct exactly.
struct Uniforms {
    float4 res;     // feedback width, height, 1/width, 1/height
    float4 time;    // seconds, frame dt, frame scale (dt * 60), aspect
    float4 audio;   // bass, mid, treble, volume (about 1 on average, 0 when silent)
    float4 beat;    // pulse (1 on a beat, decays), phase in beat, kick, seconds since beat
    float4 scenes;  // outgoing scene, incoming scene, blend 0..1, trail decay
    float4 motion;  // accumulated rotation, musical time, wave gain, seed
    float4 pal0;    // palette: dark
    float4 pal1;    //          mid
    float4 pal2;    //          highlight
};

struct VOut {
    float4 position [[position]];
    float2 uv;
};

vertex VOut fullscreen_vertex(uint vid [[vertex_id]]) {
    float2 pos = float2((vid << 1) & 2, vid & 2);
    VOut o;
    o.position = float4(pos * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(pos.x, 1.0 - pos.y);
    return o;
}

// ---------- helpers ----------

static float2 rotate2(float2 p, float a) {
    float c = cos(a), s = sin(a);
    return float2(c * p.x - s * p.y, s * p.x + c * p.y);
}

static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float3 palette(float t, constant Uniforms &u) {
    t = saturate(t);
    float3 a = u.pal0.rgb, b = u.pal1.rgb, c = u.pal2.rgb;
    return t < 0.5 ? mix(a, b, smoothstep(0.0, 1.0, t * 2.0)) : mix(b, c, smoothstep(0.0, 1.0, t * 2.0 - 1.0));
}

static float luma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

// Soft glowing falloff around a line or dot: bright core, long halo.
static float glow(float d, float w) { return (w * w) / (d * d + w * w); }

static float lookup(constant float *data, float x) {
    float f = saturate(x) * 511.0;
    int i = int(f);
    int j = min(i + 1, 511);
    return mix(data[i], data[j], f - float(i));
}

// Folds a point into one wedge of a six-way kaleidoscope (12 mirror images).
static float2 fold6(float2 p) {
    float seg = 2.0 * M_PI_F / 6.0;
    float th = atan2(p.y, p.x);
    th = abs(fmod(th + 4.0 * M_PI_F, seg) - seg * 0.5);
    return length(p) * float2(cos(th), sin(th));
}

// ---------- motion: where each pixel's previous colour comes from ----------

static float2 warpScene(int id, float2 p, constant Uniforms &u) {
    float k = u.time.z;
    float b = u.audio.x, m = u.audio.y, v = u.audio.w;
    float pulse = u.beat.x, kick = u.beat.z;
    float mt = u.motion.y;
    float r = length(p);
    switch (id) {
    case 0: { // Nebula: slow bloom outward through a curling current
        float zoom = 1.0 - (0.004 + 0.006 * b + 0.012 * pulse) * k;
        float a = 0.0025 * k * sin(mt * 0.21);
        float2 flow = 0.0022 * k * float2(sin(p.y * 4.0 + mt * 0.7) + sin(p.y * 7.3 - mt * 0.4),
                                          cos(p.x * 3.7 - mt * 0.6) + cos(p.x * 6.1 + mt * 0.5));
        return rotate2(p * zoom, a) + flow;
    }
    case 1: { // Tunnel: rushing forward, twisting with the mids
        float zoom = 1.0 - (0.014 + 0.018 * b + 0.035 * pulse + 0.02 * kick) * k;
        float dir = sin(mt * 0.07) > 0.0 ? 1.0 : -1.0;
        float a = (0.003 + 0.006 * m) * k * dir;
        return rotate2(p * zoom, a);
    }
    case 2: { // Liquid: the classic iTunes current rising like smoke
        float2 q = p;
        q.x += k * 0.0035 * sin(p.y * 6.0 + mt);
        q.y -= k * (0.0016 + 0.0025 * b + 0.004 * pulse);
        q += k * 0.0018 * float2(sin(p.y * 13.0 + mt * 1.7), cos(p.x * 9.0 - mt * 1.3));
        return q;
    }
    case 3: { // Vortex: a whirlpool pulling inward
        float a = k * (0.012 + 0.02 * m) / (0.25 + r * 3.0);
        return rotate2(p, a) * (1.0 + 0.004 * k * (1.0 + b + 2.0 * pulse));
    }
    case 4: { // Kaleidoscope: six mirrored wedges that keep folding into each other
        float2 q = rotate2(fold6(p), 0.003 * k);
        return q * (1.0 - (0.006 + 0.01 * b + 0.02 * pulse) * k);
    }
    default: { // Shockwave: rings ripple out from each beat
        float zoom = 1.0 - (0.008 + 0.05 * pulse) * k;
        float ripple = 1.0 + 0.008 * k * sin(r * 28.0 - mt * 4.0) * (0.3 + v);
        return p * zoom * ripple;
    }
    }
}

// ---------- new light drawn into the frame ----------

static float3 drawScene(int id, float2 p, constant Uniforms &u, constant float *wave, constant float *spec) {
    float b = u.audio.x, m = u.audio.y, tr = u.audio.z, v = u.audio.w;
    float pulse = u.beat.x, kick = u.beat.z, age = u.beat.w;
    float mt = u.motion.y, rot = u.motion.x, gain = u.motion.z;
    float r = length(p);
    float th = atan2(p.y, p.x);
    float x = abs(th) / M_PI_F;              // 0..1..0 around the circle, seamless
    float energy = 0.25 + 0.75 * saturate(v);
    float3 col = 0.0;
    switch (id) {
    case 0: { // a breathing waveform ring and treble sparks
        float R = 0.2 + 0.05 * b + 0.06 * pulse + 0.07 * gain * lookup(wave, x);
        col += palette(0.45 + 0.5 * x, u) * glow(abs(r - R), 0.003) * 0.32 * energy;
        float2 cell = floor(p * 60.0);
        float h = hash21(cell + floor(u.time.x * 10.0));
        if (h > 0.9975 - 0.004 * saturate(tr - 0.6)) {
            float2 c = (cell + 0.5) / 60.0;
            col += palette(0.9, u) * glow(length(p - c), 0.002) * 0.8 * saturate(tr);
        }
        break;
    }
    case 1: { // spectrum ring at the vanishing point, plus a ring thrown out on every beat
        float R = 0.06 + 0.09 * lookup(spec, x);
        col += palette(0.35 + 0.6 * lookup(spec, x), u) * glow(abs(r - R), 0.003) * 0.6 * energy;
        float Rb = 0.04 + age * 0.9;
        col += palette(0.95, u) * glow(abs(r - Rb), 0.004) * 0.5 * pulse;
        break;
    }
    case 2: { // two oscilloscope lines, mirrored
        float2 q = rotate2(p, 0.15 * sin(rot * 0.5));
        float xs = q.x / u.time.w + 0.5;
        float y1 = -0.3 + 0.14 * gain * lookup(wave, xs);
        float y2 = -0.16 + 0.1 * gain * lookup(wave, 1.0 - xs);
        float fade = smoothstep(0.0, 0.12, xs) * (1.0 - smoothstep(0.88, 1.0, xs));
        col += palette(0.75, u) * glow(abs(q.y - y1), 0.003) * 0.5 * energy * fade;
        col += palette(0.4, u) * glow(abs(q.y - y2), 0.0025) * 0.35 * energy * fade;
        break;
    }
    case 3: { // three orbiting comets whose trails get pulled into the whirlpool
        for (int i = 0; i < 3; i++) {
            float fi = float(i);
            float a = mt * (0.55 + 0.17 * fi) + fi * 2.094;
            float rad = 0.17 + 0.1 * sin(mt * 0.37 + fi * 1.7) + 0.04 * b;
            float2 c = rad * float2(cos(a), sin(a));
            float size = 0.004 + 0.006 * b + 0.006 * kick;
            col += palette(0.5 + 0.25 * fi, u) * glow(length(p - c), size) * 0.9 * energy;
        }
        col += palette(1.0, u) * glow(r, 0.01 + 0.03 * pulse) * 0.25 * pulse;
        break;
    }
    case 4: { // a waveform laid along one wedge, mirrored six ways by the motion
        float2 f = fold6(p);
        float seg = 2.0 * M_PI_F / 6.0;
        float a0 = seg * 0.25 + 0.12 * sin(rot);
        float2 dir = float2(cos(a0), sin(a0));
        float along = dot(f, dir);
        float across = dot(f, float2(-dir.y, dir.x));
        float d = abs(across - 0.035 * gain * lookup(wave, saturate(along * 2.2)));
        float inside = 1.0 - smoothstep(0.3, 0.46, along);
        col += palette(0.3 + along * 1.4, u) * glow(d, 0.0025) * 0.35 * energy * inside;
        for (int i = 0; i < 2; i++) {
            float fi = float(i);
            float rad = 0.12 + 0.1 * sin(mt * 0.45 + fi * 2.0) + 0.03 * b;
            float ang = seg * 0.25 + 0.2 * sin(mt * 0.7 + fi * 1.3);
            float2 c = rad * float2(cos(ang), sin(ang));
            col += palette(0.6 + 0.3 * fi, u) * glow(length(f - c), 0.004 + 0.004 * kick) * 0.5 * energy;
        }
        col += palette(0.9, u) * glow(r, 0.008) * 0.3 * pulse;
        break;
    }
    default: { // spectrum spokes radiating from the centre
        float bins = 72.0;
        float xb = (floor(x * bins) + 0.5) / bins;
        float L = 0.05 + 0.32 * lookup(spec, xb);
        float da = abs(fract(x * bins) - 0.5) / bins * M_PI_F * r;
        float along = (1.0 - smoothstep(L - 0.03, L, r)) * smoothstep(0.03, 0.06, r);
        col += palette(0.3 + 0.7 * r / max(L, 0.05), u) * (1.0 - smoothstep(0.0, 0.003, da)) * along * 0.1 * energy;
        col += palette(1.0, u) * glow(r, 0.01 + 0.02 * pulse) * 0.15 * pulse;
        break;
    }
    }
    return col;
}

// ---------- pass 1: advance the trails ----------

fragment float4 update_fragment(VOut in [[stage_in]],
                                constant Uniforms &u [[buffer(0)]],
                                constant float *wave [[buffer(1)]],
                                constant float *spec [[buffer(2)]],
                                texture2d<float> previous [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_zero);
    float aspect = u.time.w;
    float2 p = (in.uv - 0.5) * float2(aspect, -1.0);   // y points up on screen

    int a = int(u.scenes.x), b = int(u.scenes.y);
    float blend = smoothstep(0.0, 1.0, u.scenes.z);
    float2 q = mix(warpScene(a, p, u), warpScene(b, p, u), blend);
    float2 suv = q / float2(aspect, -1.0) + 0.5;
    float3 prev = previous.sample(s, suv, level(0.0)).rgb;

    // Keep old light inside the palette so trails never turn muddy.
    float l = luma(prev);
    float3 tint = palette(saturate(l * 0.8), u);
    float3 locked = tint * (l / max(luma(tint), 0.04));
    prev = mix(prev, locked, saturate(0.04 * u.time.z));

    float decay = pow(u.scenes.w, u.time.z);
    float3 col = prev * decay;
    float3 fresh = mix(drawScene(a, p, u, wave, spec), drawScene(b, p, u, wave, spec), blend);
    col += fresh * u.time.z;
    return float4(min(col, float3(12.0)), 1.0);
}

// ---------- pass 2: glow, tone map, vignette ----------

fragment float4 present_fragment(VOut in [[stage_in]],
                                 constant Uniforms &u [[buffer(0)]],
                                 texture2d<float> frame [[texture(0)]]) {
    constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
    float3 c = frame.sample(s, in.uv, level(0.0)).rgb;
    float3 bloom = 0.0;
    bloom += frame.sample(s, in.uv, level(1.0)).rgb * 0.30;
    bloom += frame.sample(s, in.uv, level(2.0)).rgb * 0.28;
    bloom += frame.sample(s, in.uv, level(3.0)).rgb * 0.24;
    bloom += frame.sample(s, in.uv, level(4.0)).rgb * 0.20;
    bloom += frame.sample(s, in.uv, level(5.0)).rgb * 0.16;
    bloom += frame.sample(s, in.uv, level(6.0)).rgb * 0.12;
    c += bloom * (0.32 + 0.2 * u.beat.x);

    c = 1.0 - exp(-c * 1.15);
    float2 p = (in.uv - 0.5) * float2(u.time.w, 1.0);
    c *= 1.0 - 0.45 * smoothstep(0.35, 1.0, length(p));
    c += (hash21(in.uv * u.res.xy + fract(u.time.x)) - 0.5) / 255.0;
    return float4(saturate(c), 1.0);
}
