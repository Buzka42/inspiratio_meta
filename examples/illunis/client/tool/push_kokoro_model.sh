#!/usr/bin/env bash
# Copies a local Kokoro model directory (kokoro-multi-lang-v1_0 layout) to the
# Illunis app's private model path on a connected device, for testing only.
# The model is NOT bundled in the APK (lib/app/speech_wiring.dart).
#
# Needs a debuggable build (flutter run / debug or profile APK) installed
# first: run-as only works for debuggable apps.
#
# Usage: tool/push_kokoro_model.sh <local-model-dir> [adb-serial]
# Copies only the files the app reads; espeak-ng-data/ is never pushed.
set -euo pipefail

PKG=com.illunis.illunis_client
# Must match kokoroModelSubdir in lib/app/speech_wiring.dart, under the app
# support dir (getApplicationSupportDirectory = <app data>/files).
DEST=files/models/kokoro-multi-lang-v1_0
TMP=/data/local/tmp/illunis_kokoro
FILES=(model.onnx voices.bin tokens.txt lexicon-us-en.txt lexicon-gb-en.txt)

src=${1:?usage: $0 <local-model-dir> [adb-serial]}
adb=(adb)
[[ $# -ge 2 ]] && adb=(adb -s "$2")

for f in model.onnx voices.bin tokens.txt lexicon-us-en.txt; do
  [[ -f "$src/$f" ]] || { echo "missing $f in $src" >&2; exit 1; }
done

"${adb[@]}" shell "rm -rf $TMP && mkdir -p $TMP"
for f in "${FILES[@]}"; do
  [[ -f "$src/$f" ]] || continue
  "${adb[@]}" push "$src/$f" "$TMP/$f"
done
"${adb[@]}" shell "chmod 644 $TMP/*"
"${adb[@]}" shell "run-as $PKG sh -c 'mkdir -p $DEST && cp $TMP/* $DEST/'"
"${adb[@]}" shell "rm -rf $TMP"
"${adb[@]}" shell "run-as $PKG ls -l $DEST"
echo "pushed to <app data>/$DEST; restart the app"
