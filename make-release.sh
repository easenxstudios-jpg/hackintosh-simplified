#!/bin/zsh
# Builds dist/HackintoshSimplified-<version>.dmg and its checksum for a public release.
# It leaves out the patched Realtek kexts, which aren't cleared for redistribution.
set -e

ROOT="${0:A:h}"
VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$ROOT/Resources/Info.plist")"
DIST="$ROOT/dist"
NAME="HackintoshSimplified-$VERSION"

rm -rf "$DIST" "$ROOT/.build"
mkdir -p "$DIST/image"
APP_DIR="$DIST/image" BUNDLE_PATCHED_KEXTS=0 zsh "$ROOT/build-app.sh"
ln -s /Applications "$DIST/image/Applications"

hdiutil create -quiet -volname "Hackintosh Simplified" -srcfolder "$DIST/image" -fs HFS+ -format UDZO -ov "$DIST/$NAME.dmg"
rm -rf "$DIST/image"
(cd "$DIST" && shasum -a 256 "$NAME.dmg" > "$NAME.dmg.sha256")
echo "Built: $DIST/$NAME.dmg"
