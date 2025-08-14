# 🎬 Screencast Auto-Convert (WebM → MP4 H.265)

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
> This script watches `~/Videos/Screencasts`, converts `.webm` to `.mp4` (H.265/AAC), and deletes the original for seamless use.

### 🖼 How it works
```
┌───────────────┐   new .webm   ┌────────────────┐   convert   ┌────────────────┐
│GNOME Recorder │ ───────────▶  │Auto-Convert    │ ─────────▶  │ MP4 (H.265/AAC)│
└───────────────┘               └────────────────┘             └────────────────┘
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
In `screencast_autoconvert.sh`:
- **Quality/Size**: Adjust `-crf` (lower = better quality; default **28**)
- **Speed vs Size**: Adjust `-preset` (`ultrafast` → `placebo`; default **slow**)
- **Audio bitrate**: Adjust `-b:a` (default **128k**)

> [!CAUTION]  
> For maximum legacy compatibility, switch to H.264:  
> ```bash
> -c:v libx264 -preset veryfast -crf 20
> ```

## 🧠 How it works (under the hood)
- Uses `inotifywait` for real-time `.webm` detection
- Converts to `.mp4` (H.265/AAC) via `ffmpeg`
- Ensures even dimensions with scale filter
- Uses `-movflags +faststart` for faster playback
- Deletes `.webm` only if `.mp4` is valid

> [!WARNING]  
> Runs as a systemd user service, auto-starting on login. Ensure proper configuration to avoid issues.

## 📜 License
MIT — see [LICENSE](LICENSE)

### 💡 Heads up
This runs as a **systemd user service**, so it starts automatically on login and runs in the background without manual commands.