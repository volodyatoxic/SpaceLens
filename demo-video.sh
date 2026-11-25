#!/bin/bash
# Демо-ролик «сканирование выдуманной папки»: кадры считаются самим приложением (--render-demo), без записи экрана.
# Результат в dist/demo/: space-lens-demo-25fps.mp4 (с motion blur, 16:10) и space-lens-demo-100fps.mp4 (мастер без размытия).
set -e
cd "$(dirname "$0")"
APP="/Applications/Space Lens.app/Contents/MacOS/SpaceLens"
[ -x "$APP" ] || { echo "Сначала ./build.sh install"; exit 1; }
OUT=dist/demo; FR=.build/demo-frames
rm -rf "$FR"; mkdir -p "$OUT"
pkill -x SpaceLens 2>/dev/null || true; sleep 1
"$APP" --render-demo "$FR" --fps 100 --from 0 --to 11.2
# 100 fps → tmix по 4 кадра (угол затвора 360°) → 25 fps
ffmpeg -y -v error -framerate 100 -i "$FR/%05d.png" \
  -vf "tmix=frames=4,framestep=4,scale=1920:1200:flags=lanczos,format=yuv420p" \
  -r 25 -c:v libx264 -crf 14 -movflags +faststart "$OUT/space-lens-demo-25fps.mp4"
ffmpeg -y -v error -framerate 100 -i "$FR/%05d.png" \
  -vf "scale=1920:1200:flags=lanczos,format=yuv420p" \
  -r 100 -c:v libx264 -crf 14 -movflags +faststart "$OUT/space-lens-demo-100fps.mp4"
echo "Готово: $OUT"
