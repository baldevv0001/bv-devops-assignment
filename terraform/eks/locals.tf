data "aws_availability_zones" "available" {
  state = "available"

  # Local Zones and Wavelength Zones cannot host EKS nodes, so restrict to
  # regular availability zones.
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_caller_identity" "current" {}

locals {
  name = "${var.project}-${var.environment}"

  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # Subnets are carved from the VPC CIDR by index. With a /16 and newbits 4
  # each subnet is a /20 (~4091 usable addresses), which matters because the
  # Amazon VPC CNI assigns every pod a real VPC IP — pod density is limited by
  # subnet size, not just by node size.
  #
  # Private subnets take the first block of indices, public the next. Public
  # subnets only ever hold load balancers and NAT gateways, so they are sized
  # the same for simplicity rather than need.
  private_subnets = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets  = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i + var.az_count)]

  tags = merge(
    {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Repository  = "bv-devops-assignment"
    },
    var.tags,
  )
}

# Guards for API exposure and node sizing live in variable validation blocks in
# variables.tf rather than in resource preconditions here, so that
# `terraform validate` catches them without AWS credentials or a plan.
