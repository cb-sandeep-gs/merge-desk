#!/bin/bash
# Builds MergeDesk.app from the SwiftPM executable: ./Scripts/build-app.sh [debug|release]
# Output: .build/MergeDesk.app (ad-hoc signed for local use; MD-7 adds Developer ID signing + notarization).
set -euo pipefail

CONFIGURATION="${1:-release}"
APP_NAME="MergeDesk"
PRODUCT="MergeDeskApp"
BUNDLE_ID="com.cricbuzz.mergedesk"
MIN_MACOS="14.0"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(sed -n 's/.*toolVersion = "\(.*\)".*/\1/p' "$ROOT/Sources/MergeDeskCore/MergeDeskConstants.swift")"

cd "$ROOT"
swift build -c "$CONFIGURATION" --product "$PRODUCT"
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"

APP="$ROOT/.build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$PRODUCT" "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Merge Desk</string>
  <key>CFBundleDisplayName</key><string>Merge Desk</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "Built $APP ($VERSION, $CONFIGURATION)"
