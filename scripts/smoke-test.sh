#!/usr/bin/env bash
# Smoke-tests a built image: endpoints, metrics isolation, non-root, clean drain.
# Usage: scripts/smoke-test.sh <image-ref>

set -euo pipefail

IMAGE="${1:?usage: smoke-test.sh <image-ref>}"
CONTAINER="hello-world-smoke-$$"
FAILURES=0

cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

# check <description> <expected> <actual>
check() {
  if [[ "$2" == "$3" ]]; then
    pass "$1"
  else
    fail "$1 (expected '$2', got '$3')"
  fi
}

echo "==> Starting $IMAGE"
# Short drain keeps the test quick; the default is 5s.
docker run -d --name "$CONTAINER" \
  -e DRAIN_DELAY=1s \
  -e MESSAGE="Hello World" \
  -p 127.0.0.1::8080 \
  -p 127.0.0.1::9090 \
  "$IMAGE" >/dev/null

APP_ADDR="$(docker port "$CONTAINER" 8080/tcp | head -1)"
ADMIN_ADDR="$(docker port "$CONTAINER" 9090/tcp | head -1)"
echo "    app=$APP_ADDR admin=$ADMIN_ADDR"

echo "==> Waiting for readiness"
for i in $(seq 1 50); do
  if curl -fsS --max-time 2 "http://${APP_ADDR}/healthz" >/dev/null 2>&1; then
    echo "    ready after ${i} attempt(s)"
    break
  fi
  if [[ $i -eq 50 ]]; then
    echo "    never became ready; container logs:" >&2
    docker logs "$CONTAINER" >&2 || true
    exit 1
  fi
  sleep 0.2
done

echo
echo "==> Endpoints"
check "GET / returns the greeting" \
  "Hello World" "$(curl -fsS "http://${APP_ADDR}/")"

check "GET / returns 200" \
  "200" "$(curl -s -o /dev/null -w '%{http_code}' "http://${APP_ADDR}/")"

check "GET /healthz returns 200" \
  "200" "$(curl -s -o /dev/null -w '%{http_code}' "http://${APP_ADDR}/healthz")"

check "GET /readyz returns 200" \
  "200" "$(curl -s -o /dev/null -w '%{http_code}' "http://${APP_ADDR}/readyz")"

check "unknown path returns 404" \
  "404" "$(curl -s -o /dev/null -w '%{http_code}' "http://${APP_ADDR}/nope")"

echo
echo "==> Metrics isolation"
check "metrics are served on the admin port" \
  "200" "$(curl -s -o /dev/null -w '%{http_code}' "http://${ADMIN_ADDR}/metrics")"

check "metrics are NOT served on the public port" \
  "404" "$(curl -s -o /dev/null -w '%{http_code}' "http://${APP_ADDR}/metrics")"

METRICS="$(curl -fsS "http://${ADMIN_ADDR}/metrics")"
for metric in http_requests_total http_request_duration_seconds hello_world_build_info go_goroutines; do
  if grep -q "^${metric}" <<<"$METRICS"; then
    pass "exposes ${metric}"
  else
    fail "missing ${metric}"
  fi
done

echo
echo "==> Container hardening"
check "image declares a non-root user" \
  "65532:65532" "$(docker inspect -f '{{.Config.User}}' "$CONTAINER")"

# Distroless has no shell, so this exec failing is the assertion.
if docker exec "$CONTAINER" /bin/sh -c 'echo reachable' >/dev/null 2>&1; then
  fail "a shell is present in the runtime image"
else
  pass "no shell present in the runtime image"
fi

echo
echo "==> Graceful shutdown"
docker kill --signal=TERM "$CONTAINER" >/dev/null

# Readiness must fail before the listener closes.
DRAINING=0
for _ in $(seq 1 20); do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 1 "http://${APP_ADDR}/readyz" || true)"
  if [[ "$code" == "503" ]]; then
    DRAINING=1
    break
  fi
  sleep 0.1
done
if [[ "$DRAINING" == "1" ]]; then
  pass "readiness reports 503 while draining"
else
  fail "never observed a draining readiness response"
fi

EXIT_CODE="$(timeout 30 docker wait "$CONTAINER" || echo timeout)"
check "container exits cleanly after SIGTERM" "0" "$EXIT_CODE"

CONTAINER_LOGS="$(docker logs "$CONTAINER" 2>&1)"
if grep -q '"msg":"shutdown complete"' <<<"$CONTAINER_LOGS"; then
  pass "logged a completed shutdown"
else
  fail "no shutdown-complete log line"
fi

echo
if [[ "$FAILURES" -eq 0 ]]; then
  printf '\033[32mAll smoke tests passed.\033[0m\n'
else
  printf '\033[31m%d smoke test(s) failed.\033[0m\n' "$FAILURES"
  echo "--- container logs ---"
  docker logs "$CONTAINER" 2>&1 || true
  exit 1
fi
