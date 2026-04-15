#!/usr/bin/env bash
# Insight platform — bring up all services in a local Kind cluster.
#
# Components:
#   1. Kind cluster + ingress-nginx
#   2. Ingestion (Airbyte, ClickHouse, Argo)
#   3. Backend  (API Gateway)
#   4. Frontend (SPA)
#
# Usage:
#   ./up.sh              # full stack
#   ./up.sh ingestion    # only ingestion services
#   ./up.sh app          # only backend + frontend
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

ENV="${ENV:-local}"
CLUSTER_NAME="insight"
KUBECONFIG_PATH="${KUBECONFIG:-${HOME}/.kube/insight.kubeconfig}"
COMPONENT="${1:-all}"

echo "=== Insight Platform — Environment: ${ENV} ==="

# --- Prerequisites ---
for cmd in kubectl helm docker; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: $cmd is required but not found" >&2
    exit 1
  fi
done

# ─── Kind cluster (local only) ───────────────────────────────────────────────
if [[ "$ENV" == "local" ]]; then
  if ! command -v kind &>/dev/null; then
    echo "ERROR: kind is required for local development" >&2
    exit 1
  fi

  if ! kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    echo "=== Creating Kind cluster '${CLUSTER_NAME}' ==="
    kind create cluster --config k8s/kind-config.yaml
  else
    if ! docker ps --format '{{.Names}}' | grep -q "^${CLUSTER_NAME}-control-plane$"; then
      echo "=== Starting Kind cluster ==="
      docker start "${CLUSTER_NAME}-control-plane"
      sleep 5
    else
      echo "=== Kind cluster '${CLUSTER_NAME}' already running ==="
    fi
  fi

  KUBECONFIG_PATH="$(kind get kubeconfig-path --name "${CLUSTER_NAME}" 2>/dev/null || echo "${HOME}/.kube/insight.kubeconfig")"
  kind export kubeconfig --name "${CLUSTER_NAME}" --kubeconfig "${KUBECONFIG_PATH}" 2>/dev/null || true
fi

export KUBECONFIG="${KUBECONFIG_PATH}"
echo "  KUBECONFIG=${KUBECONFIG}"

# ─── Ingress controller (local only) ─────────────────────────────────────────
if [[ "$ENV" == "local" ]]; then
  echo "=== Installing ingress-nginx ==="
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
  helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace ingress-nginx --create-namespace \
    --set controller.hostPort.enabled=true \
    --set controller.service.type=ClusterIP \
    --set controller.watchIngressWithoutClass=true \
    --wait --timeout 3m
fi

# ─── Namespace for app services ──────────────────────────────────────────────
kubectl create namespace insight --dry-run=client -o yaml | kubectl apply -f -

# ─── Ingestion ───────────────────────────────────────────────────────────────
if [[ "$COMPONENT" == "all" || "$COMPONENT" == "ingestion" ]]; then
  "$ROOT_DIR/src/ingestion/up.sh"
fi

# ─── Backend (API Gateway) ───────────────────────────────────────────────────
if [[ "$COMPONENT" == "all" || "$COMPONENT" == "app" || "$COMPONENT" == "backend" ]]; then
  echo "=== Building API Gateway ==="
  docker build -t insight-api-gateway:local \
    -f src/backend/services/api-gateway/Dockerfile \
    src/backend/

  if [[ "$ENV" == "local" ]]; then
    kind load docker-image insight-api-gateway:local --name "${CLUSTER_NAME}"
  fi

  echo "=== Deploying API Gateway ==="
  GW_HELM_ARGS=(
    --namespace insight
    --set image.repository=insight-api-gateway
    --set image.tag=local
    --set image.pullPolicy=IfNotPresent
    --wait --timeout 3m
  )
  if [[ "$ENV" == "local" ]]; then
    GW_HELM_ARGS+=(--set authDisabled=true --set ingress.host="" --set gateway.enableDocs=true)
  fi
  helm upgrade --install insight-gw src/backend/services/api-gateway/helm/ "${GW_HELM_ARGS[@]}"
fi

# ─── Frontend ────────────────────────────────────────────────────────────────
if [[ "$COMPONENT" == "all" || "$COMPONENT" == "app" || "$COMPONENT" == "frontend" ]]; then
  FRONTEND_DIR="$ROOT_DIR/insight-front_symlink"
  if [[ ! -d "$FRONTEND_DIR" ]]; then
    echo "WARNING: Frontend directory not found at $FRONTEND_DIR — skipping"
  else
    echo "=== Building Frontend ==="
    docker build -t insight-frontend:local \
      -f src/frontend/Dockerfile \
      "$FRONTEND_DIR"

    if [[ "$ENV" == "local" ]]; then
      kind load docker-image insight-frontend:local --name "${CLUSTER_NAME}"
    fi

    echo "=== Deploying Frontend ==="
    helm upgrade --install insight-fe src/frontend/helm/ \
      --namespace insight \
      --set image.pullPolicy=IfNotPresent \
      --wait --timeout 3m
  fi
fi

# ─── Airbyte port-forward (local only) ──────────────────────────────────────
if [[ "$ENV" == "local" && ("$COMPONENT" == "all" || "$COMPONENT" == "ingestion") ]]; then
  echo "=== Starting Airbyte port-forward ==="
  pkill -f 'port-forward.*airbyte' 2>/dev/null || true
  nohup kubectl -n airbyte port-forward svc/airbyte-airbyte-server-svc 8001:8001 >/dev/null 2>&1 &
  disown
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════"
echo "  KUBECONFIG: ${KUBECONFIG}"
echo "  To use:     export KUBECONFIG=${KUBECONFIG}"
echo ""
echo "  Services:"
echo "    Frontend:   http://localhost:8000"
echo "    API:        http://localhost:8000/api/v1"
echo "    Airbyte:    http://localhost:8001"
echo "    Argo UI:    http://localhost:30500"
echo "    ClickHouse: http://localhost:30123"
# Show Airbyte UI credentials hint (don't print password to logs)
if kubectl get secret airbyte-auth-secrets -n airbyte &>/dev/null; then
  echo ""
  echo "  Airbyte UI login:"
  echo "    Email:    admin@example.com"
  echo "    Password: kubectl get secret airbyte-auth-secrets -n airbyte -o jsonpath='{.data.instance-admin-password}' | base64 -d"
fi
echo ""
echo "  Next steps:"
echo "    cd src/ingestion && ./run-init.sh"
echo "════════════════════════════════════════════════"
