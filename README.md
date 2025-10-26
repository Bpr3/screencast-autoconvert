# 🎬 Screencast Auto-Convert (WebM → MP4; GPU-aware)

> [!NOTE]  
> Fixes Ubuntu/GNOME's WebM-only screencast limitation by auto-converting to MP4 (H.265) for broader compatibility.

[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-Linux-orange)
![Dependencies](https://img.shields.io/badge/deps-ffmpeg%20%7C%20inotify--tools-blue)

## ✨ Why?

Ubuntu/GNOME recorder (`Ctrl` + `Alt` + `Shift` + `R`) saves only in `.webm` (VP8/VP9).  
WebM issues:
- ❌ Android / iOS apps don't like it
- ❌ Limited compatibility (Windows, old TVs, social platforms)
- ❌ Rejected by some video editors
- ❌ No native MP4 option

> [!TIP]  
> This script watches `~/Videos/Screencasts`, converts `.webm` to `.mp4` (GPU-accelerated when available), and deletes the original for seamless use.

### 🖼 How it works
```
┌───────────────┐   new .webm   ┌────────────────┐   convert   ┌─────────────────────┐
│GNOME Recorder │ ───────────▶  │Auto-Convert    │ ─────────▶  │ MP4 (HEVC/H.264 + AAC)│
└───────────────┘               └────────────────┘             └─────────────────────┘
                                      │
                                      └── 🗑 delete original .webm 
```

## 🚀 Quick Start
```bash
git clone https://github.com/YOURUSER/screencast-autoconvert.git
cd screencast-autoconvert
make install
```

> [!IMPORTANT]  
> `make install` installs dependencies (`ffmpeg`, `inotify-tools`), sets up the script, and enables the systemd user service.

**Uninstall:**
```bash
make uninstall
```

> [!TIP]  
> Skip `sudo` in containers or if dependencies are pre-installed: `make NO_SUDO=1 install`.

## 🛠 Requirements
- `ffmpeg`
- `inotify-tools`  
> [!NOTE]  
> Both installed automatically via `make install` (uses `apt`).

## 📂 Default folder
GNOME saves to:
```text
~/Videos/Screencasts
```
Change in `screencast_autoconvert.sh`:
```bash
DIR="$HOME/Videos/Screencasts"
```

## ⚙️ Tuning
The script auto-detects GPU encoders when available and falls back to CPU. Defaults target a balanced “good quality, low size” profile out of the box.

Environment variables (optional; defaults shown):
- `SCREENCODE_CODEC`: `auto` | `hevc` | `h264` (default: `auto`)
- `SCREENCODE_QUALITY`: quality value (default: `24`)
  - For CPU encoders: used as `-crf`.
  - For NVENC: used as `-cq` (constant quality VBR).
- `SCREENCODE_PRESET`: encoder speed/quality preset (default: `fast` for GPU; CPU presets chosen per codec)
- `SCREENCODE_HWACCEL`: `auto` | `on` | `off` (default: `on`) — enables GPU decode if supported (CUDA for NVENC, QSV for Intel)
- `SCREENCODE_GPU_SCALE`: `auto` | `on` | `off` (default: `on`) — best‑effort GPU scaling for NVENC using `scale_npp` or `scale_cuda` with even-dimension guard; falls back to CPU scaling when unavailable
- `SCREENCODE_MAX_JOBS`: parallel conversions (default: `2`). Increase to `2-4` on strong GPUs.
- `SCREENCODE_EXT_REGEX`: regex for files to convert (default: `.*\.webm$`)
- `SCREENCODE_DELETE_SOURCE`: delete the source on success (default: `1`)
- `SCREENCODE_SCAN_ON_START`: scan the folder at start and convert backlog (default: `1`)
- `SCREENCODE_LOG_MAX_SIZE`: rotate log when it exceeds this size in bytes (default: `1048576` = 1 MiB)
- `SCREENCODE_AUDIO_BITRATE`: AAC audio bitrate (default: `128k`)
- `SCREENCODE_SIZE_FACTOR`: approximate target size fraction of source (e.g., `0.6`)

Examples:
```bash
# Prefer H.264 (broader compatibility) with NVENC if available
SCREENCODE_CODEC=h264 SCREENCODE_QUALITY=21 SCREENCODE_PRESET=fast

# Keep HEVC but nudge quality higher on CPU fallback
SCREENCODE_CODEC=hevc SCREENCODE_QUALITY=26

# Enable GPU decode + scaling and run up to 3 conversions in parallel
SCREENCODE_HWACCEL=on SCREENCODE_GPU_SCALE=on SCREENCODE_MAX_JOBS=3
```

Systemd user override (persist env):
```bash
systemctl --user edit screencast-autoconvert.service
# Then add under [Service]:
# Environment=SCREENCODE_CODEC=h264
# Environment=SCREENCODE_QUALITY=23
systemctl --user daemon-reload
systemctl --user restart screencast-autoconvert.service
```

Alternatively, create a per-user env file (auto-loaded):
```bash
mkdir -p ~/.config
cat > ~/.config/screencast-autoconvert.env << 'EOF'
SCREENCODE_CODEC=h264
SCREENCODE_QUALITY=23
SCREENCODE_MAX_JOBS=2
SCREENCODE_HWACCEL=on
SCREENCODE_GPU_SCALE=on
SCREENCODE_SCAN_ON_START=1
EOF
systemctl --user restart screencast-autoconvert.service
```

## 🧠 How it works (under the hood)
- Uses `inotifywait` for real-time `.webm` detection
- Converts to `.mp4` via `ffmpeg`, preferring GPU encoders when available:
  - NVIDIA: `hevc_nvenc` / `h264_nvenc`
  - Intel: `hevc_qsv` / `h264_qsv` (if present)
  - AMD: `hevc_amf` / `h264_amf` (if present)
  - Fallback CPU: `libx265` (or `libx264` if forced via `SCREENCODE_CODEC=h264`)
- Ensures even dimensions with scale filter
- Uses `-movflags +faststart` for faster playback
- Validates output duration before deleting the `.webm` (if deletion enabled)

> [!WARNING]  
> Runs as a systemd user service, auto-starting on login. Ensure proper configuration to avoid issues.

## 📜 License
MIT — see [LICENSE](LICENSE)

### 💡 Heads up
This runs as a **systemd user service**, so it starts automatically on login and runs in the background without manual commands.
