#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="iot"

# Répertoire p3, calculé à partir de l'emplacement du script.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
P3_DIR="$(dirname "$SCRIPT_DIR")"

echo "[P3] Creating K3d cluster: ${CLUSTER_NAME}"

k3d cluster create "${CLUSTER_NAME}" \
  --servers 1 \
  --agents 0 \
  --port "8888:80@loadbalancer"

echo "[P3] Using kubeconfig context..."
kubectl config use-context "k3d-${CLUSTER_NAME}"

echo "[P3] Creating namespaces argocd and dev..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace dev --dry-run=client -o yaml | kubectl apply -f -

echo "[P3] Installing Argo CD in namespace argocd..."
kubectl apply --server-side \
  -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "[P3] Waiting for Argo CD CRD..."
kubectl wait \
  --for=condition=Established \
  --timeout=120s \
  crd/applications.argoproj.io

echo "[P3] Waiting for Argo CD deployments..."
kubectl wait \
  --for=condition=Available \
  --timeout=300s \
  deployment --all \
  -n argocd

echo "[P3] Creating Argo CD Application..."
kubectl apply -f "${P3_DIR}/confs/argocd/application.yaml"

echo "[P3] Waiting for Argo CD synchronization..."

for i in {1..60}; do
  SYNC_STATUS="$(kubectl get application playground \
    -n argocd \
    -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"

  HEALTH_STATUS="$(kubectl get application playground \
    -n argocd \
    -o jsonpath='{.status.health.status}' 2>/dev/null || true)"

  if [ "$SYNC_STATUS" = "Synced" ] && [ "$HEALTH_STATUS" = "Healthy" ]; then
    echo "[P3] Argo CD application is Synced and Healthy."
    break
  fi

  sleep 5
done

if [ "$SYNC_STATUS" != "Synced" ] || [ "$HEALTH_STATUS" != "Healthy" ]; then
  echo "[ERROR] Argo CD application did not become Synced and Healthy."
  kubectl get application playground -n argocd
  exit 1
fi

echo "[P3] Waiting for playground deployment..."
kubectl rollout status deployment/playground \
  -n dev \
  --timeout=180s

echo "[P3] Cluster status:"
kubectl get nodes
kubectl get ns
kubectl get pods -n argocd
kubectl get applications -n argocd
kubectl get pods -n dev

echo "[P3] Cluster creation finished."
