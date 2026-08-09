#!/usr/bin/env bash
# Builds a release binary and installs ClaudeUsageBar.app to ~/Applications.
# Run once from Terminal; after that launch from Finder, Spotlight, or the Dock.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="ClaudeUsageBar"
BUNDLE_ID="com.keith.ClaudeUsageBar"
INSTALL_DIR="/Applications"
APP_BUNDLE="${INSTALL_DIR}/${APP_NAME}.app"

echo "==> Building ${APP_NAME} (release)..."
cd "$SCRIPT_DIR"
swift build -c release

BINARY="${SCRIPT_DIR}/.build/release/${APP_NAME}"
if [[ ! -f "$BINARY" ]]; then
    echo "Build failed -- binary not found at ${BINARY}" >&2
    exit 1
fi

# Stop any running instance so we can replace the binary safely.
if pgrep -x "$APP_NAME" > /dev/null 2>&1; then
    echo "==> Stopping running instance..."
    pkill -x "$APP_NAME" || true
    sleep 0.5
fi

echo "==> Installing to ${APP_BUNDLE}..."
rm -rf "$APP_BUNDLE"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"

cp "$BINARY" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

# Write Info.plist using printf to avoid heredoc quoting issues.
printf '<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>%s</string>
    <key>CFBundleIdentifier</key>
    <string>%s</string>
    <key>CFBundleName</key>
    <string>Claude Usage Bar</string>
    <key>CFBundleDisplayName</key>
    <string>Claude Usage Bar</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
</dict>
</plist>
' "$APP_NAME" "$BUNDLE_ID" > "${APP_BUNDLE}/Contents/Info.plist"

# Strip quarantine so macOS does not block the first launch.
xattr -cr "$APP_BUNDLE" 2>/dev/null || true

echo "==> Launching ${APP_NAME}..."
open "$APP_BUNDLE"

echo ""
echo "Done. ${APP_NAME}.app is at ${INSTALL_DIR}"
echo "Drag it to your Dock or add it in System Settings > Login Items."
