#version 460 core
#include <flutter/runtime_effect.glsl>

precision highp float;

// ---------------------------------------------------------------------------
// Caption dissolve. Runs only while a caption fades; at rest the caption is a
// plain Text widget. lib/captions/caption_dissolve_painter.dart renders the
// caption into an image (with a margin for the drift) and draws it through
// this shader over the same rect.
//
// Each pixel gets a dissolve age from smooth noise: low-noise areas go first,
// so glyphs break up into patches. An ageing pixel samples from below itself
// (so the ink drifts upward), sways sideways a little, spreads into a soft
// 5-tap blur, and fades. Fine grain breaks the patch edges into specks.
// progress 0 = untouched caption, progress 1 = fully transparent.
//
// Uniforms (float slots, written by CaptionDissolvePainter):
//   0,1  uSize      rect size in logical pixels (FlutterFragCoord matches)
//   2    uProgress  0..1, already eased
//   3    uSeed      noise offset so captions do not all dissolve alike
// Sampler 0: uTexture, the rendered caption (premultiplied alpha).
// Cost per pixel: 2 value-noise lookups (4 hashes each), 1 hash, 5 texture
// taps. The rect is caption-sized, for about 1.5 s.
// ---------------------------------------------------------------------------

uniform vec2 uSize;
uniform float uProgress;
uniform float uSeed;
uniform sampler2D uTexture;

out vec4 fragColor;

const float RISE_PX = 28.0;   // upward drift at full age
const float SWAY_PX = 6.0;    // sideways sway at full age
const float BLUR_PX = 5.0;    // diffusion radius at full age
const float SPREAD = 0.6;     // share of the fade over which ages start

float hash(vec2 p) {
  p = fract(p * vec2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}

float vnoise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  f = f * f * (3.0 - 2.0 * f);
  float a = hash(i);
  float b = hash(i + vec2(1.0, 0.0));
  float c = hash(i + vec2(0.0, 1.0));
  float d = hash(i + vec2(1.0, 1.0));
  return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

vec4 tap(vec2 px) {
  vec2 uv = px / uSize;
  if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) return vec4(0.0);
  return texture(uTexture, uv);
}

void main() {
  vec2 frag = FlutterFragCoord().xy;
  float t = clamp(uProgress, 0.0, 1.0);
  if (t <= 0.0) {
    fragColor = tap(frag);
    return;
  }

  // Patch noise, about 14 px cells, plus a slight top-first bias so the line
  // lifts off from above.
  vec2 seed = vec2(uSeed * 17.0, uSeed * 31.0);
  float n = vnoise(frag / 14.0 + seed) * 0.85 + (frag.y / uSize.y) * 0.15;
  // Age 0 until this pixel's turn, then 0..1 over the rest of the fade.
  float age = clamp((t - n * SPREAD) / (1.0 - SPREAD), 0.0, 1.0);

  float sway = (vnoise(frag / 40.0 + seed + 7.0) - 0.5) * 2.0;
  vec2 src = frag + vec2(sway * SWAY_PX, RISE_PX) * age * age;

  float r = BLUR_PX * age;
  vec4 c = tap(src) * 0.4
         + (tap(src + vec2(r, r)) + tap(src + vec2(-r, r))
          + tap(src + vec2(r, -r)) + tap(src + vec2(-r, -r))) * 0.15;

  // Fine grain: specks drop out ahead of the patch fade.
  float grain = hash(floor(frag / 1.5) + seed);
  float keep = smoothstep(age * 1.2 - 0.2, age * 1.2, grain);
  float fade = (1.0 - age) * (1.0 - age);

  // Premultiplied colour, so scaling all four channels keeps it consistent.
  fragColor = c * keep * fade * (1.0 - smoothstep(0.92, 1.0, t));
}
