#!/bin/bash
# Build QuitOnClose.app (universal when the x86_64 SDK slice is available),
# ad-hoc sign it, and optionally install it to /Applications.
#
#   ./build.sh            build only  -> build/QuitOnClose.app
#   ./build.sh --install  build, then replace /Applications/QuitOnClose.app
set -euo pipefail

NAME="QuitOnClose"
BUNDLE_ID="com.quitonclose.app"
DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD="$DIR/build"
APP="$BUILD/$NAME.app"
MACOS="$APP/Contents/MacOS"

FRAMEWORKS=(-framework Cocoa -framework ApplicationServices -framework ServiceManagement)
SOURCES=("$DIR"/Sources/*.swift)

rm -rf "$APP"
mkdir -p "$MACOS" "$APP/Contents/Resources"

build_slice() {
    local arch="$1" out="$2"
    swiftc -O -target "${arch}-apple-macos13.0" -o "$out" "${SOURCES[@]}" "${FRAMEWORKS[@]}" 2>/dev/null
}

echo "==> compiling arm64"
build_slice arm64 "$BUILD/$NAME.arm64"

if build_slice x86_64 "$BUILD/$NAME.x86_64"; then
    echo "==> compiling x86_64 (universal build)"
    lipo -create "$BUILD/$NAME.arm64" "$BUILD/$NAME.x86_64" -output "$MACOS/$NAME"
    rm -f "$BUILD/$NAME.x86_64"
else
    echo "==> x86_64 SDK slice unavailable, shipping arm64 only"
    mv "$BUILD/$NAME.arm64" "$MACOS/$NAME"
fi
rm -f "$BUILD/$NAME.arm64"

cp "$DIR/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature with a stable identifier. Accessibility (TCC) keys off the
# code signature, so a rebuild can ask for the permission again.
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
codesign --verify --verbose=1 "$APP"

echo "==> built $APP"
lipo -archs "$MACOS/$NAME"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x "$NAME" 2>/dev/null || true
    rm -rf "/Applications/$NAME.app"
    cp -R "$APP" "/Applications/$NAME.app"
    echo "==> installed /Applications/$NAME.app"
    open "/Applications/$NAME.app"
fi
