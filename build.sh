#!/bin/bash
# Builds PDF Oven and assembles build/PDF Oven.app
set -euo pipefail
cd "$(dirname "$0")"

APP="build/PDF Oven.app"

swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/PDFOven "$APP/Contents/MacOS/PDFOven"
cp Packaging/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [ -f Packaging/AppIcon.icns ]; then
	cp Packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
	/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true
fi
codesign --force --deep --sign - "$APP"
touch "$APP"

echo "Built $APP"
