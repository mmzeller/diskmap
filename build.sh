#!/bin/bash
# Builds DiskMap.app from source, puts it in Applications and opens it.
# Usage:  bash build.sh
set -uo pipefail

APP_NAME="DiskMap"
BUNDLE_ID="io.github.mmzeller.DiskMap"
VERSION="2.1"
BUILD_NUMBER="$(date +%Y%m%d.%H%M)"
MIN_MACOS="13.0"

cd "$(dirname "$0")"
SOURCE_DIR="$(pwd)"

bold() { printf "\n\033[1m%s\033[0m\n" "$1"; }
red()  { printf "\n\033[1;31m%s\033[0m\n" "$1"; }

bold "DiskMap $VERSION (build $BUILD_NUMBER)"
echo "Building from: $SOURCE_DIR"

# 1. Check the tools
if ! xcrun --find swiftc >/dev/null 2>&1; then
  red "Apple's developer tools aren't installed yet."
  echo "Run this, click Install in the window that appears, then run build.sh again:"
  echo "    xcode-select --install"
  exit 1
fi

MACOS_MAJOR=$(sw_vers -productVersion | cut -d. -f1)
if [ "$MACOS_MAJOR" -lt 13 ]; then
  red "DiskMap needs macOS 13 Ventura or newer (this Mac has $(sw_vers -productVersion))."
  exit 1
fi

ARCH=$(uname -m)
BUILD_DIR="build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"

# 2. Compile
bold "Compiling for $ARCH (this takes a minute)…"
rm -rf "$BUILD_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(find Sources -name '*.swift' | sort)

if ! xcrun --sdk macosx swiftc \
  -O -whole-module-optimization \
  -swift-version 5 \
  -parse-as-library \
  -module-name "$APP_NAME" \
  -target "${ARCH}-apple-macos${MIN_MACOS}" \
  "${SOURCES[@]}" \
  -o "$APP_DIR/Contents/MacOS/$APP_NAME"; then
  red "Build failed. Nothing was installed; the DiskMap in Applications is still the old version."
  echo "Copy everything Terminal printed above (from the first line that says 'error') and paste it to Claude."
  exit 1
fi

# 3. Bundle
cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>$MIN_MACOS</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>DiskMap asks Finder to empty the Trash when you click Empty Trash.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP_DIR" >/dev/null 2>&1

# 4. Quit any copy that's running, so the new one actually opens
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  echo "Quitting the running copy of $APP_NAME…"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x "$APP_NAME" >/dev/null 2>&1 || break
    sleep 0.5
  done
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
fi

# 5. Install, then check that the installed copy really is the new build
installed_build() {
  /usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$1/$APP_NAME.app/Contents/Info.plist" 2>/dev/null
}

install_to() {
  rm -rf "$1/$APP_NAME.app" 2>/dev/null
  ditto "$APP_DIR" "$1/$APP_NAME.app" 2>/dev/null && [ "$(installed_build "$1")" = "$BUILD_NUMBER" ]
}

INSTALL_DIR="/Applications"
if ! install_to "$INSTALL_DIR"; then
  red "macOS wouldn't let Terminal replace /Applications/$APP_NAME.app."
  echo "To fix that for next time: System Settings → Privacy & Security → App Management → turn on Terminal."
  INSTALL_DIR="$HOME/Applications"
  mkdir -p "$INSTALL_DIR"
  if ! install_to "$INSTALL_DIR"; then
    red "Couldn't install the app. You can open the new build directly from: $SOURCE_DIR/$APP_DIR"
    open "$APP_DIR"
    exit 1
  fi
  echo "Installed to $INSTALL_DIR instead. Delete the old copy in /Applications so Spotlight and the Dock don't open it."
fi

# Tell Launch Services about the new copy so Spotlight and the Dock pick it up
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$INSTALL_DIR/$APP_NAME.app" >/dev/null 2>&1 || true

bold "Done. Installed DiskMap $VERSION (build $BUILD_NUMBER) at $INSTALL_DIR/$APP_NAME.app"
echo "The version and build also show at the bottom of DiskMap's start screen and in DiskMap → About DiskMap."
echo "If macOS asks for Full Disk Access again, turn it on for DiskMap, then quit and reopen it."
open "$INSTALL_DIR/$APP_NAME.app"
