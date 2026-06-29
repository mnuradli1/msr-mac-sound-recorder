#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="MSR Meeting Recorder"
EXECUTABLE_NAME="MSRMeetingRecorder"
PRODUCT_NAME="MSRMeetingRecorder"
VERSION="0.1.0"
BUNDLE_ID="app.msr.meeting-recorder"
DIST_DIR="$ROOT_DIR/dist"
APP_PATH="$DIST_DIR/$APP_NAME.app"
DMG_STAGING="$DIST_DIR/dmg-staging"
DMG_PATH="$DIST_DIR/MSR-Meeting-Recorder-$VERSION.dmg"
INFO_PLIST="$ROOT_DIR/Config/MSRMeetingRecorder-Info.plist"

cd "$ROOT_DIR"

echo "==> Building release executable"
swift build -c release --product "$PRODUCT_NAME"
BIN_DIR="$(swift build -c release --show-bin-path)"
EXECUTABLE_PATH="$BIN_DIR/$EXECUTABLE_NAME"

if [[ ! -x "$EXECUTABLE_PATH" ]]; then
  echo "Missing executable: $EXECUTABLE_PATH" >&2
  exit 1
fi

echo "==> Creating app bundle"
rm -rf "$APP_PATH" "$DMG_STAGING" "$DMG_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$EXECUTABLE_PATH" "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
cp "$INFO_PLIST" "$APP_PATH/Contents/Info.plist"
chmod +x "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"

/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $EXECUTABLE_NAME" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_PATH/Contents/Info.plist"

echo "APPL????" > "$APP_PATH/Contents/PkgInfo"

echo "==> Ad-hoc signing app bundle"
codesign --force --deep --sign - "$APP_PATH"

echo "==> Creating DMG"
mkdir -p "$DMG_STAGING"
cp -R "$APP_PATH" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_STAGING" \
  -ov \
  -format UDZO \
  "$DMG_PATH"
rm -rf "$DMG_STAGING"

echo "==> Verifying artifacts"
codesign --verify --deep --strict "$APP_PATH"
hdiutil verify "$DMG_PATH"

echo "App: $APP_PATH"
echo "DMG: $DMG_PATH"
