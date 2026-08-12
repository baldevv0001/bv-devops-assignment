data "aws_availability_zones" "available" {
  state = "available"

  # Local and Wavelength zones cannot host EKS nodes.
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  name = "${var.project}-${var.environment}"

  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # /16 split into /20s. The VPC CNI gives every pod a real VPC IP, so subnet
  # size caps pod density. Private subnets take the first indices, public the next.
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

# Guards for API exposure and node sizing are variable validations in variables.tf.
