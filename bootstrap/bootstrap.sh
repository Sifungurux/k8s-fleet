#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# bootstrap/bootstrap.sh  —  Generic bootstrap for ANY cluster
#
# Usage:
#   GITHUB_USER=kirk CLUSTER=staging ./bootstrap/bootstrap.sh
#
# This script:
#   1. Installs Flux controllers via Helm
#   2. Applies the GitRepository + Kustomizations for the given cluster path
#   3. From then on, Flux manages itself and everything else via GitOps
#
# To add a new cluster:
#   1. mkdir -p clusters/<name>  infrastructure/<name>  apps/<name>
#   2. Copy an existing overlay (e.g. dev-cluster) and adjust as needed
#   3. Run this script with CLUSTER=<name>
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

GREEN='\033[0;32m'; CYAN='\033[0;36m'; RED='\033[0;31m'; NC='\033[0m'
info()    { echo -e "${GREEN}[bootstrap]${NC} $*"; }
section() { echo -e "\n${CYAN}━━━ $* ━━━${NC}"; }
error()   { echo -e "${RED}[bootstrap]${NC} $*" >&2; exit 1; }

# ── Config (override via env) ─────────────────────────────────────────────────
GITHUB_USER="${GITHUB_USER:-}"
CLUSTER="${CLUSTER:-dev-cluster}"
CLUSTER_CONTEXT="${CLUSTER_CONTEXT:-k3d-${CLUSTER}}"
FLUX_VERSION_RANGE="${FLUX_VERSION_RANGE:->=2.0.0 <3.0.0}"

[[ -z "${GITHUB_USER}" ]] && error "GITHUB_USER is not set. Export it before running."

CLUSTER_DIR="${REPO_ROOT}/clusters/${CLUSTER}"
[[ -d "${CLUSTER_DIR}" ]] || error "Cluster directory not found: ${CLUSTER_DIR}"

# ── Pre-flight ─────────────────────────────────────────────────────────────────
section "Pre-flight (cluster: ${CLUSTER})"
command -v helm    &>/dev/null || error "helm not found. Run: brew install helm"
command -v kubectl &>/dev/null || error "kubectl not found."
command -v flux    &>/dev/null || error "flux not found. Run: brew install fluxcd/tap/flux"
command -v envsubst &>/dev/null || error "envsubst not found. Run: brew install gettext"

CURRENT_CONTEXT="$(kubectl config current-context)"
info "kubectl context: ${CURRENT_CONTEXT}"
[[ "${CURRENT_CONTEXT}" != "${CLUSTER_CONTEXT}" ]] && \
  error "Wrong context — expected '${CLUSTER_CONTEXT}', got '${CURRENT_CONTEXT}'"
kubectl get nodes &>/dev/null || error "Cannot reach the cluster API."
info "Cluster reachable."

# ── Step 1: Flux via Helm ──────────────────────────────────────────────────────
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

info "Flux controllers running."

# ── Step 2: GitRepository ──────────────────────────────────────────────────────
section "Applying GitRepository"

GITHUB_USER="${GITHUB_USER}" CLUSTER="${CLUSTER}" \
  envsubst < "${CLUSTER_DIR}/gitrepository.yaml" | kubectl apply -f -

info "GitRepository → https://github.com/${GITHUB_USER}/k8s-fleet"

# ── Step 3: Kustomizations ────────────────────────────────────────────────────
section "Applying Kustomizations"

kubectl apply -f "${CLUSTER_DIR}/infrastructure.yaml"
kubectl apply -f "${CLUSTER_DIR}/apps.yaml"

# ── Step 4: Reconcile ─────────────────────────────────────────────────────────
section "Reconciling"

flux reconcile kustomization infrastructure --timeout=5m || true
flux reconcile kustomization apps --timeout=5m || true

echo ""
echo -e "${GREEN}✔  ${CLUSTER} bootstrapped!${NC}"
echo ""
echo "  flux get all -A"
echo "  flux logs --all-namespaces"
echo "  kubectl get helmrelease -n flux-system"
echo ""
echo "  To upgrade Flux across ALL clusters: bump version in infrastructure/base/flux/helmrelease.yaml and push."
