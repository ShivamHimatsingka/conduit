#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Shivam Himatsingka
#
# Clean uninstall of the Conduit driver (and app, once it exists).
#   sudo scripts/uninstall.sh
# For a broken system use scripts/recover.sh instead.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo $0" >&2; exit 1; }

here="$(cd "$(dirname "$0")" && pwd)"
rm -rf /Library/Audio/Plug-Ins/HAL/Conduit*.driver
rm -rf /Applications/Conduit.app
exec "$here/recover.sh" --purge
