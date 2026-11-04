# Sky, water and captions

How the visuals are built, what the app ships, and how to make new assets. The app draws the night sky, the sun
and the moon in code, and the water reflects the sky. Only clouds and the moon map are bundled images.

---

## 1. What is drawn in code

| Element | Where | Notes |
|---|---|---|
| Sky gradient, day and night | `client/shaders/sky.frag` | Procedural. The sun disc comes from the real sun direction, with limb darkening and glare. |
| Stars, planets, moon disc | `client/lib/sky/`, `client/lib/moon_render/` | Sidereal drift at 15.04 degrees per hour. Moon: one Lommel-Seeliger shading from the real sun direction. |
| Water reflection | `client/shaders/water.frag` (fallback), `client/gpu/shaders/water_surface.frag` (GPU path) | Two render paths: an analytic water port and a GPU water port. The GPU path falls back to the analytic one while loading or if Flutter GPU fails. |
| Caption dissolve | `client/shaders/caption_dissolve.frag` | Renders the caption to an image and dissolves it during the fade only. |
| Cloud layers | `client/gpu/` (`CloudPlates`), `client/assets/clouds/` | Two bundled plates. Procedural clouds are the fallback. |

Which water port runs is decided at runtime. Check it before diagnosing a missing element.

## 2. What ships

| Asset | Path | Source | Used by |
|---|---|---|---|
| Cloud plate | `client/assets/clouds/cumulus_02.png` | Gemini, 2048 px. Rejected on 2026-10-25 for visible tiling, still bundled until replaced (see 3.2). | Day cloud layer |
| Cloud plate | `client/assets/clouds/cumulus_06.png` | Gemini, 2048 px. Passed the colour gate; a candidate on the 2026-10-25 tiling check. | Day cloud layer |
| Moon map | `client/assets/moon/` (tiles plus `manifest.json`) | NASA SVS CGI Moon Kit, built by `moon_assets/build_moon_assets.py` | Moon disc. Credit in `manifest.json`. |
| Fonts | `client/assets/fonts/` | Cormorant Garamond and Jost, SIL OFL 1.1, `OFL.txt` beside each file | Captions |

Frame cost (2026-10-24 measurement, test phone): with the plates sampled at two scales, GPU water took about 24 ms
per frame (30 fps), against 7 to 12 ms without them. The budget work is open: one tap on the low tier, or
1024 px plates.

## 3. Cloud plates

### 3.1 Requirements
- Square. At least 2048 px (4096 preferred). Upscale with Lanczos if the generator is smaller, and record the method.
- Clouds only on pure black (`#000000`). Corner average under 3/255 after upscaling.
- Seamless tile: left edge matches the right edge, top matches the bottom. Clouds cross the edges, not stop at them.
  Seams under 1/255 each way, and no visible join on a 2x2 tile.
- PNG, lossless. JPEG only for reference copies.
- No horizon, ground, sun disc, people, buildings, text, watermark or logo.
- Lighting from the upper left, natural colour, photographic.

Prompt tail used for every plate:
> Photorealistic cloud study, seamless tileable texture, clouds only on a pure black background (#000000), no horizon,
> no ground, no sun disc, no people, no buildings, no text, no watermark, no logo, high resolution, natural lighting
> from the upper left, professional sky photography.

### 3.2 Types and status (2026-10-25)
Two checks ran on different days. The colour gate (2026-10-24) passed `cumulus_02` and `cumulus_06`. The visual
2x2 tiling check (2026-10-25) then rejected `cumulus_02`. The app still bundles it, so it must be replaced.

| Type | Plates | Status |
|---|---|---|
| Cumulus | 8 | `cumulus_02` rejected for visible tiling (still bundled). `cumulus_06` a candidate. |
| Stratus and overcast | 6 | `stratus_01` and `stratus_05` rejected. `stratus_03` a candidate. |
| Cirrus | 6 | `cirrus_02` rejected. `cirrus_01` a candidate. |
| Storm (cumulonimbus) | 4 | `storm_02` and `storm_04` rejected. |

No plate has yet passed the no-visible-tiling bar with certainty. The shader layering has to hide the repeat.

Each plate varies in density and spacing so the shader does not show a repeating pattern. Cumulus plates were
commissioned as: 01 medium density, 02 sparse with wide black gaps, 03 dense and flat, 04 elongated on one diagonal,
05 a grouped cluster, 06 golden-hour light, 07 overcast-leaning, 08 mid-build with cauliflower texture.

### 3.3 Rejected candidates
Rejected plates and the reasons are in the archive (`archive/docs-2026-10-26/docs/skies/clouds/rejected/README.txt`).
Common failures: full-frame deck with no black background, grey or blue wash, and horizontal or vertical seams.
Reprompt, do not patch. Keep rejects with their reasons.

### 3.4 Procedure
1. Generate one test plate first. Measure size, corner average and both seams. Stop and report if it fails.
2. Generate in batches of 3 or 4. Check each batch before the next. Keep the best per type.
3. Upscale the chosen plates to at least 2048 px. Re-run the corner and seam checks on the upscaled file.
4. Put the approved plate in `client/assets/clouds/` and list it in `client/pubspec.yaml`.
5. Put the raw generator output in a local folder, not the repository.

Fallback: if plates keep failing the gates, the shader uses procedural cloud noise. Generated plates are then reference only.

## 4. Water

- Reflection: the sky is mirrored below the horizon and displaced by slow sine sums. The walker's ripples expand from
  its view-ray hit. Ripple strength follows voice loudness and speaking state (the strength is fixed for now).
- Fresnel: the shader's floor (0.62) reflects about 28 times more sky than physical water at the screen centre
  (computed in `docs/RESEARCH.md`). The trade-off is decided by eye on the phone.
- Glint: an analytic specular lobe from the sun direction, with roughness from the wind. Not built.
- Textures in the asset brief, not yet commissioned: `water_normal_01.png` (seamless normal map, 1024 px) and
  `water_foam_01.png` (seamless caustic mask, 1024 px). Check edges for seams after generation.

## 5. Moon and sun

- Moon: keep the NASA CGI Moon Kit tiles. Fix the shading and glow, not the surface. Credit stays in `manifest.json`.
  LROC images (public domain) are the option if more detail is needed.
- Sun: keep it a shader effect, with limb darkening, a bright core and a soft glare. Do not commission a sun sprite.

## 6. Cloud motion

Two cloud layers in one fragment program, each with one plate sample. Mirror-wrap instead of `fract` at seams, since
Flutter fixes the tile mode to clamp. One blend sample at a second offset hides the repeat. Render at half resolution.

- Cirrus moves at about 0.3 to 0.5 times the cumulus speed (estimate; tune by eye).
- Wind default: 4 m/s from the west.
- Warp field scrolls at about 0.2 times the plate speed, with speed modulated by about 15 per cent.
- Estimated cost: 10 texture samples per pixel at half resolution, about 390 million per second. Profile on the mid-range
  device (Android GPU Inspector or Perfetto). Drop to one layer if over budget.
- `ImageFilter.shader` is Impeller-only. Painting a `FragmentShader` with `CustomPaint` avoids that limit.

## 7. Captions

- Font: Cormorant Garamond Light or Regular (SIL OFL 1.1). Jost Light is the sans alternative. Check the variable-weight
  axis range in each font's `METADATA.pb` before bundling.
- Dissolve: render the caption to an image, then a small fragment shader (noise displacement plus an alpha threshold
  that moves over time). Shader only during the fade. Stop the ticker when the fade ends.
- Timing (provisional, to test on the phone): hold about 4 s plus 0.3 s per word, dissolve over 1.2 to 1.8 s with
  ease-in-out. A tap dismisses at once.
- Contrast: 4.5:1 for normal text, 3:1 for large text (WCAG 1.4.3). Pale sky needs dark ink or a soft shadow.
  Test against the brightest sky frame.
- Reduced motion (`MediaQuery.disableAnimations`) or shaders off: a short opacity change, no shader.
- If the shader fails to load, fall back to a plain fade. Never block the caption on the shader.
- The fog and mist effect is an optional user setting, default on. With it off, the caption shows static and dismissable.
- Captions keep a `Semantics` label. The dissolve is visual only.

## 8. Checks before a visual change ships

- `flutter analyze` and `flutter test` pass.
- The change is seen on the test phone. A passing test does not show a visual result.
- Frame time measured with the DevTools performance overlay, against the 3 ms day-sky budget and the 30 fps floor.
- Licence and credit recorded for every new asset.
