#!/bin/sh
set -eu
cd "$(dirname "$0")"
app=PermissionPopup.app
# Pinned: this toolchain defaults to a macOS newer than the installed one, which LaunchServices rejects.
min_macos=13.0
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

build() {
    for arch in arm64 x86_64; do
        swiftc -O -swift-version 5 -target "$arch-apple-macos$min_macos" "$1" -o "$work/$2-$arch"
    done
    lipo -create "$work/$2-arm64" "$work/$2-x86_64" -output "$3"
}

mkdir -p "$work/$app/Contents/MacOS" "$work/$app/Contents/Resources"
cp Info.plist "$work/$app/Contents/Info.plist"
build PermissionPopup.swift permission-popup "$work/$app/Contents/MacOS/permission-popup"
build make-icon.swift make-icon "$work/make-icon"
"$work/make-icon" "$work/AppIcon.iconset"
iconutil -c icns "$work/AppIcon.iconset" -o "$work/$app/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$work/$app"
# Swapped in whole, so a hook running mid-build never sees a half-written app.
rm -rf "$app.old"
[ -d "$app" ] && mv "$app" "$app.old"
mv "$work/$app" "$app"
rm -rf "$app.old"
