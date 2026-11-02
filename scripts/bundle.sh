#!/bin/sh
# Builds build/Loom.app from the SwiftPM binary.
#
# With SIGN_IDENTITY set to a Developer ID certificate this produces what
# notarization needs. Without it, the bundle is signed ad hoc, which runs on the
# machine that built it.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
config=${CONFIG:-release}
identity=${SIGN_IDENTITY:--}

swift build --package-path "$root" -c "$config" --product Loom
binary=$(swift build --package-path "$root" -c "$config" --show-bin-path)/Loom

app="$root/build/Loom.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$binary" "$app/Contents/MacOS/Loom"
cp "$root/App/Info.plist" "$app/Contents/Info.plist"
codesign --force --options runtime --entitlements "$root/App/Loom.entitlements" --sign "$identity" "$app"
echo "$app"
