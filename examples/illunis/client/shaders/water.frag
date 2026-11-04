// Reflection pass. The whole screen is one water surface that reflects the
// sky above it; there is no horizon line and no mirrored half.
//
// Model, per pixel:
//   1. A virtual camera at height CAM_H looks down (PITCH) at the plane y=0.
//      The pixel's view ray hits the plane at a surface point p (x, z).
//   2. The surface normal is tilted by the gradient of a height field:
//      two slow swell sines, three capillary value-noise octaves (faded with
//      distance so they do not alias), and travelling rings around the
//      walker. Voice loudness scales all three.
//   3. The view ray is reflected about that normal and the reflected
//      direction is looked up in an equirectangular sky image:
//        u = 0.5 + azimuth / 2pi   (azimuth 0 = camera forward, + to the right)
//        v = 0.5 - elevation / pi  (v 0 = zenith, 0.5 = horizon)
//   4. Physical Schlick Fresnel (F0 = 0.02, water in air) times a display
//      exposure mixes the sky with a dark water colour. Real water reflects
//      about 2% of the sky at the screen centre; the exposure scales that so
//      the screen-mean reflectance stays close to the old 0.62-floor look
//      (measured in test/shader/water_pass_render_test.dart), and a soft knee
//      (1 - exp) keeps the grazing far water from clipping. A slight cool tint
//      follows.
//   5. Sun glint: a Beckmann specular lobe around the sun's mirror direction,
//      using the same normal n, Fresnel and exposure as the sky. Its width
//      (slope variance m2) grows with uStillness and loudness, plus the slope
//      variance of capillary octaves faded out by the pixel footprint, so the
//      glitter path widens with the waves and toward the horizon.
//   6. Distance haze: the colour fades toward the sky just above the horizon
//      (at the pixel's view azimuth) with the path length beyond the nadir
//      distance, so the far water at the top of the screen softens. Then the
//      optional screen-edge vignette.
//
// Resolution: the shader runs once per physical pixel (Flutter rasterises
// the rect at device resolution); FlutterFragCoord is in logical pixels,
// matching uSize. Cost per pixel: 3 noise octaves (4 hashes each), 3 sines,
// 4 exp, 2 atan, 1 asin, 2 texture reads (5 with the roughness blur), plus
// one exp and one cos per live voice ripple (none when silent). No loops.
//
// Uniform order (float slots). water_pass.dart sets them in this order, and
// test/shader/water_pass_render_test.dart mirrors the calm-water constants
// (CAM_H, PITCH, FOV_S, F0, REFL_K, haze, tint, water colour). Keep all three
// in step.
//   0,1  uSize      canvas size in logical pixels
//   2    uTime      seconds
//   3,4  uWalker    walker position on screen, normalised 0..1 (may be off-screen)
//   5    uLoud      voice loudness 0..1
//   6    uVignette  edge darkening strength 0..1 (0 = off)
//   7    uStillness 0 mirror calm .. 1 rough. Scales swell, capillary ripples
//                   and walker rings together, and widens a 4-tap sky blur
//                   (reflection roughness). 1 is the look before this uniform.
//   8-10 uSunDir    unit sun direction in the water frame (x right, y up,
//                   z forward), as SkySun.dir; sky.frag's uSunDir in this frame
//   11-13 uSunCol   sun light for the glint, linear 0..1 per channel
//                   (SkySun colour x intensity); 0 = no glint (night, hidden)
//   14-17 uRipA     voice ripple sources 0 and 1 as (age s, amplitude) pairs
//   18-21 uRipB     voice ripple sources 2 and 3; amplitude 0 = no source.
//                   RippleSources in water_pass.dart computes the fade, so
//                   the shader only shapes one expanding ring per source
//                   around the water point at the screen centre. Not scaled
//                   by uStillness: a step into calm water still shows.
//   sampler 0 uSky  equirectangular sky image (2:1), sampled bilinearly
#version 460 core
#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;
uniform float uTime;
uniform vec2 uWalker;
uniform float uLoud;
uniform float uVignette;
uniform float uStillness;
uniform vec3 uSunDir;
uniform vec3 uSunCol;
uniform vec4 uRipA;
uniform vec4 uRipB;
uniform sampler2D uSky;

out vec4 fragColor;

const float PI = 3.14159265;
const float CAM_H = 1.0;      // camera height above the water
const float PITCH = 0.785398; // 45 degrees below the horizontal
const float FOV_S = 1.2;      // screen height spans 2*atan(0.6), about 62 degrees
const float F0 = 0.02;        // normal-incidence reflectance of water in air
// Display exposure as reflectance at the screen centre (flat water, view ray
// at PITCH). Chosen from rendered output: with 0.62 the test render's mean
// luminance is within 1% of the old 0.62-floor shader (213.3 vs 212.1 on the
// 0..765 r+g+b scale); the render test checks that ratio, not this number.
const float REFL_K = 0.62;
const float SUN_E = 0.35;     // sun irradiance in display units of uSunCol
const float HAZE_K = 0.09;    // haze per unit of path length beyond CAM_H
// Voice ripples: centre where the screen-centre ray meets the water.
const vec2 RIP_C = vec2(0.0, 1.0);  // CAM_H / tan(PITCH) at 45 degrees
const float RIP_SPEED = 0.35; // ring radius growth, surface units per second
const float RIP_K = 30.0;     // ring wavenumber
const float RIP_SLOPE = 0.3;  // peak slope at amplitude 1

float schlick(float c) {
  return F0 + (1.0 - F0) * pow(1.0 - c, 5.0);
}

// Screen uv (0..1, y down) to a unit view ray in world space (y up).
vec3 viewRay(vec2 uv) {
  vec2 s = (uv - 0.5) * vec2(uSize.x / uSize.y, 1.0) * FOV_S;
  vec3 f = vec3(0.0, -sin(PITCH), cos(PITCH));
  vec3 up = vec3(0.0, cos(PITCH), sin(PITCH));
  return normalize(f + vec3(s.x, 0.0, 0.0) - up * s.y);
}

float hash(vec2 p) {
  p = 50.0 * fract(p * 0.3183099 + vec2(0.71, 0.113));
  return fract(p.x * p.y * (p.x + p.y));
}

// Gradient of smooth value noise (analytic, after Inigo Quilez).
vec2 noiseGrad(vec2 x) {
  vec2 i = floor(x);
  vec2 f = fract(x);
  vec2 u = f * f * (3.0 - 2.0 * f);
  vec2 du = 6.0 * f * (1.0 - f);
  float a = hash(i);
  float b = hash(i + vec2(1.0, 0.0));
  float c = hash(i + vec2(0.0, 1.0));
  float d = hash(i + vec2(1.0, 1.0));
  return du * (vec2(b - a, c - a) + (a - b - c + d) * u.yx);
}

// One noise octave of frequency k and slope amp, faded out once a pixel
// covers too much of its period (foot = surface units per logical pixel).
// The faded part's slope variance goes to lost, for the glint's roughness.
vec2 octave(vec2 p, float k, float amp, vec2 drift, float foot, inout float lost) {
  float keep = 1.0 - smoothstep(0.15, 0.45, foot * k);
  float gone = amp * (1.0 - keep);
  lost += 0.5 * gone * gone;
  return noiseGrad(p * k + drift * uTime) * (amp * keep);
}

// Slope of one voice ripple ring (age a, amplitude amp): a wave packet whose
// radius grows with age and whose width spreads, faded like the walker rings
// once a pixel covers too much of a wavelength.
vec2 voiceRing(vec2 p, vec2 src, float foot) {
  if (src.y <= 0.0) return vec2(0.0);
  vec2 dv = p - RIP_C;
  float r = length(dv);
  float w = 0.05 + 0.06 * src.x;
  float x = r - RIP_SPEED * src.x;
  float env = exp(-x * x / (w * w)) * smoothstep(0.0, 0.03, r);
  float keep = 1.0 - smoothstep(0.15, 0.45, foot * RIP_K);
  return (dv / max(r, 1e-4)) * (RIP_SLOPE * src.y * env * keep * cos(x * RIP_K));
}

void main() {
  vec2 uv = FlutterFragCoord().xy / uSize;
  vec3 d = viewRay(uv);
  float t = CAM_H / max(-d.y, 1e-3);      // ray length to the water
  vec2 p = d.xz * t;                       // surface point
  float foot = t * FOV_S / uSize.y;        // pixel footprint on the water

  float rough = clamp(uStillness, 0.0, 1.0);
  float loudBoost = (1.0 + 1.5 * uLoud) * rough;
  vec2 g = vec2(0.0);                      // height-field gradient

  // Slow swell: two long directional waves.
  vec2 k1 = vec2(0.7, 2.1);
  vec2 k2 = vec2(-1.6, 1.1);
  float sw = 0.012 * (1.0 + uLoud) * rough;
  g += k1 * (sw * cos(dot(k1, p) - uTime * 0.7));
  g += k2 * (sw * 0.8 * cos(dot(k2, p) - uTime * 0.55));

  // Fine capillary ripples: three octaves drifting in different directions.
  float lost = 0.0;                        // slope variance faded out
  g += octave(p, 6.0, 0.010 * loudBoost, vec2(0.30, 0.18), foot, lost);
  g += octave(p, 17.0, 0.006 * loudBoost, vec2(-0.45, 0.25), foot, lost);
  g += octave(p, 43.0, 0.004 * loudBoost, vec2(0.20, -0.60), foot, lost);

  // Walker rings, centred where the walker's own view ray meets the water.
  // A walker whose ray misses the water (above the screen) has no rings.
  vec3 wd = viewRay(uWalker);
  vec2 wp = wd.y < -1e-3 ? wd.xz * (CAM_H / -wd.y) : vec2(1e4);
  vec2 dv = p - wp;
  float r = length(dv);
  float fall = exp(-r * 4.0) * smoothstep(0.0, 0.03, r); // no spike at centre
  float kr = 38.0;
  float ringKeep = 1.0 - smoothstep(0.15, 0.45, foot * kr);
  float ringSlope = (0.03 + 0.16 * uLoud) * fall * ringKeep * rough;
  g += (dv / max(r, 1e-4)) * (ringSlope * cos(r * kr - uTime * 2.6));

  // Voice ripples (up to four overlapping rings, summed).
  g += voiceRing(p, uRipA.xy, foot) + voiceRing(p, uRipA.zw, foot) +
       voiceRing(p, uRipB.xy, foot) + voiceRing(p, uRipB.zw, foot);

  vec3 n = normalize(vec3(-g.x, 1.0, -g.y));
  vec3 rd = reflect(d, n);
  rd = normalize(vec3(rd.x, max(rd.y, 0.01), rd.z)); // never below the horizon

  vec2 skyUv = vec2(0.5 + atan(rd.x, rd.z) / (2.0 * PI),
                    0.5 - asin(clamp(rd.y, -1.0, 1.0)) / PI);
  vec3 sky = texture(uSky, skyUv).rgb;
  // Reflection roughness: a small tap ring whose size follows uStillness
  // (u spans 2pi, v spans pi, so the u offsets are halved). Its weight grows
  // with roughness too, so near-calm water keeps 1-texel stars sharp.
  float blur = smoothstep(0.02, 0.25, rough);
  if (blur > 0.0) {
    float sp = 0.006 * rough;
    vec3 ring = (texture(uSky, skyUv + vec2(sp * 0.5, 0.0)).rgb +
                 texture(uSky, skyUv - vec2(sp * 0.5, 0.0)).rgb +
                 texture(uSky, skyUv + vec2(0.0, sp)).rgb) / 3.0;
    sky = mix(sky, 0.4 * sky + 0.6 * ring, blur);
  }

  // Schlick Fresnel with the exposure normalised to the screen centre.
  float expo = REFL_K / schlick(sin(PITCH));
  float cosT = clamp(dot(-d, n), 0.0, 1.0);
  float refl = 1.0 - exp(-expo * schlick(cosT));
  vec3 waterCol = vec3(0.02, 0.05, 0.08);
  vec3 c = mix(waterCol, sky * vec3(0.92, 0.97, 1.0), refl);

  // Sun glint: Beckmann lobe over the half vector. m2 is the slope variance:
  // a floor (about 1 degree), the waves' roughness, and the faded octaves.
  if (uSunDir.y > 0.0 && dot(uSunCol, uSunCol) > 0.0) {
    vec3 v = -d;
    vec3 h = normalize(uSunDir + v);
    float nh = max(dot(n, h), 1e-3);
    float nh2 = nh * nh;
    float m2 = 3e-4 + 0.012 * rough * (1.0 + 1.5 * uLoud) + lost;
    float D = exp((nh2 - 1.0) / (nh2 * m2)) / (PI * m2 * nh2 * nh2);
    float Fh = 1.0 - exp(-expo * schlick(clamp(dot(v, h), 0.0, 1.0)));
    float nv = max(dot(n, v), 1e-3);
    c += uSunCol * (SUN_E * D * Fh / (4.0 * nv));
  }

  // Distance haze toward the sky just above the horizon at this azimuth.
  vec3 horizon = texture(uSky, vec2(0.5 + atan(d.x, d.z) / (2.0 * PI), 0.49)).rgb;
  c = mix(c, horizon, 1.0 - exp(-HAZE_K * max(t - CAM_H, 0.0)));

  vec2 e = (uv - 0.5) * 2.0;
  c *= 1.0 - uVignette * 0.35 * smoothstep(0.55, 1.25, length(e));
  fragColor = vec4(c, 1.0);
}
