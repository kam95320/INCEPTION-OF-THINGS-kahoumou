#!/usr/bin/env bash
# =============================================================================
# Cree le cluster K3d du bonus et y installe Argo CD.
#
# Trois namespaces sont crees :
#   argocd  -> Argo CD
#   dev     -> l'application de la Partie 3
#   gitlab  -> l'instance GitLab (installee par install_gitlab.sh)
# =============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

require_cmd k3d
require_cmd kubectl

# --- Cluster -----------------------------------------------------------------

if k3d cluster list -o json | grep -q "\"name\":\"${CLUSTER_NAME}\""; then
  log "Le cluster ${CLUSTER_NAME} existe deja, creation ignoree."
else
  log "Creation du cluster K3d ${CLUSTER_NAME}..."
  # Les deux ports pointent vers le port 80 du load balancer :
  #   8080 -> interfaces web, routees par nom d'hote (gitlab.local, argocd.local)
  #   8888 -> application, joignable sur http://localhost:8888 comme en Partie 3
  k3d cluster create "${CLUSTER_NAME}" \
    --servers 1 \
    --agents 0 \
    --port "${HTTP_PORT}:80@loadbalancer" \
    --port "${APP_PORT}:80@loadbalancer" \
    --wait
fi

log "Selection du contexte kubectl..."
kubectl config use-context "k3d-${CLUSTER_NAME}" >/dev/null

# --- Namespaces --------------------------------------------------------------

for ns in "${ARGOCD_NS}" "${DEV_NS}" "${GITLAB_NS}"; do
  kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
done
ok "Namespaces: ${ARGOCD_NS}, ${DEV_NS}, ${GITLAB_NS}"

# --- Argo CD -----------------------------------------------------------------

log "Installation d'Argo CD..."
kubectl apply --server-side \
  -n "${ARGOCD_NS}" \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml >/dev/null

log "Attente des CRD Argo CD..."
kubectl wait --for=condition=Established --timeout=120s crd/applications.argoproj.io

log "Attente des deploiements Argo CD (1 a 2 minutes)..."
kubectl wait --for=condition=Available --timeout=600s deployment --all -n "${ARGOCD_NS}"

# Deux reglages d'Argo CD, appliques ensemble :
#
# 1. server.insecure : Argo CD sert du HTTPS avec un certificat auto-signe par
#    defaut. En HTTP simple, l'Ingress Traefik peut lui parler sans avoir a
#    gerer de certificat local.
#
# 2. Detection des commits. Par defaut Argo CD empile deux caches de 3 minutes
#    (cache de revision du repo-server, puis intervalle de reconciliation), ce
#    qui fait attendre jusqu'a 6 minutes avant qu'un commit soit vu. Les deux
#    sont ramenes a 30 secondes : sur un depot local, le cout est negligeable
#    et la synchronisation devient visible en moins d'une minute.
log "Configuration d'Argo CD (HTTP local, detection rapide des commits)..."
kubectl -n "${ARGOCD_NS}" patch configmap argocd-cmd-params-cm --type merge -p \
  '{"data":{"server.insecure":"true","reposerver.revision.cache.expiration":"30s"}}' >/dev/null
kubectl -n "${ARGOCD_NS}" patch configmap argocd-cm --type merge -p \
  '{"data":{"timeout.reconciliation":"30s"}}' >/dev/null

kubectl -n "${ARGOCD_NS}" rollout restart deployment argocd-server argocd-repo-server >/dev/null
kubectl -n "${ARGOCD_NS}" rollout restart statefulset argocd-application-controller >/dev/null
kubectl -n "${ARGOCD_NS}" rollout status deployment argocd-server --timeout=180s
kubectl -n "${ARGOCD_NS}" rollout status deployment argocd-repo-server --timeout=180s
kubectl -n "${ARGOCD_NS}" rollout status statefulset argocd-application-controller --timeout=180s

log "Publication de l'interface Argo CD sur http://${ARGOCD_HOST}:${HTTP_PORT}"
kubectl apply -f "${CONFS_DIR}/argocd-ingress.yaml" >/dev/null

# --- Resolution des noms d'hotes ---------------------------------------------

log "Ajout de ${GITLAB_HOST} et ${ARGOCD_HOST} dans /etc/hosts (sudo)..."
for host in "${GITLAB_HOST}" "${ARGOCD_HOST}"; do
  if grep -qE "(^|[[:space:]])${host}([[:space:]]|$)" /etc/hosts; then
    continue
  fi
  if printf '127.0.0.1 %s\n' "${host}" | sudo tee -a /etc/hosts >/dev/null 2>&1; then
    ok "/etc/hosts : ${host}"
  else
    warn "Impossible d'ecrire dans /etc/hosts. Ajoutez manuellement :"
    warn "    127.0.0.1 ${GITLAB_HOST} ${ARGOCD_HOST}"
    break
  fi
done

ok "Cluster pret."
echo
kubectl get nodes
kubectl get ns
