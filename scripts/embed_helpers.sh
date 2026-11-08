#!/bin/bash
# Copies the Merajfy helper programs from Helpers/ (merajfy-cli, ffmpeg, and yt-dlp as the "onedir" build:
# yt-dlp_macos + _internal/) into Musicam.app/Contents/Resources/Helpers and signs them so the sandboxed app may run them.
# They inherit the app's sandbox; they get no extra rights.
# (The one-file yt-dlp does not work in a sandbox: its loader uses a system semaphore the sandbox forbids.)
# Run by the "Embed Merajfy helpers" build phase of Musicam-macOS.
set -euo pipefail
SRC="${SRCROOT}/Helpers"
DEST="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Resources/Helpers"
rm -rf "$DEST" "${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Helpers"   # (the old place, from earlier builds)
if [ ! -d "$SRC" ] || [ -z "$(ls -A "$SRC" 2>/dev/null)" ]; then
  echo "warning: no Helpers/ folder; the built-in Merajfy downloader will be unavailable in this build"
  exit 0
fi
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
[ -n "$IDENTITY" ] || IDENTITY="-"
mkdir -p "$DEST"
cp -Rp "$SRC"/. "$DEST"/

# libraries and Python modules inside folders: plain signature
# (PyInstaller's Python.framework is not a real framework layout, so codesign refuses files inside it by path:
#  sign a copy outside any .framework folder and put it back; the signature lives inside the file.)
TMPSIGN="$(mktemp -d)"
find "$DEST" -mindepth 2 -type f \( -name '*.dylib' -o -name '*.so' -o -name 'Python' \) -print0 |
  while IFS= read -r -d '' lib; do
    case "$lib" in
      *.framework/*)
        cp -p "$lib" "$TMPSIGN/lib"
        /usr/bin/codesign --force --sign "$IDENTITY" "$TMPSIGN/lib"
        cp -p "$TMPSIGN/lib" "$lib" ;;
      *) /usr/bin/codesign --force --sign "$IDENTITY" "$lib" ;;
    esac
  done
rm -rf "$TMPSIGN"
# the programs themselves: sandbox-inheriting signature
for exe in "$DEST"/*; do
  [ -f "$exe" ] || continue
  /usr/bin/codesign --force --sign "$IDENTITY" --entitlements "${SRCROOT}/Config/helper.entitlements" "$exe"
done
echo "embedded helpers: $(ls "$DEST" | tr '\n' ' ')"
