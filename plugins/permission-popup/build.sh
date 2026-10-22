#!/bin/sh
set -eu
cd "$(dirname "$0")"
app=PermissionPopup.app
# Pinned: this toolchain defaults to a macOS newer than the installed one, which LaunchServices rejects.
min_macos=13.0
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

build() {
    output=$1
    shift
    for arch in arm64 x86_64; do
        swiftc -O -swift-version 5 -target "$arch-apple-macos$min_macos" "$@" -o "$work/$(basename "$output")-$arch"
    done
    lipo -create "$work/$(basename "$output")-arm64" "$work/$(basename "$output")-x86_64" -output "$output"
}

mkdir -p "$work/$app/Contents/MacOS" "$work/$app/Contents/Resources"
cp Info.plist "$work/$app/Contents/Info.plist"
build "$work/$app/Contents/MacOS/permission-popup" Sources/*.swift
build "$work/make-icon" make-icon.swift
"$work/make-icon" "$work/AppIcon.iconset"
iconutil -c icns "$work/AppIcon.iconset" -o "$work/$app/Contents/Resources/AppIcon.icns"
# CI compares this against the sources to catch a committed app that is out of date.
./source-hash.sh > "$work/$app/Contents/Resources/source.sha256"
codesign --force --sign - "$work/$app"
# Swapped in whole, so a hook running mid-build never sees a half-written app.
rm -rf "$app.old"
[ -d "$app" ] && mv "$app" "$app.old"
mv "$work/$app" "$app"
rm -rf "$app.old"
