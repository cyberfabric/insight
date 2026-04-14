#!/bin/sh
set -e

# Inject runtime OIDC config into index.html if env vars are set
if [ -n "$OIDC_ISSUER" ] && [ -n "$OIDC_CLIENT_ID" ]; then
  CONFIG_SCRIPT="<script>window.__OIDC_CONFIG__={issuer_url:\"$OIDC_ISSUER\",client_id:\"$OIDC_CLIENT_ID\"}</script>"
  sed -i "s|</head>|${CONFIG_SCRIPT}</head>|" /usr/share/nginx/html/index.html
  echo "OIDC config injected: issuer=$OIDC_ISSUER client_id=$OIDC_CLIENT_ID"
fi

exec "$@"
