#!/usr/bin/env bash
# Copies the owner-import bundle written by tool/import_owner_data.dart into
# the Illunis app's private storage on a connected device. The app imports it
# once on the next start (lib/memory/owner_import_loader.dart) and deletes
# the file when everything is stored; a second push adds nothing.
#
# Needs a debuggable build (flutter run / debug or profile APK) installed
# first: run-as only works for debuggable apps.
#
# Usage: tool/push_owner_import.sh <out-dir> [adb-serial]
# Prints no content: the bundle holds personal data.
set -euo pipefail

PKG=com.illunis.illunis_client
FILE=owner_import.json
# Must match ownerImportDir/ownerImportFile in
# lib/memory/owner_import_bundle.dart, under the app support dir
# (getApplicationSupportDirectory = <app data>/files).
DEST=files/import
TMP=/data/local/tmp/illunis_owner_import

src=${1:?usage: $0 <out-dir> [adb-serial]}
adb=(adb)
[[ $# -ge 2 ]] && adb=(adb -s "$2")
[[ -f "$src/$FILE" ]] || { echo "missing $FILE in $src (run tool/import_owner_data.dart first)" >&2; exit 1; }

# /data/local/tmp is shell-readable, so the copy there lives only for the cp.
cleanup() { "${adb[@]}" shell "rm -rf $TMP" >/dev/null 2>&1 || true; }
trap cleanup EXIT
"${adb[@]}" shell "rm -rf $TMP && mkdir -p $TMP && chmod 711 $TMP"
"${adb[@]}" push "$src/$FILE" "$TMP/$FILE" >/dev/null
"${adb[@]}" shell "chmod 644 $TMP/$FILE"
"${adb[@]}" shell "run-as $PKG sh -c 'mkdir -p $DEST && cp $TMP/$FILE $DEST/$FILE && chmod 600 $DEST/$FILE'"
cleanup
"${adb[@]}" shell "run-as $PKG ls -l $DEST/$FILE"
echo "pushed to <app data>/$DEST/$FILE"
echo "now restart the app (force stop, then open it): it imports the file once on start"
echo "  ${adb[*]} shell am force-stop $PKG"
