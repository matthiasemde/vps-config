#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
REPO_DIR="$SCRIPT_DIR"
ENV_FILE="$REPO_DIR/services/frp/.env"

# 1) Install Docker if not present
if ! command -v docker >/dev/null 2>&1; then
  echo "Docker not found. Installing..."
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl wget
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

# 3) Install Node Exporter
echo "Installing Node Exporter..."

NODE_EXPORTER_USER="node_exporter"
NODE_EXPORTER_BIN="/usr/local/bin/node_exporter"
NODE_EXPORTER_VERSION="1.9.1"

if ! id "$NODE_EXPORTER_USER" >/dev/null 2>&1; then
  sudo useradd \
    --no-create-home \
    --shell /usr/sbin/nologin \
    "$NODE_EXPORTER_USER"
fi

if [ ! -f "$NODE_EXPORTER_BIN" ]; then
  cd /tmp

  wget -q \
    "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"

  tar xzf \
    "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"

  sudo cp \
    "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter" \
    "$NODE_EXPORTER_BIN"

  sudo chown \
    "$NODE_EXPORTER_USER:$NODE_EXPORTER_USER" \
    "$NODE_EXPORTER_BIN"

  sudo chmod +x "$NODE_EXPORTER_BIN"

  rm -rf \
    "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64"*
fi

# Node Exporter service
sudo tee /etc/systemd/system/node_exporter.service >/dev/null <<UNIT
[Unit]
Description=Prometheus Node Exporter
After=network-online.target

[Service]
User=${NODE_EXPORTER_USER}
Group=${NODE_EXPORTER_USER}
ExecStart=${NODE_EXPORTER_BIN}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

# 4) Node Exporter automatic updater
echo "Installing Node Exporter updater..."

sudo tee /usr/local/bin/update-node-exporter >/dev/null <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

BIN="/usr/local/bin/node_exporter"
USER="node_exporter"

CURRENT=$(
  "$BIN" --version 2>&1 |
  awk '{print $3}'
)

LATEST=$(
  curl -fsSL https://api.github.com/repos/prometheus/node_exporter/releases/latest |
  grep tag_name |
  sed -E 's/.*v([^"]+).*/\1/'
)

if [ "$CURRENT" = "$LATEST" ]; then
  echo "Node Exporter already current ($CURRENT)"
  exit 0
fi

echo "Updating Node Exporter $CURRENT -> $LATEST"

cd /tmp

wget -q \
"https://github.com/prometheus/node_exporter/releases/download/v${LATEST}/node_exporter-${LATEST}.linux-amd64.tar.gz"

tar xzf \
"node_exporter-${LATEST}.linux-amd64.tar.gz"

cp \
"node_exporter-${LATEST}.linux-amd64/node_exporter" \
"${BIN}.new"

chown "${USER}:${USER}" "${BIN}.new"
chmod +x "${BIN}.new"

mv "${BIN}.new" "$BIN"

systemctl restart node_exporter

rm -rf \
"node_exporter-${LATEST}.linux-amd64"*

echo "Node Exporter updated"
SCRIPT

sudo chmod +x /usr/local/bin/update-node-exporter


sudo tee /etc/systemd/system/node-exporter-update.service >/dev/null <<UNIT
[Unit]
Description=Update Node Exporter

[Service]
Type=oneshot
ExecStart=/usr/local/bin/update-node-exporter
UNIT


sudo tee /etc/systemd/system/node-exporter-update.timer >/dev/null <<UNIT
[Unit]
Description=Weekly Node Exporter update check

[Timer]
OnCalendar=Sun *-*-* 04:00:00
Persistent=true

[Install]
WantedBy=timers.target
UNIT

# 5) VPS config update timer
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


# 6) Enable everything
sudo systemctl daemon-reload

sudo systemctl enable --now node_exporter
sudo systemctl enable --now node-exporter-update.timer
sudo systemctl enable --now vps-config-update.timer

# 7) Start Docker services
cd "$REPO_DIR"
docker compose up -d

echo
echo "Done."
echo
echo "Active services:"
echo "  Node Exporter: $(systemctl is-active node_exporter)"
echo "  Docker:        $(systemctl is-active docker)"
echo
echo "Timers:"
systemctl list-timers | grep -E "node|vps-config" || true
echo
echo "Metrics endpoint:"
echo "  http://<server-ip>:9100/metrics"
