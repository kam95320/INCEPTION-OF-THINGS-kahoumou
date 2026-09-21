#!/usr/bin/env bash
# =============================================================================
# Installe tout ce dont le bonus a besoin : Docker (pour K3d), kubectl, K3d,
# Helm (pour GitLab) et git.
# A lancer une seule fois, avec sudo.
# =============================================================================
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "[ERROR] Run this script with sudo."
  exit 1
fi

TARGET_USER="${SUDO_USER:-$USER}"

echo "[BONUS] Updating apt..."
apt-get update

echo "[BONUS] Installing base tools and Docker..."
apt-get install -y ca-certificates curl git docker.io

echo "[BONUS] Enabling Docker service..."
systemctl enable --now docker

echo "[BONUS] Adding ${TARGET_USER} to docker group..."
usermod -aG docker "$TARGET_USER"

echo "[BONUS] Installing kubectl..."
if ! command -v kubectl >/dev/null 2>&1; then
  curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
  install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
  rm -f kubectl
fi

echo "[BONUS] Installing k3d..."
if ! command -v k3d >/dev/null 2>&1; then
  curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
fi

echo "[BONUS] Installing helm..."
if ! command -v helm >/dev/null 2>&1; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

echo "[BONUS] Installed versions:"
docker --version
kubectl version --client
k3d version
helm version --short
git --version

echo "[BONUS] Tools installation finished."
echo "[BONUS] Log out and back in (or reboot) so the docker group is applied."
