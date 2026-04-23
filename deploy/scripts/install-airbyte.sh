#!/usr/bin/env bash
#
# Install/upgrade Airbyte as a standalone Helm release.
#
# Idempotent: re-running does `helm upgrade` with the same values.
#
# Environment overrides:
#   AIRBYTE_NAMESPACE  (default: airbyte)
#   AIRBYTE_RELEASE    (default: airbyte)
#   AIRBYTE_VERSION    (default: 1.5.1)
#   AIRBYTE_VALUES     (default: deploy/airbyte/values.yaml)
#   EXTRA_VALUES_FILE  additional -f values.yaml (for prod overrides)
#
# Usage:
#   ./deploy/scripts/install-airbyte.sh
#   EXTRA_VALUES_FILE=deploy/airbyte/values-prod.yaml ./deploy/scripts/install-airbyte.sh
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

NAMESPACE="${AIRBYTE_NAMESPACE:-airbyte}"
RELEASE="${AIRBYTE_RELEASE:-airbyte}"
VERSION="${AIRBYTE_VERSION:-1.5.1}"
VALUES="${AIRBYTE_VALUES:-deploy/airbyte/values.yaml}"
EXTRA="${EXTRA_VALUES_FILE:-}"

log() { printf '\033[36m[install-airbyte]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[install-airbyte] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ─── Prerequisites ─────────────────────────────────────────────────────
command -v helm      >/dev/null || die "helm not found"
command -v kubectl   >/dev/null || die "kubectl not found"
[[ -f "$VALUES" ]]                || die "values file not found: $VALUES"
[[ -z "$EXTRA" || -f "$EXTRA" ]]  || die "extra values file not found: $EXTRA"

log "Cluster: $(kubectl config current-context)"
log "Namespace: $NAMESPACE · Release: $RELEASE · Chart: airbyte/airbyte@$VERSION"

# ─── Repo ──────────────────────────────────────────────────────────────
if ! helm repo list 2>/dev/null | grep -q '^airbyte\s'; then
  log "Adding Airbyte helm repo"
  helm repo add airbyte https://airbytehq.github.io/helm-charts
fi
helm repo update airbyte >/dev/null

# ─── Install / upgrade ─────────────────────────────────────────────────
VALUES_ARGS=(-f "$VALUES")
[[ -n "$EXTRA" ]] && VALUES_ARGS+=(-f "$EXTRA")

log "Running helm upgrade --install"
helm upgrade --install "$RELEASE" airbyte/airbyte \
  --namespace "$NAMESPACE" --create-namespace \
  --version "$VERSION" \
  "${VALUES_ARGS[@]}" \
  --wait --timeout 15m

# ─── JWT secret mirror ─────────────────────────────────────────────────
# Ingestion WorkflowTemplates работают в namespace `insight` и подписывают
# JWT для Airbyte API. Зеркалим airbyte-auth-secrets из airbyte-ns в
# insight-ns под ТЕМ ЖЕ именем/ключом (jwt-signature-secret) — это имя
# и ключ, которые Airbyte-чарт создаёт сам, и которые зашиты в шаблонах.
#
# Идемпотентно: пересоздаёт при каждом запуске (секрет может ротироваться
# между версиями Airbyte).
log "Mirroring Airbyte auth secret to Insight namespace"
INSIGHT_NS="${INSIGHT_NAMESPACE:-insight}"
kubectl create namespace "$INSIGHT_NS" --dry-run=client -o yaml | kubectl apply -f -

if kubectl -n "$NAMESPACE" get secret airbyte-auth-secrets >/dev/null 2>&1; then
  JWT_B64=$(kubectl -n "$NAMESPACE" get secret airbyte-auth-secrets \
    -o jsonpath='{.data.jwt-signature-secret}' 2>/dev/null)
  if [[ -n "$JWT_B64" ]]; then
    kubectl -n "$INSIGHT_NS" apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: airbyte-auth-secrets
type: Opaque
data:
  jwt-signature-secret: $JWT_B64
EOF
    log "Mirrored: $INSIGHT_NS/airbyte-auth-secrets"
  else
    log "WARNING: jwt-signature-secret key missing in airbyte-auth-secrets"
  fi
else
  log "WARNING: airbyte-auth-secrets not found in airbyte namespace yet."
  log "         Rerun this script after Airbyte finishes booting."
fi

# ─── Summary ───────────────────────────────────────────────────────────
cat <<EOF

✓ Airbyte installed.

Verify:
  kubectl -n $NAMESPACE get pods
  kubectl -n $NAMESPACE port-forward svc/$RELEASE-airbyte-webapp-svc 8080:80
  # then open http://localhost:8080

API reachable at:
  http://$RELEASE-airbyte-server-svc.$NAMESPACE.svc.cluster.local:8001

Insight will use JWT secret: $INSIGHT_NS/airbyte-auth-secrets (key: jwt-signature-secret)

Next step:
  ./deploy/scripts/install-insight.sh

EOF
