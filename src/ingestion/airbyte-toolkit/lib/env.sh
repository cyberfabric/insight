#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Airbyte Toolkit — Environment resolver
#
# Auto-detects host vs in-cluster runtime.
# Resolves Airbyte API URL, JWT token, workspace ID.
#
# Usage: source airbyte-toolkit/lib/env.sh
# Exports: AIRBYTE_API, AIRBYTE_TOKEN, WORKSPACE_ID
# ---------------------------------------------------------------------------

set -euo pipefail

# All Insight components share a single namespace (default: insight).
# Override with INSIGHT_NAMESPACE=... for non-default installs.
_ns="${INSIGHT_NAMESPACE:-insight}"

# Auto-detect runtime
if [[ -f /var/run/secrets/kubernetes.io/serviceaccount/token ]]; then
  export AIRBYTE_API="${AIRBYTE_API:-http://airbyte-airbyte-server-svc.${_ns}.svc.cluster.local:8001}"
else
  export AIRBYTE_API="${AIRBYTE_API:-http://localhost:8001}"
fi

# Read Airbyte auth secrets from the Insight namespace (single-namespace model)
_secret_json=$(kubectl get secret -n "$_ns" airbyte-auth-secrets -o json 2>/dev/null) || {
  echo "ERROR: cannot read airbyte-auth-secrets from namespace $_ns" >&2
  return 1 2>/dev/null || exit 1
}

_jwt_secret=$(echo "$_secret_json" | python3 -c "import sys,json,base64; print(base64.b64decode(json.load(sys.stdin)['data']['jwt-signature-secret']).decode())")

# Mint JWT token (short-lived, 5 minutes)
export AIRBYTE_TOKEN=$(node -e "
  const c=require('crypto');
  const h=Buffer.from(JSON.stringify({alg:'HS256',typ:'JWT'})).toString('base64url');
  const n=Math.floor(Date.now()/1000);
  const p=Buffer.from(JSON.stringify({iss:'airbyte-server',sub:'00000000-0000-0000-0000-000000000000',iat:n,exp:n+300})).toString('base64url');
  const s=c.createHmac('sha256','${_jwt_secret}').update(h+'.'+p).digest('base64url');
  console.log(h+'.'+p+'.'+s);
")

# Resolve workspace ID
export WORKSPACE_ID=$(curl -sf -H "Authorization: Bearer $AIRBYTE_TOKEN" \
  "${AIRBYTE_API}/api/v1/workspaces/list_by_organization_id" \
  -X POST -H "Content-Type: application/json" \
  -d '{"organizationId":"00000000-0000-0000-0000-000000000000"}' \
  | python3 -c "
import sys,json
ws = json.load(sys.stdin).get('workspaces',[])
print(ws[0]['workspaceId'] if ws else '')
" 2>/dev/null)

if [[ -z "$WORKSPACE_ID" ]]; then
  echo "ERROR: no Airbyte workspace found" >&2
  return 1 2>/dev/null || exit 1
fi

echo "  Workspace: $WORKSPACE_ID" >&2

unset _secret_json _jwt_secret _ns
