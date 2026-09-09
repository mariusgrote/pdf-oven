#!/bin/bash
# Builds one self-contained qpdf executable for the requested macOS architecture.
set -euo pipefail

cd "$(dirname "$0")/.."

ARCH=""
OUTPUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --arch)
            [ $# -ge 2 ] || { echo "--arch needs a value" >&2; exit 2; }
            ARCH="$2"
            shift 2
            ;;
        --output)
            [ $# -ge 2 ] || { echo "--output needs a value" >&2; exit 2; }
            OUTPUT="$2"
            shift 2
            ;;
        *)
            echo "unknown option: $1" >&2
            exit 2
            ;;
    esac
done

case "$ARCH" in
    arm64|x86_64) ;;
    *) echo "--arch must be arm64 or x86_64" >&2; exit 2 ;;
esac
[ -n "$OUTPUT" ] || { echo "--output is required" >&2; exit 2; }

QPDF_VERSION="12.4.1"
QPDF_SHA256="f045aa277be2356ff53a89a8622945958291177d2483afc20ede7c8a8cd3873c"
JPEG_VERSION="3.2.0"
JPEG_SHA256="6f30092cef9fb839779646608f4ee14ae3cbac989c47fa05e841b0841f09878e"
DEPENDENCY_ROOT="build/dependencies/$ARCH"
DOWNLOADS="build/dependencies/downloads"
JPEG_PREFIX="$DEPENDENCY_ROOT/jpeg"
QPDF_BUILD="$DEPENDENCY_ROOT/qpdf-build"
OUTPUT_DIR="$(dirname "$OUTPUT")"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
if [ "$JOBS" -gt 8 ]; then JOBS=8; fi

mkdir -p "$DOWNLOADS" "$DEPENDENCY_ROOT" "$OUTPUT_DIR"

download() {
    local url="$1"
    local destination="$2"
    local checksum="$3"
    if [ ! -f "$destination" ] || ! echo "$checksum  $destination" | shasum -a 256 -c - >/dev/null 2>&1; then
        curl --fail --location --retry 3 "$url" --output "$destination"
    fi
    echo "$checksum  $destination" | shasum -a 256 -c -
}

QPDF_ARCHIVE="$DOWNLOADS/qpdf-$QPDF_VERSION.tar.gz"
JPEG_ARCHIVE="$DOWNLOADS/libjpeg-turbo-$JPEG_VERSION.tar.gz"
download \
    "https://github.com/qpdf/qpdf/releases/download/v$QPDF_VERSION/qpdf-$QPDF_VERSION.tar.gz" \
    "$QPDF_ARCHIVE" "$QPDF_SHA256"
download \
    "https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/$JPEG_VERSION/libjpeg-turbo-$JPEG_VERSION.tar.gz" \
    "$JPEG_ARCHIVE" "$JPEG_SHA256"

rm -rf \
    "$DEPENDENCY_ROOT/qpdf-$QPDF_VERSION" \
    "$DEPENDENCY_ROOT/libjpeg-turbo-$JPEG_VERSION" \
    "$DEPENDENCY_ROOT/jpeg-build" \
    "$JPEG_PREFIX" \
    "$QPDF_BUILD"
tar -xzf "$QPDF_ARCHIVE" -C "$DEPENDENCY_ROOT"
tar -xzf "$JPEG_ARCHIVE" -C "$DEPENDENCY_ROOT"

cmake \
    -S "$DEPENDENCY_ROOT/libjpeg-turbo-$JPEG_VERSION" \
    -B "$DEPENDENCY_ROOT/jpeg-build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PWD/$JPEG_PREFIX" \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DENABLE_SHARED=OFF \
    -DENABLE_STATIC=ON \
    -DWITH_JPEG8=ON \
    -DWITH_SIMD=OFF \
    -DWITH_TURBOJPEG=OFF \
    -DWITH_TOOLS=OFF \
    -DWITH_TESTS=OFF
cmake --build "$DEPENDENCY_ROOT/jpeg-build" --parallel "$JOBS"
cmake --install "$DEPENDENCY_ROOT/jpeg-build"

cmake \
    -S "$DEPENDENCY_ROOT/qpdf-$QPDF_VERSION" \
    -B "$QPDF_BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_STATIC_LIBS=ON \
    -DUSE_IMPLICIT_CRYPTO=OFF \
    -DALLOW_CRYPTO_NATIVE=ON \
    -DREQUIRE_CRYPTO_NATIVE=ON \
    -DINSTALL_MANUAL=OFF \
    -DINSTALL_EXAMPLES=OFF \
    -DINSTALL_PKGCONFIG=OFF \
    -DINSTALL_CMAKE_PACKAGE=OFF \
    -DPKG_CONFIG_EXECUTABLE=/usr/bin/false \
    -DLIBJPEG_H_PATH="$PWD/$JPEG_PREFIX/include" \
    -DLIBJPEG_LIB_PATH="$PWD/$JPEG_PREFIX/lib/libjpeg.a" \
    -DZLIB_H_PATH="$SDKROOT/usr/include" \
    -DZLIB_LIB_PATH="$SDKROOT/usr/lib/libz.tbd"
cmake --build "$QPDF_BUILD" --parallel "$JOBS" --target qpdf

cp "$QPDF_BUILD/qpdf/qpdf" "$OUTPUT"
chmod 755 "$OUTPUT"

ARCHS="$(lipo -archs "$OUTPUT")"
case " $ARCHS " in
    *" $ARCH "*) ;;
    *) echo "$OUTPUT does not contain $ARCH" >&2; exit 1 ;;
esac

if otool -L "$OUTPUT" | tail -n +2 | awk '{print $1}' | grep -Ev '^(/usr/lib/|/System/Library/)' >/dev/null; then
    echo "$OUTPUT has a non-system dynamic library dependency:" >&2
    otool -L "$OUTPUT" >&2
    exit 1
fi

LICENSES="$OUTPUT_DIR/Licenses"
mkdir -p "$LICENSES"
cp "$DEPENDENCY_ROOT/qpdf-$QPDF_VERSION/LICENSE.txt" "$LICENSES/qpdf-LICENSE.txt"
cp "$DEPENDENCY_ROOT/qpdf-$QPDF_VERSION/NOTICE.md" "$LICENSES/qpdf-NOTICE.md"
cp "$DEPENDENCY_ROOT/libjpeg-turbo-$JPEG_VERSION/LICENSE.md" \
    "$LICENSES/libjpeg-turbo-LICENSE.md"
cp "$DEPENDENCY_ROOT/libjpeg-turbo-$JPEG_VERSION/README.ijg" \
    "$LICENSES/libjpeg-turbo-README.ijg"

if [ "$ARCH" = "$(uname -m)" ]; then
    "$OUTPUT" --version
fi
