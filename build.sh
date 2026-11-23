#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Shivam Himatsingka
#
# Friendly front-end for the Makefile with preflight checks.
#   ./build.sh [build|install|uninstall|test|clean] [make VAR=value ...]
set -euo pipefail
cd "$(dirname "$0")"

cmd="${1:-build}"
[[ $# -gt 0 ]] && shift

die() { echo "error: $*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "macOS only"
command -v clang++ >/dev/null   || die "clang++ not found - run: xcode-select --install"
command -v codesign >/dev/null  || die "codesign not found - install Xcode command line tools"
command -v lipo >/dev/null      || die "lipo not found"

os_major="$(sw_vers -productVersion | cut -d. -f1)"
os_minor="$(sw_vers -productVersion | cut -d. -f2)"
if (( os_major < 14 )) || (( os_major == 14 && os_minor < 4 )); then
    echo "warning: host is macOS $(sw_vers -productVersion); the driver targets 14.4+" >&2
fi

case "$cmd" in
    build|install|uninstall|test|clean|verify)
        exec make "$cmd" "$@" ;;
    *)
        die "unknown command '$cmd' (build|install|uninstall|test|clean|verify)" ;;
esac
