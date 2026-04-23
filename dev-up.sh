#!/usr/bin/env bash
# Insight platform — DEV bring-up from source.
#
# Use this when you work on the codebase: builds Docker images from src/,
# creates a local Kind cluster (or targets a dev-owned remote like virtuozzo),
# loads images into the cluster, and deploys all services.
#
# NOT for end-user installations. For customers / production-like installs
# from published chart artifacts, use:  deploy/scripts/install.sh
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
#   ./dev-up.sh                         # --env local, all components
#   ./dev-up.sh --env virtuozzo         # remote cluster, all components
#   ./dev-up.sh --env virtuozzo app     # backend + frontend only
#   ./dev-up.sh ingestion               # only ingestion (default env=local)
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

# ─── Image build (dev-only) ───────────────────────────────────────────────
# Для dev-цикла собираем контейнеры из src/ и грузим в Kind.
# Prod-клиенты используют уже опубликованные образы из ghcr.io.
image_ref() {
  local svc="$1"
  echo "${IMAGE_REGISTRY:+$IMAGE_REGISTRY/}insight-${svc}:${IMAGE_TAG}"
}

build_and_load_image() {
  local svc="$1" dockerfile="$2" ctx="${3:-src/backend/}"
  local full; full=$(image_ref "$svc")

  if [[ "$BUILD_IMAGES" == "true" ]]; then
    if [[ -n "$IMAGE_PLATFORM" ]]; then
      [[ -n "$IMAGE_REGISTRY" ]] || { echo "ERROR: IMAGE_PLATFORM requires IMAGE_REGISTRY" >&2; exit 1; }
      echo "  Building ${full} for ${IMAGE_PLATFORM} (buildx + push)..."
      docker buildx build --platform "$IMAGE_PLATFORM" -t "$full" -f "$dockerfile" --push "$ctx"
    else
      echo "  Building ${full}..."
      docker build -t "$full" -f "$dockerfile" "$ctx"
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

if [[ "$COMPONENT" == "all" || "$COMPONENT" == "app" || "$COMPONENT" == "backend" ]]; then
  echo "=== Building backend images ==="
  build_and_load_image analytics-api src/backend/services/analytics-api/Dockerfile
  build_and_load_image identity      src/backend/services/identity/Dockerfile
  build_and_load_image api-gateway   src/backend/services/api-gateway/Dockerfile
fi

if [[ "$COMPONENT" == "all" || "$COMPONENT" == "app" || "$COMPONENT" == "frontend" ]]; then
  # Frontend — всегда pull, билд происходит в insight-front репо.
  FE_REPO="${FE_IMAGE_REPOSITORY:-ghcr.io/cyberfabric/insight-front}"
  FE_TAG="${FE_IMAGE_TAG:-latest}"
  FE_IMAGE="${FE_REPO}:${FE_TAG}"
  echo "=== Pulling Frontend image ==="
  docker pull "$FE_IMAGE"
  [[ "$LOAD_IMAGES_INTO_KIND" == "true" ]] && kind load docker-image "$FE_IMAGE" --name "${CLUSTER_NAME}"
fi

# ─── Generate dev overrides for umbrella ──────────────────────────────────
# Канонический installer читает values.yaml умбрелы + наш override-файл.
# Здесь мы генерим override из env-переменных dev-up.sh (.env.<env>).
DEV_VALUES=$(mktemp)
trap 'rm -f "$DEV_VALUES"' EXIT

ANALYTICS_IMG=$(image_ref analytics-api)
IDENTITY_IMG=$(image_ref identity)
GATEWAY_IMG=$(image_ref api-gateway)

split_image() { printf '%s\n%s\n' "${1%:*}" "${1##*:}"; }
read -r GW_REPO GW_TAG_VAL < <(split_image "$GATEWAY_IMG" | tr '\n' ' ')
read -r AN_REPO AN_TAG_VAL < <(split_image "$ANALYTICS_IMG" | tr '\n' ' ')
read -r ID_REPO ID_TAG_VAL < <(split_image "$IDENTITY_IMG" | tr '\n' ' ')

cat > "$DEV_VALUES" <<EOF
# Auto-generated by dev-up.sh — do not edit (values derived from .env.${ENV_NAME})
apiGateway:
  image:
    repository: "${GW_REPO}"
    tag: "${GW_TAG_VAL}"
    pullPolicy: "${IMAGE_PULL_POLICY}"
  authDisabled: ${AUTH_DISABLED}
  oidc:
    existingSecret: "${OIDC_EXISTING_SECRET}"
    issuer: "${OIDC_ISSUER}"
    audience: "${OIDC_AUDIENCE}"
    clientId: "${OIDC_CLIENT_ID}"
    redirectUri: "${OIDC_REDIRECT_URI}"
  ingress:
    enabled: ${INGRESS_ENABLED}
    className: "${INGRESS_CLASS}"
  gateway:
    enableDocs: true
analyticsApi:
  image:
    repository: "${AN_REPO}"
    tag: "${AN_TAG_VAL}"
    pullPolicy: "${IMAGE_PULL_POLICY}"
identity:
  enabled: false
  image:
    repository: "${ID_REPO}"
    tag: "${ID_TAG_VAL}"
    pullPolicy: "${IMAGE_PULL_POLICY}"
frontend:
  image:
    repository: "${FE_REPO:-ghcr.io/cyberfabric/insight-front}"
    tag: "${FE_TAG:-latest}"
    pullPolicy: "${IMAGE_PULL_POLICY}"
  ingress:
    enabled: ${INGRESS_ENABLED}
    className: "${INGRESS_CLASS}"
EOF

if [[ -n "$IMAGE_PULL_SECRET" ]]; then
  cat >> "$DEV_VALUES" <<EOF
global:
  imagePullSecrets:
    - name: "${IMAGE_PULL_SECRET}"
EOF
fi

# ─── Delegate to canonical installers ─────────────────────────────────────
case "$COMPONENT" in
  all)
    INSIGHT_NAMESPACE="$NAMESPACE" \
      INSIGHT_VALUES="$DEV_VALUES" \
      "$ROOT_DIR/deploy/scripts/install.sh"
    ;;
  ingestion)
    "$ROOT_DIR/deploy/scripts/install-airbyte.sh"
    "$ROOT_DIR/deploy/scripts/install-argo.sh"
    ;;
  app|backend|frontend)
    # Umbrella разворачивает ВСЁ: infra + backend + frontend. Для backend-only
    # или frontend-only возможны точечные выключения через values, но на dev
    # проще оставить full deploy — helm upgrade идемпотентен.
    SKIP_AIRBYTE=1 SKIP_ARGO=1 \
      INSIGHT_NAMESPACE="$NAMESPACE" \
      INSIGHT_VALUES="$DEV_VALUES" \
      "$ROOT_DIR/deploy/scripts/install.sh"
    ;;
  infra)
    # Только зависимости (CH/MariaDB/Redis/Redpanda) — через umbrella
    # с выключенными app-service'ами.
    cat >> "$DEV_VALUES" <<EOF
apiGateway:  { enabled: false }
analyticsApi: { enabled: false }
identity:    { enabled: false }
frontend:    { enabled: false }
EOF
    SKIP_AIRBYTE=1 SKIP_ARGO=1 \
      INSIGHT_NAMESPACE="$NAMESPACE" \
      INSIGHT_VALUES="$DEV_VALUES" \
      "$ROOT_DIR/deploy/scripts/install-insight.sh"
    ;;
  *)
    echo "ERROR: unknown component: $COMPONENT (expected: all|ingestion|app|backend|frontend|infra)" >&2
    exit 1
    ;;
esac

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
