#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

echo "  Registering connectors..."
./scripts/upload-manifests.sh --all

echo "  Applying Terraform connections..."
./scripts/apply-connections.sh --all

echo "  Syncing Kestra flows..."
./scripts/sync-flows.sh --all
