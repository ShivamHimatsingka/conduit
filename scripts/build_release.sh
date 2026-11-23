#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Shivam Himatsingka
#
# Builds the distributable installer: build/release/Conduit-<version>.pkg
#
#   scripts/build_release.sh                      # unsigned local test package (Gatekeeper will reject it if downloaded)
#   APP_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
#   INSTALLER_SIGN_IDENTITY="Developer ID Installer: Name (TEAMID)" \
#   NOTARY_PROFILE=conduit-notary \
#       scripts/build_release.sh --notarize       # signed, notarized, stapled
#
# Notary credentials, either:
#   NOTARY_PROFILE                         a profile saved with:  xcrun notarytool store-credentials conduit-notary ...
#   NOTARY_KEY_PATH + NOTARY_KEY_ID + NOTARY_ISSUER   an App Store Connect API key (what CI uses)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
APP_SIGN_IDENTITY="${APP_SIGN_IDENTITY:-}"
INSTALLER_SIGN_IDENTITY="${INSTALLER_SIGN_IDENTITY:-}"
NOTARIZE=0
for a in "$@"; do case "$a" in --notarize) NOTARIZE=1 ;; -h|--help) sed -n '2,16p' "$0"; exit 0 ;; *) echo "unknown option $a" >&2; exit 2 ;; esac; done

die() { echo "error: $*" >&2; exit 1; }
SIGNED=0
if [[ -n "$APP_SIGN_IDENTITY" && -n "$INSTALLER_SIGN_IDENTITY" ]]; then SIGNED=1
elif [[ -n "$APP_SIGN_IDENTITY$INSTALLER_SIGN_IDENTITY" ]]; then die "set BOTH APP_SIGN_IDENTITY and INSTALLER_SIGN_IDENTITY (or neither for an unsigned test build)"; fi
(( NOTARIZE )) && (( ! SIGNED )) && die "--notarize needs APP_SIGN_IDENTITY and INSTALLER_SIGN_IDENTITY"

OUT="build/release"
rm -rf "$OUT"; mkdir -p "$OUT/pkgs"

# ---- 1. build and sign the binaries (hardened runtime + secure timestamp are required for notarization)
echo "==> driver"
rm -rf build/Conduit.driver
if (( SIGNED )); then
    make build VERSION="$VERSION" SIGN_IDENTITY="$APP_SIGN_IDENTITY" SIGN_FLAGS="--timestamp --options runtime"
else
    make build VERSION="$VERSION"
fi
echo "==> app"
VERSION="$VERSION" SIGN_IDENTITY="${APP_SIGN_IDENTITY:--}" scripts/make_app.sh

# ---- 2. payload roots
DRV="$OUT/driver-root"; APP="$OUT/app-root"
mkdir -p "$DRV/Library/Audio/Plug-Ins/HAL" "$DRV/Library/Application Support/Conduit" "$APP/Applications"
ditto --norsrc --noextattr build/Conduit.driver "$DRV/Library/Audio/Plug-Ins/HAL/Conduit.driver"
install -m 755 scripts/uninstall.sh scripts/recover.sh "$DRV/Library/Application Support/Conduit/"
ditto --norsrc --noextattr build/Conduit.app "$APP/Applications/Conduit.app"
# Extended attributes (quarantine, provenance, ...) would be archived as ._* AppleDouble files inside the package.
xattr -cr "$DRV" "$APP"

# ---- 3. component packages. Bundles must not be relocatable: the installer would otherwise "upgrade"
#         any stray copy of Conduit.app it finds elsewhere on disk instead of installing to /Applications.
SIGN_PKG=(); (( SIGNED )) && SIGN_PKG=(--sign "$INSTALLER_SIGN_IDENTITY" --timestamp)
build_component() { # name root identifier [scripts-dir]
    local name="$1" root="$2" id="$3" scripts="${4:-}" plist="$OUT/$1.plist"
    pkgbuild --analyze --root "$root" "$plist" >/dev/null
    local n; n=$(/usr/libexec/PlistBuddy -c "Print" "$plist" | grep -c "BundleIsRelocatable" || true)
    for ((i = 0; i < n; i++)); do /usr/libexec/PlistBuddy -c "Set :$i:BundleIsRelocatable false" "$plist"; done
    # --filter drops AppleDouble (._*) entries that macOS synthesises for the unclearable com.apple.provenance attribute.
    local args=(--root "$root" --component-plist "$plist" --identifier "$id" --version "$VERSION" --install-location / --filter '/\._[^/]*$')
    [[ -n "$scripts" ]] && args+=(--scripts "$scripts")
    pkgbuild "${args[@]}" ${SIGN_PKG[@]+"${SIGN_PKG[@]}"} "$OUT/pkgs/$name.pkg"
}
echo "==> component packages"
build_component Conduit-Driver "$DRV" com.conduit.pkg.driver distribution/scripts/driver
build_component Conduit-App "$APP" com.conduit.pkg.app

# A release payload must not contain AppleDouble (._*) files. They appear when the build runs in a context whose files
# carry the kernel-protected com.apple.provenance attribute that cannot be cleared; build from a normal shell or CI.
DIRTY=$( { pkgutil --payload-files "$OUT/pkgs/Conduit-Driver.pkg"; pkgutil --payload-files "$OUT/pkgs/Conduit-App.pkg"; } | grep -c '/\._' || true)
if (( DIRTY > 0 )); then
    if (( SIGNED )); then die "payload contains $DIRTY AppleDouble (._*) entries; build from a clean shell / CI"
    else echo "warning: payload contains $DIRTY AppleDouble (._*) entries (harmless for a local test, fatal for a signed release)"; fi
fi

# ---- 4. product archive (the thing users download)
echo "==> product archive"
sed "s|@VERSION@|$VERSION|g" distribution/distribution.xml > "$OUT/distribution.xml"
PKG="$OUT/Conduit-$VERSION.pkg"
productbuild --distribution "$OUT/distribution.xml" --resources distribution/resources --package-path "$OUT/pkgs" \
    --version "$VERSION" ${SIGN_PKG[@]+"${SIGN_PKG[@]}"} "$PKG"

# ---- 5. notarize + staple
if (( NOTARIZE )); then
    echo "==> notarizing (this takes a few minutes)"
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then AUTH=(--keychain-profile "$NOTARY_PROFILE")
    elif [[ -n "${NOTARY_KEY_PATH:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER:-}" ]]; then AUTH=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
    else die "set NOTARY_PROFILE, or NOTARY_KEY_PATH + NOTARY_KEY_ID + NOTARY_ISSUER"; fi
    if ! xcrun notarytool submit "$PKG" "${AUTH[@]}" --wait --output-format json > "$OUT/notary.json"; then
        cat "$OUT/notary.json" 2>/dev/null || true; die "notarytool submit failed"
    fi
    STATUS=$(/usr/bin/plutil -extract status raw -o - "$OUT/notary.json" 2>/dev/null || echo unknown)
    if [[ "$STATUS" != "Accepted" ]]; then
        ID=$(/usr/bin/plutil -extract id raw -o - "$OUT/notary.json" 2>/dev/null || true)
        [[ -n "$ID" ]] && xcrun notarytool log "$ID" "${AUTH[@]}" || true
        die "notarization status: $STATUS"
    fi
    xcrun stapler staple "$PKG"
    xcrun stapler validate "$PKG"
    spctl --assess --type install --verbose=2 "$PKG"
fi

# ---- 6. report
( cd "$OUT" && shasum -a 256 "Conduit-$VERSION.pkg" > "Conduit-$VERSION.pkg.sha256" )
echo
echo "==> $PKG ($(du -h "$PKG" | cut -f1))"
pkgutil --check-signature "$PKG" || true
echo "payload:"; pkgutil --payload-files "$OUT/pkgs/Conduit-Driver.pkg" | grep -v "/Contents/" | sed 's/^/  driver: /'
pkgutil --payload-files "$OUT/pkgs/Conduit-App.pkg" | grep -v "/Contents/" | sed 's/^/  app:    /'
(( SIGNED )) || echo "NOTE: unsigned test build. Do not distribute; Gatekeeper rejects an unsigned package that has been downloaded."
