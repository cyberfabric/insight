#!/usr/bin/env bash
# Quick restart of the Insight Kind cluster after WSL crash / Docker restart.
# If the cluster exists — restarts it and scales pods back to 1.
# If the cluster is gone — falls back to full up.sh + init.sh.
#
# Usage:
#   ./restart.sh                  # default: --env local
#   ./restart.sh --env virtuozzo  # remote env (just reconnect, no Kind)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

# ─── Parse --env (same as up.sh) ─────────────────────────────────────────
ENV_NAME="local"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)   ENV_NAME="$2"; shift 2 ;;
    --env=*) ENV_NAME="${1#*=}"; shift ;;
    *)       shift ;;
  esac
done

ENV_FILE="$ROOT_DIR/.env.${ENV_NAME}"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: env file not found: $ENV_FILE" >&2
  exit 1
fi
set -a; source "$ENV_FILE"; set +a

CLUSTER_MODE="${CLUSTER_MODE:-local}"
CLUSTER_NAME="${CLUSTER_NAME:-insight}"
NAMESPACE="${NAMESPACE:-insight}"

echo "═══════════════════════════════════════════════════════════════"
echo "  Insight Platform — Restart"
echo "  Environment: ${ENV_NAME}   (${CLUSTER_MODE})"
echo "═══════════════════════════════════════════════════════════════"

# ─── Remote mode: just verify connectivity ────────────────────────────────
if [[ "$CLUSTER_MODE" != "local" ]]; then
  echo "Remote cluster — verifying connectivity..."
  kubectl cluster-info --request-timeout=15s || { echo "ERROR: cannot reach cluster" >&2; exit 1; }
  echo "Cluster reachable. Run ./up.sh --env $ENV_NAME to redeploy."
  exit 0
fi

# ─── Local mode: Kind cluster ────────────────────────────────────────────
command -v kind &>/dev/null || { echo "ERROR: kind required" >&2; exit 1; }
KUBECONFIG_PATH="${KUBECONFIG:-${HOME}/.kube/insight.kubeconfig}"

# Clean up ghost containers from crashed sessions
echo "=== Cleaning up stale containers ==="
for c in $(docker ps -a --filter "status=exited" --filter "name=kind" --format '{{.Names}}' 2>/dev/null); do
  echo "  Removing dead container: $c"
  docker rm -f "$c" 2>/dev/null || true
done

# Check if cluster exists
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "=== Restarting Kind cluster '${CLUSTER_NAME}' ==="
  docker start "${CLUSTER_NAME}-control-plane" 2>/dev/null || true
  sleep 5

  kind export kubeconfig --name "${CLUSTER_NAME}" --kubeconfig "${KUBECONFIG_PATH}" 2>/dev/null || true
  export KUBECONFIG="${KUBECONFIG_PATH}"

  echo "  Waiting for API server..."
  if kubectl cluster-info --request-timeout=30s &>/dev/null; then
    echo "  Cluster is up. Scaling services back..."

    # Ingestion
    kubectl scale deployment/clickhouse -n data --replicas=1 2>/dev/null || true
    kubectl scale deployment -n argo --all --replicas=1 2>/dev/null || true
    kubectl scale statefulset -n airbyte --all --replicas=1 2>/dev/null || true
    kubectl scale deployment -n airbyte --all --replicas=1 2>/dev/null || true

    # App infra (MariaDB is a StatefulSet)
    kubectl scale statefulset -n "$NAMESPACE" --all --replicas=1 2>/dev/null || true
    kubectl scale deployment -n "$NAMESPACE" --all --replicas=1 2>/dev/null || true

    echo "  Waiting for key pods..."
    kubectl wait --for=condition=ready pod -l app=clickhouse -n data --timeout=120s 2>/dev/null \
      || echo "  WARNING: ClickHouse not ready"
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argo-workflows-server -n argo --timeout=120s 2>/dev/null \
      || echo "  WARNING: Argo not ready"
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=mariadb -n "$NAMESPACE" --timeout=120s 2>/dev/null \
      || echo "  WARNING: MariaDB not ready"

    # Clean up stale replication-job pods (Airbyte sync pods that didn't finish cleanly)
    kubectl delete pod -n airbyte --field-selector=status.phase!=Running --force 2>/dev/null || true

    # Ensure CoreDNS is patched (public DNS upstream — survives Kind restart normally,
    # but guard against manual edits / cluster-wide reset).
    if kubectl get configmap coredns -n kube-system -o yaml 2>/dev/null \
      | grep -q "forward . /etc/resolv.conf"; then
      echo "  Patching CoreDNS to use public DNS (8.8.8.8, 8.8.4.4)..."
      kubectl get configmap coredns -n kube-system -o yaml \
        | sed 's|forward \. /etc/resolv.conf|forward . 8.8.8.8 8.8.4.4|' \
        | kubectl apply -f - >/dev/null
      kubectl rollout restart deployment/coredns -n kube-system >/dev/null
    fi

    # Clean up stuck helm releases
    for ns_release in "airbyte:airbyte" "argo:argo-workflows"; do
      ns="${ns_release%%:*}"
      release="${ns_release##*:}"
      status=$(helm status "$release" -n "$ns" -o json 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('info',{}).get('status',''))" 2>/dev/null || true)
      if [[ "$status" == pending-* ]]; then
        echo "  Cleaning stuck helm release: $release ($status)"
        helm uninstall "$release" -n "$ns" --no-hooks 2>/dev/null || true
      fi
    done

    # Airbyte port-forward
    pkill -f 'port-forward.*airbyte' 2>/dev/null || true
    nohup kubectl -n airbyte port-forward svc/airbyte-airbyte-server-svc 8001:8001 >/dev/null 2>&1 &
    disown

    echo ""
    echo "=== Restart complete ==="
    echo "  KUBECONFIG: ${KUBECONFIG}"
    echo "  Frontend:   http://localhost:${INGRESS_HTTP_PORT:-8000}"
    echo "  API:        http://localhost:${INGRESS_HTTP_PORT:-8000}/api"
    echo "  Airbyte:    http://localhost:8001"
    echo "  Argo UI:    http://localhost:30500"
    echo "  ClickHouse: http://localhost:30123"
    exit 0
  fi

  echo "  Cluster not responding — will recreate."
  kind delete cluster --name "${CLUSTER_NAME}"
fi

# ─── Cluster gone — full setup ───────────────────────────────────────────
echo "=== Cluster not found — running full up.sh ==="
"$ROOT_DIR/up.sh" --env "$ENV_NAME"

# Run init if up.sh created a new cluster
if [[ -f "$ROOT_DIR/src/ingestion/run-init.sh" ]]; then
  echo ""
  echo "=== Running init (databases, connectors, connections)... ==="
  cd "$ROOT_DIR/src/ingestion"
  ./secrets/apply.sh 2>/dev/null || true
  ./run-init.sh
fi
