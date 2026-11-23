#!/bin/bash
# Обновляет скриншоты для README (docs/*.png) из установленного приложения.
# Снимает системные папки (/Applications, /Library), чтобы на скриншотах не было личных данных.
set -e
cd "$(dirname "$0")"
APP="/Applications/Space Lens.app"
[ -d "$APP" ] || { echo "Сначала ./build.sh install"; exit 1; }
mkdir -p docs .build
[ -x .build/wid ] || swiftc -O tools/wid.swift -o .build/wid
BID=app.spacelens.mac
OLD=$(defaults read $BID nested 2>/dev/null || echo 1)

shot() {  # путь, вложенность, файл
  pkill -x SpaceLens 2>/dev/null || true; sleep 1
  defaults write $BID nested -bool "$2"
  open -n "$APP" --args --scan "$1" --force
  sleep 25
  screencapture -x -o -l"$(.build/wid)" "docs/$3"
  sips -Z 1800 "docs/$3" >/dev/null
}
shot /Applications true screenshot-nested.png
shot /Library false screenshot-flat.png

pkill -x SpaceLens 2>/dev/null || true; sleep 1
defaults write $BID nested -bool "$([ "$OLD" = 0 ] && echo false || echo true)"
open "$APP"
echo "Готово: docs/screenshot-nested.png, docs/screenshot-flat.png"
