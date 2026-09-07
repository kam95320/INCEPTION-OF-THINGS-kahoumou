#!/usr/bin/env bash
# =============================================================================
# Installe GitLab dans le namespace "gitlab".
#
# L'image utilisee est `gitlab/gitlab-ce:latest` : la distribution officielle
# tout-en-un, jamais figee sur une version, donc toujours la derniere publiee.
# =============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

require_cmd kubectl
require_cluster

# --- Mot de passe du compte root ---------------------------------------------
# Genere une seule fois et conserve dans un Secret Kubernetes : rien n'est
# ecrit en clair dans le depot.

if kubectl get secret gitlab-root-password -n "${GITLAB_NS}" >/dev/null 2>&1; then
  log "Mot de passe root deja present."
else
  log "Generation du mot de passe root..."
  ROOT_PASSWORD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"
  kubectl create secret generic gitlab-root-password \
    -n "${GITLAB_NS}" \
    --from-literal=password="${ROOT_PASSWORD}" >/dev/null
fi

# --- Deploiement -------------------------------------------------------------

log "Deploiement de GitLab (namespace ${GITLAB_NS})..."
kubectl apply -f "${CONFS_DIR}/gitlab.yaml" >/dev/null

log "Telechargement de l'image et demarrage."
log "Le premier lancement prend 5 a 15 minutes (migrations de la base)."

kubectl -n "${GITLAB_NS}" rollout status statefulset/gitlab --timeout=2400s

POD="$(gitlab_pod)"
VERSION="$(kubectl exec -n "${GITLAB_NS}" "${POD}" -- \
  head -1 /opt/gitlab/version-manifest.txt 2>/dev/null || echo 'inconnue')"

ok "GitLab est demarre (${VERSION})."
echo
kubectl get pods,svc,ingress -n "${GITLAB_NS}"
echo
echo "Interface   : ${GITLAB_PUBLIC_URL}"
echo "Utilisateur : ${GITLAB_USER}"
echo "Mot de passe: $(gitlab_root_password)"
