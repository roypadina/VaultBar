#!/bin/bash
# Regenerates the VaultBar demo from scratch: build the real VaultBarCore, compile the real PasswordPanel + kit + scene, render frames
# offscreen (no window is ever shown, nothing is mounted, unlocked, clicked or captured, the installed app is never launched), encode.
# One command: ./render.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="${KIT:-$HERE}"; [ -f "$KIT/DemoKit.swift" ] || KIT="$HERE/../kit"          # repo: kit is vendored next to this file
APP="${APP_SRC:-$HERE/../..}"                                                   # repo: docs/demo -> repo root
GIF="${GIF:-$HERE/../demo.gif}"                                                 # repo: docs/demo.gif
BUILD="${BUILD:-${TMPDIR:-/tmp}/vaultbar-demo}"                                 # never inside the repo (hundreds of MB of frames)
mkdir -p "$BUILD"
# PasswordPanel.swift does `import VaultBarCore`: build the app's real Core as a module (it is only used for `Secret`).
swiftc -swift-version 5 -O -emit-library -static -module-name VaultBarCore -emit-module -emit-module-path "$BUILD/VaultBarCore.swiftmodule" \
  -o "$BUILD/libVaultBarCore.a" "$APP"/Sources/VaultBarCore/*.swift
swiftc -swift-version 5 -parse-as-library -O -I "$BUILD" -L "$BUILD" -lVaultBarCore -o "$BUILD/demo" \
  "$KIT/DemoKit.swift" "$HERE/scene.swift" "$APP/Sources/VaultBarApp/PasswordPanel.swift"
rm -rf "$BUILD/frames"
VB_ASSETS="$APP/Assets/icons" \
  "$BUILD/demo" "$BUILD/frames" 30 -AppleLocale en_US -AppleLanguages "(en)"
POSTER=${POSTER:-147}  # the unlock panel with ten dots typed (shows the app, never the empty desktop)
"$KIT/encode.sh" "$BUILD/frames" "$GIF" "${MP4:-}" "${WEBP:-}" "${POSTER:-}"
rm -rf "$BUILD/frames"                                                            # only after a successful encode (set -e)
