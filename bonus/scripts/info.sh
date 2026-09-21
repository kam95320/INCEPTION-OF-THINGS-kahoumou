#!/usr/bin/env bash
# =============================================================================
# Affiche tout ce qu'il faut pour la defense : adresses, identifiants, etat.
# =============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

require_cmd kubectl
require_cluster

echo "============================================================"
echo " GitLab"
echo "   URL         : ${GITLAB_PUBLIC_URL}"
echo "   Utilisateur : ${GITLAB_USER}"
echo "   Mot de passe: $(gitlab_root_password)"
echo "   Depot       : ${GITLAB_PUBLIC_URL}/${GITLAB_USER}/${GITLAB_PROJECT}"
echo
echo " Argo CD"
echo "   URL         : http://${ARGOCD_HOST}:${HTTP_PORT}"
echo "   Utilisateur : admin"
echo "   Mot de passe: $(argocd_admin_password)"
echo
echo " Application"
echo "   URL         : http://localhost:${APP_PORT}/"
echo "============================================================"
echo
kubectl get ns
echo
kubectl get pods -n "${DEV_NS}"
echo
kubectl get application -n "${ARGOCD_NS}"
echo
echo "Version deployee :"
kubectl get deployment playground -n "${DEV_NS}" \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}' 2>/dev/null || true
echo "Reponse HTTP :"
app_response || true
