#!/usr/bin/env bash
set -euo pipefail

# Build the jira-enrich Rust binary as a container image and optionally load it
# into the local Kind cluster.
#
# Usage:
#   ./build.sh                  # build image with tag `local`
#   IMAGE_TAG=v0.1.0 ./build.sh # custom tag
#
# The produced image: `insight-jira-enrich:${IMAGE_TAG}`

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

IMAGE_NAME="insight-jira-enrich"
IMAGE_TAG="${IMAGE_TAG:-local}"
IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"

echo "=== Building jira-enrich ==="
echo "  Image: ${IMAGE}"

docker build -t "$IMAGE" -f Dockerfile .

KIND_CLUSTER="${KIND_CLUSTER:-insight}"
if command -v kind >/dev/null 2>&1 && kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER}$"; then
    echo "  Loading into Kind cluster '${KIND_CLUSTER}'..."
    kind load docker-image "$IMAGE" --name "$KIND_CLUSTER"
fi

echo "=== Done ==="
echo "  ${IMAGE}"
