#!/usr/bin/env bash
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "[ERROR] Run this script with sudo."
  exit 1
fi

TARGET_USER="${SUDO_USER:-$USER}"

echo "[P3] Updating apt..."
apt-get update

echo "[P3] Installing base tools and Docker..."
apt-get install -y ca-certificates curl docker.io

echo "[P3] Enabling Docker service..."
systemctl enable --now docker

echo "[P3] Adding ${TARGET_USER} to docker group..."
usermod -aG docker "$TARGET_USER"

echo "[P3] Installing kubectl..."
if ! command -v kubectl >/dev/null 2>&1; then
  curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
  install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
  rm -f kubectl
fi

echo "[P3] Installing k3d..."
if ! command -v k3d >/dev/null 2>&1; then
  curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
fi

echo "[P3] Installed versions:"
docker --version
kubectl version --client
k3d version

echo "[P3] Tools installation finished."
echo "[P3] Reboot the VM so the docker group is applied."
