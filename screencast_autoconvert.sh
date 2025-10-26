#!/usr/bin/env bash
set -uo pipefail

# Optional per-user env file (also supported by systemd unit)
USER_ENV_FILE="$HOME/.config/screencast-autoconvert.env"
[ -f "$USER_ENV_FILE" ] && . "$USER_ENV_FILE"

# Config (overridable via env)
DIR="${DIR:-$HOME/Videos/Screencasts}"
LOG="${LOG:-$HOME/.local/share/screencast-autoconvert.log}"
# File match regex for watcher and scan
SCREENCODE_EXT_REGEX="${SCREENCODE_EXT_REGEX:-.*\\.webm$}"
# auto|hevc|h264 -> preferred video codec family
SCREENCODE_CODEC="${SCREENCODE_CODEC:-auto}"
# Quality: CRF for CPU encoders, CQ for NVENC encoders (lower = better)
SCREENCODE_QUALITY="${SCREENCODE_QUALITY:-24}"
# Presets: CPU x265 default medium, x264 fast. NVENC preset: fast (safe across ffmpeg versions)
SCREENCODE_PRESET="${SCREENCODE_PRESET:-fast}"
# GPU acceleration toggles
SCREENCODE_HWACCEL="${SCREENCODE_HWACCEL:-on}"   # auto|on|off
SCREENCODE_GPU_SCALE="${SCREENCODE_GPU_SCALE:-on}" # auto|on|off (NVENC only best-effort)
# Concurrency (number of parallel conversions)
SCREENCODE_MAX_JOBS="${SCREENCODE_MAX_JOBS:-2}"
SCREENCODE_DELETE_SOURCE="${SCREENCODE_DELETE_SOURCE:-1}"
SCREENCODE_SCAN_ON_START="${SCREENCODE_SCAN_ON_START:-1}"
SCREENCODE_LOG_MAX_SIZE="${SCREENCODE_LOG_MAX_SIZE:-1048576}"
# Optional target size factor (0.0-1.0). When set (e.g., 0.5), encoder switches to bitrate mode targeting ~factor of source size.
SCREENCODE_SIZE_FACTOR="${SCREENCODE_SIZE_FACTOR:-}"

mkdir -p "$(dirname "$LOG")"

rotate_log_if_needed() {
  # Simple log rotation to prevent unbounded growth
  local max_size="$SCREENCODE_LOG_MAX_SIZE"
  if [ -f "$LOG" ]; then
    local sz
    sz=$(wc -c < "$LOG" 2>/dev/null || echo 0)
    if [ "$sz" -ge "$max_size" ]; then
      mv -f "$LOG" "${LOG}.1" 2>/dev/null || true
    fi
  fi
}

rotate_log_if_needed

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[$(date '+%F %T')] ERROR: required command not found: $1" >> "$LOG"
    exit 1
  }
}

require_cmd inotifywait
require_cmd ffmpeg
command -v ffprobe >/dev/null 2>&1 || echo "[$(date '+%F %T')] WARN: ffprobe not found; duration checks disabled" >> "$LOG"

has_encoder() {
  # $1 = encoder name regex
  ffmpeg -hide_banner -encoders 2>/dev/null | grep -Eiq -- "$1"
}

has_filter() {
  # $1 = filter name regex
  ffmpeg -hide_banner -filters 2>/dev/null | grep -Eiq -- "$1"
}

detect_video_stack() {
  # Decide on encoder and options. Prints 4 newline-separated fields:
  # vcodec\nvopts\nvfilter\naopts
  local want="$SCREENCODE_CODEC"
  local q="$SCREENCODE_QUALITY"
  local preset="$SCREENCODE_PRESET"

  local vcodec vopts vf aopts hwaccel_args=""

  # Base filters: ensure even dimensions and yuv420p for mp4 compatibility
  local base_vf="scale=ceil(iw/2)*2:ceil(ih/2)*2,format=yuv420p"
  local a_bitrate="${SCREENCODE_AUDIO_BITRATE:-128k}"
  aopts="-c:a aac -b:a ${a_bitrate}"

  # Prefer GPU if available and requested (auto)
  if [[ "$want" == "auto" || "$want" == "hevc" || "$want" == "h264" ]]; then
    # NVIDIA NVENC
    if has_encoder '(hevc|h264)_nvenc'; then
      # Optional GPU decode + scaling for NVENC
      if [[ "$SCREENCODE_HWACCEL" != "off" ]]; then
        if has_filter 'scale_npp|scale_cuda'; then
          # Use CUDA hwaccel and GPU scale if allowed
          if [[ "$SCREENCODE_GPU_SCALE" != "off" ]]; then
            hwaccel_args="-hwaccel cuda -hwaccel_output_format cuda"
            # Prefer scale_npp; fallback to scale_cuda
            if has_filter 'scale_npp'; then
              vf="scale_npp=ceil(iw/2)*2:ceil(ih/2)*2:format=yuv420p"
            else
              vf="scale_cuda=ceil(iw/2)*2:ceil(ih/2)*2,format=yuv420p"
            fi
          fi
        fi
      fi
      if [[ "$want" == "h264" ]]; then
        vcodec="h264_nvenc"; vopts="-preset $preset -tune hq -rc vbr -cq $q -b:v 0 -pix_fmt yuv420p"; vf="${vf:-$base_vf}"
        printf '%s\t%s\t%s\t%s\t%s\n' "$vcodec" "$vopts" "$vf" "$aopts" "$hwaccel_args"; return
      fi
      # default to HEVC if available
      if has_encoder 'hevc_nvenc'; then
        vcodec="hevc_nvenc"; vopts="-preset $preset -tune hq -rc vbr -cq $q -b:v 0 -pix_fmt yuv420p"; vf="${vf:-$base_vf}"
        printf '%s\t%s\t%s\t%s\t%s\n' "$vcodec" "$vopts" "$vf" "$aopts" "$hwaccel_args"; return
      fi
      # fallback to H.264 NVENC
      if has_encoder 'h264_nvenc'; then
        vcodec="h264_nvenc"; vopts="-preset $preset -tune hq -rc vbr -cq $q -b:v 0 -pix_fmt yuv420p"; vf="${vf:-$base_vf}"
        printf '%s\t%s\t%s\t%s\t%s\n' "$vcodec" "$vopts" "$vf" "$aopts" "$hwaccel_args"; return
      fi
    fi

    # Intel Quick Sync (QSV)
    if has_encoder 'hevc_qsv|h264_qsv'; then
      if [[ "$want" == "h264" ]] && has_encoder 'h264_qsv'; then
        # Best-effort QSV decode only if explicitly enabled; CPU scaling retained
        if [[ "$SCREENCODE_HWACCEL" == "on" ]]; then hwaccel_args="-hwaccel qsv"; fi
        vcodec="h264_qsv"; vopts="-preset $preset -global_quality $q"; vf="$base_vf"
        printf '%s\t%s\t%s\t%s\t%s\n' "$vcodec" "$vopts" "$vf" "$aopts" "$hwaccel_args"; return
      fi
      if has_encoder 'hevc_qsv'; then
        if [[ "$SCREENCODE_HWACCEL" == "on" ]]; then hwaccel_args="-hwaccel qsv"; fi
        vcodec="hevc_qsv"; vopts="-preset $preset -global_quality $q"; vf="$base_vf"
        printf '%s\t%s\t%s\t%s\t%s\n' "$vcodec" "$vopts" "$vf" "$aopts" "$hwaccel_args"; return
      fi
      if has_encoder 'h264_qsv'; then
        if [[ "$SCREENCODE_HWACCEL" == "on" ]]; then hwaccel_args="-hwaccel qsv"; fi
        vcodec="h264_qsv"; vopts="-preset $preset -global_quality $q"; vf="$base_vf"
        printf '%s\t%s\t%s\t%s\t%s\n' "$vcodec" "$vopts" "$vf" "$aopts" "$hwaccel_args"; return
      fi
    fi

    # AMD AMF
    if has_encoder 'hevc_amf|h264_amf'; then
      if [[ "$want" == "h264" ]] && has_encoder 'h264_amf'; then
        vcodec="h264_amf"; vopts="-quality $preset -rc vbr -q $q"; vf="$base_vf"
        printf '%s\n%s\n%s\n%s\n%s\n' "$vcodec" "$vopts" "$vf" "$aopts" "$hwaccel_args"; return
      fi
      if has_encoder 'hevc_amf'; then
        vcodec="hevc_amf"; vopts="-quality $preset -rc vbr -q $q"; vf="$base_vf"
        printf '%s\n%s\n%s\n%s\n%s\n' "$vcodec" "$vopts" "$vf" "$aopts" "$hwaccel_args"; return
      fi
      if has_encoder 'h264_amf'; then
        vcodec="h264_amf"; vopts="-quality $preset -rc vbr -q $q"; vf="$base_vf"
        printf '%s\n%s\n%s\n%s\n%s\n' "$vcodec" "$vopts" "$vf" "$aopts" "$hwaccel_args"; return
      fi
    fi
  fi

  # CPU fallback
  if [[ "$want" == "h264" ]]; then
    vcodec="libx264"; vopts="-preset medium -crf ${q:-23}"; vf="$base_vf"
  else
    vcodec="libx265"; vopts="-preset slow -crf ${q:-24}"; vf="$base_vf"
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$vcodec" "$vopts" "$vf" "$aopts" "$hwaccel_args"
}

dur_seconds() {
  # prints integer seconds (rounded) or 0 on failure
  local f="$1"
  if ! command -v ffprobe >/dev/null 2>&1; then echo 0; return; fi
  ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$f" 2>/dev/null | awk '{printf("%d", ($1+0.5))}' 2>/dev/null || echo 0
}

is_within_tolerance() {
  # args: src_sec out_sec
  # True if out is within 5% or <=2s diff
  local s="$1"; local o="$2"
  if [ "$s" -eq 0 ] || [ "$o" -eq 0 ]; then return 0; fi
  local diff=$(( s>o ? s-o : o-s ))
  local fivep=$(( s/20 ))
  if [ "$diff" -le 2 ] || [ "$diff" -le "$fivep" ]; then return 0; else return 1; fi
}

echo "[$(date '+%F %T')] watcher started for: $DIR (regex=$SCREENCODE_EXT_REGEX)" >> "$LOG"

# Log which encoder we’ll use (best-effort dry-run)
plan_line=$(detect_video_stack)
echo "[$(date '+%F %T')] encoder raw plan: ${plan_line}" >> "$LOG"
IFS=$'\t' read -r _vcodec _vopts _vf _aopts _hwaccel_args <<< "$plan_line"
echo "[$(date '+%F %T')] encoder plan: vcodec=${_vcodec} opts='${_vopts}' vf='${_vf}' a='${_aopts}' hw='${_hwaccel_args}'" >> "$LOG"

wait_for_slot() {
  local max="$SCREENCODE_MAX_JOBS"
  [[ "$max" -lt 1 ]] && max=1
  while :; do
    local running
    running=$(jobs -rp | wc -l)
    if [[ "$running" -lt "$max" ]]; then
      break
    fi
    sleep 0.2
  done
}

convert_one() {
  local f="$1"
  local out="${f%.*}.mp4"
  local tmp="${out}.part"

  # Resolve encoder stack for each file (allows changing env at runtime)
  plan_line=$(detect_video_stack)
  IFS=$'\t' read -r vcodec vopts vf aopts hwaccel_args <<< "$plan_line"
  echo "[$(date '+%F %T')] converting: $f -> $out (v=${vcodec})" >> "$LOG"

  # If size factor is set, compute target bitrate and switch to VBR bitrate mode
  if [[ -n "${SCREENCODE_SIZE_FACTOR}" ]]; then
    # compute original bitrate via ffprobe or from file size and duration
    local dur orig_bps target_bps buf_bps factor
    factor="${SCREENCODE_SIZE_FACTOR}"
    dur=$(dur_seconds "$f")
    orig_bps=$(ffprobe -v error -show_entries format=bit_rate -of default=nw=1:nk=1 "$f" 2>/dev/null | head -n1)
    [[ -z "$orig_bps" || "$orig_bps" = "N/A" || "$orig_bps" = 0 ]] && orig_bps=$(awk -v sz=$(stat -c%s "$f" 2>/dev/null || echo 0) -v d=${dur:-0} 'BEGIN{ if(d>0){print int((sz*8)/d)} else {print 0} }')
    target_bps=$(awk -v obps=${orig_bps:-0} -v f=$factor 'BEGIN{print int(obps*f)}')
    buf_bps=$(awk -v t=${target_bps:-0} 'BEGIN{print int(t*2)}')
    if [[ ${target_bps:-0} -gt 0 ]]; then
      case "$vcodec" in
        *nvenc)
          vopts="-preset $SCREENCODE_PRESET -tune hq -rc vbr_hq -b:v ${target_bps} -maxrate ${target_bps} -bufsize ${buf_bps} -pix_fmt yuv420p" ;;
        *qsv)
          vopts="-preset $SCREENCODE_PRESET -b:v ${target_bps} -maxrate ${target_bps} -bufsize ${buf_bps}" ;;
        *amf)
          vopts="-quality $SCREENCODE_PRESET -rc vbr -b:v ${target_bps} -maxrate ${target_bps} -bufsize ${buf_bps}" ;;
        libx264)
          vopts="-preset medium -b:v ${target_bps} -maxrate ${target_bps} -bufsize ${buf_bps}" ;;
        libx265)
          vopts="-preset slow -b:v ${target_bps} -maxrate ${target_bps} -bufsize ${buf_bps}" ;;
      esac
      echo "[$(date '+%F %T')] size-factor ${factor}; orig_bps=${orig_bps}; target_bps=${target_bps}" >> "$LOG"
    else
      echo "[$(date '+%F %T')] WARN: could not compute target_bps; proceeding with quality-based settings" >> "$LOG"
    fi
  fi

  # Small delay in case the file is still being finalized
  sleep 1

  nice -n 10 ionice -c2 -n7 \
    ffmpeg -y -hide_banner -loglevel error \
      ${hwaccel_args} \
      -i "$f" \
      -map 0:v:0 -map 0:a? -map -0:d -map -0:s \
      -vf "$vf" \
      -c:v $vcodec $vopts \
      $aopts \
      -movflags +faststart \
      -f mp4 \
      "$tmp"

  if [ $? -eq 0 ] && [ -s "$tmp" ] ; then
    mv "$tmp" "$out"
    if [ -s "$out" ]; then
      echo "[$(date '+%F %T')] done: $out" >> "$LOG"
    else
      echo "[$(date '+%F %T')] ERROR: MP4 empty after move, keeping source $f" >> "$LOG"
    fi
  else
    echo "[$(date '+%F %T')] ERROR converting (primary path), retrying with CPU scaling: $f" >> "$LOG"
    rm -f "$tmp" 2>/dev/null || true

    # Retry once with GPU scaling disabled (but keep GPU encode/decode if selected)
    plan_line=$(SCREENCODE_GPU_SCALE=off detect_video_stack)
    IFS=$'\t' read -r vcodec vopts vf aopts hwaccel_args <<< "$plan_line"
    nice -n 10 ionice -c2 -n7 \
      ffmpeg -y -hide_banner -loglevel error \
        ${hwaccel_args} \
        -i "$f" \
        -map 0:v:0 -map 0:a? -map -0:d -map -0:s \
        -vf "$vf" \
        -c:v $vcodec $vopts \
        $aopts \
        -movflags +faststart \
        -f mp4 \
        "$tmp"

    if [ $? -eq 0 ] && [ -s "$tmp" ] ; then
      mv "$tmp" "$out"
      if [ -s "$out" ]; then
        echo "[$(date '+%F %T')] done (after retry): $out" >> "$LOG"
      else
        echo "[$(date '+%F %T')] ERROR: MP4 empty after retry move, keeping source $f" >> "$LOG"
      fi
    else
      echo "[$(date '+%F %T')] ERROR converting (retry failed): $f" >> "$LOG"
      rm -f "$tmp" 2>/dev/null || true
    fi
  fi

  # Validate durations before deleting source (if configured)
  if [ -f "$out" ] && [ "$SCREENCODE_DELETE_SOURCE" = "1" ]; then
    local src_dur out_dur
    src_dur=$(dur_seconds "$f")
    out_dur=$(dur_seconds "$out")
    if is_within_tolerance "$src_dur" "$out_dur"; then
      rm -f "$f"
      echo "[$(date '+%F %T')] validated durations (src=${src_dur}s out=${out_dur}s), deleted source: $f" >> "$LOG"
    else
      echo "[$(date '+%F %T')] WARNING: duration mismatch (src=${src_dur}s out=${out_dur}s); keeping source: $f" >> "$LOG"
    fi
  fi
}

# Watch for completed writes or moved-in files matching regex
trap 'wait' EXIT

# Optional on-start backlog scan
if [ "$SCREENCODE_SCAN_ON_START" = "1" ]; then
  echo "[$(date '+%F %T')] scanning backlog for regex: $SCREENCODE_EXT_REGEX" >> "$LOG"
  find "$DIR" -maxdepth 1 -type f 2>/dev/null | grep -E "$SCREENCODE_EXT_REGEX" | while read -r bf; do
    out="${bf%.*}.mp4"
    [ -f "$out" ] && continue
    wait_for_slot
    convert_one "$bf" &
  done
fi

inotifywait -m -e close_write -e moved_to --format '%w%f' --include "$SCREENCODE_EXT_REGEX" "$DIR" | while read -r f; do
  [ -f "$f" ] || continue

  out="${f%.*}.mp4"
  tmp="${out}.part"

  # Skip if already converted
  if [ -f "$out" ]; then
    echo "[$(date '+%F %T')] skip (exists): $out" >> "$LOG"
    continue
  fi

  wait_for_slot
  convert_one "$f" &
done
