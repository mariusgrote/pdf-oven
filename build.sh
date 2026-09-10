#!/bin/bash
# Builds PDF Oven and assembles build/PDF Oven.app
# Usage: ./build.sh [--arch <arm64|x86_64>]...   (default: the host architecture)
set -euo pipefail
cd "$(dirname "$0")"

APP="build/PDF Oven.app"
ARCHS=()
TARGET_ARCHS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --arch)
            [ $# -ge 2 ] || { echo "--arch needs a value" >&2; exit 2; }
            ARCHS+=(--arch "$2")
            TARGET_ARCHS+=("$2")
            shift 2
            ;;
        *)
            echo "unknown option: $1" >&2
            exit 2
            ;;
    esac
done
BUILD_ARGS=(-c release ${ARCHS[@]+"${ARCHS[@]}"})
if [ ${#TARGET_ARCHS[@]} -eq 0 ]; then
    TARGET_ARCHS=("$(uname -m)")
fi

# The plist in Packaging/ holds a placeholder version; the real one is stamped in here.
# CI passes VERSION/BUILD from the release tag, local builds describe the working tree.
VERSION="${VERSION:-$(git describe --tags --always --dirty 2>/dev/null || echo 0.0.0)}"
VERSION="${VERSION#v}"
BUILD="${BUILD:-0}"

swift build "${BUILD_ARGS[@]}"
BIN="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"

QPDF_ROOT="build/qpdf-helper"
QPDF_INPUTS=()
for TARGET_ARCH in "${TARGET_ARCHS[@]}"; do
    QPDF_OUTPUT="$QPDF_ROOT/$TARGET_ARCH/qpdf"
    Packaging/build-qpdf.sh --arch "$TARGET_ARCH" --output "$QPDF_OUTPUT"
    QPDF_INPUTS+=("$QPDF_OUTPUT")
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources/Licenses"
cp "$BIN/PDFOven" "$APP/Contents/MacOS/PDFOven"
if [ ${#QPDF_INPUTS[@]} -eq 1 ]; then
    cp "${QPDF_INPUTS[0]}" "$APP/Contents/Helpers/qpdf"
else
    lipo -create "${QPDF_INPUTS[@]}" -output "$APP/Contents/Helpers/qpdf"
fi
chmod 755 "$APP/Contents/Helpers/qpdf"
cp "$QPDF_ROOT/${TARGET_ARCHS[0]}/Licenses/"* "$APP/Contents/Resources/Licenses/"
cp Packaging/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp Packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$APP"
touch "$APP"

APP_ARCHS="$(lipo -archs "$APP/Contents/MacOS/PDFOven")"
QPDF_ARCHS="$(lipo -archs "$APP/Contents/Helpers/qpdf")"
[ "$APP_ARCHS" = "$QPDF_ARCHS" ] || {
    echo "App architectures ($APP_ARCHS) do not match qpdf architectures ($QPDF_ARCHS)" >&2
    exit 1
}
echo "Built $APP $VERSION ($APP_ARCHS) with bundled qpdf"
