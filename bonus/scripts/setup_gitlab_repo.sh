#!/usr/bin/env bash
# =============================================================================
# Cree le depot du projet sur le GitLab local et y pousse les manifestes de
# l'application. C'est ce depot, et non GitHub, qui sera la source d'Argo CD.
#
# Le projet est cree via `gitlab-rails` directement dans le conteneur GitLab :
# aucune manipulation dans l'interface web n'est necessaire.
# =============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

require_cmd kubectl
require_cmd git
require_cluster

mkdir -p "${STATE_DIR}"
chmod 700 "${STATE_DIR}"

GL_PASS="$(gitlab_root_password)"
[ -n "${GL_PASS}" ] || die "Mot de passe root introuvable. GitLab est-il installe ?"

POD="$(gitlab_pod)"
[ -n "${POD}" ] || die "Aucun pod GitLab en cours d'execution."

# --- Creation du projet ------------------------------------------------------

log "Creation du projet ${GITLAB_USER}/${GITLAB_PROJECT} (peut prendre 1 minute)..."

kubectl exec -n "${GITLAB_NS}" "${POD}" -- gitlab-rails runner "
  user = User.find_by_username('${GITLAB_USER}')
  project = Project.find_by_full_path('${GITLAB_USER}/${GITLAB_PROJECT}')

  if project.nil?
    project = ::Projects::CreateService.new(
      user,
      name: '${GITLAB_PROJECT}',
      path: '${GITLAB_PROJECT}',
      namespace_id: user.namespace.id,
      visibility_level: Gitlab::VisibilityLevel::PUBLIC,
      initialize_with_readme: false
    ).execute
  end

  if project.persisted?
    puts \"PROJECT_OK #{project.full_path}\"
  else
    puts \"PROJECT_ERROR #{project.errors.full_messages.join(', ')}\"
  end
" 2>/dev/null | tee "${STATE_DIR}/project.log"

grep -q PROJECT_OK "${STATE_DIR}/project.log" ||
  die "Creation du projet impossible (voir ${STATE_DIR}/project.log)."
ok "Projet disponible : ${GITLAB_USER}/${GITLAB_PROJECT}"

# --- Copie de travail locale -------------------------------------------------

log "Preparation de la copie de travail (${WORK_REPO})..."
mkdir -p "${WORK_REPO}/app"
cp "${CONFS_DIR}/app/"*.yaml "${WORK_REPO}/app/"

cat > "${WORK_REPO}/README.md" <<'EOF'
# iot-kahoumou

Depot heberge sur le GitLab local du cluster K3d.

Argo CD surveille le dossier `app/` et deploie son contenu dans le namespace
`dev`. Changer le tag de l'image dans `app/deployment.yaml` puis pousser
suffit a changer la version de l'application deployee.
EOF

cd "${WORK_REPO}"
if [ ! -d .git ]; then
  git init -q
  git symbolic-ref HEAD refs/heads/main
fi
git config user.email "root@gitlab.local"
git config user.name "root"

# --- Envoi vers le GitLab local ----------------------------------------------

BASE="$(gitlab_http_base)"
trap stop_gitlab_forward EXIT
log "GitLab joignable sur ${BASE}"
wait_gitlab_http "${BASE}"

git remote remove origin 2>/dev/null || true
git remote add origin "${BASE}/${GITLAB_USER}/${GITLAB_PROJECT}.git"

git add -A
if git rev-parse HEAD >/dev/null 2>&1 && git diff --cached --quiet; then
  log "Aucun changement a commiter."
else
  git commit -q -m "Deploy playground application (v1)"
fi

log "Envoi du depot vers GitLab..."
export GL_PASS
git -c credential.helper='!f() { echo username=root; echo "password=${GL_PASS}"; }; f' \
  push -u origin main

ok "Manifestes pousses sur ${GITLAB_PUBLIC_URL}/${GITLAB_USER}/${GITLAB_PROJECT}"
