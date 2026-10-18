#include <metal_stdlib>
using namespace metal;

// Must match FrameUniforms in Renderer.swift.
struct FrameUniforms {
    float4x4 viewProj;
    float4 camPos;
    float time, dt, aspect, fade;
    float bass, mid, treble, level;
    float beat, turbulence, radial, swirl;
    float4 gravity;
    float bgHue, bgIntensity, warp, zoom;
    float rotate, saturation, particleBright, charCount;
    float4 charPos[3];    // xyz + attraction
    float4 charColor[3];  // rgb + brightness
    float4 worlds;        // classic, magnetosphere, xbox, twirl
    float4 effects;       // hue drift, flash
};

struct Particle {
    float4 pos;  // xyz + life
    float4 vel;  // xyz + seed
};

struct LineVertex {
    float4 position;  // w = 1 world space, w = 0 already on screen
    float4 color;     // rgb + brightness
    float4 extra;     // x: position across the line (-1...1)
};

// ---------- helpers ----------

static float hash11(float n) { return fract(sin(n) * 43758.5453123); }

static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float vnoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float a = hash21(i);
    float b = hash21(i + float2(1, 0));
    float c = hash21(i + float2(0, 1));
    float d = hash21(i + float2(1, 1));
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

static float fbm(float2 p) {
    float v = 0.0;
    float a = 0.5;
    for (int i = 0; i < 5; i++) {
        v += a * vnoise(p);
        p = p * 2.03 + float2(1.7, 9.2);
        a *= 0.5;
    }
    return v;
}

static float3 palette(float t, float hue, float sat) {
    float3 c = 0.5 + 0.5 * cos(6.28318 * (t + hue + float3(0.0, 0.33, 0.67)));
    float l = dot(c, float3(0.299, 0.587, 0.114));
    return mix(float3(l), c, saturate(sat));
}

static float3 hueRotate(float3 c, float angle) {
    const float3 k = float3(0.57735);
    float cs = cos(angle);
    return c * cs + cross(k, c) * sin(angle) + k * dot(k, c) * (1.0 - cs);
}

static float3 flowField(float3 p, float t) {
    return float3(sin(p.y * 1.3 + t) + sin(p.z * 0.7 - t * 0.6),
                  sin(p.z * 1.1 + t * 0.8) + sin(p.x * 0.9 + t * 0.4),
                  sin(p.x * 1.2 - t * 0.7) + sin(p.y * 0.8 + t * 0.5));
}

// ---------- particles ----------

kernel void updateParticles(device Particle *particles [[buffer(0)]],
                            constant FrameUniforms &u [[buffer(1)]],
                            uint id [[thread_position_in_grid]]) {
    Particle p = particles[id];
    float seed = p.vel.w;
    int count = max(1, int(u.charCount));
    int owner = int(id) % count;
    float4 home = u.charPos[owner];

    float3 pos = p.pos.xyz;
    float3 vel = p.vel.xyz;
    float dt = min(u.dt, 0.05);

    float3 toHome = home.xyz - pos;
    float dist = length(toHome) + 1e-3;
    float3 dir = toHome / dist;

    // Pulled towards its character, swirling around it, pushed by the music.
    float pull = home.w * (0.6 + 0.4 * hash11(seed * 7.1));
    vel += dir * pull * min(dist, 3.0) * dt * 2.0;
    float3 tangent = normalize(cross(dir, float3(0.0, 1.0, 0.0)) + float3(1e-4));
    vel += tangent * u.swirl * dt * 3.0 / (0.5 + dist);
    vel += flowField(pos * 0.8 + seed, u.time * 0.3) * u.turbulence * dt;
    vel -= dir * (u.radial + u.beat * 1.5 * (0.5 + u.bass)) * dt * 6.0 / (0.3 + dist * 0.5);
    vel += u.gravity.xyz * dt;
    vel *= (1.0 - dt * 1.2);
    pos += vel * dt;

    float life = p.pos.w - dt * (0.08 + 0.1 * hash11(seed));
    if (life <= 0.0 || length(pos) > 12.0) {
        float3 r = float3(hash11(seed + u.time), hash11(seed * 1.3 + u.time), hash11(seed * 2.7 + u.time)) * 2.0 - 1.0;
        pos = home.xyz + r * 0.6;
        vel = r * 0.3;
        life = 1.0;
    }
    particles[id].pos = float4(pos, life);
    particles[id].vel = float4(vel, seed);
}

struct ParticleOut {
    float4 position [[position]];
    float size [[point_size]];
    float4 color;
};

vertex ParticleOut particleVertex(const device Particle *particles [[buffer(0)]],
                                  constant FrameUniforms &u [[buffer(1)]],
                                  uint vid [[vertex_id]]) {
    Particle p = particles[vid];
    ParticleOut o;
    o.position = u.viewProj * float4(p.pos.xyz, 1.0);
    int count = max(1, int(u.charCount));
    float4 cc = u.charColor[int(vid) % count];
    float speed = length(p.vel.xyz);
    float seed = p.vel.w;
    // Magnetosphere: the nebula spreads across neighbouring hues instead of one flat colour.
    float3 spread = palette(fract(seed * 0.37) * 0.35 + u.time * 0.02, u.bgHue, 1.0);
    float3 base = mix(cc.rgb, spread, 0.55 * u.worlds.y);
    float3 col = mix(base, float3(1.0), saturate(speed * 0.15 + u.treble * 0.3));
    float life = p.pos.w;
    float fade = smoothstep(0.0, 0.2, life) * (1.0 - smoothstep(0.9, 1.0, life));
    float worldBright = 0.25 + u.worlds.y;
    o.color = float4(col * (0.35 + 0.65 * cc.a) * u.particleBright * fade * worldBright * 0.07, 1.0);
    o.size = clamp((2.5 + u.treble * 3.0) * 7.0 / max(o.position.w, 0.1), 1.0, 14.0);
    return o;
}

fragment float4 particleFragment(ParticleOut in [[stage_in]], float2 pc [[point_coord]]) {
    float d = length(pc - 0.5) * 2.0;
    float a = exp(-d * d * 4.0);
    return float4(in.color.rgb * a, a);
}

// ---------- glowing lines ----------

struct LineOut {
    float4 position [[position]];
    float4 color;
    float across;
};

vertex LineOut lineVertex(const device LineVertex *vertices [[buffer(0)]],
                          constant FrameUniforms &u [[buffer(1)]],
                          uint vid [[vertex_id]]) {
    LineVertex v = vertices[vid];
    LineOut o;
    if (v.position.w < 0.5) {
        o.position = float4(v.position.xy, 0.0, 1.0);
    } else {
        o.position = u.viewProj * float4(v.position.xyz, 1.0);
    }
    o.color = v.color;
    o.across = v.extra.x;
    return o;
}

fragment float4 lineFragment(LineOut in [[stage_in]]) {
    float d = abs(in.across);
    float core = 1.0 - smoothstep(0.0, 1.0, d);
    float edge = core * core;
    return float4(in.color.rgb * in.color.a * edge, 1.0);
}

// ---------- full-screen passes ----------

struct ScreenOut {
    float4 position [[position]];
    float2 uv;
};

vertex ScreenOut screenVertex(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    ScreenOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

// Dreamy flame-like background plus the previous frame, slightly zoomed and turned, for trails.
fragment float4 composeFragment(ScreenOut in [[stage_in]],
                                texture2d<float> previous [[texture(0)]],
                                constant FrameUniforms &u [[buffer(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_zero);
    float2 c = in.uv - 0.5;
    // Classic iTunes liquid swirl: turns harder near the centre.
    float twirl = u.worlds.w * 0.03 / (0.15 + length(c) * 3.0);
    float cs = cos(u.rotate + twirl);
    float sn = sin(u.rotate + twirl);
    c = float2(c.x * cs - c.y * sn, c.x * sn + c.y * cs) / u.zoom;
    float3 trail = previous.sample(s, c + 0.5).rgb * u.fade;
    trail = max(hueRotate(trail, u.effects.x), 0.0);

    float2 p = in.uv * 2.0 - 1.0;
    p.x *= u.aspect;
    float t = u.time * 0.04;
    float2 q = float2(fbm(p * 1.2 + t), fbm(p * 1.2 + float2(5.2, 1.3) - t));
    float2 r = float2(fbm(p + 3.0 * u.warp * q + float2(1.7, 9.2) + 0.15 * t),
                      fbm(p + 3.0 * u.warp * q + float2(8.3, 2.8) - 0.12 * t));
    float f = fbm(p + 3.5 * r);
    float3 bg = palette(f * 0.8 + length(r) * 0.4, u.bgHue, u.saturation) * (f * f * 1.6) * u.bgIntensity;
    bg *= 0.75 + u.bass * 0.5;
    return float4(trail + bg * (0.02 + 0.05 * u.worlds.x), 1.0);
}

fragment float4 presentFragment(ScreenOut in [[stage_in]],
                                texture2d<float> trails [[texture(0)]],
                                texture2d<float> crisp [[texture(1)]],
                                constant FrameUniforms &u [[buffer(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 c = trails.sample(s, in.uv).rgb + crisp.sample(s, in.uv).rgb;
    float2 px = 1.0 / float2(trails.get_width(), trails.get_height());
    float3 glow = float3(0.0);
    for (int i = -2; i <= 2; i++) {
        for (int j = -2; j <= 2; j++) {
            float2 at = in.uv + float2(i, j) * px * 6.0;
            glow += crisp.sample(s, at).rgb + trails.sample(s, at).rgb * 0.5;
        }
    }
    glow /= 25.0;
    c += glow * (0.6 + 0.4 * u.worlds.z);
    c += u.effects.y * 0.35;
    c = 1.0 - exp(-c * 1.1);
    float vignette = 1.0 - smoothstep(0.35, 1.2, length(in.uv - 0.5) * 1.5);
    return float4(c * vignette, 1.0);
}
