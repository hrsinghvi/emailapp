#!/bin/bash
# Builds a locally-signed (not notarized) DMG of Threadwell — no paid Apple
# Developer Program membership required. Runs standalone via double-click,
# no Xcode/Terminal needed on the machine that installs it.
#
# Caveat this script can't get around: without Apple notarization, macOS
# Gatekeeper will show a one-time "Apple could not verify this app is free
# of malware" prompt the first time it's opened (on this Mac or any other).
# That's expected, not a bug — right-click the app -> Open, or System
# Settings > Privacy & Security > "Open Anyway", clears it permanently for
# that copy of the app.
#
# Usage: ./scripts/release-local.sh

set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Threadwell"
SCHEME="EmailApp"
PROJECT="EmailApp.xcodeproj"

BUILD_DIR="$(pwd)/build"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
DMG_PATH="$BUILD_DIR/$APP_NAME.dmg"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Archiving (Release configuration)..."
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  -destination "generic/platform=macOS"

APP_PATH="$ARCHIVE_PATH/Products/Applications/$APP_NAME.app"
if [ ! -d "$APP_PATH" ]; then
  echo "ERROR: expected archived app at $APP_PATH but it doesn't exist."
  exit 1
fi

echo "==> Verifying the app is at least signed (locally) and structurally valid..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "==> Building DMG..."
DMG_STAGING="$BUILD_DIR/dmg-staging"
mkdir -p "$DMG_STAGING"
cp -R "$APP_PATH" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

hdiutil create -volname "$APP_NAME" \
  -srcfolder "$DMG_STAGING" \
  -ov -format UDZO \
  "$DMG_PATH"

echo
echo "Done. Installer (not notarized — see the note at the top of this script) at:"
echo "  $DMG_PATH"
echo
echo "First launch on any Mac will need a right-click -> Open (or System"
echo "Settings > Privacy & Security > \"Open Anyway\") once, since it isn't"
echo "notarized by Apple. After that first approval it opens normally."
