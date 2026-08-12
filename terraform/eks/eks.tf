module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.24"

  name               = local.name
  kubernetes_version = var.kubernetes_version

  vpc_id = module.vpc.vpc_id

  # Nodes and the control plane's cross-account ENIs both live in the private
  # subnets. Public subnets carry load balancers only.
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.private_subnets

  # The private endpoint is always on, so in-cluster traffic to the API never
  # leaves the VPC. Public access is what lets kubectl work from a laptop, and
  # is CIDR-restricted by the guard in locals.tf.
  endpoint_private_access      = true
  endpoint_public_access       = var.endpoint_public_access
  endpoint_public_access_cidrs = var.endpoint_public_access_cidrs

  # API mode drops the old aws-auth ConfigMap in favour of native access
  # entries, so cluster access is expressed as IAM rather than as a ConfigMap
  # that no audit trail covers.
  authentication_mode = "API"

  # Grants the identity running Terraform cluster-admin, so kubectl works
  # immediately after apply without a second bootstrapping step.
  enable_cluster_creator_admin_permissions = true

  # Envelope encryption for Kubernetes Secrets, using a customer-managed KMS
  # key created by the module. Without this, Secrets are encrypted only by the
  # EKS-managed key at the etcd layer.
  create_kms_key                  = true
  enable_kms_key_rotation         = true
  kms_key_deletion_window_in_days = 7

  enabled_log_types                      = var.cluster_log_types
  create_cloudwatch_log_group            = true
  cloudwatch_log_group_retention_in_days = var.cluster_log_retention_days

  # IRSA is not needed: this cluster uses EKS Pod Identity, which associates an
  # IAM role with a service account through an API object instead of an OIDC
  # trust policy. Leaving the OIDC provider uncreated removes a moving part.
  enable_irsa = false

  addons = merge(
    {
      # before_compute installs the CNI before any node joins. Without it a
      # node can come up, fail to get pod networking, and sit NotReady.
      vpc-cni = {
        before_compute = true
        configuration_values = jsonencode({
          env = {
            # Prefix delegation raises the pod-per-node ceiling considerably by
            # assigning /28 prefixes instead of individual secondary IPs.
            ENABLE_PREFIX_DELEGATION = "true"
            WARM_PREFIX_TARGET       = "1"
            # Enforce NetworkPolicy in the data plane. The chart's policy is
            # inert without this.
            ENABLE_NETWORK_POLICY = "true"
          }
        })
      }
      kube-proxy = {}
      coredns = {
        configuration_values = jsonencode({
          # Two replicas so DNS survives a single node loss. CoreDNS failure
          # looks like every service in the cluster breaking at once.
          replicaCount = 2
        })
      }
      # The agent that serves credentials to pods using Pod Identity. Nothing
      # else in this configuration works without it.
      eks-pod-identity-agent = {
        before_compute = true
      }
    },
    var.enable_metrics_server ? {
      metrics-server = {}
    } : {},
    var.enable_ebs_csi_driver ? {
      aws-ebs-csi-driver = {
        # Pod Identity in place of IRSA: no OIDC provider, no trust policy
        # JSON, just an association between a role and a service account.
        pod_identity_association = [{
          role_arn        = module.ebs_csi_pod_identity[0].iam_role_arn
          service_account = "ebs-csi-controller-sa"
        }]
      }
    } : {},
  )

  eks_managed_node_groups = {
    default = {
      # AL2023 is the current EKS-optimised AMI family; Amazon Linux 2 is
      # end-of-life for new EKS versions.
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = var.node_instance_types
      capacity_type  = var.node_capacity_type

      min_size     = var.node_min_size
      max_size     = var.node_max_size
      desired_size = var.node_desired_size

      # Spanning every private subnet is what puts a node in each zone, which
      # is the precondition for the workload's zone spread constraint.
      subnet_ids = module.vpc.private_subnets

      block_device_mappings = {
        root = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = var.node_disk_size
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }

      metadata_options = {
        # IMDSv2 only. IMDSv1's unauthenticated GET is what turns a
        # server-side request forgery bug into stolen node credentials.
        http_endpoint = "enabled"
        http_tokens   = "required"
        # A hop limit of 1 means the response never survives the extra network
        # hop out of a pod's namespace, so pods cannot reach IMDS at all. That
        # is the intent: workloads get credentials through Pod Identity, not by
        # borrowing the node's role.
        http_put_response_hop_limit = 1
      }

      # Surface node failures as replacements instead of leaving a NotReady
      # node in the group indefinitely.
      node_repair_config = {
        enabled = true
      }

      update_config = {
        max_unavailable_percentage = 33
      }

      labels = {
        role = "general"
      }

      tags = local.tags
    }
  }

  # Allows the control plane to reach webhook and metrics ports on the nodes.
  # Without it, admission webhooks and metrics-server scraping time out in ways
  # that are tedious to diagnose.
  node_security_group_enable_recommended_rules = true

  tags = local.tags

}
