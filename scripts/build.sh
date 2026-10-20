#!/bin/sh
# Builds dist/FlashEdit.app (universal: Apple silicon + Intel) and dist/FlashEdit.zip, the file a release ships.
# Needs only the Xcode Command Line Tools. Usage: scripts/build.sh [version]   (default 1.0.0)
set -e
cd "$(dirname "$0")/.."
VERSION=${1:-1.0.0}
for arch in arm64 x86_64; do swift build -c release --triple "$arch-apple-macosx14.0"; done
ARM=$(swift build -c release --triple arm64-apple-macosx14.0 --show-bin-path)
INTEL=$(swift build -c release --triple x86_64-apple-macosx14.0 --show-bin-path)
APP=dist/FlashEdit.app
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "$ARM/FlashEdit" "$INTEL/FlashEdit" -output "$APP/Contents/MacOS/FlashEdit"
cp Sources/FlashEdit/Presets/*.json assets/AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>FlashEdit</string>
  <key>CFBundleIdentifier</key><string>com.lokendrakushwah.flashedit</string>
  <key>CFBundleName</key><string>FlashEdit</string>
  <key>CFBundleDisplayName</key><string>FlashEdit</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>FlashEdit records voice-overs for your videos with the microphone.</string>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>Image or video</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Alternate</string>
    <key>LSItemContentTypes</key><array><string>public.image</string><string>public.heic</string><string>public.heif</string><string>public.movie</string></array>
  </dict></array>
</dict></plist>
PLIST
codesign --force -s - "$APP"
ditto -c -k --keepParent "$APP" dist/FlashEdit.zip
echo "Built $(pwd)/$APP and dist/FlashEdit.zip (version $VERSION)"
