# Install prefix (defaults to current user's HOME)
PREFIX ?= $(HOME)
BIN_DIR := $(PREFIX)/bin
SYSTEMD_DIR := $(PREFIX)/.config/systemd/user

# Set NO_SUDO=1 to skip sudo (useful in containers or if you preinstalled deps)
NO_SUDO ?= 0
SUDO_CMD := $(if $(filter 1,$(NO_SUDO)),,sudo)

install:
	$(SUDO_CMD) apt update
	$(SUDO_CMD) apt install -y ffmpeg inotify-tools
	mkdir -p "$(BIN_DIR)"
	cp screencast_autoconvert.sh "$(BIN_DIR)/"
	chmod +x "$(BIN_DIR)/screencast_autoconvert.sh"
	mkdir -p "$(SYSTEMD_DIR)"
	cp screencast-autoconvert.service "$(SYSTEMD_DIR)/"
	systemctl --user daemon-reload
	systemctl --user enable --now screencast-autoconvert.service

uninstall:
	- systemctl --user disable --now screencast-autoconvert.service
	- rm -f "$(SYSTEMD_DIR)/screencast-autoconvert.service"
	systemctl --user daemon-reload
	- rm -f "$(BIN_DIR)/screencast_autoconvert.sh"

.PHONY: install uninstall
