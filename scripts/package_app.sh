#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="MSR Meeting Recorder"
EXECUTABLE_NAME="MSRMeetingRecorder"
PRODUCT_NAME="MSRMeetingRecorder"
source "$ROOT_DIR/Config/version.env"
VERSION="$MSR_VERSION"
BUILD_NUMBER="${MSR_BUILD_NUMBER:-$(git rev-list --count HEAD)}"
BUNDLE_ID="app.msr.meeting-recorder"
DIST_DIR="$ROOT_DIR/dist"
APP_PATH="$DIST_DIR/$APP_NAME.app"
DMG_STAGING="$DIST_DIR/dmg-staging"
DMG_PATH="$DIST_DIR/MSR-Meeting-Recorder-$VERSION.dmg"
APP_ZIP_PATH="$DIST_DIR/MSR-Meeting-Recorder-$VERSION-app.zip"
INFO_PLIST="$ROOT_DIR/Config/MSRMeetingRecorder-Info.plist"
ICON_PATH="$ROOT_DIR/Assets/AppIcon/MSRMeetingRecorder.icns"
ENTITLEMENTS_PATH="$ROOT_DIR/Config/MSRMeetingRecorder.entitlements"

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
rm -rf "$APP_PATH" "$DMG_STAGING" "$DMG_PATH" "$APP_ZIP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$EXECUTABLE_PATH" "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
cp "$INFO_PLIST" "$APP_PATH/Contents/Info.plist"
cp "$ICON_PATH" "$APP_PATH/Contents/Resources/MSRMeetingRecorder.icns"
RESOURCE_BUNDLE="$(find "$BIN_DIR" -maxdepth 1 -type d -name '*MSRMeetingRecorder*.bundle' -print -quit)"
if [[ -n "$RESOURCE_BUNDLE" ]]; then
  cp -R "$RESOURCE_BUNDLE" "$APP_PATH/Contents/Resources/"
  for localization in "$RESOURCE_BUNDLE"/*.lproj; do
    [[ -d "$localization" ]] || continue
    cp -R "$localization" "$APP_PATH/Contents/Resources/"
  done
fi
chmod +x "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"

/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $EXECUTABLE_NAME" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP_PATH/Contents/Info.plist"

echo "APPL????" > "$APP_PATH/Contents/PkgInfo"

if [[ -n "${APPLE_SIGNING_IDENTITY:-}" ]]; then
  echo "==> Developer ID signing app bundle"
  codesign --force --deep --options runtime --timestamp --entitlements "$ENTITLEMENTS_PATH" --sign "$APPLE_SIGNING_IDENTITY" "$APP_PATH"
else
  echo "==> Ad-hoc signing app bundle"
  codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS_PATH" --sign - "$APP_PATH"
fi

echo "==> Creating app zip"
(
  cd "$DIST_DIR"
  ditto -c -k --sequesterRsrc --keepParent "$APP_NAME.app" "$APP_ZIP_PATH"
)

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
unzip -tq "$APP_ZIP_PATH"
hdiutil verify "$DMG_PATH"

if [[ -n "${APPLE_SIGNING_IDENTITY:-}" && -n "${APPLE_NOTARY_PROFILE:-}" ]]; then
  echo "==> Notarizing and stapling"
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$APPLE_NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP_PATH"
  xcrun stapler staple "$DMG_PATH"
fi

shasum -a 256 "$APP_ZIP_PATH" "$DMG_PATH" > "$DIST_DIR/SHA256SUMS"
DMG_SHA="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
sed \
  -e "s/__VERSION__/$VERSION/g" \
  -e "s/__SHA256__/$DMG_SHA/g" \
  -e "s|__URL__|${MSR_RELEASE_URL:-https://github.com/mnuradli1/msr-mac-sound-recorder/releases/download/v$VERSION/MSR-Meeting-Recorder-$VERSION.dmg}|g" \
  "$ROOT_DIR/packaging/msr.rb.template" > "$DIST_DIR/msr.rb"

printf '{"version":"%s","build":"%s","commit":"%s","artifacts":["%s","%s"]}\n' \
  "$VERSION" "$BUILD_NUMBER" "$(git rev-parse HEAD)" "$(basename "$APP_ZIP_PATH")" "$(basename "$DMG_PATH")" \
  > "$DIST_DIR/provenance.json"

echo "App: $APP_PATH"
echo "App ZIP: $APP_ZIP_PATH"
echo "DMG: $DMG_PATH"
echo "Checksums: $DIST_DIR/SHA256SUMS"
