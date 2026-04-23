#!/bin/bash
set -e

APP_NAME="cornershop.app"
BINARY_NAME="cornershop"
SOURCE_FILE="cornershop.swift"
ICONS_DIR="app-assets/AppIcons/Assets.xcassets/AppIcon.appiconset"
ICONSET_DIR="/tmp/cornershop_build.iconset"

killall "$BINARY_NAME" 2>/dev/null || true

echo "Building $APP_NAME..."

rm -rf "$APP_NAME"

swiftc "$SOURCE_FILE" -o "$BINARY_NAME"

mkdir -p "$APP_NAME/Contents/MacOS"
mkdir -p "$APP_NAME/Contents/Resources"

mv "$BINARY_NAME" "$APP_NAME/Contents/MacOS/$BINARY_NAME"
chmod +x "$APP_NAME/Contents/MacOS/$BINARY_NAME"

cp "app-assets/Info.plist" "$APP_NAME/Contents/Info.plist"

# Build AppIcon.icns from PNGs using iconutil
# iconutil requires the directory name to end in .iconset and files named icon_NxN[@2x].png
rm -rf "$ICONSET_DIR"
mkdir "$ICONSET_DIR"
cp "$ICONS_DIR/16.png"   "$ICONSET_DIR/icon_16x16.png"
cp "$ICONS_DIR/32.png"   "$ICONSET_DIR/icon_16x16@2x.png"
cp "$ICONS_DIR/32.png"   "$ICONSET_DIR/icon_32x32.png"
cp "$ICONS_DIR/64.png"   "$ICONSET_DIR/icon_32x32@2x.png"
cp "$ICONS_DIR/128.png"  "$ICONSET_DIR/icon_128x128.png"
cp "$ICONS_DIR/256.png"  "$ICONSET_DIR/icon_128x128@2x.png"
cp "$ICONS_DIR/256.png"  "$ICONSET_DIR/icon_256x256.png"
cp "$ICONS_DIR/512.png"  "$ICONSET_DIR/icon_256x256@2x.png"
cp "$ICONS_DIR/512.png"  "$ICONSET_DIR/icon_512x512.png"
cp "$ICONS_DIR/1024.png" "$ICONSET_DIR/icon_512x512@2x.png"
iconutil -c icns "$ICONSET_DIR" -o "$APP_NAME/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET_DIR"

# Ad-hoc sign (required for launch on Apple Silicon)
codesign --force --deep --sign - "$APP_NAME"

touch "$APP_NAME"
echo "$APP_NAME is ready."
