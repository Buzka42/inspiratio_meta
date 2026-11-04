#version 460 core
#include <flutter/runtime_effect.glsl>

precision highp float;

// ---------------------------------------------------------------------------
// Illunis sky. One pass: atmosphere, sun, twilight, moonlit night,
// the galactic band, a shaded moon, the ground, grain. Catalog stars are
// Canvas points, not this shader. Geometry is a stereographic camera
// standing on the ground looking at the horizon — the inverse of
// lib/sky/sky_camera.dart, which must stay in step with this.
//
// Ported unchanged (maths and look) from the original Illunis app.
// Uniform order matters: lib/sky/sky_shader.dart writes them by index
// (SkyShader.uniforms), 44 floats in total. test/sky/sky_shader_test.dart
// checks that this table and that list agree.
// ---------------------------------------------------------------------------

uniform vec2  uSize;        // 0,1  render target size, px
uniform vec2  uPrincipal;   // 2,3  principal point (on the horizon), px
uniform float uFocal;       // 4    focal length, px
uniform float uAzimuth;     // 5    camera bearing, rad, from north via east
uniform vec3  uSunDir;      // 6-8  horizontal frame: x east, y up, z south
uniform vec3  uMoonDir;     // 9-11
uniform float uSidereal;    // 12   local sidereal time, rad
uniform float uLatitude;    // 13   rad
uniform float uTurbidity;   // 14   ~2 crisp .. ~8 murky
uniform float uMie;         // 15   aerosol scale
uniform float uExposure;    // 16
uniform float uStillness;   // 17   0 restless .. 1 still
uniform float uTime;        // 18   seconds
uniform float uMoonRadius;  // 19   angular radius, rad
uniform float uSunRadius;   // 20   angular radius, rad
uniform float uMoonIllum;   // 21   0..1
uniform float uDayness;     // 22   0 night .. 1 day (perceptual)
uniform vec4  uPlanet0;     // 23-26 Mercury: dir.xyz, brightness (0 = hidden)
uniform vec4  uPlanet1;     // 27-30 Venus
uniform vec4  uPlanet2;     // 31-34 Mars
uniform vec4  uPlanet3;     // 35-38 Jupiter
uniform vec4  uPlanet4;     // 39-42 Saturn
uniform float uPixelScale;  // 43   device pixels per uniform pixel (1 when pre-scaled)

out vec4 fragColor;

const float PI = 3.141592653589793;
const vec3  UP = vec3(0.0, 1.0, 0.0);

// --- hashing / noise -------------------------------------------------------

float hash21(vec2 p) {
  vec3 p3 = fract(vec3(p.xyx) * 0.1031);
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.x + p3.y) * p3.z);
}

float hash31(vec3 p) {
  p = fract(p * 0.3183099 + 0.1);
  p *= 17.0;
  return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float noise3(vec3 x) {
  vec3 i = floor(x);
  vec3 f = fract(x);
  f = f * f * (3.0 - 2.0 * f);
  return mix(
    mix(mix(hash31(i + vec3(0, 0, 0)), hash31(i + vec3(1, 0, 0)), f.x),
        mix(hash31(i + vec3(0, 1, 0)), hash31(i + vec3(1, 1, 0)), f.x), f.y),
    mix(mix(hash31(i + vec3(0, 0, 1)), hash31(i + vec3(1, 0, 1)), f.x),
        mix(hash31(i + vec3(0, 1, 1)), hash31(i + vec3(1, 1, 1)), f.x), f.y),
    f.z);
}

float fbm3(vec3 p) {
  float a = 0.5, s = 0.0;
  for (int i = 0; i < 3; i++) {
    s += a * noise3(p);
    p = p * 2.03 + 11.7;
    a *= 0.5;
  }
  return s;
}

// --- camera ----------------------------------------------------------------

vec3 rayDir(vec2 frag) {
  vec2 q = vec2(frag.x - uPrincipal.x, -(frag.y - uPrincipal.y)) / uFocal;
  float r2 = dot(q, q);
  float cz = (4.0 - r2) / (4.0 + r2);
  float s = 4.0 / (4.0 + r2);
  vec2 c = q * s;
  vec3 fwd = vec3(sin(uAzimuth), 0.0, -cos(uAzimuth));
  vec3 rgt = vec3(cos(uAzimuth), 0.0, sin(uAzimuth));
  return normalize(rgt * c.x + UP * c.y + fwd * cz);
}

// --- atmosphere (Preetham-family single scattering, after three.js Sky) ----

const vec3  RAYLEIGH = vec3(5.804542996261093e-6, 1.3562911419845635e-5, 3.0265902468824876e-5);
const vec3  MIE_CONST = vec3(1.8399918514433978e14, 2.7798023919660528e14, 4.0790479543861094e14);
const float RAYLEIGH_ZENITH = 8.4e3;
const float MIE_ZENITH = 1.25e3;
const float CUTOFF = 1.6110731556870734;  // rad, sun stops lighting the air
const float STEEPNESS = 1.5;
const float EE = 1000.0;
const float MIE_G = 0.80;

float sunIntensity(float zenithCos) {
  zenithCos = clamp(zenithCos, -1.0, 1.0);
  return EE * max(0.0, 1.0 - exp(-((CUTOFF - acos(zenithCos)) / STEEPNESS)));
}

vec3 totalMie(float T) {
  float c = (0.2 * T) * 10.0e-18;
  return 0.434 * c * MIE_CONST;
}

// Radiance of the air along `dir` lit by `light` with strength `E`.
vec3 scatter(vec3 dir, vec3 light, float E, vec3 betaR, vec3 betaM) {
  float zenith = acos(max(0.0, dir.y));
  float inv = 1.0 / (max(0.0, dir.y) + 0.15 * pow(93.885 - degrees(zenith), -1.253));
  vec3 Fex = exp(-(betaR * RAYLEIGH_ZENITH * inv + betaM * MIE_ZENITH * inv));

  float cosT = dot(dir, light);
  float rPhase = 0.05968310365946075 * (1.0 + cosT * cosT);
  float g2 = MIE_G * MIE_G;
  float phaseBase = 1.0 - 2.0 * MIE_G * cosT + g2;
  float mPhase = 0.07957747154594767 * ((1.0 - g2) / (phaseBase * sqrt(phaseBase)));
  vec3 betaTheta = betaR * rPhase + betaM * mPhase;

  vec3 lightTerm = E * (betaTheta / (betaR + betaM));
  vec3 radiance = max(lightTerm * (1.0 - Fex), 0.0);
  vec3 Lin = radiance * sqrt(radiance);
  float horizon = 1.0 - light.y;
  float horizon2 = horizon * horizon;
  Lin *= mix(vec3(1.0),
             sqrt(max(lightTerm * Fex, 0.0)),
             clamp(horizon2 * horizon2 * horizon, 0.0, 1.0));
  return Lin;
}

vec3 extinction(vec3 dir, vec3 betaR, vec3 betaM) {
  float zenith = acos(max(0.0, dir.y));
  float inv = 1.0 / (max(0.0, dir.y) + 0.15 * pow(93.885 - degrees(zenith), -1.253));
  return exp(-(betaR * RAYLEIGH_ZENITH * inv + betaM * MIE_ZENITH * inv));
}

// --- galactic band ---------------------------------------------------------

vec3 rotateAxis(vec3 v, vec3 axis, float a) {
  float c = cos(a), s = sin(a);
  return v * c + cross(axis, v) * s + axis * (dot(axis, v) * (1.0 - c));
}

// Horizontal → equatorial: y is the celestial pole, z is RA 0, x is RA 90°.
vec3 toEquatorial(vec3 d) {
  vec3 pole = vec3(0.0, sin(uLatitude), -cos(uLatitude));
  vec3 e = rotateAxis(d, pole, uSidereal);
  float a = PI * 0.5 - uLatitude;
  float c = cos(a), s = sin(a);
  return vec3(e.x, e.y * c - e.z * s, e.y * s + e.z * c);
}

// A planet is a steady point: no twinkle, its own tint, sized by brightness.
vec3 planetPoint(vec3 d, vec4 p, vec3 tint, float pxAngle) {
  if (p.w <= 0.0 || dot(d, p.xyz) <= 0.0) return vec3(0.0);
  float ang = length(cross(d, p.xyz));
  float radius = pxAngle * (0.9 + 0.9 * p.w);
  float core = exp(-(ang * ang) / (radius * radius * 0.5));
  return tint * core * (0.35 + 2.2 * p.w);
}

const vec3 GALACTIC_POLE = vec3(-0.198, 0.456, -0.868);

vec3 galaxy(vec3 e) {
  float lat = asin(clamp(dot(e, GALACTIC_POLE), -1.0, 1.0));
  float band = exp(-(lat * lat) / (0.16 * 0.16));
  // Outside the band its maximum contribution is far below one output code
  // value. Do not evaluate six octaves of invisible galactic dust there.
  if (band < 0.00001) return vec3(0.0);
  float clumps = fbm3(e * 5.5) * 0.8 + 0.2;
  float dust = smoothstep(0.35, 0.65, fbm3(e * 9.0 + 3.1));
  return vec3(0.62, 0.66, 0.78) * band * clumps * (1.0 - 0.55 * dust) * 0.055;
}

// --- tone ------------------------------------------------------------------

vec3 aces(vec3 x) {
  return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0);
}

float luma(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }

// ---------------------------------------------------------------------------

void main() {
  vec2 frag = FlutterFragCoord().xy;
  vec3 d = rayDir(frag);
  bool ground = d.y < 0.0;
  vec3 dSky = ground ? normalize(vec3(d.x, 0.0035, d.z)) : d;

  // Sun: real direction lights the disc; a horizon-clamped stand-in keeps
  // twilight scattering alive until the sun is 18° down.
  float sunAltDeg = degrees(asin(clamp(uSunDir.y, -1.0, 1.0)));
  vec3 sunFlat = normalize(vec3(uSunDir.x, max(uSunDir.y, -0.012), uSunDir.z));
  float twilight = smoothstep(-18.0, -0.7, sunAltDeg);
  float sunfade = 1.0 - clamp(1.0 - exp(uSunDir.y * 0.89), 0.0, 1.0);

  float rayleighCoef = 3.1 - (1.0 - sunfade);
  vec3 betaR = RAYLEIGH * rayleighCoef;
  vec3 betaM = totalMie(uTurbidity) * 0.0014 * uMie;

  float E = sunIntensity(dot(sunFlat, UP)) * pow(twilight, 1.5);
  vec3 sky = vec3(0.0);
  if (E > 0.0) sky = scatter(dSky, sunFlat, E, betaR, betaM);

  // Moonlight: the same air, a far dimmer lamp, seen with an adapted eye.
  float moonUp = smoothstep(-0.05, 0.12, uMoonDir.y);
  float moonE = sunIntensity(dot(uMoonDir, UP)) * 0.0032 * (0.08 + 0.92 * uMoonIllum) * moonUp;
  if (moonE > 0.0) sky += scatter(dSky, uMoonDir, moonE, betaR, betaM * 0.6);

  float night = 1.0 - uDayness;

  // Sun, per pixel from its real direction: a limb-darkened disc and a soft
  // core glare, both extinguished by the air in front of them, so the colour
  // is white-warm high up and reddens at the horizon through the same
  // extinction that colours the sky. Twilight fades it out below the
  // horizon. A radius of 0 leaves it out (the Reflection bake when the
  // water draws the sun per pixel); the baked equirect keeps this disc as
  // the water's fallback while that renderer loads.
  if (uSunDir.y >= -0.004 && uSunRadius > 0.0) {
    float cosSun = dot(dSky, uSunDir);
    // Squared angle from the centre in sun radii; 1 - cos ~ theta^2 / 2.
    float x2 = 2.0 * (1.0 - cosSun) / (uSunRadius * uSunRadius);
    if (x2 < 144.0) {  // the glare is below one code value beyond 12 r
      float glare = 1.0 / (1.0 + x2);
      glare *= glare * glare;
      float disc = smoothstep(cos(uSunRadius), cos(max(uSunRadius - 1.4 / (uFocal * uPixelScale), 0.0)), cosSun);
      // Linear limb darkening I(mu) = 1 - u(1 - mu), u near 0.6 in the
      // visible and larger in the blue; mu = cos of the angle on the surface.
      float mu = sqrt(max(1.0 - x2, 0.0));
      vec3 limb = 1.0 - vec3(0.50, 0.60, 0.72) * (1.0 - mu);
      vec3 light = sunIntensity(dot(uSunDir, UP)) * extinction(dSky, betaR, betaM) * twilight;
      sky += light * (19000.0 * disc * limb + 40.0 * glare);
    }
  }

  // Deep sky. Stars fade under twilight and behind the horizon's air.
  float starVis = (1.0 - smoothstep(-15.0, -5.0, sunAltDeg)) * smoothstep(-0.01, 0.10, dSky.y);
  vec3 deep = vec3(0.0);
  if (starVis > 0.002 && !ground) {
    vec3 e = toEquatorial(dSky);
    deep = galaxy(e) * starVis;
    // The moon's glare and its scattered light both hide stars near it.
    deep *= 1.0 - 0.75 * uMoonIllum * moonUp * pow(max(dot(dSky, uMoonDir), 0.0), 24.0);
  }
  // Planets carry their own visibility (in .w), so they show in twilight
  // before any star does.
  if (!ground) {
    float pxAngle = 1.15 / (uFocal * uPixelScale);
    deep += planetPoint(dSky, uPlanet0, vec3(0.90, 0.90, 0.88), pxAngle);
    deep += planetPoint(dSky, uPlanet1, vec3(1.00, 0.98, 0.94), pxAngle);
    deep += planetPoint(dSky, uPlanet2, vec3(1.00, 0.72, 0.52), pxAngle);
    deep += planetPoint(dSky, uPlanet3, vec3(1.00, 0.95, 0.84), pxAngle);
    deep += planetPoint(dSky, uPlanet4, vec3(0.98, 0.92, 0.72), pxAngle);
  }

  // One radiance compression followed by one output transfer. The old
  // pre-tone power plus final gamma bleached the blue out of clear noon.
  vec3 adapted = pow(max(sky * 0.04, 0.0), vec3(1.0 / (1.2 + 1.2 * sunfade)));
  vec3 response = mix(adapted, max(sky, 0.0) * 0.012,
      smoothstep(0.0, 18.0, sunAltDeg));
  vec3 col = aces(response * uExposure);
  // Airglow floor, in display-linear units, so a moonless night is a deep
  // navy rather than black — and never a milky blue.
  col += vec3(0.0060, 0.0085, 0.0150) * (0.55 + 0.45 * dSky.y) * night;
  // Stars only where the sky is dark enough to show them.
  col += deep * clamp(1.0 - luma(col) * 3.0, 0.0, 1.0);

  // Moon: a lit sphere with a Lommel–Seeliger surface, composited additively
  // so by day only the lit limb rises above the sky and the dark side vanishes.
  float cosMoon = dot(d, uMoonDir);
  float moonMask = smoothstep(cos(uMoonRadius), cos(max(uMoonRadius - 1.4 / (uFocal * uPixelScale), 0.0)), cosMoon);
  if (moonMask > 0.0 && !ground) {
    vec3 o = d - uMoonDir * cosMoon;
    float sinAng = max(length(o), 1e-6);
    float rho = clamp(sinAng / sin(uMoonRadius), 0.0, 1.0);
    vec3 oh = o / sinAng;
    float ce = sqrt(max(1.0 - rho * rho, 0.0));
    vec3 n = normalize(oh * rho - uMoonDir * ce);
    float ci = max(dot(n, uSunDir), 0.0);
    float ls = (ci + ce > 1e-4) ? ci / (ci + ce) : 0.0;
    vec3 reference = abs(uMoonDir.y) > 0.99 ? vec3(0.0, 0.0, 1.0) : UP;
    vec3 t1 = normalize(cross(reference, uMoonDir));
    vec3 t2 = cross(uMoonDir, t1);
    vec3 local = vec3(dot(n, t1), dot(n, t2), ce);
    float maria = smoothstep(0.42, 0.62, fbm3(local * 2.6 + 7.3));
    float fine = fbm3(local * 9.0 + 1.7);
    float albedo = mix(1.0, 0.58, maria) * (0.9 + 0.2 * fine);
    float lit = 2.0 * ls * albedo;
    vec3 moonCol = vec3(0.98, 0.97, 0.94) * (lit * 0.92 + 0.028 * albedo);
    float skyL = luma(col);
    col = min(col + moonCol * (1.0 - skyL) * moonMask, vec3(1.0));
  }
  // A soft halo, night only.
  col += vec3(0.60, 0.66, 0.78) * 0.16 * uMoonIllum * moonUp * night * pow(max(cosMoon, 0.0), 700.0);

  // Ground: a matte field that takes the horizon's light and holds figures.
  if (ground) {
    float depth = -d.y;
    vec3 base = vec3(0.0105, 0.0115, 0.0135);
    vec3 horizonLight = col;
    float fog = exp(-depth * 26.0);
    vec3 g = base + horizonLight * 0.028;
    g = mix(g, horizonLight * 0.30 + base, fog * 0.8);
    g *= 1.0 - smoothstep(0.0, 0.9, depth) * 0.4;
    float l = luma(g);
    if (l > 0.040) g *= 0.040 / l;
    col = g;
  }

  // Dither in the output transfer space, at physical pixel frequency.
  // Linear-space noise near black was amplified by gamma into grey speckle.
  // Two independent hashes form triangular noise with one code-value peak;
  // highp and bounded inputs survive mobile Vulkan without sine-hash stripes.
  col = pow(max(col, 0.0), vec3(1.0 / 2.2));
  vec2 pixel = floor(frag * uPixelScale);
  float dither = hash21(pixel) + hash21(pixel + vec2(17.0, 59.0)) - 1.0;
  float motion = floor(uTime * 12.0) * night;
  float grain = hash21(pixel + mod(motion, 1024.0)) - 0.5;
  col += dither / 255.0 + grain * night * (1.25 - uStillness) * 0.006;
  fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
