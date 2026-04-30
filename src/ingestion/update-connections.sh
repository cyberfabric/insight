#!/usr/bin/env bash
set -euo pipefail

# Apply tenant connection configs against the running Airbyte instance.
#
# Required env (no defaults — set explicitly so cross-cluster mistakes
# fail loudly instead of writing to the wrong cluster):
#   KUBECONFIG          path to the insight cluster kubeconfig
#   INSIGHT_NAMESPACE   release namespace of the umbrella chart
#
# Args:
#   <tenant_name>       optional; if omitted, processes every connections/*.yaml
: "${KUBECONFIG:?must be set, e.g. export KUBECONFIG=~/.kube/insight.kubeconfig}"
: "${INSIGHT_NAMESPACE:?must be set to the umbrella release namespace, e.g. export INSIGHT_NAMESPACE=insight}"
export KUBECONFIG INSIGHT_NAMESPACE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

TENANT="${1:-}"
echo "=== Updating connections ==="

if [[ -n "$TENANT" ]]; then
  ./airbyte-toolkit/connect.sh "$TENANT"
else
  ./airbyte-toolkit/connect.sh --all
fi

echo "=== Done ==="
