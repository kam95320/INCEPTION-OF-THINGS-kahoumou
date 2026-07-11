#!/bin/sh

# Arrête le script immédiatement si une commande échoue.
set -eu

apt_clean_lists() {
    rm -rf /var/lib/apt/lists/*
    mkdir -p /var/lib/apt/lists/partial
}

apt_update_retry() {
    apt_clean_lists
    for attempt in 1 2 3; do
        echo "[APT] apt-get update attempt ${attempt}/3"
        if apt-get update; then
            return 0
        fi
        echo "[APT] apt-get update failed, cleaning cache before retry..."
        apt_clean_lists
        sleep 5
    done
    echo "[APT] ERROR: apt-get update failed after 3 attempts"
    return 1
}

apt_install_retry() {
    for attempt in 1 2 3; do
        echo "[APT] apt-get install attempt ${attempt}/3: $*"
        if DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"; then
            return 0
        fi
        echo "[APT] apt-get install failed, refreshing package lists before retry..."
        apt-get update || true
        sleep 5
    done
    echo "[APT] ERROR: apt-get install failed after 3 attempts: $*"
    return 1
}


# IP obligatoire du serveur selon le sujet.
SERVER_IP="192.168.56.110"

# IP obligatoire du worker selon le sujet.
AGENT_IP="192.168.56.111"

# Fichier partagé contenant le token généré par le serveur.
TOKEN_FILE="/vagrant/confs/node-token"

echo "[AGENT] Starting K3s agent installation..."

# Met à jour la liste des paquets Debian.
apt_update_retry
# Installe curl pour télécharger K3s,
# et ca-certificates pour les connexions HTTPS.
apt_install_retry curl ca-certificates iptables
# Cherche automatiquement l'interface réseau qui porte l'IP 192.168.56.111.
AGENT_IFACE="$(ip -o -4 addr show | awk -v ip="$AGENT_IP" '$4 ~ ip"/" {print $2; exit}')"

# Vérifie que l'interface réseau a bien été trouvée.
if [ -z "$AGENT_IFACE" ]; then
	echo "[AGENT] ERROR: interface with IP $AGENT_IP not found"
	ip -4 addr
	exit 1
fi

echo "[AGENT] Detected interface: $AGENT_IFACE"

# Attend que le token du serveur existe dans le dossier partagé.
for i in $(seq 1 120); do
	if [ -s "$TOKEN_FILE" ]; then
		echo "[AGENT] Token found."
		break
	fi
	echo "[AGENT] Waiting for server token..."
	sleep 2
done

# Vérifie définitivement que le token existe.
if [ ! -s "$TOKEN_FILE" ]; then
	echo "[AGENT] ERROR: token file not found: $TOKEN_FILE"
	exit 1
fi

# Lit le token généré par le serveur.
TOKEN="$(cat "$TOKEN_FILE")"

# Installe K3s en mode agent si K3s n'est pas déjà installé.
# K3S_URL indique l'adresse du serveur K3s.
# K3S_TOKEN autorise l'agent à rejoindre le cluster.
# --node-ip force Kubernetes à utiliser l'IP attendue par le sujet.
# --flannel-iface force le réseau interne des pods à utiliser la bonne interface.
if ! command -v k3s >/dev/null 2>&1; then
	curl -sfL https://get.k3s.io | \
		K3S_URL="https://${SERVER_IP}:6443" \
		K3S_TOKEN="${TOKEN}" \
		INSTALL_K3S_EXEC="agent --node-ip=${AGENT_IP} --flannel-iface=${AGENT_IFACE}" \
		sh -
else
	echo "[AGENT] K3s already installed, skipping installation."
fi

# Attend que le service k3s-agent soit actif.
for i in $(seq 1 60); do
	if systemctl is-active --quiet k3s-agent; then
		echo "[AGENT] k3s-agent service is active."
		break
	fi
	echo "[AGENT] Waiting for k3s-agent service..."
	sleep 2
done

# Vérifie définitivement que le service k3s-agent est actif.
if ! systemctl is-active --quiet k3s-agent; then
	echo "[AGENT] ERROR: k3s-agent service is not active"
	systemctl status k3s-agent --no-pager || true
	exit 1
fi

echo "[AGENT] K3s agent installation finished."
