#!/usr/bin/env bash
# Resolves Airbyte credentials and workspace from K8s secrets.
# Sources this file to set environment variables:
#   AIRBYTE_TOKEN, AIRBYTE_CLIENT_ID, AIRBYTE_CLIENT_SECRET, WORKSPACE_ID
#
# Usage: source ./scripts/resolve-airbyte-env.sh

set -euo pipefail

# KUBECONFIG can be empty when running in-cluster (uses service account)

# Auto-detect: use in-cluster service URL if running in K8s, else localhost
if [[ -f /var/run/secrets/kubernetes.io/serviceaccount/token ]]; then
  export AIRBYTE_API="${AIRBYTE_API:-http://airbyte-airbyte-server-svc.airbyte.svc.cluster.local:8001}"
else
  export AIRBYTE_API="${AIRBYTE_API:-http://localhost:8000}"
fi

# Read secrets
_secret_json=$(kubectl get secret -n airbyte airbyte-auth-secrets -o json 2>/dev/null) || {
  echo "ERROR: cannot read airbyte-auth-secrets" >&2
  return 1 2>/dev/null || exit 1
}

export AIRBYTE_CLIENT_ID=$(echo "$_secret_json" | python3 -c "import sys,json,base64; print(base64.b64decode(json.load(sys.stdin)['data']['instance-admin-client-id']).decode())")
export AIRBYTE_CLIENT_SECRET=$(echo "$_secret_json" | python3 -c "import sys,json,base64; print(base64.b64decode(json.load(sys.stdin)['data']['instance-admin-client-secret']).decode())")

_jwt_secret=$(echo "$_secret_json" | python3 -c "import sys,json,base64; print(base64.b64decode(json.load(sys.stdin)['data']['jwt-signature-secret']).decode())")

export AIRBYTE_TOKEN=$(node -e "
  const c=require('crypto');
  const h=Buffer.from(JSON.stringify({alg:'HS256',typ:'JWT'})).toString('base64url');
  const n=Math.floor(Date.now()/1000);
  const p=Buffer.from(JSON.stringify({iss:'airbyte-server',sub:'00000000-0000-0000-0000-000000000000',iat:n,exp:n+300})).toString('base64url');
  const s=c.createHmac('sha256','${_jwt_secret}').update(h+'.'+p).digest('base64url');
  console.log(h+'.'+p+'.'+s);
")

# Resolve workspace — use the default workspace created by Helm chart
export WORKSPACE_ID=$(curl -sf -H "Authorization: Bearer $AIRBYTE_TOKEN" \
  "${AIRBYTE_API}/api/v1/workspaces/list_by_organization_id" \
  -X POST -H "Content-Type: application/json" \
  -d '{"organizationId":"00000000-0000-0000-0000-000000000000"}' \
  | python3 -c "
import sys,json
ws = json.load(sys.stdin).get('workspaces',[])
# Pick the first workspace (created by Helm chart on install)
print(ws[0]['workspaceId'] if ws else '')
" 2>/dev/null)

if [[ -z "$WORKSPACE_ID" ]]; then
  echo "ERROR: no Airbyte workspace found" >&2
  return 1 2>/dev/null || exit 1
fi
echo "  Workspace: $WORKSPACE_ID" >&2

# Resolve m365 source definition ID (if registered)
export M365_DEFINITION_ID=$(curl -sf -H "Authorization: Bearer $AIRBYTE_TOKEN" \
  "${AIRBYTE_API}/api/v1/source_definitions/list" \
  -X POST -H "Content-Type: application/json" \
  -d "{\"workspaceId\":\"$WORKSPACE_ID\"}" \
  | python3 -c "
import sys,json
for d in json.load(sys.stdin).get('sourceDefinitions',[]):
    if 'm365' in d['name'].lower():
        print(d['sourceDefinitionId'])
        break
" 2>/dev/null) || true

unset _secret_json _jwt_secret
