#!/usr/bin/env bash
#
# Verifies that the monitoring stack is actually monitoring things.
#
# "All pods are Running" proves very little: Prometheus runs happily with zero
# targets, and a dashboard ConfigMap that the sidecar never picked up looks
# exactly like one it did. Every check here queries the Prometheus or Grafana
# API for a result.
#
# Usage: scripts/monitoring-test.sh [kind|eks] [--fire-alert]
#
#   --fire-alert  additionally scales the application to zero and waits for
#                 HelloWorldAllReplicasDown to reach Alertmanager, then
#                 restores it. Takes about four minutes and causes a real
#                 outage, so it is opt-in.

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

# One long-lived probe pod, execed into for every request.
#
# The obvious alternative — `kubectl run --rm -i` per request — drops its output
# intermittently, which shows up as checks that fail while the thing they test
# is demonstrably working. A single pod plus exec is deterministic and much
# faster, since nothing is scheduled per query.
#
# It runs inside the cluster rather than through a port-forward because the
# NetworkPolicy only admits the monitoring namespace; a port-forward would
# bypass the very thing under test.
start_probe() {
  "${K[@]}" delete pod "$PROBE_POD" -n "$NAMESPACE" --ignore-not-found --now >/dev/null 2>&1 || true
  "${K[@]}" run "$PROBE_POD" -n "$NAMESPACE" --image="$CURL_IMAGE" --restart=Never \
    --command -- sleep 3600 >/dev/null
  "${K[@]}" wait --for=condition=Ready "pod/${PROBE_POD}" -n "$NAMESPACE" --timeout=120s >/dev/null
}

incluster_curl() {
  "${K[@]}" exec -n "$NAMESPACE" "$PROBE_POD" -- curl -sS --max-time 20 "$@" 2>/dev/null || true
}

# Fetches a URL into a file. Parsing always reads from a file rather than from
# a shell variable interpolated into Python source: API responses contain
# backslash escapes (PromQL expressions are full of \"), and Python would
# interpret those escapes before json.loads ever saw them. The parse then threw,
# the except branch printed nothing, and the check reported a false result —
# in one case a false *pass*.
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

# Prints the alertstate label of the first matching ALERTS series. Alert state
# lives in a label, not in the sample value, so promql_value cannot read it.
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

# Both prerequisites are easy to lose without noticing: scripts/chart-test.sh
# uninstalls the application release when it finishes, which takes the
# ServiceMonitor and alert rules with it. Without this check that shows up as a
# dozen unrelated-looking failures further down instead of one clear message.
MISSING=""
"${K[@]}" get namespace "$NAMESPACE" >/dev/null 2>&1 || MISSING+="  - the ${NAMESPACE} namespace does not exist\n"
# Counted with wc rather than tested with `grep -q`. Under `set -o pipefail` a
# `producer | grep -q` pipeline is a race: grep exits at the first match, the
# producer gets SIGPIPE, and pipefail reports the whole pipeline as failed. That
# made this preflight intermittently claim the stack was not installed while
# nine pods were running. wc reads its input to the end, so it cannot misfire.
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

# Waits for a condition, polling every 5s.
#
# Nothing here is synchronous. After the application is installed the operator
# has to regenerate Prometheus's config, Prometheus has to reload it, service
# discovery has to run, and only then does a scrape interval elapse before the
# first sample exists. Sampling once immediately after an install reliably
# reports everything as broken.
wait_for() {
  local timeout="$1"; shift
  local deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    if "$@"; then return 0; fi
    sleep 5
  done
  return 1
}

# Counts targets Prometheus is scraping *right now*.
#
# Deliberately not `sum(up{...})`: an instant query resolves each series to its
# last sample within a five-minute lookback, so pods deleted moments ago still
# contribute their final up=1. Straight after a redeploy that reports six
# healthy replicas when three exist. The targets API reports live state.
# Matched on the job label, which the operator sets to the Service name
# (hw-hello-world-metrics). Not on scrapePool, which is named after the
# ServiceMonitor (serviceMonitor/hello-world/hw-hello-world/0) and contains no
# "metrics"; and not on a substring of the whole target, because the
# cluster=hello-world external label makes every target in the cluster match.
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
# Buffered into a variable before grepping, for the SIGPIPE reason above — the
# rules payload is hundreds of kilobytes, which makes the race far more likely
# than it looks.
rules_loaded() {
  local out
  out="$(incluster_curl "${PROM}/api/v1/rules")"
  grep -q 'HelloWorldAllReplicasDown' <<<"$out"
}
# rate() needs at least two points inside its window, so a freshly discovered
# target has to be scraped twice before this returns anything at all.
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

# The ServiceMonitor is created by the app chart in a different namespace and a
# different Helm release, so this also proves the operator's selector is not
# restricted to its own release label.
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

# Scraping succeeding at all is itself the proof that the NetworkPolicy admits
# the monitoring namespace to port 9090 while denying everyone else.
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

# The point of pre-initialising: a replica that has served no traffic must
# still export the counter, so rate() sees zero rather than a missing series.
for route in "/" "/healthz" "other"; do
  COUNT="$(promql_count "http_requests_total{route=\"${route}\"}")"
  if [[ "$COUNT" -ge 1 ]]; then
    pass "http_requests_total exists for route=\"${route}\" (${COUNT} series)"
  else
    fail "no http_requests_total series for route=\"${route}\""
  fi
done

# rate() over a series that exists returns a number; over a missing one it
# returns nothing at all. This is the assertion that matters for alerting.
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

# A rule that is loaded but whose expression errors is worse than no rule: it
# looks healthy and never fires. Check none are in an error state.
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

# Asserting on a rule count as well as on emptiness: an empty 'broken' list
# means nothing only if rules were actually parsed. Previously a parse failure
# produced an empty list and reported a false pass.
if [[ "${RULE_COUNT:-0}" -lt 1 ]]; then
  fail "no rules parsed from the API; the health check below would be meaningless"
elif [[ -z "$BROKEN" ]]; then
  pass "none of the ${RULE_COUNT} loaded rules is in an error state"
else
  fail "rules with evaluation errors:"
  echo "$BROKEN" | sed 's/^/        /'
fi

# Watchdog is the stack's own proof-of-life alert. If it is not firing, the
# alerting pipeline is not working and nothing else would fire either.
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

# The dashboard is delivered as a labelled ConfigMap and loaded by a sidecar.
# Asking Grafana for it by uid is the only way to know the sidecar actually
# picked it up — the ConfigMap existing proves nothing.
# The sidecar writes the file, then Grafana's file provisioner imports it on
# its own schedule. Retry rather than assume the import has already happened.
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
    # This is the case the absent() arm exists for: with no replicas left there
    # is no `up` series at all, so a bare "== 0" would never fire — precisely
    # when the outage is total.
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
