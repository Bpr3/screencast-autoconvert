#!/usr/bin/env bash
set -uo pipefail

DIR="$HOME/Videos/Screencasts"
LOG="$HOME/.local/share/screencast-autoconvert.log"

mkdir -p "$(dirname "$LOG")"

echo "[$(date '+%F %T')] watcher started for: $DIR" >> "$LOG"

# Watch for completed writes or moved-in files with .webm extension
inotifywait -m -e close_write -e moved_to --format '%w%f' --include '.*\.webm$' "$DIR" | while read -r f; do
  [ -f "$f" ] || continue

  out="${f%.webm}.mp4"
  tmp="${out}.part"

  # Skip if already converted
  if [ -f "$out" ]; then
    echo "[$(date '+%F %T')] skip (exists): $out" >> "$LOG"
    continue
  fi

  echo "[$(date '+%F %T')] converting (H.265): $f -> $out" >> "$LOG"

  # Small delay in case the file is still being finalized
  sleep 1

  # Re-encode to HEVC/AAC, ensure even dimensions; mp4 muxer + faststart
  nice -n 10 ionice -c2 -n7 ffmpeg -y -hide_banner -loglevel error     -i "$f"     -map 0     -vf "scale=ceil(iw/2)*2:ceil(ih/2)*2,format=yuv420p"     -c:v libx265 -preset slow -crf 28     -c:a aac -b:a 128k     -movflags +faststart     -f mp4     "$tmp"

  if [ $? -eq 0 ] && [ -s "$tmp" ] ; then
    mv "$tmp" "$out"
    if [ -s "$out" ]; then
      rm -f "$f"
      echo "[$(date '+%F %T')] done: $out (deleted source $f)" >> "$LOG"
    else
      echo "[$(date '+%F %T')] ERROR: MP4 empty after move, keeping source $f" >> "$LOG"
    fi
  else
    echo "[$(date '+%F %T')] ERROR converting: $f" >> "$LOG"
    rm -f "$tmp" 2>/dev/null || True
  fi
done
