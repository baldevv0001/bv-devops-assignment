#!/usr/bin/env bash
# Verifies monitoring by querying the Prometheus and Grafana APIs.
# Usage: scripts/monitoring-test.sh [kind|eks] [--fire-alert]

set -euo pipefail

ENVIRONMENT="${1:-kind}"
FIRE_ALERT=0
for arg in "$@"; do
  [[ "$arg" == "--fire-alert" ]] && FIRE_ALERT=1
done
NAMESPACE="monitoring"
APP_NAMESPACE="hello-world"
RELEASE="kube-prometheus-stack"
CURL_IMAGE="curlimages/curl:8.19.0"
PROM="http://${RELEASE}-prometheus:9090"
GRAFANA="http://${RELEASE}-grafana:80"
FAILURES=0

if [[ "$ENVIRONMENT" == "kind" ]]; then
  K=(kubectl --context kind-hello-world)
else
  K=(kubectl)
fi

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
info() { printf '        %s\n' "$1"; }
section() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

PROBE_POD="monitoring-probe"

cleanup() {
  "${K[@]}" delete pod "$PROBE_POD" -n "$NAMESPACE" --ignore-not-found --now --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

# One long-lived probe pod, execed into per request; `kubectl run --rm -i` drops
# output intermittently. In-cluster, because the policy only admits this namespace.
start_probe() {
  "${K[@]}" delete pod "$PROBE_POD" -n "$NAMESPACE" --ignore-not-found --now >/dev/null 2>&1 || true
  "${K[@]}" run "$PROBE_POD" -n "$NAMESPACE" --image="$CURL_IMAGE" --restart=Never \
    --command -- sleep 3600 >/dev/null
  "${K[@]}" wait --for=condition=Ready "pod/${PROBE_POD}" -n "$NAMESPACE" --timeout=120s >/dev/null
}

incluster_curl() {
  "${K[@]}" exec -n "$NAMESPACE" "$PROBE_POD" -- curl -sS --max-time 20 "$@" 2>/dev/null || true
}

# Fetches a URL into a file. Parsing reads the file rather than a variable
# interpolated into Python, whose backslash escapes would break json.loads.
fetch_json() {
  local url="$1" out="$2"
  incluster_curl "$url" > "$out"
}

# Runs an instant PromQL query and prints the first sample's value, or nothing.
promql_value() {
  incluster_curl -G --data-urlencode "query=$1" "${PROM}/api/v1/query" \
    | python3 -c "
import json,sys
try:
    r = json.load(sys.stdin)['data']['result']
    print(r[0]['value'][1] if r else '')
except Exception:
    print('')
"
}

# Alert state lives in a label, not the sample value, so read it separately.
promql_value_state() {
  incluster_curl -G --data-urlencode "query=$1" "${PROM}/api/v1/query" \
    | python3 -c "
import json,sys
try:
    r = json.load(sys.stdin)['data']['result']
    print(r[0]['metric'].get('alertstate','') if r else '')
except Exception:
    print('')
"
}

# Counts the series returned by a query.
promql_count() {
  incluster_curl -G --data-urlencode "query=$1" "${PROM}/api/v1/query" \
    | python3 -c "
import json,sys
try:
    print(len(json.load(sys.stdin)['data']['result']))
except Exception:
    print(0)
"
}

section "Preflight"

# chart-test.sh uninstalls the app release when it finishes, which removes the
# ServiceMonitor and rules. Without this that looks like a dozen failures.
MISSING=""
"${K[@]}" get namespace "$NAMESPACE" >/dev/null 2>&1 || MISSING+="  - the ${NAMESPACE} namespace does not exist\n"
# wc, not `grep -q`: under pipefail, grep exiting early sends SIGPIPE to the
# producer and the whole pipeline reports failure.
POD_COUNT="$("${K[@]}" get pods -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l)"
if [[ "${POD_COUNT:-0}" -eq 0 ]]; then
  MISSING+="  - no pods in ${NAMESPACE}; kube-prometheus-stack is not installed\n"
fi
if ! "${K[@]}" get servicemonitor -n "$APP_NAMESPACE" >/dev/null 2>&1 \
   || [[ "$("${K[@]}" get servicemonitor -n "$APP_NAMESPACE" --no-headers 2>/dev/null | wc -l)" -eq 0 ]]; then
  MISSING+="  - no ServiceMonitor in ${APP_NAMESPACE}; the application is not wired into monitoring\n"
fi

if [[ -n "$MISSING" ]]; then
  printf '\033[31mPrerequisites are missing:\033[0m\n'
  printf "%b" "$MISSING"
  cat <<EOF

Run the installer first:

    scripts/install-monitoring.sh ${ENVIRONMENT}

Note that scripts/chart-test.sh uninstalls the application release when it
finishes, so run it BEFORE the installer, not after.
EOF
  exit 1
fi
pass "kube-prometheus-stack and the application's ServiceMonitor are present"

section "Probe"
start_probe
pass "probe pod ready in the ${NAMESPACE} namespace"

# Polls for a condition. After an install the operator regenerates config,
# Prometheus reloads, discovery runs, and only then does a scrape happen.
wait_for() {
  local timeout="$1"; shift
  local deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    if "$@"; then return 0; fi
    sleep 5
  done
  return 1
}

# Counts targets scraped right now. Not `sum(up{...})`, whose five-minute
# lookback still counts pods deleted moments ago. Matched on the job label,
# since scrapePool is named after the ServiceMonitor and has no "metrics" in it.
active_up_targets() {
  incluster_curl "${PROM}/api/v1/targets?state=active" \
    | python3 -c "
import json,sys
try:
    t = json.load(sys.stdin)['data']['activeTargets']
    print(len([x for x in t
               if x['labels'].get('job','').endswith('hello-world-metrics')
               and x.get('health') == 'up']))
except Exception:
    print(0)
"
}

targets_up()   { [[ "$(active_up_targets)" == "3" ]]; }
# Buffered before grepping, for the SIGPIPE reason above.
rules_loaded() {
  local out
  out="$(incluster_curl "${PROM}/api/v1/rules")"
  grep -q 'HelloWorldAllReplicasDown' <<<"$out"
}
# rate() needs two points, so a new target must be scraped twice.
rate_ready()   { [[ -n "$(promql_value 'sum(rate(http_requests_total[5m]))')" ]]; }

printf '        waiting for service discovery and rule evaluation to settle\n'
wait_for 240 targets_up   || true
wait_for 120 rules_loaded || true
wait_for 120 rate_ready   || true

# ---------------------------------------------------------------------------
section "Prometheus health"

READY="$(incluster_curl "${PROM}/-/ready")"
if [[ "$READY" == *"Ready"* || "$READY" == *"ready"* ]]; then
  pass "Prometheus reports ready"
else
  fail "Prometheus not ready (got: ${READY:-<empty>})"
fi

BUILD="$(incluster_curl "${PROM}/api/v1/status/buildinfo" | python3 -c "
import json,sys
try: print(json.load(sys.stdin)['data']['version'])
except Exception: print('')
")"
[[ -n "$BUILD" ]] && info "Prometheus version ${BUILD}"

# ---------------------------------------------------------------------------
section "Application scraping"

# Created by a different release, so this also proves the selector is not scoped.
SM="$("${K[@]}" get servicemonitor -n "$APP_NAMESPACE" -o name 2>/dev/null | wc -l)"
if [[ "$SM" -ge 1 ]]; then
  pass "ServiceMonitor exists in the application namespace"
else
  fail "no ServiceMonitor found in $APP_NAMESPACE"
fi

UP="$(active_up_targets)"
if [[ "${UP:-0}" == "3" ]]; then
  pass "Prometheus is scraping all 3 replicas (3 active targets, health=up)"
else
  fail "expected 3 active healthy scrape targets, got '${UP:-none}'"
  info "active targets in this scrape pool:"
  incluster_curl "${PROM}/api/v1/targets?state=active" | python3 -c "
import json,sys
try:
    for t in json.load(sys.stdin)['data']['activeTargets']:
        if t['labels'].get('job','').endswith('hello-world-metrics'):
            print('       ', t['scrapeUrl'], t.get('health'), t.get('lastError',''))
except Exception as e:
    print('        could not parse targets:', e)
"
fi

# Scraping working at all proves the NetworkPolicy admits this namespace.
if [[ "${UP:-0}" == "3" ]]; then
  pass "NetworkPolicy permits scraping from the monitoring namespace"
fi

BUILD_INFO="$(promql_count 'hello_world_build_info')"
if [[ "$BUILD_INFO" -ge 1 ]]; then
  pass "application build info is queryable (${BUILD_INFO} series)"
else
  fail "hello_world_build_info returned no series"
fi

# ---------------------------------------------------------------------------
section "Pre-initialised series"

# A replica that has served nothing must still export the counter.
for route in "/" "/healthz" "other"; do
  COUNT="$(promql_count "http_requests_total{route=\"${route}\"}")"
  if [[ "$COUNT" -ge 1 ]]; then
    pass "http_requests_total exists for route=\"${route}\" (${COUNT} series)"
  else
    fail "no http_requests_total series for route=\"${route}\""
  fi
done

# rate() over a missing series returns nothing at all.
RATE="$(promql_value 'sum(rate(http_requests_total[5m]))')"
if [[ -n "$RATE" ]]; then
  pass "rate() over the request counter evaluates (${RATE} req/s)"
else
  fail "rate(http_requests_total[5m]) returned no result"
fi

# ---------------------------------------------------------------------------
section "Alert rules"

RULES_FILE="$(mktemp)"
trap 'rm -f "$RULES_FILE"; cleanup' EXIT
fetch_json "${PROM}/api/v1/rules" "$RULES_FILE"

LOADED="$(python3 -c "
import json,sys
d = json.load(sys.stdin)
names = [r['name'] for g in d['data']['groups'] for r in g['rules'] if r.get('type')=='alerting']
print('\n'.join(n for n in names if n.startswith('HelloWorld')))
" < "$RULES_FILE" 2>/dev/null || true)"

EXPECTED_RULES=(
  HelloWorldAllReplicasDown
  HelloWorldReplicasUnavailable
  HelloWorldPodCrashLooping
  HelloWorldHighErrorRate
  HelloWorldHighLatency
  HelloWorldNotSpreadAcrossZones
)
for rule in "${EXPECTED_RULES[@]}"; do
  if grep -qx "$rule" <<<"$LOADED"; then
    pass "rule loaded: $rule"
  else
    fail "rule not loaded: $rule"
  fi
done

# A loaded rule whose expression errors looks healthy and never fires.
BROKEN="$(python3 -c "
import json,sys
d = json.load(sys.stdin)
for g in d['data']['groups']:
    for r in g['rules']:
        if r.get('health') not in (None, 'ok'):
            print(r.get('name'), r.get('health'), r.get('lastError',''))
" < "$RULES_FILE")"
RULE_COUNT="$(python3 -c "
import json,sys
d = json.load(sys.stdin)
print(sum(len(g['rules']) for g in d['data']['groups']))
" < "$RULES_FILE")"

# An empty list means nothing unless rules were actually parsed.
if [[ "${RULE_COUNT:-0}" -lt 1 ]]; then
  fail "no rules parsed from the API; the health check below would be meaningless"
elif [[ -z "$BROKEN" ]]; then
  pass "none of the ${RULE_COUNT} loaded rules is in an error state"
else
  fail "rules with evaluation errors:"
  echo "$BROKEN" | sed 's/^/        /'
fi

# Watchdog is the stack's own proof-of-life alert.
WATCHDOG="$(promql_value 'ALERTS{alertname="Watchdog",alertstate="firing"}')"
if [[ -n "$WATCHDOG" ]]; then
  pass "Watchdog alert is firing (the alerting pipeline is alive)"
else
  fail "Watchdog is not firing; alert evaluation may not be running"
fi

# ---------------------------------------------------------------------------
section "Cluster monitoring"

for check in \
  "kube_node_info|kube-state-metrics is exporting node objects" \
  "node_memory_MemAvailable_bytes|node-exporter is exporting node metrics" \
  "kube_pod_container_status_restarts_total|pod restart counters are available" \
  "apiserver_request_total|API server metrics are being scraped"
do
  q="${check%%|*}"; desc="${check##*|}"
  n="$(promql_count "$q")"
  if [[ "$n" -ge 1 ]]; then
    pass "$desc (${n} series)"
  else
    fail "$desc — query '$q' returned nothing"
  fi
done

# ---------------------------------------------------------------------------
section "Grafana"

if [[ "$ENVIRONMENT" == "kind" ]]; then
  GRAFANA_AUTH="admin:admin"
else
  GRAFANA_AUTH="admin:$("${K[@]}" -n "$NAMESPACE" get secret grafana-admin -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d)"
fi

HEALTH="$(incluster_curl "${GRAFANA}/api/health")"
if grep -q '"database"' <<<"$HEALTH"; then
  pass "Grafana API is responding"
else
  fail "Grafana health check failed (got: ${HEALTH:-<empty>})"
fi

# Asking Grafana by uid is the only proof the sidecar picked the ConfigMap up.
# The sidecar writes the file, then Grafana imports it on its own schedule.
DASH_FILE="$(mktemp)"
TITLE=""
for _ in $(seq 1 12); do
  incluster_curl -u "$GRAFANA_AUTH" "${GRAFANA}/api/dashboards/uid/hello-world" > "$DASH_FILE"
  TITLE="$(python3 -c "
import json,sys
try: print(json.load(sys.stdin)['dashboard']['title'])
except Exception: print('')
" < "$DASH_FILE" 2>/dev/null || true)"
  [[ -n "$TITLE" ]] && break
  sleep 5
done

if [[ -n "$TITLE" ]]; then
  pass "the application dashboard was loaded by the Grafana sidecar"
  info "dashboard title: ${TITLE}"
  PANELS="$(python3 -c "
import json,sys
try: print(len(json.load(sys.stdin)['dashboard']['panels']))
except Exception: print(0)
" < "$DASH_FILE")"
  info "panels: ${PANELS}"
else
  fail "dashboard uid 'hello-world' not found in Grafana"
  info "the sidecar watches for ConfigMaps labelled grafana_dashboard=1"
fi
rm -f "$DASH_FILE"

DS_FILE="$(mktemp)"
incluster_curl -u "$GRAFANA_AUTH" "${GRAFANA}/api/datasources" > "$DS_FILE"
DS_TYPES="$(python3 -c "
import json,sys
try: print(' '.join(sorted({d.get('type','') for d in json.load(sys.stdin)})))
except Exception: print('')
" < "$DS_FILE")"
if grep -qw 'prometheus' <<<"$DS_TYPES"; then
  pass "a Prometheus datasource is provisioned"
  info "datasources: ${DS_TYPES}"
else
  fail "no Prometheus datasource found in Grafana (types: ${DS_TYPES:-none})"
fi
rm -f "$DS_FILE"

# ---------------------------------------------------------------------------
if [[ "$FIRE_ALERT" -eq 1 ]]; then
  section "End-to-end alert delivery"

  info "scaling the application to zero — this is a deliberate outage"
  ORIGINAL="$("${K[@]}" -n "$APP_NAMESPACE" get deploy hw-hello-world -o jsonpath='{.spec.replicas}')"
  "${K[@]}" -n "$APP_NAMESPACE" scale deploy/hw-hello-world --replicas=0 >/dev/null

  restore() {
    "${K[@]}" -n "$APP_NAMESPACE" scale deploy/hw-hello-world --replicas="${ORIGINAL:-3}" >/dev/null 2>&1 || true
  }

  STATE="none"
  for i in $(seq 1 14); do
    sleep 25
    STATE="$(promql_value_state 'ALERTS{alertname="HelloWorldAllReplicasDown"}')"
    info "t+$((i * 25))s: alertstate=${STATE:-none}"
    [[ "$STATE" == "firing" ]] && break
  done

  if [[ "$STATE" == "firing" ]]; then
    pass "HelloWorldAllReplicasDown fired after the outage"
    # With no replicas there is no `up` series, so a bare "== 0" would not fire.
    pass "the absent() arm handled the total-outage case"
  else
    fail "HelloWorldAllReplicasDown did not reach firing (last state: ${STATE:-none})"
  fi

  AM="$(incluster_curl "http://${RELEASE}-alertmanager:9093/api/v2/alerts" \
    | python3 -c "
import json,sys
try:
    a = json.load(sys.stdin)
    print(len([x for x in a if x['labels'].get('alertname')=='HelloWorldAllReplicasDown']))
except Exception:
    print(0)
")"
  if [[ "${AM:-0}" -ge 1 ]]; then
    pass "the alert was delivered to Alertmanager"
  else
    fail "the alert never reached Alertmanager"
  fi

  info "restoring ${ORIGINAL:-3} replicas"
  restore
  "${K[@]}" -n "$APP_NAMESPACE" rollout status deploy/hw-hello-world --timeout=180s >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
section "Result"

if [[ "$FAILURES" -eq 0 ]]; then
  printf '\033[32mAll monitoring checks passed.\033[0m\n'
else
  printf '\033[31m%d monitoring check(s) failed.\033[0m\n' "$FAILURES"
  exit 1
fi
