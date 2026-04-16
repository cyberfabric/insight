#!/usr/bin/env bash
# Insight platform — bring up all services in a Kubernetes cluster.
#
# Environment is selected with --env <name>. Configuration for each environment
# lives in .env.<name> at the repo root. See .env.local.example for the full
# contract.
#
# Components:
#   1. Cluster bootstrap (Kind create / external kubeconfig)
#   2. Ingress controller (optional, driven by INGRESS_INSTALL)
#   3. Ingestion (Airbyte, ClickHouse, Argo)
#   4. Backend (Analytics API, Identity Resolution, API Gateway)
#   5. Frontend (SPA)
#
# Usage:
#   ./up.sh                         # --env local, all components
#   ./up.sh --env virtuozzo         # remote cluster, all components
#   ./up.sh --env virtuozzo app     # backend + frontend only
#   ./up.sh ingestion               # only ingestion (default env=local)
#
# Valid components: all | ingestion | app | backend | frontend
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

# ─── Argument parsing ─────────────────────────────────────────────────────
ENV_NAME="local"
COMPONENT="all"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      ENV_NAME="$2"
      shift 2
      ;;
    --env=*)
      ENV_NAME="${1#*=}"
      shift
      ;;
    -h|--help)
      grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      COMPONENT="$1"
      shift
      ;;
  esac
done

# ─── Load environment config ──────────────────────────────────────────────
ENV_FILE="$ROOT_DIR/.env.${ENV_NAME}"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: env file not found: $ENV_FILE" >&2
  echo "       Copy .env.${ENV_NAME}.example to .env.${ENV_NAME} and fill it in." >&2
  exit 1
fi
# shellcheck source=/dev/null
set -a
source "$ENV_FILE"
set +a

# ─── Defaults (env file may override) ─────────────────────────────────────
CLUSTER_MODE="${CLUSTER_MODE:-local}"           # local | remote
CLUSTER_NAME="${CLUSTER_NAME:-insight}"
NAMESPACE="${NAMESPACE:-insight}"

IMAGE_REGISTRY="${IMAGE_REGISTRY:-}"            # empty = local-only images
IMAGE_TAG="${IMAGE_TAG:-local}"
IMAGE_PULL_POLICY="${IMAGE_PULL_POLICY:-IfNotPresent}"
IMAGE_PULL_SECRET="${IMAGE_PULL_SECRET:-}"
IMAGE_PLATFORM="${IMAGE_PLATFORM:-}"            # e.g., linux/amd64. Empty = native.
BUILD_IMAGES="${BUILD_IMAGES:-true}"
BUILD_AND_PUSH="${BUILD_AND_PUSH:-false}"
LOAD_IMAGES_INTO_KIND="${LOAD_IMAGES_INTO_KIND:-auto}"   # auto = yes iff CLUSTER_MODE=local

INGRESS_INSTALL="${INGRESS_INSTALL:-false}"
INGRESS_CLASS="${INGRESS_CLASS:-nginx}"
INGRESS_ENABLED="${INGRESS_ENABLED:-false}"     # chart-level ingress resource
INGRESS_MODE="${INGRESS_MODE:-hostPort}"        # hostPort | nodePort
INGRESS_HTTP_PORT="${INGRESS_HTTP_PORT:-80}"
INGRESS_HTTPS_PORT="${INGRESS_HTTPS_PORT:-443}"

AUTH_DISABLED="${AUTH_DISABLED:-false}"
OIDC_EXISTING_SECRET="${OIDC_EXISTING_SECRET:-}"
OIDC_ISSUER="${OIDC_ISSUER:-}"
OIDC_CLIENT_ID="${OIDC_CLIENT_ID:-}"
OIDC_REDIRECT_URI="${OIDC_REDIRECT_URI:-}"
OIDC_AUDIENCE="${OIDC_AUDIENCE:-api://default}"

DEPLOY_TS="$(date +%s)"

# ─── Sanity ───────────────────────────────────────────────────────────────
if [[ "$AUTH_DISABLED" != "true" && -z "$OIDC_EXISTING_SECRET" ]]; then
  : "${OIDC_ISSUER:?ERROR: OIDC_ISSUER is required — set it in $ENV_FILE or use OIDC_EXISTING_SECRET}"
  : "${OIDC_CLIENT_ID:?ERROR: OIDC_CLIENT_ID is required — set it in $ENV_FILE or use OIDC_EXISTING_SECRET}"
  OIDC_REDIRECT_URI="${OIDC_REDIRECT_URI:-http://localhost:8000/callback}"
fi

echo "═══════════════════════════════════════════════════════════════"
echo "  Insight Platform"
echo "  Environment: ${ENV_NAME}   (${CLUSTER_MODE})"
echo "  Component:   ${COMPONENT}"
echo "  Namespace:   ${NAMESPACE}"
echo "  Image:       ${IMAGE_REGISTRY:-<local>}/insight-*:${IMAGE_TAG}"
echo "═══════════════════════════════════════════════════════════════"

for cmd in kubectl helm docker; do
  command -v "$cmd" &>/dev/null || { echo "ERROR: $cmd required" >&2; exit 1; }
done

# ─── Cluster bootstrap ────────────────────────────────────────────────────
if [[ "$CLUSTER_MODE" == "local" ]]; then
  command -v kind &>/dev/null || { echo "ERROR: kind required for CLUSTER_MODE=local" >&2; exit 1; }
  KUBECONFIG_PATH="${KUBECONFIG:-${HOME}/.kube/insight.kubeconfig}"
  if ! kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    echo "=== Creating Kind cluster '${CLUSTER_NAME}' ==="
    kind create cluster --config k8s/kind-config.yaml
  elif ! docker ps --format '{{.Names}}' | grep -q "^${CLUSTER_NAME}-control-plane$"; then
    echo "=== Starting Kind cluster ==="
    docker start "${CLUSTER_NAME}-control-plane"
    sleep 5
  fi
  kind export kubeconfig --name "${CLUSTER_NAME}" --kubeconfig "${KUBECONFIG_PATH}" 2>/dev/null || true
  export KUBECONFIG="${KUBECONFIG_PATH}"
else
  # remote: KUBECONFIG must already be set via env file or shell
  : "${KUBECONFIG:?ERROR: KUBECONFIG must be set for CLUSTER_MODE=remote (set it in $ENV_FILE)}"
  if [[ "$KUBECONFIG" != /* ]]; then
    KUBECONFIG="$ROOT_DIR/$KUBECONFIG"
  fi
  [[ -f "$KUBECONFIG" ]] || { echo "ERROR: kubeconfig not found: $KUBECONFIG" >&2; exit 1; }
  export KUBECONFIG
fi
echo "  KUBECONFIG=${KUBECONFIG}"

# Resolve whether to load images into Kind
if [[ "$LOAD_IMAGES_INTO_KIND" == "auto" ]]; then
  [[ "$CLUSTER_MODE" == "local" ]] && LOAD_IMAGES_INTO_KIND=true || LOAD_IMAGES_INTO_KIND=false
fi

# ─── Ingress controller ───────────────────────────────────────────────────
if [[ "$INGRESS_INSTALL" == "true" ]]; then
  echo "=== Installing ingress-nginx (${INGRESS_MODE}) ==="
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
  helm repo update ingress-nginx >/dev/null
  INGRESS_ARGS=(
    --namespace ingress-nginx --create-namespace
    --set controller.watchIngressWithoutClass=true
    --set controller.ingressClassResource.default=true
  )
  case "$INGRESS_MODE" in
    hostPort)
      INGRESS_ARGS+=(
        --set controller.kind=DaemonSet
        --set controller.hostPort.enabled=true
        --set controller.hostPort.ports.http="$INGRESS_HTTP_PORT"
        --set controller.hostPort.ports.https="$INGRESS_HTTPS_PORT"
        --set controller.service.type=ClusterIP
      )
      ;;
    nodePort)
      INGRESS_ARGS+=(
        --set controller.service.type=NodePort
        --set controller.service.nodePorts.http="$INGRESS_HTTP_PORT"
        --set controller.service.nodePorts.https="$INGRESS_HTTPS_PORT"
      )
      ;;
    *)
      echo "ERROR: unknown INGRESS_MODE: $INGRESS_MODE (hostPort|nodePort)" >&2
      exit 1
      ;;
  esac
  helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    "${INGRESS_ARGS[@]}" --wait --timeout 5m
fi

# ─── Namespace ────────────────────────────────────────────────────────────
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# ─── Ingestion ────────────────────────────────────────────────────────────
if [[ "$COMPONENT" == "all" || "$COMPONENT" == "ingestion" ]]; then
  ENV="$ENV_NAME" "$ROOT_DIR/src/ingestion/up.sh"
fi

# ─── App-level infra (redis) ──────────────────────────────────────────────
# Plain Deployment + Service. Cache only — no persistence, no auth.
# (Using redis:7-alpine from Docker Hub; bitnami/redis chart images moved
# behind a paywall in 2025 and no longer pull freely.)
if [[ "$COMPONENT" == "all" || "$COMPONENT" == "app" || "$COMPONENT" == "infra" ]]; then
  if [[ "${DEPLOY_REDIS:-false}" == "true" ]]; then
    echo "=== Deploying Redis ==="
    kubectl apply -n "$NAMESPACE" -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: insight-redis-master
  labels: {app.kubernetes.io/name: redis, app.kubernetes.io/instance: insight-redis}
spec:
  replicas: 1
  selector:
    matchLabels: {app.kubernetes.io/name: redis, app.kubernetes.io/instance: insight-redis}
  template:
    metadata:
      labels: {app.kubernetes.io/name: redis, app.kubernetes.io/instance: insight-redis}
    spec:
      containers:
        - name: redis
          image: redis:7-alpine
          args: ["redis-server", "--appendonly", "no", "--save", ""]
          ports:
            - name: tcp-redis
              containerPort: 6379
          readinessProbe:
            tcpSocket: {port: tcp-redis}
            initialDelaySeconds: 2
            periodSeconds: 5
          resources:
            requests: {cpu: 50m, memory: 32Mi}
            limits:   {cpu: 200m, memory: 128Mi}
---
apiVersion: v1
kind: Service
metadata:
  name: insight-redis-master
  labels: {app.kubernetes.io/name: redis, app.kubernetes.io/instance: insight-redis}
spec:
  type: ClusterIP
  selector: {app.kubernetes.io/name: redis, app.kubernetes.io/instance: insight-redis}
  ports:
    - name: tcp-redis
      port: 6379
      targetPort: tcp-redis
EOF
    kubectl rollout status deployment/insight-redis-master -n "$NAMESPACE" --timeout=2m
  fi
fi

# ─── Backend ──────────────────────────────────────────────────────────────
image_ref() {
  local svc="$1"
  echo "${IMAGE_REGISTRY:+$IMAGE_REGISTRY/}insight-${svc}:${IMAGE_TAG}"
}

build_and_load_image() {
  local svc="$1" dockerfile="$2"
  local full; full=$(image_ref "$svc")

  if [[ "$BUILD_IMAGES" == "true" ]]; then
    if [[ -n "$IMAGE_PLATFORM" ]]; then
      # Cross-platform build via buildx. For non-native platforms, buildx cannot
      # load the result into the local docker image store — we push directly.
      if [[ -z "$IMAGE_REGISTRY" ]]; then
        echo "ERROR: IMAGE_PLATFORM set but IMAGE_REGISTRY is empty — cross-platform build needs a registry to push to" >&2
        exit 1
      fi
      echo "  Building ${full} for ${IMAGE_PLATFORM} (buildx + push)..."
      docker buildx build --platform "$IMAGE_PLATFORM" \
        -t "$full" -f "$dockerfile" --push src/backend/
    else
      echo "  Building ${full}..."
      docker build -t "$full" -f "$dockerfile" src/backend/
      if [[ -n "$IMAGE_REGISTRY" && "$BUILD_AND_PUSH" == "true" ]]; then
        echo "  Pushing ${full}..."
        docker push "$full"
      fi
    fi
  fi
  if [[ "$LOAD_IMAGES_INTO_KIND" == "true" ]]; then
    echo "  Loading ${full} into Kind..."
    kind load docker-image "$full" --name "${CLUSTER_NAME}"
  fi
}

helm_image_args() {
  local full="$1"
  local repo="${full%:*}"
  local tag="${full##*:}"
  printf -- '--set image.repository=%s --set image.tag=%s --set image.pullPolicy=%s' \
    "$repo" "$tag" "$IMAGE_PULL_POLICY"
  if [[ -n "$IMAGE_PULL_SECRET" ]]; then
    printf -- ' --set imagePullSecrets[0].name=%s' "$IMAGE_PULL_SECRET"
  fi
}

if [[ "$COMPONENT" == "all" || "$COMPONENT" == "app" || "$COMPONENT" == "backend" ]]; then
  build_and_load_image analytics-api src/backend/services/analytics-api/Dockerfile
  build_and_load_image identity       src/backend/services/identity/Dockerfile
  build_and_load_image api-gateway    src/backend/services/api-gateway/Dockerfile
  ANALYTICS_IMG=$(image_ref analytics-api)
  IDENTITY_IMG=$(image_ref identity)
  GATEWAY_IMG=$(image_ref api-gateway)

  # ── Service wiring (env-configurable) ───────────────────────────────
  ANALYTICS_DB_URL="${ANALYTICS_DB_URL:-mysql://insight:insight-pass@insight-mariadb:3306/analytics}"
  CLICKHOUSE_URL="${CLICKHOUSE_URL:-http://clickhouse.data.svc.cluster.local:8123}"
  CLICKHOUSE_DB="${CLICKHOUSE_DB:-insight}"
  CLICKHOUSE_CREDENTIALS_SECRET="${CLICKHOUSE_CREDENTIALS_SECRET:-}"
  CLICKHOUSE_CREDENTIALS_USER_KEY="${CLICKHOUSE_CREDENTIALS_USER_KEY:-username}"
  CLICKHOUSE_CREDENTIALS_PASSWORD_KEY="${CLICKHOUSE_CREDENTIALS_PASSWORD_KEY:-password}"
  # Inline fallback: only used when CLICKHOUSE_CREDENTIALS_SECRET is empty
  CLICKHOUSE_USER="${CLICKHOUSE_USER:-default}"
  CLICKHOUSE_PASSWORD="${CLICKHOUSE_PASSWORD:-}"
  REDIS_URL="${REDIS_URL:-redis://insight-redis-master:6379}"
  IDENTITY_URL="${IDENTITY_URL:-http://insight-identity-identity-resolution:8082}"

  # Build --set args for ClickHouse credentials: prefer secretRef
  CH_CREDS_ARGS=()
  if [[ -n "$CLICKHOUSE_CREDENTIALS_SECRET" ]]; then
    CH_CREDS_ARGS+=(
      --set clickhouse.credentialsSecret.name="$CLICKHOUSE_CREDENTIALS_SECRET"
      --set clickhouse.credentialsSecret.userKey="$CLICKHOUSE_CREDENTIALS_USER_KEY"
      --set clickhouse.credentialsSecret.passwordKey="$CLICKHOUSE_CREDENTIALS_PASSWORD_KEY"
      --set clickhouse.user=
      --set clickhouse.password=
    )
  else
    CH_CREDS_ARGS+=(
      --set clickhouse.user="$CLICKHOUSE_USER"
      --set clickhouse.password="$CLICKHOUSE_PASSWORD"
    )
  fi

  echo "=== Deploying Analytics API ==="
  # shellcheck disable=SC2046
  helm upgrade --install insight-analytics src/backend/services/analytics-api/helm/ \
    --namespace "$NAMESPACE" \
    $(helm_image_args "$ANALYTICS_IMG") \
    --set database.url="$ANALYTICS_DB_URL" \
    --set clickhouse.url="$CLICKHOUSE_URL" \
    --set clickhouse.database="$CLICKHOUSE_DB" \
    "${CH_CREDS_ARGS[@]}" \
    --set redis.url="$REDIS_URL" \
    --set identityResolution.url="$IDENTITY_URL" \
    --set-string podAnnotations.deployedAt="$DEPLOY_TS" \
    --wait --timeout 3m

  echo "=== Deploying Identity Resolution ==="
  # shellcheck disable=SC2046
  helm upgrade --install insight-identity src/backend/services/identity/helm/ \
    --namespace "$NAMESPACE" \
    $(helm_image_args "$IDENTITY_IMG") \
    --set clickhouse.url="$CLICKHOUSE_URL" \
    --set clickhouse.database="$CLICKHOUSE_DB" \
    "${CH_CREDS_ARGS[@]}" \
    --set-string podAnnotations.deployedAt="$DEPLOY_TS" \
    --wait --timeout 3m

  echo "=== Deploying API Gateway ==="
  GW_ARGS=(
    --namespace "$NAMESPACE"
    --set ingress.enabled="$INGRESS_ENABLED"
    --set ingress.className="$INGRESS_CLASS"
    --set gateway.enableDocs=true
    --set authDisabled="$AUTH_DISABLED"
    --set proxy.routes[0].prefix=/analytics
    --set proxy.routes[0].upstream=http://insight-analytics-analytics-api:8081
    --set proxy.routes[0].public=false
    --set proxy.routes[1].prefix=/identity-resolution
    --set proxy.routes[1].upstream=http://insight-identity-identity-resolution:8082
    --set proxy.routes[1].public=false
    --set-string podAnnotations.deployedAt="$DEPLOY_TS"
  )
  # shellcheck disable=SC2206
  GW_ARGS+=( $(helm_image_args "$GATEWAY_IMG") )
  if [[ "$AUTH_DISABLED" != "true" ]]; then
    if [[ -n "$OIDC_EXISTING_SECRET" ]]; then
      GW_ARGS+=( --set oidc.existingSecret="$OIDC_EXISTING_SECRET" )
    else
      GW_ARGS+=(
        --set oidc.issuer="$OIDC_ISSUER"
        --set oidc.audience="$OIDC_AUDIENCE"
        --set oidc.clientId="$OIDC_CLIENT_ID"
        --set oidc.redirectUri="$OIDC_REDIRECT_URI"
      )
    fi
  fi
  helm upgrade --install insight-gw src/backend/services/api-gateway/helm/ "${GW_ARGS[@]}" --wait --timeout 3m
fi

# ─── Frontend ─────────────────────────────────────────────────────────────
if [[ "$COMPONENT" == "all" || "$COMPONENT" == "app" || "$COMPONENT" == "frontend" ]]; then
  FE_REPO="${FE_IMAGE_REPOSITORY:-ghcr.io/cyberfabric/insight-front}"
  FE_TAG="${FE_IMAGE_TAG:-latest}"
  FE_IMAGE="${FE_REPO}:${FE_TAG}"

  echo "=== Pulling Frontend image ==="
  docker pull "$FE_IMAGE"
  if [[ "$LOAD_IMAGES_INTO_KIND" == "true" ]]; then
    kind load docker-image "$FE_IMAGE" --name "${CLUSTER_NAME}"
  fi

  echo "=== Deploying Frontend ==="
  FE_ARGS=(
    --namespace "$NAMESPACE"
    --set image.repository="$FE_REPO"
    --set image.tag="$FE_TAG"
    --set image.pullPolicy="$IMAGE_PULL_POLICY"
    --set ingress.enabled="$INGRESS_ENABLED"
    --set ingress.className="$INGRESS_CLASS"
    --set-string podAnnotations.deployedAt="$DEPLOY_TS"
  )
  if [[ -n "$IMAGE_PULL_SECRET" ]]; then
    FE_ARGS+=( --set "imagePullSecrets[0].name=$IMAGE_PULL_SECRET" )
  fi
  helm upgrade --install insight-fe src/frontend/helm/ "${FE_ARGS[@]}" --wait --timeout 3m
fi

# ─── Airbyte port-forward (local only) ────────────────────────────────────
if [[ "$CLUSTER_MODE" == "local" && ("$COMPONENT" == "all" || "$COMPONENT" == "ingestion") ]]; then
  echo "=== Starting Airbyte port-forward ==="
  pkill -f 'port-forward.*airbyte' 2>/dev/null || true
  kubectl -n airbyte port-forward svc/airbyte-airbyte-server-svc 8001:8001 >/dev/null 2>&1 &
fi

# ─── Summary ──────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  KUBECONFIG: ${KUBECONFIG}"
if [[ "$CLUSTER_MODE" == "local" ]]; then
  echo "  Frontend:   http://localhost:${INGRESS_HTTP_PORT:-8000}"
  echo "  API:        http://localhost:${INGRESS_HTTP_PORT:-8000}/api"
  echo "  Airbyte:    http://localhost:8001"
  echo "  Argo UI:    http://localhost:30500"
  echo "  ClickHouse: http://localhost:30123"
else
  echo "  Access via VPN-reachable node IP on port ${INGRESS_HTTP_PORT}"
fi
if kubectl get secret airbyte-auth-secrets -n airbyte &>/dev/null; then
  echo ""
  echo "  Airbyte UI login:"
  echo "    Email:    admin@example.com"
  echo "    Password: kubectl get secret airbyte-auth-secrets -n airbyte -o jsonpath='{.data.instance-admin-password}' | base64 -d"
fi
echo "═══════════════════════════════════════════════════════════════"
