# Releasing Conduit

A release is one signed, notarized, stapled installer package, `Conduit-<version>.pkg`, containing two components:

| Component | Installs | Notes |
|---|---|---|
| `Conduit-Driver.pkg` | `/Library/Audio/Plug-Ins/HAL/Conduit.driver`, plus `/Library/Application Support/Conduit/{uninstall,recover}.sh` | `preinstall` removes any old copy; `postinstall` restarts `coreaudiod` (audio pauses for a moment) |
| `Conduit-App.pkg` | `/Applications/Conduit.app` | menu-bar app, universal, hardened runtime |

Both bundles are universal (arm64 + x86_64), target macOS 14.4+, and are marked non-relocatable so the installer never "upgrades" a stray copy elsewhere on disk.

## One-time setup (Apple Developer Program account)

1. In your Apple Developer account create two certificates and install them in your login keychain:
   * **Developer ID Application** (signs the driver and the app)
   * **Developer ID Installer** (signs the package)
2. Create notarization credentials, either
   * a keychain profile: `xcrun notarytool store-credentials conduit-notary --apple-id <id> --team-id <TEAMID> --password <app-specific-password>`, or
   * an App Store Connect API key (`.p8`, key id, issuer id), which is what CI uses.

## Build locally

```bash
# Unsigned test package (never distribute; Gatekeeper rejects it once downloaded)
scripts/build_release.sh

# Signed, notarized, stapled
export APP_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export INSTALLER_SIGN_IDENTITY="Developer ID Installer: Your Name (TEAMID)"
export NOTARY_PROFILE=conduit-notary
VERSION=0.1.0 scripts/build_release.sh --notarize
```

Output: `build/release/Conduit-<version>.pkg` and its `.sha256`. The script then prints the signature check and payload listing. `--notarize` submits with `notarytool --wait`, prints the notary log on rejection, staples the ticket, and runs `spctl --assess --type install`.

What gets signed, and how:

* **Driver**: `codesign --options runtime --timestamp` with *no entitlements*. A HAL plug-in runs inside `coreaudiod`; it needs none, and it does not need library-validation exceptions.
* **App**: hardened runtime + `app/Conduit.entitlements` (`com.apple.security.device.audio-input`, for microphone sources). Process taps are governed by the *Audio Capture* privacy permission (`NSAudioCaptureUsageDescription`), not an entitlement.
* **Packages**: `pkgbuild`/`productbuild --sign "Developer ID Installer" --timestamp`.

## Build in CI

Pushing a tag `vX.Y.Z` runs `.github/workflows/release.yml` on a clean macOS runner, **once you set the repository variable `SIGNED_RELEASES` to `true`** (until then the workflow is skipped, so tagging a hand-made pre-release does not fail). Required repository secrets:

| Secret | Value |
|---|---|
| `DEVELOPER_ID_APPLICATION_P12`, `DEVELOPER_ID_INSTALLER_P12` | base64 of each exported `.p12` |
| `CERT_PASSWORD` | the `.p12` password |
| `APP_SIGN_IDENTITY`, `INSTALLER_SIGN_IDENTITY` | the full certificate names, as above |
| `NOTARY_API_KEY_P8`, `NOTARY_KEY_ID`, `NOTARY_ISSUER` | App Store Connect API key |

The workflow imports the certificates into a throwaway keychain, runs `scripts/build_release.sh --notarize`, and attaches the package and checksum to a GitHub release. `.github/workflows/ci.yml` builds and runs the hardware-free tests on every push.

Build releases from a clean environment such as CI. If files on the build machine carry the protected `com.apple.provenance` attribute (this happens when the build is launched from some sandboxed tools), `pkgbuild` archives `._*` AppleDouble entries; for a signed release the script aborts rather than ship them.

## Verify a package by hand

```bash
pkgutil --check-signature build/release/Conduit-0.1.0.pkg
spctl --assess --type install --verbose=2 build/release/Conduit-0.1.0.pkg
xcrun stapler validate build/release/Conduit-0.1.0.pkg
pkgutil --expand-full build/release/Conduit-0.1.0.pkg /tmp/x
codesign --verify --strict --deep --verbose=2 /tmp/x/Conduit-Driver.pkg/Payload/Library/Audio/Plug-Ins/HAL/Conduit.driver
```

## Uninstall and recovery

```bash
sudo "/Library/Application Support/Conduit/uninstall.sh"       # removes driver, app and receipts, restarts coreaudiod
sudo "/Library/Application Support/Conduit/recover.sh"         # if audio is broken: quarantines the driver instead
```
No working Terminal: boot to Recovery, open Terminal, `rm -rf "/Volumes/Macintosh HD/Library/Audio/Plug-Ins/HAL/Conduit.driver"`, reboot.

## Release checklist

1. `make test-all` is green locally (needs no `sudo`).
2. `make install`, then `conduit-bench loopback` and `conduitctl tap` against the live driver (see ARCHITECTURE.md, Phase 5).
3. Bump `VERSION`, tag `vX.Y.Z`, push the tag.
4. After CI finishes, download the package on a *different* Mac and confirm Gatekeeper opens it without warnings.
