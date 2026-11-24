#!/bin/bash
# Builds Paper.app into ./build. Pass --install to also copy it to /Applications,
# or --release to build for Apple Silicon and Intel and zip it for a release.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Paper.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [[ "${1:-}" == "--release" ]]; then
    # Built separately and joined: one universal build needs full Xcode.
    slices=()
    for arch in arm64 x86_64; do
        triple="$arch-apple-macosx14.0"
        swift build -c release --triple "$triple"
        slices+=("$(swift build -c release --triple "$triple" --show-bin-path)/Paper")
    done
    lipo -create "${slices[@]}" -output "$APP/Contents/MacOS/Paper"
else
    swift build -c release
    cp "$(swift build -c release --show-bin-path)/Paper" "$APP/Contents/MacOS/Paper"
fi
# Debug symbols record the paths of the Mac it was built on.
strip -S -x "$APP/Contents/MacOS/Paper"
cp Info.plist "$APP/Contents/Info.plist"
cp Icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    rm -rf /Applications/Paper.app
    cp -R "$APP" /Applications/
    echo "Installed to /Applications/Paper.app"
elif [[ "${1:-}" == "--release" ]]; then
    rm -f build/Paper.zip
    TZ=UTC ditto -c -k --norsrc --noextattr --keepParent "$APP" build/Paper.zip
    echo "Zipped to build/Paper.zip"
fi
