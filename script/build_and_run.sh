#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
APP_NAME="Nogrammerly"
VERSION="1.1"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
BUNDLE_ID="com.nogrammerly.app"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_MACOS="$APP_BUNDLE/Contents/MacOS"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
ICON_FILE="$ROOT_DIR/Assets/Nogrammerly.icns"
pkill -x "$APP_NAME" >/dev/null 2>&1 || true
swift build --package-path "$ROOT_DIR"
BUILD_BINARY="$(swift build --package-path "$ROOT_DIR" --show-bin-path)/$APP_NAME"
"$ROOT_DIR/script/create_icon.sh"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_BUNDLE/Contents/Resources"
cp "$BUILD_BINARY" "$APP_MACOS/$APP_NAME"
cp "$ICON_FILE" "$APP_BUNDLE/Contents/Resources/Nogrammerly.icns"
chmod +x "$APP_MACOS/$APP_NAME"
cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>$APP_NAME</string><key>CFBundleIconFile</key><string>Nogrammerly.icns</string><key>CFBundleIdentifier</key><string>$BUNDLE_ID</string><key>CFBundleName</key><string>$APP_NAME</string><key>CFBundleDisplayName</key><string>$APP_NAME</string><key>CFBundleShortVersionString</key><string>$VERSION</string><key>CFBundleVersion</key><string>$BUILD_NUMBER</string><key>LSApplicationCategoryType</key><string>public.app-category.productivity</string><key>NSHumanReadableCopyright</key><string>Writing checks run entirely on this Mac.</string><key>CFBundlePackageType</key><string>APPL</string><key>LSMinimumSystemVersion</key><string>14.0</string><key>NSAccessibilityUsageDescription</key><string>Nogrammerly uses Accessibility only to identify and improve text in the field you are actively writing in.</string><key>NSPrincipalClass</key><string>NSApplication</string></dict></plist>
PLIST
# Sign with a stable identity so macOS keeps the Accessibility permission across rebuilds.
# Run script/create_signing_identity.sh once to create it; ad-hoc signing works but loses the permission on every build.
SIGNING_IDENTITY="Nogrammerly Local Signing"
if security find-certificate -c "$SIGNING_IDENTITY" >/dev/null 2>&1; then
  codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"
else
  echo "warning: \"$SIGNING_IDENTITY\" not found; signing ad-hoc (Accessibility must be re-granted after each build). Run script/create_signing_identity.sh." >&2
  codesign --force --deep --sign - "$APP_BUNDLE"
fi

case "$MODE" in
  run) /usr/bin/open -n "$APP_BUNDLE" ;;
  --bundle|bundle) ;;
  --debug|debug) lldb -- "$APP_MACOS/$APP_NAME" ;;
  --logs|logs) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\"" ;;
  --telemetry|telemetry) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\"" ;;
  --verify|verify) /usr/bin/open -n "$APP_BUNDLE"; sleep 1; pgrep -x "$APP_NAME" >/dev/null ;;
  *) echo "usage: $0 [run|--bundle|--debug|--logs|--telemetry|--verify]" >&2; exit 2 ;;
esac
