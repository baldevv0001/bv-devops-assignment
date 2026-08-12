module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.6"

  name = "${local.name}-vpc"
  cidr = var.vpc_cidr
  azs  = local.azs

  private_subnets = local.private_subnets
  public_subnets  = local.public_subnets

  # Required by the VPC CNI and by EKS for private endpoint resolution.
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Nodes live in private subnets and reach the internet outbound only. Egress
  # is still needed: pulling container images, reaching the EKS API, and
  # talking to AWS service endpoints.
  enable_nat_gateway     = true
  single_nat_gateway     = var.single_nat_gateway
  one_nat_gateway_per_az = !var.single_nat_gateway

  enable_flow_log                      = var.enable_flow_logs
  create_flow_log_cloudwatch_log_group = var.enable_flow_logs
  create_flow_log_cloudwatch_iam_role  = var.enable_flow_logs
  flow_log_max_aggregation_interval    = 60

  # These tags are load-bearing, not decorative. The AWS cloud controller
  # discovers subnets by tag when provisioning a load balancer for a Service:
  # without role/elb on the public subnets, a type=LoadBalancer Service stays
  # stuck in <pending> with no obvious explanation.
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
    Tier                     = "public"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
    Tier                              = "private"
  }

  tags = local.tags
}
