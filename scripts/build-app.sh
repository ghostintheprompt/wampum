#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift build -c release
APP="${WAMPUM_APP_OUTPUT:-$PWD/build/Wampum.app}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Wampum "$APP/Contents/MacOS/Wampum"
cp .build/release/WampumDocument "$APP/Contents/MacOS/WampumDocument"
cp scripts/document-check.py "$APP/Contents/Resources/document-check.py"
cp scripts/document-check.py .build/release/document-check.py
cp scripts/document-worker.py "$APP/Contents/Resources/document-worker.py"
cp scripts/document-worker.py .build/release/document-worker.py
cp .build/release/WampumQuality "$APP/Contents/MacOS/WampumQuality"
codesign --force --sign - "$APP/Contents/MacOS/WampumQuality"
codesign --force --sign - "$APP/Contents/MacOS/WampumDocument"
cp .build/release/WampumController "$APP/Contents/MacOS/WampumController"
codesign --force --sign - "$APP/Contents/MacOS/WampumController"
cp .build/release/WampumIntegrity "$APP/Contents/MacOS/WampumIntegrity"
codesign --force --sign - "$APP/Contents/MacOS/WampumIntegrity"
cp scripts/playwright-stdio.cjs "$APP/Contents/Resources/playwright-stdio.cjs"
ICONSET="$PWD/build/Wampum.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Resources/WampumIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" Resources/WampumIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Wampum.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Wampum</string>
<key>CFBundleIdentifier</key><string>com.ghostintheprompt.wampum</string>
<key>CFBundleIconFile</key><string>Wampum.icns</string>
<key>CFBundleName</key><string>Wampum</string>
<key>CFBundleDisplayName</key><string>Wampum</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.1</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
/usr/bin/plutil -replace CFBundleIdentifier -string "${WAMPUM_BUNDLE_ID:-com.ghostintheprompt.wampum}" "$APP/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleName -string "${WAMPUM_APP_NAME:-Wampum}" "$APP/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleDisplayName -string "${WAMPUM_APP_NAME:-Wampum}" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
printf '%s\n' "$APP"
