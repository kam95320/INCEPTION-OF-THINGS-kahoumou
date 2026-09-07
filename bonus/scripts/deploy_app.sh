#!/usr/bin/env bash
# =============================================================================
# Branche Argo CD sur le depot du GitLab local et attend le deploiement.
#
# C'est l'etape qui remplace GitHub par GitLab : l'Application Argo CD pointe
# sur le Service Kubernetes de GitLab, a l'interieur du cluster.
# =============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

require_cmd kubectl
require_cluster

GL_PASS="$(gitlab_root_password)"
[ -n "${GL_PASS}" ] || die "Mot de passe root GitLab introuvable."

log "Enregistrement du depot GitLab aupres d'Argo CD..."
sed "s|__GITLAB_PASSWORD__|${GL_PASS}|" "${CONFS_DIR}/argocd-repo-secret.yaml" |
  kubectl apply -f - >/dev/null
ok "Secret gitlab-local-repo cree dans le namespace ${ARGOCD_NS}"

log "Creation de l'Application Argo CD..."
kubectl apply -f "${CONFS_DIR}/application.yaml" >/dev/null

log "Attente de la synchronisation (Synced + Healthy)..."
SYNC_STATUS=""
HEALTH_STATUS=""
for _ in $(seq 1 90); do
  SYNC_STATUS="$(kubectl get application playground -n "${ARGOCD_NS}" \
    -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  HEALTH_STATUS="$(kubectl get application playground -n "${ARGOCD_NS}" \
    -o jsonpath='{.status.health.status}' 2>/dev/null || true)"

  if [ "${SYNC_STATUS}" = "Synced" ] && [ "${HEALTH_STATUS}" = "Healthy" ]; then
    ok "Application Synced et Healthy."
    break
  fi
  sleep 5
done

if [ "${SYNC_STATUS}" != "Synced" ] || [ "${HEALTH_STATUS}" != "Healthy" ]; then
  kubectl get application playground -n "${ARGOCD_NS}" \
    -o jsonpath='{.status.conditions}' 2>/dev/null || true
  echo
  die "L'application n'est pas synchronisee (sync=${SYNC_STATUS} health=${HEALTH_STATUS})."
fi

kubectl rollout status deployment/playground -n "${DEV_NS}" --timeout=180s

echo
kubectl get applications -n "${ARGOCD_NS}"
kubectl get pods -n "${DEV_NS}"
echo
log "Test de l'application :"
curl -s "http://localhost:${APP_PORT}/" || warn "L'application ne repond pas encore."
echo
