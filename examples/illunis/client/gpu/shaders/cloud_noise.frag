// One-off pass: fills the tileable cloud texture (RGBA8, square) that the
// surface pass samples with a repeat sampler (water_surface.frag, day block).
//   r = base shape: periodic gradient-noise fbm mixed with inverted Worley
//       (billows), stretched so 1 - coverage is roughly the coverage threshold
//   g = detail: inverted Worley fbm with gradient noise, mean about 0.5
//   b = cirrus: streaky fbm (lattice 8x finer across than along), domain warped
// Every octave's lattice wraps on an integer period, so texel column 0 is the
// continuation of the last column (and row 0 of the last row).
// Cloud plates (CloudPlates) do not replace it: they have their own samplers
// (plateA, plateB); this texture stays the fallback and tier 1's cirrus.
//
// Texels are addressed by gl_FragCoord, so the result does not depend on the
// backend's y orientation.
uniform NoiseInfo {
  vec4 size;  // width, height (texels), seed, unused
}
info;

out vec4 frag_color;

float hash(vec2 p) {
  vec3 p3 = fract(vec3(p.xyx) * 0.1031 + info.size.z * 0.0137);
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.x + p3.y) * p3.z);
}

vec2 grad(vec2 i, vec2 per) {
  float h = hash(mod(i, per)) * 6.2831853;
  return vec2(cos(h), sin(h));
}

// Gradient noise about 0 (roughly -0.7..0.7); x in lattice cells, the
// lattice repeating every per cells.
float gnoise(vec2 x, vec2 per) {
  vec2 i = floor(x);
  vec2 f = x - i;
  vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
  float a = dot(grad(i, per), f);
  float b = dot(grad(i + vec2(1.0, 0.0), per), f - vec2(1.0, 0.0));
  float c = dot(grad(i + vec2(0.0, 1.0), per), f - vec2(0.0, 1.0));
  float d = dot(grad(i + vec2(1.0, 1.0), per), f - vec2(1.0, 1.0));
  return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// Distance to the nearest feature point (0..~1), one point per cell.
float worley(vec2 x, vec2 per) {
  vec2 i = floor(x);
  vec2 f = x - i;
  float d = 9.0;
  for (int y = -1; y <= 1; y++) {
    for (int k = -1; k <= 1; k++) {
      vec2 o = vec2(float(k), float(y));
      vec2 c = mod(i + o, per);
      vec2 pt = o + vec2(hash(c + 0.37), hash(c + vec2(41.7, 13.1)));
      vec2 v = pt - f;
      d = min(d, dot(v, v));
    }
  }
  return sqrt(d);
}

float perlinFbm(vec2 uv, vec2 per, int octaves) {
  float s = 0.0, a = 0.5, n = 0.0;
  for (int i = 0; i < 5; i++) {
    if (i >= octaves) break;
    s += a * gnoise(uv * per, per);
    n += a;
    per *= 2.0;
    a *= 0.5;
  }
  return s / n;
}

void main() {
  vec2 uv = gl_FragCoord.xy / info.size.xy;  // 0..1, one period

  // Base shape: large puffs.
  float pf = perlinFbm(uv, vec2(6.0), 5);
  float wb = 1.0 - (0.625 * worley(uv * 6.0, vec2(6.0)) + 0.375 * worley(uv * 12.0, vec2(12.0)));
  float shape = 0.5 + 1.25 * pf;
  shape = mix(shape, wb, 0.35);
  float r = clamp((shape - 0.52) * 2.1 + 0.5, 0.0, 1.0);

  // Detail: cauliflower edges.
  float wd = 1.0 - (0.5 * worley(uv * 8.0, vec2(8.0)) + 0.3 * worley(uv * 16.0, vec2(16.0)) +
                    0.2 * worley(uv * 32.0, vec2(32.0)));
  float pd = perlinFbm(uv + 0.31, vec2(16.0), 3);
  float g = clamp(0.5 + 1.6 * (wd - 0.57) + 0.6 * pd, 0.0, 1.0);

  // Cirrus: long streaks along x, gently warped.
  vec2 warp = vec2(gnoise(uv * 3.0, vec2(3.0)), gnoise(uv * 3.0 + 5.2, vec2(3.0)));
  vec2 uw = uv + warp * 0.07;
  float st = perlinFbm(uw, vec2(3.0, 24.0), 4);
  float cl = perlinFbm(uv + 0.73, vec2(4.0), 3);
  float b = clamp(0.5 + 1.4 * st + 0.9 * cl, 0.0, 1.0);

  frag_color = vec4(r, g, b, 1.0);
}
