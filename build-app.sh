#!/bin/zsh
# Builds "Hackintosh Simplified.app" in build/. It doesn't touch the EFI.
set -e

ROOT="${0:A:h}"
FIXES="$ROOT/../hackintosh-fixes"
APP="$ROOT/build/Hackintosh Simplified.app"
[ -d "$HOME/Downloads/Xcode.app" ] && export DEVELOPER_DIR="$HOME/Downloads/Xcode.app/Contents/Developer"

cd "$ROOT"
swift build -c release --arch x86_64
BIN="$(swift build -c release --arch x86_64 --show-bin-path)/HackintoshSimplified"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/BundledKexts"
cp "$BIN" "$APP/Contents/MacOS/HackintoshSimplified"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

xcrun swift "$ROOT/Resources/make-icon.swift" "$ROOT/build/AppIcon.iconset"
iconutil -c icns "$ROOT/build/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ROOT/build/AppIcon.iconset"

# The patched Realtek Bluetooth kexts, only offered on the exact build and chip they match.
for kext in "$FIXES/6-bluetooth-kext/RealtekBluetoothFirmware.kext" "$FIXES/9-bluetoolfixup/BlueToolFixup.kext"; do
    if [ -d "$kext" ]; then
        cp -R "$kext" "$APP/Contents/Resources/BundledKexts/"
    else
        echo "Note: $kext not found, so this build won't include it."
    fi
done

cp "$ROOT/Resources/connect-bluetooth.js" "$APP/Contents/Resources/"

codesign --force --deep --sign - "$APP"
echo "Built: $APP"
