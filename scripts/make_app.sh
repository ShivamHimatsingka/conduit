#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Shivam Himatsingka
#
# Assembles build/Conduit.app from the SwiftPM release build (universal arm64 + x86_64), with the audio driver
# embedded in Contents/Resources so the app can install it itself (DriverInstaller).
#   scripts/make_app.sh                       # ad-hoc signed, hardened runtime
#   SIGN_IDENTITY="Developer ID Application: ..." scripts/make_app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.0.5}"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.conduit.app}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
APP="build/Conduit.app"

echo "==> swift build (universal)"
swift build -c release --arch arm64 --arch x86_64 --product Conduit
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Conduit"

echo "==> driver (embedded in the app)"
rm -rf build/Conduit.driver
if [[ "$SIGN_IDENTITY" == "-" ]]; then make build VERSION="$VERSION" >/dev/null
else make build VERSION="$VERSION" SIGN_IDENTITY="$SIGN_IDENTITY" SIGN_FLAGS="--timestamp --options runtime" >/dev/null; fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Conduit"
cp app/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# The driver keeps its own signature; the app signature below seals it as a resource.
ditto --norsrc --noextattr build/Conduit.driver "$APP/Contents/Resources/Conduit.driver"
sed -e "s|@APP_BUNDLE_ID@|$APP_BUNDLE_ID|g" -e "s|@VERSION@|$VERSION|g" app/Info.plist.in > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> codesign ($SIGN_IDENTITY)"
TS=(--timestamp=none); [[ "$SIGN_IDENTITY" != "-" ]] && TS=(--timestamp)
codesign --force --sign "$SIGN_IDENTITY" "${TS[@]}" --options runtime --entitlements app/Conduit.entitlements "$APP"
codesign --verify --strict --verbose=1 "$APP"
codesign --verify --strict --verbose=1 "$APP/Contents/Resources/Conduit.driver"
lipo -info "$APP/Contents/MacOS/Conduit"
lipo -info "$APP/Contents/Resources/Conduit.driver/Contents/MacOS/Conduit"
echo "OK: $APP"
