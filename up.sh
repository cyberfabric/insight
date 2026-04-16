#!/usr/bin/env bash
# Insight platform — bring up all services in a local Kind cluster.
#
# Components:
#   1. Kind cluster + ingress-nginx
#   2. Ingestion (Airbyte, ClickHouse, Argo)
#   3. Backend  (Analytics API, Identity Resolution, API Gateway)
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

# ─── Load .env.local (OIDC credentials, overrides) ─────────────────────────
ENV_FILE="$ROOT_DIR/.env.local"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$ENV_FILE"
fi

: "${OIDC_ISSUER:?ERROR: OIDC_ISSUER is required — set it in .env.local}"
: "${OIDC_CLIENT_ID:?ERROR: OIDC_CLIENT_ID is required — set it in .env.local}"
OIDC_REDIRECT_URI="${OIDC_REDIRECT_URI:-http://localhost:8000/callback}"
OIDC_AUDIENCE="${OIDC_AUDIENCE:-api://default}"

# Timestamp to force pod restarts when image tag doesn't change
DEPLOY_TS="$(date +%s)"

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

  echo "=== Building Analytics API ==="
  docker build -t insight-analytics-api:local \
    -f src/backend/services/analytics-api/Dockerfile \
    src/backend/

  if [[ "$ENV" == "local" ]]; then
    kind load docker-image insight-analytics-api:local --name "${CLUSTER_NAME}"
  fi

  echo "=== Deploying Analytics API ==="
  helm upgrade --install insight-analytics src/backend/services/analytics-api/helm/ \
    --namespace insight \
    --set image.repository=insight-analytics-api \
    --set image.tag=local \
    --set image.pullPolicy=IfNotPresent \
    --set database.url="mysql://insight:insight-pass@insight-mariadb:3306/analytics" \
    --set clickhouse.url="http://clickhouse.data.svc.cluster.local:8123" \
    --set clickhouse.database=insight \
    --set redis.url="redis://insight-redis-master:6379" \
    --set identityResolution.url="http://insight-identity-identity-resolution:8082" \
    --set-string podAnnotations.deployedAt="$DEPLOY_TS" \
    --wait --timeout 3m

  echo "=== Building Identity Resolution ==="
  docker build -t insight-identity:local \
    -f src/backend/services/identity/Dockerfile \
    src/backend/

  if [[ "$ENV" == "local" ]]; then
    kind load docker-image insight-identity:local --name "${CLUSTER_NAME}"
  fi

  echo "=== Deploying Identity Resolution ==="
  helm upgrade --install insight-identity src/backend/services/identity/helm/ \
    --namespace insight \
    --set image.repository=insight-identity \
    --set image.tag=local \
    --set image.pullPolicy=IfNotPresent \
    --set clickhouse.url="http://clickhouse.data.svc.cluster.local:8123" \
    --set clickhouse.database=insight \
    --set clickhouse.user="${CLICKHOUSE_USER:-insight}" \
    --set clickhouse.password="${CLICKHOUSE_PASSWORD:-}" \
    --set-string podAnnotations.deployedAt="$DEPLOY_TS" \
    --wait --timeout 3m

  echo "=== Deploying API Gateway ==="
  GW_HELM_ARGS=(
    --namespace insight
    --set image.repository=insight-api-gateway
    --set image.tag=local
    --set image.pullPolicy=IfNotPresent
    --set ingress.enabled=false
    --set gateway.enableDocs=true
    --set oidc.issuer="$OIDC_ISSUER"
    --set oidc.audience="$OIDC_AUDIENCE"
    --set oidc.clientId="$OIDC_CLIENT_ID"
    --set oidc.redirectUri="$OIDC_REDIRECT_URI"
    --set proxy.routes[0].prefix=/analytics
    --set proxy.routes[0].upstream=http://insight-analytics-analytics-api:8081
    --set proxy.routes[0].public=false
    --set proxy.routes[1].prefix=/identity-resolution
    --set proxy.routes[1].upstream=http://insight-identity-identity-resolution:8082
    --set proxy.routes[1].public=false
    --set-string podAnnotations.deployedAt="$DEPLOY_TS"
    --wait --timeout 3m
  )
  if [[ "$ENV" == "local" ]]; then
    GW_HELM_ARGS+=(--set authDisabled=true)
  fi
  helm upgrade --install insight-gw src/backend/services/api-gateway/helm/ "${GW_HELM_ARGS[@]}"
fi

# ─── Frontend ────────────────────────────────────────────────────────────────
if [[ "$COMPONENT" == "all" || "$COMPONENT" == "app" || "$COMPONENT" == "frontend" ]]; then
  FE_IMAGE="ghcr.io/cyberfabric/insight-front:latest"
  echo "=== Pulling Frontend image ==="
  docker pull "$FE_IMAGE"
  if [[ "$ENV" == "local" ]]; then
    kind load docker-image "$FE_IMAGE" --name "${CLUSTER_NAME}"
  fi

  echo "=== Deploying Frontend ==="
  helm upgrade --install insight-fe src/frontend/helm/ \
    --namespace insight \
    --set image.pullPolicy=IfNotPresent \
    --set ingress.enabled=false \
    --set oidc.issuer="$OIDC_ISSUER" \
    --set oidc.clientId="$OIDC_CLIENT_ID" \
    --set-string podAnnotations.deployedAt="$DEPLOY_TS" \
    --wait --timeout 3m
fi

# ─── Airbyte port-forward (local only) ──────────────────────────────────────
if [[ "$ENV" == "local" && ("$COMPONENT" == "all" || "$COMPONENT" == "ingestion") ]]; then
  echo "=== Starting Airbyte port-forward ==="
  pkill -f 'port-forward.*airbyte' 2>/dev/null || true
  kubectl -n airbyte port-forward svc/airbyte-airbyte-server-svc 8001:8001 >/dev/null 2>&1 &
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════"
echo "  KUBECONFIG: ${KUBECONFIG}"
echo "  To use:     export KUBECONFIG=${KUBECONFIG}"
echo ""
echo "  Services:"
echo "    Frontend:   http://localhost:8000"
echo "    API:        http://localhost:8000/api"
echo "    Analytics:  http://localhost:8000/api/analytics/v1/metrics (via gateway)"
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
