#!/usr/bin/env bash
# Copies the breathwork library into the client's assets (build plan B7).
# Flutter cannot bundle files from outside the package, so content/breathwork
# and its schema are copied into client/assets/breath/. Edit content/, never
# the copies; test/breath/breath_content_sync_test.dart checks they match.
# Uses mkdir and cp only. Run from anywhere.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
client="$(dirname "$here")"
content="$(dirname "$client")/content"
out="$client/assets/breath"

mkdir -p "$out"
cp "$content"/breathwork/*.json "$out"/
cp "$content/schemas/technique.schema.json" "$out"/
echo "sync_breath_content: copied to assets/breath"
