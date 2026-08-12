#!/usr/bin/env bash
#
# Installs kube-prometheus-stack and wires the application into it.
#
# Usage: scripts/install-monitoring.sh [kind|eks]
#
# Both environments share monitoring/values/common.yaml and layer an
# environment file on top, so the two deployments differ only where they must.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENVIRONMENT="${1:-kind}"

CHART_VERSION="88.2.0"
NAMESPACE="monitoring"
RELEASE="kube-prometheus-stack"

case "$ENVIRONMENT" in
  kind|eks) ;;
  *) echo "usage: $0 [kind|eks]" >&2; exit 1 ;;
esac

VALUES=(
  --values "${REPO_ROOT}/monitoring/values/common.yaml"
  --values "${REPO_ROOT}/monitoring/values/${ENVIRONMENT}.yaml"
)

KUBECTL=(kubectl)
HELM=(helm)
if [[ "$ENVIRONMENT" == "kind" ]]; then
  KUBECTL=(kubectl --context kind-hello-world)
  HELM=(helm --kube-context kind-hello-world)
fi

echo "==> Installing kube-prometheus-stack ${CHART_VERSION} for ${ENVIRONMENT}"

"${HELM[@]}" repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
"${HELM[@]}" repo update prometheus-community >/dev/null

"${KUBECTL[@]}" create namespace "$NAMESPACE" --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f - >/dev/null

# Grafana's admin password comes from a Secret so it is never committed and
# never appears in `helm get values`.
if [[ "$ENVIRONMENT" == "eks" ]]; then
  if ! "${KUBECTL[@]}" -n "$NAMESPACE" get secret grafana-admin >/dev/null 2>&1; then
    PASSWORD="$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 20)"
    "${KUBECTL[@]}" -n "$NAMESPACE" create secret generic grafana-admin \
      --from-literal=admin-user=admin \
      --from-literal=admin-password="$PASSWORD"
    echo
    echo "    Generated a Grafana admin password and stored it in the grafana-admin secret."
    echo "    Read it back with:"
    echo "      kubectl -n $NAMESPACE get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d"
    echo
  fi
fi

# The CRDs in this chart are large enough to exceed the annotation size limit
# that client-side apply uses, so server-side apply is required.
"${HELM[@]}" upgrade --install "$RELEASE" prometheus-community/kube-prometheus-stack \
  --version "$CHART_VERSION" \
  --namespace "$NAMESPACE" \
  "${VALUES[@]}" \
  --wait --timeout 15m

echo
echo "==> Enabling the application's ServiceMonitor, alert rules and dashboard"

APP_VALUES=(
  --set serviceMonitor.enabled=true
  --set prometheusRule.enabled=true
  --set grafanaDashboard.enabled=true
)
if [[ "$ENVIRONMENT" == "kind" ]]; then
  APP_VALUES+=(--values "${REPO_ROOT}/charts/hello-world/ci/kind-values.yaml")
fi

"${KUBECTL[@]}" create namespace hello-world --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f - >/dev/null

"${HELM[@]}" upgrade --install hw "${REPO_ROOT}/charts/hello-world" \
  --namespace hello-world \
  "${APP_VALUES[@]}" \
  --wait --timeout 5m

echo
echo "==> Done"
"${KUBECTL[@]}" -n "$NAMESPACE" get pods

cat <<EOF

Reach the UIs:

  Grafana:
    kubectl -n $NAMESPACE port-forward svc/${RELEASE}-grafana 3000:80
    http://localhost:3000
EOF

if [[ "$ENVIRONMENT" == "kind" ]]; then
  cat <<EOF
    or http://localhost:30300 (NodePort), user admin / password admin
EOF
else
  cat <<EOF
    user admin, password from:
      kubectl -n $NAMESPACE get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d
EOF
fi

cat <<EOF

  Prometheus:
    kubectl -n $NAMESPACE port-forward svc/${RELEASE}-prometheus 9090:9090

  Alertmanager:
    kubectl -n $NAMESPACE port-forward svc/${RELEASE}-alertmanager 9093:9093

Verify the wiring with: scripts/monitoring-test.sh ${ENVIRONMENT}
EOF
