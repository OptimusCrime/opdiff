#!/usr/bin/env bash
# Builds a release binary and wraps it in build/OptimusDiff.app
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
BIN="$BIN_DIR/opdiff"
APP="build/OptimusDiff.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/opdiff"
# SwiftPM resource bundles (e.g. highlight.js + themes) are looked up in Contents/Resources.
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
for bundle in "$BIN_DIR"/*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>OptimusDiff</string>
    <key>CFBundleDisplayName</key><string>OptimusDiff</string>
    <key>CFBundleIdentifier</key><string>io.github.optimuscrime.opdiff</string>
    <key>CFBundleExecutable</key><string>opdiff</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
</dict>
</plist>
PLIST

# Ad-hoc signature so Gatekeeper is happy running a locally built app.
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
