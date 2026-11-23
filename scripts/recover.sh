#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Shivam Himatsingka
#
# EMERGENCY RECOVERY. Use when audio is missing, glitching, or coreaudiod is
# crash-looping after installing a Conduit driver.
#
#   sudo scripts/recover.sh                 # quarantine every Conduit*.driver, restart coreaudiod
#   sudo scripts/recover.sh --purge         # delete instead of quarantine
#   sudo scripts/recover.sh --reset-prefs   # additionally reset CoreAudio user preferences
#   sudo scripts/recover.sh --target /Volumes/Macintosh\ HD   # from Recovery mode Terminal
#
# Nothing here can damage the OS: HAL plug-ins are plain bundles in
# /Library/Audio/Plug-Ins/HAL and macOS ignores them when they are absent.
set -uo pipefail

PURGE=0; RESET_PREFS=0; TARGET=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --purge) PURGE=1 ;;
        --reset-prefs) RESET_PREFS=1 ;;
        --target) TARGET="${2:-}"; shift ;;
        -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo $0 $*" >&2; exit 1; }

HAL="${TARGET%/}/Library/Audio/Plug-Ins/HAL"
QUARANTINE="${TARGET%/}/Library/Application Support/Conduit/quarantine/$(date +%Y%m%d-%H%M%S)"

echo "==> Scanning $HAL"
found=0
shopt -s nullglob
for d in "$HAL"/Conduit*.driver; do
    found=1
    if (( PURGE )); then
        echo "    removing    $d"
        rm -rf "$d"
    else
        mkdir -p "$QUARANTINE"
        echo "    quarantine  $d -> $QUARANTINE/"
        mv "$d" "$QUARANTINE/"
    fi
done
(( found )) || echo "    no Conduit drivers found"

# Installer receipts, so a later reinstall is not treated as an upgrade of a ghost.
if [[ -z "$TARGET" ]]; then
    for pkg in $(pkgutil --pkgs 2>/dev/null | grep -i '^com\.conduit\.'); do
        echo "==> Forgetting receipt $pkg"
        pkgutil --forget "$pkg" >/dev/null 2>&1 || true
    done
fi

if (( RESET_PREFS )) && [[ -z "$TARGET" ]]; then
    echo "==> Resetting CoreAudio preferences (system + console user)"
    rm -f /Library/Preferences/Audio/com.apple.audio.DeviceSettings.plist \
          /Library/Preferences/Audio/com.apple.audio.SystemSettings.plist
    user="${SUDO_USER:-}"
    if [[ -n "$user" ]]; then
        sudo -u "$user" defaults delete com.apple.audio.AudioMIDISetup >/dev/null 2>&1 || true
    fi
fi

if [[ -z "$TARGET" ]]; then
    echo "==> Restarting coreaudiod"
    killall coreaudiod 2>/dev/null || launchctl kickstart -k system/com.apple.audio.coreaudiod || true
    sleep 2
    if pgrep -x coreaudiod >/dev/null; then
        echo "==> coreaudiod is running again. Audio devices:"
        system_profiler SPAudioDataType 2>/dev/null | grep -E '^\s{8}[A-Za-z].*:$' || true
    else
        echo "!! coreaudiod is not running yet; wait a few seconds or reboot." >&2
    fi
else
    echo "==> Offline target: reboot the machine to finish."
fi
echo "Done."
