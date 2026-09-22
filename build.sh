#!/bin/bash
# Builds "Poddle Helper.app" with Apple's command line tools only (no Xcode project, no dependencies).
# Output: build/Poddle Helper.app and dist/Poddle-Helper.zip
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Poddle Helper.app"
BIN=PoddleHelper
rm -rf build dist
mkdir -p build/obj "$APP/Contents/MacOS" "$APP/Contents/Resources" dist

# 1. Compile for Apple silicon and Intel, then join into one universal binary.
#    The Info.plist is also embedded in the binary itself: without it macOS silently denies motion access.
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos14" Sources/*.swift -o "build/obj/$BIN-$arch" \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Resources/Info.plist
done
lipo -create "build/obj/$BIN-arm64" "build/obj/$BIN-x86_64" -output "$APP/Contents/MacOS/$BIN"

# 2. App bundle: Info.plist and icon.
cp Resources/Info.plist "$APP/Contents/Info.plist"
ICONSET=build/obj/AppIcon.iconset
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size Resources/icon-512.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2)); [ $double -le 512 ] || continue
  sips -z $double $double Resources/icon-512.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# 3. Ad-hoc signature (there is no Apple Developer ID yet), then zip.
codesign --force --deep --sign - "$APP"
ditto -c -k --keepParent "$APP" dist/Poddle-Helper.zip

echo "built: $APP"
echo "zip:   dist/Poddle-Helper.zip"
