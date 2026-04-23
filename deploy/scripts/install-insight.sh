#!/usr/bin/env bash
#
# Install/upgrade Insight umbrella chart.
#
# Предполагает, что Airbyte уже стоит (иначе ingestion-сервисы не работают).
# Запускай ПОСЛЕ install-airbyte.sh или параллельно с ним.
#
# Environment overrides:
#   INSIGHT_NAMESPACE  (default: insight)
#   INSIGHT_RELEASE    (default: insight)
#   INSIGHT_VERSION    (default: auto — читает Chart.yaml)
#   INSIGHT_VALUES     дополнительные -f values.yaml (для кастомизации)
#   CHART_SOURCE       local | oci   (default: local — path к charts/insight)
#   OCI_REF            OCI-ссылка на чарт (по умолчанию oci://ghcr.io/cyberfabric/charts/insight)
#
# Usage:
#   ./deploy/scripts/install-insight.sh
#   INSIGHT_VALUES=deploy/prod-values.yaml ./deploy/scripts/install-insight.sh
#   CHART_SOURCE=oci INSIGHT_VERSION=0.2.0 ./deploy/scripts/install-insight.sh
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

NAMESPACE="${INSIGHT_NAMESPACE:-insight}"
RELEASE="${INSIGHT_RELEASE:-insight}"
CHART_SOURCE="${CHART_SOURCE:-local}"
OCI_REF="${OCI_REF:-oci://ghcr.io/cyberfabric/charts/insight}"
EXTRA_VALUES="${INSIGHT_VALUES:-}"

log() { printf '\033[36m[install-insight]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[install-insight] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ─── Resolve chart reference ──────────────────────────────────────────
case "$CHART_SOURCE" in
  local)
    CHART_REF="./charts/insight"
    [[ -f "$CHART_REF/Chart.yaml" ]] || die "local chart not found: $CHART_REF"
    log "Ensuring subchart dependencies"
    helm dependency update "$CHART_REF" >/dev/null
    # auto-detect version if not set
    VERSION="${INSIGHT_VERSION:-$(grep '^version:' "$CHART_REF/Chart.yaml" | awk '{print $2}')}"
    VERSION_ARG=()
    ;;
  oci)
    [[ -n "${INSIGHT_VERSION:-}" ]] || die "INSIGHT_VERSION required for CHART_SOURCE=oci"
    VERSION="$INSIGHT_VERSION"
    CHART_REF="$OCI_REF"
    VERSION_ARG=(--version "$VERSION")
    ;;
  *)
    die "unknown CHART_SOURCE: $CHART_SOURCE (expected: local | oci)"
    ;;
esac

# ─── Prerequisites ─────────────────────────────────────────────────────
command -v helm    >/dev/null || die "helm not found"
command -v kubectl >/dev/null || die "kubectl not found"

log "Cluster: $(kubectl config current-context)"
log "Namespace: $NAMESPACE · Release: $RELEASE · Chart: $CHART_REF@$VERSION"

# ─── Check Airbyte is reachable (warning only) ─────────────────────────
AIRBYTE_SVC="airbyte-airbyte-server-svc.airbyte.svc.cluster.local"
if ! kubectl -n airbyte get svc airbyte-airbyte-server-svc >/dev/null 2>&1; then
  log "WARNING: Airbyte not detected in 'airbyte' namespace."
  log "         Ingestion workflows will fail until Airbyte is installed."
  log "         Run: ./deploy/scripts/install-airbyte.sh"
fi

# ─── Install / upgrade ─────────────────────────────────────────────────
VALUES_ARGS=()
[[ -n "$EXTRA_VALUES" ]] && VALUES_ARGS+=(-f "$EXTRA_VALUES")

log "Running helm upgrade --install"
helm upgrade --install "$RELEASE" "$CHART_REF" \
  --namespace "$NAMESPACE" --create-namespace \
  "${VERSION_ARG[@]}" \
  "${VALUES_ARGS[@]}" \
  --wait --timeout 10m

# ─── Summary ───────────────────────────────────────────────────────────
cat <<EOF

✓ Insight installed.

Verify:
  kubectl -n $NAMESPACE rollout status deploy --timeout=5m

Access:
  kubectl -n $NAMESPACE port-forward svc/$RELEASE-frontend 8080:80
  # then open http://localhost:8080

EOF
