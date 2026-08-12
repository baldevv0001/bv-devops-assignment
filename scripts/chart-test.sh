#!/usr/bin/env bash
#
# Exercises the hello-world chart on the local kind cluster.
#
# This goes beyond "does it install": it asserts the properties the chart
# claims to provide — replicas spread across zones, a disruption budget that
# actually holds during a node drain, a hardened pod, and a rolling update that
# drops no requests. Run scripts/kind-up.sh first.
#
# Usage: scripts/chart-test.sh [--keep]
#   --keep   leave the release installed for manual inspection

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER_NAME="hello-world"
CONTEXT="kind-${CLUSTER_NAME}"
NAMESPACE="hello-world"
RELEASE="hw"
CHART="${REPO_ROOT}/charts/hello-world"
VALUES="${CHART}/ci/kind-values.yaml"
CURL_IMAGE="curlimages/curl:8.19.0"
KEEP=0
FAILURES=0

# Selects the workload pods only. The trailing "!component" term excludes the
# helm-test pod, which carries the same instance and name labels but sets
# app.kubernetes.io/component=test; without it a lingering test pod would be
# counted as a replica.
SELECTOR="app.kubernetes.io/instance=${RELEASE},app.kubernetes.io/name=hello-world,!app.kubernetes.io/component"

[[ "${1:-}" == "--keep" ]] && KEEP=1

k() { kubectl --context "$CONTEXT" "$@"; }
h() { helm --kube-context "$CONTEXT" "$@"; }

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
info() { printf '        %s\n' "$1"; }
section() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

check() {
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}

# Creates a namespace, first waiting out any Terminating leftover from a
# previous run. A namespace in Terminating still exists, so `create` is a no-op
# against it, but it rejects new pods — which shows up as a confusing
# "unreachable" failure rather than an obvious one.
ensure_namespace() {
  local ns="$1"
  for _ in $(seq 1 60); do
    [[ "$(k get ns "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || true)" == "Terminating" ]] || break
    sleep 2
  done
  k create namespace "$ns" --dry-run=client -o yaml | k apply -f - >/dev/null
}

# Prints "name node ready" for each pod of the release, skipping any that are
# terminating.
#
# This filter matters: a pod being deleted keeps reporting ready=true until its
# readiness probe fails, which here takes 2 failures x 5s. Helm's --wait
# returns as soon as the new ReplicaSet is fully ready, so for a few seconds
# after a rollout there are legitimately four "ready" pods — three new plus one
# still draining. Counting those raw double-counts the outgoing replica and
# also makes it look like two replicas share a zone.
live_pods() {
  k get pods -n "$NAMESPACE" -l "$SELECTOR" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.nodeName}{"\t"}{.status.containerStatuses[0].ready}{"\t"}{.metadata.deletionTimestamp}{"\n"}{end}' \
    | awk -F'\t' '$4 == "" { print $1, $2, $3 }'
}

# Waits until exactly `want` non-terminating pods exist and all are ready.
wait_for_live_ready() {
  local want="$1" total ready
  for _ in $(seq 1 60); do
    total="$(live_pods | wc -l)"
    ready="$(live_pods | awk '$3 == "true"' | wc -l)"
    if [[ "$total" -eq "$want" && "$ready" -eq "$want" ]]; then
      return 0
    fi
    sleep 2
  done
  return 1
}

# Runs curl from a throwaway pod and prints whatever it received.
#
# Each invocation gets a unique pod name. Reusing one name breaks as soon as a
# probe is *expected* to fail: `kubectl run --rm` can leave the pod behind when
# the command exits non-zero, and the next run then dies on a name collision
# instead of testing anything.
PROBE_SEQ=0
probe() {
  local ns="$1" url="$2" name
  PROBE_SEQ=$((PROBE_SEQ + 1))
  name="probe-${PROBE_SEQ}"
  k delete pod "$name" -n "$ns" --ignore-not-found --now >/dev/null 2>&1 || true
  k run "$name" -n "$ns" --image="$CURL_IMAGE" --restart=Never --rm -i --quiet \
    --command -- curl -fsS --max-time 8 "$url" 2>/dev/null || true
  k delete pod "$name" -n "$ns" --ignore-not-found --now --wait=false >/dev/null 2>&1 || true
}

cleanup() {
  k delete pod --namespace "$NAMESPACE" -l 'run' --ignore-not-found --now --wait=false >/dev/null 2>&1 || true
  k delete pod loadgen --namespace "$NAMESPACE" --ignore-not-found --now --wait=false >/dev/null 2>&1 || true
  k uncordon --all >/dev/null 2>&1 || true
  if [[ "$KEEP" -eq 0 ]]; then
    h uninstall "$RELEASE" --namespace "$NAMESPACE" >/dev/null 2>&1 || true
    # Only this suite's own namespace. The monitoring namespace is deliberately
    # left alone: it may hold a real kube-prometheus-stack installation, and
    # deleting it takes the whole monitoring stack with it while stranding the
    # operator's admission webhook pointing at a service that no longer exists.
    # Not waited on, to keep teardown quick — ensure_namespace() at the start
    # of the next run waits it out instead.
    k delete namespace "$NAMESPACE" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

CLUSTERS="$(kind get clusters 2>/dev/null || true)"
if ! grep -qx "$CLUSTER_NAME" <<<"$CLUSTERS"; then
  echo "kind cluster '$CLUSTER_NAME' not found. Run scripts/kind-up.sh first." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
section "Reset"

# A release left behind by a previous --keep run makes this suite lie. The
# server-side dry-run below would fail on "nodePort 30080 already allocated",
# and the replica assertions would count pods from the old revision. Start from
# a known-empty state instead of assuming one.
if h status "$RELEASE" --namespace "$NAMESPACE" >/dev/null 2>&1; then
  info "removing an existing '$RELEASE' release from a previous run"
  h uninstall "$RELEASE" --namespace "$NAMESPACE" --wait >/dev/null 2>&1 || true
fi
# Only this suite's namespace, for the reason given in cleanup(). The
# monitoring namespace is created if absent and otherwise reused.
k delete namespace "$NAMESPACE" --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1 || true
k uncordon --all >/dev/null 2>&1 || true
pass "starting from a clean namespace"

# ---------------------------------------------------------------------------
section "Static validation"

if h lint "$CHART" --values "$VALUES" >/dev/null 2>&1; then
  pass "helm lint"
else
  fail "helm lint"
  h lint "$CHART" --values "$VALUES" || true
fi

# The API server validates the rendered manifests against real schemas, which
# catches field name and type errors that helm lint cannot see.
if h template "$RELEASE" "$CHART" --values "$VALUES" --namespace "$NAMESPACE" \
    | k apply --dry-run=server -f - >/dev/null 2>&1; then
  pass "server-side dry-run accepts all manifests"
else
  fail "server-side dry-run rejected a manifest"
  h template "$RELEASE" "$CHART" --values "$VALUES" --namespace "$NAMESPACE" \
    | k apply --dry-run=server -f - 2>&1 | tail -5 || true
fi

# The HPA is disabled for the kind run, so verify that path by rendering it.
HPA_RENDER="$(h template "$RELEASE" "$CHART" --values "$VALUES" --set autoscaling.enabled=true 2>/dev/null || true)"
if grep -q 'kind: HorizontalPodAutoscaler' <<<"$HPA_RENDER"; then
  pass "HPA renders when autoscaling is enabled"
else
  fail "HPA did not render with autoscaling enabled"
fi

# With the HPA owning replicas, the Deployment must not also set them, or Helm
# and the autoscaler fight over the field on every upgrade.
HPA_DEPLOY="$(sed -n '/kind: Deployment/,/^---/p' <<<"$HPA_RENDER")"
if grep -q '^  replicas:' <<<"$HPA_DEPLOY"; then
  fail "Deployment still sets replicas while autoscaling is enabled"
else
  pass "Deployment omits replicas when the HPA owns it"
fi

# The values schema should reject a wrong type before anything reaches the API.
if h template "$RELEASE" "$CHART" --values "$VALUES" \
    --set-string replicaCount=three >/dev/null 2>&1; then
  fail "values schema accepted a non-integer replicaCount"
else
  pass "values schema rejects a non-integer replicaCount"
fi

# ---------------------------------------------------------------------------
section "Install"

ensure_namespace "$NAMESPACE"

h upgrade --install "$RELEASE" "$CHART" \
  --namespace "$NAMESPACE" \
  --values "$VALUES" \
  --wait --timeout 5m >/dev/null

pass "chart installed"

if wait_for_live_ready 3; then
  pass "3 replicas are Ready"
else
  fail "did not settle at 3 ready replicas"
  live_pods | sed 's/^/        /'
fi

# ---------------------------------------------------------------------------
section "High availability: topology spread"

# Map each pod to the zone of the node it landed on.
declare -A ZONE_COUNT=()
PLACEMENTS=""
while read -r pod node _ready; do
  [[ -z "$node" ]] && continue
  zone="$(k get node "$node" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')"
  ZONE_COUNT["$zone"]=$(( ${ZONE_COUNT["$zone"]:-0} + 1 ))
  PLACEMENTS+="        ${pod}  ->  ${node}  (${zone})"$'\n'
done < <(live_pods)

printf '%s' "$PLACEMENTS"
check "replicas occupy 3 distinct zones" "3" "${#ZONE_COUNT[@]}"

MAX_PER_ZONE=0
for z in "${!ZONE_COUNT[@]}"; do
  (( ZONE_COUNT[$z] > MAX_PER_ZONE )) && MAX_PER_ZONE=${ZONE_COUNT[$z]}
done
check "no zone holds more than one replica (maxSkew 1)" "1" "$MAX_PER_ZONE"

DISTINCT_NODES="$(live_pods | awk '{print $2}' | sort -u | wc -l)"
check "replicas occupy 3 distinct nodes" "3" "$DISTINCT_NODES"

# ---------------------------------------------------------------------------
section "Pod hardening"

POD="$(live_pods | head -1 | awk '{print $1}')"

check "runAsNonRoot" "true" \
  "$(k get pod "$POD" -n "$NAMESPACE" -o jsonpath='{.spec.containers[0].securityContext.runAsNonRoot}')"
check "runAsUser is 65532" "65532" \
  "$(k get pod "$POD" -n "$NAMESPACE" -o jsonpath='{.spec.containers[0].securityContext.runAsUser}')"
check "readOnlyRootFilesystem" "true" \
  "$(k get pod "$POD" -n "$NAMESPACE" -o jsonpath='{.spec.containers[0].securityContext.readOnlyRootFilesystem}')"
check "allowPrivilegeEscalation is false" "false" \
  "$(k get pod "$POD" -n "$NAMESPACE" -o jsonpath='{.spec.containers[0].securityContext.allowPrivilegeEscalation}')"
check "all capabilities dropped" "ALL" \
  "$(k get pod "$POD" -n "$NAMESPACE" -o jsonpath='{.spec.containers[0].securityContext.capabilities.drop[0]}')"
check "seccomp profile is RuntimeDefault" "RuntimeDefault" \
  "$(k get pod "$POD" -n "$NAMESPACE" -o jsonpath='{.spec.containers[0].securityContext.seccompProfile.type}')"
check "no CPU limit set" "" \
  "$(k get pod "$POD" -n "$NAMESPACE" -o jsonpath='{.spec.containers[0].resources.limits.cpu}')"
check "memory limit set" "128Mi" \
  "$(k get pod "$POD" -n "$NAMESPACE" -o jsonpath='{.spec.containers[0].resources.limits.memory}')"

# A projected service-account token would appear as a volume mount; with
# automountServiceAccountToken false there should be none.
POD_JSON="$(k get pod "$POD" -n "$NAMESPACE" -o json)"
if grep -q 'kube-api-access' <<<"$POD_JSON"; then
  fail "a service-account token is mounted into the pod"
else
  pass "no service-account token mounted"
fi

check "NetworkPolicy exists" "${RELEASE}-hello-world" \
  "$(k get networkpolicy -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}')"

POLICY_TYPES="$(k get networkpolicy "${RELEASE}-hello-world" -n "$NAMESPACE" \
  -o jsonpath='{.spec.policyTypes[*]}')"
check "policy covers both ingress and egress" "Ingress Egress" "$POLICY_TYPES"

# ---------------------------------------------------------------------------
section "Service and metrics wiring"

TEST_POD="${RELEASE}-hello-world-test-connection"
k delete pod "$TEST_POD" -n "$NAMESPACE" --ignore-not-found --now >/dev/null 2>&1 || true
if h test "$RELEASE" --namespace "$NAMESPACE" >/dev/null 2>&1; then
  pass "helm test (endpoints answer through the Service)"
else
  fail "helm test"
  # The pod's own logs, not `helm test --logs`, whose tail is the release
  # NOTES rather than anything about the failure.
  info "test pod logs:"
  k logs "$TEST_POD" -n "$NAMESPACE" 2>&1 | sed 's/^/          /' || true
  info "termination: $(k get pod "$TEST_POD" -n "$NAMESPACE" \
    -o jsonpath='exit={.status.containerStatuses[0].state.terminated.exitCode} reason={.status.containerStatuses[0].state.terminated.reason}' 2>/dev/null || true)"
fi

METRICS_SVC="${RELEASE}-hello-world-metrics"

# Asserted against build_info rather than http_requests_total: the request
# counter is a CounterVec with no pre-initialised series, so a replica that has
# not yet served a request exports no such line, and this Service balances
# across all three.
#
# The probe runs from the monitoring namespace because the NetworkPolicy only
# admits :9090 from there — and kindnet does enforce that, so probing from
# anywhere else would (correctly) be dropped.
ensure_namespace monitoring

METRICS_ALLOWED="$(probe monitoring "http://${METRICS_SVC}.${NAMESPACE}:9090/metrics")"
if grep -q '^hello_world_build_info' <<<"$METRICS_ALLOWED"; then
  pass "metrics reachable from the monitoring namespace"
else
  fail "metrics not reachable from monitoring on ${METRICS_SVC}:9090"
fi

# The matching negative case. Without this, a policy that silently failed open
# would still let the test above pass.
METRICS_DENIED="$(probe "$NAMESPACE" "http://${METRICS_SVC}:9090/metrics")"
if grep -q '^hello_world_build_info' <<<"$METRICS_DENIED"; then
  fail "NetworkPolicy did not block :9090 from outside the monitoring namespace"
else
  pass "NetworkPolicy blocks :9090 from outside the monitoring namespace"
fi

MAIN_SVC_PORTS="$(k get svc "${RELEASE}-hello-world" -n "$NAMESPACE" -o jsonpath='{.spec.ports[*].port}')"
check "main Service exposes only the HTTP port" "80" "$MAIN_SVC_PORTS"

# ---------------------------------------------------------------------------
section "Disruption budget"

check "PDB allows exactly one disruption" "1" \
  "$(k get pdb "${RELEASE}-hello-world" -n "$NAMESPACE" -o jsonpath='{.status.disruptionsAllowed}')"
check "PDB reports 3 healthy pods" "3" \
  "$(k get pdb "${RELEASE}-hello-world" -n "$NAMESPACE" -o jsonpath='{.status.currentHealthy}')"

# ---------------------------------------------------------------------------
section "Zero-downtime rolling update"

# A pod inside the cluster hammers the Service through kube-proxy while the
# Deployment is rolled. Any dropped request would mean the drain sequence or
# the maxUnavailable:0 strategy is not doing its job.
k run loadgen -n "$NAMESPACE" --image="$CURL_IMAGE" --restart=Never --command -- \
  /bin/sh -c "
    ok=0; fail=0
    end=\$(( \$(date +%s) + 75 ))
    while [ \$(date +%s) -lt \$end ]; do
      if curl -fsS --max-time 2 http://${RELEASE}-hello-world/ >/dev/null 2>&1; then
        ok=\$((ok+1))
      else
        fail=\$((fail+1))
      fi
    done
    echo \"RESULT ok=\$ok fail=\$fail\"
  " >/dev/null

k wait --for=condition=Ready pod/loadgen -n "$NAMESPACE" --timeout=60s >/dev/null
info "load generator running, triggering a rolling update"

h upgrade "$RELEASE" "$CHART" \
  --namespace "$NAMESPACE" \
  --values "$VALUES" \
  --set config.message="Hello World" \
  --set-string podAnnotations.rollout="$(date +%s)" \
  --wait --timeout 5m >/dev/null

pass "rolling update completed"

# Let the outgoing ReplicaSet finish terminating before any later assertion
# counts pods, so the drain section starts from a settled three.
wait_for_live_ready 3 || true

k wait --for=jsonpath='{.status.phase}'=Succeeded pod/loadgen -n "$NAMESPACE" --timeout=120s >/dev/null
RESULT="$(k logs loadgen -n "$NAMESPACE" | grep '^RESULT' || echo 'RESULT ok=0 fail=-1')"
OK_COUNT="$(sed -n 's/.*ok=\([0-9]*\).*/\1/p' <<<"$RESULT")"
FAIL_COUNT="$(sed -n 's/.*fail=\(-\?[0-9]*\).*/\1/p' <<<"$RESULT")"
info "requests during rollout: ${OK_COUNT} succeeded, ${FAIL_COUNT} failed"

check "no requests dropped during the rolling update" "0" "$FAIL_COUNT"
if [[ "${OK_COUNT:-0}" -gt 50 ]]; then
  pass "load generator sent a meaningful number of requests (${OK_COUNT})"
else
  fail "only ${OK_COUNT} requests sent; the test may not have overlapped the rollout"
fi
k delete pod loadgen -n "$NAMESPACE" --ignore-not-found >/dev/null

# ---------------------------------------------------------------------------
section "Node drain survival"

DRAIN_NODE="$(live_pods | head -1 | awk '{print $2}')"
DRAIN_ZONE="$(k get node "$DRAIN_NODE" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')"
info "draining ${DRAIN_NODE} (${DRAIN_ZONE})"

if k drain "$DRAIN_NODE" --ignore-daemonsets --delete-emptydir-data --force --timeout=90s >/dev/null 2>&1; then
  pass "drain succeeded (the PDB permitted one eviction)"
else
  fail "drain did not complete within 90s"
fi

sleep 5
STILL_READY="$(live_pods | awk '$3 == "true"' | wc -l)"
if [[ "$STILL_READY" -ge 2 ]]; then
  pass "${STILL_READY} replicas still Ready after losing a zone"
else
  fail "only ${STILL_READY} replicas Ready after drain, expected at least 2"
fi

# Retried: EndpointSlice updates after an eviction are eventually consistent,
# so a single probe immediately after the drain can race the endpoint being
# withdrawn and land on nothing.
SERVING=0
for attempt in 1 2 3; do
  DRAIN_BODY="$(probe "$NAMESPACE" "http://${RELEASE}-hello-world/")"
  if grep -q "Hello World" <<<"$DRAIN_BODY"; then
    SERVING=1
    [[ "$attempt" -gt 1 ]] && info "served on attempt ${attempt}"
    break
  fi
  sleep 3
done
if [[ "$SERVING" -eq 1 ]]; then
  pass "service still serving traffic with a zone down"
else
  fail "service unreachable after drain"
  k get endpointslice -n "$NAMESPACE" -o wide || true
fi

# The evicted replica should stay Pending rather than doubling up in a
# surviving zone: that refusal is exactly what DoNotSchedule buys.
PENDING="$(k get pods -n "$NAMESPACE" -l "$SELECTOR" --field-selector=status.phase=Pending \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep -c . || true)"
if [[ "$PENDING" -ge 1 ]]; then
  pass "evicted replica stayed Pending rather than concentrating in a live zone"
  REASON="$(k get pods -n "$NAMESPACE" -l "$SELECTOR" --field-selector=status.phase=Pending \
    -o jsonpath='{.items[0].status.conditions[0].message}' 2>/dev/null || true)"
  [[ -n "$REASON" ]] && info "scheduler: ${REASON:0:150}"
else
  info "no Pending replica; the scheduler found a placement satisfying the spread"
fi

info "uncordoning ${DRAIN_NODE}"
k uncordon "$DRAIN_NODE" >/dev/null

if wait_for_live_ready 3; then
  pass "all 3 replicas Ready again after uncordon"
else
  fail "did not return to 3 ready replicas after uncordon"
  live_pods | sed 's/^/        /'
fi

# ---------------------------------------------------------------------------
section "Result"

if [[ "$FAILURES" -eq 0 ]]; then
  printf '\033[32mAll chart tests passed.\033[0m\n'
else
  printf '\033[31m%d chart test(s) failed.\033[0m\n' "$FAILURES"
  exit 1
fi

if [[ "$KEEP" -eq 1 ]]; then
  echo
  echo "Release left installed. Inspect with:"
  echo "  kubectl --context $CONTEXT get all -n $NAMESPACE"
  echo "  curl http://localhost:30080/"
fi
