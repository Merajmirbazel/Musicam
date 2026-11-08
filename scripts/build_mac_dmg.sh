#!/bin/zsh
# Builds a Release Musicam.app (sandboxed, ad-hoc signed) and a drag-to-install DMG into ./dist.
# Ad-hoc signing runs on this Mac. To open it on other Macs without a warning it needs Developer ID signing and notarization.
set -euo pipefail
cd "${0:A:h}/.."

VERSION="0.13.0"
BUILD="build"
DIST="dist"
rm -rf "$DIST/Musicam.app" "$DIST/dmg" "$BUILD"; mkdir -p "$DIST"   # older DMGs in dist/ are kept

echo "▸ Compiling (Release)"
xcodebuild -project Musicam.xcodeproj -scheme Musicam-macOS -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$BUILD" CODE_SIGN_IDENTITY=- build | tail -1

APP="$BUILD/Build/Products/Release/Musicam.app"
codesign --verify --deep --strict "$APP"
cp -R "$APP" "$DIST/Musicam.app"

echo "▸ DMG"
STAGE="$DIST/dmg"; mkdir -p "$STAGE"
cp -R "$DIST/Musicam.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Musicam" -srcfolder "$STAGE" -ov -format UDZO "$DIST/Musicam-$VERSION.dmg" >/dev/null
rm -rf "$STAGE"
hdiutil verify "$DIST/Musicam-$VERSION.dmg" | tail -1
echo "✓ $DIST/Musicam-$VERSION.dmg"
