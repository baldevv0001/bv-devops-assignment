# Terraform

Provisions the EKS cluster the application runs on. Two configurations:

| Directory | Purpose | State |
| --- | --- | --- |
| [`eks/`](eks) | VPC, EKS cluster, node group, addons, Pod Identity roles | Local by default |
| [`bootstrap/`](bootstrap) | S3 bucket for remote state — optional | Local, by necessity |

## Quick start

```bash
cd terraform/eks
terraform init
terraform plan -var-file=environments/dev.tfvars
terraform apply -var-file=environments/dev.tfvars
aws eks update-kubeconfig --region ap-south-1 --name bv-devops-dev
```

Destroy when finished — this cluster costs roughly ₹30/hour:

```bash
terraform destroy -var-file=environments/dev.tfvars
```

Before applying, narrow the API endpoint to your own address in
`environments/dev.tfvars`:

```bash
curl -s https://checkip.amazonaws.com
```

Set `endpoint_public_access_cidrs = ["<that address>/32"]` and
`allow_public_api_from_anywhere = false`. The configuration refuses to plan with
`0.0.0.0/0` unless you set that flag, so leaving the API open is a decision
rather than an oversight.

## State

State is **local** by default — `terraform.tfstate` in `eks/`. That keeps the
project runnable end to end with nothing provisioned in advance, at the cost of
state that is not shared, not locked, and not backed up. Fine for a single
operator; not fine for a team or for CI.

To move to S3:

```bash
cd terraform/bootstrap
terraform init && terraform apply          # note the state_bucket_name output
cd ../eks
mv backend.tf.s3-example backend.tf        # then fill in the bucket name
terraform init -migrate-state
```

The bucket is versioned, encrypted, blocked from public access, and denies
non-TLS requests. There is **no DynamoDB lock table**: Terraform 1.10+ supports
native S3 state locking through a lock file in the bucket itself, which removes
a resource and its cost.

`bootstrap/` necessarily keeps its own state locally — it cannot store state in
the bucket it is responsible for creating. Its entire output is one bucket, so
losing that state costs an import, not a rebuild.

## Testing

The guard rails have native Terraform tests that use `mock_provider`, so they
need no AWS credentials and create nothing:

```bash
cd terraform/eks && terraform test
```

Thirteen cases: three that assert valid configurations plan and derive the
right topology — including the path where the optional addons are disabled,
which is the only thing that exercises the `[0]` indexes into the Pod Identity
module — and ten that assert specific misconfigurations are rejected. The
mocking is more elaborate than it looks — `aws_iam_policy_document`,
`aws_partition` and `aws_iam_session_context` all need realistic defaults,
because the generated placeholders are not valid JSON or valid ARNs and the
resulting errors drown out the ones being tested.

## Design decisions

**Official upstream modules.** `terraform-aws-modules/vpc` and
`terraform-aws-modules/eks`, pinned to `~> 6.6` and `~> 21.24`. Writing EKS from
raw resources means owning the launch template, the IAM roles, the security
group rules and the addon lifecycle — a large surface with no benefit here.

**EKS Pod Identity instead of IRSA.** A role trusts `pods.eks.amazonaws.com` and
is bound to a service account by an association object. No OIDC provider, no
trust-policy JSON with a subject string that has to match exactly, and the
binding is a first-class resource that can be listed and audited. `enable_irsa`
is off, so `oidc_provider_arn` is deliberately null.

Only the EBS CSI driver gets a role. The hello-world workload calls no AWS APIs,
which is why its ServiceAccount has no role and no mounted token.

**Nodes in private subnets, one NAT gateway.** Public subnets carry load
balancers and NAT gateways only. `single_nat_gateway = true` saves about
₹5/hour versus one per zone, and makes outbound internet access depend on one
zone. Inbound and pod-to-pod traffic are unaffected, so the cluster keeps
serving if that zone fails — nodes elsewhere just lose egress. Set it false for
production.

**IMDSv2 required, hop limit 1.** IMDSv1's unauthenticated GET is what turns a
server-side request forgery bug into stolen node credentials. A hop limit of 1
means the response cannot survive the extra hop out of a pod's network
namespace, so pods cannot reach IMDS at all — which is the intent, since
workloads get credentials through Pod Identity rather than by borrowing the
node's role.

**`ENABLE_NETWORK_POLICY` on the VPC CNI.** The chart's NetworkPolicy is inert
without a CNI that enforces it. This is the setting that makes it real on EKS.

**Secrets envelope encryption with a customer-managed KMS key**, plus a separate
key for EBS volumes so the two rotate independently.

**`authentication_mode = "API"`.** Drops the `aws-auth` ConfigMap in favour of
native access entries, so cluster access is expressed as IAM and shows up in
CloudTrail rather than living in a ConfigMap nobody audits.

**Subnet tags are load-bearing.** `kubernetes.io/role/elb` on public subnets and
`kubernetes.io/role/internal-elb` on private ones are how the cloud controller
discovers where to place a load balancer. Without them a `type=LoadBalancer`
Service sits in `<pending>` with no useful explanation.

**No Kubernetes provider in this configuration.** Pointing the `kubernetes`
provider at a cluster created in the same apply produces a configuration that
cannot be applied from scratch in one pass and cannot be destroyed cleanly once
the cluster is gone. Cluster-level objects such as the gp3 StorageClass are
applied after the cluster exists, in the observability step.

## Known limitations

- **Local state by default.** No locking and no history. Two concurrent applies
  will corrupt it. Switch to S3 for anything beyond one operator.
- **`dev.tfvars` ships with `allow_public_api_from_anywhere = true`** so a first
  run works without editing. Narrow it before any real use.
- **One node group.** No separate system/workload pools and no taints, so
  everything shares the same nodes.
- **No cluster autoscaler or Karpenter.** `node_max_size` exists but nothing
  moves the desired count; the HPA scales pods, not nodes.
- **VPC flow logs default to off** to avoid CloudWatch ingestion cost.
- **No AWS Load Balancer Controller.** `service.type=LoadBalancer` provisions an
  in-tree NLB, which is enough for this workload but gives no control over
  target-group behaviour or ALB features.
