#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# bootstrap/dev-cluster.sh
#
# One-time bootstrap for the dev-cluster. After this runs, Flux manages itself
# and all infra/apps via GitOps from this repository.
#
# Usage:
#   GITHUB_USER=<your-github-username> ./bootstrap/dev-cluster.sh
#
# Prerequisites:
#   - k8s-colima-cluster is running (make start from that repo)
#   - kubectl context is set to k3d-dev-cluster
#   - helm is installed (brew install helm)
#   - This repo is pushed to GitHub at https://github.com/$GITHUB_USER/k8s-fleet
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

GREEN='\033[0;32m'; CYAN='\033[0;36m'; RED='\033[0;31m'; NC='\033[0m'
info()    { echo -e "${GREEN}[bootstrap]${NC} $*"; }
section() { echo -e "\n${CYAN}━━━ $* ━━━${NC}"; }
error()   { echo -e "${RED}[bootstrap]${NC} $*" >&2; exit 1; }

GITHUB_USER="${GITHUB_USER:-}"
CLUSTER_CONTEXT="${CLUSTER_CONTEXT:-k3d-dev-cluster}"

[[ -z "${GITHUB_USER}" ]] && error "GITHUB_USER is not set. Export it before running: export GITHUB_USER=<your-username>"

# ── Pre-flight ─────────────────────────────────────────────────────────────────
section "Pre-flight checks"
command -v helm    &>/dev/null || error "helm not found. Run: brew install helm"
command -v kubectl &>/dev/null || error "kubectl not found."
command -v flux    &>/dev/null || error "flux CLI not found. Run: brew install fluxcd/tap/flux"

CURRENT_CONTEXT="$(kubectl config current-context)"
info "Current kubectl context: ${CURRENT_CONTEXT}"
[[ "${CURRENT_CONTEXT}" != "${CLUSTER_CONTEXT}" ]] && \
  error "Wrong context. Expected '${CLUSTER_CONTEXT}', got '${CURRENT_CONTEXT}'. Run: kubectl config use-context ${CLUSTER_CONTEXT}"

kubectl get nodes &>/dev/null || error "Cannot reach the cluster API server."
info "Cluster is reachable."

# ── Step 1: Install Flux via Helm ──────────────────────────────────────────────
section "Installing Flux controllers via Helm"

helm repo add fluxcd-community https://fluxcd-community.github.io/helm-charts 2>/dev/null || true
helm repo update fluxcd-community

helm upgrade --install flux fluxcd-community/flux2 \
  --namespace flux-system \
  --create-namespace \
  --wait \
  --timeout 5m \
  --set sourceController.create=true \
  --set kustomizeController.create=true \
  --set helmController.create=true \
  --set notificationController.create=true \
  --set imageAutomationController.create=false \
  --set imageReflectionController.create=false

info "Flux controllers installed."

# ── Step 2: Apply GitRepository pointing at this repo ─────────────────────────
section "Configuring GitRepository source"

# Substitute GITHUB_USER into the GitRepository manifest and apply
GITHUB_USER="${GITHUB_USER}" envsubst < "${REPO_ROOT}/clusters/dev-cluster/gitrepository.yaml" \
  | kubectl apply -f -

info "GitRepository applied. Flux will sync from https://github.com/${GITHUB_USER}/k8s-fleet"

# ── Step 3: Apply Flux Kustomizations ─────────────────────────────────────────
section "Applying cluster Kustomizations"

kubectl apply -f "${REPO_ROOT}/clusters/dev-cluster/infrastructure.yaml"
kubectl apply -f "${REPO_ROOT}/clusters/dev-cluster/apps.yaml"

# ── Step 4: Wait for reconciliation ───────────────────────────────────────────
section "Waiting for Flux to reconcile"

info "Waiting for infrastructure Kustomization..."
flux reconcile kustomization infrastructure --timeout=5m || true

info "Waiting for apps Kustomization..."
flux reconcile kustomization apps --timeout=5m || true

# ── Done ───────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}✔  Bootstrap complete!${NC}"
echo ""
echo "  flux get all -A          # see all Flux resources"
echo "  flux logs --all-namespaces  # check reconciliation logs"
echo "  kubectl get helmrelease -n flux-system  # check Flux's own HelmRelease"
echo ""
echo "  To upgrade Flux: bump the version in infrastructure/base/flux/helmrelease.yaml and push."
