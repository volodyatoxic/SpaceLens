#!/bin/bash
# Собирает SpaceLens.app в папке build/
set -e
cd "$(dirname "$0")"
swift build -c release
APP="build/Space Lens.app"
rm -rf "$APP" build/SpaceLens.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/SpaceLens "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# Стабильная подпись сертификатом разработчика: тогда разрешения macOS (доступ к папкам, «Полный доступ к диску»)
# не сбрасываются после каждой пересборки. Без сертификата — временная подпись (разрешения придётся давать заново).
ID=$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | head -1 | awk '{print $2}')
if [ -n "$ID" ]; then codesign --force --deep --sign "$ID" "$APP"; echo "Подписано сертификатом разработчика"; else codesign --force --deep --sign - "$APP"; fi
echo "Готово: $APP"

# ./build.sh install — ещё и ставит приложение в /Applications (старое закрывается и заменяется) и запускает.
if [ "$1" = "install" ]; then
  DEST=/Applications
  [ -w "$DEST" ] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }
  pkill -x SpaceLens 2>/dev/null && sleep 0.7 || true
  rm -rf "$DEST/SpaceLens.app" "$DEST/Space Lens.app"
  ditto "$APP" "$DEST/Space Lens.app"
  echo "Установлено: $DEST/Space Lens.app"
  open "$DEST/Space Lens.app"
fi
