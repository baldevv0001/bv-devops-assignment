module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.24"

  name               = local.name
  kubernetes_version = var.kubernetes_version

  vpc_id = module.vpc.vpc_id

  # Nodes and control plane ENIs in private subnets; public carries load balancers.
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.private_subnets

  # Private endpoint always on; public access is CIDR-restricted by a variable guard.
  endpoint_private_access      = true
  endpoint_public_access       = var.endpoint_public_access
  endpoint_public_access_cidrs = var.endpoint_public_access_cidrs

  # Drops the aws-auth ConfigMap for native access entries, so access is IAM.
  authentication_mode = "API"

  # Gives the identity running Terraform cluster-admin, so kubectl works after apply.
  enable_cluster_creator_admin_permissions = true

  # Envelope encryption for Secrets with a customer-managed key.
  create_kms_key                  = true
  enable_kms_key_rotation         = true
  kms_key_deletion_window_in_days = 7

  enabled_log_types                      = var.cluster_log_types
  create_cloudwatch_log_group            = true
  cloudwatch_log_group_retention_in_days = var.cluster_log_retention_days

  # Not needed: this cluster uses Pod Identity instead of IRSA.
  enable_irsa = false

  addons = merge(
    {
      # Installed before any node joins, or a node comes up without pod networking.
      vpc-cni = {
        before_compute = true
        configuration_values = jsonencode({
          env = {
            # Raises the pod-per-node ceiling by assigning /28 prefixes.
            ENABLE_PREFIX_DELEGATION = "true"
            WARM_PREFIX_TARGET       = "1"
            # The chart's NetworkPolicy is inert without this.
            ENABLE_NETWORK_POLICY = "true"
          }
        })
      }
      kube-proxy = {}
      coredns = {
        configuration_values = jsonencode({
          # Two replicas so DNS survives losing a node.
          replicaCount = 2
        })
      }
      # Serves credentials to pods using Pod Identity.
      eks-pod-identity-agent = {
        before_compute = true
      }
    },
    var.enable_metrics_server ? {
      metrics-server = {}
    } : {},
    var.enable_ebs_csi_driver ? {
      aws-ebs-csi-driver = {
        # Pod Identity: an association between a role and a service account.
        pod_identity_association = [{
          role_arn        = module.ebs_csi_pod_identity[0].iam_role_arn
          service_account = "ebs-csi-controller-sa"
        }]
      }
    } : {},
  )

  eks_managed_node_groups = {
    default = {
      # AL2023 is the current EKS-optimised AMI family.
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = var.node_instance_types
      capacity_type  = var.node_capacity_type

      min_size     = var.node_min_size
      max_size     = var.node_max_size
      desired_size = var.node_desired_size

      # Spanning every private subnet puts a node in each zone.
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
        # IMDSv2 only, so an SSRF bug cannot read node credentials.
        http_endpoint = "enabled"
        http_tokens   = "required"
        # Hop limit 1 stops pods reaching IMDS; they use Pod Identity instead.
        http_put_response_hop_limit = 1
      }

      # Replace failed nodes instead of leaving them NotReady.
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

  # Lets the control plane reach webhook and metrics ports on the nodes.
  node_security_group_enable_recommended_rules = true

  tags = local.tags

}
