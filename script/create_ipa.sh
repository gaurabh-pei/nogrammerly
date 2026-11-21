#!/usr/bin/env bash
# Builds an UNSIGNED dist/Nogrammerly-iOS-unsigned.ipa (app + keyboard extension).
# Sign and install it with your own Apple ID using AltStore or Sideloadly.
# Same approach as https://github.com/adro0303/ipa-builder: build with code signing
# off, then zip the .app into Payload/.
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD=.build/ios-ipa
OUT=dist/Nogrammerly-iOS-unsigned.ipa
rm -rf "$BUILD" "$OUT"

xcodebuild \
  -project iOS/Nogrammerly.xcodeproj \
  -scheme NogrammerlyiOS \
  -configuration Release \
  -sdk iphoneos \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$BUILD/DerivedData" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true

APP="$BUILD/DerivedData/Build/Products/Release-iphoneos/NogrammerlyiOS.app"
[ -d "$APP/PlugIns/NogrammerlyKeyboard.appex" ] || { echo "Build failed or keyboard extension missing: $APP" >&2; exit 1; }

mkdir -p "$BUILD/Payload" dist
cp -R "$APP" "$BUILD/Payload/"
(cd "$BUILD" && zip -qry "$OLDPWD/$OUT" Payload)
echo "Wrote $OUT ($(du -h "$OUT" | cut -f1))"
