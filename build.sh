#!/bin/bash
set -euo pipefail

APP_NAME="SkyHook"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"

echo "Building $APP_NAME (universal)..."

rm -rf "$BUILD_DIR"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

SDK=$(xcrun --show-sdk-path)

build_arch() {
    local ARCH=$1
    local TARGET="${ARCH}-apple-macos14.0"
    local FLAGS="-target $TARGET -sdk $SDK -O"

    echo "  Compiling ($ARCH)..."
    swiftc -parse-as-library $FLAGS \
        -framework SwiftUI \
        -framework AppKit \
        -framework ServiceManagement \
        -o "$BUILD_DIR/${APP_NAME}_${ARCH}" \
        Sources/*.swift
}

build_arch arm64
build_arch x86_64

echo "  Creating universal binary..."
lipo -create "$BUILD_DIR/${APP_NAME}_arm64" "$BUILD_DIR/${APP_NAME}_x86_64" \
    -output "$APP/Contents/MacOS/$APP_NAME"

rm -f "$BUILD_DIR/${APP_NAME}_arm64" "$BUILD_DIR/${APP_NAME}_x86_64"

cp Resources/Info.plist "$APP/Contents/"
if [ -f Resources/SkyHook.icns ]; then
    cp Resources/SkyHook.icns "$APP/Contents/Resources/"
fi

echo -n "APPL????" > "$APP/Contents/PkgInfo"

codesign --force --deep --sign - "$APP"

echo ""
echo "Built: $APP (universal: arm64 + x86_64)"
echo ""
echo "Run:   open $APP"
echo "Install: cp -r $APP /Applications/"
