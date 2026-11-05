// Decision #20 (study A4, docs/product/briefs/003-glass-studies.html): a thick-glass dome
// over a faint ghost head, raymarched per pixel. A port of the sketch's WebGL fragment
// shader (thickGlass + ghost); the same constants and the table frame (mm, +x subject's
// right, +y nose, +z up). Used as a SwiftUI `colorEffect` (HeadGlassView): `position` is in
// points from the top-left; colours are premultiplied, as SwiftUI expects.

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

namespace headglass {

constant float3 C = float3(0.8, -16.5, -16.4);
constant float3 RAD = float3(89.3, 105.9, 120.5);
constant float ZC = -58.0;

struct Cam { float3 ro, f, r, u; };

float4 over(float4 f, float4 b) { return f + b * (1.0 - f.a); }

// Ray / scaled-ellipsoid hits (near, far); (-1, -1) for a miss.
float2 ell(float3 ro, float3 rd, float s) {
    float3 R = RAD * s;
    float3 a2 = (ro - C) / R, d2 = rd / R;
    float a = dot(d2, d2), b = dot(a2, d2), c = dot(a2, a2) - 1.0, h = b * b - a * c;
    if (h < 0.0) return float2(-1.0);
    h = sqrt(h);
    return float2((-b - h) / a, (-b + h) / a);
}

float3 ellN(float3 p) { return normalize((p - C) / (RAD * RAD)); }

// Two softboxes (upper-left key, right strip) plus a faint sky, in camera space.
float env(float3 r, Cam cam) {
    float3 k1 = normalize(cam.u * 0.9 - cam.f * 0.25 - cam.r * 0.55);
    float3 k2 = normalize(cam.r * 0.95 + cam.u * 0.15 - cam.f * 0.1);
    return smoothstep(0.88, 0.975, dot(r, k1)) + 0.5 * smoothstep(0.93, 0.985, dot(r, k2)) + 0.06 * clamp(r.z, 0.0, 1.0);
}

float sdEll(float3 p, float3 r) { float k0 = length(p / r); float k1 = length(p / (r * r)); return k0 * (k0 - 1.0) / k1; }
float smin(float a, float b, float k) { float h = max(k - abs(a - b), 0.0) / k; return min(a, b) - h * h * k * 0.25; }
float smax(float a, float b, float k) { return -smin(-a, -b, k); }
float sdCap(float3 p, float3 a, float3 b, float r) {
    float3 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h) - r;
}

// The blended head: skull, jaw, brow, nose, chin, ears, neck, eye sockets (smooth-min).
float headSDF(float3 p) {
    float d = sdEll(p - C, RAD * 0.985);
    d = smin(d, sdEll(p - float3(0.0, 36.0, -90.0), float3(58.0, 56.0, 60.0)), 30.0);
    d = smin(d, sdEll(p - float3(0.0, 72.0, -26.0), float3(56.0, 20.0, 15.0)), 14.0);
    d = smin(d, sdCap(p, float3(0.0, 88.0, -40.0), float3(0.0, 104.0, -70.0), 8.5), 9.0);
    d = smin(d, sdEll(p - float3(0.0, 66.0, -136.0), float3(26.0, 20.0, 17.0)), 18.0);
    float3 q = float3(abs(p.x), p.y, p.z);
    d = smin(d, sdEll(q - float3(85.0, -24.0, -50.0), float3(8.0, 17.0, 28.0)), 6.0);
    d = smin(d, sdCap(p, float3(0.0, -30.0, -110.0), float3(0.0, -38.0, -320.0), 50.0), 36.0);
    d = smax(d, -(length(q - float3(31.0, 90.0, -50.0)) - 12.0), 9.0);
    return d;
}

float3 headN(float3 p) {
    float2 e = float2(0.35, 0.0);
    return normalize(float3(headSDF(p + e.xyy) - headSDF(p - e.xyy),
                            headSDF(p + e.yxy) - headSDF(p - e.yxy),
                            headSDF(p + e.yyx) - headSDF(p - e.yyx)));
}

// One glass wall. `thick` is the path length through it (mm): longer paths absorb more,
// so the dome's edges read darker/denser than its face.
float4 glassSurf(float3 p, float3 n, float3 rd, float thick, bool front, Cam cam, float3 ink, float3 accent, float3 glow, float contrast) {
    float c = abs(dot(n, rd)), F = 0.04 + 0.96 * pow(1.0 - c, 5.0);
    float e = env(reflect(rd, n), cam);
    float ab = 1.0 - exp(-min(thick, 60.0) * 0.03);
    float3 tint = mix(accent, glow, 0.35);
    float a = clamp(ab * 0.5 + F * (0.55 + 0.35 * contrast) + e * (0.25 + F), 0.0, 1.0);
    float3 col = tint * ab * 0.5 + tint * F * 0.35 + float3(e * (0.3 + F) * (front ? 1.0 : 0.35));
    // The polished rim at the cut.
    if (p.z < ZC + 3.2) {
        float m = env(reflect(rd, float3(n.xy, 0.0) * 0.9 + float3(0.0, 0.0, 0.1)), cam);
        col = mix(ink * 0.85, float3(1.0), m * 0.8);
        a = 0.96;
    }
    if (!front) { a *= 0.5; col *= 0.5; }
    return float4(col, a);   // premultiplied, as the sketch composes it
}

float4 thickGlass(float3 ro, float3 rd, Cam cam, float3 ink, float3 accent, float3 glow, float contrast) {
    float2 to = ell(ro, rd, 1.0);
    if (to.y < 0.0) return float4(0.0);
    float2 ti = ell(ro, rd, 0.968);
    float4 res = float4(0.0);
    float3 pf = ro + rd * to.x;
    if (to.x > 0.0 && pf.z > ZC) {
        float th = ti.y < 0.0 ? to.y - to.x : ti.x - to.x;
        res = glassSurf(pf, ellN(pf), rd, th, true, cam, ink, accent, glow, contrast);
    }
    float3 pb = ro + rd * to.y;
    if (pb.z > ZC) {
        float th = ti.y < 0.0 ? 0.0 : to.y - ti.y;
        res = over(res, glassSurf(pb, -ellN(pb), rd, th, false, cam, ink, accent, glow, contrast));
    }
    return res;
}

// Reduce Transparency: the dome as frosted, solid glass (the sketch's cap() shading, kept
// pale), with the same polished rim.
float4 frostedDome(float3 ro, float3 rd, Cam cam, float3 ink, float3 accent, float3 cap) {
    float2 t = ell(ro, rd, 1.0);
    if (t.y < 0.0) return float4(0.0);
    float3 p = ro + rd * t.x;
    bool inside = false;
    if (t.x < 0.0 || p.z <= ZC) { p = ro + rd * t.y; inside = true; if (p.z <= ZC) return float4(0.0); }
    float3 n = inside ? -ellN(p) : ellN(p);
    float3 L = normalize(cam.u * 0.8 - cam.f * 0.5 - cam.r * 0.45);
    float dif = clamp((dot(n, L) + 0.3) / 1.3, 0.0, 1.0), fr = pow(1.0 - abs(dot(n, rd)), 3.0);
    float3 col = mix(cap, accent, 0.07) * (0.6 + 0.4 * dif) + accent * fr * 0.18;
    if (p.z < ZC + 3.2) {
        float m = env(reflect(rd, float3(n.xy, 0.0) * 0.9 + float3(0.0, 0.0, 0.1)), cam);
        col = mix(ink * 0.85, float3(1.0), m * 0.8);
    }
    if (inside) col *= 0.7;
    return float4(col, 1.0);
}

// Only the rim glow of the blended head, fading out below the neck and under the dome's cut.
float4 ghost(float3 ro, float3 rd, float3 ink, float contrast) {
    // March only inside a bounding sphere round the head (everything visible fades out
    // below z = -240, well inside it): background rays return at once instead of marching
    // to t = 1700, which kept transitions (the camera moving every frame) under budget.
    float3 oc = ro - float3(0.0, -10.0, -60.0);
    float bb = dot(oc, rd), cc = dot(oc, oc) - 300.0 * 300.0, hh = bb * bb - cc;
    if (hh < 0.0) return float4(0.0);
    hh = sqrt(hh);
    float t = max(0.0, -bb - hh), tEnd = -bb + hh;
    bool hit = false;
    for (int i = 0; i < 200; i++) {
        float d = headSDF(ro + rd * t);
        if (d < 0.25) { hit = true; break; }
        t += d * 0.85;
        if (t > tEnd) break;
    }
    if (!hit) return float4(0.0);
    float3 p = ro + rd * t, n = headN(p);
    float fade = smoothstep(-240.0, -170.0, p.z) * (1.0 - smoothstep(ZC - 6.0, ZC + 6.0, p.z) * 0.85);
    // The sketch's rim term with its 0.03 base dropped and a steeper falloff (decision #20:
    // "only the rim glow"), so the face and neck creases don't read as a shaded mannequin.
    float a = pow(1.0 - clamp(dot(n, -rd), 0.0, 1.0), 3.2) * (0.62 + 0.5 * contrast) * fade;
    a = min(a, 1.0);
    return float4(ink * a, a);
}

} // namespace headglass

using namespace headglass;

[[ stitchable ]] half4 headGlass(float2 position, half4 color, float2 size,
                                 float3 camPos, float3 camF, float3 camR, float3 camU, float focal,
                                 half4 inkColor, half4 accentColor, half4 glowColor, half4 capColor,
                                 float solid, float contrast) {
    Cam cam = { camPos, camF, camR, camU };
    float2 uv = float2(position.x - 0.5 * size.x, 0.5 * size.y - position.y) / (0.5 * size.y);
    float3 rd = normalize(camF * focal + camR * uv.x + camU * uv.y), ro = camPos;
    float3 ink = float3(inkColor.rgb), accent = float3(accentColor.rgb), glow = float3(glowColor.rgb), cap = float3(capColor.rgb);
    float2 to = ell(ro, rd, 1.0);
    float3 pf = ro + rd * to.x;
    bool frontHit = to.y >= 0.0 && to.x > 0.0 && pf.z > ZC;
    float4 o;
    if (solid > 0.5) {
        float4 dome = frostedDome(ro, rd, cam, ink, accent, cap);
        o = dome.a > 0.0 ? dome : ghost(ro, rd, ink, contrast);
    } else {
        float4 g = thickGlass(ro, rd, cam, ink, accent, glow, contrast);
        float4 front = frontHit ? g : float4(0.0), back = frontHit ? float4(0.0) : g;
        o = over(front, over(ghost(ro, rd, ink, contrast), back));
    }
    return half4(o);
}
