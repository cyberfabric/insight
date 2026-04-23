#!/usr/bin/env bash
#
# Install/upgrade Argo Workflows as a standalone Helm release.
#
# Устанавливает инфраструктуру для ingestion-pipelines.
# WorkflowTemplates (airbyte-sync/dbt-run/ingestion-pipeline) поставляются
# отдельно через umbrella-чарт Insight — см. values.ingestion.templates.enabled.
#
# Environment overrides:
#   ARGO_NAMESPACE     (default: argo)
#   ARGO_RELEASE       (default: argo-workflows)
#   ARGO_VERSION       (default: 0.45.16)
#   ARGO_VALUES        (default: deploy/argo/values.yaml)
#   ARGO_RBAC          (default: deploy/argo/rbac.yaml)
#   EXTRA_VALUES_FILE  additional -f file (для prod-оверрайдов)
#
# Usage:
#   ./deploy/scripts/install-argo.sh
#   EXTRA_VALUES_FILE=deploy/argo/values-prod.yaml ./deploy/scripts/install-argo.sh
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

NAMESPACE="${ARGO_NAMESPACE:-argo}"
RELEASE="${ARGO_RELEASE:-argo-workflows}"
VERSION="${ARGO_VERSION:-0.45.16}"
VALUES="${ARGO_VALUES:-deploy/argo/values.yaml}"
RBAC="${ARGO_RBAC:-deploy/argo/rbac.yaml}"
EXTRA="${EXTRA_VALUES_FILE:-}"

log() { printf '\033[36m[install-argo]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[install-argo] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ─── Prerequisites ─────────────────────────────────────────────────────
command -v helm    >/dev/null || die "helm not found"
command -v kubectl >/dev/null || die "kubectl not found"
[[ -f "$VALUES" ]]                || die "values file not found: $VALUES"
[[ -f "$RBAC" ]]                  || die "rbac file not found: $RBAC"
[[ -z "$EXTRA" || -f "$EXTRA" ]]  || die "extra values file not found: $EXTRA"

log "Cluster: $(kubectl config current-context)"
log "Namespace: $NAMESPACE · Release: $RELEASE · Chart: argo/argo-workflows@$VERSION"

# ─── Repo ──────────────────────────────────────────────────────────────
if ! helm repo list 2>/dev/null | grep -q '^argo\s'; then
  log "Adding argo helm repo"
  helm repo add argo https://argoproj.github.io/argo-helm
fi
helm repo update argo >/dev/null

# ─── Pre-create namespaces (RBAC ссылается на ns 'insight') ────────────
for ns in argo insight; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
done

# ─── Install / upgrade ─────────────────────────────────────────────────
VALUES_ARGS=(-f "$VALUES")
[[ -n "$EXTRA" ]] && VALUES_ARGS+=(-f "$EXTRA")

log "Running helm upgrade --install"
helm upgrade --install "$RELEASE" argo/argo-workflows \
  --namespace "$NAMESPACE" --create-namespace \
  --version "$VERSION" \
  "${VALUES_ARGS[@]}" \
  --wait --timeout 5m

# ─── Apply supplemental RBAC ───────────────────────────────────────────
log "Applying supplemental RBAC"
kubectl apply -f "$RBAC"

# ─── Summary ───────────────────────────────────────────────────────────
cat <<EOF

✓ Argo Workflows installed.

Verify:
  kubectl -n $NAMESPACE get pods
  kubectl -n $NAMESPACE port-forward svc/$RELEASE-server 2746:2746
  # then open http://localhost:2746

Insight WorkflowTemplates will be deployed by the umbrella chart
(ingestion.templates.enabled=true) into 'insight' namespace.

Next step:
  ./deploy/scripts/install-insight.sh

EOF
