# hello-world Helm chart

Deploys the [hello-world service](../../app/README.md) with the availability
and security posture described below. Defaults are production-shaped rather
than minimal — installing with no overrides gives three zone-spread replicas, a
disruption budget, a restrictive NetworkPolicy and a hardened pod.

## Install

```bash
helm install hello-world charts/hello-world --namespace hello-world --create-namespace
```

On EKS, exposing it through an NLB:

```bash
helm install hello-world charts/hello-world \
  --namespace hello-world --create-namespace \
  --set service.type=LoadBalancer \
  --set serviceMonitor.enabled=true
```

## What the chart creates

| Object | Purpose |
| --- | --- |
| `Deployment` | 3 replicas, zone- and node-spread, rolling update with `maxUnavailable: 0` |
| `Service` | HTTP only. Type is configurable |
| `Service` (`-metrics`) | Always ClusterIP, port 9090, scrape target |
| `ServiceAccount` | Dedicated identity, no RoleBinding, no token mounted |
| `PodDisruptionBudget` | Keeps 2 replicas during voluntary disruption |
| `HorizontalPodAutoscaler` | 3–10 replicas on 70% CPU |
| `NetworkPolicy` | Default-deny with a DNS-only egress allow-list |
| `ServiceMonitor` | Optional, off by default |
| `Ingress` | Optional, off by default |

## Design decisions

**Two Services, not two ports on one.** A `LoadBalancer` Service publishes
every port it lists. Putting `:9090` on the main Service would expose
`/metrics` to the internet the moment `service.type` changed from ClusterIP.
The metrics Service is always ClusterIP, so that cannot happen by accident.

**Zone spread is `DoNotSchedule`, node spread is `ScheduleAnyway`.** Zone
spreading is the property that turns losing an AZ into partial capacity loss
instead of an outage, so it is a hard requirement — under pressure a replica
stays `Pending` with a legible reason rather than silently stacking into one
zone. Node spreading is worth having but not worth refusing to schedule over.

Both constraints use `matchLabelKeys: [pod-template-hash]`, which scopes the
skew calculation to the current ReplicaSet. Without it, pods from the outgoing
revision count toward skew during a rolling update and can deadlock the
rollout.

**No `preStop` hook.** The conventional `preStop: sleep 5` exists to hold a pod
open while endpoint removal propagates, but it needs a shell the distroless
image does not have. The application performs that drain itself on SIGTERM:
`/readyz` starts returning 503, traffic drains for `config.drainDelay`, then
in-flight requests finish. This is more precise than a fixed sleep and visible
in the pod's logs.

`terminationGracePeriodSeconds` must exceed `drainDelay + shutdownTimeout`, or
the kubelet sends SIGKILL part-way through the drain. The chart's default of
30s covers the default 5s + 15s.

**A memory limit but no CPU limit.** CPU limits are enforced by CFS quota,
which throttles the process for the remainder of each 100ms period once the
quota is spent — that shows up as latency spikes even when the node has idle
CPU. The CPU *request* already guarantees a share and protects neighbours.
Memory is different: it is incompressible, so an unbounded pod can push the
whole node into OOM rather than just itself. Set `resources.limits.cpu` only
where a hard cap is genuinely required.

**`automountServiceAccountToken: false`.** The service never calls the
Kubernetes API. A token that is not present cannot be stolen and replayed.

**Egress is restricted to DNS.** The service makes no outbound calls, so a
compromised pod cannot reach the EC2 metadata endpoint, the API server, other
namespaces, or the internet.

## Validation beyond schema

`values.schema.json` catches type and enum mistakes. Cross-field rules that
JSON Schema cannot express are enforced in `_helpers.tpl` and fail the render
with an explanation rather than producing a subtly broken deployment:

- `config.drainDelay` / `config.shutdownTimeout` must be Go durations — `5`
  is rejected, `5s` is accepted.
- `podDisruptionBudget.minAvailable` must be less than the replica count.
  Setting it equal produces a PDB that permits no disruption at all, which
  makes node drains hang forever and turns a routine cluster upgrade into an
  outage.
- `minAvailable` and `maxUnavailable` cannot both be set.

## Testing

The suite in `scripts/chart-test.sh` runs against a local kind cluster whose
three workers carry fake `topology.kubernetes.io/zone` labels, so the scheduler
makes the same decisions it would across three real AZs.

```bash
make kind-up
make chart-test
```

It asserts, among other things:

- replicas land in three distinct zones, one per zone,
- the pod runs non-root with a read-only root filesystem, all capabilities
  dropped and no service-account token,
- the NetworkPolicy admits `:9090` from the `monitoring` namespace **and
  blocks it from elsewhere** — both directions, so a policy that failed open
  would be caught,
- a rolling update drops zero requests out of ~3800 sent from inside the
  cluster during the rollout,
- draining a node succeeds, two replicas keep serving, and the evicted replica
  stays `Pending` rather than concentrating into a surviving zone.

That last one is the intended behaviour, not a failure: it is what
`whenUnsatisfiable: DoNotSchedule` buys.

## Key values

See [values.yaml](values.yaml) for the full annotated list.

| Value | Default | Notes |
| --- | --- | --- |
| `replicaCount` | `3` | Ignored when `autoscaling.enabled` |
| `image.digest` | `""` | Takes precedence over `tag`; pins the release to exact content |
| `service.type` | `ClusterIP` | `LoadBalancer` for EKS |
| `autoscaling.enabled` | `true` | Requires metrics-server |
| `podDisruptionBudget.minAvailable` | `2` | Must be < replica count |
| `topologySpread.zone.whenUnsatisfiable` | `DoNotSchedule` | Hard multi-AZ requirement |
| `networkPolicy.restrictEgress` | `true` | DNS-only egress |
| `resources.limits.cpu` | `""` | Deliberately unset |
| `serviceMonitor.enabled` | `false` | Needs prometheus-operator CRDs |
| `prometheusRule.enabled` | `false` | Alert rules; needs the same CRDs |
| `grafanaDashboard.enabled` | `false` | Dashboard ConfigMap for the Grafana sidecar |

## Observability

Three optional templates wire the service into kube-prometheus-stack. All are
off by default, because rendering them on a cluster without the
prometheus-operator CRDs fails the install with an unhelpful "no matches for
kind" error.

- **`serviceMonitor.enabled`** — scrapes the metrics Service on `:9090`.
- **`prometheusRule.enabled`** — six alerts covering availability, error rate,
  latency and zone spread.
- **`grafanaDashboard.enabled`** — renders `dashboards/hello-world.json` into a
  labelled ConfigMap that the Grafana sidecar loads. No Grafana credentials and
  no API calls are involved.

Alerts ship with the chart rather than with the monitoring release so that a
rule always matches the version of the application it was written for. See
[monitoring/README.md](../../monitoring/README.md) for what each alert does and
why its expression is shaped the way it is.
