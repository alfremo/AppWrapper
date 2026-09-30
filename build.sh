#!/bin/zsh
# Builds AppWrapper.app into ./build and optionally installs to ~/Applications (./build.sh install)
set -e
cd "$(dirname "$0")"
# Falls back to Command Line Tools if the Xcode license hasn't been accepted.
swiftc --version >/dev/null 2>&1 || export DEVELOPER_DIR=/Library/Developer/CommandLineTools
mkdir -p build
# CLT lacks the SwiftUI macro plugin (@State); borrow Xcode's if present.
PLUGIN=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib
EXTRA=()
[[ -f $PLUGIN ]] && EXTRA=(-load-plugin-library $PLUGIN)
swiftc -O $EXTRA -parse-as-library -target arm64-apple-macosx14.0 Sources/*.swift -o build/AppWrapper-bin
APP=build/AppWrapper.app
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS"
mv build/AppWrapper-bin "$APP/Contents/MacOS/AppWrapper"
mkdir -p "$APP/Contents/Resources"
# AppIcon.icon (Icon Composer) is the source; AppIcon.icns is its flattened fallback for machines without Xcode.
ACTOOL=/Applications/Xcode.app/Contents/Developer/usr/bin/actool
if [[ -x $ACTOOL ]]; then
  $ACTOOL AppIcon.icon --compile "$APP/Contents/Resources" --app-icon AppIcon --platform macosx \
    --minimum-deployment-target 14.0 --output-partial-info-plist build/partial.plist >/dev/null
else
  cp AppIcon.icns "$APP/Contents/Resources/"
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.appwrapper</string>
  <key>CFBundleName</key><string>AppWrapper</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>AppWrapper</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
if [[ "$1" == install ]]; then
  rm -rf ~/Applications/AppWrapper.app && cp -R "$APP" ~/Applications/
  echo "Installed ~/Applications/AppWrapper.app"
else
  echo "Built $APP"
fi
