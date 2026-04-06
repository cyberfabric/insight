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

# --- Airbyte ---
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

# --- ClickHouse ---
echo "=== Deploying ClickHouse ==="
kubectl apply -f k8s/clickhouse/
kubectl scale deployment/clickhouse -n data --replicas=1 2>/dev/null || true

# --- Argo Workflows ---
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

# --- Wait for services ---
echo "=== Waiting for services ==="
kubectl wait --for=condition=ready pod -l app=clickhouse -n data --timeout=120s
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argo-workflows-server -n argo --timeout=120s

# --- ClickHouse init ---
echo "=== Initializing ClickHouse ==="
kubectl exec -n data deploy/clickhouse -- \
  clickhouse-client --password clickhouse \
  --query "CREATE DATABASE IF NOT EXISTS silver" 2>/dev/null || true

# --- Run init inside cluster via toolbox ---
echo "=== Initializing (toolbox job) ==="
kubectl delete job ingestion-init -n data --ignore-not-found 2>/dev/null

# Grant toolbox access to airbyte secrets + argo resources
kubectl create clusterrolebinding toolbox-admin \
  --clusterrole=cluster-admin \
  --serviceaccount=data:default \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ingestion-init
  namespace: data
spec:
  backoffLimit: 1
  ttlSecondsAfterFinished: 300
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: init
          image: ${TOOLBOX_IMAGE}
          imagePullPolicy: Never
          command: [bash, /ingestion/scripts/init.sh]
          env:
            - name: KUBECONFIG
              value: ""
            - name: AIRBYTE_API
              value: "http://airbyte-airbyte-server-svc.airbyte.svc.cluster.local:8001"
EOF

echo "  Waiting for init job..."
kubectl wait --for=condition=complete job/ingestion-init -n data --timeout=300s 2>&1 || {
  echo "  Init job failed. Logs:" >&2
  kubectl logs job/ingestion-init -n data --tail=30 2>&1 || true
  echo "  (continuing — you can re-run init manually)" >&2
}

# --- Airbyte port-forward for local access ---
echo "=== Starting Airbyte port-forward ==="
pkill -f 'port-forward.*airbyte' 2>/dev/null || true
kubectl -n airbyte port-forward svc/airbyte-airbyte-server-svc 8000:8001 >/dev/null 2>&1 &

echo "=== Ready ==="
echo ""
echo "KUBECONFIG: ${KUBECONFIG}"
echo "To use:     export KUBECONFIG=${KUBECONFIG}"
echo ""
echo "Services:"
echo "  Airbyte:    http://localhost:8000"
echo "  Argo UI:    http://localhost:30500"
echo "  ClickHouse: http://localhost:30123  (user: default, password: clickhouse)"
echo ""
echo "Airbyte credentials:"
echo "  Email:    admin@example.com"
echo "  Password: $(kubectl get secret -n airbyte airbyte-auth-secrets -o jsonpath='{.data.instance-admin-password}' | base64 -d 2>/dev/null || echo 'unknown')"
