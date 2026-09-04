#!/bin/bash
# Builds PDF Oven and assembles build/PDF Oven.app
# Usage: ./build.sh [--arch <arm64|x86_64>]...   (default: the host architecture)
set -euo pipefail
cd "$(dirname "$0")"

APP="build/PDF Oven.app"
ARCHS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --arch)
            [ $# -ge 2 ] || { echo "--arch needs a value" >&2; exit 2; }
            ARCHS+=(--arch "$2")
            shift 2
            ;;
        *)
            echo "unknown option: $1" >&2
            exit 2
            ;;
    esac
done
BUILD_ARGS=(-c release ${ARCHS[@]+"${ARCHS[@]}"})

swift build "${BUILD_ARGS[@]}"
BIN="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/PDFOven" "$APP/Contents/MacOS/PDFOven"
cp Packaging/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp Packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$APP"
touch "$APP"

echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/PDFOven"))"
