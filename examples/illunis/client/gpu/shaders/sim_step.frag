// One heightfield step (simulation pass). GPU twin of stepHeightField() in
// lib/src/heightfield.dart; every constant comes in through SimInfo so the
// Dart reference and this shader share one source of numbers.
//
// State texel: r = height now, g = height one step ago (RGBA16F).
// Discrete damped wave equation (leapfrog):
//   next = (2h - prev + k * (sum of 4 neighbours - 4h)) * damping * sponge
// Neighbours past the edge read the edge texel (clamp sampler), which is a
// reflecting boundary; the sponge band absorbs waves before they get there.
// Drops add a raised-cosine bump, strength * 0.5 * (1 + cos(pi * r / radius)),
// to the new height and to the stored previous height (displacement only).
//
// Texel addressing uses gl_FragCoord with nearest sampling, so the pass is
// independent of the backend's y orientation (row y written = row y read).
uniform SimInfo {
  vec4 size;      // sim width, height (texels), 1/width, 1/height
  vec4 wave;      // k (c^2, <= 0.5), damping, sponge width (texels), sponge strength
  vec4 drops[4];  // x, y (texel coords), radius (texels), strength; strength 0 = none
}
sim;

uniform sampler2D state;

out vec4 frag_color;

const float PI = 3.14159265;

void main() {
  vec2 px = gl_FragCoord.xy;            // texel centre, (i + 0.5, j + 0.5)
  vec2 t = sim.size.zw;
  vec2 uv = px * t;
  vec4 c = texture(state, uv);
  float h = c.r;
  float prev = c.g;
  float sum = texture(state, uv + vec2(t.x, 0.0)).r +
              texture(state, uv - vec2(t.x, 0.0)).r +
              texture(state, uv + vec2(0.0, t.y)).r +
              texture(state, uv - vec2(0.0, t.y)).r;

  float next = 2.0 * h - prev + sim.wave.x * (sum - 4.0 * h);

  // Sponge: distance (texels) to the nearest edge, measured from texel centres.
  vec2 cell = px - 0.5;
  float edge = min(min(cell.x, sim.size.x - 1.0 - cell.x),
                   min(cell.y, sim.size.y - 1.0 - cell.y));
  float s = clamp(1.0 - edge / max(sim.wave.z, 1.0), 0.0, 1.0);
  next *= sim.wave.y * (1.0 - sim.wave.w * s * s);

  float bump = 0.0;
  for (int i = 0; i < 4; i++) {
    vec4 d = sim.drops[i];
    float r = length(cell - d.xy);
    if (d.w != 0.0 && r < d.z) {
      bump += d.w * 0.5 * (1.0 + cos(PI * r / d.z));
    }
  }

  // The bump goes into both channels: a drop displaces, it adds no velocity.
  frag_color = vec4(next + bump, h + bump, 0.0, 1.0);
}
