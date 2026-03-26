#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Local declarative-connector runner
#
# Runs Airbyte declarative manifest connectors in Docker without the full
# Airbyte platform. Useful for rapid manifest development and validation.
#
# Usage:
#   ./source.sh check   <class>/<connector>
#   ./source.sh discover <class>/<connector>
#   ./source.sh read     <class>/<connector> <connection>
#
# Example:
#   ./source.sh check   collaboration/m365
#   ./source.sh discover collaboration/m365
#   ./source.sh read     collaboration/m365 dev
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONNECTORS_DIR="${SCRIPT_DIR}/../../connectors"

# Load global overrides (image tags, etc.) if present
GLOBAL_ENV_FILE="${SCRIPT_DIR}/.env.local"
if [[ -f "${GLOBAL_ENV_FILE}" ]]; then
  set -a; source "${GLOBAL_ENV_FILE}"; set +a
fi

IMAGE="${AIRBYTE_CONNECTOR_IMAGE:-airbyte/source-declarative-manifest:local}"
BASE_IMAGE="${AIRBYTE_BASE_IMAGE:-airbyte/source-declarative-manifest:latest}"
COMMAND_NAME="${AIRBYTE_COMMAND:-source-declarative-manifest}"
SECRETS_TMPFS_OPTS="${AIRBYTE_SECRETS_TMPFS_OPTS:-/secrets:rw,mode=1777}"

usage() {
  cat >&2 <<EOF
Usage:
  $0 validate <class>/<connector>
  $0 check    <class>/<connector>
  $0 discover <class>/<connector>
  $0 read     <class>/<connector> <connection>

Commands:
  validate  Validate manifest structure (no credentials needed)
  check     Validate manifest + credentials against source API
  discover  List available streams and their schemas
  read      Extract data (outputs Airbyte Protocol JSON to stdout)

Arguments:
  <class>/<connector>  Path relative to connectors/ (e.g. collaboration/m365)
  <connection>         Connection profile name (subdirectory of connections/)

Environment:
  Connector credentials must be in connectors/<class>/<connector>/.env.local
  as AIRBYTE_CONFIG='{"tenant_id":"...","client_id":"...",...}'

Examples:
  $0 check   collaboration/m365
  $0 discover collaboration/m365
  $0 read     collaboration/m365 dev
EOF
}

# --- Argument parsing ---
command="${1:-}"
connector="${2:-}"

if [[ -z "${command}" || -z "${connector}" ]]; then
  usage
  exit 1
fi

connector_dir="${CONNECTORS_DIR}/${connector}"
manifest_path="${connector_dir}/connector.yaml"
env_file="${connector_dir}/.env.local"

# --- Validate inputs ---
if [[ ! -d "${connector_dir}" ]]; then
  echo "ERROR: Connector directory not found: ${connector_dir}" >&2
  echo "Available connectors:" >&2
  find "${CONNECTORS_DIR}" -name "connector.yaml" -exec dirname {} \; 2>/dev/null | \
    sed "s|${CONNECTORS_DIR}/||" | sort >&2
  exit 1
fi

if [[ ! -f "${manifest_path}" ]]; then
  echo "ERROR: Connector manifest not found: ${manifest_path}" >&2
  exit 1
fi

# --- Load credentials (skip for validate) ---
if [[ "${command}" != "validate" ]]; then
  if [[ ! -f "${env_file}" ]]; then
    echo "ERROR: Credentials file not found: ${env_file}" >&2
    if [[ -f "${connector_dir}/example.env.local" ]]; then
      echo "  Copy the template: cp ${connector_dir}/example.env.local ${env_file}" >&2
    else
      echo "  Create ${env_file} with: AIRBYTE_CONFIG='{\"tenant_id\":\"...\"}'" >&2
    fi
    exit 1
  fi
  AIRBYTE_CONFIG=$(grep '^AIRBYTE_CONFIG=' "${env_file}" | head -1 | sed "s/^AIRBYTE_CONFIG=//; s/^'//; s/'$//")
  if [[ -z "${AIRBYTE_CONFIG:-}" ]]; then
    echo "ERROR: AIRBYTE_CONFIG is not set in ${env_file}" >&2
    exit 1
  fi
  if ! echo "${AIRBYTE_CONFIG}" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
    echo "ERROR: AIRBYTE_CONFIG is not valid JSON" >&2
    exit 1
  fi
fi

# --- Build wrapper image if missing ---
if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
  echo "Building connector image (${IMAGE})..." >&2
  docker build \
    --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
    --build-arg "AIRBYTE_COMMAND=${COMMAND_NAME}" \
    -f "${SCRIPT_DIR}/Dockerfile" \
    -t "${IMAGE}" \
    "${SCRIPT_DIR}" >/dev/null
fi

# --- Execute command ---
case "${command}" in
  validate)
    shift 2
    docker run --rm \
      -e 'AIRBYTE_CONFIG={}' \
      -e "AIRBYTE_COMMAND=${COMMAND_NAME}" \
      --tmpfs "${SECRETS_TMPFS_OPTS}" \
      -v "${connector_dir}:/input:ro" \
      "${IMAGE}" check \
        --config /secrets/config.json \
        --manifest-path /input/connector.yaml \
        "$@" 2>&1 | {
      valid=true
      while IFS= read -r line; do
        if echo "$line" | grep -q "declarative_component_schema.yaml schema failed"; then
          valid=false
          echo "$line"
        elif echo "$line" | grep -q "ValidationError\|is not valid under"; then
          echo "$line" >&2
        fi
      done
      if $valid; then
        echo '{"type":"LOG","log":{"level":"INFO","message":"Manifest is valid"}}'
      else
        exit 1
      fi
    }
    ;;

  check|discover)
    shift 2
    docker run --rm \
      -e "AIRBYTE_CONFIG=${AIRBYTE_CONFIG}" \
      -e "AIRBYTE_COMMAND=${COMMAND_NAME}" \
      --tmpfs "${SECRETS_TMPFS_OPTS}" \
      -v "${connector_dir}:/input:ro" \
      "${IMAGE}" "${command}" \
        --config /secrets/config.json \
        --manifest-path /input/connector.yaml \
        "$@"
    ;;

  read)
    connection="${3:-}"
    if [[ -z "${connection}" ]]; then
      echo "ERROR: read command requires a <connection> argument" >&2
      usage
      exit 1
    fi

    connection_dir="${connector_dir}/connections/${connection}"
    configured_catalog="${connection_dir}/configured_catalog.json"
    state_path="${connection_dir}/state.json"

    if [[ ! -f "${configured_catalog}" ]]; then
      echo "ERROR: Missing configured catalog: ${configured_catalog}" >&2
      exit 1
    fi

    # Create empty state if missing (first run)
    if [[ ! -f "${state_path}" ]]; then
      echo '[]' > "${state_path}"
      echo "INFO: Created empty state file: ${state_path}" >&2
    fi

    shift 3
    docker run --rm \
      -e "AIRBYTE_CONFIG=${AIRBYTE_CONFIG}" \
      -e "AIRBYTE_COMMAND=${COMMAND_NAME}" \
      --tmpfs "${SECRETS_TMPFS_OPTS}" \
      -v "${connector_dir}:/input:ro" \
      "${IMAGE}" read \
        --config /secrets/config.json \
        --catalog "/input/connections/${connection}/configured_catalog.json" \
        --manifest-path /input/connector.yaml \
        --state "/input/connections/${connection}/state.json" \
        "$@"
    ;;

  *)
    echo "ERROR: Unknown command '${command}'" >&2
    usage
    exit 1
    ;;
esac
