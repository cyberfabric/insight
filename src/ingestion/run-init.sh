#!/usr/bin/env bash
# Initialize the ingestion stack: create databases, register connectors, apply connections, sync workflows.
# Run AFTER: ./up.sh && ./secrets/apply.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

TOOLBOX_IMAGE="${TOOLBOX_IMAGE:-insight-toolbox:local}"

# --- Verify secrets exist ---
echo "=== Verifying secrets ==="
if ! kubectl get secret clickhouse-credentials -n data &>/dev/null; then
  echo "ERROR: clickhouse-credentials Secret not found in namespace 'data'" >&2
  echo "  Run: ./secrets/apply.sh" >&2
  exit 1
fi

# --- Create dedicated ServiceAccount with minimal RBAC ---
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ingestion-init
  namespace: data
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ingestion-init
  namespace: data
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list"]
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list", "create", "update", "patch"]
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get"]
  - apiGroups: [""]
    resources: ["pods", "pods/exec"]
    verbs: ["get", "create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ingestion-init
  namespace: data
subjects:
  - kind: ServiceAccount
    name: ingestion-init
    namespace: data
roleRef:
  kind: Role
  name: ingestion-init
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ingestion-init-airbyte
  namespace: airbyte
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ingestion-init-airbyte
  namespace: airbyte
subjects:
  - kind: ServiceAccount
    name: ingestion-init
    namespace: data
roleRef:
  kind: Role
  name: ingestion-init-airbyte
  apiGroup: rbac.authorization.k8s.io
EOF

# --- Run init job ---
echo "=== Running init job ==="
kubectl delete job ingestion-init -n data --ignore-not-found 2>/dev/null

TOOLBOX_IMAGE="${TOOLBOX_IMAGE:-ghcr.io/cyberfabric/insight-toolbox:latest}"

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
      serviceAccountName: ingestion-init
      restartPolicy: Never
      containers:
        - name: init
          image: ${TOOLBOX_IMAGE}
          imagePullPolicy: IfNotPresent
          command: [bash, /ingestion/scripts/init.sh]
          env:
            - name: KUBECONFIG
              value: ""
            - name: AIRBYTE_API
              value: "http://airbyte-airbyte-server-svc.airbyte.svc.cluster.local:8001"
            - name: CLICKHOUSE_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: clickhouse-credentials
                  key: password
EOF

echo "  Waiting for init job..."
kubectl wait --for=condition=complete job/ingestion-init -n data --timeout=300s 2>&1 || {
  echo "  Init job failed. Logs:" >&2
  kubectl logs job/ingestion-init -n data --tail=50 2>&1 || true
  exit 1
}

echo "=== Init complete ==="
