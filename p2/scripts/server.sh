#!/bin/sh

set -eu

SERVER_IP="192.168.56.110"
CONFS_DIR="/vagrant/confs"

echo "[P2 SERVER] Starting K3s server installation..."

apt_retry_update() {
  i=1
  while [ "$i" -le 3 ]; do
    echo "[APT] apt-get update attempt $i/3"
    if apt-get update; then
      return 0
    fi
    i=$((i + 1))
    sleep 5
  done
  return 1
}

apt_retry_install() {
  i=1
  while [ "$i" -le 3 ]; do
    echo "[APT] apt-get install attempt $i/3: $*"
    if apt-get install -y "$@"; then
      return 0
    fi
    i=$((i + 1))
    sleep 5
  done
  return 1
}

apt_retry_update
apt_retry_install curl ca-certificates iptables

SERVER_IFACE="$(ip -o -4 addr show | awk -v ip="$SERVER_IP" '$4 ~ ip"/" {print $2; exit}')"

if [ -z "$SERVER_IFACE" ]; then
  echo "[ERROR] No network interface found for ${SERVER_IP}"
  ip -4 addr show
  exit 1
fi

echo "[P2 SERVER] Detected interface: ${SERVER_IFACE}"

curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --node-ip=${SERVER_IP} --advertise-address=${SERVER_IP} --tls-san=${SERVER_IP} --flannel-iface=${SERVER_IFACE}" sh -

i=1
while [ "$i" -le 60 ]; do
  if systemctl is-active --quiet k3s; then
    echo "[P2 SERVER] k3s service is active."
    break
  fi
  i=$((i + 1))
  sleep 2
done

if ! systemctl is-active --quiet k3s; then
  echo "[ERROR] k3s service is not active."
  journalctl -u k3s -n 80 --no-pager || true
  exit 1
fi

mkdir -p /home/vagrant/.kube
cp /etc/rancher/k3s/k3s.yaml /home/vagrant/.kube/config
chown -R vagrant:vagrant /home/vagrant/.kube
chmod 600 /home/vagrant/.kube/config

grep -qxF 'export KUBECONFIG=/home/vagrant/.kube/config' /home/vagrant/.bashrc || echo 'export KUBECONFIG=/home/vagrant/.kube/config' >> /home/vagrant/.bashrc

echo "[P2 SERVER] Waiting for node to be Ready..."

i=1
while [ "$i" -le 60 ]; do
  if kubectl get nodes | grep -q " Ready "; then
    echo "[P2 SERVER] Node is Ready."
    break
  fi
  i=$((i + 1))
  sleep 2
done

if ! kubectl get nodes | grep -q " Ready "; then
  echo "[ERROR] Node is not Ready."
  kubectl get nodes -o wide || true
  exit 1
fi

if ls "${CONFS_DIR}"/*.yaml >/dev/null 2>&1; then
  echo "[P2 SERVER] Applying Kubernetes manifests..."
  kubectl apply -f "${CONFS_DIR}"
else
  echo "[P2 SERVER] No Kubernetes manifests found yet in ${CONFS_DIR}."
fi

echo "[P2 SERVER] Current Kubernetes state:"
kubectl get nodes -o wide || true
kubectl get pods,svc,ingress -A || true

echo "[P2 SERVER] Installation finished."
