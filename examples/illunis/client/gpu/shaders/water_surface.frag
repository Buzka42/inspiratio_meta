// Render pass: the whole screen is one water surface reflecting the sky.
// Same camera, sky lookup and Fresnel as option A (client/shaders/water.frag),
// but the surface normal comes from the simulated heightfield, with option A's
// analytic swell and capillary octaves layered on for sub-texel detail and for
// the far field outside the simulated patch.
//
// Per pixel:
//   1. The view ray from a camera at height cam.x, pitched cam.y below the
//      horizontal, hits the plane y = 0 at p = (x, z).
//   2. p is mapped into the simulated patch (domain); a 4-tap central
//      difference of the height texture gives the slope in world units.
//      The sim slope fades out over the last few percent of the patch.
//   3. Analytic swell + three noise octaves (footprint-faded) are added.
//   4. Reflect about the normal, look up the equirectangular sky
//      (u = 0.5 + azimuth / 2pi, v = 0.5 - elevation / pi).
//   5. Per screen pixel, not from the bake: catalog stars and planets as
//      anti-aliased discs (a star grid over the upper hemisphere, one cell
//      per layer read under the pixel), then the moon from a disc picture
//      made at its on-screen size. The bake holds only the smooth sky.
//   6. Fresnel mix with the water colour, tint, optional vignette, then
//      dither and night grain at physical pixel frequency.
uniform FrameInfo {
  vec4 screen;  // width, height (physical px), time (s), loudness 0..1
  vec4 cam;     // height, pitch (rad), fov scale, vignette 0..1
  vec4 domain;  // world x0, z0, x1, z1 of the simulated patch
  vec4 sim;     // sim width, height (texels), height scale (world / unit), detail 0..1
  vec4 look;    // stillness 0 mirror calm .. 1 rough, baked halo, moon exposure, moon glow
  vec4 moonDir;   // water-frame centre xyz, tan(angular radius) (0 = no moon)
  vec4 moonRight; // xyz, disc radius / picture side
  vec4 moonUp;    // xyz, night grain amplitude
  vec4 stars;     // grid columns, rows per layer (0 = no stars), rad per px, reserved
  // Day (sky_detail.dart SkySun / SkyClouds). day.x == 0 skips all of it.
  vec4 sun;       // water-frame unit xyz, angular radius (rad)
  vec4 sunLight;  // linear transmittance rgb, intensity 0..1
  vec4 day;       // dayFade 0..1, cloud tier 0/1, cloud shadow 0..1, 1 / tile period (world)
  vec4 cloud;     // coverage 0..1, density, plane height / tile period (0 = no clouds),
                  // plate side in texels (0 = procedural clouds)
  vec4 wind;      // base uv offset xy (0..1; plates: plate A sample 1, 0..2), detail uv offset xy (0..1)
  vec4 cirrus;    // cirrus uv offset xy (wrapped 0..1), plate B sample 1 uv offset xy (0..2)
  vec4 plates;    // plate A sample 2 uv offset xy, plate B sample 2 uv offset xy (0..2)
  // Night clouds (sky_detail.dart CloudNight). night.x == 0: day only.
  vec4 nightMoon; // water-frame moon unit xyz, moonlight 0..1 (illumination x above horizon)
  vec4 night;     // night cloud weight 0..1 (1 - dayFade), unused, unused, unused
}
frame;

uniform sampler2D heights;
uniform sampler2D sky;
uniform sampler2D starGrid;
uniform sampler2D moonDisc;
uniform sampler2D clouds;  // tileable, repeat + linear: r base, g detail, b cirrus
// Cloud plates (cloud.w > 0): cumulus_02 (A) and cumulus_06 (B), clouds on
// pure black, brightness = opacity. Bound with MIRROR addressing (used: the
// ray's plate uv runs far outside 0..1, and the plates' seams are not
// invisible, 02 L/R 6.4 T/B 16.7, 06 4.8/11.0 per 255), so every edge
// continues into its own reflection; the offsets wrap on 2 for that reason.
uniform sampler2D plateA;
uniform sampler2D plateB;

in vec2 v_uv;
out vec4 frag_color;

const float PI = 3.14159265;

vec3 viewRay(vec2 uv) {
  vec2 s = (uv - 0.5) * vec2(frame.screen.x / frame.screen.y, 1.0) * frame.cam.z;
  float pitch = frame.cam.y;
  vec3 f = vec3(0.0, -sin(pitch), cos(pitch));
  vec3 up = vec3(0.0, cos(pitch), sin(pitch));
  return normalize(f + vec3(s.x, 0.0, 0.0) - up * s.y);
}

float hash(vec2 p) {
  p = 50.0 * fract(p * 0.3183099 + vec2(0.71, 0.113));
  return fract(p.x * p.y * (p.x + p.y));
}

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

vec2 octave(vec2 p, float k, float amp, vec2 drift, float foot, float time) {
  float keep = 1.0 - smoothstep(0.15, 0.45, foot * k);
  return noiseGrad(p * k + drift * time) * (amp * keep);
}

float hash21(vec2 p) {
  vec3 p3 = fract(vec3(p.xyx) * 0.1031);
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.x + p3.y) * p3.z);
}

// One star cell: alpha-over a disc of the cell's star onto col. pa is the
// pixel's angular footprint (from screen derivatives, so ripples widen it).
vec3 starCell(vec3 col, vec3 rd, vec2 cellUv, float pa) {
  vec4 s = texture(starGrid, cellUv);
  if (s.w < 0.5) return col;
  float a = floor(s.w / 65536.0 + 1e-4);
  float rest = s.w - a * 65536.0;
  float rq = floor(rest / 256.0 + 1e-4);
  float tint = (rest - rq * 256.0) / 255.0;
  float alpha = a / 255.0;
  float rPx = rq / 16.0;
  float ang = length(cross(rd, s.xyz));
  if (dot(rd, s.xyz) <= 0.0) return col;
  float px = frame.stars.z;
  float rAng = rPx * px;
  float cov = clamp((rAng - ang) / pa + 0.5, 0.0, 1.0);
  // A faint glow around bright stars, a few pixels wide.
  float g = ang / (px * (1.5 + 2.0 * rPx));
  float glow = smoothstep(1.2, 2.6, rPx) * 0.22 * exp(-g * g);
  vec3 c = mix(vec3(0.773, 0.831, 1.0), vec3(1.0, 0.784, 0.627), tint);
  return mix(col, c, clamp(alpha * max(cov, glow), 0.0, 1.0));
}

// Moon aureole at angle theta from the centre of a disc of angular radius
// rho, 1 at the limb: forward scattering by haze falls off roughly as
// 1 / angle^2 outside the disc, plus a faint wide skirt.
float aureole(float theta, float rho) {
  float x = max(theta / rho, 1.0);
  float skirt = theta / (8.0 * rho);
  return 0.9 / (x * x) + 0.1 * exp(-skirt * skirt);
}

// --- Day: clouds and sun --------------------------------------------------
// Moonlight on the clouds, linear, for a full moon: the aureole's blue-white
// (0.62, 0.68, 0.80), low enough that a thin edge 90 degrees from the moon
// stays near the night sky (display ~0.06) and only the rim near the moon
// (forward scattering, phase up to 12x) reaches about 0.18.
const vec3 MOON_CLOUD = vec3(0.0034, 0.0037, 0.0044);
// Sky glow on a cloud base at night, x the bake's zenith: below 1, so the
// cloud reads darker than the sky around it (it hides the airglow and the
// stars above it), as an unlit cloud does away from city light.
const float NIGHT_AMB = 0.55;
// One cloud plane. q is the unwrapped base-layer uv of a ray,
// rd.xz / rd.y * height / tilePeriod; the wind offsets come in wrapped.
const float DETAIL_SCALE = 3.7;   // detail layer frequency vs base (Dart detailScale)
const float CIRRUS_SCALE = 1.6;   // cirrus layer frequency vs base (Dart cirrusScale)

// Cloud thickness at q: 0 outside, ~1 well inside, up to ~2.5 in the cores
// (unclamped, so the light tap still sees a gradient inside a cloud). The
// detail layer erodes the edges more than the cores. keepD fades the detail
// layer and keepB the base toward its average as the pixel footprint
// outgrows them.
float cloudDensity(vec2 q, float keepB, float keepD) {
  float n = texture(clouds, q + frame.wind.xy).r;
  float det = texture(clouds, q * DETAIL_SCALE + frame.wind.zw).g - 0.5;
  float thr = 1.0 - frame.cloud.x;
  float edge = 1.0 - smoothstep(0.0, 0.3, n - thr);  // 1 at the edge, 0 in the core
  n += det * (0.35 + 0.5 * edge) * keepD;
  float h = max(n - thr, 0.0) / 0.3;
  return mix(0.4 * frame.cloud.x, h, keepB);
}

// Plates: the same thickness scale from plate brightness (black = clear).
// Anti-tiling, so no repeat period shows:
//  - Each plate is sampled twice, at two scales and rotations, each with its
//    own offset (Dart SkyClouds.plateLayers / plateOffsets). A slow weight
//    field (incommensurate sines, ~13 km) picks between the two samples, so
//    locally one dominates at full contrast and neither period repeats.
//  - Every sample uses a half-offset blend: near its mirror lines (integer
//    uv) a second fetch at uv + 0.5, whose own lines are mid-plate, takes
//    over, so the mirror fold never shows. The second fetch is skipped
//    where it has no weight (~70% of the plate).
//  - Blends keep the variance (contrast) about the plate mean, so mixed
//    zones are not washed out; black (clear) stays clear.
// The plates' own colour is not used (cumulus_06 is warm-toned); the sun
// and sky light them as the procedural clouds. keep fades each plate toward
// a far-field mean as the pixel footprint outgrows its texels (no mipmaps
// in flutter_gpu); fully faded, no fetch is made at all.
// Per sample: vec4(scale, angle rad, unused, unused); Dart SkyClouds.plateLayers.
const vec4 PLATE_A1 = vec4(1.0, 0.0, 0.0, 0.0);
const vec4 PLATE_A2 = vec4(1.37, 2.2, 0.0, 0.0);
const vec4 PLATE_B1 = vec4(1.7, 0.6, 0.0, 0.0);
const vec4 PLATE_B2 = vec4(2.3, -1.1, 0.0, 0.0);
const float PLATE_MEAN = 0.3;     // mean plate brightness (02: 0.35, 06: 0.31)
const float PLATE_A_FAR = 0.08;   // far-field mean thickness (as 0.4 * coverage procedurally)
const float PLATE_B_FAR = 0.04;

float plateLuma(vec4 c) { return dot(c.rgb, vec3(0.2126, 0.7152, 0.0722)); }

vec2 plateUv(vec2 q, vec4 l, vec2 off) {
  float c = cos(l.y), s = sin(l.y);
  return vec2(c * q.x - s * q.y, s * q.x + c * q.y) * l.x + off;
}

// Contrast-keeping blend of a and b with weight w on b.
float keepBlend(float a, float b, float w) {
  float k = inversesqrt((1.0 - w) * (1.0 - w) + w * w);
  return clamp(PLATE_MEAN + ((1.0 - w) * (a - PLATE_MEAN) + w * (b - PLATE_MEAN)) * k, 0.0, 1.0);
}

// One mirrored sample with the half-offset blend. texture(): no mip chain, so
// level 0 is what every fetch reads. GL_EXT_shader_texture_lod is not on the
// Blade GPU, so textureLod is not used.
float plateTap(sampler2D t, vec2 uv) {
  vec2 e = 1.0 - abs(fract(uv) - 0.5) * 2.0;  // 0 on a mirror line, 1 mid-plate
  float w = smoothstep(0.0, 0.16, min(e.x, e.y));
  float a = 0.0, b = 0.0;
  if (w > 0.0) a = plateLuma(texture(t, uv));
  if (w < 1.0) b = plateLuma(texture(t, uv + 0.5));
  if (w >= 1.0) return a;
  if (w <= 0.0) return b;
  return keepBlend(b, a, w);
}

// Weight of a layer's second sample at plane point q (static on the plane,
// so a drifting cloud slowly changes shape as it crosses it).
float layerWeight(vec2 q, float k) {
  float n = sin(dot(q, vec2(2.3, 1.7)) + k) * sin(dot(q, vec2(-1.1, 2.9)) + 1.3 * k);
  return smoothstep(-0.1, 0.1, n);  // narrow: one sample rules locally
}

float plateLayer(sampler2D t, vec2 q, vec4 l1, vec2 o1, vec4 l2, vec2 o2, float k) {
  float w = layerWeight(q, k);
  float a = 0.0, b = 0.0;
  if (w < 1.0) a = plateTap(t, plateUv(q, l1, o1));
  if (w > 0.0) b = plateTap(t, plateUv(q, l2, o2));
  if (w <= 0.0) return a;
  if (w >= 1.0) return b;
  return keepBlend(a, b, w);
}

float plateDensity(vec2 q, float keepA, float keepB) {
  // Black level 3/255; coverage under 0.8 raises the cut (0.36 at the
  // default 0.45), so fewer, smaller clouds and no grey veil; the cut is
  // soft (thickness ramps from it), so cloud edges stay feathered.
  float thr = 0.012 + 1.0 * max(0.8 - frame.cloud.x, 0.0);
  float tb = min(thr + 0.2, 0.8);
  float d = 0.0;
  if (keepA > 0.0) {
    float a = plateLayer(plateA, q, PLATE_A1, frame.wind.xy, PLATE_A2, frame.plates.xy, 0.0);
    d += keepA * 1.8 * max(a - thr, 0.0) / (1.0 - thr);
  }
  if (keepB > 0.0) {
    float b = plateLayer(plateB, q, PLATE_B1, frame.cirrus.zw, PLATE_B2, frame.plates.zw, 2.1);
    d += keepB * 0.7 * max(b - tb, 0.0) / (1.0 - tb);
  }
  return d + (1.0 - keepA) * PLATE_A_FAR + (1.0 - keepB) * PLATE_B_FAR;
}

// Henyey-Greenstein, divided by its value at 90 degrees.
float hgRatio(float c, float g) {
  float g2 = g * g;
  return pow((1.0 + g2) / (1.0 + g2 - 2.0 * g * c), 1.5);
}

vec3 toLin(vec3 c) { return pow(max(c, 0.0), vec3(2.2)); }
vec3 toDisplay(vec3 c) { return pow(max(c, 0.0), vec3(1.0 / 2.2)); }

// Soft shoulder for extra radiance: identity slope at add = 0, saturating
// toward 1 (white) per channel.
vec3 addShoulder(vec3 lin, vec3 add) {
  vec3 head = max(1.0 - lin, 1e-3);
  return lin + head * (1.0 - exp(-add / head));
}

void main() {
  float time = frame.screen.z;
  float loud = frame.screen.w;
  vec3 d = viewRay(v_uv);
  float t = frame.cam.x / max(-d.y, 1e-3);
  vec2 p = d.xz * t;
  float foot = t * frame.cam.z / frame.screen.y;   // world units per pixel

  // Stillness scales every slope (sim and analytic) and the sky blur below.
  float rough = clamp(frame.look.x, 0.0, 1.0);
  vec2 g = vec2(0.0);

  // Simulated heightfield (walker rings, drops). Linear sampling, clamp.
  vec2 lo = frame.domain.xy;
  vec2 span = frame.domain.zw - frame.domain.xy;
  vec2 suv = (p - lo) / span;
  vec2 texel = 1.0 / frame.sim.xy;
  vec2 cellWorld = span * texel;
  float hl = texture(heights, suv - vec2(texel.x, 0.0)).r;
  float hr = texture(heights, suv + vec2(texel.x, 0.0)).r;
  float hd = texture(heights, suv - vec2(0.0, texel.y)).r;
  float hu = texture(heights, suv + vec2(0.0, texel.y)).r;
  vec2 simG = vec2(hr - hl, hu - hd) / (2.0 * cellWorld) * frame.sim.z;
  vec2 inside = smoothstep(vec2(0.0), vec2(0.04), suv) *
                (1.0 - smoothstep(vec2(0.96), vec2(1.0), suv));
  g += simG * (inside.x * inside.y);

  // Analytic detail from option A, scaled by frame.sim.w.
  float loudBoost = 1.0 + 1.5 * loud;
  vec2 k1 = vec2(0.7, 2.1);
  vec2 k2 = vec2(-1.6, 1.1);
  float sw = 0.012 * (1.0 + loud);
  vec2 a = vec2(0.0);
  a += k1 * (sw * cos(dot(k1, p) - time * 0.7));
  a += k2 * (sw * 0.8 * cos(dot(k2, p) - time * 0.55));
  a += octave(p, 6.0, 0.010 * loudBoost, vec2(0.30, 0.18), foot, time);
  a += octave(p, 17.0, 0.006 * loudBoost, vec2(-0.45, 0.25), foot, time);
  a += octave(p, 43.0, 0.004 * loudBoost, vec2(0.20, -0.60), foot, time);
  g += a * frame.sim.w;
  g *= rough;

  vec3 n = normalize(vec3(-g.x, 1.0, -g.y));
  vec3 rd = reflect(d, n);
  rd = normalize(vec3(rd.x, max(rd.y, 0.01), rd.z));

  vec2 skyUv = vec2(0.5 + atan(rd.x, rd.z) / (2.0 * PI),
                    0.5 - asin(clamp(rd.y, -1.0, 1.0)) / PI);
  vec3 skyCol = texture(sky, skyUv).rgb;
  // The blur's weight grows with roughness, not only its spread: a fixed
  // 0.4 centre weight cut a 1-texel star's peak by up to half even at the
  // near-calm default (0.04), where the taps sit under one texel away.
  float blur = smoothstep(0.02, 0.25, rough);
  if (blur > 0.0) {
    float sp = 0.006 * rough;
    vec3 ring = (texture(sky, skyUv + vec2(sp * 0.5, 0.0)).rgb +
                 texture(sky, skyUv - vec2(sp * 0.5, 0.0)).rgb +
                 texture(sky, skyUv + vec2(0.0, sp)).rgb) / 3.0;
    skyCol = mix(skyCol, 0.4 * skyCol + 0.6 * ring, blur);
  }

  // Angular size of this pixel in the reflected sky; derivatives taken in
  // uniform control flow, before any branch.
  float pxRad = max(frame.stars.z, 1e-5);
  float pa = clamp(max(length(dFdx(rd)), length(dFdy(rd))), 0.6 * pxRad, 6.0 * pxRad);

  if (frame.stars.y > 0.0) {
    vec2 cr = vec2(frame.stars.x, frame.stars.y);
    vec2 cell = floor(vec2(skyUv.x * cr.x, skyUv.y * 2.0 * cr.y));
    cell.x = mod(cell.x, cr.x);
    cell.y = clamp(cell.y, 0.0, cr.y - 1.0);
    float rowsAll = 2.0 * cr.y;  // two layers stacked
    skyCol = starCell(skyCol, rd, vec2((cell.x + 0.5) / cr.x, (cell.y + 0.5) / rowsAll), pa);
    skyCol = starCell(skyCol, rd, vec2((cell.x + 0.5) / cr.x, (cell.y + cr.y + 0.5) / rowsAll), pa);
  }

  // Moon. In the sky: the bake's flat Gaussian halo is swapped for an
  // aureole that falls off steeply from the limb (display-linear). The disc
  // is composited after the Fresnel mix below.
  vec4 moonPx = vec4(0.0);
  if (frame.moonDir.w > 0.0) {
    float z = dot(rd, frame.moonDir.xyz);
    float haloAmp = frame.look.y;
    float glowAmp = frame.look.w;
    // Only near the moon (14 radii): both terms are negligible beyond, and
    // the whole-screen version halved the frame rate on the Blade.
    float rho = atan(frame.moonDir.w);
    if ((haloAmp > 0.0 || glowAmp > 0.0) && z > cos(14.0 * rho)) {
      float theta = acos(min(z, 1.0));
      vec3 lin = pow(max(skyCol, 0.0), vec3(2.2));
      lin -= vec3(0.60, 0.66, 0.78) * (haloAmp * pow(max(z, 0.0), 700.0));
      lin = max(lin, 0.0);
      float fade = 1.0 - smoothstep(9.0 * rho, 14.0 * rho, theta);
      lin += vec3(0.62, 0.68, 0.80) * (glowAmp * fade * aureole(theta, rho));
      skyCol = pow(lin, vec3(1.0 / 2.2));
    }
    if (z > 0.2) {
      vec2 q = vec2(dot(rd, frame.moonRight.xyz), dot(rd, frame.moonUp.xyz)) / (z * frame.moonDir.w);
      if (dot(q, q) < 1.7) moonPx = texture(moonDisc, 0.5 + vec2(q.x, -q.y) * frame.moonRight.w);
    }
  }

  vec3 waterCol = vec3(0.02, 0.05, 0.08);

  // Clouds over the sky (and the moon and stars), cloud shadow on the water
  // body. Lit by the sun by day and by the moon and the sky glow at night
  // (night.x). A uniform branch: with dayFade 0 and no night clouds none of
  // this runs and the frame is the night frame exactly.
  float dayFade = frame.day.x;
  float cloudVis = clamp(dayFade + frame.night.x, 0.0, 1.0);
  float cloudA = 0.0;
  vec3 sunLin = frame.sunLight.rgb * frame.sunLight.w;
  vec3 moonLin = MOON_CLOUD * (frame.nightMoon.w * frame.night.x);
  if (cloudVis > 0.0) {
    bool tier1 = frame.day.y > 0.5;
    vec3 amb = toLin(texture(sky, vec2(0.5, 0.02)).rgb);  // the bake near the zenith
    amb = mix(amb, vec3(dot(amb, vec3(0.2126, 0.7152, 0.0722))), 0.45);
    float shade = 1.0;
    if (frame.cloud.z > 0.0) {
      vec2 q = rd.xz / rd.y * frame.cloud.z;
      // uv per pixel of the base layer (ripples widen it, as for the stars).
      float fb = max(length(dFdx(q)), length(dFdy(q)));
      float keepB = 1.0 - smoothstep(0.006, 0.03, fb);
      float keepD = 1.0 - smoothstep(0.0015, 0.004, fb * DETAIL_SCALE);
      // Plates (2048 or more texels per repeat): aliasing starts near 1 texel
      // per pixel; fade between about 4 and 16 texels per pixel.
      bool plates = frame.cloud.w > 0.0;
      // Texels per pixel of each plate's finest sample (A2, B2).
      float keepPA = 1.0 - smoothstep(4.0, 16.0, fb * frame.cloud.w * PLATE_A2.x);
      float keepPB = 1.0 - smoothstep(4.0, 16.0, fb * frame.cloud.w * PLATE_B2.x);
      float horizon = smoothstep(0.03, 0.16, rd.y);
      vec3 lin = toLin(skyCol);
      float cosS = dot(rd, frame.sun.xyz);
      float phase = 0.62 + 0.38 * min(hgRatio(cosS, 0.6), 10.0);
      // Moon phase: narrower forward lobe, so only edges near it light up.
      float phaseM = min(hgRatio(dot(rd, frame.nightMoon.xyz), 0.7), 12.0);
      // One light tap, toward the dominant light: the sun while it is up,
      // else the moon; none when neither lights the layer.
      bool sunUp = frame.sunLight.w > 0.0;
      bool lit = sunUp || frame.nightMoon.w * frame.night.x > 0.0;
      vec3 ld = sunUp ? frame.sun.xyz : frame.nightMoon.xyz;
      vec2 sx = ld.xz / max(length(ld.xz), 1e-3);
      float ambK = mix(NIGHT_AMB, 1.0, dayFade);

      if (tier1) {
        // Cirrus, higher and behind the cumulus: thin, bright, no shading.
        float c = texture(clouds, q * CIRRUS_SCALE + frame.cirrus.xy).b;
        float keepC = 1.0 - smoothstep(0.004, 0.02, fb * CIRRUS_SCALE);
        float ca = smoothstep(0.62, 1.0, c) * 0.22 * keepC * horizon * cloudVis * frame.cloud.y;
        lin = mix(lin, sunLin * (0.8 * phase) + moonLin * (0.8 * phaseM) + amb * (0.9 * ambK),
                  clamp(ca, 0.0, 1.0));
      }

      float dens = plates ? plateDensity(q, keepPA, keepPB) : cloudDensity(q, keepB, keepD);
      if (dens > 0.0) {
        // Toward the sun: less cloud there means this side faces the light.
        vec2 q1 = q + sx * 0.025;
        float dl = dens;
        if (lit) dl = plates ? plateDensity(q1, keepPA, keepPB) : cloudDensity(q1, keepB, keepD);
        if (tier1 && lit) {
          vec2 q2 = q + sx * 0.06;
          dl = 0.5 * (dl + (plates ? plateDensity(q2, keepPA, keepPB) : cloudDensity(q2, keepB, keepD)));
        }
        float tr = exp(-1.4 * max(dl - dens, 0.0) - 0.25 * dens);
        // Seen from below: thin parts pass the light (bright, silver near the
        // sun), thick cores show their greyer base.
        float thin = exp(-0.7 * dens);
        // Moonlit rim: the thin edges only (thin^2), the cores stay dark.
        vec3 cl = sunLin * (1.1 * tr * phase * (0.45 + 0.55 * thin)) +
                  moonLin * (tr * phaseM * (0.05 + 0.95 * thin * thin)) +
                  amb * (1.3 * ambK * (0.6 + 0.4 * thin));
        // Aerial perspective: far (low) clouds take on the sky behind them.
        cl = mix(cl, lin, 0.35 * (1.0 - smoothstep(0.25, 0.85, rd.y)));
        cl = mix(cl, 0.8 + 0.2 * (1.0 - exp(-(cl - 0.8) / 0.2)), step(0.8, cl));
        cloudA = clamp((1.0 - exp(-dens * frame.cloud.y * 2.2)) * horizon * cloudVis, 0.0, 1.0);
        lin = mix(lin, cl, cloudA);
      }
      skyCol = toDisplay(lin);
      moonPx *= 1.0 - cloudA;

      // Shadow on the water body: cloud at the plane along the sun ray from
      // this water point. The visible water is metres across and the cloud
      // plane kilometres up, so it changes slowly over the screen.
      float s = frame.day.z * (tier1 ? 1.0 : 0.5);
      if (s > 0.0 && frame.sun.y > 0.02) {
        vec2 qs = p * frame.day.w + frame.sun.xz / frame.sun.y * frame.cloud.z;
        float sd;
        if (plates) {
          sd = plateDensity(qs, 1.0, 1.0);
        } else {
          float ns = texture(clouds, qs + frame.wind.xy).r;
          if (tier1) ns += (texture(clouds, qs * DETAIL_SCALE + frame.wind.zw).g - 0.5) * 0.55;
          sd = max(ns - (1.0 - frame.cloud.x), 0.0) / 0.3;
        }
        shade = 1.0 - s * (1.0 - exp(-sd * frame.cloud.y * 2.2));
      }
    }
    // Daylit water body: a little sky and sun light scattered back up.
    vec3 body = vec3(0.05, 0.11, 0.13) * (0.45 + 0.55 * frame.sunLight.w) * shade;
    waterCol = mix(waterCol, body, dayFade);
  }

  float cosT = clamp(dot(-d, n), 0.0, 1.0);
  float refl = mix(0.62, 1.0, pow(1.0 - cosT, 3.0));
  vec3 tint = vec3(0.92, 0.97, 1.0);
  vec3 col = mix(waterCol, skyCol * tint, refl);

  if (moonPx.a > 0.0) {
    if (frame.look.z > 0.0) {
      // Premultiplied picture -> linear radiance x exposure x reflectance,
      // then a soft shoulder: the disc saturates toward white, the maria
      // stay readable in the shoulder.
      vec3 lin = pow(moonPx.rgb / moonPx.a, vec3(2.2)) * pow(tint, vec3(2.2));
      vec3 c = pow(1.0 - exp(-lin * (frame.look.z * refl)), vec3(1.0 / 2.2));
      col = col * (1.0 - moonPx.a) + c * moonPx.a;
    } else {
      // The picture as it is, as if it had been composited into the sky.
      col = col * (1.0 - moonPx.a) + moonPx.a * (1.0 - refl) * waterCol + moonPx.rgb * tint * refl;
    }
  }

  // Sun: disc and glare, per pixel, after the Fresnel mix (like the moon's
  // exposure path). Ripples spread the reflected disc into a glitter path;
  // clouds along rd hide it. Direction, colour and strength come from the
  // app's celestial maths and extinction (lib/app/day_sky.dart), updated
  // every second; nothing here is hand-placed or tinted.
  if (dayFade > 0.0 && frame.sun.w > 0.0) {
    float z = dot(rd, frame.sun.xyz);
    if (z > 0.8) {  // within ~37 degrees; both terms are negligible beyond
      float rho = frame.sun.w;  // 0.00465 rad: 0.53 degrees across
      float ang = length(cross(rd, frame.sun.xyz));
      float theta = asin(min(ang, 1.0));
      // Disc: anti-aliased edge over the pixel footprint. Limb darkening per
      // channel, I(mu) = 1 - u (1 - mu), u = 0.50 / 0.60 / 0.72 for r / g / b
      // (stronger at short wavelengths, so the limb is a little redder).
      // The disc is opaque: it hides the reflected sky behind it (otherwise
      // a blue sky tints a noon sun blue-white). Its radiance = transmitted
      // colour, dimmed with the extinction strength, into a per-channel soft
      // shoulder from black: the noon disc reads near white but keeps its
      // warm cast and limb darkening instead of clipping to a flat disc.
      float cov = clamp((rho - ang) / pa + 0.5, 0.0, 1.0);
      float r2 = min(ang * ang / (rho * rho), 1.0);
      float mu1 = 1.0 - sqrt(1.0 - r2);
      vec3 limb = 1.0 - vec3(0.50, 0.60, 0.72) * mu1;
      float vis = smoothstep(-0.0175, 0.0, frame.sun.y);  // down to 1 degree below
      float occ = cov * vis * (1.0 - cloudA);
      float disc = 4.0 * (0.45 + 0.55 * frame.sunLight.w) * occ;
      vec3 add = frame.sunLight.rgb * limb * disc;
      // Glare: narrow 1/theta^2 aureole and a faint wide skirt, scaled by the
      // sky's own brightness here (hazy bright sky: more; deep blue or a dim
      // horizon sky: less). No flare ghosts.
      float skyL = dot(toLin(skyCol), vec3(0.2126, 0.7152, 0.0722));
      float bloom = clamp(skyL / 0.35, 0.2, 1.0);
      float x = max(theta / rho, 1.0);
      float sk = theta / 0.2;
      float glare = 0.22 / (x * x) + 0.06 * exp(-sk * sk);
      add += sunLin * (glare * bloom * dayFade * (1.0 - 0.85 * cloudA));
      col = toDisplay(addShoulder(toLin(col) * (1.0 - occ * refl), add * refl * pow(tint, vec3(2.2))));
    }
  }

  vec2 e = (v_uv - 0.5) * 2.0;
  col *= 1.0 - frame.cam.w * 0.35 * smoothstep(0.55, 1.25, length(e));
  // Triangular dither (one code value) and the sky's animated night grain,
  // at physical pixel frequency; the bake leaves both out.
  vec2 pix = floor(gl_FragCoord.xy);
  float dither = hash21(pix) + hash21(pix + vec2(17.0, 59.0)) - 1.0;
  float grain = hash21(pix + mod(floor(time * 12.0), 1024.0)) - 0.5;
  col += dither / 255.0 + grain * frame.moonUp.w;
  frag_color = vec4(col, 1.0);
}
