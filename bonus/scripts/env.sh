#!/usr/bin/env bash
# =============================================================================
# Variables et fonctions communes a tous les scripts du bonus.
# Ce fichier n'est pas execute directement, il est source par les autres.
# =============================================================================

CLUSTER_NAME="iot-bonus"

ARGOCD_NS="argocd"
DEV_NS="dev"
GITLAB_NS="gitlab"

GITLAB_HOST="gitlab.local"
ARGOCD_HOST="argocd.local"

# Ports de la machine hote rediriges vers le port 80 du load balancer K3d.
#   HTTP_PORT : interfaces web (GitLab et Argo CD, routees par nom d'hote)
#   APP_PORT  : application de la Partie 3, joignable sur http://localhost:8888
HTTP_PORT="8080"
APP_PORT="8888"

# Depot heberge sur le GitLab local.
GITLAB_USER="root"
GITLAB_PROJECT="iot-kahoumou"

# Adresse de GitLab a l'interieur du cluster : c'est par la qu'Argo CD clone.
# Le Service ecoute sur 8080, donc cette URL a exactement la meme forme que
# l'URL publique http://gitlab.local:8080 configuree dans GitLab.
GITLAB_SVC="gitlab.${GITLAB_NS}.svc.cluster.local"
GITLAB_INTERNAL_URL="http://${GITLAB_SVC}:${HTTP_PORT}"

# URL publique, celle qu'utilise un navigateur.
GITLAB_PUBLIC_URL="http://${GITLAB_HOST}:${HTTP_PORT}"

# Etat local (jamais commite) : copie de travail du depot GitLab.
STATE_DIR="${HOME}/.iot-bonus"
WORK_REPO="${STATE_DIR}/${GITLAB_PROJECT}"

# Port local utilise si gitlab.local n'est pas resolvable (kubectl port-forward).
FORWARD_PORT="8181"

# Racine du dossier bonus, quel que soit l'endroit d'ou le script est lance.
BONUS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFS_DIR="${BONUS_DIR}/confs"
SCRIPTS_DIR="${BONUS_DIR}/scripts"

log()  { printf '\033[1;34m[bonus]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ ok ]\033[0m  %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 ||
    die "'$1' est introuvable. Lancez d'abord: bonus/scripts/install_tools.sh"
}

require_cluster() {
  kubectl config current-context 2>/dev/null | grep -q "k3d-${CLUSTER_NAME}" ||
    die "Le contexte kubectl n'est pas k3d-${CLUSTER_NAME}. Lancez create_cluster.sh."
}

# --- Secrets -----------------------------------------------------------------

gitlab_root_password() {
  kubectl get secret gitlab-root-password -n "${GITLAB_NS}" \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d
}

argocd_admin_password() {
  kubectl -n "${ARGOCD_NS}" get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d
}

# --- Acces a GitLab depuis la machine ----------------------------------------
# Normalement http://gitlab.local:8080 suffit (create_cluster.sh renseigne
# /etc/hosts). Si le nom n'est pas resolvable — par exemple quand /etc/hosts
# n'a pas pu etre modifie — on bascule automatiquement sur un port-forward.

# Le PID est conserve dans un fichier et non dans une variable : les fonctions
# ci-dessous sont appelees depuis des substitutions de commande, donc dans des
# sous-shells dont les variables ne remontent pas au script appelant.
FORWARD_PID_FILE="${STATE_DIR}/port-forward.pid"

stop_gitlab_forward() {
  [ -f "${FORWARD_PID_FILE}" ] || return 0
  kill "$(cat "${FORWARD_PID_FILE}")" 2>/dev/null || true
  rm -f "${FORWARD_PID_FILE}"
}

start_gitlab_forward() {
  # Coupe d'abord un eventuel port-forward laisse par une execution precedente.
  stop_gitlab_forward
  mkdir -p "${STATE_DIR}"
  kubectl port-forward -n "${GITLAB_NS}" \
    "svc/gitlab" "${FORWARD_PORT}:${HTTP_PORT}" >/dev/null 2>&1 &
  echo $! > "${FORWARD_PID_FILE}"
  sleep 3
}

# Renvoie l'URL de base a utiliser pour parler a GitLab depuis la machine,
# en montant un port-forward si necessaire.
gitlab_http_base() {
  if getent hosts "${GITLAB_HOST}" >/dev/null 2>&1; then
    printf '%s' "${GITLAB_PUBLIC_URL}"
    return 0
  fi
  start_gitlab_forward
  printf 'http://127.0.0.1:%s' "${FORWARD_PORT}"
}

# Attend que GitLab reponde sur l'URL donnee.
wait_gitlab_http() {
  local base="$1" i code
  for i in $(seq 1 90); do
    code="$(curl -s -o /dev/null -w '%{http_code}' "${base}/users/sign_in" 2>/dev/null || true)"
    case "${code}" in
      200|302) return 0 ;;
    esac
    sleep 5
  done
  die "GitLab ne repond pas sur ${base}"
}

# Interroge l'application. Juste apres un remplacement de pod, Traefik met
# une a deux secondes a basculer ses endpoints : une requete unique pourrait
# tomber sur "Bad Gateway" alors que le deploiement est correct.
app_response() {
  local i out=""
  for i in $(seq 1 15); do
    out="$(curl -s --max-time 5 "http://localhost:${APP_PORT}/" 2>/dev/null || true)"
    case "${out}" in
      *'"status"'*) printf '%s\n' "${out}"; return 0 ;;
    esac
    sleep 2
  done
  printf '%s\n' "${out:-aucune reponse}"
  return 1
}

# Nom du pod GitLab (StatefulSet a une seule replique).
gitlab_pod() {
  kubectl get pods -n "${GITLAB_NS}" -l app=gitlab \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}
