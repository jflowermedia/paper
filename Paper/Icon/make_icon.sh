#!/bin/bash
# Renders make_icon.swift and packs it into AppIcon.icns.
set -euo pipefail
cd "$(dirname "$0")"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

swiftc -O -o "$work/make_icon" make_icon.swift
"$work/make_icon" "$work/icon.png"

iconset="$work/AppIcon.iconset"
mkdir "$iconset"
for size in 16 32 128 256 512; do
    sips -z $size $size "$work/icon.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$work/icon.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o AppIcon.icns
echo "Wrote Icon/AppIcon.icns"
