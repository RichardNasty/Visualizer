#!/bin/bash
# Builds Visualizer.app (universal: Apple Silicon + Intel) into ./build and zips it.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64 --arch x86_64
BIN_DIR=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)

APP=build/Visualizer.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Visualizer" "$APP/Contents/MacOS/Visualizer"
sed "s/BUILD_NUMBER/${GITHUB_RUN_NUMBER:-1}/" Resources/Info.plist > "$APP/Contents/Info.plist"
cp Shaders/Visualizer.metal "$APP/Contents/Resources/"
# App icon from the PNG.
ICONSET=build/AppIcon.iconset
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature so macOS will run it (there is no paid Apple developer account).
codesign --force --deep --sign - "$APP"
codesign --verify --verbose "$APP"

(cd build && ditto -c -k --keepParent Visualizer.app Visualizer.zip)
echo "Built build/Visualizer.app and build/Visualizer.zip"
