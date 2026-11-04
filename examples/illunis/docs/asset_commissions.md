# Asset commissions (for Gemini, or any image generator)

Owner brief, 2026-10-25. Revised 2026-10-26 after the first generation batch (Hermes review). Use these prompts to
generate assets, then hand the files to the builders in `client/assets/`. Nothing here ships until the owner has
checked the image and the licence terms of the tool that made it.

## Ground rules for every image

- No text, watermarks, logos, people or animals.
- Realistic photographic or physically plausible rendering, not illustrated or cartoon.
- Output as PNG (lossless). Do not ask for alpha: generators do not emit real transparency. A "transparent"
  background comes back as a checkerboard painted into opaque pixels.
- Name files exactly as listed below. Keep the originals in `examples/illunis/docs/assets_raw/` (not committed) (not in the app).

## 1. Clouds (black-background plates, blended in the shader)

Cloud plates are RGB with a pure black background (`#000000`). They are not sprites. The shader blends them with
additive or screen blending, so the black drops out and no alpha channel is needed. The two bundled sprites
(`client/assets/clouds/cumulus_02.png` and `cumulus_06.png`) move to this blending, which removes the visible box.

The full plate rules (size, corner average, seamless tile, acceptance checks, procedure) are in
`archive/docs-2026-10-26/docs/sky_commission_v4_day_clouds.md`. The black-plate pipeline supersedes the RGBA
sprite plan that was in this file.

- Files: `cumulus_01.png` … `cumulus_08.png`, `stratus_01.png` … `stratus_06.png`, `cirrus_01.png` … `cirrus_06.png`,
  `storm_01.png` … `storm_04.png`. Save each under `docs/skies/clouds/<type>_<nn>.png`.
- Size: 2048×2048 minimum, RGB, pure black background. Corner average under 3/255 after upscaling.
- Seamless tile: left edge matches right, top matches bottom. Check seams after generation.
- Prompt (append the shared tail from the v4 commission to every prompt):
  - Cumulus: "Square texture of fair-weather cumulus clouds, puffy and separated, bright white tops, soft grey
    shadows on the lower side, clouds only on a pure black background (#000000)."
  - Stratus: "Square texture of soft grey layered stratus cloud, flat light, gentle folds, clouds only on a pure
    black background (#000000)."
  - Cirrus: "Square texture of wispy high cirrus streaks, very low contrast, clouds only on a pure black background
    (#000000)."
  - Storm: "Square texture of a towering cumulonimbus anvil, dark underside, bright upper edge, clouds only on a pure
    black background (#000000)."
  - Shared tail: "Photorealistic cloud study, seamless tileable texture, no horizon, no ground, no sun disc, no people,
    no buildings, no text, no watermark, no logo, high resolution, natural lighting from the upper left,
    professional sky photography."

## 2. Water

The water surface shader is `client/shaders/water.frag` (analytic fallback) and `client/gpu/shaders/water_surface.frag`
(GPU path).

- `water_foam_01.png`: tileable grayscale foam and caustic mask, 1024×1024, seamless. Prompt: "Seamless tileable
  grayscale caustic light pattern on shallow water, black and white, 1024×1024." Check edges for seams. If there is
  a seam, ask for a fix or let a builder blend the edges.
- Normal map: NOT generated. A painted or generated normal map has wrong vectors and lights as noise. The builder
  computes the water normal procedurally in code. Do not commission `water_normal_01.png`.

## 3. Moon

Do not generate the moon's surface. The current texture is NASA's CGI Moon Kit (`client/assets/moon/`,
see `manifest.json`). Improve it with rendering, not invented detail:

- Use the existing tiles. The problem is the shading and the glow, not the map.
- If a higher-detail source is needed, use NASA's LROC images (public domain). Record the source and
  credit in `manifest.json`, as the current file does.

No change from the 2026-10-25 brief; reviewed and agreed on 2026-10-26.

## 4. Sun

The sky shader draws the sun disc from the real sun direction (`client/shaders/sky.frag`). Keep the sun as a
shader effect, not a bitmap: limb darkening, a bright core, and a soft glare. Do not commission a sun sprite.

No change from the 2026-10-25 brief; reviewed and agreed on 2026-10-26.

## Delivery

Put the raw files in `examples/illunis/docs/assets_raw/` (not committed) and tell the lead the file names. The lead or a builder moves approved
files into `client/assets/` and updates the pubspec. Cloud plates go to `docs/skies/clouds/` first, per the v4
commission.
