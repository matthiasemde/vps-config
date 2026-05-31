#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
REPO_DIR="$SCRIPT_DIR"
ENV_FILE="$REPO_DIR/services/frp/.env"

# 1) Install Docker if not present
if ! command -v docker >/dev/null 2>&1; then
  echo "Docker not found. Installing..."
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

# 2) Verify .env exists
if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: .env not found at ${ENV_FILE}."
  echo "Create it with FRP_TOKEN=... and FRP_DASHBOARD_PWD=... and re-run."
  exit 1
fi

# 3) Install systemd service and timer for nightly auto-update
SERVICE_PATH="/etc/systemd/system/vps-config-update.service"
TIMER_PATH="/etc/systemd/system/vps-config-update.timer"

echo "Installing systemd service and timer..."
sudo tee "$SERVICE_PATH" >/dev/null <<UNIT
[Unit]
Description=Pull latest vps-config and restart docker compose
After=network-online.target docker.service
Requires=docker.service

[Service]
Type=oneshot
WorkingDirectory=${REPO_DIR}
ExecStart=/bin/bash -c 'git pull origin main && docker compose up -d --pull always --remove-orphans'
UNIT

sudo tee "$TIMER_PATH" >/dev/null <<UNIT
[Unit]
Description=Nightly vps-config update at 05:30

[Timer]
OnCalendar=*-*-* 05:30:00
Persistent=true

[Install]
WantedBy=timers.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable --now vps-config-update.timer

# 4) Start the services
cd "$REPO_DIR"
docker compose up -d

echo
echo "Done. Check logs with:"
echo "  cd ${REPO_DIR} && docker compose logs -f"
echo
echo "Nightly updates enabled via vps-config-update.timer (05:30 daily)."
