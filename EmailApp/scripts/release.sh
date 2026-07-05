#!/bin/bash
# Builds a signed, notarized, DMG-packaged release of Threadwell.
#
# Prerequisites (one-time, manual — see README section this script's
# companion doc, or the assistant's explanation):
#   1. A "Developer ID Application" certificate installed in your login
#      keychain (requires an active Apple Developer Program membership).
#   2. Notarization credentials stored once via:
#        xcrun notarytool store-credentials "threadwell-notary" \
#          --apple-id "you@example.com" \
#          --team-id "KUKVJ5G7P5" \
#          --password "xxxx-xxxx-xxxx-xxxx"   # an app-specific password
#      (generate the app-specific password at appleid.apple.com >
#      Sign-In and Security > App-Specific Passwords)
#
# Usage: ./scripts/release.sh

set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Threadwell"
SCHEME="EmailApp"
PROJECT="EmailApp.xcodeproj"
NOTARY_PROFILE="threadwell-notary"

BUILD_DIR="$(pwd)/build"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
DMG_PATH="$BUILD_DIR/$APP_NAME.dmg"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Checking for a Developer ID Application signing identity..."
if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  echo "ERROR: No 'Developer ID Application' certificate found in your keychain."
  echo "This requires an active (paid) Apple Developer Program membership."
  echo "See the setup steps above this line in the script, or ask the assistant to re-explain."
  exit 1
fi

echo "==> Checking for stored notarization credentials (profile: $NOTARY_PROFILE)..."
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "ERROR: No notarization credentials stored under profile '$NOTARY_PROFILE'."
  echo "Run this once first:"
  echo "  xcrun notarytool store-credentials \"$NOTARY_PROFILE\" --apple-id \"YOUR_APPLE_ID\" --team-id \"KUKVJ5G7P5\" --password \"YOUR_APP_SPECIFIC_PASSWORD\""
  exit 1
fi

echo "==> Archiving (Release configuration)..."
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  -destination "generic/platform=macOS" \
  | xcbeautify 2>/dev/null || xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  -destination "generic/platform=macOS"

echo "==> Exporting signed .app with Developer ID..."
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "scripts/ExportOptions.plist"

APP_PATH="$EXPORT_PATH/$APP_NAME.app"
if [ ! -d "$APP_PATH" ]; then
  echo "ERROR: expected export at $APP_PATH but it doesn't exist."
  exit 1
fi

echo "==> Verifying code signature..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "==> Zipping for notarization submission..."
ZIP_PATH="$BUILD_DIR/$APP_NAME-for-notarization.zip"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "==> Submitting to Apple notary service (this can take a few minutes)..."
xcrun notarytool submit "$ZIP_PATH" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

echo "==> Stapling notarization ticket to the app..."
xcrun stapler staple "$APP_PATH"

echo "==> Verifying Gatekeeper acceptance..."
spctl --assess --type execute --verbose=4 "$APP_PATH"

echo "==> Building DMG..."
DMG_STAGING="$BUILD_DIR/dmg-staging"
mkdir -p "$DMG_STAGING"
cp -R "$APP_PATH" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

hdiutil create -volname "$APP_NAME" \
  -srcfolder "$DMG_STAGING" \
  -ov -format UDZO \
  "$DMG_PATH"

echo "==> Notarizing the DMG itself too (Gatekeeper checks the DMG on first open)..."
xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait
xcrun stapler staple "$DMG_PATH"

echo
echo "Done. Signed, notarized installer at:"
echo "  $DMG_PATH"
