#!/usr/bin/env bash
# =============================================================================
# Change la version de l'application depuis le depot GitLab local.
#
#   ./switch_version.sh v2
#
# Le script modifie le tag de l'image dans app/deployment.yaml, pousse le
# commit sur GitLab, puis attend qu'Argo CD detecte le changement tout seul.
# =============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

require_cmd kubectl
require_cmd git
require_cluster

VERSION="${1:-}"
case "${VERSION}" in
  v1|v2) ;;
  *) die "Usage: $0 <v1|v2>" ;;
esac

[ -d "${WORK_REPO}/.git" ] || die "Copie de travail absente. Lancez setup_gitlab_repo.sh."

GL_PASS="$(gitlab_root_password)"
export GL_PASS

cd "${WORK_REPO}"

log "Passage de l'application en ${VERSION} dans le depot GitLab..."
sed -i -E "s|(image: wil42/playground:)v[0-9]+|\1${VERSION}|" app/deployment.yaml
grep -n "image: wil42/playground" app/deployment.yaml

git add -A
if git diff --cached --quiet; then
  log "Le depot est deja en ${VERSION}, rien a pousser."
else
  git commit -q -m "Update playground application to ${VERSION}"
  BASE="$(gitlab_http_base)"
  trap stop_gitlab_forward EXIT
  git remote set-url origin "${BASE}/${GITLAB_USER}/${GITLAB_PROJECT}.git"
  git -c credential.helper='!f() { echo username=root; echo "password=${GL_PASS}"; }; f' \
    push origin main
  ok "Commit pousse sur le GitLab local."
fi

# Argo CD interroge le depot toutes les 3 minutes.
# L'option --now force une verification immediate au lieu d'attendre.
if [ "${2:-}" = "--now" ]; then
  log "Rafraichissement force d'Argo CD..."
  kubectl -n "${ARGOCD_NS}" annotate application playground \
    argocd.argoproj.io/refresh=hard --overwrite >/dev/null
fi

# Argo CD est configure pour interroger le depot toutes les 30 secondes
# (voir create_cluster.sh), la bascule est donc visible en moins d'une minute.
# La fenetre reste large pour absorber le temps de telechargement de l'image.
log "Attente de la synchronisation automatique par Argo CD..."
TARGET="wil42/playground:${VERSION}"
for i in $(seq 1 72); do
  CURRENT="$(kubectl get deployment playground -n "${DEV_NS}" \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  if [ "${CURRENT}" = "${TARGET}" ]; then
    ok "Argo CD a deploye ${TARGET} (apres $((i * 5))s)."
    break
  fi
  sleep 5
done

kubectl rollout status deployment/playground -n "${DEV_NS}" --timeout=180s

echo
kubectl get application playground -n "${ARGOCD_NS}"
kubectl get pods -n "${DEV_NS}"
echo
log "Reponse de l'application :"
app_response
