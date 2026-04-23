#!/usr/bin/env bash
#
# Top-level installer: Airbyte → Argo Workflows → Insight.
#
# Это UX-обёртка: для пользователя "одна команда ставит весь стек",
# а под капотом — три последовательных helm release в разных namespace'ах.
#
# Идемпотентно: безопасно запускать повторно.
#
# Usage:
#   ./deploy/scripts/install.sh
#
# Environment:
#   SKIP_AIRBYTE=1   — если Airbyte уже установлен или управляется отдельно
#   SKIP_ARGO=1      — если Argo Workflows уже установлен
#   SKIP_INSIGHT=1   — установить только инфру (без umbrella)
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '\033[32m[install]\033[0m %s\n' "$*"; }

if [[ "${SKIP_AIRBYTE:-0}" == "1" ]]; then
  log "SKIP_AIRBYTE=1 → пропускаем Airbyte"
else
  log "Step 1/3: Airbyte"
  "$ROOT_DIR/install-airbyte.sh"
fi

if [[ "${SKIP_ARGO:-0}" == "1" ]]; then
  log "SKIP_ARGO=1 → пропускаем Argo Workflows"
else
  log "Step 2/3: Argo Workflows"
  "$ROOT_DIR/install-argo.sh"
fi

if [[ "${SKIP_INSIGHT:-0}" == "1" ]]; then
  log "SKIP_INSIGHT=1 → пропускаем Insight"
else
  log "Step 3/3: Insight"
  "$ROOT_DIR/install-insight.sh"
fi

cat <<'EOF'

╔════════════════════════════════════════════════════════════════════════╗
║   All done.                                                            ║
║                                                                        ║
║   Airbyte UI:    kubectl -n airbyte  port-forward svc/airbyte-airbyte-webapp-svc 8080:80
║   Insight UI:    kubectl -n insight  port-forward svc/insight-frontend 8081:80
║                                                                        ║
║   Open http://localhost:8081 in your browser.                          ║
╚════════════════════════════════════════════════════════════════════════╝

EOF
