#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Nogrammerly"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
DMG_PATH="$ROOT_DIR/dist/$APP_NAME-Installer.dmg"
ICON_FILE="$ROOT_DIR/Assets/Nogrammerly.icns"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nogrammerly-dmg.XXXXXX")"
SOURCE_DIR="$STAGING_DIR/$APP_NAME"
RW_DMG="$STAGING_DIR/rw.dmg"
DEVICE=""

cleanup() {
  [[ -n "$DEVICE" ]] && hdiutil detach "$DEVICE" -quiet -force >/dev/null 2>&1 || true
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

"$ROOT_DIR/script/build_and_run.sh" --bundle
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

# Disk contents: the app, an Applications shortcut, the full instructions, a background and a volume icon.
mkdir -p "$SOURCE_DIR/.background"
cp -R "$APP_BUNDLE" "$SOURCE_DIR/$APP_NAME.app"
ln -s /Applications "$SOURCE_DIR/Applications"
textutil -convert rtf "$ROOT_DIR/Assets/ReadMe.html" -output "$SOURCE_DIR/Read Me First.rtf"
swift "$ROOT_DIR/script/make_artwork.swift" background "$STAGING_DIR/background.png" "$STAGING_DIR/background@2x.png"
tiffutil -cathidpicheck "$STAGING_DIR/background.png" "$STAGING_DIR/background@2x.png" -out "$SOURCE_DIR/.background/background.tiff"

# Build a writable image, lay out its Finder window, then compress it.
hdiutil detach "/Volumes/$APP_NAME" -quiet -force >/dev/null 2>&1 || true
# Leave headroom for the volume icon and Finder metadata added below; compression removes the slack.
hdiutil create -volname "$APP_NAME" -srcfolder "$SOURCE_DIR" -fs HFS+ -format UDRW -size 64m -ov "$RW_DMG" >/dev/null
ATTACH_OUTPUT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG")"
DEVICE="$(awk '/Apple_HFS/ {print $1}' <<<"$ATTACH_OUTPUT")"
MOUNT_POINT="$(awk -F'\t' '/Apple_HFS/ {print $NF}' <<<"$ATTACH_OUTPUT")"
VOLUME_NAME="$(basename "$MOUNT_POINT")"
# Finder registers new volumes asynchronously; wait until it can see this one.
for _ in $(seq 1 20); do osascript -e "tell application \"Finder\" to get disk \"$VOLUME_NAME\"" >/dev/null 2>&1 && break; sleep 0.5; done

if ! osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOLUME_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 700}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 96
    set text size of viewOptions to 13
    set background picture of viewOptions to file ".background:background.tiff"
    set position of item "$APP_NAME.app" of container window to {170, 165}
    set position of item "Applications" of container window to {490, 165}
    set position of item "Read Me First.rtf" of container window to {330, 395}
    update without registering applications
    close
    -- Reopen once so Finder writes the final window state to .DS_Store.
    open
    delay 2
    close
  end tell
end tell
APPLESCRIPT
then
  echo "warning: Finder window layout was skipped (allow this terminal to control Finder to get the styled installer window)" >&2
fi

# Finder saves .DS_Store asynchronously; wait until it has been written before detaching.
for _ in $(seq 1 20); do [[ -s "$MOUNT_POINT/.DS_Store" ]] && break; sleep 0.5; done
sleep 3
# Add the disk icon last: Finder's layout pass above removes it.
cp "$ICON_FILE" "$MOUNT_POINT/.VolumeIcon.icns"
SetFile -a V "$MOUNT_POINT/.VolumeIcon.icns"
SetFile -a C "$MOUNT_POINT"
chmod -Rf go-w "$MOUNT_POINT" || true
sync
hdiutil detach "$DEVICE" -quiet
DEVICE=""
rm -f "$DMG_PATH"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" >/dev/null
hdiutil verify "$DMG_PATH" >/dev/null

# Give the .dmg file itself the app icon in Finder.
osascript -l JavaScript -e "ObjC.import('AppKit'); \$.NSWorkspace.sharedWorkspace.setIconForFileOptions(\$.NSImage.alloc.initWithContentsOfFile('$ICON_FILE'), '$DMG_PATH', 0)" >/dev/null

echo "Created $DMG_PATH"
