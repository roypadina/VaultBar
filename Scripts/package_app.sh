#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="VaultBar"
BUNDLE_ID="com.padina.vaultbar"
BUILD_CONFIG="release"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
# CODE_SIGN_IDENTITY, else (dev builds) the first code-signing identity in the keychain, else ad hoc (e.g. CI).
# A stable identity keeps the login item across rebuilds.
SIGNING_IDENTITY="${CODE_SIGN_IDENTITY:-}"
# RELEASE=1: also zip the app into dist/VaultBar.zip for GitHub Releases and the Homebrew cask.
RELEASE="${RELEASE:-}"

cd "$ROOT_DIR"

# Map the checkout path to "." so no local home-folder path ends up in the binary.
swift build -c "$BUILD_CONFIG" -Xswiftc -file-prefix-map -Xswiftc "$ROOT_DIR=."

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp ".build/$BUILD_CONFIG/VaultBarApp" "$MACOS_DIR/$APP_NAME"
cp Assets/icons/AppIcon.icns Assets/icons/menubar-*.png "$RESOURCES_DIR/"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.2</string>
    <key>CFBundleVersion</key>
    <string>3</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>$BUNDLE_ID</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>vaultbar</string>
            </array>
        </dict>
    </array>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 Padina</string>
</dict>
</plist>
PLIST

# Login item (SMAppService.agent): launchd restarts VaultBar after a crash, but not after Quit (exit 0).
mkdir -p "$CONTENTS_DIR/Library/LaunchAgents"
cat > "$CONTENTS_DIR/Library/LaunchAgents/$BUNDLE_ID.agent.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$BUNDLE_ID.agent</string>
    <key>BundleProgram</key>
    <string>Contents/MacOS/$APP_NAME</string>
    <key>AssociatedBundleIdentifiers</key>
    <array>
        <string>$BUNDLE_ID</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
</dict>
</plist>
PLIST

chmod +x "$MACOS_DIR/$APP_NAME"
# Drop the debug map (object-file paths from the build machine).
strip -S -x "$MACOS_DIR/$APP_NAME"

# Published zips are ad hoc signed unless CODE_SIGN_IDENTITY is set, so no local certificate name ships.
if [[ -n "$RELEASE" && -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="-"
fi

if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="$(
        security find-identity -v -p codesigning 2>/dev/null \
            | awk -F '"' '/valid identities found/ { next } /".+"/ { print $2; exit }'
    )"
fi

if [[ -n "$SIGNING_IDENTITY" ]]; then
    codesign --force --deep --sign "$SIGNING_IDENTITY" --identifier "$BUNDLE_ID" "$APP_DIR"
else
    echo "warning: no code-signing identity found; falling back to ad hoc signing" >&2
    codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP_DIR"
fi

if [[ -n "$RELEASE" ]]; then
    ZIP="$DIST_DIR/VaultBar.zip"
    rm -f "$ZIP"
    ditto -c -k --norsrc --noextattr --keepParent "$APP_DIR" "$ZIP"
    shasum -a 256 "$ZIP"
fi

echo "$APP_DIR"
