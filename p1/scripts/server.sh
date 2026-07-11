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

# Fichier partagé qui contiendra le token permettant au worker de rejoindre le cluster.
TOKEN_DEST="/vagrant/confs/node-token"

echo "[SERVER] Starting K3s server installation..."

# Met à jour la liste des paquets Debian.
apt_update_retry
# Installe curl pour télécharger le script officiel K3s,
# et ca-certificates pour vérifier les certificats HTTPS.
apt_install_retry curl ca-certificates iptables
# Cherche automatiquement l'interface réseau qui porte l'IP 192.168.56.110.
# Cela évite de supposer que l'interface s'appelle forcément enp0s8.
SERVER_IFACE="$(ip -o -4 addr show | awk -v ip="$SERVER_IP" '$4 ~ ip"/" {print $2; exit}')"

# Vérifie que l'interface réseau a bien été trouvée.
if [ -z "$SERVER_IFACE" ]; then
	echo "[SERVER] ERROR: interface with IP $SERVER_IP not found"
	ip -4 addr
	exit 1
fi

echo "[SERVER] Detected interface: $SERVER_IFACE"

# Installe K3s en mode server si K3s n'est pas déjà installé.
# --node-ip force Kubernetes à utiliser l'IP attendue par le sujet.
# --advertise-address force le serveur API à annoncer 192.168.56.110.
# --tls-san ajoute 192.168.56.110 au certificat TLS de l'API server.
# --flannel-iface force le réseau interne des pods à utiliser la bonne interface.
if ! command -v k3s >/dev/null 2>&1; then
	curl -sfL https://get.k3s.io | \
		INSTALL_K3S_EXEC="server --node-ip=${SERVER_IP} --advertise-address=${SERVER_IP} --tls-san=${SERVER_IP} --flannel-iface=${SERVER_IFACE}" \
		sh -
else
	echo "[SERVER] K3s already installed, skipping installation."
fi

# Attend que le service k3s soit actif.
for i in $(seq 1 60); do
	if systemctl is-active --quiet k3s; then
		echo "[SERVER] k3s service is active."
		break
	fi
	echo "[SERVER] Waiting for k3s service..."
	sleep 2
done

# Vérifie définitivement que le service k3s est actif.
if ! systemctl is-active --quiet k3s; then
	echo "[SERVER] ERROR: k3s service is not active"
	systemctl status k3s --no-pager || true
	exit 1
fi

# Prépare kubectl pour l'utilisateur vagrant.
mkdir -p /home/vagrant/.kube
cp /etc/rancher/k3s/k3s.yaml /home/vagrant/.kube/config
chown -R vagrant:vagrant /home/vagrant/.kube
chmod 600 /home/vagrant/.kube/config

# Force kubectl à utiliser le kubeconfig utilisateur.
if ! grep -q "KUBECONFIG=/home/vagrant/.kube/config" /home/vagrant/.bashrc; then
	echo 'export KUBECONFIG=/home/vagrant/.kube/config' >> /home/vagrant/.bashrc
fi


# Crée le dossier confs dans /vagrant s'il n'existe pas.
mkdir -p /vagrant/confs

# Copie le token du serveur dans le dossier partagé pour que l'agent puisse le lire.
cp /var/lib/rancher/k3s/server/node-token "$TOKEN_DEST"

# Rend le token lisible par l'agent pendant le provisionnement.
chmod 644 "$TOKEN_DEST"

echo "[SERVER] Node token copied to $TOKEN_DEST"

# Affiche les nodes visibles depuis le serveur.
kubectl get nodes -o wide || true

echo "[SERVER] K3s server installation finished."
