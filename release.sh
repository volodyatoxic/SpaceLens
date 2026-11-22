#!/bin/bash
# Собирает приложение и упаковывает его в dist/SpaceLens-<версия>.dmg
set -e
cd "$(dirname "$0")"
VER=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
./build.sh
rm -rf dist/stage && mkdir -p dist/stage
ditto "build/Space Lens.app" "dist/stage/Space Lens.app"
ln -s /Applications dist/stage/Applications
DMG="dist/SpaceLens-$VER.dmg"
rm -f "$DMG"
hdiutil create -volname "Space Lens" -srcfolder dist/stage -ov -format UDZO "$DMG" >/dev/null
rm -rf dist/stage
echo "Готово: $DMG"
