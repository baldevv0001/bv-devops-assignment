# bv-devops-assignment

A production-shaped Kubernetes workload: a Go microservice, a Helm chart with real high-availability
primitives, Terraform for an EKS cluster, and Prometheus/Grafana monitoring for both the service and
the cluster.

---

## Status

Read this before anything else. It states what was actually executed and what was not.

| Part | State | How it was verified |
| --- | --- | --- |
| Go microservice + image | Working | 14 unit tests, 98.1% coverage, 16 smoke tests |
| Helm chart | Working | 36 assertions on a 3-zone kind cluster |
| Terraform for EKS | **Never applied to AWS** | `terraform validate` + 13 mocked tests |
| Prometheus + Grafana | Working | 26 assertions on kind, including a live alert to Alertmanager |
| CI/CD deploy pipeline | **Not built** | Three CI workflows validate; none deploys |

Two things are deliberately absent, and neither is claimed to work:

- **The Terraform was never applied against a real AWS account.** It passes `terraform validate` and
  13 mocked tests that need no credentials. No `terraform plan` was ever run against AWS, because no
  credentials were configured. Treat the EKS side as reviewed code, not as a running cluster.
- **The deployment pipeline was optional in the brief and was not built.** CI lints, tests and
  builds on every pull request, but nothing pushes an image or deploys anywhere.

Everything that runs locally on kind was executed repeatedly and is reproducible with the commands
below.

---

## Repository layout

```
app/                      Go microservice and its Dockerfile
charts/hello-world/       Helm chart, including alert rules and a Grafana dashboard
terraform/eks/            VPC, EKS cluster, node group, addons, Pod Identity
terraform/bootstrap/      Optional S3 bucket for remote state
monitoring/values/        kube-prometheus-stack values, shared plus per-environment
scripts/                  Bootstrap and verification scripts
test/kind/cluster.yaml    3-worker kind cluster with fake availability-zone labels
.github/workflows/        app-ci, chart-ci, terraform-ci
```

The Helm chart lives in this repository rather than a separate one, so the application and the chart
that deploys it move through the same pull request. Nothing publishes the chart to a registry.

Component-level documentation sits next to the code it describes:

- [app/README.md](app/README.md) — endpoints, configuration, shutdown behaviour
- [charts/hello-world/README.md](charts/hello-world/README.md) — chart values and design decisions
- [terraform/README.md](terraform/README.md) — infrastructure decisions and limitations
- [monitoring/README.md](monitoring/README.md) — alerts, dashboards, access

---

## Prerequisites

| Tool | Version used | Needed for |
| --- | --- | --- |
| Docker | 29.6.2 | Building the image, running kind |
| kind | 0.32.0 | Local cluster |
| kubectl | 1.36.1 | Everything Kubernetes |
| Helm | 3.20.0 | Chart and monitoring stack |
| Go | 1.26.5 | Unit tests, local runs |
| Terraform | 1.15.8 | Infrastructure code (1.10+ required) |
| AWS CLI | 2.36.20 | Only for the EKS path |

`make` and `gcc` are optional. `make` runs the targets below; `gcc` enables `make test-race`, since
the Go race detector needs cgo. Every target maps to a script that can be run directly.

---

## Quick start — local, no AWS account, no cost

This is the path that was actually executed. It needs no cloud credentials.

**1. Create a 3-zone kind cluster and load the image.**

```bash
make kind-up
```

The three workers are labelled `topology.kubernetes.io/zone=ap-south-1a|b|c`. Those labels are the
point: without them there is one topology domain, the zone spread constraint is trivially satisfied,
and none of the availability behaviour can be observed locally.

**2. Run the chart test suite.**

```bash
make chart-test
```

36 assertions covering placement, hardening, disruption budget, a rolling update and a node drain.
See [Verification](#verification) for what it proves.

**3. Install Prometheus, Alertmanager and Grafana, and wire the application in.**

```bash
make monitoring-install
```

**4. Verify the monitoring actually monitors.**

```bash
make monitoring-test
```

Optionally prove alert delivery end to end. This scales the application to zero, waits for
`HelloWorldAllReplicasDown` to reach Alertmanager, and restores it. It takes about four minutes:

```bash
make monitoring-test-alert
```

**5. Look at it.**

```bash
make grafana
```

Grafana is then on <http://localhost:3000> with `admin` / `admin`. The application dashboard is
**Hello World Service**.

Grafana's Service is a NodePort on 30300, but `test/kind/cluster.yaml` only maps 30080 to the host,
so that port is not reachable from outside the cluster. Use the port-forward above.

> **Order matters.** `make chart-test` uninstalls the application release when it finishes, which
> removes the ServiceMonitor and alert rules. Run it *before* `make monitoring-install`, not after.
> `monitoring-test` has a preflight check that says so if you get it the wrong way round.

**6. Tear down.**

```bash
make kind-down
```

---

## The application alone

```bash
make check          # gofmt, go vet, go test
make run            # serve on :8080, metrics on :9090
make docker-smoke   # build the image and run 16 checks against the running container
```

The service exposes **two listeners**:

| Port | Paths | Purpose |
| --- | --- | --- |
| 8080 | `GET /`, `GET /healthz`, `GET /readyz` | User traffic |
| 9090 | `GET /metrics`, `GET /healthz`, `GET /readyz` | Prometheus scraping |

Configuration is read entirely from the environment — `PORT`, `ADMIN_PORT`, `MESSAGE`, `LOG_LEVEL`,
`READ_TIMEOUT`, `WRITE_TIMEOUT`, `IDLE_TIMEOUT`, `SHUTDOWN_TIMEOUT`, `DRAIN_DELAY`. An unparseable
value fails startup rather than being silently ignored, so a typo in a Helm value breaks the pod
loudly instead of quietly changing behaviour.

Exported metrics: `http_requests_total`, `http_request_duration_seconds`, `http_requests_in_flight`,
`hello_world_build_info`, plus the standard Go runtime and process collectors.

---

## The EKS path — never executed, review only

```bash
cd terraform/eks
terraform init
terraform test                                   # 13 mocked tests, no credentials needed
terraform plan  -var-file=environments/dev.tfvars # needs AWS credentials
terraform apply -var-file=environments/dev.tfvars # costs money
```

Then, in order:

```bash
aws eks update-kubeconfig --region ap-south-1 --name bv-devops-dev
scripts/apply-storage-class.sh          # encrypted gp3, reads the KMS key from Terraform output
scripts/install-monitoring.sh eks
helm upgrade --install hello-world charts/hello-world \
  --namespace hello-world --create-namespace \
  --set service.type=LoadBalancer \
  --set serviceMonitor.enabled=true \
  --set prometheusRule.enabled=true \
  --set grafanaDashboard.enabled=true
```

**Before applying**, narrow the API endpoint in `terraform/eks/environments/dev.tfvars`:

```bash
curl -s https://checkip.amazonaws.com
```

Set `endpoint_public_access_cidrs = ["<that address>/32"]` and
`allow_public_api_from_anywhere = false`. The configuration refuses to plan with `0.0.0.0/0` unless
that flag is set, so leaving the API open is a decision rather than an oversight. The committed
`dev.tfvars` ships with the flag **enabled** so a first run works unedited — change it.

Destroy when finished:

```bash
make tf-destroy
```

---

## Architecture

**Infrastructure.** A VPC across three availability zones with public and private subnets. Nodes and
the control plane's cross-account network interfaces live in the private subnets; public subnets
carry only load balancers and NAT gateways. One EKS managed node group of three `t3.medium`
instances, one per zone.

**Cluster addons.** `vpc-cni`, `kube-proxy`, `coredns`, `eks-pod-identity-agent`, `metrics-server`
and `aws-ebs-csi-driver`.

**Workload.** Three replicas spread one per zone, fronted by a ClusterIP Service by default or a
LoadBalancer Service on EKS. A second, always-ClusterIP Service carries the metrics port.

**Monitoring.** kube-prometheus-stack 88.2.0 in the `monitoring` namespace, scraping both cluster
components and the application.

### Pinned versions

| Component | Version |
| --- | --- |
| Terraform | `>= 1.10` |
| AWS provider | `~> 6.52` |
| VPC module | `~> 6.6` |
| EKS module | `~> 21.24` |
| EKS Pod Identity module | `~> 2.8` |
| Kubernetes | `1.34` |
| kube-prometheus-stack | `88.2.0` |
| Go | `1.26.5` |
| Base image | `gcr.io/distroless/static-debian12:nonroot` |

---

## Design decisions and trade-offs

### Two Services, not two ports on one

A `LoadBalancer` Service publishes **every** port it lists. Putting `:9090` on the main Service
would expose `/metrics` to the internet the moment `service.type` changed from ClusterIP. The
metrics Service is always ClusterIP, so that cannot happen by accident.

### Zone spread is a hard constraint, node spread is not

- Zone spread uses `whenUnsatisfiable: DoNotSchedule`. It is what turns losing an availability zone
  into partial capacity loss rather than an outage, so under pressure a replica stays `Pending` with
  a legible reason instead of silently stacking into one zone.
- Node spread uses `ScheduleAnyway`. Preferring one pod per node is worth having, but not worth
  refusing to schedule over.

Both use `matchLabelKeys: [pod-template-hash]`, which scopes the skew calculation to the current
ReplicaSet. Without it, pods from the outgoing revision count toward skew during a rolling update
and can deadlock the rollout.

A consequence worth knowing: after draining a node, the evicted replica stays `Pending` rather than
doubling up in a surviving zone. That is the intended behaviour, not a failure.

### No preStop hook

The conventional `preStop: sleep 5` exists to hold a pod open while endpoint removal propagates, but
it needs a shell the distroless image does not have. The application performs the drain itself on
SIGTERM:

1. `/readyz` starts returning 503 while traffic is still served,
2. it waits `DRAIN_DELAY` (5s) for kube-proxy on every node to observe the EndpointSlice update,
3. in-flight requests finish within `SHUTDOWN_TIMEOUT` (15s),
4. the process exits 0.

Liveness keeps returning 200 throughout, otherwise the kubelet would kill the pod mid-drain.
`terminationGracePeriodSeconds` is 30, which must exceed 5 + 15.

### A memory limit but no CPU limit

CPU limits are enforced by CFS quota, which throttles the process for the remainder of each 100ms
period once the quota is spent — visible as latency spikes even when the node has idle CPU. The CPU
*request* already guarantees a share. Memory is different: it is incompressible, so an unbounded
pod can push the whole node into OOM rather than just itself. Requests are `50m` / `64Mi`; the only
limit is `128Mi` of memory.

### EKS Pod Identity instead of IRSA

A role trusts `pods.eks.amazonaws.com` and is bound to a service account by an association object.
No OIDC provider, no trust-policy JSON with a subject string that must match exactly, and the
binding is a first-class resource that can be listed and audited. `enable_irsa` is off, so the
`oidc_provider_arn` output is deliberately null.

Only the EBS CSI driver gets a role. The application calls no AWS APIs, which is why its
ServiceAccount has no role and no mounted token.

### One NAT gateway by default

`single_nat_gateway = true` saves roughly ₹5/hour against one per zone, and makes outbound internet
access depend on a single zone. Inbound and pod-to-pod traffic are unaffected, so the cluster keeps
serving if that zone fails — nodes elsewhere just lose egress. Set it to `false` for production.

### Local Terraform state by default

State is written to `terraform/eks/terraform.tfstate`. That keeps the project runnable end to end
with nothing provisioned in advance, at the cost of state that is not shared, not locked and not
backed up. `terraform/bootstrap/` creates a versioned, encrypted S3 bucket for remote state when
wanted, and `terraform/eks/backend.tf.s3-example` is the backend block to enable it. There is no
DynamoDB lock table — Terraform 1.10+ locks natively in S3 via `use_lockfile`.

### No Kubernetes provider in the Terraform

Pointing the `kubernetes` provider at a cluster created in the same apply produces a configuration
that cannot be applied from scratch in one pass and cannot be destroyed cleanly once the cluster is
gone. Cluster-level objects such as the gp3 StorageClass are applied afterwards by
`scripts/apply-storage-class.sh`.

---

## Security

**Infrastructure**

- Nodes run in private subnets; only load balancers and NAT gateways sit in public subnets.
- IMDSv2 is required and the hop limit is 1, so pods cannot reach instance metadata at all.
  Workloads get credentials through Pod Identity rather than by borrowing the node's role.
- Kubernetes Secrets use envelope encryption with a customer-managed KMS key; EBS volumes use a
  second, separate key so the two rotate independently.
- `authentication_mode = "API"` drops the `aws-auth` ConfigMap in favour of native access entries,
  so cluster access is expressed as IAM and appears in CloudTrail.
- Control plane logs go to CloudWatch. Node root volumes are encrypted.
- The configuration refuses to plan with the API endpoint open to `0.0.0.0/0` unless explicitly
  acknowledged.

**Application**

- Distroless image with a static, CGO-free binary. No shell, no package manager, nothing to pivot to
  after an RCE. Runs as uid 65532.
- `runAsNonRoot`, `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false`, all capabilities
  dropped, `seccompProfile: RuntimeDefault`.
- `automountServiceAccountToken: false` — the service never calls the Kubernetes API, and a token
  that is not present cannot be stolen.
- A NetworkPolicy allows HTTP from anywhere, admits `:9090` only from the `monitoring` namespace,
  and restricts egress to DNS. Both directions of the metrics rule are tested.
- The `route` metric label is supplied by the code, never taken from the URL. Unmatched paths all
  collapse to `route="other"`, so scanning for `/wp-admin` cannot grow the series count without
  bound.

---

## Observability

kube-prometheus-stack provides cluster monitoring — node-exporter, kube-state-metrics, the API
server, kubelet and cAdvisor, plus around 225 built-in rules.

The application ships its own ServiceMonitor, alert rules and Grafana dashboard **inside the
chart**, so a rule always matches the version of the application it was written for. All three are
off by default, because rendering them without the prometheus-operator CRDs fails the install.

| Alert | Severity | Fires when |
| --- | --- | --- |
| `HelloWorldAllReplicasDown` | critical | No replica responds to a scrape for 2m |
| `HelloWorldReplicasUnavailable` | warning | Below desired replica count for 10m |
| `HelloWorldPodCrashLooping` | warning | More than 3 restarts in 15m |
| `HelloWorldHighErrorRate` | critical | 5xx ratio above 5% for 5m |
| `HelloWorldHighLatency` | warning | p99 above 500ms for 10m |
| `HelloWorldNotSpreadAcrossZones` | warning | Replicas on fewer than 3 nodes for 15m |

Three details in those expressions are deliberate:

- **`absent()` in the outage alert.** When every replica disappears there is no `up` series left, so
  a bare `up == 0` stops matching at exactly the moment the outage becomes total.
- **`clamp_min` in the error ratio.** An idle service divides zero by zero, producing `NaN`, which
  compares false against any threshold.
- **Probe endpoints excluded from latency.** `/healthz` and `/readyz` are scraped constantly and
  answer in microseconds, which would drag the percentile down far enough to hide real latency.

The service also pre-registers the metric label combinations its router can produce, so they read
zero from the first scrape. A Prometheus `CounterVec` exports nothing for a label set it has never
observed, which means `rate()` on a fresh replica would otherwise evaluate against a missing series
rather than zero, and an error-rate alert could not fire.

---

## Continuous integration

Three workflows run on pull requests. None uses secrets, and none deploys.

| Workflow | Jobs | What it does |
| --- | --- | --- |
| `app-ci` | `test`, `image` | gofmt, vet, race tests, build image, 16 smoke tests |
| `chart-ci` | `lint`, `install` | Lint, render, guards, then the 36-assertion kind suite |
| `terraform-ci` | `validate`, `scan` | fmt, validate both configs, 13 mocked tests, Trivy scan |

The Trivy scan reports findings without failing the build, because several are deliberate trade-offs
documented above and gating on them would push toward ignore-comments that hide real findings later.

---

## Cost

Approximate hourly cost in `ap-south-1`, at roughly ₹95 to the US dollar:

| Component | USD/hour |
| --- | --- |
| EKS control plane | 0.100 |
| 3 × `t3.medium` | 0.125 |
| NAT gateway (one) | 0.056 |
| Network load balancer | 0.024 |
| EBS volumes | 0.008 |
| **Total** | **≈ 0.31** |

That is roughly **₹30 per hour**, or about **₹100–150** for a two-to-three hour
create-verify-destroy session. Left running for a month it would be in the region of ₹22,000.
`make tf-destroy` removes everything.

---

## Verification

Every number below came from an actual run on a 3-worker kind cluster.

**Container** — `make docker-smoke`, 16 checks: all endpoints answer; `/metrics` is reachable on
9090 and returns 404 on 8080; the image declares uid 65532; `docker exec /bin/sh` fails because no
shell exists; SIGTERM produces a 503 readiness response and then a clean exit 0.

**Chart** — `make chart-test`, 36 assertions:

- replicas land on three distinct nodes in three distinct zones, one per zone,
- pod runs non-root with a read-only root filesystem, all capabilities dropped, no service-account
  token, and no CPU limit,
- the NetworkPolicy admits `:9090` from the `monitoring` namespace **and blocks it from
  elsewhere** — both directions, so a policy that failed open would be caught,
- a rolling update dropped **0 of ~3,600 requests** sent from inside the cluster during the rollout,
- draining a node succeeded, two replicas kept serving, and the evicted replica stayed `Pending`
  rather than concentrating into a surviving zone.

**Monitoring** — `make monitoring-test`, 26 assertions: three healthy scrape targets, 225 rules
loaded with none in an error state, cluster metrics present, and the dashboard loaded into Grafana
by the sidecar. With `--fire-alert`, scaling to zero drove `HelloWorldAllReplicasDown` from pending
to firing and into Alertmanager as `severity=critical`.

**Terraform** — `terraform validate` on both configurations and 13 `terraform test` runs using
`mock_provider`, so no credentials are used and nothing is created. Three assert that a valid
configuration plans and derives the expected topology; ten assert that specific misconfigurations
are rejected.

---

## Known limitations

- **Never applied to AWS.** The Terraform passes `validate` and 13 mocked tests. No `plan` was run
  against a real account and no cluster was ever created, so the EKS path is unproven in practice.
- **No deployment pipeline.** This was the optional item in the brief. CI validates, builds and
  tests, but nothing publishes an image or deploys.
- **The default image does not exist.** The chart defaults to `docker.io/baldevv0001/hello-world`,
  which has never been pushed. The kind flow works because `scripts/kind-up.sh` builds the image
  locally and loads it into the cluster. To deploy anywhere else, build and push it first and set
  `image.repository`.
- **`dev.tfvars` allows the Kubernetes API from `0.0.0.0/0`** so a first run works unedited. Narrow
  it before any real use.
- **Alertmanager has no receiver.** The `critical` route exists but sends nowhere, because a webhook
  URL is a secret and does not belong in a repository. Wiring instructions are in
  [monitoring/README.md](monitoring/README.md).
- **Local Terraform state.** No locking and no history; two concurrent applies would corrupt it.
- **Single Prometheus replica with local storage.** No Thanos or remote write, so retention is
  bounded by disk and there is no long-term or cross-cluster view.
- **One node group, no cluster autoscaler.** The HPA scales pods between 3 and 10, but nothing
  scales nodes, so `node_max_size` is never reached automatically.
- **Control plane scrape targets are disabled.** On EKS the control plane runs on AWS-managed
  infrastructure that cannot be scraped; on kind those components bind to localhost. Leaving them
  enabled produces permanently-down targets, which trains people to ignore alerts.
- **No AWS Load Balancer Controller.** `service.type=LoadBalancer` provisions an in-tree NLB, which
  is enough here but gives no control over target-group behaviour or ALB features.
- **The chart is not published.** It is installed from this directory; nothing pushes it to a chart
  registry.
