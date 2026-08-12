#!/usr/bin/env bash
# Creates the three-zone kind cluster and loads the app image into it.
# Usage: scripts/kind-up.sh [image-tag]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER_NAME="hello-world"
IMAGE="${1:-hello-world:ci}"

echo "==> Cluster"
CLUSTERS="$(kind get clusters 2>/dev/null || true)"
if grep -qx "$CLUSTER_NAME" <<<"$CLUSTERS"; then
  echo "    '$CLUSTER_NAME' already exists, reusing it"
else
  kind create cluster --config "${REPO_ROOT}/test/kind/cluster.yaml" --wait 120s
fi

echo
echo "==> Building $IMAGE"
docker build \
  --build-arg VERSION=ci \
  --build-arg COMMIT="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo none)" \
  -t "$IMAGE" \
  "${REPO_ROOT}/app"

echo
echo "==> Loading image into cluster nodes"
kind load docker-image "$IMAGE" --name "$CLUSTER_NAME"

echo
echo "==> Nodes"
kubectl --context "kind-${CLUSTER_NAME}" get nodes \
  -o custom-columns='NAME:.metadata.name,STATUS:.status.conditions[-1].type,ZONE:.metadata.labels.topology\.kubernetes\.io/zone'

echo
echo "Cluster ready. Run scripts/chart-test.sh to exercise the chart."
