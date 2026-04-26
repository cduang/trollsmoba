#!/bin/sh

# This script is used to build the TrollSpeed app and create a tipa file with Xcode.
set -eu

if [ $# -ne 1 ]; then
    echo "Usage: $0 <version>"
    exit 1
fi

VERSION=$1
VERSION=${VERSION#v}

ARCHIVE_NAME="TrollSpeed.xcarchive"
ARCHIVE_PRODUCTS="$ARCHIVE_NAME/Products"
APP_NAME="Apibug-HUD.app"
APP_PATH="$ARCHIVE_PRODUCTS/Applications/$APP_NAME"
PAYLOAD_PATH="$ARCHIVE_PRODUCTS/Payload"
ENTITLEMENTS_PATH="$ARCHIVE_PRODUCTS/TS.entitlements"

# Build using Xcode
xcodebuild clean build archive \
-scheme TrollSpeed \
-project THOR-HUD.xcodeproj \
-sdk iphoneos \
-destination 'generic/platform=iOS' \
-archivePath TrollSpeed \
CODE_SIGNING_ALLOWED=NO | xcpretty

cp supports/TS.entitlements "$ENTITLEMENTS_PATH"

if [ ! -d "$APP_PATH" ]; then
    echo "App bundle not found: $APP_PATH"
    exit 1
fi

codesign --remove-signature "$APP_PATH" || true

rm -rf "$PAYLOAD_PATH"
mkdir -p "$PAYLOAD_PATH"
mv "$ARCHIVE_PRODUCTS/Applications" "$PAYLOAD_PATH/Applications"

if command -v ldid >/dev/null 2>&1; then
    ldid -S"$ENTITLEMENTS_PATH" "$PAYLOAD_PATH/Applications/$APP_NAME"
else
    echo "ldid not found, skipping ad-hoc re-sign step"
fi

( cd "$PAYLOAD_PATH" && zip -qr ../Apibug-HUD.tipa . )
mkdir -p packages
mv "$ARCHIVE_PRODUCTS/Apibug-HUD.tipa" packages/ApibugSmoba.tipa
