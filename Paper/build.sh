#!/bin/bash
# Builds Paper.app into ./build. Pass --install to also copy it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP=build/Paper.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/Paper" "$APP/Contents/MacOS/Paper"
cp Info.plist "$APP/Contents/Info.plist"
cp Icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    rm -rf /Applications/Paper.app
    cp -R "$APP" /Applications/
    echo "Installed to /Applications/Paper.app"
fi
