#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ENV="${ENV:-local}"
CLUSTER_NAME="ingestion"
KUBECONFIG_PATH="${KUBECONFIG:-${HOME}/.kube/ingestion.kubeconfig}"
TOOLBOX_IMAGE="${TOOLBOX_IMAGE:-insight-toolbox:local}"

echo "=== Environment: ${ENV} ==="

# --- Prerequisites ---
for cmd in kubectl helm docker; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: $cmd is required but not found" >&2
    exit 1
  fi
done

# --- Kind cluster (local only) ---
if [[ "$ENV" == "local" ]]; then
  if ! command -v kind &>/dev/null; then
    echo "ERROR: kind is required for local development" >&2
    exit 1
  fi

  if ! kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    echo "=== Creating Kind cluster ==="
    kind create cluster --config k8s/kind-config.yaml
  else
    # Restart stopped cluster container
    if ! docker ps --format '{{.Names}}' | grep -q "^${CLUSTER_NAME}-control-plane$"; then
      echo "=== Starting Kind cluster ==="
      docker start "${CLUSTER_NAME}-control-plane"
      sleep 5
    else
      echo "=== Kind cluster '${CLUSTER_NAME}' already running ==="
    fi
  fi

  KUBECONFIG_PATH="$(kind get kubeconfig-path --name "${CLUSTER_NAME}" 2>/dev/null || echo "${HOME}/.kube/kind-${CLUSTER_NAME}")"
  kind export kubeconfig --name "${CLUSTER_NAME}" --kubeconfig "${KUBECONFIG_PATH}" 2>/dev/null || true
fi

export KUBECONFIG="${KUBECONFIG_PATH}"
echo "  KUBECONFIG=${KUBECONFIG}"

# --- Build toolbox image ---
echo "=== Building toolbox image ==="
TOOLBOX_IMAGE="$TOOLBOX_IMAGE" ./tools/toolbox/build.sh

# --- Namespaces ---
echo "=== Creating namespaces ==="
for ns in airbyte argo data; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

# --- Secret checks ---
# Track what's missing so we can report at the end
MISSING=()

has_secret() {
  kubectl get secret "$1" -n "$2" &>/dev/null
}

# --- Ingress controller (local only) ---
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

# --- Airbyte (no user Secret required — Helm creates internal auth secrets) ---
echo "=== Deploying Airbyte ==="
helm repo add airbyte https://airbytehq.github.io/helm-charts 2>/dev/null || true
helm repo update airbyte
# Scale up DB + minio before helm upgrade (bootloader needs them)
kubectl scale statefulset -n airbyte --all --replicas=1 2>/dev/null || true
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=db -n airbyte --timeout=60s 2>/dev/null || true
# Clean up bootloader pod from previous run (blocks helm upgrade)
kubectl delete pod airbyte-airbyte-bootloader -n airbyte --force --grace-period=0 2>/dev/null || true
helm upgrade --install airbyte airbyte/airbyte \
  --namespace airbyte \
  --values "k8s/airbyte/values-${ENV}.yaml" \
  --wait --timeout 10m
# Scale up if previously stopped by down.sh
kubectl scale deployment -n airbyte --all --replicas=1 2>/dev/null || true
kubectl scale statefulset -n airbyte --all --replicas=1 2>/dev/null || true

# --- Copy Airbyte auth secret to argo namespace (for JWT minting in workflow steps) ---
echo "=== Syncing Airbyte auth secret to argo namespace ==="
if kubectl get secret airbyte-auth-secrets -n airbyte &>/dev/null; then
  kubectl get secret airbyte-auth-secrets -n airbyte -o json \
    | python3 -c "import sys,json; s=json.load(sys.stdin); print(json.dumps({'apiVersion':'v1','kind':'Secret','type':'Opaque','metadata':{'name':'airbyte-auth-secrets','namespace':'argo'},'data':s['data']}))" \
    | kubectl apply -f -
else
  echo "  WARNING: airbyte-auth-secrets not found in airbyte namespace (Airbyte may still be starting)"
fi

# --- ClickHouse (requires clickhouse-credentials Secret) ---
if has_secret clickhouse-credentials data; then
  echo "=== Deploying ClickHouse ==="
  kubectl apply -f k8s/clickhouse/
  kubectl scale deployment/clickhouse -n data --replicas=1 2>/dev/null || true
else
  echo "=== SKIP: ClickHouse — Secret 'clickhouse-credentials' not found in namespace 'data' ==="
  echo "  Create it:"
  echo "    kubectl create secret generic clickhouse-credentials -n data --from-literal=password='YOUR_PASSWORD'"
  echo "  Or copy and apply the example:"
  echo "    cp secrets/clickhouse.yaml.example secrets/clickhouse.yaml"
  echo "    kubectl apply -f secrets/clickhouse.yaml -n data"
  echo "    kubectl apply -f secrets/clickhouse.yaml -n argo"
  MISSING+=("clickhouse-credentials (namespace: data)")
fi

# --- Argo Workflows (no user Secret required for server auth-mode) ---
echo "=== Deploying Argo Workflows ==="
helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo update argo
helm upgrade --install argo-workflows argo/argo-workflows \
  --namespace argo \
  --values "k8s/argo/values-${ENV}.yaml" \
  --wait --timeout 5m
kubectl scale deployment -n argo --all --replicas=1 2>/dev/null || true

# --- Argo RBAC ---
echo "=== Applying Argo RBAC ==="
kubectl apply -f k8s/argo/rbac.yaml

# --- WorkflowTemplates ---
echo "=== Applying WorkflowTemplates ==="
kubectl apply -f workflows/templates/

# --- Wait for services that were deployed ---
echo "=== Waiting for services ==="
if has_secret clickhouse-credentials data; then
  kubectl wait --for=condition=ready pod -l app=clickhouse -n data --timeout=120s
fi
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argo-workflows-server -n argo --timeout=120s

# --- Airbyte port-forward for local access ---
if [[ "$ENV" == "local" ]]; then
  echo "=== Starting Airbyte port-forward ==="
  pkill -f 'port-forward.*airbyte' 2>/dev/null || true
  kubectl -n airbyte port-forward svc/airbyte-airbyte-server-svc 8000:8001 >/dev/null 2>&1 &
fi

# --- Summary ---
echo ""
echo "════════════════════════════════════════════════"
echo "  KUBECONFIG: ${KUBECONFIG}"
echo "  To use:     export KUBECONFIG=${KUBECONFIG}"
echo ""

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "  ⚠ Missing secrets:"
  for m in "${MISSING[@]}"; do
    echo "    - $m"
  done
  echo ""
  echo "  Create the missing secrets and re-run ./up.sh"
  echo "  Or use: ./secrets/apply.sh"
else
  echo "  Services:"
  echo "    Airbyte:    http://localhost:8000"
  echo "    Argo UI:    http://localhost:30500"
  echo "    ClickHouse: http://localhost:30123"
  echo ""
  echo "  All services deployed. Next step:"
  echo "    ./run-init.sh"
fi
echo "════════════════════════════════════════════════"
