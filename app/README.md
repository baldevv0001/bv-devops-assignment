# hello-world service

A small Go HTTP service used as the deployable workload for this project. Full
project documentation lives in the repository root README; this file covers the
service itself.

## Endpoints

The service binds **two** listeners.

### Public listener — port `8080`

| Method | Path       | Response                                            |
| ------ | ---------- | --------------------------------------------------- |
| `GET`  | `/`        | `200` `Hello World`                                  |
| `GET`  | `/healthz` | `200` `ok` — liveness                                |
| `GET`  | `/readyz`  | `200` `ready`, or `503` `draining` during shutdown   |
| any    | anything else | `404` `not found`                                 |

### Admin listener — port `9090`

| Method | Path       | Response                          |
| ------ | ---------- | --------------------------------- |
| `GET`  | `/metrics` | Prometheus exposition format      |
| `GET`  | `/healthz` | `200` `ok`                        |
| `GET`  | `/readyz`  | `200` `ready` / `503` `draining`  |

Metrics are deliberately **not** exposed on the public listener. Splitting them
onto a second port means a NetworkPolicy can allow scraping only from the
monitoring namespace without having to also constrain user traffic, and the
cloud load balancer never fronts the metrics endpoint at all.

## Configuration

Everything is read from the environment, so one image is promoted unchanged
between clusters. An unparseable value fails startup rather than being silently
ignored.

| Variable           | Default       | Meaning                                       |
| ------------------ | ------------- | --------------------------------------------- |
| `PORT`             | `8080`        | Public listener port                          |
| `ADMIN_PORT`       | `9090`        | Metrics/admin listener port                   |
| `MESSAGE`          | `Hello World` | Body returned by `/`                          |
| `LOG_LEVEL`        | `info`        | `debug`, `info`, `warn` or `error`            |
| `READ_TIMEOUT`     | `5s`          | Request read timeout                          |
| `WRITE_TIMEOUT`    | `10s`         | Response write timeout                        |
| `IDLE_TIMEOUT`     | `120s`        | Keep-alive idle timeout                       |
| `SHUTDOWN_TIMEOUT` | `15s`         | Budget for draining in-flight requests        |
| `DRAIN_DELAY`      | `5s`          | Time spent NotReady before listeners close    |

## Metrics

| Metric                          | Type      | Labels                    |
| ------------------------------- | --------- | ------------------------- |
| `http_requests_total`           | counter   | `method`, `route`, `status` |
| `http_request_duration_seconds` | histogram | `method`, `route`         |
| `http_requests_in_flight`       | gauge     | –                         |
| `hello_world_build_info`        | gauge     | `version`, `commit`       |

Plus the standard Go runtime and process collectors.

The `route` label is a fixed value supplied by the code, never the raw request
path. Unmatched paths all report `route="other"`, which bounds cardinality by
construction — otherwise anyone scanning the service for `/wp-admin`,
`/.env` and friends could grow the metric series count without limit and
exhaust Prometheus's memory.

## Shutdown behaviour

Endpoint removal in Kubernetes is eventually consistent: after a pod is marked
Terminating, every node's kube-proxy still has to observe the EndpointSlice
update and rewrite its rules. A server that exits as soon as it receives
SIGTERM will therefore refuse connections that are still being routed to it,
which is the usual source of 502s during a rolling update.

So on SIGTERM the service:

1. flips `/readyz` to `503` while continuing to serve traffic normally,
2. waits `DRAIN_DELAY` for that to propagate,
3. calls `http.Server.Shutdown` and lets in-flight requests finish within
   `SHUTDOWN_TIMEOUT`,
4. exits `0`.

Liveness keeps returning `200` throughout, otherwise the kubelet would kill the
pod mid-drain — exactly what the drain is trying to avoid.

## Container image

Multi-stage build producing a `gcr.io/distroless/static-debian12:nonroot`
image of roughly 21 MB. The binary is fully static (`CGO_ENABLED=0`), so the
runtime layer needs no libc, no shell and no package manager: there is no
interactive foothold if an attacker achieves execution. The image runs as uid
`65532`.

## Local development

```bash
make check          # gofmt, go vet, go test
make test-race      # tests under the race detector (needs a C compiler)
make run            # run on :8080 with metrics on :9090
make docker-smoke   # build the image and assert all 16 behaviours
```
