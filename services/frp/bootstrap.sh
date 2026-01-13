#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./bootstrap-frp.sh [FLAKE_DIR]
# Example:
#   ./bootstrap-frp.sh /home/ubuntu/frp-flake
FLAKE_DIR="${1:-.}"
FLAKE="$FLAKE_DIR/flake.nix"

# defaults (change by editing the flake or setting env vars before running)
FRP_VERSION="${FRP_VERSION:-0.63.0}"
ARCH="${ARCH:-amd64}"   # "amd64" or "arm64"
SUFFIX="linux_${ARCH}"
TARBALL_URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_${SUFFIX}.tar.gz"

if [ ! -f "$FLAKE" ]; then
  echo "ERROR: flake.nix not found in ${FLAKE_DIR}. Put the provided flake.nix there and re-run."
  exit 1
fi

# 1) Ensure required tools
if ! command -v nix >/dev/null 2>&1; then
  echo "Nix not found — installing multi-user (daemon) Nix..."
  # official installer (multi-user)
  sh <(curl -L https://nixos.org/nix/install) --daemon
  echo "Installed Nix; enabling flakes in /etc/nix/nix.conf..."
  sudo mkdir -p /etc/nix
  # safe-append the experimental-features line if not present
  if ! grep -q "experimental-features" /etc/nix/nix.conf 2>/dev/null; then
    echo "experimental-features = nix-command flakes" | sudo tee -a /etc/nix/nix.conf
  else
    sudo sed -i 's/^experimental-features *=.*/experimental-features = nix-command flakes/' /etc/nix/nix.conf || true
  fi
  # restart daemon if available
  sudo systemctl restart nix-daemon || true
  echo "You will need to open a new interactive shell to use nix. Do so and re-run this script!"
  exit 1
else
  echo "Nix already installed."
fi

# 2) Build the image with nix
echo "Building docker image via nix..."
nix build "${FLAKE_DIR}#packages.x86_64-linux.frpsImage"

# The build creates "result" which is a tar that docker can load
IMAGE_TAR="$(readlink -f result)"
if [ ! -f "$IMAGE_TAR" ]; then
  echo "Build failed: result not found."
  exit 1
fi
echo "Built tarball at: $IMAGE_TAR"

# 3) Load the image into docker
if ! command -v docker >/dev/null 2>&1; then
    echo "Docker not found. Installing..."
    # Add Docker's official GPG key:
    sudo apt-get update
    sudo apt-get install ca-certificates curl
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc

    # Add the repository to Apt sources:
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update
    apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
echo "Loading image into docker..."
LOAD_OUT=$(docker load -i "$IMAGE_TAR" 2>&1)

echo "Load output:"
echo "$LOAD_OUT"

# Attempt to extract the image tag/name from the loader output. Fallback to 'frps:${FRP_VERSION}'.
IMG_REF=$(echo "$LOAD_OUT" | sed -n 's/Loaded image: //p' | head -n1 || true)
if [ -z "$IMG_REF" ]; then
  IMG_REF="frps:${FRP_VERSION}"
fi
echo "Image reference to be used: $IMG_REF"


# 2) Create a systemd service that runs the container (bind-mounts /etc/frp)
ENV_FILE="$(dirname "$(readlink -f "$0")")/.env"
SERVICE_PATH="/etc/systemd/system/docker-frps.service"
echo "Writing systemd service to ${SERVICE_PATH}..."
sudo tee "$SERVICE_PATH" >/dev/null <<EOF
[Unit]
Description=frps container (FRP server)
After=docker.service
Requires=docker.service

[Service]
Restart=always
# Pre remove old container if exists
ExecStartPre=docker rm -f frps
ExecStart=docker run --name frps --restart unless-stopped -p 80:80 -p 443:443 -p 25565:25565 -p 7777:7777 -p 7777:7777/udp -p 8888:8888 -p 7000:7000 -p 7500:7500 -p 3478:3478 -p 3478:3478/udp -p 49152-65535:49152-65535/udp  --env-file /root/app/services/frp/.env frps:0.64.0
ExecStop=docker stop frps
TimeoutStartSec=30

[Install]
WantedBy=multi-user.target
EOF

echo "Reloading systemd and enabling service..."
sudo systemctl daemon-reload
sudo systemctl enable --now docker-frps.service

echo
echo "Done. frps should be running and bound to ports 7000 (control) and 7500 (dashboard)."
echo "Check service logs with: sudo journalctl -u docker-frps.service -f"
echo
echo "If you want to override the config, edit /etc/frp/frps.ini and restart the service:"
echo "  sudo systemctl restart docker-frps.service"
