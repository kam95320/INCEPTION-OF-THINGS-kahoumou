#!/usr/bin/env bash
# =============================================================================
# Deroule l'installation complete du bonus, dans l'ordre.
#
#   1. cluster K3d + namespaces + Argo CD
#   2. GitLab (chart Helm officiel) dans le namespace gitlab
#   3. creation du depot sur ce GitLab et envoi des manifestes
#   4. branchement d'Argo CD sur ce depot local
#
# Duree totale : environ 15 a 25 minutes, GitLab etant long a demarrer.
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"${HERE}/create_cluster.sh"
"${HERE}/install_gitlab.sh"
"${HERE}/setup_gitlab_repo.sh"
"${HERE}/deploy_app.sh"
"${HERE}/info.sh"
