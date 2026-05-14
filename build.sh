#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="GitHubNotifications"
APP_BUNDLE="${APP_NAME}.app"
BUILD_DIR="build"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/$APP_BUNDLE/Contents/MacOS"
mkdir -p "$BUILD_DIR/$APP_BUNDLE/Contents/Resources"

cp Info.plist "$BUILD_DIR/$APP_BUNDLE/Contents/Info.plist"

# Generate the app icon from the SF Symbol used in the menu bar.
swift make_icon.swift "$BUILD_DIR/$APP_BUNDLE/Contents/Resources/AppIcon.icns"

swiftc -O \
    -framework AppKit \
    -framework UserNotifications \
    -o "$BUILD_DIR/$APP_BUNDLE/Contents/MacOS/$APP_NAME" \
    main.swift

# Ad-hoc sign so UserNotifications and the menu-bar item work.
codesign --force --deep --sign - "$BUILD_DIR/$APP_BUNDLE"

echo
echo "Built: $BUILD_DIR/$APP_BUNDLE"
echo "Run:   open $BUILD_DIR/$APP_BUNDLE"
echo "Install (optional): cp -R $BUILD_DIR/$APP_BUNDLE /Applications/"
