#!/usr/bin/env bash
# Compiles the water shaders into one Flutter GPU shader bundle with the SDK's
# impellerc (all backends: Vulkan, OpenGL ES, Metal). Output is checked in at
# assets/water.shaderbundle so `flutter build` needs no build hook or package.
# Re-run after editing anything in shaders/.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
flutter_root="${FLUTTER_ROOT:-$HOME/development/flutter}"
impellerc="$flutter_root/bin/cache/artifacts/engine/linux-x64/impellerc"
s="$here/shaders"
bundle=$(cat <<JSON
{"FullscreenVertex": {"type": "vertex", "file": "$s/fullscreen.vert"},
 "SimStepFragment": {"type": "fragment", "file": "$s/sim_step.frag"},
 "WaterSurfaceFragment": {"type": "fragment", "file": "$s/water_surface.frag"},
 "CloudNoiseFragment": {"type": "fragment", "file": "$s/cloud_noise.frag"}}
JSON
)
"$impellerc" --sl="$here/assets/water.shaderbundle" --shader-bundle="$bundle" \
  --include="$flutter_root/bin/cache/artifacts/engine/linux-x64/shader_lib"
echo "wrote $here/assets/water.shaderbundle"
