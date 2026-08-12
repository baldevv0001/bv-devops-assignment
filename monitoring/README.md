# Monitoring

Prometheus, Alertmanager and Grafana via
[kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
`88.2.0`, covering both the cluster and the application.

## Install

```bash
scripts/install-monitoring.sh kind    # local
scripts/install-monitoring.sh eks     # on the provisioned cluster
```

On EKS, create the encrypted storage class first — Prometheus and Grafana both
claim volumes:

```bash
scripts/apply-storage-class.sh
```

Then verify:

```bash
scripts/monitoring-test.sh kind
scripts/monitoring-test.sh kind --fire-alert   # also proves an alert reaches Alertmanager
```

## Layout

| File | Purpose |
| --- | --- |
| `values/common.yaml` | Shared by every environment |
| `values/kind.yaml` | Local overrides — memory limits, no persistence |
| `values/eks.yaml` | Retention, gp3 persistence, secret-based Grafana password |

Application-specific pieces live with the application chart rather than here:
the `ServiceMonitor`, the `PrometheusRule`, and the Grafana dashboard are all
templates in `charts/hello-world`. That way a rule always matches the version of
the application it was written for — moving them into the monitoring release
would mean an app rollback silently leaves alerts referencing metrics that no
longer exist.

They are off by default and enabled by the install script, because rendering
them on a cluster without the prometheus-operator CRDs fails the install with an
unhelpful "no matches for kind" error.

## What gets monitored

**The cluster**, from the stack itself: node-exporter for node metrics,
kube-state-metrics for object state, the API server, kubelet and cAdvisor, plus
around 225 built-in recording and alerting rules.

**The application**, from its own `/metrics` on port 9090:

| Metric | Type |
| --- | --- |
| `http_requests_total` | counter, by method / route / status |
| `http_request_duration_seconds` | histogram, by method / route |
| `http_requests_in_flight` | gauge |
| `hello_world_build_info` | gauge, version / commit |

## Alerts

| Alert | Severity | Fires when |
| --- | --- | --- |
| `HelloWorldAllReplicasDown` | critical | No replica responds to a scrape for 2m |
| `HelloWorldReplicasUnavailable` | warning | Below desired replica count for 10m |
| `HelloWorldPodCrashLooping` | warning | More than 3 restarts in 15m |
| `HelloWorldHighErrorRate` | critical | 5xx ratio above 5% for 5m |
| `HelloWorldHighLatency` | warning | p99 above 500ms for 10m |
| `HelloWorldNotSpreadAcrossZones` | warning | Replicas on fewer than 3 nodes for 15m |

Three details in these rules are deliberate:

**`absent()` in the outage alert.** When every replica disappears there is no
`up` series left, so a bare `up == 0` stops matching at exactly the moment the
outage becomes total. The `absent()` arm covers that. This is verified rather
than assumed — `--fire-alert` scales the deployment to zero and waits for the
alert to reach Alertmanager.

**`clamp_min` in the error ratio.** An idle service divides zero by zero,
producing `NaN`, which compares false against any threshold. Clamping the
denominator keeps the expression evaluable.

**Probe endpoints excluded from latency.** `/healthz` and `/readyz` are scraped
constantly and answer in microseconds; including them drags the percentile down
far enough to hide real user latency.

## Metric pre-initialisation

A Prometheus `CounterVec` exports nothing for a label set it has never observed.
On a freshly started replica that means `rate(http_requests_total[5m])` has no
series to evaluate against — a dashboard shows a gap instead of a flat line, and
an error-rate alert cannot fire because there is nothing to compare.

The service therefore registers the label combinations its router can actually
produce at startup, so they read zero from the first scrape. Only reachable
combinations are registered; inventing others would leave permanently-zero
series in front of whoever reads the metrics next.

## Access

Neither Grafana nor Prometheus is exposed publicly. Neither has TLS or SSO, so
putting them behind a load balancer would mean an unauthenticated console on the
internet.

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093:9093
```

On kind, Grafana is also on `http://localhost:30300` with `admin` / `admin`.

On EKS the password is generated at install time into a Secret, so it is never
committed and never appears in `helm get values`:

```bash
kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d
```

## Known limitations

- **Alertmanager has no real receiver.** The `critical` route exists but sends
  nowhere, because a Slack or PagerDuty webhook is a secret and does not belong
  in a repository. To attach one:

  ```bash
  kubectl -n monitoring create secret generic alertmanager-slack \
    --from-literal=webhook-url='https://hooks.slack.com/services/...'
  ```

  then add a `slack_configs` block to the `critical` receiver in
  `values/common.yaml` referencing it.

- **Single Prometheus replica, local storage.** No Thanos or remote write, so
  retention is bounded by disk and there is no long-term history or
  cross-cluster view.
- **Control plane targets are disabled** on both environments. On EKS the
  control plane runs on AWS-managed infrastructure that cannot be scraped; on
  kind the components bind to localhost. Leaving them enabled produces
  permanently-down targets, which trains people to ignore alerts.
- **kube-proxy metrics are not scraped** on EKS — it binds to `127.0.0.1`
  unless its ConfigMap is changed.
- **`serviceMonitorSelectorNilUsesHelmValues: false`** makes Prometheus select
  every ServiceMonitor in the cluster. Convenient here, since the application is
  a separate release; in a large cluster you would scope it with a label
  selector instead.
- **No TLS between Prometheus and scrape targets.** Traffic stays inside the
  VPC, but a service mesh or scrape-level TLS would be expected in production.
