#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="iot"

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
kubectl apply --server-side -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "[P3] Waiting for Argo CD deployments..."
kubectl wait --for=condition=Available --timeout=300s deployment --all -n argocd

echo "[P3] Cluster status:"
kubectl get nodes
kubectl get ns
kubectl get pods -n argocd
kubectl get pods -n dev

echo "[P3] Cluster creation finished."
