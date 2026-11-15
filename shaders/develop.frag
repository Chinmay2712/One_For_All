#version 460 core
#include <flutter/runtime_effect.glsl>

precision highp float;

// NOTE: uniform order must match DevelopRenderer._setUniforms in
// lib/photo/develop_renderer.dart.
uniform vec2 uSize;      // image size in px; the shader is drawn on Rect(0,0,uSize)
uniform vec2 uVigC;      // vignette centre (image uv)
uniform vec2 uVigR;      // vignette half extent (image uv)
uniform float uExposure; // stops
uniform float uContrast; // -1..1
uniform float uHighlights;
uniform float uShadows;
uniform float uWhites;
uniform float uBlacks;
uniform float uTemp;
uniform float uTint;
uniform float uVibrance;
uniform float uSaturation;
uniform float uTexture;
uniform float uClarity;
uniform float uDehaze;
uniform float uSharpen;  // 0..1
uniform float uNoise;    // 0..1
uniform float uVignette; // -1..1
uniform float uVigMid;   // 0..1
uniform float uVigFeather;
uniform float uGrain;    // 0..1
uniform float uGrainSize;
uniform float uCurveOn;
uniform float uHslOn;
uniform float uBW;
uniform vec3 uHsl0; // (hue, sat, lum) per colour band, each -1..1
uniform vec3 uHsl1;
uniform vec3 uHsl2;
uniform vec3 uHsl3;
uniform vec3 uHsl4;
uniform vec3 uHsl5;
uniform vec3 uHsl6;
uniform vec3 uHsl7;
uniform vec3 uGS; // colour grading shadows (hue 0..1, sat 0..1, lum -1..1)
uniform vec3 uGM;
uniform vec3 uGH;
uniform float uGradeBalance;
uniform float uGradeBlend;
uniform vec4 uM0Geo;
uniform vec4 uM0Cfg; // type, feather, invert, texture channel
uniform vec4 uM0A;   // exposure, contrast, highlights, shadows
uniform vec4 uM0B;   // temp, tint, saturation, unused
uniform vec4 uM1Geo;
uniform vec4 uM1Cfg;
uniform vec4 uM1A;
uniform vec4 uM1B;
uniform vec4 uM2Geo;
uniform vec4 uM2Cfg;
uniform vec4 uM2A;
uniform vec4 uM2B;
uniform float uShowMask; // 0 none, 1..3 = overlay that mask in red
uniform sampler2D uImage;
uniform sampler2D uCurve; // 256x1 lookup, rgb = per channel curve
uniform sampler2D uMask0; // painted / AI masks, greyscale, one per mask slot
uniform sampler2D uMask1;
uniform sampler2D uMask2;

out vec4 fragColor;

// Impeller's OpenGL ES backend samples textures upside down.
vec2 tex(vec2 uv) {
#ifdef IMPELLER_TARGET_OPENGLES
  return vec2(uv.x, 1.0 - uv.y);
#else
  return uv;
#endif
}

float luma(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }

vec3 rgb2hsl(vec3 c) {
  float mx = max(c.r, max(c.g, c.b));
  float mn = min(c.r, min(c.g, c.b));
  float l = (mx + mn) * 0.5;
  float d = mx - mn;
  float h = 0.0;
  float s = 0.0;
  if (d > 0.00001) {
    s = d / (1.0 - abs(2.0 * l - 1.0) + 0.00001);
    if (mx == c.r) {
      h = mod((c.g - c.b) / d, 6.0);
    } else if (mx == c.g) {
      h = (c.b - c.r) / d + 2.0;
    } else {
      h = (c.r - c.g) / d + 4.0;
    }
    h = h / 6.0;
  }
  return vec3(h, clamp(s, 0.0, 1.0), l);
}

vec3 hsl2rgb(vec3 hsl) {
  vec3 k = mod(vec3(0.0, 8.0, 4.0) + hsl.x * 12.0, 12.0);
  float a = hsl.y * min(hsl.z, 1.0 - hsl.z);
  return hsl.z - a * clamp(min(k - 3.0, 9.0 - k), -1.0, 1.0);
}

vec3 texRgb(vec2 uv) {
  vec4 t = texture(uImage, tex(clamp(uv, vec2(0.0), vec2(1.0))));
  return t.a > 0.0001 ? t.rgb / t.a : t.rgb;
}

vec3 ring(vec2 uv, vec2 r) {
  vec3 s = texRgb(uv + r * vec2(1.0, 0.0));
  s += texRgb(uv + r * vec2(-1.0, 0.0));
  s += texRgb(uv + r * vec2(0.0, 1.0));
  s += texRgb(uv + r * vec2(0.0, -1.0));
  s += texRgb(uv + r * vec2(0.7071, 0.7071));
  s += texRgb(uv + r * vec2(-0.7071, 0.7071));
  s += texRgb(uv + r * vec2(0.7071, -0.7071));
  s += texRgb(uv + r * vec2(-0.7071, -0.7071));
  return s / 8.0;
}

// White balance, exposure and the tonal sliders. Identity when all args are 0.
vec3 tone(vec3 c, float ev, float contrast, float hi, float sh, float wh,
          float bl, float temp, float tint) {
  vec3 lin = pow(max(c, vec3(0.0)), vec3(2.2));
  vec3 wb = vec3(1.0 + 0.28 * temp + 0.06 * tint, 1.0 - 0.22 * tint,
                 1.0 - 0.28 * temp + 0.06 * tint);
  wb = wb / luma(wb);
  lin = lin * wb * exp2(ev);
  c = pow(lin, vec3(1.0 / 2.2));
  // Soft shoulder so pushed exposure rolls off instead of clipping hard.
  vec3 over = max(c - 0.9, vec3(0.0));
  vec3 rolled = min(c, vec3(0.9)) + 0.1 * (1.0 - exp(-over / 0.1));
  c = mix(c, rolled, clamp(ev, 0.0, 1.0));

  float L = clamp(luma(c), 0.0, 1.0);
  float d = sh * 0.30 * L * pow(1.0 - L, 3.0) * 9.48;
  d += hi * 0.30 * (1.0 - L) * pow(L, 3.0) * 9.48;
  d += wh * 0.25 * L * L;
  d += bl * 0.25 * (1.0 - L) * (1.0 - L);
  vec3 added = c + d;
  vec3 scaled = c * ((L + d) / max(L, 0.001));
  c = mix(added, scaled, smoothstep(0.0, 0.25, L));

  c = clamp(c, 0.0, 1.0);
  vec3 s = c * c * (3.0 - 2.0 * c);
  c = mix(c, s, max(contrast, 0.0));
  c = mix(c, vec3(0.5) + (c - 0.5) * 0.4, max(-contrast, 0.0));
  return c;
}

float bandW(float h, float c, float lo, float hi) {
  float d = mod(h - c + 0.5, 1.0) - 0.5;
  return d < 0.0 ? max(0.0, 1.0 + d / lo) : max(0.0, 1.0 - d / hi);
}

float maskW(vec2 uv, vec4 geo, vec4 cfg, float painted) {
  float type = cfg.x;
  if (type < 0.5) {
    return 0.0;
  }
  float w = 0.0;
  if (type < 1.5) {
    // Linear gradient: full effect at geo.xy, none at geo.zw.
    vec2 a = geo.xy * uSize;
    vec2 ab = geo.zw * uSize - a;
    float t = dot(uv * uSize - a, ab) / max(dot(ab, ab), 0.0001);
    w = 1.0 - smoothstep(0.0, 1.0, t);
  } else if (type < 2.5) {
    // Radial: centre geo.xy, radii geo.zw (fractions of image width).
    vec2 d = (uv - geo.xy) * uSize / max(geo.zw * uSize.x, vec2(0.001));
    float r = length(d);
    w = 1.0 - smoothstep(1.0 - clamp(cfg.y, 0.01, 1.0), 1.0, r);
  } else {
    w = painted;
  }
  return mix(w, 1.0 - w, cfg.z);
}

vec3 localAdjust(vec3 c, vec4 a, vec4 b) {
  vec3 o = tone(c, a.x, a.y, a.z, a.w, 0.0, 0.0, b.x, b.y);
  float l = luma(o);
  return clamp(mix(vec3(l), o, 1.0 + b.z), 0.0, 1.0);
}

vec3 gradeTint(vec3 g) {
  vec3 t = hsl2rgb(vec3(g.x, 1.0, 0.5));
  return (t - luma(t)) * g.y * 0.6 + vec3(g.z * 0.25);
}

float hash(vec2 p) {
  return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

void main() {
  vec2 uv = FlutterFragCoord().xy / uSize;
  vec2 px = 1.0 / uSize;
  float longEdge = max(uSize.x, uSize.y);
  vec4 srcTex = texture(uImage, tex(uv));
  float alpha = srcTex.a;
  vec3 src = alpha > 0.0001 ? srcTex.rgb / alpha : srcTex.rgb;
  vec3 c = src;

  // ---- Detail: noise reduction (bilateral) and sharpening (unsharp mask).
  if (uSharpen > 0.001 || uNoise > 0.001) {
    vec2 r = px * max(1.0, longEdge / 2400.0);
    vec3 n0 = texRgb(uv + vec2(r.x, 0.0));
    vec3 n1 = texRgb(uv - vec2(r.x, 0.0));
    vec3 n2 = texRgb(uv + vec2(0.0, r.y));
    vec3 n3 = texRgb(uv - vec2(0.0, r.y));
    if (uNoise > 0.001) {
      vec3 n4 = texRgb(uv + r * 1.5);
      vec3 n5 = texRgb(uv - r * 1.5);
      vec3 n6 = texRgb(uv + vec2(r.x, -r.y) * 1.5);
      vec3 n7 = texRgb(uv + vec2(-r.x, r.y) * 1.5);
      float k = 40.0 / (uNoise * uNoise + 0.02);
      vec3 acc = c;
      float wsum = 1.0;
      float w;
      w = exp(-dot(n0 - c, n0 - c) * k); acc += n0 * w; wsum += w;
      w = exp(-dot(n1 - c, n1 - c) * k); acc += n1 * w; wsum += w;
      w = exp(-dot(n2 - c, n2 - c) * k); acc += n2 * w; wsum += w;
      w = exp(-dot(n3 - c, n3 - c) * k); acc += n3 * w; wsum += w;
      w = exp(-dot(n4 - c, n4 - c) * k); acc += n4 * w; wsum += w;
      w = exp(-dot(n5 - c, n5 - c) * k); acc += n5 * w; wsum += w;
      w = exp(-dot(n6 - c, n6 - c) * k); acc += n6 * w; wsum += w;
      w = exp(-dot(n7 - c, n7 - c) * k); acc += n7 * w; wsum += w;
      c = mix(c, acc / wsum, clamp(uNoise * 1.2, 0.0, 1.0));
    }
    vec3 blur = (n0 + n1 + n2 + n3) * 0.25;
    c += vec3(luma(src - blur)) * uSharpen * 2.0;
  }

  // ---- Presence: clarity and texture are luminance local contrast.
  if (abs(uClarity) > 0.001 || abs(uTexture) > 0.001) {
    float L0 = luma(c);
    float mid = sqrt(max(1.0 - abs(2.0 * L0 - 1.0), 0.0));
    if (abs(uClarity) > 0.001) {
      vec2 rw = px * longEdge * 0.02;
      vec3 wide = (src + ring(uv, rw) + ring(uv, rw * 0.5)) / 3.0;
      c += vec3((luma(src) - luma(wide)) * uClarity * 1.1 * mid);
    }
    if (abs(uTexture) > 0.001) {
      vec3 fine = (src + ring(uv, px * longEdge * 0.004) * 2.0) / 3.0;
      c += vec3((luma(src) - luma(fine)) * uTexture * 1.6 * mid);
    }
  }

  // ---- Global tone.
  c = tone(c, uExposure, uContrast, uHighlights, uShadows, uWhites, uBlacks,
           uTemp, uTint);

  // ---- Dehaze.
  if (uDehaze > 0.0) {
    float a = uDehaze * 0.16;
    c = (c - a * 0.9) / (1.0 - a);
    float l = luma(c);
    c = mix(vec3(l), c, 1.0 + 0.25 * uDehaze);
  } else {
    c = mix(c, vec3(0.9), -uDehaze * 0.35);
  }
  c = clamp(c, 0.0, 1.0);

  // ---- Tone curve.
  if (uCurveOn > 0.5) {
    vec3 t = c * (255.0 / 256.0) + 0.5 / 256.0;
    c = vec3(texture(uCurve, vec2(t.r, 0.5)).r,
             texture(uCurve, vec2(t.g, 0.5)).g,
             texture(uCurve, vec2(t.b, 0.5)).b);
  }

  // ---- Colour mixer (8 hue bands).
  if (uHslOn > 0.5) {
    vec3 hsl = rgb2hsl(c);
    float h = hsl.x;
    vec3 acc = uHsl0 * bandW(h, 0.0, 0.16667, 0.08333);
    acc += uHsl1 * bandW(h, 0.08333, 0.08333, 0.08333);
    acc += uHsl2 * bandW(h, 0.16667, 0.08333, 0.16667);
    acc += uHsl3 * bandW(h, 0.33333, 0.16667, 0.16667);
    acc += uHsl4 * bandW(h, 0.5, 0.16667, 0.16667);
    acc += uHsl5 * bandW(h, 0.66667, 0.16667, 0.08333);
    acc += uHsl6 * bandW(h, 0.75, 0.08333, 0.08333);
    acc += uHsl7 * bandW(h, 0.83333, 0.08333, 0.16667);
    float colourful = smoothstep(0.0, 0.3, hsl.y);
    hsl.x = fract(hsl.x + acc.x * 0.0833);
    hsl.z = clamp(hsl.z + acc.z * 0.3 * colourful * min(hsl.z, 1.0 - hsl.z) * 2.0,
                  0.0, 1.0);
    hsl.y = clamp(hsl.y * (1.0 + acc.y), 0.0, 1.0);
    c = hsl2rgb(hsl);
  }

  // ---- Vibrance, saturation, black and white.
  float L = luma(c);
  float satNow = max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b));
  c = mix(vec3(L), c, 1.0 + uVibrance * (1.0 - satNow));
  c = mix(vec3(luma(c)), c, 1.0 + uSaturation);
  c = mix(c, vec3(luma(c)), uBW);

  // ---- Colour grading (shadows / midtones / highlights).
  float Lg = clamp(luma(c) - uGradeBalance * 0.25, 0.0, 1.0);
  float bwid = 0.15 + uGradeBlend * 0.35;
  float ws = 1.0 - smoothstep(0.0, 0.33 + bwid, Lg);
  float wh = smoothstep(0.67 - bwid, 1.0, Lg);
  float wm = clamp(1.0 - ws - wh, 0.0, 1.0);
  c += gradeTint(uGS) * ws + gradeTint(uGM) * wm + gradeTint(uGH) * wh;
  c = clamp(c, 0.0, 1.0);

  // ---- Masks (local adjustments).
  float w0 = maskW(uv, uM0Geo, uM0Cfg, texture(uMask0, tex(uv)).r);
  float w1 = maskW(uv, uM1Geo, uM1Cfg, texture(uMask1, tex(uv)).r);
  float w2 = maskW(uv, uM2Geo, uM2Cfg, texture(uMask2, tex(uv)).r);
  if (w0 > 0.001) { c = mix(c, localAdjust(c, uM0A, uM0B), w0); }
  if (w1 > 0.001) { c = mix(c, localAdjust(c, uM1A, uM1B), w1); }
  if (w2 > 0.001) { c = mix(c, localAdjust(c, uM2A, uM2B), w2); }

  // ---- Vignette (follows the crop).
  if (abs(uVignette) > 0.001) {
    float dist = length((uv - uVigC) / uVigR) / 1.4142;
    float start = uVigMid * 0.8;
    float v = smoothstep(start, start + mix(0.05, 1.0, uVigFeather), dist);
    c = uVignette < 0.0 ? c * (1.0 + uVignette * v)
                        : mix(c, vec3(1.0), uVignette * v * 0.8);
  }

  // ---- Grain.
  if (uGrain > 0.001) {
    float gs = mix(1.0, 4.0, uGrainSize) * max(1.0, longEdge / 1600.0);
    vec2 gp = floor(uv * uSize / gs);
    float n = (hash(gp) + hash(gp + vec2(17.0, 31.0))) * 0.5 - 0.5;
    float lg = luma(c);
    c += vec3(n * uGrain * 0.45 * (1.0 - 0.6 * abs(2.0 * lg - 1.0)));
  }

  c = clamp(c, 0.0, 1.0);

  if (uShowMask > 0.5) {
    float w = uShowMask < 1.5 ? w0 : (uShowMask < 2.5 ? w1 : w2);
    c = mix(c, vec3(1.0, 0.16, 0.16), w * 0.5);
  }

  fragColor = vec4(c * alpha, alpha);
}
