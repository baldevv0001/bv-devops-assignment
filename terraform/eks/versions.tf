terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      # The EKS module v21 requires >= 6.52.
      source  = "hashicorp/aws"
      version = "~> 6.52"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.13"
    }
  }

  # No backend block, so state is local. See backend.tf.s3-example to use S3.
}

provider "aws" {
  region = var.region

  # Applied to every resource, including ones inside modules.
  default_tags {
    tags = local.tags
  }
}
