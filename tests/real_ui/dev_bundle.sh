#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Shivam Himatsingka
#
# Fast arm64-only app bundle for UI tests: build/dev/Conduit.app from the SwiftPM release binary (no universal build, no driver build).
set -euo pipefail
cd "$(dirname "$0")/../.."
APP=build/dev/Conduit.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Conduit "$APP/Contents/MacOS/ConduitUITest"   # own executable name: tests never kill or touch the real Conduit
cp app/Resources/AppIcon.icns "$APP/Contents/Resources/"
[[ -d build/Conduit.driver ]] && ditto --norsrc --noextattr build/Conduit.driver "$APP/Contents/Resources/Conduit.driver"
sed -e "s|@APP_BUNDLE_ID@|com.conduit.app.uitest|g" -e "s|@VERSION@|0.0.0-dev|g" app/Info.plist.in > "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable ConduitUITest" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName ConduitUITest" "$APP/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1
echo "$APP"
